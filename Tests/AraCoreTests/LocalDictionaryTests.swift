import Foundation
import Testing
@testable import AraCore

@Suite("LocalDictionary")
struct LocalDictionaryTests {

    private func dict(_ entries: [LocalDictionary.Entry]) -> LocalDictionary {
        LocalDictionary(entries: entries)
    }

    private func entry(_ canonical: String, _ variants: String...)
        -> LocalDictionary.Entry
    {
        LocalDictionary.Entry(canonical: canonical, variants: variants)
    }

    private func write(_ content: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ara-dict-\(UUID().uuidString).json")
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Collects what the user would have been told.
    private final class Warnings: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        var sink: @Sendable (String) -> Void {
            { line in self.lock.lock(); self.stored.append(line); self.lock.unlock() }
        }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return stored }
        var joined: String { lines.joined(separator: "\n") }
    }

    // MARK: - apply: the replacement engine

    @Test("replaces a misheard variant with its canonical form")
    func basicReplacement() {
        let d = dict([entry("Ara", "arra", "aara")])
        #expect(d.apply("i said arra loudly") == "i said Ara loudly")
    }

    @Test("every occurrence is replaced, not just the first")
    func allOccurrences() {
        let d = dict([entry("Ara", "arra")])
        #expect(d.apply("arra talks to arra") == "Ara talks to Ara")
    }

    @Test("an empty dictionary returns the input unchanged")
    func emptyDictionary() {
        #expect(dict([]).apply("nothing to correct here") == "nothing to correct here")
    }

    // MARK: - apply: the three ported PR-#6 specs

    /// A `$` in the canonical must stay a dollar sign. Regex replacement
    /// templates treat `$0`/`$1` as capture references, so an unescaped
    /// template would splice match text where the user wrote currency.
    @Test("a dollar sign in the canonical stays literal")
    func literalDollar() {
        let d = dict([entry("$100", "hundred bucks")])
        #expect(d.apply("it costs hundred bucks today") == "it costs $100 today")
    }

    /// The regression PR #6 fixed: a variant that is a prefix of a longer
    /// word must not fire inside it.
    @Test("a variant that is a prefix of a longer word does not fire inside it")
    func prefixOfLongerWord() {
        let d = dict([entry("Ara", "ara")])
        #expect(d.apply("arabica beans") == "arabica beans")
    }

    @Test("matches are whole words: punctuation bounds, letters do not")
    func wholeWordBoundaries() {
        let d = dict([entry("Ara", "ara")])
        #expect(d.apply("ara, meet ara!") == "Ara, meet Ara!")
        #expect(d.apply("(ara)") == "(Ara)")
        #expect(d.apply("paragraf") == "paragraf")
        // Underscore is a word character: `ara_config` is an identifier, not
        // the word "ara".
        #expect(d.apply("ara_config") == "ara_config")
        #expect(d.apply("2ara") == "2ara")
    }

    // MARK: - apply: the rest of the contract

    @Test("matching is case-insensitive and the canonical is inserted verbatim")
    func caseInsensitiveCanonicalVerbatim() {
        let d = dict([entry("PostgreSQL", "postgres")])
        #expect(d.apply("POSTGRES is up") == "PostgreSQL is up")
        #expect(d.apply("Postgres is up") == "PostgreSQL is up")
    }

    /// "new york times" must beat "new york" even when the shorter variant
    /// belongs to an earlier entry — longest across *all* entries, not
    /// first-listed.
    @Test("the longest variant wins across entries")
    func longestVariantFirst() {
        let d = dict([entry("NYC", "new york"),
                      entry("NYT", "new york times")])
        #expect(d.apply("the new york times said") == "the NYT said")
        #expect(d.apply("back in new york today") == "back in NYC today")
    }

    /// The user dictates Polish: `ł`, `ż` and friends are letters, so a
    /// variant must not match a fragment whose neighbour is a diacritic
    /// letter — ASCII-only `\w`/`\b` would treat `ł` as a boundary.
    @Test("Polish diacritics are word characters for boundary purposes")
    func polishDiacriticBoundaries() {
        #expect(dict([entry("X", "star")]).apply("starł") == "starł")
        #expect(dict([entry("X", "owo")]).apply("słowo") == "słowo")
        #expect(dict([entry("X", "ar")]).apply("żar") == "żar")
        // And a variant containing diacritics still matches as a whole word.
        let d = dict([entry("Kraków", "krakuf")])
        #expect(d.apply("jadę do krakuf jutro") == "jadę do Kraków jutro")
    }

    /// Single pass: one entry's output is never re-matched by another entry,
    /// in either listing order — but the same variant elsewhere in the
    /// original text is still replaced.
    @Test("one entry's output is never re-matched by another")
    func noChaining() {
        let d = dict([entry("bar baz", "foo"), entry("QUX", "baz")])
        #expect(d.apply("foo") == "bar baz")
        #expect(d.apply("foo and baz") == "bar baz and QUX")

        let reversed = dict([entry("QUX", "baz"), entry("bar baz", "foo")])
        #expect(reversed.apply("foo") == "bar baz")
    }

    @Test("regex metacharacters in a variant are treated literally")
    func metacharactersAreLiteral() {
        let d = dict([entry("Node.js", "node.js")])
        #expect(d.apply("deploy node.js now") == "deploy Node.js now")
        #expect(d.apply("deploy nodeXjs now") == "deploy nodeXjs now")
    }

    // MARK: - load: tolerant, hot, quiet about the normal case

    @Test("a missing file is an empty dictionary and says nothing")
    func missingFile() {
        let warnings = Warnings()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ara-dict-missing-\(UUID().uuidString).json")
        let d = LocalDictionary.load(from: url, warn: warnings.sink)
        #expect(d.entries.isEmpty)
        #expect(warnings.lines.isEmpty)
    }

    @Test("a well-formed file loads its entries")
    func wellFormedFile() {
        let warnings = Warnings()
        let url = write(#"[{"canonical": "Ara", "variants": ["arra", "aara"]}]"#)
        let d = LocalDictionary.load(from: url, warn: warnings.sink)
        #expect(d.entries == [entry("Ara", "arra", "aara")])
        #expect(warnings.lines.isEmpty)
    }

    /// Hot reload is nothing more than reading fresh every call — an edit
    /// must reach the very next load, no restart, no cache.
    @Test("the file is read fresh on every load")
    func hotReload() {
        let url = write(#"[{"canonical": "Ara", "variants": ["arra"]}]"#)
        #expect(LocalDictionary.load(from: url).entries == [entry("Ara", "arra")])
        try! #"[{"canonical": "Parrot", "variants": ["parat"]}]"#
            .write(to: url, atomically: true, encoding: .utf8)
        #expect(LocalDictionary.load(from: url).entries == [entry("Parrot", "parat")])
    }

    @Test("a malformed file is empty, warns once, and never spams")
    func malformedWarnsOnce() {
        let warnings = Warnings()
        let url = write("not json at all")
        for _ in 0..<5 {
            #expect(LocalDictionary.load(from: url, warn: warnings.sink).entries.isEmpty)
        }
        #expect(warnings.lines.count == 1)
        #expect(warnings.joined.contains(url.path))
    }

    @Test("a malformed file that changes to different garbage warns again")
    func changedMalformedWarnsAgain() {
        let warnings = Warnings()
        let url = write("garbage one")
        _ = LocalDictionary.load(from: url, warn: warnings.sink)
        try! "garbage two".write(to: url, atomically: true, encoding: .utf8)
        _ = LocalDictionary.load(from: url, warn: warnings.sink)
        _ = LocalDictionary.load(from: url, warn: warnings.sink)
        #expect(warnings.lines.count == 2)
    }

    /// Fixing the file resets the ledger: the *next* breakage is a new
    /// failure the user has not been told about yet.
    @Test("a repaired file that breaks again warns again")
    func repairedThenBrokenWarnsAgain() {
        let warnings = Warnings()
        let url = write("broken")
        _ = LocalDictionary.load(from: url, warn: warnings.sink)
        try! #"[{"canonical": "Ara", "variants": ["arra"]}]"#
            .write(to: url, atomically: true, encoding: .utf8)
        _ = LocalDictionary.load(from: url, warn: warnings.sink)
        try! "broken".write(to: url, atomically: true, encoding: .utf8)
        _ = LocalDictionary.load(from: url, warn: warnings.sink)
        #expect(warnings.lines.count == 2)
    }

    // MARK: - adding: the pure merge Task 2's form calls

    @Test("adding a correction for a new canonical creates an entry")
    func addingCreatesEntry() {
        let d = dict([]).adding(heard: "arra", canonical: "Ara")
        #expect(d.entries == [entry("Ara", "arra")])
    }

    @Test("adding to an existing canonical appends the variant")
    func addingAppendsVariant() {
        let d = dict([entry("Ara", "arra")]).adding(heard: "aara", canonical: "Ara")
        #expect(d.entries == [entry("Ara", "arra", "aara")])
    }

    /// Canonical dedupe is case- and diacritic-insensitive: "Krakow" typed
    /// into the form must merge into the existing "Kraków" entry, not fork a
    /// near-duplicate.
    @Test("canonical matching for the merge ignores case and diacritics")
    func addingMergesAccentedCanonical() {
        let d = dict([entry("Kraków", "krakuf")])
            .adding(heard: "krakof", canonical: "krakow")
        #expect(d.entries == [entry("Kraków", "krakuf", "krakof")])
    }

    @Test("adding an existing variant to its own canonical is a no-op")
    func addingExistingVariantIsNoOp() {
        let original = dict([entry("Ara", "arra")])
        #expect(original.adding(heard: "arra", canonical: "Ara") == original)
        #expect(original.adding(heard: "ARRA", canonical: "ara") == original)
    }

    @Test("a variant already mapped to another canonical moves")
    func addingMovesVariant() {
        let d = dict([entry("Ara", "arra", "aara"), entry("Parrot", "parat")])
            .adding(heard: "arra", canonical: "Parrot")
        #expect(d.entries == [entry("Ara", "aara"),
                              entry("Parrot", "parat", "arra")])
    }

    /// The move above, when the moved variant was its entry's last: the
    /// emptied entry is dropped, not kept. A variant-less entry can never
    /// match anything, and the form never needs one — re-adding a correction
    /// for that canonical later recreates the entry.
    @Test("moving the last variant away drops the emptied entry")
    func addingDropsEmptiedEntry() {
        let d = dict([entry("Ara", "arra"), entry("Parrot", "parat")])
            .adding(heard: "arra", canonical: "Parrot")
        #expect(d.entries == [entry("Parrot", "parat", "arra")])
    }

    /// The form's empty-field rule, enforced at the merge too: a blank side
    /// changes nothing, so no caller can write a broken entry.
    @Test("an empty or whitespace-only input is a no-op")
    func addingEmptyInputsAreNoOps() {
        let original = dict([entry("Ara", "arra")])
        #expect(original.adding(heard: "", canonical: "Ara") == original)
        #expect(original.adding(heard: "  \n", canonical: "Ara") == original)
        #expect(original.adding(heard: "aara", canonical: "") == original)
        #expect(original.adding(heard: " ", canonical: "\t") == original)
    }

    @Test("inputs are trimmed before merging")
    func addingTrimsInputs() {
        let d = dict([]).adding(heard: "  arra ", canonical: " Ara\n")
        #expect(d.entries == [entry("Ara", "arra")])
    }

    // MARK: - encoding: stable, pretty, round-trips

    @Test("encoding is deterministic and round-trips through load")
    func encodingRoundTrips() throws {
        let d = dict([entry("Ara", "arra", "aara"), entry("Kraków", "krakuf")])
        let first = try d.encoded()
        let second = try d.encoded()
        #expect(first == second)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ara-dict-rt-\(UUID().uuidString).json")
        try first.write(to: url)
        #expect(LocalDictionary.load(from: url).entries == d.entries)
    }

    @Test("the encoded file is pretty-printed for hand editing")
    func encodingIsPretty() throws {
        let data = try dict([entry("Ara", "arra")]).encoded()
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\n"))
        #expect(text.contains("\"canonical\""))
    }

    // MARK: - write: the persistence the menu form calls

    private func uniqueURL(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ara-dict-\(tag)-\(UUID().uuidString).json")
    }

    /// The whole menu flow, minus AppKit: load whatever is there, merge the
    /// correction in, write, and the next per-utterance load sees it.
    @Test("adding then writing round-trips through load")
    func writeRoundTripsThroughLoad() throws {
        let url = uniqueURL("write-rt")
        let d = LocalDictionary.load(from: url)
            .adding(heard: "arra", canonical: "Ara")
            .adding(heard: "krakuf", canonical: "Kraków")
        try d.write(to: url)
        #expect(LocalDictionary.load(from: url) == d)

        // A later correction merges into what the first write left behind —
        // including the case-insensitive canonical match.
        let again = LocalDictionary.load(from: url)
            .adding(heard: "aara", canonical: "ara")
        try again.write(to: url)
        #expect(LocalDictionary.load(from: url).entries
                == [entry("Ara", "arra", "aara"), entry("Kraków", "krakuf")])
    }

    /// A fresh install has no `~/.config/ara` until something writes there;
    /// the first correction must not require the user to `mkdir` first.
    @Test("write creates the directory when it is missing")
    func writeCreatesDirectory() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ara-dict-dir-\(UUID().uuidString)")
            .appendingPathComponent("nested")
            .appendingPathComponent("dictionary.json")
        try dict([entry("Ara", "arra")]).write(to: url)
        #expect(LocalDictionary.load(from: url).entries == [entry("Ara", "arra")])
    }

    @Test("write emits exactly the stable pretty JSON encoded() promises")
    func writeMatchesEncoded() throws {
        let url = uniqueURL("write-stable")
        let d = dict([entry("Ara", "arra"), entry("Kraków", "krakuf")])
        try d.write(to: url)
        #expect(try Data(contentsOf: url) == d.encoded())
    }

    // MARK: - starter: the file "Edit dictionary…" is born with

    /// The starter must be a dictionary the per-utterance load reads back
    /// exactly — a user whose first act is "Edit dictionary…" gets a working
    /// file, not a template that warns on the next utterance.
    @Test("the starter file round-trips through load cleanly")
    func starterRoundTripsThroughLoad() throws {
        let url = uniqueURL("starter-rt")
        try LocalDictionary.starter.write(to: url)
        let warnings = Warnings()
        let loaded = LocalDictionary.load(from: url, warn: warnings.sink)
        #expect(loaded == LocalDictionary.starter)
        #expect(warnings.lines.isEmpty)
    }

    /// JSON has no comments, so the example entry *is* the documentation: it
    /// must match the README's example — canonical "Ara", misheard variants —
    /// so the file and the docs teach the same lesson.
    @Test("the starter's example entry matches the README's")
    func starterMatchesREADMEExample() {
        #expect(LocalDictionary.starter.entries
                == [entry("Ara", "arra", "aara")])
    }

    @Test("createStarterFileIfAbsent writes the starter where nothing was")
    func starterCreatedWhenAbsent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ara-dict-starter-\(UUID().uuidString)")
            .appendingPathComponent("dictionary.json")
        #expect(try LocalDictionary.createStarterFileIfAbsent(at: url))
        #expect(try Data(contentsOf: url)
                == LocalDictionary.starter.encoded())
    }

    /// The user's accumulated vocabulary — or even their half-broken edit —
    /// must never be replaced by the example. Any existing file, parseable or
    /// not, stays byte-identical.
    @Test("createStarterFileIfAbsent never touches an existing file")
    func starterLeavesExistingFileAlone() throws {
        let existing = uniqueURL("starter-existing")
        try dict([entry("Kraków", "krakuf")]).write(to: existing)
        let before = try Data(contentsOf: existing)
        #expect(try !LocalDictionary.createStarterFileIfAbsent(at: existing))
        #expect(try Data(contentsOf: existing) == before)

        let broken = uniqueURL("starter-broken")
        try Data("not json".utf8).write(to: broken)
        #expect(try !LocalDictionary.createStarterFileIfAbsent(at: broken))
        #expect(try Data(contentsOf: broken) == Data("not json".utf8))
    }

    // MARK: - listingLines: what `parrot dictionary` prints

    @Test("the listing is the path, then one canonical ← variants line per entry")
    func listingLinesForEntries() {
        let d = dict([entry("Ara", "arra", "aara"), entry("Kraków", "krakuf")])
        #expect(d.listingLines(path: "/home/u/.config/ara/dictionary.json") == [
            "/home/u/.config/ara/dictionary.json",
            "Ara ← arra, aara",
            "Kraków ← krakuf",
        ])
    }

    /// Entry order is file order everywhere else; the listing must not sort.
    @Test("the listing preserves file order")
    func listingPreservesOrder() {
        let d = dict([entry("Zulu", "zoolu"), entry("Alpha", "alfa")])
        #expect(d.listingLines(path: "p") == ["p", "Zulu ← zoolu", "Alpha ← alfa"])
    }

    @Test("an empty dictionary lists as 'no dictionary yet' plus the path")
    func listingLinesWhenEmpty() {
        let lines = dict([]).listingLines(path: "/x/dictionary.json")
        #expect(lines == ["no dictionary yet — corrections will live at /x/dictionary.json"])
    }

    // MARK: - UnsavedCorrections: what applies when the write failed

    @Test("with nothing remembered the overlay changes nothing")
    func unsavedOverlayEmpty() {
        let base = dict([entry("Ara", "arra")])
        #expect(UnsavedCorrections().applied(to: base) == base)
    }

    /// A correction whose write failed still applies for the rest of the
    /// session: replayed, in order, on top of every fresh load.
    @Test("remembered corrections apply on top of every fresh load")
    func unsavedOverlayApplies() {
        let unsaved = UnsavedCorrections()
        unsaved.remember(heard: "parat", canonical: "Parrot")
        unsaved.remember(heard: "aara", canonical: "Ara")
        let base = dict([entry("Ara", "arra")])
        #expect(unsaved.applied(to: base).entries
                == [entry("Ara", "arra", "aara"), entry("Parrot", "parat")])
    }

    /// Once the file catches up — a later write succeeded, or the user added
    /// the correction by hand — the replay must change nothing.
    @Test("a correction the file has since gained overlays as a no-op")
    func unsavedOverlayIsIdempotent() {
        let unsaved = UnsavedCorrections()
        unsaved.remember(heard: "arra", canonical: "Ara")
        let caughtUp = dict([entry("Ara", "arra")])
        #expect(unsaved.applied(to: caughtUp) == caughtUp)
    }

    /// A successful write clears the backlog, so a correction the user later
    /// hand-deletes from the file cannot be resurrected by the overlay.
    @Test("clear forgets the backlog once a write has landed it")
    func unsavedClearForgets() {
        let unsaved = UnsavedCorrections()
        unsaved.remember(heard: "arra", canonical: "Ara")
        unsaved.clear()
        #expect(unsaved.applied(to: dict([])) == dict([]))
    }

    // MARK: - save: the menu form's whole decision, AppKit excluded

    /// A directory the daemon cannot write into, restored on the way out —
    /// how these tests make `write` fail on demand.
    private func readOnlyDirectory() throws -> (dir: URL, url: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ara-dict-ro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return (dir, dir.appendingPathComponent("dictionary.json"))
    }

    private func setWritable(_ writable: Bool, _ dir: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: writable ? 0o755 : 0o555],
            ofItemAtPath: dir.path)
    }

    @Test("save merges into the file and lands the backlog with it")
    func saveWritesMergeAndBacklog() throws {
        let url = uniqueURL("save")
        let unsaved = UnsavedCorrections()
        unsaved.remember(heard: "parat", canonical: "Parrot")
        #expect(unsaved.save(heard: "arra", canonical: "Ara", to: url) == nil)
        #expect(LocalDictionary.load(from: url).entries
                == [entry("Parrot", "parat"), entry("Ara", "arra")])
        // The backlog rode along with the write and is forgotten: a later
        // hand deletion from the file must not be resurrected.
        #expect(unsaved.applied(to: dict([])) == dict([]))
    }

    /// No churn: proved by making a write impossible — a save that attempted
    /// one would return its error.
    @Test("a correction the file already has writes nothing")
    func saveNoChurn() throws {
        let (dir, url) = try readOnlyDirectory()
        try dict([entry("Ara", "arra")]).write(to: url)
        try setWritable(false, dir)
        defer { try? setWritable(true, dir) }
        #expect(UnsavedCorrections()
            .save(heard: "ARRA", canonical: "ara", to: url) == nil)
    }

    /// The clobber hole: `load` tolerates a broken file by behaving as empty
    /// (dictation must never stop), but a *rewrite* must not — merging into
    /// the empty fallback and writing back would atomically replace the
    /// user's whole accumulated vocabulary with a single new entry. A file
    /// that exists but cannot be parsed gets the failed-write treatment
    /// instead: bytes untouched, error returned (the daemon's "applies until
    /// quit" line), correction backlogged.
    ///
    /// The fixture is a *truncated* file, not a trailing comma: this OS's
    /// `JSONDecoder` quietly accepts trailing commas, so a comma would test
    /// nothing. Truncation mid-edit is also exactly the manual-verification
    /// breakage.
    @Test("save never rewrites a file it cannot parse")
    func saveRefusesToClobberBrokenFile() throws {
        let url = uniqueURL("save-broken")
        // A hand edit gone wrong: the closing bracket never made it.
        let broken = Data(#"[{"canonical": "Ara", "variants": ["arra"]}"#.utf8)
        try broken.write(to: url)

        let unsaved = UnsavedCorrections()
        #expect(unsaved.save(heard: "parat", canonical: "Parrot", to: url) != nil)
        #expect(try Data(contentsOf: url) == broken)
        // The correction still applies for the session, on top of whatever
        // each utterance's load can read (nothing, while the file is broken).
        #expect(unsaved
            .applied(to: LocalDictionary.load(from: url, warn: { _ in }))
            .entries == [entry("Parrot", "parat")])
    }

    /// The stale-backlog hole: a correction whose write failed must not
    /// outvote the user's *newer* answer for the same variant. Sequence:
    /// a mistaken `arra → Parrot` fails to write and is backlogged; the user
    /// re-corrects with `arra → Ara`, whose merged result equals the file
    /// exactly — nothing to write, but the backlog now contradicts what the
    /// user just asked for, and keeping it would make the stale correction
    /// win on every later load until quit.
    @Test("re-correcting a failed save drops the stale backlog")
    func saveDropsContradictedBacklog() throws {
        let (dir, url) = try readOnlyDirectory()
        try dict([entry("Ara", "arra")]).write(to: url)
        try setWritable(false, dir)
        defer { try? setWritable(true, dir) }

        let unsaved = UnsavedCorrections()
        // (1) The mistake: write fails, correction backlogged and applying.
        #expect(unsaved.save(heard: "arra", canonical: "Parrot", to: url) != nil)
        #expect(unsaved.applied(to: LocalDictionary.load(from: url)).entries
                == [entry("Parrot", "arra")])
        // (2) The user corrects the mistake. Merged state == the file, so
        // there is nothing to write and no error to report.
        #expect(unsaved.save(heard: "arra", canonical: "Ara", to: url) == nil)
        // (3) Every later utterance must see the user's newer answer, not
        // the stale backlog.
        #expect(unsaved.applied(to: LocalDictionary.load(from: url)).entries
                == [entry("Ara", "arra")])
    }
}
