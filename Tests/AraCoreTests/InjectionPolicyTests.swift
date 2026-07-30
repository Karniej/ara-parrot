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
}
