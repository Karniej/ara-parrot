import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import AraCore

@Suite("AudioCapture")
struct AudioCaptureTests {
    // MARK: - Fakes

    /// One fake engine. The formats are real `AVAudioFormat`s and the buffers
    /// real `AVAudioPCMBuffer`s, so the production converter path runs for
    /// real; only the AVFoundation *engine* calls are recorded instead of
    /// executed.
    private final class FakeEngine {
        let format: AVAudioFormat
        var routed: [AudioDeviceID] = []
        var routingError: Error?
        var startError: Error?
        var tapHandler: ((AVAudioPCMBuffer) -> Void)?
        var tapInstalledWith: AVAudioFormat?
        var tapRemoved = false
        var started = false
        var engineStopped = false
        var toreDown = false
        /// Models the hardware: a genuine device loss stops the engine
        /// underneath us without `stopEngine` being called. Tests that
        /// simulate a death set this before firing the notification —
        /// mirroring the real discriminator, since a routed engine posts a
        /// configuration change about its own (healthy) start too.
        var deviceDied = false
        var order: [String] = []
        var onConfigurationChange: (() -> Void)?

        init(format: AVAudioFormat) { self.format = format }

        func backend() -> AudioCapture.Backend {
            AudioCapture.Backend(
                inputFormat: { self.order.append("probe"); return self.format },
                setInputDevice: { id in
                    self.order.append("route")
                    if let error = self.routingError { throw error }
                    self.routed.append(id)
                },
                installTap: { format, handler in
                    self.order.append("tap")
                    self.tapInstalledWith = format
                    self.tapHandler = handler
                },
                removeTap: { self.tapRemoved = true },
                startEngine: {
                    self.order.append("start")
                    if let error = self.startError { throw error }
                    self.started = true
                },
                stopEngine: { self.engineStopped = true },
                isEngineRunning: { self.started && !self.engineStopped && !self.deviceDied },
                tearDown: { self.toreDown = true })
        }
    }

    /// A backend owner whose deallocation is observable. Unlike `Harness`,
    /// the lifetime regression below deliberately keeps no strong array of
    /// these: the production backend closures and the notification
    /// registration/invocation are its only owners.
    private final class LifetimeEngine {
        let format: AVAudioFormat
        let onTearDown: () -> Void
        let onDeinit: () -> Void

        init(
            format: AVAudioFormat,
            onTearDown: @escaping () -> Void = {},
            onDeinit: @escaping () -> Void = {}
        ) {
            self.format = format
            self.onTearDown = onTearDown
            self.onDeinit = onDeinit
        }

        deinit { onDeinit() }

        func backend(isRunning: Bool) -> AudioCapture.Backend {
            AudioCapture.Backend(
                inputFormat: { self.format },
                setInputDevice: { _ in },
                installTap: { _, _ in },
                removeTap: {},
                startEngine: {},
                stopEngine: {},
                isEngineRunning: { isRunning },
                tearDown: { self.onTearDown() })
        }
    }

    private final class WeakBox<Value: AnyObject> {
        weak var value: Value?
    }

    /// A thread-safe stand-in for NotificationCenter's observer registration.
    /// `fire` retains the callback for the duration of an invocation even when
    /// `clear` concurrently removes the registered copy.
    private final class NotificationSlot {
        private let lock = NSLock()
        private var callback: (() -> Void)?

        func install(_ callback: @escaping () -> Void) {
            lock.lock()
            self.callback = callback
            lock.unlock()
        }

        func clear() {
            lock.lock()
            callback = nil
            lock.unlock()
        }

        func fire() {
            lock.lock()
            let callback = callback
            lock.unlock()
            callback?()
        }
    }

    /// Hands `AudioCapture` a fresh fake engine per (re)build and records how
    /// many were built — the rebuild tests hinge on which engine is live.
    private final class Harness {
        let engines: [FakeEngine]
        private(set) var built = 0

