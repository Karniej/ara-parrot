import UIKit

/// The throwaway keyboard whose only job is to run the three experiments from
/// *inside* `com.apple.keyboard-service` and get the answers out.
///
/// Reporting channel: the keyboard types its own report into whatever text
/// field is focused (`Type report`), because an appex has no stderr anyone can
/// read and this needs no App Group, no entitlements, no server. Open Notes,
/// switch to this keyboard, run, tap Type report.
final class KeyboardViewController: UIInputViewController {
    private let log = UITextView()
    private var lines: [String] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.06, alpha: 1)

        log.isEditable = false
        log.backgroundColor = .clear
        log.textColor = UIColor(red: 1, green: 0.75, blue: 0.46, alpha: 1)
        log.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

        let buttons = [
            button("1 FM") { await Experiments.foundationModels() },
            button("2 Mic") { await Experiments.microphone() },
            button("3 ASR") { await Experiments.onDeviceASR() },
        ]
        let typeButton = UIButton(configuration: .borderedProminent(), primaryAction:
            UIAction(title: "Type report") { [weak self] _ in
                guard let self else { return }
                self.textDocumentProxy.insertText(self.lines.joined(separator: "\n") + "\n")
            })
        let clearButton = UIButton(configuration: .bordered(), primaryAction:
            UIAction(title: "Clear") { [weak self] _ in
                self?.lines = []
                self?.log.text = ""
            })

        let row1 = UIStackView(arrangedSubviews: buttons)
        row1.distribution = .fillEqually
        row1.spacing = 6
        let row2 = UIStackView(arrangedSubviews: [typeButton, clearButton])
        row2.distribution = .fillEqually
        row2.spacing = 6
        let stack = UIStackView(arrangedSubviews: [row1, row2, log])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            view.heightAnchor.constraint(equalToConstant: 340),
        ])

        // `hasFullAccess` is the variable every experiment is run against —
        // the plan calls for one pass with it on and one with it off.
        append(Experiments.header(context: "KEYBOARD EXTENSION",
                                  fullAccess: hasFullAccess))
    }

    private func button(_ title: String,
                        run: @escaping () async -> [String]) -> UIButton {
        UIButton(configuration: .bordered(), primaryAction:
            UIAction(title: title) { [weak self] _ in
                self?.append(["… running \(title)"])
                Task { @MainActor [weak self] in
                    self?.append(await run())
                }
            })
    }

    private func append(_ new: [String]) {
        lines.append(contentsOf: new)
        log.text = lines.joined(separator: "\n")
        log.scrollRangeToVisible(NSRange(location: max(0, log.text.count - 1), length: 1))
    }
}
