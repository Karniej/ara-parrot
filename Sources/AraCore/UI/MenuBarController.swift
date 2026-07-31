import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
public final class MenuBarController {
    private let statusItem: NSStatusItem
    private let modelLabel: NSMenuItem
    private let modeLabel: NSMenuItem
    private let stateLabel: NSMenuItem
    private let microphoneItem: NSMenuItem
    private let cleanupItem: NSMenuItem
    private let languageItem: NSMenuItem
    private let modeItem: NSMenuItem
    private let modelItem: NSMenuItem
    private let hotkeyItem: NSMenuItem
    private let engineItem: NSMenuItem
    private let startAtLoginItem: NSMenuItem
    private let modelID: String
    private let idleTitle: String
    /// What `setStartAtLogin` last read from disk; the toggle click requests
    /// the opposite. Never updated on a click — only from a fresh disk read.
    private var startAtLoginInstalled = false

    /// The user picked a row in the Microphone submenu: the device's UID, or
    /// `nil` for "System default". Invoked on the main thread by AppKit.
    public var onMicrophonePicked: ((String?) -> Void)?

    /// The user submitted the "Add dictionary correction…" form with both
    /// fields filled in: what dictation heard, and what it should have typed.
    /// Both arrive trimmed and non-empty — an empty field never gets here.
    /// Invoked on the main thread by AppKit.
    public var onCorrectionAdded: ((_ heard: String, _ canonical: String) -> Void)?

    /// The user picked an intensity in the Cleanup submenu. The pick
    /// persists to the config and applies on the next launch — the submenu's
    /// caption says so; see `CleanupMenuModel`. Invoked on the main thread
    /// by AppKit.
    public var onCleanupPicked: ((CleanupIntensity) -> Void)?

    /// The user clicked a row in the Language submenu. The row carries the
    /// whole resulting setting — see `LanguageMenuModel.Item.picked` — so this
    /// is the new setting, not a toggle to be interpreted. Applies to the next
    /// utterance *and* persists. Invoked on the main thread by AppKit.
    public var onLanguagePicked: ((LanguageSetting) -> Void)?

    /// The user picked "Edit dictionary…": open the dictionary file in
    /// whatever edits JSON on this machine. The file is the editor and the
    /// per-utterance load is the apply mechanism, so this callback's whole
    /// job is making sure a file exists and handing it to the system.
    /// Invoked on the main thread by AppKit.
    public var onEditDictionary: (() -> Void)?

    /// "Edit snippets…", the same contract as `onEditDictionary`: ensure a
    /// file exists, hand it to the system editor, and let the per-utterance
    /// load apply whatever gets saved. Invoked on the main thread by AppKit.
    public var onEditSnippets: (() -> Void)?

    /// The user picked a mode in the Mode submenu: the mode's id, or `nil`
    /// for "Auto (per app)". Applies to the next utterance and is never
    /// persisted — see `ModeMenuModel`. Invoked on the main thread by AppKit.
    public var onModePicked: ((String?) -> Void)?

    /// The user picked a transcription model in the Model submenu. The pick
    /// persists to the config and applies on the next launch — the submenu's
    /// caption says so; see `ModelMenuModel`. Invoked on the main thread by
    /// AppKit.
    public var onModelPicked: ((String) -> Void)?

    /// The user picked a key in the Hotkey submenu. Persists and applies on
    /// restart — see `HotkeyMenuModel`. Invoked on the main thread by AppKit.
    public var onHotkeyPicked: ((Hotkey) -> Void)?

    /// The user picked an engine in the Engine submenu. Persists and applies
    /// on restart — see `EngineMenuModel`. Invoked on the main thread by
    /// AppKit.
    public var onEnginePicked: ((Engine) -> Void)?

    /// The user clicked "Start at Login": the state they asked for (the
    /// opposite of what `setStartAtLogin` last showed). The caller owns the
    /// install/uninstall and must call `setStartAtLogin` again from a fresh
    /// disk read — success or failure. Invoked on the main thread by AppKit.
    public var onStartAtLoginToggled: ((Bool) -> Void)?

    /// The user clicked "Run Diagnostics…". The caller owns running the
    /// checks off the main thread and handing the rendered report to
    /// `showDiagnosticsReport`. Invoked on the main thread by AppKit.
    public var onRunDiagnostics: (() -> Void)?

