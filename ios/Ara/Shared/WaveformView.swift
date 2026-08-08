import SwiftUI

/// The brand element: asymmetric amber bars, alive only when audio could be.
/// One rule keeps it honest — movement means the microphone is open — so the
/// animation runs only when `animating` is true, and everything else in the
/// product stays still. Deterministic per-bar phases (no randomness at render
/// time) keep the motion organic without ever looking glitchy.
struct WaveformView: View {
    /// Bar count; odd numbers read best (a peak with shoulders).
    var bars: Int = 5
    var barWidth: CGFloat = 6
    var spacing: CGFloat = 5
    var maxHeight: CGFloat = 64
    /// 0…1 — scales amplitude; feed real audio level when there is one.
    var level: CGFloat = 1
    var animating: Bool = true
    var color: Color = Theme.accentFill
    var glow: Bool = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animating)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: spacing) {
                ForEach(0..<bars, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(color)
                        .frame(width: barWidth,
                               height: height(bar: index, time: animating ? t : 0))
                        .shadow(color: glow ? color.opacity(0.45) : .clear,
                                radius: glow ? barWidth * 1.6 : 0)
                }
            }
            .animation(.easeOut(duration: 0.12), value: animating)
        }
        .frame(height: maxHeight)
    }

    /// Three incommensurate sine frequencies per bar — repeats visually never,
    /// costs nothing, and stays identical across processes (no shared seed
    /// needed between app and keyboard).
    private func height(bar: Int, time: Double) -> CGFloat {
        let phase = Double(bar) * 1.7
        let profile = 1 - abs(Double(bar) - Double(bars - 1) / 2) / Double(bars)
        let wave = animatedAmplitude(phase: phase, time: time)
        let idle = 0.22 + 0.5 * profile
        let amplitude = time == 0 ? idle : (0.25 + 0.75 * wave) * (0.4 + 0.6 * profile)
        return max(barWidth, maxHeight * amplitude * max(0.15, level))
    }

    private func animatedAmplitude(phase: Double, time: Double) -> Double {
        let a = sin(time * 6.1 + phase)
        let b = sin(time * 3.3 + phase * 2.1)
        let c = sin(time * 9.7 + phase * 0.7)
        return (a + b + c + 3) / 6
    }
}
