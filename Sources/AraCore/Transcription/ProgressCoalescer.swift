import Foundation

/// Collapses a download's progress stream into at most one report per whole
/// percent.
///
/// The Hub downloader (`HubApi.snapshot` → `Downloader`) calls its progress
/// handler for every chunk of every file — hundreds of times a second on a
/// fast link, on whatever `URLSession` thread the transfer landed on. The
/// consumer is a pill of text that can change a hundred times in the life of
/// the whole download, and every report that changes nothing would still cost
/// a hop to the main actor and a SwiftUI invalidation. So the coalescing
/// happens here, at the source, *before* the hop: `step` answers `nil` for a
/// change nobody could have seen.
///
/// Thread-safe by lock rather than by actor, because the callers are
/// synchronous callbacks on foreign threads with no `await` to offer.
final class ProgressCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var lastReported: Int?

    /// - Returns: the whole percent worth showing, or `nil` when this reading
    ///   would not change what is on screen.
    func step(_ fraction: Double) -> Int? {
        // `Progress(totalUnitCount: 0).fractionCompleted` is NaN, and
        // `Int(NaN)` traps rather than degrading. A download of nothing has
        // nothing to report.
        guard fraction.isFinite else { return nil }
        let percent = Int(min(1, max(0, fraction)) * 100)
        return lock.withLock {
            // Monotonic: the fraction is read from a live `Progress` on an
            // arbitrary thread, so two readings can arrive out of order, and a
            // percentage that goes backwards reads as a bug.
            guard let last = lastReported else {
                lastReported = percent
                return percent
            }
            guard percent > last else { return nil }
            lastReported = percent
            return percent
        }
    }
}
