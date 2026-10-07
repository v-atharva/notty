import NottyCore
import PencilKit
import UIKit
import XCTest
@testable import Notty

@MainActor
final class NotebookWritingComfortTests: XCTestCase {
    func testSimulatorAcceptsNativeDrawingInput() async throws {
        let fixture = try await presentController()
        defer { fixture.close() }
        #if targetEnvironment(simulator)
        XCTAssertEqual(fixture.controller.canvasView.drawingPolicy, .anyInput)
        #else
        XCTAssertEqual(fixture.controller.canvasView.drawingPolicy, .pencilOnly)
        #endif
    }

    func testMinimumZoomCanShowAnEntireA4Section() async throws {
        let fixture = try await presentController()
        defer { fixture.close() }
        let canvas = fixture.controller.canvasView
        let page = PaperGeometry(pageWidth: 794)
        XCTAssertGreaterThan(canvas.bounds.width, 0)
        XCTAssertGreaterThan(canvas.bounds.height, 0)
        XCTAssertLessThanOrEqual(canvas.minimumZoomScale, canvas.bounds.width / 794 * 0.5 + 0.001)
        canvas.setZoomScale(canvas.minimumZoomScale, animated: false)
        XCTAssertLessThanOrEqual(CGFloat(page.pageHeight) * canvas.zoomScale, canvas.bounds.height + 0.5)
    }

    func testCapacityKeepsTheRealUndoManagerAvailable() async throws {
        let fixture = try await presentController()
        defer { fixture.close() }
        let manager = try XCTUnwrap(fixture.controller.canvasView.undoManager)
        fixture.controller.setInputGate(.capacity)
        let pausedManager = try XCTUnwrap(fixture.controller.canvasView.undoManager)
        XCTAssertTrue(manager === pausedManager)
        XCTAssertFalse(fixture.controller.canvasView.drawingGestureRecognizer.isEnabled)
    }

    func testTeardownEndsActiveToolBeforeApplyingClosedAdmission() async throws {
        let fixture = try await presentController()
        defer { fixture.close() }
        let controller = fixture.controller
        controller.canvasViewDidBeginUsingTool(controller.canvasView)
        controller.setInputGate(.failed)
        XCTAssertTrue(controller.canvasView.drawingGestureRecognizer.isEnabled)
        controller.tearDown()
        XCTAssertFalse(controller.canvasView.drawingGestureRecognizer.isEnabled)
        XCTAssertFalse(controller.canvasView.isDrawingEnabled)
    }

    func testTeardownClearsTheActualUndoAndRedoStacks() async throws {
        for startsWithRedo in [false, true] {
            let fixture = try await presentController()
            defer { fixture.close() }
            let manager = try XCTUnwrap(fixture.controller.canvasView.undoManager)
            manager.removeAllActions()
            let target = UndoTarget(manager: manager)
            target.register()
            if startsWithRedo {
                manager.undo()
                XCTAssertTrue(manager.canRedo)
            } else {
                XCTAssertTrue(manager.canUndo)
            }
            let callsBefore = target.calls
            fixture.controller.tearDown()
            XCTAssertFalse(manager.canUndo)
            XCTAssertFalse(manager.canRedo)
            XCTAssertEqual(target.calls, callsBefore)
        }
    }

