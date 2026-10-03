import PencilKit
import UIKit
import XCTest
@testable import Notty

@MainActor
final class NotebookControllerTests: XCTestCase {
    func testPausedCanvasKeepsNavigationAndBlocksMutationRoutes() {
        let drawing = PKDrawing(strokes: [NotebookTestFixtures.stroke()])
        let controller = NotebookViewController(pageCount: 3, initialDrawing: drawing)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        controller.setEditingEnabled(false)
        let canvas = controller.canvasView
        XCTAssertTrue(canvas.isUserInteractionEnabled)
        XCTAssertTrue(canvas.isScrollEnabled)
        XCTAssertTrue(canvas.panGestureRecognizer.isEnabled)
        XCTAssertTrue(canvas.pinchGestureRecognizer?.isEnabled == true)
        XCTAssertFalse(canvas.isDrawingEnabled)
        XCTAssertFalse(canvas.drawingGestureRecognizer.isEnabled)
        XCTAssertNil(canvas.undoManager)
        for action in ["cut:", "paste:", "delete:", "undo:", "redo:", "duplicate:"] {
            let selector = NSSelectorFromString(action)
            XCTAssertFalse(canvas.canPerformAction(selector, withSender: nil))
            XCTAssertNil(canvas.target(forAction: selector, withSender: nil))
        }
        canvas.paste(nil)
        canvas.cut(nil)
        canvas.delete(nil)
        canvas.paste(itemProviders: [NSItemProvider(object: "waiting" as NSString)])
        XCTAssertFalse(canvas.canPaste([NSItemProvider(object: "waiting" as NSString)]))
        canvas.setContentOffset(CGPoint(x: 0, y: 150), animated: false)
        XCTAssertEqual(canvas.contentOffset.y, 150, accuracy: 0.1)
        let requestedZoom = min(canvas.minimumZoomScale * 1.5, canvas.maximumZoomScale)
        canvas.setZoomScale(requestedZoom, animated: false)
        XCTAssertEqual(canvas.zoomScale, requestedZoom, accuracy: 0.01)
        XCTAssertEqual(canvas.drawing.strokes.map(\.id), drawing.strokes.map(\.id))
        controller.setEditingEnabled(true)
        XCTAssertTrue(canvas.isDrawingEnabled)
        XCTAssertTrue(canvas.drawingGestureRecognizer.isEnabled)
        controller.tearDown()
    }

    func testSeedRetainsWorkingDrawingAcrossRotationAndExtentUpdate() {
        let drawing = PKDrawing(strokes: [NotebookTestFixtures.stroke()])
        let controller = NotebookViewController(pageCount: 4, initialDrawing: drawing)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_000, height: 700)
        controller.view.layoutIfNeeded()
        controller.setPageCount(5)
        controller.setEditingEnabled(false)
        controller.view.frame = CGRect(x: 0, y: 0, width: 700, height: 1_000)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.currentDrawing.strokes.map(\.id), drawing.strokes.map(\.id))
        XCTAssertEqual(controller.currentDrawing.strokes[0].path.creationDate, drawing.strokes[0].path.creationDate)
        controller.tearDown()
    }
}
