import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let modelLabel: NSMenuItem
    private let stateLabel: NSMenuItem
    private let modelID: String

    init(modelID: String) {
        self.modelID = modelID
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "idle · hold fn to dictate", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        modelLabel = NSMenuItem(title: "model: \(modelID)", action: nil, keyEquivalent: "")
        modelLabel.isEnabled = false
        menu.addItem(modelLabel)

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

    func setRecording(_ recording: Bool) {
        configureButton(recording: recording)
        stateLabel.title = recording ? "● recording" : "idle · hold fn to dictate"
    }

    func setTranscribing() {
        stateLabel.title = "transcribing…"
    }

    private func configureButton(recording: Bool) {
        guard let button = statusItem.button else { return }
        let image = Self.birdImage()
        image?.isTemplate = !recording
        button.image = image
        button.contentTintColor = recording ? NSColor.systemRed : nil
    }

    private static func birdImage() -> NSImage? {
        guard let url = Bundle.module.url(forResource: "bird", withExtension: "svg"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }
}
