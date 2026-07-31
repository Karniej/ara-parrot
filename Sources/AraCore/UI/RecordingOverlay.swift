import AppKit
import SwiftUI

/// Borderless, click-through pill near the bottom of the active screen.
/// Driven by the daemon's hotkey + transcription lifecycle.
@MainActor
public final class RecordingOverlay {
    public enum State: Equatable {
        case hidden
        case recording
        case transcribing
        /// The daemon is not ready to dictate yet, and this is what it is
        /// doing about it — "downloading whisper-large-v3-turbo… 45%". Shown
        /// when the hotkey is pressed during warm-up, in place of the
        /// recording the press cannot start; the sentences come from
        /// `WarmupStatus`.
        ///
        /// Like `.recording` and unlike `.error`, this one is hidden by the
        /// lifecycle that raised it — the key release — so it does not
        /// self-hide. A user holding the key through a two-minute download
        /// should keep seeing the number move.
        case warmingUp(String)
        /// A short message in place of the waveform — "no microphone". Unlike
        /// the other states, which the daemon's lifecycle hides, this one has
        /// no "release the key" moment guaranteed to follow, so it hides
        /// itself after a beat (unless a newer state supersedes it first).
        case error(String)
    }

    private var window: NSPanel?
    private let model = OverlayModel()
    /// Bumped on every show/hide; the error state's auto-hide fires only if
    /// its token is still current, so a recording that starts inside the
    /// error's lifetime is never yanked off screen.
    private var showToken = 0

    public init() {}

    public func show(_ state: State) {
        ensureWindow()
        showToken += 1
        if state == .recording {
            model.resetLevels()
        }
        guard let window else { return }
        let needsAppear = !window.isVisible
        if needsAppear {
            positionAtBottomCenter(window)
            window.orderFrontRegardless()
            // Defer the state change so SwiftUI lays out in the .hidden style
            // first, then animates to the visible style on the next runloop tick.
            //
            // Token-guarded, because the deferral opens a window in which a
            // *newer* state can be applied directly (the panel is visible from
            // `orderFrontRegardless` onwards, so the next `show` takes the
            // other branch) and then be overwritten by this stale one. Rare
            // before warm-up status existed — nothing repainted a pill twice
            // in a runloop turn — and now reachable, since a download's
            // percentage can tick while the pill is appearing.
            let token = showToken
            DispatchQueue.main.async { [weak self, model] in
                guard let self, self.showToken == token else { return }
                model.state = state
            }
        } else {
            model.state = state
        }
        if case .error = state {
            let token = showToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self, self.showToken == token else { return }
                self.hide()
            }
        }
    }

    public func hide() {
        showToken += 1
        model.state = .hidden
        // Let the SwiftUI scale+fade animation play out before yanking the
        // window — otherwise it just pops away.
        let window = self.window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            window?.orderOut(nil)
        }
    }

    /// Push a new audio level (0…~1). Safe to call from any thread.
    public nonisolated func pushLevel(_ level: Float) {
        Task { @MainActor in
            self.model.pushLevel(level)
        }
    }

    private func ensureWindow() {
        if window != nil { return }
        // Wider than the waveform pill needs: the capsule hugs its content
        // and the rest of the panel is clear and click-through, so the extra
        // width is invisible — it only gives the text states room to render.
        // Sized for the longest of them, a warm-up line carrying a model id
        // and a percentage ("downloading whisper-large-v3-turbo… 45%"); at
        // 280 that one was clipped by the panel, because `fixedSize` refuses
        // to wrap rather than shrinking to fit.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let host = NSHostingView(rootView: OverlayPill(model: model))
        host.frame = panel.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        window = panel
    }

    private func positionAtBottomCenter(_ window: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = window.frame
        let visible = screen.visibleFrame
        let x = visible.midX - frame.width / 2
        let y = visible.minY + 32
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// Observable state for the SwiftUI pill.
@MainActor
final class OverlayModel: ObservableObject {
    static let barCount = 6
    /// Per-bar height multiplier — center bars peak higher than edge bars.
    private static let envelope: [Float] = [0.55, 0.85, 1.0, 1.0, 0.85, 0.55]

    @Published var state: RecordingOverlay.State = .hidden
    @Published var levels: [Float] = Array(repeating: 0, count: barCount)

    func pushLevel(_ level: Float) {
        let shaped = min(1.0, sqrt(max(0, level)) * 3.4)
        var next = [Float]()
        next.reserveCapacity(Self.barCount)
        for i in 0..<Self.barCount {
            // Small per-bar jitter so the bars don't all move in lockstep.
            let jitter = Float.random(in: 0.78...1.0)
            next.append(shaped * Self.envelope[i] * jitter)
        }
        levels = next
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: Self.barCount)
    }
}

/// The waveform's blue, and by extension the pill's "this is working" colour.
/// Shared so the warm-up line and the bars it replaces read as the same thing
/// happening — the error state's red is the only tone that means otherwise.
private let waveformBlue = Color(red: 181/255.0, green: 209/255.0, blue: 255/255.0)

private struct OverlayPill: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(Color(red: 16/255, green: 18/255, blue: 18/255))
            )
            .scaleEffect(model.state == .hidden ? 0 : 1)
            .animation(
                .timingCurve(0.16, 1, 0.3, 1, duration: 0.3),
                value: model.state
            )
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .hidden, .recording:
            Waveform(levels: model.levels)
                .frame(width: 54, height: 22)
        case .transcribing:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.8)
                .frame(width: 54, height: 22)
        case .warmingUp(let message):
            // The error state's shape — same pill, words instead of bars —
            // in the waveform's own blue, because this is the daemon working
            // rather than the daemon failing. The spinner sits with it: the
            // sentence says what is happening, the spinner says it is still
            // happening, which is the question a two-minute download raises.
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(waveformBlue)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(height: 22)
        case .error(let message):
            // Same pill, words instead of bars; the desaturated red is the
            // waveform blue's tone shifted to "something is wrong".
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(red: 255/255.0, green: 173/255.0, blue: 173/255.0))
                .fixedSize()
                .frame(height: 22)
        }
    }
}

private struct Waveform: View {
    let levels: [Float]
    private let color = waveformBlue

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(color)
                    .frame(width: 2.5)
                    .frame(maxHeight: .infinity)
                    .scaleEffect(y: max(0.10, CGFloat(level)), anchor: .center)
                    .animation(.easeOut(duration: 0.09), value: level)
            }
        }
    }
}
