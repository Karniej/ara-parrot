import AVFoundation
import Foundation

/// Experiment 4: the container-relay theory.
///
/// The matrix (2026-08-07, iPhone 11, iOS 26.0) proved the appex cannot record
/// by any API path. The one architecture left that explains a shipping
/// competitor's UX is: the *container app* records with the background-audio
/// mode while the keyboard is frontmost, and the two talk through the App
/// Group. This probe tests exactly that seam, end to end:
///
/// - **App side** (`startBackgroundRecording`): activates a `.playAndRecord`
///   session, taps the input, and writes a heartbeat — frame count + wall
///   clock — into the shared defaults twice a second.
/// - **Keyboard side** (`observeRelay`): watches the heartbeat for three
///   seconds. Frames still advancing while the keyboard is on screen means the
///   app is recording *in the background* and the relay is real.
enum RelayProbe {
    static let group = "group.com.silpho.araspike"
    static let framesKey = "relay.frames"
    static let stampKey = "relay.stamp"

    // MARK: - App side

    /// Starts recording and heartbeating. Returns immediately; the closure
    /// gets status lines for the app's own log. Keeps recording until the
    /// process dies or `stop` is called — outliving the foreground is the
    /// entire point.
    @MainActor
    static func startBackgroundRecording(report: @escaping (String) -> Void) {
        guard let defaults = UserDefaults(suiteName: group) else {
            report("no App Group access — provisioning did not grant \(group)")
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            // `.playAndRecord` + the `audio` background mode is the
            // combination that keeps capture alive after backgrounding.
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.allowBluetooth])
            try session.setActive(true)
        } catch {
            report("session THREW: \(error)")
            return
        }
        let engine = AVAudioEngine()
        let format = engine.inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            report("zero-rate input format")
            return
        }
        let counter = FrameTally()
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            counter.add(Int(buffer.frameLength))
        }
        do { try engine.start() } catch {
            report("engine.start THREW: \(error)")
            return
        }
        running = (engine, counter)
        report("recording — leave this app NOW, open Notes, run the keyboard's test 4")
        heartbeat = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            defaults.set(counter.total, forKey: framesKey)
            defaults.set(Date().timeIntervalSince1970, forKey: stampKey)
        }
    }

    @MainActor
    static func stop() {
        heartbeat?.invalidate()
        heartbeat = nil
        if let (engine, _) = running {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        running = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    @MainActor private static var running: (AVAudioEngine, FrameTally)?
    @MainActor private static var heartbeat: Timer?

    // MARK: - Keyboard side

    /// Reads the heartbeat for ~3 s and reports whether frames advanced.
    static func observeRelay() async -> [String] {
        var lines = ["— experiment 4: container-relay recording —"]
        guard let defaults = UserDefaults(suiteName: group) else {
            lines.append("no App Group access from the keyboard")
            lines.append("VERDICT: relay unreadable (check Full Access / provisioning)")
            return lines
        }
        let stamp = defaults.double(forKey: stampKey)
        guard stamp > 0 else {
            lines.append("no heartbeat found — start recording in the AraSpike app first")
            return lines
        }
        let age = Date().timeIntervalSince1970 - stamp
        lines.append(String(format: "heartbeat age: %.1f s", age))
        if age > 5 {
            lines.append("heartbeat is stale — the app stopped recording "
                         + "(backgrounded apps without live audio get suspended)")
        }
        let first = defaults.integer(forKey: framesKey)
        try? await Task.sleep(for: .seconds(3))
        let second = defaults.integer(forKey: framesKey)
        let delta = second - first
        lines.append("frames while keyboard on screen: +\(delta)")
        lines.append(delta > 0
            ? "VERDICT: the container app RECORDS IN THE BACKGROUND — the relay works"
            : "VERDICT: no frames advanced — the app was suspended; relay needs more than the audio flag")
        return lines
    }
}

private final class FrameTally: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add(_ n: Int) { lock.withLock { count += n } }
    var total: Int { lock.withLock { count } }
}
