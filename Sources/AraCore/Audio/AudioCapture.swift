import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Captures microphone audio while recording is active and returns a 16 kHz
/// mono Float32 buffer when stopped. Format-converts on the fly so callers
/// don't have to worry about the input device's native rate.
///
/// ## No audio path may kill the daemon
///
/// `installTap` raises an ObjC exception Swift cannot catch when handed the
/// format a dead device reports — zero channels, zero sample rate. Every path
/// into AVFoundation therefore validates the probed format first, making the
/// exception unreachable; every failure is a thrown `CaptureError` instead.
///
/// ## Device routing is per-engine
///
/// `deviceProvider` supplies the input device (Task 2 wires it to
/// `MicrophoneStore`); routing sets the input unit's current-device property
/// on *this* engine and never touches the system default input.
///
/// ## Mid-recording device loss
///
/// A device that dies mid-recording fires the engine's configuration-change
/// notification. The handler tears the engine down, re-resolves through
/// `deviceProvider`, and resumes capturing into the *same* samples buffer; if
/// nothing usable remains it degrades to a state where `stop()` still returns
/// everything captured so far. Captured audio is never lost.
///
/// Degraded is not terminal: the engine's notification can race the device
/// store's own listener, so the rebuild may have read a stale provider while
/// a healthy fallback was milliseconds from being resolved. The store's
/// change signal calls `retryIfDegraded()`, which re-runs the same start path
/// into the same buffer — recovery is event-driven, no polling. Engine
/// notifications while degraded stay a no-op; only the store signal retries.
///
/// ## The seam
///
/// Everything the class does to AVFoundation goes through a `Backend` — a
/// struct of function values built by an injected factory, one backend per
/// engine lifetime. Tests substitute recording fakes and drive the production
/// `start`/`stop`/`handleConfigurationChange` bodies; the public initializer
/// wires the real `AVAudioEngine`.
public final class AudioCapture {
    enum CaptureError: Error {
        case engineStartFailed(Error)
        case converterCreationFailed
        /// The input device's format cannot carry audio — the state a dead or
        /// missing device reports, and the one `installTap` would crash on.
        case invalidInputFormat(channels: UInt32, sampleRate: Double)
        /// Setting the input unit's current device failed.
        case deviceRoutingFailed(OSStatus)
    }

    public static let targetSampleRate: Double = 16_000

    /// One engine's lifetime of AVFoundation operations, as function values.
    /// A rebuild discards the whole struct and makes a fresh one, so closures
    /// may (and in production do) close over a single `AVAudioEngine`.
    struct Backend {
        let inputFormat: () -> AVAudioFormat
        let setInputDevice: (AudioDeviceID) throws -> Void
        let installTap: (AVAudioFormat, @escaping (AVAudioPCMBuffer) -> Void) -> Void
        let removeTap: () -> Void
        let startEngine: () throws -> Void
        let stopEngine: () -> Void
        /// Whether the engine is currently running. The rebuild path uses
        /// this to tell a genuine device death (engine stopped) from the
        /// configuration-change notification a routed engine posts about its
        /// OWN start: measured, routing the input unit makes every engine
        /// start post one, and rebuilding on it tears the healthy engine
        /// down before its first buffer — a storm of ~200 ms engines that
        /// captures nothing.
        let isEngineRunning: () -> Bool
        /// Releases everything registered at build time (the configuration-
        /// change observer). Must be safe to call whether or not the engine
        /// ever started.
        let tearDown: () -> Void
    }

    /// The factory's argument is what a configuration-change notification
    /// invokes; the returned backend owns the registration.
    typealias MakeBackend = (@escaping () -> Void) -> Backend

    private enum State {
        case idle
        case recording
        /// Recording continued past the death of every usable device: the tap
        /// is gone but the samples are kept for `stop()`.
        case degraded
    }

    private let makeBackend: MakeBackend
    private var backend: Backend?
    private var state: State = .idle
    /// Bumped (under `stateLock`) every time a backend is built. Each
    /// backend's notification closure carries the generation it was built
    /// under, so a notification enqueued by an engine that has since been
    /// torn down — `stop()` then a fresh `start()` can both happen before the
    /// hop runs — identifies itself as stale and is ignored instead of
    /// rebuilding a healthy new engine.
    private var generation: UInt64 = 0
    private var samples: [Float] = []
    private let lock = NSLock()

    /// Guards `state`/`backend`. Separate from `lock` (the samples lock) so
    /// the audio tap, which only ever takes `lock`, can never contend with —
    /// or deadlock against — a control operation. Control operations never
    /// run on the audio thread.
    private let stateLock = NSLock()

    /// The rebuild hop. The configuration-change notification is delivered
    /// synchronously on whatever thread posts it — possibly one the teardown
    /// itself needs — so the handler always bounces through this queue rather
    /// than re-entering `stateLock`.
    private let rebuildQueue = DispatchQueue(label: "ara.audio-capture.rebuild")

