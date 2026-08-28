import AppKit
import SwiftUI

/// The first-run window: one step at a time, drawn from `SetupFlow`.
///
/// Everything that decides anything is in `SetupFlow`, which is tested. This
/// draws what it is told, raises the two system prompts, and reports what the
/// user pressed. The one rule it owns is the activation policy: ara is
/// `LSUIElement`, and an accessory app cannot put a window in front of anyone
/// — the same lesson `StartupFailure` already learned — so the policy goes to
/// `.regular` while the window is up and back to `.accessory` when it closes.
@MainActor
public final class SetupWindow {
    /// What the window is waiting for, beyond the step itself.
    public enum Activity: Equatable, Sendable {
        case idle
        /// A download, as a whole percent, or `nil` before the hub has
        /// answered with a file listing.
        case downloading(percent: Int?)
        /// The compile. Carries elapsed seconds because there is no progress
        /// to show and a still window is what makes a user quit; a number that
        /// keeps moving is the whole of the reassurance available.
        case preparing(seconds: Int)
    }

    private var window: NSWindow?
    private let model = SetupModel()
    private var preparingTimer: Timer?
    private var launchPlayed = false
    private var launchTimer: Timer?
    private var closeWatcher: SetupWindowDelegate?
    /// Called when the user closes the window with its red button.
    ///
    /// The window is closable on purpose — a window a user cannot dismiss is
    /// worse than one they can — but who *owns* that close differs entirely
    /// by which launch this is. During the permission steps the daemon has not
    /// started and never will on this launch, so closing has to end the
    /// process; during the compile the daemon is running and a close is just a
    /// user who has read the message and wants their screen back. Only the
    /// caller knows which, so the window reports and decides nothing.
    public var onClose: (@MainActor () -> Void)?
    /// Called when the user presses the step's button. The caller owns what
    /// each press does — raising the microphone prompt, opening Settings,
    /// restarting, dismissing — because all of those are process-level acts
    /// and none of them belong to a view.
    public var onAction: (@MainActor (SetupFlow.Step, SetupFlow.Answer) -> Void)?

    public init() {}

    /// - Parameter activating: whether to take the foreground. True for a
    ///   first run, where nothing else is going on and the window *is* the
    ///   app. False when the window opens mid-warm-up — after an update, the
    ///   compile starts twenty seconds into a launch the user has already gone
    ///   back to work from, and pulling their focus out of what they are
    ///   typing to announce a wait is worse than the wait.
    public func show(step: SetupFlow.Step, activating: Bool = true) {
        model.step = step
        model.copy = SetupFlow.copy(for: step)
        ensureWindow()
        startLaunchMoment()
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        // After the policy, never before it. A Dock tile does not exist until
        // ara is a regular app, and an icon set while it is still an accessory
        // is dropped when the tile is finally created — which is exactly how
        // the first attempt at this failed, leaving the generic "exec" tile on
        // screen with nothing in the process able to tell.
        AraMarkImage.applyDockIcon()
        if activating {
            app.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }

    /// Moves to a new step, or updates the one on screen. Idempotent: the
    /// caller polls system state and may hand the same step back many times.
    ///
    /// Does nothing once the window is gone. A closed window must stay closed:
    /// the poll behind the permission steps runs twice a second, and reopening
    /// on the next tick would be a window the user cannot dismiss.
    public func update(step: SetupFlow.Step, activity: Activity = .idle) {
        guard window != nil else { return }
        model.step = step
        model.copy = SetupFlow.copy(for: step)
        setActivity(activity)
    }

    /// Whether a window is up. False before the first `show` and after any
    /// close, the user's included.
    public var isOpen: Bool { window != nil }

    /// Which step is on screen. Read by the caller's poll, which must not
    /// move a user off the restart step it deliberately put them on.
    public var currentStep: SetupFlow.Step { model.step }

    public func setActivity(_ activity: Activity) {
        // The elapsed counter is the window's own, not the caller's. The
        // compile reports nothing from the inside — there is no percentage and
        // no phase — so a number that keeps moving is the only evidence the
        // user has that the machine is still working. Driving it from here
        // means the caller cannot forget to.
        if case .preparing = activity {
            if preparingTimer == nil { startPreparingClock() }
            return
        }
        preparingTimer?.invalidate()
        preparingTimer = nil
        model.activity = activity
    }

    /// Leaves the launch moment after its choreography has run. Guarded so a
    /// second `show` — the caller polls, and a permission answer repaints —
    /// does not replay it.
    private func startLaunchMoment() {
        guard !launchPlayed else { return }
        launchPlayed = true
        var step = 0
        launchTimer = Timer.scheduledTimer(
            withTimeInterval: AraLaunchMark.frameSeconds, repeats: true
        ) { [weak self] timer in
            step += 1
            Task { @MainActor in
                guard let self else { return }
                if step < AraLaunchMark.frames.count {
                    self.model.launchFrame = step
                    return
                }
                // The mark has finished opening. The wordmark lands, it is
                // held long enough to read, and then the window gets on with
                // the thing the user is actually here for.
                self.model.launchSettled = true
                timer.invalidate()
                self.launchTimer = nil
                Timer.scheduledTimer(withTimeInterval: Self.holdSeconds,
                                     repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.model.launching = false }
                }
            }
        }
    }

