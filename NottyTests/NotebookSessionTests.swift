import Foundation
import NottyCore
import PencilKit
import SwiftUI
import UIKit
import XCTest
@testable import Notty

@MainActor
final class NotebookSessionTests: XCTestCase {
    private func setup(
        failure: NotebookSaveFailure = .contentLimit
    ) async throws -> (NotebookSession, NotebookStorageProbe, URL) {
        let id = UUID()
        let root = NotebookTestFixtures.root()
        let stored = try await NotebookTestFixtures.stored(id: id)
        let probe = try NotebookStorageProbe(stored: stored, recoveryRoot: root)
        await probe.setSaveFailure(failure)
        let storage = await probe.storage(notebookID: id)
        let session = NotebookSession(notebookID: id, openStorage: { storage })
        await session.load()
        return (session, probe, root)
    }

    func testPermanentFailurePreservesOrderedWorkingEditsAndRecoveryCopy() async throws {
        let (session, probe, root) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = session.makeCanvasSeed()
        let first = PKDrawing(strokes: [NotebookTestFixtures.stroke()])
        let undone = PKDrawing()
        session.recordCompletedEdit(first, ownerID: seed.ownerID)
        session.recordCompletedEdit(undone, ownerID: seed.ownerID)
        await session.waitUntilSettled()
        let pending = session.pendingEdits
        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(session.saveState, .failed(.contentLimit))
        XCTAssertEqual(session.inputGate, .failed)
        XCTAssertFalse(session.canEdit)
        session.retrySave()
        await session.waitUntilSettled()
        let calls = await probe.saveCalls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(session.pendingEdits, pending)

        await session.saveRecoveryCopy()
        XCTAssertTrue(session.canReopenSaved)
        XCTAssertEqual(session.pendingEdits, pending)
        let preservedBatch = await probe.preservedBatch
        let batch = try XCTUnwrap(preservedBatch)
        XCTAssertEqual(batch.edits.map(\.id), pending.map(\.id))
        XCTAssertEqual(batch.edits.map(\.stamp), pending.map(\.stamp))
        XCTAssertEqual(batch.edits.map(\.strokeIDs), pending.map { $0.snapshot.drawing.strokes.map(\.id) })
        await session.refreshRecoveryCopies()
        XCTAssertEqual(session.recoveryCopies.count, 1)
        let restoredBatch = try await session.openRecoveryCopy(id: session.recoveryCopies[0].id)
        XCTAssertEqual(restoredBatch, batch)
        await session.reopenSavedNotebook()
        XCTAssertEqual(session.loadState, .ready)
        XCTAssertEqual(session.pendingEdits.count, 0)
        XCTAssertTrue(session.canEdit)
        XCTAssertTrue(session.workingDrawing.strokes.isEmpty)
        await session.refreshRecoveryCopies()
        XCTAssertEqual(session.recoveryCopies.count, 1)
    }

    func testFailedRecoveryAndFailedCommittedRereadRetainUnsavedState() async throws {
        let (session, probe, root) = try await setup(failure: .revisionConflict)
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = session.makeCanvasSeed()
        let drawing = PKDrawing(strokes: [NotebookTestFixtures.stroke()])
        session.recordCompletedEdit(drawing, ownerID: seed.ownerID)
        await session.waitUntilSettled()
        let pending = session.pendingEdits
        await probe.setPreserveFailure(.storageFull)
        await session.saveRecoveryCopy()
        XCTAssertEqual(session.recoveryFailure, .storageFull)
        XCTAssertFalse(session.canReopenSaved)
        await session.reopenSavedNotebook()
        XCTAssertEqual(session.pendingEdits, pending)

        await probe.setPreserveFailure(nil)
        await session.saveRecoveryCopy()
        XCTAssertTrue(session.canReopenSaved)
        await probe.setLoadFailure(.corruptData)
        await session.reopenSavedNotebook()
        XCTAssertEqual(session.recoveryFailure, .corruptData)
        XCTAssertEqual(session.pendingEdits, pending)
        XCTAssertEqual(session.workingDrawing.strokes.map(\.id), drawing.strokes.map(\.id))
        XCTAssertTrue(session.canReopenSaved)
        XCTAssertEqual(session.saveState, .failed(.revisionConflict))
    }