        init(_ engines: [FakeEngine]) { self.engines = engines }

        func capture() -> AudioCapture {
            AudioCapture(makeBackend: { onConfigurationChange in
                let engine = self.engines[self.built]
                self.built += 1
                engine.onConfigurationChange = onConfigurationChange
                return engine.backend()
            })
        }
    }

    /// What a live `AVAudioEngine` reports for a healthy 48 kHz microphone.
    private static var live48kMono: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    }

    /// What a live engine reports when its device is gone: zero channels,
    /// zero sample rate. Constructible without hardware — verified: the
    /// standard-format initializer accepts zeros and returns a real object.
    private static var dead: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 0, channels: 0)!
    }

    /// Pushes `frames` frames of a constant signal through the installed tap,
    /// exactly as the audio thread would.
    private func feed(_ engine: FakeEngine, frames: AVAudioFrameCount, value: Float = 0.25) {
        let format = engine.tapInstalledWith!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            let ptr = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) { ptr[i] = value }
        }
        engine.tapHandler?(buffer)
    }

    // MARK: - The crash fix: validation precedes AVFoundation

    /// The guard this proves is the crash fix: `installTap` raises an
    /// uncatchable ObjC exception on a 0-channel/0 Hz format. A mutation that
    /// deletes the guard reaches `installTap` and fails the second half of
    /// this test.
    @Test("a dead input format is refused before the tap is touched")
    func deadFormatRefused() {
        let engine = FakeEngine(format: Self.dead)
        let capture = Harness([engine]).capture()
        do {
            try capture.start()
            Issue.record("start() should have thrown for a 0-channel/0 Hz format")
        } catch AudioCapture.CaptureError.invalidInputFormat {
        } catch {
            Issue.record("wrong error: \(error)")
        }
        #expect(engine.tapInstalledWith == nil)
        #expect(!engine.started)
        #expect(engine.toreDown)  // the failed backend is not leaked
    }

    @Test("zero sample rate alone is refused")
    func zeroRateRefused() {
        let engine = FakeEngine(format: AVAudioFormat(standardFormatWithSampleRate: 0, channels: 1)!)
        let capture = Harness([engine]).capture()
        #expect(throws: AudioCapture.CaptureError.self) { try capture.start() }
        #expect(engine.tapInstalledWith == nil)
    }

    @Test("zero channels alone is refused")
    func zeroChannelsRefused() {
        let engine = FakeEngine(format: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 0)!)
        let capture = Harness([engine]).capture()
        #expect(throws: AudioCapture.CaptureError.self) { try capture.start() }
        #expect(engine.tapInstalledWith == nil)
    }

    // MARK: - Routing

    @Test("the provider's device is routed before the format is probed")
    func routesProviderDevice() throws {
        let engine = FakeEngine(format: Self.live48kMono)
        let capture = Harness([engine]).capture()
        capture.deviceProvider = { 42 }
        try capture.start()
        #expect(engine.routed == [42])
        // Routing must precede probing: the route changes what the probe sees.
        #expect(engine.order == ["route", "probe", "tap", "start"])
    }

    @Test("no provider leaves the engine's default routing untouched")
    func noProviderNoRouting() throws {
        let engine = FakeEngine(format: Self.live48kMono)
        let capture = Harness([engine]).capture()
        try capture.start()
        #expect(engine.routed.isEmpty)
        #expect(engine.order == ["probe", "tap", "start"])
    }

    @Test("a routing failure throws instead of crashing, and cleans up")
    func routingFailureThrows() {
        let engine = FakeEngine(format: Self.live48kMono)
        engine.routingError = AudioCapture.CaptureError.deviceRoutingFailed(-1)
        let capture = Harness([engine]).capture()
        capture.deviceProvider = { 42 }
        #expect(throws: AudioCapture.CaptureError.self) { try capture.start() }
        #expect(engine.tapInstalledWith == nil)
        #expect(!engine.started)
        #expect(engine.toreDown)
    }

    // MARK: - Capture

    @Test("captured audio is converted to 16 kHz and returned by stop")
    func captureRoundTrip() throws {
        let engine = FakeEngine(format: Self.live48kMono)
        let capture = Harness([engine]).capture()
        try capture.start()
        // 100 ms at 48 kHz. Nominally 1600 samples at 16 kHz; the resampler's
        // priming latency deterministically holds back ~240, yielding 1360.
        feed(engine, frames: 4800)
        let samples = capture.stop()
        #expect(samples.count > 1200 && samples.count < 1700)
        #expect(engine.tapRemoved)
        #expect(engine.engineStopped)
        #expect(engine.toreDown)
    }

    @Test("each recording starts from an empty buffer")
    func freshBufferPerRecording() throws {
        let first = FakeEngine(format: Self.live48kMono)
        let second = FakeEngine(format: Self.live48kMono)
        let capture = Harness([first, second]).capture()
        try capture.start()
        feed(first, frames: 4800)
        _ = capture.stop()
        try capture.start()
        feed(second, frames: 2400)  // 50 ms → ~800 samples minus priming
        let samples = capture.stop()
        #expect(samples.count > 500 && samples.count < 900)
    }

    @Test("stop while idle returns nothing")
    func stopWhileIdle() {
        let capture = Harness([]).capture()
        #expect(capture.stop().isEmpty)
    }

    // MARK: - Mid-recording device loss

    @Test("a configuration change rebuilds on the re-resolved device and keeps the samples")
    func rebuildKeepsSamples() throws {
        let first = FakeEngine(format: Self.live48kMono)
        // The replacement device runs at a different native format; the
        // converter must be rebuilt for it, not reused.
        let second = FakeEngine(format: AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 2)!)
        let harness = Harness([first, second])
        let capture = harness.capture()
        nonisolated(unsafe) var device: AudioDeviceID = 42
        capture.deviceProvider = { device }
        try capture.start()
        feed(first, frames: 4800)  // ~1600 samples

        device = 77  // the store re-resolved to a different device
        first.deviceDied = true
        capture.handleConfigurationChange()

        #expect(first.tapRemoved)
        #expect(first.engineStopped)
        #expect(first.toreDown)
        #expect(second.routed == [77])
        #expect(second.started)

        feed(second, frames: 2400)  // 100 ms at 24 kHz → ~1600 samples
        let samples = capture.stop()
        #expect(samples.count > 2700 && samples.count < 3600)  // both halves
    }

    @Test("losing every device degrades gracefully; stop still returns the samples")
    func rebuildWithNoDeviceDegrades() throws {
        let first = FakeEngine(format: Self.live48kMono)
        let second = FakeEngine(format: Self.dead)
        let capture = Harness([first, second]).capture()
        try capture.start()
        feed(first, frames: 4800)

        first.deviceDied = true
        capture.handleConfigurationChange()

        #expect(!second.started)
        #expect(second.toreDown)  // the failed rebuild is not leaked

        let samples = capture.stop()
        #expect(samples.count > 1200 && samples.count < 1700)
    }

    @Test("a failed rebuild leaves the capture restartable")
    func degradedThenRestart() throws {
        let first = FakeEngine(format: Self.live48kMono)
        let second = FakeEngine(format: Self.dead)
        let third = FakeEngine(format: Self.live48kMono)
        let capture = Harness([first, second, third]).capture()
        try capture.start()
        feed(first, frames: 4800)
        first.deviceDied = true
        capture.handleConfigurationChange()
        _ = capture.stop()

        try capture.start()
        feed(third, frames: 2400)
        #expect(capture.stop().count > 500)
    }

    @Test("a configuration change while idle does nothing")
    func configChangeWhileIdle() {
        let harness = Harness([FakeEngine(format: Self.live48kMono)])
        let capture = harness.capture()
        capture.handleConfigurationChange()
        #expect(harness.built == 0)
    }

    @Test("a second configuration change after degrading does not rebuild again")
    func configChangeWhileDegraded() throws {
        let first = FakeEngine(format: Self.live48kMono)
        let second = FakeEngine(format: Self.dead)
        let harness = Harness([first, second])
        let capture = harness.capture()
        try capture.start()
        first.deviceDied = true
        capture.handleConfigurationChange()
        #expect(harness.built == 2)
        capture.handleConfigurationChange()
        #expect(harness.built == 2)  // degraded: no further engines
    }

    // MARK: - Recovery from degraded

    /// The race this pins: the engine's configuration-change and the store's
    /// Core Audio listener have no ordering guarantee, so the rebuild can read
    /// the store while it still names the dead device and degrade — even
    /// though the store resolves a healthy fallback milliseconds later. The
    /// store's change signal is the second chance.
    @Test("a retry after degrading resumes recording into the same buffer")
    func retryAfterDegradeResumes() throws {
        let first = FakeEngine(format: Self.live48kMono)
        let second = FakeEngine(format: Self.dead)  // rebuild raced the store: still the dead device
        let third = FakeEngine(format: Self.live48kMono)  // the store has since re-resolved
        let harness = Harness([first, second, third])
        let capture = harness.capture()
        nonisolated(unsafe) var device: AudioDeviceID? = 42
        capture.deviceProvider = { device }
        try capture.start()
        feed(first, frames: 4800)  // ~1360 samples at 16 kHz

        first.deviceDied = true
        capture.handleConfigurationChange()  // dead probe → degraded
        #expect(!second.started)

        device = 77  // the healthy fallback the store now resolves
        capture.handleRetryIfDegraded()

        #expect(third.routed == [77])
        #expect(third.order == ["route", "probe", "tap", "start"])
        #expect(third.started)

        feed(third, frames: 2400)  // ~560 more
        let samples = capture.stop()
        // Both halves: either alone stays under 1800 (~1360 / ~560).
        #expect(samples.count > 1800 && samples.count < 2600)
    }

    @Test("a retry with no usable device stays degraded and keeps the samples")
    func retryWithoutDeviceStaysDegraded() throws {
        let first = FakeEngine(format: Self.live48kMono)
        let second = FakeEngine(format: Self.dead)
        let third = FakeEngine(format: Self.dead)
        let harness = Harness([first, second, third])
        let capture = harness.capture()
        try capture.start()
        feed(first, frames: 4800)
        first.deviceDied = true
        capture.handleConfigurationChange()

        capture.handleRetryIfDegraded()  // no provider; the probe is dead

        #expect(!third.started)
        #expect(third.toreDown)  // the failed retry backend is not leaked
        #expect(harness.built == 3)

        // Still degraded: an engine notification remains a pinned no-op…
        capture.handleConfigurationChange()
        #expect(harness.built == 3)

        // …and stop still returns everything captured before the loss.
        let samples = capture.stop()
        #expect(samples.count > 1200 && samples.count < 1700)
    }

    @Test("a retry while idle builds nothing")
    func retryWhileIdle() {
        let harness = Harness([])
        let capture = harness.capture()
        capture.handleRetryIfDegraded()
        #expect(harness.built == 0)
        #expect(capture.stop().isEmpty)
    }

    @Test("a retry while recording leaves the live engine untouched")
    func retryWhileRecording() throws {
        let engine = FakeEngine(format: Self.live48kMono)
        let harness = Harness([engine])
        let capture = harness.capture()
        try capture.start()

        capture.handleRetryIfDegraded()

        #expect(harness.built == 1)  // no new backend
        #expect(!engine.toreDown)  // no teardown
        #expect(!engine.tapRemoved)
        feed(engine, frames: 4800)  // the original tap still records
        #expect(capture.stop().count > 1200)
    }

    /// The production wiring: `retryIfDegraded` is what the store's `onChange`
    /// calls, from the store's listener queue; it must reach the retry
    /// decision asynchronously via the rebuild queue.
    @Test("the public retryIfDegraded reaches the retry decision")
    func publicRetryHopsToTheRebuildQueue() throws {
        let first = FakeEngine(format: Self.live48kMono)
        let second = FakeEngine(format: Self.dead)
        let third = FakeEngine(format: Self.live48kMono)
        let capture = Harness([first, second, third]).capture()
        try capture.start()
        first.deviceDied = true
        capture.handleConfigurationChange()

        capture.retryIfDegraded()

        // The hop is async by design; poll briefly for the recovery.
        for _ in 0..<200 where !third.started {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(third.started)
        _ = capture.stop()
    }

    // MARK: - Transition reporting

    /// What the daemon's UI needs to hear: the moment recording effectively
    /// stalls (every usable device gone) and the moment it comes back. A
    /// healthy rebuild is silent — the user never noticed anything — and so
    /// is a failed retry, whose next chance is the next device change.
    @Test("degrade and recovery are reported; healthy rebuilds and failed retries are silent")
    func transitionsReported() throws {
        let first = FakeEngine(format: Self.live48kMono)
        let second = FakeEngine(format: Self.live48kMono)  // healthy rebuild
        let third = FakeEngine(format: Self.dead)  // degrade
        let fourth = FakeEngine(format: Self.dead)  // failed retry
        let fifth = FakeEngine(format: Self.live48kMono)  // recovery
        let capture = Harness([first, second, third, fourth, fifth]).capture()
        nonisolated(unsafe) var transitions: [AudioCapture.Transition] = []
        capture.onTransition = { transitions.append($0) }

        try capture.start()
        first.deviceDied = true
        capture.handleConfigurationChange()  // healthy rebuild → silent
        #expect(transitions.isEmpty)

        second.deviceDied = true
        capture.handleConfigurationChange()  // dead probe → degraded
        #expect(transitions == [.degraded])

        capture.handleRetryIfDegraded()  // still nothing usable → silent
        #expect(transitions == [.degraded])

        capture.handleRetryIfDegraded()  // a device returned
        #expect(transitions == [.degraded, .resumed])

        _ = capture.stop()  // a normal stop is not a transition
        #expect(transitions == [.degraded, .resumed])
    }

    /// The regression that shipped: a routed engine posts a configuration
    /// change about its own start. Rebuilding on it tears the healthy engine
    /// down before its first buffer — measured live: ~10 rebuilt engines in
    /// 2 s and zero frames captured. A notification from an engine that is
    /// still running is not a device loss and must change nothing.
    @Test("a configuration change from a running engine is ignored")
    func configChangeWhileEngineRunningIsIgnored() throws {
        let engine = FakeEngine(format: Self.live48kMono)
        let harness = Harness([engine])
        let capture = harness.capture()
        try capture.start()
        feed(engine, frames: 4800)

        capture.handleConfigurationChange()  // deviceDied stays false: routing echo

        #expect(harness.built == 1)  // no rebuild
        #expect(!engine.toreDown)
        #expect(!engine.tapRemoved)
        #expect(!engine.engineStopped)
        feed(engine, frames: 2400)  // the tap keeps recording
        #expect(capture.stop().count > 1800)
    }

    // MARK: - Stale notifications

    /// AVAudioEngine posts configuration changes from an internal queue and
    /// explicitly forbids deallocating the engine inside that notification
    /// callback. Merely hopping to `rebuildQueue` is insufficient: the hop can
    /// retire the old backend before the posting callback has returned.
    ///
    /// AVFoundation's private queue cannot be driven in a unit test, so this
    /// is the deterministic seam equivalent. It holds a synthetic notification
    /// callback open while the production rebuild retires the first backend,
    /// then queues a degraded retry as proof the original handler has fully
    /// returned. The notifying source must remain alive until the outer
    /// callback exits, and may be released immediately afterward.
    @Test("a rebuild cannot deallocate its source inside the notification callback")
    func notificationSourceOutlivesCallback() throws {
        let firstReleased = DispatchSemaphore(value: 0)
        let originalHandlerReturned = DispatchSemaphore(value: 0)
        let first = WeakBox<LifetimeEngine>()
        let notification = NotificationSlot()
        nonisolated(unsafe) var built = 0

        let capture = AudioCapture(makeBackend: { onConfigurationChange in
            built += 1
            let index = built
            let engine = LifetimeEngine(
                format: index == 1 ? Self.live48kMono : Self.dead,
                onTearDown: {
                    // The third backend is the retry queued from the degrade
                    // transition. Reaching it proves the first configuration-
                    // change handler has returned, not merely started a fresh
                    // backend.
                    if index == 3 { originalHandlerReturned.signal() }
                    if index == 1 { notification.clear() }
                },
                onDeinit: {
                    if index == 1 { firstReleased.signal() }
                })

            if index == 1 {
                first.value = engine
                let relay = AudioCapture.ConfigurationChangeRelay(
                    source: engine, notify: onConfigurationChange)
                notification.install {
                    relay.call()
                    #expect(originalHandlerReturned.wait(
                        timeout: .now() + 1) == .success)
                    #expect(firstReleased.wait(timeout: .now()) == .timedOut)
                    #expect(first.value != nil)
                }
            }
            return engine.backend(isRunning: false)
        })
        capture.onTransition = { [weak capture] transition in
            if transition == .degraded { capture?.retryIfDegraded() }
        }

        try capture.start()
        #expect(first.value != nil)
        notification.fire()

        #expect(firstReleased.wait(timeout: .now() + 1) == .success)
        #expect(first.value == nil)
        capture.onTransition = nil
        _ = capture.stop()
    }

    /// A dying engine's notification is *enqueued* before `stop()` removes
    /// the observer; by the time the hop runs, a new utterance may already be
    /// recording on a fresh healthy engine. The stale hop must not tear that
    /// engine down.
    @Test("a stale notification from a torn-down backend cannot disturb the next recording")
    func staleNotificationIsIgnored() throws {
        let first = FakeEngine(format: Self.live48kMono)
        let second = FakeEngine(format: Self.live48kMono)
        let third = FakeEngine(format: Self.live48kMono)
        let harness = Harness([first, second, third])
        let capture = harness.capture()
        try capture.start()
        let stale = first.onConfigurationChange!  // delivered, its hop not yet run
        _ = capture.stop()
        try capture.start()  // the next utterance, on the second engine

        stale()

        // The hop is async; give it ample time, then prove it did nothing.
        Thread.sleep(forTimeInterval: 0.3)
        #expect(harness.built == 2)
        #expect(!second.toreDown)
        feed(second, frames: 4800)
        #expect(capture.stop().count > 1200)  // the live tap was never replaced
    }

    /// The production wiring: the closure handed to the backend factory is
    /// what the engine's configuration-change notification invokes. It must
    /// reach `handleConfigurationChange` (asynchronously, off the notifying
    /// thread).
    @Test("the notification closure given to the factory triggers the rebuild")
    func notificationClosureTriggersRebuild() throws {
        let first = FakeEngine(format: Self.live48kMono)
        let second = FakeEngine(format: Self.live48kMono)
        let harness = Harness([first, second])
        let capture = harness.capture()
        try capture.start()

        first.deviceDied = true
        first.onConfigurationChange?()

        // The hop is async by design (the notification can fire on the very
        // thread the teardown needs); poll briefly for the rebuild.
        for _ in 0..<200 where !second.started {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(second.started)
        _ = capture.stop()
    }
}
