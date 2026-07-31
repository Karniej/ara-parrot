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
            from: .local(folder), onRepair: { _ in repairs += 1 }
        ) { source in
            attempts.append(source)
            return "loaded"
        }
        #expect(result == "loaded")
        #expect(attempts == [.local(folder)])
        #expect(repairs == 0)
    }

    /// The repair, end to end: the second attempt happens, and it happens
    /// against the hub.
    @Test("a local load that fails is retried against the hub")
    func localFailureRetriesAgainstTheHub() async throws {
        var attempts: [ModelSource] = []
        var repaired: [ModelSource] = []
        let result = try await WhisperWarmupPlan.attempt(
            from: .local(folder), onRepair: { repaired.append($0) }
        ) { source in
            attempts.append(source)
            if case .local = source { throw Boom(which: "local") }
            return "repaired"
        }
        #expect(result == "repaired")
        #expect(attempts == [.local(folder), .hub])
        #expect(repaired == [.hub])
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