    /// - Parameter modeID: The mode the daemon starts in. Modes are resolved per
    ///   utterance — the frontmost application can change the answer — so this is
    ///   only the initial value; `setMode` keeps the label honest afterwards.
    public init(modelID: String, hotkeyLabel: String = "fn", modeID: String) {
        self.modelID = modelID
        self.idleTitle = "idle · hold \(hotkeyLabel) to dictate"
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: idleTitle, action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        modelLabel = NSMenuItem(title: "model: \(modelID)", action: nil, keyEquivalent: "")
        modelLabel.isEnabled = false
        menu.addItem(modelLabel)

        modeLabel = NSMenuItem(title: "mode: \(modeID)", action: nil, keyEquivalent: "")
        modeLabel.isEnabled = false
        menu.addItem(modeLabel)

        menu.addItem(.separator())

        microphoneItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let microphoneSubmenu = NSMenu()
        microphoneSubmenu.autoenablesItems = false
        microphoneItem.submenu = microphoneSubmenu
        menu.addItem(microphoneItem)

        cleanupItem = NSMenuItem(title: "Cleanup", action: nil, keyEquivalent: "")
        let cleanupSubmenu = NSMenu()
        cleanupSubmenu.autoenablesItems = false
        cleanupItem.submenu = cleanupSubmenu
        menu.addItem(cleanupItem)

        languageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let languageSubmenu = NSMenu()
        languageSubmenu.autoenablesItems = false
        languageItem.submenu = languageSubmenu
        menu.addItem(languageItem)

        modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        let modeSubmenu = NSMenu()
        modeSubmenu.autoenablesItems = false
        modeItem.submenu = modeSubmenu
        menu.addItem(modeItem)

        modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let modelSubmenu = NSMenu()
        modelSubmenu.autoenablesItems = false
        modelItem.submenu = modelSubmenu
        menu.addItem(modelItem)

        hotkeyItem = NSMenuItem(title: "Hotkey", action: nil, keyEquivalent: "")
        let hotkeySubmenu = NSMenu()
        hotkeySubmenu.autoenablesItems = false
        hotkeyItem.submenu = hotkeySubmenu
        menu.addItem(hotkeyItem)

        engineItem = NSMenuItem(title: "Engine", action: nil, keyEquivalent: "")
        let engineSubmenu = NSMenu()
        engineSubmenu.autoenablesItems = false
        engineItem.submenu = engineSubmenu
        menu.addItem(engineItem)

        // Created here — every stored property must exist before the first
        // `target = self` below — and added to the menu further down, with
        // the other daemon-level actions.
        startAtLoginItem = NSMenuItem(
            title: "Start at Login",
            action: #selector(startAtLoginClicked),
            keyEquivalent: ""
        )

        let addCorrection = NSMenuItem(
            title: "Add dictionary correction…",
            action: #selector(addCorrectionClicked),
            keyEquivalent: ""
        )
        addCorrection.target = self
        menu.addItem(addCorrection)

        let editDictionary = NSMenuItem(
            title: "Edit dictionary…",
            action: #selector(editDictionaryClicked),
            keyEquivalent: ""
        )
        editDictionary.target = self
        menu.addItem(editDictionary)

        let editSnippets = NSMenuItem(
            title: "Edit snippets…",
            action: #selector(editSnippetsClicked),
            keyEquivalent: ""
        )
        editSnippets.target = self
        menu.addItem(editSnippets)

        menu.addItem(.separator())

        startAtLoginItem.target = self
        menu.addItem(startAtLoginItem)

        let diagnostics = NSMenuItem(
            title: "Run Diagnostics…",
            action: #selector(runDiagnosticsClicked),
            keyEquivalent: ""
        )
        diagnostics.target = self
        menu.addItem(diagnostics)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Ara",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        configureButton(recording: false)
    }

    public func setRecording(_ recording: Bool) {
        stateLabel.title = recording ? "● recording" : idleTitle
    }

    /// The daemon is loading models and cannot dictate yet: holding the key
    /// shows status instead of recording, and this line is why. Set before the
    /// warm-up starts and re-set on every phase change; replaced by
    /// `setReady()` when the hotkey loop arms. Nothing can race it in between
    /// — every other state begins with a hotkey press that the warm-up gate
    /// turns away, and `clearNoMicrophone` only ever replaces its own message.
    ///
    /// The message is the same sentence the overlay pill shows
    /// (`WarmupStatus.message`), so a user who opens the menu during a long
    /// download and a user who presses the hotkey are told the same thing.
    public func setWarmingUp(_ message: String) {
        stateLabel.title = message
    }

    /// Warm-up finished and the hotkey loop is armed: show the idle line.
    /// From here the state line belongs to the dictation lifecycle.
    public func setReady() {
        stateLabel.title = idleTitle
    }