    /// How long the settled wordmark stays before the window turns into a
    /// setup step. Long enough to read three letters, short enough that a user
    /// waiting on a permission prompt is not watching a logo.
    private static let holdSeconds: TimeInterval = 0.9

    private func startPreparingClock() {
        let started = Date()
        model.activity = .preparing(seconds: 0)
        preparingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.model.activity = .preparing(
                    seconds: Int(Date().timeIntervalSince(started)))
            }
        }
    }

    /// Closes the window and hands the screen back. The policy returns to
    /// `.accessory`, which is what makes ara a menu-bar app again — leaving it
    /// `.regular` would put a Dock icon on a daemon that has no windows.
    public func close() {
        window?.orderOut(nil)
        teardown()
    }

    /// Drops everything the window owns and hands the screen back. The policy
    /// returns to `.accessory`, which is what makes ara a menu-bar app again —
    /// leaving it `.regular` would put a Dock icon on a daemon that has no
    /// windows.
    private func teardown() {
        preparingTimer?.invalidate()
        preparingTimer = nil
        launchTimer?.invalidate()
        launchTimer = nil
        window?.delegate = nil
        closeWatcher = nil
        window = nil
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    private func ensureWindow() {
        if window != nil { return }
        let size = Self.contentSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "Ara Setup"
        window.titlebarAppearsTransparent = true
        // The titlebar shows the window's own background, and the content
        // paints `Brand.background` — without this the strip above the content
        // stays system grey and the window reads as two halves.
        window.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 9 / 255, green: 9 / 255, blue: 8 / 255, alpha: 1)
                : NSColor(srgbRed: 235 / 255, green: 228 / 255, blue: 216 / 255, alpha: 1)
        }
        window.isMovableByWindowBackground = true
        window.center()
        // No minimise and no resize: the window is five short steps and a
        // progress bar. A user who minimises it during the compile has hidden
        // the only thing telling them not to quit.
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false

        let host = NSHostingView(rootView: SetupView(model: model) { [weak self] step, answer in
            self?.onAction?(step, answer)
        })
        // `RecordingOverlay`'s lesson, and the same one line of fix: an
        // `NSHostingView`'s intrinsic size otherwise wins over the size the
        // window was built at, and the window comes up whatever the current
        // step happens to need.
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        // Held here, because `NSWindow.delegate` is unowned: a delegate that
        // only the window points at is deallocated immediately and the close
        // is never reported.
        let watcher = SetupWindowDelegate { [weak self] in
            guard let self else { return }
            // Torn down before the caller is told, so a caller that keeps the
            // process alive is not left holding a window that no longer exists
            // but still answers `update`.
            self.teardown()
            self.onClose?()
        }
        window.delegate = watcher
        closeWatcher = watcher
        self.window = window
    }

    /// Sized for the longest step, which is now one of the two questions: four
    /// lines of explanation plus a stacked pair of answers.
    ///
    /// 340 rather than the 300 it was. At 300 the question steps measured 297
    /// — three points of margin, which is not a margin, it is a near miss that
    /// the next word added to the copy would turn into a clipped button.
    /// `SetupVisualCheck` pins every step against this.
    public static let contentSize = CGSize(width: 480, height: 340)
}

