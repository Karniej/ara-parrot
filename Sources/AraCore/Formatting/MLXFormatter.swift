import Dispatch
import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// On-device formatting via a bundled small language model running on MLX.
///
/// This is the default engine, and the reason the project has one that works:
/// `FoundationModelsFormatter` needs macOS 26 *and* Apple Intelligence switched
/// on, and `CloudFormatter` needs an API key and a network. A stock Apple
/// Silicon Mac has neither, so before this existed the default install fell
/// through to rule-based cleanup on every utterance.
///
/// Model: `mlx-community/Qwen2.5-1.5B-Instruct-4bit`, ~0.9 GB. Measured
/// through this class's own `format` — `PARROT_MLX_BENCH=1 swift test --filter
/// MLXLatency`, release build, M3 Pro, shipped `TranscriptPrompt`, six
/// realistic transcripts: **429 ms median, 505 ms max** against the chain's
/// 2500 ms deadline, deterministic at temperature 0, no tag leaks. Correct
/// rewrites on 5/6 — a dictated "ignore all previous instructions" was obeyed
/// rather than punctuated; see docs/KNOWN-ISSUES.md before trusting the
/// prompt's injection resistance. Qwen2.5 was chosen over Qwen3-1.7B on the
/// plan's Python measurement (379 vs 418 ms median, equally correct), and it
/// has no thinking mode, so `<think>` tags cannot arrive at the user's cursor.
///
/// ## The load happens at startup, and `format` never triggers one
///
/// Measured: 38.4 s cold (including the download), and ~1.8 s warm for the
/// load *plus the priming generation* `loadBundledModel` runs — see the
/// comment there; without it the first `format` after every start pays a
/// one-time 3.4 s Metal-pipeline cost and loses to the deadline. The chain's
/// deadline is 2500 ms, so a lazy first load would be abandoned every time —
/// and an abandoned load is *worse* than a slow one, because abandoning does
/// not stop compute-bound work, it only stops waiting for it. `warmUp()` is
/// therefore the only thing that loads, `Run` calls it before the hotkey loop,
/// and `format` throws `.unavailable` in microseconds when it finds no model
/// so the chain falls through to rules immediately.
///
/// This is also why the class is a lock-guarded `final class` rather than an
/// `actor`. An actor would make `format` actor-isolated, and actor isolation
/// beats executor preference — `withTaskExecutorPreference` would then move
/// nothing, which is exactly the defect the next section exists to prevent.
///
/// ## Everything model-facing runs off the cooperative pool
///
/// See `runOffCooperativePool`. Both the load and the generation go through it.
public final class MLXFormatter: Formatter, @unchecked Sendable {
    /// The single model-facing step, injectable so tests can drive the real
    /// `format` path — its executor routing, its prompt construction and its
    /// error mapping — on a machine with no model on disk. Everything outside
    /// this closure is production code in every configuration.
    typealias Generate = @Sendable (_ instructions: String, _ prompt: String) async throws -> String

    /// Loading is a seam too, and for the same reason: the property under test
    /// is "`format` does not load", which cannot be asserted against a step
    /// that takes 38 s and 0.9 GB of disk to reach.
    typealias Load = @Sendable () async throws -> Generate

    private let isModelPresent: @Sendable () -> Bool
    private let load: Load

    /// The loaded model, as the closure that uses it. `nil` until `warmUp()`
    /// succeeds. Guarded by a lock rather than an actor for the reason in the
    /// type's doc comment.
    private let lock = NSLock()
    private var generate: Generate?

    public convenience init() {
        self.init(isModelPresent: { MLXModel.isPresent }, load: Self.loadBundledModel)
    }

    init(isModelPresent: @escaping @Sendable () -> Bool, load: @escaping Load) {
        self.isModelPresent = isModelPresent
        self.load = load
    }

    /// Whether a model has been loaded and `format` can do anything.
    public var isLoaded: Bool {
        lock.withLock { generate != nil }
    }

