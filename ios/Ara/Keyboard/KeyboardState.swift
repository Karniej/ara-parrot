import SwiftUI
import UIKit

/// The alternates popup, fully resolved: the state object computes its
/// geometry so slide-to-select is a division rather than a hit test against
/// views the gesture cannot see.
struct KeyPopup: Equatable {
    let keyID: String
    let items: [String]
    var selection: Int
    /// Top-left corner in the keyboard coordinate space.
    let origin: CGPoint
    let cellSize: CGSize

    var width: CGFloat { cellSize.width * CGFloat(items.count) }
}

/// Everything the key grid does between a finger going down and text arriving
/// in the host: shift, layers, the alternates popup, backspace repeat, and
/// snippet expansion. Views stay declarative; this is the only mutable state.
@MainActor
final class KeyboardState: ObservableObject {
    enum Shift: Equatable {
        case off
        /// Consumed by the next inserted character.
        case oneShot
        case locked
    }

    @Published private(set) var layer: KeyboardLayer = .letters
    @Published private(set) var shift: Shift = .off
    @Published private(set) var popup: KeyPopup?

    private let bridge: KeyboardBridge
    private var popupTask: Task<Void, Never>?
    private var repeatTask: Task<Void, Never>?
    private var lastShiftTap: Date?
    private lazy var impact = UIImpactFeedbackGenerator(style: .light)

    /// Boundary keys are where a snippet trigger can end. Kept in sync with
    /// the design doc's "space / return / punctuation" list.
    private static let boundaryCharacters: Set<String> = [".", ",", "!", "?"]
    private static let sentenceTerminators: Set<Character> = [".", "!", "?"]
    private static let doubleTapWindow: TimeInterval = 0.35
    private static let popupDelay: Duration = .milliseconds(450)

    init(bridge: KeyboardBridge) {
        self.bridge = bridge
    }

    // MARK: - Appearance lifecycle

    /// Called when the keyboard comes back on screen. The extension process
    /// survives between appearances, so every piece of state that could have
    /// gone stale — or grown — is re-derived here rather than kept.
    func activate() {
        cancelTimers()
        popup = nil
        layer = .letters
        shift = .off
        refreshAutoCapitalization()
    }

    func deactivate() {
        cancelTimers()
        popup = nil
    }

    /// The host moved the caret or changed the text under us.
    func hostChangedText() {
        refreshAutoCapitalization()
    }

    // MARK: - Key gestures

    /// One finger's worth of contact: `pressBegan` on touch down, `pressMoved`
    /// for every drag update (which is what drives popup selection), and
    /// `pressEnded` on lift, which is where most keys actually type.
    func pressBegan(_ key: Key, anchor: CGRect, containerWidth: CGFloat) {
        if bridge.hapticsEnabled {
            impact.impactOccurred()
            impact.prepare()
        }
        cancelTimers()
        popup = nil
        switch key.action {
        case .backspace:
            // Backspace is the one key that fires on touch down: the repeat
            // has to start from the first deletion, not the second.
            deleteBackward()
            startBackspaceRepeat()
        case .character where !key.alternates.isEmpty:
            schedulePopup(for: key, anchor: anchor, containerWidth: containerWidth)
        default:
            break
        }
    }

    func pressMoved(to location: CGPoint) {
        guard var open = popup else { return }
        let offset = location.x - open.origin.x
        let index = Int((offset / open.cellSize.width).rounded(.down))
        let clamped = min(max(index, 0), open.items.count - 1)
        guard clamped != open.selection else { return }
        open.selection = clamped
        popup = open
        if bridge.hapticsEnabled { impact.impactOccurred(intensity: 0.6) }
    }

    func pressEnded(_ key: Key) {
        cancelTimers()
        if let open = popup, open.keyID == key.id {
            popup = nil
            type(open.items[open.selection])
            return
        }
        popup = nil
        fire(key)
    }

    // MARK: - Key actions

    private func fire(_ key: Key) {
        switch key.action {
        case .character(let base):
            if Self.boundaryCharacters.contains(base) { expandSnippet() }
            type(shift == .off ? base : base.uppercased())
        case .shift:
            toggleShift()
        case .backspace:
            break
        case .layer(let target):
            layer = target
        case .globe:
            bridge.advanceToNextInputMode()
        case .space:
            expandSnippet()
            type(" ")
            // Convention: a space ends the excursion into the number plane.
            if layer != .letters { layer = .letters }
        case .newline:
            expandSnippet()
            type("\n")
        }
    }

    private func type(_ text: String) {
        bridge.insert(text)
        if shift == .oneShot { shift = .off }
        refreshAutoCapitalization()
    }

    private func deleteBackward() {
        bridge.deleteBackward()
        refreshAutoCapitalization()
    }

    // MARK: - Shift

    private func toggleShift() {
        let now = Date()
        if let last = lastShiftTap,
           now.timeIntervalSince(last) < Self.doubleTapWindow,
           shift != .locked
        {
            shift = .locked
        } else {
            shift = shift == .off ? .oneShot : .off
        }
        lastShiftTap = now
    }

