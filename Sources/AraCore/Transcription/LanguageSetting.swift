import Foundation

/// Which language or languages dictation should be transcribed in — the
/// `language` key in `config.json`, and what the Language submenu writes.
///
/// Two cases, because there are two honest answers and "detect it every time"
/// is only one of them:
///
/// - `automatic`: run Whisper's language detection and accept whatever comes
///   back. Right for someone who dictates in languages they cannot enumerate;
///   wrong for almost everyone else, because detection reads only the first
///   window and a two-word utterance is a coin toss.
/// - `monitored([code])` with **one** code: pin it. One decoder pass, no
///   detection, no misdetection possible. This is the fastest and the most
///   reliable setting, and it is what a monolingual user should have.
/// - `monitored([codes])` with **several**: the interesting case. Detection
///   runs, but its answer is confined to the set the user actually speaks —
///   and `LanguagePolicy` biases marginal calls toward the language of the
///   previous utterance, so a session does not flap between two languages on
///   the strength of a two-word "tak, jasne". The cost is one extra decoder
///   pass on any utterance whose language is not the previous one's —
///   measured at roughly double the transcription phase on the large model;
///   see `LanguagePlan.refines`.
///
/// The set-of-languages design is adapted from `aivars/parrot` (MIT,
/// © Andrew Jones); the config plumbing and the English-only handling are
/// this project's.
public enum LanguageSetting: Equatable, Sendable {
    case automatic
    /// One or more codes, already validated, lower-cased and de-duplicated by
    /// `LanguageCatalog.validate`. Never empty — an empty set would silently
    /// mean `automatic`, which is a different answer from the one the user
    /// gave.
    case monitored([String])

    /// The spelling `auto` has in `config.json` and in a menu row's
    /// `representedObject`.
    public static let automaticName = "auto"

    /// The config spelling: `"auto"`, `"pl"`, or `"en,pl"`. A single code
    /// stays a single code so a hand-written `"language": "pl"` survives a
    /// menu pick unchanged.
    public var rawValue: String {
        switch self {
        case .automatic: return Self.automaticName
        case .monitored(let codes): return codes.joined(separator: ",")
        }
    }

    /// Parses a config spelling or a menu row's `representedObject`. `nil`
    /// for anything else — the caller decides what an unparseable value
    /// costs, which for `Config.load` is one warning and nothing else.
    public init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased() == Self.automaticName {
            self = .automatic
            return
        }
        guard let codes = try? LanguageCatalog.parse(trimmed) else { return nil }
        self = .monitored(codes)
    }

    /// The monitored codes, or `nil` under `automatic` — which monitors
    /// nothing, by design: it accepts whatever WhisperKit detects.
    public var monitoredCodes: [String]? {
        switch self {
        case .automatic: return nil
        case .monitored(let codes): return codes
        }
    }

    public func monitors(_ code: String) -> Bool {
        monitoredCodes?.contains(code.lowercased()) ?? false
    }

    /// The valid spellings, for the config warning: a user who typo'd one
    /// deserves the shape of the answer, not just the rejection. The full
    /// ninety-nine codes are not listed — that is a paragraph, not a warning —
    /// so the message teaches the form and names the ones the menu offers.
    public static var validNames: String {
        "\"\(automaticName)\", one code (\"pl\"), or a list "
            + "(\"en,pl\" or [\"en\",\"pl\"]) — the menu offers "
            + LanguageCatalog.offered.map(\.code).joined(separator: ", ")
    }
}

/// Decoded from either a string (`"auto"`, `"pl"`, `"en,pl"`) or an array
/// (`["en","pl"]`), because both are things a person reasonably writes.
///
/// The failure message is the one `LanguageCatalog` produced, so a typo says
/// *which* code was wrong rather than only that something was.
extension LanguageSetting: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let codes = try? container.decode([String].self) {
            self = .monitored(try Self.validated(codes, in: container))
            return
        }
        let raw = try container.decode(String.self)
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == Self.automaticName
        {
            self = .automatic
            return
        }
        self = .monitored(try Self.validated(raw.split(separator: ",").map(String.init),
                                             in: container))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .automatic: try container.encode(Self.automaticName)
        case .monitored(let codes) where codes.count == 1: try container.encode(codes[0])
        case .monitored(let codes): try container.encode(codes)
        }
    }

    private static func validated(_ codes: [String],
                                  in container: SingleValueDecodingContainer) throws -> [String] {
        do {
            return try LanguageCatalog.validate(codes)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: (error as? LanguageSelectionError)?
                    .errorDescription ?? "invalid language")
        }
    }
}
