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
                tearDown: { self.toreDown = true })
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
        capture.handleConfigurationChange()

        capture.retryIfDegraded()

        // The hop is async by design; poll briefly for the recovery.
        for _ in 0..<200 where !third.started {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(third.started)
        _ = capture.stop()
    }

    // MARK: - Stale notifications

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