    func testCompletedEditDuringPreserveInvalidatesReceiptUntilAnotherCopy() async throws {
        let (session, probe, root) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = session.makeCanvasSeed()
        session.recordCompletedEdit(
            PKDrawing(strokes: [NotebookTestFixtures.stroke()]), ownerID: seed.ownerID
        )
        await session.waitUntilSettled()
        let original = session.pendingEdits
        await probe.setSuspendPreserve()
        let preserving = Task { await session.saveRecoveryCopy() }
        await probe.waitForPreserve()
        XCTAssertEqual(session.inputGate, .recovering)
        session.recordCompletedEdit(PKDrawing(), ownerID: seed.ownerID)
        await probe.releasePreserve()
        await preserving.value
        XCTAssertFalse(session.canReopenSaved)
        XCTAssertEqual(Array(session.pendingEdits.prefix(1)), original)
        XCTAssertEqual(session.pendingEdits.count, 2)
        await session.reopenSavedNotebook()
        XCTAssertEqual(session.pendingEdits.count, 2)
        await session.saveRecoveryCopy()
        XCTAssertTrue(session.canReopenSaved)
        await session.refreshRecoveryCopies()
        XCTAssertEqual(session.recoveryCopies.count, 2)
    }

    func testControllerReplacementUsesCurrentWorkingInkAndRejectsOldOwner() async throws {
        let (session, _, root) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldSeed = session.makeCanvasSeed()
        let drawing = PKDrawing(strokes: [NotebookTestFixtures.stroke()])
        session.attachCanvas(ownerID: oldSeed.ownerID) { drawing }
        let newSeed = session.makeCanvasSeed()
        XCTAssertEqual(newSeed.drawing.strokes.map(\.id), drawing.strokes.map(\.id))
        let pending = session.pendingEdits
        XCTAssertFalse(session.recordCompletedEdit(PKDrawing(), ownerID: oldSeed.ownerID))
        session.detachCanvas(ownerID: oldSeed.ownerID)
        XCTAssertEqual(session.pendingEdits, pending)
        XCTAssertEqual(session.workingDrawing.strokes.map(\.id), drawing.strokes.map(\.id))
        await session.waitUntilSettled()
    }

    func testFailedLoadNeverInitializesBlankNotebook() async {
        let session = NotebookSession(openStorage: { throw NotebookSaveFailure.corruptData })
        await session.load()
        XCTAssertEqual(session.loadState, .failed(.corruptData))
        XCTAssertFalse(session.canEdit)
        XCTAssertTrue(session.pendingEdits.isEmpty)
        await session.saveRecoveryCopy()
        XCTAssertFalse(session.canReopenSaved)
    }

    func testDiskFullRetryUsesOriginalEditsWithoutChangingTheirCapturedStamps() async throws {
        let (session, probe, root) = try await setup(failure: .storageFull)
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = session.makeCanvasSeed()
        let drawing = PKDrawing(strokes: [NotebookTestFixtures.stroke()])
        session.recordCompletedEdit(drawing, ownerID: seed.ownerID)
        await session.waitUntilSettled()
        let captured = session.pendingEdits[0].stamp
        XCTAssertEqual(session.saveState, .failed(.storageFull))
        await probe.setSaveFailure(nil)
        session.retrySave()
        await session.waitUntilSettled()
        XCTAssertTrue(session.canEdit)
        let storage = await probe.storage(notebookID: session.notebookID)
        let reopened = try await storage.load()
        XCTAssertEqual(reopened?.content.editStamp, captured)
        XCTAssertEqual(reopened?.content.strokes.map(\.id), drawing.strokes.map(\.id))
    }

