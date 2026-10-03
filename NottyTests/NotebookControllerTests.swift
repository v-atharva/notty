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
        controller.setInputGate(.failed)
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
        controller.setInputGate(.open)
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
        controller.setInputGate(.failed)
        controller.view.frame = CGRect(x: 0, y: 0, width: 700, height: 1_000)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.currentDrawing.strokes.map(\.id), drawing.strokes.map(\.id))
        XCTAssertEqual(controller.currentDrawing.strokes[0].path.creationDate, drawing.strokes[0].path.creationDate)
        controller.tearDown()
    }
    func testCapacityPauseKeepsFirstResponderAndInsets() {
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing())
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_024, height: 1_366))
        }
        window.frame = CGRect(x: 0, y: 0, width: 1_024, height: 1_366)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        controller.setInputGate(.open)
        let canvas = controller.canvasView
        XCTAssertTrue(canvas.becomeFirstResponder())
        let firstBefore = canvas.isFirstResponder
        XCTAssertTrue(firstBefore)
        let insetsBefore = canvas.contentInset
        controller.setInputGate(.capacity)
        let firstPaused = canvas.isFirstResponder
        let insetsPaused = canvas.contentInset
        controller.setInputGate(.open)
        XCTAssertEqual(firstPaused, firstBefore, "N1: a pause resigns first responder, hiding the tool picker")
        XCTAssertEqual(insetsPaused, insetsBefore, "N1: a pause changes content insets")
        controller.tearDown()
        window.isHidden = true
    }

    func testTwentyCapacityCyclesKeepResponderPaletteViewportAndInsets() {
        let drawing = PKDrawing(strokes: [NotebookTestFixtures.stroke()])
        let controller = NotebookViewController(pageCount: 3, initialDrawing: drawing)
        let window = present(controller)
        defer {
            controller.tearDown()
            window.isHidden = true
        }
        let canvas = controller.canvasView
        let picker = controller.drawingToolPicker
        canvas.setZoomScale(
            min(canvas.minimumZoomScale * 1.25, canvas.maximumZoomScale), animated: false
        )
        canvas.setContentOffset(CGPoint(x: 80, y: 300), animated: false)
        let offset = canvas.contentOffset
        let insets = canvas.contentInset
        let indicatorInsets = canvas.verticalScrollIndicatorInsets
        let scale = canvas.zoomScale
        let initialDrawing = canvas.drawing
        let pickerVisible = picker.isVisible
        XCTAssertTrue(pickerVisible)
        XCTAssertTrue(canvas.isFirstResponder)
        for _ in 0..<20 {
            controller.setInputGate(.capacity)
            controller.setInputGate(.capacity)
            XCTAssertTrue(canvas.isFirstResponder)
            XCTAssertFalse(canvas.isDrawingEnabled)
            XCTAssertFalse(canvas.drawingGestureRecognizer.isEnabled)
            XCTAssertNil(canvas.undoManager)
            XCTAssertEqual(picker.isVisible, pickerVisible)
            XCTAssertEqual(canvas.contentInset, insets)
            XCTAssertEqual(canvas.verticalScrollIndicatorInsets, indicatorInsets)
            XCTAssertEqual(canvas.contentOffset, offset)
            XCTAssertEqual(canvas.zoomScale, scale, accuracy: 0.001)
            controller.setInputGate(.open)
            controller.setInputGate(.open)
            XCTAssertTrue(canvas.isFirstResponder)
            XCTAssertTrue(canvas.isDrawingEnabled)
            XCTAssertEqual(picker.isVisible, pickerVisible)
            XCTAssertEqual(canvas.contentInset, insets)
            XCTAssertEqual(canvas.verticalScrollIndicatorInsets, indicatorInsets)
            XCTAssertEqual(canvas.contentOffset, offset)
            XCTAssertEqual(canvas.zoomScale, scale, accuracy: 0.001)
        }
        XCTAssertEqual(canvas.drawing, initialDrawing)
        XCTAssertEqual(canvas.drawing.strokes.map(\.id), drawing.strokes.map(\.id))
    }

    func testNativeToolChoicesDuringCapacityCannotReenableMutation() async {
        let drawing = PKDrawing(strokes: [NotebookTestFixtures.stroke()])
        let controller = NotebookViewController(pageCount: 3, initialDrawing: drawing)
        let window = present(controller)
        defer {
            controller.tearDown()
            window.isHidden = true
        }
        let canvas = controller.canvasView
        let picker = controller.drawingToolPicker
        let originalTool = picker.selectedToolItem
        let initialDrawing = canvas.drawing
        let tools = picker.toolItems.filter {
            $0 is PKToolPickerInkingItem || $0 is PKToolPickerEraserItem || $0 is PKToolPickerLassoItem
        }
        XCTAssertTrue(tools.contains { $0 is PKToolPickerInkingItem })
        XCTAssertTrue(tools.contains { $0 is PKToolPickerEraserItem })
        XCTAssertTrue(tools.contains { $0 is PKToolPickerLassoItem })
        controller.setInputGate(.capacity)
        for item in tools {
            picker.selectedToolItem = item
            await Task.yield()
            XCTAssertEqual(controller.inputGate, .capacity)
            XCTAssertTrue(canvas.isFirstResponder)
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
            canvas.isDrawingEnabled = true
            XCTAssertFalse(canvas.isDrawingEnabled)
            XCTAssertFalse(canvas.drawingGestureRecognizer.isEnabled)
            XCTAssertEqual(canvas.drawing, initialDrawing)
            XCTAssertEqual(canvas.drawing.strokes.map(\.id), drawing.strokes.map(\.id))
        }
        picker.selectedToolItem = originalTool
        await Task.yield()
        controller.setInputGate(.open)
        XCTAssertTrue(canvas.isFirstResponder)
        XCTAssertTrue(canvas.isDrawingEnabled)
        canvas.isDrawingEnabled = false
        controller.setInputGate(.capacity)
        controller.setInputGate(.open)
        XCTAssertFalse(canvas.isDrawingEnabled)
        XCTAssertFalse(canvas.drawingGestureRecognizer.isEnabled)
        canvas.isDrawingEnabled = true
        XCTAssertTrue(canvas.isDrawingEnabled)
    }

    func testNativeCustomItemDrawingRequestSurvivesCapacityResume() async {
        let pen = PKToolPickerInkingItem(type: .pen, color: .black, width: 3, identifier: "test.pen")
        var configuration = PKToolPickerCustomItem.Configuration(identifier: "test.inspect", name: "Inspect")
        configuration.imageProvider = { _ in UIImage(systemName: "hand.draw")! }
        let custom = PKToolPickerCustomItem(configuration: configuration)
        let picker = PKToolPicker(toolItems: [pen, custom])
        let controller = NotebookViewController(
            pageCount: 3, initialDrawing: PKDrawing(), toolPicker: picker
        )
        let window = present(controller)
        let canvas = controller.canvasView
        defer {
            controller.tearDown()
            window.isHidden = true
        }
        controller.setInputGate(.capacity)
        picker.selectedToolItem = pen
        await Task.yield()
        XCTAssertFalse(canvas.isDrawingEnabled)
        picker.selectedToolItem = custom
        await Task.yield()
        XCTAssertFalse(canvas.isDrawingEnabled)
        controller.setInputGate(.open)
        XCTAssertFalse(canvas.isDrawingEnabled)
        XCTAssertFalse(canvas.drawingGestureRecognizer.isEnabled)
        XCTAssertTrue(canvas.isFirstResponder)
        controller.setInputGate(.capacity)
        picker.selectedToolItem = pen
        await Task.yield()
        XCTAssertFalse(canvas.isDrawingEnabled)
        controller.setInputGate(.open)
        XCTAssertTrue(canvas.isDrawingEnabled)
        XCTAssertTrue(canvas.drawingGestureRecognizer.isEnabled)
    }

    func testCompletedEditAppliesCapacityReasonSynchronously() {
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing())
        controller.loadViewIfNeeded()
        var receivedIDs: [UUID] = []
        controller.onCompletedEdit = { drawing in
            receivedIDs = drawing.strokes.map(\.id)
            return .capacity
        }
        let drawing = PKDrawing(strokes: [NotebookTestFixtures.stroke()])
        controller.canvasView.drawing = drawing
        controller.canvasViewDrawingDidChange(controller.canvasView)
        XCTAssertEqual(receivedIDs, drawing.strokes.map(\.id))
        XCTAssertEqual(controller.inputGate, .capacity)
        XCTAssertFalse(controller.canvasView.isDrawingEnabled)
        XCTAssertFalse(controller.canvasView.drawingGestureRecognizer.isEnabled)
        controller.tearDown()
    }

    func testFailureRecoveryAndReadOnlyHidePaletteAndResignResponder() {
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing())
        let window = present(controller)
        defer {
            controller.tearDown()
            window.isHidden = true
        }
        for gate in [NotebookInputGate.failed, .recovering, .readOnly] {
            controller.setInputGate(.open)
            XCTAssertTrue(controller.canvasView.isFirstResponder)
            controller.setInputGate(.capacity)
            XCTAssertTrue(controller.canvasView.isFirstResponder)
            XCTAssertFalse(controller.canvasView.isDrawingEnabled)
            controller.setInputGate(gate)
            controller.setInputGate(gate)
            XCTAssertFalse(controller.canvasView.isFirstResponder)
            XCTAssertFalse(controller.drawingToolPicker.isVisible)
            XCTAssertFalse(controller.canvasView.isDrawingEnabled)
            XCTAssertTrue(controller.canvasView.panGestureRecognizer.isEnabled)
            XCTAssertTrue(controller.canvasView.pinchGestureRecognizer?.isEnabled == true)
        }
    }

    private func present(_ controller: NotebookViewController) -> UIWindow {
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_024, height: 1_366))
        }
        window.frame = CGRect(x: 0, y: 0, width: 1_024, height: 1_366)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        controller.drawingToolPicker.setVisible(true, forFirstResponder: controller.canvasView)
        XCTAssertTrue(controller.canvasView.becomeFirstResponder())
        return window
    }

}
