import SwiftUI

/// The keyboard itself: suggestion strip on top, key grid below, alternates
/// popup drawn over both. One coordinate space spans the whole thing so key
/// frames, drag locations, and popup placement are all the same numbers.
struct KeyboardRootView: View {
    @ObservedObject var bridge: KeyboardBridge
    @ObservedObject var state: KeyboardState

    var body: some View {
        VStack(spacing: 0) {
            SuggestionBarView(bridge: bridge)
            keyGrid
        }
        .frame(height: KeyboardMetrics.totalHeight)
        .background(Theme.background)
        .coordinateSpace(name: KeyboardMetrics.coordinateSpace)
        .overlay(alignment: .topLeading) { popupOverlay }
    }

    private var keyGrid: some View {
        GeometryReader { geometry in
            let unit = KeyboardMetrics.unitWidth(in: geometry.size.width)
            VStack(spacing: KeyboardMetrics.rowSpacing) {
                ForEach(KeyboardLayout.rows(for: state.layer,
                                            needsGlobeKey: bridge.needsGlobeKey)) { row in
                    HStack(spacing: KeyboardMetrics.keySpacing) {
                        ForEach(row.keys) { key in
                            KeyView(key: key, unit: unit,
                                    containerWidth: geometry.size.width, state: state)
                        }
                    }
                    .padding(.horizontal,
                             row.inset ? (unit + KeyboardMetrics.keySpacing) / 2 : 0)
                }
            }
            .padding(.horizontal, KeyboardMetrics.edgeInset)
            .padding(.vertical, KeyboardMetrics.verticalInset)
        }
        .frame(height: KeyboardMetrics.keyboardHeight)
    }

    @ViewBuilder private var popupOverlay: some View {
        if let popup = state.popup {
            KeyPopupView(popup: popup)
                .frame(width: popup.width, height: popup.cellSize.height)
                .offset(x: popup.origin.x, y: popup.origin.y)
                // The gesture that opened it still owns the finger.
                .allowsHitTesting(false)
        }
    }
}

/// One key. Owns its own frame (for popup anchoring) and a single drag
/// gesture that covers the whole contact: press highlight, hold-to-open,
/// slide-to-select, and the release that types.
struct KeyView: View {
    let key: Key
    let unit: CGFloat
    let containerWidth: CGFloat
    @ObservedObject var state: KeyboardState

    @State private var frame: CGRect = .zero
    @State private var isPressed = false

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.keyCornerRadius, style: .continuous)
            .fill(isPressed || isShiftEngaged ? Theme.surfacePressed : Theme.surface)
            .overlay { label }
            .frame(height: KeyboardMetrics.keyHeight)
            .modifier(KeyWidth(span: key.span, unit: unit))
            .contentShape(Rectangle())
            .background(frameReader)
            .gesture(gesture)
    }

    private var isShiftEngaged: Bool {
        key.action == .shift && state.shift != .off
    }

    @ViewBuilder private var label: some View {
        switch key.action {
        case .character(let base):
            Text(state.displayText(for: base))
                .font(.system(size: 22))
                .foregroundStyle(Theme.textPrimary)
        case .shift:
            Image(systemName: shiftSymbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(state.shift == .off ? Theme.textPrimary : Theme.accent)
        case .backspace:
            Image(systemName: "delete.left")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
        case .layer(let target):
            Text(target.switchLabel)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
        case .globe:
            Image(systemName: "globe")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
        case .space:
            Text("space")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
        case .newline:
            Text(state.returnLabel)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private var shiftSymbol: String {
        switch state.shift {
        case .off: return "shift"
        case .oneShot: return "shift.fill"
        case .locked: return "capslock.fill"
        }
    }

    private var frameReader: some View {
        GeometryReader { geometry in
            Color.clear.onChange(
                of: geometry.frame(in: .named(KeyboardMetrics.coordinateSpace)),
                initial: true
            ) { _, new in
                frame = new
            }
        }
    }

    private var gesture: some Gesture {
        DragGesture(minimumDistance: 0,
                    coordinateSpace: .named(KeyboardMetrics.coordinateSpace))
            .onChanged { value in
                if !isPressed {
                    isPressed = true
                    state.pressBegan(key, anchor: frame, containerWidth: containerWidth)
                }
                state.pressMoved(to: value.location)
            }
            .onEnded { _ in
                isPressed = false
                state.pressEnded(key)
            }
    }
}

/// Fixed-width keys are sized in grid units; flexible ones divide the
/// remainder, which is how a row stays full width at any device size.
private struct KeyWidth: ViewModifier {
    let span: KeySpan
    let unit: CGFloat

    @ViewBuilder func body(content: Content) -> some View {
        switch span {
        case .units(let count):
            content.frame(width: unit * count
                + max(0, count - 1) * KeyboardMetrics.keySpacing)
        case .flexible:
            content.frame(maxWidth: .infinity)
        }
    }
}

struct KeyPopupView: View {
    let popup: KeyPopup

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(popup.items.enumerated()), id: \.offset) { index, item in
                Text(item)
                    .font(.system(size: 22))
                    .foregroundStyle(index == popup.selection
                        ? Theme.background : Theme.textPrimary)
                    .frame(width: popup.cellSize.width, height: popup.cellSize.height)
                    .background {
                        RoundedRectangle(cornerRadius: Theme.keyCornerRadius,
                                         style: .continuous)
                            .fill(index == popup.selection ? Theme.accent : Color.clear)
                    }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(Theme.surfacePressed)
                .shadow(color: Theme.background.opacity(0.6), radius: 10, y: 3)
        }
    }
}
