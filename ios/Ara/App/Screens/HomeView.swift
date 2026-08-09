import SwiftUI
import UIKit

/// The dictation card, which is the whole of Home: what the relay is doing,
/// the one switch that starts and stops it, and the two honest footnotes that
/// go with keeping a microphone session open.
struct HomeView: View {
    @ObservedObject var coordinator: DictationCoordinator

    /// Mirrors `coordinator.isArmed` rather than binding through it: `arm()`
    /// can refuse (no App Group, no mic), and a `Toggle` that flips anyway
    /// would lie about the state of the microphone.
    @State private var armed = false
    @State private var isUnlocked = StoreGate.isUnlocked
    @State private var showPaywall = false
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    stateCard
                    if !Relay.available {
                        provisioningWarning
                    } else if !isUnlocked {
                        lockedToggle
                    } else if !Relay.keyboardEverSeen {
                        fullAccessAction
                    } else {
                        armToggle
                    }
                    indicatorNote
                    batteryNote
                    PlaygroundField(caption: "Try it here",
                                    prompt: "Switch to the Ara keyboard and dictate")
                }
                .padding(22)
            }
            .background(Theme.background)
            .navigationTitle("Ara")
            .toolbarBackground(Theme.background, for: .navigationBar)
        }
        .onAppear {
            armed = coordinator.isArmed
            isUnlocked = StoreGate.isUnlocked
        }
        .onChange(of: coordinator.isArmed) { _, value in armed = value }
        .sheet(isPresented: $showPaywall, onDismiss: {
            isUnlocked = StoreGate.isUnlocked
        }) { PaywallView() }
    }

    // MARK: - Pieces

    /// The hero: the brand waveform inside a breathing halo. The one motion
    /// rule from the design system — movement means the microphone is open —
    /// is enforced here: bars animate only while recording, the halo breathes
    /// only while the mic session is live, and idle is perfectly still.
    private var stateCard: some View {
        VStack(spacing: 14) {
            ZStack {
                // The halo breathes on opacity and scale only. Animating a
                // shadow's radius instead — which is what this used to do —
                // re-renders an offscreen pass every frame for as long as the
                // mic is open, which is precisely the whole time the user is
                // looking at it.
                Circle()
                    .fill(RadialGradient(
                        colors: [Theme.accentFill.opacity(0.30),
                                 Theme.accentFill.opacity(0)],
                        center: .center, startRadius: 40, endRadius: 108))
                    .frame(width: 216, height: 216)
                    .opacity(micIsLive ? (reduceMotion ? 0.72 : (breathe ? 1 : 0.55)) : 0)
                    .scaleEffect(reduceMotion ? 1 : (breathe ? 1.06 : 1))
                    .animation(micIsLive && !reduceMotion
                               ? .easeInOut(duration: 2).repeatForever(autoreverses: true)
                               : .easeOut(duration: 0.4),
                               value: breathe)
                    .animation(.easeOut(duration: 0.4), value: micIsLive)
                Circle()
                    .stroke(Theme.accentFill.opacity(0.25), lineWidth: 1)
                    .background {
                        Circle().fill(Theme.accentFill.opacity(micIsLive ? 0.05 : 0))
                    }
                    .frame(width: 148, height: 148)
                WaveformView(bars: 5, barWidth: 7, spacing: 6, maxHeight: 72,
                             animating: coordinator.state == .recording && !reduceMotion,
                             color: micIsLive ? Theme.accentFill : Theme.textSecondary,
                             // Idle bars are grey, and a grey glow is just a
                             // smudge. The glow belongs to the live state.
                             glow: micIsLive)
            }
            .padding(.top, 10)
            .onAppear { breathe = micIsLive }
            .onChange(of: micIsLive) { _, live in breathe = live }
            Text(stateHeadline)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(stateColor)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: stateHeadline)
            Text(stateDetail)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Theme.card, in: RoundedRectangle(
            cornerRadius: Theme.heroCornerRadius, style: .continuous))
    }

    private var micIsLive: Bool {
        switch coordinator.state {
        case .armed, .recording, .transcribing: return true
        case .idle, .error: return false
        }
    }

    private var armToggle: some View {
        Toggle(isOn: $armed) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Keep Ara ready")
                    .foregroundStyle(Theme.textPrimary)
                Text("The orange privacy indicator stays visible while the mic "
                     + "session is open.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .tint(Theme.accent)
        .padding(16)
        .background(Theme.surface,
                    in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .disabled(coordinator.isTransitioning)
        .onChange(of: armed) { _, isOn in
            guard isOn != coordinator.isArmed else { return }
            Task {
                if isOn { await coordinator.arm() } else { await coordinator.disarm() }
                // Snap back if the coordinator refused.
                armed = coordinator.isArmed
            }
        }
    }

    private var lockedToggle: some View {
        Button { showPaywall = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keep Ara ready")
                        .foregroundStyle(Theme.textPrimary)
                    Text("Ara dictation and Clean unlock for $49.99 once. "
                         + "The free keyboard still types normally.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(16)
            .background(Theme.surface,
                        in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        }
        .buttonStyle(.plain)
    }

    private var indicatorNote: some View {
        Label {
            Text("You can always see when Ara is listening — the orange dot in "
                 + "the status bar is on for the whole time the microphone is "
                 + "open. iOS makes it impossible to hide, and we wouldn't "
                 + "want to.")
        } icon: {
            Circle().fill(Theme.micIndicator).frame(width: 8, height: 8)
                .padding(.top, 5)
        }
        .font(.footnote)
        .foregroundStyle(Theme.textSecondary)
    }

    private var batteryNote: some View {
        Text("Staying ready costs battery: the audio session runs continuously "
             + "so iOS does not suspend Ara, which is the only way a keyboard "
             + "can hand off recording. Turn it off when you are done "
             + "dictating.")
            .font(.footnote)
            .foregroundStyle(Theme.textSecondary)
    }

    private var provisioningWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("App group unavailable", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
            Text("Ara and its keyboard cannot reach each other, so dictation is "
                 + "off. This is a provisioning problem — reinstall Ara.")
                .font(.footnote)
        }
        .foregroundStyle(Theme.danger)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.surface,
                    in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }

    private var fullAccessAction: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        } label: {
            Label("Allow Full Access", systemImage: "keyboard.badge.ellipsis")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.surface, in: RoundedRectangle(
                    cornerRadius: Theme.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }


    // MARK: - State rendering

    private var stateHeadline: String {
        if !Relay.available { return "The keyboard can't reach Ara" }
        if !isUnlocked { return "Dictation is locked" }
        if !Relay.keyboardEverSeen { return "Keyboard is limited" }
        if coordinator.isTransitioning { return "Starting…" }
        switch coordinator.state {
        case .idle: return "Ara is off"
        case .armed: return "Listening for you"
        case .recording: return "Recording"
        case .transcribing: return "Transcribing"
        case .error: return "Ara needs attention"
        }
    }

    private var stateDetail: String {
        if !Relay.available {
            return "The shared App Group is missing. Dictation cannot work until that link is restored."
        }
        if !isUnlocked {
            return "The Ara keyboard types free, forever. Dictation and Clean unlock with one purchase — no subscription."
        }
        if !Relay.keyboardEverSeen {
            return "Without Full Access, the Ara keyboard still types like any keyboard. Dictation and Clean need the on-device link to this app."
        }
        switch coordinator.state {
        case .idle:
            return "The microphone is released. Turn on Keep Ara ready when "
                + "you want to dictate from the keyboard."
        case .armed:
            return "Dictate from the Ara keyboard in any app. Everything is "
                + "transcribed on this phone."
        case .recording:
            return "Tap the amber mic again when your thought is complete."
        case .transcribing:
            return "Your voice is becoming text. Nothing is leaving this phone."
        case .error(let message):
            return message
        }
    }

    private var stateColor: Color {
        if !Relay.available { return Theme.danger }
        if !isUnlocked || !Relay.keyboardEverSeen { return Theme.textSecondary }
        switch coordinator.state {
        case .error: return Theme.danger
        case .armed, .recording, .transcribing: return Theme.accent
        case .idle: return Theme.textSecondary
        }
    }
}
