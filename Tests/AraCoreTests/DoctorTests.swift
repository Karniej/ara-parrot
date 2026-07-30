import Foundation
import Testing
@testable import AraCore

/// The spec's error-handling table requires an unavailable on-device model to be
/// "surfaced once in `doctor`". For the Apple model it is the only place it
/// *can* be surfaced: with Apple Intelligence off, `Pipeline.appleFormatter()`
/// returns `nil`, the chain is built with no candidate under that engine, and
/// so no fall-through is ever logged either. The user just gets plainer text
/// with no explanation anywhere.
///
/// The MLX check exists for the sharper version of the same problem: that
/// engine is the *default*, so a fresh install with no model downloaded is the
/// normal state rather than an unusual one.
@Suite("Doctor")
struct DoctorTests {
    @Test("the report includes on-device formatting")
    func reportIncludesFormattingCheck() {
        #expect(DoctorReport.run().contains { $0.name == "on-device formatting" })
    }

    /// A hard requirement, not a preference: `Run` gates startup on
    /// `DoctorReport.allOK`, so a `.fail` here would refuse to start the daemon
    /// on every Mac without Apple Intelligence — which is most of them. The app
    /// is fully functional on the rule-based floor.
    @Test("an unavailable model is a warning, never a failure")
    func unavailableIsOnlyAWarning() {
        let check = DoctorReport.checkOnDeviceFormatting()
        if case .fail = check.status {
            Issue.record("on-device formatting must never block startup")
        }
        #expect(DoctorReport.allOK([check]))
    }