    public func setTranscribing() {
        stateLabel.title = "transcribing…"
    }

    /// The capture could not start, or lost every input mid-utterance: the
    /// state line must not keep claiming "recording" (or promising that
    /// holding the hotkey will dictate). Cleared by the next state change, or
    /// by `clearNoMicrophone()` when a device returns while idle.
    public func setNoMicrophone() {
        stateLabel.title = Self.noMicrophoneTitle
    }

    /// Restores the idle line — but only over the no-microphone message, so a
    /// device change can never clobber "● recording" or "transcribing…".
    public func clearNoMicrophone() {
        if stateLabel.title == Self.noMicrophoneTitle {
            stateLabel.title = idleTitle
        }
    }

    private static let noMicrophoneTitle = "no microphone"

    /// Shows the mode the current utterance is being formatted in. The daemon
    /// resolves a mode per utterance from the `--mode` flag, the config default
    /// and the frontmost application, so this is the only way to see which of
    /// those actually won.
    public func setMode(_ id: String) {
        modeLabel.title = "mode: \(id)"
    }

    /// Rebuilds the Microphone submenu from a model. A verbatim transcription
    /// — titles, checks, enabled flags, and the informational status line all
    /// arrive decided; the rules live in `MicrophoneMenuModel.compute`, where
    /// they are unit-tested.
    public func setMicrophoneMenu(_ model: MicrophoneMenuModel) {
        guard let submenu = microphoneItem.submenu else { return }
        submenu.removeAllItems()
        if let status = model.status {
            let line = NSMenuItem(title: status, action: nil, keyEquivalent: "")
            line.isEnabled = false
            submenu.addItem(line)
            submenu.addItem(.separator())
        }
        for item in model.items {
            let row = NSMenuItem(
                title: item.title,
                action: #selector(microphoneClicked(_:)),
                keyEquivalent: "")
            row.target = self
            row.isEnabled = item.enabled
            row.state = item.checked ? .on : .off
            row.representedObject = item.uid
            submenu.addItem(row)
        }
    }

    /// Rebuilds the Cleanup submenu from a model, `setMicrophoneMenu`'s
    /// pattern exactly: titles, the check, and the trailing "applies on
    /// restart" caption all arrive decided by `CleanupMenuModel.compute`,
    /// where they are unit-tested.
    public func setCleanupMenu(_ model: CleanupMenuModel) {
        guard let submenu = cleanupItem.submenu else { return }
        submenu.removeAllItems()
        for item in model.items {
            let row = NSMenuItem(
                title: item.title,
                action: #selector(cleanupClicked(_:)),
                keyEquivalent: "")
            row.target = self
            row.state = item.checked ? .on : .off
            row.representedObject = item.intensity.rawValue
            submenu.addItem(row)
        }
        submenu.addItem(.separator())
        let caption = NSMenuItem(title: model.caption, action: nil,
                                 keyEquivalent: "")
        caption.isEnabled = false
        submenu.addItem(caption)
    }

    /// Rebuilds the Language submenu from a model — the established pattern,
    /// with the Microphone submenu's status line: the cost line, the rows,
    /// the checks, what a click means, and the caption all arrive decided by
    /// `LanguageMenuModel.compute`, where they are unit-tested.
    public func setLanguageMenu(_ model: LanguageMenuModel) {
        guard let submenu = languageItem.submenu else { return }
        submenu.removeAllItems()
        if let status = model.status {
            let line = NSMenuItem(title: status, action: nil, keyEquivalent: "")
            line.isEnabled = false
            submenu.addItem(line)
            submenu.addItem(.separator())
        }
        for item in model.items {
            let row = NSMenuItem(
                title: item.title,
                action: #selector(languageClicked(_:)),
                keyEquivalent: "")
            row.target = self
            row.isEnabled = item.enabled
            row.state = item.checked ? .on : .off
            row.representedObject = item.picked.rawValue
            submenu.addItem(row)
            // The Automatic row is a different kind of answer from the
            // language rows, not another language.
            if item.code == nil { submenu.addItem(.separator()) }
        }
        submenu.addItem(.separator())
        let caption = NSMenuItem(title: model.caption, action: nil,
                                 keyEquivalent: "")
        caption.isEnabled = false
        submenu.addItem(caption)
    }

