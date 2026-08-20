import Foundation

/// What the user asked for — the `inject` config key or the `--inject` flag.
///
/// `auto` is the default and the reason this is three values rather than two:
/// neither mechanism is right everywhere. Typing leaves the pasteboard alone
/// but is dropped or mangled by terminals and Electron apps; paste works
/// everywhere those live but briefly occupies the pasteboard. `auto` sends
/// each utterance down the path that works in the app it was spoken into.
public enum InjectionSetting: String, CaseIterable, Sendable {
    case auto, type, paste

    public static var valueNames: String {
        allCases.map(\.rawValue).joined(separator: ", ")
    }
}

/// The mechanism actually used for one utterance.
public enum InjectionMethod: Sendable, Equatable {
    case type, paste
}

/// Decides `InjectionMethod` per utterance, from the setting and the app the
/// utterance was spoken into — the same by-value `frontmostBundleID` that mode
/// resolution already carries, sampled at hotkey release (see `FrontmostApp`
/// for why it must be carried, not re-read).
public enum InjectionPolicy {
    /// The apps where `auto` picks paste: terminals, Electron apps, and
    /// editors, which drop or reorder synthesized unicode keyboard events.
    /// Every serious dictation tool pastes into these. One list, one place —
    /// extend it here.
    ///
    /// A list is the wrong shape for this problem and is known to be: it
    /// fails silently for every app nobody has added yet, and the symptom is
    /// mangled text rather than an error. It is kept because the alternative —
    /// pasting everywhere by default — puts the transcript on the pasteboard
    /// of every app the user dictates into, which is a privacy cost paid
    /// always to fix a problem that happens sometimes.
    ///
    /// A wrong identifier here is inert: it matches nothing, and that app goes
    /// on typing exactly as it did before. So the risk of adding one is
    /// bounded, and the entries below that could be checked against a real
    /// install were — `notion.id` and `com.apple.dt.Xcode` among them.
    public static let pastePreferredBundleIDs: Set<String> = [
        "com.apple.Terminal",             // Terminal
        "com.googlecode.iterm2",          // iTerm2
        "com.microsoft.VSCode",           // Visual Studio Code
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.tinyspeck.slackmacgap",      // Slack
        "com.hnc.Discord",                // Discord
        "net.kovidgoyal.kitty",           // kitty
        "org.alacritty",                  // Alacritty
        "com.github.wez.wezterm",         // WezTerm
        "com.mitchellh.ghostty",          // Ghostty
        "dev.warp.Warp-Stable",           // Warp
        "co.zeit.hyper",                  // Hyper
        "notion.id",                      // Notion
        "md.obsidian",                    // Obsidian
        "com.linear",                     // Linear
        "dev.zed.Zed",                    // Zed
        "com.apple.dt.Xcode",             // Xcode
    ]

    /// The transcript length above which `auto` pastes in *any* app.
    ///
    /// The list above answers "which apps mangle typing". This answers the
    /// other half, which the list cannot: **how much** text is being typed.
    /// `TextInjector` has to split anything past about 20 UTF-16 units across
    /// several `CGEvent`s, and the order those events are committed in is not
    /// something the API promises. Two field captures, in two different apps
    /// neither of which is on the list, each had exactly one whole chunk
    /// overtaken by the rest and committed at the end:
    ///
    /// ```text
    /// ...everywhere, but not[ from VidNotes web. ]And it looked like...
    ///                       └──── moved here ────────────────────────┐
    /// ...my transcribed videos in my library. from VidNotes web.  ←───┘
    /// ```
    ///
    /// Nothing is lost or duplicated, so it never looks like a delivery
    /// failure — it looks like the user dictated a sentence in the wrong
    /// order. Pacing the events apart made it rarer and could not make it
    /// impossible. A paste is one event and has nothing to reorder.
    ///
    /// One hundred characters, which is roughly five events: past the point
    /// where a single misplaced fragment changes what a sentence means, and
    /// well above the short "yes, do that" utterances that make up most
    /// dictation. Those keep typing and keep the pasteboard untouched, which
    /// is the whole reason this is a threshold and not simply "always paste".
    ///
    /// It is a judgement, not a measurement: both captures were far above it
    /// (186 and ~290 characters) and there is no observation at all of what
    /// two or three events do. Lower it if a shorter transcript ever arrives
    /// scrambled.
    public static let pasteAboveCharacters = 100

    /// An explicit setting is absolute; `auto` pastes when the app is known to
    /// mangle typed events, when there is enough text for the ordering of those
    /// events to matter, or when a single character cannot survive the typed
    /// path at all. An unknown or absent frontmost app still types short
    /// transcripts — the conservative choice, because typing never touches
    /// state the user can see, while paste briefly does.
    ///
    /// `text` is the transcript about to be delivered, passed whole rather than
    /// as a length because two of the three questions above are about its
    /// contents.
    public static func method(setting: InjectionSetting,
                              frontmostBundleID: String?,
                              text: String = "") -> InjectionMethod {
        switch setting {
        case .type: return .type
        case .paste: return .paste
        case .auto:
            if text.count > pasteAboveCharacters { return .paste }
            if containsUntypableCharacter(text) { return .paste }
            guard let id = frontmostBundleID else { return .type }
            return pastePreferredBundleIDs.contains(id) ? .paste : .type
        }
    }

    /// Whether any single character is too large for one keyboard event.
    ///
    /// `TextInjector` never splits a character, because half a grapheme is not
    /// text — so a character whose own UTF-16 encoding is longer than the
    /// event payload limit is handed to the API oversized, and the API
    /// truncates it. A long emoji sequence (a family, a flag with a skin-tone
    /// modifier) or a stacked run of combining marks reaches that size.
    ///
    /// Neither splitting nor sending it oversized delivers the character, so
    /// the only honest answer is to stop typing and paste the transcript. This
    /// is rare enough to cost nothing and silent enough to be worth catching:
    /// the user would otherwise see a mangled glyph and no error.
    static func containsUntypableCharacter(_ text: String) -> Bool {
        text.contains { $0.utf16.count > TextInjector.chunkLimit }
    }
}
