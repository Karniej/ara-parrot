import Foundation

/// Voice-activated text expansion: the user dictates a trigger phrase —
/// "insert my scheduling link", "sign off formal" — and the expansion text is
/// injected verbatim instead of the transcript.
///
/// ## Whole-utterance matching, nothing fuzzier
///
/// A trigger fires only when the *entire* utterance equals it under
/// `normalize` — case-folded, surrounding whitespace trimmed, terminal
/// punctuation stripped, internal whitespace collapsed. No substring or fuzzy
/// matching: a trigger firing inside a real sentence replaces words the user
/// actually wanted, which is strictly worse than a missed trigger. The
/// sentence "please insert my scheduling link here" formats normally.
///
/// ## The expansion is authored text, not speech
///
/// On a hit, `DictationSession.process` returns the expansion as the final
/// output: no mode, no formatter chain, no output guard — nothing between the
/// file and the injector may touch it, which is what lets an expansion carry
/// newlines, URLs, and exact capitalisation.
///
/// ## The same tolerant loader as `LocalDictionary`
///
/// `snippets.json` lives next to `config.json` and `dictionary.json` and
/// follows the same philosophy: `load` never throws (a missing or malformed
/// file is empty snippets — the feature simply off), it runs per utterance
/// (that *is* the hot-reload mechanism), and a broken file warns once per
/// distinct failure rather than once per dictation. The loader is deliberately
/// a mirror of `LocalDictionary.load` rather than a shared abstraction — two
/// similar loaders are cheaper than the wrong generalisation, and a third
/// file of this shape is the moment to revisit that.
public struct Snippets: Sendable, Equatable {
    /// One snippet: the phrase the user dictates, and the text that should be
    /// typed in its place.
    public struct Entry: Sendable, Equatable, Codable {
        public var trigger: String
        public var expansion: String

        public init(trigger: String, expansion: String) {
            self.trigger = trigger
            self.expansion = expansion
        }
    }

    /// In file order; the first entry wins a duplicate trigger, so a
    /// misconfigured file behaves deterministically.
    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    /// `snippets.json` in the directory the user already edits configuration
    /// in — derived from `Config.defaultURL` rather than spelled out again,
    /// so the files cannot drift apart.
    public static var defaultURL: URL {
        Config.defaultURL.deletingLastPathComponent()
            .appendingPathComponent("snippets.json")
    }

    // MARK: - Loading

    /// Loads the snippets, reading the file fresh — callers call this per
    /// utterance and edits apply to the very next dictation.
    ///
    /// Never throws and never blocks dictation: a missing file is the normal
    /// case for an install that has added no snippets and says nothing; an
    /// unreadable or malformed file warns once per distinct failure and
    /// behaves as empty. `warn` is injectable so tests can assert on what a
    /// user would be told — and on what they would *not* be told twice.
    public static func load(from url: URL,
                            warn: @Sendable (String) -> Void = warnToStderr)
        -> Snippets
    {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if FileManager.default.fileExists(atPath: url.path) {
                failureLog.warnOnce(signature: "unreadable \(type(of: error))",
                                    at: url.path, warn: warn) {
                    "cannot read \(url.path) (\(type(of: error))); "
                    + "dictating without snippets"
                }
            } else {
                // Deleting the file is a fix like any other: the next
                // breakage is news again.
                failureLog.clear(url.path)
            }
            return Snippets()
        }

        do {
            let entries = try JSONDecoder().decode([Entry].self, from: data)
            failureLog.clear(url.path)
            return Snippets(entries: entries)
        } catch {
            // Signed by content hash, exactly as `LocalDictionary.load`:
            // reloading the same broken bytes says nothing new, but an edit
            // that produces *different* broken bytes is a fresh mistake the
            // user has not been told about.
            failureLog.warnOnce(signature: "malformed \(data.hashValue)",
                                at: url.path, warn: warn) {
                "ignoring \(url.path): \(Config.describe(error)); "
                + "dictating without snippets"
            }
            return Snippets()
        }
    }

    /// Which failure each path last warned about, so a per-utterance `load`
    /// of the same broken file costs one stderr line total, not one per
    /// dictation. Process-wide by necessity: `load` is static and a new
    /// value exists per call, so the memory of "already said that" cannot
    /// live on any instance.
    private final class FailureLog: @unchecked Sendable {
        private let lock = NSLock()
        private var lastSignature: [String: String] = [:]

        func warnOnce(signature: String, at path: String,
                      warn: (String) -> Void, message: () -> String) {
            lock.lock()
            let isNew = lastSignature[path] != signature
            if isNew { lastSignature[path] = signature }
            lock.unlock()
            // Outside the lock: `warn` is foreign code.
            if isNew { warn(message()) }
        }

        func clear(_ path: String) {
            lock.lock()
            lastSignature[path] = nil
            lock.unlock()
        }
    }

    private static let failureLog = FailureLog()

    /// One line on stderr, matching how the rest of the daemon reports.
    public static let warnToStderr: @Sendable (String) -> Void = { message in
        FileHandle.standardError.write(Data("snippets: \(message)\n".utf8))
    }

    // MARK: - Matching

    /// The characters an ASR appends to a sentence that a trigger's author
    /// never typed. Stripped from the *end* only — punctuation inside the
    /// phrase is part of what was said.
    private static let terminalPunctuation: Set<Character> =
        [".", "!", "?", ",", ";", ":", "…"]

    /// The identity a trigger and an utterance share: case-folded (full
    /// Unicode folding, so Polish `Ż` meets `ż`), surrounding whitespace
    /// trimmed, terminal punctuation stripped, internal whitespace collapsed
    /// to single spaces. Deliberately *not* diacritic-insensitive — "kraków"
    /// and "krakow" are different phrases, and a trigger fires on what was
    /// said, not on what it resembles.
    ///
    /// Pure, and applied to both sides of every comparison, so a trigger
    /// hand-written as "Insert my link." still fires.
    public static func normalize(_ utterance: String) -> String {
        let folded = utterance.folding(options: .caseInsensitive, locale: nil)
        var text = folded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // Stripping punctuation can expose whitespace ("link ." → "link "),
        // so both go in one sweep from the end.
        while let last = text.last,
              terminalPunctuation.contains(last) || last.isWhitespace
        {
            text.removeLast()
        }
        return text
    }

    /// The expansion to inject for `utterance`, or `nil` when the utterance
    /// is not a trigger and should be processed normally.
    ///
    /// Pure and never fails — the caller's never-lose-the-transcript contract
    /// rests on that. An entry with an empty expansion never matches: it
    /// would erase words the user actually said, so it is inert instead.
    public func expansion(for utterance: String) -> String? {
        let key = Self.normalize(utterance)
        guard !key.isEmpty else { return nil }
        for entry in entries where !entry.expansion.isEmpty {
            if Self.normalize(entry.trigger) == key {
                return entry.expansion
            }
        }
        return nil
    }
}
