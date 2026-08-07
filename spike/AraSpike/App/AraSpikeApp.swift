import SwiftUI

/// Container app: setup instructions plus the same three experiments run
/// in-app as the control group. A result that differs between here and the
/// keyboard is the extension sandbox; a result that matches is the device.
@main
struct AraSpikeApp: App {
    var body: some Scene {
        WindowGroup { SpikeView() }
    }
}

struct SpikeView: View {
    @State private var lines: [String] =
        Experiments.header(context: "CONTAINER APP (control)", fullAccess: nil)
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ara spike").font(.title2.bold())
            Text("""
            1. Settings → General → Keyboard → Keyboards → Add New Keyboard → AraSpike, \
            then tap it and Allow Full Access.
            2. Open Notes, switch to the AraSpike keyboard (globe key), run 1/2/3, \
            tap Type report.
            3. Turn Full Access OFF and run all three again.
            4. Run the control group below and compare.
            """).font(.footnote).foregroundStyle(.secondary)

            HStack {
                Button("1 FM") { run { await Experiments.foundationModels() } }
                Button("2 Mic") { run { await Experiments.microphone() } }
                Button("3 ASR") { run { await Experiments.onDeviceASR() } }
                Button("Copy") { UIPasteboard.general.string = lines.joined(separator: "\n") }
            }
            .buttonStyle(.bordered)
            .disabled(running)

            ScrollView {
                Text(lines.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(Color(red: 1, green: 0.75, blue: 0.46))
            }
            .background(Color(white: 0.06))
        }
        .padding()
        .preferredColorScheme(.dark)
    }

    private func run(_ body: @escaping () async -> [String]) {
        running = true
        Task {
            let result = await body()
            await MainActor.run {
                lines.append(contentsOf: result)
                running = false
            }
        }
    }
}
