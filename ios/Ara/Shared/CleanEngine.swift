import Foundation
import UIKit

/// The ✨ Clean action's logic, kept UI-free and proxy-free so the guards are
/// testable. The keyboard applies the result through `deleteBackward` ×
/// `deleteCount` + `insertText(insert)` — an IPC boundary with no ranged
/// replace, which is why everything here is engineered to touch as little
/// text as possible.
enum CleanEngine {
    /// The visible scope: the last sentence of the host's before-input
    /// context. Never more — `documentContextBeforeInput` truncates
    /// differently per host, and rewriting text the user cannot see is how
    /// keyboards destroy documents.
    static func sentenceScope(of context: String) -> String {
        guard !context.isEmpty else { return "" }
        // Find the last sentence terminator that has content after it.
        let terminators: Set<Character> = [".", "!", "?", "\n"]
        if let cut = context.lastIndex(where: { terminators.contains($0) }),
           context.index(after: cut) < context.endIndex {
            return String(context[context.index(after: cut)...])
        }
        // No terminator with a tail: the whole (truncated) context is one
        // sentence; cap it so a truncation artifact never becomes a 4000-char
        // rewrite.
        return String(context.suffix(500))
    }

    /// Rules floor + dictionary + conservative spell repair. Returns nil when
    /// the result would be unusable — and nil means *abort*, because by the
    /// data-loss guard no delete has happened yet.
    static func clean(_ sentence: String, mode: Mode,
                      dictionary: LocalDictionary) async -> String? {
        let trimmed = sentence.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let ruled = (try? await RuleBasedFormatter().format(sentence, mode: mode))
            ?? sentence
        let corrected = dictionary.apply(ruled)
        let spelled = spellRepair(corrected, protecting: dictionary)
        // The empty-output guard, verbatim from the design: empty for
        // non-empty input aborts before the first delete.
        guard !spelled.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return spelled
    }

    /// `UITextChecker`, applied conservatively: only whole misspelled words,
    /// only when the checker has a first guess, and never words the user's
    /// dictionary declares canonical — the user's own vocabulary outranks
    /// Apple's lexicon.
    static func spellRepair(_ text: String,
                            protecting dictionary: LocalDictionary) -> String {
        let checker = UITextChecker()
        let language = Locale.preferredLanguages.first ?? "en-US"
        let protected = Set(dictionary.entries.map { $0.canonical.lowercased() })
        var result = text
        var searchFrom = 0
        while true {
            let ns = result as NSString
            let range = checker.rangeOfMisspelledWord(
                in: result, range: NSRange(location: 0, length: ns.length),
                startingAt: searchFrom, wrap: false, language: language)
            guard range.location != NSNotFound else { break }
            let word = ns.substring(with: range)
            searchFrom = range.location + range.length
            guard !protected.contains(word.lowercased()),
                  let guess = checker.guesses(forWordRange: range, in: result,
                                              language: language)?.first,
                  // A guess that changes length or case wildly is a rewrite,
                  // not a repair; skip anything not clearly the same word.
                  abs(guess.count - word.count) <= 2 else { continue }
            result = ns.replacingCharacters(in: range, with: guess)
            searchFrom = range.location + (guess as NSString).length
        }
        return result
    }

    /// Minimal suffix edit turning `old` into `new`: keep the longest common
    /// prefix, delete the rest, type the new tail. The prefix is never
    /// deleted — that is the second data-loss guard.
    static func suffixEdit(from old: String, to new: String)
        -> (deleteCount: Int, insert: String)
    {
        let oldChars = Array(old)
        let newChars = Array(new)
        var common = 0
        while common < oldChars.count && common < newChars.count
            && oldChars[common] == newChars[common] {
            common += 1
        }
        return (deleteCount: oldChars.count - common,
                insert: String(newChars[common...]))
    }
}
