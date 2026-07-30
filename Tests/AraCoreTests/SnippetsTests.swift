import Foundation
import Testing
@testable import AraCore

@Suite("Snippets")
struct SnippetsTests {

    private func snippets(_ entries: [Snippets.Entry]) -> Snippets {
        Snippets(entries: entries)
    }

    private func entry(_ trigger: String, _ expansion: String)
        -> Snippets.Entry
    {
        Snippets.Entry(trigger: trigger, expansion: expansion)
    }

    private func write(_ content: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ara-snip-\(UUID().uuidString).json")
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

    // MARK: - normalize: the identity a trigger and an utterance share

    @Test("normalization folds case")
    func normalizeFoldsCase() {
        #expect(Snippets.normalize("Insert My Scheduling Link")
                == "insert my scheduling link")
    }

    /// The user dictates Polish: case folding must cover `Ż`, `Ó`, `Ł`, `Ć`
    /// and every other diacritic letter, not just ASCII.
    @Test("case folding covers Polish diacritics")
    func normalizeFoldsDiacriticCase() {
        #expect(Snippets.normalize("PODPIS SŁUŻBOWY") == "podpis służbowy")
        #expect(Snippets.normalize("Wyślij Późną Odpowiedź")
                == "wyślij późną odpowiedź")
    }

    /// Case-folded, not diacritic-folded: "krakow" and "kraków" are different
    /// phrases. A trigger fires on what was said, not on what it resembles.
    @Test("diacritics are significant, not folded away")
    func normalizeKeepsDiacritics() {
        #expect(Snippets.normalize("kraków") != Snippets.normalize("krakow"))
    }

    @Test("surrounding whitespace is trimmed")
    func normalizeTrims() {
        #expect(Snippets.normalize("  insert my link \n") == "insert my link")
    }

    /// The ASR appends sentence punctuation the trigger's author never typed:
    /// "insert my link." and "insert my link" are the same utterance.
    @Test("terminal punctuation is stripped, in every variant")
    func normalizeStripsTerminalPunctuation() {
        for spoken in ["insert my link.", "insert my link!", "insert my link?",
                       "insert my link…", "insert my link?!", "insert my link,",
                       "insert my link ."] {
            #expect(Snippets.normalize(spoken) == "insert my link",
                    "«\(spoken)» should normalize to «insert my link»")
        }
    }

    /// Terminal means terminal: punctuation *inside* the phrase is part of
    /// what was said and must survive.
    @Test("internal punctuation survives")
    func normalizeKeepsInternalPunctuation() {
        #expect(Snippets.normalize("sign off, formal.") == "sign off, formal")
    }

    @Test("internal whitespace collapses to single spaces")
    func normalizeCollapsesWhitespace() {
        #expect(Snippets.normalize("insert  my\tscheduling\n link")
                == "insert my scheduling link")
    }

    @Test("an empty or punctuation-only utterance normalizes to nothing")
    func normalizeDegenerateInputs() {
        #expect(Snippets.normalize("") == "")
        #expect(Snippets.normalize("   ") == "")
        #expect(Snippets.normalize("...") == "")
        #expect(Snippets.normalize(" ?! ") == "")
    }

    // MARK: - expansion(for:): whole-utterance matching

    @Test("a dictated trigger yields its expansion verbatim")
    func basicMatch() {
        let s = snippets([entry("insert my scheduling link",
                                "https://cal.com/pawel/30min")])
        #expect(s.expansion(for: "insert my scheduling link")
                == "https://cal.com/pawel/30min")
    }

    /// The whole point of injecting verbatim: an expansion is authored text,
    /// newlines and all, and nothing between the file and the injector may
    /// touch it.
    @Test("a multiline expansion comes back byte-for-byte")
    func multilineExpansion() {
        let signature = "Best regards,\nPawel Karniej\nSilpho\n"
        let s = snippets([entry("sign off formal", signature)])
        #expect(s.expansion(for: "sign off formal") == signature)
    }

    @Test("the utterance matches under normalization")
    func utteranceIsNormalized() {
        let s = snippets([entry("insert my link", "https://example.com")])
        #expect(s.expansion(for: "Insert my link.") == "https://example.com")
        #expect(s.expansion(for: "  insert  MY link?! ") == "https://example.com")
    }

    /// The trigger side is normalized too: a hand-written "Insert my link."
    /// in the file must not be a trigger that can never fire.
    @Test("the trigger matches under normalization")
    func triggerIsNormalized() {
        let s = snippets([entry("Insert my link.", "https://example.com")])
        #expect(s.expansion(for: "insert my link") == "https://example.com")
    }

    @Test("a Polish trigger with diacritics matches the dictated form")
    func polishTrigger() {
        let s = snippets([entry("podpis służbowy", "Z poważaniem,\nPaweł")])
        #expect(s.expansion(for: "Podpis służbowy.") == "Z poważaniem,\nPaweł")
        // The diacritic-less near-miss is a different phrase.
        #expect(s.expansion(for: "podpis sluzbowy") == nil)
    }

    /// No substring matching, ever: a trigger firing inside a real sentence
    /// replaces words the user actually wanted, which is strictly worse than
    /// a missed trigger.
    @Test("a sentence containing the trigger is not a match")
    func substringIsNotAMatch() {
        let s = snippets([entry("insert my link", "https://example.com")])
        #expect(s.expansion(for: "please insert my link here") == nil)
        #expect(s.expansion(for: "insert my link please") == nil)
        #expect(s.expansion(for: "oh insert my link") == nil)
    }

    @Test("no snippets means no match")
    func emptySnippets() {
        #expect(snippets([]).expansion(for: "insert my link") == nil)
    }

    @Test("an empty utterance never matches, even an empty trigger")
    func emptyUtterance() {
        #expect(snippets([entry("", "boom")]).expansion(for: "") == nil)
        #expect(snippets([entry("...", "boom")]).expansion(for: "?!") == nil)
    }

    /// A misconfigured file behaves deterministically: the first entry wins,
    /// same rule as the dictionary's duplicate variants.
    @Test("duplicate triggers resolve to the first entry")
    func duplicateTriggerFirstWins() {
        let s = snippets([entry("sign off", "first"),
                          entry("Sign off.", "second")])
        #expect(s.expansion(for: "sign off") == "first")
    }

    /// An empty expansion would erase the utterance — "nothing to type" for
    /// words the user actually said. Such an entry is inert and the utterance
    /// processes normally.
    @Test("an entry with an empty expansion never matches")
    func emptyExpansionIsInert() {
        let s = snippets([entry("sign off", "")])
        #expect(s.expansion(for: "sign off") == nil)
    }

    // MARK: - load: tolerant, hot, quiet about the normal case

    @Test("the file lives next to config.json")
    func defaultLocation() {
        #expect(Snippets.defaultURL
                == Config.defaultURL.deletingLastPathComponent()
                    .appendingPathComponent("snippets.json"))
    }

    @Test("a missing file is empty snippets and says nothing")
    func missingFile() {
        let warnings = Warnings()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ara-snip-missing-\(UUID().uuidString).json")
        let s = Snippets.load(from: url, warn: warnings.sink)
        #expect(s.entries.isEmpty)
        #expect(warnings.lines.isEmpty)
    }

    @Test("a well-formed file loads its entries")
    func wellFormedFile() {
        let warnings = Warnings()
        let url = write(
            #"[{"trigger": "sign off formal", "expansion": "Best,\nPawel"}]"#)
        let s = Snippets.load(from: url, warn: warnings.sink)
        #expect(s.entries == [entry("sign off formal", "Best,\nPawel")])
        #expect(warnings.lines.isEmpty)
    }

    /// Hot reload is nothing more than reading fresh every call — an edit
    /// must reach the very next load, no restart, no cache.
    @Test("the file is read fresh on every load")
    func hotReload() {
        let url = write(#"[{"trigger": "a", "expansion": "one"}]"#)
        #expect(Snippets.load(from: url).entries == [entry("a", "one")])
        try! #"[{"trigger": "b", "expansion": "two"}]"#
            .write(to: url, atomically: true, encoding: .utf8)
        #expect(Snippets.load(from: url).entries == [entry("b", "two")])
    }

    @Test("a malformed file is empty, warns once, and never spams")
    func malformedWarnsOnce() {
        let warnings = Warnings()
        let url = write("not json at all")
        for _ in 0..<5 {
            #expect(Snippets.load(from: url, warn: warnings.sink).entries.isEmpty)
        }
        #expect(warnings.lines.count == 1)
        #expect(warnings.joined.contains(url.path))
    }

    @Test("a malformed file that changes to different garbage warns again")
    func changedMalformedWarnsAgain() {
        let warnings = Warnings()
        let url = write("garbage one")
        _ = Snippets.load(from: url, warn: warnings.sink)
        try! "garbage two".write(to: url, atomically: true, encoding: .utf8)
        _ = Snippets.load(from: url, warn: warnings.sink)
        _ = Snippets.load(from: url, warn: warnings.sink)
        #expect(warnings.lines.count == 2)
    }

    /// Fixing the file resets the ledger: the *next* breakage is a new
    /// failure the user has not been told about yet.
    @Test("a repaired file that breaks again warns again")
    func repairedThenBrokenWarnsAgain() {
        let warnings = Warnings()
        let url = write("broken")
        _ = Snippets.load(from: url, warn: warnings.sink)
        try! #"[{"trigger": "a", "expansion": "one"}]"#
            .write(to: url, atomically: true, encoding: .utf8)
        _ = Snippets.load(from: url, warn: warnings.sink)
        try! "broken".write(to: url, atomically: true, encoding: .utf8)
        _ = Snippets.load(from: url, warn: warnings.sink)
        #expect(warnings.lines.count == 2)
    }
}