    func testCapacityReservesOnlyOneOwnedUndoOrRedoBeforeMutation() async throws {
        for startsWithRedo in [false, true] {
            let fixture = try await presentController()
            defer { fixture.close() }
            let controller = fixture.controller
            let canvas = controller.canvasView
            let manager = try XCTUnwrap(canvas.undoManager)
            manager.removeAllActions()
            let target = UndoTarget(manager: manager)
            target.register()
            if startsWithRedo { manager.undo() }
            let callsBefore = target.calls
            controller.setInputGate(.capacity)
            var reservationCalls = 0
            controller.reserveHistoryAction = {
                reservationCalls += 1
                return true
            }
            target.onChange = {
                XCTAssertFalse(controller.currentUndoAvailability.canUndo)
                XCTAssertFalse(controller.currentUndoAvailability.canRedo)
            }
            let action = NSSelectorFromString(startsWithRedo ? "redo:" : "undo:")
            XCTAssertTrue(canvas.canPerformAction(action, withSender: nil))
            XCTAssertTrue(canvas.target(forAction: action, withSender: nil) as? PKCanvasView === canvas)
            XCTAssertEqual(reservationCalls, 0, "Availability queries must not consume admission.")
            canvas.perform(action, with: nil)
            XCTAssertEqual(target.calls, callsBefore + 1)
            XCTAssertEqual(reservationCalls, 1)
            XCTAssertFalse(controller.currentUndoAvailability.canUndo)
            XCTAssertFalse(controller.currentUndoAvailability.canRedo)
            controller.performUndo()
            controller.performRedo()
            controller.setInputGate(.capacity)
            controller.performUndo()
            controller.performRedo()
            XCTAssertEqual(target.calls, callsBefore + 1)
            XCTAssertEqual(reservationCalls, 1)
            target.onChange = nil
            controller.setInputGate(.open)
            controller.setInputGate(.capacity)
            if startsWithRedo { controller.performUndo() } else { controller.performRedo() }
            XCTAssertEqual(target.calls, callsBefore + 2)
            XCTAssertEqual(reservationCalls, 2)
        }
    }

    func testHistoryCommandsRespectActiveToolAndAuthorizationAtInvocation() async throws {
        let fixture = try await presentController()
        defer { fixture.close() }
        let controller = fixture.controller
        let manager = try XCTUnwrap(controller.canvasView.undoManager)
        manager.removeAllActions()
        let target = UndoTarget(manager: manager)
        target.register()
        controller.canvasViewDidBeginUsingTool(controller.canvasView)
        controller.performUndo()
        XCTAssertEqual(target.calls, 0)
        XCTAssertTrue(controller.currentUndoAvailability.isUsingTool)
        XCTAssertFalse(controller.currentUndoAvailability.canUndo)
        controller.canvasViewDidEndUsingTool(controller.canvasView)
        controller.canPerformHistoryAction = { false }
        controller.performUndo()
        XCTAssertEqual(target.calls, 0)
        controller.canPerformHistoryAction = { true }
        controller.reserveHistoryAction = {
            controller.setInputGate(.failed)
            return true
        }
        controller.performUndo()
        XCTAssertEqual(target.calls, 0)
        XCTAssertNil(controller.canvasView.undoManager)
    }

    func testPaletteSuppressionSurvivesClosedGatesAndActiveTool() async throws {
        let fixture = try await presentController()
        defer { fixture.close() }
        let controller = fixture.controller
        let store = try XCTUnwrap(controller.drawingToolStore)
        XCTAssertTrue(store.isToolbarAvailable)
        controller.canvasViewDidBeginUsingTool(controller.canvasView)
        controller.setPaletteSuppressed(true)
        XCTAssertFalse(store.isToolbarAvailable, "tool choices stop as soon as suppression starts")
        XCTAssertTrue(controller.canvasView.isFirstResponder, "the stroke in progress keeps its responder until it ends")
        controller.canvasViewDidEndUsingTool(controller.canvasView)
        XCTAssertFalse(store.isToolbarAvailable)
        XCTAssertTrue(controller.canvasView.becomeFirstResponder())
        XCTAssertTrue(controller.canvasView.isFirstResponder)
        controller.setPaletteSuppressed(true)
        XCTAssertFalse(controller.canvasView.isFirstResponder)
        XCTAssertFalse(store.isToolbarAvailable)
        controller.setInputGate(.failed)
        controller.setPaletteSuppressed(false)
        XCTAssertFalse(store.isToolbarAvailable)
        XCTAssertFalse(controller.canvasView.isFirstResponder)
        controller.setInputGate(.open)
        XCTAssertTrue(store.isToolbarAvailable)
        controller.setPaletteSuppressed(true)
        controller.setInputGate(.capacity)
        controller.setInputGate(.open)
        XCTAssertFalse(store.isToolbarAvailable)
        controller.setPaletteSuppressed(false)
        XCTAssertTrue(store.isToolbarAvailable)
    }

