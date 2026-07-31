import AppKit
import ArgumentParser
import AraCore
import Foundation

@main
struct Ara: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ara",
        abstract: "Minimal macOS dictation daemon. Hold Fn, speak, release.",
        // Read out of Ara.app's Info.plist, which scripts/package-app.sh
        // stamps from the VERSION file. A source build has no bundle and says
        // so rather than claiming a release number it cannot know.
        version: AraVersion.current,
        subcommands: [Run.self, Setup.self, Doctor.self, Models.self,
                      DictionaryCommand.self, SnippetsCommand.self, Install.self],
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

    @Flag(name: .long, help: "Write each capture to /tmp/ara-last.wav for inspection.")
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

    // Optional for `hotkey`'s reason: `nil` means "the user said nothing",
    // and only then does `config.inject` get a say.
    @Option(
        name: .long,
        help: "How transcripts are delivered. One of: \(InjectionSetting.valueNames). Defaults to config.inject, then auto — paste into terminals and Electron apps, type everywhere else."
    )
    var inject: InjectionSetting?

    func run() throws {
        if !skipDoctor {
            let checks = DoctorReport.run()
            if !DoctorReport.allOK(checks) {
                // Launched from Finder there is no stderr to read and, being
                // `LSUIElement`, no window and no Dock icon either — the app
                // would exit and the user would see *nothing at all*. That is
                // exactly what happens on a fresh install: TCC files the
                // microphone and accessibility grants under the bundle's
                // identity, so a copy that has never been granted anything
                // fails these checks on its first launch. (Run the same binary
                // from a terminal and it inherits the terminal's grants, which
                // is why this does not reproduce there.)
                if !StartupFailure.hasReadableTerminal() {
                    StartupFailure.presentAndExit(checks)
                }
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

        // CLI flags > config > defaults, for all of these. The rules live in
        // `StartupResolution` so they are covered by tests; `run()` is not.
        let chosenHotkey = StartupResolution.hotkey(flag: hotkey, config: config.hotkey)
        let injectionSetting = StartupResolution.injection(flag: inject, config: config.inject)
        let chosenModel: TranscriptionModel
        switch StartupResolution.model(flag: model, config: config.model) {
        case .chosen(let m):
            chosenModel = m
        case .unknownFlag(let id):
            FileHandle.standardError.write(Data("unknown model: \(id)\n".utf8))
            FileHandle.standardError.write(Data("run `ara models list` to see options.\n".utf8))
            throw ExitCode(1)
        case .noModelsRegistered:
            FileHandle.standardError.write(Data("no models registered\n".utf8))
            throw ExitCode(1)
        }

        // The language plan is resolved once here so the one thing it can
        // report — a non-English language asked of an English-only model —
        // is said at startup rather than discovered as English transcripts.
        // The transcriber re-resolves it per utterance, because the Language
        // submenu can change the setting live.
        if let warning = LanguagePlan.resolve(model: chosenModel,
                                              setting: config.language).warning {
            FileHandle.standardError.write(Data("config: \(warning)\n".utf8))
        }

        // One hot-reloaded source for both halves of custom vocabulary. The
        // transcriber uses canonical spellings as decoder hints, then the
        // session deterministically replaces any variants Whisper still
        // emits. Failed menu saves remain active in both places until quit.
        let dictionaryURL = LocalDictionary.defaultURL
        let snippetsURL = Snippets.defaultURL
        let unsavedCorrections = UnsavedCorrections()
        let dictionarySource: @Sendable () -> LocalDictionary = {
            unsavedCorrections.applied(
                to: LocalDictionary.load(from: dictionaryURL))
        }
        let transcriber = WhisperKitTranscriber(model: chosenModel,
                                                language: config.language,
                                                vocabularyHints: {
                                                    dictionarySource().vocabularyHints()
                                                })
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
        // One injector for the whole process, because it is stateful: the
        // pasteboard snapshot and the generation counter that let overlapping
        // dictations share one restore live in it. `pasteRestoreMs` arrives
        // already clamped by `Config.load`.
        let pasteInjector = MainActor.assumeIsolated {
            PasteInjector.system(settleDelayMs: config.pasteRestoreMs)
        }
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
        // a menu bar item that says what the daemon is doing.
        let menuBar = MainActor.assumeIsolated {
            MenuBarController(modelID: chosenModel.id, hotkeyLabel: hotkeyLabel,
                              modeID: startingMode)
        }

        // Owns the state line and the overlay for as long as the daemon cannot
        // dictate. The hotkey arms immediately now — a press during warm-up is
        // answered with this status rather than with silence — so something has
        // to hold the answer, and it has to be main-actor state: the warm-up
        // task hops in to write it, and the press handler (which AppKit already
        // delivers on the main queue) reads it.
        //
        // The first phase is decided from disk rather than waited for. The
        // download's own first report cannot arrive until the hub has answered
        // with a file listing, and calling a warm start's etag check
        // "downloading" for those seconds would be a claim the pill then has to
        // take back.
        let warmup = MainActor.assumeIsolated {
            WarmupState(
                status: WarmupStatus(
                    modelID: chosenModel.id,
                    transcriber: WhisperModelStore.isPresent(chosenModel)
                        ? .loading : .downloading(percent: nil),
                    formatter: warmsMLX ? .loading : .notLoading),
                overlay: overlay,
                menuBar: menuBar,
                readyMessage: WarmupStatus.readyMessage(hotkeyLabel: hotkeyLabel))
        }

        // The session's manual mode override, main-actor state like the menu
        // that sets it: the Mode submenu writes it, and the released-handler
        // reads it at the same main-actor sample point as the frontmost app —
        // by value, into that utterance. Deliberately not persisted: it is a
        // session override, and `config.mode` stays the startup default.
        let manualMode = MainActor.assumeIsolated { ManualMode() }

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
            menuBar.onEditDictionary = {
                // The file is the editor and the per-utterance load is the
                // apply mechanism — saving in whatever opens is the whole
                // "apply" story. All this does is guarantee there is a file
                // to open: a fresh install gets the starter (the README's
                // own example entry, so the format explains itself), an
                // existing file — even a broken one — is never touched.
                do {
                    try LocalDictionary.createStarterFileIfAbsent(at: dictionaryURL)
                } catch {
                    FileHandle.standardError.write(Data(
                        "dictionary: could not create \(dictionaryURL.path) (\(type(of: error)))\n"
                            .utf8))
                    return
                }
                if !NSWorkspace.shared.open(dictionaryURL) {
                    FileHandle.standardError.write(Data(
                        "dictionary: no editor opened \(dictionaryURL.path)\n".utf8))
                }
            }
            menuBar.onEditSnippets = {
                // The dictionary's contract, for the other hand-edited file.
                do {
                    try Snippets.createStarterFileIfAbsent(at: snippetsURL)
                } catch {
                    FileHandle.standardError.write(Data(
                        "snippets: could not create \(snippetsURL.path) (\(type(of: error)))\n"
                            .utf8))
                    return
                }
                if !NSWorkspace.shared.open(snippetsURL) {
                    FileHandle.standardError.write(Data(
                        "snippets: no editor opened \(snippetsURL.path)\n".utf8))
                }
            }
            // The check shows what the config resolved at startup — which is
            // what the running session is actually doing. A pick persists via
            // the same one-key rewrite as the microphone, but unlike the
            // microphone it cannot apply live: the session's intensity was
            // stamped when it was built, so the submenu's caption (and the
            // model's doc) say "applies on restart". The check moves only
            // when the pick actually landed in the file — a failed write
            // changes nothing on restart, so re-checking would be a lie.
            let startupCleanup = config.cleanup
            menuBar.setCleanupMenu(CleanupMenuModel.compute(current: startupCleanup))
            menuBar.onCleanupPicked = { intensity in
                do {
                    try Config.persistCleanup(intensity)
                    menuBar.setCleanupMenu(CleanupMenuModel.compute(current: intensity))
                } catch {
                    let reason = (error as? Config.PersistError)?.description
                        ?? "\(type(of: error))"
                    FileHandle.standardError.write(Data(
                        "config: cleanup choice not saved (\(reason)); the saved setting is unchanged\n"
                            .utf8))
                }
            }

            // The Language submenu — the *other* live pick, and the only one
            // that both applies live and persists. The transcriber builds its
            // `DecodingOptions` inside `transcribe`, so `setLanguage` lands
            // between utterances and the next dictation uses it; the config
            // write only decides what the next launch starts with. Ordered
            // like the microphone for the same reason: the live apply cannot
            // fail, so it happens first and holds until quit even when the
            // file cannot be written.
            let repaintLanguageMenu: @MainActor (LanguageSetting) -> Void = { current in
                menuBar.setLanguageMenu(LanguageMenuModel.compute(
                    model: chosenModel, current: current))
            }
            repaintLanguageMenu(config.language)
            menuBar.onLanguagePicked = { setting in
                Task { await transcriber.setLanguage(setting) }
                repaintLanguageMenu(setting)
                do {
                    try Config.persistLanguage(setting)
                } catch {
                    let reason = (error as? Config.PersistError)?.description
                        ?? "\(type(of: error))"
                    FileHandle.standardError.write(Data(
                        "config: language choice not saved (\(reason)); it applies until quit\n"
                            .utf8))
                }
            }

            // The Mode submenu — the one live pick. It writes the session
            // override the released-handler samples per utterance, and never
            // the config: `mode` in config.json stays the startup default
            // (see ModeMenuModel for why). Repainted on every pick so the
            // check follows the override; the `mode:` label line keeps
            // showing what each utterance actually resolved.
            menuBar.setModeMenu(ModeMenuModel.compute(
                modes: registry.all, manual: manualMode.id))
            menuBar.onModePicked = { id in
                manualMode.id = id
                menuBar.setModeMenu(ModeMenuModel.compute(
                    modes: registry.all, manual: id))
            }

            // Model, Hotkey, Engine: the cleanup pattern verbatim — the check
            // shows what the running daemon resolved at startup, a pick
            // persists via the same one-key rewrite, and the check moves only
            // when the pick actually landed in the file (a failed write
            // changes nothing on restart, so re-checking would be a lie).
            // Each submenu's caption owns the "applies on restart" truth.
            let repaintModelMenu: @MainActor (String) -> Void = { current in
                menuBar.setModelMenu(ModelMenuModel.compute(
                    models: ModelRegistry.shared,
                    currentID: current,
                    downloaded: WhisperModelStore.isPresent,
                    formatterDownloaded: MLXModel.isPresent))
            }
            repaintModelMenu(chosenModel.id)
            menuBar.onModelPicked = { id in
                do {
                    try Config.persistModel(id)
                    repaintModelMenu(id)
                } catch {
                    let reason = (error as? Config.PersistError)?.description
                        ?? "\(type(of: error))"
                    FileHandle.standardError.write(Data(
                        "config: model choice not saved (\(reason)); the saved setting is unchanged\n"
                            .utf8))
                }
            }

            menuBar.setHotkeyMenu(HotkeyMenuModel.compute(current: chosenHotkey))
            menuBar.onHotkeyPicked = { picked in
                do {
                    try Config.persistHotkey(picked)
                    menuBar.setHotkeyMenu(HotkeyMenuModel.compute(current: picked))
                } catch {
                    let reason = (error as? Config.PersistError)?.description
                        ?? "\(type(of: error))"
                    FileHandle.standardError.write(Data(
                        "config: hotkey choice not saved (\(reason)); the saved setting is unchanged\n"
                            .utf8))
                }
            }

            // `hasAPIKey` is the startup keychain read's result, carried by
            // value — the menu must never read the keychain itself, because
            // that read can raise a blocking prompt (see Keychain's doc).
            let hasAPIKey = apiKey != nil
            menuBar.setEngineMenu(EngineMenuModel.compute(
                current: config.engine, hasAPIKey: hasAPIKey))
            menuBar.onEnginePicked = { picked in
                do {
                    try Config.persistEngine(picked)
                    menuBar.setEngineMenu(EngineMenuModel.compute(
                        current: picked, hasAPIKey: hasAPIKey))
                } catch {
                    let reason = (error as? Config.PersistError)?.description
                        ?? "\(type(of: error))"
                    FileHandle.standardError.write(Data(
                        "config: engine choice not saved (\(reason)); the saved setting is unchanged\n"
                            .utf8))
                }
            }

            // Start at Login: the checkmark is always a fresh disk read —
            // after success *and* failure — never an assumption about what
            // the toggle did. Install remains the single source of truth for
            // the plist and the launchctl choreography; the notice after
            // enabling is honest about what `installAgent` actually does
            // (RunAtLoad + bootstrap start the login copy *now*).
            menuBar.setStartAtLogin(Install.isInstalled())
            menuBar.onStartAtLoginToggled = { enable in
                do {
                    if enable {
                        // The notice reports what actually happened: a
                        // bootstrap can fail while the plist write succeeds,
                        // and claiming "started now" on that outcome would be
                        // a promise the code declined to verify.
                        let outcome = try Install.installAgent()
                        menuBar.showNotice(
                            title: "Start at Login enabled",
                            message: Install.startNotice(for: outcome))
                    } else {
                        try Install.uninstallAgent()
                    }
                } catch {
                    // `localizedDescription` so an `InstallError` renders its
                    // sentence; a foreign error still degrades to something,
                    // and the type name goes to stderr where a developer can
                    // find it rather than into the user's dialog.
                    FileHandle.standardError.write(Data(
                        "start at login failed: \(type(of: error))\n".utf8))
                    menuBar.showNotice(
                        title: enable
                            ? "Could not enable Start at Login"
                            : "Could not disable Start at Login",
                        message: error.localizedDescription)
                }
                menuBar.setStartAtLogin(Install.isInstalled())
            }

            // Run Diagnostics: the checks read disk and spawn `defaults`/`ps`
            // (and touch no keychain — DoctorReport.run has no keychain
            // check), so they run off the main thread; only the alert hops
            // back.
            menuBar.onRunDiagnostics = {
                Task.detached {
                    let text = DoctorReport.rendered(DoctorReport.run())
                    await MainActor.run {
                        menuBar.showDiagnosticsReport(text)
                    }
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
            dictionary: dictionarySource,
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

        // The hotkey monitor starts here, before the warm-up rather than after
        // it. Dictating into a cold transcriber is still impossible — the gate
        // below turns a press away — but *silence* is not the way to say so:
        // a first run on the large model spends over a minute downloading, and
        // a user with their hands on the keyboard never sees the menu bar.
        //
        // Recording remains gated on `warmup.isWarming`, which is defined as
        // "there is still something to say", so the check the press makes and
        // the sentence the pill shows cannot disagree. `WarmupState.finish()`
        // is the only thing that opens the gate, and only the warm-up task's
        // completion calls it.
        do {
            try monitor.start { event in
                switch event {
                case .pressed:
                    // The warm-up answer, and nothing else: no capture, no
                    // recording sound, no menu state change beyond the line
                    // the warm-up already owns.
                    if MainActor.assumeIsolated({ warmup.showStatusIfWarming() }) {
                        return
                    }
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
                    // The other half of the gate, and the reason it is a latch
                    // rather than a second `isWarming` check: the warm-up can
                    // finish while the key is still held, and a release that
                    // then fell through would stop a capture that was never
                    // started. The press that was turned away owns this
                    // release; it takes the pill down and returns.
                    if MainActor.assumeIsolated({ warmup.hideStatusIfShowing() }) {
                        return
                    }
                    let samples = capture.stop()
                    // Sampled here — on the main thread, where the AppKit read
                    // is legal — and then carried by value into this utterance's
                    // task. Not read later from a shared slot: formatting starts
                    // seconds from now, and by then a user who has begun their
                    // next utterance would have moved the answer on. The manual
                    // mode override rides the same sample for the same reason:
                    // a pick made while this utterance formats belongs to the
                    // next one.
                    let (frontmostBundleID, manualModeID): (String?, String?)
                        = MainActor.assumeIsolated {
                        let id = FrontmostApp.bundleID
                        overlay?.show(.transcribing)
                        menuBar.setTranscribing()
                        return (id, manualMode.id)
                    }
                    let seconds = Double(samples.count) / AudioCapture.targetSampleRate
                    let rms = computeRMS(samples)
                    FileHandle.standardError.write(Data(
                        String(format: "○ captured %.2fs · rms %.3f\n", seconds, rms).utf8
                    ))
                    if dumpWav, !samples.isEmpty {
                        let path = "/tmp/ara-last.wav"
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
                                text, override: modeOverride, manual: manualModeID,
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
                                // prevent, so the guard is the point, not
                                // tidiness — and it guards *both* delivery
                                // paths (each also refuses "" on its own).
                                if !cleaned.isEmpty {
                                    // Method chosen from the same by-value
                                    // bundle ID mode resolution used: the app
                                    // the utterance was spoken into, not
                                    // whatever is frontmost seconds later.
                                    switch InjectionPolicy.method(
                                        setting: injectionSetting,
                                        frontmostBundleID: frontmostBundleID)
                                    {
                                    case .type: TextInjector.inject(cleaned)
                                    case .paste: pasteInjector.inject(cleaned)
                                    }
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
            FileHandle.standardError.write(Data("run `ara setup` to configure permissions.\n".utf8))
            // `ExitCode` again, which the old ordering could not use: the tap
            // is now registered before `app.run()` rather than from inside a
            // pumping run loop, so there is a `throws` path to ride out on.
            // The user-visible outcome — two stderr lines and status 1 — is
            // unchanged, and it now happens in milliseconds rather than after
            // a model download.
            throw ExitCode(1)
        }

        // Opens the warm-up gate: from here a press records. Runs on the main
        // actor only once the transcriber is warm — never before. Dictating
        // into a cold transcriber is the reason startup used to block, and
        // that ordering is the part of the old design worth keeping; only the
        // *feedback* moved earlier, never the recording.
        let declareReady: @MainActor () -> Void = {
            warmup.finish()
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
        // floor.
        //
        // The two loads run CONCURRENTLY: measured on this machine (M3 Pro),
        // Whisper's prewarm takes ~4.0s warm and MLX ~1.0s, and running them
        // back-to-back put every millisecond of the second load on the
        // startup clock. Concurrent, startup costs max(4.0, 1.0) not the sum
        // — MLX loads entirely inside Whisper's shadow. They touch different
        // engines (ANE vs Metal) and different code, and each runs off the
        // cooperative pool internally, so the overlap is contention-free.
        // The MLX result is awaited even when the transcriber failed — the
        // process is about to exit then, and abandoning the load would leak
        // nothing, but awaiting keeps this block free of unstructured
        // abandonment. Failure precedence is unchanged: fatal transcriber
        // first, formatter warning second.
        Task.detached {
            async let transcriberResult: Error? = {
                do {
                    // Already coalesced to one report per whole percent by the
                    // transcriber, so this is one hop per visible change and
                    // not one per byte. The callback itself arrives on a
                    // URLSession thread; the hop is the whole body.
                    try await transcriber.warmUp { phase in
                        Task { @MainActor in warmup.setTranscriber(phase) }
                    }
                    // The transcriber is warm *before* the gate opens, and
                    // that gap is the point: the formatting model may still be
                    // loading, and the pill should say so rather than keep
                    // naming a model that is already in memory.
                    await MainActor.run { warmup.setTranscriber(nil) }
                    return nil
                } catch {
                    return error
                }
            }()
            async let mlxResult: Error? = {
                guard warmsMLX else { return nil }
                FileHandle.standardError.write(Data(
                    "loading \(MLXModel.id) (formatting — the first run can take a while)...\n"
                        .utf8))
                let started = Date()
                do {
                    try await mlx.warmUp()
                    FileHandle.standardError.write(Data(String(
                        format: "✓ %@ ready (%.1fs)\n",
                        MLXModel.id, Date().timeIntervalSince(started)).utf8))
                    await MainActor.run { warmup.setFormatter(.ready) }
                    return nil
                } catch {
                    // Ready in the sense the pill cares about: there is
                    // nothing left to wait for. The failure is reported below,
                    // where the precedence between the two is decided.
                    await MainActor.run { warmup.setFormatter(.ready) }
                    return error
                }
            }()
            let warmupError = await transcriberResult
            let mlxWarmupError = await mlxResult
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
                declareReady()
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

/// The Mode submenu's session override: `nil` is Auto (the resolver's
/// frontmost-app rule decides), a mode id pins every following utterance
/// until changed or quit. Main-actor because both its writer (the menu) and
/// its reader (the released-handler's sample point) already live there.
/// Never persisted — see `ModeMenuModel`'s doc for why a session override
/// must not rewrite the config's startup default.
@MainActor
private final class ManualMode {
    var id: String?
}

/// The warm-up's live state and everything on screen that reflects it.
///
/// Main-actor for `ManualMode`'s reason: its writers (the warm-up task, which
/// hops in) and its reader (the hotkey's press handler, which AppKit already
/// delivers on the main queue) both belong there. All the *rules* — which
/// phase gets the line, what the line says, whether a press should record —
/// live in `WarmupStatus`, where they are unit-tested; this class is the
/// mutable slot around them plus two AppKit calls.
///
/// The gate it implements is deliberately one-way: `isWarming` opens only in
/// `finish()`, which only the warm-up task's completion calls, and phase
/// updates are ignored afterwards so an out-of-order hop from a `URLSession`
/// thread cannot close it again behind a recording.
@MainActor
private final class WarmupState {
    private var status: WarmupStatus
    private let overlay: RecordingOverlay?
    private let menuBar: MenuBarController
    private let readyMessage: String
    /// Whether the pill is currently showing warm-up status. Set by a press
    /// the gate turned away and cleared by that press's release — so it is
    /// also the latch that tells the release handler the press was never a
    /// recording, which `isWarming` cannot: the warm-up may have finished
    /// while the key was held.
    private var showingStatus = false
    /// One-way, for the reason in the type's doc.
    private var transcriberSettled = false

    init(status: WarmupStatus, overlay: RecordingOverlay?,
         menuBar: MenuBarController, readyMessage: String) {
        self.status = status
        self.overlay = overlay
        self.menuBar = menuBar
        self.readyMessage = readyMessage
        // The state line's first value. From here the warm-up owns it until
        // `MenuBarController.setReady()`.
        if let message = status.message { menuBar.setWarmingUp(message) }
    }

    /// A hotkey press. Answers `true` when it was consumed as a status
    /// display — which is exactly when recording is not allowed yet.
    func showStatusIfWarming() -> Bool {
        // `blocksDictation`, not `message`: the formatting model may still be
        // loading and still have a line to show, but it does not gate speech.
        guard status.blocksDictation, let message = status.message else {
            return false
        }
        showingStatus = true
        overlay?.show(.warmingUp(message))
        return true
    }

    /// The matching release. Answers `true` when it belonged to a press the
    /// gate turned away, and so must not reach the capture.
    func hideStatusIfShowing() -> Bool {
        guard showingStatus else { return false }
        showingStatus = false
        overlay?.hide()
        return true
    }

    /// `nil` means the transcriber is warm — see `WarmupStatus.transcriber`.
    ///
    /// Each report reaches the main actor on its own `Task`, and those arrive
    /// unordered — which is why `transcriberSettled` exists at all. The same
    /// reordering can land 45% after 46%, so the percentage is filtered here
    /// as well as coalesced at the source: a number that walks backwards on
    /// screen reads as a stall or a bug, and the coalescer's monotonicity
    /// only ever applied to what it emitted, not to what arrived.
    func setTranscriber(_ phase: TranscriberWarmup?) {
        guard !transcriberSettled else { return }
        if case .downloading(let incoming?) = phase,
           case .downloading(let current?) = status.transcriber,
           incoming < current {
            return
        }
        if phase == nil { transcriberSettled = true }
        status.transcriber = phase
        repaint()
    }

    func setFormatter(_ phase: WarmupStatus.Formatter) {
        status.formatter = phase
        repaint()
    }

    /// The warm-up is over and a press records from here.
    func finish() {
        transcriberSettled = true
        status.transcriber = nil
        status.formatter = .ready
        // Only if the user is watching: they are holding the key at the moment
        // the wait ended, and the pill vanishing under their thumb would read
        // as a crash while a stale "loading…" would be a lie. Their release
        // takes it down through the ordinary path.
        if showingStatus { overlay?.show(.warmingUp(readyMessage)) }
    }

    private func repaint() {
        guard let message = status.message else { return }
        menuBar.setWarmingUp(message)
        if showingStatus { overlay?.show(.warmingUp(message)) }
    }
}

/// Read-only in v1: the file is the editor (see "Edit dictionary…" in the
/// menu), so the CLI's job is showing what is there and where — mutation
/// flags would be a second editor to keep honest.
///
/// Named `DictionaryCommand` rather than `Dictionary` so the standard
/// library's type keeps its name in this file; the user-facing name comes
/// from the configuration.
struct DictionaryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dictionary",
        abstract: "Show the custom dictionary: each correction, and the file that holds them."
    )

    func run() throws {
        let url = LocalDictionary.defaultURL
        // The tolerant per-utterance loader, deliberately: what this prints
        // is what the next dictation will actually use, and a broken file
        // explains itself through load's own stderr warning.
        let dictionary = LocalDictionary.load(from: url)
        for line in dictionary.listingLines(path: url.path) {
            print(line)
        }
    }
}

/// `DictionaryCommand`'s twin for the other hand-edited file.
struct SnippetsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snippets",
        abstract: "Show the voice snippets: each trigger, and the file that holds them."
    )

    func run() throws {
        let url = Snippets.defaultURL
        let snippets = Snippets.load(from: url)
        for line in snippets.listingLines(path: url.path) {
            print(line)
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
            // Rows, including the on-disk column, come from `ModelListing` —
            // the pick made here decides whether the next launch spends a
            // minute and a half downloading, so the column that says so is
            // unit-tested rather than assembled in a print loop.
            for line in ModelListing.lines(models: ModelRegistry.shared,
                                           isPresent: WhisperModelStore.isPresent) {
                print(line)
            }
            print("★ recommended · a model not on disk is downloaded by the "
                + "next launch's warm-up")
        }
    }

    /// The one-time fetch of the local formatting model.
    ///
    /// A separate subcommand rather than an entry in `ModelRegistry`, because
    /// that registry is typed `TranscriptionModel` — engine, WhisperKit id,
    /// languages — and none of those fields mean anything for a formatting
    /// model. Bending the type to fit would make `ara models list` offer a
    /// model that `--model` cannot accept.
    ///
    /// Explicit and user-initiated, mirroring `ara models download`: a
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
                do {
                    // The same percentage the overlay shows during a daemon
                    // warm-up, on the terminal that asked for the download —
                    // `download-formatter`'s line, for the other model kind.
                    try await t.warmUp { phase in
                        guard case .downloading(let percent?) = phase else { return }
                        FileHandle.standardError.write(Data(
                            String(format: "\r  %3d%%", percent).utf8))
                    }
                } catch {
                    capturedError = error
                }
                sem.signal()
            }
            sem.wait()
            FileHandle.standardError.write(Data("\r".utf8))
            if let e = capturedError { throw e }
        }
    }
}
