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

    @Option(name: .long,
            help: "Model id to use. Defaults to config.model, then the recommended model.")
    var model: String?

    // Optional, not defaulted to `.fn`: a default here is indistinguishable at
    // the use site from the user having asked for Fn, which is what made
    // `config.hotkey` dead. `nil` means "the user said nothing", and only then
    // does the config get a say.
    @Option(
        name: .long,
        help: "Push-to-talk key. One of: \(Hotkey.valueNames). Defaults to config.hotkey, then fn. Fn only works on Apple's built-in keyboard."
    )
    var hotkey: Hotkey?

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
        var config = Config.load()
        let registry = ModeRegistry(userModes: [])
        let knownModes = registry.all.map(\.id).joined(separator: ", ")
        // A bad flag is a mistake the user just made and can retype, so it is
        // fatal. A bad `mode` key in config.json is not: exiting would leave the
        // daemon unusable until a file is edited, over something the resolver
        // already degrades from safely. Warn and continue — but *explicitly*, so
        // the menu bar does not advertise a mode that does not exist and the
        // silent degradation in `ModeResolver` never has to happen.
        if let mode, registry.mode(id: mode) == nil {
            FileHandle.standardError.write(Data("unknown mode: \(mode)\n".utf8))
            FileHandle.standardError.write(Data("known modes: \(knownModes)\n".utf8))
            throw ExitCode(1)
        }
        if registry.mode(id: config.mode) == nil {
            let warning = "unknown mode in config: \(config.mode) — using "
                + "\(ModeRegistry.defaultMode.id)\n"
            FileHandle.standardError.write(Data(warning.utf8))
            FileHandle.standardError.write(Data("known modes: \(knownModes)\n".utf8))
            config.mode = ModeRegistry.defaultMode.id
        }

        // CLI flags > config > defaults, for both of these. The rules live in
        // `StartupResolution` so they are covered by tests; `run()` is not.
        let chosenHotkey = StartupResolution.hotkey(flag: hotkey, config: config.hotkey)
        let chosenModel: TranscriptionModel
        switch StartupResolution.model(flag: model, config: config.model) {
        case .chosen(let m):
            chosenModel = m
        case .unknownFlag(let id):
            FileHandle.standardError.write(Data("unknown model: \(id)\n".utf8))
            FileHandle.standardError.write(Data("run `parrot models list` to see options.\n".utf8))
            throw ExitCode(1)
        case .noModelsRegistered:
            FileHandle.standardError.write(Data("no models registered\n".utf8))
            throw ExitCode(1)
        }

        let transcriber = WhisperKitTranscriber(model: chosenModel)
        // The formatting model is loaded here too, before the hotkey loop, and
        // never on the dictation path: a warm load is ~1s and a cold one ~38s
        // against a 2500ms per-engine deadline, so a lazy first load would be
        // abandoned every time — and abandoning compute-bound work does not
        // stop it, it only stops waiting for it.
        //
        // Built unconditionally so the chain always has the candidate, but only
        // *warmed* under the engines that will consult it: `apple`, `rules` and
        // `off` would otherwise pay a second of startup and 0.9GB of resident
        // memory for a model they never call.
        let mlx = Pipeline.mlxFormatter()
        let warmsMLX = config.engine == .mlx || config.engine == .cloud
        let warmupSemaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var warmupError: Error?
        nonisolated(unsafe) var mlxWarmupError: Error?
        Task.detached {
            do {
                try await transcriber.warmUp()
            } catch {
                warmupError = error
            }
            if warmsMLX {
                do {
                    try await mlx.warmUp()
                } catch {
                    mlxWarmupError = error
                }
            }
            warmupSemaphore.signal()
        }
        warmupSemaphore.wait()
        if let warmupError {
            FileHandle.standardError.write(Data("warmup failed: \(warmupError)\n".utf8))
            throw ExitCode(1)
        }
        // A warning, not a failure. Transcription without formatting is the
        // whole app minus its polish; formatting without transcription is
        // nothing. So a missing Whisper model is fatal above and a missing
        // formatting model is one line here, with the command that fixes it.
        if let mlxWarmupError {
            let detail: String
            if case .transportFailure(let message)? = mlxWarmupError as? FormatterError {
                detail = message
            } else {
                detail = "\(mlxWarmupError)"
            }
            FileHandle.standardError.write(Data(
                "! local formatting unavailable: \(detail)\n".utf8))
            FileHandle.standardError.write(Data(
                "  dictation will use rule-based cleanup until then\n".utf8))
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let monitor = HotkeyMonitor(hotkey: chosenHotkey, debug: debugHotkey)
        let capture = AudioCapture()
        // The store watches the hardware for the whole process; the capture
        // consults it at every `start()` and on every mid-recording rebuild.
        // That is the entire idle-time story: a device change while idle
        // re-arms nothing, because the next utterance resolves afresh anyway.
        // With no config key and no menu pick the provider yields the system
        // default input — exactly what an unrouted engine would have used.
        let micStore = MicrophoneStore(preferredUID: config.microphone)
        capture.deviceProvider = { micStore.effective.device?.id }
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

        let hotkeyLabel = chosenHotkey.label
        let startingMode = mode ?? config.mode
        let menuBar = MainActor.assumeIsolated {
            MenuBarController(modelID: chosenModel.id, hotkeyLabel: hotkeyLabel,
                              modeID: startingMode)
        }

        // The dictionary itself is loaded per utterance — that is the entire
        // hot-reload mechanism — so the menu form has no session to poke: it
        // merges into the file and the next dictation reads it. The backlog
        // exists for saves that fail; those corrections overlay every load
        // until quit, the same "applies until quit" contract as a microphone
        // pick whose config write failed.
        let dictionaryURL = LocalDictionary.defaultURL
        let unsavedCorrections = UnsavedCorrections()

        // The submenu's contents are computed by `MicrophoneMenuModel.compute`
        // (unit-tested); this closure only ferries store state to the shell.
        let refreshMicrophoneMenu: @MainActor () -> Void = {
            menuBar.setMicrophoneMenu(MicrophoneMenuModel.compute(
                devices: micStore.devices,
                preferredUID: micStore.preferredUID,
                effective: micStore.effective))
        }
        MainActor.assumeIsolated {
            refreshMicrophoneMenu()
            menuBar.onMicrophonePicked = { uid in
                // The store first: it re-resolves and fires `onChange`, which
                // repaints the submenu. Persistence is best-effort — a config
                // file that cannot be rewritten must not undo the pick, so the
                // failure is one warning line and the choice holds in memory.
                micStore.setPreferredUID(uid)
                do {
                    try Config.persistMicrophone(uid)
                } catch {
                    // Our own error explains itself; a foreign one is reduced
                    // to its type name, the same rule `Config.load` follows.
                    let reason = (error as? Config.PersistError)?.description
                        ?? "\(type(of: error))"
                    FileHandle.standardError.write(Data(
                        "config: microphone choice not saved (\(reason)); it applies until quit\n"
                            .utf8))
                }
            }
            menuBar.onCorrectionAdded = { heard, canonical in
                // Merge against a fresh load — the file may have been
                // hand-edited since the last utterance — plus any earlier
                // corrections whose write failed.
                let onDisk = LocalDictionary.load(from: dictionaryURL)
                let merged = unsavedCorrections.applied(to: onDisk)
                    .adding(heard: heard, canonical: canonical)
                // The file already says all of this (the correction exists,
                // and there is no backlog to land): no write, no churn.
                guard merged != onDisk else { return }
                do {
                    try merged.write(to: dictionaryURL)
                    // The write carried the backlog with it; forgetting it is
                    // what lets a later hand edit of the file win again.
                    unsavedCorrections.clear()
                } catch {
                    unsavedCorrections.remember(heard: heard, canonical: canonical)
                    FileHandle.standardError.write(Data(
                        "dictionary: correction not saved (\(type(of: error))); it applies until quit\n"
                            .utf8))
                }
            }
        }
        // Hardware events arrive on the store's listener queue; the menu is
        // main-actor state, so hop before repainting. The retry comes first
        // and needs no hop: it is the recovery path for the race where the
        // engine's own configuration-change fired before the store had
        // re-enumerated — the rebuild read the dead device and degraded while
        // a healthy fallback was milliseconds away. The store firing again is
        // the only signal that the device world actually changed, so a
        // degraded capture re-resolves here or not at all.
        micStore.onChange = {
            capture.retryIfDegraded()
            Task { @MainActor in
                refreshMicrophoneMenu()
                // A device came back while the state line still said
                // "no microphone" — let it offer dictation again. Guarded
                // inside the controller: only that message is replaced.
                if micStore.effective.device != nil {
                    menuBar.clearNoMicrophone()
                }
            }
        }
        // Mid-utterance loss and recovery, from the capture itself. Without
        // this, a degrade is invisible: the overlay keeps animating bars over
        // silence and the menu keeps claiming "● recording". Fired on the
        // capture's rebuild queue — hop before UI.
        capture.onTransition = { transition in
            Task { @MainActor in
                switch transition {
                case .degraded:
                    overlay?.show(.error("no microphone"))
                    menuBar.setNoMicrophone()
                case .resumed:
                    overlay?.show(.recording)
                    menuBar.setRecording(true)
                }
            }
        }

        let modeOverride = mode
        let session = Pipeline.makeSession(
            config: config,
            apiKey: apiKey,
            mlx: mlx,
            apple: Pipeline.appleFormatter(),
            registry: registry,
            dictionary: {
                unsavedCorrections.applied(
                    to: LocalDictionary.load(from: dictionaryURL))
            },
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
                        // A stderr line is invisible for a menu-bar daemon;
                        // the spec's contract is an on-screen answer: an
                        // error pill (self-hiding — there is no release-path
                        // cleanup coming for a recording that never started)
                        // and a menu state line that stops promising
                        // dictation. The Microphone submenu already explains
                        // itself: the store repainted it "no microphone
                        // connected" when the last device left.
                        FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
                        MainActor.assumeIsolated {
                            overlay?.show(.error("no microphone"))
                            menuBar.setNoMicrophone()
                        }
                    }
                case .released:
                    let samples = capture.stop()
                    // Sampled here — on the main thread, where the AppKit read
                    // is legal — and then carried by value into this utterance's
                    // task. Not read later from a shared slot: formatting starts
                    // seconds from now, and by then a user who has begun their
                    // next utterance would have moved the answer on.
                    let frontmostBundleID: String? = MainActor.assumeIsolated {
                        let id = FrontmostApp.bundleID
                        overlay?.show(.transcribing)
                        menuBar.setTranscribing()
                        return id
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
                                text, override: modeOverride, manual: nil,
                                frontmostBundleID: frontmostBundleID)
                            let total = Date().timeIntervalSince(started)
                            if cleaned.isEmpty, !text.isEmpty {
                                // An empty result for a non-empty transcript is
                                // `process`'s report that the request was
                                // withdrawn. Logged as its own thing: an `↦`
                                // line with nothing after it would read as "the
                                // formatter deleted your sentence".
                                FileHandle.standardError.write(Data(
                                    String(format: "⨯ %.2fs · cancelled; nothing injected\n",
                                           total).utf8
                                ))
                            } else if !cleaned.isEmpty, cleaned != text {
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
            "listening on \(chosenHotkey.label) hold · model: \(chosenModel.id) · ^C to quit\n".utf8
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
        abstract: "Manage transcription and formatting models.",
        subcommands: [List.self, Download.self, DownloadFormatter.self]
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

    /// The one-time fetch of the local formatting model.
    ///
    /// A separate subcommand rather than an entry in `ModelRegistry`, because
    /// that registry is typed `TranscriptionModel` — engine, WhisperKit id,
    /// languages — and none of those fields mean anything for a formatting
    /// model. Bending the type to fit would make `parrot models list` offer a
    /// model that `--model` cannot accept.
    ///
    /// Explicit and user-initiated, mirroring `parrot models download`: a
    /// default install performs no network I/O for formatting, and 0.9GB is not
    /// something to fetch behind a user's back on first launch.
    struct DownloadFormatter: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "download-formatter",
            abstract: "Download the local formatting model (~900 MB, one time)."
        )

        func run() throws {
            if MLXModel.isPresent {
                print("✓ \(MLXModel.id) already at \(MLXModel.directory.path)")
                return
            }
            print("downloading \(MLXModel.id) (~\(MLXModel.sizeMB) MB)...")

            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var capturedError: Error?
            nonisolated(unsafe) var directory: URL?
            Task.detached {
                do {
                    directory = try await MLXModel.download { fraction in
                        FileHandle.standardError.write(Data(
                            String(format: "\r  %3.0f%%", fraction * 100).utf8))
                    }
                } catch {
                    capturedError = error
                }
                sem.signal()
            }
            sem.wait()
            FileHandle.standardError.write(Data("\r".utf8))
            if let capturedError {
                // The type name only, following the rule the formatters follow:
                // a foreign error's message is a channel its producer controls,
                // and a Hub error can quote URLs and paths.
                print("download failed: \(type(of: capturedError))")
                throw ExitCode(1)
            }
            print("✓ \(MLXModel.id) ready at \(directory?.path ?? MLXModel.directory.path)")
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
