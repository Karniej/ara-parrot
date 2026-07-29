import Foundation
import Testing
@testable import AraCore

/// Peak simultaneous occupancy, sampled from threads that are about to block.
///
/// Deliberately lock-based rather than an actor: the whole point is to measure
/// code that blocks its thread without ever suspending, and such code cannot
/// `await`.
private final class PeakOccupancy: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var high = 0

    func enter() {
        lock.lock()
        current += 1
        high = max(high, current)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        current -= 1
        lock.unlock()
    }

    var peak: Int {
        lock.lock()
        defer { lock.unlock() }
        return high
    }
}

@Suite("FoundationModels availability")
struct FoundationModelsAvailabilityTests {
    let mode = Mode(id: "default", name: "Default", prompt: "clean it up",
                    appBundleIDs: [], usesLLM: true)

    @Test("availability check never traps, whatever the machine state")
    func availabilityIsSafe() throws {
        guard #available(macOS 26.0, *) else { return }
        // Must return a Bool rather than crashing when Apple Intelligence
        // is disabled — that is the common case for other users.
        _ = FoundationModelsFormatter.isAvailable
    }

    @Test("formatter throws .unavailable rather than hanging when disabled")
    func throwsWhenUnavailable() async throws {
        guard #available(macOS 26.0, *) else { return }
        guard !FoundationModelsFormatter.isAvailable else { return }
        let formatter = FoundationModelsFormatter()

        // Timed, because "throws" is only half the requirement: the chain gives
        // each engine a deadline, and an engine that spends it before admitting
        // it has no model delays the user's text by that much for nothing.
        let start = ContinuousClock.now
        do {
            let out = try await formatter.format("hello there friend", mode: mode)
            Issue.record("expected .unavailable, got \(out)")
        } catch let error as FormatterError {
            guard case .unavailable = error else {
                Issue.record("expected .unavailable, got \(error)")
                return
            }
        }
        #expect(ContinuousClock.now - start < .milliseconds(100))
    }

    @Test("blocking inference work is kept off the cooperative thread pool")
    func inferenceRunsOffTheCooperativePool() async throws {
        guard #available(macOS 26.0, *) else { return }
        // The cooperative pool is sized to the core count and does not grow for
        // threads that block, so occupancy above that count is only reachable
        // off it. The bodies here never suspend — that is the point: they are
        // strictly less cooperative than `respond(to:)` is believed to be, so
        // the test cannot pass by being handled more gently than reality.
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let blockers = cores * 2
        let occupancy = PeakOccupancy()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<blockers {
                group.addTask {
                    try? await FoundationModelsFormatter.runOffCooperativePool {
                        occupancy.enter()
                        usleep(400_000)
                        occupancy.leave()
                    }
                }
            }
        }

        #expect(occupancy.peak > cores,
                "peak occupancy \(occupancy.peak) on \(cores) cores: blocking work was confined to the cooperative pool")
    }

    @Test("model output is stripped of the wrapper the prompt puts around input")
    func cleanStripsWrapperTags() throws {
        guard #available(macOS 26.0, *) else { return }
        #expect(FoundationModelsFormatter.clean("  Hello there, friend.\n")
                == "Hello there, friend.")
        #expect(FoundationModelsFormatter.clean("<transcript>Hello there.</transcript>")
                == "Hello there.")
        // Truncated generation leaves only the opening tag behind.
        #expect(FoundationModelsFormatter.clean("<transcript>\nHello there.")
                == "Hello there.")
        // Tags the user actually dictated are content, not wrapper, and survive.
        #expect(FoundationModelsFormatter.clean("Wrap it in a <div> tag.")
                == "Wrap it in a <div> tag.")
        #expect(FoundationModelsFormatter.clean("   \n ").isEmpty)
    }
}
