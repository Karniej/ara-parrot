import SwiftUI

/// The VidNotes-style paywall: dark, one accent, one price, no urgency
/// theater. Presented from the app only — the keyboard never shows a price
/// (App Review 4.4).
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = StoreService()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(10)
                        .background(Theme.surface, in: Circle())
                }
            }
            .padding(.bottom, 8)

            Text("Unlock Ara")
                .font(.largeTitle.bold())
                .foregroundStyle(Theme.textPrimary)
            Text("Yours forever. No subscription, no account, no server.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 14) {
                feature("mic.fill", "Dictate with Ara's own mic",
                        "your voice is transcribed on this phone and nowhere else")
                feature("sparkles", "Clean up any sentence",
                        "one tap fixes dictation artifacts, spacing and typos")
                feature("dial.high", "Cleanup intensity control",
                        "from punctuation-only to full tidy")
            }
            .padding(.vertical, 28)

            Spacer(minLength: 0)

            if store.isUnlocked {
                Label("Unlocked — everything is yours", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                Button {
                    Task { await store.purchase() }
                } label: {
                    Text(purchaseLabel)
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Theme.accentFill, in: RoundedRectangle(
                            cornerRadius: Theme.cornerRadius))
                }
                Button {
                    Task { await store.restore() }
                } label: {
                    Text("Restore purchase")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                }
            }

            if let error = store.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .presentationBackground(Theme.background)
        .onChange(of: store.isUnlocked) { _, unlocked in
            if unlocked { dismiss() }
        }
    }

    private var purchaseLabel: String {
        if let product = store.product {
            return "Unlock forever · \(product.displayPrice)"
        }
        return "Unlock forever"
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}
