import Foundation
import Testing
@testable import AraCore

/// The Hotkey submenu's contents are a pure function of the running hotkey —
/// `HotkeyMenuModel.compute` — so the ordering, the labels, the checkmark,
/// and the restart caption are all checked here, off-screen.
@Suite("Hotkey menu model")
struct HotkeyMenuModelTests {

    @Test("every hotkey is listed, in declaration order, under its label")
    func allHotkeysListed() {
        let model = HotkeyMenuModel.compute(current: .fn)
        #expect(model.items.map(\.hotkey) == Hotkey.allCases)
        #expect(model.items.map(\.title) == Hotkey.allCases.map(\.label))
    }

    @Test("the running hotkey carries the check, and only it")
    func checkmarkPlacement() {
        for hotkey in Hotkey.allCases {
            let checks = HotkeyMenuModel.compute(current: hotkey)
                .items.map(\.checked)
            #expect(checks.filter { $0 }.count == 1)
            #expect(checks[Hotkey.allCases.firstIndex(of: hotkey)!])
        }
    }

    /// The event tap is armed with one hotkey at startup and nothing re-arms
    /// it live (a known follow-up — see the model's doc), so the caption has
    /// to say a pick waits for the next launch.
    @Test("the caption says a pick applies on restart")
    func restartCaption() {
        #expect(HotkeyMenuModel.compute(current: .rightCommand).caption
                == "applies on restart")
    }
}
