import Foundation
import Testing
@testable import AraCore

/// Where `warmUp` gets its model folder from — the decision that costs a warm
/// start four to six seconds of network round trip when it comes out wrong.
///
/// Measured on an M3 Pro with everything already on disk: `WhisperKit.download`
/// spends 3.7s (base.en) to 6.1s (large-v3-turbo) confirming with the hub that
/// the files it is about to hand back are the files already sitting there. That
/// was 85% of base.en's entire warm start and 60% of large-v3-turbo's.
@Suite("Whisper warm-up plan")
struct WhisperWarmupPlanTests {
    private let folder = URL(fileURLWithPath: "/models/openai_whisper-base.en")

    /// The normal case, and the whole point: a complete variant is loaded from
    /// disk without asking anyone.
    @Test("a complete variant on disk is loaded from disk")
    func presentLoadsLocally() {
        #expect(WhisperWarmupPlan.source(present: true, directory: folder) == .local(folder))
    }

    @Test("a variant that is not on disk goes to the hub")
    func absentDownloads() {
        #expect(WhisperWarmupPlan.source(present: false, directory: folder) == .hub)
    }

    /// `WhisperModelStore.directory` returns `nil` for a model with no engine
    /// id. There is no folder to load from then, and inventing one would turn a
    /// clear "this model has no download" into a Core ML error about a missing
    /// file.
    @Test("no directory means the hub decides, whatever presence claimed")
    func noDirectory() {
        #expect(WhisperWarmupPlan.source(present: true, directory: nil) == .hub)
        #expect(WhisperWarmupPlan.source(present: false, directory: nil) == .hub)
    }

    /// The guarantee skipping the hub must not give up. `isPresent` checks that
    /// `config.json` and the three `.mlmodelc` directories exist — it does not
    /// open a 1.3 GB `weight.bin` to see whether the last byte arrived. A local
    /// load that fails is exactly the truncated-download case the etag check
    /// used to repair on every launch, so it must still be repaired — once,
    /// when it actually happens, rather than pre-emptively every time.
    @Test("a failed local load falls back to the hub")
    func localFailureRepairs() {
        #expect(WhisperWarmupPlan.recovery(after: .local(folder)) == .hub)
    }

    /// And exactly once. A hub load that fails has already re-checked every
    /// etag and re-fetched whatever did not match; running it again would only
    /// spend the same seconds to reach the same error, and a warm-up that
    /// retries forever is a daemon that never reports the failure it should.
    @Test("a failed hub load is the end of it")
    func hubFailureIsFinal() {
        #expect(WhisperWarmupPlan.recovery(after: .hub) == nil)
    }

    private struct Boom: Error, Equatable { let which: String }

    /// The happy path costs nothing extra: one attempt, no repair.
    @Test("a local load that works is not second-guessed")
    func successLoadsOnce() async throws {
        var attempts: [ModelSource] = []
        var repairs = 0
        let result = try await WhisperWarmupPlan.attempt(
            from: .local(folder), onRepair: { _, _ in repairs += 1 }
        ) { source in
            attempts.append(source)
            return "loaded"
        }
        #expect(result == "loaded")
        #expect(attempts == [.local(folder)])
        #expect(repairs == 0)
    }

    /// The repair, end to end: the second attempt happens, it happens against
    /// the hub, and the fault that caused it is handed over rather than
    /// dropped. `attempt` throws the *hub's* error when both fail, so this
    /// callback is the only place the first one can still be reported — and
    /// "why is this suddenly downloading 1.6 GB?" is a question a user is
    /// entitled to an answer to.
    @Test("a local load that fails is retried against the hub, with its reason")
    func localFailureRetriesAgainstTheHub() async throws {
        var attempts: [ModelSource] = []
        var repaired: [ModelSource] = []
        var reasons: [Boom] = []
        let result = try await WhisperWarmupPlan.attempt(
            from: .local(folder),
            onRepair: { source, error in
                repaired.append(source)
                if let boom = error as? Boom { reasons.append(boom) }
            }
        ) { source in
            attempts.append(source)
            if case .local = source { throw Boom(which: "local") }
            return "repaired"
        }
        #expect(result == "repaired")
        #expect(attempts == [.local(folder), .hub])
        #expect(repaired == [.hub])
        #expect(reasons == [Boom(which: "local")])
    }

