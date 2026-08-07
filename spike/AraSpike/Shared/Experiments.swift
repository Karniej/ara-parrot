import AVFoundation
import Foundation
import Speech
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

/// The three experiments from docs/IOS-BUILD-PLAN.md Phase 0, as functions that
/// return report lines instead of asserting — the point is to *read* the
/// device's answer, not to pass.
///
/// Compiled into **both** the container app and the keyboard extension, so the
/// two runs differ only in sandbox. A result that differs between them is the
/// extension sandbox speaking; a result that matches is the device or OS.
enum Experiments {
    /// Jetsam headroom in MB. The number to watch in every report: the
    /// analysis says extensions die at ~30–48 MB with no crash report, so a
    /// big drop during an experiment is the answer arriving early.
    static func availableMemoryMB() -> Int {
        Int(os_proc_available_memory() / 1_048_576)
    }

    /// Bumped every push, printed in every header, so a pasted report names
    /// the build that produced it instead of leaving it to archaeology.
    static let spikeBuild = 8

    static func header(context: String, fullAccess: Bool?) -> [String] {
        var lines = ["═══ Ara spike · \(context) · build \(spikeBuild) ═══",
                     "mem available: \(availableMemoryMB()) MB"]
        if let fullAccess {
            lines.append("full access: \(fullAccess)")
        }
        return lines
    }

    // MARK: - Experiment 1: Foundation Models

