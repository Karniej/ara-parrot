import AppKit
import SwiftUI

/// Ara's palette and type, shared with the iOS app.
///
/// ## Why this is a copy and not an import
///
/// The iOS app (`Karniej/ara-ios`) carries the same identity in
/// `ios/Ara/Shared/Theme.swift`, and its rule is that hardcoding a colour
/// anywhere else is a review defect. This is that file, ported: the values are
/// the same numbers, the names are the same names, and the two `adaptive`
/// helpers differ only in that one wraps `UIColor` and this one wraps
/// `NSColor`. Two repositories cannot share a Swift file, so what keeps them
/// together is that this one says where it came from.
///
/// What is deliberately *not* ported is everything iOS has and macOS has no
/// surface for — the paywall tokens, the key caps, the rocker switch. A macOS
/// daemon has a menu bar, a pill and one setup window.
///
/// ## The rules that come with the colours
///
/// - **Amber is the only hue in the product.** It marks the live microphone
///   and nothing else. It is not a progress colour, not a button fill, and not
///   a way to make something look important.
/// - **Filled amber keeps `accentFill` in both appearances, with black on
///   top.** Only tints adapt.
/// - Elevation in the dark appearance is a lighter fill plus a one-pixel
///   hairline, not a shadow.
/// - Sentence case. No exclamation marks. The app does not congratulate the
///   user for finishing a step it asked them to do.
public enum Brand {
    // MARK: - Colour

    /// The tint. Adapts, because amber on warm paper at full strength is not
    /// legible — the light value is the same hue burnt down.
    public static let accent = adaptive(
        dark: NSColor(srgbRed: 1, green: 190 / 255, blue: 118 / 255, alpha: 1),
        light: NSColor(srgbRed: 168 / 255, green: 94 / 255, blue: 24 / 255, alpha: 1))
    /// The fill, which does *not* adapt: a filled amber control is amber in
    /// both appearances and always carries black glyphs.
    public static let accentFill = Color(red: 1, green: 190 / 255, blue: 118 / 255)
    public static let accentInk = Color.black

    public static let background = adaptive(
        dark: NSColor(srgbRed: 9 / 255, green: 9 / 255, blue: 8 / 255, alpha: 1),
        light: NSColor(srgbRed: 235 / 255, green: 228 / 255, blue: 216 / 255, alpha: 1))
    public static let paperLow = adaptive(
        dark: NSColor(srgbRed: 13 / 255, green: 12 / 255, blue: 11 / 255, alpha: 1),
        light: NSColor(srgbRed: 225 / 255, green: 216 / 255, blue: 201 / 255, alpha: 1))
    public static let plate = adaptive(
        dark: NSColor(srgbRed: 19 / 255, green: 18 / 255, blue: 17 / 255, alpha: 1),
        light: NSColor(srgbRed: 248 / 255, green: 243 / 255, blue: 233 / 255, alpha: 1))
    public static let rule = adaptive(
        dark: NSColor(srgbRed: 38 / 255, green: 35 / 255, blue: 32 / 255, alpha: 1),
        light: NSColor(srgbRed: 202 / 255, green: 190 / 255, blue: 170 / 255, alpha: 1))
    public static let ruleSoft = adaptive(
        dark: NSColor(srgbRed: 29 / 255, green: 27 / 255, blue: 25 / 255, alpha: 1),
        light: NSColor(srgbRed: 220 / 255, green: 211 / 255, blue: 194 / 255, alpha: 1))

    public static let textPrimary = adaptive(
        dark: NSColor(srgbRed: 242 / 255, green: 237 / 255, blue: 227 / 255, alpha: 1),
        light: NSColor(srgbRed: 26 / 255, green: 22 / 255, blue: 19 / 255, alpha: 1))
    public static let textSecondary = adaptive(
        dark: NSColor(srgbRed: 156 / 255, green: 148 / 255, blue: 136 / 255, alpha: 1),
        light: NSColor(srgbRed: 92 / 255, green: 83 / 255, blue: 71 / 255, alpha: 1))
    public static let textTertiary = adaptive(
        dark: NSColor(srgbRed: 128 / 255, green: 120 / 255, blue: 108 / 255, alpha: 1),
        light: NSColor(srgbRed: 112 / 255, green: 104 / 255, blue: 92 / 255, alpha: 1))

    public static let danger = adaptive(
        dark: NSColor(srgbRed: 1, green: 0.35, blue: 0.30, alpha: 1),
        light: NSColor(srgbRed: 0.76, green: 0.19, blue: 0.12, alpha: 1))

