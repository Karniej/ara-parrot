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
}
