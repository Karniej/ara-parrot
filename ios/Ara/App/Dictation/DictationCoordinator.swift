import Foundation
import Speech
import SwiftUI

/// The app-side brain of the relay. Owns the armed lifecycle, listens for the
/// keyboard's commands over the App Group, and publishes state, heartbeats
/// and transcripts back.
///
/// The armed model, and why it looks the way it does: iOS suspends a
/// backgrounded app the moment its audio session goes quiet — a suspended
/// app cannot hear Darwin notifications, so "start recording on demand"
/// cannot exist without a wake channel (spike experiment 5, unresolved).
/// While armed, the session therefore stays continuously active: the orange
/// mic indicator is on, iOS keeps the process alive, and the keyboard's
/// start/stop merely gates whether buffers reach the recognizer. Disarming
/// releases the mic entirely.
@MainActor
final class DictationCoordinator: ObservableObject {
    @Published private(set) var state: RelayState = .idle
    @Published private(set) var lastError: String?
    @Published private(set) var isArmed = false

    private let sink = AudioSink()
    private lazy var recorder = RecorderService(sink: sink)
    private let speech = SpeechService()
    private let notifier = DarwinNotifier()
    private var heartbeat: Timer?
    private var transcriptSeq = 0

    init() {
        Relay.defaults?.set(Date().timeIntervalSince1970,
                            forKey: Relay.Key.appLaunched)
        // A `@MainActor` class is Sendable, so `self` may cross into the
        // `@Sendable` Darwin handler; the hop back to the main actor happens
        // in the Task.
        notifier.observe(Relay.Note.command) { [weak self] in
            Task { @MainActor in self?.handlePendingCommand() }
        }
        publish(.idle)
    }

    func arm() {
        guard !isArmed else { return }
        guard Relay.available else {
            fail("App Group unavailable — reinstall Ara")
            return
        }
        do {
            try recorder.start()
        } catch {
            fail(error.localizedDescription)
            return
        }
        isArmed = true
        publish(.armed)
        startHeartbeat()
    }

    func disarm() {
        speech.cancel()
        sink.setForward(nil)
        recorder.stop()
        stopHeartbeat()
        isArmed = false
        publish(.idle)
    }

    /// Permissions are requested app-side (onboarding calls this too); the
    /// keyboard can never raise these prompts.
    func requestPermissions() async -> Bool {
        let mic = await AVAudioApplication.requestRecordPermission()
        let speechAuth = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization {
                continuation.resume(returning: $0 == .authorized)
            }
        }
        return mic && speechAuth
    }

    private func handlePendingCommand() {
        guard let command = RelayPublisher.pendingCommand() else { return }
        RelayPublisher.clearCommand()
        switch command {
        case .start: beginUtterance()
        case .stop: endUtterance()
        case .cancel: cancelUtterance()
        }
    }

    private func beginUtterance() {
        guard isArmed, state != .recording else { return }
        transcriptSeq += 1
        let seq = transcriptSeq
        let dictionary = EngineProvider.loadDictionary()
        let forward = speech.begin(
            onPartial: { [weak self] text in
                guard let self, self.transcriptSeq == seq else { return }
                RelayPublisher.publish(
                    RelayTranscript(seq: seq, text: text, isFinal: false))
            },
            onFinal: { [weak self] result in
                guard let self, self.transcriptSeq == seq else { return }
                self.sink.setForward(nil)
                switch result {
                case .success(let raw):
                    let corrected = dictionary.apply(raw)
                    RelayPublisher.publish(
                        RelayTranscript(seq: seq, text: corrected, isFinal: true))
                    self.publish(self.isArmed ? .armed : .idle)
                case .failure(let error):
                    self.fail(error.localizedDescription)
                }
            })
        guard let forward else { return }
        sink.setForward(forward)
        publish(.recording)
    }

    private func endUtterance() {
        guard state == .recording else { return }
        sink.setForward(nil)
        publish(.transcribing)
        speech.endUtterance()
    }

    private func cancelUtterance() {
        sink.setForward(nil)
        speech.cancel()
        publish(isArmed ? .armed : .idle)
    }

    private func startHeartbeat() {
        stopHeartbeat()
        let sink = self.sink
        heartbeat = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            RelayPublisher.heartbeat(frames: sink.frames)
        }
    }

    private func stopHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = nil
    }

    private func publish(_ new: RelayState) {
        state = new
        RelayPublisher.publish(new)
    }

    private func fail(_ message: String) {
        lastError = message
        publish(.error(message))
    }
}

/// Process-wide singletons the SwiftUI tree hangs off. A struct of lets, not
/// a DI framework — three services do not need one.
///
/// The store lives here, not only behind the paywall screen: its init
/// re-derives the entitlement and rewrites the App Group mirror, and that
/// must happen on every app launch — a refund or family-sharing change the
/// keyboard should notice cannot wait for the user to open Settings.
@MainActor
final class AppServices {
    static let shared = AppServices()
    let dictation = DictationCoordinator()
    let store = StoreService()
    private init() {}
}
