import SwiftUI

/// The 36 pt top strip: mic key, one status/transcript line, ✨ Clean.
struct SuggestionBarView: View {
    @ObservedObject var bridge: KeyboardBridge
    @ObservedObject var bar: SuggestionBarModel

    var body: some View {
        HStack(spacing: 8) {
            micKey
            Text(bar.status ?? "")
                .font(.footnote)
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(nil, value: bar.status)
            cleanKey
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: KeyboardMetrics.suggestionBarHeight)
        .background(Theme.background)
    }

    private var micKey: some View {
        Button(action: { bar.micTapped() }) {
            Image(systemName: micSymbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(micColor)
                .symbolEffect(.pulse, isActive: bar.micState == .recording)
                .frame(width: 44, height: KeyboardMetrics.suggestionBarHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dictate")
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
        case .recording: return "stop.circle.fill"
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
