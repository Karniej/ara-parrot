import AppKit
import AraCore
import Darwin
import Foundation

/// What a startup check failure looks like when there is nobody to read stderr.
///
/// The daemon is `LSUIElement`: no Dock icon, no window, and — launched from
/// Finder — no terminal. Exiting on a failed check therefore produced an app
/// that appeared to do nothing whatsoever, which is what a fresh install looks
/// like every time: TCC files microphone and accessibility grants under the
/// *bundle's* identity, so a newly installed copy has none of them and fails
/// its own preflight. Run the same binary from a terminal and it inherits the
/// terminal's grants instead, which is why this never reproduced in
/// development.
enum StartupFailure {
    /// Whether anyone can see what we write to stderr. `isatty` is the whole
    /// test: a terminal means a human is reading, a pipe or `/dev/null` means
    /// launchd or Finder started us and the text goes nowhere.
    static func hasReadableTerminal() -> Bool {
        isatty(STDERR_FILENO) == 1
    }

    /// Shows the failures in an alert and exits. Never returns.
    ///
    /// Sets the activation policy to `.regular` first: an accessory app cannot
    /// bring an alert to the front, so without it the dialog exists behind
    /// every other window and the app still looks dead.
    static func presentAndExit(_ checks: [Check]) -> Never {
        let detail = Check.failureSummary(checks)
            ?? "A startup check failed. Run `ara doctor` in a terminal for detail."

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Ara cannot start yet"
        alert.informativeText = detail
            + "\n\nmacOS grants these to each copy of an app separately, so a "
            + "newly installed Ara has to be granted them again."
        alert.addButton(withTitle: "Open Privacy Settings")
        alert.addButton(withTitle: "Quit")

        if alert.runModal() == .alertFirstButtonReturn {
            // Straight to the pane that matters. Microphone first when it is
            // the failure, because dictation cannot start without it at all;
            // accessibility only stops the text being typed.
            let pane = Check.failed(checks, nameContains: "microphone")
                ? "Privacy_Microphone"
                : "Privacy_Accessibility"
            if let url = URL(string:
                "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                NSWorkspace.shared.open(url)
            }
        }
        exit(1)
    }
}
