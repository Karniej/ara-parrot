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

    /// Shows the permission steps and never returns.
    ///
    /// Ends by starting the daemon in this same process, through `then` —
    /// which is why the window can stay on screen across the handover. It only
    /// leaves through `Relaunch` if the user asks for a restart.
    ///
    /// - Parameter then: the rest of the daemon. Called on the main actor,
    ///   inside the run loop this method starts, the moment both permissions
    ///   are in place. It is handed the window so the daemon can go on using
    ///   it — the download and the compile are the next two steps of the same
    ///   setup, and opening a second window for them would undo the point.
    static func collectPermissions(step: SetupFlow.Step,
                                   then start: @escaping @MainActor (SetupWindow) -> Void) -> Never {
        let app = NSApplication.shared
        let window = SetupWindow()
        // Closing the window ends the launch. There is nothing else running:
        // the daemon has not started, because it cannot start without the
        // permission this window is collecting. Staying alive would leave a
        // process with no window, no menu bar item and no hotkey — ara would
        // look installed and be inert until the user found it in Activity
        // Monitor.
        window.onClose = {
            FileHandle.standardError.write(Data(
                ("setup was closed before ara could start; run it again when "
                    + "you are ready\n").utf8))
            NSApp.terminate(nil)
        }
        window.onAction = { step in
            switch step {
            case .microphone:
                SetupPermissions.requestMicrophone {
                    // The answer arrives on a background queue and lands here;
                    // repainting from the poll below would work too, but a
                    // window that changes the moment the sheet closes is the
                    // difference between "it noticed" and "did that work?".
                    refresh(window, then: start)
                }
            case .accessibility:
                SetupPermissions.requestAccessibility()
                // Straight to the waiting step, which is where the restart
                // button lives. The poll takes the window off it by itself
                // once macOS reports the grant.
                report(.restart)
                window.update(step: .restart)
            case .restart:
                Relaunch.now()
            case .download, .prepare, .done:
                break
            }
        }
        report(step)
        window.show(step: step)

        Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { timer in
            Task { @MainActor in
                if refresh(window, then: start) { timer.invalidate() }
            }
        }
        app.run()
        // `NSApplication.run` does not return; the compiler cannot know that.
        Relaunch.now()
    }

    /// One line per step, because the permission phase used to write nothing
    /// at all. An app launched from Finder has no terminal, so this reaches a
    /// file only when someone runs ara from one or captures its stderr — but
    /// when a user says "it crashed", the difference between an empty log and
    /// a log that ends at a named step is the difference between guessing and
    /// knowing.
    private static func report(_ step: SetupFlow.Step) {
        guard step != lastReported else { return }
        lastReported = step
        FileHandle.standardError.write(Data(
            "setup: \(SetupFlow.copy(for: step).title.lowercased())\n".utf8))
    }

    private static var lastReported: SetupFlow.Step?
    /// Whether the handover has already happened, so a poll that fires while
    /// the daemon is starting cannot start it twice.
    private static var started = false

    /// Re-reads both permissions, and either moves the window on or hands
    /// control to the daemon. Answers whether the handover happened.
    ///
    /// Both are read fresh every time rather than remembered: the whole reason
    /// this polls is that Settings tells us nothing when the user flips a
    /// switch, and the measured behaviour is that `AXIsProcessTrusted` starts
    /// answering true about a second later, in this same process.
    @discardableResult
    private static func refresh(_ window: SetupWindow,
                                then start: @MainActor (SetupWindow) -> Void) -> Bool {
        guard !started else { return true }
        let microphone = SetupPermissions.microphone()
        if microphone == .granted, SetupPermissions.accessibility() {
            started = true
            FileHandle.standardError.write(Data(
                "setup: both permissions granted; starting ara\n".utf8))
            // The window is deliberately left up. The daemon's warm-up takes
            // it over on the next repaint — the download and the compile are
            // steps of the same setup — and the user sees one window walk from
            // the first permission to a working dictation, rather than an app
            // that disappears and comes back.
            start(window)
            return true
        }
        // A user parked on the restart step is left there. They have been sent
        // to Settings and told what to press; moving them back to the step
        // they just completed would read as the app losing their work.
        if window.currentStep == .restart, microphone == .granted { return false }
        let next: SetupFlow.Step = microphone == .granted ? .accessibility : .microphone
        report(next)
        window.update(step: next)
        return false
    }
}