    /// The readout tones, which stay dark in both appearances on iOS — the
    /// hero panel there is a physical instrument window, not a card. The
    /// overlay pill is this daemon's only equivalent, and it floats over
    /// whatever the user happens to be looking at, so it keeps the same rule.
    public static let window = Color(red: 12 / 255, green: 11 / 255, blue: 9 / 255)
    public static let windowInk = Color(red: 241 / 255, green: 235 / 255, blue: 225 / 255)
    public static let windowInkSecondary = Color(red: 139 / 255, green: 129 / 255, blue: 115 / 255)
    /// The warm hairline around a readout. Dark-appearance elevation is this
    /// plus a lighter fill — never a shadow.
    public static let windowEdge = Color(red: 44 / 255, green: 35 / 255, blue: 24 / 255)

    // MARK: - Shape and type

    public static let cornerRadius: CGFloat = 12
    /// The radius iOS uses for its primary call to action, and the one this
    /// daemon's buttons use.
    public static let buttonCornerRadius: CGFloat = 14
    public static let cardCornerRadius: CGFloat = 16
    /// The overlay pill's, which predates the shared palette and is kept: at
    /// the pill's height it is within two points of a capsule.
    public static let pillCornerRadius: CGFloat = 18
    /// The screen gutter, from iOS.
    public static let gutter: CGFloat = 22

    /// Serif, and that is the identity: every other dictation tool on this
    /// platform is rounded sans, and a serif display face is the one thing a
    /// user sees before they read a word of it.
    public static let displayFont = Font.system(size: 26, weight: .semibold, design: .serif)
    public static let titleFont = Font.system(size: 19, weight: .semibold, design: .serif)
    /// The micro-label — "setup · 01 / 04", "on device". Monospaced, tracked
    /// out, and always short.
    public static let silkFont = Font.system(size: 9.5, weight: .medium, design: .monospaced)
    public static let silkTracking: CGFloat = 1.3
    public static let bodyFont = Font.system(size: 13, weight: .regular)
    public static let labelFont = Font.system(size: 13, weight: .semibold)

    private static func adaptive(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            // `bestMatch` rather than reading `.name` directly: an appearance
            // can be any of four (aqua, dark aqua, and both high-contrast
            // variants), and asking which of two it is closest to is the only
            // form that keeps working when Apple adds a fifth.
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark : light
        })
    }
}

/// The app icon, as a view: a solid parrot head with thin slits cut through
/// it, a hooked beak, and one eye.
///
/// ## Why slits and not bars
///
/// The first port of this took `AraBirdWaveMark` from the iOS app literally —
/// nine capsules with a gap between each — and it was wrong at every size the
/// daemon uses. The *icon* is the shape people recognise, and the icon is the
/// opposite arrangement: a solid amber mass with a few narrow black slits
/// through it. Wide light, thin dark. That reads at 16 points; nine separated
/// capsules do not, because at that size the gaps eat more of the bird than
/// the bars keep.
///
/// The slits still mean what the bars mean — audio, and feathers, at once —
/// and they are still asymmetric and mid-utterance rather than a symmetric
/// equaliser.
public struct AraBirdMark: View {
    public var color: Color
    /// What shows *through* the mark: the slits and the eye. It has to be
    /// whatever is behind the mark, because these are holes rather than marks.
    public var voidColor: Color
    /// Bar heights, or `nil` for the icon's own. Used by the launch animation,
    /// which walks a sequence of them.
    public var heights: [CGFloat]?

    public init(color: Color = Brand.accentFill,
                voidColor: Color = Brand.window,
                heights: [CGFloat]? = nil) {
        self.color = color
        self.voidColor = voidColor
        self.heights = heights
    }

    /// Where the slits fall and how far down each one runs, measured off
    /// `AppIcon-1024.png`. Four slits, uneven spacing, uneven depth — the
    /// asymmetry is the rule the iOS brand doc states, and a regular comb
    /// would read as an equaliser.
    static let slits: [(x: CGFloat, top: CGFloat, bottom: CGFloat)] = [
        (0.255, 0.10, 0.86),
        (0.345, 0.06, 0.78),
        (0.450, 0.00, 0.74),
        (0.545, 0.10, 0.72),
    ]
    static let slitWidth: CGFloat = 0.018

    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                AraParrotHead().fill(color)
                AraParrotBeak().fill(color)

                ForEach(Array(Self.slits.enumerated()), id: \.offset) { index, slit in
                    let depth = heights.map { $0[min(index, $0.count - 1)] } ?? 1
                    let top = size.height * slit.top
                    let full = size.height * (slit.bottom - slit.top)
                    Rectangle()
                        .fill(voidColor)
                        .frame(width: max(1, size.width * Self.slitWidth),
                               height: max(0, full * depth))
                        .offset(x: size.width * slit.x, y: top)
                }

