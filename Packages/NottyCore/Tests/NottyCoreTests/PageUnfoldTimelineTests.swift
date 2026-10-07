import XCTest
@testable import NottyCore

final class PageUnfoldTimelineTests: XCTestCase {
    private typealias Timeline = PageUnfoldTimeline

    /// CSS pixels per millimetre, at which the source measures its eye and darkening.
    private static let webPointsPerMillimetre = 96 / 25.4
    /// `PaperGeometry`'s default page height.
    private static let pageHeight = (794.0 * 297) / 210
    private static let frame60 = 1_000.0 / 60
    private static let frame120 = 1_000.0 / 120

    /// The source's model over the default page at the page's own height: at the web's density,
    /// and at the density its darkening is authored at.
    private var web: Timeline {
        Timeline(pageHeight: Self.pageHeight, extent: Self.pageHeight, pointsPerMillimetre: Self.webPointsPerMillimetre)
    }
    private var authored: Timeline {
        Timeline(
            pageHeight: Self.pageHeight, extent: Self.pageHeight,
            pointsPerMillimetre: Timeline.referencePointsPerMillimetre
        )
    }
    /// The frost Notty draws over the default page.
    private var page: Timeline { Timeline(pageHeight: Self.pageHeight) }
    /// The default page frosted as the source's opening frosts its half screen.
    private var halfScreen: Timeline { Timeline(pageHeight: Self.pageHeight, extent: Timeline.sourceHalfScreen) }

    // MARK: Hinge script

    func testHingeScriptMatchesTheSource() {
        assertClose(Source.hingeTimes.map(Timeline.hinge(at:)), Source.hinge, "hinge")
        for key in Timeline.hingeKeys {
            XCTAssertEqual(Timeline.hinge(at: key.time), key.angle, "the script passes through each key")
        }
    }

    func testHingeScriptNeverTurnsBackAndLandsFlatWhereTheSourceDoes() {
        var previous = -Double.infinity
        for time in 0...1_060 {
            let hinge = Timeline.hinge(at: Double(time))
            XCTAssertGreaterThanOrEqual(hinge, previous, "monotonic at \(time) ms")
            previous = hinge
        }
        let flat = stride(from: 0.0, through: 1_060, by: 0.5).first { Timeline.hinge(at: $0) >= Timeline.flatHinge }
        XCTAssertEqual(flat, 985.5)
    }

    func testFrostStartsAtThePanelSwapAtItsSteepest() {
        XCTAssertEqual(Timeline.scriptStart, 520)
        XCTAssertEqual(Timeline.hinge(at: Timeline.scriptStart), Timeline.panelOnHinge)
        let frame = halfScreen.currentFrame
        XCTAssertEqual(frame.tilt, 27)
        XCTAssertEqual(frame.fade, 1)
        XCTAssertEqual(frame.taps, Timeline.maximumTaps)
        XCTAssertEqual(frame.phase, .clearing)
        XCTAssertEqual(frame.farEdgeRadius, Source.halfScreen60Far[0], accuracy: 1e-12)
    }

    // MARK: Tilt and follower

    func testTiltMapsTheHingeOntoTwentySevenDegreesDownToZero() {
        let tilts = Source.tiltHinges.map(Timeline.tilt(atHinge:))
        assertClose(tilts, Source.tilt, "tilt")
        for tenth in -100...1_900 {
            let tilt = Timeline.tilt(atHinge: Double(tenth) / 10)
            XCTAssertGreaterThanOrEqual(tilt, 0)
            XCTAssertLessThanOrEqual(tilt, 27)
        }
        XCTAssertEqual(Timeline.tilt(atHinge: Timeline.panelOnHinge), 27)
        XCTAssertEqual(Timeline.tilt(atHinge: Timeline.flatHinge), 0)
    }

    func testFollowerEasesTowardItsTargetAsTheSourceDoes() {
        assertClose(follow(from: 27, to: 0, interval: Self.frame60, frames: 40), Source.followFrom27At60Hz, "60 Hz")
        assertClose(follow(from: 10, to: 3, interval: 7, frames: 12), Source.followFrom10To3At7ms, "7 ms")
        let edges = [
            Timeline.follow(27, toward: 0, interval: 250),
            Timeline.follow(27, toward: 0, interval: 100),
            Timeline.follow(27, toward: 0, interval: -5),
            Timeline.follow(0.019, toward: 0, interval: 0),
            Timeline.follow(0.021, toward: 0, interval: 0),
            Timeline.follow(5, toward: 5.03, interval: 1)
        ]
        assertClose(edges, Source.followEdges, "a long step is clamped, a negative one holds, a near one lands")
    }

    // MARK: Frost