    func testReadOnlyViewerAndUnmountedCanvasDoNotAllocateToolStore() async throws {
        let before = NotebookSceneToolStore.creationCount
        let unmounted = NotebookViewController(pageCount: 1, initialDrawing: PKDrawing())
        unmounted.loadViewIfNeeded()
        XCTAssertNil(unmounted.drawingToolStore)
        XCTAssertEqual(NotebookSceneToolStore.creationCount, before)
        unmounted.tearDown()
        let fixture = try await presentController(injectStore: false, allowsEditing: false)
        defer { fixture.close() }
        XCTAssertNil(fixture.controller.drawingToolStore)
        XCTAssertEqual(NotebookSceneToolStore.creationCount, before)
        XCTAssertFalse(fixture.controller.canvasView.isFirstResponder)
        fixture.controller.setInputGate(.open)
        XCTAssertEqual(fixture.controller.inputGate, .readOnly)
        XCTAssertFalse(fixture.controller.canvasView.isDrawingEnabled)
    }

    func testSceneOwnedToolStoreHandoffRetainsSelectionAndRetiresOldOwner() async throws {
        let first = try await presentController(injectStore: false)
        defer { first.close() }
        let store = try XCTUnwrap(first.controller.drawingToolStore)
        let scene = try XCTUnwrap(first.window.windowScene)
        // The scene store and its settings outlive this test, so restore both for the tests that follow.
        NotebookTestFixtures.restoreSceneToolDefaults(for: scene, after: self)
        let original = store.tool
        defer { store.update { $0 = original } }
        XCTAssertEqual(store.toolDefaultsKey, "notty.editor.tool." + scene.session.persistentIdentifier)
        store.update { $0.select(.eraser(.vector)) }
        let manager = try XCTUnwrap(first.controller.canvasView.undoManager)
        manager.removeAllActions()
        let target = UndoTarget(manager: manager)
        target.register()
        var detachCount = 0
        first.controller.onDetach = { detachCount += 1 }
        let second = try await presentController(injectStore: false)
        defer { second.close() }
        XCTAssertTrue(try XCTUnwrap(second.controller.drawingToolStore) === store)
        XCTAssertEqual(store.tool.kind, .eraser(.vector))
        XCTAssertTrue(second.controller.canvasView.tool is PKEraserTool, "the retained selection reaches the new canvas")
        XCTAssertEqual(detachCount, 1)
        XCTAssertFalse(manager.canUndo)
        XCTAssertFalse(manager.canRedo)
        XCTAssertFalse(first.controller.canvasView.isDrawingEnabled)
        XCTAssertTrue(second.controller.canvasView.isFirstResponder)
        first.controller.tearDown()
        XCTAssertTrue(store.isToolbarAvailable)
        XCTAssertTrue(second.controller.canvasView.isFirstResponder)
    }

    func testPaperLayersTrackLogicalGeometryAcrossZoomWithoutAnimations() async throws {
        let fixture = try await presentController()
        defer { fixture.close() }
        let paper = fixture.controller.paperView
        let height = CGFloat(NotebookPaperMetrics.geometry.pageHeight)
        XCTAssertEqual(paper.boundaryLayers.count, 2)
        for scale: CGFloat in [0.4, 1, 2.5] {
            let offset = CGPoint(x: 32, y: 150)
            paper.setViewport(scale: scale, offset: offset)
            paper.finishZoom()
            for (index, layer) in paper.boundaryLayers.enumerated() {
                let point = paper.contentLayer.convert(layer.position, to: paper.layer)
                XCTAssertEqual(point.x, -offset.x, accuracy: 0.001)
                XCTAssertEqual(point.y, height * CGFloat(index + 1) * scale - offset.y, accuracy: 0.001)
                XCTAssertTrue(layer.animationKeys()?.isEmpty ?? true)
                XCTAssertEqual(layer.bounds.width, 794, accuracy: 0.001)
                XCTAssertEqual(layer.bounds.height * scale, 1 / paper.traitCollection.displayScale, accuracy: 0.001)
            }
            let edge = paper.contentLayer.convert(paper.edgeLayer.position, to: paper.layer)
            XCTAssertEqual(edge.y, height * 3 * scale - offset.y, accuracy: 0.001)
            XCTAssertFalse(paper.edgeLayer.isHidden)
            XCTAssertTrue(paper.contentLayer.animationKeys()?.isEmpty ?? true)
        }
        fixture.controller.setPageCount(4)
        XCTAssertEqual(paper.boundaryLayers.count, 3)
        XCTAssertEqual(paper.edgeLayer.position.y, height * 4, accuracy: 0.001)
    }