    /// Does the OS-hosted 3B model answer from this process? Decides whether
    /// the smart cleanup tier exists. Watch for: `.available` + a real
    /// response, `.unavailable(...)` with a named reason, or the sandbox
    /// error 159 that killed it in DeviceActivityReport.
    static func foundationModels() async -> [String] {
        var lines = ["— experiment 1: Foundation Models —",
                     "mem before: \(availableMemoryMB()) MB"]
        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            lines.append("availability: .available")
            do {
                let session = LanguageModelSession()
                let start = Date()
                let response = try await session.respond(
                    to: "Reply with exactly one word: OK")
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                lines.append("response (\(ms) ms): \(String(response.content.prefix(60)))")
            } catch {
                lines.append("respond THREW: \(type(of: error)): \(error)")
            }
        case .unavailable(let reason):
            lines.append("availability: .unavailable(\(String(describing: reason)))")
        }
        #else
        lines.append("FoundationModels does not compile on this SDK")
        #endif
        lines.append("mem after: \(availableMemoryMB()) MB")
        return lines
    }

    // MARK: - Experiment 2: microphone

    /// Can this process record at all? Permission state, session activation,
    /// input format, and — the part that matters — whether frames actually
    /// arrive. The macOS lesson pinned in AudioCapture applies: ask the
    /// *input* side for its format and count real buffers; a tap that
    /// installs but never fires is a no.
    static func microphone() async -> [String] {
        var lines = ["— experiment 2: microphone —",
                     "mem before: \(availableMemoryMB()) MB"]

        let permission = AVAudioApplication.shared.recordPermission
        lines.append("permission at entry: \(describe(permission))")
        if permission == .undetermined {
            let granted = await AVAudioApplication.requestRecordPermission()
            lines.append("prompt shown → granted: \(granted)")
        }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            lines.append("stopping: permission not granted")
            return lines
        }

        let session = AVAudioSession.sharedInstance()
        lines.append("isInputAvailable: \(session.isInputAvailable) · "
                     + "inputs: \(session.availableInputs?.map(\.portType.rawValue).joined(separator: ",") ?? "none")")

        // First device run (2026-08-07): permission granted, session active,
        // real input format — and `kAUStartIO` refused with 'what'
        // (AVAudioSessionErrorCodeUnspecified). One refused API is not "the
        // platform forbids recording": a shipping competitor records from a
        // keyboard somehow, so this is a matrix over capture paths, hunting
        // the one that starts. Each attempt tears its session down before the
        // next so a failure cannot poison its successor.
        var anyWorked = false
        for attempt in Attempt.allCases {
            lines.append("· \(attempt.label)")
            let verdict = await attempt.run()
            lines.append(contentsOf: verdict.map { "   \($0)" })
            anyWorked = anyWorked || verdict.contains { $0.hasPrefix("OK") }
        }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)

        lines.append(anyWorked
            ? "VERDICT: recording WORKS in this process (see which path above)"
            : "VERDICT: every capture path refused — in-appex recording is off the table")
        lines.append("mem after: \(availableMemoryMB()) MB")
        return lines
    }

    /// The capture paths worth ruling in or out, cheapest-to-strangest.
    enum Attempt: CaseIterable {
        /// The original: plain engine under `.record`/`.measurement`.
        case engineRecord
        /// `.playAndRecord` with `.mixWithOthers` — a keyboard lives inside a
        /// *host app* that may own the audio session; refusing to share is the
        /// most likely reason an exclusive `.record` start is refused.
        case engineMixed
        /// `.voiceChat` mode — routes through the voice-processing unit, a
        /// different I/O path with its own policy.
        case engineVoiceChat
        /// `AVAudioRecorder` to a file — the highest-level API; if policy
        /// gates by API rather than by process, this is the one apps predating
        /// AVAudioEngine still use.
        case fileRecorder

        var label: String {
            switch self {
            case .engineRecord: return "engine · .record/.measurement"
            case .engineMixed: return "engine · .playAndRecord/.mixWithOthers"
            case .engineVoiceChat: return "engine · .playAndRecord/.voiceChat"
            case .fileRecorder: return "AVAudioRecorder → file"
            }
        }

        func run() async -> [String] {
            let session = AVAudioSession.sharedInstance()
            defer { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
            do {
                switch self {
                case .engineRecord:
                    try session.setCategory(.record, mode: .measurement)
                case .engineMixed:
                    try session.setCategory(.playAndRecord, mode: .default,
                                            options: [.mixWithOthers, .defaultToSpeaker,
                                                      .allowBluetooth])
                case .engineVoiceChat:
                    try session.setCategory(.playAndRecord, mode: .voiceChat,
                                            options: [.allowBluetooth])
                case .fileRecorder:
                    try session.setCategory(.playAndRecord, mode: .default,
                                            options: [.mixWithOthers])
                }
                try session.setActive(true)
            } catch {
                return ["session: THREW \(Self.shortError(error))"]
            }

            if self == .fileRecorder { return await Self.runFileRecorder() }

            let engine = AVAudioEngine()
            let format = engine.inputNode.inputFormat(forBus: 0)
            guard format.sampleRate > 0 else { return ["zero-rate input format"] }
            let counter = FrameCounter()
            engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
                counter.add(Int(buffer.frameLength))
            }
            defer { engine.inputNode.removeTap(onBus: 0); engine.stop() }
            do { try engine.start() } catch {
                return ["start: THREW \(Self.shortError(error))"]
            }
            try? await Task.sleep(for: .milliseconds(900))
            let frames = counter.total
            return frames > 0
                ? ["OK — \(frames) frames (\(String(format: "%.2f", Double(frames) / format.sampleRate)) s)"]
                : ["started but 0 frames"]
        }

        private static func runFileRecorder() async -> [String] {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("spike-rec.m4a")
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let recorder = try AVAudioRecorder(url: url, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                ])
                guard recorder.record() else { return ["record() returned false"] }
                try? await Task.sleep(for: .milliseconds(900))
                recorder.stop()
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                return size ?? 0 > 200
                    ? ["OK — wrote \(size ?? 0) bytes"]
                    : ["recorded but file is \(size ?? 0) bytes"]
            } catch {
                return ["init/record THREW \(shortError(error))"]
            }
        }

        private static func shortError(_ error: any Error) -> String {
            let ns = error as NSError
            return "\(ns.domain) \(ns.code)"
        }
    }

    // MARK: - Experiment 3: on-device ASR

    /// The one that decides the product. Transcribes the bundled sentence with
    /// `requiresOnDeviceRecognition = true` — recognition runs in the system's
    /// speech daemon, so what we are really measuring is whether an appex may
    /// talk to it and what it costs *this* process in memory.
    ///
    /// A bundled file rather than the microphone, deliberately: it decouples
    /// this experiment from experiment 2, so a mic refusal cannot mask an ASR
    /// answer.
    static func onDeviceASR() async -> [String] {
        var lines = ["— experiment 3: on-device ASR —",
                     "mem before: \(availableMemoryMB()) MB"]

        let auth = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        lines.append("authorization: \(describe(auth))")
        guard auth == .authorized else {
            lines.append("stopping: not authorized")
            return lines
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            lines.append("stopping: no recognizer for en-US")
            return lines
        }
        lines.append("supportsOnDeviceRecognition: \(recognizer.supportsOnDeviceRecognition)")
        guard let url = Bundle.main.url(forResource: "probe", withExtension: "wav") else {
            lines.append("stopping: probe.wav missing from bundle")
            return lines
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        let start = Date()
        do {
            let text = try await recognize(recognizer: recognizer, request: request,
                                           timeout: .seconds(20))
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            lines.append("transcript (\(ms) ms): \"\(text)\"")
            lines.append("VERDICT: on-device ASR WORKS from this process")
        } catch {
            lines.append("recognition FAILED: \(type(of: error)): \(error)")
            lines.append("VERDICT: on-device ASR blocked or broken here")
        }
        lines.append("mem after: \(availableMemoryMB()) MB")
        return lines
    }

    // MARK: - Plumbing

    /// One-shot recognition with a deadline. The deadline matters in an
    /// appex: a hung recognition holding the process open is a jetsam vector,
    /// and "no answer in 20 s" is itself a result worth reporting.
    ///
    /// A dispatch-timer watchdog rather than a task group: SFSpeech types are
    /// not Sendable, and hopping them across child tasks is exactly what
    /// Swift 6 strict concurrency exists to refuse. The `done` lock makes the
    /// three racers — final result, error, timeout — resume exactly once.
    private static func recognize(recognizer: SFSpeechRecognizer,
                                  request: SFSpeechRecognitionRequest,
                                  timeout: Duration) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let done = OSAllocatedUnfairLock(initialState: false)
            let box = TaskBox()
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if done.withLock({ d in defer { d = true }; return d }) { return }
                    cont.resume(throwing: error)
                } else if let result, result.isFinal {
                    if done.withLock({ d in defer { d = true }; return d }) { return }
                    cont.resume(returning: result.bestTranscription.formattedString)
                }
            }
            box.set(task)
            DispatchQueue.global().asyncAfter(
                deadline: .now() + Double(timeout.components.seconds)) {
                if done.withLock({ d in defer { d = true }; return d }) { return }
                box.cancel()
                cont.resume(throwing: TimeoutError())
            }
        }
    }

    struct TimeoutError: Error {}

    private static func describe(_ p: AVAudioApplication.recordPermission) -> String {
        switch p {
        case .granted: return "granted"
        case .denied: return "denied"
        case .undetermined: return "undetermined"
        @unknown default: return "unknown(\(p.rawValue))"
        }
    }

    private static func describe(_ s: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown(\(s.rawValue))"
        }
    }
}

/// Counts audio frames delivered on the tap's realtime thread.
private final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add(_ n: Int) { lock.withLock { count += n } }
    var total: Int { lock.withLock { count } }
}

/// Holds the recognition task so the timeout path can cancel it.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: SFSpeechRecognitionTask?
    func set(_ t: SFSpeechRecognitionTask) { lock.withLock { task = t } }
    func cancel() { lock.withLock { task?.cancel(); task = nil } }
}
