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
    private let modelID: String
    private let idleTitle: String

    /// The user picked a row in the Microphone submenu: the device's UID, or
    /// `nil` for "System default". Invoked on the main thread by AppKit.
    public var onMicrophonePicked: ((String?) -> Void)?

    /// The user submitted the "Add dictionary correction…" form with both
    /// fields filled in: what dictation heard, and what it should have typed.
    /// Both arrive trimmed and non-empty — an empty field never gets here.
    /// Invoked on the main thread by AppKit.
    public var onCorrectionAdded: ((_ heard: String, _ canonical: String) -> Void)?

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

        let addCorrection = NSMenuItem(
            title: "Add dictionary correction…",
            action: #selector(addCorrectionClicked),
            keyEquivalent: ""
        )
        addCorrection.target = self
        menu.addItem(addCorrection)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit parrot",
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

    /// The daemon is loading models and the hotkey is not armed yet: holding
    /// the key does nothing, and this line is why. Set before the warm-up
    /// starts; replaced by `setReady()` when the hotkey loop arms. Nothing
    /// can race it in between — every other state begins with a hotkey press,
    /// and `clearNoMicrophone` only ever replaces its own message.
    public func setWarmingUp() {
        stateLabel.title = "warming up models…"
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

    @objc private func microphoneClicked(_ sender: NSMenuItem) {
        onMicrophonePicked?(sender.representedObject as? String)
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
