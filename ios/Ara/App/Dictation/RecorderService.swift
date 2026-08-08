import AVFoundation
import Foundation

/// Owns the audio session and the engine tap. This is the "ears" half of the
/// container relay: while running, the app records — in the foreground or
/// background (`UIBackgroundModes: audio`) — and forwards every buffer to a
/// sink. The spike measured this sustaining a gapless 48 kHz with the app
/// backgrounded; keeping the session *continuously* active while armed is
/// what keeps iOS from suspending the process, which is why arming shows the
/// orange mic indicator the whole time. That is presented as a feature.
///
/// Deliberately *not* main-actor isolated. `setActive(true)`, `inputFormat`
/// and `engine.start()` each block the calling thread while the audio HAL
/// configures — together, seconds on a cold session, and longer when another
/// app is giving the microphone up. Run from the main actor that is a frozen
/// UI, which is exactly how it felt. Every audio call is serialized onto one
/// private queue instead, and callers await the result.
final class RecorderService: @unchecked Sendable {
    /// Receives buffers on the realtime capture thread. Must be cheap and
    /// allocation-free on the hot path.
    private let sink: AudioSink
    /// The single thread every AVAudioSession/AVAudioEngine call runs on.
    /// Serial, so start/stop/restart can never interleave.
    private let queue = DispatchQueue(label: "com.silpho.ara.recorder",
                                      qos: .userInitiated)
    /// All of these are touched only on `queue`.
    private var engine: AVAudioEngine?
    private var restartOnInterruptionEnd = false
    private var observers: [NSObjectProtocol] = []

    var framesCaptured: Int { sink.frames }

    init(sink: AudioSink) {
        self.sink = sink
    }

    /// Throws with a user-presentable message; the coordinator publishes it
    /// as `RelayState.error` so the *keyboard* can show it too.
    func start() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.startOnQueue()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.stopOnQueue()
                continuation.resume()
            }
        }
    }

    // MARK: - On the recorder queue

    private func startOnQueue() throws {
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
        // `@Sendable`, load-bearing: the tap fires on the realtime capture
        // thread, and a closure literal that inherits any actor's isolation
        // gets the process killed by dispatch_assert_queue. The spike crashed
        // exactly this way.
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048,
                                    format: format) { @Sendable buffer, _ in
            sink.consume(buffer)
        }
        try engine.start()
        self.engine = engine
        installObserversOnQueue()
    }

    private func stopOnQueue() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        removeObserversOnQueue()
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Phone calls, Siri, other apps taking the mic: stop cleanly, then
    /// re-arm when the interruption ends. Without this, one phone call
    /// silently kills dictation until the user finds the toggle.
    private func installObserversOnQueue() {
        let center = NotificationCenter.default
        // `queue: nil` delivers on the posting thread; the handler hops to the
        // recorder queue itself. Handing NotificationCenter our serial queue
        // is not an option — it takes an OperationQueue, not a DispatchQueue.
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil,
            queue: nil
        ) { [weak self] note in
            // Extract the one Sendable value before the hop — the Notification
            // itself cannot cross a concurrency boundary under Swift 6.
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            // Resolve the weak reference once, before the hop: reading `self?`
            // again inside the escaping block is a second, racing load.
            guard let self else { return }
            self.queue.async { self.handleInterruptionOnQueue(rawType: raw) }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil,
            queue: nil
        ) { [weak self] _ in
            // Route changes (headphones in/out) can leave the engine wedged
            // on the old input format; a restart is cheap and always correct.
            guard let self else { return }
            self.queue.async { self.restartOnQueue() }
        })
    }

    private func handleInterruptionOnQueue(rawType: UInt?) {
        guard let raw = rawType,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            restartOnInterruptionEnd = engine != nil
            stopOnQueue()
        case .ended:
            if restartOnInterruptionEnd {
                restartOnInterruptionEnd = false
                try? startOnQueue()
            }
        @unknown default:
            break
        }
    }

    private func restartOnQueue() {
        guard engine != nil else { return }
        stopOnQueue()
        try? startOnQueue()
    }

    private func removeObserversOnQueue() {
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
