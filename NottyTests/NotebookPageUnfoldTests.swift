import Metal
import NottyCore
import UIKit
import XCTest
@testable import Notty

@MainActor
final class NotebookPageUnfoldTests: XCTestCase {
    private typealias Timeline = PageUnfoldTimeline

    /// `PaperGeometry`'s default page.
    private static let pageSize = CGSize(width: 794, height: (794.0 * 297) / 210)
    private static let ivory = SIMD3<Double>(0.98, 0.96, 0.91)
    private static let charcoal = SIMD3<Double>(0.17, 0.16, 0.15)
    /// Where the filmstrip and the timing report go, when the run names a directory.
    private static let shotsDirectory = ProcessInfo.processInfo.environment["NOTTY_UNFOLD_SHOTS_DIRECTORY"]

    // MARK: - Shaders

    func testShadersLoadFromTheAppBundleAndCompile() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: NotebookPageUnfold.self))
        XCTAssertTrue(library.functionNames.contains("pageUnfoldVertex"))
        XCTAssertTrue(library.functionNames.contains("pageUnfoldFragment"))
        let unfold = NotebookPageUnfold(device: device)
        let ready = await unfold.ready()
        XCTAssertTrue(ready)
        XCTAssertTrue(unfold.isReady)
    }

    func testUniformsAreLaidOutAsTheShaderReadsThem() {
        typealias Uniforms = NotebookPageUnfold.Uniforms
        XCTAssertEqual(MemoryLayout<Uniforms>.offset(of: \Uniforms.glass), 0)
        XCTAssertEqual(MemoryLayout<Uniforms>.offset(of: \Uniforms.size), 16)
        XCTAssertEqual(MemoryLayout<Uniforms>.offset(of: \Uniforms.pixelsPerPoint), 24)
        XCTAssertEqual(MemoryLayout<Uniforms>.offset(of: \Uniforms.tilt), 32)
        XCTAssertEqual(MemoryLayout<Uniforms>.offset(of: \Uniforms.eyeDistance), 36)
        XCTAssertEqual(MemoryLayout<Uniforms>.offset(of: \Uniforms.blurSpread), 40)
        XCTAssertEqual(MemoryLayout<Uniforms>.offset(of: \Uniforms.darkening), 44)
        XCTAssertEqual(MemoryLayout<Uniforms>.offset(of: \Uniforms.maximumTaps), 48)
        XCTAssertEqual(MemoryLayout<Uniforms>.offset(of: \Uniforms.distanceScale), 52)
        XCTAssertEqual(MemoryLayout<Uniforms>.stride, 64, "the shader's struct rounds up to its float4's alignment")
    }

    // MARK: - Frames

    func testTheClearedFrameIsTheSourcePixelForPixel() async throws {
        let unfold = try await readyUnfold()
        let source = Self.checkerboard()
        let expected = Pixels(source)
        let flat = try render(unfold, source: source, tilt: 0)
        XCTAssertLessThanOrEqual(flat.largestDifference(from: expected), 1.0 / 255)

        var timeline = Timeline(pageHeight: Self.pageSize.height)
        var last = timeline.currentFrame
        var elapsed = 0.0
        while !last.isFinished {
            last = timeline.advance(elapsed: elapsed, interval: elapsed == 0 ? 0 : 1_000.0 / 60)
            elapsed += 1_000.0 / 60
        }
        let final = try render(unfold, source: source, tilt: last.tilt)
        XCTAssertLessThanOrEqual(
            final.largestDifference(from: expected), 2.0 / 255, "what is left of the frost cannot be seen"
        )
    }

    func testTheFirstFrameIsSharpAlongTheTopEdgeAndFrostedAndDarkerBelow() async throws {
        let unfold = try await readyUnfold()
        let source = Self.checkerboard()
        let original = Pixels(source)
        let tilt = Timeline(pageHeight: Self.pageSize.height).currentFrame.tilt
        XCTAssertEqual(tilt, 27)
        let frame = try render(unfold, source: source, tilt: tilt)
        try assertFrost(frame, over: original, tilt: tilt)
    }

    func testAtTheSourcesHalfScreenTheShaderFrostsAsTheTimelineDoes() async throws {
        let unfold = try await readyUnfold()
        let source = Self.checkerboard()
        let timeline = Timeline(pageHeight: Self.pageSize.height, extent: Timeline.sourceHalfScreen)
        // The source's geometry blurs the far edge about twice as wide as the default does, so this holds the shader
        // to the timeline at the wider blur too.
        XCTAssertGreaterThan(timeline.currentFrame.farEdgeRadius, 32)
        let frame = try render(unfold, source: source, tilt: 27, timeline: timeline)
        try assertFrost(frame, over: Pixels(source), tilt: 27, timeline: timeline)
    }

    func testMidwayTheFrostHasClearedFromTheTopDown() async throws {
        let unfold = try await readyUnfold()
        let source = Self.checkerboard()
        let original = Pixels(source)
        let tilt = try midwayTilt()
        let timeline = Timeline(pageHeight: Self.pageSize.height)
        let frame = try render(unfold, source: source, tilt: tilt)
        try assertFrost(frame, over: original, tilt: tilt)

        let sharpDepth = try XCTUnwrap(
            (0..<frame.height).last { timeline.radius(atDistance: Double($0) + 0.5, tilt: tilt) < 0.5 }
        )
        let startSharpDepth = try XCTUnwrap(
            (0..<frame.height).last { timeline.radius(atDistance: Double($0) + 0.5, tilt: 27) < 0.5 }
        )
        XCTAssertGreaterThan(sharpDepth, startSharpDepth * 2, "the sharp band has grown down the page")
        // Rows sharp by now, which assertFrost has checked, were still frosted at the start.
        let atStart = try render(unfold, source: source, tilt: 27)
        let rows = (startSharpDepth + 2)...sharpDepth
        XCTAssertGreaterThan(atStart.meanDifference(from: frame, rows: rows), 0.02)
    }

    func testTheFirstFrameDimsABlankPageDownToSixTenthsOfItsLight() async throws {
        let unfold = try await readyUnfold()
        let fixture = try await PaperFixture(screenPixelsPerPoint: 1)
        let paper = Pixels(fixture.source)
        let frame = try render(unfold, source: fixture.source, tilt: 27)
        let timeline = Timeline(pageHeight: Self.pageSize.height)
        let paperLuminance = Self.luminance(paper.statistics(rows: 0..<paper.height, columns: 0..<paper.width).mean)

        var sharpRows = 0
        for y in 0..<frame.height {
            let radius = timeline.radius(atDistance: Double(y) + 0.5, tilt: 27)
            guard radius < 0.45 else { break }
            let attenuation = timeline.attenuation(radius: radius)
            for x in stride(from: 0, to: frame.width, by: 7) {
                XCTAssertEqual(
                    frame.luminance(x: x, y: y), paper.luminance(x: x, y: y) * attenuation, accuracy: 2.0 / 255,
                    "sharp at \(x), \(y)"
                )
            }
            sharpRows += 1
        }
        XCTAssertGreaterThan(sharpRows, 8, "the top edge stays sharp")

        // Row for row, the shader dims the page by the timeline's attenuation, so both scale the distance alike. The
        // last band is the farthest whose kernel stays on the page.
        let lastBand = try XCTUnwrap((0..<(frame.height - 4)).last { y in
            Double(y + 4) + timeline.radius(atDistance: Double(y + 4), tilt: 27) + 1 < Double(frame.height)
        })
        func band(at y: Int) -> (shown: Double, expected: Double) {
            let radius = timeline.radius(atDistance: Double(y) + 2, tilt: 27)
            let margin = Int(radius.rounded(.up)) + 2
            let columns = margin..<(frame.width - margin)
            let shown = Self.luminance(frame.statistics(rows: y..<(y + 4), columns: columns).mean)
            return (shown, paperLuminance * timeline.attenuation(radius: radius))
        }
        for y in [frame.height / 4, frame.height / 2, frame.height * 3 / 4, lastBand] {
            let measured = band(at: y)
            XCTAssertEqual(measured.shown, measured.expected, accuracy: 0.012, "\(y) pt down")
        }

        // The bottom keeps six tenths of its light: its kernel takes in the dark below the page too, so it lies
        // between that dark and the paper, each dimmed by that edge's attenuation.
        let farAttenuation = timeline.attenuation(radius: timeline.currentFrame.farEdgeRadius)
        XCTAssertEqual(farAttenuation, 0.6, accuracy: 0.001)
        let bottom = frame.statistics(rows: (frame.height - 2)..<frame.height, columns: 64..<(frame.width - 64))
        let backdropLuminance = Self.luminance(Self.backdrop)
        XCTAssertGreaterThanOrEqual(
            Self.luminance(bottom.mean), min(paperLuminance, backdropLuminance) * farAttenuation - 0.01
        )
        XCTAssertLessThanOrEqual(
            Self.luminance(bottom.mean), max(paperLuminance, backdropLuminance) * farAttenuation + 0.01
        )
    }

    /// Added from the card, a page shows only the card's room of itself, its top, where the frost
    /// has barely begun: on the 12.9-inch iPad in portrait that strip keeps 95% of its light at
    /// the frost's steepest, while the foot of the page keeps 60%. Hence the paper scrolls on to
    /// the new page as it clears.
    func testAtTheCardsGlimpseOfTheNewPageTheFrostBarelyShows() async throws {
        let unfold = try await readyUnfold()
        let fixture = try await PaperFixture(screenPixelsPerPoint: 1)
        let card = NotebookEndOfNotebookCard()
        card.configure(addPage: .available, contentSize: .large, maximumWidth: 1_024 - 2 * NotebookTheme.endCardGap)
        let room = card.bounds.height + 2 * NotebookTheme.endCardGap
        let zoom = 1_024 / Self.pageSize.width
        let strip = Int((room / zoom).rounded(.down))
        XCTAssertGreaterThan(strip, 100)
        let frame = try render(unfold, source: fixture.source, tilt: 27)
        let paper = Pixels(fixture.source)
        let columns = 64..<(frame.width - 64)
        func kept(_ rows: Range<Int>) -> Double {
            Self.luminance(frame.statistics(rows: rows, columns: columns).mean)
                / Self.luminance(paper.statistics(rows: rows, columns: columns).mean)
        }
        let glimpse = kept((strip - 8)..<strip)
        let foot = kept((frame.height - 40)..<(frame.height - 32))
        XCTAssertGreaterThan(glimpse, 0.94, "The glimpse's lowest rows, the most frosted it shows.")
        XCTAssertLessThan(foot, 0.65)
        try record(["cardRoomPoints": room, "glimpsePagePoints": Double(strip), "glimpseLightKept": glimpse,
                    "footLightKept": foot], name: "unfold-glimpse")
    }

    func testTheFrostBlursARuleOnItsOwnRow() async throws {
        let unfold = try await readyUnfold()
        let row = 1_050
        let tilt = try midwayTilt()
        let frame = try render(unfold, source: Self.ruled(row: row), tilt: tilt)
        let radius = Timeline(pageHeight: Self.pageSize.height).radius(atDistance: Double(row), tilt: tilt)
        XCTAssertGreaterThan(radius, 6, "the rule is blurred")
        let reach = Int(radius.rounded(.up)) + 8
        let columns = reach..<(frame.width - reach)
        let profile = ((row - reach)...(row + reach)).map { y in
            (y, Self.luminance(frame.statistics(rows: y..<(y + 1), columns: columns).mean))
        }
        let darkest = try XCTUnwrap(profile.min { $0.1 < $1.1 })
        XCTAssertEqual(Double(darkest.0), Double(row), accuracy: 2, "what the frost samples lies on the row it draws")
        let paper = try XCTUnwrap(profile.first).1
        XCTAssertLessThan(darkest.1, paper - 0.05, "the rule shows through the frost")
    }

    func testBlurredPixelsCarryTheGrainOfTheirRotatedKernels() async throws {
        let unfold = try await readyUnfold()
        let frame = try render(unfold, source: Self.checkerboard(), tilt: 27)
        let rows = 860..<900
        let columns = 120..<674
        var difference = 0.0
        var count = 0
        for y in rows {
            for x in columns.dropLast() {
                difference += abs(frame.luminance(x: x, y: y) - frame.luminance(x: x + 1, y: y))
                count += 1
            }
        }
        let meanDifference = difference / Double(count)
        // An even blur of a fine checkerboard this wide would be flat; per-pixel rotation leaves grain.
        XCTAssertGreaterThan(meanDifference, 0.01, "neighbouring frosted pixels differ")
        let distinct = Set(columns.map { frame.bytes[(880 * frame.width + $0) * 4] })
        XCTAssertGreaterThan(distinct.count, 12, "the grain varies along a row")
    }

    func testTheBackdropShowsWhereTheKernelMissesThePage() async throws {
        let unfold = try await readyUnfold()
        let source = Self.flat(Self.ivory)
        let frame = try render(unfold, source: source, tilt: 27)
        let timeline = Timeline(pageHeight: Self.pageSize.height)
        let y = 600
        let radius = timeline.radius(atDistance: Double(y) + 0.5, tilt: 27)
        let attenuation = timeline.attenuation(radius: radius)
        let centre = frame.color(x: frame.width / 2, y: y)
        for (channel, value) in [centre.x, centre.y, centre.z].enumerated() {
            XCTAssertEqual(
                value, Self.ivory[channel] * attenuation, accuracy: 2.0 / 255, "the page's own colour, darkened"
            )
        }
        let edge = frame.luminance(x: 0, y: y)
        let backdrop = Self.luminance(Self.backdrop) * attenuation
        XCTAssertLessThan(edge, frame.luminance(x: frame.width / 2, y: y) - 0.02, "the dark mixes in at the side")
        XCTAssertGreaterThan(edge, backdrop - 0.02)
    }

    // MARK: - Playing

    func testPlayDrawsTheFirstFrameOverTheNewPageAndFinishCutsToTheEnd() async throws {
        let unfold = try await readyUnfold()
        let fixture = try await PaperFixture()
        let completions = Counter()
        let played = unfold.play(
            page: fixture.page, source: fixture.source, in: fixture.paper.contentLayer, above: fixture.paper.grainLayer
        ) { completions.count += 1 }
        XCTAssertTrue(played)
        XCTAssertTrue(unfold.isPlaying)
        let layer = try XCTUnwrap(unfold.layer)
        XCTAssertTrue(layer.superlayer === fixture.paper.contentLayer)
        XCTAssertEqual(layer.frame, fixture.page)
        let sublayers = try XCTUnwrap(fixture.paper.contentLayer.sublayers)
        let grain = try XCTUnwrap(sublayers.firstIndex { $0 === fixture.paper.grainLayer })
        XCTAssertTrue(sublayers[grain + 1] === layer, "over the paper's grain, under its lines")
        XCTAssertEqual(layer.drawableSize, CGSize(width: fixture.source.width, height: fixture.source.height))
        XCTAssertEqual(unfold.framesDrawn, 1, "the first frame shows with the page")
        XCTAssertFalse(layer.presentsWithTransaction, "later frames present as soon as they are drawn")
        XCTAssertTrue(layer.animationKeys()?.isEmpty ?? true)

        unfold.finish()
        XCTAssertEqual(completions.count, 1)
        XCTAssertFalse(unfold.isPlaying)
        XCTAssertNil(unfold.layer)
        XCTAssertNil(layer.superlayer)
        unfold.finish()
        XCTAssertEqual(completions.count, 1, "finishing twice completes once")
    }

    func testAPlayWhileOneRunsFinishesThatOneFirst() async throws {
        let unfold = try await readyUnfold()
        let fixture = try await PaperFixture()
        let first = Counter()
        let second = Counter()
        unfold.play(page: fixture.page, source: fixture.source, in: fixture.paper.contentLayer) { first.count += 1 }
        let firstLayer = try XCTUnwrap(unfold.layer)
        unfold.play(page: fixture.page, source: fixture.source, in: fixture.paper.contentLayer) { second.count += 1 }
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 0)
        XCTAssertNil(firstLayer.superlayer)
        XCTAssertEqual(fixture.paper.contentLayer.sublayers?.filter { $0 is NotebookPageUnfoldLayer }.count, 1)
        unfold.finish()
        XCTAssertEqual(second.count, 1)
    }

    func testTheFrostNeverTakesTouches() async throws {
        let unfold = try await readyUnfold()
        let fixture = try await PaperFixture()
        unfold.play(page: fixture.page, source: fixture.source, in: fixture.paper.contentLayer) {}
        let layer = try XCTUnwrap(unfold.layer)
        let inside = CGPoint(x: fixture.page.midX, y: fixture.page.midY)
        XCTAssertNil(layer.hitTest(inside))
        XCTAssertFalse(layer.contains(CGPoint(x: 10, y: 10)))
        XCTAssertFalse(fixture.paper.contentLayer.hitTest(inside) === layer)
        XCTAssertFalse(fixture.paper.isUserInteractionEnabled, "the paper under the canvas takes no touches either")
        XCTAssertTrue(fixture.paper.subviews.isEmpty, "the frost is a layer, never a view")
        unfold.finish()
    }

    func testTheFrostClearsOnItsOwnAndHandsOverToThePage() async throws {
        let unfold = try await readyUnfold()
        let fixture = try await PaperFixture()
        let host = AppearanceTrackingController()
        let window = try NotebookTestFixtures.window(showing: host, width: 794)
        addTeardownBlock { @MainActor in
            window.isHidden = true
            window.rootViewController = nil
        }
        try await NotebookTestFixtures.waitUntilAppeared(host)
        host.view.addSubview(fixture.paper)

        let ended = expectation(description: "the frost ends")
        let started = CACurrentMediaTime()
        var duration: CFTimeInterval = 0
        unfold.play(page: fixture.page, source: fixture.source, in: fixture.paper.contentLayer) {
            duration = CACurrentMediaTime() - started
            ended.fulfill()
        }
        let layer = try XCTUnwrap(unfold.layer)
        await fulfillment(of: [ended], timeout: 5)
        XCTAssertFalse(unfold.isPlaying)
        XCTAssertNil(layer.superlayer)
        XCTAssertGreaterThan(unfold.framesDrawn, 1)
        XCTAssertLessThan(duration, 2)
        try record(
            ["playDurationSeconds": duration, "playFramesDrawn": Double(unfold.framesDrawn)], name: "unfold-play"
        )
    }

    func testReduceMotionFadesFromTheDarkBelowThePageWithoutFrost() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let unfold = NotebookPageUnfold(device: device, prefersReducedMotion: { true })
        _ = await unfold.ready()
        let fixture = try await PaperFixture()
        let ended = expectation(description: "the fade ends")
        let started = CACurrentMediaTime()
        var duration: CFTimeInterval = 0
        let played = unfold.play(page: fixture.page, source: fixture.source, in: fixture.paper.contentLayer) {
            duration = CACurrentMediaTime() - started
            ended.fulfill()
        }
        XCTAssertTrue(played)
        let layer = try XCTUnwrap(unfold.layer)
        XCTAssertEqual(
            layer.backgroundColor, NotebookTheme.backdropBelowPaper.cgColor,
            "it starts as the dark the page is added over"
        )
        XCTAssertEqual(layer.frame, fixture.page)
        await fulfillment(of: [ended], timeout: 3)
        XCTAssertEqual(unfold.framesDrawn, 0, "no frost is drawn")
        XCTAssertGreaterThanOrEqual(duration, NotebookPageUnfold.reducedMotionFadeDuration * 0.8)
        XCTAssertLessThan(duration, 1)
        XCTAssertNil(layer.superlayer)
    }

    func testWithoutMetalNothingPlays() async throws {
        for reducedMotion in [false, true] {
            let unfold = NotebookPageUnfold(device: nil, prefersReducedMotion: { reducedMotion })
            let ready = await unfold.ready()
            XCTAssertFalse(ready)
            let host = CALayer()
            let completions = Counter()
            let played = unfold.play(
                page: CGRect(origin: .zero, size: Self.pageSize), source: Self.flat(Self.ivory), in: host
            ) { completions.count += 1 }
            XCTAssertFalse(played)
            XCTAssertEqual(completions.count, 1, "completes at once")
            XCTAssertNil(host.sublayers)
            XCTAssertFalse(unfold.isPlaying)
        }
    }

    func testAPageAddedBeforeTheShadersAreReadySimplyAppears() throws {
        let unfold = NotebookPageUnfold(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        XCTAssertFalse(unfold.isReady)
        let host = CALayer()
        let completions = Counter()
        let played = unfold.play(
            page: CGRect(origin: .zero, size: Self.pageSize), source: Self.flat(Self.ivory), in: host
        ) { completions.count += 1 }
        XCTAssertFalse(played)
        XCTAssertEqual(completions.count, 1)
        XCTAssertNil(host.sublayers)
    }

    /// The caller draws a source only when the frost would draw over it; without one the frost
    /// shows nothing, while Reduce Motion's fade needs none.
    func testOnlyTheFrostNeedsASource() async throws {
        let unfold = try await readyUnfold()
        XCTAssertTrue(unfold.needsSource)
        let host = CALayer()
        let completions = Counter()
        let page = CGRect(origin: .zero, size: Self.pageSize)
        XCTAssertFalse(unfold.play(page: page, source: nil, in: host) { completions.count += 1 })
        XCTAssertEqual(completions.count, 1)
        XCTAssertNil(host.sublayers)

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let reduced = NotebookPageUnfold(device: device, prefersReducedMotion: { true })
        _ = await reduced.ready()
        XCTAssertFalse(reduced.needsSource, "The fade needs no picture of the page.")
        XCTAssertTrue(reduced.play(page: page, source: nil, in: host) {})
        XCTAssertEqual(reduced.layer?.backgroundColor, NotebookTheme.backdropBelowPaper.cgColor)
        reduced.finish()
        XCTAssertFalse(NotebookPageUnfold(device: nil).needsSource)
        XCTAssertFalse(NotebookPageUnfold(device: device).needsSource, "Not before the shaders are ready.")
    }

    // MARK: - Placement

    func testOnlyAPageThatShowsIsWorthTheFrost() {
        let page = CGRect(x: 0, y: 1_123, width: 794, height: 1_123)
        XCTAssertTrue(NotebookPageUnfold.isVisible(page: page, within: CGRect(x: 0, y: 900, width: 794, height: 600)))
        XCTAssertFalse(
            NotebookPageUnfold.isVisible(page: page, within: CGRect(x: 0, y: 523, width: 794, height: 600)),
            "a viewport ending at the page's top edge shows none of it"
        )
        XCTAssertFalse(NotebookPageUnfold.isVisible(page: page, within: CGRect(x: 0, y: 0, width: 794, height: 600)))
        XCTAssertTrue(NotebookPageUnfold.isVisible(page: page, within: CGRect(x: 0, y: 2_000, width: 794, height: 600)))
    }

    func testVisibleContentFollowsTheCanvasOffsetAndZoom() {
        let zooming = ZoomingScrollView(frame: CGRect(x: 0, y: 0, width: 1_032, height: 1_376))
        zooming.setZoomScale(1.3, animated: false)
        zooming.contentOffset = CGPoint(x: 0, y: 1_300)
        let visible = NotebookPageUnfold.visibleContent(of: zooming)
        XCTAssertEqual(visible.minY, 1_000, accuracy: 0.001)
        XCTAssertEqual(visible.width, 1_032 / 1.3, accuracy: 0.001)
        XCTAssertEqual(visible.height, 1_376 / 1.3, accuracy: 0.001)
        let page = CGRect(x: 0, y: 2_246, width: 794, height: 1_123)
        XCTAssertFalse(NotebookPageUnfold.isVisible(page: page, in: zooming))
        zooming.contentOffset = CGPoint(x: 0, y: 1_900)
        XCTAssertTrue(NotebookPageUnfold.isVisible(page: page, in: zooming))
    }

    func testSnapshotDrawsThePaperAsItShowsWithItsGrain() async throws {
        let fixture = try await PaperFixture(screenPixelsPerPoint: 2.6)
        XCTAssertEqual(fixture.source.width, 1_588, "two pixels per point at most")
        XCTAssertEqual(fixture.source.height, Int((Self.pageSize.height * 2).rounded()))
        let pixels = Pixels(fixture.source)
        let all = pixels.statistics(rows: 8..<(pixels.height - 8), columns: 0..<pixels.width)
        for channel in 0..<3 {
            XCTAssertEqual(all.mean[channel], Self.ivory[channel], accuracy: 0.01, "paper colour on average")
        }
        XCTAssertGreaterThan(all.variance.squareRoot(), 0.005, "the fibre pattern is drawn, not flat paper")

        fixture.paper.grainLayer.isHidden = true
        let plain = try XCTUnwrap(
            NotebookPageUnfold.snapshot(of: fixture.paper.contentLayer, rect: fixture.page, screenPixelsPerPoint: 2)
        )
        let plainPixels = Pixels(plain)
        XCTAssertLessThan(
            plainPixels.statistics(rows: 8..<(plainPixels.height - 8), columns: 0..<plainPixels.width).variance,
            1e-6
        )
        XCTAssertNil(NotebookPageUnfold.snapshot(of: fixture.paper.contentLayer, rect: .zero, screenPixelsPerPoint: 2))
    }

    /// The blank page the controller gives the frost is the paper as the screen shows it, its
    /// fibres in the same phase, so the hand-off to the live page shows no change of grain.
    func testBlankPageMatchesThePaperOnScreen() async throws {
        await ready(NotebookMaterials.shared)
        let host = AppearanceTrackingController()
        let window = try NotebookTestFixtures.window(showing: host, width: 794)
        addTeardownBlock { @MainActor in
            window.isHidden = true
            window.rootViewController = nil
        }
        try await NotebookTestFixtures.waitUntilAppeared(host)
        let height = Self.pageSize.height
        let paper = NotebookPaperView(frame: CGRect(x: 0, y: 0, width: 794, height: 1_366))
        host.view.addSubview(paper)
        // The third page, whose top is neither a whole point nor a whole repeat of the fibres.
        paper.setGeometry(width: 794, height: height * 3, boundaries: [height, height * 2])
        let page = CGRect(x: 0, y: height * 2, width: 794, height: height)
        paper.setViewport(scale: 1, offset: CGPoint(x: 0, y: page.minY))
        let scale = window.traitCollection.displayScale
        XCTAssertEqual(scale, 2, "The comparison assumes the frost's own two pixels per point.")
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let screen = try XCTUnwrap(UIGraphicsImageRenderer(bounds: paper.bounds, format: format).image { _ in
            paper.drawHierarchy(in: paper.bounds, afterScreenUpdates: true)
        }.cgImage)
        let shown = Pixels(screen)
        let blank = Pixels(try XCTUnwrap(paper.blankPageImage(page, screenPixelsPerPoint: scale)))
        XCTAssertEqual(blank.width, 1_588)
        XCTAssertEqual(blank.height, Int((height * 2).rounded()))

        // Below the divider at the page's top and above its foot, across the whole width.
        let rows = 6..<(blank.height - 6)
        func difference(shift: Int) -> Double {
            var total = 0.0
            var count = 0
            for y in stride(from: rows.lowerBound, to: rows.upperBound, by: 3) {
                for x in stride(from: 0, to: blank.width - 64, by: 3) {
                    total += abs(blank.luminance(x: x + shift, y: y) - shown.luminance(x: x, y: y))
                    count += 1
                }
            }
            return total / Double(count)
        }
        let aligned = difference(shift: 0)
        let shifted = difference(shift: 37)
        XCTAssertLessThan(aligned, 1.5 / 255, "The paper as the screen shows it.")
        XCTAssertLessThan(aligned * 3, shifted, "The fibres lie in the screen's phase, not merely look alike.")
        let fibres = blank.statistics(rows: rows, columns: 0..<blank.width)
        XCTAssertGreaterThan(fibres.variance.squareRoot(), 0.005, "The fibres are drawn, not flat paper.")

        paper.grainLayer.isHidden = true
        let plain = Pixels(try XCTUnwrap(paper.blankPageImage(page, screenPixelsPerPoint: scale)))
        let flat = plain.statistics(rows: 0..<plain.height, columns: 0..<plain.width)
        XCTAssertLessThan(flat.variance, 1e-6, "Plain materials leave flat paper.")
        for channel in 0..<3 {
            XCTAssertEqual(flat.mean[channel], Self.ivory[channel], accuracy: 0.5 / 255)
        }
        XCTAssertNil(paper.blankPageImage(.zero, screenPixelsPerPoint: scale))
    }

    // MARK: - Report

    /// Times the blank page against a snapshot of the paper's layers, on the main thread where the
    /// controller takes it, and records both with the upload.
    func testBlankPageCostsLessThanASnapshotOfThePaper() async throws {
        await ready(NotebookMaterials.shared)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let unfold = try await readyUnfold()
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let height = Self.pageSize.height
        let paper = NotebookPaperView(frame: CGRect(x: 0, y: 0, width: 794, height: 1_000))
        paper.setGeometry(width: 794, height: height * 2, boundaries: [height])
        let page = CGRect(x: 0, y: height, width: 794, height: height)

        let firstStart = CACurrentMediaTime()
        _ = paper.blankPageImage(page, screenPixelsPerPoint: 2)
        let first = CACurrentMediaTime() - firstStart
        var blanks: [Double] = []
        var snapshots: [Double] = []
        var uploads: [Double] = []
        for _ in 0..<7 {
            let blankStart = CACurrentMediaTime()
            let blank = try XCTUnwrap(paper.blankPageImage(page, screenPixelsPerPoint: 2))
            blanks.append(CACurrentMediaTime() - blankStart)
            let snapshotStart = CACurrentMediaTime()
            _ = try XCTUnwrap(NotebookPageUnfold.snapshot(of: paper.contentLayer, rect: page, screenPixelsPerPoint: 2))
            snapshots.append(CACurrentMediaTime() - snapshotStart)
            uploads.append(try upload(blank, with: unfold, queue: queue).encode)
        }
        let blank = Self.median(blanks)
        let snapshot = Self.median(snapshots)
        try record([
            "firstBlankPageSeconds": first, "blankPageMedianSeconds": blank, "snapshotMedianSeconds": snapshot,
            "uploadEncodeMedianSeconds": Self.median(uploads)
        ], name: "unfold-source-timing")
        XCTAssertLessThan(blank, snapshot, "Tiling the fibres costs less than rendering the layers.")
    }

    func testFrameTimingSmoke() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let compileStart = CACurrentMediaTime()
        let unfold = NotebookPageUnfold(device: device)
        _ = await unfold.ready()
        let compile = CACurrentMediaTime() - compileStart
        await ready(NotebookMaterials.shared)
        let paper = NotebookPaperView(frame: CGRect(x: 0, y: 0, width: 794, height: 1_000))
        paper.setGeometry(width: 794, height: Self.pageSize.height * 2, boundaries: [Self.pageSize.height])
        let page = CGRect(x: 0, y: Self.pageSize.height, width: 794, height: Self.pageSize.height)

        let snapshotStart = CACurrentMediaTime()
        let source = try XCTUnwrap(
            NotebookPageUnfold.snapshot(of: paper.contentLayer, rect: page, screenPixelsPerPoint: 2)
        )
        let snapshot = CACurrentMediaTime() - snapshotStart
        let warmStart = CACurrentMediaTime()
        _ = NotebookPageUnfold.snapshot(of: paper.contentLayer, rect: page, screenPixelsPerPoint: 2)
        let warmSnapshot = CACurrentMediaTime() - warmStart
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let (texture, uploadEncode, upload) = try upload(source, with: unfold, queue: queue)

        let target = try renderTarget(device, width: source.width, height: source.height)
        let timeline = Timeline(pageHeight: Self.pageSize.height)
        var report: [String: Double] = [
            "pipelineReadySeconds": compile, "snapshotSeconds": snapshot, "warmSnapshotSeconds": warmSnapshot,
            "uploadEncodeSeconds": uploadEncode,
            "uploadSeconds": upload, "drawablePixels": Double(source.width * source.height)
        ]
        for (tilt, taps) in [(27.0, 32), (13.5, 32), (3.0, 32), (27.0, 6)] {
            var encodes: [Double] = []
            var gpu: [Double] = []
            var walls: [Double] = []
            for _ in 0..<12 {
                let timing = try timeFrame(
                    unfold, tilt: tilt, taps: taps, timeline: timeline, pageSize: page.size, source: texture,
                    target: target, queue: queue
                )
                encodes.append(timing.encode)
                gpu.append(timing.gpu)
                walls.append(timing.wall)
            }
            let label = "tilt\(Int(tilt))taps\(taps)"
            report["\(label).encodeMedianMilliseconds"] = Self.median(encodes) * 1_000
            report["\(label).gpuMedianMilliseconds"] = Self.median(Array(gpu.dropFirst(2))) * 1_000
            report["\(label).wallMedianMilliseconds"] = Self.median(Array(walls.dropFirst(2))) * 1_000
            XCTAssertTrue(encodes.allSatisfy { $0.isFinite && $0 > 0 })
            XCTAssertTrue(walls.allSatisfy { $0.isFinite && $0 > 0 })
        }
        try record(report, name: "unfold-timing")
    }

    func testFilmstripOfTheClearing() async throws {
        let unfold = try await readyUnfold()
        let fixture = try await PaperFixture(screenPixelsPerPoint: 1)
        let written = Self.writtenPage(over: fixture.source)
        var timeline = Timeline(pageHeight: Self.pageSize.height)
        var frames: [Timeline.Frame] = []
        var elapsed = 0.0
        while frames.last?.isFinished != true {
            frames.append(timeline.advance(elapsed: elapsed, interval: elapsed == 0 ? 0 : 1_000.0 / 60))
            elapsed += 1_000.0 / 60
        }
        let picks = (0..<6).map { frames[$0 * (frames.count - 1) / 5] }
        var means: [Double] = []
        for (name, source) in [("blank", fixture.source), ("written", written)] {
            let live = Pixels(source)
            var panels: [Pixels] = []
            for frame in picks {
                let frost = try render(unfold, source: source, tilt: frame.tilt, taps: frame.taps, timeline: timeline)
                let shown = frost.over(live, opacity: frame.fade)
                if name == "blank" {
                    means.append(shown.statistics(rows: 0..<shown.height, columns: 0..<shown.width).mean.sum())
                }
                panels.append(shown)
            }
            try write(Pixels.strip(panels, gap: 24, background: Self.backdrop), name: "unfold-filmstrip-\(name)")
            if name == "written" {
                let crops = try [frames[0], frames[14]].map { frame in
                    try render(unfold, source: source, tilt: frame.tilt, timeline: timeline)
                        .crop(x: 0, y: 700, width: 400, height: 300)
                }
                try write(Pixels.strip(crops, gap: 12, background: Self.backdrop), name: "unfold-grain-crop")
            }
        }
        for (earlier, later) in zip(means, means.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier, later + 0.001, "the page only brightens as the frost clears")
        }
    }

    // MARK: - Helpers

    /// The near-black a page is added over, which the frost shows wherever its kernel misses the page.
    private static var backdrop: SIMD3<Double> {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        NotebookTheme.backdropBelowPaper.uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return SIMD3(Double(red), Double(green), Double(blue))
    }

    private nonisolated static func luminance(_ color: SIMD3<Double>) -> Double {
        0.2126 * color.x + 0.7152 * color.y + 0.0722 * color.z
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    private func readyUnfold() async throws -> NotebookPageUnfold {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let unfold = NotebookPageUnfold(device: device, prefersReducedMotion: { false })
        let ready = await unfold.ready()
        XCTAssertTrue(ready, "the shaders must compile")
        return unfold
    }

    private func ready(_ materials: NotebookMaterials) async {
        await withCheckedContinuation { continuation in
            materials.whenReady { _ in continuation.resume() }
        }
    }

    /// The tilt about halfway through the clearing at 60 Hz and the source's pace, its twentieth
    /// frame; the app's slower pace passes through the same tilt later.
    private func midwayTilt() throws -> Double {
        var timeline = Timeline(pageHeight: Self.pageSize.height, timeScale: Timeline.sourceTimeScale)
        var tilt = timeline.currentFrame.tilt
        for frame in 0...19 {
            tilt = timeline.advance(elapsed: Double(frame) * 1_000 / 60, interval: frame == 0 ? 0 : 1_000.0 / 60).tilt
        }
        XCTAssertEqual(tilt, 11.5503452725291, accuracy: 1e-9)
        return tilt
    }

    /// Checks a frost frame at `tilt` against the page it frosts, by `timeline`'s blur: sharp where
    /// the blur is under half a point, flatter and darker by the attenuation where it is wide.
    private func assertFrost(
        _ frame: Pixels, over original: Pixels, tilt: Double,
        timeline: Timeline = Timeline(pageHeight: NotebookPageUnfoldTests.pageSize.height), line: UInt = #line
    ) throws {
        XCTAssertEqual(frame.width, original.width, line: line)
        XCTAssertEqual(frame.height, original.height, line: line)
        var sharpRows = 0
        for y in 0..<frame.height {
            let radius = timeline.radius(atDistance: Double(y) + 0.5, tilt: tilt)
            guard radius < 0.45 else { break }
            let attenuation = timeline.attenuation(radius: radius)
            for x in stride(from: 0, to: frame.width, by: 7) {
                let expected = original.color(x: x, y: y) * attenuation
                let actual = frame.color(x: x, y: y)
                XCTAssertEqual(actual.x, expected.x, accuracy: 2.0 / 255, "sharp at \(x), \(y)", line: line)
                XCTAssertEqual(actual.z, expected.z, accuracy: 2.0 / 255, "sharp at \(x), \(y)", line: line)
            }
            sharpRows += 1
        }
        XCTAssertGreaterThan(sharpRows, 0, "the top edge is sharp", line: line)

        let height = Double(frame.height)
        var frostedBands = 0
        for depth in [0.45, 0.65, 0.8, 0.95] {
            let y = Int(height * depth)
            let radius = timeline.radius(atDistance: Double(y), tilt: tilt)
            guard radius > 6, Double(y) + radius < height - 4 else { continue }
            frostedBands += 1
            let margin = Int(radius.rounded(.up)) + 4
            let rows = y..<(y + 4)
            let columns = margin..<(frame.width - margin)
            let frosted = frame.statistics(rows: rows, columns: columns)
            let page = original.statistics(rows: rows, columns: columns)
            XCTAssertLessThan(frosted.variance, page.variance * 0.25, "blurred \(Int(depth * 100))% down", line: line)
            let attenuation = timeline.attenuation(radius: radius + 0.5)
            for channel in 0..<3 {
                XCTAssertEqual(
                    frosted.mean[channel], page.mean[channel] * attenuation, accuracy: 0.02,
                    "darkened by the attenuation \(Int(depth * 100))% down", line: line
                )
            }
        }
        XCTAssertGreaterThan(frostedBands, 0, "a band wide enough to judge the blur", line: line)
    }

    /// Renders one frame of `timeline`'s frost over `source`, a page of `pageSize` at the image's
    /// pixels, and reads it back.
    private func render(
        _ unfold: NotebookPageUnfold, source: CGImage, tilt: Double, taps: Int = Timeline.maximumTaps,
        timeline: Timeline = Timeline(pageHeight: NotebookPageUnfoldTests.pageSize.height)
    ) throws -> Pixels {
        let device = try XCTUnwrap(unfold.device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let texture = try XCTUnwrap(unfold.makeTexture(source, commands: commands))
        let target = try renderTarget(device, width: source.width, height: source.height)
        unfold.encode(
            tilt: tilt, taps: taps, timeline: timeline, pageSize: Self.pageSize, source: texture, into: target,
            commands: commands
        )
        let bytesPerRow = source.width * 4
        let length = bytesPerRow * source.height
        let buffer = try XCTUnwrap(device.makeBuffer(length: length, options: .storageModeShared))
        let blit = try XCTUnwrap(commands.makeBlitCommandEncoder())
        blit.copy(
            from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: source.width, height: source.height, depth: 1), to: buffer,
            destinationOffset: 0, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: length
        )
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        XCTAssertNil(commands.error)
        let contents = buffer.contents().assumingMemoryBound(to: UInt8.self)
        var bytes = [UInt8](UnsafeBufferPointer(start: contents, count: length))
        for index in stride(from: 0, to: length, by: 4) {
            bytes.swapAt(index, index + 2)
        }
        return Pixels(width: source.width, height: source.height, bytes: bytes)
    }

    /// Uploads `source` and returns the texture with the time to encode the upload and to finish it.
    private func upload(
        _ source: CGImage, with unfold: NotebookPageUnfold, queue: MTLCommandQueue
    ) throws -> (MTLTexture, encode: Double, total: Double) {
        let start = CACurrentMediaTime()
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let texture = try XCTUnwrap(unfold.makeTexture(source, commands: commands))
        let encode = CACurrentMediaTime() - start
        commands.commit()
        commands.waitUntilCompleted()
        return (texture, encode, CACurrentMediaTime() - start)
    }

    /// Draws one frame and returns the time to encode and commit it, the GPU's own time for it (0
    /// where it reports none) and the wall time until it finished.
    private func timeFrame(
        _ unfold: NotebookPageUnfold, tilt: Double, taps: Int, timeline: Timeline, pageSize: CGSize,
        source: MTLTexture, target: MTLTexture, queue: MTLCommandQueue
    ) throws -> (encode: Double, gpu: Double, wall: Double) {
        let start = CACurrentMediaTime()
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        unfold.encode(
            tilt: tilt, taps: taps, timeline: timeline, pageSize: pageSize, source: source, into: target,
            commands: commands
        )
        commands.commit()
        let encode = CACurrentMediaTime() - start
        commands.waitUntilCompleted()
        let wall = CACurrentMediaTime() - start
        return (encode, max(commands.gpuEndTime - commands.gpuStartTime, 0), wall)
    }

    private func renderTarget(_ device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    /// Ivory and charcoal squares `cell` pixels across, one pixel per point: detail a wide blur can
    /// only average.
    private static func checkerboard(cell: Int = 4) -> CGImage {
        let width = Int(pageSize.width)
        let height = Int(pageSize.height.rounded())
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let color = (x / cell + y / cell).isMultiple(of: 2) ? ivory : charcoal
                let index = (y * width + x) * 4
                bytes[index] = UInt8((color.x * 255).rounded())
                bytes[index + 1] = UInt8((color.y * 255).rounded())
                bytes[index + 2] = UInt8((color.z * 255).rounded())
            }
        }
        return Pixels(width: width, height: height, bytes: bytes).image
    }

    private static func flat(_ color: SIMD3<Double>) -> CGImage {
        let width = Int(pageSize.width)
        let height = Int(pageSize.height.rounded())
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            bytes[index] = UInt8((color.x * 255).rounded())
            bytes[index + 1] = UInt8((color.y * 255).rounded())
            bytes[index + 2] = UInt8((color.z * 255).rounded())
        }
        return Pixels(width: width, height: height, bytes: bytes).image
    }

    /// Ivory with a charcoal rule three pixels thick centred on `row`, one pixel per point.
    private static func ruled(row: Int) -> CGImage {
        var pixels = Pixels(flat(ivory))
        let ink = [charcoal.x, charcoal.y, charcoal.z].map { UInt8(($0 * 255).rounded()) }
        for y in (row - 1)...(row + 1) {
            for x in 0..<pixels.width {
                let index = (y * pixels.width + x) * 4
                pixels.bytes.replaceSubrange(index..<(index + 3), with: ink)
            }
        }
        return pixels.image
    }

    /// `paper` with lines of dark, uneven dashes, as a handwritten page reads from a distance.
    private static func writtenPage(over paper: CGImage) -> CGImage {
        let size = CGSize(width: paper.width, height: paper.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIImage(cgImage: paper).draw(in: CGRect(origin: .zero, size: size))
            let cg = context.cgContext
            cg.setStrokeColor(UIColor(red: 0.12, green: 0.11, blue: 0.10, alpha: 1).cgColor)
            cg.setLineWidth(2)
            cg.setLineCap(.round)
            var generator = SplitMix(seed: 7)
            for line in stride(from: 70.0, to: size.height - 60, by: 34) {
                var x = 56.0
                while x < size.width - 80 {
                    let word = 18 + generator.unit() * 70
                    var pen = x
                    cg.move(to: CGPoint(x: pen, y: line))
                    while pen < x + word {
                        pen += 4 + generator.unit() * 5
                        cg.addLine(to: CGPoint(x: pen, y: line - 9 * generator.unit()))
                    }
                    cg.strokePath()
                    x += word + 12 + generator.unit() * 10
                }
            }
        }
        return image.cgImage!
    }

    private func record(_ values: [String: Double], name: String) throws {
        guard let directory = Self.shotsDirectory else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url.appendingPathComponent("\(name).json"), options: .atomic)
    }

    private func write(_ pixels: Pixels, name: String) throws {
        guard let directory = Self.shotsDirectory else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let data = try XCTUnwrap(UIImage(cgImage: pixels.image).pngData())
        try data.write(to: url.appendingPathComponent("\(name).png"), options: .atomic)
    }

    /// Two pages of paper with its fibres, and a snapshot of the second.
    private struct PaperFixture {
        let paper: NotebookPaperView
        let page: CGRect
        let source: CGImage

        @MainActor
        init(screenPixelsPerPoint: CGFloat = 2) async throws {
            await withCheckedContinuation { continuation in
                NotebookMaterials.shared.whenReady { _ in continuation.resume() }
            }
            let height = NotebookPageUnfoldTests.pageSize.height
            paper = NotebookPaperView(frame: CGRect(x: 0, y: 0, width: 794, height: 1_000))
            paper.setGeometry(width: 794, height: height * 2, boundaries: [height])
            paper.setViewport(scale: 1, offset: CGPoint(x: 0, y: height - 400))
            page = CGRect(x: 0, y: height, width: 794, height: height)
            let snapshot = NotebookPageUnfold.snapshot(
                of: paper.contentLayer, rect: page, screenPixelsPerPoint: screenPixelsPerPoint
            )
            source = try XCTUnwrap(snapshot)
        }
    }

    @MainActor
    private final class Counter {
        var count = 0
    }

    /// A scroll view that zooms, as the canvas does.
    private final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate {
        private let content = UIView(frame: CGRect(x: 0, y: 0, width: 794, height: 3_369))

        override init(frame: CGRect) {
            super.init(frame: frame)
            addSubview(content)
            contentSize = content.bounds.size
            minimumZoomScale = 0.5
            maximumZoomScale = 4
            delegate = self
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("Use init(frame:).")
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }
    }

    /// A deterministic sequence for the written page's strokes.
    private struct SplitMix {
        var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func unit() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }
    }

    /// RGBA pixels, eight bits a channel, rows from the top.
    private struct Pixels {
        let width: Int
        let height: Int
        var bytes: [UInt8]

        init(width: Int, height: Int, bytes: [UInt8]) {
            self.width = width
            self.height = height
            self.bytes = bytes
        }

        init(_ image: CGImage) {
            width = image.width
            height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            bytes.withUnsafeMutableBytes { raw in
                let context = CGContext(
                    data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
                context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            self.bytes = bytes
        }

        var image: CGImage {
            let provider = CGDataProvider(data: Data(bytes) as CFData)!
            return CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent
            )!
        }

        func color(x: Int, y: Int) -> SIMD3<Double> {
            let index = (y * width + x) * 4
            return SIMD3(Double(bytes[index]), Double(bytes[index + 1]), Double(bytes[index + 2])) / 255
        }

        func luminance(x: Int, y: Int) -> Double {
            NotebookPageUnfoldTests.luminance(color(x: x, y: y))
        }

        /// The mean colour over a region and the variance of its luminance.
        func statistics(rows: Range<Int>, columns: Range<Int>) -> (mean: SIMD3<Double>, variance: Double) {
            var sum = SIMD3<Double>(repeating: 0)
            var luminanceSum = 0.0
            var squares = 0.0
            for y in rows {
                for x in columns {
                    let color = color(x: x, y: y)
                    let value = NotebookPageUnfoldTests.luminance(color)
                    sum += color
                    luminanceSum += value
                    squares += value * value
                }
            }
            let count = Double(rows.count * columns.count)
            let mean = luminanceSum / count
            return (sum / count, max(squares / count - mean * mean, 0))
        }

        /// The mean difference per colour channel from `other` over `rows`.
        func meanDifference(from other: Pixels, rows: ClosedRange<Int>) -> Double {
            var total = 0.0
            for y in rows {
                for x in 0..<width {
                    let difference = color(x: x, y: y) - other.color(x: x, y: y)
                    total += (abs(difference.x) + abs(difference.y) + abs(difference.z)) / 3
                }
            }
            return total / Double(rows.count * width)
        }

        func largestDifference(from other: Pixels) -> Double {
            zip(bytes, other.bytes).enumerated().reduce(0) { largest, item in
                guard item.offset % 4 != 3 else { return largest }
                return max(largest, abs(Double(item.element.0) - Double(item.element.1)) / 255)
            }
        }

        /// This frame laid over `under` at `opacity`, as the layer shows over the live page.
        func over(_ under: Pixels, opacity: Double) -> Pixels {
            var mixed = bytes
            for index in mixed.indices where index % 4 != 3 {
                let value = Double(bytes[index]) * opacity + Double(under.bytes[index]) * (1 - opacity)
                mixed[index] = UInt8(value.rounded())
            }
            return Pixels(width: width, height: height, bytes: mixed)
        }

        func crop(x: Int, y: Int, width: Int, height: Int) -> Pixels {
            var cropped: [UInt8] = []
            cropped.reserveCapacity(width * height * 4)
            for row in y..<(y + height) {
                let start = (row * self.width + x) * 4
                cropped.append(contentsOf: bytes[start..<(start + width * 4)])
            }
            return Pixels(width: width, height: height, bytes: cropped)
        }

        /// Panels side by side, `gap` pixels apart on `background`.
        static func strip(_ panels: [Pixels], gap: Int, background: SIMD3<Double>) -> Pixels {
            let height = panels.map(\.height).max() ?? 0
            let width = panels.map(\.width).reduce(0, +) + gap * (panels.count + 1)
            let fill = [background.x, background.y, background.z].map { UInt8(($0 * 255).rounded()) } + [255]
            var bytes = [UInt8]()
            bytes.reserveCapacity(width * (height + 2 * gap) * 4)
            for _ in 0..<(width * (height + 2 * gap)) { bytes.append(contentsOf: fill) }
            var strip = Pixels(width: width, height: height + 2 * gap, bytes: bytes)
            var left = gap
            for panel in panels {
                for row in 0..<panel.height {
                    let source = row * panel.width * 4
                    let target = ((row + gap) * width + left) * 4
                    strip.bytes.replaceSubrange(
                        target..<(target + panel.width * 4), with: panel.bytes[source..<(source + panel.width * 4)]
                    )
                }
                left += panel.width + gap
            }
            return strip
        }
    }
}