    func testUnitsAreTheSourcesAtTheWebDensity() {
        XCTAssertEqual(Timeline.sourcePixelsPerMillimetre, Self.webPointsPerMillimetre)
        XCTAssertEqual(web.eyeDistance, 1_700.7874015748034, accuracy: 1e-12)
        XCTAssertEqual(web.darkeningPerPoint, 0.023812499999999997, accuracy: 1e-15)
        XCTAssertEqual(authored.eyeDistance, 2_700)
        XCTAssertEqual(authored.darkeningPerPoint, 0.015, accuracy: 1e-15)
        XCTAssertEqual(page.eyeDistance, web.eyeDistance)
        XCTAssertEqual(page.darkeningPerPoint, web.darkeningPerPoint)
        XCTAssertEqual(web.distanceScale, 1, "a page frosted at its own height is unscaled")
        XCTAssertEqual(halfScreen.distanceScale, 628.2 / Self.pageHeight, accuracy: 1e-15)
        XCTAssertEqual(page.extent, Timeline.frostExtent)
        XCTAssertEqual(page.distanceScale, 299.37 / Self.pageHeight, accuracy: 1e-15)
    }

    // MARK: The source's screen

    func testTheSourceHalfScreenFollowsTheSourcesSizingRule() {
        // The source's sizing rule (pure/device.ts deviceGeometry over tokens.ts device) for its default device in a
        // 1,440 × 900 viewport: a margin of 8 vmin within 10 to 110 px a side, the device at most 2.1 times as wide
        // as it is tall, and a bezel of 2.2 vmin within 12 to 28 px a side.
        let vmin = min(1_440.0, 900) / 100
        let margin = min(110, max(10, 8 * vmin))
        let width = 1_440 - 2 * margin
        let height = 900 - 2 * margin
        XCTAssertLessThan(width, 2.1 * height, "the aspect clamp leaves the width as it is")
        let bezel = min(28, max(12, 2.2 * vmin))
        let halfScreen = (width - 2 * bezel) / 2
        XCTAssertEqual(Timeline.sourceHalfScreen, halfScreen, accuracy: 1e-9)
        XCTAssertEqual(Timeline.sourceHalfScreen, Source.halfScreen, accuracy: 1e-9)
    }

    func testAnExtentOrHeightThatIsNoLengthLeavesDistancesUnscaled() {
        for extent in [0, -Timeline.sourceHalfScreen, .nan, .infinity] {
            XCTAssertEqual(Timeline(pageHeight: Self.pageHeight, extent: extent).distanceScale, 1, "extent \(extent)")
        }
        for height in [0, -Self.pageHeight, .nan, .infinity] {
            XCTAssertEqual(Timeline(pageHeight: height).distanceScale, 1, "height \(height)")
        }
        XCTAssertEqual(Timeline(pageHeight: -Self.pageHeight, extent: -Timeline.sourceHalfScreen).distanceScale, 1)
        let unscaled = Timeline(pageHeight: Self.pageHeight, extent: 0).currentFrame.farEdgeRadius
        XCTAssertEqual(unscaled, web.currentFrame.farEdgeRadius, "the frost of the page at its own height")
    }

    func testAtTheSourcesHalfScreenThePageBottomFrostsAsItsScreenEdgeAtTheFirstFrame() {
        for height in [400, 794, Self.pageHeight, 2_000] {
            let timeline = Timeline(pageHeight: height, extent: Timeline.sourceHalfScreen)
            let far = timeline.currentFrame.farEdgeRadius
            XCTAssertEqual(far, Source.halfScreenFarRadius, accuracy: 1e-9, "a page \(height) pt tall")
            XCTAssertEqual(
                timeline.attenuation(radius: far), Source.halfScreenFarAttenuation, accuracy: 1e-9,
                "a page \(height) pt tall"
            )
        }
        let unscaled = web.attenuation(radius: web.currentFrame.farEdgeRadius)
        XCTAssertEqual(unscaled, 0, "at its own height the page's far edge would lose all its light")
    }

    func testEveryDistanceDownThePageFrostsAsTheSameShareOfTheSourcesScreen() {
        let screen = Timeline(pageHeight: Source.halfScreen, extent: Timeline.sourceHalfScreen)
        XCTAssertEqual(screen.distanceScale, 1)
        let timeline = halfScreen
        for share in stride(from: 0.0, through: 1, by: 0.05) {
            let radii = Source.radiusTilts.map { timeline.radius(atDistance: share * Self.pageHeight, tilt: $0) }
            let source = Source.radiusTilts.map { screen.radius(atDistance: share * Source.halfScreen, tilt: $0) }
            for (radius, reference) in zip(radii, source) {
                XCTAssertEqual(radius, reference, accuracy: 1e-9, "\(Int((share * 100).rounded()))% down")
            }
        }
    }

    func testRadiusMatchesTheSourceAtBothDensities() {
        for (row, distance) in Source.radiusDistances.enumerated() {
            let web = Source.radiusTilts.map { self.web.radius(atDistance: distance, tilt: $0) }
            let authored = Source.radiusTilts.map { self.authored.radius(atDistance: distance, tilt: $0) }
            assertClose(web, Source.webRadius[row], "web radius \(distance) pt down")
            assertClose(authored, Source.authoredRadius[row], "authored radius \(distance) pt down")
        }
    }

