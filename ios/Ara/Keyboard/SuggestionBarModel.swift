import Foundation
import SwiftUI

/// State behind the suggestion bar: the mic key's relay client and the
/// ✨ Clean action. One model because they share the bar's single status line
/// and the same lifecycle (created per keyboard appearance, dropped on
/// disappear — nothing here survives an invocation).
@MainActor
final class SuggestionBarModel: ObservableObject {
    /// What the mic key means right now — the design table's three rows,
    /// plus the transient utterance states.
    enum MicState: Equatable {
        /// Not purchased: Ara's mic is a paid feature; the system dictation
        /// button (Tier B) still exists because `hasDictationKey` is unset.
        case locked
        /// No Full Access: the relay is unreadable by construction.
        case noFullAccess
        /// Purchased + Full Access, but the app has no live heartbeat.
        case appCold
        case ready
        case recording
        case transcribing
    }

    @Published private(set) var micState: MicState = .locked
    /// One line in the bar's center: live partials while recording,
    /// instructions or errors otherwise. Nil shows nothing.
    @Published private(set) var status: String?
    /// Transcripts truncate from the head — the newest words are the ones
    /// worth seeing. Messages must truncate from the tail, or the instruction
    /// loses its first half and reads as gibberish.
    @Published private(set) var statusIsTranscript = false
    @Published private(set) var isCleaning = false
    @Published private(set) var cleanFeedback: String?

    private weak var bridge: KeyboardBridge?
    private let notifier = DarwinNotifier()
    private var lastInsertedSeq = 0
    /// Clears transient status lines; replaced on every new message so an
    /// old timer can't erase a newer message early.
    private var statusExpiry: Task<Void, Never>?

    init(bridge: KeyboardBridge) {
        self.bridge = bridge
        // Start level with whatever has already been published. Finals insert
        // without checking the mic state, so a keyboard opening on top of a
        // leftover transcript file would otherwise type a previous session's
        // words into the user's next message.
        lastInsertedSeq = Relay.defaults?.integer(forKey: Relay.Key.transcriptSeq) ?? 0
        notifier.observe(Relay.Note.state) { [weak self] in
            Task { @MainActor in self?.refreshMicState() }
        }
        notifier.observe(Relay.Note.transcript) { [weak self] in
            Task { @MainActor in self?.consumeTranscript() }
        }
        refreshMicState()
    }

    // MARK: - Mic key

    func micTapped() {
        switch micState {
        case .locked:
            show("Dictation unlocks in the Ara app", for: 4)
        case .noFullAccess:
            show("Full Access off — keyboard still types", for: 4)
        case .appCold:
            // Not "open the app once": opening it is not enough. The mic key
            // needs a live heartbeat, and that only exists while the app is
            // armed, so the switch is the actual instruction.
            show("Open Ara and turn on Keep Ara ready", for: 5)
        case .ready:
            lastInsertedSeq = Relay.defaults?.integer(forKey: Relay.Key.transcriptSeq) ?? 0
            RelayClient.send(.start)
            micState = .recording
            show("Listening…", for: nil)
        case .recording:
            RelayClient.send(.stop)
            micState = .transcribing
            show("Transcribing…", for: nil)
        case .transcribing:
            break
        }
    }

    func refreshMicState() {
        // Transient utterance states are owned locally; the relay's word
        // only replaces them when it says something newer.
        let relayState = RelayClient.state()
        switch (micState, relayState) {
        case (.recording, .recording), (.transcribing, .transcribing):
            return
        case (_, .error(let message)):
            micState = baseline()
            show(message, for: 5)
        default:
            let base = baseline()
            // Only a genuine drop-out warrants the warning: the app disarming
            // or going quiet. Returning to .armed is how every *successful*
            // utterance ends, and warning on that told the user dictation had
            // failed at the exact moment it had worked.
            let droppedOut = relayState == .idle || !RelayClient.appIsLive()
            if droppedOut, micState == .recording || micState == .transcribing {
                show("Dictation stopped — check Ara", for: 4)
            }
            micState = base
            if status == nil, base == .ready {
                show("tap to dictate — stays on this phone", for: nil)
            }
        }
    }

