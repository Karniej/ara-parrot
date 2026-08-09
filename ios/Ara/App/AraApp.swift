import SwiftUI
import UIKit

@main
struct AraApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(Theme.accent)
        }
    }
}

/// Bridges the App-Group appearance setting into SwiftUI. An object rather
/// than a read in `body` so the Settings picker can flip the whole app live.
@MainActor
final class AppearanceModel: ObservableObject {
    @Published var appearance: Appearance = .current {
        didSet { Appearance.set(appearance) }
    }
}

/// Three tabs, with onboarding covering them until it has been through once.
struct RootView: View {
    @StateObject private var appearanceModel = AppearanceModel()
    @AppStorage(OnboardingState.key) private var onboardingCompleted = false
    /// Read once from `UserDefaults` rather than derived from the binding: a
    /// cover driven by a negated `@AppStorage` value re-presents itself the
    /// moment anything else writes the suite.
    @State private var showOnboarding =
        !UserDefaults.standard.bool(forKey: OnboardingState.key)

    var body: some View {
        TabView {
            HomeView(coordinator: AppServices.shared.dictation)
                .tabItem { Label("Home", systemImage: "mic") }
            VocabularyView()
                .tabItem { Label("Vocabulary", systemImage: "textformat.abc") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(Theme.accent)
        .preferredColorScheme(appearanceModel.appearance.colorScheme)
        .environmentObject(appearanceModel)
        .onAppear { applyBarAppearance() }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView {
                onboardingCompleted = true
                showOnboarding = false
            }
        }
    }

    /// UIKit still owns the tab and navigation bar chrome, and its default
    /// translucent material over a flat background reads as grey. The
    /// appearance proxies are the only way to reach it; the colors are
    /// dynamic, so they track light/dark on their own.
    @MainActor
    private func applyBarAppearance() {
        let background = UIColor(Theme.background)
        let text = UIColor(Theme.textPrimary)
        let tabBar = UITabBarAppearance()
        tabBar.configureWithOpaqueBackground()
        tabBar.backgroundColor = background
        UITabBar.appearance().standardAppearance = tabBar
        UITabBar.appearance().scrollEdgeAppearance = tabBar

        let navigationBar = UINavigationBarAppearance()
        navigationBar.configureWithOpaqueBackground()
        navigationBar.backgroundColor = background
        navigationBar.titleTextAttributes = [.foregroundColor: text]
        navigationBar.largeTitleTextAttributes = [.foregroundColor: text]
        UINavigationBar.appearance().standardAppearance = navigationBar
        UINavigationBar.appearance().scrollEdgeAppearance = navigationBar
    }
}