    func testFrostIsSharpAtTheHingeAndWidensDownThePage() {
        let timeline = page
        for tilt in [0.5, 5, 13.5, 27] {
            var previous = timeline.radius(atDistance: 0, tilt: tilt)
            XCTAssertEqual(previous, 0, "the hinge is always sharp")
            for distance in stride(from: 10.0, through: Self.pageHeight, by: 10) {
                let radius = timeline.radius(atDistance: distance, tilt: tilt)
                XCTAssertGreaterThan(radius, previous, "\(distance) pt down at \(tilt)°")
                previous = radius
            }
        }
    }

    func testAttenuationMatchesTheSource() {
        assertClose(Source.radii.map(web.attenuation(radius:)), Source.webAttenuation, "web")
        assertClose(Source.radii.map(authored.attenuation(radius:)), Source.authoredAttenuation, "authored")
        assertClose(Source.radii.map(halfScreen.attenuation(radius:)), Source.webAttenuation, "half screen")
        assertClose(Source.radii.map(page.attenuation(radius:)), Source.webAttenuation, "page")
    }

    func testHandOffBeginsAtOneAndAHalfAndEndsAtAQuarterPointOfBlur() {
        assertClose(Source.handOffTilts.map(web.handOff(tilt:)), Source.webHandOff, "web")
        assertClose(Source.handOffTilts.map(authored.handOff(tilt:)), Source.authoredHandOff, "authored")
        let timeline = page
        for tenth in 0...300 {
            let tilt = Double(tenth) / 100
            let far = timeline.radius(atDistance: Self.pageHeight, tilt: tilt)
            let fade = timeline.handOff(tilt: tilt)
            if far >= Timeline.handOffRadius { XCTAssertEqual(fade, 1, "\(tilt)°") }
            if far <= Timeline.unseenRadius { XCTAssertEqual(fade, 0, "\(tilt)°") }
            if far > Timeline.unseenRadius, far < Timeline.handOffRadius {
                XCTAssertGreaterThan(fade, 0)
                XCTAssertLessThan(fade, 1)
            }
        }
    }

    // MARK: Whole clearing

    func testWholeClearingMatchesTheSourceFrameByFrame() {
        let cases: [(Timeline, Double, [Double], [Double], String)] = [
            (web, Self.frame60, Source.web60Tilt, Source.web60Fade, "web 60 Hz"),
            (web, Self.frame120, Source.web120Tilt, Source.web120Fade, "web 120 Hz"),
            (authored, Self.frame60, Source.authored60Tilt, Source.authored60Fade, "authored 60 Hz"),
            (authored, Self.frame120, Source.authored120Tilt, Source.authored120Fade, "authored 120 Hz")
        ]
        for (timeline, interval, tilts, fades, label) in cases {
            let clearing = clear(timeline, intervals: [interval])
            XCTAssertEqual(clearing.outcome, .finished, label)
            assertClose(clearing.frames.map(\.tilt), tilts, "\(label) tilt")
            assertClose(clearing.frames.map(\.fade), fades, "\(label) fade")
            XCTAssertTrue(clearing.frames.dropLast().allSatisfy { $0.phase == .clearing }, label)
            XCTAssertTrue(clearing.frames.allSatisfy { $0.taps == Timeline.maximumTaps }, label)
        }
        let far = clear(authored, intervals: [Self.frame60]).frames.map(\.farEdgeRadius)
        assertClose(far, Source.authored60Far, "far edge radius")
    }

    func testThePagesClearingIsTheSourceOpeningsAtItsHalfScreenFrameByFrame() {
        let cases: [(Double, [Double], [Double], [Double], String)] = [
            (Self.frame60, Source.web60Tilt, Source.halfScreen60Fade, Source.halfScreen60Far, "60 Hz"),
            (Self.frame120, Source.web120Tilt, Source.halfScreen120Fade, Source.halfScreen120Far, "120 Hz")
        ]
        for (interval, tilts, fades, far, label) in cases {
            let clearing = clear(halfScreen, intervals: [interval])
            XCTAssertEqual(clearing.outcome, .finished, label)
            // The script and the follower are the same whatever the extent, which only decides when the hand-off runs.
            assertClose(clearing.frames.map(\.tilt), Array(tilts.prefix(fades.count)), "\(label) tilt")
            assertClose(clearing.frames.map(\.fade), fades, "\(label) fade")
            assertClose(clearing.frames.map(\.farEdgeRadius), far, "\(label) far edge radius")
        }
    }

