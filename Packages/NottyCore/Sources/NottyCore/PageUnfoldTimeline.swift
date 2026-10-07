import Foundation

/// The frost that clears down a page as it is added: the inner panel's clearing from the Duo
/// opening of Duo Open (its hinge script, hinge-to-tilt mapping, tilt follower and hand-off), with
/// the hinge laid along the new page's top edge instead of down the device's centre.
///
/// The page is one glass pane tilted about that edge, its far edge toward an eye on the page's
/// normal through the hinge. The farther a point lies below the edge, the wider the gap between
/// glass and paper there, and so the blur and the light lost; as the pane lands flat the page
/// clears from its top edge down, and the live page takes over for the last of the frost.
///
/// The model measures distances below the hinge on a fixed scale: the page's far edge lies
/// `extent` below the hinge however tall the page is, so every page frosts alike. The page itself
/// keeps its size; only the model's distance from the hinge is scaled.
///
/// Deterministic and free of timers: the renderer reports each frame it draws and draws what
/// comes back. Angles are degrees, lengths page points and times milliseconds.
public struct PageUnfoldTimeline: Equatable, Sendable {
    /// A point the hinge script passes through: its time, its angle and its slope in degrees per
    /// millisecond.
    public struct HingeKey: Equatable, Sendable {
        public let time: Double
        public let angle: Double
        public let slope: Double
    }

    public enum Phase: Equatable, Sendable {
        /// The frost is still clearing.
        case clearing
        /// The frost has cleared and the live page shows.
        case finished
        /// The device could not draw the frost at a usable rate, so it ends at once.
        case abandoned
    }

    /// What to draw for one frame.
    public struct Frame: Equatable, Sendable {
        /// The pane's tilt about the page's top edge.
        public let tilt: Double
        /// The blur radius at the page's bottom edge, the farthest from the hinge.
        public let farEdgeRadius: Double
        /// Opacity of the frost over the live page: 1 until the hand-off, then down to 0.
        public let fade: Double
        /// The most blur taps a pixel may take.
        public let taps: Int
        public let phase: Phase

        public var isFinished: Bool { phase != .clearing }
    }

    // MARK: - Model

    /// The most the pane tilts.
    public static let maximumTilt = 45.0
    /// The hinge angle at which the device lies flat and the pane has no tilt.
    public static let flatHinge = 172.0
    /// The hinge angle at which the inner panel first shows, frosted at its steepest.
    public static let panelOnHinge = 20.0
    /// With both panes moving, each tilts this share of the full mapping.
    public static let bothPanesScale = 0.6
    /// Blur radius per point of gap between the glass and the paper.
    public static let blurSpread = 0.12
    /// Light lost per unit of blur radius, at `referencePointsPerMillimetre`.
    public static let darkening = 0.015
    /// The density the darkening is authored at.
    public static let referencePointsPerMillimetre = 6.0
    /// The density the eye's distance and the darkening are converted at: the source's CSS pixels
    /// per millimetre, not the iPad's. The source's blur is in on-screen units, as a page point
    /// is, so a blur of so many of its pixels is one of as many page points.
    public static let sourcePixelsPerMillimetre = 96 / 25.4
    /// How far back the eye sits on the page's normal through the hinge.
    public static let eyeDistanceMillimetres = 450.0
    /// The extent at which the frost blurs and dims a page as the source's opening does its screen:
    /// the distance from its hinge to its screen's outer edge, half the open screen's width in a
    /// 1,440 × 900 CSS viewport by the source's own sizing rule, (1,296 − 2 × 19.8) / 2. That is
    /// the viewport less an 8 vmin margin a side, then less a 2.2 vmin bezel a side. The source's
    /// own value follows the window: about 565 to 667 in common laptop windows, 814 in a full
    /// 1080p one.
    public static let sourceHalfScreen = 628.2
    /// How far below the hinge the model takes a new page's far edge to lie: near enough that the
    /// page's bottom keeps 60% of its light at the panel swap, under a blur of about 16.8 points.
    /// Over light ivory paper the dimming of the source's half screen reads as a dark wipe.
    public static let frostExtent = 299.37
    /// Time constant of the follower that eases the drawn tilt toward the script's.
    public static let followerTimeConstant = 45.0
    /// Blur taps per pixel at most, and the fewest the frame budget can bring them down to.
    public static let maximumTaps = 32
    public static let minimumTaps = 6
    /// The hinge script from closed to flat as a hand opens the device: a quick crack open, a
    /// deliberate pull to the panel swap, then a confident swing that lands gently. Its slopes keep
    /// every segment of the cubic Hermite through these keys monotonic.
    public static let hingeKeys = [
        HingeKey(time: 0, angle: 0, slope: 0),
        HingeKey(time: 50, angle: 6, slope: 0.1),
        HingeKey(time: 160, angle: 11, slope: 0.03),
        HingeKey(time: 520, angle: 20, slope: 0.04),
        HingeKey(time: 1_060, angle: 180, slope: 0)
    ]
    /// The frost starts where the inner panel first shows, so the page clears at once.
    public static let scriptStart = hingeKeys.first { $0.angle >= panelOnHinge }?.time ?? 0
    /// The blur at the far edge under which the live page starts to take over, and under which
    /// what is left can no longer be seen.
    public static let handOffRadius = 1.5
    public static let unseenRadius = 0.25

