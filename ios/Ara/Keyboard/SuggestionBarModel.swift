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

    private weak var bridge: KeyboardBridge?
    private let notifier = DarwinNotifier()
    private var lastInsertedSeq = 0
    /// Clears transient status lines; replaced on every new message so an
    /// old timer can't erase a newer message early.
    private var statusExpiry: Task<Void, Never>?

    init(bridge: KeyboardBridge) {
        self.bridge = bridge
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
            show("Unlock Ara's mic in the app", for: 4)
        case .noFullAccess:
            show("Allow Full Access in Settings", for: 4)
        case .appCold:
            // Not "open the app once": opening it is not enough. The mic key
            // needs a live heartbeat, and that only exists while the app is
            // armed, so the switch is the actual instruction.
            show("Turn on “Ready to dictate” in Ara", for: 5)
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
            if micState != base, micState == .recording || micState == .transcribing {
                // The app dropped out mid-utterance (disarmed, suspended).
                show("Dictation stopped — check Ara", for: 4)
            }
            micState = base
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
        guard micState == .recording || micState == .transcribing,
              let transcript = RelayTranscript.load(),
              transcript.seq > lastInsertedSeq else { return }
        if transcript.isFinal {
            lastInsertedSeq = transcript.seq
            insertFinal(transcript.text)
            micState = baseline()
            show(nil, for: nil)
        } else {
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
            show("Unlock Clean in the Ara app", for: 4)
            return
        }
        guard let bridge, let context = bridge.contextBeforeInput else { return }
        let scope = CleanEngine.sentenceScope(of: context)
        guard !scope.trimmingCharacters(in: .whitespaces).isEmpty else { return }
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
                show("Text changed — try again", for: 3)
                return
            }
            let edit = CleanEngine.suffixEdit(from: scope, to: cleaned)
            guard edit.deleteCount > 0 || !edit.insert.isEmpty else {
                show("Already clean", for: 2)
                return
            }
            for _ in 0..<edit.deleteCount { bridge.deleteBackward() }
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