                Circle()
                    .fill(voidColor)
                    .frame(width: size.width * 0.076)
                    .position(x: size.width * 0.45, y: size.height * 0.30)
            }
            .compositingGroup()
        }
        .aspectRatio(1.08, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ara")
    }
}

/// The iOS launch moment, ported: the slits open, the head carves itself out,
/// the beak grows, the eye arrives, and the wordmark lands under it.
///
/// The choreography and its timings are `LaunchMomentView` in the iOS app,
/// step for step, so a user who has seen ara start on their phone recognises
/// it starting on their Mac. It plays once, when the window appears.
///
/// Nothing here is load-bearing: a user who has `reduceMotion` on gets the
/// finished mark immediately, which is also what the animation ends at.
public struct AraLaunchMark: View {
    public var color: Color
    public var voidColor: Color
    /// Drawn under the mark once it settles. `nil` leaves it out — the setup
    /// window's header already carries a wordmark of its own.
    public var wordmark: Color?
    /// Which baked frame to draw, and whether the wordmark has landed. Both
    /// are driven from outside rather than by a `.task` here: a SwiftUI task
    /// runs on appear, and a view rendered for a check never appears — the
    /// first version of this animated correctly on screen and rendered as a
    /// closed mark in every image, which is the same as having no check at
    /// all. `SetupWindow` owns the clock.
    public var frame: Int
    public var settled: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(color: Color = Brand.accentFill,
                voidColor: Color = Brand.window,
                wordmark: Color? = nil,
                frame: Int = AraLaunchMark.frames.count - 1,
                settled: Bool = true) {
        self.color = color
        self.voidColor = voidColor
        self.wordmark = wordmark
        self.frame = frame
        self.settled = settled
    }

    /// The six baked frames of slit depth, from the iOS app's `liveHeights`
    /// reduced from nine bars to this mark's four slits. Frame 0 is the closed
    /// mark; the last frame is where it rests.
    public static let frames: [[CGFloat]] = [
        [0.00, 0.00, 0.00, 0.00],
        [0.30, 0.44, 0.34, 0.26],
        [0.72, 0.96, 0.74, 0.60],
        [0.86, 0.95, 0.85, 0.52],
        [1.00, 0.83, 0.95, 0.34],
        [0.90, 0.91, 0.87, 0.50],
    ]
    /// One frame's worth of time, from the iOS launch sequence.
    public static let frameSeconds: TimeInterval = 0.11

    public var body: some View {
        VStack(spacing: 12) {
            AraBirdMark(color: color, voidColor: voidColor,
                        heights: Self.frames[min(max(frame, 0), Self.frames.count - 1)])
                .animation(reduceMotion ? nil : .easeInOut(duration: Self.frameSeconds),
                           value: frame)
            if let wordmark {
                Text("ara")
                    .font(Brand.displayFont)
                    .foregroundStyle(wordmark)
                    .opacity(settled || reduceMotion ? 1 : 0)
                    .offset(y: settled || reduceMotion ? 0 : 8)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: settled)
            }
        }
    }
}

/// The same mark as one flat silhouette, for the menu bar.
///
/// The nine bars do not survive being 16 points tall — measured while building
/// the setup window's header, where the mark stopped reading as a bird below
/// about 28 points and became an amber smudge. A status item is 16, so the
/// bars go and the profile stays: head, hooked beak, and the eye punched
/// through, which is the part that makes it a face at any size.
///
/// A template image, so macOS tints it for the menu bar the user has — black
/// on a light bar, white on a dark one, and inverted while the menu is open.
/// That is also why the eye is a hole rather than a colour: a template image
/// has no colours, only coverage.
public enum AraMarkImage {
    /// The mark for the menu bar. `tint` is `nil` for the ordinary state — a
    /// template image, which macOS recolours for the bar it is on — and amber
    /// while the microphone is open, which is the one thing amber is allowed
    /// to mean. A tinted image cannot be a template: the system would throw
    /// the colour away.
    public static func mark(height: CGFloat, tint: NSColor? = nil) -> NSImage {
        let image = draw(height: height, ink: tint ?? .black)
        image.isTemplate = tint == nil
        return image
    }

    public static func template(height: CGFloat) -> NSImage {
        mark(height: height)
    }

