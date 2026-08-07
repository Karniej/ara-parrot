import SwiftUI

/// The short settings list v1 earns: cleanup intensity, keyboard haptics,
/// restore, the privacy page, and a version string.
///
/// Both toggles write straight through to the App Group on change rather than
/// on leaving the screen — the keyboard reloads them per invocation, so a
/// setting that has not landed by the time the user switches keyboards has
/// effectively not been changed.
struct SettingsView: View {
    @State private var intensity = EngineProvider.intensity()
    @State private var haptics = EngineProvider.hapticsEnabled()
    @StateObject private var store = StoreService()
    @State private var restoring = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Cleanup intensity", selection: $intensity) {
                        ForEach(CleanupIntensity.allCases, id: \.self) { level in
                            Text(level.rawValue.capitalized).tag(level)
                        }
                    }
                    .onChange(of: intensity) { _, value in
                        EngineProvider.set(intensity: value)
                    }
                } footer: {
                    Text("How far the Clean action goes: none leaves the "
                         + "transcript alone, high also drops fillers and "
                         + "tightens sentences.")
                }

                Section {
                    Toggle("Keyboard haptics", isOn: $haptics)
                        .tint(Theme.accent)
                        .onChange(of: haptics) { _, value in
                            EngineProvider.set(hapticsEnabled: value)
                        }
                } footer: {
                    Text("iOS also has a system-wide keyboard feedback switch; "
                         + "Ara respects that one too.")
                }

                Section {
                    Button(restoring ? "Restoring…" : "Restore purchase") {
                        restoring = true
                        Task {
                            await store.restore()
                            restoring = false
                        }
                    }
                    .disabled(restoring)
                } footer: {
                    Text(store.isUnlocked
                         ? "Ara is unlocked on this device."
                         : "Bought Ara before, on this or another device? "
                           + "This asks the App Store — no account needed.")
                }

                Section {
                    NavigationLink("What leaves your phone") { PrivacyView() }
                }

                Section {
                    Text(versionLine)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .listRowBackground(Color.clear)
            }
            .tint(Theme.accent)
            .foregroundStyle(Theme.textPrimary)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
            .toolbarBackground(Theme.background, for: .navigationBar)
        }
        .onAppear {
            intensity = EngineProvider.intensity()
            haptics = EngineProvider.hapticsEnabled()
        }
    }

    private var versionLine: String {
        let version = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "Ara \(version ?? "—")"
    }
}