    /// Supplies the device to record from; consulted at `start` and again on
    /// every mid-recording rebuild. `nil` (or no provider) leaves the engine
    /// on the system default input. Task 2 wires this to
    /// `MicrophoneStore.effective`. Set before the first `start`.
    public var deviceProvider: (() -> AudioDeviceID?)?

    /// Called for every audio buffer with the buffer's RMS level (0…~1).
    /// Invoked on an arbitrary thread; hop to main if you touch UI.
    public var onLevel: ((Float) -> Void)?

    /// The mid-utterance transitions the UI must reflect: `.degraded` when a
    /// loss leaves nothing to record from — the overlay and menu must stop
    /// claiming "recording" — and `.resumed` when a later device change
    /// brings recording back. Healthy rebuilds are silent (the user never
    /// noticed anything), and so are failed retries. Invoked on an arbitrary
    /// thread; hop to main if you touch UI.
    public enum Transition: Equatable, Sendable {
        case degraded
        case resumed
    }
    public var onTransition: ((Transition) -> Void)?

    public init() {
        self.makeBackend = AudioCapture.liveBackend
    }

    init(makeBackend: @escaping MakeBackend) {
        self.makeBackend = makeBackend
    }

    deinit {
        backend?.tearDown()
    }

    /// Begin recording. Idempotent — calling while already recording is a no-op.
    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard state == .idle else { return }

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        let backend = newBackend()
        do {
            try startRecording(on: backend, device: deviceProvider?())
        } catch {
            backend.tearDown()
            throw error
        }
        self.backend = backend
        state = .recording
    }

    /// Stop recording and return all captured samples (16 kHz mono Float32).
    /// Returns whatever was captured even when the device died mid-recording.
    @discardableResult
    public func stop() -> [Float] {
        stateLock.lock()
        guard state != .idle else {
            stateLock.unlock()
            return []
        }
        if let backend {
            // Observer first: a stopping engine may post a configuration
            // change, and a rebuild triggered by our own teardown would
            // resurrect the recording `stop` is ending.
            backend.tearDown()
            backend.removeTap()
            backend.stopEngine()
        }
        backend = nil
        state = .idle
        stateLock.unlock()

        lock.lock()
        let captured = samples
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        return captured
    }

    // MARK: - Mid-recording rebuild

    /// The rebuild decision, runnable without hardware: tear down the dead
    /// engine, re-resolve through `deviceProvider`, and resume into the same
    /// samples buffer — or degrade, keeping what was captured, when nothing
    /// usable remains. Production reaches this via `rebuildQueue` from the
    /// engine's configuration-change notification; tests call it directly.
    ///
    /// `generation` is the token the notifying backend was built under; `nil`
    /// (the direct-call form) means "the current backend". A mismatch means
    /// the notification outlived its engine and must not touch whatever is
    /// recording now.
    func handleConfigurationChange(generation: UInt64? = nil) {
        stateLock.lock()
        guard state == .recording, let old = backend,
              generation == nil || generation == self.generation
        else {
            stateLock.unlock()
            return
        }

        // A routed engine posts a configuration change about its own start
        // (see Backend.isEngineRunning). If the engine is still running, the
        // device did not die — audio is flowing and a rebuild would kill it.
        // A genuine device loss stops the engine first; only then rebuild.
        if old.isEngineRunning() {
            stateLock.unlock()
            return
        }

        old.tearDown()
        old.removeTap()
        old.stopEngine()
        backend = nil

        let fresh = newBackend()
        var lost = false
        do {
            try startRecording(on: fresh, device: deviceProvider?())
            backend = fresh
            // state stays .recording; the tap appends to the same buffer.
        } catch {
            fresh.tearDown()
            state = .degraded
            lost = true
        }
        // The callback runs outside the lock: it is client code and may call
        // back into a control operation (`stop`, another retry).
        stateLock.unlock()
        if lost { onTransition?(.degraded) }
    }

    // MARK: - Recovery from degraded

    /// The device world changed — re-attempt recording iff a mid-utterance
    /// loss degraded the capture. Wired to the device store's change signal,
    /// which fires only on real changes, so this is event-driven with no
    /// polling and no loop: a failed retry leaves the capture degraded,
    /// silently, and the *next* store change is the next retry.
    ///
    /// On success recording resumes into the same samples buffer — nothing
    /// captured before the loss is dropped. A no-op while idle or recording.
    /// Safe to call from any thread.
    public func retryIfDegraded() {
        rebuildQueue.async { self.handleRetryIfDegraded() }
    }

    /// The retry decision, runnable without hardware; production reaches it
    /// via `rebuildQueue`, tests call it directly (the same split as
    /// `handleConfigurationChange`).
    func handleRetryIfDegraded() {
        stateLock.lock()
        guard state == .degraded else {
            stateLock.unlock()
            return
        }

        var resumed = false
        let fresh = newBackend()
        do {
            try startRecording(on: fresh, device: deviceProvider?())
            backend = fresh
            state = .recording
            resumed = true
        } catch {
            fresh.tearDown()
            // Still degraded; the next store change retries.
        }
        // Outside the lock, same reason as in `handleConfigurationChange`.
        stateLock.unlock()
        if resumed { onTransition?(.resumed) }
    }

    // MARK: - Shared start path

    /// Callers hold `stateLock` (every path that builds a backend is a
    /// control operation), which is what makes the `generation` bump safe.
    private func newBackend() -> Backend {
        generation &+= 1
        let gen = generation
        return makeBackend { [weak self] in
            guard let self else { return }
            self.rebuildQueue.async { self.handleConfigurationChange(generation: gen) }
        }
    }

    /// Routes, validates, converts, taps, starts — in that order. Routing
    /// first because it changes what the probe sees; validation before the
    /// tap because that is the crash fix.
    private func startRecording(on backend: Backend, device: AudioDeviceID?) throws {
        if let device {
            try backend.setInputDevice(device)
        }

        let inputFormat = backend.inputFormat()
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw CaptureError.invalidInputFormat(
                channels: inputFormat.channelCount, sampleRate: inputFormat.sampleRate)
        }

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioCapture.targetSampleRate,
            channels: 1,
            interleaved: false
        )!
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.converterCreationFailed
        }

        // Tap with input format; convert inside the callback. The converter is
        // per-backend: a rebuild makes a new one for the new device's native
        // format.
        backend.installTap(inputFormat) { [weak self] buffer in
            self?.process(buffer: buffer, converter: converter, targetFormat: targetFormat)
        }
        do {
            try backend.startEngine()
        } catch {
            backend.removeTap()
            throw CaptureError.engineStartFailed(error)
        }
    }

    // MARK: - The real engine

    private static func liveBackend(onConfigurationChange: @escaping () -> Void) -> Backend {
        let engine = AVAudioEngine()
        // Registered per engine (`object: engine`), so a notification can only
        // ever describe this backend's device. Delivery is synchronous on the
        // posting thread (`queue: nil`); the capture's wiring hops queues.
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in onConfigurationChange() }

        return Backend(
            // `inputFormat(forBus:)`, not `outputFormat(forBus:)`: after
            // routing, the output side still reports the format cached when
            // the node was created (measured: cached 44.1 kHz vs routed
            // 48 kHz device). A tap installed with that stale format never
            // fires — the engine runs and zero buffers arrive. The input
            // side reports the routed hardware's true format. Pinned by
            // AudioCaptureHardwareTests (opt-in, ARA_AUDIO_HW=1).
            inputFormat: { engine.inputNode.inputFormat(forBus: 0) },
            setInputDevice: { deviceID in
                // Per-engine routing via the input unit's current-device
                // property; the system default input is never written.
                guard let unit = engine.inputNode.audioUnit else {
                    throw CaptureError.deviceRoutingFailed(kAudio_ParamError)
                }
                var id = deviceID
                let status = AudioUnitSetProperty(
                    unit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &id,
                    UInt32(MemoryLayout<AudioDeviceID>.size))
                guard status == noErr else {
                    throw CaptureError.deviceRoutingFailed(status)
                }
            },
            installTap: { format, handler in
                engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) {
                    buffer, _ in handler(buffer)
                }
            },
            removeTap: { engine.inputNode.removeTap(onBus: 0) },
            startEngine: {
                engine.prepare()
                try engine.start()
            },
            stopEngine: { engine.stop() },
            isEngineRunning: { engine.isRunning },
            tearDown: { NotificationCenter.default.removeObserver(observer) })
    }

    private func process(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        // Output buffer capacity scales with sample-rate ratio.
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64

        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outCapacity
        ) else { return }

        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
        guard status != .error, let channelData = outBuffer.floatChannelData else { return }

        let count = Int(outBuffer.frameLength)
        let ptr = channelData[0]
        let chunk = Array(UnsafeBufferPointer(start: ptr, count: count))

        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()

        if let onLevel {
            onLevel(computeRMS(chunk))
        }
    }
}