    private static func draw(height: CGFloat, ink: NSColor,
                             slits: Bool = true) -> NSImage {
        let size = NSSize(width: (height * 1.08).rounded(), height: height)
        // Flipped, because `AraParrotHead` and `AraParrotBeak` are SwiftUI
        // shapes: their normalised points are measured from the top-left, and
        // an unflipped image context measures from the bottom-left. Drawn
        // unflipped the bird comes out upside down with the beak detached —
        // which is exactly what the first render of this showed.
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(ink.cgColor)
            context.addPath(AraParrotHead().path(in: rect).cgPath)
            context.addPath(AraParrotBeak().path(in: rect).cgPath)
            context.fillPath()

            // Cleared, not painted. A template image has no colours, only
            // coverage, so the slits and the eye have to be holes — which is
            // also what they are in the icon.
            context.setBlendMode(.clear)
            if slits {
                // Two slits in the menu bar, four everywhere else. Four is the
                // icon, and four at 16 points is a barcode: the mark is 34
                // device pixels wide, so four hairlines plus their anti-aliased
                // edges take most of the head. The pair kept is the pair that
                // frames the eye, which is what makes it a face.
                //
                // Snapped to device pixels for the same reason. Unsnapped, a
                // half-point slit lands across two pixels at half coverage
                // each and renders as a grey smear twice its width — which is
                // exactly how the four-slit version failed.
                let chosen = rect.height < 24
                    ? Array(AraBirdMark.slits[1 ... 2])
                    : AraBirdMark.slits
                for slit in chosen {
                    context.fill(CGRect(
                        x: (rect.width * slit.x * 2).rounded() / 2,
                        y: rect.height * slit.top,
                        // Half a point is the floor, which is one device pixel
                        // on a retina display and the same hairline the iOS
                        // icon keeps at its smallest sizes. A one-point floor
                        // was tried first and is twice that: four slits then
                        // take a quarter of the head and the bird reads as a
                        // barcode.
                        width: max(0.5, rect.width * AraBirdMark.slitWidth),
                        height: rect.height * (slit.bottom - slit.top)))
                }
            }
            let diameter = max(1.5, rect.width * 0.11)
            context.fillEllipse(in: CGRect(
                x: rect.width * 0.45 - diameter / 2,
                y: rect.height * 0.30 - diameter / 2,
                width: diameter, height: diameter))
            return true
        }
        return image
    }

    /// The amber the recording state uses, as an `NSColor` — `Brand.accentFill`
    /// is a SwiftUI `Color` and Core Graphics wants the other one.
    public static let recordingInk = NSColor(srgbRed: 1, green: 190 / 255,
                                             blue: 118 / 255, alpha: 1)
}

/// Normalised path, copied verbatim from the iOS app so the two marks are the
/// same shape rather than two drawings of the same idea.
struct AraParrotHead: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width, height = rect.height
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: width * x, y: height * y)
        }
        var path = Path()
        path.move(to: point(0.140, 1.000))
        path.addCurve(to: point(0.260, 0.290), control1: point(0.130, 0.700), control2: point(0.160, 0.440))
        path.addCurve(to: point(0.580, 0.140), control1: point(0.330, 0.150), control2: point(0.470, 0.090))
        path.addCurve(to: point(0.663, 0.285), control1: point(0.630, 0.170), control2: point(0.655, 0.230))
        path.addCurve(to: point(0.607, 0.615), control1: point(0.620, 0.380), control2: point(0.591, 0.510))
        path.addCurve(to: point(0.550, 0.712), control1: point(0.583, 0.655), control2: point(0.567, 0.686))
        path.addCurve(to: point(0.340, 0.725), control1: point(0.477, 0.732), control2: point(0.410, 0.735))
        path.addCurve(to: point(0.140, 1.000), control1: point(0.240, 0.765), control2: point(0.155, 0.850))
        path.closeSubpath()
        return path
    }
}

struct AraParrotBeak: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width, height = rect.height
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: width * x, y: height * y)
        }
        var path = Path()
        path.move(to: point(0.693, 0.280))
        path.addCurve(to: point(0.861, 0.580), control1: point(0.764, 0.335), control2: point(0.852, 0.450))
        path.addCurve(to: point(0.829, 0.790), control1: point(0.866, 0.690), control2: point(0.852, 0.750))
        path.addCurve(to: point(0.693, 0.596), control1: point(0.810, 0.707), control2: point(0.760, 0.632))
        path.addCurve(to: point(0.637, 0.615), control1: point(0.667, 0.584), control2: point(0.645, 0.591))
        path.addCurve(to: point(0.693, 0.280), control1: point(0.620, 0.510), control2: point(0.650, 0.380))
        path.closeSubpath()
        return path
    }
}
