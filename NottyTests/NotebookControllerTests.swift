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
    func testCapacityPauseKeepsFirstResponderAndInsets() async throws {
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing())
        let window = try await present(controller)
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

    func testTwentyCapacityCyclesKeepResponderPaletteViewportAndInsets() async throws {
        let drawing = PKDrawing(strokes: [NotebookTestFixtures.stroke()])
        let controller = NotebookViewController(pageCount: 3, initialDrawing: drawing)
        let window = try await present(controller)
        defer {
            controller.tearDown()
            window.isHidden = true
        }
        let canvas = controller.canvasView
        let picker = try XCTUnwrap(controller.drawingToolPicker)
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
            XCTAssertNotNil(canvas.undoManager)
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

    func testNativeToolChoicesDuringCapacityCannotReenableMutation() async throws {
        let drawing = PKDrawing(strokes: [NotebookTestFixtures.stroke()])
        let controller = NotebookViewController(pageCount: 3, initialDrawing: drawing)
        let window = try await present(controller)
        defer {
            controller.tearDown()
            window.isHidden = true
        }
        let canvas = controller.canvasView
        let picker = try XCTUnwrap(controller.drawingToolPicker)
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
            XCTAssertNotNil(canvas.undoManager)
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

    func testNativeCustomItemDrawingRequestSurvivesCapacityResume() async throws {
        let pen = PKToolPickerInkingItem(type: .pen, color: .black, width: 3, identifier: "test.pen")
        var configuration = PKToolPickerCustomItem.Configuration(identifier: "test.inspect", name: "Inspect")
        configuration.imageProvider = { _ in UIImage(systemName: "hand.draw")! }
        let custom = PKToolPickerCustomItem(configuration: configuration)
        let picker = PKToolPicker(toolItems: [pen, custom])
        let controller = NotebookViewController(
            pageCount: 3, initialDrawing: PKDrawing(), toolPicker: picker
        )
        let window = try await present(controller)
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

    func testFailureRecoveryAndReadOnlyHidePaletteAndResignResponder() async throws {
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing())
        let window = try await present(controller)
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
            XCTAssertFalse(controller.drawingToolPicker?.isVisible == true)
            XCTAssertFalse(controller.canvasView.isDrawingEnabled)
            XCTAssertTrue(controller.canvasView.panGestureRecognizer.isEnabled)
            XCTAssertTrue(controller.canvasView.pinchGestureRecognizer?.isEnabled == true)
        }
        controller.setInputGate(.failed)
        XCTAssertTrue(controller.canvasView.becomeFirstResponder())
        XCTAssertTrue(controller.canvasView.isFirstResponder)
        controller.setInputGate(.recovering)
        XCTAssertFalse(controller.canvasView.isFirstResponder)
        XCTAssertFalse(controller.drawingToolPicker?.isVisible == true)
        XCTAssertFalse(controller.canvasView.isDrawingEnabled)
        XCTAssertTrue(controller.canvasView.becomeFirstResponder())
        XCTAssertTrue(controller.canvasView.isFirstResponder)
        controller.setInputGate(.recovering)
        XCTAssertFalse(controller.canvasView.isFirstResponder)
        XCTAssertFalse(controller.drawingToolPicker?.isVisible == true)
        XCTAssertFalse(controller.canvasView.isDrawingEnabled)
    }

    func testObservedStatesDuringToolUseKeepGenerationsAndDeferCapacityDisableUntilEnd() async throws {
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing())
        let window = try await present(controller)
        defer { window.isHidden = true }
        var observations: [NotebookCanvasObservation] = []
        controller.onObservation = {
            observations.append($0)
            return .capacity
        }
        let canvas = controller.canvasView
        // This fixture controls callback delivery independently of SDK assignment notifications.
        canvas.delegate = nil
        controller.canvasViewDidBeginUsingTool(canvas)
        let stroke = NotebookTestFixtures.stroke()
        canvas.drawing = PKDrawing(strokes: [stroke])
        controller.canvasViewDrawingDidChange(canvas)
        var moved = stroke
        moved.transform = CGAffineTransform(translationX: 30, y: 40)
        canvas.drawing = PKDrawing(strokes: [moved])
        controller.canvasViewDrawingDidChange(canvas)
        XCTAssertEqual(observations.map(\.generation), [1, 2])
        XCTAssertEqual(observations[0].drawing.strokes[0].transform, stroke.transform)
        XCTAssertEqual(observations[1].drawing.strokes[0].transform, moved.transform)
        XCTAssertLessThanOrEqual(observations[0].capturedAt, observations[1].capturedAt)
        XCTAssertLessThanOrEqual(observations[0].uptime, observations[1].uptime)
        XCTAssertEqual(controller.inputGate, .capacity)
        XCTAssertTrue(canvas.isDrawingEnabled)
        XCTAssertTrue(canvas.drawingGestureRecognizer.isEnabled)
        XCTAssertNotNil(canvas.undoManager)
        XCTAssertFalse(canvas.canPerformAction(NSSelectorFromString("paste:"), withSender: nil))
        controller.setInputGate(.failed)
        XCTAssertTrue(canvas.isDrawingEnabled)
        XCTAssertTrue(canvas.drawingGestureRecognizer.isEnabled)
        XCTAssertTrue(canvas.isFirstResponder)
        XCTAssertTrue(controller.drawingToolPicker?.isVisible == true)
        controller.canvasViewDidEndUsingTool(canvas)
        XCTAssertFalse(canvas.isDrawingEnabled)
        XCTAssertFalse(canvas.drawingGestureRecognizer.isEnabled)
        XCTAssertEqual(observations.count, 2)
        XCTAssertFalse(canvas.isFirstResponder)
        XCTAssertFalse(controller.drawingToolPicker?.isVisible == true)
        controller.tearDown()
        XCTAssertEqual(observations.count, 2)
    }

    func testOmittedEndCallbackAndLateNextToolCallbackRemainDistinctObservedStates() {
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing())
        controller.loadViewIfNeeded()
        var observations: [NotebookCanvasObservation] = []
        controller.onObservation = {
            observations.append($0)
            return .open
        }
        let canvas = controller.canvasView
        // Omit assignment notifications to exercise the end and flush barriers explicitly.
        canvas.delegate = nil
        let stroke = NotebookTestFixtures.stroke()
        controller.canvasViewDidBeginUsingTool(canvas)
        canvas.drawing = PKDrawing(strokes: [stroke])
        controller.canvasViewDidEndUsingTool(canvas)
        XCTAssertEqual(observations.map(\.generation), [1])
        controller.canvasViewDidBeginUsingTool(canvas)
        var masked = stroke
        masked.mask = UIBezierPath(rect: CGRect(x: 20, y: 30, width: 12, height: 25))
        canvas.drawing = PKDrawing(strokes: [masked])
        controller.canvasViewDrawingDidChange(canvas)
        XCTAssertEqual(observations.map(\.generation), [1, 2])
        XCTAssertNil(observations[0].drawing.strokes[0].mask)
        XCTAssertEqual(observations[1].drawing.strokes[0].mask?.cgPath, masked.mask?.cgPath)
        var moved = masked
        moved.transform = CGAffineTransform(translationX: 50, y: 10)
        canvas.drawing = PKDrawing(strokes: [moved])
        _ = controller.captureBarrier()
        XCTAssertEqual(observations.map(\.generation), [1, 2, 3])
        controller.canvasViewDidEndUsingTool(canvas)
        controller.tearDown()
        XCTAssertEqual(observations.count, 3)
        XCTAssertGreaterThan(controller.barrierSignatureChecks, 0)
        let metrics = try? JSONSerialization.data(
            withJSONObject: controller.observationWork.values, options: [.sortedKeys]
        )
        if let metrics { print("NOTTY_BARRIER_METRIC \(String(decoding: metrics, as: UTF8.self))") }
    }

    private func present(_ controller: NotebookViewController) async throws -> UIWindow {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1_024, height: 1_366)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !controller.isCanvasVisible || controller.view.window !== window
                || controller.drawingToolPicker?.isVisible != true || !controller.canvasView.isFirstResponder {
                guard ContinuousClock.now < deadline else {
                    XCTFail("The scene-backed canvas did not become visible and ready.")
                    throw FixtureFailure.readiness
                }
                try await Task.sleep(for: .milliseconds(5))
            }
        } catch {
            controller.tearDown()
            window.isHidden = true
            window.rootViewController = nil
            throw error
        }
        return window
    }

    private enum FixtureFailure: Error { case readiness }
}
