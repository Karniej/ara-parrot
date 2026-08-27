import FluidAudio
import Foundation

/// FluidAudio exports a `FluidAudio` *struct* as well as the module, so
/// `FluidAudio.Language` resolves to a member of that struct and does not
/// compile. Unqualified `Language` reaches the right type — AraCore has none
/// of its own — and the alias gives it a name that says whose it is, so a
/// reader does not mistake it for `LanguageSetting` or `LanguageCatalog`.
private typealias ASRLanguage = Language

/// Parakeet TDT v3 on the Neural Engine, through FluidAudio.
///
/// ## Why this is the default
///
/// Measured on an M3 Pro against `whisper-large-v3-turbo` — the same audio,
/// the same process, the user's own dictation rather than a synthesized voice:
///
/// | utterance          | parakeet | whisper | |
/// |--------------------|----------|---------|---|
/// | 34.6s English      | 380 ms   | 1674 ms | 4.4x |
/// | 29.3s Polish       | 413 ms   | 1991 ms | 4.8x |
/// | load               | 336 ms   | 1540 ms | 4.6x |
///
/// Both transcripts were essentially correct in both languages. The speed is
/// the whole difference, and it is large enough to change what dictation feels
/// like: the wait between releasing the key and seeing text is dominated by
/// this call.
///
/// It also punctuates and capitalises itself, which is what `cleanup: light`
/// used to buy from a language model at the cost of another second.
///
/// ## What it cannot do
///
/// **25 European languages, against Whisper's 99.** Polish, Czech, Ukrainian
/// and the rest of Europe are covered; Japanese, Chinese, Korean, Arabic,
/// Hindi, Turkish and about sixty-five others are not. That is the entire
/// reason `WhisperKitTranscriber` stays in the tree and remains selectable —
/// see `ModelRegistry`.
///
/// It also keeps filler words where Whisper silently drops them ("this new um
/// engine"). The rules floor strips them in about two milliseconds, so this
/// costs nothing in practice, but it is why turning cleanup off entirely is
/// not the same as turning `RuleBasedFormatter` off.
///
/// ## Why there is no ladder here
///
/// `WarmupLadder` exists because a Whisper model can take minutes to become
/// usable and something has to serve utterances meanwhile. A third of a second
/// needs no stand-in, so this type has no `adopt` and no `buildPipeline`, and
/// `SpeechTranscriber` deliberately does not require them.
public actor ParakeetTranscriber: SpeechTranscriber {
    private let modelIDLock = NSLock()
    nonisolated(unsafe) private var _modelID: String
    public nonisolated var modelID: String {
        modelIDLock.withLock { _modelID }
    }

    private let model: TranscriptionModel
    private var manager: AsrManager?

    /// The language setting, kept for the same reason `WhisperKitTranscriber`
    /// keeps it: the Language submenu can change it between utterances.
    ///
    /// Parakeet detects the language itself and needs no token to be told
    /// which to produce, so this is only ever a *hint* — passed as
    /// `Language` to bias token selection towards the right script, which is
    /// what FluidAudio's filter is for. A monitored set of more than one, and
    /// automatic, both pass nothing and let the model decide.
    private var language: LanguageSetting

    public init(model: TranscriptionModel, language: LanguageSetting = .automatic) {
        self.model = model
        self._modelID = model.id
        self.language = language
    }

    public func warmUp(
        onPhase: @escaping @Sendable (TranscriberWarmup) -> Void = { _ in }
    ) async throws {
        if manager != nil { return }

        // `.loading` rather than `.downloading` when the bundle is already
        // there. FluidAudio's download is quiet — there is no progress stream
        // to forward — so the honest report is which of the two waits this is,
        // and then nothing until it finishes.
        let present = AsrModels.modelsExist(
            at: AsrModels.defaultCacheDirectory(), version: .v3)
        onPhase(present ? .loading : .downloading(percent: nil))
        if !present {
            FileHandle.standardError.write(Data(
                ("downloading \(model.id) "
                    + "(\(ModelSize.label(megabytes: model.sizeMB)), one time)...\n").utf8))
        }
        FileHandle.standardError.write(Data("loading \(model.id)...\n".utf8))

        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        // No "done" report: `TranscriberWarmup` has no such case, and the
        // caller learns the load finished by this method returning. Whisper's
        // warm-up behaves the same way.
    }

    public func setLanguage(_ setting: LanguageSetting) {
        language = setting
    }

    public func transcribe(_ audio: [Float]) async throws -> String {
        if manager == nil { try await warmUp() }
        guard let manager else { throw TranscriberError.notLoaded }

        // Fresh state per utterance. A TDT decoder carries state so a stream
        // can continue where it left off; ara's utterances are independent —
        // a hotkey release ends one — and reusing it would let one dictation
        // condition the next.
        var decoder = try TdtDecoderState()
        let result = try await manager.transcribe(
            audio, decoderState: &decoder, language: hint)

        if let hint {
            FileHandle.standardError.write(Data(
                "  language: \(hint.rawValue) · hinted\n".utf8))
        }
        return WhisperKitTranscriber.sanitize(result.text)
    }

    /// The language to bias towards, or `nil` to let the model decide.
    ///
    /// Only a single monitored language is a hint. A set of several is the
    /// user saying "I switch between these", which is exactly the case the
    /// model's own detection handles and a fixed hint would break.
    private var hint: ASRLanguage? {
        guard let codes = language.monitoredCodes, codes.count == 1 else { return nil }
        return ASRLanguage(rawValue: codes[0])
    }
}
