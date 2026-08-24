import AppKit
import ApplicationServices
import AVFoundation
import Foundation

/// The system side of the first-run window: what macOS currently says, and the
/// two prompts that ask it to say something else.
///
/// Split from `SetupFlow` because none of this is testable — every call here
/// reads or moves TCC state that belongs to the user's machine — and split
/// from `SetupWindow` because a view should not be raising system prompts.
public enum SetupPermissions {
    public static func microphone() -> MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        // `restricted` is a managed device refusing on the user's behalf.
        // Nothing the window can do differs from a denial, so it reads as one.
        default: return .denied
        }
    }

    public static func accessibility() -> Bool {
        AXIsProcessTrusted()
    }

    /// Raises the microphone prompt, or opens Settings when macOS will not
    /// prompt again.
    ///
    /// A denial is final for the lifetime of the grant: macOS shows the sheet
    /// exactly once per app identity, and every later request returns the
    /// stored answer without showing anything. A window that kept calling
    /// `requestAccess` would look broken, so a denied state goes to Settings
    /// instead.
    public static func requestMicrophone(then: @escaping @MainActor () -> Void) {
        guard microphone() == .notDetermined else {
            openSettings(pane: "Privacy_Microphone")
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor in then() }
        }
    }

    /// Opens the Accessibility pane, and asks macOS to list ara in it.
    ///
    /// The prompt call is what puts an unlisted app into the list — without
    /// it, a user sent to Settings finds nothing to switch on.
    public static func requestAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        openSettings(pane: "Privacy_Accessibility")
    }

    public static func openSettings(pane: String) {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Starts ara again and leaves.
///
/// macOS binds an accessibility grant to a process at launch: a process that
/// was running when the switch was flipped keeps being untrusted for its whole
/// life, no matter how many times it asks. `ara setup` has always told the
/// user to run the command again for exactly this reason. A window cannot ask
/// that of someone who has never seen a terminal, so it does it for them.
public enum Relaunch {
    /// - Parameter delay: seconds to wait before the replacement starts.
    ///   Non-zero so the current process is gone first — two copies of a
    ///   menu-bar daemon competing for one hotkey tap is worse than a moment
    ///   with none.
    public static func now(delay: TimeInterval = 0.5) -> Never {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            // Fire and forget: this process is about to exit, and waiting for
            // the completion handler of a launch that starts after we are gone
            // is waiting for nobody.
            NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)
            exit(0)
        }
        // A binary run straight from a terminal — a development build, or an
        // install into `~/.local/bin`. `open` has nothing to work with, so the
        // replacement is spawned directly, after this process has quit.
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let arguments = Array(CommandLine.arguments.dropFirst())
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        let quoted = ([executable] + arguments)
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        shell.arguments = ["-c", "sleep \(delay); exec \(quoted)"]
        do {
            try shell.run()
        } catch {
            // The one thing worse than a failed relaunch is a silent one: the
            // user pressed a button called "Restart Ara" and the app would
            // simply cease to exist, with no window, no menu bar item and
            // nothing to read.
            FileHandle.standardError.write(Data(
                "relaunch failed (\(type(of: error))); start ara again yourself\n".utf8))
        }
        exit(0)
    }
}
