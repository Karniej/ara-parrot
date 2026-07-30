import Foundation

/// The version this build reports.
///
/// There is one number in the project — the `VERSION` file at the repository
/// root. `scripts/package-app.sh` reads it into `Ara.app`'s Info.plist as
/// `CFBundleShortVersionString`, names the DMG after it, and this reads it
/// back out at runtime. Nothing here duplicates the number, so nothing here
/// can disagree with the file.
///
/// A `swift build` binary has no bundle and therefore no version, and says so
/// rather than reporting a stale literal: "which release is this?" has no
/// answer for a working copy, and inventing one is how a bug report ends up
/// pinned to the wrong commit.
public enum AraVersion {
    /// What a bundle-less build reports. Deliberately not a number.
    public static let sourceBuild = "source build (unversioned)"

    /// The running build's version.
    public static var current: String { string(from: Bundle.main.infoDictionary) }

    /// Pure so the packaged and unpackaged answers are both testable from a
    /// test bundle, which is neither.
    static func string(from infoDictionary: [String: Any]?) -> String {
        guard let raw = infoDictionary?["CFBundleShortVersionString"] as? String else {
            return sourceBuild
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? sourceBuild : trimmed
    }
}
