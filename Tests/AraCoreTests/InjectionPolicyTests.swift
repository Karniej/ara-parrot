import Foundation
import Testing
@testable import AraCore

/// Which delivery mechanism an utterance gets: the user's explicit choice, or —
/// under `auto` — paste for the apps known to drop synthesized unicode typing
/// (terminals and Electron apps) and typing everywhere else.
@Suite("InjectionPolicy")
struct InjectionPolicyTests {

    @Test("an explicit 'type' setting types everywhere, even in a terminal")
    func explicitType() {
        #expect(InjectionPolicy.method(setting: .type,
                                       frontmostBundleID: "com.apple.Terminal") == .type)
    }

    @Test("an explicit 'paste' setting pastes everywhere, even in TextEdit")
    func explicitPaste() {
        #expect(InjectionPolicy.method(setting: .paste,
                                       frontmostBundleID: "com.apple.TextEdit") == .paste)
    }

    @Test("auto pastes into every app on the built-in list",
          arguments: [
            "com.apple.Terminal",             // Terminal
            "com.googlecode.iterm2",          // iTerm2
            "com.microsoft.VSCode",           // VS Code
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
          ])
    func autoPastesIntoKnownApps(bundleID: String) {
        #expect(InjectionPolicy.pastePreferredBundleIDs.contains(bundleID))
        #expect(InjectionPolicy.method(setting: .auto,
                                       frontmostBundleID: bundleID) == .paste)
    }

    @Test("auto types everywhere else")
    func autoTypesElsewhere() {
        #expect(InjectionPolicy.method(setting: .auto,
                                       frontmostBundleID: "com.apple.TextEdit") == .type)
        #expect(InjectionPolicy.method(setting: .auto,
                                       frontmostBundleID: "com.apple.mail") == .type)
    }

    @Test("auto with no frontmost app types — the conservative path")
    func autoNilBundle() {
        #expect(InjectionPolicy.method(setting: .auto, frontmostBundleID: nil) == .type)
    }

    // MARK: - Length, the half the app list cannot answer

    /// The bug this threshold exists for. A long transcript typed into an app
    /// nobody has added to the list is exactly the case that scrambled twice
    /// in the field, so it is the case that must not type.
    @Test("auto pastes a long transcript into an app that is not on the list")
    func autoPastesLongTextAnywhere() {
        let long = String(repeating: "a", count: InjectionPolicy.pasteAboveCharacters + 1)
        #expect(!InjectionPolicy.pastePreferredBundleIDs.contains("com.apple.TextEdit"))
        #expect(InjectionPolicy.method(setting: .auto,
                                       frontmostBundleID: "com.apple.TextEdit",
                                       text: long) == .paste)
        // And with no frontmost app at all: the length alone is enough.
        #expect(InjectionPolicy.method(setting: .auto, frontmostBundleID: nil,
                                       text: long) == .paste)
    }

    /// The other side of the trade. Short utterances are most of dictation and
    /// they must keep typing, or the threshold has bought nothing over
    /// pasting always and the pasteboard is touched every time.
    @Test("auto still types a short transcript")
    func autoTypesShortTextAnywhere() {
        #expect(InjectionPolicy.method(setting: .auto,
                                       frontmostBundleID: "com.apple.TextEdit",
                                       text: String(repeating: "a", count: 99)) == .type)
    }

    /// Pinned, because the boundary is a judgement someone will want to move
    /// and moving it should come back through this file.
    @Test("the threshold is exclusive at exactly 100 characters")
    func thresholdBoundary() {
        #expect(InjectionPolicy.pasteAboveCharacters == 100)
        #expect(InjectionPolicy.method(
            setting: .auto, frontmostBundleID: nil,
            text: String(repeating: "a", count: 100)) == .type)
        #expect(InjectionPolicy.method(
            setting: .auto, frontmostBundleID: nil,
            text: String(repeating: "a", count: 101)) == .paste)
    }

    /// An explicit setting is still absolute: someone who asked for typing
    /// gets typing, however much they dictated.
    @Test("length never overrides an explicit setting")
    func lengthDoesNotOverrideExplicitSetting() {
        let long = String(repeating: "a", count: InjectionPolicy.pasteAboveCharacters * 10)
        #expect(InjectionPolicy.method(setting: .type, frontmostBundleID: nil,
                                       text: long) == .type)
        #expect(InjectionPolicy.method(setting: .paste, frontmostBundleID: nil,
                                       text: "") == .paste)
    }

    // MARK: - Characters one keyboard event cannot carry

    /// A grapheme longer than the event payload limit is truncated by the API,
    /// and `TextInjector` will not split it because half a grapheme is not
    /// text. Neither path delivers it, so the policy has to route around the
    /// typed path entirely — even for a short transcript in an app that types.
    @Test("auto pastes a short transcript that contains an untypable character")
    func autoPastesUntypableCharacter() {
        // 26 UTF-16 units in one Character: a letter under a stack of
        // combining acute accents.
        let stacked = "e" + String(repeating: "\u{0301}", count: 25)
        #expect(stacked.count == 1)
        #expect(stacked.utf16.count > TextInjector.chunkLimit)
        #expect(InjectionPolicy.method(setting: .auto,
                                       frontmostBundleID: "com.apple.TextEdit",
                                       text: "hi " + stacked) == .paste)
    }

    /// The characters people actually dictate must not trip it, or every
    /// transcript with an emoji in it starts touching the pasteboard.
    @Test("ordinary text, accents and short emoji still type")
    func ordinaryCharactersStillType() {
        for sample in ["hello", "zażółć gęślą jaźń", "ok 👍", "done ✅", "👨‍👩‍👧‍👦"] {
            #expect(!InjectionPolicy.containsUntypableCharacter(sample),
                    "\(sample) was treated as untypable")
        }
    }
}
