import CoreImage
import NottyCore
import PencilKit
import UIKit
import XCTest
@testable import Notty

@MainActor
final class NotebookMaterialsTests: XCTestCase {
    func testTileIsRenderedOnceAcrossManyUses() async {
        let probe = RenderProbe()
        let materials = probe.materials()
        XCTAssertEqual(probe.renderCount, 0)
        await ready(materials)
        XCTAssertEqual(probe.renderCount, 1)
        let fibre = materials.paperFibrePattern
        XCTAssertNotNil(fibre)
        let settings = AccessibilitySettings()
        for _ in 0..<200 {
            materials.prepare()
            XCTAssertTrue(materials.paperFibrePattern === fibre)
        }
        await ready(materials)
        for _ in 0..<20 {
            let paper = NotebookPaperView(frame: .zero, materials: materials, accessibility: settings.source)
            paper.setGeometry(width: 794, height: 3_369, boundaries: [1_123, 2_246])
            XCTAssertTrue(paper.grainLayer.backgroundColor === fibre)
        }
        XCTAssertEqual(probe.renderCount, 1)
    }

    func testOpeningPaperNeverRendersTexturesOnTheMainThread() async throws {
        let probe = RenderProbe()
        let materials = probe.materials()
        let settings = AccessibilitySettings()
        let paper = NotebookPaperView(frame: .zero, materials: materials, accessibility: settings.source)
        paper.setGeometry(width: 794, height: 1_123, boundaries: [])
        XCTAssertEqual(probe.renderCount, 0, "creating the paper must not render a tile synchronously")
        XCTAssertNil(paper.grainLayer.backgroundColor, "plain paper shows until the fibres are ready")
        var released: NotebookPaperView? = NotebookPaperView(frame: .zero, materials: materials, accessibility: settings.source)
        weak let releasedReference = released
        released = nil
        XCTAssertNil(releasedReference, "a pending fibre request must not keep a paper view alive")

        await ready(materials)
        XCTAssertEqual(probe.renderCount, 1)
        XCTAssertFalse(probe.renderedOnMainThread)
        let pattern = try XCTUnwrap(paper.grainLayer.backgroundColor)
        XCTAssertNotNil(pattern.pattern)
        XCTAssertTrue(pattern === materials.paperFibrePattern)
        XCTAssertTrue(paper.grainLayer.animationKeys()?.isEmpty ?? true)
    }

    func testFailedRenderingFallsBackToFlatPaper() async throws {
        let materials = NotebookMaterials { nil }
        let paper = NotebookPaperView(
            frame: CGRect(x: 0, y: 0, width: 300, height: 200), materials: materials,
            accessibility: AccessibilitySettings().source
        )
        paper.setGeometry(width: 794, height: 1_123, boundaries: [])
        paper.setViewport(scale: 1, offset: CGPoint(x: 40, y: 20))
        await ready(materials)
        XCTAssertNotNil(paper.grainLayer.backgroundColor?.pattern)
        let pixels = try render(paper, scale: 2)
        XCTAssertLessThan(pixels.luminanceRange, 0.001, "A failed render leaves flat paper, not a pattern.")
        try assertMeanColor(of: pixels, equals: NotebookTheme.paperIvory)
    }

    func testTilePixelSizesAndMemoryAreBounded() async throws {
        let probe = RenderProbe()
        let materials = probe.materials()
        await ready(materials)
        let fibre = try XCTUnwrap(probe.lastOutput)
        XCTAssertEqual(fibre.width, 512)
        XCTAssertEqual(fibre.height, 512)
        XCTAssertLessThanOrEqual(fibre.bytesPerRow * fibre.height, 1_024 * 1_024, "One RGBA tile, nothing more.")
    }

    func testFibreTileIsVisibleButStaysCloseToThePaperColour() async throws {
        let pixels = try SRGBPixels(await Self.renderedFibreTile())
        let paper = try XCTUnwrap(SRGBPixels.components(NotebookPaperView.paperColor))
        let paperLuminance = SRGBPixels.relativeLuminance(paper)
        let deviations = pixels.colors.map { abs(SRGBPixels.relativeLuminance($0) - paperLuminance) }
        let maximum = try XCTUnwrap(deviations.max())
        XCTAssertLessThanOrEqual(maximum, 0.06, "Fibres must stay quiet enough for thin ink.")
        XCTAssertGreaterThanOrEqual(maximum, 0.05, "Fibres must be visible as a tactile texture.")
        let spread = pixels.luminanceStandardDeviation
        XCTAssertGreaterThanOrEqual(spread, 0.012, "Tooth and fibres must cover the page, not a few specks.")
        XCTAssertLessThanOrEqual(spread, 0.02, "The texture must stay subtle behind handwriting.")
        let mean = pixels.meanColor
        XCTAssertEqual(mean.red, paper.red, accuracy: 0.004)
        XCTAssertEqual(mean.green, paper.green, accuracy: 0.004)
        XCTAssertEqual(mean.blue, paper.blue, accuracy: 0.004)
    }

    func testTileWrapsWithoutVisibleSeams() async throws {
        let pixels = try SRGBPixels(await Self.renderedFibreTile())
        let last = pixels.width - 1
        let middle = pixels.width / 2
        let horizontalSeam = pixels.meanDifference { (pixels.color(x: 0, y: $0), pixels.color(x: last, y: $0)) }
        let horizontalInterior = pixels.meanDifference {
            (pixels.color(x: middle, y: $0), pixels.color(x: middle - 1, y: $0))
        }
        let verticalSeam = pixels.meanDifference { (pixels.color(x: $0, y: 0), pixels.color(x: $0, y: last)) }
        let verticalInterior = pixels.meanDifference {
            (pixels.color(x: $0, y: middle), pixels.color(x: $0, y: middle - 1))
        }
        XCTAssertLessThanOrEqual(horizontalSeam, horizontalInterior * 1.5 + 0.001)
        XCTAssertLessThanOrEqual(verticalSeam, verticalInterior * 1.5 + 0.001)
    }

    func testGrainCoversHeadMarginAndPagesBelowEveryLineAndShade() async throws {
        await ready(.shared)
        let paper = NotebookPaperView(frame: .zero, accessibility: AccessibilitySettings().source)
        paper.setGeometry(width: 794, height: 3_369, boundaries: [1_123, 2_246])
        let sublayers = try XCTUnwrap(paper.contentLayer.sublayers)
        XCTAssertTrue(paper.grainLayer.superlayer === paper.contentLayer)
        XCTAssertTrue(sublayers.first === paper.headMarginLayer, "the opaque grain must lie over the head margin")
        XCTAssertTrue(sublayers.dropFirst().first === paper.grainLayer)
        let grainIndex = try XCTUnwrap(sublayers.firstIndex { $0 === paper.grainLayer })
        for line in Self.linesAndShading(of: paper) + paper.boundaryLayers {
            XCTAssertLessThan(grainIndex, try XCTUnwrap(sublayers.firstIndex { $0 === line }))
        }
        XCTAssertEqual(paper.grainLayer.frame, CGRect(x: 0, y: -600, width: 794, height: 3_969))
        XCTAssertFalse(paper.grainLayer.isHidden)
        XCTAssertNil(paper.grainLayer.contents)
        XCTAssertNotNil(paper.grainLayer.backgroundColor?.pattern)

        paper.setGeometry(width: 794, height: 4_492, boundaries: [1_123, 2_246, 3_369])
        XCTAssertEqual(paper.grainLayer.frame, CGRect(x: 0, y: -600, width: 794, height: 5_092))
        XCTAssertTrue(paper.contentLayer.sublayers?.dropFirst().first === paper.grainLayer)
        XCTAssertTrue(paper.grainLayer.animationKeys()?.isEmpty ?? true)
    }

    func testHeadMarginContinuesThePaperAbovePageOne() async throws {
        await ready(.shared)
        let settings = AccessibilitySettings()
        let paper = NotebookPaperView(
            frame: CGRect(x: 0, y: 0, width: 834, height: 700), accessibility: settings.source
        )
        let window = try await hostInWindow(paper)
        defer { window.close() }
        paper.setGeometry(width: 794, height: 2_246, boundaries: [1_123])
        XCTAssertEqual(paper.headMarginLayer.frame, CGRect(x: 0, y: -600, width: 794, height: 600))
        XCTAssertEqual(paper.headMarginLayer.backgroundColor, NotebookTheme.paperIvory.cgColor)
        XCTAssertFalse(paper.headMarginLayer.isHidden)
        XCTAssertEqual(paper.pageTopLayer.position, .zero, "page 1 begins at a divider, like every page")
        XCTAssertEqual(paper.pageTopLayer.backgroundColor, NotebookTheme.paperDivider.cgColor)

        // Width fit with page 1 starting 400 pt down: everything above it is the head margin.
        let scale = paper.traitCollection.displayScale
        paper.setViewport(scale: 834 / 794, offset: CGPoint(x: 0, y: -400))
        paper.finishZoom()
        let margin = 0..<Int((398 * scale).rounded())
        let textured = try render(paper, scale: scale)
        let texturedMargin = textured.region(rows: margin)
        XCTAssertGreaterThan(texturedMargin.luminanceRange, 0.01, "The fibres continue through the head margin.")
        try assertMeanColor(of: texturedMargin, equals: NotebookTheme.paperIvory)

        settings.reducesTransparency = true
        settings.post(UIAccessibility.reduceTransparencyStatusDidChangeNotification)
        let plain = try render(paper, scale: scale).region(rows: margin)
        XCTAssertLessThan(try largestDifference(in: plain, from: NotebookTheme.paperIvory), 0.01, "Plain paper, no stone.")

        // Zoomed far out the head margin spans only 240 pt, and stone shows above it.
        paper.setViewport(scale: 0.4, offset: CGPoint(x: -258.2, y: -300))
        paper.finishZoom()
        let farOut = try render(paper, scale: scale)
        let pageColumns = Int((270 * scale).rounded())..<Int((560 * scale).rounded())
        let stone = farOut.region(rows: 0..<Int((55 * scale).rounded()), columns: pageColumns)
        XCTAssertLessThan(try largestDifference(in: stone, from: NotebookTheme.backdropStone), 0.01)
        let head = farOut.region(rows: Int((65 * scale).rounded())..<Int((295 * scale).rounded()), columns: pageColumns)
        XCTAssertLessThan(try largestDifference(in: head, from: NotebookTheme.paperIvory), 0.01)
    }

    func testThousandViewportUpdatesNeverRedrawOrReplaceTheGrain() async throws {
        let probe = RenderProbe()
        let materials = probe.materials()
        await ready(materials)
        let paper = PaperDrawSpy(frame: .zero, materials: materials, accessibility: AccessibilitySettings().source)
        let fixture = try await presentController(paperView: paper)
        defer { fixture.close() }
        paper.setNeedsDisplay()
        try await waitForRenderedFrames()
        XCTAssertGreaterThan(paper.drawCalls, 0, "The mounted spy must observe an actual display.")
        let drawCallsBefore = paper.drawCalls
        let geometryBefore = paper.geometryUpdates
        let viewportBefore = paper.viewportUpdates
        let grain = paper.grainLayer
        let pattern = try XCTUnwrap(grain.backgroundColor)
        let frame = grain.frame
        for step in 1...1_000 {
            paper.setViewport(scale: 1 + CGFloat(step % 7) * 0.1, offset: CGPoint(x: 0, y: CGFloat(step)))
        }
        try await waitForRenderedFrames()
        XCTAssertEqual(paper.viewportUpdates - viewportBefore, 1_000)
        XCTAssertEqual(paper.drawCalls, drawCallsBefore)
        XCTAssertEqual(paper.geometryUpdates, geometryBefore)
        XCTAssertEqual(probe.renderCount, 1)
        XCTAssertTrue(paper.grainLayer === grain)
        XCTAssertTrue(grain.backgroundColor === pattern)
        XCTAssertNil(grain.contents)
        XCTAssertEqual(grain.frame, frame)
        XCTAssertTrue(grain.animationKeys()?.isEmpty ?? true)
        XCTAssertTrue(paper.contentLayer.animationKeys()?.isEmpty ?? true)
    }

    func testViewportUpdatesNeverMoveOrRedrawThePageEdges() async throws {
        let paper = PaperDrawSpy(frame: .zero, accessibility: AccessibilitySettings().source)
        let fixture = try await presentController(paperView: paper)
        defer { fixture.close() }
        try await waitForRenderedFrames()
        let layers = [paper.headMarginLayer, paper.grainLayer] + Self.linesAndShading(of: paper)
        let frames = layers.map(\.frame)
        let drawCallsBefore = paper.drawCalls
        let thicknessBefore = paper.thicknessUpdates
        for step in 1...1_000 {
            let offset = CGPoint(x: CGFloat(step % 13), y: CGFloat(step))
            paper.setViewport(scale: 0.5 + CGFloat(step % 9) * 0.25, offset: offset)
        }
        try await waitForRenderedFrames()
        XCTAssertEqual(paper.drawCalls, drawCallsBefore)
        XCTAssertEqual(paper.thicknessUpdates, thicknessBefore, "Edge thickness changes only when a zoom ends.")
        XCTAssertEqual(layers.map(\.frame), frames)
        for layer in layers {
            XCTAssertNil(layer.contents)
            XCTAssertTrue(layer.animationKeys()?.isEmpty ?? true)
        }
    }

