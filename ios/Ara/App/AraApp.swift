import SwiftUI
import UIKit

@main
struct AraApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

/// Three tabs, with onboarding covering them until it has been through once.
struct RootView: View {
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
        .onAppear { applyBarAppearance() }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView {
                onboardingCompleted = true
                showOnboarding = false
            }
        }
    }

    /// UIKit still owns the tab and navigation bar chrome, and its default
    /// translucent material over `#000` reads as grey. The appearance proxies
    /// are the only way to reach it.
    @MainActor
    private func applyBarAppearance() {
        let tabBar = UITabBarAppearance()
        tabBar.configureWithOpaqueBackground()
        tabBar.backgroundColor = .black
        UITabBar.appearance().standardAppearance = tabBar
        UITabBar.appearance().scrollEdgeAppearance = tabBar

        let navigationBar = UINavigationBarAppearance()
        navigationBar.configureWithOpaqueBackground()
        navigationBar.backgroundColor = .black
        navigationBar.titleTextAttributes = [.foregroundColor: UIColor.white]
        navigationBar.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = navigationBar
        UINavigationBar.appearance().scrollEdgeAppearance = navigationBar
    }
}
