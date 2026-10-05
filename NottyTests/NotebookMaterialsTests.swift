import CoreImage
import NottyCore
import PencilKit
import SwiftUI
import UIKit
import XCTest
@testable import Notty

@MainActor
final class NotebookMaterialsTests: XCTestCase {
    func testTilesAreRenderedOnceAcrossManyUses() async {
        let probe = RenderProbe()
        let materials = probe.materials()
        XCTAssertEqual(probe.renderCount, 0)
        await ready(materials)
        XCTAssertEqual(probe.renderCount, 1, "One render produces both tiles.")
        let leather = materials.leatherTile
        let fibre = materials.paperFibrePattern
        XCTAssertNotNil(leather)
        let settings = AccessibilitySettings()
        for _ in 0..<200 {
            materials.prepare()
            XCTAssertTrue(materials.leatherTile === leather)
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

    func testFailedRenderingFallsBackToFlatTiles() async throws {
        let materials = NotebookMaterials { NotebookMaterials.RenderedTiles(leather: nil, paperFibre: nil) }
        let settings = AccessibilitySettings()
        let paper = NotebookPaperView(frame: .zero, materials: materials, accessibility: settings.source)
        await ready(materials)
        let leather = try SRGBPixels(try XCTUnwrap(materials.leatherTile))
        XCTAssertLessThan(leather.luminanceRange, 0.001)
        let expected = try XCTUnwrap(SRGBPixels.components(NotebookTheme.leatherMid.uiColor))
        XCTAssertEqual(leather.meanColor.red, expected.red, accuracy: 0.01)
        XCTAssertEqual(leather.meanColor.green, expected.green, accuracy: 0.01)
        XCTAssertEqual(leather.meanColor.blue, expected.blue, accuracy: 0.01)
        XCTAssertNotNil(paper.grainLayer.backgroundColor?.pattern)
    }

    func testTilePixelSizesAndMemoryAreBounded() async throws {
        let probe = RenderProbe()
        let materials = probe.materials()
        await ready(materials)
        let rendered = try XCTUnwrap(probe.lastOutput)
        var totalBytes = 0
        for image in [try XCTUnwrap(rendered.leather), try XCTUnwrap(rendered.paperFibre)] {
            XCTAssertEqual(image.width, 512)
            XCTAssertEqual(image.height, 512)
            totalBytes += image.bytesPerRow * image.height
        }
        let leather = try XCTUnwrap(materials.leatherTile)
        XCTAssertEqual(leather.size, CGSize(width: NotebookMaterials.tileSide, height: NotebookMaterials.tileSide))
        XCTAssertEqual(leather.scale, NotebookMaterials.tileScale)
        XCTAssertLessThan(totalBytes, 8 * 1_024 * 1_024)
    }

    func testFibreTileIsVisibleButStaysCloseToThePaperColour() async throws {
        let pixels = try SRGBPixels(await Self.renderedTiles().fibre)
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

    func testLeatherTileKeepsTheWarmThemeTone() async throws {
        let pixels = try SRGBPixels(await Self.renderedTiles().leather)
        let theme = try XCTUnwrap(SRGBPixels.components(NotebookTheme.leatherMid.uiColor))
        let mean = pixels.meanColor
        XCTAssertEqual(mean.red, theme.red, accuracy: 0.03)
        XCTAssertEqual(mean.green, theme.green, accuracy: 0.03)
        XCTAssertEqual(mean.blue, theme.blue, accuracy: 0.03)
        for color in pixels.colors {
            XCTAssertGreaterThanOrEqual(color.red, color.green)
            XCTAssertGreaterThanOrEqual(color.green, color.blue)
        }
    }

    func testTilesWrapWithoutVisibleSeams() async throws {
        let tiles = await Self.renderedTiles()
        for tile in [tiles.leather, tiles.fibre] {
            let pixels = try SRGBPixels(tile)
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
    }

    func testGrainLayerSitsInsideContentBelowDividersAndEdge() async throws {
        await ready(.shared)
        let paper = NotebookPaperView(frame: .zero, accessibility: AccessibilitySettings().source)
        paper.setGeometry(width: 794, height: 3_369, boundaries: [1_123, 2_246])
        let sublayers = try XCTUnwrap(paper.contentLayer.sublayers)
        XCTAssertTrue(paper.grainLayer.superlayer === paper.contentLayer)
        XCTAssertTrue(sublayers.first === paper.grainLayer)
        let grainIndex = try XCTUnwrap(sublayers.firstIndex { $0 === paper.grainLayer })
        let edgeIndex = try XCTUnwrap(sublayers.firstIndex { $0 === paper.edgeLayer })
        XCTAssertLessThan(grainIndex, edgeIndex)
        for divider in paper.boundaryLayers {
            XCTAssertLessThan(grainIndex, try XCTUnwrap(sublayers.firstIndex { $0 === divider }))
        }
        XCTAssertEqual(paper.grainLayer.frame, CGRect(x: 0, y: 0, width: 794, height: 3_369))
        XCTAssertFalse(paper.grainLayer.isHidden)
        XCTAssertNil(paper.grainLayer.contents)
        XCTAssertNotNil(paper.grainLayer.backgroundColor?.pattern)

        paper.setGeometry(width: 794, height: 4_492, boundaries: [1_123, 2_246, 3_369])
        XCTAssertEqual(paper.grainLayer.frame, CGRect(x: 0, y: 0, width: 794, height: 4_492))
        XCTAssertTrue(paper.contentLayer.sublayers?.first === paper.grainLayer)
        XCTAssertTrue(paper.grainLayer.animationKeys()?.isEmpty ?? true)
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
        XCTAssertEqual(paper.grainLayer.frame.height, 1_123)
    }

    func testLeatherSurfaceFallsBackToFlatColourForAccessibility() {
        XCTAssertFalse(NotebookLeatherSurface.usesFlatFill(reduceTransparency: false, contrast: .standard))
        XCTAssertTrue(NotebookLeatherSurface.usesFlatFill(reduceTransparency: true, contrast: .standard))
        XCTAssertTrue(NotebookLeatherSurface.usesFlatFill(reduceTransparency: false, contrast: .increased))
        XCTAssertTrue(NotebookLeatherSurface.usesFlatFill(reduceTransparency: true, contrast: .increased))
    }

    func testLeatherSurfaceRendersFlatUnderIncreasedContrast() async throws {
        await ready(.shared)
        let textured = try await renderLeather(contrast: .normal)
        let flat = try await renderLeather(contrast: .high)
        XCTAssertGreaterThan(textured.luminanceRange, 0.005, "The standard surface shows the leather grain.")
        XCTAssertLessThan(flat.luminanceRange, 0.001, "Increased contrast shows one flat leather colour.")
        let expected = try XCTUnwrap(SRGBPixels.components(NotebookTheme.leatherMid.uiColor))
        XCTAssertEqual(flat.meanColor.red, expected.red, accuracy: 0.01)
        XCTAssertEqual(flat.meanColor.green, expected.green, accuracy: 0.01)
        XCTAssertEqual(flat.meanColor.blue, expected.blue, accuracy: 0.01)
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
        let pixels = try SRGBPixels(await Self.renderedTiles().fibre)
        let paper = try XCTUnwrap(SRGBPixels.components(NotebookPaperView.paperColor))
        let darkest = try XCTUnwrap(pixels.colors.min { SRGBPixels.relativeLuminance($0) < SRGBPixels.relativeLuminance($1) })
        for ink in Self.catalogInks {
            let inkColor = SRGBPixels.Color(red: ink.red, green: ink.green, blue: ink.blue)
            let onPaper = SRGBPixels.contrastRatio(inkColor, paper)
            let onFibre = SRGBPixels.contrastRatio(inkColor, darkest)
            XCTAssertGreaterThanOrEqual(onFibre, onPaper * 0.9, "\(ink) loses too much contrast on the fibres")
        }
    }

    func testTilesRepeatOnlyOncePerTile() async throws {
        let tiles = await Self.renderedTiles()
        for tile in [tiles.leather, tiles.fibre] {
            let pixels = try SRGBPixels(tile)
            let half = pixels.width / 2
            let unrelatedX = pixels.meanDifference(shiftedBy: 97, 0)
            let unrelatedY = pixels.meanDifference(shiftedBy: 0, 97)
            XCTAssertGreaterThan(unrelatedX, 0)
            XCTAssertGreaterThanOrEqual(pixels.meanDifference(shiftedBy: half, 0), unrelatedX * 0.75)
            XCTAssertGreaterThanOrEqual(pixels.meanDifference(shiftedBy: 0, half), unrelatedY * 0.75)
            XCTAssertGreaterThanOrEqual(pixels.meanDifference(shiftedBy: half, half), unrelatedX * 0.75)
        }
    }

    func testGrainStaysAnchoredToTheDocumentWhenThePaperGrows() async throws {
        await ready(.shared)
        let paper = NotebookPaperView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300), accessibility: AccessibilitySettings().source
        )
        let window = try hostInWindow(paper)
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

    func testStackedLeatherSurfacesContinueOnePattern() async throws {
        await ready(.shared)
        let size = CGSize(width: 300, height: 400)
        let continuous = try await renderSwiftUI(NotebookLeatherSurface(), size: size)
        let stacked = try await renderSwiftUI(
            VStack(spacing: 0) {
                NotebookLeatherSurface().frame(height: 132)
                NotebookLeatherSurface()
            },
            size: size
        )
        XCTAssertGreaterThan(continuous.luminanceRange, 0.005)
        let misaligned = continuous.meanDifference(shiftedBy: 0, 9)
        XCTAssertLessThan(stacked.meanDifference(to: continuous), misaligned * 0.1)
    }

    func testCanvasMarginsStayIvoryWhenThePageIsScrolledOutOfView() async throws {
        await ready(.shared)
        let size = CGSize(width: 300, height: 500)
        let paper = NotebookPaperView(frame: CGRect(origin: .zero, size: size), accessibility: AccessibilitySettings().source)
        paper.setGeometry(width: 794, height: 1_123, boundaries: [])
        paper.setViewport(scale: 1, offset: CGPoint(x: 2_000, y: 0))
        let pixels = try render(paper, scale: 2)
        let expected = try XCTUnwrap(SRGBPixels.components(NotebookTheme.paperIvory.uiColor))
        XCTAssertEqual(pixels.meanColor.red, expected.red, accuracy: 0.02)
        XCTAssertEqual(pixels.meanColor.green, expected.green, accuracy: 0.02)
        XCTAssertEqual(pixels.meanColor.blue, expected.blue, accuracy: 0.02)
        XCTAssertGreaterThan(pixels.luminanceRange, 0.005)
    }

    func testIvorySurroundsThePageAndFlattensForAccessibility() async throws {
        let materials = NotebookMaterials()
        let settings = AccessibilitySettings()
        let paper = NotebookPaperView(frame: .zero, materials: materials, accessibility: settings.source)
        paper.setGeometry(width: 794, height: 1_123, boundaries: [])
        XCTAssertEqual(paper.backgroundColor, NotebookTheme.paperIvory.uiColor, "flat ivory until the tile is ready")
        XCTAssertNil(paper.backdropLayer.backgroundColor)
        XCTAssertTrue(paper.layer.sublayers?.first === paper.backdropLayer, "the ivory lies under the page")

        await ready(materials)
        let pattern = try XCTUnwrap(paper.backdropLayer.backgroundColor)
        XCTAssertNotNil(pattern.pattern)
        XCTAssertTrue(pattern === materials.paperFibrePattern, "textured ivory around the page")
        XCTAssertFalse(paper.backdropLayer.isHidden)
        settings.increasesContrast = true
        settings.post(UIAccessibility.darkerSystemColorsStatusDidChangeNotification)
        XCTAssertTrue(paper.backdropLayer.isHidden, "flat ivory under Increase Contrast")
        XCTAssertEqual(paper.backgroundColor, NotebookTheme.paperIvory.uiColor)
        settings.increasesContrast = false
        settings.post(UIAccessibility.darkerSystemColorsStatusDidChangeNotification)
        XCTAssertFalse(paper.backdropLayer.isHidden)
        settings.reducesTransparency = true
        settings.post(UIAccessibility.reduceTransparencyStatusDidChangeNotification)
        XCTAssertTrue(paper.backdropLayer.isHidden, "flat ivory under Reduce Transparency")
        XCTAssertTrue(paper.backdropLayer.animationKeys()?.isEmpty ?? true)
    }

    func testPaperDrawsWithThemeTones() {
        let paper = NotebookPaperView(frame: .zero, accessibility: AccessibilitySettings().source)
        paper.setGeometry(width: 794, height: 2_246, boundaries: [1_123])
        XCTAssertEqual(paper.contentLayer.backgroundColor, NotebookTheme.paperIvory.cgColor, "the page itself stays ivory")
        XCTAssertEqual(paper.edgeLayer.backgroundColor, NotebookTheme.paperEdge.cgColor)
        XCTAssertEqual(paper.boundaryLayers.first?.backgroundColor, NotebookTheme.paperDivider.cgColor)
    }

    /// PencilKit input cannot be synthesized in a unit test, and the stroke shown while the
    /// Pencil is still down is not covered. This proves what decides the surround: at the
    /// smallest zoom, touches beside and below the page reach the canvas, and the canvas keeps
    /// ink lying wholly outside the page but never draws it, so no finished ink rests on the leather.
    func testCanvasKeepsButNeverDrawsInkOutsideThePage() async throws {
        let charcoal = try XCTUnwrap(EditorInkCatalog.presets.first { $0.id == "charcoal-monoline" }).color
        let beside = Self.stroke(from: CGPoint(x: -230, y: 300), to: CGPoint(x: -110, y: 300), color: charcoal)
        let below = Self.stroke(from: CGPoint(x: 300, y: 1_165), to: CGPoint(x: 460, y: 1_165), color: charcoal)
        let onPage = Self.stroke(from: CGPoint(x: 300, y: 300), to: CGPoint(x: 420, y: 300), color: charcoal)
        var drawing = PKDrawing()
        drawing.strokes = [beside, below, onPage]
        await ready(.shared)

        let offPage = [beside, below].map { CGPoint(x: $0.renderBounds.midX, y: $0.renderBounds.midY) }
        let pageOnly = try await renderZoomedOut(drawing: PKDrawing(strokes: [onPage])).pixels
        let zoomedOut = try await renderZoomedOut(drawing: drawing, touching: offPage)
        XCTAssertEqual(zoomedOut.drawing.dataRepresentation(), drawing.dataRepresentation(), "off-page ink is kept")
        XCTAssertEqual(zoomedOut.reachesCanvas, [true, true], "Touches beside and below the page reach the canvas.")
        for document in offPage {
            let point = zoomedOut.viewPoint(document)
            XCTAssertFalse(zoomedOut.page.contains(point), "The stroke must lie outside the page.")
            XCTAssertTrue(zoomedOut.bounds.contains(point), "The stroke must be on screen.")
        }
        let onPagePoint = zoomedOut.viewPoint(CGPoint(x: onPage.renderBounds.midX, y: onPage.renderBounds.midY))
        let blankPaper = zoomedOut.viewPoint(CGPoint(x: 360, y: 360))
        XCTAssertGreaterThanOrEqual(
            SRGBPixels.contrastRatio(
                zoomedOut.pixels.meanColor(around: onPagePoint), zoomedOut.pixels.meanColor(around: blankPaper)
            ),
            3, "The render must capture ink on the page."
        )
        XCTAssertLessThan(zoomedOut.pixels.meanDifference(to: pageOnly), 0.000_5, "ink outside the page is never drawn")
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
    /// whether a touch at each of `documentPoints` reaches its canvas.
    private func renderZoomedOut(drawing: PKDrawing, touching documentPoints: [CGPoint] = []) async throws -> ZoomedOutCanvas {
        let fixture = try await presentController(
            drawing: drawing, pageCount: 1,
            paperView: NotebookPaperView(frame: .zero, accessibility: AccessibilitySettings().source)
        )
        defer { fixture.close() }
        let canvas = fixture.controller.canvasView
        canvas.setZoomScale(canvas.minimumZoomScale, animated: false)
        canvas.setContentOffset(CGPoint(x: -canvas.contentInset.left, y: -canvas.contentInset.top), animated: false)
        try await waitForRenderedFrames()
        try await waitForRenderedFrames()
        let view = try XCTUnwrap(fixture.controller.view)
        let result = ZoomedOutCanvas(
            pixels: try render(view, scale: 1), drawing: canvas.drawing, bounds: view.bounds,
            origin: canvas.convert(CGPoint.zero, to: view), contentSize: canvas.contentSize, scale: canvas.zoomScale
        )
        let reaches = documentPoints.map { document in
            let point = view.convert(result.viewPoint(document), to: fixture.window)
            return fixture.window.hitTest(point, with: nil)?.isDescendant(of: canvas) ?? false
        }
        return result.touching(reaches)
    }

    private func ready(_ materials: NotebookMaterials) async {
        await withCheckedContinuation { continuation in
            materials.whenReady { _ in continuation.resume() }
        }
    }

    private static var cachedTiles: (leather: UIImage, fibre: UIImage)?

    /// The production tiles, rendered once for the pixel tests.
    private static func renderedTiles() async -> (leather: UIImage, fibre: UIImage) {
        if let cachedTiles { return cachedTiles }
        let rendered = await Task.detached { NotebookMaterials.renderTiles() }.value
        func image(_ tile: CGImage?) -> UIImage {
            tile.map { UIImage(cgImage: $0, scale: NotebookMaterials.tileScale, orientation: .up) } ?? UIImage()
        }
        let tiles = (leather: image(rendered.leather), fibre: image(rendered.paperFibre))
        cachedTiles = tiles
        return tiles
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

    private func renderLeather(contrast: UIAccessibilityContrast) async throws -> SRGBPixels {
        try await renderSwiftUI(NotebookLeatherSurface(), size: CGSize(width: 300, height: 200), contrast: contrast)
    }

    private func renderSwiftUI(
        _ content: some View, size: CGSize, contrast: UIAccessibilityContrast = .normal, scale: CGFloat = 1
    ) async throws -> SRGBPixels {
        let host = UIHostingController(rootView: content.ignoresSafeArea())
        let window = try hostInWindow(host: host, size: size)
        window.window.traitOverrides.accessibilityContrast = contrast
        defer { window.close() }
        host.view.frame = window.window.bounds
        host.view.layoutIfNeeded()
        try await waitForRenderedFrames()
        return try render(host.view, scale: scale)
    }

    private func render(_ view: UIView, scale: CGFloat) throws -> SRGBPixels {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        return try SRGBPixels(image)
    }

    private func hostInWindow(_ view: UIView) throws -> HostWindow {
        let host = UIViewController()
        let hosted = try hostInWindow(host: host, size: view.bounds.size)
        host.view.addSubview(view)
        return hosted
    }

    private func hostInWindow(host: UIViewController, size: CGSize) throws -> HostWindow {
        let window = UIWindow(windowScene: try NotebookTestFixtures.windowScene())
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.makeKeyAndVisible()
        return HostWindow(window: window)
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
        let result = await XCTWaiter.fulfillment(of: [completed], timeout: 5)
        guard result == .completed else { throw FixtureFailure.readiness }
    }

    private func presentController(
        drawing: PKDrawing = PKDrawing(), pageCount: Int = 3, paperView: NotebookPaperView
    ) async throws -> Fixture {
        let controller = NotebookViewController(
            pageCount: pageCount, initialDrawing: drawing, toolStore: NotebookTestFixtures.toolStore(),
            allowsEditing: true, paperView: paperView
        )
        let window = UIWindow(windowScene: try NotebookTestFixtures.windowScene())
        window.frame = CGRect(x: 0, y: 0, width: 1_366, height: 1_024)
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
        var reachesCanvas: [Bool] = []

        var page: CGRect { CGRect(origin: origin, size: contentSize) }

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
        private var output: NotebookMaterials.RenderedTiles?

        var renderCount: Int { lock.withLock { calls } }
        var renderedOnMainThread: Bool { lock.withLock { onMainThread } }
        var lastOutput: NotebookMaterials.RenderedTiles? { lock.withLock { output } }

        @MainActor
        func materials() -> NotebookMaterials {
            NotebookMaterials { self.render() }
        }

        private func render() -> NotebookMaterials.RenderedTiles {
            let tiles = NotebookMaterials.renderTiles()
            lock.withLock {
                calls += 1
                onMainThread = onMainThread || Thread.isMainThread
                output = tiles
            }
            return tiles
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

        var meanColor: Color { Self.mean(of: colors) }

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
