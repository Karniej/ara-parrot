import UIKit

/// The throwaway keyboard whose only job is to run the three experiments from
/// *inside* `com.apple.keyboard-service` and get the answers out.
///
/// This keyboard does not type and does not dictate — it is an instrument.
/// One primary button runs all three checks in order; `Type results` reports
/// by inserting the log into the focused text field, because an appex has no
/// stderr anyone can read and this needs no App Group, no entitlements, no
/// server.
final class KeyboardViewController: UIInputViewController {
    private let log = UITextView()
    private var lines: [String] = []
    private var running = false
    private var runAllButton: UIButton!
    private var typeButton: UIButton!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.06, alpha: 1)

        let explainer = UILabel()
        explainer.text = "Test keyboard — it doesn't type. Run the tests, then send the results."
        explainer.font = .systemFont(ofSize: 12)
        explainer.textColor = UIColor(white: 1, alpha: 0.55)
        explainer.numberOfLines = 2

        var primary = UIButton.Configuration.borderedProminent()
        primary.title = "▶  Run all 4 tests (~40 s)"
        primary.baseBackgroundColor = UIColor(red: 1, green: 0.68, blue: 0.35, alpha: 1)
        primary.baseForegroundColor = .black
        runAllButton = UIButton(configuration: primary, primaryAction:
            UIAction { [weak self] _ in self?.runAll() })

        var relayOnly = UIButton.Configuration.bordered()
        relayOnly.title = "4 only"
        let relayButton = UIButton(configuration: relayOnly, primaryAction:
            UIAction { [weak self] _ in
                guard let self, !self.running else { return }
                self.append(["", "▶ test 4 alone…"])
                Task { @MainActor [weak self] in
                    self?.append(await RelayProbe.observeRelay())
                    self?.typeButton.isEnabled = true
                }
            })

        var secondary = UIButton.Configuration.bordered()
        secondary.title = "⌨️  Type results"
        typeButton = UIButton(configuration: secondary, primaryAction:
            UIAction { [weak self] _ in
                guard let self else { return }
                self.textDocumentProxy.insertText(self.lines.joined(separator: "\n") + "\n")
            })
        typeButton.isEnabled = false

        log.isEditable = false
        log.backgroundColor = .clear
        log.textColor = UIColor(red: 1, green: 0.75, blue: 0.46, alpha: 1)
        log.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

        let buttonRow = UIStackView(arrangedSubviews: [typeButton, relayButton])
        buttonRow.distribution = .fillProportionally
        buttonRow.spacing = 6
        let stack = UIStackView(arrangedSubviews: [explainer, runAllButton, buttonRow, log])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            view.heightAnchor.constraint(equalToConstant: 360),
        ])

        // `hasFullAccess` is the variable the whole pass is run against — the
        // plan wants one pass with it on and one with it off.
        append(Experiments.header(context: "KEYBOARD EXTENSION",
                                  fullAccess: hasFullAccess))
        append(["ready — tap ▶ to run"])
    }

    /// All three, in order, one tap. The mic test records ~1 s by itself —
    /// there is nothing to hold and nothing to say; it only counts frames.
    private func runAll() {
        guard !running else { return }
        running = true
        runAllButton.isEnabled = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.append(["", "▶ test 1/4: Apple's on-device AI model…"])
            self.append(await Experiments.foundationModels())
            self.append(["", "▶ test 2/4: microphone (records ~1 s, just wait)…"])
            self.append(await Experiments.microphone())
            self.append(["", "▶ test 3/4: on-device speech-to-text…"])
            self.append(await Experiments.onDeviceASR())
            self.append(["", "▶ test 4/4: container relay (tap Start in the app first)…"])
            self.append(await RelayProbe.observeRelay())
            self.append(["", "✔ done — tap “Type results” with a text field focused,",
                         "then run the same pass with Full Access off."])
            self.running = false
            self.runAllButton.isEnabled = true
            self.typeButton.isEnabled = true
        }
    }

    private func append(_ new: [String]) {
        lines.append(contentsOf: new)
        log.text = lines.joined(separator: "\n")
        log.scrollRangeToVisible(NSRange(location: max(0, log.text.count - 1), length: 1))
    }
}
