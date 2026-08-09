import SwiftUI

/// The privacy explainer. Static text on purpose: every claim here is either
/// checkable from the outside or it does not belong on this page, and a page
/// that computes its claims invites claims that cannot be computed.
struct PrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nothing leaves the phone.")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text("Not a promise. A product constraint you can inspect.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                PrivacyLabelView(scale: .full)
                section("Nothing leaves this device",
                        "Audio is captured, recognized, corrected and inserted "
                        + "inside Ara. There is no upload step, because there "
                        + "is nowhere to upload to: Ara has no backend, no "
                        + "account system, and no analytics or crash SDK.")

                section("On-device recognition, not a preference",
                        "The speech recognizer runs with on-device recognition "
                        + "required. If a language has no on-device model, "
                        + "dictation is unavailable in that language — Ara "
                        + "does not quietly fall back to Apple's servers.")

                section("The keyboard has no network code",
                        "The keyboard extension links no networking framework "
                        + "and makes no requests. Full Access is used for "
                        + "exactly one thing: the shared app group that "
                        + "carries commands and transcripts between the "
                        + "keyboard and this app, on this device.")

                section("Your files stay files",
                        "Your dictionary and snippets are plain JSON in Ara's "
                        + "app group container, in the same format the macOS "
                        + "version uses. You can read them, edit them, and "
                        + "delete them; deleting Ara deletes them with it.")

                section("Why any of this is provable",
                        "Claims about privacy are worth what they can be "
                        + "checked against. Ara's App Store privacy label is "
                        + "empty, which Apple enforces against what the app "
                        + "actually collects. Network activity is observable "
                        + "with a proxy or Console. An app that talks to a "
                        + "server cannot hide it for long, and this one has "
                        + "nothing to hide it with.")

                section("What Apple still sees",
                        "Ara uses Apple's on-device speech framework and, when "
                        + "you buy it, StoreKit. Apple's own handling of "
                        + "purchases and of frameworks it ships is Apple's to "
                        + "describe, not ours to promise about.")
            }
            .padding(22)
        }
        .background(Theme.background)
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(body)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
