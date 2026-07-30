import Foundation

/// The user's custom vocabulary: canonical terms the ASR model consistently
/// mishears, each with the misheard variants that should be rewritten to it.
///
/// This is the deterministic floor of the custom-vocabulary feature. It runs
/// on every transcript before any formatting engine — see
/// `DictationSession.process` — so it must be incapable of losing words:
/// `load` never throws (a missing or malformed file is an empty dictionary),
/// `apply` never throws (a regex that cannot be built leaves the text
/// unchanged), and no failure anywhere yields anything but the input.
///
/// The file lives next to `config.json` and follows the same tolerant-load
/// philosophy, with one addition: `load` runs per utterance (that *is* the
/// hot-reload mechanism), so a broken file would otherwise repeat its warning
/// hundreds of times a day. Warnings are deduplicated per failure — see
/// `FailureLog`.
public struct LocalDictionary: Sendable, Equatable {
    /// One correction: the spelling the user wants, and the misheard forms
    /// that should become it.
    public struct Entry: Sendable, Equatable, Codable {
        public var canonical: String
        public var variants: [String]

        public init(canonical: String, variants: [String]) {
            self.canonical = canonical
            self.variants = variants
        }
    }

    /// In file order, which the menu's merge and `encoded()` both preserve so
    /// a hand-edited file stays recognisable across a round-trip.
    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    /// `dictionary.json` in the directory the user already edits
    /// configuration in — derived from `Config.defaultURL` rather than
    /// spelled out again, so the two files cannot drift apart.
    public static var defaultURL: URL {
        Config.defaultURL.deletingLastPathComponent()
            .appendingPathComponent("dictionary.json")
    }

    // MARK: - Loading

    /// Loads the dictionary, reading the file fresh — callers call this per
    /// utterance and edits apply to the very next dictation.
    ///
    /// Never throws and never blocks dictation: a missing file is the normal
    /// case for an install that has added no corrections and says nothing; an
    /// unreadable or malformed file warns once per distinct failure and
    /// behaves as empty. `warn` is injectable so tests can assert on what a
    /// user would be told — and on what they would *not* be told twice.
    public static func load(from url: URL,
                            warn: @Sendable (String) -> Void = warnToStderr)
        -> LocalDictionary
    {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if FileManager.default.fileExists(atPath: url.path) {
                failureLog.warnOnce(signature: "unreadable \(type(of: error))",
                                    at: url.path, warn: warn) {
                    "cannot read \(url.path) (\(type(of: error))); "
                    + "dictating without corrections"
                }
            } else {
                // Deleting the file is a fix like any other: the next
                // breakage is news again.
                failureLog.clear(url.path)
            }
            return LocalDictionary()
        }

