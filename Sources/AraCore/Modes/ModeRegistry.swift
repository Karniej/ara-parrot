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

    public static let builtIns: [Mode] = [
        Mode(id: "verbatim", name: "Verbatim",
             prompt: "",
             appBundleIDs: [], usesLLM: false),
        Mode(id: "default", name: "Default",
             prompt: "Remove filler words and false starts. Repair sentence "
                   + "boundaries and capitalisation. Preserve the speaker's "
                   + "wording and meaning exactly.",
             appBundleIDs: [], usesLLM: true),
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
             appBundleIDs: ["com.microsoft.VSCode", "com.apple.dt.Xcode",
                            "com.cmuxterm.app"],
             usesLLM: true),
    ]
}
