import ArgumentParser
import Foundation

/// Manage ara's LaunchAgent so the daemon starts at login.
///
/// We deliberately do NOT use SMAppService.mainApp here — that requires a full
/// .app bundle. Since ara ships as a single binary in /usr/local/bin, a
/// plain LaunchAgent plist is the simpler, more honest mechanism.
public struct Install: ParsableCommand {
    public static let configuration = CommandConfiguration(
        abstract: "Install or remove the launch-at-login LaunchAgent."
    )

    @Flag(name: .long, help: "Register ara to start at login.")
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
            try Self.uninstallAgent()
        } else if launchAtLogin {
            try Self.installAgent()
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

    private static let label = "com.silpho.ara"

    /// The label this tool's LaunchAgent carried while it shipped as `parrot`.
    ///
    /// Kept — and actively hunted for — precisely *because* it is no longer
    /// the label: launchd sees no connection between the two, so an agent
    /// bootstrapped under the old one keeps `RunAtLoad`-ing the old binary at
    /// every login, forever, with nothing in the new install pointing at it.
    /// A user who then enables Start at Login gets two daemons fighting over
    /// the hotkey. Every install and uninstall clears it on the way past;
    /// `doctor` reports one that is still there.
    public static let legacyLabel = "com.digimata.parrot"

    /// Where the agent plist lives. Static so `doctor` can inspect the
    /// installed file — and the menu's "Start at Login" item can read its
    /// state — without constructing the command.
    public static var plistURL: URL { agentPlistURL(for: label) }

    /// The pre-rename agent's plist, in the same directory under the old
    /// label. `doctor` reads it; the install and uninstall paths delete it.
    public static var legacyPlistURL: URL { agentPlistURL(for: legacyLabel) }

    private static func agentPlistURL(for label: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    /// Whether launch-at-login is installed: the plist on disk, nothing else.
    /// The menu re-reads this after every toggle — success *and* failure —
    /// rather than assuming the toggle worked.
    public static func isInstalled(at url: URL = plistURL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
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

    /// Writes the agent plist and bootstraps it. Static and public so the
    /// menu's "Start at Login" toggle runs the *same* logic in-process —
    /// `Install` stays the single source of truth for the plist's content and
    /// the launchctl choreography.
    ///
    /// Note the bootstrap is immediate: `RunAtLoad` plus `launchctl
    /// bootstrap` means a background copy starts **now**, not at next login.
    /// A caller whose own process is a foreground daemon (the menu) owes the
    /// user that fact — two daemons will both grab the hotkey until one
    /// quits.
    /// Whether the agent is *running* after the call, not merely installed.
    /// `launchctl bootstrap` can fail while the plist write succeeds, and a
    /// caller that reports "started" on that outcome is claiming something
    /// the code declined to verify.
    public enum StartOutcome: Equatable, Sendable {
        case started
        case plistWrittenNotStarted
    }

    /// What to tell the user after enabling Start at Login. Pure so the two
    /// outcomes' wording is pinned by tests rather than by whichever branch
    /// someone happened to exercise.
    public static func startNotice(for outcome: StartOutcome) -> String {
        switch outcome {
        case .started:
            return "A login copy of Ara has started now and will start at "
                + "every login. If you are running Ara from a terminal, quit "
                + "that one — two daemons would both respond to the hotkey."
        case .plistWrittenNotStarted:
            return "Ara will start at your next login. It could not be "
                + "started right now — launchctl refused the bootstrap — so "
                + "nothing new is running yet. Run `ara doctor` in a terminal "
                + "if it does not appear after logging back in."
        }
    }

    /// Boots out the pre-rename agent and deletes its plist, returning the
    /// path it removed — `nil` when there was nothing there, which is the
    /// normal case on any machine that never ran the old build.
    ///
    /// The bootout comes first and while the file still exists: `launchctl
    /// bootout` takes the plist's path, so unloading a *deleted* agent tells
    /// launchd nothing and the old daemon would run on until the next reboot
    /// with nothing left on disk to explain it.
    ///
    /// Best-effort like every other cleanup path here — a bootout that fails
    /// (launchd never heard of the label; the agent was already unloaded)
    /// must not stop the plist from going, and a plist that will not delete
    /// is one stderr line rather than a failed install. `bootout` is injected
    /// so the decision is testable against real files without touching the
    /// machine's actual launchd.
    @discardableResult
    static func removeLegacyAgent(
        at url: URL = legacyPlistURL,
        bootout: (URL) -> Void = { _ = runLaunchctl(["bootout", "gui/\(uid())", $0.path]) }
    ) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        bootout(url)
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            FileHandle.standardError.write(Data(
                ("couldn't remove the pre-rename launch agent at \(url.path) "
                    + "(\(type(of: error)))\n").utf8
            ))
            return nil
        }
        return url.path
    }

    @discardableResult
    public static func installAgent() throws -> StartOutcome {
        let binary = try resolveBinaryPath()
        let plist = agentPlist(binary: binary)

        // Before the new agent lands, not after: the two labels are unrelated
        // to launchd, so bootstrapping ours on top of a live `parrot` agent is
        // exactly the two-daemons-one-hotkey state this clears.
        if let removed = removeLegacyAgent() {
            print("✓ removed the pre-rename launch agent (\(removed))")
        }

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
            // The plist is on disk, so the agent *will* start at next login —
            // but it is not running now, and the caller must not say it is.
            // A stderr warning is invisible under launchd and to a menu
            // click, which is why the outcome is returned rather than only
            // printed.
            return .plistWrittenNotStarted
        }

        print("✓ launch-at-login installed")
        print("  plist:  \(url.path)")
        print("  binary: \(binary)")
        print("  logs:   discarded (/dev/null) — run `ara` in a terminal to watch output")
        return .started
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

    /// Boots the agent out and removes its plist. Static and public for
    /// `installAgent`'s reason: the menu toggle and the CLI flag are one
    /// implementation.
    ///
    /// Both labels, because "remove launch-at-login" has to mean it: leaving
    /// the pre-rename agent behind would turn the daemon off and have it come
    /// back at the next login under a name nothing in this build mentions.
    public static func uninstallAgent() throws {
        let legacy = removeLegacyAgent()
        if let legacy {
            print("✓ removed the pre-rename launch agent (\(legacy))")
        }
        let url = plistURL
        if FileManager.default.fileExists(atPath: url.path) {
            _ = runLaunchctl(["bootout", "gui/\(uid())", url.path])
            try FileManager.default.removeItem(at: url)
            print("✓ launch-at-login removed")
        } else if legacy == nil {
            print("nothing to remove (no agent at \(url.path))")
        }
    }

    /// Failures a user can act on, worded for the menu's alert rather than for
    /// a terminal. `LocalizedError` so `"\(error)"` at a UI call site renders
    /// the sentence instead of the case name.
    public enum InstallError: LocalizedError, Equatable {
        case binaryNotFound

        public var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "Ara could not work out where its own binary lives, so "
                    + "the login item would have nothing to launch. Install "
                    + "Ara.app to Applications, or put the binary at "
                    + "/usr/local/bin/ara, and try again."
            }
        }
    }

    private static func resolveBinaryPath() throws -> String {
        let resolved = launchAgentBinary(
            runningExecutable: Bundle.main.executableURL?.resolvingSymlinksInPath().path,
            argv0: CommandLine.arguments.first ?? "ara",
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }
        )
        guard let resolved else {
            // `ExitCode` is right for the CLI and useless in a dialog: the menu
            // renders whatever is thrown, and "ExitCode(rawValue: 1)" tells a
            // user nothing about what to do. Throw something that reads.
            throw InstallError.binaryNotFound
        }
        if resolved != canonicalInstall, !isInsideAppBundle(resolved) {
            FileHandle.standardError.write(Data(
                "note: \(canonicalInstall) not found; using \(resolved)\n".utf8
            ))
        }
        return resolved
    }

    /// Where a CLI install puts the binary.
    static let canonicalInstall = "/usr/local/bin/ara"

    /// The path the LaunchAgent's `ProgramArguments[0]` should be. Pure, and
    /// separated from `resolveBinaryPath` because every branch here is a
    /// machine state a test must not create.
    ///
    /// **The bundle wins over `/usr/local/bin/ara`.** Those two are not
    /// interchangeable copies of one program. `Ara.app` carries the
    /// Info.plist — `LSUIElement`, the microphone usage sentence, and the
    /// bundle identifier that TCC files the microphone and accessibility
    /// grants under. Run the loose binary instead and macOS sees a different
    /// principal with different (probably absent) permissions; on a machine
    /// upgrading from the CLI-only era it is also an older build. Whichever
    /// copy the user launched is the one "Start at Login" must bring back.
    ///
    /// Outside a bundle the canonical install comes next, because a dev
    /// binary's path stops existing the moment the checkout moves and launchd
    /// would go on pointing at it forever.
    ///
    /// **But a known path always beats no path.** The running executable was
    /// once only consulted when it sat inside a bundle, which made the bundle
    /// check decide *eligibility* rather than *precedence* — so running
    /// `.build/release/ara`, or `ara` off a `~/.local/bin` symlink, fell all
    /// the way through to `nil` and "Start at Login" failed outright. That is
    /// the everyday case for anyone who has not installed to `/usr/local/bin`,
    /// including every developer working on Ara. `Bundle.main.executableURL`
    /// knows exactly where the process came from; a fragile path that works
    /// today beats a dialog that never works.
    static func launchAgentBinary(
        runningExecutable: String?,
        argv0: String,
        isExecutable: (String) -> Bool
    ) -> String? {
        if let runningExecutable, isInsideAppBundle(runningExecutable),
           isExecutable(runningExecutable) {
            return runningExecutable
        }
        if isExecutable(canonicalInstall) {
            return canonicalInstall
        }
        if let runningExecutable, isExecutable(runningExecutable) {
            return runningExecutable
        }
        // `argv[0]` is whatever the caller handed exec — `./ara`, or a bare
        // `ara` resolved off PATH. A relative path in the plist resolves
        // against launchd's working directory, not the user's, so it is not a
        // path at all for this purpose.
        if argv0.hasPrefix("/"), isExecutable(argv0) {
            return argv0
        }
        return nil
    }

    /// Whether the path is an executable inside an `.app`, i.e. ends in
    /// `<something>.app/Contents/MacOS/<binary>`. Checked structurally rather
    /// than by substring so a directory that merely contains "Contents/MacOS"
    /// is not mistaken for a bundle.
    static func isInsideAppBundle(_ path: String) -> Bool {
        let components = URL(fileURLWithPath: path).pathComponents
        guard components.count >= 4 else { return false }
        let macOS = components[components.count - 2]
        let contents = components[components.count - 3]
        let bundle = components[components.count - 4]
        return macOS == "MacOS" && contents == "Contents" && bundle.hasSuffix(".app")
    }

    private static func uid() -> uid_t { getuid() }

    private static func runLaunchctl(_ args: [String]) -> (status: Int32, stderr: String) {
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