    func testPageEdgesLieJustOutsideThePaperOneDevicePixelThick() async throws {
        let paper = NotebookPaperView(
            frame: CGRect(x: 0, y: 0, width: 834, height: 600), accessibility: AccessibilitySettings().source
        )
        let window = try await hostInWindow(paper)
        defer { window.close() }
        let width: CGFloat = 794
        for (pages, scale) in [(1, CGFloat(0.4)), (3, 1), (4, 2.5)] {
            let height = 1_123 * CGFloat(pages)
            paper.setGeometry(width: width, height: height, boundaries: (1..<pages).map { 1_123 * CGFloat($0) })
            paper.setViewport(scale: scale, offset: .zero)
            paper.finishZoom()
            let pixel = 1 / paper.traitCollection.displayScale
            let bottom = paper.edgeLayer.frame
            let leading = paper.leadingEdgeLayer.frame
            let trailing = paper.trailingEdgeLayer.frame
            let pageTop = paper.pageTopLayer.frame
            XCTAssertEqual(bottom.minX, 0, accuracy: 0.001)
            XCTAssertEqual(bottom.width, width, accuracy: 0.001)
            XCTAssertEqual(bottom.minY, height, accuracy: 0.001, "The bottom edge sits below the last page.")
            XCTAssertEqual(bottom.height * scale, pixel, accuracy: 0.001)
            XCTAssertEqual(leading.maxX, 0, accuracy: 0.001, "The leading edge sits beside the paper.")
            XCTAssertEqual(trailing.minX, width, accuracy: 0.001, "The trailing edge sits beside the paper.")
            for side in [leading, trailing] {
                XCTAssertEqual(side.width * scale, pixel, accuracy: 0.001)
                XCTAssertEqual(side.minY, -600, accuracy: 0.001, "The sides run up the head margin.")
                XCTAssertEqual(side.maxY, bottom.maxY, accuracy: 0.001, "The sides close the lower corners.")
            }
            XCTAssertEqual(pageTop.midY, 0, accuracy: 0.001)
            XCTAssertEqual(pageTop.width, width, accuracy: 0.001)
            XCTAssertEqual(pageTop.height * scale, pixel, accuracy: 0.001)
            for edge in [paper.edgeLayer, paper.leadingEdgeLayer, paper.trailingEdgeLayer] {
                XCTAssertFalse(edge.isHidden)
                XCTAssertEqual(edge.backgroundColor, NotebookTheme.paperEdge.cgColor)
            }
            XCTAssertEqual(paper.bottomShadowLayer.frame, CGRect(x: 0, y: height, width: width, height: 6))
            XCTAssertEqual(paper.leadingShadowLayer.frame, CGRect(x: -3, y: -600, width: 3, height: height + 600))
            XCTAssertEqual(paper.trailingShadowLayer.frame, CGRect(x: width, y: -600, width: 3, height: height + 600))
            XCTAssertEqual(paper.leadingCornerShadowLayer.frame, CGRect(x: -3, y: height, width: 3, height: 6))
            XCTAssertEqual(paper.trailingCornerShadowLayer.frame, CGRect(x: width, y: height, width: 3, height: 6))
        }
        let tone = try XCTUnwrap(SRGBPixels.components(NotebookTheme.shadowTone.uiColor))
        for (shadow, opacity): (CAGradientLayer, CGFloat) in [
            (paper.bottomShadowLayer, 0.18), (paper.leadingShadowLayer, 0.12), (paper.trailingShadowLayer, 0.12),
            (paper.leadingCornerShadowLayer, 0.15), (paper.trailingCornerShadowLayer, 0.15)
        ] {
            let colors = try XCTUnwrap(shadow.colors as? [CGColor])
            XCTAssertEqual(colors.count, 2)
            XCTAssertEqual(colors.first?.alpha ?? 0, opacity, accuracy: 0.000_1, "darkest against the paper")
            XCTAssertEqual(colors.last?.alpha, 0, "fading out")
            for color in colors {
                let opaque = try XCTUnwrap(color.copy(alpha: 1))
                let components = try XCTUnwrap(SRGBPixels.components(UIColor(cgColor: opaque)))
                XCTAssertEqual(components.red, tone.red, accuracy: 0.001, "a warm fade that never passes through gray")
                XCTAssertEqual(components.blue, tone.blue, accuracy: 0.001)
            }
            XCTAssertFalse(shadow.isHidden)
        }
        XCTAssertEqual(paper.leadingShadowLayer.startPoint.x, 1, "the leading band is darkest at the paper")
        XCTAssertEqual(paper.trailingShadowLayer.startPoint.x, 0, "the trailing band is darkest at the paper")
        XCTAssertEqual(paper.bottomShadowLayer.startPoint.y, 0, "the bottom band is darkest at the paper")
        XCTAssertEqual(paper.leadingCornerShadowLayer.type, .radial)
        XCTAssertEqual(paper.trailingCornerShadowLayer.type, .radial)
    }

    /// The bottom and side bands meet outside each lower corner of the paper. The shading must
    /// turn the corner with no step between neighbouring pixels off the hairlines, and must not
    /// spread past the bands' depths.
    func testShadingTurnsTheLowerCornersWithoutAStep() async throws {
        let settings = AccessibilitySettings()
        // Flat colours, so every step between neighbouring pixels comes from the shading.
        settings.increasesContrast = true
        let paper = NotebookPaperView(
            frame: CGRect(x: 0, y: 0, width: 200, height: 200), accessibility: settings.source
        )
        let window = try await hostInWindow(paper)
        defer { window.close() }
        paper.setGeometry(width: 794, height: 1_123, boundaries: [])
        let zoom: CGFloat = 4
        let scale = paper.traitCollection.displayScale
        let perPoint = Int((zoom * scale).rounded())
        let stone = try XCTUnwrap(SRGBPixels.components(NotebookTheme.backdropStone.uiColor))
        for (name, cornerX, outward) in [("leading", CGFloat(0), -1), ("trailing", CGFloat(794), 1)] {
            // The page corner lands in the middle of the view, on a device pixel boundary.
            paper.setViewport(scale: zoom, offset: CGPoint(x: cornerX * zoom - 100, y: 1_123 * zoom - 100))
            paper.finishZoom()
            let pixels = try render(paper, scale: scale)
            let corner = Int((100 * scale).rounded())
            // The side hairline is the pixel column just outside the page and ends on the bottom
            // hairline, the pixel row just below it.
            let sideColumn = outward < 0 ? corner - 1 : corner
            func isHairline(_ x: Int, _ y: Int) -> Bool {
                (x == sideColumn && y <= corner) || (y == corner && (outward < 0 ? x > sideColumn : x < sideColumn))
            }
            var largestStep = 0.0
            for y in (corner - perPoint)..<(corner + 8 * perPoint) {
                for x in (corner - 4 * perPoint)..<(corner + 4 * perPoint) where !isHairline(x, y) {
                    for (nextX, nextY) in [(x + 1, y), (x, y + 1)] where !isHairline(nextX, nextY) {
                        let first = pixels.color(x: x, y: y), second = pixels.color(x: nextX, y: nextY)
                        largestStep = max(
                            largestStep, abs(first.red - second.red), abs(first.green - second.green),
                            abs(first.blue - second.blue)
                        )
                    }
                }
            }
            XCTAssertLessThan(largestStep, 0.03, "the shading turns the \(name) corner without a step")
            let nearCorner = pixels.color(x: sideColumn + outward, y: corner + 1)
            XCTAssertGreaterThan(stone.red - nearCorner.red, 0.05, "the \(name) corner is shaded")
            try assertColor(
                pixels.color(x: sideColumn + outward * (3 * perPoint + 2), y: corner + 3 * perPoint),
                equals: NotebookTheme.backdropStone, "beside the \(name) corner, past the side band"
            )
            try assertColor(
                pixels.color(x: sideColumn + outward * perPoint, y: corner + 6 * perPoint + 2),
                equals: NotebookTheme.backdropStone, "below the \(name) corner, past the bottom band"
            )
        }
    }

    func testWidthFittedPageDrawsNoEdgeAlongTheScreenBorder() async throws {
        let settings = AccessibilitySettings()
        // Flat colours, so a single edge pixel in a border column stands out.
        settings.increasesContrast = true
        for viewWidth: CGFloat in [744, 834, 1_032, 1_376] {
            let paper = NotebookPaperView(
                frame: CGRect(x: 0, y: 0, width: viewWidth, height: 300), accessibility: settings.source
            )
            let window = try await hostInWindow(paper)
            defer { window.close() }
            paper.setGeometry(width: 794, height: 1_123, boundaries: [])
            paper.setViewport(scale: viewWidth / 794, offset: CGPoint(x: 0, y: 200))
            paper.finishZoom()
            let pixels = try render(paper, scale: paper.traitCollection.displayScale)
            for x in [0, 1, pixels.width - 2, pixels.width - 1] {
                let column = SRGBPixels.mean(of: (0..<pixels.height).map { pixels.color(x: x, y: $0) })
                try assertColor(column, equals: NotebookTheme.paperIvory, "column \(x) at width \(viewWidth)")
            }
        }
    }

    func testZoomedOutPaperSitsOnStoneWithEdgesAndShading() async throws {
        let settings = AccessibilitySettings()
        settings.increasesContrast = true
        let paper = NotebookPaperView(
            frame: CGRect(x: 0, y: 0, width: 834, height: 800), accessibility: settings.source
        )
        let window = try await hostInWindow(paper)
        defer { window.close() }
        // Half scale puts the paper edges on whole device pixels: 397 pt wide, 218.5 pt from
        // either side, page 1 from 100 to 661.5 pt down.
        paper.setGeometry(width: 794, height: 1_123, boundaries: [])
        paper.setViewport(scale: 0.5, offset: CGPoint(x: -218.5, y: -100))
        paper.finishZoom()
        let scale = paper.traitCollection.displayScale
        let pixels = try render(paper, scale: scale)
        func pixel(_ point: CGFloat) -> Int { Int((point * scale).rounded()) }
        let rows = pixel(200)..<pixel(400)
        let columns = pixel(300)..<pixel(500)
        func column(_ x: Int) -> SRGBPixels.Color { SRGBPixels.mean(of: rows.map { pixels.color(x: x, y: $0) }) }
        func row(_ y: Int) -> SRGBPixels.Color { SRGBPixels.mean(of: columns.map { pixels.color(x: $0, y: y) }) }

        try assertColor(column(pixel(100)), equals: NotebookTheme.backdropStone, "beside the paper")
        try assertColor(column(pixel(218.5)), equals: NotebookTheme.paperIvory, "inside the leading edge")
        try assertColor(column(pixel(615.5) - 1), equals: NotebookTheme.paperIvory, "inside the trailing edge")
        try assertColor(row(pixel(98)), equals: NotebookTheme.paperIvory, "the head margin above page 1")
        try assertColor(row(pixel(20)), equals: NotebookTheme.paperIvory, "the head margin reaches the top")
        try assertColor(row(pixel(661.5) - 1), equals: NotebookTheme.paperIvory, "inside the bottom edge")
        try assertColor(row(pixel(661.5) + 7), equals: NotebookTheme.backdropStone, "below the shading")

        let stone = try XCTUnwrap(SRGBPixels.components(NotebookTheme.backdropStone.uiColor))
        let ivory = try XCTUnwrap(SRGBPixels.components(NotebookTheme.paperIvory.uiColor))
        for (name, edge, shade) in [
            ("leading", column(pixel(218.5) - 1), column(pixel(218.5) - 2)),
            ("trailing", column(pixel(615.5)), column(pixel(615.5) + 1)),
            ("bottom", row(pixel(661.5)), row(pixel(661.5) + 1))
        ] {
            let contrast = SRGBPixels.contrastRatio(edge, stone)
            XCTAssertGreaterThan(contrast, 1.8, "the \(name) edge shows against the stone")
            XCTAssertLessThan(contrast, 2.6, "the \(name) edge stays a hairline")
            let edgeLuminance = SRGBPixels.relativeLuminance(edge)
            let shadeLuminance = SRGBPixels.relativeLuminance(shade)
            XCTAssertLessThan(shadeLuminance, SRGBPixels.relativeLuminance(stone) - 0.01, "the \(name) shading shows")
            XCTAssertGreaterThan(shadeLuminance, edgeLuminance, "the \(name) shading stays softer than the edge")
        }
        let pageTop = SRGBPixels.mean(of: [row(pixel(100) - 1), row(pixel(100))])
        let dividerContrast = SRGBPixels.contrastRatio(pageTop, ivory)
        XCTAssertGreaterThan(dividerContrast, 1.03, "a divider marks the top of page 1")
        XCTAssertLessThan(dividerContrast, SRGBPixels.contrastRatio(row(pixel(661.5)), ivory), "fainter than the edge")
    }