        do {
            let entries = try JSONDecoder().decode([Entry].self, from: data)
            failureLog.clear(url.path)
            return LocalDictionary(entries: entries)
        } catch {
            // Signed by content hash: reloading the same broken bytes says
            // nothing new, but an edit that produces *different* broken bytes
            // is a fresh mistake the user has not been told about. A hash
            // rather than the bytes so the ledger stays a few ints, and
            // in-process only — `Hasher`'s seed is stable within a process,
            // which is exactly the lifetime this dedupe needs.
            failureLog.warnOnce(signature: "malformed \(data.hashValue)",
                                at: url.path, warn: warn) {
                "ignoring \(url.path): \(Config.describe(error)); "
                + "dictating without corrections"
            }
            return LocalDictionary()
        }
    }

    /// Which failure each path last warned about, so a per-utterance `load`
    /// of the same broken file costs one stderr line total, not one per
    /// dictation. Process-wide by necessity: `load` is static and a new
    /// dictionary value exists per call, so the memory of "already said that"
    /// cannot live on any instance.
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
        FileHandle.standardError.write(Data("dictionary: \(message)\n".utf8))
    }

    // MARK: - Applying

    /// Rewrites every misheard variant in `text` to its canonical form and
    /// returns the result. Pure, and never fails: any problem — including a
    /// regex that will not build — returns the input unchanged.
    ///
    /// Semantics, each pinned by a test:
    /// - **Whole words only**, with Unicode-aware boundaries: a neighbour
    ///   that is any letter (`ł`, `ż`, and every other diacritic the user
    ///   dictates in Polish), digit, or underscore blocks the match, so a
    ///   variant never fires inside a longer word. ASCII `\b` would treat
    ///   `ł` as a boundary; the lookarounds below do not.
    /// - **Case-insensitive** match, canonical inserted verbatim — the
    ///   dictionary is the authority on spelling, including capitalisation.
    /// - **Longest variant first** across all entries, so "new york times"
    ///   beats an earlier entry's "new york".
    /// - **Single pass**: all matches are found against the original text
    ///   and spliced in one sweep, so one entry's output is never re-matched
    ///   by another entry — and a `$` in a canonical stays a dollar sign,
    ///   because no template engine ever sees it.
    public func apply(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        // Lowercased variant → canonical, first entry winning a duplicate so
        // a misconfigured file behaves deterministically.
        var canonicalByVariant: [String: String] = [:]
        var variants: [String] = []
        for entry in entries {
            for variant in entry.variants where !variant.isEmpty {
                let key = variant.lowercased()
                if canonicalByVariant[key] == nil {
                    canonicalByVariant[key] = entry.canonical
                    variants.append(variant)
                }
            }
        }
        guard !variants.isEmpty else { return text }

        // ICU alternation is first-match, not longest-match: the ordering
        // here is what makes the longer variant win.
        variants.sort { $0.count > $1.count }

        let alternation = variants
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        let pattern = "(?<![\\p{L}\\p{N}_])(?:\(alternation))(?![\\p{L}\\p{N}_])"
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive])
        else {
            // Every variant is escaped, so this should be unreachable — but
            // "should be" is not a thing to bet a transcript on.
            return text
        }

        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: full)
        guard !matches.isEmpty else { return text }

        var result = ""
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[cursor..<range.lowerBound]
            let heard = String(text[range])
            // A lookup miss is possible in exotic case-folding corners (the
            // Turkish dotted İ); keeping the heard text is the safe answer.
            result += canonicalByVariant[heard.lowercased()] ?? heard
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }

    // MARK: - Merging

    /// Returns a dictionary with `heard` mapped to `canonical` — the pure
    /// half of the menu's "Add dictionary correction…" form.
    ///
    /// Canonical matching is case- and diacritic-insensitive, so "krakow"
    /// typed into the form merges into an existing "Kraków" entry (whose
    /// spelling is kept — it was right first) instead of forking a
    /// near-duplicate. A variant already mapped to another canonical moves;
    /// an entry left with no variants is dropped, since it can never match
    /// anything. Adding a variant its canonical already has is a no-op.
    public func adding(heard: String, canonical: String) -> LocalDictionary {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !canonical.isEmpty else { return self }

        let heardKey = Self.mergeKey(heard)
        let canonicalKey = Self.mergeKey(canonical)

        var merged: [Entry] = []
        var appended = false
        for var entry in entries {
            if !appended, Self.mergeKey(entry.canonical) == canonicalKey {
                if !entry.variants.contains(where: { Self.mergeKey($0) == heardKey }) {
                    entry.variants.append(heard)
                }
                appended = true
            } else {
                entry.variants.removeAll { Self.mergeKey($0) == heardKey }
            }
            if !entry.variants.isEmpty { merged.append(entry) }
        }
        if !appended {
            merged.append(Entry(canonical: canonical, variants: [heard]))
        }
        return LocalDictionary(entries: merged)
    }

    /// The identity two spellings share for merge purposes. Dedupe only —
    /// `apply`'s matching is deliberately *not* diacritic-insensitive.
    private static func mergeKey(_ term: String) -> String {
        term.folding(options: [.caseInsensitive, .diacriticInsensitive],
                     locale: nil)
    }

    // MARK: - Encoding

    /// The entries as stable, pretty-printed JSON: byte-identical for equal
    /// dictionaries, entry order preserved, keys sorted — so the file diffs
    /// cleanly and stays hand-editable after the menu writes it.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys,
                                    .withoutEscapingSlashes]
        return try encoder.encode(entries)
    }

    /// Writes `encoded()` to `url`, creating the directory if needed — the
    /// menu form's save. Throws rather than warns: persistence is best-effort
    /// *at the call site* (the daemon's failure line lives next to the
    /// microphone one in `Run`), and only the caller knows that a failed save
    /// still applies in memory this session.
    ///
    /// Atomic, like `Config.persistMicrophone`: a crash mid-write must not
    /// leave a truncated file for the next utterance's `load` to warn about.
    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try encoded().write(to: url, options: .atomic)
    }
}