    /// Cancellation is the daemon shutting down or the warm-up being
    /// superseded. Treating it as a corrupt download and answering it with a
    /// hub round trip spends a user's network on work nobody is waiting for —
    /// and since the hub call is cancellable too, it mostly just reaches the
    /// same error again, slower.
    @Test("a cancelled load is not repaired")
    func cancellationIsNotARepair() async {
        var attempts: [ModelSource] = []
        var repairs = 0
        await #expect(throws: CancellationError.self) {
            _ = try await WhisperWarmupPlan.attempt(
                from: .local(folder), onRepair: { _, _ in repairs += 1 }
            ) { source in
                attempts.append(source)
                throw CancellationError()
            } as String
        }
        #expect(attempts == [.local(folder)])
        #expect(repairs == 0)
    }

    /// Once, not until it works. Two failures end in an error rather than a
    /// third attempt — a warm-up that retries forever is a daemon that never
    /// reports the failure the user has to fix.
    @Test("two failures stop, with the hub's error")
    func twoFailuresStop() async {
        var attempts: [ModelSource] = []
        await #expect(throws: Boom(which: "hub")) {
            _ = try await WhisperWarmupPlan.attempt(from: .local(folder)) { source in
                attempts.append(source)
                switch source {
                case .local: throw Boom(which: "local")
                case .hub: throw Boom(which: "hub")
                }
            } as String
        }
        #expect(attempts == [.local(folder), .hub])
    }

    // MARK: - the wait nobody explained

    /// Twenty seconds, and the reason it is that number rather than five or
    /// sixty. Measured on an M3 Pro, warm cache, per client identity:
    ///
    /// | load                                     | seconds |
    /// |------------------------------------------|---------|
    /// | large-v3-turbo, already specialised      | 1.0     |
    /// | base.en, already specialised             | 0.5     |
    /// | base.en, first specialisation            | 11.3    |
    /// | large-v3-turbo, first specialisation     | 141–187 |
    ///
    /// So the threshold has to clear base.en's first compile — which finishes
    /// on its own before anyone reaches for the quit key — and sit far below
    /// the large model's, which does not.
    @Test("the notice waits out every load that is going to finish by itself")
    func thresholdClearsTheShortLoads() {
        #expect(WhisperWarmupPlan.specialisationThreshold > .seconds(11.3))
        #expect(WhisperWarmupPlan.specialisationThreshold < .seconds(60))
    }

    /// The sentence a user reads in the terminal at the twenty-second mark.
    /// It has one job: stop them pressing ^C. Core ML's specialisation is
    /// all-or-nothing — a compile killed at 75 of its 145 seconds leaves ~900
    /// MB of intermediate on disk and the next launch starts from zero
    /// (measured) — so "quitting starts it over" is the load-bearing clause,
    /// and the bounded recurrence is what makes waiting worth it.
    ///
    /// **"once per macOS version", never "one time".** The cache path is
    /// `…/com.apple.e5rt.e5bundlecache/<OS build>/…`, so a system update costs
    /// the compile again. A user promised a one-off who then waits three
    /// minutes after an update has been given a reason to disbelieve
    /// everything else the daemon tells them.
    @Test("the notice bounds the recurrence honestly and says quitting undoes it")
    func noticeExplainsTheWait() {
        let notice = WhisperWarmupPlan.specialisationNotice(model: "whisper-large-v3-turbo")
        #expect(notice.contains("whisper-large-v3-turbo"))
        #expect(notice.contains("Neural Engine"))
        #expect(notice.contains("once per macOS version"))
        #expect(!notice.lowercased().contains("one time"))
        #expect(notice.lowercased().contains("starts it over"))
        #expect(notice.hasSuffix("\n"))
    }

    /// A download that fails is not retried: it already re-checked every etag
    /// and re-fetched whatever did not match.
    @Test("a hub load that fails is not retried")
    func hubFailureIsNotRetried() async {
        var attempts: [ModelSource] = []
        await #expect(throws: Boom(which: "hub")) {
            _ = try await WhisperWarmupPlan.attempt(from: .hub) { source in
                attempts.append(source)
                throw Boom(which: "hub")
            } as String
        }
        #expect(attempts == [.hub])
    }
}