    /// Re-derives the one-shot shift from what is already in the field. This
    /// doubles as the auto-downshift: after a letter the context no longer
    /// looks like a sentence start, so the shift falls off by itself.
    private func refreshAutoCapitalization() {
        guard shift != .locked else { return }
        let context = bridge.contextBeforeInput
        switch bridge.autocapitalizationType {
        case .none:
            shift = .off
        case .allCharacters:
            shift = .locked
        case .words:
            shift = Self.isAtWordStart(context) ? .oneShot : .off
        default:
            shift = Self.isAtSentenceStart(context) ? .oneShot : .off
        }
    }

    /// True at the very start of a field, after a newline, or after a
    /// sentence terminator that has been followed by a space — the space
    /// matters, or "e.g" would capitalise mid-abbreviation.
    static func isAtSentenceStart(_ context: String?) -> Bool {
        guard let context, !context.isEmpty else { return true }
        var sawSpace = false
        for character in context.reversed() {
            if character.isNewline { return true }
            if character.isWhitespace {
                sawSpace = true
                continue
            }
            return sawSpace && sentenceTerminators.contains(character)
        }
        return true
    }

    static func isAtWordStart(_ context: String?) -> Bool {
        guard let last = context?.last else { return true }
        return last.isWhitespace
    }

    // MARK: - Snippets

    /// Replaces the trailing trigger phrase with its expansion, if there is
    /// one, before the boundary character is inserted. Triggers are phrases
    /// ("insert my scheduling link"), so this scans trailing word suffixes
    /// longest-first — a single-word scan would never fire on real snippet
    /// files. Deterministic and offline: `deleteBackward()` once per
    /// character of the matched phrase, then the expansion verbatim.
    private func expandSnippet() {
        guard let context = bridge.contextBeforeInput else { return }
        let words = context.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return }
        for take in stride(from: min(6, words.count), through: 1, by: -1) {
            let phrase = words.suffix(take).joined(separator: " ")
            guard let expansion = bridge.snippets.expansion(for: phrase) else { continue }
            // Delete what is actually in the document, whitespace-as-typed
            // included: the split's Substrings index into `context`, so the
            // first matched word's own startIndex bounds the typed run.
            let start = words[words.count - take].startIndex
            let typedLength = context.distance(from: start, to: context.endIndex)
            for _ in 0..<typedLength { bridge.deleteBackward() }
            bridge.insert(expansion)
            return
        }
    }

    // MARK: - Popup

    private func schedulePopup(for key: Key, anchor: CGRect,
                               containerWidth: CGFloat)
    {
        popupTask = Task { [weak self] in
            try? await Task.sleep(for: Self.popupDelay)
            guard !Task.isCancelled else { return }
            self?.openPopup(for: key, anchor: anchor, containerWidth: containerWidth)
        }
    }

    private func openPopup(for key: Key, anchor: CGRect, containerWidth: CGFloat) {
        guard anchor != .zero else { return }
        let items = key.alternates.map { shift == .off ? $0 : $0.uppercased() }
        guard !items.isEmpty else { return }
        let cell = CGSize(width: anchor.width + 8, height: anchor.height)
        let total = cell.width * CGFloat(items.count)
        let lower = KeyboardMetrics.edgeInset
        let upper = max(lower, containerWidth - total - KeyboardMetrics.edgeInset)
        let x = min(max(anchor.midX - total / 2, lower), upper)
        // Clamped rather than allowed to overflow: an input view clipped by
        // the host would swallow the top row's popups entirely.
        let y = max(2, anchor.minY - cell.height - 6)
        let selection = min(max(Int(((anchor.midX - x) / cell.width).rounded(.down)), 0),
                            items.count - 1)
        popup = KeyPopup(keyID: key.id, items: items, selection: selection,
                         origin: CGPoint(x: x, y: y), cellSize: cell)
        if bridge.hapticsEnabled { impact.impactOccurred(intensity: 0.6) }
    }

    // MARK: - Backspace repeat

    /// Holds delete: half a second of grace, then one deletion per 100 ms
    /// accelerating to 40 ms. The run is bounded because a gesture the system
    /// cancels never delivers its `onEnded`, and an unbounded delete loop is
    /// data loss.
    private func startBackspaceRepeat() {
        repeatTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
                var interval = 100
                for _ in 0..<400 {
                    guard let self else { return }
                    self.deleteBackward()
                    try await Task.sleep(for: .milliseconds(interval))
                    interval = max(40, interval - 6)
                }
            } catch {
                // Cancellation is the normal exit: the finger came up.
            }
        }
    }

    private func cancelTimers() {
        popupTask?.cancel()
        popupTask = nil
        repeatTask?.cancel()
        repeatTask = nil
    }

    // MARK: - Labels

    func displayText(for base: String) -> String {
        shift == .off ? base : base.uppercased()
    }

    var returnLabel: String {
        switch bridge.returnKeyType {
        case .go: return "go"
        case .google, .search, .yahoo: return "search"
        case .join: return "join"
        case .next: return "next"
        case .route: return "route"
        case .send: return "send"
        case .done: return "done"
        case .continue: return "continue"
        default: return "return"
        }
    }
}