/// Corrections added through the menu that could not be written to disk.
///
/// The dictionary has no in-memory store to fall back on — `load` runs fresh
/// per utterance, which is the hot-reload mechanism — so a failed save would
/// otherwise mean the user's correction silently never applies. This is the
/// missing half of the microphone-persist pattern: remembered here, replayed
/// on top of every load, and forgotten the moment a write lands them on disk.
///
/// Replaying goes through `adding`, so it is idempotent: a correction the
/// file has since gained (a later successful write, or the user's hand edit)
/// overlays as a no-op.
///
/// `@unchecked Sendable` for the same reason as `LocalDictionary.FailureLog`:
/// remembered on the main thread by the menu, read by the session's loader on
/// whatever thread the utterance runs on, guarded by the lock.
public final class UnsavedCorrections: @unchecked Sendable {
    private let lock = NSLock()
    private var corrections: [(heard: String, canonical: String)] = []

    public init() {}

    /// Records a correction whose write failed, to replay until quit.
    public func remember(heard: String, canonical: String) {
        lock.lock()
        corrections.append((heard, canonical))
        lock.unlock()
    }

    /// Forgets the backlog — called after a successful write, which by
    /// construction persisted everything remembered here. Without this, a
    /// once-unsaved correction the user later hand-deletes from the file
    /// would be resurrected on every load.
    public func clear() {
        lock.lock()
        corrections = []
        lock.unlock()
    }

    /// The dictionary with every remembered correction merged in, in the
    /// order they were added.
    public func applied(to dictionary: LocalDictionary) -> LocalDictionary {
        lock.lock()
        let pending = corrections
        lock.unlock()
        return pending.reduce(dictionary) { partial, correction in
            partial.adding(heard: correction.heard,
                           canonical: correction.canonical)
        }
    }

    /// The whole of the menu form's save, AppKit excluded: merge the
    /// correction into a fresh load of `url` — so a hand edit made since the
    /// last utterance is never clobbered — overlaid with this backlog, and
    /// persist the result.
    ///
    /// Returns `nil` when the file now holds the merged state (including the
    /// no-churn case where it already did, which writes nothing). Returns the
    /// write error when persistence failed: the correction is then remembered
    /// here and applies until quit, and the caller owns the one stderr line —
    /// only it knows what "not saved" should sound like next to its other
    /// warnings.
    @discardableResult
    public func save(heard: String, canonical: String, to url: URL)
        -> (any Error)?
    {
        let onDisk = LocalDictionary.load(from: url)
        let merged = applied(to: onDisk)
            .adding(heard: heard, canonical: canonical)
        guard merged != onDisk else {
            // Nothing to write: the file alone already equals the desired
            // full state — which proves the backlog is at best redundant and
            // at worst contradicts the correction the user just re-made
            // (a stale failed `arra → Parrot` would otherwise outvote a
            // newer `arra → Ara` on every load until quit). Either way it
            // must go.
            clear()
            return nil
        }
        do {
            try merged.write(to: url)
            // The write carried the backlog with it; forgetting it is what
            // lets a later hand edit of the file win again.
            clear()
            return nil
        } catch {
            remember(heard: heard, canonical: canonical)
            return error
        }
    }
}
