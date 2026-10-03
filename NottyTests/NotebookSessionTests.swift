import Foundation
import NottyCore
import PencilKit
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
}
