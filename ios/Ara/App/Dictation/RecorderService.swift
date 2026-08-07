import AVFoundation
import Foundation

/// Owns the audio session and the engine tap. This is the "ears" half of the
/// container relay: while running, the app records — in the foreground or
/// background (`UIBackgroundModes: audio`) — and forwards every buffer to a
/// sink. The spike measured this sustaining a gapless 48 kHz with the app
/// backgrounded; keeping the session *continuously* active while armed is
/// what keeps iOS from suspending the process, which is why arming shows the
/// orange mic indicator the whole time. That is presented as a feature.
@MainActor
final class RecorderService {
    /// Receives buffers on the realtime capture thread. Must be cheap and
    /// allocation-free on the hot path.
    private let sink: AudioSink
    private var engine: AVAudioEngine?
    private var restartOnInterruptionEnd = false
    private var observers: [NSObjectProtocol] = []

    var isRunning: Bool { engine != nil }
    var framesCaptured: Int { sink.frames }

    init(sink: AudioSink) {
        self.sink = sink
    }

    /// Throws with a user-presentable message; the coordinator publishes it
    /// as `RelayState.error` so the *keyboard* can show it too.
    func start() throws {
        guard engine == nil else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.allowBluetooth])
        try session.setActive(true)
        let engine = AVAudioEngine()
        let format = engine.inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw RecorderError.zeroRateInput
        }
        let sink = self.sink
        // `@Sendable`, load-bearing: a closure literal formed inside a
        // `@MainActor` method inherits main-actor isolation, and the tap
        // fires on the realtime capture thread — the runtime kills the app
        // with dispatch_assert_queue. The spike crashed exactly this way.
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048,
                                    format: format) { @Sendable buffer, _ in
            sink.consume(buffer)
        }
        try engine.start()
        self.engine = engine
        installObservers()
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        removeObservers()
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Phone calls, Siri, other apps taking the mic: stop cleanly, then
    /// re-arm when the interruption ends. Without this, one phone call
    /// silently kills dictation until the user finds the toggle.
    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleInterruption(note) }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil,
            queue: .main
        ) { [weak self] _ in
            // Route changes (headphones in/out) can leave the engine wedged
            // on the old input format; a restart is cheap and always correct.
            MainActor.assumeIsolated { self?.restart() }
        })
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            restartOnInterruptionEnd = isRunning
            stop()
        case .ended:
            if restartOnInterruptionEnd {
                restartOnInterruptionEnd = false
                try? start()
            }
        @unknown default:
            break
        }
    }

    private func restart() {
        guard isRunning else { return }
        stop()
        try? start()
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }
}

enum RecorderError: LocalizedError {
    case zeroRateInput

    var errorDescription: String? {
        "microphone reported no input — try again"
    }
}

/// The realtime-safe buffer consumer. `@unchecked Sendable` because the tap
/// thread and the main actor both touch it; the lock makes the frame count
/// safe and `SpeechService` documents why forwarding the buffer is.
final class AudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var forward: (@Sendable (AVAudioPCMBuffer) -> Void)?

    var frames: Int { lock.withLock { count } }

    func consume(_ buffer: AVAudioPCMBuffer) {
        let handler = lock.withLock { () -> (@Sendable (AVAudioPCMBuffer) -> Void)? in
            count += Int(buffer.frameLength)
            return forward
        }
        handler?(buffer)
    }

    /// Set from the main actor between utterances, read on the tap thread.
    /// The tiny race on switchover is harmless: a buffer more or less at an
    /// utterance boundary is inaudible to recognition.
    func setForward(_ handler: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        lock.withLock { forward = handler }
    }
}