    /// The menu's "Run Diagnostics…" alert shows the same report the CLI
    /// prints, so the rendering is one function with two consumers — this
    /// test is what keeps them from drifting.
    @Test("rendered() is the printed format: mark, name, message, remediation")
    func renderedMatchesPrintedFormat() {
        let checks = [
            Check(name: "alpha", status: .ok, remediation: nil),
            Check(name: "beta", status: .warn("looks off"),
                  remediation: "tighten beta"),
            Check(name: "gamma", status: .fail("broken"),
                  remediation: "replace gamma"),
        ]
        #expect(DoctorReport.rendered(checks) == """
        ✓ alpha: ok
        ! beta: looks off
            → tighten beta
        ✗ gamma: broken
            → replace gamma
        """)
    }

    // MARK: - the default engine

    /// The MLX engine is the default, so its state is the one a fresh install
    /// most needs reported. Without this line the only symptom of a missing
    /// 0.9GB model is one stderr line per utterance, which a user watching
    /// their cursor never sees.
    @Test("the report includes the local formatting model")
    func reportIncludesTheLocalModelCheck() {
        #expect(DoctorReport.run().contains { $0.name == "local formatting model" })
    }

    /// `Run` gates startup on `allOK`, so a `.fail` here would refuse to start
    /// the daemon on every install that has not fetched the optional model.
    @Test("a missing formatting model is a warning, never a failure")
    func missingModelIsOnlyAWarning() {
        let check = DoctorReport.checkLocalFormattingModel()
        if case .fail = check.status {
            Issue.record("a missing formatting model must never block startup")
        }
        #expect(DoctorReport.allOK([check]))
    }

    @Test("the check agrees with what is on disk, and names the fix")
    func localModelCheckAgreesWithDisk() {
        let check = DoctorReport.checkLocalFormattingModel()
        guard #available(macOS 15.4, *) else {
            guard case .warn(let reason) = check.status else {
                Issue.record("below macOS 15.4 the MLX engine cannot run")
                return
            }
            #expect(reason.contains("macOS 15.4"))
            return
        }
        switch check.status {
        case .ok:
            #expect(MLXModel.isPresent)
            #expect(MLXRuntime.metallibIsLocatable)
        case .warn(let reason) where !MLXModel.isPresent:
            #expect(reason.contains(MLXModel.id))
            // The remediation has to be the command, not prose: this is the
            // only place a user is told the model is fetched by hand.
            #expect(check.remediation?.contains(MLXModel.downloadCommand) == true)
        case .warn(let reason):
            // Model present, so the warning can only be the other half of
            // "can the default engine run": the Metal kernel library a plain
            // `swift build` cannot produce. Same shape — the remediation is
            // the command, because this is the only place it is surfaced
            // before a warm-up failure at daemon startup.
            #expect(!MLXRuntime.metallibIsLocatable)
            #expect(reason.contains("mlx.metallib"))
            #expect(check.remediation?.contains(MLXRuntime.buildCommand) == true)
        case .fail:
            Issue.record("covered above")
        }
    }

    // MARK: - legacy transcript logs

    /// Older installs pointed the LaunchAgent's stderr at world-readable
    /// /tmp files that quoted every transcript. The files outlive the fix,
    /// so doctor is where a user finds out they exist.
    @Test("the report includes the legacy-logs check")
    func reportIncludesLegacyLogsCheck() {
        #expect(DoctorReport.run().contains { $0.name == "legacy logs" })
    }

    @Test("a leftover /tmp transcript log is flagged, re-install first, then purge")
    func legacyLogIsFlagged() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("parrot.err.log").path
        try "every transcript ever".write(toFile: log, atomically: true, encoding: .utf8)

        let check = DoctorReport.checkLegacyLogs(paths: [log])
        guard case .warn(let reason) = check.status else {
            Issue.record("a leftover transcript log must be reported")
            return
        }
        #expect(reason.contains(log))
        // The order is the point: a still-loaded old agent recreates the files,
        // so purging before re-installing is a treadmill. The remediation must
        // name the re-install first and the purge second.
        let remediation = try #require(check.remediation)
        let reinstall = try #require(remediation.range(of: "ara install --launch-at-login"))
        let purge = try #require(remediation.range(of: "ara install --purge-legacy-logs"))
        #expect(reinstall.lowerBound < purge.lowerBound)
    }

    // MARK: - the installed agent's log paths

    /// The half of the upgrade path the log files cannot tell you about: an
    /// agent installed before the fix keeps its old plist — std paths at
    /// /tmp — until `ara install --launch-at-login` is re-run, and the
    /// running daemon keeps writing there.
    @Test("an installed plist still pointing its output at /tmp is flagged")
    func oldAgentPlistIsFlagged() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-plist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plist = dir.appendingPathComponent("com.silpho.ara.plist")
        let old: [String: Any] = [
            "Label": "com.silpho.ara",
            "StandardOutPath": "/tmp/parrot.out.log",
            "StandardErrorPath": "/tmp/parrot.err.log",
        ]
        try PropertyListSerialization.data(fromPropertyList: old, format: .xml, options: 0)
            .write(to: plist)

        let check = DoctorReport.checkLaunchAgentLogPaths(plistPath: plist.path)
        guard case .warn(let reason) = check.status else {
            Issue.record("an old plist writing transcripts to /tmp must be reported")
            return
        }
        #expect(reason.contains("/tmp"))
        #expect(check.remediation?.contains("ara install --launch-at-login") == true)
    }

    @Test("a current plist, or none at all, passes the log-path check")
    func currentOrAbsentPlistIsOK() throws {
        // Absent: no agent installed is the default state, not a finding.
        let ghost = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-\(UUID().uuidString).plist").path
        if case .warn = DoctorReport.checkLaunchAgentLogPaths(plistPath: ghost).status {
            Issue.record("no plist must mean nothing to report")
        }

        // Current: exactly what Install writes today.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-plist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plist = dir.appendingPathComponent("com.silpho.ara.plist")
        try PropertyListSerialization.data(
            fromPropertyList: Install.agentPlist(binary: "/usr/local/bin/ara"),
            format: .xml, options: 0
        ).write(to: plist)
        if case .warn = DoctorReport.checkLaunchAgentLogPaths(plistPath: plist.path).status {
            Issue.record("the plist Install writes today must pass its own doctor check")
        }
    }

    @Test("an old agent plist is a warning, never a failure")
    func oldPlistNeverBlocksStartup() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-plist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plist = dir.appendingPathComponent("com.silpho.ara.plist")
        try PropertyListSerialization.data(
            fromPropertyList: ["StandardErrorPath": "/tmp/parrot.err.log"],
            format: .xml, options: 0
        ).write(to: plist)
        #expect(DoctorReport.allOK([DoctorReport.checkLaunchAgentLogPaths(plistPath: plist.path)]))
    }

    @Test("no legacy logs is a clean pass")
    func noLegacyLogsIsOK() {
        let check = DoctorReport.checkLegacyLogs(
            paths: ["/tmp/definitely-not-there-\(UUID().uuidString).log"])
        guard case .ok = check.status else {
            Issue.record("nothing on disk must mean nothing to report")
            return
        }
    }

    /// `Run` gates startup on `allOK`; an old log file must nag, not brick
    /// the daemon.
    @Test("a legacy log is a warning, never a failure")
    func legacyLogNeverBlocksStartup() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("parrot.err.log").path
        try "x".write(toFile: log, atomically: true, encoding: .utf8)

        #expect(DoctorReport.allOK([DoctorReport.checkLegacyLogs(paths: [log])]))
    }

    @Test("the check agrees with the formatter it is reporting on")
    func checkAgreesWithAvailability() {
        let check = DoctorReport.checkOnDeviceFormatting()
        guard #available(macOS 26.0, *) else {
            guard case .warn(let reason) = check.status else {
                Issue.record("below macOS 26 the model cannot exist")
                return
            }
            #expect(reason.contains("macOS 26"))
            return
        }
        switch check.status {
        case .ok:
            #expect(FoundationModelsFormatter.isAvailable)
            #expect(FoundationModelsFormatter.unavailableReason == nil)
        case .warn(let reason):
            // The load-bearing half on this machine, where Apple Intelligence
            // is switched off: the check must not claim availability, and it
            // must say why rather than only that.
            #expect(!FoundationModelsFormatter.isAvailable)
            #expect(!reason.isEmpty)
            #expect(FoundationModelsFormatter.unavailableReason == reason)
            #expect(check.remediation != nil)
        case .fail:
            Issue.record("covered above")
        }
    }
}
