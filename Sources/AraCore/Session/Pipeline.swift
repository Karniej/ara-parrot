import Foundation

/// Assembles the dictation pipeline the daemon runs.
///
/// This lives in the library rather than inside the `Run` command so the
/// assembly itself can be tested. The unit tests for `FormatterChain` prove the
/// chain behaves; they say nothing about whether the daemon builds the chain
/// the user's `config.json` asked for — a helper that works while nothing
/// proves production uses it is the exact failure this project has already
/// shipped once. Every configuration decision is therefore made here, under
/// test, and what remains in `Run` is the keychain read, one `process` call and
/// one injection.
public enum Pipeline {
    /// The on-device formatter, or `nil` when this machine cannot run one.
    ///
    /// Both gates live here: the compile-time `@available` (the package targets
    /// macOS 14, the framework needs 26) and the runtime availability read.
    ///
    /// **A startup call, deliberately.** `FoundationModelsFormatter.isAvailable`
    /// is synchronous framework work on the calling thread — measured at ~3.3ms
    /// to construct `SystemLanguageModel` plus ~3.1ms for the first
    /// `availability` read on a machine with Apple Intelligence disabled, and
    /// unmeasured on hardware that is eligible but still downloading. That is
    /// fine once, on the CLI's own thread, and would not be per utterance on a
    /// cooperative-pool thread.
    public static func localFormatter() -> (any Formatter)? {
        if #available(macOS 26.0, *), FoundationModelsFormatter.isAvailable {
            return FoundationModelsFormatter()
        }
        return nil
    }

    /// Builds the formatter chain described by `config`.
    ///
    /// - Parameters:
    ///   - config: Supplies the engine, the per-engine deadline, and whether
    ///     cloud formatting is configured at all. A `config.json` with no
    ///     `cloud` key produces a chain with no cloud formatter, so a default
    ///     install cannot reach the network even by mistake.
    ///   - apiKey: The cloud credential, **already read**, or `nil`.
    ///
    ///     A value rather than something lazy, for the reason spelled out on
    ///     `CloudFormatter.init`: `Keychain.readPassword` can put an unlock or
    ///     Allow/Deny dialog in front of the user and block its thread until
    ///     they answer, and this binary is unsigned, so the legacy keychain's
    ///     ACL re-prompts after every rebuild. Read it once, at startup, on the
    ///     caller's own thread — never on the dictation path.
    ///   - local: The on-device formatter, or `nil`. Not defaulted: silently
    ///     getting `nil` because a call site forgot the argument would disable
    ///     on-device formatting with no symptom other than plainer text.
    ///   - rules: The terminal fallback. Defaulted, because there is exactly one
    ///     right answer and substituting another is a test-only affair.
    ///   - cloudTransport: Overrides `CloudFormatter`'s production transport.
    ///     Test-only, and the reason this parameter exists: it is the only way
    ///     to prove that `config.cloud` and `apiKey` actually reach the formatter
    ///     rather than being dropped on the floor, since every other observable
    ///     outcome of a cloud misconfiguration looks identical to having no
    ///     cloud formatter at all.
    public static func makeChain(config: Config,
                                 apiKey: String?,
                                 local: (any Formatter)?,
                                 rules: any Formatter = RuleBasedFormatter(),
                                 cloudTransport: CloudFormatter.Transport? = nil)
        -> FormatterChain
    {
        var cloud: (any Formatter)?
        if let cloudConfig = config.cloud {
            if let cloudTransport {
                cloud = CloudFormatter(config: cloudConfig, apiKey: apiKey,
                                       transport: cloudTransport)
            } else {
                cloud = CloudFormatter(config: cloudConfig, apiKey: apiKey)
            }
        }
        return FormatterChain(engine: config.engine,
                              timeout: .milliseconds(config.timeoutMs),
                              local: local, cloud: cloud, rules: rules)
    }

    /// Builds the session the daemon routes every transcript through.
    ///
    /// `config.mode` becomes the resolver's default, which is what makes the
    /// `mode` key in `config.json` mean anything; `--mode` is passed per
    /// utterance as `override` and outranks it.
    public static func makeSession(config: Config,
                                   apiKey: String?,
                                   local: (any Formatter)?,
                                   registry: ModeRegistry = ModeRegistry(userModes: []),
                                   rules: any Formatter = RuleBasedFormatter(),
                                   cloudTransport: CloudFormatter.Transport? = nil,
                                   frontmostBundleID: @escaping @Sendable () -> String?,
                                   onModeResolved: (@Sendable (Mode) -> Void)? = nil)
        -> DictationSession
    {
        DictationSession(
            formatter: makeChain(config: config, apiKey: apiKey, local: local,
                                 rules: rules, cloudTransport: cloudTransport),
            resolver: ModeResolver(registry: registry, defaultID: config.mode),
            frontmostBundleID: frontmostBundleID,
            onModeResolved: onModeResolved)
    }
}
