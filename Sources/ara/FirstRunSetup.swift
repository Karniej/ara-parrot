import AppKit
import AraCore
import Foundation

/// The permission half of the first-run window, and the only part of the
/// daemon that runs *instead of* the daemon.
///
/// ## Why this launch does nothing else
///
/// Both permissions gate the whole product: without the microphone there is no
/// audio, and without accessibility `HotkeyMonitor.start` cannot create its
/// event tap at all — it throws, and the old code exited with two lines on a
/// stderr that a Finder launch does not have. Neither can be repaired inside a
/// running process either: macOS decides a process's accessibility trust when
/// it starts, so the grant the user is about to give belongs to the *next*
/// launch, not this one.
///
/// So a launch that finds a permission missing does one thing — ask for it,
/// and then restart itself. Everything after that point is the ordinary
/// startup path, unchanged, running on a process that has what it needs.
@MainActor
enum FirstRunSetup {
    /// How often the window re-reads the system's answer. The microphone
    /// prompt reports back through its own callback, but Settings does not:
    /// a user who switches ara on in the Accessibility list gets no event, so
    /// the only way to notice is to keep asking.
    private static let pollInterval: TimeInterval = 0.5

    /// Shows the permission steps and never returns. Ends in `Relaunch`, which
    /// exits.
    static func runPermissions(step: SetupFlow.Step) -> Never {
        let app = NSApplication.shared
        let window = SetupWindow()
        window.onAction = { step in
            switch step {
            case .microphone:
                SetupPermissions.requestMicrophone {
                    // The answer arrives on a background queue and lands here;
                    // repainting from the poll below would work too, but a
                    // window that changes the moment the sheet closes is the
                    // difference between "it noticed" and "did that work?".
                    refresh(window)
                }
            case .accessibility:
                SetupPermissions.requestAccessibility()
                // Straight to the restart step. macOS will not tell this
                // process that the grant landed — see `SetupFlow.Step.restart`
                // — so the user, who can see the switch, is the one who says.
                window.update(step: .restart)
            case .restart:
                Relaunch.now()
            case .download, .prepare, .done:
                break
            }
        }
        window.show(step: step)

        Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in
            Task { @MainActor in refresh(window) }
        }
        app.run()
        // `NSApplication.run` does not return; the compiler cannot know that.
        Relaunch.now()
    }

    /// Re-reads both permissions and moves the window if they changed.
    ///
    /// Once both are granted the process restarts rather than continuing: this
    /// launch has already skipped building the daemon, and a live accessibility
    /// grant does not apply to a process that started without it.
    private static func refresh(_ window: SetupWindow) {
        let microphone = SetupPermissions.microphone()
        let accessibility = SetupPermissions.accessibility()
        if microphone == .granted, accessibility {
            Relaunch.now()
        }
        // A user parked on the restart step is left there. They have been sent
        // to Settings and told what to press; moving them back to the step
        // they just completed would read as the app losing their work.
        if window.currentStep == .restart, microphone == .granted { return }
        window.update(step: microphone == .granted ? .accessibility : .microphone)
    }
}