    /// Loads the model into memory. Call once, at startup, before the hotkey
    /// loop — never from the dictation path.
    ///
    /// Fails rather than downloading. A 0.9 GB fetch is a thing a user opts
    /// into by name, mirroring `parrot models download` for Whisper weights, so
    /// the failure message names the command that performs it. `Run` treats
    /// that failure as a warning and carries on: the chain still has the
    /// rule-based floor, and refusing to start the daemon because an optional
    /// model is missing would be a worse outcome than plainer text.
    public func warmUp() async throws {
        if isLoaded { return }
        guard isModelPresent() else {
            throw FormatterError.transportFailure(Self.missingModelMessage)
        }
        let load = self.load
        let loaded: Generate
        do {
            loaded = try await Self.runOffCooperativePool(load)
        } catch {
            throw Self.translate(error)
        }
        lock.withLock { if generate == nil { generate = loaded } }
    }

    public func format(_ text: String, mode: Mode) async throws -> String {
        // Pure string work, cheap, and safe anywhere.
        let instructions = TranscriptPrompt.instructions(for: mode)
        let prompt = TranscriptPrompt.wrap(text)

        // Read, never load. The chain gives each engine the same deadline, and
        // an engine that spends it discovering it has no model has cost the
        // user their whole formatting budget for nothing.
        guard let generate = lock.withLock({ self.generate }) else {
            throw FormatterError.unavailable
        }

        let raw: String
        do {
            raw = try await Self.runOffCooperativePool {
                try await generate(instructions, prompt)
            }
        } catch {
            throw Self.translate(error)
        }

        let cleaned = TranscriptPrompt.clean(raw)
        guard !cleaned.isEmpty else { throw FormatterError.implausibleOutput }
        return cleaned
    }

    static var missingModelMessage: String {
        "the local formatting model (\(MLXModel.id)) is not downloaded — "
            + "run `\(MLXModel.downloadCommand)`"
    }

    // MARK: - The model-facing steps

    /// Loads the bundled model from disk and returns the generation step bound
    /// to it.
    ///
    /// Deliberately the *directory* overload of `loadModelContainer`, not the
    /// downloader one: taking a local `URL` makes "this call cannot reach the
    /// network" a property of the API rather than of a guard someone might
    /// later move. The download lives in `MLXModel.download`, reachable only
    /// from the CLI.
    private static let loadBundledModel: Load = {
        // `withError` is load-bearing, not defensive: MLX's default error
        // handler prints and calls `exit(-1)`. Without the scope, a missing
        // Metal library — the state every plain `swift build` binary is in,
        // because SwiftPM cannot compile Metal shaders — does not fail the
        // warm-up, it kills the daemon. The scope converts MLX errors into
        // thrown `MLXError`s; it is task-local, and both this load and the
        // generation below stay in the calling task (`ChatSession` uses
        // inheriting `Task {}`s, never `Task.detached`).
        let container: ModelContainer
        do {
            container = try await withError {
                try await loadModelContainer(
                    from: MLXModel.directory, using: TransformersTokenizerLoader())
            }
        } catch let error as MLXError {
            throw MLXFormatter.runtimeFailure(error)
        }
        // Prime with a throwaway generation. The first generation after a load
        // pays a one-time Metal cost — pipeline-state compilation for every
        // kernel the forward pass uses. Measured here: 3424 ms for the first
        // format against ~480 ms for every later one, against the chain's
        // 2500 ms deadline — so without this line the first utterance after
        // every daemon start is silently abandoned to the rules floor, and the
        // user's impression of the default engine is formed by the one call it
        // is guaranteed to lose. Four tokens is enough to run prefill and
        // decode once; the cost lands here, at startup, inside `warmUp`'s
        // off-pool routing, never on the dictation path.
        //
        // Inside the production `Load`, not in `warmUp`, so the injectable
        // seam is unchanged and stub-driven tests never see an extra call.
        do {
            _ = try await withError {
                try await ChatSession(
                    container,
                    instructions: TranscriptPrompt.instructions(for: ModeRegistry.defaultMode),
                    generateParameters: GenerateParameters(maxTokens: 4, temperature: 0.0)
                ).respond(to: TranscriptPrompt.wrap("ok"))
            }
        } catch let error as MLXError {
            throw MLXFormatter.runtimeFailure(error)
        }
        return { instructions, prompt in
            // A fresh session per call: `ChatSession` accumulates a transcript,
            // and one utterance must not condition the rewrite of the next.
            // `ChatSession` is also documented as not thread-safe, so a shared
            // one would be a data race the moment two utterances overlap; the
            // `ModelContainer` underneath is what serialises access to the
            // weights.
            let session = ChatSession(
                container,
                instructions: instructions,
                generateParameters: MLXFormatter.generateParameters)
            do {
                return try await withError {
                    try await session.respond(to: prompt)
                }
            } catch let error as MLXError {
                throw MLXFormatter.runtimeFailure(error)
            }
        }
    }