    /// The paper must never show a band of stone above page 1. Drives the real controller at
    /// width fit with the top space a header and docked toolbar reserve, through each way the
    /// page comes to rest at its revealed top: scrolling there, pulling past it, and rotating.
    /// Each state is checked with the textured and with the plain materials.
    func testRealControllerShowsOnlyPaperAbovePageOneAtItsRevealedTop() async throws {
        await ready(.shared)
        let settings = AccessibilitySettings()
        let store = NotebookTestFixtures.toolStore()
        let fixture = try await presentController(
            paperView: NotebookPaperView(frame: .zero, accessibility: settings.source), toolStore: store,
            size: CGSize(width: 834, height: 1_194)
        )
        defer { fixture.close() }
        let controller = fixture.controller
        let canvas = controller.canvasView
        store.setOverlayObstruction(UIEdgeInsets(top: 205, left: 0, bottom: 34, right: 0))
        XCTAssertEqual(canvas.contentInset.top, 205)

        canvas.setContentOffset(CGPoint(x: -canvas.contentInset.left, y: -canvas.contentInset.top), animated: false)
        try await assertOnlyPaperAbovePageOne(in: controller, settings: settings, "at the revealed top")
        canvas.setContentOffset(CGPoint(x: -canvas.contentInset.left, y: -canvas.contentInset.top - 150), animated: false)
        try await assertOnlyPaperAbovePageOne(in: controller, settings: settings, "pulled past the revealed top")

        canvas.setContentOffset(CGPoint(x: -canvas.contentInset.left, y: -canvas.contentInset.top), animated: false)
        fixture.window.frame = CGRect(x: 0, y: 0, width: 1_194, height: 834)
        controller.view.frame = fixture.window.bounds
        controller.view.layoutIfNeeded()
        XCTAssertEqual(canvas.contentOffset.y, -canvas.contentInset.top, accuracy: 0.5, "the page still rests at its top")
        try await assertOnlyPaperAbovePageOne(in: controller, settings: settings, "after rotating")
    }

    func testGrainHidesWhileReduceTransparencyOrIncreaseContrastIsOn() {
        let settings = AccessibilitySettings()
        let paper = NotebookPaperView(frame: .zero, accessibility: settings.source)
        paper.setGeometry(width: 794, height: 1_123, boundaries: [])
        XCTAssertFalse(paper.grainLayer.isHidden)

        settings.reducesTransparency = true
        settings.post(UIAccessibility.reduceTransparencyStatusDidChangeNotification)
        XCTAssertTrue(paper.grainLayer.isHidden)
        settings.reducesTransparency = false
        settings.post(UIAccessibility.reduceTransparencyStatusDidChangeNotification)
        XCTAssertFalse(paper.grainLayer.isHidden)

        settings.increasesContrast = true
        settings.post(UIAccessibility.darkerSystemColorsStatusDidChangeNotification)
        XCTAssertTrue(paper.grainLayer.isHidden)
        settings.increasesContrast = false
        settings.post(UIAccessibility.darkerSystemColorsStatusDidChangeNotification)
        XCTAssertFalse(paper.grainLayer.isHidden)
        XCTAssertTrue(paper.grainLayer.animationKeys()?.isEmpty ?? true)
    }

    func testGrainStartsHiddenWhenASettingIsAlreadyOn() {
        let settings = AccessibilitySettings()
        settings.increasesContrast = true
        let paper = NotebookPaperView(frame: .zero, accessibility: settings.source)
        paper.setGeometry(width: 794, height: 1_123, boundaries: [])
        XCTAssertTrue(paper.grainLayer.isHidden)
        XCTAssertEqual(paper.grainLayer.frame.height, 1_723)
    }

    func testMaterialsLeaveTheDrawingArchiveByteIdentical() async throws {
        var drawing = PKDrawing()
        drawing.strokes = [NotebookTestFixtures.stroke(x: 20), NotebookTestFixtures.stroke(x: 300)]
        let expected = drawing.dataRepresentation()

        let settings = AccessibilitySettings()
        let textured = try await presentController(
            drawing: drawing, paperView: NotebookPaperView(frame: .zero, accessibility: settings.source)
        )
        defer { textured.close() }
        XCTAssertEqual(textured.controller.canvasView.drawing.dataRepresentation(), expected)
        let paper = textured.controller.paperView
        textured.controller.setPageCount(4)
        for step in 0..<50 {
            paper.setViewport(scale: 0.5 + CGFloat(step) * 0.05, offset: CGPoint(x: 0, y: CGFloat(step * 40)))
        }
        settings.reducesTransparency = true
        settings.post(UIAccessibility.reduceTransparencyStatusDidChangeNotification)
        settings.reducesTransparency = false
        settings.post(UIAccessibility.reduceTransparencyStatusDidChangeNotification)
        try await waitForRenderedFrames()
        XCTAssertEqual(textured.controller.canvasView.drawing.dataRepresentation(), expected)

        let plainSettings = AccessibilitySettings()
        plainSettings.reducesTransparency = true
        let plain = try await presentController(
            drawing: drawing, paperView: NotebookPaperView(frame: .zero, accessibility: plainSettings.source)
        )
        defer { plain.close() }
        XCTAssertTrue(plain.controller.paperView.grainLayer.isHidden)
        XCTAssertEqual(plain.controller.canvasView.drawing.dataRepresentation(), expected)
    }

    func testThinInkKeepsMostOfItsContrastOnTheDarkestFibre() async throws {
        let pixels = try SRGBPixels(await Self.renderedFibreTile())
        let paper = try XCTUnwrap(SRGBPixels.components(NotebookPaperView.paperColor))
        let darkest = try XCTUnwrap(pixels.colors.min { SRGBPixels.relativeLuminance($0) < SRGBPixels.relativeLuminance($1) })
        for ink in Self.catalogInks {
            let inkColor = SRGBPixels.Color(red: ink.red, green: ink.green, blue: ink.blue)
            let onPaper = SRGBPixels.contrastRatio(inkColor, paper)
            let onFibre = SRGBPixels.contrastRatio(inkColor, darkest)
            XCTAssertGreaterThanOrEqual(onFibre, onPaper * 0.9, "\(ink) loses too much contrast on the fibres")
        }
    }

    func testFibresRepeatOnlyOncePerTile() async throws {
        let pixels = try SRGBPixels(await Self.renderedFibreTile())
        let half = pixels.width / 2
        let unrelatedX = pixels.meanDifference(shiftedBy: 97, 0)
        let unrelatedY = pixels.meanDifference(shiftedBy: 0, 97)
        XCTAssertGreaterThan(unrelatedX, 0)
        XCTAssertGreaterThanOrEqual(pixels.meanDifference(shiftedBy: half, 0), unrelatedX * 0.75)
        XCTAssertGreaterThanOrEqual(pixels.meanDifference(shiftedBy: 0, half), unrelatedY * 0.75)
        XCTAssertGreaterThanOrEqual(pixels.meanDifference(shiftedBy: half, half), unrelatedX * 0.75)
    }

