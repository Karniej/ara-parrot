import Foundation

/// The world-readable /tmp files earlier versions pointed the LaunchAgent's
/// stdout/stderr at.
///
/// Those versions also quoted every transcript on stderr, so anyone who ran
/// `parrot install --launch-at-login` has a plaintext record of everything
/// they dictated, readable by any local user, with no rotation and no size
/// cap. The plist no longer writes there and the daemon no longer logs
/// transcript text, but the files themselves outlive both fixes — hence this
/// type: `doctor` warns while they exist, `install --purge-legacy-logs`
/// removes them.
public enum LegacyLogs {
    public static let defaultPaths = ["/tmp/parrot.out.log", "/tmp/parrot.err.log"]

    /// The subset of `paths` that is actually on disk, in the order given.
    public static func existing(at paths: [String] = defaultPaths) -> [String] {
        paths.filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Removes whichever of `paths` exist and returns the ones removed.
    ///
    /// Best-effort by design: a file that cannot be deleted (already gone,
    /// foreign ownership) is simply not in the returned list, and the caller
    /// can compare against `existing(at:)` if it wants to name the failures.
    @discardableResult
    public static func purge(paths: [String] = defaultPaths) -> [String] {
        existing(at: paths).filter { path in
            (try? FileManager.default.removeItem(atPath: path)) != nil
        }
    }
}
