import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AraCore

/// The first-run window, measured and — on request — rendered offscreen.
///
/// ```
/// ARA_SETUP_SHOT=/tmp/shots swift test --filter SetupVisual
/// ```
///
/// The fit check runs always; the images are opt-in. This exists because the
/// overlay shipped once at 44 points tall and clipped its own messages, and
/// nothing failed — the layout was wrong in a way that only looking could
/// show. The window is a worse place to repeat that: it is the first thing a
/// new user ever sees of ara, and its longest step is the one explaining the
/// restart they have to perform.
///
/// Offscreen with `ImageRenderer`, never `screencapture`: an earlier attempt
/// at that photographed the user's desktop instead of the view.
///
/// One thing the images do not show honestly: an *indeterminate*
/// `ProgressView` has no still frame, and the renderer draws a placeholder
/// where the animated bar goes. The compile step is the one that uses it. Its
/// layout, and the space the bar occupies, are still what the window will do.
@Suite("SetupVisual", .serialized)
struct SetupVisualCheck {
    static var directory: String? {
        ProcessInfo.processInfo.environment["ARA_SETUP_SHOT"]
    }

    /// Every step, in the state that asks for the most room: the two waiting
    /// steps carry their progress row, which the idle steps do not have.
    @MainActor
    static var cases: [(String, SetupFlow.Step, SetupWindow.Activity)] {
        [
            ("microphone", .microphone, .idle),
            ("accessibility", .accessibility, .idle),
            ("restart", .restart, .idle),
            ("download", .download, .downloading(percent: 45)),
            ("download-start", .download, .downloading(percent: nil)),
            ("prepare", .prepare, .preparing(seconds: 154)),
            ("done", .done, .idle),
        ]
    }

    @MainActor
    static func model(step: SetupFlow.Step, activity: SetupWindow.Activity) -> SetupModel {
        let model = SetupModel()
        model.step = step
        model.copy = SetupFlow.copy(for: step)
        model.activity = activity
        return model
    }

    @MainActor
    static func view(step: SetupFlow.Step, activity: SetupWindow.Activity) -> SetupView {
        SetupView(model: model(step: step, activity: activity)) { _, _ in }
    }

    /// The same content with no frame of its own, proposed the window's width.
    /// What comes back is the height the step needs — which is the question,
    /// and which `SetupView` cannot answer because it carries the answer in it.
    @MainActor
    static func unframed(step: SetupFlow.Step,
                         activity: SetupWindow.Activity) -> NSHostingView<some View> {
        NSHostingView(
            rootView: SetupContent(model: model(step: step, activity: activity)) { _, _ in }
                .frame(width: SetupWindow.contentSize.width))
    }

    /// What each step wants, against what the window gives it. The window is
    /// fixed-size on purpose — a resizable first-run window is one a user can
    /// make too small to read — so anything that wants more than this is
    /// clipped on screen.
    @MainActor
    @Test("every step fits the window it is shown in")
    func everyStepFits() {
        for (name, step, activity) in Self.cases {
            let wanted = Self.unframed(step: step, activity: activity).fittingSize
            print("setup-size: \(name) wants \(Int(wanted.width)) x \(Int(wanted.height))"
                + " (window \(Int(SetupWindow.contentSize.width))"
                + " x \(Int(SetupWindow.contentSize.height)))")
            #expect(wanted.height <= SetupWindow.contentSize.height,
                    "\(name) needs \(wanted.height)pt of height")
            #expect(wanted.width <= SetupWindow.contentSize.width,
                    "\(name) needs \(wanted.width)pt of width")
        }
    }

    @MainActor
    @Test("render every step at the window's size")
    func renderSteps() throws {
        guard let directory = Self.directory else { return }
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)

        for (name, step, activity) in Self.cases {
            let renderer = ImageRenderer(
                content: Self.view(step: step, activity: activity)
                    .frame(width: SetupWindow.contentSize.width,
                           height: SetupWindow.contentSize.height))
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else {
                Issue.record("could not render \(name)")
                continue
            }
            let path = "\(directory)/setup-\(name).png"
            try png.write(to: URL(fileURLWithPath: path))
            print("setup-shot: \(name) → \(path)")
        }
    }

    /// The real AppKit view, not a re-render of the SwiftUI tree.
    ///
    /// `ImageRenderer` cannot draw an indeterminate `ProgressView` — it has no
    /// still frame, and the renderer substitutes a placeholder. That is
    /// exactly the control the compile step leans on for two and a half
    /// minutes, so the one image worth having is the one AppKit itself draws.
    /// `cacheDisplay(in:to:)` takes it from the view's own backing store: no
    /// screen, no window server, and nothing of the user's desktop in it.
    @MainActor
    @Test("the live window draws its own progress control")
    func liveWindowDraws() throws {
        guard let directory = Self.directory else { return }
        let host = NSHostingView(rootView: Self.view(step: .prepare,
                                                     activity: .preparing(seconds: 154)))
        host.frame = NSRect(origin: .zero, size: SetupWindow.contentSize)
        host.layoutSubtreeIfNeeded()
        // One turn of the run loop: SwiftUI builds its AppKit backing lazily,
        // and a view captured in the same tick is captured empty.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            Issue.record("no bitmap representation")
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            Issue.record("could not encode the live window")
            return
        }
        let path = "\(directory)/setup-live-prepare.png"
        try png.write(to: URL(fileURLWithPath: path))
        print("setup-live: prepare → \(path)")
    }

    /// Every frame of the launch moment, plus the settled state with the
    /// wordmark. Renderable at all only because the frames are driven from
    /// outside the view: the first version animated itself with a `.task`,
    /// which never runs for a view that is not in a window, so every image of
    /// it came out as the closed mark.
    @MainActor
    @Test("render the launch moment, frame by frame")
    func renderLaunchMoment() throws {
        guard let directory = Self.directory else { return }
        for frame in 0 ..< AraLaunchMark.frames.count {
            try Self.write(LaunchMoment(frame: frame, settled: false),
                           to: "\(directory)/launch-\(frame).png")
        }
        try Self.write(LaunchMoment(frame: AraLaunchMark.frames.count - 1, settled: true),
                       to: "\(directory)/launch-settled.png")
        print("setup-live: launch frames → \(directory)/launch-*.png")
    }

    /// Renders a view through AppKit's own drawing rather than `ImageRenderer`,
    /// which cannot draw an indeterminate progress control. Nothing of the
    /// screen is in it: `cacheDisplay` reads the view's own backing store.
    @MainActor
    static func write(_ view: some View, to path: String) throws {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: SetupWindow.contentSize)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            Issue.record("no bitmap representation for \(path)")
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            Issue.record("could not encode \(path)")
            return
        }
        try png.write(to: URL(fileURLWithPath: path))
    }

    /// The clock the compile step shows. It is the only moving thing on screen
    /// during a wait of two and a half minutes, so it has to read as time
    /// rather than as a counter that ran away.
    @Test("the elapsed clock reads as minutes and seconds")
    func elapsedReadsAsTime() {
        #expect(SetupView.elapsed(0) == "0:00 elapsed")
        #expect(SetupView.elapsed(9) == "0:09 elapsed")
        #expect(SetupView.elapsed(154) == "2:34 elapsed")
    }
}

