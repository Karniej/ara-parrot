import Foundation

public struct ModeRegistry: Sendable {
    private let modes: [String: Mode]
    private let order: [String]

    public init(userModes: [Mode]) {
        var merged = [String: Mode]()
        var ids = [String]()
        for m in Self.builtIns + userModes {
            if merged[m.id] == nil { ids.append(m.id) }
            merged[m.id] = m   // user modes are appended last, so they win
        }
        self.modes = merged
        self.order = ids
    }

    public func mode(id: String) -> Mode? { modes[id] }
    public var all: [Mode] { order.compactMap { modes[$0] } }

    /// The built-in "default" mode, hoisted into its own constant so there is
    /// exactly one definition — `builtIns` references it, and `ModeResolver`
    /// uses it as a belt-and-braces fallback instead of indexing into
    /// `builtIns` positionally.
    public static let defaultMode = Mode(
        id: "default", name: "Default",
        prompt: "Remove filler words and false starts. Repair sentence "
              + "boundaries and capitalisation. Preserve the speaker's "
              + "wording and meaning exactly.",
        appBundleIDs: [], usesLLM: true)

    static let builtIns: [Mode] = [
        Mode(id: "verbatim", name: "Verbatim",
             prompt: "",
             appBundleIDs: [], usesLLM: false),
        defaultMode,
        Mode(id: "email", name: "Email",
             prompt: "Rewrite as polished email prose with paragraph breaks. "
                   + "Do not invent a greeting or sign-off that was not spoken.",
             appBundleIDs: ["com.apple.mail", "com.readdle.smartemail-Mac"],
             usesLLM: true),
        Mode(id: "chat", name: "Chat",
             prompt: "Rewrite as a terse chat message. No greeting, no "
                   + "pleasantries, no sign-off.",
             appBundleIDs: ["com.tinyspeck.slackmacgap", "com.hnc.Discord",
                            "com.apple.MobileSMS"],
             usesLLM: true),
        Mode(id: "code", name: "Code",
             prompt: "Rewrite as a concise technical note. Preserve identifiers, "
                   + "file paths and symbols exactly as spoken. Do not turn "
                   + "technical terms into prose.",
             // Editors and terminals: dictating into either means identifiers,
             // paths and commands, not prose. The terminal ids are the same
             // ones `InjectionPolicy` prefers paste for — kept as two lists
             // because they answer different questions (how to format vs. how
             // to deliver), but a terminal that belongs on one belongs on both.
             appBundleIDs: ["com.microsoft.VSCode", "com.apple.dt.Xcode",
                            "com.todesktop.230313mzl4w4u92",
                            "com.apple.Terminal", "com.googlecode.iterm2",
                            "net.kovidgoyal.kitty", "org.alacritty",
                            "com.github.wez.wezterm"],
             usesLLM: true),
    ]
}
