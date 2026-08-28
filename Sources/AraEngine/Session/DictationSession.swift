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
    private let dictionary: @Sendable () -> LocalDictionary
    private let snippets: @Sendable () -> Snippets
    /// The editing intensity, stamped onto every resolved mode.
    ///
    /// A `var` because the Cleanup submenu changes it while the daemon runs.
    /// It was a `let` when the only way to change it was to edit the config
    /// and relaunch — which is what a user reported as the menu "not working":
    /// the pick was saved, the checkmark moved, and the next utterance was
    /// formatted by the intensity the daemon had started with.
    private var cleanup: CleanupIntensity
    private let onModeResolved: (@Sendable (Mode) -> Void)?

    /// - Parameters:
    ///   - formatter: The formatting pipeline. Production passes
    ///     `FormatterChain`; the guarantees above hold for any implementation.
    ///   - resolver: Decides which mode an utterance is formatted in.
    ///   - dictionary: The custom-vocabulary source, consulted **per
    ///     utterance** — hot reload is nothing more than this closure reading
    ///     the file fresh each call, so caching its result here would quietly
    ///     turn "edits apply to the next dictation" into "edits apply after a
    ///     restart". Production passes `LocalDictionary.load`; not defaulted,
    ///     for `Pipeline.makeChain`'s reason: a call site that forgot the
    ///     argument would disable the user's corrections with no symptom.
    ///     Runs on this actor's executor: small local file I/O is fine,
    ///     anything slower is not.
    ///   - snippets: The voice-snippets source, consulted **per utterance**
    ///     for the same hot-reload reason as `dictionary`. Production passes
    ///     `Snippets.load`; not defaulted, for the same reason again: a call
    ///     site that forgot the argument would disable the user's snippets
    ///     with no symptom.
    ///   - cleanup: The editing intensity from `config.json`, stamped onto
    ///     every resolved mode before formatting — see `Mode.applying(cleanup:)`
    ///     for how `.none` becomes the verbatim seam. Defaulted, unlike the
    ///     other collaborators, because `.medium` *is* the absent-key
    ///     behaviour: a call site that forgets it gets exactly what an
    ///     unconfigured user gets, which is not a defect to surface.
    ///   - onModeResolved: Notified with the resolved mode before formatting
    ///     starts, so a UI can show which mode an utterance was treated as.
    ///     Called from this actor's executor: it must not block. Not called
    ///     for a snippet hit — no mode is resolved for an utterance that is
    ///     never formatted.
    public init(formatter: any Formatter,
                resolver: ModeResolver,
                dictionary: @escaping @Sendable () -> LocalDictionary,
                snippets: @escaping @Sendable () -> Snippets,
                cleanup: CleanupIntensity = .medium,
                onModeResolved: (@Sendable (Mode) -> Void)? = nil) {
        self.formatter = formatter
        self.resolver = resolver
        self.dictionary = dictionary
        self.snippets = snippets
        self.cleanup = cleanup
        self.onModeResolved = onModeResolved
    }

    /// The Cleanup submenu changed. Applies to the next utterance; one already
    /// being formatted keeps the intensity it started with, which is what
    /// actor isolation gives for free.
    ///
    /// Changing this is not sufficient on its own. At `.none` no language
    /// model is loaded — see the daemon's `warmsMLX` — so raising the
    /// intensity also has to warm one, or the chain silently falls through to
    /// the rules floor and the user gets no rewriting and no error.
    public func setCleanup(_ intensity: CleanupIntensity) {
        cleanup = intensity
    }

    /// Corrects `raw` against the user's dictionary, formats it, and returns
    /// the text to inject.
    ///
    /// Returns the corrected transcript on any formatting failure, and `""`
    /// when there is nothing to type — an empty transcript, or a request the
    /// caller cancelled. Never throws.
    ///
    /// - Parameter frontmostBundleID: The application this utterance was spoken
    ///   into, **sampled by the caller when the user stopped speaking**.
    ///
    ///   A value per call rather than something the session reads for itself,
    ///   and that is the point. This method runs seconds after the hotkey was
    ///   released, once transcription has finished, so anything read here is the
    ///   state of the world *now* — which for a user who has already started
    ///   their next utterance is the wrong application. Two calls in flight at
    ///   once must resolve two different modes, and only a value carried
    ///   alongside its own transcript can do that. `FrontmostApp.bundleID` is
    ///   what production samples; see it for why the read cannot happen from
    ///   this actor at all.
    public func process(_ raw: String, override: String?, manual: String?,
                        frontmostBundleID: String?) async -> String {
        guard !raw.isEmpty else { return raw }
        // Nothing to inject for a request that was already withdrawn, and no
        // reason to spend an inference on it either.
        if Task.isCancelled { return "" }

        // Vocabulary corrections come first, before any mode or engine
        // decision, so every formatting path — including verbatim, which
        // never consults a language model — sees the corrected words, and an
        // LLM cannot paraphrase a term it only ever saw misheard. From here
        // on `corrected` *is* the transcript: every fallback below returns
        // it, because a formatter failure is no reason to also undo the
        // user's own dictionary. `LocalDictionary` never throws and treats
        // every load/apply failure as "no corrections", so this line cannot
        // cost a transcript; the emptiness guard is for the one degenerate
        // dictionary (an empty canonical swallowing the whole utterance)
        // that could otherwise turn words into "nothing to type".
        var corrected = dictionary().apply(raw)
        if corrected.isEmpty { corrected = raw }

        // Snippets next, before any mode or engine decision: a dictated
        // trigger phrase yields its authored expansion as the final output —
        // no mode prompt, no formatter chain, no output guard — which is what
        // lets an expansion carry newlines and exact capitalisation to the
        // injector untouched. Matched against `corrected` so the dictionary
        // can fix a misheard trigger word first. `expansion(for:)` is pure
        // and non-throwing, and `Snippets.load` treats every failure as "no
        // snippets", so this cannot cost a transcript: no match means the
        // utterance processes normally.
        if let expansion = snippets().expansion(for: corrected) {
            // The same hole the post-format check closes: nothing on this
            // path suspends, so only an explicit check keeps a withdrawn
            // request's expansion away from the injector.
            if Task.isCancelled { return "" }
            return expansion
        }

        // The configured intensity rides the resolved mode into the chain and
        // the prompt; `.none` arrives as `usesLLM == false`, the seam verbatim
        // mode already takes, so no formatter learns a new concept here.
        let mode = resolver.resolve(override: override, manual: manual,
                                    frontmostBundleID: frontmostBundleID)
            .applying(cleanup: cleanup)
        onModeResolved?(mode)

        do {
            let formatted = try await formatter.format(corrected, mode: mode)
            // After the work, not only before it: see the class note. A
            // formatter with no suspension point returns a string for a
            // cancelled request without ever raising anything.
            if Task.isCancelled { return "" }
            guard !formatted.isEmpty else {
                // `Formatter` forbids this. A broken implementation must not be
                // able to erase an utterance by looking like a cancellation.
                Self.note("formatter returned nothing for a non-empty "
                          + "transcript; injecting the raw transcript")
                return corrected
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
            return corrected
        }
    }

    /// One line on stderr, matching how the rest of the daemon reports.
    private static func note(_ message: String) {
        FileHandle.standardError.write(Data("dictation: \(message)\n".utf8))
    }
}