    func testClearingTakesAsLongAsTheSourceOpeningsAtEitherRate() {
        let at60 = clear(halfScreen, intervals: [Self.frame60])
        XCTAssertEqual(at60.frames.count, 36)
        XCTAssertEqual(at60.elapsed, 1_750.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(at60.frames.firstIndex { $0.fade < 1 }, 30, "the hand-off begins 500 ms in")
        let at120 = clear(halfScreen, intervals: [Self.frame120])
        XCTAssertEqual(at120.frames.count, 70)
        XCTAssertEqual(at120.elapsed, 575, accuracy: 1e-9)
        XCTAssertEqual(at120.frames.firstIndex { $0.fade < 1 }, 60, "the hand-off begins 500 ms in")
        // The source's frames fall elsewhere about its panel swap, so its clearing ends within a frame of the page's.
        for (clearing, interval) in [(at60, Self.frame60), (at120, Self.frame120)] {
            XCTAssertEqual(clearing.elapsed, Source.halfScreenClearedAfterSwap, accuracy: interval)
        }
        // Frosted at its own height, the page's far edge would stay blurred a frame or two longer.
        XCTAssertEqual(clear(authored, intervals: [Self.frame60]).elapsed, 600, accuracy: 1e-9)
        XCTAssertEqual(clear(authored, intervals: [Self.frame120]).elapsed, 600, accuracy: 1e-9)
    }

    // MARK: The new page's frost

    func testAtTheFirstFrameTheNewPagesBottomKeepsSixTenthsOfItsLight() {
        for height in [400, 794, Self.pageHeight, 2_000] {
            let timeline = Timeline(pageHeight: height)
            let far = timeline.currentFrame.farEdgeRadius
            XCTAssertEqual(far, Source.frostFarRadius, accuracy: 1e-9, "a page \(height) pt tall")
            XCTAssertEqual(timeline.attenuation(radius: far), 0.6, accuracy: 0.001, "a page \(height) pt tall")
        }
    }

    func testTheNewPageClearsWithinAFrameOfTheSourceOpeningAtTheSameExtent() {
        let at60 = clear(page, intervals: [Self.frame60])
        XCTAssertEqual(at60.outcome, .finished)
        XCTAssertEqual(at60.frames.count, 34)
        XCTAssertEqual(at60.elapsed, 550, accuracy: 1e-9)
        let at120 = clear(page, intervals: [Self.frame120])
        XCTAssertEqual(at120.outcome, .finished)
        XCTAssertEqual(at120.frames.count, 66)
        XCTAssertEqual(at120.elapsed, 1_625.0 / 3, accuracy: 1e-9)
        // The extent only decides when the hand-off runs; the script and the follower are the source's.
        assertClose(at60.frames.map(\.tilt), Array(Source.web60Tilt.prefix(34)), "60 Hz tilt")
        assertClose(at120.frames.map(\.tilt), Array(Source.web120Tilt.prefix(66)), "120 Hz tilt")
        for (clearing, interval) in [(at60, Self.frame60), (at120, Self.frame120)] {
            XCTAssertEqual(clearing.elapsed, Source.frostClearedAfterSwap, accuracy: interval)
        }
    }

    func testAFinishedClearingStaysFinished() {
        var timeline = page
        var frame = timeline.currentFrame
        var elapsed = 0.0
        while !frame.isFinished {
            frame = timeline.advance(elapsed: elapsed, interval: elapsed == 0 ? 0 : Self.frame60)
            elapsed += Self.frame60
        }
        XCTAssertEqual(frame.phase, .finished)
        XCTAssertEqual(frame.fade, 0)
        XCTAssertLessThanOrEqual(frame.farEdgeRadius, Timeline.unseenRadius, "what is left can no longer be seen")
        let later = timeline.advance(elapsed: 5_000, interval: 80, gpuTime: 90)
        XCTAssertEqual(later, frame)
    }

    // MARK: Frame rate

    func testSlowStreakSkipsTheGraceFramesAndCountsARun() {
        let streaks = [
            Timeline.slowStreak(0, frame: 0, interval: 80),
            Timeline.slowStreak(0, frame: 1, interval: 80),
            Timeline.slowStreak(0, frame: 2, interval: 80),
            Timeline.slowStreak(1, frame: 3, interval: 80),
            Timeline.slowStreak(2, frame: 4, interval: 50),
            Timeline.slowStreak(2, frame: 4, interval: 50.01)
        ]
        XCTAssertEqual(streaks, [0, 0, 1, 2, 0, 3])
    }

    func testTwoSlowFramesInARowAfterTheGraceAbandonTheClearing() {
        let clearing = clear(authored, intervals: [0, 80, 80, 30, 60, 60, 16])
        XCTAssertEqual(clearing.outcome, .abandoned)
        XCTAssertEqual(clearing.frames.count, 5)
        XCTAssertEqual(clearing.elapsed, 310)
        var timeline = authored
        for (index, interval) in [0.0, 80, 80, 30, 60, 60].enumerated() {
            _ = timeline.advance(elapsed: Double(index) * 50, interval: interval)
        }
        XCTAssertEqual(timeline.phase, .abandoned)
        XCTAssertEqual(timeline.advance(elapsed: 400, interval: 16).phase, .abandoned)
    }

    func testTapsStepDownLikeTheSourcesAndStopAtTheFloor() {
        var steps: [Int] = []
        var taps = Timeline.maximumTaps
        while taps > Timeline.minimumTaps {
            taps = Timeline.taps(taps, afterFrameCost: 20)
            steps.append(taps)
        }
        XCTAssertEqual(steps, [22, 15, 11, 8, 6])
        XCTAssertEqual(Timeline.taps(32, afterFrameCost: Timeline.frameBudget), 32, "within budget")
        XCTAssertEqual(Timeline.taps(6, afterFrameCost: 100), 6)
        let overBudget = clear(authored, intervals: [Self.frame60], gpuTimes: Array(repeating: 20, count: 60))
        XCTAssertEqual(overBudget.frames.map { Double($0.taps) }, Source.gpuOverBudgetTaps)
    }

    func testWithoutGPUTimeAMissedFrameCostsItsInterval() {
        let intervals = [0, 16.667, 16.667, 16.667, 16.667, 33.333, 16.667, 16.667, 40, 16.667]
            + Array(repeating: 16.667, count: 60)
        let clearing = clear(authored, intervals: intervals)
        XCTAssertEqual(clearing.frames.prefix(12).map { Double($0.taps) }, Source.missedFrameTaps)
    }

    func testPixelsPerPointFollowTheScreenWithinTheirBounds() {
        let width = 794.0
        let height = Self.pageHeight
        XCTAssertEqual(Timeline.pixelsPerPoint(width: width, height: height, screenPixelsPerPoint: 2.6), 2)
        XCTAssertEqual(Timeline.pixelsPerPoint(width: width, height: height, screenPixelsPerPoint: 1.5), 1.5)
        XCTAssertEqual(Timeline.pixelsPerPoint(width: width, height: height, screenPixelsPerPoint: 0.6), 0.6)
        XCTAssertEqual(Timeline.pixelsPerPoint(width: width, height: height, screenPixelsPerPoint: 0), 1)
        let large = Timeline.pixelsPerPoint(width: 2_000, height: 2_000, screenPixelsPerPoint: 2)
        XCTAssertEqual(large, (6_500_000.0 / 4_000_000).squareRoot(), accuracy: 1e-12)
        XCTAssertLessThanOrEqual(2_000 * large * 2_000 * large, Timeline.maximumPixels * (1 + 1e-12))
    }

    // MARK: Helpers

    private struct Clearing {
        var frames: [Timeline.Frame] = []
        var elapsed = 0.0
        var outcome = Timeline.Phase.clearing
    }

    /// Plays a timeline as the source's frame loop does: the first frame at once, then one frame
    /// per interval; `intervals[k]` is the time before frame k, the last repeating.
    private func clear(_ timeline: Timeline, intervals: [Double], gpuTimes: [Double?] = []) -> Clearing {
        var timeline = timeline
        var clearing = Clearing()
        for index in 0..<10_000 {
            let interval = index == 0 ? 0 : intervals[min(index, intervals.count - 1)]
            clearing.elapsed += interval
            let gpuTime = index < gpuTimes.count ? gpuTimes[index] : nil
            let frame = timeline.advance(elapsed: clearing.elapsed, interval: interval, gpuTime: gpuTime)
            clearing.outcome = frame.phase
            if frame.phase == .abandoned { return clearing }
            clearing.frames.append(frame)
            if frame.phase == .finished { return clearing }
        }
        XCTFail("the clearing never ended")
        return clearing
    }

    private func follow(from tilt: Double, to target: Double, interval: Double, frames: Int) -> [Double] {
        var tilt = tilt
        return (0..<frames).map { _ in
            tilt = Timeline.follow(tilt, toward: target, interval: interval)
            return tilt
        }
    }

    private func assertClose(
        _ actual: [Double], _ expected: [Double], _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, message, file: file, line: line)
        for (index, (value, reference)) in zip(actual, expected).enumerated() {
            XCTAssertEqual(
                value, reference, accuracy: 1e-12 * max(1, abs(reference)), "\(message) [\(index)]",
                file: file, line: line
            )
        }
    }
}

