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
    @State private var relayRecording = false
    @State private var relayError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ara spike").font(.title2.bold())

            // Experiment 4, app side. Recording starts BY ITSELF when the app
            // opens — two reports in a row came back "no heartbeat found"
            // because the start tap never happened, so there is no start tap
            // anymore. The banner below is the whole protocol.
            if relayRecording {
                VStack(alignment: .leading, spacing: 6) {
                    Label("RECORDING", systemImage: "record.circle")
                        .font(.title3.bold())
                    Text("Switch to Notes now and tap “4 only” on the AraSpike keyboard. Don't come back until it finishes.")
                        .font(.callout.bold())
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(red: 1, green: 0.45, blue: 0.35),
                            in: RoundedRectangle(cornerRadius: 10))
            } else if let relayError {
                VStack(alignment: .leading, spacing: 6) {
                    Label("TEST 4 CAN'T START", systemImage: "xmark.octagon.fill")
                        .font(.title3.bold())
                    Text(relayError).font(.callout.monospaced())
                    Text("Send this line back — it's the diagnosis.")
                        .font(.footnote)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(red: 0.75, green: 0.1, blue: 0.1),
                            in: RoundedRectangle(cornerRadius: 10))
            } else {
                Label("starting the microphone…", systemImage: "hourglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("Control group + first-time setup:")
                .font(.footnote).foregroundStyle(.secondary)
            Text("""
            Setup once: Settings → General → Keyboard → Keyboards → Add New Keyboard → \
            AraSpike, then Allow Full Access. Control group: run 1/2/3 below and Copy.
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
        .onAppear(perform: startRelay)
    }

    private func startRelay() {
        guard !relayRecording else { return }
        RelayProbe.startBackgroundRecording { line in
            lines.append(line)
            if line.hasPrefix("recording") {
                relayRecording = true
                relayError = nil
            } else {
                relayError = line
            }
        }
    }

    private func run(_ body: @escaping () async -> [String]) {
        // The relay holds the audio session; a control-group test running
        // against a busy session would report a false failure.
        if relayRecording {
            RelayProbe.stop()
            relayRecording = false
            lines.append("(relay stopped for control run — relaunch the app to restart it)")
        }
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
