import Foundation

/// The wire between the keyboard (UI) and the app (ears): App Group defaults
/// for scalar state, one JSON file in the group container for transcripts,
/// Darwin notifications for sub-second cross-process pings.
///
/// Spike lessons, now invariants:
/// - `UserDefaults(suiteName:)` never errors when provisioning is broken; the
///   container URL nil-check is the only honest detector (`Relay.available`).
/// - Every timestamp is wall clock; older than `staleAfter` means the other
///   side is gone.
/// - The keyboard never blocks on the relay: reads are snapshots, updates
///   arrive via Darwin observer → main-queue hop.
enum Relay {
    static let group = "group.com.silpho.ara"
    /// Heartbeats older than this mean the app-side recorder is suspended or
    /// dead, whatever the state key claims.
    static let staleAfter: TimeInterval = 3

    /// False exactly when provisioning did not grant the App Group.
    static var available: Bool { containerURL != nil }

    static var containerURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    static var defaults: UserDefaults? { UserDefaults(suiteName: group) }

    enum Key {
        static let command = "relay.command"
        static let commandSeq = "relay.command.seq"
        static let state = "relay.state"
        static let heartbeatStamp = "relay.heartbeat.stamp"
        static let heartbeatFrames = "relay.heartbeat.frames"
        static let transcriptSeq = "relay.transcript.seq"
        static let entitled = "store.entitled"
        static let haptics = "settings.haptics"
        static let intensity = "settings.intensity"
        static let appLaunched = "app.launched"
    }

    /// Darwin notification names. Darwin notifications carry no payload — the
    /// name is the whole message; receivers read the defaults/file for data.
    enum Note {
        static let command = "com.silpho.ara.relay.command"
        static let state = "com.silpho.ara.relay.state"
        static let transcript = "com.silpho.ara.relay.transcript"
    }
}

enum RelayCommand: String, Sendable {
    case start, stop, cancel
}

enum RelayState: Sendable, Equatable {
    case idle
    case armed
    case recording
    case transcribing
    case error(String)

    var encoded: String {
        switch self {
        case .idle: return "idle"
        case .armed: return "armed"
        case .recording: return "recording"
        case .transcribing: return "transcribing"
        case .error(let message): return "error:\(message)"
        }
    }

    init(encoded: String) {
        switch encoded {
        case "idle": self = .idle
        case "armed": self = .armed
        case "recording": self = .recording
        case "transcribing": self = .transcribing
        default:
            if encoded.hasPrefix("error:") {
                self = .error(String(encoded.dropFirst("error:".count)))
            } else {
                self = .idle
            }
        }
    }
}

/// One dictation utterance's rolling transcript. `seq` increments on every
/// update so the keyboard can cheaply skip stale reads; `isFinal` flips once,
/// after which `text` is the finished, dictionary-corrected utterance.
struct RelayTranscript: Codable, Sendable, Equatable {
    var seq: Int
    var text: String
    var isFinal: Bool

    static var fileURL: URL? {
        Relay.containerURL?.appendingPathComponent("relay-transcript.json")
    }

    static func load() -> RelayTranscript? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RelayTranscript.self, from: data)
    }

    func write() {
        guard let url = Self.fileURL, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Post/observe Darwin notifications. Observation tokens deregister on
/// deinit — keyboard extensions come and go; leaked observers in a process
/// that iOS keeps alive across invocations are a jetsam vector.
final class DarwinNotifier: @unchecked Sendable {
    private var observedNames: [String] = []
    private let handlerLock = NSLock()
    private var handlers: [String: @Sendable () -> Void] = [:]

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString), nil, nil, true)
    }

    func observe(_ name: String, handler: @escaping @Sendable () -> Void) {
        handlerLock.withLock {
            handlers[name] = handler
            observedNames.append(name)
        }
        let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), observer,
            { _, observer, name, _, _ in
                guard let observer, let name else { return }
                let notifier = Unmanaged<DarwinNotifier>
                    .fromOpaque(observer).takeUnretainedValue()
                notifier.fire(name.rawValue as String)
            },
            name as CFString, nil, .deliverImmediately)
    }

    private func fire(_ name: String) {
        let handler = handlerLock.withLock { handlers[name] }
        handler?()
    }

    deinit {
        let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), observer)
    }
}

/// Keyboard-side view of the relay. Snapshot reads only — never blocks.
struct RelayClient {
    /// Nil when the App Group is unavailable (provisioning) — callers surface
    /// that, not work around it.
    static func send(_ command: RelayCommand) {
        guard let defaults = Relay.defaults else { return }
        defaults.set(command.rawValue, forKey: Relay.Key.command)
        defaults.set(defaults.integer(forKey: Relay.Key.commandSeq) + 1,
                     forKey: Relay.Key.commandSeq)
        DarwinNotifier.post(Relay.Note.command)
    }

    static func state() -> RelayState {
        guard let defaults = Relay.defaults,
              let raw = defaults.string(forKey: Relay.Key.state) else { return .idle }
        return RelayState(encoded: raw)
    }

    /// True when the app-side recorder posted a heartbeat within `staleAfter`.
    static func appIsLive() -> Bool {
        guard let defaults = Relay.defaults else { return false }
        let stamp = defaults.double(forKey: Relay.Key.heartbeatStamp)
        return stamp > 0
            && Date().timeIntervalSince1970 - stamp < Relay.staleAfter
    }

    static func entitled() -> Bool {
        Relay.defaults?.bool(forKey: Relay.Key.entitled) ?? false
    }
}

/// App-side publisher. All writes stamp the wall clock.
struct RelayPublisher {
    static func publish(_ state: RelayState) {
        Relay.defaults?.set(state.encoded, forKey: Relay.Key.state)
        DarwinNotifier.post(Relay.Note.state)
    }

    static func heartbeat(frames: Int) {
        guard let defaults = Relay.defaults else { return }
        defaults.set(frames, forKey: Relay.Key.heartbeatFrames)
        defaults.set(Date().timeIntervalSince1970, forKey: Relay.Key.heartbeatStamp)
    }

    static func publish(_ transcript: RelayTranscript) {
        transcript.write()
        Relay.defaults?.set(transcript.seq, forKey: Relay.Key.transcriptSeq)
        DarwinNotifier.post(Relay.Note.transcript)
    }

    static func pendingCommand() -> RelayCommand? {
        guard let defaults = Relay.defaults,
              let raw = defaults.string(forKey: Relay.Key.command) else { return nil }
        return RelayCommand(rawValue: raw)
    }

    static func clearCommand() {
        Relay.defaults?.removeObject(forKey: Relay.Key.command)
    }
}
