import AVFoundation
import AppKit
import ApplicationServices
import Foundation

public enum CheckStatus {
    case ok
    case warn(String)
    case fail(String)
}

public struct Check {
    let name: String
    let status: CheckStatus
    let remediation: String?

    /// Whether a named check is among the failures — the executable's alert
    /// uses it to pick which Privacy pane to open, without needing the stored
    /// properties to become public.
    public static func failed(_ checks: [Check], nameContains needle: String) -> Bool {
        checks.contains { check in
            guard case .fail = check.status else { return false }
            return check.name.contains(needle)
        }
    }

    /// The failing checks, worded for a dialog rather than a terminal. Public
    /// because a Finder-launched daemon has no stderr and must say this in an
    /// alert instead; pure so the wording is testable without a screen.
    public static func failureSummary(_ checks: [Check]) -> String? {
        let failures = checks.compactMap { check -> String? in
            guard case .fail(let detail) = check.status else { return nil }
            guard let remediation = check.remediation else {
                return "\(check.name): \(detail)"
            }
            return "\(check.name): \(detail)\n    \(remediation)"
        }
        guard !failures.isEmpty else { return nil }
        return failures.joined(separator: "\n\n")
    }
}

public enum DoctorReport {
    public static func run() -> [Check] {
        [
            checkMicrophone(),
            checkAccessibility(),
            checkFnKeyMapping(),
            checkLocalFormattingModel(),
            checkOnDeviceFormatting(),
            checkLegacyLogs(),
            checkLaunchAgentLogPaths(),
            checkLegacyLaunchAgent(),
        ]
    }

    /// The rename's own upgrade path: an agent installed while this tool
    /// shipped as `parrot` is registered under `com.digimata.parrot`, and
    /// launchd sees no connection between that label and `com.silpho.ara`.
    /// The old agent goes on starting the old binary at every login, and a
    /// user who then enables Start at Login ends up with two daemons fighting
    /// over the hotkey — with nothing in the new install naming the other one.
    ///
    /// The remediation is just the re-install, because `installAgent` boots
    /// the old label out on its way past; there is nothing to delete by hand.
    ///
    /// A **warning, never a failure**, like every migration finding: the
    /// daemon works, it is the leftover registration that misbehaves.
    static func checkLegacyLaunchAgent(
        plistPath: String = Install.legacyPlistURL.path
    ) -> Check {
        let name = "legacy launch agent"
        guard FileManager.default.fileExists(atPath: plistPath) else {
            return Check(name: name, status: .ok, remediation: nil)
        }
        return Check(
            name: name,
            status: .warn("an agent from before the rename is still installed at "
                + plistPath + " — it starts a second daemon at every login"),
            remediation: "run `ara install --launch-at-login` (it removes the old "
                + "agent), or `ara install --uninstall` if you do not want a "
                + "background daemon at all"
        )
    }

