import Foundation

/// What macOS says about the microphone, reduced to the three answers that
/// change what the setup window does. `restricted` folds into `denied`: both
/// mean the prompt will not appear again and the user has to go to Settings.
public enum MicrophonePermission: Sendable, Equatable {
    case granted, notDetermined, denied
}

/// The first-run window's rules, with no window attached.
///
/// ## Why there is a window at all
///
/// A fresh install has to do three slow things before it can dictate: collect
/// two permissions, download a 1.6 GB model, and let Core ML compile that
/// model for this machine — measured at 139–195 s for `whisper-large-v3-turbo`
/// and thrown away entirely if the process is quit partway through
/// (`WhisperWarmupPlan.specialisationNotice`). Ara is `LSUIElement`: launched
/// from Finder there is no terminal, no Dock icon and no window, so all of
/// that used to happen behind a menu bar item the user has not met yet. The
/// honest description of a first launch was "nothing happens for three
/// minutes".
///
/// The compile cannot be made shorter — it is one `MLModel.load` — and running
/// the model on the GPU to avoid it costs 2.5× per utterance, forever, which
/// is a bad trade for a wait that happens once. So the wait stays and the
/// silence goes.
///
/// ## Why the rules are here
///
/// The window is AppKit, a run loop and two system prompts; none of that is
/// reachable from a test. What *is* worth pinning — the order of the steps,
/// when the window appears at all, and the sentence that stops a user quitting
/// into the third minute of a compile — is all here, the same split
/// `WarmupStatus` and the `*MenuModel` types use.
public enum SetupFlow {
    /// Everything the decision needs, sampled by the caller from live system
    /// state rather than remembered. A permission the user revoked in Settings
    /// must bring the window back, not be answered from a flag written weeks
    /// ago.
    public struct State: Sendable, Equatable {
        public var microphone: MicrophonePermission
        public var accessibility: Bool
        public var modelPresent: Bool
        /// The one thing no amount of looking can answer: whether the Core ML
        /// compile has ever run to completion. Nothing on disk that we can
        /// read says so — the cache is private to Core ML and keyed on the
        /// signing identity — so this is remembered in the config instead.
        public var setupCompleted: Bool

        public init(microphone: MicrophonePermission, accessibility: Bool,
                    modelPresent: Bool, setupCompleted: Bool) {
            self.microphone = microphone
            self.accessibility = accessibility
            self.modelPresent = modelPresent
            self.setupCompleted = setupCompleted
        }
    }

    public enum Step: Sendable, Equatable, CaseIterable {
        case microphone, accessibility, restart, download, prepare, done
    }

    /// One step's words. `button` is `nil` for the steps that wait on macOS
    /// rather than on the user — offering a button there would only be
    /// offering a way to interrupt.
    public struct Copy: Sendable, Equatable {
        public var title: String
        public var detail: String
        public var button: String?
    }

    /// Whether the window is shown at all.
    ///
    /// Three of the four inputs are live state, so this answers "can ara work
    /// right now" and not "was it ever set up". The fourth is the compile,
    /// which cannot be observed.
    public static func isNeeded(_ state: State) -> Bool {
        step(state) != .done
    }

    /// The step to show.
    ///
    /// Permissions before downloads, deliberately: a user who abandons the
    /// window at the accessibility step should not already have spent 1.6 GB
    /// of somebody's network on a daemon they have not agreed to run. The
    /// microphone comes before accessibility because without it there is no
    /// dictation at all, while accessibility only stops the text reaching the
    /// cursor.
    public static func step(_ state: State) -> Step {
        if state.microphone != .granted { return .microphone }
        if !state.accessibility { return .accessibility }
        if !state.modelPresent { return .download }
        if !state.setupCompleted { return .prepare }
        return .done
    }

    /// The words, in the voice the iOS app uses: sentence case, no
    /// exclamation marks, and no congratulating a user for finishing a step
    /// ara asked them to do. Every claim has to stay literally true — the
    /// microphone line below is the macOS wording of the same promise the iOS
    /// `NSMicrophoneUsageDescription` makes.
    public static func copy(for step: Step) -> Copy {
        switch step {
        case .microphone:
            return Copy(
                title: "Allow the microphone",
                detail: "Ara records only while you hold the hotkey, and only "
                    + "on this Mac. Audio never leaves it.",
                button: "Allow microphone")
        case .accessibility:
            return Copy(
                title: "Allow accessibility",
                detail: "This lets Ara see the hotkey and type the text at your "
                    + "cursor. macOS gives the permission to a newly started "
                    + "copy, so Ara restarts itself once you switch it on.",
                button: "Open Settings")
        case .restart:
            // Never returned by `step(_:)`: no reading of system state can
            // tell "granted, needs a fresh process" from "not granted". The
            // window enters it when the user comes back from Settings, which
            // is the only moment anyone knows.
            return Copy(
                title: "Restart Ara to finish",
                detail: "Switch Ara on in the Accessibility list, then restart.",
                button: "Restart Ara")
        case .download:
            return Copy(
                title: "Downloading the speech model",
                detail: "About 1.6 GB, once. The model runs on this Mac, so "
                    + "this is the only time Ara needs the network.",
                button: nil)
        case .prepare:
            // The load-bearing sentence of the whole window. The compile is
            // all or nothing: a user who quits at 75 seconds of 145 has bought
            // nothing and starts over on the next launch.
            return Copy(
                title: "Preparing the model for this Mac",
                detail: "macOS compiles the model for this machine once. "
                    + "It takes a few minutes. Quitting now starts it over.",
                button: nil)
        case .done:
            return Copy(
                title: "Ara is ready",
                detail: "Hold your hotkey and speak. Ara waits in the menu bar.",
                button: "Start dictating")
        }
    }
}
