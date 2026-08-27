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

    /// The menu computed from a default config must check whatever the daemon
    /// actually does — an unchecked menu would be describing a different app.
    ///
    /// The default moved from `.medium` to `.none` when Parakeet became the
    /// default transcriber: it punctuates its own output, so the second of
    /// generation `.medium` costs now buys rewriting nobody asked for. Written
    /// against `Config().cleanup` rather than a spelled-out row so the next
    /// change to the default moves the checkmark here too, instead of leaving
    /// this passing and wrong.
    @Test("the configured intensity carries the check, and only it")
    func checkmarkPlacement() {
        let rows = CleanupMenuModel.compute(current: Config().cleanup).items
        #expect(rows.filter(\.checked).count == 1)
        #expect(rows.first { $0.checked }?.intensity == Config().cleanup)
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
