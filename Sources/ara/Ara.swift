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
        // First line of the daemon, because a crash before it is a crash with
        // nothing to look at — which is the state a reported segfault was
        // found in. See `CrashBacktrace`.
        CrashBacktrace.install()

        // The permissions, before anything else looks at anything. Both gate
        // the whole product — no microphone is no audio, and no accessibility
        // means `HotkeyMonitor.start` cannot create its tap at all — and
        // neither can be repaired inside a running process: macOS decides a
        // process's accessibility trust when it starts. So a launch that finds
        // one missing spends itself asking for it and restarts.
        //
        // `--skip-doctor` turns this off with the rest of the preflight. It is
        // the flag for a developer who knows what is granted to what, and a
        // window is a worse interruption to them than a failed tap.
        if !skipDoctor {
            let microphone = SetupPermissions.microphone()
            let accessibility = SetupPermissions.accessibility()
            if microphone != .granted || !accessibility {
                MainActor.assumeIsolated {
                    FirstRunSetup.runPermissions(
                        step: microphone == .granted ? .accessibility : .microphone)
                }
            }
        }

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
        let transcriber = WhisperKitTranscriber(model: chosenModel,
                                                language: config.language)
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
        let warmsMLX = config.engine == .mlx || config.engine == .cloud

        // AppKit before the warm-up, not after it. The status item below must
        // exist while models load — the whole point of the non-blocking warm-up
        // is that a LaunchAgent user sees *something* during a cold download —
        // and AppKit's one-time initialisation must happen on the main thread,
        // before the warm-up task spawns threads that might touch frameworks
        // it owns.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // The Dock icon is not set here. A single binary is not a bundle and
        // has no icon of its own, but there is also no Dock tile to put one on
        // until something makes ara a regular app — so `SetupWindow` sets it
        // at that moment. Setting it here instead was tried, and the generic
        // "exec" tile appeared anyway.

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
        // The model half of the first run: the download and the compile, which
        // are the same warm-up every launch runs and the only two steps left
        // by the time the permissions are settled. `nil` on every launch after
        // the first, which is when the menu bar and the pill take the job
        // back.
        //
        // The permissions are read again rather than assumed from the branch
        // above: `--skip-doctor` skips that branch entirely, and a window that
        // opened on a stale assumption would sit on a step it cannot advance.
        let setupState = SetupFlow.State(
            microphone: SetupPermissions.microphone(),
            accessibility: SetupPermissions.accessibility(),
            modelPresent: WhisperModelStore.isPresent(chosenModel),
            setupCompleted: config.setupCompleted)
        let makeSetupWindow: @MainActor () -> SetupWindow? = {
            let window = SetupWindow()
            // Not activating: this one opens in the middle of a launch the
            // user has already walked away from, and it has nothing to ask
            // them for. Closing it is equally cheap — the daemon carries on
            // compiling and the menu bar still says what it is doing — so
            // there is nothing to report and nothing to stop.
            window.show(step: .prepare, activating: false)
            FileHandle.standardError.write(Data(
                ("opening the setup window: this build has to be compiled for "
                    + "this Mac once\n").utf8))
            return window
        }
        let openSetupWindow: (@MainActor () -> SetupWindow?)? =
            skipDoctor ? nil : makeSetupWindow
        let setupWindow: SetupWindow? = MainActor.assumeIsolated {
            guard !skipDoctor, SetupFlow.isNeeded(setupState) else { return nil }
            let window = SetupWindow()
            window.show(step: SetupFlow.step(setupState))
            return window
        }
        // Reached only with both permissions already granted — the branch at
        // the top of `run` never returns otherwise — so every step this window
        // can show is one the daemon is working through on its own. A close is
        // a user dismissing a progress report, and the warm-up behind it is
        // untouched.

        let warmup = MainActor.assumeIsolated {
            WarmupState(
                status: WarmupStatus(
                    modelID: chosenModel.id,
                    transcriber: WhisperModelStore.isPresent(chosenModel)
                        ? .loading : .downloading(percent: nil),
                    formatter: warmsMLX ? .loading : .notLoading),
                overlay: overlay,
                menuBar: menuBar,
                readyMessage: WarmupStatus.readyMessage(hotkeyLabel: hotkeyLabel),
                setup: setupWindow,
                openSetup: openSetupWindow)
        }

        // The dictionary itself is loaded per utterance — that is the entire
        // hot-reload mechanism — so the menu form has no session to poke: it
        // merges into the file and the next dictation reads it. The backlog
        // exists for saves that fail; those corrections overlay every load
        // until quit, the same "applies until quit" contract as a microphone
        // pick whose config write failed.
        let dictionaryURL = LocalDictionary.defaultURL
        let snippetsURL = Snippets.defaultURL
        let unsavedCorrections = UnsavedCorrections()

        // The session's manual mode override, main-actor state like the menu
        // that sets it: the Mode submenu writes it, and the released-handler
        // reads it at the same main-actor sample point as the frontmost app —
        // by value, into that utterance. Deliberately not persisted: it is a
        // session override, and `config.mode` stays the startup default.
        let manualMode = MainActor.assumeIsolated { ManualMode() }
        let running = MainActor.assumeIsolated { RunningModel(model: chosenModel, language: config.language) }
        // Armed by the ladder if it ever adopts the stand-in model, read by the
        // first hotkey press after that and by no press after it.
        let pressNote = MainActor.assumeIsolated { PressNote() }
        // Which utterance owns the pill and the menu state. Utterances overlap
        // — a second press lands while the first is still transcribing — and
        // without this the first one's completion clears the screen out from
        // under the recording the user is in the middle of.
        let utterances = MainActor.assumeIsolated { UtteranceGeneration() }
        let mlx = Pipeline.mlxFormatter(
            timeoutBase: .milliseconds(config.timeoutMs),
            onOverrun: {
                Task { @MainActor in
                    pressNote.arm(FormatterChain.degradedNote(engine: .mlx))
                }
            })
        // Who won the warm-up race, for the ladder — see `WarmupLadder`.
        let ladder = MainActor.assumeIsolated { LadderState() }
        let startupGeneration = MainActor.assumeIsolated { running.generation }

        // Declared out here rather than beside the Language submenu it repaints
        // because the warm-up ladder needs it too: adopting the stand-in model
        // changes which languages the *running* model can produce, and a
        // Language submenu still describing the chosen model would be locked to
        // English while a multilingual stand-in was serving.
        let repaintLanguageMenu: @MainActor () -> Void = {
            menuBar.setLanguageMenu(LanguageMenuModel.compute(
                model: running.model, current: running.language,
                switching: running.switching))
        }

        // Opens the gate once. A selected model can beat the startup model, so
        // both paths use this same handoff. `WarmupState.finish()` returns
        // false after the first handoff and prevents a later model load from
        // replacing an active recording overlay with the ready card.
        let announcedReady = MainActor.assumeIsolated { AnnouncedReady() }
        let activeHotkey = MainActor.assumeIsolated { ActiveHotkey(chosenHotkey) }
        let declareReady: @MainActor () -> Void = {
            guard warmup.finish() else { return }
            menuBar.setReady()
            // The compile has finished at least once, which is the one part of
            // `SetupFlow.State` nothing can look up. Written here rather than
            // when the window closes because it is true whether or not there
            // was a window: a `--skip-doctor` launch that reaches this line has
            // paid the same compile, and the next ordinary launch should not
            // reopen the window to watch it again.
            //
            // A write that fails is a window shown once more, which is why it
            // is a warning and not a failure.
            if !config.setupCompleted {
                do { try Config.persistSetupCompleted(true) }
                catch {
                    FileHandle.standardError.write(Data(
                        "config: could not record that setup finished (\(error))\n".utf8))
                }
            }
            guard !announcedReady.value else { return }
            announcedReady.value = true
            FileHandle.standardError.write(Data(
                "listening on \(activeHotkey.value.label) hold · model: \(running.model.id) · ^C to quit\n".utf8
            ))
        }

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
            repaintLanguageMenu()
            menuBar.onLanguagePicked = { setting in
                Task { await transcriber.setLanguage(setting) }
                running.language = setting
                repaintLanguageMenu()
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
                // …and then actually switch to it, rather than leaving the user
                // to discover that a caption in this submenu was the only thing
                // that knew a restart was required. The load runs off the actor
                // (`buildPipeline` is static), so the old model keeps serving
                // dictation for however long the new one takes — including a
                // first-time Neural Engine compile of several minutes.
                guard let target = ModelRegistry.find(id) else { return }
                beginModelSwitch(to: target, running: running,
                                 transcriber: transcriber, menuBar: menuBar,
                                 repaintLanguageMenu: repaintLanguageMenu,
                                 declareReady: declareReady)
            }

            menuBar.setHotkeyMenu(HotkeyMenuModel.compute(current: chosenHotkey))
            menuBar.onHotkeyPicked = { picked in
                // The re-arm comes first and is not conditional on the save.
                // A pick is an instruction about the key the user is about to
                // hold; a config file that could not be written is a separate
                // problem, reported below, and refusing to change the running
                // hotkey over it would answer the wrong question — the user
                // would press the new key and get nothing.
                monitor.rearm(to: picked)
                activeHotkey.value = picked
                menuBar.setHotkeyMenu(HotkeyMenuModel.compute(current: picked))
                menuBar.setHotkeyLabel(picked.label)
                warmup.setHotkeyLabel(picked.label)
                do {
                    try Config.persistHotkey(picked)
                } catch {
                    let reason = (error as? Config.PersistError)?.description
                        ?? "\(type(of: error))"
                    FileHandle.standardError.write(Data(
                        "config: hotkey choice not saved (\(reason)); it is live now but reverts on restart\n"
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
                    // No ladder note: this utterance already showed whatever
                    // it had to say when it started.
                    overlay?.show(.recording(note: nil))
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
            },
            // The transcript arrived — the chain guarantees that — but plainer
            // than this user configured, and the daemon is the only layer that
            // can say so where they will see it. Armed rather than shown: the
            // fall-through happens while the text is being injected, seconds
            // after the pill for this utterance came down, so the sentence
            // rides the next press.
            onDegrade: { engine in
                Task { @MainActor in
                    pressNote.arm(FormatterChain.degradedNote(engine: engine))
                }
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
                    if MainActor.assumeIsolated({ warmup.consumesPress() }) {
                        return
                    }
                    // Claims the screen before the capture is attempted, so a
                    // press that fails to start owns its "no microphone" pill
                    // exactly as a successful one owns its waveform. Every
                    // press past the warm-up gate issues a token, which is
                    // what lets the release below assume it has one.
                    MainActor.assumeIsolated { _ = utterances.begin() }
                    do {
                        try capture.start()
                        FileHandle.standardError.write(Data("● recording\n".utf8))
                        MainActor.assumeIsolated {
                            // `take()` answers non-nil at most once, on the
                            // first press while the fast stand-in model is
                            // serving — see `LadderNote`.
                            overlay?.show(.recording(note: pressNote.take()))
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
                    if MainActor.assumeIsolated({ warmup.consumesRelease() }) {
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
                    // `utteranceToken` rides along for the same reason as the
                    // bundle ID: what it identifies is *this* utterance, and
                    // by the time the work below finishes the user may have
                    // started another one.
                    let (frontmostBundleID, manualModeID, utteranceToken): (String?, String?, Int?)
                        = MainActor.assumeIsolated {
                        let id = FrontmostApp.bundleID
                        overlay?.show(.transcribing)
                        menuBar.setTranscribing()
                        return (id, manualMode.id, utterances.token)
                    }
                    /// Whether this utterance still owns the screen — false
                    /// once the user has pressed the hotkey again, which is
                    /// the whole point: a completion that lands during the
                    /// *next* recording must deliver its text and then leave
                    /// the pill and the menu state alone.
                    ///
                    /// A missing token means no press ever claimed the screen,
                    /// which no ordinary release can produce. It answers true
                    /// there: with nothing newer to protect, the risk worth
                    /// avoiding is a pill left on screen for good.
                    let ownsScreen: @MainActor () -> Bool = {
                        guard let utteranceToken else { return true }
                        return utterances.isCurrent(utteranceToken)
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
                        // Hiding the pill here was the silent failure: the user
                        // held the key, spoke, and got back nothing at all —
                        // indistinguishable from the daemon ignoring them. An
                        // utterance that produces no text says so.
                        FileHandle.standardError.write(Data(
                            "  nothing to transcribe: \(EmptyDictation.noAudio.reason)\n".utf8))
                        MainActor.assumeIsolated {
                            overlay?.show(.error(EmptyDictation.noAudio.message))
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
                            // Audio came in and no words came out. Whisper is
                            // unreliable below about a second, and `sanitize`
                            // strips the bracket tokens it emits in place of
                            // words — so a short or clipped utterance lands here
                            // with a healthy rms and an empty string. `diagnose`
                            // returns nil for any non-blank transcript, so this
                            // branch cannot swallow a real result.
                            if let empty = EmptyDictation.diagnose(
                                sampleCount: samples.count, seconds: seconds, rms: rms,
                                leadingSilence: EmptyDictation.leadingSilence(
                                    samples, sampleRate: AudioCapture.targetSampleRate),
                                transcript: text)
                            {
                                FileHandle.standardError.write(Data(
                                    "  nothing to transcribe: \(empty.reason)\n".utf8))
                                await MainActor.run {
                                    guard ownsScreen() else { return }
                                    overlay?.show(.error(empty.message))
                                    menuBar.setRecording(false)
                                }
                                return
                            }
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
                                        frontmostBundleID: frontmostBundleID,
                                        text: cleaned)
                                    {
                                    case .type: TextInjector.inject(cleaned)
                                    case .paste: pasteInjector.inject(cleaned)
                                    }
                                }
                                guard ownsScreen() else { return }
                                overlay?.hide()
                                menuBar.setRecording(false)
                            }
                        } catch {
                            FileHandle.standardError.write(Data("transcription failed: \(error)\n".utf8))
                            await MainActor.run {
                                guard ownsScreen() else { return }
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
            async let transcriberResult: (error: Error?, superseded: Bool) = {
                do {
                    // `buildPipeline` + `adopt` rather than `warmUp`, which is
                    // the same load with the swap point hidden inside the
                    // actor. The ladder needs the swap point: this pipeline may
                    // be replacing a stand-in that is already serving
                    // utterances, and `adopt` is what lands it between two of
                    // them instead of inside one.
                    //
                    // The phase reports are already coalesced to one per whole
                    // percent by the transcriber, so this is one hop per
                    // visible change and not one per byte. The callback itself
                    // arrives on a URLSession thread; the hop is the whole
                    // body.
                    let pipeline = try await WhisperKitTranscriber.buildPipeline(
                        model: chosenModel,
                        onPhase: { phase in
                            Task { @MainActor in warmup.setTranscriber(phase) }
                        })
                    // Claimed before the adopt, not after: a stand-in whose
                    // own load returns in this same instant must see that it
                    // has lost, or it downgrades the user it was there to help.
                    guard await MainActor.run(resultType: Bool.self, body: {
                        guard running.generation == startupGeneration else { return false }
                        ladder.targetDidLand()
                        return true
                    }) else { return (nil, true) }
                    guard await MainActor.run(resultType: Bool.self, body: {
                        running.generation == startupGeneration
                    }) else { return (nil, true) }
                    await transcriber.adopt(pipeline, model: chosenModel)
                    // The transcriber is warm *before* the gate opens, and
                    // that gap is the point: the formatting model may still be
                    // loading, and the pill should say so rather than keep
                    // naming a model that is already in memory.
                    guard await MainActor.run(resultType: Bool.self, body: {
                        running.generation == startupGeneration
                    }) else { return (nil, true) }
                    await MainActor.run {
                        running.model = chosenModel
                        running.switching = .settled
                        menuBar.setModelLabel(running: chosenModel.id, switching: .settled)
                        repaintLanguageMenu()
                        warmup.setTranscriber(nil)
                    }
                    return (nil, false)
                } catch {
                    return (error, false)
                }
            }()
            // The ladder. Dictation on a small model while the chosen one is
            // still loading — the whole of `WarmupLadder`'s reason to exist.
            //
            // Nothing here is reported to the user when it fails. It is an
            // optimisation that did not happen, and the chosen model's own wait
            // and its own messages are unchanged by it; a second error about a
            // model nobody asked for would only be noise on top of the wait
            // they are already being told about.
            async let bootstrapDone: Void = {
                guard let bootstrap = WarmupLadder.bootstrap(for: chosenModel) else { return }
                // The delay is the whole trigger — see `bootstrapDelay` for why
                // it is measured rather than probed. A warm chosen model
                // returns inside it and the check below ends this task before
                // it costs anything.
                try? await Task.sleep(for: WarmupLadder.bootstrapDelay)
                if await MainActor.run(resultType: Bool.self, body: {
                    running.generation != startupGeneration || ladder.targetLanded
                }) {
                    return
                }
                FileHandle.standardError.write(Data(
                    ("\(chosenModel.id) is still loading; bringing up \(bootstrap.id) "
                        + "to dictate on in the meantime...\n").utf8))
                guard let pipeline = try? await WhisperKitTranscriber
                    .buildPipeline(model: bootstrap) else { return }
                guard await MainActor.run(resultType: Bool.self, body: {
                    guard running.generation == startupGeneration else { return false }
                    return ladder.claimBootstrap()
                }) else {
                    FileHandle.standardError.write(Data(
                        ("\(bootstrap.id) is ready, but \(chosenModel.id) got there "
                            + "first; discarding it\n").utf8))
                    return
                }
                guard await MainActor.run(resultType: Bool.self, body: {
                    running.generation == startupGeneration
                }) else { return }
                await transcriber.adopt(pipeline, model: bootstrap)
                await MainActor.run {
                    guard running.generation == startupGeneration else { return }
                    running.model = bootstrap
                    running.switching = .loading(target: chosenModel.id)
                    menuBar.setModelLabel(running: bootstrap.id,
                                          switching: running.switching)
                    repaintLanguageMenu()
                    pressNote.arm(WarmupLadder.servingNote(target: chosenModel))
                    // The gate opens here, minutes early. Everything the chosen
                    // model's load still has to do now happens behind a daemon
                    // that dictates.
                    declareReady()
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
            let startupResult = await transcriberResult
            let mlxWarmupError = await mlxResult
            // A warning, not a failure. Transcription without formatting is
            // the whole app minus its polish; formatting without transcription
            // is nothing. So a missing Whisper model is fatal below and a
            // missing formatting model is one line here, with the command that
            // fixes it. Hoisted into a closure because the two paths below
            // report it at different moments and neither may skip it.
            let reportFormatterWarning: @MainActor () -> Void = {
                guard let mlxWarmupError else { return }
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
            // The gate does not wait for the ladder when the chosen model
            // loaded — `WarmupLadder.awaitsBootstrap` is the whole rule and
            // the reason a warm start is 2.5s rather than 5s. The ladder's
            // task sleeps before it checks anything, so awaiting it here used
            // to charge every warm launch for a stand-in that was never going
            // to be built.
            guard WarmupLadder.awaitsBootstrap(targetFailed: startupResult.error != nil) else {
                await MainActor.run {
                    reportFormatterWarning()
                    if running.generation == startupGeneration, !startupResult.superseded {
                        declareReady()
                    }
                }
                // Still awaited, so this block owns every task it started —
                // just no longer in front of the gate. It is asleep on its own
                // timer and will find the chosen model landed when it wakes.
                await bootstrapDone
                return
            }
            // Awaited so this block owns every task it started, the reason the
            // MLX result is awaited even on a fatal path. By now it has either
            // adopted, lost the race, or given up — which is what `isFatal`
            // below needs, because a bootstrap mid-load reads as "not serving".
            await bootstrapDone
            await MainActor.run {
                if running.generation == startupGeneration,
                   !startupResult.superseded,
                   let warmupError = startupResult.error {
                    FileHandle.standardError.write(Data("warmup failed: \(warmupError)\n".utf8))
                    // Fatal only when nothing is serving. With the stand-in
                    // live the user has working dictation, and exiting would
                    // take it away to punish a failure that cost them nothing
                    // — see `WarmupLadder.isFatal`. The menu says which model
                    // failed, exactly as a failed live switch does.
                    if WarmupLadder.isFatal(targetFailed: true,
                                            bootstrapServing: ladder.bootstrapServing) {
                        Darwin.exit(1)
                    }
                    running.switching = .failed(target: chosenModel.id)
                    menuBar.setModelLabel(running: running.model.id,
                                          switching: running.switching)
                    repaintLanguageMenu()
                    FileHandle.standardError.write(Data(
                        ("still dictating with \(running.model.id); pick the model "
                            + "again from the menu to retry\n").utf8))
                }
                reportFormatterWarning()
                if running.generation == startupGeneration, !startupResult.superseded {
                    declareReady()
                }
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

/// Starts a live model switch: loads `target` in the background and adopts it
/// when it is ready, leaving the current model serving dictation throughout.
///
/// A free function rather than another closure in `run()` because the body is
/// long enough that folding it into the main-actor block there defeats Swift's
/// multi-statement closure inference — and because the switch is a unit of
/// behaviour worth naming.
///
/// The load is not cancellable: `WhisperKit.init` spends its time inside Core
/// ML, which does not observe cancellation. So a superseding pick is handled by
/// *declining the result* — the generation check before `adopt` — rather than
/// by stopping the work, which cannot be done.
@MainActor
private func beginModelSwitch(
    to target: TranscriptionModel, running: RunningModel,
    transcriber: WhisperKitTranscriber, menuBar: MenuBarController,
    repaintLanguageMenu: @escaping @MainActor () -> Void,
    declareReady: @escaping @MainActor () -> Void
) {
    guard target.id != running.model.id else { return }
    running.generation += 1
    let generation = running.generation
    running.switching = .loading(target: target.id)
    menuBar.setModelLabel(running: running.model.id, switching: running.switching)
    repaintLanguageMenu()
    FileHandle.standardError.write(Data(
        ("switching to \(target.id) (\(running.model.id) stays live until it "
            + "is ready)...\n").utf8))

    Task {
        do {
            let pipeline = try await WhisperKitTranscriber.buildPipeline(model: target)
            guard running.generation == generation else {
                FileHandle.standardError.write(Data(
                    ("\(target.id) loaded, but a newer choice supersedes it; "
                        + "discarding\n").utf8))
                return
            }
            await transcriber.adopt(pipeline, model: target)
            running.model = target
            running.switching = .settled
            menuBar.setModelLabel(running: target.id, switching: .settled)
            declareReady()
            repaintLanguageMenu()
            FileHandle.standardError.write(Data(
                "✓ now transcribing with \(target.id)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data(
                ("switch to \(target.id) failed (\(type(of: error))); still "
                    + "using \(running.model.id)\n").utf8))
            guard running.generation == generation else { return }
            running.switching = .failed(target: target.id)
            menuBar.setModelLabel(running: running.model.id,
                                  switching: running.switching)
            repaintLanguageMenu()
        }
    }
}

/// Whether the "listening on…" line has been printed. A one-field class rather
/// than a captured `var` because `declareReady` is a `@MainActor` closure and
/// has to mutate it from inside itself.
@MainActor
private final class AnnouncedReady {
    var value = false
}

/// The hotkey the monitor is actually armed to, for anything that reports it
/// after startup.
///
/// The chosen hotkey is fixed at launch, but the Hotkey submenu can re-arm the
/// monitor at any time — including while the model is still warming up, which
/// is exactly when the user is most likely to go looking through the menu. The
/// readiness line tells them which key to hold, so it has to read the armed
/// key rather than the launch one, or it names a key that no longer does
/// anything.
@MainActor
private final class ActiveHotkey {
    var value: Hotkey
    init(_ hotkey: Hotkey) { value = hotkey }
}

/// Who won the warm-up race.
///
/// The chosen model and the stand-in load concurrently and either may return
/// first, so "may I adopt this?" is a question with a shared answer and it is
/// answered here — on the main actor, where the two hops that ask it are
/// already serialised. The *rules* are `WarmupLadder`'s, where a test can
/// reach them; this is the mutable slot they read.
@MainActor
private final class LadderState {
    /// Read by the stand-in's load before it spends a second on anything: if
    /// the chosen model is already home there is nothing to stand in for.
    private(set) var targetLanded = false
    private(set) var bootstrapServing = false

    /// Claimed *before* `adopt`, not after, so a stand-in finishing in the
    /// same instant loses the race rather than tying it.
    func targetDidLand() { targetLanded = true }

    /// Answers `true` at most once, and only while the chosen model is still
    /// out. The caller adopts only on `true`.
    func claimBootstrap() -> Bool {
        guard !bootstrapServing,
              WarmupLadder.adoptsBootstrap(targetLanded: targetLanded)
        else { return false }
        bootstrapServing = true
        return true
    }
}

/// One sentence for the next hotkey press, shown once and then forgotten.
///
/// Two things arm it, and both are the same shape of problem: something about
/// this dictation is worse than the user configured, they cannot see why, and
/// the overlay is the only surface they are reliably looking at.
///
/// - The warm-up ladder, when a stand-in model is serving
///   (`WarmupLadder.servingNote`).
/// - The formatter chain, when it fell through to the rules floor
///   (`FormatterChain.degradedNote`).
///
/// The wordings live with the components that know the facts, where tests can
/// read them. What lives here is only the *once*: `take()` hands the note to
/// the first press that asks and `nil` to every press after it, so a user who
/// dictates six times through a bad patch is told once rather than six times.
/// A newer note replaces an unread older one — the last thing to go wrong is
/// the one that describes the transcript they are about to get.
///
/// Main-actor for `ManualMode`'s reason: written by the ladder's adoption and
/// by the formatting task hopping in, read by the hotkey's press handler,
/// which AppKit already delivers there.
@MainActor
private final class PressNote {
    private var pending: String?

    func arm(_ note: String) { pending = note }

    func take() -> String? {
        defer { pending = nil }
        return pending
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

/// What the daemon is *actually* transcribing with, as opposed to what
/// `config.json` says it should be.
///
/// The two diverge the moment someone picks a model: the config write is
/// immediate and the load that makes it true takes seconds to minutes. Every
/// menu that describes transcription — the `model:` line, the Language rows —
/// has to read from here, or it describes a model that is not running.
///
/// Main-actor for `ManualMode`'s reason: written by the switch task hopping in,
/// read by menu repaints AppKit already delivers there.
@MainActor
private final class RunningModel {
    var model: TranscriptionModel
    var language: LanguageSetting
    var switching: ModelSwitch = .settled
    /// Bumped per pick, so a load that finishes after a *newer* pick started is
    /// discarded rather than adopted. Same token discipline as the overlay's
    /// `showToken` and the capture's generations, and for the same reason:
    /// there is no cancelling a Core ML compile already in flight, only
    /// declining its result.
    var generation = 0

    init(model: TranscriptionModel, language: LanguageSetting) {
        self.model = model
        self.language = language
    }
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
///
/// ## It owns the startup card
///
/// The overlay used to be driven by the *press handler*: a press put the
/// warm-up pill up, the release took it down, and `repaint` touched the pill
/// only while that was true. So a user who launched the daemon and did not
/// press anything saw nothing at all — and launched from Finder there is
/// nothing else to see, because the app is `LSUIElement` with no window and no
/// Dock icon. A first run spends over a minute downloading in total silence.
///
/// The card is now shown from `init` and belongs to this type for as long as
/// the warm-up does: every phase change repaints it, `finish()` swaps it to
/// the ready line, and it clears itself a few seconds later. The press handler
/// stops showing and hiding it and keeps only the one thing it actually knows
/// — whether *this* press was turned away, which its release needs.
@MainActor
private final class WarmupState {
    /// How long the ready line stays up before the card clears itself.
    ///
    /// Long enough to read a short sentence, short enough that it is gone
    /// before it becomes furniture. A dictation started inside it supersedes
    /// it immediately — see `RecordingOverlay.hide(after:)`.
    private static let readyLingerSeconds = 3.0

    private var status: WarmupStatus
    private let overlay: RecordingOverlay?
    private let menuBar: MenuBarController
    /// The first-run window, on the launches that have one. It shows the same
    /// phases as the pill and the menu line, because it is the same warm-up —
    /// what differs is who is looking. A returning user has met the menu bar;
    /// someone who installed ara five seconds ago has met nothing, and the
    /// window is the only surface they know about.
    ///
    /// A `var`, because a launch can acquire one it did not start with. The
    /// Core ML compile is keyed on the signing identity as well as the macOS
    /// build, so *every ara update* pays it again — and by then `setupCompleted`
    /// is long since true and this would otherwise be `nil` through the one
    /// wait it exists to explain.
    private var setup: SetupWindow?
    /// Opens a window mid-warm-up. `nil` under `--skip-doctor`, which turns
    /// off the whole preflight, and only that.
    ///
    /// Deliberately not `--no-overlay`. That flag turns off the *recording
    /// overlay* — the pill that appears over whatever the user is working in,
    /// every time they dictate — and someone who wants their screen left alone
    /// during dictation has not thereby asked to be told nothing about a
    /// three-minute compile they can neither see nor explain.
    private let openSetup: (@MainActor () -> SetupWindow?)?
    /// Names the hotkey, so a pick made *during* the warm-up has to move it —
    /// which is exactly when a user is most likely to be poking at the menu,
    /// because the daemon is not yet doing anything else.
    private var readyMessage: String
    /// Whether a press was turned away by the gate, so its release knows the
    /// press was never a recording — which `isWarming` cannot tell it, because
    /// the warm-up may have finished while the key was held. Nothing to do
    /// with the card any more; the card is up regardless of who is pressing
    /// what.
    private var pressWasTurnedAway = false
    /// One-way, for the reason in the type's doc.
    private var transcriberSettled = false
    /// Whether `finish()` has handed the card and the state line over. Both
    /// belong to the dictation lifecycle from that moment — `setReady()` has
    /// put the idle line up and the card is clearing itself — so a late phase
    /// report must not paint either one again. Reachable in practice: the
    /// ladder opens the gate while the formatting model is still loading, and
    /// its `setFormatter` lands afterwards.
    private var handedOver = false

    init(status: WarmupStatus, overlay: RecordingOverlay?,
         menuBar: MenuBarController, readyMessage: String,
         setup: SetupWindow? = nil,
         openSetup: (@MainActor () -> SetupWindow?)? = nil) {
        self.status = status
        self.overlay = overlay
        self.menuBar = menuBar
        self.readyMessage = readyMessage
        self.setup = setup
        self.openSetup = openSetup
        // The state line's first value. From here the warm-up owns it until
        // `MenuBarController.setReady()`.
        if let message = status.message {
            menuBar.setWarmingUp(message)
            // And the card, unprompted. This is the whole point: the answer to
            // "is it doing anything?" should not require guessing that holding
            // a key will tell you.
            overlay?.show(.warmingUp(title: message, detail: status.detail))
        }
    }

    /// A hotkey press. Answers `true` when recording is not allowed yet, which
    /// is also when the card on screen is already saying why.
    func consumesPress() -> Bool {
        // `blocksDictation`, not `message`: the formatting model may still be
        // loading and still have a line to show, but it does not gate speech.
        guard status.blocksDictation else { return false }
        pressWasTurnedAway = true
        return true
    }

    /// The matching release. Answers `true` when it belonged to a press the
    /// gate turned away, and so must not reach the capture.
    func consumesRelease() -> Bool {
        guard pressWasTurnedAway else { return false }
        pressWasTurnedAway = false
        return true
    }

    /// The Hotkey submenu re-armed the monitor mid-warm-up.
    func setHotkeyLabel(_ label: String) {
        readyMessage = WarmupStatus.readyMessage(hotkeyLabel: label)
    }

    /// `nil` means the transcriber is warm — see `WarmupStatus.transcriber`.
    ///
    /// Each report reaches the main actor on its own `Task`, and those arrive
    /// unordered, so which reports may replace which is a rule rather than an
    /// assignment — `TranscriberWarmup.advances(from:to:)`, where it is
    /// unit-tested. `transcriberSettled` stays here because it is the gate's
    /// latch rather than a phase comparison: `finish()` closes it too.
    func setTranscriber(_ phase: TranscriberWarmup?) {
        guard !transcriberSettled,
              TranscriberWarmup.advances(from: status.transcriber, to: phase)
        else { return }
        if phase == nil { transcriberSettled = true }
        status.transcriber = phase
        repaint()
    }

    func setFormatter(_ phase: WarmupStatus.Formatter) {
        status.formatter = phase
        repaint()
    }

    /// The warm-up is over and a press records from here.
    ///
    /// Reachable more than once — the ladder, startup model, or a selected
    /// model can open the gate. Only the first call changes UI state.
    ///
    /// The card is not torn down on the spot. A user holding the key at the
    /// moment the wait ends would see it vanish under their thumb, which reads
    /// as a crash; a user who walked away deserves to find out it worked. So
    /// it says the wait is over, names the key, and clears itself.
    @discardableResult
    func finish() -> Bool {
        guard !handedOver else { return false }
        transcriberSettled = true
        handedOver = true
        status.transcriber = nil
        overlay?.show(.warmingUp(title: readyMessage, detail: nil))
        overlay?.hide(after: Self.readyLingerSeconds)
        // The window's whole job was the wait, and the wait is over. It closes
        // rather than showing a "done" step nobody asked to read: the pill is
        // already saying the same thing, in the place the user will meet it
        // every day from now on.
        setup?.close()
        return true
    }

    private func repaint() {
        guard !handedOver, let message = status.message else { return }
        menuBar.setWarmingUp(message)
        overlay?.show(.warmingUp(title: message, detail: status.detail))
        repaintSetup()
    }

    /// The same phases, rendered as the first-run window's two working steps.
    /// A download has a percentage to show; everything else is the load, and
    /// the load's honest report is a clock — Core ML says nothing at all from
    /// inside the compile.
    private func repaintSetup() {
        // The compile has been running for over twenty seconds
        // (`WhisperWarmupPlan.specialisationThreshold`), which is the only
        // observable evidence that this launch is paying it. On a first run
        // there is already a window; after an update there is not, and this is
        // where it gets one. A load that finishes quickly never reaches this
        // phase and never opens anything.
        if status.transcriber == .preparingNeuralEngine, setup == nil {
            setup = openSetup?()
        }
        guard let setup else { return }
        switch status.transcriber {
        case .downloading(let percent):
            setup.update(step: .download, activity: .downloading(percent: percent))
        case .loading, .preparingNeuralEngine:
            setup.update(step: .prepare, activity: .preparing(seconds: 0))
        case nil:
            break
        }
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
            // `resolve`, not `find`: this command may also pre-fetch the warm-up
            // ladder's stand-in model, which `ara models list` does not offer
            // and `--model` will not accept. Downloading it early is the one
            // useful thing a user can do about a first cold start.
            guard let m = ModelRegistry.resolve(id) else {
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
