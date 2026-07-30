import Foundation
import Testing
@testable import AraCore

/// The Engine submenu's contents are a pure function of the running engine
/// and whether the startup keychain read produced an API key —
/// `EngineMenuModel.compute` — so the ordering, the checkmark, the cloud
/// item's honesty suffix, and the restart caption are all checked here.
@Suite("Engine menu model")
struct EngineMenuModelTests {

    @Test("the five engines are listed in declaration order")
    func allEnginesListed() {
        let model = EngineMenuModel.compute(current: .mlx, hasAPIKey: true)
        #expect(model.items.map(\.engine)
                == [.mlx, .apple, .cloud, .rules, .off])
        #expect(model.items.map(\.title)
                == ["mlx", "apple", "cloud", "rules", "off"])
    }

    @Test("the running engine carries the check, and only it")
    func checkmarkPlacement() {
        for engine in Engine.allCases {
            let checks = EngineMenuModel
                .compute(current: engine, hasAPIKey: true)
                .items.map(\.checked)
            #expect(checks.filter { $0 }.count == 1)
            #expect(checks[Engine.allCases.firstIndex(of: engine)!])
        }
    }

    /// The cloud engine without a key silently formats with the rules floor,
    /// so the item must not imply a key exists. `hasAPIKey` is the *startup*
    /// keychain read's result — the menu never reads the keychain itself,
    /// because `Keychain.readPassword` can raise a blocking prompt.
    @Test("cloud without a key says so; with a key it is just cloud")
    func cloudHonesty() {
        let without = EngineMenuModel.compute(current: .mlx, hasAPIKey: false)
        #expect(without.items.map(\.title)
                == ["mlx", "apple", "cloud (no API key set)", "rules", "off"])
        let with = EngineMenuModel.compute(current: .mlx, hasAPIKey: true)
        #expect(with.items[2].title == "cloud")
    }

    @Test("the caption says a pick applies on restart")
    func restartCaption() {
        #expect(EngineMenuModel.compute(current: .off, hasAPIKey: false).caption
                == "applies on restart")
    }
}
