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
    public static func appleFormatter() -> (any Formatter)? {
        if #available(macOS 26.0, *), FoundationModelsFormatter.isAvailable {
            return FoundationModelsFormatter()
        }
        return nil
    }

    /// The bundled MLX formatter — the default engine.
    ///
    /// Deliberately **not** gated on whether the model is on disk. The gate
    /// belongs in `warmUp`, and a chain built without the formatter would have
    /// nothing to log when the user's default engine does nothing — the same
    /// silent-degradation trap `Doctor.checkOnDeviceFormatting` exists to
    /// close. An MLX formatter that was never warmed up throws `.unavailable`
    /// in microseconds, so the cost of keeping it in the chain is one stderr
    /// line per utterance that names the missing engine.
    ///
    /// Nor is it gated on macOS version. `MLXFormatter` refuses the work
    /// itself below macOS 15.4 — see `runOffCooperativePool` — which keeps the
    /// reason next to the constraint instead of duplicating it here.
    public static func mlxFormatter() -> MLXFormatter {
        MLXFormatter()
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
    ///   - mlx: The bundled MLX formatter, or `nil`. Not defaulted, for the
    ///     same reason as `apple`.
    ///   - apple: Apple's on-device formatter, or `nil`. Not defaulted:
    ///     silently getting `nil` because a call site forgot the argument would
    ///     disable on-device formatting with no symptom other than plainer
    ///     text.
    ///   - rules: The terminal fallback. Defaulted, because there is exactly one
    ///     right answer and substituting another is a test-only affair.
    ///   - cloudTransport: Overrides `CloudFormatter`'s production transport.
    ///     Test-only, and the reason this parameter exists: it is the only way
    ///     to prove that `config.cloud` and `apiKey` actually reach the formatter
    ///     rather than being dropped on the floor, since every other observable
    ///     outcome of a cloud misconfiguration looks identical to having no
    ///     cloud formatter at all.
    ///
    /// Internal rather than public: the executable builds a session, never a
    /// bare chain, and only the tests reach for this directly.
    static func makeChain(config: Config,
                          apiKey: String?,
                          mlx: (any Formatter)?,
                          apple: (any Formatter)?,
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
                              mlx: mlx, apple: apple, cloud: cloud, rules: rules)
    }

    /// Builds the session the daemon routes every transcript through.
    ///
    /// `config.mode` becomes the resolver's default, which is what makes the
    /// `mode` key in `config.json` mean anything; `--mode` is passed per
    /// utterance as `override` and outranks it. The frontmost application is not
    /// configured here at all — it is sampled per utterance and passed to
    /// `process`.
    ///
    /// `dictionaryURL` is where the custom vocabulary lives; `nil` means the
    /// production location next to `config.json`. The session gets a *loader*,
    /// not a dictionary: `LocalDictionary.load` runs per utterance, which is
    /// the entire hot-reload mechanism — see `DictationSession.init`.
    ///
    /// `dictionary` overrides the loader wholesale. The daemon uses it to
    /// overlay `UnsavedCorrections` — menu additions whose write to disk
    /// failed — on every load; a session built from the URL alone would drop
    /// exactly those. When given, `dictionaryURL` is ignored: the source owns
    /// the whole answer, including where (or whether) it reads a file.
    ///
    /// `snippetsURL` and `snippets` follow the same pattern for voice
    /// snippets: `nil` means the production `snippets.json` next to
    /// `config.json`, loaded fresh per utterance, and a `snippets` source
    /// overrides the URL wholesale. There is no unsaved-state overlay here —
    /// snippets are file-only in v1, so the URL loader is the whole story.
    public static func makeSession(config: Config,
                                   apiKey: String?,
                                   mlx: (any Formatter)?,
                                   apple: (any Formatter)?,
                                   registry: ModeRegistry = ModeRegistry(userModes: []),
                                   rules: any Formatter = RuleBasedFormatter(),
                                   cloudTransport: CloudFormatter.Transport? = nil,
                                   dictionaryURL: URL? = nil,
                                   dictionary: (@Sendable () -> LocalDictionary)? = nil,
                                   snippetsURL: URL? = nil,
                                   snippets: (@Sendable () -> Snippets)? = nil,
                                   onModeResolved: (@Sendable (Mode) -> Void)? = nil)
        -> DictationSession
    {
        let dictionaryURL = dictionaryURL ?? LocalDictionary.defaultURL
        let snippetsURL = snippetsURL ?? Snippets.defaultURL
        return DictationSession(
            formatter: makeChain(config: config, apiKey: apiKey, mlx: mlx,
                                 apple: apple, rules: rules,
                                 cloudTransport: cloudTransport),
            resolver: ModeResolver(registry: registry, defaultID: config.mode),
            dictionary: dictionary ?? { LocalDictionary.load(from: dictionaryURL) },
            snippets: snippets ?? { Snippets.load(from: snippetsURL) },
            onModeResolved: onModeResolved)
    }
}
