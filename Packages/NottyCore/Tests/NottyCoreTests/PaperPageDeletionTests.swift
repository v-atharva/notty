import Foundation
import PencilKit
import XCTest
@testable import NottyCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@available(iOS 27.0, macOS 27.0, *)
final class PaperPageDeletionTests: XCTestCase {
    private let geometry = PaperGeometry(pageWidth: 794)
    private var height: Double { geometry.pageHeight }
    /// PencilKit rounds rendered bounds out to whole points.
    private let bounds: CGFloat = 1

    // MARK: - The page under view

    /// The page filling most of the visible paper, wherever the view rests: at the top, between
    /// two pages, at the end, and over the head margin or the space below the paper.
    func testTheMostVisiblePageIsTheOneFillingMostOfTheView() {
        let spans: [(top: Double, bottom: Double, page: Int)] = [
            (0, 1_000, 0),
            (-180, 900, 0),
            (0.30 * height, 1.30 * height, 0),
            (0.62 * height, 1.50 * height, 1),
            (6.70 * height, 7.60 * height, 7),
            (6.20 * height, 7.15 * height, 6),
            (11.20 * height, 12.40 * height, 11),
            (10.95 * height, 11.90 * height, 11),
        ]
        for span in spans {
            XCTAssertEqual(
                geometry.mostVisiblePage(top: span.top, bottom: span.bottom, pageCount: 12), span.page,
                "\(span.top / height) to \(span.bottom / height) pages"
            )
        }
    }

    /// Zoomed out, several whole pages fill the view equally; the one holding its centre wins,
    /// not the first of them.
    func testWholePagesFillingTheViewEquallyGoToTheOneAtItsCentre() {
        XCTAssertEqual(geometry.mostVisiblePage(top: 0.5 * height, bottom: 4.5 * height, pageCount: 12), 2)
        XCTAssertEqual(geometry.mostVisiblePage(top: 0.9 * height, bottom: 4.6 * height, pageCount: 12), 2)
        XCTAssertEqual(geometry.mostVisiblePage(top: 2.95 * height, bottom: 7.95 * height, pageCount: 12), 5)
        // The whole of a short notebook is its middle page, however much margin or dark space
        // shows above or below it.
        XCTAssertEqual(geometry.mostVisiblePage(top: -300, bottom: 3 * height + 400, pageCount: 3), 1)
        XCTAssertEqual(geometry.mostVisiblePage(top: -1.6 * height, bottom: 3 * height, pageCount: 3), 1)
        XCTAssertEqual(geometry.mostVisiblePage(top: 0, bottom: 4.6 * height, pageCount: 3), 1)
    }

    /// A view wholly off the paper picks the nearer end page; one that cannot be measured, or a
    /// single page, picks the first.
    func testAViewOffThePaperPicksTheNearerEnd() {
        XCTAssertEqual(geometry.mostVisiblePage(top: -900, bottom: -100, pageCount: 12), 0)
        XCTAssertEqual(geometry.mostVisiblePage(top: 12 * height + 10, bottom: 12 * height + 600, pageCount: 12), 11)
        XCTAssertEqual(geometry.mostVisiblePage(top: .nan, bottom: 600, pageCount: 12), 0)
        XCTAssertEqual(geometry.mostVisiblePage(top: 0, bottom: .infinity, pageCount: 12), 0)
        XCTAssertEqual(geometry.mostVisiblePage(top: 0, bottom: 5 * height, pageCount: 1), 0)
    }

    // MARK: - Which ink goes

    /// A stroke goes with the page holding its vertical midpoint: one crossing a divider goes with
    /// the page holding most of its height, and a midpoint on a divider belongs to the page below
    /// it. Ink off the paper belongs to the nearer end page.
    func testAStrokeBelongsToThePageHoldingItsMidpoint() throws {
        let deletion = try XCTUnwrap(PaperPageDeletion(page: 3, pageCount: 6, geometry: geometry))
        let cases: [(minY: Double, maxY: Double, fate: PaperPageDeletion.Fate)] = [
            (3.2 * height, 3.4 * height, .removed),
            (2.9 * height, 3.3 * height, .removed),
            (2.6 * height, 3.2 * height, .kept),
            (3.8 * height, 4.1 * height, .removed),
            (3.7 * height, 4.5 * height, .movedUp),
            (geometry.boundaryPosition(at: 4), geometry.boundaryPosition(at: 4), .movedUp),
            (2.1 * height, 2.9 * height, .kept),
            (5.6 * height, 7.0 * height, .movedUp),
            (-200, -40, .kept),
        ]
        for (index, stroke) in cases.enumerated() {
            XCTAssertEqual(deletion.fate(ofStrokeFrom: stroke.minY, to: stroke.maxY), stroke.fate, "case \(index)")
        }
        let first = try XCTUnwrap(PaperPageDeletion(page: 0, pageCount: 6, geometry: geometry))
        XCTAssertEqual(first.fate(ofStrokeFrom: -200, to: -40), .removed, "Ink above the paper is the first page's.")
        let last = try XCTUnwrap(PaperPageDeletion(page: 5, pageCount: 6, geometry: geometry))
        XCTAssertEqual(last.fate(ofStrokeFrom: 6 * height + 10, to: 6 * height + 90), .removed,
            "Ink below the paper is the last page's.")
    }

