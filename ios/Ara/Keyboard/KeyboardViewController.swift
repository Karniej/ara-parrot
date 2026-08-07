import SwiftUI
import UIKit

/// The extension's entry point: hosts the SwiftUI keyboard, owns the
/// `UITextDocumentProxy`, and hands both to the key grid via `KeyboardBridge`.
final class KeyboardViewController: UIInputViewController {
    private var bridge: KeyboardBridge?

    override func viewDidLoad() {
        super.viewDidLoad()
        let bridge = KeyboardBridge(controller: self)
        self.bridge = bridge
        let host = UIHostingController(rootView: KeyboardRootView(bridge: bridge))
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
        bridge?.refreshEnvironment()
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

    init(controller: KeyboardViewController) {
        self.controller = controller
        refreshEnvironment()
    }

    func refreshEnvironment() {
        guard let controller else { return }
        needsGlobeKey = controller.needsInputModeSwitchKey
        hasFullAccess = controller.hasFullAccess
    }

    var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }

    func insert(_ text: String) { proxy?.insertText(text) }
    func deleteBackward() { proxy?.deleteBackward() }
    func advanceToNextInputMode() { controller?.advanceToNextInputMode() }
    func dismiss() { controller?.dismissKeyboard() }
}

/// Placeholder until Task 3 lands the QWERTY grid.
struct KeyboardRootView: View {
    @ObservedObject var bridge: KeyboardBridge

    var body: some View {
        VStack {
            Text("Ara keyboard — under construction")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 216)
        .background(Theme.background)
    }
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
