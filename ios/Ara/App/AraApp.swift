import SwiftUI

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

/// Placeholder root until Task 6 lands the real screens; proves the target,
/// the theme, and the engine glue all build together.
struct RootView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Ara").font(.largeTitle.bold())
                .foregroundStyle(Theme.textPrimary)
            Text("Dictation that never leaves your phone.")
                .foregroundStyle(Theme.textSecondary)
            if !Relay.available {
                Text("App Group unavailable — check provisioning")
                    .font(.footnote).foregroundStyle(Theme.danger)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}