    /// Maps an MLX runtime error onto the chain's vocabulary, with one failure
    /// worth a whole sentence: the missing Metal library.
    ///
    /// That is the state every plain `swift build` binary ships in — SwiftPM
    /// cannot compile Metal shaders — so it is the one failure whose fix the
    /// user must be told by name, the way a missing model names its download
    /// command. The MLX message itself is *classified*, never quoted: the
    /// rendered string is a literal in this file, per `translate`'s rule.
    /// Every other MLX error is reduced to its type name.
    ///
    /// Two signals, either sufficient, because neither is reliable alone. The
    /// message check misses in practice: `loadModelContainer` runs its own
    /// nested `withError` scopes, the innermost scope collects first, and the
    /// error that actually surfaces from a metallib-less load was measured to
    /// be a downstream casualty ("expected a non-empty mlx_array") rather than
    /// the root cause. The locator check covers that case; the message check
    /// covers a loader miss the locator's heuristic cannot see.
    static func runtimeFailure(_ error: MLXError) -> FormatterError {
        if case .caught(let message) = error, message.contains("metallib") {
            return .transportFailure(missingMetallibMessage)
        }
        if !MLXRuntime.metallibIsLocatable {
            return .transportFailure(missingMetallibMessage)
        }
        return .transportFailure("MLXError")
    }

    static var missingMetallibMessage: String {
        "this build has no Metal kernel library (mlx.metallib) — "
            + "`swift build` cannot compile one; run `\(MLXRuntime.buildCommand)` "
            + "to compile it and place it next to the parrot binary"
    }

    /// Copy editing is not a creative task and the output is typed straight at
    /// the user's cursor, so sampling is switched off: `temperature: 0` makes
    /// the rewrite of a given transcript reproducible, which is also what makes
    /// a latency measurement mean anything.
    ///
    /// `maxTokens` bounds the worst case. A rewrite is about as long as its
    /// input, so 512 is generous for dictated speech while still capping a
    /// model that decides to keep talking — an unbounded generation would run
    /// past the deadline and be abandoned mid-compute.
    static let generateParameters = GenerateParameters(
        maxTokens: 512, temperature: 0.0)

    // MARK: - Staying off the cooperative pool

    /// The thread pool inference runs on, which is deliberately *not* the
    /// cooperative one. Concurrent rather than serial so a wedged call delays
    /// only itself; libdispatch grows this pool when its threads block, which
    /// is the property the cooperative pool specifically does not have.
    private static let inferenceQueue = DispatchQueue(
        label: "ara.formatting.mlx",
        qos: .userInitiated,
        attributes: .concurrent)

