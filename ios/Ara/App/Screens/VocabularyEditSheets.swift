import SwiftUI

struct EntryIndex: Identifiable {
    let index: Int
    var id: Int { index }
}

struct VocabularyEmptyState: View {
    let title: String
    let detail: String
    let action: String
    let perform: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            WaveformView(bars: 5, barWidth: 5, spacing: 5, maxHeight: 48,
                         animating: false, color: Theme.textTertiary, glow: false)
            Text(title)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button(action, action: perform)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(Theme.accentFill, in: Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .listRowSeparator(.hidden)
    }
}

struct DictionaryEditSheet: View {
    let onSave: (LocalDictionary.Entry) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var canonical: String
    @State private var variants: String
    @State private var confirmDelete = false

    init(entry: LocalDictionary.Entry,
         onSave: @escaping (LocalDictionary.Entry) -> Void,
         onDelete: @escaping () -> Void) {
        self.onSave = onSave
        self.onDelete = onDelete
        _canonical = State(initialValue: entry.canonical)
        _variants = State(initialValue: entry.variants.joined(separator: ", "))
    }

    private var entry: LocalDictionary.Entry? {
        let typed = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        let heard = variants.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !typed.isEmpty, !heard.isEmpty else { return nil }
        return LocalDictionary.Entry(canonical: typed, variants: heard)
    }

    var body: some View {
        editor(title: "Edit word") {
            Section("Ara types") {
                TextField("Correct spelling", text: $canonical)
                    .autocorrectionDisabled()
            }
            Section("When it hears") {
                TextField("Variants, comma separated", text: $variants, axis: .vertical)
                    .autocorrectionDisabled()
                    .lineLimit(2...5)
            }
            Section {
                Button("Delete word", role: .destructive) { confirmDelete = true }
            }
        }
        .alert("Delete word?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { onDelete(); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Ara will stop correcting its heard variants.")
        }
    }

    private func editor<Content: View>(title: String,
                                       @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            Form { content() }
                .scrollContentBackground(.hidden)
                .background(Theme.background)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { if let entry { onSave(entry); dismiss() } }
                            .disabled(entry == nil)
                    }
                }
        }
        .presentationBackground(Theme.background)
    }
}

struct SnippetEditSheet: View {
    let onSave: (Snippets.Entry) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var trigger: String
    @State private var expansion: String
    @State private var confirmDelete = false

    init(entry: Snippets.Entry,
         onSave: @escaping (Snippets.Entry) -> Void,
         onDelete: @escaping () -> Void) {
        self.onSave = onSave
        self.onDelete = onDelete
        _trigger = State(initialValue: entry.trigger)
        _expansion = State(initialValue: entry.expansion)
    }

    private var entry: Snippets.Entry? {
        let phrase = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, !expansion.isEmpty else { return nil }
        return Snippets.Entry(trigger: phrase, expansion: expansion)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Say") {
                    TextField("Trigger phrase", text: $trigger)
                        .autocorrectionDisabled()
                }
                Section("Ara types") {
                    TextField("Expansion", text: $expansion, axis: .vertical)
                        .autocorrectionDisabled()
                        .lineLimit(3...10)
                }
                Section {
                    Button("Delete snippet", role: .destructive) { confirmDelete = true }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Edit snippet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { if let entry { onSave(entry); dismiss() } }
                        .disabled(entry == nil)
                }
            }
        }
        .presentationBackground(Theme.background)
        .alert("Delete snippet?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { onDelete(); dismiss() }
            Button("Cancel", role: .cancel) {}
        }
    }
}
