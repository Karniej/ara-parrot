import SwiftUI

/// Editors for the two files the engine hot-reloads per utterance:
/// `dictionary.json` and `snippets.json`, in the App Group container, in the
/// same byte format macOS writes — a Mac-edited file drops in unchanged.
///
/// Both editors are load-edit-write over the whole file rather than mutate in
/// place: `entries` is `private(set)` by design, so a change means a new value
/// and one atomic write, which is also what makes a half-finished edit
/// incapable of truncating the file the keyboard is reading.
struct VocabularyView: View {
    private enum Tab: String, CaseIterable {
        case dictionary = "Dictionary"
        case snippets = "Snippets"
    }

    @State private var tab = Tab.dictionary
    @State private var dictionary = LocalDictionary()
    @State private var snippets = Snippets()
    @State private var addingDictionaryEntry = false
    @State private var addingSnippet = false
    @State private var editingDictionaryEntry: EntryIndex?
    @State private var editingSnippet: EntryIndex?
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(16)

                if let saveError {
                    Text(saveError)
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }

                switch tab {
                case .dictionary: dictionaryList
                case .snippets: snippetList
                }
            }
            .background(Theme.background)
            .navigationTitle("Vocabulary")
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if tab == .dictionary {
                            addingDictionaryEntry = true
                        } else {
                            addingSnippet = true
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .foregroundStyle(Theme.accent)
                }
            }
        }
        // Reload on appear: the keyboard reads these files per utterance and
        // macOS may have rewritten them; a cached copy would write back stale
        // entries.
        .onAppear(perform: reload)
        .sheet(isPresented: $addingDictionaryEntry) {
            DictionaryEntrySheet { entry in
                persist(LocalDictionary(entries: dictionary.entries + [entry]))
            }
        }
        .sheet(isPresented: $addingSnippet) {
            SnippetSheet { entry in
                persist(Snippets(entries: snippets.entries + [entry]))
            }
        }
        .sheet(item: $editingDictionaryEntry) { selection in
            DictionaryEditSheet(entry: dictionary.entries[selection.index]) { entry in
                var entries = dictionary.entries
                entries[selection.index] = entry
                persist(LocalDictionary(entries: entries))
            } onDelete: {
                var entries = dictionary.entries
                entries.remove(at: selection.index)
                persist(LocalDictionary(entries: entries))
            }
        }
        .sheet(item: $editingSnippet) { selection in
            SnippetEditSheet(entry: snippets.entries[selection.index]) { entry in
                var entries = snippets.entries
                entries[selection.index] = entry
                persist(Snippets(entries: entries))
            } onDelete: {
                var entries = snippets.entries
                entries.remove(at: selection.index)
                persist(Snippets(entries: entries))
            }
        }
    }

    // MARK: - Lists

    private var dictionaryList: some View {
        List {
            Section {
                if dictionary.entries.isEmpty {
                    VocabularyEmptyState(
                        title: "Ara can learn your words",
                        detail: "Add a name, product, or term and the ways speech recognition may hear it.",
                        action: "Add your first word") {
                            addingDictionaryEntry = true
                        }
                }
                ForEach(dictionary.entries.indices, id: \.self) { index in
                    let entry = dictionary.entries[index]
                    Button { editingDictionaryEntry = EntryIndex(index: index) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.canonical)
                                .foregroundStyle(Theme.textPrimary)
                            Text(entry.variants.joined(separator: ", "))
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    var entries = dictionary.entries
                    entries.remove(atOffsets: offsets)
                    persist(LocalDictionary(entries: entries))
                }
                .listRowBackground(Theme.surface)
            } footer: {
                Text("Every variant is rewritten to its canonical spelling "
                     + "before the transcript reaches the keyboard. Whole "
                     + "words only, case-insensitive.")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
    }

    private var snippetList: some View {
        List {
            Section {
                if snippets.entries.isEmpty {
                    VocabularyEmptyState(
                        title: "Say less. Type more.",
                        detail: "Speak a short trigger and Ara inserts the exact text you saved.",
                        action: "Add your first snippet") {
                            addingSnippet = true
                        }
                }
                ForEach(snippets.entries.indices, id: \.self) { index in
                    let entry = snippets.entries[index]
                    Button { editingSnippet = EntryIndex(index: index) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.trigger)
                                .foregroundStyle(Theme.textPrimary)
                            Text(entry.expansion)
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(2)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    var entries = snippets.entries
                    entries.remove(atOffsets: offsets)
                    persist(Snippets(entries: entries))
                }
                .listRowBackground(Theme.surface)
            } footer: {
                Text("A trigger fires only when the whole utterance is that "
                     + "phrase, and the expansion is typed verbatim — no "
                     + "cleanup, no capitalisation, exactly what you wrote.")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
    }

    // MARK: - Persistence

    private func reload() {
        dictionary = EngineProvider.loadDictionary()
        snippets = EngineProvider.loadSnippets()
    }

    private func persist(_ new: LocalDictionary) {
        do {
            try new.write(to: LocalDictionary.defaultURL)
            dictionary = new
            saveError = nil
        } catch {
            saveError = "Could not save the dictionary: \(error.localizedDescription)"
        }
    }

    private func persist(_ new: Snippets) {
        do {
            try new.write(to: Snippets.defaultURL)
            snippets = new
            saveError = nil
        } catch {
            saveError = "Could not save the snippets: \(error.localizedDescription)"
        }
    }
}

// MARK: - Add sheets

/// Canonical plus comma-separated variants, which is how the file reads and
/// how people think about it — a per-variant repeater would be more UI for a
/// list that is usually two words long.
private struct DictionaryEntrySheet: View {
    let onAdd: (LocalDictionary.Entry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var canonical = ""
    @State private var variants = ""

    private var entry: LocalDictionary.Entry? {
        let canonical = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        let variants = variants
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !canonical.isEmpty, !variants.isEmpty else { return nil }
        return LocalDictionary.Entry(canonical: canonical, variants: variants)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Canonical spelling", text: $canonical)
                        .autocorrectionDisabled()
                    TextField("Misheard variants, comma separated",
                              text: $variants, axis: .vertical)
                        .autocorrectionDisabled()
                        .lineLimit(1...3)
                }
                .listRowBackground(Theme.surface)
                .foregroundStyle(Theme.textPrimary)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("New correction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar { sheetToolbar(canSave: entry != nil, dismiss: dismiss) {
                if let entry { onAdd(entry) }
            } }
        }
        .presentationBackground(Theme.background)
    }
}

private struct SnippetSheet: View {
    let onAdd: (Snippets.Entry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var trigger = ""
    @State private var expansion = ""

    private var entry: Snippets.Entry? {
        let trigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty, !expansion.isEmpty else { return nil }
        return Snippets.Entry(trigger: trigger, expansion: expansion)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Trigger phrase", text: $trigger)
                        .autocorrectionDisabled()
                    TextField("Expansion", text: $expansion, axis: .vertical)
                        .autocorrectionDisabled()
                        .lineLimit(3...8)
                }
                .listRowBackground(Theme.surface)
                .foregroundStyle(Theme.textPrimary)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("New snippet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar { sheetToolbar(canSave: entry != nil, dismiss: dismiss) {
                if let entry { onAdd(entry) }
            } }
        }
        .presentationBackground(Theme.background)
    }
}

/// Cancel/Add, identical in both sheets and not worth two copies.
@MainActor @ToolbarContentBuilder
private func sheetToolbar(canSave: Bool,
                          dismiss: DismissAction,
                          add: @escaping () -> Void) -> some ToolbarContent {
    ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
            .foregroundStyle(Theme.textSecondary)
    }
    ToolbarItem(placement: .confirmationAction) {
        Button("Add") {
            add()
            dismiss()
        }
        .disabled(!canSave)
        .foregroundStyle(Theme.accent)
    }
}
