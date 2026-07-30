import AppKit
import CoreGraphics
import Foundation

/// The one production `TranscriptPasteboard`: a decision-free translation
/// between `PasteboardItemSnapshot` and `NSPasteboard.general`. Everything
/// with logic in it lives in `PasteInjector`, under test.
@MainActor
final class SystemPasteboard: TranscriptPasteboard {
    private let pasteboard = NSPasteboard.general

    func snapshot() -> [PasteboardItemSnapshot] {
        (pasteboard.pasteboardItems ?? []).map { item in
            PasteboardItemSnapshot(representations: item.types.compactMap { type in
                item.data(forType: type).map {
                    .init(type: type.rawValue, data: $0)
                }
            })
        }
    }

    func setItems(_ items: [PasteboardItemSnapshot]) -> Bool {
        pasteboard.clearContents()
        guard !items.isEmpty else { return true }  // an empty write is a clear
        return pasteboard.writeObjects(items.map { snapshot in
            let item = NSPasteboardItem()
            for representation in snapshot.representations {
                item.setData(representation.data,
                             forType: NSPasteboard.PasteboardType(representation.type))
            }
            return item
        })
    }
}

/// Synthesizes the ⌘V key chord. Pure glue; returns `false` only when macOS
/// refuses to construct the events, which `PasteInjector` treats as its cue
/// to fall back to typing.
enum CommandVSynthesizer {
    /// Keycode 9 is `v` on the ASCII-capable layout macOS uses to resolve key
    /// equivalents, so this stays ⌘V on non-QWERTY layouts.
    private static let vKeyCode: CGKeyCode = 9

    static func post() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return false }
        // Flags set explicitly to command-only, masking out everything else:
        // the user has just released — or is still releasing — the push-to-talk
        // modifier, and a ⌥ or ⌃ still physically down would otherwise ride
        // along and turn this into a different shortcut entirely.
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }
}

extension PasteInjector {
    /// The production wiring: `NSPasteboard.general`, a real ⌘V, the existing
    /// typing path as the fallback, and the main queue as the settle timer.
    public static func system(settleDelayMs: Int) -> PasteInjector {
        PasteInjector(
            pasteboard: SystemPasteboard(),
            settleDelay: TimeInterval(settleDelayMs) / 1000,
            postPaste: { CommandVSynthesizer.post() },
            typeFallback: { TextInjector.inject($0) },
            schedule: { delay, work in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated(work)
                }
            })
    }
}