    func testThousandPointScrollUsesTransformsWithoutCPUPaperRedraw() async throws {
        let paper = PaperDrawSpy(frame: .zero)
        let fixture = try await presentController(paperView: paper)
        defer { fixture.close() }
        paper.setNeedsDisplay()
        try await waitForRenderedFrames()
        XCTAssertGreaterThan(paper.drawCalls, 0, "The mounted spy must observe an actual display.")
        let before = paper.drawCalls
        let thicknessBefore = paper.thicknessUpdates
        let geometryBefore = paper.geometryUpdates
        let viewportBefore = paper.viewportUpdates
        let canvas = fixture.controller.canvasView
        for y in stride(from: CGFloat(0), through: CGFloat(1_000), by: CGFloat(10)) {
            canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: y), animated: false)
        }
        try await waitForRenderedFrames()
        XCTAssertEqual(canvas.contentOffset.y, 1_000, accuracy: 0.1)
        XCTAssertEqual(paper.drawCalls, before)
        XCTAssertEqual(paper.thicknessUpdates, thicknessBefore)
        XCTAssertEqual(paper.geometryUpdates, geometryBefore)
        XCTAssertGreaterThan(paper.viewportUpdates, viewportBefore)
        let values = [
            "scrollPoints": 1_000, "additionalPaperDrawCalls": paper.drawCalls - before,
            "viewportUpdates": paper.viewportUpdates - viewportBefore,
            "geometryUpdates": paper.geometryUpdates - geometryBefore,
            "thicknessUpdates": paper.thicknessUpdates - thicknessBefore
        ]
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        print("NOTTY_COMFORT_METRIC \(String(decoding: data, as: UTF8.self))")
    }

    func testRotationKeepsLogicalCenterAndFullSectionMinimumZoom() async throws {
        let fixture = try await presentController()
        defer { fixture.close() }
        let controller = fixture.controller
        let canvas = controller.canvasView
        canvas.setZoomScale(2, animated: false)
        canvas.setContentOffset(CGPoint(x: 150, y: 700), animated: false)
        let center = CGPoint(
            x: (canvas.contentOffset.x + canvas.bounds.width / 2) / canvas.zoomScale,
            y: (canvas.contentOffset.y + canvas.bounds.height / 2) / canvas.zoomScale
        )
        fixture.window.frame = CGRect(x: 0, y: 0, width: 1_024, height: 1_366)
        controller.view.frame = fixture.window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        XCTAssertEqual((canvas.contentOffset.x + canvas.bounds.width / 2) / canvas.zoomScale, center.x, accuracy: 0.5)
        XCTAssertEqual((canvas.contentOffset.y + canvas.bounds.height / 2) / canvas.zoomScale, center.y, accuracy: 0.5)
        XCTAssertLessThanOrEqual(
            CGFloat(NotebookPaperMetrics.geometry.pageHeight) * canvas.minimumZoomScale,
            canvas.bounds.height + 0.5
        )
    }

    func testEqualObservedCallbacksAndRestoredToolStateDoNotRequestGrowth() async throws {
        let stroke = nearEndStroke()
        let drawing = PKDrawing(strokes: [stroke])
        let fixture = try await presentController(drawing: drawing)
        defer { fixture.close() }
        let controller = fixture.controller
        let canvas = controller.canvasView
        canvas.delegate = nil
        var generations: [UInt64] = []
        var completions: [NotebookToolCompletion] = []
        controller.onObservation = { generations.append($0.generation); return .open }
        controller.onToolCompletion = { completions.append($0) }
        controller.canvasViewDidBeginUsingTool(canvas)
        controller.canvasViewDrawingDidChange(canvas)
        controller.canvasViewDrawingDidChange(canvas)
        controller.canvasViewDidEndUsingTool(canvas)
        XCTAssertEqual(generations, [1, 2])
        XCTAssertTrue(completions.isEmpty)
        controller.canvasViewDidBeginUsingTool(canvas)
        var moved = stroke
        moved.transform = CGAffineTransform(translationX: 10, y: 10)
        canvas.drawing = PKDrawing(strokes: [moved])
        controller.canvasViewDrawingDidChange(canvas)
        canvas.drawing = drawing
        controller.canvasViewDrawingDidChange(canvas)
        controller.canvasViewDidEndUsingTool(canvas)
        XCTAssertEqual(generations, [1, 2, 3, 4])
        XCTAssertTrue(completions.isEmpty)
    }

    func testSemanticToolCompletionRetainsStampAndLaterObservationSeparately() async throws {
        let fixture = try await presentController(drawing: PKDrawing())
        defer { fixture.close() }
        let controller = fixture.controller
        let canvas = controller.canvasView
        canvas.delegate = nil
        var observations: [NotebookCanvasObservation] = []
        var completions: [NotebookToolCompletion] = []
        controller.onObservation = { observations.append($0); return .capacity }
        controller.onToolCompletion = { completions.append($0) }
        controller.canvasViewDidBeginUsingTool(canvas)
        let stroke = nearEndStroke()
        canvas.drawing = PKDrawing(strokes: [stroke])
        controller.canvasViewDrawingDidChange(canvas)
        controller.canvasViewDidEndUsingTool(canvas)
        let completion = try XCTUnwrap(completions.first)
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completion.generation, 1)
        XCTAssertEqual(completion.pageCount, 3)
        XCTAssertTrue(completion.nearPaperEnd)
        XCTAssertEqual(completion.capturedAt, observations[0].capturedAt)
        XCTAssertEqual(completion.uptime, observations[0].uptime)
        XCTAssertFalse(controller.currentUndoAvailability.isUsingTool)
        var late = stroke
        late.transform = CGAffineTransform(translationX: 20, y: 0)
        canvas.drawing = PKDrawing(strokes: [late])
        controller.canvasViewDrawingDidChange(canvas)
        XCTAssertEqual(observations.map(\.generation), [1, 2])
        XCTAssertEqual(observations[1].drawing.strokes[0].transform, late.transform)
        XCTAssertEqual(completions.count, 1)
        controller.tearDown()
        XCTAssertEqual(completions.count, 1)
    }

    func testPaperEndEligibilityRejectsEmptyAndEarlierInk() {
        XCTAssertFalse(NotebookPaperMetrics.isNearPaperEnd(PKDrawing(), pageCount: 3))
        let early = PKDrawing(strokes: [NotebookTestFixtures.stroke()])
        XCTAssertFalse(NotebookPaperMetrics.isNearPaperEnd(early, pageCount: 3))
        let end = PKDrawing(strokes: [nearEndStroke()])
        XCTAssertTrue(NotebookPaperMetrics.isNearPaperEnd(end, pageCount: 3))
        XCTAssertFalse(NotebookPaperMetrics.isNearPaperEnd(end, pageCount: 0))
    }

    func testDisappearanceCancelsGrowthBeforeSyntheticInactivityAndTeardownDoesNotPublishIt() async throws {
        let fixture = try await presentController()
        defer { fixture.close() }
        let controller = fixture.controller
        let canvas = controller.canvasView
        canvas.delegate = nil
        var events: [String] = []
        controller.onObservation = { _ in events.append("observed"); return .open }
        controller.onInteractionInterrupted = { events.append("interrupted") }
        controller.onUndoAvailabilityChange = {
            if !$0.isUsingTool { events.append("inactive") }
        }
        controller.onDetach = { events.append("detached") }
        controller.canvasViewDidBeginUsingTool(canvas)
        canvas.drawing = PKDrawing(strokes: [nearEndStroke()])
        events.removeAll()
        controller.beginAppearanceTransition(false, animated: false)
        controller.endAppearanceTransition()
        XCTAssertEqual(events, ["observed", "interrupted", "inactive"])
        XCTAssertFalse(controller.currentUndoAvailability.isUsingTool)
        controller.canvasViewDidBeginUsingTool(canvas)
        var moved = nearEndStroke()
        moved.transform = CGAffineTransform(translationX: 20, y: 0)
        canvas.drawing = PKDrawing(strokes: [moved])
        events.removeAll()
        controller.tearDown()
        XCTAssertEqual(events, ["observed", "interrupted", "detached"])
        XCTAssertFalse(canvas.isDrawingEnabled)
    }

    func testDisplayScaleTraitChangeRefreshesOnlyDividerThickness() async throws {
        let fixture = try await presentController()
        defer { fixture.close() }
        let paper = fixture.controller.paperView
        let geometryBefore = paper.geometryUpdates
        let viewportBefore = paper.viewportUpdates
        let thicknessBefore = paper.thicknessUpdates
        let requestedScale: CGFloat = paper.traitCollection.displayScale == 3 ? 2 : 3
        paper.traitOverrides.displayScale = requestedScale
        try await waitForRenderedFrames()
        XCTAssertEqual(paper.traitCollection.displayScale, requestedScale)
        XCTAssertGreaterThan(paper.thicknessUpdates, thicknessBefore)
        XCTAssertEqual(paper.geometryUpdates, geometryBefore)
        XCTAssertEqual(paper.viewportUpdates, viewportBefore)
        XCTAssertEqual(
            try XCTUnwrap(paper.boundaryLayers.first).bounds.height * fixture.controller.canvasView.zoomScale,
            1 / requestedScale, accuracy: 0.001
        )
    }

    func testClosedFirstAppearanceDefersToolStoreUntilGenuineOpenAdmission() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let controller = NotebookViewController(pageCount: 1, initialDrawing: PKDrawing())
        controller.setInputGate(.failed)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1_366, height: 1_024)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        defer {
            controller.tearDown()
            window.isHidden = true
            window.rootViewController = nil
        }
        try await waitForAppearance(controller, window: window, expectsToolbar: false)
        XCTAssertNil(controller.drawingToolStore)
        XCTAssertFalse(controller.canvasView.isFirstResponder)
        controller.setInputGate(.open)
        let store = try XCTUnwrap(controller.drawingToolStore)
        XCTAssertTrue(store.isToolbarAvailable)
        XCTAssertTrue(controller.canvasView.isFirstResponder)
    }

    func testActualSDKRestorationCallbacksRemainObservedWithoutAutomaticGrowth() async throws {
        let original = PKDrawing(strokes: [nearEndStroke()])
        let fixture = try await presentController(drawing: original)
        defer { fixture.close() }
        let controller = fixture.controller
        let canvas = controller.canvasView
        var observations: [NotebookCanvasObservation] = []
        var completions: [NotebookToolCompletion] = []
        controller.onObservation = { observations.append($0); return .open }
        controller.onToolCompletion = { completions.append($0) }
        controller.canvasViewDidBeginUsingTool(canvas)
        var moved = original.strokes[0]
        moved.transform = moved.transform.translatedBy(x: 30, y: 0)
        let changed = PKDrawing(strokes: [moved])
        canvas.drawing = changed
        try await waitForRenderedFrames()
        let changedIndex = try XCTUnwrap(observations.firstIndex {
            $0.drawing.strokes.first?.transform == moved.transform
        })
        canvas.drawing = original
        try await waitForRenderedFrames()
        let restoredIndex = try XCTUnwrap(observations.indices.first {
            $0 > changedIndex && observations[$0].drawing.strokes.first?.transform == original.strokes[0].transform
        })
        controller.canvasViewDidEndUsingTool(canvas)
        XCTAssertGreaterThan(restoredIndex, changedIndex)
        XCTAssertTrue(completions.isEmpty)
        XCTAssertEqual(observations.map(\.generation), Array(1...UInt64(observations.count)))
        XCTAssertEqual(observations[changedIndex].drawing.strokes.map(\.id), original.strokes.map(\.id))
        XCTAssertEqual(observations[restoredIndex].drawing.strokes.map(\.id), original.strokes.map(\.id))
    }

    func testAcceptedOwnedUndoRetainsEveryActualSDKObservation() async throws {
        let initial = PKDrawing(strokes: [NotebookTestFixtures.stroke()])
        let fixture = try await presentController(drawing: initial)
        defer { fixture.close() }
        let controller = fixture.controller
        let canvas = controller.canvasView
        let manager = try XCTUnwrap(canvas.undoManager)
        manager.removeAllActions()
        let target = DrawingUndoTarget(canvas: canvas, manager: manager)
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: target) { $0.assign(PKDrawing()) }
        manager.endUndoGrouping()
        var observations: [NotebookCanvasObservation] = []
        controller.onObservation = { observations.append($0); return .capacity }
        controller.setInputGate(.capacity)
        controller.performUndo()
        try await waitForRenderedFrames()
        XCTAssertEqual(target.calls, 1)
        XCTAssertTrue(canvas.drawing.strokes.isEmpty)
        XCTAssertFalse(observations.isEmpty)
        XCTAssertTrue(try XCTUnwrap(observations.last).drawing.strokes.isEmpty)
        XCTAssertEqual(observations.map(\.generation), Array(1...UInt64(observations.count)))
        let before = observations.count
        controller.performRedo()
        try await waitForRenderedFrames()
        XCTAssertEqual(target.calls, 1)
        XCTAssertEqual(observations.count, before)
        XCTAssertTrue(manager.canRedo, "The native redo stack remains intact while admission is reserved.")
    }

    private func nearEndStroke() -> PKStroke {
        var stroke = NotebookTestFixtures.stroke()
        stroke.transform = CGAffineTransform(
            translationX: 0, y: CGFloat(NotebookPaperMetrics.geometry.pageHeight) * 2.85
        )
        return stroke
    }

    private func waitForRenderedFrames() async throws {
        let completed = expectation(description: "Paper display frames")
        let waiter = FrameWaiter(completed: completed)
        let link = CADisplayLink(target: waiter, selector: #selector(FrameWaiter.advance(_:)))
        link.add(to: .main, forMode: .common)
        defer { link.invalidate() }
        let result = await XCTWaiter.fulfillment(of: [completed], timeout: NotebookTestFixtures.readinessTimeout)
        guard result == .completed else { throw FixtureFailure.readiness }
    }

    private func presentController(
        injectStore: Bool = true, allowsEditing: Bool = true,
        drawing: PKDrawing = PKDrawing(), paperView: NotebookPaperView? = nil
    ) async throws -> Fixture {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let controller = NotebookViewController(
            pageCount: 3, initialDrawing: drawing,
            toolStore: injectStore ? NotebookTestFixtures.toolStore() : nil,
            allowsEditing: allowsEditing, paperView: paperView
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1_366, height: 1_024)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        let fixture = Fixture(controller: controller, window: window)
        do {
            try await waitForAppearance(controller, window: window, expectsToolbar: allowsEditing)
            return fixture
        } catch {
            fixture.close()
            throw error
        }
    }

    private func waitForAppearance(
        _ controller: NotebookViewController, window: UIWindow, expectsToolbar: Bool
    ) async throws {
        try await NotebookTestFixtures.waitUntil {
            controller.isCanvasVisible && controller.view.window === window
                && (!expectsToolbar || (controller.drawingToolStore?.isToolbarAvailable == true
                    && controller.canvasView.isFirstResponder))
        }
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
        weak var manager: UndoManager?
        var calls = 0
        var onChange: (() -> Void)?

        init(manager: UndoManager) { self.manager = manager }

        func register() {
            manager?.beginUndoGrouping()
            manager?.registerUndo(withTarget: self) { $0.change() }
            manager?.endUndoGrouping()
        }

        func change() {
            manager?.registerUndo(withTarget: self) { $0.change() }
            calls += 1
            onChange?()
        }
    }

    @MainActor
    private final class DrawingUndoTarget {
        weak var canvas: PKCanvasView?
        weak var manager: UndoManager?
        private(set) var calls = 0
        init(canvas: PKCanvasView, manager: UndoManager) {
            self.canvas = canvas
            self.manager = manager
        }
        func assign(_ drawing: PKDrawing) {
            guard let canvas else { return }
            let previous = canvas.drawing
            manager?.registerUndo(withTarget: self) { $0.assign(previous) }
            calls += 1
            canvas.drawing = drawing
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
