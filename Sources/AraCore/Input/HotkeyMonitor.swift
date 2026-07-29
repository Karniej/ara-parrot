import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Watches a single modifier key (default: Fn) and emits press/release edges.
/// Requires Accessibility permission. If the tap fails to register, callers
/// will see an error from `start()`.
public final class HotkeyMonitor {
    public enum Event { case pressed, released }
    enum HotkeyError: Error { case tapCreateFailed }

    /// The modifier we treat as the hotkey. Defaults to Fn.
    private let hotkey: Hotkey
    private let debug: Bool
    private var onEvent: ((Event) -> Void)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false

    public init(hotkey: Hotkey = .fn, debug: Bool = false) {
        self.hotkey = hotkey
        self.debug = debug
    }

    public func start(onEvent: @escaping (Event) -> Void) throws {
        self.onEvent = onEvent

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        if !trusted {
            FileHandle.standardError.write(Data(
                "accessibility not granted — system prompt opened. Grant access, then quit and relaunch parrot.\n".utf8
            ))
            throw HotkeyError.tapCreateFailed
        }

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        // .cgSessionEventTap is the right level for an accessibility-granted
        // user process (.cghidEventTap requires root).
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: hotkeyCallback,
                userInfo: userInfo
            )
        else {
            throw HotkeyError.tapCreateFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
    }

    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        onEvent = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if debug {
            let flags = event.flags
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            FileHandle.standardError.write(
                Data(
                    "  [debug] type=\(type.rawValue) keycode=\(keycode) flags=\(String(flags.rawValue, radix: 16))\n"
                        .utf8
                ))
        }
        guard type == .flagsChanged else { return }
        // Left/right variants share a modifier bit, so the keycode on the event
        // is what tells them apart. Fn matches on the flag alone (keyCode == nil).
        if let expected = hotkey.keyCode {
            guard event.getIntegerValueField(.keyboardEventKeycode) == expected else { return }
        }
        let pressed = event.flags.contains(hotkey.mask)
        guard pressed != isPressed else { return }
        isPressed = pressed
        onEvent?(pressed ? .pressed : .released)
    }
}

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // System disabled our tap; we'll need to re-enable. For now just no-op
        // and let the user restart parrot.
        return Unmanaged.passUnretained(event)
    }

    let copy = event.copy()
    DispatchQueue.main.async {
        if let copy {
            monitor.handle(type: type, event: copy)
        }
    }
    return Unmanaged.passUnretained(event)
}
