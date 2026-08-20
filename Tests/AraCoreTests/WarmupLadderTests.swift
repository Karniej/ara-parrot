import Foundation
import Testing
@testable import AraCore

/// The ladder's rules, off the concurrency that runs them.
///
/// `Ara.run`'s warm-up task races two model loads and adopts whichever is
/// allowed to win; none of that is reachable from a test, which is exactly why
/// none of the *decisions* live there. Everything a race could get wrong is
/// here.
@Suite("Warm-up ladder")
struct WarmupLadderTests {

    @Test("the large model gets a bootstrap")
    func largeModelLadders() {
        let target = ModelRegistry.find("whisper-large-v3-turbo")!
        #expect(WarmupLadder.bootstrap(for: target)?.id == ModelRegistry.bootstrap.id)
    }

    /// A second load of the same size buys nothing and, on a first run, costs a
    /// download to buy it.
    ///
    /// Built here rather than looked up: since the registry went down to
    /// `whisper-small` and `whisper-large-v3-turbo`, nothing offered is small
    /// enough to exercise this rule. That is a fact about today's list, not
    /// about the rule — a smaller model added tomorrow must still be refused,
    /// so the test carries its own.
    @Test("a model no larger than the bootstrap gets none")
    func smallModelsDoNotLadder() {
        let target = TranscriptionModel(
            id: "whisper-tiny", displayName: "Whisper Tiny",
            engine: .whisperKit, whisperKitID: "openai_whisper-tiny",
            sizeMB: 78, languages: ["multi"], recommended: false)
        #expect(target.sizeMB <= ModelRegistry.bootstrap.sizeMB)
        #expect(WarmupLadder.bootstrap(for: target) == nil)
    }

    @Test("the bootstrap does not bootstrap itself")
    func bootstrapDoesNotLadderItself() {
        #expect(WarmupLadder.bootstrap(for: ModelRegistry.bootstrap) == nil)
    }

    /// whisper-small is 488 MB against the bootstrap's 145: bigger, so the
    /// ladder applies to it as well as to the large model.
    @Test("a middling model still ladders")
    func middlingModelLadders() {
        let target = ModelRegistry.find("whisper-small")!
        #expect(WarmupLadder.bootstrap(for: target)?.id == ModelRegistry.bootstrap.id)
    }

    /// The bootstrap must be able to serve every language the models it stands
    /// in for can, or a Polish user's first minute is English nonsense. This is
    /// the property the whole choice of variant rests on.
    @Test("the bootstrap is multilingual")
    func bootstrapIsMultilingual() {
        #expect(!ModelRegistry.bootstrap.isEnglishOnly)
    }

    /// It is a stopgap, not an option. Listing it would let a user pick a
    /// deliberately worse model by mistake and never learn why.
    @Test("the bootstrap is not offered in the Model submenu")
    func bootstrapIsNotListed() {
        #expect(!ModelRegistry.shared.contains { $0.id == ModelRegistry.bootstrap.id })
        #expect(ModelRegistry.find(ModelRegistry.bootstrap.id) == nil)
    }

    // MARK: - which result may be adopted

    @Test("the bootstrap is adopted while the chosen model is still loading")
    func bootstrapAdoptedWhenTargetIsLate() {
        #expect(WarmupLadder.adoptsBootstrap(targetLanded: false))
    }

    /// The race that would downgrade a working user: the chosen model landed
    /// first and the bootstrap's load returns a moment later. Adopting it would
    /// swap a good model out for a worse one, permanently.
    @Test("a bootstrap arriving after the chosen model is discarded")
    func bootstrapDiscardedWhenTargetWon() {
        #expect(!WarmupLadder.adoptsBootstrap(targetLanded: true))
    }

    // MARK: - when a failure is fatal

    /// Unchanged from before the ladder: a daemon that cannot transcribe at all
    /// is not a daemon, and it says so and exits rather than sitting in the
    /// menu bar pretending.
    @Test("the chosen model failing with nothing serving is fatal")
    func targetFailureAloneIsFatal() {
        #expect(WarmupLadder.isFatal(targetFailed: true, bootstrapServing: false))
    }

    /// The rule the ladder changes. The user has working dictation; killing the
    /// process would take it away to punish a failure that cost them nothing.
    @Test("the chosen model failing with the bootstrap serving is not fatal")
    func targetFailureWithBootstrapIsSurvivable() {
        #expect(!WarmupLadder.isFatal(targetFailed: true, bootstrapServing: true))
    }

    @Test("a chosen model that loaded is never fatal")
    func successIsNeverFatal() {
        #expect(!WarmupLadder.isFatal(targetFailed: false, bootstrapServing: false))
        #expect(!WarmupLadder.isFatal(targetFailed: false, bootstrapServing: true))
    }

    // MARK: - what the user is told

    /// It answers one question — "why is this transcript worse than usual?" —
    /// and names the model that will fix it. It must not tell the user to
    /// wait: there is nothing for them to do, and the dictation they have
    /// already started is not affected by knowing.
    @Test("the pill note names the model still loading")
    func servingNoteNamesTheTarget() {
        let target = ModelRegistry.find("whisper-large-v3-turbo")!
        let note = WarmupLadder.servingNote(target: target)
        #expect(note.contains(target.id))
        #expect(!note.lowercased().contains("wait"))
        // Short enough for a second line beside the waveform, which the
        // overlay bounds at 330 points.
        #expect(note.count <= 60)
    }

    // MARK: - the delay

    /// It has to clear every warm load, or a user whose model is already
    /// resident pays for a second one they will never use. Measured on an M3
    /// Pro through the daemon's own path — `prewarm: false`, not the
    /// `loadModels()` row — large-v3-turbo warm is 2.45 s, so anything under
    /// 3 s would fire on a machine that is merely busy.
    @Test("the delay clears the slowest warm load with margin")
    func delayClearsAWarmLoad() {
        #expect(WarmupLadder.bootstrapDelay >= .seconds(4))
        // And stays a negligible fraction of the wait it exists to shorten —
        // 149 s for the large model's first specialisation on the same machine.
        #expect(WarmupLadder.bootstrapDelay <= .seconds(15))
    }
}
