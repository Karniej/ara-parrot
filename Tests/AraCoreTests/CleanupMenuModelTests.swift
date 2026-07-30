import Foundation
import Testing
@testable import AraCore

/// The Cleanup submenu's contents are a pure function of the configured
/// intensity — `CleanupMenuModel.compute` — so the ordering, the checkmark,
/// and the honesty caption are all checked here, off-screen.
/// `MenuBarController` only transcribes a model into `NSMenuItem`s.
@Suite("Cleanup menu model")
struct CleanupMenuModelTests {

    @Test("the four intensities are listed in escalation order")
    func escalationOrder() {
        let model = CleanupMenuModel.compute(current: .medium)
        #expect(model.items.map(\.title) == ["none", "light", "medium", "high"])
        #expect(model.items.map(\.intensity)
                == [.none, .light, .medium, .high])
    }

    /// `Config.load` defaults an absent `cleanup` key to `.medium`, so the
    /// menu computed from a default config must check medium — the daemon's
    /// actual behaviour, not an unchecked menu.
    @Test("the configured intensity carries the check, and only it")
    func checkmarkPlacement() {
        #expect(CleanupMenuModel.compute(current: Config().cleanup)
            .items.map(\.checked) == [false, false, true, false])
        for intensity in CleanupIntensity.allCases {
            let checks = CleanupMenuModel.compute(current: intensity)
                .items.map(\.checked)
            #expect(checks.filter { $0 }.count == 1)
            #expect(checks[CleanupIntensity.allCases
                .firstIndex(of: intensity)!])
        }
    }

    /// The session's intensity is stamped at build time, so a pick applies on
    /// the next launch — the caption is the menu telling the truth about it.
    @Test("the caption says a pick applies on restart")
    func restartCaption() {
        #expect(CleanupMenuModel.compute(current: .high).caption
                == "applies on restart")
    }
}