/// The source's own values: its pure functions and its frame loop, run with Bun over a page of
/// `PaperGeometry`'s default height at the web's density and at the darkening's own, over its own
/// screen's half width in a 1,440 × 900 viewport, and over the new page's frost extent.
private enum Source {
    /// `deviceGeometry` in a 1,440 × 900 viewport: half the open screen's width.
    static let halfScreen = 628.20000000000005
    /// How long after the panel swap the source's own frame loop, started on time, ends its hand-off at that half
    /// width: 1,100 ms into its script at 60 Hz and at 120 Hz alike.
    static let halfScreenClearedAfterSwap = 580.0

    /// `innerRadius(halfScreen, 27)` and `attenuation` of it: the screen's outer edge at the panel swap.
    static let halfScreenFarRadius = 32.326332472584646
    static let halfScreenFarAttenuation = 0.2302292079965782

    /// `innerRadius(frostExtent, 27)`: the new page's bottom at the panel swap.
    static let frostFarRadius = 16.797864601168587
    /// How long after the panel swap the source's own frame loop, started on time, ends its hand-off at the frost
    /// extent: 1,066⅔ ms into its script at 60 Hz and at 120 Hz alike.
    static let frostClearedAfterSwap = 1_640.0 / 3

    static let halfScreen60Fade: [Double] = [
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        0.71099672371481792, 0.43008662547501436, 0.23557324768639712, 0.10099977911778701, 0.0079516442733499997, 0
    ]

