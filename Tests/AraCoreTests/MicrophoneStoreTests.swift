import CoreAudio
import Foundation
import Testing
@testable import AraCore

@Suite("MicrophoneStore")
struct MicrophoneStoreTests {
    private static func dev(
        _ id: AudioDeviceID, _ uid: String, _ name: String
    ) -> MicrophoneStore.Device {
        MicrophoneStore.Device(id: id, uid: uid, name: name)
    }

    private static let yeti = dev(41, "uid-yeti", "Yeti")
    private static let builtIn = dev(52, "uid-built-in", "MacBook Pro Microphone")
    private static let airpods = dev(63, "uid-airpods", "AirPods Pro")

    // MARK: - resolve, the pure rule

    @Test("a connected preferred device is chosen")
    func preferredConnected() {
        let effective = MicrophoneStore.resolve(
            preferredUID: "uid-yeti",
            devices: [Self.builtIn, Self.yeti],
            systemDefaultID: Self.builtIn.id)
        #expect(effective == .chosen(Self.yeti))
    }

    @Test("the preference beats the system default when both are connected")
    func preferredBeatsDefault() {
        let effective = MicrophoneStore.resolve(
            preferredUID: "uid-airpods",
            devices: [Self.builtIn, Self.airpods],
            systemDefaultID: Self.builtIn.id)
        #expect(effective == .chosen(Self.airpods))
    }

    @Test("a disconnected preference falls back to the system default, and says so")
    func preferredMissingFallsBackToDefault() {
        let effective = MicrophoneStore.resolve(
            preferredUID: "uid-yeti",
            devices: [Self.builtIn, Self.airpods],
            systemDefaultID: Self.builtIn.id)
        #expect(effective == .fallback(Self.builtIn))
    }

    @Test("a disconnected preference with no system default falls back to the first input")
    func preferredMissingNoDefault() {
        let effective = MicrophoneStore.resolve(
            preferredUID: "uid-yeti",
            devices: [Self.airpods, Self.builtIn],
            systemDefaultID: nil)
        #expect(effective == .fallback(Self.airpods))
    }

    @Test("a system default that is not an input device is skipped for the first input")
    func defaultNotInList() {
        let effective = MicrophoneStore.resolve(
            preferredUID: "uid-yeti",
            devices: [Self.airpods],
            systemDefaultID: 999)
        #expect(effective == .fallback(Self.airpods))
    }

    @Test("a disconnected preference with no devices at all resolves to none")
    func preferredMissingEmptyList() {
        let effective = MicrophoneStore.resolve(
            preferredUID: "uid-yeti", devices: [], systemDefaultID: nil)
        #expect(effective == .none)
    }

    @Test("no preference uses the system default")
    func noPreferenceUsesDefault() {
        let effective = MicrophoneStore.resolve(
            preferredUID: nil,
            devices: [Self.yeti, Self.builtIn],
            systemDefaultID: Self.builtIn.id)
        #expect(effective == .systemDefault(Self.builtIn))
    }

    @Test("no preference and no default uses the first input")
    func noPreferenceNoDefault() {
        let effective = MicrophoneStore.resolve(
            preferredUID: nil,
            devices: [Self.yeti, Self.builtIn],
            systemDefaultID: nil)
        #expect(effective == .systemDefault(Self.yeti))
    }

    @Test("no preference and no devices resolves to none")
    func noPreferenceEmptyList() {
        let effective = MicrophoneStore.resolve(
            preferredUID: nil, devices: [], systemDefaultID: nil)
        #expect(effective == .none)
    }

    // MARK: - the store around it

    /// Stands in for Core Audio: the test mutates `devices`/`defaultID` and
    /// then fires the captured listener, exactly what a real device unplug
    /// does.
    private final class FakeHardware {
        var devices: [MicrophoneStore.Device] = []
        var defaultID: AudioDeviceID?
        var fire: (() -> Void)?
        var listenerRemoved = false

        func store(preferredUID: String? = nil) -> MicrophoneStore {
            MicrophoneStore(
                preferredUID: preferredUID,
                enumerate: { self.devices },
                defaultInputID: { self.defaultID },
                startListening: { refresh in
                    self.fire = refresh
                    return { self.listenerRemoved = true }
                })
        }
    }

    @Test("initial state reflects the hardware at init")
    func initialState() {
        let hw = FakeHardware()
        hw.devices = [Self.builtIn, Self.yeti]
        hw.defaultID = Self.builtIn.id
        let store = hw.store()
        #expect(store.devices == [Self.builtIn, Self.yeti])
        #expect(store.effective == .systemDefault(Self.builtIn))
    }

