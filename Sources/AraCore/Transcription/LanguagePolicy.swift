import Foundation

/// The rules that turn Whisper's language guess into the language a
/// *monitored* dictation is transcribed in.
///
/// Every function here is pure and every one of them is a decision the
/// transcriber would otherwise have made inline, where no test could reach it.
/// The bias is a parameter rather than a constant read at the use site for the
/// same reason: a stickiness rule you cannot dial to zero in a test is a rule
/// you cannot show is doing anything.
///
/// Adapted from `aivars/parrot`'s `LanguagePolicy` (MIT, © Andrew Jones) —
/// same three functions and the same bias, reimplemented against AraCore's
/// types with its test cases ported as specifications.
///
/// ## Why a bias at all
///
/// Whisper detects language from the first 30-second window only, and for a
/// two-word utterance ("tak, jasne") that window is mostly silence. Detection
/// is then close to a coin toss, and a session where every third utterance
/// lands in the wrong language is worse than one pinned to the wrong language
/// outright — at least the second is predictable. The prior is small (0.12 in
/// average log-probability) precisely so it decides only the calls that were
/// already too close to call: a genuine switch of language moves the score by
/// far more than that and wins immediately.
public enum LanguagePolicy {
    /// A modest log-probability prior for the language the previous utterance
    /// used. A clearly more confident detection still wins.
    public static let lastLanguageBias: Float = 0.12

    /// The language worth transcribing *again* under, or `nil` when the first
    /// pass needs no second opinion.
    ///
    /// A second opinion is only worth its decoder pass when the detection
    /// switched away from the language the user was just speaking, and both
    /// languages are ones they said they speak. Everything else — a stable
    /// language, the first utterance of a session, a detection outside the
    /// monitored set — is decided without it.
    public static func comparisonLanguage(detected: String?,
                                          lastUsed: String?,
                                          monitored: [String]) -> String? {
        guard let detected, monitored.contains(detected),
              let lastUsed, monitored.contains(lastUsed),
              detected != lastUsed
        else { return nil }
        return lastUsed
    }

    /// The best monitored language, used when the free detection landed
    /// *outside* the monitored set.
    ///
    /// `probabilities` is a per-language log-probability table. Today's
    /// WhisperKit has no API that produces one — `detectLangauge` returns only
    /// the sampled language (see `WhisperKitTranscriber.refine` for why that
    /// call is not made) — so `AraCore` passes an empty table and this always
    /// takes the degradation path below. The ranking is kept because it is the
    /// correct answer to the question and costs nothing to keep, and because
    /// the day a real table exists this becomes right without a rewrite.
    ///
    /// Never `nil` for a non-empty set: the caller has audio in hand and must
    /// end up transcribing it as something. When no probability is known for
    /// any monitored language the answer degrades through the detection, then
    /// the last used language, then the first monitored one — in that order,
    /// each more of a guess than the last, none of them a thrown error.
    public static func selectMonitoredLanguage(probabilities: [String: Float],
                                               detected: String?,
                                               lastUsed: String?,
                                               monitored: [String],
                                               bias: Float = lastLanguageBias) -> String? {
        guard let first = monitored.first else { return nil }

        var selection = first
        var selectionScore = score(for: first, probabilities: probabilities,
                                   lastUsed: lastUsed, bias: bias)
        for language in monitored.dropFirst() {
            let candidate = score(for: language, probabilities: probabilities,
                                  lastUsed: lastUsed, bias: bias)
            if candidate > selectionScore {
                selection = language
                selectionScore = candidate
            }
        }
        if selectionScore.isFinite { return selection }

        if let detected, monitored.contains(detected) { return detected }
        if let lastUsed, monitored.contains(lastUsed) { return lastUsed }
        return first
    }

    /// Picks between the detected language and the comparison pass's, by
    /// confidence — with the previous language's thumb on the scale.
    ///
    /// A detection outside the monitored set never wins, at any confidence:
    /// the user said which languages they speak, and a confident guess at a
    /// language they do not is still a wrong answer.
    public static func chooseLanguage(detected: String?,
                                      detectedScore: Float,
                                      alternative: String,
                                      alternativeScore: Float,
                                      lastUsed: String?,
                                      monitored: [String],
                                      bias: Float = lastLanguageBias) -> String {
        guard let detected, monitored.contains(detected) else { return alternative }
        guard alternative == lastUsed, detected != lastUsed else { return detected }
        return alternativeScore + bias >= detectedScore ? alternative : detected
    }

    private static func score(for language: String,
                              probabilities: [String: Float],
                              lastUsed: String?,
                              bias: Float) -> Float {
        guard let probability = probabilities[language] else { return -.infinity }
        return probability + (language == lastUsed ? bias : 0)
    }
}