    func testCompletedEditDuringCommittedRereadPreventsDestructiveReopen() async throws {
        let (session, probe, root) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = session.makeCanvasSeed()
        let first = NotebookTestFixtures.stroke()
        session.recordCompletedEdit(PKDrawing(strokes: [first]), ownerID: seed.ownerID)
        await session.waitUntilSettled()
        await session.saveRecoveryCopy()
        XCTAssertTrue(session.canReopenSaved)
        let original = session.pendingEdits
        await probe.setSuspendLoad()
        let reopening = Task { await session.reopenSavedNotebook() }
        await probe.waitForLoad()
        let late = PKDrawing(strokes: [first, NotebookTestFixtures.stroke(x: 120)])
        session.recordCompletedEdit(late, ownerID: seed.ownerID)
        await probe.releaseLoad()
        await reopening.value
        XCTAssertEqual(session.loadState, .ready)
        XCTAssertEqual(session.saveState, .failed(.contentLimit))
        XCTAssertEqual(session.recoveryFailure, .invalidContent)
        XCTAssertEqual(Array(session.pendingEdits.prefix(1)), original)
        XCTAssertEqual(session.pendingEdits.count, 2)
        XCTAssertEqual(session.workingDrawing.strokes.map(\.id), late.strokes.map(\.id))
        XCTAssertFalse(session.canReopenSaved)
        await session.refreshRecoveryCopies()
        XCTAssertEqual(session.recoveryCopies.count, 1)
    }


    func testSessionCapacityReasonResumesWithoutLosingQueuedEdits() async throws {
        let id = UUID()
        let root = NotebookTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let stored = try await NotebookTestFixtures.stored(id: id)
        let probe = try NotebookStorageProbe(stored: stored, recoveryRoot: root)
        await probe.setSuspendSave()
        let storage = await probe.storage(notebookID: id)
        let session = NotebookSession(notebookID: id, openStorage: { storage })
        await session.load()
        let seed = session.makeCanvasSeed()
        XCTAssertEqual(session.inputGate, .open)
        XCTAssertEqual(session.inputGateForCanvas(ownerID: seed.ownerID), .open)
        for _ in 0..<8 { session.extendPaper() }
        await probe.waitForSave()
        XCTAssertEqual(session.pendingEdits.count, 8)
        XCTAssertEqual(session.inputGate, .capacity)
        XCTAssertEqual(session.inputGateForCanvas(ownerID: seed.ownerID), .capacity)
        XCTAssertEqual(session.inputGateForCanvas(ownerID: UUID()), .readOnly)
        XCTAssertFalse(session.canEdit)
        let pending = session.pendingEdits
        let pages = session.pageCount
        session.extendPaper()
        XCTAssertEqual(session.pageCount, pages)
        XCTAssertEqual(session.pendingEdits, pending)
        await probe.releaseSave()
        await session.waitUntilSettled()
        XCTAssertTrue(session.pendingEdits.isEmpty)
        XCTAssertEqual(session.inputGate, .open)
        XCTAssertTrue(session.canEdit)
        let saved = try await storage.load()
        XCTAssertEqual(saved?.content.pageCount, pages)
        XCTAssertEqual(saved?.content.editStamp, pending.last?.stamp)
        let calls = await probe.saveCalls
        XCTAssertEqual(calls, 8)
    }

    func testOwnerScopedGenerationsRetainEqualDrawingStatesAndOriginalObservationStamps() async throws {
        let (session, probe, root) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = session.makeCanvasSeed()
        let drawing = PKDrawing(strokes: [NotebookTestFixtures.stroke()])
        let first = NotebookCanvasObservation(
            generation: 1, drawing: drawing, capturedAt: Date(timeIntervalSince1970: 123), uptime: 45
        )
        let second = NotebookCanvasObservation(
            generation: 2, drawing: drawing, capturedAt: Date(timeIntervalSince1970: 124), uptime: 46
        )
        session.recordObservation(first, ownerID: seed.ownerID)
        session.recordObservation(second, ownerID: seed.ownerID)
        session.recordObservation(second, ownerID: seed.ownerID)
        let original = session.pendingEdits
        XCTAssertEqual(original.count, 2)
        XCTAssertEqual(original.map(\.stamp.capturedAt), [first.capturedAt, second.capturedAt])
        XCTAssertEqual(original.map(\.stamp.uptime), [45, 46])
        XCTAssertEqual(Set(original.map(\.id)).count, 2)
        let nextSeed = session.makeCanvasSeed()
        XCTAssertFalse(session.recordObservation(
            NotebookCanvasObservation(
                generation: 3, drawing: PKDrawing(), capturedAt: Date(), uptime: 100
            ), ownerID: seed.ownerID
        ))
        XCTAssertEqual(session.pendingEdits, original)
        session.recordObservation(
            NotebookCanvasObservation(
                generation: 1, drawing: PKDrawing(), capturedAt: Date(timeIntervalSince1970: 125), uptime: 47
            ), ownerID: nextSeed.ownerID
        )
        let all = session.pendingEdits
        await session.waitUntilSettled()
        await session.saveRecoveryCopy()
        XCTAssertTrue(session.canReopenSaved)
        let preserved = await probe.preservedBatch
        let batch = try XCTUnwrap(preserved)
        XCTAssertEqual(batch.edits.map(\.id), all.map(\.id))
        XCTAssertEqual(batch.edits.map(\.stamp), all.map(\.stamp))
        XCTAssertEqual(session.pendingEdits, all)
    }