    static let halfScreen60Far: [Double] = [
        32.326332472584646, 32.257025739399936, 32.089626805962659, 31.807802411654862, 31.40387282243713,
        30.876150302653482, 30.227059849047336, 29.461804558198679, 28.587415435329891, 27.612076674601099,
        26.544651418014418, 25.394355643801074, 24.170543029474036, 22.882573922107369, 21.539748587610397,
        20.151289779777009, 18.726363065948604, 17.274125717900183, 15.803796611806659, 14.324740665281359,
        12.846561995161389, 11.379200294193504, 9.9330249693956052, 8.5189214295560323, 7.1483636336376835,
        5.8334667131624558, 4.5870132802391064, 3.4224470727699763, 2.3745834224322322, 1.645235731041288,
        1.1387459046435224, 0.78760828184376797, 0.54446655960799639, 0.37624972389723377, 0.2599395553416875,
        0.17955309686643287
    ]

    static let halfScreen120Fade: [Double] = [
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0.79880783712420322,
        0.63079525618997978, 0.49093036599309431, 0.37453204320787403, 0.27768728865085146, 0.19712827228152557,
        0.13012815163369873, 0.0744130613246822, 0.028087955979282642, 0
    ]

    static let halfScreen120Far: [Double] = [
        32.326332472584646, 32.310954962781651, 32.275701205616464, 32.21707084752321, 32.132395998635914,
        32.019703018318779, 31.87759712492679, 31.705165851287102, 31.501898099397117, 31.267616142059566,
        31.002418401879861, 30.70663123028385, 30.38076822800312, 30.025495907643567, 29.64160470974592,
        29.229984555303183, 28.791604257448792, 28.327494228995242, 27.838732015575943, 27.326430260279789,
        26.791726768073765, 26.235776389574792, 25.659744485950867, 25.064801771596585, 24.452120360099379,
        23.82287086299306, 23.178220410766048, 22.51933148226534, 21.847361442584056, 21.163462701196895,
        20.468783411880953, 19.764468644120921, 19.051661962482292, 18.331507356031043, 17.605151464434876,
        16.873746051021435, 16.13845067589428, 15.400435524303411, 14.660884346906892, 13.920997469412491,
        13.181994829415848, 12.44511899812, 11.711638144096048, 10.982848895398998, 10.260079055265516,
        9.5446901253807077, 8.8380795894082613, 8.141682908243741, 7.4569751773992721, 6.7854723961944057,
        6.1287322981623715, 5.4883546924407867, 4.8659812670683307, 4.2632948072245487, 3.6820177846994806,
        3.1239102794273736, 2.6020793488723721, 2.1665987703740517, 1.8034171418445795, 1.5007024658961414,
        1.2485097964052541, 1.0384940702374748, 0.8636629574913679, 0.71816505400984254, 0.59710911081356433,
        0.49641034035190695, 0.41266018954212341, 0.34301632665585274, 0.2851099449741033, 0.23696783062456428
    ]

    static let hingeTimes: [Double] = [
        -10, 0, 25, 50, 100, 160, 300, 520, 521, 600, 700, 800, 900, 1000, 1059, 1060, 1200
    ]

    static let hinge: [Double] = [
        0, 0, 2.375, 6, 9.2757325319308794, 11, 14.262345679012345, 20, 20.041496047350503, 31.816572676929326,
        64.681481481481484, 107.03884570441497, 147.51844739114975, 174.75006858710563, 179.99842987857539, 180, 180
    ]

    static let tiltHinges: [Double] = [
        .nan, -5, 0, 20, 21, 50, 96, 150, 171.90000000000001, 172, 180
    ]

    static let tilt: [Double] = [
        0, 27, 27, 27, 26.822368421052634, 21.671052631578949, 13.5, 3.9078947368421053, 0.017763157894735832, 0, 0
    ]

    static let followFrom27At60Hz: [Double] = [
        18.642920862881947, 12.872536974062184, 8.8882106708134501, 6.1371188203184452, 4.2375489071592662,
        2.9259366269911879, 2.0202964809927577, 1.394971385729884, 0.96319782037581458, 0.66506743483580344,
        0.45921479837495482, 0.31707796833957674, 0.21893553596733767, 0.15117029152265632, 0.10437984376576576,
        0.072072043222413062, 0.049764199934135334, 0.034361112636174813, 0.023725611245806664, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    ]

    static let followFrom10To3At7ms: [Double] = [
        8.9915766638858567, 8.1284272741745109, 7.3896235969113935, 6.7572523294995719, 6.2159807682514865,
        5.7526850460801882, 5.3561319264459453, 5.0167064382185647, 4.7261787475912449, 4.4775046145376312,
        4.2646545956067623, 4.0824678518447834
    ]

    static let followEdges: [Double] = [
        2.9259366269911879, 2.9259366269911879, 27, 0, 0.021000000000000001, 5.0006593138254622
    ]

    static let radiusTilts: [Double] = [
        0, 0.000010000000000000001, 0.5, 5, 13.5, 27, 45, 60, 75
    ]

    static let radiusDistances: [Double] = [
        0, 100, 561.47142857142865, 1122.9428571428571
    ]

