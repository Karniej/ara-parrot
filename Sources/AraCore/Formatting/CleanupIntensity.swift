import Foundation

/// How aggressively dictated speech is edited, configured once for the whole
/// daemon (`cleanup` in `config.json`) and orthogonal to the mode: the mode
/// says what the text should sound like (email, chat, a code note), the
/// intensity says how far from the spoken words the editor may go to get
/// there. The two compose — `TranscriptPrompt` interpolates the mode's rule
/// into whichever instruction variant the intensity selects.
///
/// - `none`: no language model at all. The rules floor still runs, so filler
///   words are stripped, but nothing rewrites. Wired through the same
///   `usesLLM` seam verbatim mode uses — see `Mode.applying(cleanup:)` — so
///   `FormatterChain` needs no new routing.
/// - `light`: punctuation, capitalisation, and dictated punctuation commands
///   only; every spoken word survives.
/// - `medium`: the default — fillers removed, boundaries repaired,
///   self-corrections collapsed, dictated punctuation obeyed. (The prompt
///   also asks for enumerations as lists, but the shipped model measurably
///   only complies at `high` — see docs/KNOWN-ISSUES.md.)
/// - `high`: everything medium does, plus restructuring fragments into
///   complete sentences and formatting spoken enumerations as numbered lists.
///
/// A `String` raw value so the config spelling is the case name, and
/// `CaseIterable` so tests and the config warning can state the valid
/// spellings from the type instead of repeating them.
public enum CleanupIntensity: String, Codable, Sendable, CaseIterable {
    case none, light, medium, high

    /// The valid spellings, rendered for the config warning: a user who
    /// typo'd one deserves the list, not just the rejection.
    static var validNames: String {
        allCases.map(\.rawValue).joined(separator: ", ")
    }
}
