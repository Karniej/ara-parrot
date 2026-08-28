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
        /// Whether the config names a transcription model. Absent means the
        /// language question has never been answered — the *value* cannot say
        /// so, because the default is itself a valid answer.
        public var modelChosen: Bool
        /// The same, for cleanup: whether the config says anything about it.
        public var cleanupChosen: Bool
        public var modelPresent: Bool
        /// The one thing no amount of looking can answer: whether the Core ML
        /// compile has ever run to completion. Nothing on disk that we can
        /// read says so — the cache is private to Core ML and keyed on the
        /// signing identity — so this is remembered in the config instead.
        public var setupCompleted: Bool

        public init(microphone: MicrophonePermission, accessibility: Bool,
                    modelChosen: Bool = true, cleanupChosen: Bool = true,
                    modelPresent: Bool, setupCompleted: Bool) {
            self.microphone = microphone
            self.accessibility = accessibility
            self.modelChosen = modelChosen
            self.cleanupChosen = cleanupChosen
            self.modelPresent = modelPresent
            self.setupCompleted = setupCompleted
        }
    }

    public enum Step: Sendable, Equatable, CaseIterable {
        case microphone, accessibility, restart, languages, rewriting,
             download, prepare, done
    }

    /// Which of a step's two buttons was pressed.
    ///
    /// `primary` on the steps that only have one, so a caller that does not
    /// care never has to look.
    public enum Answer: Sendable, Equatable {
        case primary, alternative
    }

    /// One step's words. `button` is `nil` for the steps that wait on macOS
    /// rather than on the user — offering a button there would only be
    /// offering a way to interrupt.
    public struct Copy: Sendable, Equatable {
        public var title: String
        public var detail: String
        public var button: String?
        /// The second answer, on the steps that ask a question rather than
        /// wait for one thing. A question with one button is not a question —
        /// it makes the unshown answer invisible rather than optional.
        public var alternative: String?

        public init(title: String, detail: String,
                    button: String? = nil, alternative: String? = nil) {
            self.title = title
            self.detail = detail
            self.button = button
            self.alternative = alternative
        }
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
        // Both questions before the download, because the first one decides
        // what gets downloaded: 620 MB of the fast transcriber or 1.6 GB of
        // the one that speaks ninety-nine languages. Asking afterwards would
        // mean fetching the wrong one first.
        if !state.modelChosen { return .languages }
        if !state.cleanupChosen { return .rewriting }
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
                    + "cursor. Switch Ara on in the list and it carries on by "
                    + "itself.",
                button: "Open Settings")
        case .restart:
            // Never returned by `step(_:)`. The window enters it when the user
            // comes back from Settings, and leaves it on its own the moment
            // macOS reports the grant — measured at about a second after the
            // switch is flipped, in the same process.
            //
            // The button is a fallback, not the path. Trust arriving is proven;
            // an event tap armed *after* it arriving is not, so if the hotkey
            // stays dead there is still one thing to press.
            return Copy(
                title: "Waiting for the switch",
                detail: "Switch Ara on in the Accessibility list. Ara continues "
                    + "on its own when macOS reports it — a restart is only "
                    + "needed if the hotkey stays dead.",
                button: "Restart Ara")
        case .languages:
            // No model is named. Someone installing a dictation app knows
            // which languages they speak and does not know what a Parakeet
            // is, so the question is asked in the only terms they have.
            //
            // The 25 are not listed either: a wall of language names is worse
            // to read than the one thing that distinguishes them, which is
            // that they are European.
            return Copy(
                title: "Which languages do you dictate in?",
                detail: "Ara's fast setting covers English and 24 other "
                    + "European languages. Everything else — Japanese, "
                    + "Chinese, Arabic, Hindi and about sixty more — needs the "
                    + "slower one, which is roughly five times the wait per "
                    + "sentence.",
                button: "European languages",
                alternative: "I need the others")
        case .rewriting:
            // "Rewrite" rather than "cleanup" or "intelligence": it names what
            // actually happens to the words, which is the thing a user might
            // not want.
            return Copy(
                title: "Should Ara rewrite what you say?",
                detail: "Ara always types what you said, with punctuation. It "
                    + "can also tidy it — dropping filler words, repairing "
                    + "half-finished sentences, and matching the tone of the "
                    + "app you are dictating into. That costs about a second "
                    + "per sentence and a gigabyte of memory.",
                button: "Just type it",
                alternative: "Tidy it up")
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
