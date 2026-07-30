import CoreAudio
import Foundation

/// Tracks the connected audio *input* devices and resolves which one parrot
/// should record from, given an optional preferred device UID.
///
/// The store never touches the system default input — routing is per-engine,
/// applied by `AudioCapture` via the input unit's current-device property. It
/// is event-driven: Core Audio property listeners for the device list and the
/// default input feed one `refresh` path, and `onChange` fires only when the
/// list or the resolved result actually changed, so a burst of hardware
/// notifications (a USB hub replug fires several) collapses into the changes
/// that matter.
///
/// All Core Audio access lives behind three injected function values —
/// `enumerate`, `defaultInputID`, `startListening` — so every rule in here is
/// exercised by tests on machines whose microphones are not unpluggable on
/// demand. The public initializer wires the real hardware.
public final class MicrophoneStore {
    /// One connected input device. `uid` is the identifier that survives
    /// replug and reboot and is what `Config.microphone` stores; `id` is the
    /// transient handle `AudioCapture` routes with; `name` is for the menu.
    public struct Device: Equatable, Sendable {
        public let id: AudioDeviceID
        public let uid: String
        public let name: String

        public init(id: AudioDeviceID, uid: String, name: String) {
            self.id = id
            self.uid = uid
            self.name = name
        }
    }

    /// The resolved device together with *why* it was resolved, so the menu
    /// can label the state honestly rather than showing a checkmark on a
    /// device that is not actually in use.
    public enum Effective: Equatable, Sendable {
        /// The user's preferred device, present and selected.
        case chosen(Device)
        /// The user has a preference but it is disconnected; this device is
        /// standing in until it returns.
        case fallback(Device)
        /// No preference; following the system default (or, when the default
        /// is not an input, the first available input).
        case systemDefault(Device)
        /// No input devices exist at all.
        case none

        public var device: Device? {
            switch self {
            case .chosen(let d), .fallback(let d), .systemDefault(let d): return d
            case .none: return nil
            }
        }
    }

    // MARK: - State

    private let lock = NSLock()
    private var _devices: [Device]
    private var _effective: Effective
    private var _preferredUID: String?
    private var _onChange: (() -> Void)?

    private let enumerate: () -> [Device]
    private let defaultInputID: () -> AudioDeviceID?
    private var stopListening: (() -> Void)?

    /// The connected input devices, most recently observed.
    public var devices: [Device] {
        lock.lock()
        defer { lock.unlock() }
        return _devices
    }

    /// The device parrot should record from right now, and why.
    public var effective: Effective {
        lock.lock()
        defer { lock.unlock() }
        return _effective
    }

    /// The user's current preference, `nil` for "follow the system default".
    /// Distinct from `effective`: the menu places its check on the *pick*, and
    /// `effective` cannot recover the pick once the picked device unplugs.
    public var preferredUID: String? {
        lock.lock()
        defer { lock.unlock() }
        return _preferredUID
    }

