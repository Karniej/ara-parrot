import AVFoundation
import Testing

@testable import AraCore

/// Opt-in hardware test: `ARA_AUDIO_HW=1 swift test --filter AudioCaptureHardware`.
///
/// Exists because the fake-backend suite cannot see inside `liveBackend`, and
/// the one bug it can't see broke every recording: routing the input unit to a
/// device leaves `inputNode.outputFormat(forBus:)` reporting the format cached
/// at node creation, while the hardware runs at the routed device's native
/// rate. A tap installed with that stale format never fires — the engine
/// "runs", zero buffers arrive, and dictation captures 0.00 s. Measured on
/// this machine: cached 44.1 kHz vs routed 48 kHz, tap fires 0. The live
/// backend must therefore read the post-routing hardware format
/// (`inputFormat(forBus:)`), and this test pins that audio actually flows
/// through the REAL routed path — needs a working input device and microphone
/// permission, hence opt-in.
@Suite("AudioCaptureHardware") struct AudioCaptureHardwareTests {
    @Test("routed live capture delivers audio frames")
    func routedLiveCaptureDeliversFrames() async throws {
        guard ProcessInfo.processInfo.environment["ARA_AUDIO_HW"] == "1" else { return }

        let store = MicrophoneStore(preferredUID: nil)
        guard let device = store.effective.device else {
            Issue.record("no input device connected; cannot run hardware check")
            return
        }
        print("hw-test: effective = \(device.name) (id \(device.id), \(store.effective))")
        print("hw-test: devices = \(store.devices.map { "\($0.name)#\($0.id)" })")

        // Discriminator: the unrouted path first. If THIS captures nothing,
        // the test process lacks a working default input or mic permission
        // and the routed result below is unattributable.
        let unrouted = AudioCapture()
        try unrouted.start()
        try await Task.sleep(for: .seconds(2))
        let unroutedSamples = unrouted.stop()
        print("hw-test: unrouted frames = \(unroutedSamples.count)")

        let notifications = NotificationCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { _ in notifications.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }

        let capture = AudioCapture()
        capture.deviceProvider = { store.effective.device?.id }
        var transitions: [String] = []
        capture.onTransition = { transitions.append("\($0)") }

        try capture.start()
        try await Task.sleep(for: .seconds(2))
        let samples = capture.stop()
        print("hw-test: routed frames = \(samples.count), configChange notifications = \(notifications.count), transitions = \(transitions)")

        // 2 s at 16 kHz is 32k frames; converter priming eats a little. Any
        // healthy tap delivers far more than this floor; a stale-format tap
        // delivers exactly zero.
        #expect(samples.count > 8_000,
                "routed capture delivered \(samples.count) frames — tap did not fire")
    }

    /// The risk in reusing one `AVAudioEngine` across recordings, against real
    /// hardware.
    ///
    /// `stop()` no longer releases the engine — it is kept so an AVFAudio
    /// property block already in flight cannot outlive it (see
    /// `AudioCapture.retire` for the crash that motivated it). The cost of
    /// that is a second `start()` re-routing, re-probing and re-tapping an
    /// engine that has already run once, and the fake-backend suite cannot see
    /// whether a real one survives it.
    ///
    /// It is the same failure shape this suite already exists for: a tap that
    /// silently never fires. If a reused engine reported a stale
    /// `inputFormat(forBus:)` on its second start, the second recording would
    /// capture exactly zero frames while the engine claimed to run.
    @Test("a reused engine still delivers audio on a second recording")
    func reusedEngineDeliversOnSecondRecording() async throws {
        guard ProcessInfo.processInfo.environment["ARA_AUDIO_HW"] == "1" else { return }

        let store = MicrophoneStore(preferredUID: nil)
        guard store.effective.device != nil else {
            Issue.record("no input device connected; cannot run hardware check")
            return
        }

        let capture = AudioCapture()
        capture.deviceProvider = { store.effective.device?.id }

        try capture.start()
        try await Task.sleep(for: .seconds(2))
        let first = capture.stop()

        // The same engine object, started again.
        try capture.start()
        try await Task.sleep(for: .seconds(2))
        let second = capture.stop()

        print("hw-test: reuse frames = \(first.count) then \(second.count)")
        #expect(first.count > 8_000,
                "first recording delivered \(first.count) frames")
        #expect(second.count > 8_000,
                "reused engine delivered \(second.count) frames on its second recording — the tap did not fire")
    }
}

final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}
