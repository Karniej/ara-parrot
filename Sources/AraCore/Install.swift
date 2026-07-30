import ArgumentParser
import Foundation

/// Manage parrot's LaunchAgent so the daemon starts at login.
///
/// We deliberately do NOT use SMAppService.mainApp here — that requires a full
/// .app bundle. Since parrot ships as a single binary in /usr/local/bin, a
/// plain LaunchAgent plist is the simpler, more honest mechanism.
public struct Install: ParsableCommand {
    public static let configuration = CommandConfiguration(
        abstract: "Install or remove the launch-at-login LaunchAgent."
    )

    @Flag(name: .long, help: "Register parrot to start at login.")
    var launchAtLogin: Bool = false

    @Flag(name: .long, help: "Remove the launch-at-login agent.")
    var uninstall: Bool = false

    @Flag(name: .long,
          help: "Delete the world-readable /tmp/parrot.{out,err}.log files earlier versions wrote transcripts to.")
    var purgeLegacyLogs: Bool = false

    public init() {}

    public func run() throws {
        guard Self.flagsAreValid(launchAtLogin: launchAtLogin, uninstall: uninstall,
                                 purgeLegacyLogs: purgeLegacyLogs)
        else {
            FileHandle.standardError.write(Data(
                "specify --launch-at-login, --uninstall, or --purge-legacy-logs (purge combines with either)\n"
                    .utf8
            ))
            throw ExitCode(64)
        }

        if purgeLegacyLogs {
            purgeLegacyLogFiles()
        }
        if uninstall {
            try removeAgent()
        } else if launchAtLogin {
            try writeAgent()
        }
    }

    /// The flag contract, pure so it is testable: exactly one of the two
    /// mutually exclusive agent actions, or none of them if the purge — which
    /// combines with either — is what the user came for.
    static func flagsAreValid(launchAtLogin: Bool, uninstall: Bool,
                              purgeLegacyLogs: Bool) -> Bool {
        if launchAtLogin && uninstall { return false }
        return launchAtLogin || uninstall || purgeLegacyLogs
    }

    // MARK: -

    private static let label = "com.digimata.parrot"

    private var plistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(Self.label).plist")
    }

    /// The plist content, separated from the write so tests can hold it to
    /// its privacy contract:
    ///
    /// - The std paths are `/dev/null`, not files. Under launchd, stderr is a
    ///   log; earlier versions pointed it at world-readable /tmp and — with
    ///   transcripts then quoted per utterance — accumulated everything the
    ///   user ever dictated. The daemon now logs counts, not text, but a
    ///   background process nobody watches has no reader for its output
    ///   either way.
    /// - `ProgramArguments` must never grow `--echo-transcripts`. The flag
    ///   exists for interactive runs; combined with a log file it recreates
    ///   the defect this layout exists to end.
    static func agentPlist(binary: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [binary, "run", "--skip-doctor"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false] as [String: Any],
            "ProcessType": "Interactive",
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null",
        ]
    }

    private func writeAgent() throws {
        let binary = try resolveBinaryPath()
        let plist = Self.agentPlist(binary: binary)

        let url = plistURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)

        // Best-effort bootstrap; ignore failure if already loaded.
        _ = runLaunchctl(["bootout", "gui/\(uid())", url.path])
        let result = runLaunchctl(["bootstrap", "gui/\(uid())", url.path])
        if result.status != 0 {
            FileHandle.standardError.write(Data(
                "warning: launchctl bootstrap exited \(result.status):\n\(result.stderr)\n".utf8
            ))
        }

        print("✓ launch-at-login installed")
        print("  plist:  \(url.path)")
        print("  binary: \(binary)")
        print("  logs:   discarded (/dev/null) — run `parrot` in a terminal to watch output")
    }

    /// `--purge-legacy-logs`. Best-effort like the rest of the cleanup paths:
    /// a file that will not delete gets a line naming it, not an abort.
    private func purgeLegacyLogFiles() {
        let found = LegacyLogs.existing()
        guard !found.isEmpty else {
            print("no legacy /tmp logs to remove")
            return
        }
        let removed = LegacyLogs.purge()
        for path in removed {
            print("✓ removed \(path)")
        }
        for path in found where !removed.contains(path) {
            FileHandle.standardError.write(Data("couldn't remove \(path)\n".utf8))
        }
    }

    private func removeAgent() throws {
        let url = plistURL
        if FileManager.default.fileExists(atPath: url.path) {
            _ = runLaunchctl(["bootout", "gui/\(uid())", url.path])
            try FileManager.default.removeItem(at: url)
            print("✓ launch-at-login removed")
        } else {
            print("nothing to remove (no agent at \(url.path))")
        }
    }

    private func resolveBinaryPath() throws -> String {
        // /usr/local/bin/parrot is the canonical install path. Honor a real
        // location if running from elsewhere (e.g. dev).
        let candidate = "/usr/local/bin/parrot"
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // Fall back to the running executable's resolved path.
        let argv0 = CommandLine.arguments.first ?? "parrot"
        if argv0.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: argv0) {
            FileHandle.standardError.write(Data(
                "note: /usr/local/bin/parrot not found; using \(argv0)\n".utf8
            ))
            return argv0
        }
        FileHandle.standardError.write(Data(
            "couldn't locate the parrot binary. install it to /usr/local/bin/parrot first.\n".utf8
        ))
        throw ExitCode(1)
    }

    private func uid() -> uid_t { getuid() }

    private func runLaunchctl(_ args: [String]) -> (status: Int32, stderr: String) {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = args
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()
        do {
            try task.run()
        } catch {
            return (-1, "\(error)")
        }
        task.waitUntilExit()
        let err = String(
            data: errPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return (task.terminationStatus, err)
    }
}