    /// Fired after the device list or the resolved device changed — never for
    /// an event that changed neither. Invoked on an arbitrary queue (the
    /// listener's queue for hardware events, the caller's thread for
    /// `setPreferredUID`); hop to main before touching UI.
    public var onChange: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onChange }
        set { lock.lock(); defer { lock.unlock() }; _onChange = newValue }
    }

    // MARK: - Lifecycle

    /// Watches the real hardware. `preferredUID` is `Config.microphone`.
    public convenience init(preferredUID: String? = nil) {
        self.init(
            preferredUID: preferredUID,
            enumerate: CoreAudioInputs.devices,
            defaultInputID: CoreAudioInputs.defaultInputID,
            startListening: CoreAudioInputs.listen)
    }

    /// The seam. `startListening` receives the store's refresh and returns the
    /// matching removal, which `deinit` invokes — registration and removal are
    /// forced into pairs by the shape of the parameter.
    init(preferredUID: String?,
         enumerate: @escaping () -> [Device],
         defaultInputID: @escaping () -> AudioDeviceID?,
         startListening: (@escaping () -> Void) -> (() -> Void)) {
        self._preferredUID = preferredUID
        self.enumerate = enumerate
        self.defaultInputID = defaultInputID
        let list = enumerate()
        _devices = list
        _effective = Self.resolve(
            preferredUID: preferredUID, devices: list, systemDefaultID: defaultInputID())
        stopListening = startListening { [weak self] in self?.refresh() }
    }

    deinit {
        stopListening?()
    }

    // MARK: - Behaviour

    /// Records the preference (in memory — persisting it is the caller's job)
    /// and re-resolves immediately.
    public func setPreferredUID(_ uid: String?) {
        lock.lock()
        _preferredUID = uid
        lock.unlock()
        refresh()
    }

    /// The pure resolution rule: preferred UID if connected → system default
    /// if it is an input → first available input → none. No Core Audio in
    /// sight, so every branch is unit-testable.
    static func resolve(
        preferredUID: String?,
        devices: [Device],
        systemDefaultID: AudioDeviceID?
    ) -> Effective {
        if let preferredUID, let match = devices.first(where: { $0.uid == preferredUID }) {
            return .chosen(match)
        }
        let candidate = devices.first(where: { $0.id == systemDefaultID }) ?? devices.first
        guard let candidate else { return .none }
        return preferredUID == nil ? .systemDefault(candidate) : .fallback(candidate)
    }

    /// The single path every event funnels through: re-enumerate, re-resolve,
    /// and notify only on an actual change. The callback runs outside the lock
    /// so an observer may read `devices`/`effective` re-entrantly.
    private func refresh() {
        let list = enumerate()
        let defaultID = defaultInputID()
        lock.lock()
        let resolved = Self.resolve(
            preferredUID: _preferredUID, devices: list, systemDefaultID: defaultID)
        let changed = list != _devices || resolved != _effective
        _devices = list
        _effective = resolved
        let callback = _onChange
        lock.unlock()
        if changed { callback?() }
    }
}

// MARK: - The real hardware

/// The Core Audio calls behind `MicrophoneStore`'s seams. Kept as free
/// functions on an enum so the store's logic never mentions an
/// `AudioObjectPropertyAddress`.
enum CoreAudioInputs {
    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// Every device with at least one input stream, as itself — aggregate and
    /// virtual devices included, no filtering cleverness. A device whose UID
    /// cannot be read is skipped: without a UID it cannot be preferred, and it
    /// is not routable by anything `Config.microphone` could hold.
    static func devices() -> [MicrophoneStore.Device] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids) == noErr
        else { return [] }

        return ids.compactMap { id in
            guard inputChannelCount(of: id) > 0,
                  let uid = stringProperty(of: id, selector: kAudioDevicePropertyDeviceUID)
            else { return nil }
            let name = stringProperty(of: id, selector: kAudioObjectPropertyName) ?? uid
            return MicrophoneStore.Device(id: id, uid: uid, name: name)
        }
    }

    /// The system default input, or nil when there is none. Read-only: parrot
    /// never *sets* the system default.
    static func defaultInputID() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// Registers for device-list and default-input changes; returns the
    /// removal. The same block and queue are used for add and remove because
    /// Core Audio matches listeners by identity.
    static func listen(_ onEvent: @escaping () -> Void) -> () -> Void {
        let queue = DispatchQueue(label: "ara.microphone-store.listener")
        let block: AudioObjectPropertyListenerBlock = { _, _ in onEvent() }
        var devicesAddr = address(kAudioHardwarePropertyDevices)
        var defaultAddr = address(kAudioHardwarePropertyDefaultInputDevice)
        // Registration on the system object does not fail in practice; a
        // nonzero status here would only mean events stop arriving, which
        // degrades to the pre-listener behaviour (state as of startup).
        _ = AudioObjectAddPropertyListenerBlock(systemObject, &devicesAddr, queue, block)
        _ = AudioObjectAddPropertyListenerBlock(systemObject, &defaultAddr, queue, block)
        return {
            var devicesAddr = address(kAudioHardwarePropertyDevices)
            var defaultAddr = address(kAudioHardwarePropertyDefaultInputDevice)
            _ = AudioObjectRemovePropertyListenerBlock(systemObject, &devicesAddr, queue, block)
            _ = AudioObjectRemovePropertyListenerBlock(systemObject, &defaultAddr, queue, block)
        }
    }

    /// Total input channels across the device's input stream configuration.
    /// This is the "is it an input device" test: output-only devices report a
    /// zero-buffer list under the input scope.
    private static func inputChannelCount(of id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration,
                           scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr,
              size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Reads a CFString property (UID, name). The API hands back a +1
    /// reference which ARC releases when `value` goes out of scope.
    private static func stringProperty(
        of id: AudioDeviceID, selector: AudioObjectPropertySelector
    ) -> String? {
        var addr = address(selector)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String
    }
}
