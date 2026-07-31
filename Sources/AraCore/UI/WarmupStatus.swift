import Foundation

/// What the daemon is doing before it can dictate, and the one sentence that
/// says so.
///
/// The daemon warms two models concurrently and the overlay pill has room for
/// one line, so which of them gets to speak is a decision rather than a
/// rendering detail — and it lives here, next to the other `*MenuModel` types,
/// for the same reason they do: `RecordingOverlay` and `MenuBarController`
/// transcribe a value into pixels, and every rule a test could get wrong is
/// somewhere a test can reach.
///
/// The phrasing is deliberately about *what is happening*, not about what the
/// user should do: a first run on the large model spends over a minute
/// downloading 1.5 GB, and "warming up" for that whole time tells them nothing
/// about whether it is stuck.
public struct WarmupStatus: Equatable, Sendable {
    /// The local formatting model's phase. It is not always loaded — only the
    /// `mlx` and `cloud` engines consult it — so "not being loaded at all" is
    /// a state, distinct from "loaded already".
    public enum Formatter: Equatable, Sendable {
        case notLoading
        case loading
        case ready
    }

    /// The model id the transcriber is warming, quoted in the line so a user
    /// watching a long download can see *which* model is costing them the
    /// minute — the answer is the thing they would change.
    public let modelID: String

    /// The transcriber's phase, or `nil` once it is warm. Its absence is the
    /// interesting state: it is the load that gates dictation.
    public var transcriber: TranscriberWarmup?

    public var formatter: Formatter

    public init(modelID: String, transcriber: TranscriberWarmup?,
                formatter: Formatter) {
        self.modelID = modelID
        self.transcriber = transcriber
        self.formatter = formatter
    }

    /// Whether dictation must still be held back.
    ///
    /// **The transcriber alone decides this.** The formatting model is polish:
    /// `MLXFormatter.format` throws `.unavailable` until it is loaded and
    /// `FormatterChain` falls through to the rules floor, which is the same
    /// degradation a user without the model gets permanently. Holding the
    /// hotkey shut through a second model's load buys nothing and costs the
    /// user the seconds they are standing there waiting to speak.
    public var blocksDictation: Bool { transcriber != nil }

    /// The pill's line, or `nil` when there is nothing left to wait for.
    ///
    /// The transcriber outranks the formatter because it is the one that gates
    /// dictation; the formatting model loads inside its shadow (measured ~1.0 s
    /// against ~4.0 s warm) and has nothing to add while it is in flight.
    public var message: String? {
        switch transcriber {
        case .downloading(let percent?):
            return "downloading \(modelID)… \(percent)%"
        case .downloading(nil):
            return "downloading \(modelID)…"
        case .loading:
            return "loading \(modelID)…"
        case .preparingNeuralEngine:
            // Naming the wait and its shape is the whole point: three minutes
            // of "loading…" is indistinguishable from a hang, and the user's
            // response to a hang is to quit — which throws the compile away
            // and buys them the same three minutes again next launch.
            return "preparing \(modelID) for the Neural Engine — one time, a few minutes…"
        case nil:
            switch formatter {
            case .loading: return "preparing the formatting model…"
            case .notLoading, .ready: return nil
            }
        }
    }

    /// Whether a hotkey press must be answered with status rather than with a
    /// recording. Defined as "there is something to say", so the daemon's
    /// press check and the pill's text cannot disagree — a press that lands in
    /// the gap between two different answers is a recording into a cold
    /// transcriber.
    public var isWarming: Bool { message != nil }

    /// The warm-up's last frame, for the user who was holding the key when it
    /// finished. Hiding the pill under their thumb would read as a crash, and
    /// leaving "loading…" up would be a lie, so it says the wait is over and
    /// what now works.
    public static func readyMessage(hotkeyLabel: String) -> String {
        "ready — hold \(hotkeyLabel) to dictate"
    }
}