    @Test("a device-list change updates the list and fires onChange once")
    func listChangeFiresOnce() {
        let hw = FakeHardware()
        hw.devices = [Self.builtIn]
        hw.defaultID = Self.builtIn.id
        let store = hw.store()
        var changes = 0
        store.onChange = { changes += 1 }

        hw.devices = [Self.builtIn, Self.yeti]
        hw.fire?()
        #expect(store.devices == [Self.builtIn, Self.yeti])
        #expect(changes == 1)
    }

    @Test("an event that changes nothing does not fire onChange")
    func noOpEventIsSilent() {
        let hw = FakeHardware()
        hw.devices = [Self.builtIn]
        hw.defaultID = Self.builtIn.id
        let store = hw.store()
        var changes = 0
        store.onChange = { changes += 1 }

        hw.fire?()
        #expect(changes == 0)
    }

    @Test("a default-input change re-resolves and fires")
    func defaultChangeFires() {
        let hw = FakeHardware()
        hw.devices = [Self.builtIn, Self.yeti]
        hw.defaultID = Self.builtIn.id
        let store = hw.store()
        var changes = 0
        store.onChange = { changes += 1 }

        hw.defaultID = Self.yeti.id
        hw.fire?()
        #expect(store.effective == .systemDefault(Self.yeti))
        #expect(changes == 1)
    }

    @Test("unplugging the preferred device degrades to fallback and fires")
    func unplugPreferredDegrades() {
        let hw = FakeHardware()
        hw.devices = [Self.builtIn, Self.yeti]
        hw.defaultID = Self.builtIn.id
        let store = hw.store(preferredUID: "uid-yeti")
        #expect(store.effective == .chosen(Self.yeti))
        var changes = 0
        store.onChange = { changes += 1 }

        hw.devices = [Self.builtIn]
        hw.fire?()
        #expect(store.effective == .fallback(Self.builtIn))
        #expect(changes == 1)

        // Replug: the preference is remembered, not forgotten on fallback.
        hw.devices = [Self.builtIn, Self.yeti]
        hw.fire?()
        #expect(store.effective == .chosen(Self.yeti))
        #expect(changes == 2)
    }

    @Test("setPreferredUID re-resolves and fires")
    func setPreferredFires() {
        let hw = FakeHardware()
        hw.devices = [Self.builtIn, Self.yeti]
        hw.defaultID = Self.builtIn.id
        let store = hw.store()
        var changes = 0
        store.onChange = { changes += 1 }

        store.setPreferredUID("uid-yeti")
        #expect(store.effective == .chosen(Self.yeti))
        #expect(changes == 1)

        store.setPreferredUID(nil)
        #expect(store.effective == .systemDefault(Self.builtIn))
        #expect(changes == 2)
    }

    @Test("setPreferredUID that changes nothing effective stays silent")
    func setPreferredNoChangeSilent() {
        let hw = FakeHardware()
        hw.devices = [Self.builtIn]
        hw.defaultID = Self.builtIn.id
        let store = hw.store()
        var changes = 0
        store.onChange = { changes += 1 }

        store.setPreferredUID(nil)
        #expect(changes == 0)
    }

    @Test("deinit removes the listeners")
    func deinitRemovesListeners() {
        let hw = FakeHardware()
        hw.devices = [Self.builtIn]
        var store: MicrophoneStore? = hw.store()
        _ = store?.devices
        store = nil
        #expect(hw.listenerRemoved)
    }

    @Test("preferredUID is readable — the menu needs it to place the check")
    func preferredUIDReadable() {
        let hw = FakeHardware()
        hw.devices = [Self.builtIn]
        let store = hw.store(preferredUID: "uid-yeti")
        #expect(store.preferredUID == "uid-yeti")

        store.setPreferredUID(nil)
        #expect(store.preferredUID == nil)
    }

    @Test("Effective.device exposes the resolved device, or nil for none")
    func effectiveDeviceAccessor() {
        #expect(MicrophoneStore.Effective.chosen(Self.yeti).device == Self.yeti)
        #expect(MicrophoneStore.Effective.fallback(Self.builtIn).device == Self.builtIn)
        #expect(MicrophoneStore.Effective.systemDefault(Self.airpods).device == Self.airpods)
        #expect(MicrophoneStore.Effective.none.device == nil)
    }
}
