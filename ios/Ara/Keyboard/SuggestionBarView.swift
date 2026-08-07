import SwiftUI

/// The 36 pt top strip — mic state, live transcript, ✨ Clean. Empty until the
/// dictation task fills it; it exists now because the key grid's height math
/// is measured against the total, and that number ships in a constraint.
struct SuggestionBarView: View {
    @ObservedObject var bridge: KeyboardBridge

    var body: some View {
        HStack(spacing: 8) {}
            .frame(maxWidth: .infinity)
            .frame(height: KeyboardMetrics.suggestionBarHeight)
            .background(Theme.background)
    }
}
