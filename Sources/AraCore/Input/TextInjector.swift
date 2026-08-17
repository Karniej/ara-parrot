import CoreGraphics
import Foundation

/// Posts a string of text at the current cursor location by synthesizing
/// keyboard events with `CGEventKeyboardSetUnicodeString`. Works in nearly
/// every text field on macOS; some Electron apps and secure password fields
/// can drop characters (platform constraint).
///
/// ## Long text arrives as a sequence, and a sequence can arrive out of order
///
/// The event record carries a bounded Unicode payload — about 20 UTF-16 units —
/// so anything longer than a short phrase is delivered as several events rather
/// than one, and their order is the order the text ends up in.
///
/// It is not always the order they were posted in. Captured from a real
/// dictation, the transcript that reached the formatter was 186 characters and
/// so was the text in the field, but the field's copy read:
///
/// ```
/// chunk 5: ' I think people will'
/// chunk 7: 'oo. And I want to so'   ← chunk 6 skipped
/// ...
/// chunk 6: " think that's cool t"   ← arrived last
/// ```
///
/// One chunk overtaken by the rest and committed at the end. Identical length,
/// so nothing was lost or duplicated — the pieces were simply reassembled
/// wrong, which is why it only ever shows up on text long enough to need more
/// than one event, and why it reads to the user as a sentence fragment moved to
/// the end.
///
/// `pacing` is the mitigation and `InjectionPolicy` holds the real fix: a paste
/// is one event and cannot be reordered at all, which is why the apps that
/// mangle synthesized keystrokes most reliably are on
/// `InjectionPolicy.pastePreferredBundleIDs`.
public enum TextInjector {
    /// The per-event payload limit, in UTF-16 units.
    static let chunkLimit = 20

    /// The gap left between posted events.
    ///
    /// The receiving app has to consume each event before the next one lands;
    /// posting twenty of them back to back in a few microseconds is what gives
    /// its input handling the chance to commit them in the wrong order. A pause
    /// hands the target's run loop a turn between chunks.
    ///
    /// Three milliseconds per chunk is about 60 ms across a 400-character
    /// paragraph and about 8 ms across a short sentence — below the threshold
    /// where anyone perceives the text appearing late, and four orders of
    /// magnitude under the seconds this daemon already spends transcribing and
    /// formatting. There is no speed being traded away here, which is worth
    /// stating because "slow it down to fix ordering" sounds like there is.
    ///
    /// This makes reordering unlikely rather than impossible: ordering across
    /// separate posted events is not something the API promises. Use `paste`
    /// where it must not happen at all.
    static let pacing: TimeInterval = 0.003

    /// Inject the given text at the current cursor location.
    public static func inject(_ text: String) {
        guard !text.isEmpty else { return }

        let chunks = chunks(text)
        for (index, chunk) in chunks.enumerated() {
            var chunk = chunk
            postChunk(&chunk)
            if index < chunks.count - 1 { Thread.sleep(forTimeInterval: pacing) }
        }
    }

    /// Splits `text` into per-event payloads without ever cutting a character
    /// in half.
    ///
    /// Pure, and separated from the posting for that reason: the split is the
    /// part with a rule in it, and the rule is not "every 20 UTF-16 units".
    /// Slicing a UTF-16 array at a fixed stride lands inside surrogate pairs
    /// and between a base character and its combining marks, so an emoji or an
    /// accented letter unlucky enough to straddle a boundary is delivered as
    /// two halves of nothing. Dictation in Polish produces combining marks
    /// routinely.
    ///
    /// A single character whose own encoding exceeds `chunkLimit` — a long
    /// emoji sequence — gets an event to itself and goes over the limit. The
    /// alternative is to split it, and a truncated grapheme is not better than
    /// a whole one the API may truncate.
    static func chunks(_ text: String) -> [[UniChar]] {
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        for character in text {
            let units = Array(String(character).utf16)
            if !current.isEmpty, current.count + units.count > chunkLimit {
                chunks.append(current)
                current = []
            }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func postChunk(_ chunk: inout [UniChar]) {
        let length = chunk.count
        guard length > 0 else { return }

        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        down?.post(tap: .cgSessionEventTap)

        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        up?.post(tap: .cgSessionEventTap)
    }
}
