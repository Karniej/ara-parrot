import AVFAudio
import Speech
import SwiftUI
import UIKit

/// Where "the user has seen onboarding" lives. Standard `UserDefaults`, not
/// the App Group: the keyboard has no business knowing, and the group suite is
/// the relay's — mixing UI bookkeeping into it makes the relay's state harder
/// to reason about, not easier.
enum OnboardingState {
    static let key = "onboarding.completed"
    /// The page the user was on, persisted because the "open Settings" step
    /// backgrounds the app and iOS may kill it there — relaunching into page
    /// one after the user did what page two asked reads as a broken app.
    static let pageKey = "onboarding.page"
}

/// First launch only: three dark full-screen pages, swipe or Continue. Page 2
/// is the one that matters — a keyboard nobody enables is not a product — so
/// it spells out the toggle path rather than gesturing at Settings.
struct OnboardingView: View {
    /// Called once, from the last page. The caller owns persistence.
    let onFinish: () -> Void

    @AppStorage(OnboardingState.pageKey) private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                IntroPage().tag(0)
                AddKeyboardPage().tag(1)
                PermissionsPage().tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .never))

            Button(page == 2 ? "Start using Ara" : "Continue") {
                if page == 2 {
                    onFinish()
                } else {
                    withAnimation { page += 1 }
                }
            }
            .font(.headline)
            .foregroundStyle(Color.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Theme.accentFill,
                        in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Theme.background)
    }
}

// MARK: - Pages

/// Page ①: what Ara is, and the one claim the whole product rests on. The
/// waveform performs once as an entrance — a few seconds of voice — then
/// falls still, because in this product motion means the microphone is open
/// and the intro should teach that instinct, not undermine it.
private struct IntroPage: View {
    @State private var performing = false

    var body: some View {
        OnboardingPage(title: "Ara — dictation that never leaves your phone") {
            HStack {
                Spacer()
                WaveformView(bars: 7, barWidth: 7, spacing: 6, maxHeight: 84,
                             animating: performing)
                Spacer()
            }
            .padding(.vertical, 16)
            .task {
                performing = true
                try? await Task.sleep(for: .seconds(3.2))
                performing = false
            }
            Text("You speak, Ara types. Recording and transcription both happen "
                 + "on this device, through Apple's on-device recognizer.")
            Text("There is no account, no analytics, and no server to send "
                 + "anything to. That is why Ara's App Store privacy label is "
                 + "empty — not as a promise, but because there is nothing to "
                 + "declare.")
        }
    }
}

/// Page ②: the toggle path, the deep link, and an honest Full Access answer.
private struct AddKeyboardPage: View {
    @State private var keyboardSeen = Relay.keyboardEverSeen
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        OnboardingPage(title: "Add the Ara keyboard") {
            if keyboardSeen {
                Label("The Ara keyboard is added, with Full Access",
                      systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }

            Text("iOS will not enable a keyboard on an app's say-so, but the "
                 + "button below lands one tap away:")

            // The supported deep link opens *Ara's* Settings page, which
            // carries the Keyboards row. There is no public URL for
            // General → Keyboard; the `App-prefs:` scheme is private API and
            // a rejection magnet.
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Open Settings → tap Keyboards", systemImage: "arrow.up.forward.app")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.surface,
                                in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            }
            .foregroundStyle(Theme.accent)

            Text("There, turn on Ara and Allow Full Access. (The long way "
                 + "around is Settings → General → Keyboard → Keyboards.)")
                .foregroundStyle(Theme.textPrimary)
            Text("Full Access is what lets the keyboard reach this app through "
                 + "the shared app group — the relay that carries your "
                 + "dictation, since a keyboard extension is not allowed to "
                 + "record. It is also the permission that would let a "
                 + "keyboard phone home. Ara's keyboard contains no network "
                 + "code at all, which is checkable: the extension links no "
                 + "networking framework.")
            Text("Without Full Access the keyboard still types, and dictation "
                 + "falls back to Apple's own mic key.")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { keyboardSeen = Relay.keyboardEverSeen }
        }
    }
}

/// The live answer to both prompts. Derived from the system every time rather
/// than remembered from a tap: the user can grant, deny, or change either one
/// in Settings while this page is on screen, and a page still offering "Grant"
/// for a permission already granted reads as an app that is not paying
/// attention.
enum PermissionState {
    case undetermined, granted, denied

    static var current: PermissionState {
        let mic = AVAudioApplication.shared.recordPermission
        let speech = SFSpeechRecognizer.authorizationStatus()
        if mic == .granted, speech == .authorized { return .granted }
        // Denied is sticky: iOS will not re-prompt, so the only honest next
        // step is Settings. Restricted (parental controls) behaves the same.
        if mic == .denied || speech == .denied || speech == .restricted {
            return .denied
        }
        return .undetermined
    }
}

/// Page ③: the two prompts only the app can raise, then somewhere to try it.
private struct PermissionsPage: View {
    @State private var permission = PermissionState.current
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        OnboardingPage(title: "Microphone and speech") {
            Text("Ara needs the microphone to hear you and speech recognition "
                 + "to turn it into text. Both stay on this device; the "
                 + "recognizer is pinned to on-device mode and never falls "
                 + "back to Apple's servers.")
            Text("A keyboard extension cannot raise these prompts, so they "
                 + "happen here, once.")

            switch permission {
            case .granted:
                Label("Microphone and speech are granted",
                      systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            case .undetermined:
                Button {
                    Task {
                        _ = await AppServices.shared.dictation.requestPermissions()
                        permission = .current
                    }
                } label: {
                    Label("Grant microphone and speech", systemImage: "mic")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(Theme.accent)
            case .denied:
                Text("Declined — iOS will not ask again, so dictation stays "
                     + "off until both are allowed in Settings. The keyboard "
                     + "still types.")
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Open Ara's settings", systemImage: "arrow.up.forward.app")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(Theme.accent)
            }

            PlaygroundField(caption: "Try it here",
                            prompt: "Switch to the Ara keyboard and type")
                .padding(.top, 8)
        }
        // Returning from Settings is the whole point of re-reading: the user
        // may have changed either switch while we were backgrounded.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { permission = .current }
        }
    }
}

// MARK: - Shared page chrome

/// One page's layout: title, then body copy in secondary text. Scrollable
/// because page ② is long on an SE and truncated onboarding is worse than
/// scrolled onboarding.
private struct OnboardingPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.largeTitle.bold())
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.bottom, 8)
                content
            }
            .font(.subheadline)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 64)
            .padding(.bottom, 48)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.background)
    }
}