    func testLaterCodecFailureStillPublishesEarlierValidEditAndRetainsExactTail() async throws {
        let (session, probe, root) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        await probe.setSaveFailure(nil)
        let seed = session.makeCanvasSeed()
        let template = NotebookTestFixtures.stroke()
        let tooMany = (0...InkCodec.maximumStrokeCount).map { _ in
            var stroke = template
            stroke.id = UUID()
            return stroke
        }
        let drawings = [
            PKDrawing(strokes: [template]), PKDrawing(strokes: tooMany), PKDrawing()
        ]
        for (index, drawing) in drawings.enumerated() {
            session.recordObservation(
                NotebookCanvasObservation(
                    generation: UInt64(index + 1), drawing: drawing,
                    capturedAt: Date(timeIntervalSince1970: Double(index + 10)),
                    uptime: Double(index + 20)
                ), ownerID: seed.ownerID
            )
        }
        let original = session.pendingEdits
        await session.waitUntilSettled()
        XCTAssertEqual(session.saveState, .failed(.contentLimit))
        XCTAssertEqual(session.pendingEdits, Array(original.dropFirst()))
        let calls = await probe.saveCalls
        XCTAssertEqual(calls, 1)
        await session.saveRecoveryCopy()
        XCTAssertTrue(session.canReopenSaved)
        let batch = await probe.preservedBatch
        XCTAssertEqual(batch?.edits.map(\.id), Array(original.dropFirst()).map(\.id))
        XCTAssertEqual(batch?.edits.map(\.stamp), Array(original.dropFirst()).map(\.stamp))
    }

    func testTwentyEditsWithUnchangedGateDoNotRebuildScreenOrUpdateRepresentable() async throws {
        let (session, probe, root) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        await probe.setSaveFailure(nil)
        let hosting = UIHostingController(rootView: NotebookScreen(session: session))
        let window = try NotebookTestFixtures.window(showing: hosting)
        defer {
            notebookController(in: hosting)?.tearDown()
            window.isHidden = true
        }
        try await NotebookTestFixtures.waitUntil {
            session.renderDiagnostics.screenBodyCount > 0
                && session.renderDiagnostics.canvasUpdateCount > 0
                && self.notebookController(in: hosting) != nil
        }
        try await Task.sleep(for: .milliseconds(80))
        hosting.view.layoutIfNeeded()
        let controller = try XCTUnwrap(notebookController(in: hosting))
        let controllerID = ObjectIdentifier(controller)
        let screenBefore = session.renderDiagnostics.screenBodyCount
        let canvasBefore = session.renderDiagnostics.canvasUpdateCount
        let generation = session.canvasGeneration
        let ownerID = try XCTUnwrap(session.canvasOwnerID)
        for index in 1...20 {
            session.recordObservation(
                NotebookCanvasObservation(
                    generation: UInt64(index),
                    drawing: PKDrawing(strokes: [NotebookTestFixtures.stroke(x: CGFloat(index))]),
                    capturedAt: Date(timeIntervalSince1970: Double(index)), uptime: Double(index)
                ), ownerID: ownerID
            )
            await session.waitUntilSettled()
            XCTAssertEqual(session.inputGate, .open)
        }
        try await NotebookTestFixtures.waitUntil { session.statusModel.state.status == session.saveState }
        // Let two display frames drain queued SwiftUI updates before checking counters.
        try await Task.sleep(for: .milliseconds(80))
        hosting.view.layoutIfNeeded()
        XCTAssertEqual(session.renderDiagnostics.screenBodyCount, screenBefore)
        XCTAssertEqual(session.renderDiagnostics.canvasUpdateCount, canvasBefore)
        XCTAssertEqual(session.canvasGeneration, generation)
        XCTAssertEqual(notebookController(in: hosting).map(ObjectIdentifier.init), controllerID)
        let calls = await probe.saveCalls
        XCTAssertEqual(calls, 20)
        print("Notty UI generation work: edits=20 screenBodies=\(session.renderDiagnostics.screenBodyCount - screenBefore) canvasUpdates=\(session.renderDiagnostics.canvasUpdateCount - canvasBefore)")
    }

