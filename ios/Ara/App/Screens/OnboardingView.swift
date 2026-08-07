import SwiftUI
import UIKit

/// Where "the user has seen onboarding" lives. Standard `UserDefaults`, not
/// the App Group: the keyboard has no business knowing, and the group suite is
/// the relay's — mixing UI bookkeeping into it makes the relay's state harder
/// to reason about, not easier.
enum OnboardingState {
    static let key = "onboarding.completed"
}

/// First launch only: three dark full-screen pages, swipe or Continue. Page 2
/// is the one that matters — a keyboard nobody enables is not a product — so
/// it spells out the toggle path rather than gesturing at Settings.
struct OnboardingView: View {
    /// Called once, from the last page. The caller owns persistence.
    let onFinish: () -> Void

    @State private var page = 0

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
            .background(Theme.accent,
                        in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Theme.background)
    }
}

// MARK: - Pages

/// Page ①: what Ara is, and the one claim the whole product rests on.
private struct IntroPage: View {
    var body: some View {
        OnboardingPage(title: "Ara — dictation that never leaves your phone") {
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
    var body: some View {
        OnboardingPage(title: "Add the Ara keyboard") {
            Text("iOS will not enable a keyboard on an app's say-so. The path "
                 + "is:")
            Text("Settings → General → Keyboard → Keyboards → Add New "
                 + "Keyboard → Ara")
                .font(.subheadline.monospaced())
                .foregroundStyle(Theme.textPrimary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface,
                            in: RoundedRectangle(cornerRadius: Theme.cornerRadius))

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Open Ara's settings", systemImage: "arrow.up.forward.app")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Theme.accent)

            Text("Then turn on Allow Full Access.")
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
    }
}

/// Page ③: the two prompts only the app can raise, then somewhere to try it.
private struct PermissionsPage: View {
    @State private var granted: Bool?

    var body: some View {
        OnboardingPage(title: "Microphone and speech") {
            Text("Ara needs the microphone to hear you and speech recognition "
                 + "to turn it into text. Both stay on this device; the "
                 + "recognizer is pinned to on-device mode and never falls "
                 + "back to Apple's servers.")
            Text("A keyboard extension cannot raise these prompts, so they "
                 + "happen here, once.")

            Button {
                Task { granted = await AppServices.shared.dictation
                    .requestPermissions() }
            } label: {
                Label("Grant microphone and speech", systemImage: "mic")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Theme.accent)

            if let granted {
                Text(granted
                     ? "Granted. Dictation is available."
                     : "Declined — dictation stays off until both are allowed "
                       + "in Settings. The keyboard still types.")
                    .font(.footnote)
                    .foregroundStyle(granted ? Theme.textSecondary : Theme.danger)
            }

            PlaygroundField(caption: "Try it here",
                            prompt: "Switch to the Ara keyboard and type")
                .padding(.top, 8)
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