    /// The design table's static rows, re-derived from scratch.
    private func baseline() -> MicState {
        guard StoreGate.isUnlocked else { return .locked }
        guard bridge?.hasFullAccess == true, Relay.available else { return .noFullAccess }
        guard RelayClient.appIsLive() else { return .appCold }
        switch RelayClient.state() {
        case .recording: return .recording
        case .transcribing: return .transcribing
        default: return .ready
        }
    }

    private func consumeTranscript() {
        guard let transcript = RelayTranscript.load(),
              transcript.seq > lastInsertedSeq else { return }
        if transcript.isFinal {
            // Deliberately not gated on `micState`. The app posts the
            // transcript and then the state, as two Darwin notifications whose
            // relative delivery order is not guaranteed; when the state
            // arrives first it moves the bar out of .transcribing, and a
            // state-gated insert would drop the finished utterance on the
            // floor. `seq` already makes this exactly-once.
            lastInsertedSeq = transcript.seq
            insertFinal(transcript.text)
            // Not baseline(): the relay's state key can still read
            // .transcribing until its own notification lands, and adopting
            // that makes the next state update look like a mid-utterance
            // drop-out. We know what just happened — the utterance finished.
            micState = RelayClient.appIsLive() ? .ready : .appCold
            show("tap to dictate — stays on this phone", for: nil)
        } else {
            // Partials are cosmetic, so they stay gated: showing them when we
            // are not recording would be noise.
            guard micState == .recording || micState == .transcribing else { return }
            // Live partials render in the bar only; inserting them would mean
            // a delete-storm across the proxy IPC boundary on every revision.
            show(transcript.text, for: nil, isTranscript: true)
        }
    }

    private func insertFinal(_ text: String) {
        guard let bridge, !text.isEmpty else { return }
        let before = bridge.contextBeforeInput ?? ""
        let needsSpace = !before.isEmpty
            && !(before.last?.isWhitespace ?? true)
        bridge.insert(needsSpace ? " " + text : text)
    }

    // MARK: - Clean

    var canClean: Bool {
        !(bridge?.contextBeforeInput ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    func cleanTapped() {
        guard !isCleaning else { return }
        guard StoreGate.isUnlocked else {
            show("Clean unlocks in the Ara app", for: 4)
            return
        }
        guard let bridge, let context = bridge.contextBeforeInput else {
            show("Nothing to clean", for: 2)
            return
        }
        let scope = CleanEngine.sentenceScope(of: context)
        guard !scope.trimmingCharacters(in: .whitespaces).isEmpty else {
            show("Nothing to clean", for: 2)
            return
        }
        cleanFeedback = nil
        isCleaning = true
        Task { @MainActor in
            defer { isCleaning = false }
            let cleaned = await CleanEngine.clean(
                scope, mode: EngineProvider.mode(),
                dictionary: EngineProvider.loadDictionary())
            guard let cleaned else {
                show("Nothing to clean", for: 2)
                return
            }
            // Re-read the context: the host may have changed under us while
            // the formatter ran, and a stale diff deletes the wrong text.
            guard bridge.contextBeforeInput == context else {
                show("Left as it was", for: 3)
                return
            }
            let edit = CleanEngine.suffixEdit(from: scope, to: cleaned)
            guard edit.deleteCount > 0 || !edit.insert.isEmpty else {
                show("Nothing to clean", for: 2)
                return
            }
            for _ in 0..<edit.deleteCount { bridge.deleteBackward() }
            cleanFeedback = "✓"
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                self?.cleanFeedback = nil
            }
            bridge.insert(edit.insert)
        }
    }

    // MARK: - Status line

    private func show(_ message: String?, for seconds: Double?,
                      isTranscript: Bool = false) {
        statusExpiry?.cancel()
        status = message
        statusIsTranscript = isTranscript
        guard message != nil, let seconds else { return }
        statusExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.status = nil
        }
    }
}
