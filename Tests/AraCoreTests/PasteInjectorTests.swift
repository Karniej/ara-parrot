import Foundation
import Testing
@testable import AraCore

/// The paste path's promises, tested through the seams:
///
/// - the user's pasteboard comes back exactly as it was — every representation
///   of every item, images and files included — after the settle delay;
/// - except concealed items (`org.nspasteboard.ConcealedType`), which are
///   ephemeral by design and must never be re-published;
/// - the transcript item is marked transient so clipboard managers skip it;
/// - two dictations inside one settle window restore the *original* pasteboard
///   once, never the first transcript, and never twice;
/// - any failure to write or to synthesize ⌘V falls back to the typing path,
///   because losing the transcript is the one unacceptable outcome.
@MainActor
@Suite("PasteInjector")
struct PasteInjectorTests {

    // MARK: - Test doubles

    /// In-memory pasteboard: `setItems` replaces the contents, `snapshot`
    /// returns them, and both are counted so tests can assert *when* the
    /// injector looked and wrote, not only what ended up there.
    @MainActor
    final class FakePasteboard: TranscriptPasteboard {
        var current: [PasteboardItemSnapshot]
        private(set) var changeCount = 0
        var snapshotCount = 0
        var writes: [[PasteboardItemSnapshot]] = []
        /// Set to make the next `setItems` fail (and consume the failure).
        var failNextWrite = false

        init(current: [PasteboardItemSnapshot] = []) {
            self.current = current
        }

        func snapshot() -> [PasteboardItemSnapshot] {
            snapshotCount += 1
            return current
        }

        func setItems(_ items: [PasteboardItemSnapshot]) -> Bool {
            if failNextWrite {
                failNextWrite = false
                return false
            }
            writes.append(items)
            current = items
            changeCount += 1
            return true
        }

        /// Another process takes the pasteboard — the user's ⌘C in some other
        /// app. Bumps `changeCount` exactly as `NSPasteboard` would.
        func externalWrite(_ items: [PasteboardItemSnapshot]) {
            current = items
            changeCount += 1
        }
    }

    /// Captures scheduled restores so a test can fire them by hand, in any
    /// order, standing in for the settle-delay timer.
    @MainActor
    final class FakeClock {
        var scheduled: [(delay: TimeInterval, work: @MainActor () -> Void)] = []
        func schedule(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
            scheduled.append((delay, work))
        }
        func fire(_ index: Int) { scheduled[index].work() }
    }

    // MARK: - Fixtures

    static func item(_ type: String, _ bytes: String) -> PasteboardItemSnapshot {
        PasteboardItemSnapshot(representations: [
            .init(type: type, data: Data(bytes.utf8))
        ])
    }

    /// A copied image: one item, several representations. Surviving the round
    /// trip whole is the reason snapshots keep every representation.
    static let image = PasteboardItemSnapshot(representations: [
        .init(type: "public.tiff", data: Data([0x4d, 0x4d, 0x00, 0x2a])),
        .init(type: "public.png", data: Data([0x89, 0x50, 0x4e, 0x47])),
    ])

    /// A password-manager entry: concealed by convention.
    static let secret = PasteboardItemSnapshot(representations: [
        .init(type: "public.utf8-plain-text", data: Data("hunter2".utf8)),
        .init(type: PasteboardConvention.concealed, data: Data()),
    ])

    // MARK: - The transcript item

