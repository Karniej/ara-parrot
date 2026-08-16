import AppKit
import SwiftUI

/// Borderless, click-through pill near the bottom of the active screen.
/// Driven by the daemon's hotkey + transcription lifecycle.
@MainActor
public final class RecordingOverlay {
    public enum State: Equatable {
        case hidden
        /// Capturing audio. `note` is a quiet second line under the waveform,
        /// used by the warm-up ladder to say once — on the first press only —
        /// that this utterance is going through the fast stand-in model
        /// (`WarmupLadder`). It is `nil` for every ordinary recording, and
        /// `nil` again for every press after the first, because repeating it
        /// would be the friction the ladder exists to remove.
        case recording(note: String?)
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
        case warmingUp(title: String, detail: String?)
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
        if case .recording = state {
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
        if case .error = state { hide(after: 1.6) }
    }

    /// Hide after `seconds`, unless something newer has been shown first.
    ///
    /// The token check is the whole point: a dictation started inside the
    /// delay must not have its pill yanked off screen by a hide that was
    /// scheduled for a message nobody is looking at any more. `.error` has
    /// always self-hidden this way; the startup card uses the same mechanism
    /// to clear itself once the daemon is ready, rather than owning a second
    /// timer with the same bug to get wrong.
    public func hide(after seconds: Double) {
        let token = showToken
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.showToken == token else { return }
            self.hide()
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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 84),
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
        // Without this the panel above is decoration. `NSHostingView` reports
        // an intrinsic content size by default, and as a window's contentView
        // that size wins: measured, a panel built at 520x84 came up 362x44 —
        // the pill's own size for whatever it happened to be showing.
        //
        // Two things follow, and both were reported from the field. A pill
        // 44pt tall clips the two-line warm-up states, which want 54. And
        // because the resize races the state change, the new text is laid out
        // against the *old*, smaller width — "no audio captured" came out as
        // three lines with "captured" broken across two of them, which needs a
        // proposed width near sixty points.
        //
        // Emptying `sizingOptions` gives the panel its size back. The pill
        // hugs its own content and centres inside, which is what it looked
        // like all along when the race happened to go the other way; the panel
        // is transparent and click-through, so the spare room costs nothing.
        // `OverlayVisualCheck` pins both halves: that every message fits
        // 520x84, and that the live panel actually proposes it.
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: panel.frame.size)
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

/// Ara's one accent — a warm amber, used by the waveform and by every "this is
/// working" line, so the pill never shows two competing hues. The error state's
/// red is the single tone allowed to mean something else.
///
/// Deliberately not blue: a cool blue on near-black is the default every
/// AI-adjacent menu-bar app arrives at, and amber ties the overlay to the
/// recording glyph in the menu bar, which is already warm.
private let accent = Color(red: 255/255.0, green: 190/255.0, blue: 118/255.0)
private let errorTone = Color(red: 255/255.0, green: 163/255.0, blue: 150/255.0)
/// Near-black rather than the old charcoal, with a hairline edge so the pill
/// still has a shape against a dark wallpaper.
private let pillFill = Color(red: 10/255.0, green: 10/255.0, blue: 11/255.0)

/// Internal rather than private so `OverlayVisualCheck` can render it offscreen
/// at the panel's own proposed size. Its layout is not reasoned about well —
/// a field screenshot showed this view's text overflowing its own background —
/// and rendering it is the only way to check without a screen.
struct OverlayPill: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(
                // A continuous rounded rectangle, not a capsule: a capsule
                // around two lines of text bows out at the ends and wastes the
                // width the second line needs. At the one-line height this is
                // within two points of a capsule anyway.
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(pillFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                    )
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
        case .hidden, .recording(nil):
            Waveform(levels: model.levels)
                .frame(width: 54, height: 22)
        case .recording(let note?):
            // The waveform keeps the headline slot — this is a recording, not
            // a status message, and the bars are what say the audio is going
            // in. The note takes `warmingUp`'s quiet second line, at the same
            // size and opacity, because it is the same kind of sentence: the
            // particular, one size down from what is happening.
            HStack(spacing: 11) {
                Waveform(levels: model.levels)
                    .frame(width: 54, height: 22)
                Text(note)
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .frame(maxWidth: 330, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: true)
            }
        case .transcribing:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.8)
                .tint(accent)
                .frame(width: 54, height: 22)
        case .warmingUp(let title, let detail):
            // Two lines, because one was the whole problem: the Neural Engine
            // wait needs to say what it is *and* that it is finite, and a
            // single line long enough to carry both was truncated by the pill
            // that had to hold it. The headline answers "what is happening",
            // the quieter line answers "how long, and will it happen again".
            //
            // The spinner answers the third question a multi-minute wait
            // raises — "is this still going?" — which no wording can.
            HStack(spacing: 11) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.72)
                    .tint(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.5))
                    }
                }
                // Bounded so a long model id wraps instead of stretching the
                // pill off the edge of a small screen; `fixedSize` then lets it
                // take the second line it needs rather than truncating.
                .frame(maxWidth: 330, alignment: .leading)
                .fixedSize(horizontal: true, vertical: true)
            }
        case .error(let message):
            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(errorTone)
                .frame(maxWidth: 330, alignment: .leading)
                .fixedSize(horizontal: true, vertical: true)
                .frame(minHeight: 22)
        }
    }
}

private struct Waveform: View {
    let levels: [Float]
    private let color = accent

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