    /// Runs `body` with the inference queue as the task's executor preference,
    /// so anything in it that occupies a thread occupies one of ours.
    ///
    /// The same helper as `FoundationModelsFormatter.runOffCooperativePool`,
    /// and read that one first — it carries the full argument. The short
    /// version: `FormatterChain.withDeadline` *abandons* a slow formatter
    /// rather than cancelling it, because unstructured work cannot be cancelled
    /// from outside, and an abandoned task that occupies its thread keeps
    /// occupying the cooperative pool, which is sized to the core count and
    /// never grows. Measured previously in this project with a blocking engine
    /// on a 12-core machine: calls 12, 24 and 36 each stalled ~9.16 s against
    /// an 80 ms deadline.
    ///
    /// Where Foundation Models left room for doubt — its generation happens out
    /// of process over XPC, so it *might* not block for long — MLX leaves none.
    /// Generation is matrix multiplication in this process, on this thread,
    /// through `mlx-swift`; there is no suspension point inside a decode step
    /// to yield at. A 445 ms generation is 445 ms of a thread, and the load is
    /// ~1 s of one. On a 12-core machine four concurrent utterances would take
    /// a third of the cooperative pool with them.
    ///
    /// **Precondition: the caller must be nonisolated.** Actor isolation beats
    /// executor preference, so from a `@MainActor` caller this moves nothing
    /// and the compute lands on the main thread instead — worse than the
    /// problem being solved. `FormatterChain` satisfies this today: `format` is
    /// nonisolated and the chain invokes it through an `@escaping @Sendable`
    /// closure in an unstructured task.
    ///
    /// **macOS 15.4+**, and the odd version is the real constraint rather than
    /// a rounded-up guess: `withTaskExecutorPreference` is 15.0, but
    /// `DispatchQueue`'s *conformance* to `TaskExecutor` — the thing that makes
    /// the queue usable as one — is 15.4. The package targets 14.0.
    ///
    /// Below that this refuses the work rather than running it unrouted. For
    /// this engine the routing is not an optimisation: an unrouted 445 ms
    /// generation on a pool sized to the core count is the 9.16 s stall above
    /// waiting to happen. The chain treats `.unavailable` as a fall-through to
    /// rules, which is the right outcome for a machine that cannot run the
    /// engine safely, and `Doctor` says so in words.
    static func runOffCooperativePool<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard #available(macOS 15.4, *) else { throw FormatterError.unavailable }
        return try await withTaskExecutorPreference(inferenceQueue) {
            try await body()
        }
    }

    // MARK: - Error mapping

    /// Maps failures onto the chain's vocabulary. The chain logs the mapped
    /// error before falling back, so this is what tells a user "the model is
    /// not loaded" apart from "the model is broken".
    ///
    /// Every rendered string is a literal in this file, following
    /// `CloudFormatter.translate`'s rule: a foreign error's message is a
    /// channel its producer controls, and this daemon's stderr is routinely
    /// piped to a file. MLX and swift-transformers errors can quote file paths,
    /// URLs and tokenizer contents, none of which belongs in a log — so they
    /// are reduced to a type name.
    ///
    /// `CancellationError` passes through as itself. That is the honest
    /// rendering rather than a fix for anything observable: `FormatterChain`
    /// decides cancellation by `Task.isCancelled` and never by error type.
    static func translate(_ error: any Error) -> any Error {
        if let error = error as? FormatterError { return error }
        if error is CancellationError { return error }
        return FormatterError.transportFailure("\(type(of: error))")
    }
}

// MARK: - Model management

/// Where the local formatting model lives, and how it gets there.
///
/// Separate from the formatter because the download is a CLI action and the
/// formatter must not be able to perform one — see `MLXFormatter.warmUp`.
public enum MLXModel {
    /// Measured against Qwen3-1.7B on six transcripts and chosen: faster
    /// (379 vs 418 ms median through the plan's Python probe), equally
    /// correct, and with no thinking mode it cannot emit `<think>` at the
    /// cursor. Do not substitute another model without re-running that
    /// comparison.
    public static let id = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"

    /// Named in every message that reports the model missing, so the fix is in
    /// the failure rather than in documentation the user has to go and find.
    public static let downloadCommand = "parrot models download-formatter"

    public static let sizeMB = 900

    /// The files the model needs: weights, the JSON configs, and the Jinja chat
    /// template when the repo ships one separately. This is `mlx-swift-lm`'s
    /// own `modelDownloadPatterns`, restated here because that constant is
    /// `package`-internal to it.
    static let patterns = ["*.safetensors", "*.json", "*.jinja"]

    /// The same hub cache WhisperKit downloads into — `~/Documents/huggingface`
    /// by default, laid out as `models/<org>/<repo>`. Sharing it is the point:
    /// a user who has run `parrot models download` should not later discover a
    /// second multi-gigabyte directory somewhere else.
    ///
    /// Note that this is **not** the Python `huggingface_hub` cache at
    /// `~/.cache/huggingface/hub`, which uses a different layout
    /// (`models--org--repo/snapshots/<sha>`) that swift-transformers cannot
    /// read. A machine that has fetched this model through Python `mlx_lm`
    /// still has to fetch it here.
    static let hub = HubApi.shared

    public static var directory: URL {
        hub.localRepoLocation(Hub.Repo(id: id, type: .models))
    }

