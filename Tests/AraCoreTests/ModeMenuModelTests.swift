import Foundation
import Testing
@testable import AraCore

/// The Mode submenu's contents are a pure function of the registry and the
/// session's manual override — `ModeMenuModel.compute` — so the Auto row, the
/// per-mode rows, the checkmark, and the next-utterance caption are all
/// checked here, off-screen.
@Suite("Mode menu model")
struct ModeMenuModelTests {
    private static let registry = ModeRegistry(userModes: [])

    @Test("Auto leads, then every registered mode in registry order")
    func autoThenModes() {
        let model = ModeMenuModel.compute(
            modes: Self.registry.all, manual: nil)
        #expect(model.items.map(\.title)
                == ["Auto (per app)"] + Self.registry.all.map(\.id))
        #expect(model.items.map(\.id)
                == [nil] + Self.registry.all.map { $0.id })
    }

    @Test("no manual override checks Auto, and only Auto")
    func autoChecked() {
        let checks = ModeMenuModel.compute(
            modes: Self.registry.all, manual: nil).items.map(\.checked)
        #expect(checks == [true] + Self.registry.all.map { _ in false })
    }

    @Test("a manual mode carries the check and Auto loses it")
    func manualChecked() {
        let model = ModeMenuModel.compute(
            modes: Self.registry.all, manual: "chat")
        #expect(model.items.filter(\.checked).map(\.title) == ["chat"])
    }

    /// The override rides each utterance into the resolver, so — unlike the
    /// restart submenus — the very next dictation obeys it. That is what the
    /// caption promises, and nothing here persists: the pick is a session
    /// override by design.
    @Test("the caption says a pick applies to the next utterance")
    func liveCaption() {
        #expect(ModeMenuModel.compute(modes: Self.registry.all,
                                      manual: nil).caption
                == "applies to the next utterance")
    }
}