    func testAsyncSaveCompletionPushesGateDirectlyWithoutAnyRepresentableUpdate() async throws {
        let (session, probe, root) = try await setup()
        defer { try? FileManager.default.removeItem(at: root) }
        await probe.setSaveFailure(nil)
        await probe.setSuspendSave()
        let seed = session.makeCanvasSeed()
        let controller = NotebookViewController(pageCount: seed.pageCount, initialDrawing: seed.drawing)
        controller.loadViewIfNeeded()
        session.attachCanvas(
            ownerID: seed.ownerID,
            observations: { [weak controller] in controller?.captureBarrier() },
            applyInputGate: { [weak controller] in controller?.setInputGate($0) }
        )
        defer { controller.tearDown() }
        for index in 1...8 {
            session.recordObservation(
                NotebookCanvasObservation(
                    generation: UInt64(index),
                    drawing: PKDrawing(strokes: [NotebookTestFixtures.stroke(x: CGFloat(index))]),
                    capturedAt: Date(timeIntervalSince1970: Double(index)), uptime: Double(index)
                ), ownerID: seed.ownerID
            )
        }
        await probe.waitForSave()
        XCTAssertEqual(controller.inputGate, .capacity)
        XCTAssertFalse(controller.canvasView.drawingGestureRecognizer.isEnabled)
        XCTAssertEqual(session.renderDiagnostics.canvasUpdateCount, 0)
        await probe.releaseSave()
        await session.waitUntilSettled()
        XCTAssertTrue(session.pendingEdits.isEmpty)
        XCTAssertEqual(controller.inputGate, .open)
        XCTAssertTrue(controller.canvasView.isDrawingEnabled)
        XCTAssertTrue(controller.canvasView.drawingGestureRecognizer.isEnabled)
        XCTAssertEqual(session.renderDiagnostics.canvasUpdateCount, 0)
        let replacement = session.makeCanvasSeed()
        let newer = NotebookViewController(pageCount: replacement.pageCount, initialDrawing: replacement.drawing)
        newer.loadViewIfNeeded()
        session.attachCanvas(
            ownerID: replacement.ownerID, observations: { nil },
            applyInputGate: { [weak newer] in newer?.setInputGate($0) }
        )
        session.detachCanvas(ownerID: seed.ownerID)
        await probe.setSuspendSave()
        for index in 1...8 {
            session.recordObservation(
                NotebookCanvasObservation(
                    generation: UInt64(index),
                    drawing: PKDrawing(strokes: [NotebookTestFixtures.stroke(x: CGFloat(index + 20))]),
                    capturedAt: Date(timeIntervalSince1970: Double(index + 20)), uptime: Double(index + 20)
                ), ownerID: replacement.ownerID
            )
        }
        await probe.waitForSave()
        XCTAssertEqual(newer.inputGate, .capacity)
        XCTAssertEqual(controller.inputGate, .open)
        await probe.releaseSave()
        await session.waitUntilSettled()
        XCTAssertEqual(newer.inputGate, .open)
        XCTAssertEqual(controller.inputGate, .open)
        session.detachCanvas(ownerID: replacement.ownerID)
        newer.tearDown()
    }

    private func notebookController(in controller: UIViewController) -> NotebookViewController? {
        if let notebook = controller as? NotebookViewController { return notebook }
        for child in controller.children {
            if let notebook = notebookController(in: child) { return notebook }
        }
        return nil
    }
}
