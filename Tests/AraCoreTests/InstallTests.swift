import Foundation
import Testing
@testable import AraCore

/// The LaunchAgent is where the transcript-in-logs defect became persistent:
/// the plist pointed the daemon's stderr at world-readable /tmp files, so a
/// daemonized install accumulated everything ever dictated where any local
/// user could read it. These tests pin the plist's privacy-relevant content
/// and the cleanup path for installs that predate the fix.
@Suite("Install")
struct InstallTests {
    // MARK: - the agent plist

    @Test("the agent discards the daemon's output")
    func agentOutputGoesToDevNull() {
        let plist = Install.agentPlist(binary: "/usr/local/bin/ara")
        #expect(plist["StandardOutPath"] as? String == "/dev/null")
        #expect(plist["StandardErrorPath"] as? String == "/dev/null")
    }

    /// The property that keeps the two features honest together: even though
    /// `--echo-transcripts` exists, a background daemon must never be
    /// configured to write transcript text to a log it cannot show anyone.
    @Test("the agent is never started with --echo-transcripts")
    func agentNeverEchoesTranscripts() {
        let plist = Install.agentPlist(binary: "/usr/local/bin/ara")
        let args = plist["ProgramArguments"] as? [String]
        #expect(args == ["/usr/local/bin/ara", "run", "--skip-doctor"])
        #expect(args?.contains("--echo-transcripts") == false)
    }

    @Test("the agent still keeps its launchd identity")
    func agentKeepsItsIdentity() {
        let plist = Install.agentPlist(binary: "/usr/local/bin/ara")
        #expect(plist["Label"] as? String == "com.silpho.ara")
        #expect(plist["RunAtLoad"] as? Bool == true)
    }

    /// The menu's "Start at Login" checkmark is this predicate — the plist on
    /// disk, never an assumption about what a toggle did.
    @Test("isInstalled reflects whether the agent plist exists")
    func isInstalledReflectsDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ara-agent-\(UUID().uuidString).plist")
        #expect(!Install.isInstalled(at: url))
        try Data("plist".utf8).write(to: url)
        #expect(Install.isInstalled(at: url))
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - the pre-rename agent

    /// The rename moved the agent's label, and launchd knows nothing about the
    /// connection: an agent registered under the old one keeps `RunAtLoad`-ing
    /// the old binary at every login. A user who then enables Start at Login
    /// has two daemons fighting over the hotkey, and no way to see why.
    @Test("the legacy label is the one pre-rename installs registered")
    func legacyLabelIsTheOldOne() {
        #expect(Install.legacyLabel == "com.digimata.parrot")
        #expect(Install.legacyPlistURL.lastPathComponent == "com.digimata.parrot.plist")
        #expect(Install.legacyPlistURL != Install.plistURL)
    }

    /// The order is the whole point: booting out a *deleted* plist tells
    /// launchd nothing, so the agent would go on running until the next
    /// reboot with nothing left on disk to explain it.
    @Test("a legacy agent is booted out while its plist still exists, then removed")
    func legacyAgentIsBootedOutThenRemoved() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plist = dir.appendingPathComponent("com.digimata.parrot.plist")
        try Data("plist".utf8).write(to: plist)

        var bootedOut: [String] = []
        var existedAtBootout: Bool?
        let removed = Install.removeLegacyAgent(at: plist) { url in
            bootedOut.append(url.path)
            existedAtBootout = FileManager.default.fileExists(atPath: url.path)
        }

