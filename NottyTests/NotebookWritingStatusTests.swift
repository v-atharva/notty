import Foundation
import NottyCore
import PencilKit
import SwiftUI
import UIKit
import XCTest
@testable import Notty

@MainActor
final class NotebookWritingStatusTests: XCTestCase {
    func testRetryClearsFailedPreservationFeedbackWithoutChangingPendingEdits() async throws {
        let (session, probe, root) = try await makeSession(failure: .storageFull)
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = session.makeCanvasSeed()
        session.recordCompletedEdit(
            PKDrawing(strokes: [NotebookTestFixtures.stroke()]), ownerID: seed.ownerID
        )
        await session.waitUntilSettled()
        let pending = session.pendingEdits
        await probe.setPreserveFailure(.storageFull)
        await session.saveRecoveryCopy()
        XCTAssertEqual(session.recoveryFailure, .storageFull)
        XCTAssertNotNil(session.recoveryMessage)
        await probe.setSuspendSave()
        await probe.setSaveFailure(nil)
        let callsBeforeRetry = await probe.saveCalls
        session.retrySave()
        try await waitForSuspendedSave(probe, after: callsBeforeRetry, session: session)
        XCTAssertNil(session.recoveryFailure)
        XCTAssertNil(session.recoveryMessage)
        XCTAssertEqual(session.pendingEdits, pending)
        await probe.releaseSave()
        await session.waitUntilSettled()
        XCTAssertTrue(session.pendingEdits.isEmpty)
        XCTAssertEqual(session.inputGate, .open)
    }

    func testRetryClearsSuccessfulPreservationFeedback() async throws {
        let (session, probe, root) = try await makeSession(failure: .storageFull)
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = session.makeCanvasSeed()
        session.recordCompletedEdit(
            PKDrawing(strokes: [NotebookTestFixtures.stroke()]), ownerID: seed.ownerID
        )
        await session.waitUntilSettled()
        await session.saveRecoveryCopy()
        XCTAssertTrue(session.canReopenSaved)
        XCTAssertNotNil(session.recoveryMessage)
        await probe.setSuspendSave()
        await probe.setSaveFailure(nil)
        let callsBeforeRetry = await probe.saveCalls
        session.retrySave()
        try await waitForSuspendedSave(probe, after: callsBeforeRetry, session: session)
        XCTAssertNil(session.recoveryMessage)
        XCTAssertNil(session.recoveryFailure)
        await probe.releaseSave()
        await session.waitUntilSettled()
        XCTAssertTrue(session.pendingEdits.isEmpty)
    }

