import Foundation
import Testing
@testable import AraCore

/// The version a running ara reports. There is exactly one number in the
/// project — the `VERSION` file — and it reaches the binary the only way an
/// unmodified SwiftPM build allows: `scripts/package-app.sh` stamps it into
/// `Ara.app/Contents/Info.plist`, and this reads it back out. A source build
/// has no Info.plist and therefore no version, which is the honest answer
/// rather than a literal in Swift that would rot the moment VERSION moved.
@Suite("AraVersion")
struct AraVersionTests {
    @Test("the packaged app reports the version stamped into its Info.plist")
    func readsTheBundleVersion() {
        #expect(AraVersion.string(from: ["CFBundleShortVersionString": "0.1.0"]) == "0.1.0")
    }

    /// `swift build`'s bare executable: no bundle, no Info.plist, no version.
    /// It must still answer something, and that something must be
    /// distinguishable from a release in a bug report.
    @Test("a source build says so instead of inventing a number")
    func sourceBuildIsLabelled() {
        #expect(AraVersion.string(from: nil) == AraVersion.sourceBuild)
        #expect(AraVersion.sourceBuild.contains("source"))
    }

    /// A bundle can exist without the key — `Bundle.main.infoDictionary` is
    /// non-nil for plenty of hosts (the test runner is one). An empty or
    /// whitespace value is the same amount of information as no key at all.
    @Test("a missing or blank value is not a version")
    func blankIsNotAVersion() {
        #expect(AraVersion.string(from: [:]) == AraVersion.sourceBuild)
        #expect(AraVersion.string(from: ["CFBundleShortVersionString": ""]) == AraVersion.sourceBuild)
        #expect(AraVersion.string(from: ["CFBundleShortVersionString": "   "]) == AraVersion.sourceBuild)
        #expect(AraVersion.string(from: ["CFBundleShortVersionString": 3]) == AraVersion.sourceBuild)
    }

    @Test("surrounding whitespace is trimmed, not reported")
    func trimsWhitespace() {
        #expect(AraVersion.string(from: ["CFBundleShortVersionString": " 1.2.3\n"]) == "1.2.3")
    }
}