    /// A stroke with no measurable bounds draws nothing, so it is never removed or moved.
    func testAStrokeWithoutBoundsIsKept() throws {
        let deletion = try XCTUnwrap(PaperPageDeletion(page: 0, pageCount: 3, geometry: geometry))
        XCTAssertEqual(deletion.fate(ofStrokeFrom: .infinity, to: .infinity), .kept)
        XCTAssertEqual(deletion.fate(ofStrokeFrom: .nan, to: 40), .kept)
        XCTAssertEqual(deletion.fate(ofStrokeFrom: .infinity, to: -.infinity), .kept)
    }

    func testOnlyAPageOfPaperWithAnotherPageCanBeDeleted() {
        XCTAssertNil(PaperPageDeletion(page: 0, pageCount: 1, geometry: geometry))
        XCTAssertNil(PaperPageDeletion(page: -1, pageCount: 4, geometry: geometry))
        XCTAssertNil(PaperPageDeletion(page: 4, pageCount: 4, geometry: geometry))
        let deletion = PaperPageDeletion(page: 3, pageCount: 4, geometry: geometry)
        XCTAssertEqual(deletion?.remainingPageCount, 3)
        XCTAssertEqual(deletion?.verticalShift, -height)
    }

    // MARK: - The drawing

    /// Deleting page 2 of 4 removes its ink, moves the ink of pages 3 and 4 up by exactly one page
    /// and leaves page 1 untouched; every remaining stroke keeps its order and identity. Strokes
    /// crossing the first divider go with the page holding their midpoint.
    func testDeletionRemovesThePagesInkAndMovesLaterInkUpByOnePage() throws {
        let onFirst = stroke(page: 0.3)
        let onSecond = stroke(page: 1.5)
        let crossingIntoSecond = stroke(page: 1.02, height: 120)
        let crossingFromFirst = stroke(page: 0.98, height: 120)
        let onThird = stroke(page: 2.4)
        let onFourth = stroke(page: 3.7)
        XCTAssertLessThan(Double(crossingIntoSecond.renderBounds.minY), height)
        XCTAssertGreaterThan(Double(crossingFromFirst.renderBounds.maxY), height)
        let original = PKDrawing(strokes: [onFirst, onThird, onSecond, crossingIntoSecond, crossingFromFirst, onFourth])
        let deletion = try XCTUnwrap(PaperPageDeletion(page: 1, pageCount: 4, geometry: geometry))
        let result = deletion.apply(to: original)

        XCTAssertEqual(result.strokes.map(\.id), [onFirst.id, onThird.id, crossingFromFirst.id, onFourth.id])
        for (kept, before) in [(result.strokes[0], onFirst), (result.strokes[2], crossingFromFirst)] {
            XCTAssertEqual(kept.transform, before.transform, "Earlier ink is untouched.")
            XCTAssertEqual(kept.renderBounds, before.renderBounds)
        }
        for (moved, before) in [(result.strokes[1], onThird), (result.strokes[3], onFourth)] {
            XCTAssertEqual(moved.path.creationDate, before.path.creationDate)
            XCTAssertEqual(moved.path.count, before.path.count)
            XCTAssertEqual(moved.ink.inkType, before.ink.inkType)
            XCTAssertEqual(moved.renderBounds.minX, before.renderBounds.minX, accuracy: bounds)
            XCTAssertEqual(moved.renderBounds.width, before.renderBounds.width, accuracy: bounds)
            XCTAssertEqual(moved.renderBounds.height, before.renderBounds.height, accuracy: bounds)
            XCTAssertEqual(Double(moved.renderBounds.minY), Double(before.renderBounds.minY) - height, accuracy: Double(bounds))
        }
    }

    /// A stroke already moved, by the lasso or an earlier deletion, keeps that move and gains the
    /// page's on top of it.
    func testAMovedStrokeKeepsItsTransformAndGainsTheShift() throws {
        var moved = stroke(page: 2.2)
        moved.transform = CGAffineTransform(translationX: 40, y: 0.5 * height)
        let before = moved.renderBounds
        let deletion = try XCTUnwrap(PaperPageDeletion(page: 0, pageCount: 4, geometry: geometry))
        let result = try XCTUnwrap(deletion.apply(to: PKDrawing(strokes: [moved])).strokes.first)
        XCTAssertEqual(result.transform, moved.transform.concatenating(CGAffineTransform(translationX: 0, y: -height)))
        XCTAssertEqual(result.renderBounds.minX, before.minX, accuracy: bounds)
        XCTAssertEqual(Double(result.renderBounds.minY), Double(before.minY) - height, accuracy: Double(bounds))
    }