    // MARK: - Frame rate

    /// GPU time per frame above which the blur takes fewer taps.
    public static let frameBudget = 12.0
    /// Each frame over budget keeps this share of the taps.
    public static let tapReduction = 0.7
    /// A frame this long is slow; `slowFrameLimit` in a row end the frost at once rather than
    /// play it as a slideshow.
    public static let slowFrameInterval = 50.0
    public static let slowFrameLimit = 2
    /// The first frames carry the start's own work and first raster, so they are never counted
    /// as slow.
    public static let graceFrames = 2
    /// How long the frost takes to fade out when the slow-frame guard ends it.
    public static let skipDuration = 120.0
    /// Pixels per page point at most: the snapshot behind the glass has no finer detail, so more
    /// would only add taps.
    public static let maximumPixelsPerPoint = 2.0
    /// The most pixels the frost draws in all.
    public static let maximumPixels = 6_500_000.0

    /// Intervals this short are not display frames, such as the first frame's.
    private static let shortestDisplayInterval = 4.0
    /// Without a GPU time, a frame this many times the display's interval was missed by the
    /// display, and its interval stands in for its cost.
    private static let missedFrameFactor = 1.5
    /// Frames after the first few whose interval may stand in for their cost.
    private static let firstCostedFrame = 4
    /// The follower lands on its target once this close.
    private static let followerSnap = 0.02
    /// The follower never steps further than this in one frame, however long the frame.
    private static let longestFollowerStep = 100.0
    /// Tilts past this are clamped by the projection.
    private static let steepestProjectedTilt = 60.0

    // MARK: - State

    public let pageHeight: Double
    /// The model's distance from the hinge to the page's far edge.
    public let extent: Double
    /// The model's distance from the hinge per page point below it: `extent` over `pageHeight`, or
    /// 1 where either is not a positive finite length.
    public let distanceScale: Double
    /// The eye's distance from the page, in page points.
    public let eyeDistance: Double
    /// Light lost per point of blur radius.
    public let darkeningPerPoint: Double
    public private(set) var phase = Phase.clearing
    /// The tilt drawn last.
    public private(set) var tilt: Double
    /// The most blur taps a pixel may take.
    public private(set) var taps = maximumTaps
    private var frames = 0
    private var slowFrames = 0
    private var displayInterval = Double.infinity

    /// - Parameters:
    ///   - pageHeight: the new page's height in points: the distance from the hinge to the far edge.
    ///   - extent: how far below the hinge the model takes the far edge to lie. The page's own
    ///     height leaves its distances unscaled, as does an extent or a height that is not a
    ///     positive finite length.
    ///   - pointsPerMillimetre: the density the eye's distance and the darkening are converted at.
    public init(
        pageHeight: Double, extent: Double = frostExtent,
        pointsPerMillimetre: Double = sourcePixelsPerMillimetre
    ) {
        self.pageHeight = pageHeight
        self.extent = extent
        let scale = extent / pageHeight
        // The shader divides by the scale, so it must be a usable positive number.
        distanceScale = extent > 0 && pageHeight > 0 && scale.isNormal ? scale : 1
        eyeDistance = Self.eyeDistanceMillimetres * pointsPerMillimetre
        darkeningPerPoint = (Self.darkening * Self.referencePointsPerMillimetre) / pointsPerMillimetre
        tilt = Self.tilt(atHinge: Self.hinge(at: Self.scriptStart))
    }

    /// The frame for the state as it stands: before the first `advance`, the frost at its steepest.
    public var currentFrame: Frame {
        Frame(
            tilt: tilt, farEdgeRadius: radius(atDistance: pageHeight, tilt: tilt), fade: handOff(tilt: tilt),
            taps: taps, phase: phase
        )
    }

    /// Advances to the frame drawn `elapsed` after the first, `interval` after the frame before it
    /// (0 for the first frame).
    ///
    /// - Parameter gpuTime: the GPU's time for a frame measured since the last call, if any. Without
    ///   it, a frame the display missed counts its interval as its cost.
    public mutating func advance(elapsed: Double, interval: Double, gpuTime: Double? = nil) -> Frame {
        guard phase == .clearing else { return currentFrame }
        slowFrames = Self.slowStreak(slowFrames, frame: frames, interval: interval)
        if slowFrames >= Self.slowFrameLimit {
            phase = .abandoned
            return currentFrame
        }
        if interval > Self.shortestDisplayInterval {
            displayInterval = min(displayInterval, interval)
        }
        let missed = frames >= Self.firstCostedFrame && interval > displayInterval * Self.missedFrameFactor
        let cost = gpuTime ?? (missed ? interval : 0)
        frames += 1
        taps = Self.taps(taps, afterFrameCost: cost)
        let target = Self.tilt(atHinge: Self.hinge(at: Self.scriptStart + elapsed))
        tilt = Self.follow(tilt, toward: target, interval: interval)
        let frame = currentFrame
        if frame.fade == 0 {
            phase = .finished
            return currentFrame
        }
        return frame
    }