/// The observable half of the window.
@MainActor
final class SetupModel: ObservableObject {
    @Published var step: SetupFlow.Step = .microphone
    @Published var copy: SetupFlow.Copy = SetupFlow.copy(for: .microphone)
    @Published var activity: SetupWindow.Activity = .idle
    /// The launch moment, which the window opens on and leaves once. It is not
    /// a loading screen — nothing is waiting on it — it is the app arriving,
    /// the same way the iOS app arrives.
    @Published var launching = true
    @Published var launchFrame = 0
    @Published var launchSettled = false
}

/// The window's contents at the window's size.
///
/// The fixed frame is what the window shows; `SetupContent` is the same view
/// without it, which is the only way to ask what a step actually needs — a
/// hosting view wrapped in an explicit frame answers every measurement with
/// that frame, which made the first version of `SetupVisualCheck` a test that
/// could not fail.
struct SetupView: View {
    @ObservedObject var model: SetupModel
    var action: (SetupFlow.Step, SetupFlow.Answer) -> Void

    var body: some View {
        ZStack {
            if model.launching {
                LaunchMoment(frame: model.launchFrame, settled: model.launchSettled)
                    .transition(.opacity)
            } else {
                SetupContent(model: model, action: action)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.32), value: model.launching)
        .frame(width: SetupWindow.contentSize.width,
               height: SetupWindow.contentSize.height,
               alignment: .topLeading)
    }

    static func elapsed(_ seconds: Int) -> String {
        SetupContent.elapsed(seconds)
    }
}

/// The launch moment: the mark, the wordmark, and nothing else.
///
/// Ported from `LaunchMomentView` in the iOS app. It plays once, when the
/// window opens, and lasts about as long as it takes to read the word — long
/// enough to be seen, short enough that nobody waiting on a setup step resents
/// it. The window it hands over to is doing the actual work.
struct LaunchMoment: View {
    var frame: Int = AraLaunchMark.frames.count - 1
    var settled: Bool = true

    var body: some View {
        VStack {
            Spacer()
            AraLaunchMark(voidColor: Brand.background,
                          wordmark: Brand.textPrimary,
                          frame: frame, settled: settled)
                .frame(width: 116, height: 152)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.background)
    }
}