    /// Rebuilds the Mode submenu from a model, the established pattern: the
    /// Auto row, titles, the check, and the "applies to the next utterance"
    /// caption all arrive decided by `ModeMenuModel.compute`, where they are
    /// unit-tested.
    public func setModeMenu(_ model: ModeMenuModel) {
        guard let submenu = modeItem.submenu else { return }
        submenu.removeAllItems()
        for item in model.items {
            let row = NSMenuItem(
                title: item.title,
                action: #selector(modeClicked(_:)),
                keyEquivalent: "")
            row.target = self
            row.state = item.checked ? .on : .off
            row.representedObject = item.id
            submenu.addItem(row)
        }
        submenu.addItem(.separator())
        let caption = NSMenuItem(title: model.caption, action: nil,
                                 keyEquivalent: "")
        caption.isEnabled = false
        submenu.addItem(caption)
    }

    /// Rebuilds the Model submenu from a model: the pickable transcription
    /// models, then the formatting-model line (informational when it is
    /// downloaded, an offer of the CLI command when it is not), then the
    /// caption — all decided by `ModelMenuModel.compute`, unit-tested.
    public func setModelMenu(_ model: ModelMenuModel) {
        guard let submenu = modelItem.submenu else { return }
        submenu.removeAllItems()
        for item in model.items {
            let row = NSMenuItem(
                title: item.title,
                action: #selector(modelClicked(_:)),
                keyEquivalent: "")
            row.target = self
            row.state = item.checked ? .on : .off
            row.representedObject = item.id
            submenu.addItem(row)
        }
        submenu.addItem(.separator())
        let formatter = NSMenuItem(
            title: model.formatter.title,
            action: model.formatter.offersDownload
                ? #selector(formatterDownloadClicked) : nil,
            keyEquivalent: "")
        if model.formatter.offersDownload {
            formatter.target = self
        } else {
            formatter.isEnabled = false
        }
        submenu.addItem(formatter)
        submenu.addItem(.separator())
        let caption = NSMenuItem(title: model.caption, action: nil,
                                 keyEquivalent: "")
        caption.isEnabled = false
        submenu.addItem(caption)
    }

    /// Rebuilds the Hotkey submenu from a model — `setCleanupMenu`'s pattern
    /// exactly; the rules live in `HotkeyMenuModel.compute`, unit-tested.
    public func setHotkeyMenu(_ model: HotkeyMenuModel) {
        guard let submenu = hotkeyItem.submenu else { return }
        submenu.removeAllItems()
        for item in model.items {
            let row = NSMenuItem(
                title: item.title,
                action: #selector(hotkeyClicked(_:)),
                keyEquivalent: "")
            row.target = self
            row.state = item.checked ? .on : .off
            row.representedObject = item.hotkey.rawValue
            submenu.addItem(row)
        }
        submenu.addItem(.separator())
        let caption = NSMenuItem(title: model.caption, action: nil,
                                 keyEquivalent: "")
        caption.isEnabled = false
        submenu.addItem(caption)
    }

    /// Rebuilds the Engine submenu from a model — the same pattern; the
    /// rules, including the cloud item's no-key suffix, live in
    /// `EngineMenuModel.compute`, unit-tested.
    public func setEngineMenu(_ model: EngineMenuModel) {
        guard let submenu = engineItem.submenu else { return }
        submenu.removeAllItems()
        for item in model.items {
            let row = NSMenuItem(
                title: item.title,
                action: #selector(engineClicked(_:)),
                keyEquivalent: "")
            row.target = self
            row.state = item.checked ? .on : .off
            row.representedObject = item.engine.rawValue
            submenu.addItem(row)
        }
        submenu.addItem(.separator())
        let caption = NSMenuItem(title: model.caption, action: nil,
                                 keyEquivalent: "")
        caption.isEnabled = false
        submenu.addItem(caption)
    }

    /// Shows whether launch-at-login is installed. Callers pass a fresh
    /// `Install.isInstalled()` read — never an assumption about what a
    /// toggle just did.
    public func setStartAtLogin(_ installed: Bool) {
        startAtLoginInstalled = installed
        startAtLoginItem.state = installed ? .on : .off
    }

    @objc private func microphoneClicked(_ sender: NSMenuItem) {
        onMicrophonePicked?(sender.representedObject as? String)
    }