    @Test("the transcript is written as plain text marked transient")
    func transcriptItemShape() {
        let item = PasteInjector.transcriptItem("hello")
        #expect(item.representations.contains(
            .init(type: "public.utf8-plain-text", data: Data("hello".utf8))))
        #expect(item.representations.contains(where: {
            $0.type == PasteboardConvention.transient
        }))
    }

    // MARK: - Snapshot semantics

    @Test("a concealed item is recognised by its declared type")
    func concealedDetection() {
        #expect(Self.secret.isConcealed)
        #expect(!Self.image.isConcealed)
    }

    @Test("restorable() drops concealed items and keeps everything else")
    func restorableFilters() {
        let kept = PasteInjector.restorable([Self.image, Self.secret,
                                             Self.item("public.utf8-plain-text", "keep")])
        #expect(kept == [Self.image, Self.item("public.utf8-plain-text", "keep")])
    }

    // MARK: - The happy path

    @MainActor
    private func makeHarness(
        current: [PasteboardItemSnapshot] = [],
        settleDelay: TimeInterval = 0.3,
        pasteSucceeds: Bool = true,
        onWarn: ((String) -> Void)? = nil
    ) -> (FakePasteboard, FakeClock, PasteInjector,
          pasteCount: () -> Int, typed: () -> [String]) {
        let pasteboard = FakePasteboard(current: current)
        let clock = FakeClock()
        final class Counter { var pastes = 0; var typed: [String] = [] }
        let counter = Counter()
        let injector = PasteInjector(
            pasteboard: pasteboard,
            settleDelay: settleDelay,
            postPaste: { counter.pastes += 1; return pasteSucceeds },
            typeFallback: { counter.typed.append($0) },
            schedule: { delay, work in clock.schedule(delay, work) },
            warn: onWarn ?? { _ in })
        return (pasteboard, clock, injector,
                { counter.pastes }, { counter.typed })
    }

    @Test("paste writes the transcript, posts ⌘V, and restores after the delay")
    func happyPath() {
        let original = [Self.image]
        let (pasteboard, clock, injector, pasteCount, typed) =
            makeHarness(current: original, settleDelay: 0.3)

        injector.inject("hello world")

        // The transcript is on the pasteboard and ⌘V went out…
        #expect(pasteboard.current == [PasteInjector.transcriptItem("hello world")])
        #expect(pasteCount() == 1)
        #expect(typed().isEmpty)

        // …and nothing is restored until the settle delay elapses.
        #expect(clock.scheduled.count == 1)
        #expect(clock.scheduled[0].delay == 0.3)
        #expect(pasteboard.current != original)

        clock.fire(0)
        // The copied image survived the round trip, every representation intact.
        #expect(pasteboard.current == original)
    }

    @Test("an empty transcript injects nothing and never touches the pasteboard")
    func emptyString() {
        let (pasteboard, clock, injector, pasteCount, typed) = makeHarness(current: [Self.image])
        injector.inject("")
        #expect(pasteboard.snapshotCount == 0)
        #expect(pasteboard.writes.isEmpty)
        #expect(pasteCount() == 0)
        #expect(typed().isEmpty)
        #expect(clock.scheduled.isEmpty)
    }

    @Test("an empty pasteboard is restored to empty, not left holding the transcript")
    func emptyPasteboardRoundTrip() {
        let (pasteboard, clock, injector, _, _) = makeHarness(current: [])
        injector.inject("hello")
        #expect(pasteboard.current == [PasteInjector.transcriptItem("hello")])
        clock.fire(0)
        #expect(pasteboard.current.isEmpty)
    }

    // MARK: - Concealed items are never re-published

    @Test("a concealed item is not restored; its siblings are")
    func concealedNotRestored() {
        let (pasteboard, clock, injector, _, _) =
            makeHarness(current: [Self.secret, Self.image])
        injector.inject("hello")
        clock.fire(0)
        #expect(pasteboard.current == [Self.image])
    }

    @Test("an all-concealed pasteboard restores to empty")
    func allConcealedRestoresEmpty() {
        let (pasteboard, clock, injector, _, _) = makeHarness(current: [Self.secret])
        injector.inject("hello")
        clock.fire(0)
        #expect(pasteboard.current.isEmpty)
    }

    // MARK: - Failure falls back to typing; the transcript is never lost

    @Test("a pasteboard write failure types the text instead and posts no ⌘V")
    func writeFailureFallsBack() {
        let original = [Self.image]
        let (pasteboard, clock, injector, pasteCount, typed) = makeHarness(current: original)
        pasteboard.failNextWrite = true

        injector.inject("hello")

        #expect(typed() == ["hello"])
        #expect(pasteCount() == 0)
        #expect(pasteboard.current == original)
        // Nothing left pending that could clobber the pasteboard later.
        for i in clock.scheduled.indices { clock.fire(i) }
        #expect(pasteboard.current == original)
    }

    @Test("a ⌘V synthesis failure restores the pasteboard and types the text")
    func pasteFailureFallsBack() {
        let original = [Self.image]
        let (pasteboard, clock, injector, _, typed) =
            makeHarness(current: original, pasteSucceeds: false)

        injector.inject("hello")

        #expect(typed() == ["hello"])
        // The transcript was written before ⌘V failed; it must not linger.
        #expect(pasteboard.current == original)
        for i in clock.scheduled.indices { clock.fire(i) }
        #expect(pasteboard.current == original)
    }

    @Test("a failure restore also drops concealed items")
    func failureRestoreConcealed() {
        let (pasteboard, _, injector, _, typed) =
            makeHarness(current: [Self.secret], pasteSucceeds: false)
        injector.inject("hello")
        #expect(typed() == ["hello"])
        #expect(pasteboard.current.isEmpty)
    }

    // MARK: - Generation: overlapping dictations

    @Test("two dictations inside the settle window restore the original once")
    func rapidDoubleDictation() {
        let original = [Self.image]
        let (pasteboard, clock, injector, pasteCount, _) = makeHarness(current: original)

        injector.inject("first")
        injector.inject("second")

        // The second snapshot would have captured the first transcript; the
        // injector must keep the one taken while the pasteboard was the user's.
        #expect(pasteboard.snapshotCount == 1)
        #expect(pasteboard.current == [PasteInjector.transcriptItem("second")])
        #expect(pasteCount() == 2)

        // The first restore is stale and must do nothing.
        clock.fire(0)
        #expect(pasteboard.current == [PasteInjector.transcriptItem("second")])

        clock.fire(1)
        #expect(pasteboard.current == original)
    }

    @Test("after a completed restore, the next dictation snapshots afresh")
    func freshSnapshotAfterRestore() {
        let original = [Self.image]
        let (pasteboard, clock, injector, _, _) = makeHarness(current: original)

        injector.inject("first")
        clock.fire(0)
        #expect(pasteboard.current == original)

        // The user copies something new between dictations.
        let newCopy = [Self.item("public.utf8-plain-text", "new copy")]
        pasteboard.current = newCopy

        injector.inject("second")
        #expect(pasteboard.snapshotCount == 2)
        clock.fire(1)
        #expect(pasteboard.current == newCopy)
    }

    // MARK: - The pasteboard belongs to whoever wrote it last

    @Test("an external copy during the settle window wins; the restore stands down")
    func externalCopyWins() {
        let original = [Self.image]
        let (pasteboard, clock, injector, _, _) = makeHarness(current: original)

        injector.inject("hello")
        // The user ⌘C's something in another app before the settle delay
        // fires. The generation counter cannot see this — only the
        // pasteboard's own change count can.
        let userCopy = [Self.item("public.utf8-plain-text", "user copy")]
        pasteboard.externalWrite(userCopy)

        clock.fire(0)
        #expect(pasteboard.current == userCopy)

        // And the stale snapshot was dropped, not parked: the next dictation
        // snapshots the user's copy afresh and restores *that*.
        injector.inject("second")
        #expect(pasteboard.snapshotCount == 2)
        clock.fire(1)
        #expect(pasteboard.current == userCopy)
    }

    // MARK: - A restore that fails says so

    @Test("a failed restore warns instead of silently losing the snapshot")
    func failedRestoreWarns() {
        final class Warnings { var lines: [String] = [] }
        let warnings = Warnings()
        let (pasteboard, clock, injector, _, _) = makeHarness(
            current: [Self.image], onWarn: { warnings.lines.append($0) })

        injector.inject("hello")
        pasteboard.failNextWrite = true
        clock.fire(0)

        #expect(warnings.lines.count == 1)
        #expect(warnings.lines.joined().contains("restore"))
    }

    // MARK: - Concealed bytes never sit in the daemon's memory

    @Test("concealed items are dropped at snapshot time, not merely at restore")
    func concealedDroppedAtSnapshot() {
        let (_, _, injector, _, _) = makeHarness(current: [Self.secret, Self.image])
        injector.inject("hello")
        // The held snapshot must not contain the password bytes for the
        // duration of the settle window — filtering only at restore would.
        #expect(injector.saved == [Self.image])
    }

    @Test("a fallback mid-window cancels the pending restore after restoring now")
    func fallbackCancelsPendingRestore() {
        let original = [Self.image]
        let (pasteboard, clock, injector, _, typed) = makeHarness(current: original)

        injector.inject("first")               // schedules restore #0
        pasteboard.failNextWrite = true
        injector.inject("second")              // fails → restores now, types

        #expect(typed() == ["second"])
        #expect(pasteboard.current == original)

        // The first dictation's timer must not restore again (double-restore
        // would clobber anything the user copies in the meantime).
        pasteboard.current = [Self.item("public.utf8-plain-text", "user copy")]
        clock.fire(0)
        #expect(pasteboard.current == [Self.item("public.utf8-plain-text", "user copy")])
    }
}