    /// An erased stroke moves with its eraser mask: what showed of it still shows, one page up.
    func testAnErasedStrokeMovesWithItsMask() throws {
        var erased = stroke(page: 2.5, length: 300)
        let line = erased.renderBounds
        let kept = CGRect(x: line.minX, y: line.minY - 10, width: line.width / 3, height: line.height + 20)
        #if canImport(UIKit)
        erased.mask = UIBezierPath(rect: kept)
        #else
        erased.mask = NSBezierPath(rect: kept)
        #endif
        let shown = erased.renderBounds
        XCTAssertLessThan(shown.width, line.width / 2, "The mask clips what the stroke shows.")
        let deletion = try XCTUnwrap(PaperPageDeletion(page: 1, pageCount: 4, geometry: geometry))
        let result = try XCTUnwrap(deletion.apply(to: PKDrawing(strokes: [erased])).strokes.first)
        XCTAssertEqual(result.mask?.bounds, erased.mask?.bounds, "The mask stays in the stroke's own space.")
        XCTAssertEqual(result.renderBounds.minX, shown.minX, accuracy: bounds)
        XCTAssertEqual(result.renderBounds.width, shown.width, accuracy: bounds)
        XCTAssertEqual(Double(result.renderBounds.minY), Double(shown.minY) - height, accuracy: Double(bounds))
    }

    /// Deleting a blank last page leaves every stroke as it was.
    func testDeletingABlankLastPageLeavesTheInkAsItWas() throws {
        let strokes = [stroke(page: 0.5), stroke(page: 1.2), stroke(page: 2.8)]
        let deletion = try XCTUnwrap(PaperPageDeletion(page: 3, pageCount: 4, geometry: geometry))
        let result = deletion.apply(to: PKDrawing(strokes: strokes))
        XCTAssertEqual(result.strokes.map(\.id), strokes.map(\.id))
        XCTAssertEqual(result.strokes.map(\.transform), strokes.map(\.transform))
        XCTAssertEqual(try InkDrawingSignature(result), try InkDrawingSignature(PKDrawing(strokes: strokes)))
    }

    /// The codec reuses the stored archives of untouched strokes and stores moved strokes again
    /// under their own identities; decoding gives back the moved drawing.
    func testTheCodecStoresMovedStrokesAgainUnderTheirIdentities() async throws {
        let strokes = [stroke(page: 0.5), stroke(page: 1.5), stroke(page: 2.5), stroke(page: 3.5)]
        let original = PKDrawing(strokes: strokes)
        let codec = InkCodec()
        let before = try await codec.encode(original)
        let serializedBefore = await codec.serializedStrokeCount
        let deletion = try XCTUnwrap(PaperPageDeletion(page: 1, pageCount: 4, geometry: geometry))
        let deleted = deletion.apply(to: original)
        let after = try await codec.encode(deleted)
        let serialized = await codec.serializedStrokeCount - serializedBefore
        XCTAssertEqual(serialized, 2, "Only the two moved strokes are archived again.")
        XCTAssertEqual(after.map(\.id), [strokes[0].id, strokes[2].id, strokes[3].id])
        XCTAssertEqual(after[0].data, before[0].data)
        XCTAssertNotEqual(after[1].data, before[2].data)
        let reopened = try await InkCodec().decode(after)
        XCTAssertEqual(reopened.strokes.map(\.id), deleted.strokes.map(\.id))
        // Archives hold transforms in single precision.
        for (restored, expected) in zip(reopened.strokes, deleted.strokes) {
            XCTAssertEqual(restored.transform.ty, expected.transform.ty, accuracy: 1e-3)
            XCTAssertEqual(restored.renderBounds.minY, expected.renderBounds.minY, accuracy: bounds)
        }
    }

    // MARK: - Fixtures

    /// A horizontal pen stroke `length` points long whose middle sits `page` pages down the paper,
    /// rising by `height` points from start to end.
    private func stroke(page: Double, height rise: CGFloat = 0, length: CGFloat = 60) -> PKStroke {
        #if canImport(UIKit)
        let color = UIColor.black
        #else
        let color = NSColor.black
        #endif
        let middle = CGFloat(page * height)
        let points = (0..<4).map { index in
            let fraction = CGFloat(index) / 3
            return PKStrokePoint(
                location: CGPoint(x: 100 + fraction * length, y: middle - rise / 2 + fraction * rise),
                timeOffset: Double(index) * 0.02, size: CGSize(width: 3, height: 3),
                opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
            )
        }
        var result = PKStroke(
            ink: PKInk(.pen, color: color),
            path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1_000))
        )
        result.id = UUID()
        return result
    }
}
