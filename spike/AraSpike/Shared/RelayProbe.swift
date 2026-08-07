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
    static let launchKey = "relay.launch"
    static let statusKey = "relay.status"

    /// `UserDefaults(suiteName:)` returns a working-looking object even when
    /// provisioning never granted the group — each process then talks to a
    /// private container and the two sides silently never meet. The container
    /// URL is the honest check: it is nil exactly when the entitlement is
    /// missing.
    static var containerExists: Bool {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: group) != nil
    }

    // MARK: - App side

    /// Starts recording and heartbeating. Returns immediately; the closure
    /// gets status lines for the app's own log. Keeps recording until the
    /// process dies or `stop` is called — outliving the foreground is the
    /// entire point.
    @MainActor
    static func startBackgroundRecording(report: @escaping (String) -> Void) {
        // Every status line is mirrored into the App Group so the *keyboard's*
        // report can say what happened on the app side — three runs in a row
        // produced keyboard-only reports, so the keyboard report must carry
        // the whole story.
        let mirrored: (String) -> Void = { line in
            UserDefaults(suiteName: group)?.set(line, forKey: statusKey)
            report(line)
        }
        // Launch marker, before anything can fail: splits "the app never
        // opened" from "the app opened and something broke".
        UserDefaults(suiteName: group)?
            .set(Date().timeIntervalSince1970, forKey: launchKey)
        guard containerExists else {
            mirrored("no App Group container — provisioning did not grant \(group)")
            return
        }
        Task { @MainActor in
            if AVAudioApplication.shared.recordPermission != .granted {
                guard await AVAudioApplication.requestRecordPermission() else {
                    mirrored("mic permission denied")
                    return
                }
            }
            begin(report: mirrored)
        }
    }

    @MainActor
    private static func begin(report: (String) -> Void) {
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
        // `@Sendable`, load-bearing: a closure literal formed inside a
        // `@MainActor` function silently inherits main-actor isolation, and
        // the tap fires on the realtime capture thread — the runtime enforces
        // the mismatch with dispatch_assert_queue and kills the app. Crashed
        // exactly that way on first device run; `@Sendable` severs the
        // inference.
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048,
                                    format: format) { @Sendable buffer, _ in
            counter.add(Int(buffer.frameLength))
        }
        do { try engine.start() } catch {
            report("engine.start THREW: \(error)")
            return
        }
        running = (engine, counter)
        // Stamp immediately, not at the timer's first tick: it splits "the
        // app never started" from "the app started and was then suspended" —
        // the two verdicts this experiment exists to distinguish.
        defaults.set(0, forKey: framesKey)
        defaults.set(Date().timeIntervalSince1970, forKey: stampKey)
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
        lines.append("keyboard app-group container: \(containerExists ? "ok" : "MISSING")")
        guard containerExists, let defaults = UserDefaults(suiteName: group) else {
            lines.append("VERDICT: provisioning did not grant \(group) to the keyboard — regenerate profiles (delete both apps, clean build)")
            return lines
        }
        let launch = defaults.double(forKey: launchKey)
        guard launch > 0 else {
            lines.append("the app has never launched on this build — open the AraSpike app once, then rerun")
            return lines
        }
        lines.append(String(format: "app last launched: %.0f s ago", Date().timeIntervalSince1970 - launch))
        if let status = defaults.string(forKey: statusKey) {
            lines.append("app says: \(status)")
        }
        let stamp = defaults.double(forKey: stampKey)
        guard stamp > 0 else {
            lines.append("app launched but no heartbeat — the app-side line above is the diagnosis")
            return lines
        }
        let age = Date().timeIntervalSince1970 - stamp
        lines.append(String(format: "heartbeat age: %.1f s", age))
        if age > 5 {
            lines.append("heartbeat is stale — the app stopped recording "
                         + "(backgrounded apps without live audio get suspended)")
        }
        let first = defaults.integer(forKey: framesKey)
        lines.append("frames at entry: \(first)")
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