    static let webRadius: [[Double]] = [
        [
            0, 0, 0, 0, 0, 0, 0, 0, 0
        ],
        [
            0, 0, 0.1046687071899742, 1.0444910903416629, 2.840844481613503, 5.936459691985692, 11.333624836029733,
            18.863577438060627, 18.863577438060627
        ],
        [
            0, 0, 0.58629733654700089, 5.7292142035135525, 14.987811785477353, 29.386987185851101,
            50.654338186233026, 74.246227870123576, 74.246227870123576
        ],
        [
            0, 0, 1.1692358373736913, 11.145557220259631, 27.924937576302575, 51.376428039814627,
            81.164426731793625, 108.88271102886364, 108.88271102886364
        ]
    ]

    static let authoredRadius: [[Double]] = [
        [
            0, 0, 0, 0, 0, 0, 0, 0, 0
        ],
        [
            0, 0, 0.10468857632744574, 1.0464730538334663, 2.8555540764003422, 6.0010575587456696,
            11.571428571428571, 19.531653532524153, 19.531653532524153
        ],
        [
            0, 0, 0.58692130215742622, 5.7893576484685987, 15.406514214485789, 31.041059371715971,
            55.777506208854014, 85.796949006077682, 85.796949006077682
        ],
        [
            0, 0, 1.1717200504328644, 11.375454268619793, 29.414347671234829, 56.654310654849176,
            95.171049976457908, 135.66822078783656, 135.66822078783656
        ]
    ]

    static let handOffTilts: [Double] = [
        0, 0.050000000000000003, 0.10000000000000001, 0.20000000000000001, 0.29999999999999999, 0.5,
        0.64000000000000001, 1, 27
    ]

    static let webHandOff: [Double] = [
        0, 0, 0, 0.17543801494509789, 0.36251314670485424, 0.73538866989895302, 0.99539923087546689, 1, 1
    ]

    static let authoredHandOff: [Double] = [
        0, 0, 0, 0.17575777123036765, 0.36323125889741553, 0.73737604034629156, 0.99864694001022958, 1, 1
    ]

    static let radii: [Double] = [
        0, 1, 10, 30, 41.990000000000002, 42, 100
    ]

    static let webAttenuation: [Double] = [
        1, 0.97618749999999999, 0.76187500000000008, 0.28562500000000013, 0.00011312500000004722, 0, 0
    ]

    static let authoredAttenuation: [Double] = [
        1, 0.98499999999999999, 0.84999999999999998, 0.55000000000000004, 0.37014999999999998, 0.37, 0
    ]

    static let web60Tilt: [Double] = [
        27, 26.940951272801584, 26.798270378603696, 26.557877162374375, 26.212943761924269, 25.761649867713619,
        25.205632777897613, 24.548917194580742, 23.797176271085831, 22.957221380943473, 22.036649814323432,
        21.043601519977294, 19.986591140767619, 18.874392037803588, 17.715956211594293, 16.520359009322718,
        15.296760946404476, 14.054381345092954, 12.802480132501671, 11.5503452725291, 10.307284087872352,
        9.082617268063764, 7.8856747321486695, 6.7257927719531772, 5.6123120795718204, 4.5545763853900887,
        3.5619315176682167, 2.6437247532039465, 1.8254352354527141, 1.2604238753652304, 0.87029565044892476,
        0.60092047920850644, 0.41492270143589938, 0.28649522544750616, 0.19781880798560664, 0.13658964379501126,
        0.094312219257764035
    ]

    static let web60Fade: [Double] = [
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        0.92290257051468794, 0.57697927923304126, 0.33727399661000657, 0.17135278282819785, 0.056591232311603346, 0
    ]

    static let web120Tilt: [Double] = [
        27, 26.986899731760058, 26.956864011793545, 26.906903580357298, 26.834732098372609, 26.738647318960965,
        26.617432346885355, 26.470273590044499, 26.296692581235018, 26.096489325418087, 25.869695224108618,
        25.616533957878055, 25.337388981654847, 25.032776514931683, 24.703323097967687, 24.349746942105845,
        23.972842432812048, 23.573467252469285, 23.152531680058516, 22.710989699724273, 22.249831612433805,
        21.770077896632362, 21.272774106752294, 20.758986634127218, 20.229799184521987, 19.686309851134826,
        19.129628682407347, 18.560875660995297, 17.981179024393551, 17.391673869458764, 16.79350099283694,
        16.18780592741626, 15.575738141667204, 14.958450374333879, 14.337098081595546, 13.712838977685266,
        13.086832653166791, 12.460240257741583, 11.834224236677198, 11.209948111792336, 10.588576299466302,
        9.9712739594138746, 9.3592068690247334, 8.753541318945766, 8.1554440263151324, 7.5660820626640799,
        6.986622794006931, 6.4182338310588349, 5.8620829878691918, 5.3193382474480702, 4.7911677332034746,
        4.2787396852071318, 3.7832224404725325, 3.3057844165669623, 2.8475940979939147, 2.4098200248775519,
        2.0024408892639429, 1.6639290376881632, 1.382642482635061, 1.1489073100396943, 0.95468497723792856,
        0.7932958540687628, 0.65918949924551684, 0.54775377141689963, 0.45515620992877592, 0.37821223010631067,
        0.31427560007227601, 0.26114743241652028, 0.21700056078822882, 0.18031670059577776, 0.14983423266577606,
        0.12450481405418752, 0.10345732378291497
    ]