    func testSaveFailureDoesNotResizeCanvasOrMoveViewport() async throws {
        let (session, probe, root) = try await makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = UIHostingController(rootView: NotebookScreen(session: session))
        let window = makeWindow(hosting)
        defer {
            notebookController(in: hosting)?.tearDown()
            window.isHidden = true
            window.rootViewController = nil
        }
        try await waitForUI { self.notebookController(in: hosting) != nil }
        hosting.view.layoutIfNeeded()
        let controller = try XCTUnwrap(notebookController(in: hosting))
        // This case controls session observations; native callback fixtures exercise the delegate separately.
        controller.canvasView.delegate = nil
        controller.canvasView.setZoomScale(0.75, animated: false)
        controller.canvasView.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
        try await settleLayout(hosting)
        let originalBounds = controller.canvasView.bounds.size
        let originalOffset = controller.canvasView.contentOffset
        let originalZoom = controller.canvasView.zoomScale
        let controllerID = ObjectIdentifier(controller)
        let generation = session.canvasGeneration
        let owner = try XCTUnwrap(session.canvasOwnerID)
        await probe.setSaveFailure(.storageFull)
        session.recordObservation(
            NotebookCanvasObservation(
                generation: 1,
                drawing: PKDrawing(strokes: [NotebookTestFixtures.stroke()]),
                capturedAt: Date(timeIntervalSince1970: 100), uptime: 10
            ), ownerID: owner
        )
        await session.waitUntilSettled()
        try await waitForUI { session.statusModel.state.status == .failed(.storageFull) }
        try await settleLayout(hosting)
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(notebookController(in: hosting))), controllerID)
        XCTAssertEqual(session.canvasGeneration, generation)
        XCTAssertEqual(controller.canvasView.bounds.size.width, originalBounds.width, accuracy: 0.5)
        XCTAssertEqual(controller.canvasView.bounds.size.height, originalBounds.height, accuracy: 0.5)
        XCTAssertEqual(controller.canvasView.contentOffset.x, originalOffset.x, accuracy: 0.5)
        XCTAssertEqual(controller.canvasView.contentOffset.y, originalOffset.y, accuracy: 0.5)
        XCTAssertEqual(controller.canvasView.zoomScale, originalZoom, accuracy: 0.001)
    }


    func testSavingCaptionWaitsForDelayAndCancelledEpisodeCannotReturn() async throws {
        let clock = WritingFeedbackClock()
        let model = NotebookSavePresentationModel(delay: { await clock.wait($0) })
        let saved = NotebookSaveStatus.saved(Date(timeIntervalSince1970: 100))
        model.update(presentation(saved))
        model.update(presentation(.saving))
        let first = try await waitForRequest(clock, duration: .milliseconds(400))
        XCTAssertEqual(model.displayedStatus, saved)
        model.update(presentation(.saved(Date(timeIntervalSince1970: 101))))
        await clock.release(first)
        try await settleTasks()
        XCTAssertEqual(model.displayedStatus, .saved(Date(timeIntervalSince1970: 101)))
        model.update(presentation(.saving))
        let second = try await waitForRequest(clock, duration: .milliseconds(400))
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(model.displayedStatus, .saving)
        await clock.release(second)
        try await waitForUI { model.displayedStatus == .saving }
        model.update(presentation(.failed(.storageFull)))
        XCTAssertEqual(model.displayedStatus, .failed(.storageFull))
        model.reset()
        XCTAssertEqual(model.displayedStatus, .idle)
        await clock.releaseAll()
    }

    func testSuccessExpiryCannotClearNewerFailureAndDoesNotRebuildCanvas() async throws {
        let clock = WritingFeedbackClock()
        let (session, probe, root) = try await makeSession(
            failure: .storageFull, feedbackDelay: { await clock.wait($0) }
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = UIHostingController(rootView: NotebookScreen(session: session))
        let window = makeWindow(hosting)
        defer {
            notebookController(in: hosting)?.tearDown()
            window.isHidden = true
            window.rootViewController = nil
        }
        try await waitForUI { self.notebookController(in: hosting) != nil }
        let controller = try XCTUnwrap(notebookController(in: hosting))
        controller.canvasView.delegate = nil
        let owner = try XCTUnwrap(session.canvasOwnerID)
        let stroke = NotebookTestFixtures.stroke()
        session.recordObservation(
            NotebookCanvasObservation(generation: 1, drawing: PKDrawing(strokes: [stroke]),
                capturedAt: Date(timeIntervalSince1970: 100), uptime: 10), ownerID: owner
        )
        await session.waitUntilSettled()
        await session.saveRecoveryCopy()
        let oldExpiry = try await waitForRequest(clock, duration: .seconds(5))
        session.recordObservation(
            NotebookCanvasObservation(
                generation: 2, drawing: PKDrawing(strokes: [stroke, NotebookTestFixtures.stroke(x: 120)]),
                capturedAt: Date(timeIntervalSince1970: 101), uptime: 11
            ), ownerID: owner
        )
        await probe.setPreserveFailure(.storageFull)
        await session.saveRecoveryCopy()
        let failureMessage = session.recoveryMessage
        await clock.release(oldExpiry)
        try await settleTasks()
        XCTAssertEqual(session.recoveryFailure, .storageFull)
        XCTAssertEqual(session.recoveryMessage, failureMessage)
        await probe.setPreserveFailure(nil)
        await session.saveRecoveryCopy()
        let newExpiry = try await waitForRequest(clock, duration: .seconds(5))
        try await settleLayout(hosting)
        let screenBefore = session.renderDiagnostics.screenBodyCount
        let canvasBefore = session.renderDiagnostics.canvasUpdateCount
        let controllerID = ObjectIdentifier(controller)
        await clock.release(newExpiry)
        try await waitForUI { session.recoveryMessage == nil }
        try await settleLayout(hosting)
        XCTAssertNil(session.recoveryFailure)
        XCTAssertEqual(session.renderDiagnostics.screenBodyCount, screenBefore)
        XCTAssertEqual(session.renderDiagnostics.canvasUpdateCount, canvasBefore)
        XCTAssertEqual(notebookController(in: hosting).map(ObjectIdentifier.init), controllerID)
        await clock.releaseAll()
    }

    func testReopenInvalidatesPreviousFeedbackExpiryAndClearsFailure() async throws {
        let clock = WritingFeedbackClock()
        let (session, probe, root) = try await makeSession(
            failure: .storageFull, feedbackDelay: { await clock.wait($0) }
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = session.makeCanvasSeed()
        session.recordCompletedEdit(
            PKDrawing(strokes: [NotebookTestFixtures.stroke()]), ownerID: seed.ownerID
        )
        await session.waitUntilSettled()
        await probe.setPreserveFailure(.storageFull)
        await session.saveRecoveryCopy()
        await probe.setPreserveFailure(nil)
        await session.saveRecoveryCopy()
        let priorExpiry = try await waitForRequest(clock, duration: .seconds(5))
        let generation = session.canvasGeneration
        await session.reopenSavedNotebook()
        let reopenedExpiry = try await waitForRequest(clock, duration: .seconds(5), excluding: [priorExpiry])
        XCTAssertNotEqual(session.canvasGeneration, generation)
        XCTAssertNil(session.recoveryFailure)
        XCTAssertTrue(session.pendingEdits.isEmpty)
        let reopenedMessage = session.recoveryMessage
        XCTAssertNotNil(reopenedMessage)
        await clock.release(priorExpiry)
        try await settleTasks()
        XCTAssertEqual(session.recoveryMessage, reopenedMessage)
        await clock.release(reopenedExpiry)
        try await waitForUI { session.recoveryMessage == nil }
        XCTAssertNil(session.recoveryFailure)
        await clock.releaseAll()
    }

    func testRecoveryPresentationRechecksNativeActivityBeforeSuppressingPalette() async throws {
        let (session, probe, root) = try await makeSession(failure: .storageFull)
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = session.makeCanvasSeed()
        let controls = WritingCanvasControlsProbe()
        session.attachCanvas(ownerID: seed.ownerID, observations: { nil }, controls: controls.controls)
        XCTAssertTrue(session.commandModel.state.canOpenRecoveryCopies)
        // Native state may change before SwiftUI renders its disabled state.
        controls.availability = NotebookUndoAvailability(canUndo: true, canRedo: false, isUsingTool: true)
        XCTAssertFalse(session.beginRecoveryCopiesPresentation())
        XCTAssertEqual(controls.paletteSuppressions, [false])
        session.recordObservation(
            NotebookCanvasObservation(
                generation: 1, drawing: nearEndDrawing(),
                capturedAt: Date(timeIntervalSince1970: 10), uptime: 1
            ), ownerID: seed.ownerID
        )
        await session.waitUntilSettled()
        let original = session.pendingEdits
        controls.availability = NotebookUndoAvailability(canUndo: true, canRedo: false, isUsingTool: false)
        session.updateUndoAvailability(controls.availability, ownerID: seed.ownerID)
        XCTAssertTrue(session.beginRecoveryCopiesPresentation())
        XCTAssertEqual(controls.paletteSuppressions, [false, true])
        session.endRecoveryCopiesPresentation()
        XCTAssertEqual(controls.paletteSuppressions, [false, true, false])
        XCTAssertEqual(session.inputGate, .failed)
        XCTAssertEqual(session.pendingEdits, original)
        let calls = await probe.saveCalls
        XCTAssertEqual(calls, 1)
    }

    func testCommandAndPaletteCallbacksRejectReplacedCanvasOwners() async throws {
        let (session, _, root) = try await makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = session.makeCanvasSeed()
        let first = WritingCanvasControlsProbe()
        first.availability = NotebookUndoAvailability(canUndo: true, canRedo: true, isUsingTool: false)
        session.attachCanvas(ownerID: old.ownerID, observations: { nil }, controls: first.controls)
        XCTAssertTrue(session.canPerformHistoryAction(ownerID: old.ownerID))
        XCTAssertTrue(session.reserveHistoryAction(ownerID: old.ownerID))
        session.undo()
        session.redo()
        XCTAssertEqual(first.undoCalls, 1)
        XCTAssertEqual(first.redoCalls, 1)
        let replacement = session.makeCanvasSeed()
        let second = WritingCanvasControlsProbe()
        second.availability = NotebookUndoAvailability(canUndo: true, canRedo: false, isUsingTool: true)
        session.attachCanvas(ownerID: replacement.ownerID, observations: { nil }, controls: second.controls)
        session.updateUndoAvailability(.unavailable, ownerID: old.ownerID)
        session.detachCanvas(ownerID: old.ownerID)
        XCTAssertFalse(session.reserveHistoryAction(ownerID: old.ownerID))
        XCTAssertFalse(session.beginRecoveryCopiesPresentation())
        session.undo()
        session.redo()
        XCTAssertEqual(first.undoCalls, 1)
        XCTAssertEqual(first.redoCalls, 1)
        XCTAssertEqual(second.undoCalls, 0)
        XCTAssertEqual(second.redoCalls, 0)
        XCTAssertTrue(session.commandModel.state.isUsingTool)
        second.availability = NotebookUndoAvailability(canUndo: true, canRedo: false, isUsingTool: false)
        session.updateUndoAvailability(second.availability, ownerID: replacement.ownerID)
        XCTAssertTrue(session.beginRecoveryCopiesPresentation())
        session.endRecoveryCopiesPresentation()
        XCTAssertEqual(first.paletteSuppressions, [false])
        XCTAssertEqual(second.paletteSuppressions, [false, true, false])
    }

    func testDeferredExtentUsesCurrentLateObservationAndOriginalRequestStampBeforeOpeningGate() async throws {
        let (session, probe, root) = try await makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        await probe.setSuspendSave()
        let seed = session.makeCanvasSeed()
        let controls = WritingCanvasControlsProbe()
        var openedPages: [Int] = []
        session.attachCanvas(
            ownerID: seed.ownerID, observations: { nil },
            applyInputGate: { gate in
                if gate == .open { openedPages.append(session.pageCount) }
            }, controls: controls.controls
        )
        let first = nearEndDrawing()
        for index in 1...8 {
            session.recordObservation(
                NotebookCanvasObservation(
                    generation: UInt64(index), drawing: first,
                    capturedAt: Date(timeIntervalSince1970: Double(index)), uptime: Double(index)
                ), ownerID: seed.ownerID
            )
        }
        try await waitForSuspendedSave(probe, after: 0, session: session)
        let accepted = session.pendingEdits
        let request = NotebookToolCompletion(
            generation: 8, pageCount: 3, nearPaperEnd: true,
            capturedAt: Date(timeIntervalSince1970: 8), uptime: 8
        )
        session.completedTool(request, ownerID: seed.ownerID)
        session.completedTool(request, ownerID: seed.ownerID)
        XCTAssertEqual(session.pageCount, 3)
        let later = nearEndDrawing(x: 120)
        session.recordObservation(
            NotebookCanvasObservation(
                generation: 9, drawing: later,
                capturedAt: Date(timeIntervalSince1970: 9), uptime: 9
            ), ownerID: seed.ownerID
        )
        let laterEdit = try XCTUnwrap(session.pendingEdits.last)
        XCTAssertEqual(session.pendingEdits.prefix(8).map(\.id), accepted.map(\.id))
        // Drain the original batch, leaving the current drawing and extent saves gated.
        for index in 1...8 {
            await probe.releaseSave(suspendNext: true)
            try await waitForSuspendedSave(probe, after: index, session: session)
        }
        let tail = session.pendingEdits
        XCTAssertEqual(tail.count, 2)
        XCTAssertEqual(tail.first, laterEdit)
        let extent = try XCTUnwrap(tail.last)
        XCTAssertNotEqual(extent.id, laterEdit.id)
        XCTAssertFalse(accepted.map(\.id).contains(extent.id))
        XCTAssertEqual(extent.snapshot.drawing.strokes.map(\.id), later.strokes.map(\.id))
        XCTAssertEqual(extent.snapshot.pageCount, 4)
        XCTAssertEqual(extent.stamp.capturedAt, request.capturedAt)
        XCTAssertEqual(extent.stamp.uptime, request.uptime)
        XCTAssertEqual(extent.stamp.sessionID, accepted.last?.stamp.sessionID)
        XCTAssertEqual(controls.appliedPageCounts, [4])
        XCTAssertEqual(session.pageCount, 4)
        XCTAssertFalse(openedPages.dropFirst().contains(3))
        await probe.releaseSave()
        await session.waitUntilSettled()
        XCTAssertEqual(session.inputGate, .open)
        XCTAssertTrue(session.pendingEdits.isEmpty)
        let storage = await probe.storage(notebookID: session.notebookID)
        let saved = try await storage.load()
        XCTAssertEqual(saved?.content.pageCount, 4)
        XCTAssertEqual(saved?.content.editStamp, extent.stamp)
        XCTAssertEqual(saved?.content.strokes.map(\.id), later.strokes.map(\.id))
    }

    func testDeferredExtentIsDiscardedWhenCurrentDrawingFallsBelowThreshold() async throws {
        let (session, probe, root) = try await makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        await probe.setSuspendSave()
        let seed = session.makeCanvasSeed()
        let controls = WritingCanvasControlsProbe()
        session.attachCanvas(ownerID: seed.ownerID, observations: { nil }, controls: controls.controls)
        for index in 1...8 {
            session.recordObservation(
                NotebookCanvasObservation(
                    generation: UInt64(index), drawing: nearEndDrawing(),
                    capturedAt: Date(timeIntervalSince1970: Double(index)), uptime: Double(index)
                ), ownerID: seed.ownerID
            )
        }
        try await waitForSuspendedSave(probe, after: 0, session: session)
        session.completedTool(
            NotebookToolCompletion(generation: 8, pageCount: 3, nearPaperEnd: true,
                capturedAt: Date(timeIntervalSince1970: 8), uptime: 8), ownerID: seed.ownerID
        )
        session.recordObservation(
            NotebookCanvasObservation(generation: 9, drawing: PKDrawing(),
                capturedAt: Date(timeIntervalSince1970: 9), uptime: 9), ownerID: seed.ownerID
        )
        let pending = session.pendingEdits
        await probe.releaseSave()
        await session.waitUntilSettled()
        XCTAssertEqual(session.pageCount, 3)
        XCTAssertTrue(controls.appliedPageCounts.isEmpty)
        let calls = await probe.saveCalls
        XCTAssertEqual(calls, 9)
        let storage = await probe.storage(notebookID: session.notebookID)
        let saved = try await storage.load()
        XCTAssertTrue(try XCTUnwrap(saved).content.strokes.isEmpty)
        XCTAssertEqual(saved?.content.editStamp, pending.last?.stamp)
    }

    func testExtentWaitsForInactivityAndClearsOnOwnerReplacement() async throws {
        let (session, probe, root) = try await makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = session.makeCanvasSeed()
        let controls = WritingCanvasControlsProbe()
        controls.availability = NotebookUndoAvailability(canUndo: false, canRedo: false, isUsingTool: true)
        session.attachCanvas(ownerID: seed.ownerID, observations: { nil }, controls: controls.controls)
        session.recordObservation(
            NotebookCanvasObservation(generation: 1, drawing: nearEndDrawing(),
                capturedAt: Date(timeIntervalSince1970: 10), uptime: 10), ownerID: seed.ownerID
        )
        session.completedTool(
            NotebookToolCompletion(generation: 1, pageCount: 3, nearPaperEnd: true,
                capturedAt: Date(timeIntervalSince1970: 10), uptime: 10), ownerID: seed.ownerID
        )
        await session.waitUntilSettled()
        XCTAssertEqual(session.pageCount, 3)
        XCTAssertTrue(controls.appliedPageCounts.isEmpty)
        let replacement = session.makeCanvasSeed()
        let newer = WritingCanvasControlsProbe()
        session.attachCanvas(ownerID: replacement.ownerID, observations: { nil }, controls: newer.controls)
        session.updateUndoAvailability(.unavailable, ownerID: replacement.ownerID)
        XCTAssertEqual(session.pageCount, 3)
        session.completedTool(
            NotebookToolCompletion(generation: 1, pageCount: 3, nearPaperEnd: true,
                capturedAt: Date(timeIntervalSince1970: 10), uptime: 10), ownerID: seed.ownerID
        )
        XCTAssertTrue(newer.appliedPageCounts.isEmpty)
        let calls = await probe.saveCalls
        XCTAssertEqual(calls, 1)
    }

    func testExtentWaitsForInactivityThenAddsOneMetadataEditWithOriginalStamp() async throws {
        let (session, probe, root) = try await makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = session.makeCanvasSeed()
        let controls = WritingCanvasControlsProbe()
        controls.availability = NotebookUndoAvailability(canUndo: false, canRedo: false, isUsingTool: true)
        session.attachCanvas(ownerID: seed.ownerID, observations: { nil }, controls: controls.controls)
        let drawing = nearEndDrawing()
        session.recordObservation(
            NotebookCanvasObservation(generation: 1, drawing: drawing,
                capturedAt: Date(timeIntervalSince1970: 10), uptime: 10), ownerID: seed.ownerID
        )
        session.completedTool(
            NotebookToolCompletion(generation: 1, pageCount: 3, nearPaperEnd: true,
                capturedAt: Date(timeIntervalSince1970: 10), uptime: 10), ownerID: seed.ownerID
        )
        await session.waitUntilSettled()
        XCTAssertEqual(session.pageCount, 3)
        controls.availability = .unavailable
        session.updateUndoAvailability(.unavailable, ownerID: seed.ownerID)
        XCTAssertEqual(session.pageCount, 4)
        await session.waitUntilSettled()
        let calls = await probe.saveCalls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(controls.appliedPageCounts, [4])
        let storage = await probe.storage(notebookID: session.notebookID)
        let saved = try await storage.load()
        XCTAssertEqual(saved?.content.strokes.map(\.id), drawing.strokes.map(\.id))
        XCTAssertEqual(saved?.content.editStamp?.capturedAt, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(saved?.content.editStamp?.uptime, 10)
    }

    func testFailedSaveDiscardsUnacceptedExtentWithoutDroppingDrawingEdit() async throws {
        let (session, probe, root) = try await makeSession(failure: .storageFull)
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = session.makeCanvasSeed()
        let controls = WritingCanvasControlsProbe()
        controls.availability = NotebookUndoAvailability(canUndo: false, canRedo: false, isUsingTool: true)
        session.attachCanvas(ownerID: seed.ownerID, observations: { nil }, controls: controls.controls)
        session.recordObservation(
            NotebookCanvasObservation(generation: 1, drawing: nearEndDrawing(),
                capturedAt: Date(timeIntervalSince1970: 10), uptime: 10), ownerID: seed.ownerID
        )
        let accepted = session.pendingEdits
        session.completedTool(
            NotebookToolCompletion(generation: 1, pageCount: 3, nearPaperEnd: true,
                capturedAt: Date(timeIntervalSince1970: 10), uptime: 10), ownerID: seed.ownerID
        )
        await session.waitUntilSettled()
        XCTAssertEqual(session.pendingEdits, accepted)
        controls.availability = .unavailable
        session.updateUndoAvailability(.unavailable, ownerID: seed.ownerID)
        await probe.setSaveFailure(nil)
        session.retrySave()
        await session.waitUntilSettled()
        XCTAssertEqual(session.pageCount, 3)
        XCTAssertTrue(controls.appliedPageCounts.isEmpty)
        XCTAssertTrue(session.pendingEdits.isEmpty)
    }

    private func presentation(_ status: NotebookSaveStatus) -> NotebookSavePresentation {
        NotebookSavePresentation(
            status: status, inputPaused: false, performingRecovery: false,
            canPreserveRecovery: false, canReopenSaved: false,
            recoveryMessage: nil, recoveryFailure: nil, isReady: true
        )
    }

    private func nearEndDrawing(x: CGFloat = 20) -> PKDrawing {
        var stroke = NotebookTestFixtures.stroke(x: x)
        stroke.transform = CGAffineTransform(
            translationX: 0, y: CGFloat(NotebookPaperMetrics.geometry.pageHeight) * 2.9
        )
        return PKDrawing(strokes: [stroke])
    }

    private func waitForRequest(
        _ clock: WritingFeedbackClock, duration: Duration, excluding: Set<UUID> = []
    ) async throws -> UUID {
        for _ in 0..<100 {
            let requests = await clock.requests(for: duration)
            if let request = requests.first(where: { !excluding.contains($0) }) { return request }
            try await Task.sleep(for: .milliseconds(20))
        }
        await clock.releaseAll()
        XCTFail("The feedback timer did not begin within two seconds.")
        throw NotebookSaveFailure.unexpected
    }

    private func settleTasks() async throws {
        try await Task.sleep(for: .milliseconds(40))
    }

    private func waitForSuspendedSave(
        _ probe: NotebookStorageProbe, after previousCalls: Int, session: NotebookSession
    ) async throws {
        do {
            for _ in 0..<100 {
                if await probe.saveCalls > previousCalls { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("The retried save did not begin within two seconds.")
            throw NotebookSaveFailure.unexpected
        } catch {
            await probe.releaseSave()
            await session.waitUntilSettled()
            throw error
        }
    }

    private func makeSession(
        failure: NotebookSaveFailure? = nil,
        feedbackDelay: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> (NotebookSession, NotebookStorageProbe, URL) {
        let id = UUID()
        let root = NotebookTestFixtures.root()
        let stored = try await NotebookTestFixtures.stored(id: id)
        let probe = try NotebookStorageProbe(stored: stored, recoveryRoot: root)
        await probe.setSaveFailure(failure)
        let storage = await probe.storage(notebookID: id)
        let session = NotebookSession(
            notebookID: id, openStorage: { storage }, feedbackDelay: feedbackDelay
        )
        await session.load()
        XCTAssertEqual(session.loadState, .ready)
        return (session, probe, root)
    }

    private func makeWindow(_ hosting: UIViewController) -> UIWindow {
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_024, height: 1_366))
        }
        window.frame = CGRect(x: 0, y: 0, width: 1_024, height: 1_366)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        hosting.view.layoutIfNeeded()
        return window
    }

    private func notebookController(in controller: UIViewController) -> NotebookViewController? {
        if let notebook = controller as? NotebookViewController { return notebook }
        for child in controller.children {
            if let notebook = notebookController(in: child) { return notebook }
        }
        return nil
    }

    private func settleLayout(_ hosting: UIViewController) async throws {
        try await Task.sleep(for: .milliseconds(100))
        hosting.view.layoutIfNeeded()
    }

    private func waitForUI(_ ready: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Writing status UI did not become ready within two seconds.")
        throw NotebookSaveFailure.unexpected
    }
}

@MainActor
private final class WritingCanvasControlsProbe {
    var availability = NotebookUndoAvailability.unavailable
    private(set) var undoCalls = 0
    private(set) var redoCalls = 0
    private(set) var paletteSuppressions: [Bool] = []
    private(set) var appliedPageCounts: [Int] = []

    var controls: NotebookCanvasControls {
        NotebookCanvasControls(
            undo: { [weak self] in self?.undoCalls += 1 },
            redo: { [weak self] in self?.redoCalls += 1 },
            setPaletteSuppressed: { [weak self] in self?.paletteSuppressions.append($0) },
            applyPageCount: { [weak self] in self?.appliedPageCounts.append($0) },
            currentAvailability: { [weak self] in self?.availability ?? .unavailable }
        )
    }
}

private actor WritingFeedbackClock {
    private struct Request {
        let duration: Duration
        let continuation: CheckedContinuation<Void, Never>
    }

    private var pending: [UUID: Request] = [:]

    func wait(_ duration: Duration) async {
        await withCheckedContinuation {
            pending[UUID()] = Request(duration: duration, continuation: $0)
        }
    }

    func requests(for duration: Duration) -> [UUID] {
        pending.filter { $0.value.duration == duration }.map(\.key)
    }

    func release(_ id: UUID) {
        pending.removeValue(forKey: id)?.continuation.resume()
    }

    func releaseAll() {
        let requests = Array(pending.values)
        pending.removeAll()
        requests.forEach { $0.continuation.resume() }
    }
}