    @objc private func cleanupClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let intensity = CleanupIntensity(rawValue: raw)
        else { return }
        onCleanupPicked?(intensity)
    }

    @objc private func languageClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let setting = LanguageSetting(rawValue: raw)
        else { return }
        onLanguagePicked?(setting)
    }

    @objc private func modeClicked(_ sender: NSMenuItem) {
        onModePicked?(sender.representedObject as? String)
    }

    @objc private func modelClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onModelPicked?(id)
    }

    @objc private func hotkeyClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let hotkey = Hotkey(rawValue: raw)
        else { return }
        onHotkeyPicked?(hotkey)
    }

    @objc private func engineClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let engine = Engine(rawValue: raw)
        else { return }
        onEnginePicked?(engine)
    }

    @objc private func startAtLoginClicked() {
        onStartAtLoginToggled?(!startAtLoginInstalled)
    }

    @objc private func runDiagnosticsClicked() {
        onRunDiagnostics?()
    }

    /// The menu cannot fetch 0.9 GB itself — the download is deliberately a
    /// CLI action (see `ModelMenuModel.FormatterItem`) — so the offer is an
    /// alert naming the exact command, with a button that copies it. Honest
    /// beats magic.
    @objc private func formatterDownloadClicked() {
        let alert = NSAlert()
        alert.messageText = "Download the formatting model"
        alert.informativeText = "The download is ~\(MLXModel.sizeMB) MB and "
            + "runs in a terminal:\n\n\(MLXModel.downloadCommand)\n\n"
            + "Restart Ara afterwards — the model is loaded at startup."
        alert.addButton(withTitle: "Copy command")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(MLXModel.downloadCommand, forType: .string)
    }

    /// The doctor report in a window: the exact text `ara doctor` prints
    /// (`DoctorReport.rendered`), monospaced so its alignment survives, with
    /// a button that copies it — a bug report should not require a terminal.
    public func showDiagnosticsReport(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Diagnostics"
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.isSelectable = true
        label.sizeToFit()
        alert.accessoryView = label
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy report")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    /// One informational alert, used by the Start at Login wiring for both
    /// the honest post-enable notice and a failed toggle. The daemon is an
    /// `.accessory` app, so the activation is what puts the alert in front.
    public func showNotice(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func editDictionaryClicked() {
        onEditDictionary?()
    }

    @objc private func editSnippetsClicked() {
        onEditSnippets?()
    }

    /// The "heard → should be" form: an `NSAlert` with two text fields as its
    /// accessory view. Deliberately the thinnest possible AppKit — no window,
    /// no xib, single-binary — over the merge logic in
    /// `LocalDictionary.adding`, which is where the behaviour (and the tests)
    /// live. This method only collects two trimmed strings; an empty field
    /// means the callback is never invoked.
    @objc private func addCorrectionClicked() {
        let heardField = NSTextField(frame: NSRect(x: 98, y: 34, width: 190, height: 24))
        heardField.placeholderString = "what dictation typed"
        let canonicalField = NSTextField(frame: NSRect(x: 98, y: 2, width: 190, height: 24))
        canonicalField.placeholderString = "what it should be"

        let heardLabel = NSTextField(labelWithString: "Heard:")
        heardLabel.alignment = .right
        heardLabel.frame = NSRect(x: 0, y: 38, width: 92, height: 17)
        let canonicalLabel = NSTextField(labelWithString: "Should be:")
        canonicalLabel.alignment = .right
        canonicalLabel.frame = NSRect(x: 0, y: 6, width: 92, height: 17)

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 292, height: 60))
        accessory.addSubview(heardLabel)
        accessory.addSubview(heardField)
        accessory.addSubview(canonicalLabel)
        accessory.addSubview(canonicalField)

        let alert = NSAlert()
        alert.messageText = "Add dictionary correction"
        alert.informativeText = "When dictation hears the first, it types the "
            + "second — whole words, any capitalisation. Applies from the "
            + "next utterance."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = heardField
        heardField.nextKeyView = canonicalField
        canonicalField.nextKeyView = heardField

        // The daemon is an `.accessory` app: without activation the alert
        // appears behind the frontmost app and the fields never get focus.
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let heard = heardField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical = canonicalField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !canonical.isEmpty else { return }
        onCorrectionAdded?(heard, canonical)
    }

    private func configureButton(recording: Bool) {
        guard let button = statusItem.button else { return }
        let image = Self.birdImage()
        image?.isTemplate = true
        button.image = image
    }

    // Inlined Lucide bird SVG. Keeping it in source means the executable has
    // no separate resource bundle to install alongside it — true single-binary.
    private static let birdSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M16 7h.01"/>\
    <path d="M3.4 18H12a8 8 0 0 0 8-8V7a4 4 0 0 0-7.28-2.3L2 20"/>\
    <path d="m20 7 2 .5-2 .5"/>\
    <path d="M10 18v3"/>\
    <path d="M14 17.75V21"/>\
    <path d="M7 18a6 6 0 0 0 3.84-10.61"/>\
    </svg>
    """

    private static func birdImage() -> NSImage? {
        guard let data = birdSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }
}
