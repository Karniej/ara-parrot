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
    @State private var showPaywall = false
    @EnvironmentObject private var appearanceModel: AppearanceModel
    #if DEBUG
    @State private var debugUnlocked = StoreGate.debugUnlocked
    #endif

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Appearance", selection: $appearanceModel.appearance) {
                        ForEach(Appearance.allCases, id: \.self) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("Applies to the app and the Ara keyboard, whatever "
                         + "the app you're typing in uses.")
                }

                Section {
                    if store.isUnlocked {
                        Picker("Cleanup intensity", selection: $intensity) {
                            ForEach(CleanupIntensity.allCases, id: \.self) { level in
                                Text(level.rawValue.capitalized).tag(level)
                            }
                        }
                        .onChange(of: intensity) { _, value in
                            EngineProvider.set(intensity: value)
                        }
                    } else {
                        Button { showPaywall = true } label: {
                            HStack {
                                Text("Cleanup intensity")
                                Spacer()
                                Text("Locked ›").foregroundStyle(Theme.accent)
                            }
                        }
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

                #if DEBUG
                Section {
                    Toggle("Unlock everything (debug)", isOn: $debugUnlocked)
                        .tint(Theme.danger)
                        .onChange(of: debugUnlocked) { _, value in
                            StoreGate.debugUnlocked = value
                        }
                } header: {
                    Text("Developer")
                } footer: {
                    Text("Grants the paid features to this device without a "
                         + "purchase, so dictation can be tested after a "
                         + "reinstall. The keyboard reads the same switch. "
                         + "This section does not exist in a release build.")
                }
                #endif

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
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .onAppear {
            intensity = EngineProvider.intensity()
            haptics = EngineProvider.hapticsEnabled()
            #if DEBUG
            debugUnlocked = StoreGate.debugUnlocked
            #endif
        }
    }

    private var versionLine: String {
        let version = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "Ara \(version ?? "—")"
    }
}
