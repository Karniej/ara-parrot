import Foundation
import WhisperKit

/// One language a user can name: the Whisper code that goes into
/// `DecodingOptions.language`, and the English name the menu shows.
public struct SpeechLanguage: Hashable, Sendable {
    public let code: String
    public let displayName: String
}

/// Which languages exist, which ones the menu offers, and how a user's
/// spelling becomes codes WhisperKit will accept.
///
/// The design of this feature — a *monitored set* of languages rather than
/// one language or blind detection — is adapted from `aivars/parrot`
/// (MIT, © Andrew Jones), reimplemented here against AraCore's types. See
/// `LanguagePolicy` for the selection rules that make the set worth having.
public enum LanguageCatalog {
    /// Every code WhisperKit's multilingual tokenizer accepts, taken from
    /// WhisperKit itself rather than copied. A WhisperKit upgrade that adds a
    /// language therefore needs no edit here, and one that drops a language
    /// breaks a test rather than a user's dictation.
    public static let supportedCodes: Set<String> = Constants.languageCodes

    /// The curated submenu list.
    ///
    /// Fourteen rather than all ninety-nine, because a submenu with a hundred
    /// rows is a catalogue, not a menu — and because the monitored set is a
    /// multiple choice, so every extra row is a row the user has to *not*
    /// tick. Hand-edited `config.json` still reaches every code WhisperKit
    /// knows; this list is only what the menu shows.
    ///
    /// Chosen as the languages most likely to be dictated on a Mac in the
    /// West plus the three largest East Asian ones, and ordered alphabetically
    /// by English name so no ranking has to be defended. English is here
    /// because it is what every other default in this daemon assumes; Polish
    /// because it is the language whose silent misdetection is the bug this
    /// feature fixes.
    ///
    /// The names are spelled out rather than looked up with
    /// `Locale.localizedString(forLanguageCode:)`: that call answers in the
    /// user's locale, which would put a Polish name in a menu whose every
    /// other word is English, and would make this list untestable.
    public static let offered: [SpeechLanguage] = [
        SpeechLanguage(code: "zh", displayName: "Chinese"),
        SpeechLanguage(code: "cs", displayName: "Czech"),
        SpeechLanguage(code: "nl", displayName: "Dutch"),
        SpeechLanguage(code: "en", displayName: "English"),
        SpeechLanguage(code: "fr", displayName: "French"),
        SpeechLanguage(code: "de", displayName: "German"),
        SpeechLanguage(code: "it", displayName: "Italian"),
        SpeechLanguage(code: "ja", displayName: "Japanese"),
        SpeechLanguage(code: "ko", displayName: "Korean"),
        SpeechLanguage(code: "pl", displayName: "Polish"),
        SpeechLanguage(code: "pt", displayName: "Portuguese"),
        SpeechLanguage(code: "ru", displayName: "Russian"),
        SpeechLanguage(code: "es", displayName: "Spanish"),
        SpeechLanguage(code: "uk", displayName: "Ukrainian"),
    ]

    /// The English name for a code, or the code itself when it is one of the
    /// eighty-five the menu does not offer — a hand-edited `"language": "haw"`
    /// still has to render somewhere, and `haw` is more honest than a guess.
    public static func displayName(for code: String) -> String {
        offered.first { $0.code == code.lowercased() }?.displayName ?? code
    }

    /// Splits a comma-separated spelling (`"en, pl"`) and validates it. The
    /// comma form exists because `config.json` may hold either a string or an
    /// array, and one parser for both keeps the two spellings honest.
    public static func parse(_ value: String) throws -> [String] {
        try validate(value.split(separator: ",").map(String.init))
    }

    /// Lower-cases, trims, drops duplicates keeping first-seen order, and
    /// rejects anything WhisperKit does not know.
    ///
    /// Throwing rather than dropping the bad entries: silently monitoring
    /// `["en"]` when the user asked for `["en", "pll"]` would look like the
    /// feature working, which is exactly the failure mode this whole branch
    /// exists to end. `Config.load` catches the throw and warns — the file
    /// itself is never discarded over it.
    public static func validate(_ codes: [String]) throws -> [String] {
        var seen = Set<String>()
        let normalized = codes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }

        guard !normalized.isEmpty else { throw LanguageSelectionError.emptySelection }

        let unsupported = normalized.filter { !supportedCodes.contains($0) }
        guard unsupported.isEmpty else {
            throw LanguageSelectionError.unsupportedCodes(unsupported)
        }
        return normalized
    }
}

/// Why a language selection was refused. `LocalizedError` so the sentence is
/// what `Config.load` prints — unlike a foreign error, this one's message is a
/// channel we control.
public enum LanguageSelectionError: LocalizedError, Equatable {
    case emptySelection
    case unsupportedCodes([String])

    public var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "no language named"
        case .unsupportedCodes(let codes):
            return "unsupported language code\(codes.count == 1 ? "" : "s"): "
                + codes.joined(separator: ", ")
        }
    }
}