// MARK: - WAV writer (for debugging M3 captures)

public enum WAVWriter {
    /// Write Float32 mono samples as 16-bit PCM WAV to `path`.
    public static func write(samples: [Float], sampleRate: Int, to path: String) throws {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(uint32LE(36 + UInt32(dataSize)))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(uint32LE(16))                       // fmt chunk size
        data.append(uint16LE(1))                        // PCM
        data.append(uint16LE(1))                        // mono
        data.append(uint32LE(UInt32(sampleRate)))
        data.append(uint32LE(UInt32(sampleRate * bytesPerSample)))
        data.append(uint16LE(UInt16(bytesPerSample)))   // block align
        data.append(uint16LE(16))                       // bits per sample
        data.append(contentsOf: Array("data".utf8))
        data.append(uint32LE(UInt32(dataSize)))

        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            let i = Int16(clamped * 32767.0)
            data.append(uint16LE(UInt16(bitPattern: i)))
        }

        try data.write(to: URL(fileURLWithPath: path))
    }

    private static func uint32LE(_ v: UInt32) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 4)
    }
    private static func uint16LE(_ v: UInt16) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 2)
    }
}

public func computeRMS(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var sum: Double = 0
    for s in samples { sum += Double(s * s) }
    return Float((sum / Double(samples.count)).squareRoot())
}
