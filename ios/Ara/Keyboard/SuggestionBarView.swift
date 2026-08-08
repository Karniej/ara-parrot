import SwiftUI

/// The 36 pt top strip: mic key, one status/transcript line, ✨ Clean.
struct SuggestionBarView: View {
    @ObservedObject var bridge: KeyboardBridge
    @ObservedObject var bar: SuggestionBarModel

    var body: some View {
        HStack(spacing: 8) {
            micKey
            if bar.micState == .recording {
                WaveformView(bars: 5, barWidth: 3, spacing: 3, maxHeight: 18,
                             glow: false)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            Text(bar.status ?? "")
                .font(.footnote)
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .truncationMode(bar.statusIsTranscript ? .head : .tail)
                // Instructions are short enough to fit whole on any phone this
                // ships to; shrinking a little beats truncating at all.
                .minimumScaleFactor(bar.statusIsTranscript ? 1 : 0.75)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(nil, value: bar.status)
            cleanKey
        }
        .animation(.spring(duration: 0.3), value: bar.micState)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: KeyboardMetrics.suggestionBarHeight)
        .background(Theme.background)
    }

    /// The hero key: a filled control, not an icon — amber and glowing the
    /// whole time audio is live, which makes it the in-keyboard twin of the
    /// system's orange indicator.
    private var micKey: some View {
        Button(action: { bar.micTapped() }) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(micIsLive ? Theme.accentFill : Theme.surface)
                    .shadow(color: micIsLive ? Theme.accentFill.opacity(0.5) : .clear,
                            radius: 8)
                Image(systemName: micSymbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(micIsLive ? Color.black : micColor)
            }
            .frame(width: 44, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dictate")
    }

    private var micIsLive: Bool {
        bar.micState == .recording || bar.micState == .transcribing
    }

    private var cleanKey: some View {
        Button(action: { bar.cleanTapped() }) {
            Group {
                if bar.isCleaning {
                    ProgressView().controlSize(.small).tint(Theme.accent)
                } else {
                    Text("✨ Clean").font(.footnote.weight(.medium))
                }
            }
            .foregroundStyle(bar.canClean ? Theme.accent : Theme.textSecondary)
            .frame(height: KeyboardMetrics.suggestionBarHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(bar.isCleaning)
        .accessibilityLabel("Clean up text")
    }

    private var micSymbol: String {
        switch bar.micState {
        case .recording: return "stop.fill"
        case .transcribing: return "waveform"
        case .locked: return "mic.slash"
        default: return "mic.fill"
        }
    }

    private var micColor: Color {
        switch bar.micState {
        case .recording: return Theme.accent
        case .transcribing: return Theme.accent
        case .ready: return Theme.textPrimary
        default: return Theme.textSecondary
        }
    }

    private var statusColor: Color {
        bar.micState == .recording ? Theme.textPrimary : Theme.textSecondary
    }
}
