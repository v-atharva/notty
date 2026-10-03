import NottyCore
import PencilKit
import UIKit
import XCTest
@testable import Notty

@MainActor
final class NotebookWritingComfortTests: XCTestCase {
    func testSimulatorAcceptsNativeDrawingInput() throws {
        let fixture = try presentController()
        defer { fixture.close() }
        #if targetEnvironment(simulator)
        XCTAssertEqual(fixture.controller.canvasView.drawingPolicy, .anyInput)
        #else
        XCTAssertEqual(fixture.controller.canvasView.drawingPolicy, .pencilOnly)
        #endif
    }

    func testMinimumZoomCanShowAnEntireA4Section() throws {
        let fixture = try presentController()
        defer { fixture.close() }
        let canvas = fixture.controller.canvasView
        let page = PaperGeometry(pageWidth: 794)
        XCTAssertGreaterThan(canvas.bounds.width, 0)
        XCTAssertGreaterThan(canvas.bounds.height, 0)
        XCTAssertLessThanOrEqual(canvas.minimumZoomScale, canvas.bounds.width / 794 * 0.5 + 0.001)
        canvas.setZoomScale(canvas.minimumZoomScale, animated: false)
        XCTAssertLessThanOrEqual(CGFloat(page.pageHeight) * canvas.zoomScale, canvas.bounds.height + 0.5)
    }

    func testCapacityKeepsTheRealUndoManagerAvailable() throws {
        let fixture = try presentController()
        defer { fixture.close() }
        let manager = try XCTUnwrap(fixture.controller.canvasView.undoManager)
        fixture.controller.setInputGate(.capacity)
        let pausedManager = try XCTUnwrap(fixture.controller.canvasView.undoManager)
        XCTAssertTrue(manager === pausedManager)
        XCTAssertFalse(fixture.controller.canvasView.drawingGestureRecognizer.isEnabled)
    }

    func testTeardownEndsActiveToolBeforeApplyingClosedAdmission() throws {
        let fixture = try presentController()
        defer { fixture.close() }
        let controller = fixture.controller
        controller.canvasViewDidBeginUsingTool(controller.canvasView)
        controller.setInputGate(.failed)
        XCTAssertTrue(controller.canvasView.drawingGestureRecognizer.isEnabled)
        controller.tearDown()
        XCTAssertFalse(controller.canvasView.drawingGestureRecognizer.isEnabled)
        XCTAssertFalse(controller.canvasView.isDrawingEnabled)
    }

    func testTeardownClearsTheActualUndoAndRedoStacks() throws {
        let fixture = try presentController()
        defer { fixture.close() }
        let manager = try XCTUnwrap(fixture.controller.canvasView.undoManager)
        manager.removeAllActions()
        let target = UndoTarget()
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: target) { $0.calls += 1 }
        manager.endUndoGrouping()
        XCTAssertTrue(manager.canUndo)
        fixture.controller.tearDown()
        XCTAssertFalse(manager.canUndo)
        XCTAssertFalse(manager.canRedo)
        XCTAssertEqual(target.calls, 0)
    }

    private func presentController() throws -> Fixture {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let picker = PKToolPicker()
        picker.stateAutosaveName = nil
        let controller = NotebookViewController(
            pageCount: 3, initialDrawing: PKDrawing(), toolPicker: picker
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1_366, height: 1_024)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return Fixture(controller: controller, window: window)
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

    @MainActor
    private final class UndoTarget {
        var calls = 0
    }
}
