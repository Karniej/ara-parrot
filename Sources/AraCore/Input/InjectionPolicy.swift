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

    /// An explicit setting is absolute; `auto` consults the list. An unknown
    /// or absent frontmost app types — the conservative choice, because typing
    /// never touches state the user can see, while paste briefly does.
    public static func method(setting: InjectionSetting,
                              frontmostBundleID: String?) -> InjectionMethod {
        switch setting {
        case .type: return .type
        case .paste: return .paste
        case .auto:
            guard let id = frontmostBundleID else { return .type }
            return pastePreferredBundleIDs.contains(id) ? .paste : .type
        }
    }
}
