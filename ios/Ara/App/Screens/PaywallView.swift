import SwiftUI

/// App-only purchase UI. The keyboard never links StoreKit, presents a price,
/// or sends the user to purchase, which keeps the App Review 4.4 boundary.
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = StoreService()

    var body: some View {
        Group {
            switch store.phase {
            case .purchased, .restored:
                confirmation
            case .restoring:
                restoring
            case .nothingToRestore:
                nothingToRestore
            case .failed:
                failure
            case .idle, .purchasing, .pending:
                offer
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .presentationBackground(Theme.background)
    }

    private var offer: some View {
        VStack(alignment: .leading, spacing: 0) {
            closeButton
            Text("Unlock Ara")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text("Everything, forever, on your App Store devices.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 5)

            price
                .padding(.top, 24)

            VStack(alignment: .leading, spacing: 18) {
                feature("mic.fill", "Dictate from the Ara keyboard",
                        "On-device speech in every app that accepts a keyboard.")
                feature("sparkles", "Clean any sentence",
                        "Remove dictation noise without changing what you meant.")
                feature("dial.high", "Choose cleanup intensity",
                        "From punctuation only to a full tidy.")
            }
            .padding(.vertical, 26)

            Spacer(minLength: 12)

            Button {
                Task { await store.purchase() }
            } label: {
                HStack(spacing: 8) {
                    if store.phase == .purchasing {
                        ProgressView().tint(.black)
                    }
                    Text(store.phase == .pending ? "Waiting for approval" : "Unlock forever")
                }
                .font(.system(.headline, design: .rounded, weight: .bold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Theme.accentFill, in: RoundedRectangle(
                    cornerRadius: Theme.cornerRadius, style: .continuous))
            }
            .disabled(store.phase == .purchasing || store.phase == .pending)

            Button("Restore purchase") {
                Task { await store.restore() }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)

            PrivacyLabelView(scale: .seal)
        }
    }

    private var price: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(store.product?.displayPrice ?? "$49.99")
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text("once")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text("NO SUBSCRIPTION")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .overlay(Capsule().stroke(Theme.accent.opacity(0.5)))
        }
    }

    private var confirmation: some View {
        outcome(symbol: "checkmark.circle.fill", title: "Ara is yours.",
                detail: "The keyboard already knows. Your unlock is mirrored before this screen appears.") {
            Button("Done") { dismiss() }
                .primaryPaywallButton()
        }
    }

    private var restoring: some View {
        outcome(symbol: "arrow.triangle.2.circlepath", title: "Asking App Store…",
                detail: "This can take a moment. No Ara account is required.") {
            ProgressView().tint(Theme.accent)
            Button("Cancel") {
                store.resetPhase()
            }
            .foregroundStyle(Theme.textSecondary)
        }
    }

    private var nothingToRestore: some View {
        outcome(symbol: "bag", title: "No purchase found.",
                detail: "The App Store did not find an Ara purchase for this Apple ID. Nothing changed.") {
            Button("Back") { store.resetPhase() }
                .primaryPaywallButton()
        }
    }

    private var failure: some View {
        outcome(symbol: "exclamationmark.circle", title: "That didn't go through.",
                detail: "You were not charged. Try again when the App Store is available.") {
            Button("Try again") { store.resetPhase() }
                .primaryPaywallButton()
            Button("Not now") { dismiss() }
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var closeButton: some View {
        HStack {
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(10)
                    .background(Theme.surface, in: Circle())
            }
        }
        .padding(.bottom, 8)
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func outcome<Actions: View>(symbol: String, title: String,
                                        detail: String,
                                        @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
            VStack(spacing: 14) { actions() }
                .frame(maxWidth: .infinity)
        }
    }
}

private extension View {
    func primaryPaywallButton() -> some View {
        font(.system(.headline, design: .rounded, weight: .bold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Theme.accentFill, in: RoundedRectangle(
                cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}