/// The menu-bar mark, at the size the menu bar actually uses and again at
/// eight times that. The small one is the truth; the large one is the only way
/// to see what the small one is doing.
@Suite("MarkVisual", .serialized)
struct MarkVisualCheck {
    @MainActor
    @Test("render the status-item mark")
    func renderMark() throws {
        guard let directory = SetupVisualCheck.directory else { return }
        // At 1× and at 2×. The menu bar on any current Mac is 2×, and a 1×
        // rasterisation of a 16-point mark is not what anybody sees — the
        // first look at this judged a grey smear that only existed in the
        // export.
        for height in [16.0, 18.0, 128.0] {
            for scale in [1, 2] {
                let image = AraMarkImage.template(height: height)
                let pixels = NSSize(width: image.size.width * CGFloat(scale),
                                    height: image.size.height * CGFloat(scale))
                guard let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                    isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0)
                else {
                    Issue.record("no bitmap for \(height)@\(scale)x")
                    continue
                }
                rep.size = image.size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                image.draw(in: NSRect(origin: .zero, size: image.size))
                NSGraphicsContext.restoreGraphicsState()
                guard let png = rep.representation(using: .png, properties: [:]) else {
                    Issue.record("could not encode the mark at \(height)@\(scale)x")
                    continue
                }
                let path = "\(directory)/mark-\(Int(height))@\(scale)x.png"
                try png.write(to: URL(fileURLWithPath: path))
                print("mark-shot: \(Int(height))@\(scale)x → \(path)")
            }
        }
    }

    /// The Dock icon, at the size the Dock actually asks for — and, when
    /// `ARA_ICON_MASTER` names a path, the 1024px master that
    /// `scripts/build-icon.sh` turns into `packaging/Ara.icns`.
    ///
    /// The icon is generated rather than drawn in an editor, so the bundle's
    /// icon, the Dock tile, the menu bar and the setup window are all one
    /// shape. This is where the generator lives, because it is already the
    /// place that can run AppKit drawing and write a file.
    @MainActor
    @Test("render the app icon")
    func renderAppIcon() throws {
        if let master = ProcessInfo.processInfo.environment["ARA_ICON_MASTER"] {
            let image = AraMarkImage.appIcon(size: 1024)
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else {
                Issue.record("could not render the icon master")
                return
            }
            try png.write(to: URL(fileURLWithPath: master))
            print("icon-master: → \(master)")
        }
        guard let directory = SetupVisualCheck.directory else { return }
        let image = AraMarkImage.appIcon(size: 512)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            Issue.record("could not render the app icon")
            return
        }
        try png.write(to: URL(fileURLWithPath: "\(directory)/app-icon.png"))
        print("mark-shot: app icon → \(directory)/app-icon.png")
    }

    /// A status item is nominally 18 points tall and the mark is drawn to fit
    /// inside that. Its aspect ratio is the iOS mark's, not a square.
    @MainActor
    @Test("the mark keeps the iOS aspect ratio")
    func markAspect() {
        let image = AraMarkImage.template(height: 16)
        #expect(image.size.height == 16)
        #expect(image.size.width == 17)
        #expect(image.isTemplate)
    }
}

/// Puts a real Dock tile on screen for a few seconds so its icon can be
/// looked at. Opt-in, because it turns the test process into a regular app.
///
/// ```
/// ARA_DOCK_CHECK=1 swift test --filter DockIcon
/// ```
///
/// Exists because the first attempt at this — `applicationIconImage` set at
/// startup — left the generic "exec" tile on screen, and nothing in the
/// process could tell: the Dock draws the tile, not us.
@Suite("DockIcon", .serialized)
struct DockIconCheck {
    @MainActor
    @Test("show a Dock tile carrying the app icon")
    func showsDockTile() {
        guard ProcessInfo.processInfo.environment["ARA_DOCK_CHECK"] == "1" else { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        AraMarkImage.applyDockIcon()
        print("dock-check: tile up for 12 seconds — look at the Dock")
        RunLoop.main.run(until: Date().addingTimeInterval(12))
        app.setActivationPolicy(.accessory)
    }
}