    static let web120Fade: [Double] = [
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0.82417013954496754,
        0.65192997022000265, 0.508531917401712, 0.38918445443640765, 0.289880373837898, 0.2072719874395787,
        0.13856508124529995, 0.081429150883304754, 0.033921658335768878, 0
    ]

    static let authored60Tilt: [Double] = [
        27, 26.940951272801584, 26.798270378603696, 26.557877162374375, 26.212943761924269, 25.761649867713619,
        25.205632777897613, 24.548917194580742, 23.797176271085831, 22.957221380943473, 22.036649814323432,
        21.043601519977294, 19.986591140767619, 18.874392037803588, 17.715956211594293, 16.520359009322718,
        15.296760946404476, 14.054381345092954, 12.802480132501671, 11.5503452725291, 10.307284087872352,
        9.082617268063764, 7.8856747321486695, 6.7257927719531772, 5.6123120795718204, 4.5545763853900887,
        3.5619315176682167, 2.6437247532039465, 1.8254352354527141, 1.2604238753652304, 0.87029565044892476,
        0.60092047920850644, 0.41492270143589938, 0.28649522544750616, 0.19781880798560664, 0.13658964379501126,
        0.094312219257764035
    ]

    static let authored60Fade: [Double] = [
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        0.92576782884194664, 0.57835002607842667, 0.33792907566602803, 0.17166561538250105, 0.056740549276031518, 0
    ]

    static let authored60Far: [Double] = [
        56.654310654849176, 56.535217452280037, 56.247526324256384, 55.7630523059034, 55.068383283991913,
        54.160305649563867, 53.042587627013368, 51.723706341692804, 50.215238852628431, 48.530726797415618,
        46.684883916407543, 44.693055581699838, 42.570866234630849, 40.334008749116578, 37.998142089124855,
        35.578872114508201, 33.091796244106689, 30.552596705929261, 27.977169804186715, 25.381780342483502,
        22.783231279541496, 20.199039012793971, 17.647604512540653, 15.14836999102036, 12.721950033704333,
        10.390225329049921, 8.17638654120816, 6.1049157623068355, 4.2384870271460002, 2.9379668953896778,
        2.0341421358362282, 1.4072097860524333, 0.97293753259803339, 0.67241134458253504, 0.46458201922812631,
        0.32092568659503939, 0.22166004093127095
    ]

    static let authored120Tilt: [Double] = [
        27, 26.986899731760058, 26.956864011793545, 26.906903580357298, 26.834732098372609, 26.738647318960965,
        26.617432346885355, 26.470273590044499, 26.296692581235018, 26.096489325418087, 25.869695224108618,
        25.616533957878055, 25.337388981654847, 25.032776514931683, 24.703323097967687, 24.349746942105845,
        23.972842432812048, 23.573467252469285, 23.152531680058516, 22.710989699724273, 22.249831612433805,
        21.770077896632362, 21.272774106752294, 20.758986634127218, 20.229799184521987, 19.686309851134826,
        19.129628682407347, 18.560875660995297, 17.981179024393551, 17.391673869458764, 16.79350099283694,
        16.18780592741626, 15.575738141667204, 14.958450374333879, 14.337098081595546, 13.712838977685266,
        13.086832653166791, 12.460240257741583, 11.834224236677198, 11.209948111792336, 10.588576299466302,
        9.9712739594138746, 9.3592068690247334, 8.753541318945766, 8.1554440263151324, 7.5660820626640799,
        6.986622794006931, 6.4182338310588349, 5.8620829878691918, 5.3193382474480702, 4.7911677332034746,
        4.2787396852071318, 3.7832224404725325, 3.3057844165669623, 2.8475940979939147, 2.4098200248775519,
        2.0024408892639429, 1.6639290376881632, 1.382642482635061, 1.1489073100396943, 0.95468497723792856,
        0.7932958540687628, 0.65918949924551684, 0.54775377141689963, 0.45515620992877592, 0.37821223010631067,
        0.31427560007227601, 0.26114743241652028, 0.21700056078822882, 0.18031670059577776, 0.14983423266577606,
        0.12450481405418752, 0.10345732378291497
    ]

    static let authored120Fade: [Double] = [
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0.8265531526150639,
        0.65357820885466467, 0.50967161524811611, 0.38997232666831216, 0.2904249209322976, 0.20764829508675603,
        0.13882509157510731, 0.08160878472275282, 0.034045750416835927, 0
    ]

    static let gpuOverBudgetTaps: [Double] = [
        22, 15, 11, 8, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
        6, 6
    ]

    static let missedFrameTaps: [Double] = [
        32, 32, 32, 32, 32, 22, 22, 22, 15, 15, 15, 15
    ]
}