/// The steps' words and controls, sized by their own content. The chassis is
/// `Brand`, ported from the iOS app: graphite, one serif display line, a
/// monospaced step counter, and amber used for nothing here at all — the
/// microphone is not open, and amber means the microphone is open.
struct SetupContent: View {
    @ObservedObject var model: SetupModel
    var action: (SetupFlow.Step, SetupFlow.Answer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Text(model.copy.title)
                .font(Brand.displayFont)
                .tracking(-0.4)
                .foregroundStyle(Brand.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(model.copy.detail)
                .font(Brand.bodyFont)
                .foregroundStyle(Brand.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            activityView

            Spacer(minLength: 0)

            footer
        }
        .padding(Brand.gutter)
        .background(Brand.background)
    }

    /// The bottom of the window.
    ///
    /// A step that asks a question stacks its answers, because that is what
    /// the iOS app does with a primary call to action and what the style is
    /// built for: full width, cream on graphite, with the other answer as
    /// plain text under it. Squeezed into a row beside a second button it
    /// reads as a slab crammed into a corner — which is exactly how the first
    /// version of this looked.
    ///
    /// A step with one action keeps the row, where the button is small enough
    /// to sit beside the "on device" mark without either crowding the other.
    @ViewBuilder
    private var footer: some View {
        if let alternative = model.copy.alternative, let button = model.copy.button {
            VStack(spacing: 10) {
                Button(button) { action(model.step, .primary) }
                    .buttonStyle(BrandButtonStyle(fullWidth: true))
                    .keyboardShortcut(.defaultAction)
                Button { action(model.step, .alternative) } label: {
                    Text(alternative)
                        .font(Brand.bodyFont)
                        .foregroundStyle(Brand.textSecondary)
                }
                .buttonStyle(.plain)
            }
        } else {
            HStack(alignment: .bottom) {
                Text("on device")
                    .font(Brand.silkFont)
                    .tracking(Brand.silkTracking)
                    .textCase(.uppercase)
                    .foregroundStyle(Brand.textTertiary)
                Spacer()
                if let button = model.copy.button {
                    Button(button) { action(model.step, .primary) }
                        .buttonStyle(BrandButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// The wordmark left of the mark, never stacked — the icon rule the iOS
    /// app states — plus the step counter it uses on the same line.
    private var header: some View {
        HStack(spacing: 9) {
            // The launch moment, which plays once when the window appears —
            // the same choreography as the iOS app's, so ara starting on a Mac
            // looks like ara starting on a phone. The slits are holes, so what
            // shows through them is the window's own background.
            AraLaunchMark(voidColor: Brand.background)
                .frame(height: 30)
            Text("ara")
                .font(Brand.titleFont)
                .foregroundStyle(Brand.textPrimary)
            Spacer()
            if let counter = Self.counter(for: model.step) {
                Text(counter)
                    .font(Brand.silkFont)
                    .tracking(Brand.silkTracking)
                    .textCase(.uppercase)
                    .foregroundStyle(Brand.textTertiary)
            }
        }
    }

    /// "setup · 01 / 04", the iOS onboarding header. `.restart` counts as the
    /// accessibility step it is still finishing, and `.done` has no number
    /// because there is nothing left to count.
    static func counter(for step: SetupFlow.Step) -> String? {
        let order: [SetupFlow.Step] = [.microphone, .accessibility, .download, .prepare]
        let counted = step == .restart ? .accessibility : step
        guard let index = order.firstIndex(of: counted) else { return nil }
        return String(format: "setup · %02d / %02d", index + 1, order.count)
    }

    @ViewBuilder
    private var activityView: some View {
        switch model.activity {
        case .idle:
            EmptyView()
        case .downloading(let percent):
            // Neutral, not amber. "Amber is not a progress color" is the iOS
            // rule and the reason the hue means anything at all.
            ProgressView(value: percent.map(Double.init) ?? 0, total: 100)
                .progressViewStyle(.linear)
                .tint(Brand.textSecondary)
                .opacity(percent == nil ? 0.4 : 1)
            Text(percent.map { "\($0)%" } ?? "starting")
                .font(Brand.silkFont)
                .tracking(Brand.silkTracking)
                .foregroundStyle(Brand.textTertiary)
        case .preparing(let seconds):
            // Indeterminate, because Core ML reports nothing at all from
            // inside the compile. The elapsed count is the only honest signal
            // that anything is still happening.
            ProgressView()
                .progressViewStyle(.linear)
                .tint(Brand.textSecondary)
            Text(Self.elapsed(seconds))
                .font(Brand.silkFont)
                .tracking(Brand.silkTracking)
                .foregroundStyle(Brand.textTertiary)
        }
    }

    static func elapsed(_ seconds: Int) -> String {
        String(format: "%d:%02d elapsed", seconds / 60, seconds % 60)
    }
}

/// The iOS primary call to action: the text colour as the fill, the background
/// colour as the label, radius 14. Amber is deliberately not used — a filled
/// amber button would spend the one hue the product has on a thing that is not
/// a microphone.
struct BrandButtonStyle: ButtonStyle {
    /// Full width for a question's primary answer, hugging otherwise. iOS
    /// only ever draws this style full width; at button size the cream fill
    /// stops reading as a call to action and starts reading as a slab.
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Brand.labelFont)
            .foregroundStyle(Brand.background)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, 18)
            .padding(.vertical, fullWidth ? 12 : 10)
            .background(
                RoundedRectangle(cornerRadius: Brand.buttonCornerRadius, style: .continuous)
                    .fill(Brand.textPrimary))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

/// Reports the window's red button to `SetupWindow`.
///
/// A separate object rather than `SetupWindow` conforming: `NSWindowDelegate`
/// inherits `NSObjectProtocol`, and making the whole main-actor class an
/// `NSObject` subclass to receive one callback is more surface than the
/// callback is worth.
private final class SetupWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: @MainActor () -> Void

    init(onClose: @escaping @MainActor () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { onClose() }
    }
}
