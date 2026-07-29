import Foundation

/// Owns the transcript → text-to-inject step of the pipeline: pick a mode, run
/// the formatter, and hand back the string the injection layer should type.
///
/// ## `process` returns `String` and never throws
///
/// The user spoke; they get text back, whatever happened downstream. Formatting
/// is an enhancement, never a dependency — and a non-throwing, non-optional
/// return type is that promise stated in the type system rather than in a
/// comment a later edit can ignore. Every engine failure (a missing model, a
/// timeout, a refusal, a rewrite the plausibility guard rejected, an injected
/// formatter that is simply broken) degrades to the raw transcript.
///
/// ## …but a withdrawn request is not a failure, and must not be injected
///
/// `FormatterChain.format` throws `CancellationError` when the calling task has
/// been cancelled, and it does so deliberately: that is what stops an abandoned
/// request from coming back as a perfectly good string which the injection
/// layer then types into whatever the user has focused. Catching it here and
/// returning `raw` would undo exactly that; `try?` would undo it silently, and
/// this project has already paid twice to close that trap.
///
/// The two requirements meet at the empty string. `process` still returns a
/// `String` and still never throws, but a cancelled request yields `""` — the
/// one value that is safe to hand an injector, because typing nothing is what a
/// withdrawn request deserves. Callers need no new concept: `""` already means
/// "nothing to type" for an empty transcript, so a single `guard !out.isEmpty`
/// at the injection site covers both reasons at once. The inverse mistake is
/// closed too: a formatter that returns `""` for a *non-empty* transcript has
/// broken the `Formatter` contract, and that case returns `raw` rather than
/// letting a bug masquerade as a cancellation and swallow the user's words.
///
/// ## Cancellation is decided by task state, never by the error's type
///
/// Two independent reasons, both already load-bearing elsewhere in this module:
///
/// - A `CancellationError` thrown by a formatter is not proof that *our* caller
///   withdrew anything — it can leak from an internal task group whose child was
///   cancelled while the caller is very much alive and still waiting for text.
///   Treating that as withdrawal would silently drop a transcript. Here it falls
///   into the ordinary failure path and the transcript survives.
/// - The converse hole is worse and cannot be seen from the catch block at all.
///   `RuleBasedFormatter` is pure string work with no suspension point: it
///   cannot observe cancellation, cannot throw, and always succeeds. A
///   verbatim-mode call cancelled while it ran would return normally, with no
///   error anywhere. Only the check *after* a successful return catches that,
///   which is why there is one.
///
/// `FormatterChain` makes the same checks internally, so with the production
/// chain installed these are belt and braces. `formatter` is an `any Formatter`
/// and nothing in the type system says otherwise, so the belt is worth wearing.
public actor DictationSession {
    private let formatter: any Formatter
    private let resolver: ModeResolver
    private let frontmostBundleID: @Sendable () -> String?
    private let onModeResolved: (@Sendable (Mode) -> Void)?

    /// - Parameters:
    ///   - formatter: The formatting pipeline. Production passes
    ///     `FormatterChain`; the guarantees above hold for any implementation.
    ///   - resolver: Decides which mode an utterance is formatted in.
    ///   - frontmostBundleID: Reads the bundle identifier of the app the user is
    ///     dictating into.
    ///
    ///     **It must not block and must not assert an actor context.** It is
    ///     called from this actor's executor, so a `MainActor.assumeIsolated`
    ///     around an AppKit read traps the process rather than hopping to the
    ///     main thread, and a `DispatchQueue.main.sync` would park a
    ///     cooperative-pool thread on the main run loop. `FrontmostApp.reader`
    ///     is the supported implementation: a lock-protected read of a value
    ///     captured on the main actor when the hotkey was released.
    ///   - onModeResolved: Notified with the resolved mode before formatting
    ///     starts, so a UI can show which mode an utterance was treated as.
    ///     Called from this actor's executor: it must not block either.
    public init(formatter: any Formatter,
                resolver: ModeResolver,
                frontmostBundleID: @escaping @Sendable () -> String?,
                onModeResolved: (@Sendable (Mode) -> Void)? = nil) {
        self.formatter = formatter
        self.resolver = resolver
        self.frontmostBundleID = frontmostBundleID
        self.onModeResolved = onModeResolved
    }

    /// Formats `raw` and returns the text to inject.
    ///
    /// Returns the raw transcript on any formatting failure, and `""` when
    /// there is nothing to type — an empty transcript, or a request the caller
    /// cancelled. Never throws.
    public func process(_ raw: String, override: String?,
                        manual: String?) async -> String {
        guard !raw.isEmpty else { return raw }
        // Nothing to inject for a request that was already withdrawn, and no
        // reason to spend an inference on it either.
        if Task.isCancelled { return "" }

        let mode = resolver.resolve(override: override, manual: manual,
                                    frontmostBundleID: frontmostBundleID())
        onModeResolved?(mode)

        do {
            let formatted = try await formatter.format(raw, mode: mode)
            // After the work, not only before it: see the class note. A
            // formatter with no suspension point returns a string for a
            // cancelled request without ever raising anything.
            if Task.isCancelled { return "" }
            guard !formatted.isEmpty else {
                // `Formatter` forbids this. A broken implementation must not be
                // able to erase an utterance by looking like a cancellation.
                Self.note("formatter returned nothing for a non-empty "
                          + "transcript; injecting the raw transcript")
                return raw
            }
            return formatted
        } catch {
            if Task.isCancelled { return "" }
            // The type name only, and no interpolation of the error's payload.
            // `FormatterChain` has already logged the specific per-engine
            // reason by the time anything reaches here, and error text on this
            // path can be derived from a transcript or from an API error body —
            // the reason `CloudFormatter` reduces foreign errors to a type name
            // before the chain prints them. Reached at all only when the
            // injected formatter is not the chain, since the chain absorbs
            // everything except cancellation.
            Self.note("formatting failed (\(type(of: error))); "
                      + "injecting the raw transcript")
            return raw
        }
    }

    /// One line on stderr, matching how the rest of the daemon reports.
    private static func note(_ message: String) {
        FileHandle.standardError.write(Data("dictation: \(message)\n".utf8))
    }
}
