import SwiftUI

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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !Relay.available { provisioningWarning }
                    stateCard
                    if isUnlocked { armToggle } else { lockedToggle }
                    indicatorNote
                    batteryNote
                    PlaygroundField(caption: "Try it here",
                                    prompt: "Switch to the Ara keyboard and dictate")
                }
                .padding(20)
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
        .sheet(isPresented: $showPaywall) { PaywallView() }
    }

    // MARK: - Pieces

    private var stateCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(stateHeadline)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(stateColor)
            Text(stateDetail)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Theme.surface,
                    in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }

    private var armToggle: some View {
        Toggle(isOn: $armed) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Keep Ara ready to dictate")
                    .foregroundStyle(Theme.textPrimary)
                Text("Holds the microphone session open so the keyboard's mic "
                     + "key works instantly.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .tint(Theme.accent)
        .padding(16)
        .background(Theme.surface,
                    in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .onChange(of: armed) { _, isOn in
            guard isOn != coordinator.isArmed else { return }
            if isOn { coordinator.arm() } else { coordinator.disarm() }
            // Snap back if the coordinator refused.
            armed = coordinator.isArmed
        }
    }

    private var lockedToggle: some View {
        Button { showPaywall = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keep Ara ready to dictate")
                        .foregroundStyle(Theme.textPrimary)
                    Text("Ara's own dictation is part of the one-time unlock. "
                         + "The keyboard types, and Apple's mic key still "
                         + "works, without it.")
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
            Circle().fill(Color.orange).frame(width: 8, height: 8)
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

    // MARK: - State rendering

    private var stateHeadline: String {
        switch coordinator.state {
        case .idle: return "Off"
        case .armed: return "Ready"
        case .recording: return "Listening"
        case .transcribing: return "Transcribing"
        case .error: return "Error"
        }
    }

    private var stateDetail: String {
        switch coordinator.state {
        case .idle:
            return "The microphone is released. The keyboard's mic key falls "
                + "back to Apple's dictation."
        case .armed:
            return "The microphone is open and waiting for the keyboard's mic "
                + "key. Nothing is being transcribed."
        case .recording:
            return "Recording. Tap the keyboard's mic key again to finish."
        case .transcribing:
            return "Turning the last utterance into text, on this device."
        case .error(let message):
            return message
        }
    }

    private var stateColor: Color {
        switch coordinator.state {
        case .error: return Theme.danger
        case .armed, .recording, .transcribing: return Theme.accent
        case .idle: return Theme.textSecondary
        }
    }
}