        #expect(removed == plist.path)
        #expect(bootedOut == [plist.path])
        #expect(existedAtBootout == true)
        #expect(!FileManager.default.fileExists(atPath: plist.path))
    }

    /// The normal case, on every machine that never ran the old build: no
    /// plist, so nothing to boot out either. `launchctl bootout` against a
    /// label launchd has never heard of is noise in a fresh install's output.
    @Test("no legacy agent means nothing is booted out and nothing is removed")
    func noLegacyAgentIsANoOp() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ghost = dir.appendingPathComponent("com.digimata.parrot.plist")

        var bootedOut: [String] = []
        let removed = Install.removeLegacyAgent(at: ghost) { bootedOut.append($0.path) }

        #expect(removed == nil)
        #expect(bootedOut.isEmpty)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - flag validation

    @Test("exactly one primary action, purge allowed alone or alongside")
    func flagValidation() {
        // The two originals, unchanged.
        #expect(Install.flagsAreValid(launchAtLogin: true, uninstall: false,
                                      purgeLegacyLogs: false))
        #expect(Install.flagsAreValid(launchAtLogin: false, uninstall: true,
                                      purgeLegacyLogs: false))
        #expect(!Install.flagsAreValid(launchAtLogin: true, uninstall: true,
                                       purgeLegacyLogs: false))
        #expect(!Install.flagsAreValid(launchAtLogin: false, uninstall: false,
                                       purgeLegacyLogs: false))
        // Purge stands alone or rides along with either action.
        #expect(Install.flagsAreValid(launchAtLogin: false, uninstall: false,
                                      purgeLegacyLogs: true))
        #expect(Install.flagsAreValid(launchAtLogin: true, uninstall: false,
                                      purgeLegacyLogs: true))
        #expect(Install.flagsAreValid(launchAtLogin: false, uninstall: true,
                                      purgeLegacyLogs: true))
        #expect(!Install.flagsAreValid(launchAtLogin: true, uninstall: true,
                                       purgeLegacyLogs: true))
    }
}

/// The purge itself, against real files in a temp directory — the /tmp paths
/// are only the default argument.
@Suite("LegacyLogs")
struct LegacyLogsTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-logs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("the default paths are the ones old installs wrote")
    func defaultPaths() {
        #expect(LegacyLogs.defaultPaths == ["/tmp/parrot.out.log", "/tmp/parrot.err.log"])
    }

    @Test("existing() reports only the files that are there")
    func existingReportsPresence() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let present = dir.appendingPathComponent("parrot.err.log").path
        let absent = dir.appendingPathComponent("parrot.out.log").path
        try "the transcript".write(toFile: present, atomically: true, encoding: .utf8)

        #expect(LegacyLogs.existing(at: [absent, present]) == [present])
        #expect(LegacyLogs.existing(at: [absent]).isEmpty)
    }

    @Test("purge removes the files and says which")
    func purgeRemoves() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("parrot.out.log").path
        let b = dir.appendingPathComponent("parrot.err.log").path
        try "out".write(toFile: a, atomically: true, encoding: .utf8)
        try "err".write(toFile: b, atomically: true, encoding: .utf8)

        let removed = LegacyLogs.purge(paths: [a, b])
        #expect(removed == [a, b])
        #expect(!FileManager.default.fileExists(atPath: a))
        #expect(!FileManager.default.fileExists(atPath: b))
    }

    @Test("purging nothing is a no-op, not an error")
    func purgeWithNothingThere() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ghost = dir.appendingPathComponent("parrot.out.log").path
        #expect(LegacyLogs.purge(paths: [ghost]).isEmpty)
    }
}

@Suite("InstallStartNotice")
struct InstallStartNoticeTests {
    /// The bug this pins: the menu used to claim "has started now"
    /// unconditionally, while `installAgent` returns normally after a failed
    /// `launchctl bootstrap` (writing only a stderr warning that launchd sends
    /// to /dev/null). A notice may only promise what the outcome carries.
    @Test("a started agent is reported as running now")
    func startedSaysRunning() {
        let notice = Install.startNotice(for: .started)
        #expect(notice.contains("has started now"))
        #expect(notice.contains("two daemons"))
    }

    @Test("a written-but-not-started agent never claims to be running")
    func notStartedNeverClaimsRunning() {
        let notice = Install.startNotice(for: .plistWrittenNotStarted)
        #expect(!notice.contains("has started now"))
        #expect(notice.contains("next login"))
        #expect(notice.contains("could not be started"))
    }
}
