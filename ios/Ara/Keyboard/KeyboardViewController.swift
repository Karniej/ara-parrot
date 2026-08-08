import SwiftUI
import UIKit

/// The extension's entry point: hosts the SwiftUI keyboard, owns the
/// `UITextDocumentProxy`, and hands both to the key grid via `KeyboardBridge`.
final class KeyboardViewController: UIInputViewController {
    private var bridge: KeyboardBridge?
    private var state: KeyboardState?
    private var bar: SuggestionBarModel?

    /// A custom keyboard gets the system's default height unless it asks for
    /// its own. Below `.required` so the system's transient layout passes
    /// (rotation, split view) resolve instead of logging conflicts.
    private lazy var heightConstraint: NSLayoutConstraint = {
        let constraint = view.heightAnchor
            .constraint(equalToConstant: KeyboardMetrics.totalHeight)
        constraint.priority = UILayoutPriority(999)
        return constraint
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        let bridge = KeyboardBridge(controller: self)
        let state = KeyboardState(bridge: bridge)
        let bar = SuggestionBarModel(bridge: bridge)
        self.bridge = bridge
        self.state = state
        self.bar = bar
        let host = UIHostingController(
            rootView: KeyboardRootView(bridge: bridge, state: state, bar: bar))
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        #if DEBUG
        logAvailableMemory("keyboard viewDidLoad")
        #endif
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        heightConstraint.isActive = true
        // A keyboard inherits the *host app's* interface style — exactly
        // wrong for a user forcing light because their display struggles
        // with dark. The App-Group setting wins; `.unspecified` restores
        // host-following for "system".
        view.window?.overrideUserInterfaceStyle = Appearance.current.interfaceStyle
        view.overrideUserInterfaceStyle = Appearance.current.interfaceStyle
        bridge?.refreshEnvironment()
        // Proof-of-life for the app's onboarding: only reachable with Full
        // Access, which is exactly what page ② is asking the user to grant.
        if bridge?.hasFullAccess == true { Relay.markKeyboardSeen() }
        bridge?.loadEngineState()
        state?.activate()
        bar?.refreshMicState()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        state?.deactivate()
        bridge?.releaseEngineState()
    }

    /// The host can move the caret without us — respect the new context so
    /// the shift key does not claim a sentence start that moved away.
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        state?.hostChangedText()
    }
}

/// The seam between SwiftUI keys and the UIKit input controller. Everything
/// the keys need — text insertion, host traits, Full Access, the globe key —
/// crosses here, so the SwiftUI layer stays testable and controller-free.
@MainActor
final class KeyboardBridge: ObservableObject {
    private weak var controller: KeyboardViewController?

    @Published var needsGlobeKey = true
    @Published var hasFullAccess = false

    /// Engine state is loaded per appearance and dropped on the way out: the
    /// extension process outlives the keyboard, and anything retained across
    /// invocations is a jetsam vector. Reading it per keystroke would be the
    /// opposite mistake — a file read on the typing path.
    private(set) var snippets = Snippets()
    private(set) var hapticsEnabled = true

    init(controller: KeyboardViewController) {
        self.controller = controller
        refreshEnvironment()
    }

    func refreshEnvironment() {
        guard let controller else { return }
        needsGlobeKey = controller.needsInputModeSwitchKey
        hasFullAccess = controller.hasFullAccess
    }

    func loadEngineState() {
        snippets = EngineProvider.loadSnippets()
        hapticsEnabled = EngineProvider.hapticsEnabled()
    }

    func releaseEngineState() {
        snippets = Snippets()
        hapticsEnabled = true
    }

    var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }

    /// Truncated by the host at its own discretion — callers treat it as a
    /// hint about the tail of the text, never as the document.
    var contextBeforeInput: String? { proxy?.documentContextBeforeInput }

    var returnKeyType: UIReturnKeyType { proxy?.returnKeyType ?? .default }

    var autocapitalizationType: UITextAutocapitalizationType {
        proxy?.autocapitalizationType ?? .sentences
    }

    func insert(_ text: String) { proxy?.insertText(text) }
    func deleteBackward() { proxy?.deleteBackward() }
    func advanceToNextInputMode() { controller?.advanceToNextInputMode() }
    func dismiss() { controller?.dismissKeyboard() }
}

#if DEBUG
import os
/// Jetsam kills keyboards with no crash report; this line in the debug
/// console is the only early warning there is.
func logAvailableMemory(_ where_: String) {
    let mb = os_proc_available_memory() / 1_048_576
    Logger(subsystem: "com.silpho.ara", category: "memory")
        .debug("\(where_, privacy: .public): \(mb) MB available")
}
#endif
