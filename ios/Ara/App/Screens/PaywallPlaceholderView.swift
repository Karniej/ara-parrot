import SwiftUI

/// Stands in for the real VidNotes-style paywall until Task 7 lands StoreKit.
/// Kept deliberately bare and in a file of its own: the locked touchpoints
/// already present it, so replacing this body is the whole of that task.
struct PaywallPlaceholderView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Unlock Ara")
                .font(.title2.bold())
                .foregroundStyle(Theme.textPrimary)
            Text("One-time purchase, no subscription, no account, no server.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Text("Purchase arrives in Task 7.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            Button("Close") { dismiss() }
                .foregroundStyle(Theme.accent)
                .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .presentationBackground(Theme.background)
    }
}