    func testGrainStaysAnchoredToTheDocumentWhenThePaperGrows() async throws {
        await ready(.shared)
        let paper = NotebookPaperView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300), accessibility: AccessibilitySettings().source
        )
        let window = try await hostInWindow(paper)
        defer { window.close() }
        paper.setGeometry(width: 794, height: 1_123, boundaries: [])
        paper.setViewport(scale: 1, offset: CGPoint(x: 40, y: 20))
        try await waitForRenderedFrames()
        let before = try render(paper, scale: 2)
        // Not a multiple of the tile, so a pattern anchored anywhere but the top would shift.
        paper.setGeometry(width: 794, height: 2_283, boundaries: [1_123])
        try await waitForRenderedFrames()
        let after = try render(paper, scale: 2)
        XCTAssertGreaterThan(before.luminanceRange, 0.01, "The rendered page must show fibres.")
        XCTAssertLessThan(before.meanDifference(to: after), 0.001)
    }

    func testSpaceBeyondThePaperEndIsPlainStone() async throws {
        await ready(.shared)
        let size = CGSize(width: 300, height: 500)
        let paper = NotebookPaperView(frame: CGRect(origin: .zero, size: size), accessibility: AccessibilitySettings().source)
        paper.setGeometry(width: 794, height: 1_123, boundaries: [])
        // 10 pt past the end of the paper, clear of its shading.
        paper.setViewport(scale: 1, offset: CGPoint(x: 0, y: 1_133))
        let pixels = try render(paper, scale: 2)
        XCTAssertLessThan(pixels.luminanceRange, 0.001, "No fibres past the paper, so it never reads as writable.")
        try assertMeanColor(of: pixels, equals: NotebookTheme.backdropStone)
    }

    func testBackdropStaysPlainStoneWhateverTheMaterialsAndSettings() async throws {
        let materials = NotebookMaterials()
        let settings = AccessibilitySettings()
        let paper = NotebookPaperView(frame: .zero, materials: materials, accessibility: settings.source)
        paper.setGeometry(width: 794, height: 1_123, boundaries: [])
        XCTAssertEqual(paper.backgroundColor, NotebookTheme.backdropStone.uiColor)
        XCTAssertTrue(paper.layer.sublayers?.first === paper.contentLayer, "nothing but the paper lies on the stone")

        await ready(materials)
        XCTAssertEqual(paper.backgroundColor, NotebookTheme.backdropStone.uiColor)
        XCTAssertFalse(paper.grainLayer.isHidden)
        settings.increasesContrast = true
        settings.post(UIAccessibility.darkerSystemColorsStatusDidChangeNotification)
        XCTAssertEqual(paper.backgroundColor, NotebookTheme.backdropStone.uiColor)
        XCTAssertTrue(paper.grainLayer.isHidden)
        settings.increasesContrast = false
        settings.reducesTransparency = true
        settings.post(UIAccessibility.reduceTransparencyStatusDidChangeNotification)
        XCTAssertEqual(paper.backgroundColor, NotebookTheme.backdropStone.uiColor, "plain materials keep the page apart")
        XCTAssertTrue(paper.grainLayer.isHidden)
        XCTAssertEqual(paper.headMarginLayer.backgroundColor, NotebookTheme.paperIvory.cgColor)
        XCTAssertFalse(paper.headMarginLayer.isHidden)
        XCTAssertEqual(paper.layer.sublayers?.count, 1)
    }

    func testBackdropIsAStepDarkerAndGreyerThanThePaper() throws {
        let paper = try XCTUnwrap(SRGBPixels.components(NotebookTheme.paperIvory.uiColor))
        let stone = try XCTUnwrap(SRGBPixels.components(NotebookTheme.backdropStone.uiColor))
        let contrast = SRGBPixels.contrastRatio(paper, stone)
        XCTAssertGreaterThan(contrast, 1.4, "The page must stand apart from the backdrop.")
        XCTAssertLessThan(contrast, 1.6, "The backdrop stays a quiet step below the paper.")
        func chroma(_ color: SRGBPixels.Color) -> Double {
            max(color.red, color.green, color.blue) - min(color.red, color.green, color.blue)
        }
        XCTAssertLessThan(chroma(stone), chroma(paper), "The stone is greyer than the ivory.")
        XCTAssertGreaterThan(stone.red, stone.blue, "The stone stays warm.")
    }

    func testPaperDrawsWithThemeTones() {
        let paper = NotebookPaperView(frame: .zero, accessibility: AccessibilitySettings().source)
        paper.setGeometry(width: 794, height: 2_246, boundaries: [1_123])
        XCTAssertEqual(paper.contentLayer.backgroundColor, NotebookTheme.paperIvory.cgColor, "the page itself stays ivory")
        XCTAssertEqual(paper.headMarginLayer.backgroundColor, NotebookTheme.paperIvory.cgColor)
        XCTAssertEqual(paper.backgroundColor, NotebookTheme.backdropStone.uiColor)
        XCTAssertTrue(NotebookPaperView.backdropColor === NotebookTheme.backdropStone.uiColor)
        let traits = paper.traitCollection
        XCTAssertEqual(paper.edgeLayer.backgroundColor, NotebookTheme.paperEdge.cgColor(for: traits))
        XCTAssertEqual(paper.leadingEdgeLayer.backgroundColor, NotebookTheme.paperEdge.cgColor(for: traits))
        XCTAssertEqual(paper.pageTopLayer.backgroundColor, NotebookTheme.paperDivider.cgColor(for: traits))
        XCTAssertEqual(paper.boundaryLayers.first?.backgroundColor, NotebookTheme.paperDivider.cgColor(for: traits))
    }

    /// Under Increase Contrast the page edges become solid one-point charcoal lines and the
    /// dividers darken, and both follow the setting while the paper is shown.
    func testPageEdgesTurnSolidCharcoalUnderIncreaseContrastAndFollowALiveChange() async throws {
        let paper = NotebookPaperView(
            frame: CGRect(x: 0, y: 0, width: 600, height: 800), accessibility: AccessibilitySettings().source
        )
        paper.setGeometry(width: 794, height: 2_246, boundaries: [1_123])
        paper.setViewport(scale: 0.5, offset: CGPoint(x: -100, y: -50))
        paper.finishZoom()
        let host = try await hostInWindow(paper)
        defer { host.close() }
        let pixel = 1 / (paper.traitCollection.displayScale * 0.5)
        let standardEdge: [CGFloat] = [0.47, 0.40, 0.31, 0.65]
        let charcoal: [CGFloat] = [0.17, 0.16, 0.15, 1]
        assertLines(of: paper, edge: standardEdge, dividerAlpha: 0.30, edgeThickness: pixel, "standard contrast")

        paper.traitOverrides.accessibilityContrast = .high
        try await NotebookTestFixtures.waitUntil {
            paper.layoutIfNeeded()
            return paper.traitCollection.accessibilityContrast == .high
        }
        assertLines(of: paper, edge: charcoal, dividerAlpha: 0.55, edgeThickness: 2, "increased contrast")
        XCTAssertEqual(paper.pageTopLayer.bounds.height, pixel, accuracy: 0.000_1, "dividers stay one device pixel")
        paper.setGeometry(width: 794, height: 3_369, boundaries: [1_123, 2_246])
        assertComponents(
            of: try XCTUnwrap(paper.boundaryLayers.last?.backgroundColor), equal: [0.47, 0.40, 0.31, 0.55],
            "a divider added later takes the increased tone"
        )

        paper.traitOverrides.accessibilityContrast = .normal
        try await NotebookTestFixtures.waitUntil {
            paper.layoutIfNeeded()
            return paper.traitCollection.accessibilityContrast == .normal
        }
        assertLines(of: paper, edge: standardEdge, dividerAlpha: 0.30, edgeThickness: pixel, "contrast restored")
    }

    /// The status veil lies between the canvas and the chrome, covers the top safe area plus
    /// its fade with paper, and replaces the system's scroll edge effects.
    func testStatusVeilCoversTheStatusBarWithPaperOnlyOverThePage() async throws {
        let settings = AccessibilitySettings()
        let fixture = try await presentController(
            paperView: NotebookPaperView(frame: .zero, accessibility: settings.source),
            size: CGSize(width: 834, height: 1_194)
        )
        defer { fixture.close() }
        let controller = fixture.controller
        // A known top safe area, whatever the window's own.
        controller.additionalSafeAreaInsets = UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0)
        controller.view.layoutIfNeeded()
        let canvas = controller.canvasView
        let veil = controller.statusVeil
        let safeTop = controller.view.safeAreaInsets.top
        XCTAssertGreaterThanOrEqual(safeTop, 20)
        XCTAssertTrue(canvas.topEdgeEffect.isHidden, "The system's top edge effect would tint the paper.")
        XCTAssertTrue(canvas.bottomEdgeEffect.isHidden)
        let subviews = controller.view.subviews
        XCTAssertGreaterThan(
            try XCTUnwrap(subviews.firstIndex(of: veil)), try XCTUnwrap(subviews.firstIndex(of: canvas))
        )
        XCTAssertFalse(veil.isUserInteractionEnabled)

        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: 300), animated: false)
        XCTAssertFalse(veil.isHidden)
        let fade = NotebookTheme.statusVeilFade
        XCTAssertEqual(fade, 10)
        XCTAssertEqual(veil.frame, CGRect(x: 0, y: 0, width: 834, height: safeTop + fade))
        let locations = try XCTUnwrap(veil.gradientLayer.locations).map(\.doubleValue)
        XCTAssertEqual(locations[0], 0)
        XCTAssertEqual(locations[1], Double(safeTop / (safeTop + fade)), accuracy: 0.000_1)
        XCTAssertEqual(locations[2], 1)
        let colors = try veilColors(veil)
        for (color, alpha) in zip(colors, [0.94, 0.94, 0]) {
            assertComponents(of: color, equal: [0.98, 0.96, 0.91, CGFloat(alpha)], "paper veil")
        }
        let underVeil = NotebookTestFixtures.hit(CGPoint(x: 400, y: safeTop / 2), in: controller.view)
        XCTAssertTrue(underVeil.isDescendant(of: canvas), "Touches pass through the veil.")

        canvas.setZoomScale(canvas.minimumZoomScale, animated: false)
        XCTAssertLessThan(canvas.zoomScale, 834 / 794)
        XCTAssertTrue(veil.isHidden, "Below width fit the veil would lie over stone.")
        canvas.setZoomScale(834 / 794, animated: false)
        XCTAssertFalse(veil.isHidden)

        settings.reducesTransparency = true
        settings.post(UIAccessibility.reduceTransparencyStatusDidChangeNotification)
        XCTAssertTrue(veil.isOpaqueBand)
        XCTAssertEqual(veil.frame, CGRect(x: 0, y: 0, width: 834, height: safeTop), "An opaque band without a fade.")
        for color in try veilColors(veil) {
            assertComponents(of: color, equal: [0.98, 0.96, 0.91, 1], "opaque paper band")
        }
        settings.reducesTransparency = false
        settings.post(UIAccessibility.reduceTransparencyStatusDidChangeNotification)
        XCTAssertFalse(veil.isOpaqueBand)
        XCTAssertEqual(veil.frame.height, safeTop + fade)

        // A safe-area change alone, as when a navigation bar shows or hides, resizes the veil
        // in the layout pass that follows, without any scroll.
        let offset = canvas.contentOffset
        for extra: CGFloat in [74, 0] {
            controller.additionalSafeAreaInsets = UIEdgeInsets(top: extra, left: 0, bottom: 0, right: 0)
            controller.view.layoutIfNeeded()
            let top = controller.view.safeAreaInsets.top
            XCTAssertEqual(top, safeTop - 20 + extra, accuracy: 0.5)
            XCTAssertEqual(veil.frame, CGRect(x: 0, y: 0, width: 834, height: top + fade), "extra safe area \(extra)")
            let locations = try XCTUnwrap(veil.gradientLayer.locations).map(\.doubleValue)
            XCTAssertEqual(locations[1], Double(top / (top + fade)), accuracy: 0.000_1)
        }
        XCTAssertEqual(canvas.contentOffset, offset, "The veil never moves the page.")
    }

    /// A veil created while Reduce Transparency is already on starts as the opaque band.
    func testStatusVeilStartsAsAnOpaqueBandWhenReduceTransparencyIsAlreadyOn() async throws {
        let settings = AccessibilitySettings()
        settings.reducesTransparency = true
        let fixture = try await presentController(
            paperView: NotebookPaperView(frame: .zero, accessibility: settings.source),
            size: CGSize(width: 834, height: 1_194)
        )
        defer { fixture.close() }
        let controller = fixture.controller
        controller.additionalSafeAreaInsets = UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0)
        controller.view.layoutIfNeeded()
        let veil = controller.statusVeil
        let safeTop = controller.view.safeAreaInsets.top
        XCTAssertTrue(veil.isOpaqueBand)
        XCTAssertFalse(veil.isHidden)
        XCTAssertEqual(veil.frame, CGRect(x: 0, y: 0, width: 834, height: safeTop), "An opaque band without a fade.")
        for color in try veilColors(veil) {
            assertComponents(of: color, equal: [0.98, 0.96, 0.91, 1], "opaque paper band")
        }
    }

    /// The veil and the tab follow the paper directly, even when a scroll lands inside an
    /// animation block such as a rotation's.
    func testVeilAndEndOfPaperTabNeverAnimate() async throws {
        let fixture = try await presentController(
            paperView: NotebookPaperView(frame: .zero, accessibility: AccessibilitySettings().source),
            size: CGSize(width: 834, height: 1_194)
        )
        defer { fixture.close() }
        let controller = fixture.controller
        controller.onAddPage = {}
        let canvas = controller.canvasView
        UIView.animate(withDuration: 1) {
            canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: Self.endOffset(of: canvas)), animated: false)
            canvas.setZoomScale(canvas.minimumZoomScale, animated: false)
            controller.view.layoutIfNeeded()
        }
        let tab = controller.endOfPaperTab
        XCTAssertFalse(tab.isHidden)
        for layer in [tab.layer, controller.statusVeil.layer] {
            XCTAssertTrue(layer.animationKeys()?.isEmpty ?? true, "\(layer)")
        }
    }

    /// The tab sits centred on the page with its top 20 points below the last page, wherever the
    /// page is scrolled or zoomed, and the canvas keeps room for it above the home indicator.
    func testEndOfPaperTabFollowsTheLastPageAndHasRoomAboveTheHomeIndicator() async throws {
        let store = NotebookTestFixtures.toolStore()
        let fixture = try await presentController(
            paperView: NotebookPaperView(frame: .zero, accessibility: AccessibilitySettings().source),
            toolStore: store, size: CGSize(width: 834, height: 1_194)
        )
        defer { fixture.close() }
        let controller = fixture.controller
        let canvas = controller.canvasView
        let tab = controller.endOfPaperTab
        XCTAssertTrue(tab.isHidden, "A canvas that cannot add pages shows no tab.")
        XCTAssertEqual(canvas.contentInset.bottom, 0)

        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: 250), animated: false)
        let offset = canvas.contentOffset
        var added = 0
        controller.onAddPage = { added += 1 }
        let safeBottom = controller.view.safeAreaInsets.bottom
        XCTAssertEqual(NotebookTheme.endScrollMinimum, 104)
        XCTAssertEqual(canvas.contentInset.bottom, safeBottom + 104, accuracy: 0.5)
        XCTAssertEqual(canvas.contentOffset, offset, "Room below the last page never moves the page.")
        XCTAssertTrue(tab.isHidden, "The tab waits below the visible area.")

        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: Self.endOffset(of: canvas)), animated: false)
        try assertTab(of: controller, followsTheLastPage: "at the end of the paper")
        XCTAssertLessThanOrEqual(
            tab.frame.maxY, canvas.bounds.height - safeBottom, "The tab clears the home indicator."
        )
        XCTAssertEqual(tab.frame.height, NotebookTheme.endTabHeight)
        XCTAssertEqual(tab.titleLabel.text, "Add page")
        XCTAssertFalse(tab.iconView.isHidden)
        XCTAssertNotNil(UIImage(systemName: NotebookEndOfPaperTab.symbolName))
        XCTAssertEqual(tab.accessibilityLabel, "Add page")
        XCTAssertEqual(tab.accessibilityHint, "Adds a page at the end of the notebook.")
        XCTAssertEqual(tab.accessibilityTraits, .button)
        XCTAssertEqual(tab.layer.shadowOpacity, Float(NotebookTheme.shellShadow.opacity))
        XCTAssertNotNil(tab.layer.shadowPath, "A fixed shadow path keeps moves from re-rendering the blur.")
        let hit = NotebookTestFixtures.hit(CGPoint(x: tab.frame.midX, y: tab.frame.midY), in: controller.view)
        XCTAssertTrue(hit === tab, "\(hit)")
        tab.sendActions(for: .touchUpInside)
        XCTAssertEqual(added, 1)

        canvas.setZoomScale(canvas.minimumZoomScale, animated: false)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: Self.endOffset(of: canvas)), animated: false)
        try assertTab(of: controller, followsTheLastPage: "zoomed out")

        // A toolbar floating at the bottom stacks its own room on top of the tab's.
        store.setOverlayObstruction(UIEdgeInsets(top: 0, left: 0, bottom: 140, right: 0))
        XCTAssertEqual(canvas.contentInset.bottom, safeBottom + 104 + 140, accuracy: 0.5)
        store.setOverlayObstruction(.zero)

        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: -canvas.contentInset.top), animated: false)
        XCTAssertTrue(tab.isHidden, "Hidden while below the visible area.")
    }

    func testEndOfPaperTabReadsPaperLimitReachedAtTwelvePages() async throws {
        let fixture = try await presentController(
            pageCount: 11, paperView: NotebookPaperView(frame: .zero, accessibility: AccessibilitySettings().source),
            size: CGSize(width: 834, height: 1_194)
        )
        defer { fixture.close() }
        let controller = fixture.controller
        var added = 0
        controller.onAddPage = { added += 1 }
        let canvas = controller.canvasView
        let tab = controller.endOfPaperTab
        XCTAssertEqual(tab.mode, .available)
        let availableWidth = tab.bounds.width

        controller.setPageCount(NotebookViewController.maximumPageCount)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: Self.endOffset(of: canvas)), animated: false)
        XCTAssertEqual(tab.mode, .limitReached)
        XCTAssertEqual(tab.titleLabel.text, "Paper limit reached")
        XCTAssertTrue(tab.iconView.isHidden, "Nothing can be added, so the plus badge goes.")
        XCTAssertGreaterThan(tab.bounds.width, availableWidth)
        XCTAssertFalse(tab.isEnabled)
        XCTAssertEqual(tab.accessibilityLabel, "Paper limit reached")
        XCTAssertNil(tab.accessibilityHint)
        XCTAssertTrue(tab.accessibilityTraits.contains(.notEnabled))
        XCTAssertEqual(tab.layer.shadowOpacity, 0, "At the limit the tab lies flat without a shadow.")
        try assertTab(of: controller, followsTheLastPage: "twelve pages")
        tab.sendActions(for: .touchUpInside)
        XCTAssertEqual(added, 0)
    }

    func testEndOfPaperTabShowsDisabledWhileTheGateBlocksWriting() async throws {
        let fixture = try await presentController(
            paperView: NotebookPaperView(frame: .zero, accessibility: AccessibilitySettings().source),
            size: CGSize(width: 834, height: 1_194)
        )
        defer { fixture.close() }
        let controller = fixture.controller
        var added = 0
        controller.onAddPage = { added += 1 }
        let canvas = controller.canvasView
        let tab = controller.endOfPaperTab
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: Self.endOffset(of: canvas)), animated: false)
        let bottom = canvas.contentInset.bottom

        for gate in [NotebookInputGate.capacity, .failed, .recovering, .readOnly] {
            controller.setInputGate(gate)
            XCTAssertEqual(tab.mode, .paused, "\(gate)")
            XCTAssertFalse(tab.isHidden, "\(gate): shown disabled rather than hidden")
            XCTAssertFalse(tab.isEnabled, "\(gate)")
            XCTAssertEqual(tab.titleLabel.text, "Add page", "\(gate)")
            XCTAssertTrue(tab.accessibilityTraits.contains(.notEnabled), "\(gate)")
            XCTAssertEqual(canvas.contentInset.bottom, bottom, "\(gate): the room stays")
            tab.sendActions(for: .touchUpInside)
            XCTAssertEqual(added, 0, "\(gate)")
            controller.setInputGate(.open)
            XCTAssertEqual(tab.mode, .available, "\(gate)")
            XCTAssertTrue(tab.isEnabled)
        }
        tab.sendActions(for: .touchUpInside)
        XCTAssertEqual(added, 1)
    }

    /// While writing is paused the tab keeps its shell and shadow and dims its content as the
    /// paused rail does: to 0.55, or 0.70 under Increase Contrast.
    func testPausedEndOfPaperTabKeepsItsShellAndDimsItsContent() async throws {
        let fixture = try await presentTabAtTheEnd()
        defer { fixture.close() }
        let controller = fixture.controller
        let tab = controller.endOfPaperTab
        let title = tab.titleLabel.convert(tab.titleLabel.bounds, to: tab)
        let face = CGPoint(x: 8, y: tab.bounds.midY)
        let below = CGPoint(x: tab.bounds.midX, y: tab.bounds.maxY + 2)
        let beyond = CGPoint(x: tab.bounds.midX, y: tab.bounds.maxY + 22)
        let glyph = try XCTUnwrap(SRGBPixels.components(NotebookTheme.glyph.uiColor))
        let shell = try Self.mix(NotebookTheme.panelTop, NotebookTheme.panelBottom, 0.5)
        let surface = try XCTUnwrap(SRGBPixels.components(NotebookTheme.panelSurface.uiColor))

        let available = try renderTab(of: controller, margin: 24)
        let availableInk = available.darkestPoint(in: title)
        assertColor(available.color(at: availableInk), matches: glyph, "available: the title in the glyph tone")
        controller.setInputGate(.failed)
        XCTAssertEqual(tab.mode, .paused)
        for contrast in [UIAccessibilityContrast.normal, .high] {
            controller.traitOverrides.accessibilityContrast = contrast
            try await NotebookTestFixtures.waitUntil {
                controller.updateTraitsIfNeeded()
                controller.view.layoutIfNeeded()
                return tab.traitCollection.accessibilityContrast == contrast
            }
            let increased = contrast == .high
            let name = increased ? "paused, increased contrast" : "paused"
            let opacity = increased ? NotebookTheme.disabledOpacityIncreased : NotebookTheme.disabledOpacity
            let paused = try renderTab(of: controller, margin: 24)
            assertColor(paused.color(at: face), matches: increased ? surface : shell, "\(name): the shell stays")
            // The face beside the title's darkest pixel, on the same row of the gradient.
            let ink = paused.darkestPoint(in: title)
            let background = paused.color(at: CGPoint(x: face.x, y: ink.y))
            assertColor(
                paused.color(at: ink), matches: Self.blend(glyph, opacity, over: background), "\(name): the title dims"
            )
            XCTAssertEqual(tab.layer.shadowOpacity, Float(NotebookTheme.shellShadow.opacity), name)
            XCTAssertLessThan(
                SRGBPixels.relativeLuminance(paused.color(at: below)),
                SRGBPixels.relativeLuminance(paused.color(at: beyond)) - 0.005, "\(name): the shadow stays"
            )
        }
    }

    /// The room below the last page follows the home indicator, but never shrinks while a
    /// stroke is in progress, so the page stays under the pen.
    func testEndOfPaperRoomFollowsTheSafeAreaAndHoldsDuringAStroke() async throws {
        let fixture = try await presentTabAtTheEnd()
        defer { fixture.close() }
        let controller = fixture.controller
        let canvas = controller.canvasView
        let room = canvas.contentInset.bottom
        XCTAssertEqual(room, controller.view.safeAreaInsets.bottom + NotebookTheme.endScrollMinimum, accuracy: 0.5)

        controller.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0, bottom: 40, right: 0)
        controller.view.layoutIfNeeded()
        let grown = canvas.contentInset.bottom
        XCTAssertEqual(grown, room + 40, accuracy: 0.5, "More room at once for a taller home indicator area.")
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: Self.endOffset(of: canvas)), animated: false)
        let end = canvas.contentOffset

        controller.canvasViewDidBeginUsingTool(canvas)
        controller.additionalSafeAreaInsets = .zero
        controller.view.layoutIfNeeded()
        XCTAssertEqual(canvas.contentInset.bottom, grown, "The room is held while the stroke is in progress.")
        XCTAssertEqual(canvas.contentOffset, end, "The page never moves under the pen.")
        controller.canvasViewDidEndUsingTool(canvas)
        XCTAssertEqual(canvas.contentInset.bottom, room, accuracy: 0.5, "Released when the stroke ends.")
        XCTAssertEqual(canvas.contentOffset.y, Self.endOffset(of: canvas), accuracy: 0.5, "Settled at the new end.")
        try assertTab(of: controller, followsTheLastPage: "after the release")
    }

    /// Scrolling moves the tab without drawing it again: its edge is a bitmap drawn once per
    /// size and tone, no layer is masked, and the shadow keeps its path.
    func testScrollingMovesTheEndOfPaperTabWithoutDrawingItAgain() async throws {
        let fixture = try await presentTabAtTheEnd()
        defer { fixture.close() }
        let controller = fixture.controller
        let canvas = controller.canvasView
        let tab = controller.endOfPaperTab
        let renders = tab.edgeRenders
        XCTAssertGreaterThan(renders, 0)
        let shadowPath = try XCTUnwrap(tab.layer.shadowPath)
        let end = Self.endOffset(of: canvas)
        var positions = Set<CGFloat>()
        for step in 0..<50 {
            canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: end - CGFloat(step)), animated: false)
            controller.view.layoutIfNeeded()
            positions.insert(tab.frame.minY)
        }
        XCTAssertEqual(positions.count, 50, "The tab follows the paper.")
        XCTAssertEqual(tab.edgeRenders, renders, "Moving never draws the edge again.")
        XCTAssertEqual(tab.layer.shadowPath, shadowPath)
        var layers = [tab.layer]
        while let layer = layers.popLast() {
            XCTAssertNil(layer.mask, "A mask renders offscreen on every frame: \(layer)")
            XCTAssertFalse(layer.shouldRasterize, "\(layer)")
            layers += layer.sublayers ?? []
        }

        controller.traitOverrides.accessibilityContrast = .high
        try await NotebookTestFixtures.waitUntil {
            controller.updateTraitsIfNeeded()
            controller.view.layoutIfNeeded()
            return tab.traitCollection.accessibilityContrast == .high
        }
        XCTAssertEqual(tab.edgeRenders, renders + 1, "A new tone draws the edge once.")
    }

    /// The tab is a lit shell with rounded corners. Pressed, it sinks into the pressed well and
    /// its content drops one point, as a secondary action key does.
    func testEndOfPaperTabSinksIntoThePressedWellAndDropsItsContentWhilePressed() async throws {
        let fixture = try await presentTabAtTheEnd()
        defer { fixture.close() }
        let controller = fixture.controller
        let tab = controller.endOfPaperTab
        let title = tab.titleLabel.convert(tab.titleLabel.bounds, to: tab)
        let resting = try renderTab(of: controller)
        tab.isHighlighted = true
        let pressed = try renderTab(of: controller)
        tab.isHighlighted = false

        // Beside the content, halfway down, where the shell gradient is at its middle.
        let face = CGPoint(x: 8, y: tab.bounds.midY)
        let shell = try Self.mix(NotebookTheme.panelTop, NotebookTheme.panelBottom, 0.5)
        let well = try XCTUnwrap(SRGBPixels.components(NotebookTheme.selectedWell.uiColor))
        assertColor(resting.color(at: face), matches: shell, "the shell")
        assertColor(
            pressed.color(at: face), matches: Self.blend(well, NotebookTheme.pressedWellOpacity, over: shell),
            "the pressed well"
        )
        let stone = try XCTUnwrap(SRGBPixels.components(NotebookTheme.backdropStone.uiColor))
        for (render, state) in [(resting, "resting"), (pressed, "pressed")] {
            let corner = SRGBPixels.relativeLuminance(render.color(at: CGPoint(x: 0.25, y: 0.25)))
            XCTAssertLessThan(corner, SRGBPixels.relativeLuminance(stone) + 0.005, "\(state): the corners are rounded")
        }
        let columns = title.minX...title.maxX
        let restingTop = try XCTUnwrap(resting.firstRow(darkerThan: 0.2, columns: columns), "The title was not drawn.")
        let pressedTop = try XCTUnwrap(pressed.firstRow(darkerThan: 0.2, columns: columns))
        XCTAssertEqual(pressedTop - restingTop, NotebookTheme.pressTravel, accuracy: 0.01)
    }

    /// Under Increase Contrast the tab turns flat with a dark outline and keeps its shadow, and
    /// it follows the setting while shown.
    func testEndOfPaperTabTurnsFlatWithAnOutlineUnderIncreaseContrast() async throws {
        let fixture = try await presentTabAtTheEnd()
        defer { fixture.close() }
        let controller = fixture.controller
        let tab = controller.endOfPaperTab
        // Above the content, where the shell gradient is still lighter than the flat surface.
        let face = CGPoint(x: tab.bounds.midX, y: 6)
        // Halfway down the leading side, inside the one-point edge.
        let side = CGPoint(x: 0.25, y: tab.bounds.midY)
        let pixelCentre = 6 + 0.5 / tab.traitCollection.displayScale
        let shell = try Self.mix(NotebookTheme.panelTop, NotebookTheme.panelBottom, pixelCentre / tab.bounds.height)
        let shellMiddle = try Self.mix(NotebookTheme.panelTop, NotebookTheme.panelBottom, 0.5)
        let surface = try XCTUnwrap(SRGBPixels.components(NotebookTheme.panelSurface.uiColor))
        let outline = try XCTUnwrap(SRGBPixels.components(
            NotebookTheme.panelLowerEdge.uiColor.resolvedColor(with: UITraitCollection(accessibilityContrast: .high))
        ))

        let standard = try renderTab(of: controller)
        assertColor(standard.color(at: face), matches: shell, "standard contrast: the shell")
        assertColor(standard.color(at: side), matches: shellMiddle, "standard contrast: no edge along the sides")
        for contrast in [UIAccessibilityContrast.high, .normal] {
            controller.traitOverrides.accessibilityContrast = contrast
            try await NotebookTestFixtures.waitUntil {
                controller.updateTraitsIfNeeded()
                controller.view.layoutIfNeeded()
                return tab.traitCollection.accessibilityContrast == contrast
            }
            let render = try renderTab(of: controller)
            let increased = contrast == .high
            let name = increased ? "increased contrast" : "contrast restored"
            assertColor(render.color(at: face), matches: increased ? surface : shell, "\(name): face")
            assertColor(render.color(at: side), matches: increased ? outline : shellMiddle, "\(name): side")
            XCTAssertEqual(tab.layer.shadowOpacity, Float(NotebookTheme.shellShadow.opacity), name)
        }
    }

    /// The tab grows with the text size, still ends above the home indicator at the largest
    /// size, and returns to its standard size.
    func testEndOfPaperTabGrowsWithTheTextSizeAndStaysClearOfTheHomeIndicator() async throws {
        let fixture = try await presentTabAtTheEnd()
        defer { fixture.close() }
        let controller = fixture.controller
        let canvas = controller.canvasView
        let tab = controller.endOfPaperTab
        let standard = controller.traitCollection.preferredContentSizeCategory
        let standardSize = tab.bounds.size
        let standardIcon = tab.iconView.intrinsicContentSize
        XCTAssertEqual(standardSize.height, NotebookTheme.endTabHeight)
        let room = canvas.contentInset.bottom
        let largest = UIContentSizeCategory.accessibilityExtraExtraExtraLarge

        controller.traitOverrides.preferredContentSizeCategory = largest
        try await NotebookTestFixtures.waitUntil {
            controller.updateTraitsIfNeeded()
            controller.view.layoutIfNeeded()
            return controller.traitCollection.preferredContentSizeCategory == largest
        }
        XCTAssertEqual(NotebookTheme.tabLabel.style, .subheadline)
        let scaled = UIFontMetrics(forTextStyle: .subheadline).scaledValue(
            for: NotebookTheme.tabLabel.pointSize,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: largest)
        )
        XCTAssertEqual(tab.titleLabel.font.pointSize, scaled, accuracy: 0.5)
        XCTAssertGreaterThan(tab.iconView.intrinsicContentSize.height, standardIcon.height)
        XCTAssertGreaterThan(tab.bounds.height, NotebookTheme.endTabHeight)
        XCTAssertGreaterThan(tab.bounds.width, standardSize.width)
        XCTAssertEqual(canvas.contentInset.bottom, room, "The room below the last page stays.")
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: Self.endOffset(of: canvas)), animated: false)
        try assertTab(of: controller, followsTheLastPage: "largest text size")
        XCTAssertLessThanOrEqual(
            tab.frame.maxY, controller.view.bounds.height - controller.view.safeAreaInsets.bottom,
            "The tab clears the home indicator at the largest text size."
        )

        controller.traitOverrides.remove(UITraitPreferredContentSizeCategory.self)
        try await NotebookTestFixtures.waitUntil {
            controller.updateTraitsIfNeeded()
            controller.view.layoutIfNeeded()
            return controller.traitCollection.preferredContentSizeCategory == standard
        }
        XCTAssertEqual(tab.bounds.size, standardSize)
        XCTAssertEqual(tab.iconView.intrinsicContentSize, standardIcon)
    }

    /// In a narrow window at the largest text size the tab keeps the margin from the window's
    /// sides, and its title shrinks to fit rather than being cut off.
    func testEndOfPaperTabFitsANarrowWindowAtTheLargestTextSize() async throws {
        let width: CGFloat = 375
        let fixture = try await presentTabAtTheEnd(
            pageCount: NotebookViewController.maximumPageCount, size: CGSize(width: width, height: 800)
        )
        defer { fixture.close() }
        let controller = fixture.controller
        let canvas = controller.canvasView
        let tab = controller.endOfPaperTab
        let largest = UIContentSizeCategory.accessibilityExtraExtraExtraLarge
        controller.traitOverrides.preferredContentSizeCategory = largest
        try await NotebookTestFixtures.waitUntil {
            controller.updateTraitsIfNeeded()
            controller.view.layoutIfNeeded()
            return controller.traitCollection.preferredContentSizeCategory == largest
        }
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: Self.endOffset(of: canvas)), animated: false)
        XCTAssertEqual(tab.mode, .limitReached)
        XCTAssertFalse(tab.isHidden)
        let margin = NotebookTheme.endTabGap
        XCTAssertGreaterThanOrEqual(tab.frame.minX, margin - 0.5)
        XCTAssertLessThanOrEqual(tab.frame.maxX, width - margin + 0.5)
        let natural = tab.titleLabel.sizeThatFits(
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        )
        let shown = tab.titleLabel.bounds.width
        XCTAssertGreaterThan(natural.width, shown, "The title is too wide for the window at full size.")
        XCTAssertLessThanOrEqual(shown, tab.bounds.width - 32)
        XCTAssertTrue(tab.titleLabel.adjustsFontSizeToFitWidth)
        XCTAssertLessThanOrEqual(
            natural.width * tab.titleLabel.minimumScaleFactor, shown, "Shrinking fits the whole title."
        )
        XCTAssertGreaterThan(
            tab.sizeThatFits(tab.bounds.size).width, tab.bounds.width,
            "sizeThatFits reports the natural size, so sizeToFit never narrows the tab further."
        )
    }

    func testReadOnlyViewerShowsNoTabAndKeepsItsRange() async throws {
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), allowsEditing: false)
        controller.onAddPage = { XCTFail("A viewer never adds pages.") }
        let window = UIWindow(windowScene: try NotebookTestFixtures.windowScene())
        window.frame = CGRect(x: 0, y: 0, width: 834, height: 1_194)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            controller.tearDown()
            window.isHidden = true
            window.rootViewController = nil
        }
        try await NotebookTestFixtures.waitUntilAppeared(controller)
        let canvas = controller.canvasView
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: Self.endOffset(of: canvas)), animated: false)
        XCTAssertTrue(controller.endOfPaperTab.isHidden)
        XCTAssertEqual(canvas.contentInset.bottom, 0)
    }

    /// The notebook screen's canvas adds a page through the session when its tab is tapped.
    func testEndOfPaperTabOnTheNotebookScreenExtendsThePaper() async throws {
        let id = UUID()
        let root = NotebookTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = try NotebookStorageProbe(stored: try await NotebookTestFixtures.stored(id: id), recoveryRoot: root)
        let storage = await probe.storage(notebookID: id)
        let session = NotebookSession(notebookID: id, openStorage: { storage })
        await session.load()
        let scene = try NotebookTestFixtures.windowScene()
        NotebookTestFixtures.restoreSceneToolDefaults(for: scene, after: self)
        let window = UIWindow(windowScene: scene)
        let hosting = AppearanceTrackingHostingController(rootView: NotebookScreen(session: session))
        window.frame = CGRect(x: 0, y: 0, width: 834, height: 1_194)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        defer {
            session.flush()
            window.isHidden = true
            window.rootViewController = nil
        }
        try await NotebookTestFixtures.waitUntil {
            guard let controller = NotebookTestFixtures.notebookController(in: hosting) else { return false }
            return hosting.hasAppeared && controller.isCanvasVisible
        }
        let controller = try XCTUnwrap(NotebookTestFixtures.notebookController(in: hosting))
        let canvas = controller.canvasView
        XCTAssertGreaterThanOrEqual(
            canvas.contentInset.bottom, controller.view.safeAreaInsets.bottom + NotebookTheme.endScrollMinimum - 0.5
        )
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: Self.endOffset(of: canvas)), animated: false)
        let tab = controller.endOfPaperTab
        XCTAssertFalse(tab.isHidden)
        XCTAssertEqual(tab.mode, .available)
        XCTAssertEqual(session.pageCount, 3)
        tab.sendActions(for: .touchUpInside)
        XCTAssertEqual(session.pageCount, 4)
        let threePages = canvas.bounds.width / 794 * 1_123 * 3
        try await NotebookTestFixtures.waitUntil { canvas.contentSize.height > threePages + 1 }
    }

    /// PencilKit input cannot be synthesized in a unit test, and the stroke shown while the
    /// Pencil is still down is not covered. This proves what decides the backdrop: at the
    /// smallest zoom, touches beside and below the page reach the canvas, and the canvas keeps
    /// ink lying wholly outside the page but never draws it, so no finished ink rests on the stone.
    func testCanvasKeepsButNeverDrawsInkOutsideThePage() async throws {
        let charcoal = try XCTUnwrap(EditorInkCatalog.presets.first { $0.id == "charcoal-monoline" }).color
        let beside = Self.stroke(from: CGPoint(x: -230, y: 300), to: CGPoint(x: -110, y: 300), color: charcoal)
        let below = Self.stroke(from: CGPoint(x: 300, y: 1_165), to: CGPoint(x: 460, y: 1_165), color: charcoal)
        let onPage = Self.stroke(from: CGPoint(x: 300, y: 300), to: CGPoint(x: 420, y: 300), color: charcoal)
        var drawing = PKDrawing()
        drawing.strokes = [beside, below, onPage]
        await ready(.shared)

        let ink = CGPoint(x: onPage.renderBounds.midX, y: onPage.renderBounds.midY)
        let blank = CGPoint(x: 360, y: 360)
        let offPage = [beside, below].map { CGPoint(x: $0.renderBounds.midX, y: $0.renderBounds.midY) }
        let pageOnly = try await renderZoomedOut(drawing: PKDrawing(strokes: [onPage]), inkAt: ink, blankAt: blank)
        let zoomedOut = try await renderZoomedOut(drawing: drawing, inkAt: ink, blankAt: blank, touching: offPage)
        XCTAssertEqual(zoomedOut.drawing.dataRepresentation(), drawing.dataRepresentation(), "off-page ink is kept")
        XCTAssertEqual(zoomedOut.reachesCanvas, [true, true], "Touches beside and below the page reach the canvas.")
        for document in offPage {
            let point = zoomedOut.viewPoint(document)
            XCTAssertFalse(zoomedOut.page.contains(point), "The stroke must lie outside the page.")
            XCTAssertTrue(zoomedOut.bounds.contains(point), "The stroke must be on screen.")
        }
        XCTAssertGreaterThanOrEqual(pageOnly.inkContrast, 3, "The reference render must capture the ink on the page.")
        XCTAssertGreaterThanOrEqual(zoomedOut.inkContrast, 3, "The render must capture the ink on the page.")
        XCTAssertLessThan(
            zoomedOut.pixels.meanDifference(to: pageOnly.pixels), 0.000_5, "ink outside the page is never drawn"
        )
    }

    func testNoiseFieldsAreIndependentAndRepeatOncePerTile() throws {
        let fields = try NotebookMaterials.NoiseField.allCases.map { try Self.values(of: NotebookMaterials.noise($0)) }
        let side = 512, half = side / 2
        for (index, field) in fields.enumerated() {
            let shiftedAcross = (0..<side * side).map { field[($0 / side) * side + ($0 % side + half) % side] }
            let shiftedDown = (0..<side * side).map { field[(($0 / side + half) % side) * side + $0 % side] }
            XCTAssertLessThan(abs(Self.correlation(field, shiftedAcross)), 0.05, "field \(index) repeats inside a tile")
            XCTAssertLessThan(abs(Self.correlation(field, shiftedDown)), 0.05, "field \(index) repeats inside a tile")
            for other in fields[(index + 1)...] {
                XCTAssertLessThan(abs(Self.correlation(field, other)), 0.05, "fields share a pattern")
            }
        }
    }

    func testThemePaperMatchesTheInkContrastReference() throws {
        // NottyCore's ink contrast test cannot see the app theme, so it repeats this value.
        let paper = try XCTUnwrap(SRGBPixels.components(NotebookTheme.paperIvory.uiColor))
        XCTAssertEqual(paper.red, 0.98, accuracy: 0.000_1)
        XCTAssertEqual(paper.green, 0.96, accuracy: 0.000_1)
        XCTAssertEqual(paper.blue, 0.91, accuracy: 0.000_1)
        XCTAssertTrue(NotebookPaperView.paperColor === NotebookTheme.paperIvory.uiColor)
    }

    // MARK: - Helpers

    /// A controller at its smallest zoom with the page scrolled to its top-left corner, and
    /// whether a touch at each of `documentPoints` reaches its canvas. PencilKit draws a newly
    /// shown drawing asynchronously, and its first draw after an install also compiles Metal
    /// shaders, which outlasts any fixed number of frames. So the render is taken once the ink at
    /// `ink` shows against the blank paper at `blank` and two frames later the view looks the same.
    private func renderZoomedOut(
        drawing: PKDrawing, inkAt ink: CGPoint, blankAt blank: CGPoint, touching documentPoints: [CGPoint] = []
    ) async throws -> ZoomedOutCanvas {
        let fixture = try await presentController(
            drawing: drawing, pageCount: 1,
            paperView: NotebookPaperView(frame: .zero, accessibility: AccessibilitySettings().source)
        )
        defer { fixture.close() }
        let canvas = fixture.controller.canvasView
        canvas.setZoomScale(canvas.minimumZoomScale, animated: false)
        canvas.setContentOffset(CGPoint(x: -canvas.contentInset.left, y: -canvas.contentInset.top), animated: false)
        let view = try XCTUnwrap(fixture.controller.view)
        func capture() throws -> ZoomedOutCanvas {
            ZoomedOutCanvas(
                pixels: try render(view, scale: 1), drawing: canvas.drawing, bounds: view.bounds,
                origin: canvas.convert(CGPoint.zero, to: view), contentSize: canvas.contentSize,
                scale: canvas.zoomScale, ink: ink, blank: blank
            )
        }
        try await waitForRenderedFrames()
        var result = try capture()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            try await waitForRenderedFrames()
            let next = try capture()
            let settled = next.pixels.meanDifference(to: result.pixels) == 0
            result = next
            if settled, result.inkContrast >= 3 { break }
        }
        let reaches = documentPoints.map { document in
            let point = view.convert(result.viewPoint(document), to: fixture.window)
            return fixture.window.hitTest(point, with: nil)?.isDescendant(of: canvas) ?? false
        }
        return result.touching(reaches)
    }

    /// Renders the paper of `controller` with textured and then plain materials, and checks that
    /// it is width fitted, that everything above page 1 is paper, and that both screen-border
    /// columns match the middle of the page. Leaves the materials textured.
    private func assertOnlyPaperAbovePageOne(
        in controller: NotebookViewController, settings: AccessibilitySettings, _ state: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let canvas = controller.canvasView
        XCTAssertEqual(canvas.zoomScale, canvas.bounds.width / 794, accuracy: 0.000_1, "\(state)", file: file, line: line)
        XCTAssertEqual(canvas.contentInset.left, 0, accuracy: 0.000_1, "\(state)", file: file, line: line)
        let pageTop = -canvas.contentOffset.y
        XCTAssertGreaterThanOrEqual(pageTop, 205, "\(state): page 1 starts below the reserved space", file: file, line: line)
        let paper = controller.paperView
        let scale = paper.traitCollection.displayScale
        defer {
            settings.increasesContrast = false
            settings.post(UIAccessibility.darkerSystemColorsStatusDidChangeNotification)
        }
        for plain in [false, true] {
            settings.increasesContrast = plain
            settings.post(UIAccessibility.darkerSystemColorsStatusDidChangeNotification)
            try await waitForRenderedFrames()
            let materials = "\(state), \(plain ? "plain" : "textured")"
            let pixels = try render(paper, scale: scale)
            let above = pixels.region(rows: 0..<Int(((pageTop - 1) * scale).rounded(.down)))
            // Fibres stray up to 0.03 per channel from the paper; stone lies 0.16 or more away.
            XCTAssertLessThan(
                try largestDifference(in: above, from: NotebookTheme.paperIvory, file: file, line: line),
                plain ? 0.01 : 0.045, "\(materials): only paper above page 1", file: file, line: line
            )
            if !plain {
                XCTAssertGreaterThan(above.luminanceRange, 0.01, "\(materials): fibres show", file: file, line: line)
                try assertMeanColor(of: above, equals: NotebookTheme.paperIvory, file: file, line: line)
            }
            // Two fibre pixels differ by at most 0.18 over the three channels; even a half-covered
            // edge pixel differs from the paper by more than 0.5.
            let tolerance = plain ? 0.03 : 0.3
            let middle = pixels.width / 2
            for x in [0, 1, pixels.width - 2, pixels.width - 1] {
                let differing = (0..<pixels.height).filter {
                    SRGBPixels.difference(pixels.color(x: x, y: $0), pixels.color(x: middle, y: $0)) > tolerance
                }
                XCTAssertTrue(
                    differing.isEmpty, "\(materials): column \(x) differs at rows \(differing.prefix(4))",
                    file: file, line: line
                )
            }
        }
    }

    /// The page-top divider, the edges and the shading around the paper.
    private static func linesAndShading(of paper: NotebookPaperView) -> [CALayer] {
        [paper.pageTopLayer, paper.edgeLayer, paper.leadingEdgeLayer, paper.trailingEdgeLayer]
            + [paper.bottomShadowLayer, paper.leadingShadowLayer, paper.trailingShadowLayer]
            + [paper.leadingCornerShadowLayer, paper.trailingCornerShadowLayer]
    }

    private static func endOffset(of canvas: UIScrollView) -> CGFloat {
        canvas.contentSize.height - canvas.bounds.height + canvas.contentInset.bottom
    }

    /// Shows a canvas that can add pages, scrolled to the end of its paper.
    private func presentTabAtTheEnd(
        pageCount: Int = 3, size: CGSize = CGSize(width: 834, height: 1_194)
    ) async throws -> Fixture {
        let fixture = try await presentController(
            pageCount: pageCount,
            paperView: NotebookPaperView(frame: .zero, accessibility: AccessibilitySettings().source), size: size
        )
        fixture.controller.onAddPage = {}
        let canvas = fixture.controller.canvasView
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: Self.endOffset(of: canvas)), animated: false)
        fixture.controller.view.layoutIfNeeded()
        return fixture
    }

    /// The controller's view around its end tab, with `margin` points of the backdrop on every side.
    private func renderTab(of controller: NotebookViewController, margin: CGFloat = 8) throws -> TabRender {
        let view = try XCTUnwrap(controller.view)
        let region = controller.endOfPaperTab.frame.insetBy(dx: -margin, dy: -margin)
        let format = UIGraphicsImageRendererFormat()
        format.scale = view.traitCollection.displayScale
        let image = UIGraphicsImageRenderer(size: region.size, format: format).image { _ in
            view.drawHierarchy(
                in: CGRect(origin: CGPoint(x: -region.minX, y: -region.minY), size: view.bounds.size),
                afterScreenUpdates: true
            )
        }
        return TabRender(pixels: try SRGBPixels(image), scale: format.scale, margin: margin)
    }

    /// Pixels around the end tab, read at points in the tab's own coordinates.
    private struct TabRender {
        let pixels: SRGBPixels
        let scale: CGFloat
        let margin: CGFloat

        func color(at point: CGPoint) -> SRGBPixels.Color {
            pixels.color(x: pixel(point.x), y: pixel(point.y))
        }

        /// The centre of the darkest pixel within `rect`, both in the tab's points.
        func darkestPoint(in rect: CGRect) -> CGPoint {
            let pixels = self.pixels
            let points = (pixel(rect.minY)..<pixel(rect.maxY)).flatMap { y in
                (pixel(rect.minX)..<pixel(rect.maxX)).map { (x: $0, y: y) }
            }
            let darkest = points.min {
                SRGBPixels.relativeLuminance(pixels.color(x: $0.x, y: $0.y))
                    < SRGBPixels.relativeLuminance(pixels.color(x: $1.x, y: $1.y))
            } ?? (x: 0, y: 0)
            return CGPoint(
                x: (CGFloat(darkest.x) + 0.5) / scale - margin, y: (CGFloat(darkest.y) + 0.5) / scale - margin
            )
        }

        /// The first row, in points, where a pixel within `columns` is darker than `luminance`.
        func firstRow(darkerThan luminance: Double, columns: ClosedRange<CGFloat>) -> CGFloat? {
            let xs = pixel(columns.lowerBound)...pixel(columns.upperBound)
            let row = (0..<pixels.height).first { y in
                xs.contains { SRGBPixels.relativeLuminance(pixels.color(x: $0, y: y)) < luminance }
            }
            return row.map { CGFloat($0) / scale - margin }
        }

        private func pixel(_ point: CGFloat) -> Int {
            Int(((point + margin) * scale).rounded(.down))
        }
    }

    /// The colour `fraction` of the way from `start` to `end`, as a two-stop gradient draws it.
    private static func mix(
        _ start: NotebookTheme.Tone, _ end: NotebookTheme.Tone, _ fraction: Double
    ) throws -> SRGBPixels.Color {
        let first = try XCTUnwrap(SRGBPixels.components(start.uiColor))
        let second = try XCTUnwrap(SRGBPixels.components(end.uiColor))
        return blend(second, fraction, over: first)
    }

    private static func blend(
        _ color: SRGBPixels.Color, _ opacity: Double, over background: SRGBPixels.Color
    ) -> SRGBPixels.Color {
        SRGBPixels.Color(
            red: color.red * opacity + background.red * (1 - opacity),
            green: color.green * opacity + background.green * (1 - opacity),
            blue: color.blue * opacity + background.blue * (1 - opacity)
        )
    }

    private func assertColor(
        _ color: SRGBPixels.Color, matches expected: SRGBPixels.Color, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(color.red, expected.red, accuracy: 0.01, message, file: file, line: line)
        XCTAssertEqual(color.green, expected.green, accuracy: 0.01, message, file: file, line: line)
        XCTAssertEqual(color.blue, expected.blue, accuracy: 0.01, message, file: file, line: line)
    }

    /// Checks that the tab is shown centred on the page with its top `endTabGap` below the
    /// last page, in the controller's coordinates.
    private func assertTab(
        of controller: NotebookViewController, followsTheLastPage state: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let canvas = controller.canvasView
        let tab = controller.endOfPaperTab
        let pageBottom = canvas.contentSize.height - canvas.contentOffset.y
        let pageCentre = canvas.contentSize.width / 2 - canvas.contentOffset.x
        XCTAssertFalse(tab.isHidden, state, file: file, line: line)
        XCTAssertEqual(NotebookTheme.endTabGap, 20, file: file, line: line)
        XCTAssertEqual(tab.frame.minY, pageBottom + 20, accuracy: 0.5, state, file: file, line: line)
        XCTAssertEqual(tab.frame.midX, pageCentre, accuracy: 0.5, state, file: file, line: line)
        let scale = tab.traitCollection.displayScale
        for edge in [tab.frame.minX * scale, tab.frame.minY * scale] {
            XCTAssertEqual(edge, edge.rounded(), accuracy: 0.001, "\(state): whole pixels", file: file, line: line)
        }
    }

    private func assertLines(
        of paper: NotebookPaperView, edge: [CGFloat], dividerAlpha: CGFloat, edgeThickness: CGFloat, _ state: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for layer in [paper.edgeLayer, paper.leadingEdgeLayer, paper.trailingEdgeLayer] {
            guard let color = layer.backgroundColor else { return XCTFail(state, file: file, line: line) }
            assertComponents(of: color, equal: edge, "\(state): edge", file: file, line: line)
        }
        for layer in paper.boundaryLayers + [paper.pageTopLayer] {
            guard let color = layer.backgroundColor else { return XCTFail(state, file: file, line: line) }
            assertComponents(
                of: color, equal: [0.47, 0.40, 0.31, dividerAlpha], "\(state): divider", file: file, line: line
            )
        }
        XCTAssertEqual(paper.edgeLayer.bounds.height, edgeThickness, accuracy: 0.000_1, state, file: file, line: line)
        XCTAssertEqual(
            paper.leadingEdgeLayer.frame.width, edgeThickness, accuracy: 0.000_1, state, file: file, line: line
        )
        XCTAssertEqual(
            paper.leadingEdgeLayer.frame.maxX, 0, accuracy: 0.000_1, "\(state): just outside the page",
            file: file, line: line
        )
    }

    private func assertComponents(
        of color: CGColor, equal expected: [CGFloat], _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let components = color.converted(to: space, intent: .defaultIntent, options: nil)?.components else {
            return XCTFail(message, file: file, line: line)
        }
        XCTAssertEqual(components.count, expected.count, message, file: file, line: line)
        for (actual, value) in zip(components, expected) {
            XCTAssertEqual(actual, value, accuracy: 0.002, message, file: file, line: line)
        }
    }

    private func veilColors(_ veil: NotebookStatusVeil) throws -> [CGColor] {
        let colors = try XCTUnwrap(veil.gradientLayer.colors)
        return colors.map { $0 as! CGColor }
    }

    private func ready(_ materials: NotebookMaterials) async {
        await withCheckedContinuation { continuation in
            materials.whenReady { _ in continuation.resume() }
        }
    }

    private static var cachedFibreTile: UIImage?

    /// The production fibre tile, rendered once for the pixel tests.
    private static func renderedFibreTile() async -> UIImage {
        if let cachedFibreTile { return cachedFibreTile }
        let rendered = await Task.detached { NotebookMaterials.renderFibreTile() }.value
        let tile = rendered.map {
            UIImage(cgImage: $0, scale: NotebookMaterials.tileScale, orientation: .up)
        } ?? UIImage()
        cachedFibreTile = tile
        return tile
    }

    /// First-channel values of one 512 px tile of a single-channel image.
    private static func values(of image: CIImage) throws -> [Double] {
        let bounds = CGRect(x: 0, y: 0, width: 512, height: 512)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
        let cgImage = try XCTUnwrap(context.createCGImage(image, from: bounds, format: .RGBA8, colorSpace: space))
        return try SRGBPixels(UIImage(cgImage: cgImage)).colors.map(\.red)
    }

    private static func correlation(_ first: [Double], _ second: [Double]) -> Double {
        let count = Double(first.count)
        let meanFirst = first.reduce(0, +) / count
        let meanSecond = second.reduce(0, +) / count
        var covariance = 0.0, varianceFirst = 0.0, varianceSecond = 0.0
        for (a, b) in zip(first, second) {
            covariance += (a - meanFirst) * (b - meanSecond)
            varianceFirst += (a - meanFirst) * (a - meanFirst)
            varianceSecond += (b - meanSecond) * (b - meanSecond)
        }
        return covariance / (varianceFirst * varianceSecond).squareRoot()
    }

    private func assertMeanColor(
        of pixels: SRGBPixels, equals tone: NotebookTheme.Tone, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try assertColor(pixels.meanColor, equals: tone, file: file, line: line)
    }

    private func assertColor(
        _ color: SRGBPixels.Color, equals tone: NotebookTheme.Tone, _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let expected = try XCTUnwrap(SRGBPixels.components(tone.uiColor), file: file, line: line)
        XCTAssertEqual(color.red, expected.red, accuracy: 0.01, message, file: file, line: line)
        XCTAssertEqual(color.green, expected.green, accuracy: 0.01, message, file: file, line: line)
        XCTAssertEqual(color.blue, expected.blue, accuracy: 0.01, message, file: file, line: line)
    }

    /// The largest difference in any one channel between a pixel of `pixels` and `tone`.
    private func largestDifference(
        in pixels: SRGBPixels, from tone: NotebookTheme.Tone, file: StaticString = #filePath, line: UInt = #line
    ) throws -> Double {
        let expected = try XCTUnwrap(SRGBPixels.components(tone.uiColor), file: file, line: line)
        return pixels.colors.reduce(0) { largest, color in
            max(largest, abs(color.red - expected.red), abs(color.green - expected.green), abs(color.blue - expected.blue))
        }
    }

    private func render(_ view: UIView, scale: CGFloat) throws -> SRGBPixels {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        return try SRGBPixels(image)
    }

    /// Shows `view` in a window of its size, returning once the window's root has appeared.
    private func hostInWindow(_ view: UIView) async throws -> HostWindow {
        let host = AppearanceTrackingController()
        let window = UIWindow(windowScene: try NotebookTestFixtures.windowScene())
        window.frame = CGRect(origin: .zero, size: view.bounds.size)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.addSubview(view)
        let hosted = HostWindow(window: window)
        do {
            try await NotebookTestFixtures.waitUntilAppeared(host)
        } catch {
            hosted.close()
            throw error
        }
        return hosted
    }

    private static var catalogInks: [EditorInkColor] {
        EditorInkCatalog.swatches + EditorInkCatalog.presets.map(\.color)
    }

    private static func stroke(from start: CGPoint, to end: CGPoint, color: EditorInkColor) -> PKStroke {
        let points = (0...8).map { index in
            let fraction = CGFloat(index) / 8
            return PKStrokePoint(
                location: CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction),
                timeOffset: Double(index) * 0.02, size: CGSize(width: 16, height: 16),
                opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
            )
        }
        return PKStroke(
            ink: PKInk(.monoline, color: UIColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)),
            path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1_000))
        )
    }

    private func waitForRenderedFrames() async throws {
        let completed = expectation(description: "Display frames")
        let waiter = FrameWaiter(completed: completed)
        let link = CADisplayLink(target: waiter, selector: #selector(FrameWaiter.advance(_:)))
        link.add(to: .main, forMode: .common)
        defer { link.invalidate() }
        let result = await XCTWaiter.fulfillment(of: [completed], timeout: NotebookTestFixtures.readinessTimeout)
        guard result == .completed else { throw FixtureFailure.readiness }
    }

    private func presentController(
        drawing: PKDrawing = PKDrawing(), pageCount: Int = 3, paperView: NotebookPaperView,
        toolStore: NotebookSceneToolStore = NotebookTestFixtures.toolStore(),
        size: CGSize = CGSize(width: 1_366, height: 1_024)
    ) async throws -> Fixture {
        let controller = NotebookViewController(
            pageCount: pageCount, initialDrawing: drawing, toolStore: toolStore,
            allowsEditing: true, paperView: paperView
        )
        let window = UIWindow(windowScene: try NotebookTestFixtures.windowScene())
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        let fixture = Fixture(controller: controller, window: window)
        do {
            try await NotebookTestFixtures.waitUntil { controller.isCanvasVisible && controller.view.window === window }
        } catch {
            fixture.close()
            throw error
        }
        return fixture
    }

    @MainActor
    private struct Fixture {
        let controller: NotebookViewController
        let window: UIWindow

        func close() {
            controller.tearDown()
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    private struct ZoomedOutCanvas {
        let pixels: SRGBPixels
        let drawing: PKDrawing
        let bounds: CGRect
        let origin: CGPoint
        let contentSize: CGSize
        let scale: CGFloat
        /// Document points of a stroke on the page and of blank paper near it.
        let ink: CGPoint
        let blank: CGPoint
        var reachesCanvas: [Bool] = []

        var page: CGRect { CGRect(origin: origin, size: contentSize) }

        /// Contrast between the rendered stroke at `ink` and the blank paper at `blank`.
        var inkContrast: Double {
            SRGBPixels.contrastRatio(pixels.meanColor(around: viewPoint(ink)), pixels.meanColor(around: viewPoint(blank)))
        }

        func viewPoint(_ document: CGPoint) -> CGPoint {
            CGPoint(x: origin.x + document.x * scale, y: origin.y + document.y * scale)
        }

        func touching(_ reaches: [Bool]) -> ZoomedOutCanvas {
            var copy = self
            copy.reachesCanvas = reaches
            return copy
        }
    }

    @MainActor
    private struct HostWindow {
        let window: UIWindow

        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    /// Wraps the production renderer to count renders and keep what they produced.
    private final class RenderProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var onMainThread = false
        private var output: CGImage?

        var renderCount: Int { lock.withLock { calls } }
        var renderedOnMainThread: Bool { lock.withLock { onMainThread } }
        var lastOutput: CGImage? { lock.withLock { output } }

        @MainActor
        func materials() -> NotebookMaterials {
            NotebookMaterials { self.render() }
        }

        private func render() -> CGImage? {
            let tile = NotebookMaterials.renderFibreTile()
            lock.withLock {
                calls += 1
                onMainThread = onMainThread || Thread.isMainThread
                output = tile
            }
            return tile
        }
    }

    /// Accessibility settings the test toggles, delivered through a private notification centre.
    @MainActor
    private final class AccessibilitySettings {
        var reducesTransparency = false
        var increasesContrast = false
        let center = NotificationCenter()

        var source: NotebookMaterialAccessibility {
            NotebookMaterialAccessibility(
                notificationCenter: center,
                isReduceTransparencyEnabled: { self.reducesTransparency },
                isIncreaseContrastEnabled: { self.increasesContrast }
            )
        }

        func post(_ name: Notification.Name) {
            center.post(name: name, object: nil)
        }
    }

    /// Pixels of an image redrawn into an sRGB bitmap, so values compare with sRGB theme colours.
    private struct SRGBPixels {
        struct Color {
            let red: Double
            let green: Double
            let blue: Double
        }

        let width: Int
        let height: Int
        let colors: [Color]

        init(_ image: UIImage) throws {
            let pixels = try RenderedPixels(try XCTUnwrap(image.cgImage), scale: image.scale)
            width = pixels.width
            height = pixels.height
            let bytes = pixels.rgba
            colors = stride(from: 0, to: bytes.count, by: 4).map { (offset: Int) -> Color in
                let red = Double(bytes[offset]) / 255
                let green = Double(bytes[offset + 1]) / 255
                let blue = Double(bytes[offset + 2]) / 255
                return Color(red: red, green: green, blue: blue)
            }
        }

        private init(width: Int, height: Int, colors: [Color]) {
            self.width = width
            self.height = height
            self.colors = colors
        }

        var meanColor: Color { Self.mean(of: colors) }

        /// The pixels in `rows` and `columns`; all columns when `columns` is nil.
        func region(rows: Range<Int>, columns: Range<Int>? = nil) -> SRGBPixels {
            let columns = columns ?? 0..<width
            let colors = rows.flatMap { y in columns.map { x in color(x: x, y: y) } }
            return SRGBPixels(width: columns.count, height: rows.count, colors: colors)
        }

        var luminanceRange: Double {
            let values = colors.map(Self.relativeLuminance)
            return (values.max() ?? 0) - (values.min() ?? 0)
        }

        var luminanceStandardDeviation: Double {
            let values = colors.map(Self.relativeLuminance)
            let mean = values.reduce(0, +) / Double(values.count)
            let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
            return variance.squareRoot()
        }

        func color(x: Int, y: Int) -> Color { colors[y * width + x] }

        /// Mean colour of the 5 x 5 pixel block centred on `point`, given in pixels.
        func meanColor(around point: CGPoint) -> Color {
            let centerX = Int(point.x.rounded()), centerY = Int(point.y.rounded())
            var block: [Color] = []
            for y in (centerY - 2)...(centerY + 2) where (0..<height).contains(y) {
                for x in (centerX - 2)...(centerX + 2) where (0..<width).contains(x) {
                    block.append(color(x: x, y: y))
                }
            }
            return Self.mean(of: block)
        }

        /// Mean per-pixel channel difference from the same image moved by whole pixels, wrapping at the edges.
        func meanDifference(shiftedBy dx: Int, _ dy: Int) -> Double {
            var total = 0.0
            for y in 0..<height {
                for x in 0..<width {
                    total += Self.difference(color(x: x, y: y), color(x: (x + dx) % width, y: (y + dy) % height))
                }
            }
            return total / Double(width * height)
        }

        /// Mean difference over `rows`, comparing each row with `other`'s row `shiftedDown` rows lower.
        func meanDifference(to other: SRGBPixels, rows: Range<Int>, shiftedDown: Int = 0) -> Double {
            precondition(width == other.width && height == other.height)
            var total = 0.0
            for y in rows {
                for x in 0..<width {
                    total += Self.difference(color(x: x, y: y), other.color(x: x, y: (y + shiftedDown) % height))
                }
            }
            return total / Double(rows.count * width)
        }

        func meanDifference(to other: SRGBPixels) -> Double {
            precondition(width == other.width && height == other.height)
            return zip(colors, other.colors).reduce(0) { $0 + Self.difference($1.0, $1.1) } / Double(colors.count)
        }

        static func difference(_ first: Color, _ second: Color) -> Double {
            abs(first.red - second.red) + abs(first.green - second.green) + abs(first.blue - second.blue)
        }

        static func mean(of colors: [Color]) -> Color {
            let count = Double(colors.count)
            return Color(
                red: colors.reduce(0) { $0 + $1.red } / count,
                green: colors.reduce(0) { $0 + $1.green } / count,
                blue: colors.reduce(0) { $0 + $1.blue } / count
            )
        }

        static func contrastRatio(_ first: Color, _ second: Color) -> Double {
            let luminances = [relativeLuminance(first), relativeLuminance(second)].sorted()
            return (luminances[1] + 0.05) / (luminances[0] + 0.05)
        }

        func meanDifference(_ pair: (Int) -> (Color, Color)) -> Double {
            let total = (0..<height).reduce(0.0) { sum, index in
                let (first, second) = pair(index)
                return sum + abs(first.red - second.red) + abs(first.green - second.green)
                    + abs(first.blue - second.blue)
            }
            return total / Double(height)
        }

        static func components(_ color: UIColor) -> Color? {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let converted = color.cgColor.converted(to: space, intent: .defaultIntent, options: nil),
                  let values = converted.components, values.count >= 3 else { return nil }
            return Color(red: Double(values[0]), green: Double(values[1]), blue: Double(values[2]))
        }

        /// WCAG relative luminance from gamma-encoded sRGB components.
        static func relativeLuminance(_ color: Color) -> Double {
            func linear(_ value: Double) -> Double {
                value <= 0.040_45 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
        }
    }

    @MainActor
    private final class PaperDrawSpy: NotebookPaperView {
        private(set) var drawCalls = 0
        override func draw(_ rect: CGRect) {
            drawCalls += 1
            super.draw(rect)
        }
    }

    @MainActor
    private final class FrameWaiter: NSObject {
        let completed: XCTestExpectation
        private var frames = 0
        init(completed: XCTestExpectation) { self.completed = completed }
        @objc func advance(_ link: CADisplayLink) {
            frames += 1
            if frames == 2 {
                link.invalidate()
                completed.fulfill()
            }
        }
    }

    private enum FixtureFailure: Error { case readiness }
}
