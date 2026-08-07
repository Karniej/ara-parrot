import SwiftUI

/// The "try it here" field, shared by onboarding's last page and Home.
///
/// Deliberately a plain `TextField` with nothing intercepting it: what the Ara
/// keyboard inserts here is exactly what it would insert in Messages, so the
/// playground cannot flatter the keyboard by being special.
struct PlaygroundField: View {
    let caption: String
    let prompt: String

    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(caption)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            TextField(prompt, text: $text, axis: .vertical)
                .lineLimit(3...5)
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.textPrimary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface,
                            in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        }
    }
}
