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

    // Off by default because stderr is a file under launchd, and a file that
    // quotes the transcript accumulates everything ever dictated. The install
    // command never writes this flag into the LaunchAgent plist.
    @Flag(name: .long,
          help: "Print full transcript text to stderr. Everything you dictate will appear in any log that captures stderr.")
    var echoTranscripts: Bool = false

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
        // The formatting model is loaded at startup too — before the hotkey
        // arms, and never on the dictation path: a warm load is ~1s and a cold
        // one ~38s against a 2500ms per-engine deadline, so a lazy first load
        // would be abandoned every time — and abandoning compute-bound work
        // does not stop it, it only stops waiting for it.
        //
        // Built unconditionally so the chain always has the candidate, but only
        // *warmed* under the engines that will consult it: `apple`, `rules` and
        // `off` would otherwise pay a second of startup and 0.9GB of resident
        // memory for a model they never call.
        let mlx = Pipeline.mlxFormatter()
        let warmsMLX = config.engine == .mlx || config.engine == .cloud

        // AppKit before the warm-up, not after it. The status item below must
        // exist while models load — the whole point of the non-blocking warm-up
        // is that a LaunchAgent user sees *something* during a cold download —
        // and AppKit's one-time initialisation must happen on the main thread,
        // before the warm-up task spawns threads that might touch frameworks
        // it owns.
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
        let echoTranscripts = self.echoTranscripts
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
        // Created before the warm-up starts, so the first thing a user sees is
        // a menu bar item that says what the daemon is doing. Until the models
        // are warm the hotkey is not armed and holding it does nothing; the
        // state line is the explanation.
        let menuBar = MainActor.assumeIsolated {
            let controller = MenuBarController(modelID: chosenModel.id, hotkeyLabel: hotkeyLabel,
                                               modeID: startingMode)
            controller.setWarmingUp()
            return controller
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
                // The merge-and-persist decisions live in
                // `UnsavedCorrections.save`, under test; what remains here is
                // the stderr line, following the microphone pattern above.
                if let error = unsavedCorrections.save(
                    heard: heard, canonical: canonical, to: dictionaryURL)
                {
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

        // Installed before the warm-up rather than after the hotkey arms, so a
        // ^C during a long first-run model download still shuts down cleanly.
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            monitor.stop()
            NSApp.terminate(nil)
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        // Arms the hotkey and declares the daemon ready. Runs on the main
        // actor only once the transcriber is warm — never before: dictating
        // into a cold transcriber is the reason startup used to block, and
        // that ordering is the part of the old design worth keeping.
        let armHotkey: @MainActor () -> Void = {
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
                                    (TranscriptLog.raw(seconds: transcribed, text: text,
                                                       echoTranscript: echoTranscripts) + "\n").utf8
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
                                        (TranscriptLog.cleaned(seconds: total, text: cleaned,
                                                               echoTranscript: echoTranscripts) + "\n").utf8
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
                // Not `ExitCode`: the run loop is already pumping, so there is
                // no `throws` path left to ride out of `run()` on.
                Darwin.exit(1)
            }
            menuBar.setReady()
            FileHandle.standardError.write(Data(
                "listening on \(chosenHotkey.label) hold · model: \(chosenModel.id) · ^C to quit\n".utf8
            ))
        }

        // The warm-up itself, off the main thread so the status item stays
        // alive and responsive while models load — a cold download takes
        // minutes, and the old semaphore here froze the process through all
        // of it. The completion hops to the main actor to arm the hotkey;
        // failure semantics are unchanged from the blocking design: a cold
        // transcriber is fatal, a cold formatter is a warning and the rules
        // floor. (Skipping the formatter after a fatal transcriber failure is
        // the one difference — there is no point loading 0.9GB for a process
        // about to exit.)
        Task.detached {
            var transcriberFailure: Error?
            do {
                try await transcriber.warmUp()
            } catch {
                transcriberFailure = error
            }
            var mlxFailure: Error?
            if transcriberFailure == nil, warmsMLX {
                FileHandle.standardError.write(Data(
                    "loading \(MLXModel.id) (formatting — the first run can take a while)...\n"
                        .utf8))
                let started = Date()
                do {
                    try await mlx.warmUp()
                    FileHandle.standardError.write(Data(String(
                        format: "✓ %@ ready (%.1fs)\n",
                        MLXModel.id, Date().timeIntervalSince(started)).utf8))
                } catch {
                    mlxFailure = error
                }
            }
            let warmupError = transcriberFailure
            let mlxWarmupError = mlxFailure
            await MainActor.run {
                if let warmupError {
                    FileHandle.standardError.write(Data("warmup failed: \(warmupError)\n".utf8))
                    Darwin.exit(1)
                }
                // A warning, not a failure. Transcription without formatting
                // is the whole app minus its polish; formatting without
                // transcription is nothing. So a missing Whisper model is
                // fatal above and a missing formatting model is one line
                // here, with the command that fixes it.
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
                armHotkey()
            }
        }

        // `app.run()` never returns, but ARC is still free to release locals
        // after their last static use — and the event tap holds an
        // *unretained* pointer to `monitor` (see `HotkeyMonitor.start`), so
        // its deallocation would leave the tap callback dangling. Pin the
        // roots of the object graph for as long as the application runs.
        withExtendedLifetime((monitor, sigint, menuBar)) {
            app.run()
        }
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
