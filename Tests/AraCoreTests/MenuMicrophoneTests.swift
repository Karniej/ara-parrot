import CoreAudio
import Foundation
import Testing
@testable import AraCore

/// The Microphone submenu's contents are a pure function of store state —
/// `MicrophoneMenuModel.compute` — so every labeling rule is checked here,
/// off-screen. `MenuBarController` only transcribes a model into `NSMenuItem`s.
@Suite("Microphone menu model")
struct MenuMicrophoneTests {
    private static func dev(
        _ id: AudioDeviceID, _ uid: String, _ name: String
    ) -> MicrophoneStore.Device {
        MicrophoneStore.Device(id: id, uid: uid, name: name)
    }

    private static let yeti = dev(41, "uid-yeti", "Yeti")
    private static let builtIn = dev(52, "uid-built-in", "MacBook Pro Microphone")

    @Test("no preference: System default is checked, devices listed unchecked")
    func noPreference() {
        let model = MicrophoneMenuModel.compute(
            devices: [Self.builtIn, Self.yeti],
            preferredUID: nil,
            effective: .systemDefault(Self.builtIn))
        #expect(model.items.map(\.title) == [
            "System default", "MacBook Pro Microphone", "Yeti",
        ])
        #expect(model.items.map(\.checked) == [true, false, false])
        #expect(model.status == nil)
    }

    @Test("System default carries no uid; each device item carries its own")
    func itemUIDs() {
        let model = MicrophoneMenuModel.compute(
            devices: [Self.builtIn, Self.yeti],
            preferredUID: nil,
            effective: .systemDefault(Self.builtIn))
        #expect(model.items.map(\.uid) == [nil, "uid-built-in", "uid-yeti"])
    }

    @Test("a chosen device gets the check and System default loses it")
    func chosenDevice() {
        let model = MicrophoneMenuModel.compute(
            devices: [Self.builtIn, Self.yeti],
            preferredUID: "uid-yeti",
            effective: .chosen(Self.yeti))
        #expect(model.items.map(\.checked) == [false, false, true])
        #expect(model.status == nil)
    }

    @Test("fallback: nothing is checked and the status names the stand-in")
    func fallbackLabeled() {
        let model = MicrophoneMenuModel.compute(
            devices: [Self.builtIn],
            preferredUID: "uid-yeti",
            effective: .fallback(Self.builtIn))
        // The preferred device is disconnected, so no row can honestly carry
        // the check: the built-in mic is in use but was not picked, and
        // "System default" was not picked either.
        #expect(model.items.map(\.checked) == [false, false])
        #expect(model.status == "preferred mic disconnected — using MacBook Pro Microphone")
    }

    @Test("no devices at all: the status says so")
    func noDevices() {
        let model = MicrophoneMenuModel.compute(
            devices: [], preferredUID: nil, effective: .none)
        #expect(model.items.map(\.title) == ["System default"])
        #expect(model.items.map(\.checked) == [true])
        #expect(model.status == "no microphone connected")
    }

    @Test("no devices with a preference set: nothing checked, same status")
    func noDevicesWithPreference() {
        let model = MicrophoneMenuModel.compute(
            devices: [], preferredUID: "uid-yeti", effective: .none)
        #expect(model.items.map(\.checked) == [false])
        #expect(model.status == "no microphone connected")
    }

    @Test("every item is pickable — the status line is not an item")
    func allItemsEnabled() {
        let model = MicrophoneMenuModel.compute(
            devices: [Self.builtIn],
            preferredUID: "uid-yeti",
            effective: .fallback(Self.builtIn))
        #expect(model.items.allSatisfy { $0.enabled })
    }
}
