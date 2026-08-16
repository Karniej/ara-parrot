import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AraCore

/// Opt-in visual check: renders the overlay pill offscreen, at exactly the size
/// its panel proposes, so its layout can be looked at instead of reasoned
/// about.
///
/// ```
/// ARA_OVERLAY_SHOT=/tmp/shots swift test --filter OverlayVisual
/// ```
///
/// Exists because a field screenshot showed the error pill's text overflowing
/// its own background and being clipped by the panel — a layout that reading
/// the SwiftUI could not explain.
///
/// **Offscreen on purpose.** The first attempt showed the real panel and ran
/// `screencapture`, which photographed the user's desktop rather than the pill.
/// `ImageRenderer` needs no window, no activation and no screen, and it cannot
/// capture anything but the view it is given.
@Suite("OverlayVisual", .serialized)
struct OverlayVisualCheck {
    static var directory: String? {
        ProcessInfo.processInfo.environment["ARA_OVERLAY_SHOT"]
    }

    /// The content size of `RecordingOverlay`'s panel. The pill is centred in
    /// this and anything it needs beyond it is clipped, exactly as on screen.
    static let panel = CGSize(width: 520, height: 84)

    /// Every state the pill can be asked to show, with the longest real string
    /// for each shape.
    @MainActor
    static var states: [(String, RecordingOverlay.State)] {
        [
            ("error-no-audio", .error("no audio captured")),
            ("error-silence", .error("only silence — check your microphone")),
            ("error-longest", .error("too short — your mic starts late; hold the key longer")),
            ("warmup-neural", .warmingUp(title: "Preparing the Neural Engine",
                                         detail: "one-time for this macOS version · a few minutes")),
            ("warmup-download", .warmingUp(title: "Downloading the speech model… 45%",
                                           detail: "whisper-large-v3-turbo")),
            ("ready", .warmingUp(title: "ready — hold right ⌥ to dictate", detail: nil)),
            ("recording-note", .recording(note: "mlx cleanup unavailable · basic punctuation")),
        ]
    }

    /// What the pill actually wants, with no window and no screen.
    @MainActor
    static func idealSize(for state: RecordingOverlay.State) -> CGSize {
        let model = OverlayModel()
        model.state = state
        let host = NSHostingView(rootView: OverlayPill(model: model))
        return host.fittingSize
    }

    @MainActor
    @Test("render every pill state at the panel's size")
    func renderStates() throws {
        guard let directory = Self.directory else { return }
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)

        for (name, state) in Self.states {
            let model = OverlayModel()
            model.state = state
            let renderer = ImageRenderer(
                content: OverlayPill(model: model)
                    .frame(width: Self.panel.width, height: Self.panel.height)
                    .background(Color(red: 0.1, green: 0.1, blue: 0.12)))
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else {
                Issue.record("could not render \(name)")
                continue
            }
            let path = "\(directory)/\(name).png"
            try png.write(to: URL(fileURLWithPath: path))
            print("overlay-shot: \(name) → \(path)")
        }
    }



    /// The panel a freshly built overlay creates. Every `RecordingOverlay`
    /// makes its own, and earlier tests leave theirs in `NSApplication.shared.windows` — some
    /// still ordered out asynchronously — so "the last panel" is not reliably
    /// this test's. Identity is.
    @MainActor
    static func newPanel(besides existing: Set<ObjectIdentifier>) -> NSPanel? {
        NSApplication.shared.windows.first { !existing.contains(ObjectIdentifier($0)) } as? NSPanel
    }

    @MainActor
    static func windowIdentities() -> Set<ObjectIdentifier> {
        Set(NSApplication.shared.windows.map { ObjectIdentifier($0) })
    }

    /// What the REAL panel gives the pill, as opposed to what the pill wants.
    ///
    /// `idealSize` measures an unconstrained view and says everything fits.
    /// The field says otherwise — "no audio captured" rendered as three lines
    /// with "captured" broken across two of them, which needs a proposed width
    /// of about sixty points. So the panel is not proposing its own bounds,
    /// and this probe is the difference between the two.
    @MainActor
    @Test("the live panel proposes its full width to the pill")
    func livePanelProposesItsFullWidth() {
        let existing = Self.windowIdentities()
        let overlay = RecordingOverlay()
        overlay.show(.hidden)
        overlay.show(.error("no audio captured"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        guard let panel = Self.newPanel(besides: existing),
              let content = panel.contentView else {
            Issue.record("no panel was created")
            return
        }
        print("overlay-live: panel frame  = \(panel.frame.size)")
        print("overlay-live: content frame = \(content.frame.size)")
        print("overlay-live: content fitting = \(content.fittingSize)")
        overlay.hide()
        #expect(content.frame.width >= Self.panel.width,
                "the pill is proposed \(content.frame.width)pt of width, not \(Self.panel.width)pt")
    }

    /// Every message the pill can be asked to show must fit the panel it is
    /// shown in. Not opt-in, and needs no screen: `fittingSize` is what the
    /// view wants, and the panel is a constant.
    ///
    /// This is the check that was missing. The panel used to be 460x44 while
    /// the two-line warm-up states want 54 points of height, so they were
    /// clipped top and bottom — a user reported exactly that, and nothing in
    /// the suite could have caught it. Widening the panel fixed the instance;
    /// this fixes the class.
    ///
    /// Both bounds matter. Height is what clipped before. Width is what makes
    /// a message wrap into more lines than it needs, which is how a one-line
    /// sentence becomes a three-line block that then overflows the height.
    @MainActor
    @Test("every message fits the panel it is shown in")
    func everyStateFitsThePanel() {
        for (name, state) in Self.states {
            let size = Self.idealSize(for: state)
            print(String(format: "overlay-size: %@ wants %.0f x %.0f (panel %.0f x %.0f)",
                         name, size.width, size.height,
                         Self.panel.width, Self.panel.height))
            #expect(size.width <= Self.panel.width,
                    "\(name) wants \(size.width)pt of width; the panel is \(Self.panel.width)pt")
            #expect(size.height <= Self.panel.height,
                    "\(name) wants \(size.height)pt of height; the panel is \(Self.panel.height)pt")
        }
    }
}