    // MARK: - Script and follower

    /// The scripted hinge angle `time` into the script.
    public static func hinge(at time: Double) -> Double {
        guard let first = hingeKeys.first, let last = hingeKeys.last else { return 0 }
        guard time > first.time else { return first.angle }
        for (start, end) in zip(hingeKeys, hingeKeys.dropFirst()) where time <= end.time {
            let span = end.time - start.time
            let s = (time - start.time) / span
            let s2 = s * s
            let s3 = s2 * s
            let startTerm = (2 * s3 - 3 * s2 + 1) * start.angle
            let startSlope = (s3 - 2 * s2 + s) * span * start.slope
            let endTerm = (-2 * s3 + 3 * s2) * end.angle
            let endSlope = (s3 - s2) * span * end.slope
            return startTerm + startSlope + endTerm + endSlope
        }
        return last.angle
    }

    /// The pane's tilt at a hinge angle: from `panelOnHinge` to `flatHinge` it falls linearly from
    /// `maximumTilt` scaled by `bothPanesScale` to 0.
    public static func tilt(atHinge hinge: Double) -> Double {
        guard !hinge.isNaN else { return 0 }
        let progress = unit((flatHinge - hinge) / (flatHinge - panelOnHinge))
        return min(maximumTilt, progress * maximumTilt * bothPanesScale)
    }

    /// One frame of the drawn tilt easing exponentially toward `target`.
    public static func follow(_ tilt: Double, toward target: Double, interval: Double) -> Double {
        let step = min(longestFollowerStep, max(0, interval))
        let next = tilt + (target - tilt) * (1 - exp(-step / followerTimeConstant))
        return abs(target - next) < followerSnap ? target : next
    }

    // MARK: - Frost

    /// The blur radius the eye sees `distance` page points below the hinge with the pane at `tilt`.
    /// Inverting the projection along the page, a point the model places u = `distance`·`distanceScale`
    /// below the hinge is seen through the pane at d = u·E / (E·cos t + u·sin t), and the radius is
    /// `blurSpread`·d·sin t.
    public func radius(atDistance distance: Double, tilt: Double) -> Double {
        let angle = Self.radians(min(Self.steepestProjectedTilt, max(0, tilt)))
        guard angle >= 1e-4 else { return 0 }
        let u = abs(distance) * distanceScale
        let d = (u * eyeDistance) / (eyeDistance * cos(angle) + u * sin(angle))
        return Self.blurSpread * d * sin(angle)
    }

    /// The light kept at a blur radius: frosted glass absorbs in proportion to how much it scatters.
    public func attenuation(radius: Double) -> Double {
        max(1 - darkeningPerPoint * radius, 0)
    }

    /// How much of the frost is left at `tilt`: 1 until the far edge's blur falls under
    /// `handOffRadius`, then down to 0 as it reaches `unseenRadius`.
    public func handOff(tilt: Double) -> Double {
        let far = radius(atDistance: pageHeight, tilt: tilt)
        return Self.unit((far - Self.unseenRadius) / (Self.handOffRadius - Self.unseenRadius))
    }

    // MARK: - Frame rate

    /// The run of slow frames after the `frame`th frame of the motion took `interval`.
    public static func slowStreak(_ streak: Int, frame: Int, interval: Double) -> Int {
        frame >= graceFrames && interval > slowFrameInterval ? streak + 1 : 0
    }

    /// The tap limit after a frame that cost `cost`: fewer taps while frames run over budget,
    /// never fewer than `minimumTaps`.
    public static func taps(_ taps: Int, afterFrameCost cost: Double) -> Int {
        guard cost > frameBudget, taps > minimumTaps else { return taps }
        return max(minimumTaps, Int((Double(taps) * tapReduction).rounded()))
    }

    /// The frost's pixels per page point: the screen's, held to `maximumPixelsPerPoint` and to
    /// `maximumPixels` over the page. A page zoomed out has fewer than one pixel per point.
    public static func pixelsPerPoint(width: Double, height: Double, screenPixelsPerPoint: Double) -> Double {
        let screen = screenPixelsPerPoint > 0 ? screenPixelsPerPoint : 1
        let area = max(width * height, 1)
        return min(maximumPixelsPerPoint, screen, (maximumPixels / area).squareRoot())
    }

    private static func radians(_ degrees: Double) -> Double {
        (degrees * .pi) / 180
    }

    private static func unit(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