    /// The other half of the legacy-logs upgrade path: an agent installed
    /// before the fix keeps its old plist — std paths at /tmp — until
    /// `ara install --launch-at-login` is re-run, and the running daemon
    /// keeps writing transcripts there. Purging the files without fixing the
    /// plist is a treadmill; this check is what points at the plist.
    ///
    /// A **warning, never a failure**, like every migration finding: the
    /// daemon itself works fine, it is the leftover configuration that leaks.
    static func checkLaunchAgentLogPaths(
        plistPath: String = Install.plistURL.path
    ) -> Check {
        let name = "launch agent log paths"
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, format: nil) as? [String: Any]
        else {
            // No agent installed (or unreadable) — nothing writing anywhere.
            return Check(name: name, status: .ok, remediation: nil)
        }
        let stale = ["StandardOutPath", "StandardErrorPath"]
            .compactMap { plist[$0] as? String }
            .filter { $0.hasPrefix("/tmp/") }
        guard !stale.isEmpty else {
            return Check(name: name, status: .ok, remediation: nil)
        }
        return Check(
            name: name,
            status: .warn("the installed agent still sends daemon output to "
                + stale.joined(separator: ", ")),
            remediation: "re-run `ara install --launch-at-login` to rewrite the agent, "
                + "then `ara install --purge-legacy-logs`"
        )
    }

    /// Flags the world-readable /tmp files earlier versions sent the
    /// LaunchAgent's stderr to — files that quote every transcript dictated
    /// while that agent ran. The plist no longer writes there, but the files
    /// outlive the fix, so this line is how a user learns they exist.
    ///
    /// A **warning, never a failure**: `Run` gates startup on `allOK`, and a
    /// leftover log is something to clean up, not a reason to refuse to start.
    static func checkLegacyLogs(paths: [String] = LegacyLogs.defaultPaths) -> Check {
        let found = LegacyLogs.existing(at: paths)
        guard !found.isEmpty else {
            return Check(name: "legacy logs", status: .ok, remediation: nil)
        }
        return Check(
            name: "legacy logs",
            status: .warn("world-readable transcript logs from an earlier version: "
                + found.joined(separator: ", ")),
            // Order matters: a still-loaded old agent recreates the files, so
            // the re-install that rewrites its plist has to come first or the
            // purge is a treadmill.
            remediation: "if the background daemon is installed, re-run "
                + "`ara install --launch-at-login` first (the old agent keeps "
                + "writing there), then `ara install --purge-legacy-logs`"
        )
    }

    /// Reports whether the **default** formatting engine can run.
    ///
    /// This is the check that matters most now: `engine` defaults to `mlx`, and
    /// the bundled model is a 0.9 GB explicit download. Without this line, a
    /// fresh install formats with rule-based cleanup only, and the sole clue is
    /// one stderr line per utterance that a user watching their cursor will
    /// never see.
    ///
    /// A **warning, never a failure**, for the same reason as the check below:
    /// `Run` gates startup on `allOK`, and refusing to start the daemon because
    /// an optional model has not been fetched would make a working install
    /// unusable.
    ///
    /// The macOS-15.4 floor is reported separately from the missing model,
    /// because they have different fixes — one is a download, the other is not
    /// something the user can do anything about.
    static func checkLocalFormattingModel() -> Check {
        let name = "local formatting model"
        guard #available(macOS 15.4, *) else {
            return Check(
                name: name,
                status: .warn("requires macOS 15.4"),
                remediation: "The MLX engine cannot be kept off the cooperative "
                    + "thread pool before macOS 15.4, so it is not run. "
                    + "Rule-based cleanup is used instead; no action needed on "
                    + "this macOS."
            )
        }
        guard MLXModel.isPresent else {
            return Check(
                name: name,
                status: .warn("\(MLXModel.id) is not downloaded"),
                remediation: "run `\(MLXModel.downloadCommand)` "
                    + "(~\(MLXModel.sizeMB) MB, one time). Until then, "
                    + "formatting falls back to rule-based cleanup."
            )
        }
        // The other half of "can the default engine run": the compiled Metal
        // kernels. Release binaries ship with `mlx.metallib` beside them, but
        // `swift build` cannot compile Metal shaders, so a source build is
        // missing it until the build script has run once — and the only other
        // symptom is one warm-up warning at daemon startup.
        guard MLXRuntime.metallibIsLocatable else {
            return Check(
                name: name,
                status: .warn("the Metal kernel library (mlx.metallib) is missing from this build"),
                remediation: "`swift build` cannot compile Metal shaders; run "
                    + "`\(MLXRuntime.buildCommand)` once to compile it and place "
                    + "it next to the ara binary. Until then, formatting "
                    + "falls back to rule-based cleanup."
            )
        }
        return Check(name: name, status: .ok, remediation: nil)
    }

    /// Reports whether on-device formatting can run, and why not when it cannot.
    ///
    /// The spec's error-handling table says an unavailable Apple Intelligence
    /// should be surfaced "once in `doctor`", and this is the only place it can
    /// be: when the model is unavailable the daemon builds a chain with **no**
    /// local candidate, so there is not even a fall-through line to read. The
    /// symptom otherwise is dictation that is merely filler-stripped, with
    /// nothing anywhere connecting that to a system setting.
    ///
    /// A **warning, never a failure.** The rule-based floor is always present
    /// and the app is fully functional without a language model; `run()` gates
    /// startup on `allOK`, so returning `.fail` here would refuse to start the
    /// daemon on every Mac that has Apple Intelligence switched off — which is
    /// most of them.
    static func checkOnDeviceFormatting() -> Check {
        let name = "on-device formatting"
        let remediation = "System Settings → Apple Intelligence & Siri → turn on. "
            + "Only `engine: \"apple\"` uses this; the default `mlx` engine does "
            + "not, and without either, formatting falls back to rule-based cleanup."
        if #available(macOS 26.0, *) {
            guard let reason = FoundationModelsFormatter.unavailableReason else {
                return Check(name: name, status: .ok, remediation: nil)
            }
            return Check(name: name, status: .warn(reason), remediation: remediation)
        }
        return Check(
            name: name,
            status: .warn("requires macOS 26"),
            remediation: "Rule-based cleanup is used instead; no action needed on this macOS."
        )
    }

    static func checkMicrophone() -> Check {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return Check(name: "microphone", status: .ok, remediation: nil)
        case .notDetermined:
            return Check(
                name: "microphone",
                status: .warn("not yet requested — will prompt on first recording"),
                remediation: "run ara and hold Fn once; macOS will prompt"
            )
        case .denied, .restricted:
            return Check(
                name: "microphone",
                status: .fail("denied"),
                remediation: "System Settings → Privacy & Security → Microphone → enable for your terminal"
            )
        @unknown default:
            return Check(name: "microphone", status: .fail("unknown state"), remediation: nil)
        }
    }

    static func checkAccessibility() -> Check {
        if AXIsProcessTrusted() {
            return Check(name: "accessibility", status: .ok, remediation: nil)
        }
        let parent = parentProcessName() ?? "your terminal"
        return Check(
            name: "accessibility",
            status: .fail("not granted"),
            remediation: "System Settings → Privacy & Security → Accessibility → enable for \(parent)"
        )
    }

    /// macOS routes Fn (🌐) to one of: Do Nothing / Change Input Source / Show Emoji / Start Dictation.
    /// We need "Do Nothing" so Fn is a clean modifier.
    static func checkFnKeyMapping() -> Check {
        let raw = readDefault(domain: "com.apple.HIToolbox", key: "AppleFnUsageType")
        guard let raw, let value = Int(raw) else {
            return Check(
                name: "fn key mapping",
                status: .warn("unset — system default may intercept Fn"),
                remediation: "System Settings → Keyboard → Press 🌐 key to → Do Nothing"
            )
        }
        switch value {
        case 0:
            return Check(name: "fn key mapping", status: .ok, remediation: nil)
        case 1:
            return Check(
                name: "fn key mapping",
                status: .fail("set to Change Input Source"),
                remediation: "System Settings → Keyboard → Press 🌐 key to → Do Nothing"
            )
        case 2:
            return Check(
                name: "fn key mapping",
                status: .fail("set to Show Emoji & Symbols"),
                remediation: "System Settings → Keyboard → Press 🌐 key to → Do Nothing"
            )
        case 3:
            return Check(
                name: "fn key mapping",
                status: .fail("set to Start Dictation"),
                remediation: "System Settings → Keyboard → Press 🌐 key to → Do Nothing"
            )
        default:
            return Check(
                name: "fn key mapping",
                status: .warn("unknown value \(value)"),
                remediation: "System Settings → Keyboard → Press 🌐 key to → Do Nothing"
            )
        }
    }

    private static func readDefault(domain: String, key: String) -> String? {
        let task = Process()
        task.launchPath = "/usr/bin/defaults"
        task.arguments = ["read", domain, key]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parentProcessName() -> String? {
        let ppid = getppid()
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-p", String(ppid), "-o", "comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        return (s as NSString).lastPathComponent
    }

    public static func print(_ checks: [Check]) {
        Swift.print(rendered(checks))
    }

    /// The report as one string, exactly what `print` emits — a second
    /// consumer (the menu's "Run Diagnostics…" alert) needs the same text in
    /// a window instead of a terminal, and two renderers would drift.
    public static func rendered(_ checks: [Check]) -> String {
        var lines: [String] = []
        for c in checks {
            let (mark, label): (String, String) = {
                switch c.status {
                case .ok: return ("✓", "ok")
                case .warn(let msg): return ("!", msg)
                case .fail(let msg): return ("✗", msg)
                }
            }()
            lines.append("\(mark) \(c.name): \(label)")
            if let r = c.remediation {
                lines.append("    → \(r)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// True if no checks are in a hard-fail state. Warnings don't block.
    public static func allOK(_ checks: [Check]) -> Bool {
        checks.allSatisfy {
            if case .fail = $0.status { return false }
            return true
        }
    }

    /// True only if every check passed cleanly (used by `ara doctor` exit code).
    static func allClean(_ checks: [Check]) -> Bool {
        checks.allSatisfy {
            if case .ok = $0.status { return true }
            return false
        }
    }
}