    /// Whether the model is on disk and usable.
    ///
    /// Checks for actual weights and a config rather than for the directory,
    /// because an interrupted download leaves the directory behind: "the folder
    /// exists" would send `warmUp` into a load that fails with a
    /// tokenizer-shaped error instead of the one sentence that tells the user
    /// to run the download again.
    public static var isPresent: Bool {
        let fm = FileManager.default
        let dir = directory
        guard fm.fileExists(atPath: dir.appendingPathComponent("config.json").path) else {
            return false
        }
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        return entries.contains { $0.hasSuffix(".safetensors") }
    }

    /// Fetches the model. Called only from the CLI — never from `format`, and
    /// never from `warmUp`.
    @discardableResult
    public static func download(
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        try await hub.snapshot(from: Hub.Repo(id: id, type: .models),
                               matching: patterns) { p in
            progress(p.fractionCompleted)
        }
    }
}

// MARK: - The Metal kernel library

/// Whether the compiled Metal kernel library the MLX runtime needs is where its
/// loader will look — the build-artifact question, separate from `MLXModel`'s
/// weights-on-disk question because the fixes are different: one is a download,
/// the other is a build step.
///
/// SwiftPM cannot compile Metal shaders, so a plain `swift build` produces a
/// parrot binary with **no** kernel library; `warmUp` then fails (gracefully,
/// via the `withError` scope in `loadBundledModel`) and formatting falls back
/// to rules. `xcodebuild` can compile them, and `scripts/build-metallib.sh`
/// runs it once and copies the result next to the binary.
///
/// Used by `Doctor` only, as a heuristic: the authoritative check is MLX's own
/// loader, whose C++ search (dladdr on the running image, then SwiftPM bundle
/// lookups) this mirrors for the layouts a parrot binary actually has — a bare
/// CLI next to its metallib, or a test bundle. A miss here is one wrong `warn`
/// line in `doctor`, never a disabled engine: `warmUp` itself asks MLX and
/// believes only the real loader.
public enum MLXRuntime {
    /// Named in every message that reports the library missing, mirroring
    /// `MLXModel.downloadCommand`.
    public static let buildCommand = "scripts/build-metallib.sh"

    public static var metallibIsLocatable: Bool { locatedMetallib != nil }

    /// The loader's candidate paths, in its order: colocated `mlx.metallib`,
    /// `Resources/`, the SwiftPM resource bundle, then `default.metallib` in
    /// the working directory (the compiled-in `METAL_PATH` fallback).
    static var locatedMetallib: URL? {
        var roots: [URL] = []
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            roots.append(executable.deletingLastPathComponent())
        }
        // Under `swift test` the code runs inside a .xctest bundle loaded by a
        // separate runner binary; dladdr resolves to the bundle's own MacOS
        // directory, not the runner's. `Bundle(for:)` finds the image this
        // class lives in either way.
        let image = Bundle(for: MLXFormatter.self).bundleURL.resolvingSymlinksInPath()
        roots.append(image.appendingPathComponent("Contents/MacOS"))
        roots.append(image)

        var candidates: [URL] = []
        for root in roots {
            candidates.append(root.appendingPathComponent("mlx.metallib"))
            candidates.append(root.appendingPathComponent("Resources/mlx.metallib"))
            candidates.append(root.appendingPathComponent(
                "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"))
            candidates.append(root.appendingPathComponent("Resources/default.metallib"))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("default.metallib"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

// MARK: - Bridging swift-transformers to MLXLMCommon

/// Loads a tokenizer with swift-transformers' `AutoTokenizer`.
///
/// mlx-swift-lm 3.x deliberately dropped its dependency on the HuggingFace
/// libraries: `TokenizerLoader` and `Downloader` are protocols with no
/// implementations in the package, and a caller must supply both. The package
/// ships `MLXHuggingFace` macros that generate exactly this bridge, but they
/// expand to code against swift-transformers **2.x** (`HuggingFace.HubClient`,
/// `TokenizerError.missingChatTemplate`), and this project is pinned to 1.1.x
/// by WhisperKit. So the bridge is written out by hand against the 1.1 API
/// instead. It is a mechanical adaptation and nothing more: every method
/// forwards.
private struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TransformersTokenizer(try await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TransformersTokenizer: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    // swift-transformers names this parameter `tokens`, MLXLMCommon `tokenIds`.
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try upstream.applyChatTemplate(messages: messages, tools: tools,
                                       additionalContext: additionalContext)
    }
}
