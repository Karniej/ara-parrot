import SwiftUI

/// Ara's product signature. The same empty App Store privacy label appears at
/// three scales so privacy is a visible product fact, not footer copy.
struct PrivacyLabelView: View {
    enum Scale { case full, medium, seal }
    var scale: Scale = .full

    var body: some View {
        switch scale {
        case .full: fullLabel
        case .medium: mediumLabel
        case .seal: seal
        }
    }

    private var fullLabel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Privacy label")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                    Text("App Store")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .textCase(.uppercase)
                }
                Spacer()
                Image(systemName: "checkmark.shield.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
            }
            Divider().overlay(Theme.hairline)
            labelRow("Data used to track you")
            labelRow("Data linked to you")
            labelRow("Data not linked to you")
            Divider().overlay(Theme.hairline)
            Label("Data not collected", systemImage: "checkmark.circle.fill")
                .fontWeight(.semibold)
                .foregroundStyle(Theme.accent)
            Text("The developer does not collect any data from this app.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(22)
        .background(Theme.card, in: RoundedRectangle(
            cornerRadius: Theme.heroCornerRadius, style: .continuous))
        .overlay { outline(radius: Theme.heroCornerRadius, color: Theme.accent.opacity(0.28)) }
    }

    private var mediumLabel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Privacy label", systemImage: "checkmark.shield.fill")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                Spacer()
                Text("APP STORE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            labelRow("Tracking")
            labelRow("Linked to you")
            Label("Data not collected", systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.accent)
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(18)
        .background(Theme.card, in: RoundedRectangle(
            cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay { outline(radius: Theme.cornerRadius, color: Theme.hairline) }
    }

    private var seal: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.and.hand.point.up.left.filled")
                .font(.title3)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("The label is empty.")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("no account · no server · no tracking")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(
            cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay { outline(radius: Theme.cornerRadius, color: Theme.hairline) }
    }

    private func labelRow(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text("None")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private func outline(radius: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(color, lineWidth: 1)
    }
}
