import Foundation

/// The nspasteboard.org marker types this project understands.
///
/// They are conventions, not API: pasteboard-aware apps (clipboard managers,
/// password managers) declare and honour them by agreement.
public enum PasteboardConvention {
    /// Declared on data that should not be recorded by clipboard history
    /// tools. The transcript item carries it: the pasteboard is only a
    /// delivery vehicle here, and a transcript that lingers in a clipboard
    /// manager's history is a leak the settle-delay restore cannot undo.
    public static let transient = "org.nspasteboard.TransientType"

    /// Declared by password managers on copied secrets. An item carrying it
    /// is ephemeral *by its producer's design* — the manager clears it on its
    /// own schedule — so re-publishing one during restore would put a password
    /// back on the pasteboard after its owner deliberately retired it. Restore
    /// drops these items instead.
    public static let concealed = "org.nspasteboard.ConcealedType"
}

/// One pasteboard item, every representation captured.
///
/// Every representation and not just the string, because a pasteboard item is
/// a bundle of renderings of one thing — a copied image is TIFF *and* PNG, a
/// copied file is a URL *and* an icon *and* a display name. Restoring only the
/// richest type would hand back an item half the apps in the paste chain can
/// no longer read.
public struct PasteboardItemSnapshot: Equatable, Sendable {
    public struct Representation: Equatable, Sendable {
        public let type: String
        public let data: Data

        public init(type: String, data: Data) {
            self.type = type
            self.data = data
        }
    }

    /// In the item's own fidelity order — richest first, as `NSPasteboardItem`
    /// reports it — because consumers pick the first type they understand.
    public var representations: [Representation]

    public init(representations: [Representation]) {
        self.representations = representations
    }

    /// Whether the producing app declared this item concealed. See
    /// `PasteboardConvention.concealed` for why such an item is never restored.
    public var isConcealed: Bool {
        representations.contains { $0.type == PasteboardConvention.concealed }
    }
}

/// The pasteboard operations the paste path needs, as values.
///
/// A protocol so the ordering, generation, and filtering logic in
/// `PasteInjector` runs under test against an in-memory fake; the one
/// production conformance (`SystemPasteboard`) is a thin translation to
/// `NSPasteboard` with no decisions in it. Main-actor-bound because that is
/// where the existing injector already runs and where AppKit is comfortable.
@MainActor
public protocol TranscriptPasteboard: AnyObject {
    /// The current contents, every representation of every item.
    func snapshot() -> [PasteboardItemSnapshot]

    /// Replaces the contents with these items (an empty array clears).
    /// Returns `false` when the pasteboard refused the write.
    func setItems(_ items: [PasteboardItemSnapshot]) -> Bool
}

/// Delivers a transcript by pasting it: snapshot the user's pasteboard, put
/// the transcript on it, synthesize ⌘V, and put the snapshot back once the
/// target app has had time to read the paste.
///
/// ## The transcript is never lost
///
/// If the pasteboard write or the ⌘V synthesis fails, the original contents
/// are restored immediately and the text goes out through `typeFallback` —
/// the pre-existing typing path. Degraded delivery, never no delivery.
///
/// ## The generation counter
///
/// Restore happens on a timer, and a user can dictate twice inside one settle
/// window. Two hazards, one counter:
///
/// - the second dictation must not snapshot the first one's transcript as
///   "the user's pasteboard" — so the saved snapshot is only taken while no
///   restore is pending, and held until one restore completes;
/// - the first dictation's timer must not restore underneath the second
///   paste — each scheduled restore carries the generation it was armed for,
///   and a stale generation does nothing. The *last* dictation's timer
///   performs the one restore, so the transcript can neither leak onto the
///   pasteboard permanently nor clobber it with stale content.
@MainActor
public final class PasteInjector {
    private let pasteboard: any TranscriptPasteboard
    private let postPaste: () -> Bool
    private let typeFallback: (String) -> Void
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void

    /// How long the target app gets to service the synthesized ⌘V before the
    /// user's pasteboard is put back. See `Config.pasteRestoreMs` for the
    /// tradeoff and the clamp; this value arrives pre-clamped.
    public let settleDelay: TimeInterval

    /// The user's pasteboard, held while one or more pastes are in flight.
    private var saved: [PasteboardItemSnapshot]?
    /// Identifies the newest paste; a scheduled restore for any older one
    /// finds the numbers unequal and stands down.
    private var generation = 0

    public init(pasteboard: any TranscriptPasteboard,
                settleDelay: TimeInterval,
                postPaste: @escaping () -> Bool,
                typeFallback: @escaping (String) -> Void,
                schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void) {
        self.pasteboard = pasteboard
        self.settleDelay = settleDelay
        self.postPaste = postPaste
        self.typeFallback = typeFallback
        self.schedule = schedule
    }

    /// Delivers `text` by paste, or by the typing fallback when the paste
    /// machinery fails. An empty string does nothing — same contract as
    /// `TextInjector.inject`, and the cancellation story depends on it.
    public func inject(_ text: String) {
        guard !text.isEmpty else { return }

        // Snapshot only while no restore is pending: mid-window the pasteboard
        // holds the previous transcript, not anything worth preserving.
        if saved == nil { saved = pasteboard.snapshot() }
        generation &+= 1
        let armed = generation

        guard pasteboard.setItems([Self.transcriptItem(text)]), postPaste() else {
            // Whatever half-happened, put the user's pasteboard back and let
            // the typing path deliver the words. This also invalidates any
            // pending restore — the pasteboard is already correct again.
            restoreNow()
            typeFallback(text)
            return
        }

        schedule(settleDelay) { [weak self] in
            self?.completeRestore(generation: armed)
        }
    }

    /// The transcript as a pasteboard item: plain text, plus the transient
    /// marker so clipboard managers do not record it.
    static func transcriptItem(_ text: String) -> PasteboardItemSnapshot {
        PasteboardItemSnapshot(representations: [
            .init(type: "public.utf8-plain-text", data: Data(text.utf8)),
            .init(type: PasteboardConvention.transient, data: Data()),
        ])
    }

    /// What restore is allowed to write back: everything except concealed
    /// items. Dropping them is deliberate — see `PasteboardConvention` — and
    /// means a pasteboard that held only a password restores to empty.
    static func restorable(_ items: [PasteboardItemSnapshot]) -> [PasteboardItemSnapshot] {
        items.filter { !$0.isConcealed }
    }

    private func completeRestore(generation armed: Int) {
        guard armed == generation else { return }  // superseded; a newer paste owns the restore
        if let saved {
            _ = pasteboard.setItems(Self.restorable(saved))
        }
        saved = nil
    }

    private func restoreNow() {
        generation &+= 1  // stand down any restore already scheduled
        if let saved {
            _ = pasteboard.setItems(Self.restorable(saved))
        }
        saved = nil
    }
}
