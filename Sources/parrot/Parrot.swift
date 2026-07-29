import AppKit
import ArgumentParser
import AraCore
import Foundation

@main
struct Parrot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "parrot",
        abstract: "Minimal macOS dictation daemon. Hold Fn, speak, release.",
        subcommands: [Run.self, Setup.self, Doctor.self, Models.self, Install.self],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the daemon (default)."
    )

    @Flag(name: .long, help: "Skip permission checks at startup.")
    var skipDoctor: Bool = false

    @Flag(name: .long, help: "Print every keyboard event the tap sees (debug).")
    var debugHotkey: Bool = false

    @Flag(name: .long, help: "Write each capture to /tmp/parrot-last.wav for inspection.")
    var dumpWav: Bool = false

    @Flag(name: .long, help: "Disable the on-screen recording overlay.")
    var noOverlay: Bool = false

    @Option(name: .long, help: "Model id to use. Defaults to the recommended model.")
    var model: String?

    @Option(
        name: .long,
        help: "Push-to-talk key. One of: \(Hotkey.valueNames). Fn only works on Apple's built-in keyboard."
    )
    var hotkey: Hotkey = .fn

    @Option(name: .long, help: "Output mode. One of: verbatim, default, email, chat, code.")
    var mode: String?

    func run() throws {
        if !skipDoctor {
            let checks = DoctorReport.run()
            if !DoctorReport.allOK(checks) {
                FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
                DoctorReport.print(checks)
                FileHandle.standardError.write(Data("\nfix the above or pass --skip-doctor\n".utf8))
                throw ExitCode(1)
            }
        }

        // Configuration and argument validation ahead of the model warm-up, so
        // `--mode typo` fails in milliseconds rather than after a model download.
        let config = Config.load()
        let registry = ModeRegistry(userModes: [])
        if let mode, registry.mode(id: mode) == nil {
            FileHandle.standardError.write(Data("unknown mode: \(mode)\n".utf8))
            let known = registry.all.map(\.id).joined(separator: ", ")
            FileHandle.standardError.write(Data("known modes: \(known)\n".utf8))
            throw ExitCode(1)
        }

        let chosenModel: TranscriptionModel
        if let id = model {
            guard let m = ModelRegistry.find(id) else {
                FileHandle.standardError.write(Data("unknown model: \(id)\n".utf8))
                FileHandle.standardError.write(Data("run `parrot models list` to see options.\n".utf8))
                throw ExitCode(1)
            }
            chosenModel = m
        } else {
            guard let m = ModelRegistry.recommended() else {
                FileHandle.standardError.write(Data("no models registered\n".utf8))
                throw ExitCode(1)
            }
            chosenModel = m
        }

        let transcriber = WhisperKitTranscriber(model: chosenModel)
        let warmupSemaphore = DispatchSemaphore(value: 0)
        var warmupError: Error?
        Task.detached {
            do {
                try await transcriber.warmUp()
            } catch {
                warmupError = error
            }
            warmupSemaphore.signal()
        }
        warmupSemaphore.wait()
        if let warmupError {
            FileHandle.standardError.write(Data("warmup failed: \(warmupError)\n".utf8))
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let monitor = HotkeyMonitor(hotkey: hotkey, debug: debugHotkey)
        let capture = AudioCapture()
        let dumpWav = self.dumpWav
        let overlay: RecordingOverlay? = noOverlay ? nil : MainActor.assumeIsolated { RecordingOverlay() }
        if let overlay {
            capture.onLevel = { level in overlay.pushLevel(level) }
        }
        // The keychain read happens ONCE, here, on the CLI's own thread — never
        // inside `format`. `SecItemCopyMatching` raises an unlock or Allow/Deny
        // prompt on a locked keychain or on an item whose ACL does not trust
        // this binary, and blocks until a human answers it. On a
        // cooperative-pool thread that is an unbounded version of the 9.16s
        // stall `FormatterChain.withDeadline` documents — and the deadline
        // cannot rescue it, because abandoning a task does not free the thread
        // it is blocking. This binary is unsigned, so the legacy keychain's
        // ACL-by-identity re-prompts after every rebuild; this is the normal
        // path, not a corner case. The cost is that a rotated key needs a
        // restart, which is the right trade.
        var apiKey: String?
        if let cloudConfig = config.cloud {
            apiKey = Keychain.readPassword(account: cloudConfig.keychainAccount)
        }

        let hotkeyLabel = hotkey.label
        let startingMode = mode ?? config.mode
        let menuBar = MainActor.assumeIsolated {
            MenuBarController(modelID: chosenModel.id, hotkeyLabel: hotkeyLabel,
                              modeID: startingMode)
        }

        // Sampled on the main actor at each hotkey release and read back from
        // the session's actor. See `FrontmostApp` for why reading NSWorkspace
        // from the session directly is a trap rather than a hop.
        let frontmost = FrontmostApp()
        MainActor.assumeIsolated { frontmost.capture() }

        let modeOverride = mode
        let session = Pipeline.makeSession(
            config: config,
            apiKey: apiKey,
            local: Pipeline.localFormatter(),
            registry: registry,
            frontmostBundleID: frontmost.reader,
            onModeResolved: { resolved in
                Task { @MainActor in menuBar.setMode(resolved.id) }
            })

        do {
            try monitor.start { event in
                switch event {
                case .pressed:
                    do {
                        try capture.start()
                        FileHandle.standardError.write(Data("● recording\n".utf8))
                        MainActor.assumeIsolated {
                            overlay?.show(.recording)
                            menuBar.setRecording(true)
                        }
                    } catch {
                        FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
                    }
                case .released:
                    let samples = capture.stop()
                    MainActor.assumeIsolated {
                        // Sampled here, on the main thread, while it is still
                        // true: this is the app the user was dictating into,
                        // before transcription gives them time to switch away.
                        frontmost.capture()
                        overlay?.show(.transcribing)
                        menuBar.setTranscribing()
                    }
                    let seconds = Double(samples.count) / AudioCapture.targetSampleRate
                    let rms = computeRMS(samples)
                    FileHandle.standardError.write(Data(
                        String(format: "○ captured %.2fs · rms %.3f\n", seconds, rms).utf8
                    ))
                    if dumpWav, !samples.isEmpty {
                        let path = "/tmp/parrot-last.wav"
                        do {
                            try WAVWriter.write(samples: samples, sampleRate: 16_000, to: path)
                            FileHandle.standardError.write(Data("  wrote \(path)\n".utf8))
                        } catch {
                            FileHandle.standardError.write(Data("  wav write failed: \(error)\n".utf8))
                        }
                    }
                    guard !samples.isEmpty else {
                        MainActor.assumeIsolated {
                            overlay?.hide()
                            menuBar.setRecording(false)
                        }
                        return
                    }
                    Task {
                        let started = Date()
                        do {
                            let text = try await transcriber.transcribe(samples)
                            let transcribed = Date().timeIntervalSince(started)
                            FileHandle.standardError.write(Data(
                                String(format: "→ %.2fs · %@\n", transcribed, text).utf8
                            ))
                            // Never `try?`, and never a throwing call: `process`
                            // returns a String and cannot fail, so a broken
                            // formatter can only ever degrade to raw text.
                            let cleaned = await session.process(
                                text, override: modeOverride, manual: nil)
                            if cleaned != text {
                                let total = Date().timeIntervalSince(started)
                                FileHandle.standardError.write(Data(
                                    String(format: "↦ %.2fs · %@\n", total, cleaned).utf8
                                ))
                            }
                            await MainActor.run {
                                // The empty string is `process`'s "nothing to
                                // type": an empty transcript, or a request that
                                // was cancelled while it was being formatted.
                                // Injecting a withdrawn request's text is the
                                // failure the chain propagates cancellation to
                                // prevent, so the guard is the point, not tidiness.
                                if !cleaned.isEmpty {
                                    TextInjector.inject(cleaned)
                                }
                                overlay?.hide()
                                menuBar.setRecording(false)
                            }
                        } catch {
                            FileHandle.standardError.write(Data("transcription failed: \(error)\n".utf8))
                            await MainActor.run {
                                overlay?.hide()
                                menuBar.setRecording(false)
                            }
                        }
                    }
                }
            }
        } catch {
            FileHandle.standardError.write(Data("failed to register hotkey tap: \(error)\n".utf8))
            FileHandle.standardError.write(Data("run `parrot setup` to configure permissions.\n".utf8))
            throw ExitCode(1)
        }

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            monitor.stop()
            NSApp.terminate(nil)
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        FileHandle.standardError.write(Data(
            "listening on \(hotkey.label) hold · model: \(chosenModel.id) · ^C to quit\n".utf8
        ))
        app.run()
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, accessibility, and Fn key configuration."
    )

    func run() throws {
        let checks = DoctorReport.run()
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage transcription models.",
        subcommands: [List.self, Download.self]
    )

    struct List: ParsableCommand {
        func run() throws {
            for m in ModelRegistry.shared {
                let star = m.recommended ? "★" : " "
                let id = m.id.padding(toLength: 26, withPad: " ", startingAt: 0)
                let langs = "[\(m.languages.joined(separator: ","))]"
                    .padding(toLength: 9, withPad: " ", startingAt: 0)
                let size = String(format: "%5d MB", m.sizeMB)
                print("\(star) \(id) \(size)  \(langs)  \(m.displayName)")
            }
        }
    }

    struct Download: ParsableCommand {
        @Argument(help: "Model id to download.") var id: String

        func run() throws {
            guard let m = ModelRegistry.find(id) else {
                print("unknown model: \(id)")
                throw ExitCode(1)
            }
            let t = WhisperKitTranscriber(model: m)

            let sem = DispatchSemaphore(value: 0)
            var capturedError: Error?
            Task.detached {
                do { try await t.warmUp() } catch { capturedError = error }
                sem.signal()
            }
            sem.wait()
            if let e = capturedError { throw e }
        }
    }
}
