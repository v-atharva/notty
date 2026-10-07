import Combine
import NottyCore
import PencilKit
import SwiftUI
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
        XCTAssertEqual(firstPaused, firstBefore, "N1: a pause resigns first responder, disabling the toolbar")
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
        let store = try XCTUnwrap(controller.drawingToolStore)
        canvas.setZoomScale(
            min(canvas.minimumZoomScale * 1.25, canvas.maximumZoomScale), animated: false
        )
        canvas.setContentOffset(CGPoint(x: 80, y: 300), animated: false)
        let offset = canvas.contentOffset
        let insets = canvas.contentInset
        let indicatorInsets = canvas.verticalScrollIndicatorInsets
        let scale = canvas.zoomScale
        let initialDrawing = canvas.drawing
        let toolbarAvailable = store.isToolbarAvailable
        XCTAssertTrue(toolbarAvailable)
        XCTAssertTrue(canvas.isFirstResponder)
        for _ in 0..<20 {
            controller.setInputGate(.capacity)
            controller.setInputGate(.capacity)
            XCTAssertTrue(canvas.isFirstResponder)
            XCTAssertFalse(canvas.isDrawingEnabled)
            XCTAssertFalse(canvas.drawingGestureRecognizer.isEnabled)
            XCTAssertNotNil(canvas.undoManager)
            XCTAssertEqual(store.isToolbarAvailable, toolbarAvailable)
            XCTAssertEqual(canvas.contentInset, insets)
            XCTAssertEqual(canvas.verticalScrollIndicatorInsets, indicatorInsets)
            XCTAssertEqual(canvas.contentOffset, offset)
            XCTAssertEqual(canvas.zoomScale, scale, accuracy: 0.001)
            controller.setInputGate(.open)
            controller.setInputGate(.open)
            XCTAssertTrue(canvas.isFirstResponder)
            XCTAssertTrue(canvas.isDrawingEnabled)
            XCTAssertEqual(store.isToolbarAvailable, toolbarAvailable)
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
        let controller = NotebookViewController(
            pageCount: 3, initialDrawing: drawing, toolStore: NotebookTestFixtures.toolStore()
        )
        let window = try await present(controller)
        defer {
            controller.tearDown()
            window.isHidden = true
        }
        let canvas = controller.canvasView
        let store = try XCTUnwrap(controller.drawingToolStore)
        let originalTool = store.tool.kind
        let initialDrawing = canvas.drawing
        let tools: [EditorToolKind] = EditorInkFamily.allCases.map { .ink($0) } + [.eraser(.vector), .eraser(.bitmap), .lasso]
        // Start away from the first choice so every selection below is a real change.
        store.update { $0.select(.lasso) }
        controller.setInputGate(.capacity)
        for kind in tools {
            store.update { $0.select(kind) }
            await Task.yield()
            XCTAssertEqual(store.tool.kind, kind)
            assertCanvasTool(canvas, is: kind, "a capacity pause still delivers the chosen native tool")
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
        store.update { $0.select(originalTool) }
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

    func testCanvasDrawingPauseRequestSurvivesToolChoicesAndCapacityResume() async throws {
        let store = NotebookTestFixtures.toolStore()
        let controller = NotebookViewController(
            pageCount: 3, initialDrawing: PKDrawing(), toolStore: store
        )
        let window = try await present(controller)
        let canvas = controller.canvasView
        defer {
            controller.tearDown()
            window.isHidden = true
        }
        controller.setInputGate(.capacity)
        canvas.isDrawingEnabled = false
        store.update { $0.select(.lasso) }
        XCTAssertTrue(canvas.tool is PKLassoTool)
        XCTAssertFalse(canvas.isDrawingEnabled)
        store.update { $0.isRulerActive = true }
        XCTAssertTrue(canvas.isRulerActive)
        XCTAssertFalse(canvas.isDrawingEnabled)
        store.update { $0.select(.ink(.marker)) }
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, .marker)
        XCTAssertFalse(canvas.isDrawingEnabled)
        controller.setInputGate(.open)
        XCTAssertFalse(canvas.isDrawingEnabled, "reopening the gate must not override a requested drawing pause")
        XCTAssertFalse(canvas.drawingGestureRecognizer.isEnabled)
        XCTAssertTrue(canvas.isFirstResponder)
        store.update { $0.select(.ink(.pen)) }
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, .pen)
        XCTAssertFalse(canvas.isDrawingEnabled, "a tool choice must not override a requested drawing pause")
        controller.setInputGate(.capacity)
        canvas.isDrawingEnabled = true
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
            XCTAssertFalse(controller.drawingToolStore?.isToolbarAvailable == true)
            XCTAssertFalse(controller.canvasView.isDrawingEnabled)
            XCTAssertTrue(controller.canvasView.panGestureRecognizer.isEnabled)
            XCTAssertTrue(controller.canvasView.pinchGestureRecognizer?.isEnabled == true)
        }
        controller.setInputGate(.failed)
        XCTAssertTrue(controller.canvasView.becomeFirstResponder())
        XCTAssertTrue(controller.canvasView.isFirstResponder)
        controller.setInputGate(.recovering)
        XCTAssertFalse(controller.canvasView.isFirstResponder)
        XCTAssertFalse(controller.drawingToolStore?.isToolbarAvailable == true)
        XCTAssertFalse(controller.canvasView.isDrawingEnabled)
        XCTAssertTrue(controller.canvasView.becomeFirstResponder())
        XCTAssertTrue(controller.canvasView.isFirstResponder)
        controller.setInputGate(.recovering)
        XCTAssertFalse(controller.canvasView.isFirstResponder)
        XCTAssertFalse(controller.drawingToolStore?.isToolbarAvailable == true)
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
        XCTAssertTrue(controller.drawingToolStore?.isToolbarAvailable == false)
        controller.canvasViewDidEndUsingTool(canvas)
        XCTAssertFalse(canvas.isDrawingEnabled)
        XCTAssertFalse(canvas.drawingGestureRecognizer.isEnabled)
        XCTAssertEqual(observations.count, 2)
        XCTAssertFalse(canvas.isFirstResponder)
        XCTAssertFalse(controller.drawingToolStore?.isToolbarAvailable == true)
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

    func testToolChangeDuringActiveStrokeAppliesAfterTheStrokeEnds() async throws {
        let store = NotebookTestFixtures.toolStore()
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), toolStore: store)
        let window = try await present(controller)
        defer {
            controller.tearDown()
            window.isHidden = true
        }
        let canvas = controller.canvasView
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, .pen)
        controller.canvasViewDidBeginUsingTool(canvas)
        store.update { $0.select(.ink(.marker)) }
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, .pen, "the stroke in progress keeps its tool")
        controller.canvasViewDidEndUsingTool(canvas)
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, .marker)
    }

    func testRetiredControllerIgnoresLaterToolChanges() async throws {
        let store = NotebookTestFixtures.toolStore()
        let first = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), toolStore: store)
        let firstWindow = try await present(first)
        let second = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), toolStore: store)
        let secondWindow = try await present(second)
        defer {
            first.tearDown()
            second.tearDown()
            firstWindow.isHidden = true
            secondWindow.isHidden = true
        }
        XCTAssertFalse(store.belongs(to: first))
        XCTAssertTrue(store.belongs(to: second))
        store.update { $0.select(.lasso) }
        XCTAssertTrue(second.canvasView.tool is PKLassoTool)
        XCTAssertFalse(first.canvasView.tool is PKLassoTool)
        first.applyTool(store.tool)
        XCTAssertFalse(first.canvasView.tool is PKLassoTool, "a retired controller never takes a later tool")
    }

    func testStoredToolRestoresOnFirstAcquire() async throws {
        let suite = NotebookTestFixtures.temporaryDefaultsSuite()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        var stored = EditorToolState.standard
        stored.select(.ink(.marker))
        stored.widthStep = .bold
        defaults.set(stored.encoded(), forKey: "notty.editor.tool." + suite)
        let store = NotebookSceneToolStore(identifier: suite, defaults: defaults)
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), toolStore: store)
        let window = try await present(controller)
        defer {
            controller.tearDown()
            window.isHidden = true
        }
        let tool = try XCTUnwrap(controller.canvasView.tool as? PKInkingTool)
        let expected = try XCTUnwrap(stored.nativeTool as? PKInkingTool)
        XCTAssertEqual(tool.inkType, .marker)
        XCTAssertEqual(tool.width, expected.width, accuracy: 0.001)
    }

    func testCorruptStoredToolAndToolbarOpenWithDefaults() async throws {
        let suite = NotebookTestFixtures.temporaryDefaultsSuite()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(Data("not a tool".utf8), forKey: "notty.editor.tool." + suite)
        defaults.set(Data("not a toolbar".utf8), forKey: NotebookSceneToolStore.toolbarDefaultsKey)
        let store = NotebookSceneToolStore(identifier: suite, defaults: defaults)
        XCTAssertEqual(store.tool, .standard)
        XCTAssertEqual(store.toolbar, .standard)
        let fixture = try await NotebookTestFixtures.mountToolbarHost(store: store)
        defer { fixture.close() }
        let controller = fixture.controller
        XCTAssertTrue(controller.isCanvasVisible)
        XCTAssertTrue(store.isToolbarAvailable)
        XCTAssertEqual((controller.canvasView.tool as? PKInkingTool)?.inkType, EditorToolState.standard.inkFamily?.inkType)
        XCTAssertEqual(fixture.canvasFrame.minY, 0, accuracy: 0.5, "the standard anchor overlays the canvas")
        XCTAssertEqual(fixture.canvasFrame.maxY, fixture.host.bounds.maxY, accuracy: 0.5)
    }

    func testCorruptLastToolSeedsANewSceneWithDefaults() throws {
        let suite = NotebookTestFixtures.temporaryDefaultsSuite()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(Data("not a tool".utf8), forKey: NotebookSceneToolStore.lastToolDefaultsKey)
        let store = NotebookSceneToolStore(identifier: UUID().uuidString, defaults: defaults)
        XCTAssertEqual(store.tool, .standard)
        XCTAssertEqual(store.toolbar, .standard)
    }

    func testToolChoiceIsStoredForTheSceneAndSeedsNewScenes() throws {
        let suite = NotebookTestFixtures.temporaryDefaultsSuite()
        let defaults = try XCTUnwrap(CountingDefaults(suiteName: suite))
        let store = NotebookSceneToolStore(identifier: "scene-a", defaults: defaults)
        store.update { state in
            state.select(.ink(.marker))
            state.widthStep = .bold
            state.isRulerActive = true
        }
        store.update { $0.select(.ink(.marker)) }
        XCTAssertEqual(defaults.writes[store.toolDefaultsKey], 1, "an unchanged choice is not written again")
        XCTAssertEqual(defaults.writes[NotebookSceneToolStore.lastToolDefaultsKey], 1)
        // The Pencil's return-to-previous-tool history lasts only for the session; the rest is stored.
        let stored = EditorToolState.decode(store.tool.encoded())
        XCTAssertEqual(stored.kind, .ink(.marker))
        XCTAssertEqual(stored.widthStep, .bold)
        XCTAssertTrue(stored.isRulerActive)
        XCTAssertEqual(EditorToolState.decode(defaults.data(forKey: store.toolDefaultsKey)), stored)
        XCTAssertEqual(EditorToolState.decode(defaults.data(forKey: NotebookSceneToolStore.lastToolDefaultsKey)), stored)

        let reopened = NotebookSceneToolStore(identifier: "scene-a", defaults: defaults)
        XCTAssertEqual(reopened.tool, stored)
        let newScene = NotebookSceneToolStore(identifier: "scene-b", defaults: defaults)
        XCTAssertEqual(newScene.tool, stored, "a scene with no stored tool starts from the last choice")
        XCTAssertNil(defaults.data(forKey: newScene.toolDefaultsKey))

        newScene.update { $0.select(.lasso) }
        XCTAssertEqual(NotebookSceneToolStore(identifier: "scene-a", defaults: defaults).tool, stored)
        XCTAssertEqual(NotebookSceneToolStore(identifier: "scene-c", defaults: defaults).tool.kind, .lasso)
    }

    func testSettledToolbarDragIsStoredExactlyOnce() throws {
        let suite = NotebookTestFixtures.temporaryDefaultsSuite()
        let defaults = try XCTUnwrap(CountingDefaults(suiteName: suite))
        let store = NotebookSceneToolStore(identifier: suite, defaults: defaults)
        let owner = NotebookViewController(pageCount: 1, initialDrawing: PKDrawing())
        store.attach(owner)
        store.setToolbarAvailable(true, for: owner)
        let actions = NotebookToolbarActions(store: store)
        let resolver = NotebookToolbarDragResolver(
            placement: store.toolbar.placement, size: CGSize(width: 480, height: 60),
            usable: CGRect(x: 0, y: 0, width: 1_024, height: 1_200)
        )
        let session = NotebookToolbarDragSession()
        let translation = CGSize(width: -120, height: 640)
        for step in 1...10 {
            let fraction = CGFloat(step) / 10
            session.move(
                to: CGSize(width: translation.width * fraction, height: translation.height * fraction),
                resolver: resolver
            )
        }
        XCTAssertNil(defaults.writes[NotebookSceneToolStore.toolbarDefaultsKey], "moves only update the preview")
        let placement = try XCTUnwrap(session.end(at: translation, resolver: resolver, actions: actions))
        guard case .floating = placement else { return XCTFail("A drag into the page floats the toolbar.") }
        // SwiftUI may deliver the end again through the gesture's own resolver after the session resets.
        XCTAssertEqual(session.end(at: translation, resolver: resolver, actions: actions), placement)

        XCTAssertEqual(defaults.writes[NotebookSceneToolStore.toolbarDefaultsKey], 1)
        XCTAssertEqual(
            EditorToolbarPreferences.decode(defaults.data(forKey: NotebookSceneToolStore.toolbarDefaultsKey)),
            store.toolbar
        )
        XCTAssertEqual(NotebookSceneToolStore(identifier: UUID().uuidString, defaults: defaults).toolbar.placement, placement)
        owner.tearDown()
    }

    func testPruningStoredToolsKeepsOpenScenesAndTheLastChoice() throws {
        let suite = NotebookTestFixtures.temporaryDefaultsSuite()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let tool = EditorToolState.standard.encoded()
        for key in ["notty.editor.tool.open", "notty.editor.tool.discarded", NotebookSceneToolStore.lastToolDefaultsKey] {
            defaults.set(tool, forKey: key)
        }
        defaults.set(Data([1]), forKey: NotebookSceneToolStore.toolbarDefaultsKey)
        defaults.set("kept", forKey: "notty.editor.toolbox")
        NotebookSceneToolStore.pruneStoredTools(in: defaults, keepingSessions: ["open"])
        XCTAssertNotNil(defaults.data(forKey: "notty.editor.tool.open"))
        XCTAssertNil(defaults.object(forKey: "notty.editor.tool.discarded"))
        XCTAssertNotNil(defaults.data(forKey: NotebookSceneToolStore.lastToolDefaultsKey))
        XCTAssertNotNil(defaults.data(forKey: NotebookSceneToolStore.toolbarDefaultsKey))
        XCTAssertEqual(defaults.string(forKey: "notty.editor.toolbox"), "kept")
    }

    func testAttachAndDetachPublishOnlyRealChanges() {
        let store = NotebookTestFixtures.toolStore()
        let controller = NotebookViewController(pageCount: 1, initialDrawing: PKDrawing())
        let other = NotebookViewController(pageCount: 1, initialDrawing: PKDrawing())
        let changes = ChangeCounter(store)
        store.attach(controller)
        store.detach(controller)
        XCTAssertEqual(changes.count, 0, "an unavailable toolbar stays unavailable without a change notification")
        store.attach(controller)
        store.setToolbarAvailable(true, for: controller)
        XCTAssertEqual(changes.count, 1)
        store.setToolActive(true, for: controller)
        XCTAssertTrue(store.isToolActive)
        XCTAssertEqual(changes.count, 1, "a pen going down never invalidates the views that show the tools")
        store.setToolActive(true, for: other)
        store.setToolActive(false, for: other)
        XCTAssertTrue(store.isToolActive, "only the owning canvas reports tool use")
        store.setToolActive(false, for: controller)
        XCTAssertFalse(store.isToolActive)
        store.setToolActive(true, for: controller)
        XCTAssertEqual(changes.count, 1, "nor does a pen coming up")
        store.detach(controller)
        XCTAssertEqual(changes.count, 2)
        XCTAssertFalse(store.isToolbarAvailable)
        XCTAssertFalse(store.isToolActive, "detaching ends the owner's tool use")
        store.detach(controller)
        store.attach(controller)
        XCTAssertEqual(changes.count, 2)
        store.setToolActive(true, for: controller)
        store.attach(other)
        XCTAssertFalse(store.isToolActive, "a new owner starts without tool use")
        XCTAssertEqual(changes.count, 2)
        store.setOverlayObstruction(UIEdgeInsets(top: 0, left: 0, bottom: 80, right: 0))
        XCTAssertEqual(changes.count, 2, "the obstruction goes to the canvas, not to the toolbar's views")
        other.tearDown()
        controller.tearDown()
    }

    func testCanvasResolvesLightAppearanceInADarkWindow() async throws {
        let controller = NotebookViewController(
            pageCount: 3, initialDrawing: PKDrawing(), toolStore: NotebookTestFixtures.toolStore()
        )
        let window = try await present(controller)
        defer {
            controller.tearDown()
            window.isHidden = true
        }
        window.overrideUserInterfaceStyle = .dark
        controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.canvasView.traitCollection.userInterfaceStyle, .light)
    }

    func testPresetChangesOnlySubsequentInk() async throws {
        let existing = NotebookTestFixtures.stroke()
        let store = NotebookTestFixtures.toolStore()
        let controller = NotebookViewController(
            pageCount: 3, initialDrawing: PKDrawing(strokes: [existing]), toolStore: store
        )
        let window = try await present(controller)
        defer {
            controller.tearDown()
            window.isHidden = true
        }
        let preset = try XCTUnwrap(EditorInkCatalog.presets.first { $0.family == .fountainPen })
        store.update { $0.apply(preset) }
        XCTAssertEqual((controller.canvasView.tool as? PKInkingTool)?.inkType, .fountainPen)
        let stroke = try XCTUnwrap(controller.canvasView.drawing.strokes.first)
        XCTAssertEqual(stroke.ink.inkType, existing.ink.inkType)
        XCTAssertEqual(stroke.ink.color, existing.ink.color)
        XCTAssertEqual(controller.canvasView.drawing.strokes.map(\.id), [existing.id])
    }

    func testEditingCanvasInstallsOnePencilInteractionUntilTearDown() async throws {
        let controller = NotebookViewController(
            pageCount: 3, initialDrawing: PKDrawing(), toolStore: NotebookTestFixtures.toolStore()
        )
        let window = try await present(controller)
        defer { window.isHidden = true }
        let interactions = pencilInteractions(on: controller.canvasView)
        XCTAssertEqual(interactions.count, 1)
        XCTAssertTrue(interactions.first?.delegate === controller)
        controller.tearDown()
        XCTAssertTrue(pencilInteractions(on: controller.canvasView).isEmpty)
    }

    func testCanvasLoadedAfterTearDownInstallsNoPencilInteraction() {
        let controller = NotebookViewController(
            pageCount: 3,
            initialDrawing: PKDrawing(),
            toolStore: NotebookTestFixtures.toolStore()
        )
        controller.tearDown()
        controller.loadViewIfNeeded()
        XCTAssertTrue(pencilInteractions(on: controller.canvasView).isEmpty)
    }

    func testReadOnlyCanvasInstallsNoPencilInteraction() {
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), allowsEditing: false)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        controller.view.layoutIfNeeded()
        XCTAssertTrue(pencilInteractions(on: controller.canvasView).isEmpty)
        controller.tearDown()
    }

    func testPencilSwitchEraserTogglesBetweenEraserAndInk() async throws {
        let store = NotebookTestFixtures.toolStore()
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), toolStore: store)
        let window = try await present(controller)
        defer {
            controller.tearDown()
            window.isHidden = true
        }
        let canvas = controller.canvasView
        let ink = store.tool.kind
        controller.handlePencilPreference(.switchEraser)
        XCTAssertEqual(store.tool.kind, .eraser(.vector))
        XCTAssertTrue(canvas.tool is PKEraserTool)
        controller.handlePencilPreference(.switchEraser)
        XCTAssertEqual(store.tool.kind, ink)
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, .pen)
    }

    func testPencilGestureDuringCapacityChangesToolButKeepsDrawingPaused() async throws {
        let store = NotebookTestFixtures.toolStore()
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), toolStore: store)
        let window = try await present(controller)
        defer {
            controller.tearDown()
            window.isHidden = true
        }
        let canvas = controller.canvasView
        controller.setInputGate(.capacity)
        XCTAssertTrue(store.isToolbarAvailable)
        controller.handlePencilPreference(.switchEraser)
        XCTAssertEqual(store.tool.kind, .eraser(.vector))
        XCTAssertTrue(canvas.tool is PKEraserTool)
        XCTAssertFalse(canvas.isDrawingEnabled)
        XCTAssertFalse(canvas.drawingGestureRecognizer.isEnabled)
        XCTAssertEqual(controller.inputGate, .capacity)
    }

    func testPencilGestureIsIgnoredWhileSuppressedOrPaused() async throws {
        let store = NotebookTestFixtures.toolStore()
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), toolStore: store)
        let window = try await present(controller)
        defer {
            controller.tearDown()
            window.isHidden = true
        }
        let canvas = controller.canvasView
        let tool = store.tool
        let reveals = store.revealRequest

        controller.setPaletteSuppressed(true)
        XCTAssertFalse(store.isToolbarAvailable)
        controller.handlePencilPreference(.switchEraser)
        controller.handlePencilPreference(.showColorPalette)
        XCTAssertEqual(store.tool, tool)
        XCTAssertEqual(store.revealRequest, reveals)
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, .pen)
        controller.setPaletteSuppressed(false)

        for gate in [NotebookInputGate.failed, .recovering, .readOnly] {
            controller.setInputGate(.open)
            XCTAssertTrue(store.isToolbarAvailable)
            controller.setInputGate(gate)
            XCTAssertFalse(store.isToolbarAvailable)
            controller.handlePencilPreference(.switchEraser)
            controller.handlePencilPreference(.showContextualPalette)
            XCTAssertEqual(store.tool, tool, "\(gate)")
            XCTAssertEqual(store.revealRequest, reveals, "\(gate)")
            XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, .pen, "\(gate)")
        }
    }

    func testGateClosingDuringAStrokeWithdrawsToolChoicesAtOnceButKeepsTheResponder() async throws {
        let closures: [(String, (NotebookViewController) -> Void)] = [
            ("failed", { $0.setInputGate(.failed) }),
            ("recovering", { $0.setInputGate(.recovering) }),
            ("readOnly", { $0.setInputGate(.readOnly) }),
            ("suppressed", { $0.setPaletteSuppressed(true) })
        ]
        for (name, close) in closures {
            let store = NotebookTestFixtures.toolStore()
            let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), toolStore: store)
            let window = try await present(controller)
            let canvas = controller.canvasView
            let tool = store.tool
            let reveals = store.revealRequest
            controller.canvasViewDidBeginUsingTool(canvas)
            close(controller)
            XCTAssertFalse(store.isToolbarAvailable, name)
            XCTAssertTrue(canvas.isFirstResponder, name)
            controller.handlePencilPreference(.switchEraser)
            controller.handlePencilPreference(.showColorPalette)
            store.handlePencil(.switchEraser, from: controller)
            XCTAssertTrue(canvas.isFirstResponder, name)
            controller.canvasViewDidEndUsingTool(canvas)
            XCTAssertFalse(canvas.isFirstResponder, name)
            XCTAssertFalse(store.isToolbarAvailable, name)
            XCTAssertEqual(store.tool, tool, name)
            XCTAssertEqual(store.revealRequest, reveals, name)
            XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, .pen, name)
            controller.tearDown()
            window.isHidden = true
        }
    }

    func testPencilGestureActsAgainOnceTheGateReopens() async throws {
        let store = NotebookTestFixtures.toolStore()
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), toolStore: store)
        let window = try await present(controller)
        defer {
            controller.tearDown()
            window.isHidden = true
        }
        let canvas = controller.canvasView
        let reopenings: [(String, () -> Void, () -> Void)] = [
            ("suppressed", { controller.setPaletteSuppressed(true) }, { controller.setPaletteSuppressed(false) }),
            ("failed", { controller.setInputGate(.failed) }, { controller.setInputGate(.open) }),
            ("recovering", { controller.setInputGate(.recovering) }, { controller.setInputGate(.open) }),
            ("readOnly", { controller.setInputGate(.readOnly) }, { controller.setInputGate(.open) })
        ]
        for (name, close, reopen) in reopenings {
            close()
            controller.handlePencilPreference(.switchEraser)
            XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, .pen, name)
            reopen()
            controller.handlePencilPreference(.switchEraser)
            XCTAssertTrue(canvas.tool is PKEraserTool, name)
            controller.handlePencilPreference(.switchEraser)
            XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, .pen, name)

            controller.canvasViewDidBeginUsingTool(canvas)
            close()
            reopen()
            XCTAssertFalse(store.isToolbarAvailable, "\(name): restored only when the stroke ends")
            controller.canvasViewDidEndUsingTool(canvas)
            XCTAssertTrue(store.isToolbarAvailable, name)
            XCTAssertTrue(canvas.isFirstResponder, name)
            controller.handlePencilPreference(.switchEraser)
            XCTAssertTrue(canvas.tool is PKEraserTool, name)
            controller.handlePencilPreference(.switchEraser)
            XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, .pen, name)
        }
    }

    func testRetiredControllerPencilGestureLeavesTheReplacementUntouched() async throws {
        let store = NotebookTestFixtures.toolStore()
        let retired = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), toolStore: store)
        let retiredWindow = try await present(retired)
        let replacement = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), toolStore: store)
        let window = try await present(replacement)
        defer {
            retired.tearDown()
            replacement.tearDown()
            retiredWindow.isHidden = true
            window.isHidden = true
        }
        XCTAssertTrue(pencilInteractions(on: retired.canvasView).isEmpty)
        XCTAssertEqual(pencilInteractions(on: replacement.canvasView).count, 1)
        let tool = store.tool
        retired.handlePencilPreference(.switchEraser)
        XCTAssertEqual(store.tool, tool)
        XCTAssertEqual((replacement.canvasView.tool as? PKInkingTool)?.inkType, .pen)
        replacement.handlePencilPreference(.switchEraser)
        XCTAssertTrue(replacement.canvasView.tool is PKEraserTool)
    }

    func testPencilGestureAfterTearDownChangesNothing() async throws {
        let store = NotebookTestFixtures.toolStore()
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), toolStore: store)
        let window = try await present(controller)
        defer { window.isHidden = true }
        let tool = store.tool
        let reveals = store.revealRequest
        controller.tearDown()
        controller.handlePencilPreference(.switchEraser)
        controller.handlePencilPreference(.showInkAttributes)
        XCTAssertEqual(store.tool, tool)
        XCTAssertEqual(store.revealRequest, reveals)
        XCTAssertEqual((controller.canvasView.tool as? PKInkingTool)?.inkType, .pen)
    }

    func testPencilGestureDuringActiveStrokeAppliesAfterTheStrokeEnds() async throws {
        let store = NotebookTestFixtures.toolStore()
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), toolStore: store)
        let window = try await present(controller)
        defer {
            controller.tearDown()
            window.isHidden = true
        }
        let canvas = controller.canvasView
        controller.canvasViewDidBeginUsingTool(canvas)
        controller.handlePencilPreference(.switchEraser)
        XCTAssertEqual(store.tool.kind, .eraser(.vector))
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, .pen, "the stroke in progress keeps its tool")
        controller.canvasViewDidEndUsingTool(canvas)
        XCTAssertTrue(canvas.tool is PKEraserTool)
    }

    func testPencilRevealPreferencesRequestToolsWithoutChangingTheTool() async throws {
        let store = NotebookTestFixtures.toolStore()
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), toolStore: store)
        let window = try await present(controller)
        defer {
            controller.tearDown()
            window.isHidden = true
        }
        let tool = store.tool
        var reveals = store.revealRequest
        for preference in [EditorPencilTapPreference.showColorPalette, .showInkAttributes, .showContextualPalette] {
            controller.handlePencilPreference(preference)
            XCTAssertEqual(store.revealRequest, reveals + 1, "\(preference)")
            XCTAssertEqual(store.tool, tool, "\(preference)")
            reveals = store.revealRequest
        }
        for preference in [EditorPencilTapPreference.ignore, .runSystemShortcut] {
            controller.handlePencilPreference(preference)
            XCTAssertEqual(store.revealRequest, reveals, "\(preference)")
            XCTAssertEqual(store.tool, tool, "\(preference)")
        }
        XCTAssertEqual((controller.canvasView.tool as? PKInkingTool)?.inkType, .pen)
    }

    func testPencilPreferredActionsMapToEditorPreferences() throws {
        let expected: [(UIPencilPreferredAction, EditorPencilTapPreference)] = [
            (.ignore, .ignore),
            (.switchEraser, .switchEraser),
            (.switchPrevious, .switchPrevious),
            (.showColorPalette, .showColorPalette),
            (.showInkAttributes, .showInkAttributes),
            (.showContextualPalette, .showContextualPalette),
            (.runSystemShortcut, .runSystemShortcut)
        ]
        for (action, preference) in expected {
            XCTAssertEqual(EditorPencilTapPreference(action), preference, "\(action.rawValue)")
        }
        let future = try XCTUnwrap(UIPencilPreferredAction(rawValue: 99))
        XCTAssertEqual(EditorPencilTapPreference(future), .ignore)
    }

    func testPencilSqueezeActsOnlyWhenItEnds() {
        for phase in [UIPencilInteraction.Phase.began, .changed, .cancelled] {
            XCTAssertNil(NotebookViewController.squeezePreference(for: phase), "\(phase.rawValue)")
        }
        XCTAssertNotNil(NotebookViewController.squeezePreference(for: .ended), "a completed squeeze acts")
    }

    func testOwningCanvasPublishesToolUseUntilTheStrokeEnds() async throws {
        let store = NotebookTestFixtures.toolStore()
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), toolStore: store)
        let window = try await present(controller)
        defer {
            controller.tearDown()
            window.isHidden = true
        }
        let canvas = controller.canvasView
        XCTAssertFalse(store.isToolActive)
        controller.canvasViewDidBeginUsingTool(canvas)
        XCTAssertTrue(store.isToolActive)
        controller.setInputGate(.capacity)
        XCTAssertTrue(store.isToolActive, "a pause does not end the stroke in progress")
        controller.setInputGate(.open)
        controller.canvasViewDidEndUsingTool(canvas)
        XCTAssertFalse(store.isToolActive)

        let outsider = NotebookViewController(pageCount: 1, initialDrawing: PKDrawing())
        store.setToolActive(true, for: outsider)
        XCTAssertFalse(store.isToolActive, "only the owning canvas reports tool use")
        outsider.tearDown()
    }

    func testToolUseEndsWhenTheCanvasDisappearsOrIsTornDown() async throws {
        let store = NotebookTestFixtures.toolStore()
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), toolStore: store)
        let window = try await present(controller)
        defer {
            controller.tearDown()
            window.isHidden = true
        }
        controller.canvasViewDidBeginUsingTool(controller.canvasView)
        XCTAssertTrue(store.isToolActive)
        controller.beginAppearanceTransition(false, animated: false)
        controller.endAppearanceTransition()
        XCTAssertFalse(store.isToolActive)

        let replacement = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), toolStore: store)
        let replacementWindow = try await present(replacement)
        defer {
            replacement.tearDown()
            replacementWindow.isHidden = true
        }
        replacement.canvasViewDidBeginUsingTool(replacement.canvasView)
        XCTAssertTrue(store.isToolActive)
        replacement.tearDown()
        XCTAssertFalse(store.isToolActive)
    }

    func testFloatingToolbarObstructionLetsThePageEndsScrollClearWithoutMovingThePage() async throws {
        let store = NotebookTestFixtures.toolStore()
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), toolStore: store)
        let window = try await present(controller)
        defer {
            controller.tearDown()
            window.isHidden = true
        }
        let canvas = controller.canvasView
        let horizontal = canvas.contentInset.left
        canvas.setContentOffset(CGPoint(x: -horizontal, y: 400), animated: false)
        let offset = canvas.contentOffset
        let unobstructedEnd = maximumOffsetY(canvas)

        store.setOverlayObstruction(UIEdgeInsets(top: 0, left: 300, bottom: 140, right: 0))
        XCTAssertEqual(canvas.contentInset, UIEdgeInsets(top: 0, left: horizontal, bottom: 140, right: horizontal))
        XCTAssertEqual(canvas.verticalScrollIndicatorInsets.bottom, 140)
        XCTAssertEqual(canvas.contentOffset, offset, "reserving space never moves the visible page")
        XCTAssertEqual(maximumOffsetY(canvas), unobstructedEnd + 140, accuracy: 0.5)

        store.setOverlayObstruction(UIEdgeInsets(top: 90, left: 0, bottom: 0, right: 0))
        XCTAssertEqual(canvas.contentInset.top, 90)
        XCTAssertEqual(canvas.contentInset.bottom, 0)
        XCTAssertEqual(canvas.contentOffset, offset)
        canvas.setContentOffset(CGPoint(x: -horizontal, y: -90), animated: false)
        XCTAssertEqual(canvas.contentOffset.y, -90, "the top of the first page can scroll below the toolbar")

        store.setOverlayObstruction(.zero)
        XCTAssertEqual(canvas.contentInset, UIEdgeInsets(top: 0, left: horizontal, bottom: 0, right: horizontal))
        XCTAssertEqual(canvas.contentOffset.y, 0, accuracy: 0.001, "an offset left outside the smaller range settles at its edge")
        XCTAssertEqual(canvas.verticalScrollIndicatorInsets, .zero)
    }

    func testObstructionAtTheEndOfTheLastPageIsReleasedAfterTheStroke() async throws {
        let store = NotebookTestFixtures.toolStore()
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), toolStore: store)
        let window = try await present(controller)
        defer {
            controller.tearDown()
            window.isHidden = true
        }
        let canvas = controller.canvasView
        store.setOverlayObstruction(UIEdgeInsets(top: 0, left: 0, bottom: 140, right: 0))
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: maximumOffsetY(canvas)), animated: false)
        let end = canvas.contentOffset
        controller.canvasViewDidBeginUsingTool(canvas)
        store.setOverlayObstruction(.zero)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        XCTAssertEqual(canvas.contentInset.bottom, 140, "the space is held until the stroke ends")
        XCTAssertEqual(canvas.contentOffset, end, "the page never moves under a stroke in progress")
        store.setOverlayObstruction(UIEdgeInsets(top: 0, left: 0, bottom: 200, right: 0))
        XCTAssertEqual(canvas.contentInset.bottom, 200, "more space can be reserved at once")
        XCTAssertEqual(canvas.contentOffset, end)
        store.setOverlayObstruction(.zero)
        controller.canvasViewDidEndUsingTool(canvas)
        XCTAssertEqual(canvas.contentInset.bottom, 0)
        XCTAssertEqual(canvas.contentOffset.y, maximumOffsetY(canvas), accuracy: 0.5, "the page settles at its new end")
    }

    func testCanvasAdoptsTheObstructionWhenItAcquiresTheStoreAndAcrossResizes() async throws {
        let store = NotebookTestFixtures.toolStore()
        store.setOverlayObstruction(UIEdgeInsets(top: 0, left: 0, bottom: 120, right: 0))
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), toolStore: store)
        let window = try await present(controller)
        defer {
            controller.tearDown()
            window.isHidden = true
        }
        XCTAssertEqual(controller.canvasView.contentInset.bottom, 120)
        window.frame = CGRect(x: 0, y: 0, width: 1_366, height: 1_024)
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.canvasView.contentInset.bottom, 120)

        let unowned = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing())
        unowned.loadViewIfNeeded()
        unowned.view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        unowned.view.layoutIfNeeded()
        XCTAssertEqual(unowned.canvasView.contentInset.bottom, 0, "a canvas the toolbar is not drawn over keeps its full range")
        unowned.tearDown()
    }

    func testOverlayScrollRangeDoesNotPushThePageBelowTheToolbar() async throws {
        let store = NotebookTestFixtures.toolStore()
        store.setOverlayObstruction(UIEdgeInsets(top: 90, left: 0, bottom: 0, right: 0))
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), toolStore: store)
        let window = try await present(controller)
        defer {
            controller.tearDown()
            window.isHidden = true
        }
        let canvas = controller.canvasView
        XCTAssertEqual(canvas.contentInset.top, 90)
        XCTAssertEqual(canvas.contentOffset.y, 0, "a notebook opens with its first page beneath the toolbar")

        store.setOverlayObstruction(UIEdgeInsets(top: 130, left: 0, bottom: 0, right: 0))
        XCTAssertEqual(canvas.contentInset.top, 130)
        XCTAssertEqual(canvas.contentOffset.y, 0, "adding scroll range keeps the paper behind the overlay")

        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: -130), animated: false)
        store.setOverlayObstruction(UIEdgeInsets(top: 170, left: 0, bottom: 0, right: 0))
        XCTAssertEqual(canvas.contentInset.top, 170)
        XCTAssertEqual(canvas.contentOffset.y, -130, "a toolbar moving down never pushes a revealed page below it")

        // A resize in the order the toolbar host delivers it: the toolbar is re-measured for its
        // new area before the canvas is laid out at its new size.
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: -170), animated: false)
        window.frame = CGRect(x: 0, y: 0, width: 1_024, height: 1_300)
        controller.view.frame = window.bounds
        store.setOverlayObstruction(UIEdgeInsets(top: 200, left: 0, bottom: 0, right: 0), followingResize: true)
        XCTAssertEqual(canvas.contentInset.top, 200)
        XCTAssertEqual(canvas.contentOffset.y, -170, "the re-measure alone never moves the page")
        controller.view.layoutIfNeeded()
        XCTAssertEqual(canvas.contentOffset.y, -200, accuracy: 0.5, "after the resize a revealed page stays revealed")

        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: 300), animated: false)
        store.setOverlayObstruction(UIEdgeInsets(top: 60, left: 0, bottom: 0, right: 0))
        XCTAssertEqual(canvas.contentOffset.y, 300, "a page scrolled away from its top stays where it is")
    }

    func testTopInsetReductionDuringAStrokeWaitsForTheStrokeToEnd() async throws {
        let store = NotebookTestFixtures.toolStore()
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), toolStore: store)
        let window = try await present(controller)
        defer {
            controller.tearDown()
            window.isHidden = true
        }
        let canvas = controller.canvasView
        store.setOverlayObstruction(UIEdgeInsets(top: 130, left: 0, bottom: 0, right: 0))
        let revealed = CGPoint(x: canvas.contentOffset.x, y: -130)
        canvas.setContentOffset(revealed, animated: false)

        controller.canvasViewDidBeginUsingTool(canvas)
        store.setOverlayObstruction(UIEdgeInsets(top: 60, left: 0, bottom: 0, right: 0))
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        XCTAssertEqual(canvas.contentInset.top, 130, "the space is held until the stroke ends")
        XCTAssertEqual(canvas.verticalScrollIndicatorInsets.top, 130)
        XCTAssertEqual(canvas.contentOffset, revealed, "the page never moves under a stroke in progress")

        controller.canvasViewDidEndUsingTool(canvas)
        XCTAssertEqual(canvas.contentInset.top, 60)
        XCTAssertEqual(canvas.verticalScrollIndicatorInsets.top, 60)
        XCTAssertEqual(canvas.contentOffset.x, revealed.x)
        XCTAssertEqual(canvas.contentOffset.y, -60, accuracy: 0.5, "the page moves only onto the new top of its range")

        store.setOverlayObstruction(UIEdgeInsets(top: 130, left: 0, bottom: 0, right: 0))
        canvas.setContentOffset(CGPoint(x: revealed.x, y: 200), animated: false)
        controller.canvasViewDidBeginUsingTool(canvas)
        store.setOverlayObstruction(UIEdgeInsets(top: 60, left: 0, bottom: 0, right: 0))
        XCTAssertEqual(canvas.contentInset.top, 130)
        controller.canvasViewDidEndUsingTool(canvas)
        XCTAssertEqual(canvas.contentInset.top, 60)
        XCTAssertEqual(canvas.contentOffset.y, 200, "a page inside the smaller range stays where it is")
    }

    func testEveryCanvasReservesTheChromeAndTheToolbarDrawnOverIt() async throws {
        let size = CGSize(width: 1_024, height: 1_366)
        let chrome = NotebookCanvasChrome(top: 74, bottom: 20, canvasSize: size)
        let toolbar = UIEdgeInsets(top: 120, left: 0, bottom: 40, right: 0)
        let store = NotebookTestFixtures.toolStore()
        store.setOverlayObstruction(toolbar)
        let owner = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), toolStore: store)
        owner.applyChrome(chrome)
        let window = try await present(owner)
        defer {
            owner.tearDown()
            window.isHidden = true
        }
        XCTAssertEqual(owner.canvasView.contentInset.top, 194, "the owner adds the toolbar it takes its tools from")
        XCTAssertEqual(owner.canvasView.contentInset.bottom, 60)
        XCTAssertEqual(owner.canvasView.contentOffset.y, 0, "the page opens beneath the header and toolbar")

        for gate in [NotebookInputGate.failed, .recovering, .readOnly] {
            let paused = NotebookViewController(
                pageCount: 3, initialDrawing: PKDrawing(), toolStore: store, allowsEditing: gate != .readOnly
            )
            paused.setInputGate(gate)
            paused.applyChrome(chrome)
            paused.placeUnderToolbar(of: store)
            let pausedWindow = try await present(paused, ownsTools: false)
            XCTAssertNil(paused.drawingToolStore, "\(gate): the gate keeps a shown canvas from taking the tools")
            XCTAssertTrue(store.belongs(to: owner), "\(gate)")
            let canvas = paused.canvasView
            XCTAssertEqual(canvas.contentInset.top, 194, "\(gate): the header and the toolbar over it are reserved")
            XCTAssertEqual(canvas.contentInset.bottom, 60, "\(gate)")
            XCTAssertEqual(canvas.contentOffset.y, 0, "\(gate): the page opens beneath them")
            canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: -194), animated: false)
            XCTAssertEqual(canvas.contentOffset.y, -194, "\(gate): the first line scrolls clear of both")

            store.setOverlayObstruction(UIEdgeInsets(top: 150, left: 0, bottom: 40, right: 0))
            XCTAssertEqual(canvas.contentInset.top, 224, "\(gate): the toolbar moving reaches the canvas under it")
            XCTAssertEqual(canvas.contentOffset.y, -194, "\(gate): and never pushes its page")
            store.setOverlayObstruction(toolbar)

            paused.canvasViewDidBeginUsingTool(canvas)
            paused.applyChrome(NotebookCanvasChrome(top: 50, bottom: 20, canvasSize: size))
            XCTAssertEqual(canvas.contentInset.top, 194, "\(gate): a stroke admitted before the pause holds the space")
            paused.canvasViewDidEndUsingTool(canvas)
            XCTAssertEqual(canvas.contentInset.top, 170, "\(gate): the space is released when the stroke ends")
            paused.tearDown()
            XCTAssertFalse(store.covers(paused), "\(gate): a retired canvas no longer takes the toolbar's space")
            pausedWindow.isHidden = true
        }
        XCTAssertTrue(store.belongs(to: owner))

        // A pause for capacity keeps the toolbar, so the canvas takes the tools as well.
        let capacityStore = NotebookTestFixtures.toolStore()
        capacityStore.setOverlayObstruction(toolbar)
        let capacity = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), toolStore: capacityStore)
        capacity.setInputGate(.capacity)
        capacity.applyChrome(chrome)
        let capacityWindow = try await present(capacity)
        defer {
            capacity.tearDown()
            capacityWindow.isHidden = true
        }
        XCTAssertEqual(capacity.inputGate, .capacity)
        XCTAssertTrue(capacity.drawingToolStore === capacityStore)
        XCTAssertEqual(capacity.canvasView.contentInset.top, 194)
        XCTAssertEqual(capacity.canvasView.contentInset.bottom, 60)
    }

    func testResizeKeepsARevealedFirstLineClearOfTheHeader() {
        let landscape = CGSize(width: 1_366, height: 1_024)
        let portrait = CGSize(width: 1_024, height: 1_366)
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), allowsEditing: false)
        defer { controller.tearDown() }
        controller.loadViewIfNeeded()
        let canvas = controller.canvasView
        func resize(to size: CGSize) {
            controller.view.frame = CGRect(origin: .zero, size: size)
            controller.view.layoutIfNeeded()
        }
        resize(to: landscape)
        controller.applyChrome(NotebookCanvasChrome(top: 74, bottom: 20, canvasSize: landscape))
        XCTAssertEqual(canvas.contentOffset.y, 0, "the first measurement leaves the opening page beneath the header")
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: -74), animated: false)

        // The canvas is laid out at its new size before the chrome measured for that size reaches
        // it, the order the notebook screen delivers a resize in.
        resize(to: portrait)
        controller.applyChrome(NotebookCanvasChrome(top: 110, bottom: 20, canvasSize: portrait))
        XCTAssertEqual(canvas.contentInset.top, 110)
        XCTAssertEqual(canvas.contentOffset.y, -110, "a revealed first line stays clear after a resize")

        controller.applyChrome(NotebookCanvasChrome(top: 140, bottom: 20, canvasSize: portrait))
        XCTAssertEqual(canvas.contentOffset.y, -110, "a taller header without a resize never pushes the page down")

        // The chrome measured for the new size reaches the canvas before it is laid out at that size.
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: -140), animated: false)
        controller.view.frame = CGRect(origin: .zero, size: landscape)
        controller.applyChrome(NotebookCanvasChrome(top: 170, bottom: 20, canvasSize: landscape))
        XCTAssertEqual(canvas.contentOffset.y, -170)
        controller.view.layoutIfNeeded()
        XCTAssertEqual(canvas.contentOffset.y, -170, accuracy: 0.5)

        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: 600), animated: false)
        resize(to: portrait)
        let midPage = canvas.contentOffset
        controller.applyChrome(NotebookCanvasChrome(top: 120, bottom: 20, canvasSize: portrait))
        XCTAssertEqual(canvas.contentOffset, midPage, "a page scrolled into its writing keeps its place")

        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: -120), animated: false)
        resize(to: landscape)
        controller.canvasViewDidBeginUsingTool(canvas)
        controller.applyChrome(NotebookCanvasChrome(top: 150, bottom: 20, canvasSize: landscape))
        XCTAssertEqual(canvas.contentOffset.y, -120, "the page never moves under a stroke in progress")
        controller.canvasViewDidEndUsingTool(canvas)
        XCTAssertEqual(canvas.contentOffset.y, -120, "nor when that stroke ends")
    }

    func testResizeMovesOnlyAPageThatRestedAtItsRevealedTop() {
        let landscape = CGSize(width: 1_366, height: 1_024)
        let portrait = CGSize(width: 1_024, height: 1_366)
        let taller = CGSize(width: 1_024, height: 1_400)
        let store = NotebookTestFixtures.toolStore()
        store.setOverlayObstruction(UIEdgeInsets(top: 60, left: 0, bottom: 0, right: 0))
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), allowsEditing: false)
        defer { controller.tearDown() }
        controller.loadViewIfNeeded()
        controller.placeUnderToolbar(of: store)
        let canvas = controller.canvasView
        // A resize in the order the toolbar host delivers it: the toolbar is re-measured for its
        // new area, the canvas is laid out at its new size, and the chrome measured for it follows.
        func resize(to size: CGSize, toolbarTop: CGFloat, headerTop: CGFloat) {
            controller.view.frame = CGRect(origin: .zero, size: size)
            store.setOverlayObstruction(UIEdgeInsets(top: toolbarTop, left: 0, bottom: 0, right: 0), followingResize: true)
            controller.view.layoutIfNeeded()
            controller.applyChrome(NotebookCanvasChrome(top: headerTop, bottom: 20, canvasSize: size))
        }
        controller.view.frame = CGRect(origin: .zero, size: landscape)
        controller.view.layoutIfNeeded()
        controller.applyChrome(NotebookCanvasChrome(top: 74, bottom: 20, canvasSize: landscape))
        XCTAssertEqual(canvas.contentInset.top, 134)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: -124), animated: false)

        // Keeping the centre of this page, which showed its first lines under the toolbar, clamps
        // it onto its revealed top in the narrower layout.
        resize(to: portrait, toolbarTop: 60, headerTop: 74)
        XCTAssertEqual(canvas.contentInset.top, 134)
        XCTAssertEqual(canvas.contentOffset.y, -134, accuracy: 0.5)

        // The next resize reserves more space for the toolbar before the canvas is laid out.
        controller.view.frame = CGRect(origin: .zero, size: landscape)
        store.setOverlayObstruction(UIEdgeInsets(top: 100, left: 0, bottom: 0, right: 0), followingResize: true)
        XCTAssertEqual(canvas.contentInset.top, 174)
        XCTAssertEqual(canvas.contentOffset.y, -134, accuracy: 0.5, "the re-measure alone never moves the page")
        controller.view.layoutIfNeeded()
        controller.applyChrome(NotebookCanvasChrome(top: 74, bottom: 20, canvasSize: landscape))
        XCTAssertEqual(canvas.contentOffset.y, -174, accuracy: 0.5,
            "a page resting at its revealed top when a resize begins stays there, however it came to rest")

        // A page only near its top: the toolbar re-measured for the next size reserves less space,
        // which clamps the page onto its top, and the chrome measured after the layout reserves more.
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: -160), animated: false)
        controller.view.frame = CGRect(origin: .zero, size: portrait)
        store.setOverlayObstruction(UIEdgeInsets(top: 60, left: 0, bottom: 0, right: 0), followingResize: true)
        XCTAssertEqual(canvas.contentOffset.y, -134, accuracy: 0.5)
        controller.view.layoutIfNeeded()
        let laidOut = canvas.contentOffset
        controller.applyChrome(NotebookCanvasChrome(top: 110, bottom: 20, canvasSize: portrait))
        XCTAssertEqual(canvas.contentInset.top, 170)
        XCTAssertEqual(canvas.contentOffset, laidOut,
            "a page that was only near its top when the resize began is not moved to the new top")
        XCTAssertGreaterThan(canvas.contentOffset.y, -canvas.contentInset.top + 0.5)

        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: -170), animated: false)
        store.setOverlayObstruction(UIEdgeInsets(top: 100, left: 0, bottom: 0, right: 0))
        XCTAssertEqual(canvas.contentInset.top, 210)
        XCTAssertEqual(canvas.contentOffset.y, -170, accuracy: 0.5, "a toolbar moving down never pushes the page")
        resize(to: taller, toolbarTop: 100, headerTop: 110)
        XCTAssertGreaterThan(canvas.contentOffset.y, -canvas.contentInset.top + 0.5,
            "the page the toolbar moved over no longer rests at its top, so a resize leaves it off its top")
    }

    func testControlAreaChangeWithoutAResizeNeverPushesThePage() {
        let portrait = CGSize(width: 1_024, height: 1_366)
        let shorter = CGSize(width: 1_024, height: 1_300)
        let store = NotebookTestFixtures.toolStore()
        store.setOverlayObstruction(UIEdgeInsets(top: 60, left: 0, bottom: 0, right: 0))
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), allowsEditing: false)
        defer { controller.tearDown() }
        controller.loadViewIfNeeded()
        controller.placeUnderToolbar(of: store)
        let canvas = controller.canvasView
        controller.view.frame = CGRect(origin: .zero, size: portrait)
        controller.view.layoutIfNeeded()
        controller.applyChrome(NotebookCanvasChrome(top: 110, bottom: 20, canvasSize: portrait))
        XCTAssertEqual(canvas.contentInset.top, 170)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: -170), animated: false)

        // A shorter header at the same canvas size: a floating toolbar near the top follows the
        // larger control area down, and its re-measure arrives before the chrome.
        store.setOverlayObstruction(UIEdgeInsets(top: 75, left: 0, bottom: 0, right: 0), followingResize: true)
        XCTAssertEqual(canvas.contentInset.top, 185)
        XCTAssertEqual(canvas.contentOffset.y, -170, "the toolbar's re-measure never pushes the page")
        controller.applyChrome(NotebookCanvasChrome(top: 80, bottom: 20, canvasSize: portrait))
        XCTAssertEqual(canvas.contentInset.top, 155)
        XCTAssertEqual(canvas.contentOffset.y, -155, accuracy: 0.5, "the smaller top only clamps the page onto it")

        // A taller header again: the toolbar reaching less far clamps the page, the header leaves it.
        store.setOverlayObstruction(UIEdgeInsets(top: 60, left: 0, bottom: 0, right: 0), followingResize: true)
        controller.applyChrome(NotebookCanvasChrome(top: 110, bottom: 20, canvasSize: portrait))
        XCTAssertEqual(canvas.contentInset.top, 170)
        XCTAssertEqual(canvas.contentOffset.y, -140, accuracy: 0.5,
            "a taller header at the same canvas size never pushes the page")

        // The page rested at its top when that re-measure arrived, but the header change it
        // belonged to has passed, so a later resize finds the page off its top and keeps its centre.
        controller.view.frame = CGRect(origin: .zero, size: shorter)
        controller.view.layoutIfNeeded()
        controller.applyChrome(NotebookCanvasChrome(top: 110, bottom: 20, canvasSize: shorter))
        XCTAssertEqual(canvas.contentOffset.y, -140 + (portrait.height - shorter.height) / 2, accuracy: 0.5,
            "a page left off its top by a header change is not moved to its top by a later resize")
    }

    func testMovingTopAnchorsDoesNotPushThePageDown() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost()
        defer { fixture.close() }
        let canvas = fixture.controller.canvasView
        let actions = NotebookToolbarActions(store: fixture.store)
        let host = fixture.host
        XCTAssertEqual(canvas.contentOffset.y, 0, accuracy: 0.5)

        for placement in [
            EditorToolbarPlacement.floating(CGPoint(x: 0.5, y: 0.6)), .docked(.topLeading),
            .floating(CGPoint(x: 0.5, y: 0)), .docked(.topCenter)
        ] {
            actions.place(placement)
            try await NotebookTestFixtures.waitUntil { abs(canvas.bounds.height - host.bounds.height) < 0.5 }
            for _ in 0..<5 {
                try await Task.sleep(for: .milliseconds(20))
                host.layoutIfNeeded()
            }
            XCTAssertEqual(
                canvas.contentOffset.y, 0, accuracy: 0.5,
                "\(placement): toolbar movement does not displace the paper"
            )
        }
    }

    // MARK: - Writing view

    func testOnlyTheUsersOwnScrollingReachesTheWritingView() async throws {
        let store = NotebookTestFixtures.toolStore()
        let rig = try await NotebookChromeRig(store: store)
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), toolStore: store)
        controller.writingChrome = rig.chrome
        let window = try await present(controller)
        defer {
            controller.tearDown()
            window.isHidden = true
        }
        let canvas = controller.canvasView
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: 300), animated: false)
        XCTAssertEqual(rig.chrome.travel, 0, "a programmatic offset is not the user's scrolling")

        controller.scrollViewWillBeginDragging(canvas)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: 320), animated: false)
        XCTAssertEqual(rig.chrome.travel, 20)
        controller.scrollViewDidEndDragging(canvas, willDecelerate: true)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: 330), animated: false)
        XCTAssertEqual(rig.chrome.travel, 30, "the deceleration a drag starts still counts")
        controller.scrollViewDidEndDecelerating(canvas)
        XCTAssertEqual(rig.chrome.travel, NotebookWritingChrome.fullTravel, "a header past hiding settles away")
        XCTAssertTrue(store.areToolsHidden)

        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: 100), animated: false)
        XCTAssertFalse(rig.chrome.state.showsHeader, "once the drag has ended, offsets do not count")
        controller.scrollViewDidScrollToTop(canvas)
        XCTAssertTrue(rig.chrome.state.showsHeader, "the status-bar tap is the user's own arrival at the top")
        XCTAssertEqual(rig.chrome.travel, 0)
    }

    func testSpringingBackFromPastTheLastPageIsNotAnUpwardScroll() async throws {
        let store = NotebookTestFixtures.toolStore()
        let rig = try await NotebookChromeRig(store: store)
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), toolStore: store)
        controller.writingChrome = rig.chrome
        let window = try await present(controller)
        defer {
            controller.tearDown()
            window.isHidden = true
        }
        let canvas = controller.canvasView
        let end = maximumOffsetY(canvas)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: end - 200), animated: false)
        controller.scrollViewWillBeginDragging(canvas)
        for y in [end - 100, end, end + 60, end + 90] {
            canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: y), animated: false)
        }
        controller.scrollViewDidEndDragging(canvas, willDecelerate: true)
        for y in [end + 60, end + 20, end] {
            canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: y), animated: false)
        }
        controller.scrollViewDidEndDecelerating(canvas)
        XCTAssertFalse(rig.chrome.state.showsHeader, "the spring back reports no movement")
        XCTAssertTrue(store.areToolsHidden)
    }

    /// A deceleration can stop without reporting its end, as when a stroke halts it. Offsets the
    /// user no longer drives then end the scroll instead of moving the header.
    func testOffsetsAfterAnUnreportedStopDoNotMoveTheHeader() async throws {
        let store = NotebookTestFixtures.toolStore()
        let rig = try await NotebookChromeRig(store: store)
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), toolStore: store)
        controller.writingChrome = rig.chrome
        let window = try await present(controller)
        defer {
            controller.tearDown()
            window.isHidden = true
        }
        let canvas = controller.canvasView
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: 300), animated: false)
        controller.scrollViewWillBeginDragging(canvas)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: 310), animated: false)
        controller.scrollViewDidEndDragging(canvas, willDecelerate: true)
        XCTAssertEqual(rig.chrome.travel, 10)

        rig.chrome.scrollIsUserDriven = { _ in false }
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: 360), animated: false)
        XCTAssertEqual(rig.chrome.travel, 0, "the scroll ends there and the part-way header settles back")
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: 500), animated: false)
        XCTAssertEqual(rig.chrome.travel, 0, "later offsets belong to layout or code")
        XCTAssertTrue(rig.chrome.state.showsHeader)
        XCTAssertFalse(store.areToolsHidden)

        // The real test reads the scroll view itself, which reports no touches here.
        XCTAssertFalse(NotebookWritingChrome.isUserDriven(canvas))
        rig.chrome.scrollIsUserDriven = NotebookWritingChrome.isUserDriven
        controller.scrollViewWillBeginDragging(canvas)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: 600), animated: false)
        XCTAssertEqual(rig.chrome.travel, 0, "a canvas neither tracking, dragging nor decelerating is not the user's")
    }

    func testToolUseReachesTheWritingViewAndTearDownCancelsIt() async throws {
        let store = NotebookTestFixtures.toolStore()
        let rig = try await NotebookChromeRig(store: store)
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), toolStore: store)
        controller.writingChrome = rig.chrome
        let window = try await present(controller)
        defer {
            controller.tearDown()
            window.isHidden = true
        }
        let canvas = controller.canvasView
        controller.canvasViewDidBeginUsingTool(canvas)
        controller.scrollViewWillBeginDragging(canvas)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: 200), animated: false)
        controller.scrollViewDidEndDragging(canvas, willDecelerate: false)
        XCTAssertEqual(rig.chrome.travel, 0, "the header holds still under the pen")
        XCTAssertTrue(rig.chrome.state.showsHeader)
        controller.canvasViewDidEndUsingTool(canvas)
        XCTAssertFalse(rig.chrome.state.showsHeader, "focus clears the page once the stroke ends")
        XCTAssertTrue(store.areToolsHidden)

        rig.chrome.reveal(.sticky)
        controller.canvasViewDidBeginUsingTool(canvas)
        controller.tearDown()
        XCTAssertNil(controller.writingChrome)
        XCTAssertTrue(rig.chrome.state.showsHeader, "a stroke cut short hides nothing")
        rig.drag(by: 100)
        XCTAssertFalse(rig.chrome.state.showsHeader, "scrolling counts again once the stroke is cancelled")
    }

    func testPencilToolSwitchShowsTheToolsBrieflyAndPaletteRequestsKeepThem() async throws {
        let store = NotebookTestFixtures.toolStore()
        let rig = try await NotebookChromeRig(store: store)
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), toolStore: store)
        controller.writingChrome = rig.chrome
        let window = try await present(controller)
        defer {
            controller.tearDown()
            window.isHidden = true
        }
        let canvas = controller.canvasView
        controller.canvasViewDidBeginUsingTool(canvas)
        controller.canvasViewDidEndUsingTool(canvas)
        XCTAssertTrue(store.areToolsHidden)

        controller.handlePencilPreference(.switchEraser)
        XCTAssertFalse(store.areToolsHidden, "the switched tool shows")
        XCTAssertFalse(rig.chrome.state.showsHeader, "a tool switch leaves the page clear of the header")
        try await NotebookTestFixtures.waitUntil { store.areToolsHidden }

        controller.handlePencilPreference(.showColorPalette)
        XCTAssertFalse(store.areToolsHidden)
        XCTAssertTrue(rig.chrome.state.showsHeader)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(store.areToolsHidden, "a palette request keeps the tools up")
    }

    /// A toolbar re-measured for a new control area claims the page rested at its top. When no resize
    /// follows and the user then scrolls into the page, a later resize must not move it back to its top.
    func testUserScrollEndsAnUnconfirmedClaimThatThePageRestedAtItsTop() {
        let portrait = CGSize(width: 1_024, height: 1_366)
        let landscape = CGSize(width: 1_366, height: 1_024)
        let store = NotebookTestFixtures.toolStore()
        store.setOverlayObstruction(UIEdgeInsets(top: 60, left: 0, bottom: 0, right: 0))
        let controller = NotebookViewController(pageCount: 3, initialDrawing: PKDrawing(), allowsEditing: false)
        defer { controller.tearDown() }
        controller.loadViewIfNeeded()
        controller.placeUnderToolbar(of: store)
        let canvas = controller.canvasView
        controller.view.frame = CGRect(origin: .zero, size: portrait)
        controller.view.layoutIfNeeded()
        controller.applyChrome(NotebookCanvasChrome(top: 110, bottom: 20, canvasSize: portrait))
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: -canvas.contentInset.top), animated: false)

        store.setOverlayObstruction(UIEdgeInsets(top: 75, left: 0, bottom: 0, right: 0), followingResize: true)
        controller.scrollViewWillBeginDragging(canvas)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: 600), animated: false)
        controller.scrollViewDidEndDragging(canvas, willDecelerate: false)

        controller.view.frame = CGRect(origin: .zero, size: landscape)
        controller.view.layoutIfNeeded()
        XCTAssertGreaterThan(canvas.contentOffset.y, -canvas.contentInset.top + 0.5,
            "a page the user scrolled into keeps its place through a later resize")
    }

    private func maximumOffsetY(_ canvas: PKCanvasView) -> CGFloat {
        canvas.contentSize.height - canvas.bounds.height + canvas.contentInset.bottom
    }

    private func assertCanvasTool(
        _ canvas: PKCanvasView, is kind: EditorToolKind, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        switch kind {
        case let .ink(family):
            XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, family.inkType, message, file: file, line: line)
        case .eraser(.vector):
            XCTAssertEqual((canvas.tool as? PKEraserTool)?.eraserType, .vector, message, file: file, line: line)
        case .eraser(.bitmap):
            XCTAssertEqual((canvas.tool as? PKEraserTool)?.eraserType, .bitmap, message, file: file, line: line)
        case .lasso:
            XCTAssertTrue(canvas.tool is PKLassoTool, message, file: file, line: line)
        }
    }

    private func pencilInteractions(on canvas: PKCanvasView) -> [UIPencilInteraction] {
        canvas.interactions.compactMap { $0 as? UIPencilInteraction }
    }

    /// Shows `controller` in its own window and waits until it appears and, when `ownsTools`,
    /// until it has taken the tools.
    private func present(_ controller: NotebookViewController, ownsTools: Bool = true) async throws -> UIWindow {
        let window = UIWindow(windowScene: try NotebookTestFixtures.windowScene())
        window.frame = CGRect(x: 0, y: 0, width: 1_024, height: 1_366)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        do {
            try await NotebookTestFixtures.waitUntil {
                guard controller.isCanvasVisible, controller.view.window === window else { return false }
                return !ownsTools
                    || controller.drawingToolStore?.isToolbarAvailable == true && controller.canvasView.isFirstResponder
            }
        } catch {
            controller.tearDown()
            window.isHidden = true
            window.rootViewController = nil
            throw error
        }
        return window
    }
}

/// Counts the change notifications an observable object sends to the views observing it.
@MainActor
private final class ChangeCounter {
    private(set) var count = 0
    private var subscription: AnyCancellable?

    init<Object: ObservableObject>(_ object: Object) where Object.ObjectWillChangePublisher == ObservableObjectPublisher {
        subscription = object.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.count += 1 }
        }
    }
}

/// Records how often each key is written, to tell one settled write from repeated ones.
private final class CountingDefaults: UserDefaults, @unchecked Sendable {
    private(set) var writes: [String: Int] = [:]

    override func set(_ value: Any?, forKey defaultName: String) {
        writes[defaultName, default: 0] += 1
        super.set(value, forKey: defaultName)
    }
}
