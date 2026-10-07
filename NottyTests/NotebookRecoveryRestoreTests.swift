import CryptoKit
import Foundation
import NottyCore
import PencilKit
import SwiftUI
import UIKit
import XCTest
@testable import Notty

@MainActor
final class NotebookRecoveryRestoreTests: XCTestCase {
    func testRestorePublishesFreshIdentityAndStampWithSeparateOriginalProvenance() async throws {
        let fixture = try await RestoreFixture()
        defer { fixture.remove() }
        let advanced = try await fixture.repository.save(
            id: fixture.notebookID,
            content: NotebookContent(title: "More recent title", pageCount: 4, strokes: fixture.initial.content.strokes,
                                     editStamp: NotebookTestFixtures.stamp(110)),
            expectedRevisionID: fixture.initial.revisionID
        )
        XCTAssertNotEqual(advanced.revisionID, fixture.initial.revisionID)
        let trace = RestoreStorageTrace(base: fixture.storage, suspendSave: true)
        let session = try await fixture.session(storage: await trace.storage())
        let originalGeneration = session.canvasGeneration
        let before = Date()
        let restored = await session.restoreRecoveryEdit(copyID: fixture.receipt.id, editID: fixture.state.id)
        XCTAssertTrue(restored)
        do {
            try await NotebookTestFixtures.waitUntil { await trace.saveEntered }
            let pending = try XCTUnwrap(session.pendingEdits.first)
            XCTAssertNotEqual(pending.id, fixture.state.id)
            XCTAssertNotEqual(pending.stamp, fixture.state.stamp)
            XCTAssertGreaterThanOrEqual(pending.stamp.capturedAt, before)
            XCTAssertLessThanOrEqual(pending.stamp.capturedAt, Date())
            XCTAssertEqual(pending.snapshot.title, fixture.state.title)
            XCTAssertEqual(pending.snapshot.pageCount, fixture.state.pageCount)
            XCTAssertEqual(pending.snapshot.drawing.strokes.map(\.id), fixture.state.strokes.map(\.id))
            let source = try XCTUnwrap(pending.snapshot.recoverySource)
            XCTAssertEqual(source.notebookID, fixture.notebookID)
            XCTAssertEqual(source.copyID, fixture.receipt.id)
            XCTAssertEqual(source.editID, fixture.state.id)
            XCTAssertEqual(source.originalStamp, fixture.state.stamp)
            XCTAssertEqual(source.baseRevisionID, fixture.initial.revisionID)
            XCTAssertNotEqual(session.canvasGeneration, originalGeneration)
            XCTAssertEqual(session.integrityModel.state, .verified(revisions: 2))
            await trace.releaseAll()
            await session.waitUntilSettled()
            let loaded = try await fixture.repository.load(id: fixture.notebookID)
            let saved = try XCTUnwrap(loaded)
            XCTAssertEqual(saved.content.editStamp, pending.stamp)
            XCTAssertEqual(saved.content.recoverySource, source)
            XCTAssertEqual(saved.content.title, fixture.state.title)
            XCTAssertEqual(saved.content.pageCount, fixture.state.pageCount)
            XCTAssertEqual(saved.content.strokes.map(\.id), fixture.state.strokes.map(\.id))
            let history = try await fixture.repository.history(id: fixture.notebookID)
            XCTAssertEqual(history.count, 3)
            XCTAssertEqual(saved.sequence, advanced.sequence + 1)
            XCTAssertEqual(history.dropFirst().first?.revisionID, advanced.revisionID)
            XCTAssertEqual(history.first?.revisionID, saved.revisionID)
            XCTAssertEqual(history.first?.editStamp, pending.stamp)
            XCTAssertEqual(history.first?.recoverySource, source)
            let offered = await trace.offered
            let receipts = await trace.receipts
            let expectedRevisions = await trace.expectedRevisions
            XCTAssertEqual(expectedRevisions, [advanced.revisionID])
            XCTAssertEqual(offered.map(\.id), [pending.id])
            XCTAssertEqual(receipts.map(\.editID), [pending.id])
            let retained = try await fixture.recovery.loadStates(id: fixture.receipt.id)
            XCTAssertEqual(retained.edits, [fixture.state])
            let reopened = try await fixture.session()
            XCTAssertEqual(reopened.title, fixture.state.title)
            XCTAssertEqual(reopened.pageCount, fixture.state.pageCount)
            XCTAssertEqual(reopened.workingDrawing.strokes.map(\.id), fixture.state.strokes.map(\.id))
        } catch {
            await trace.releaseAll()
            await session.waitUntilSettled()
            throw error
        }
    }

    func testOrdinaryObservationAfterRestoreDoesNotInheritRecoverySource() async throws {
        let fixture = try await RestoreFixture()
        defer { fixture.remove() }
        let session = try await fixture.session()
        let restored = await session.restoreRecoveryEdit(copyID: fixture.receipt.id, editID: fixture.state.id)
        XCTAssertTrue(restored)
        await session.waitUntilSettled()
        let seed = session.makeCanvasSeed()
        session.attachCanvas(ownerID: seed.ownerID, observations: { nil })
        let drawing = PKDrawing(strokes: session.workingDrawing.strokes + [NotebookTestFixtures.stroke(x: 240)])
        let stamp = NotebookTestFixtures.stamp(50)
        session.recordObservation(
            NotebookCanvasObservation(generation: 1, drawing: drawing,
                                      capturedAt: stamp.capturedAt, uptime: stamp.uptime),
            ownerID: seed.ownerID
        )
        let pending = try XCTUnwrap(session.pendingEdits.first)
        XCTAssertNil(pending.snapshot.recoverySource)
        await session.waitUntilSettled()
        let history = try await fixture.repository.history(id: fixture.notebookID)
        XCTAssertNil(history.first?.recoverySource)
        XCTAssertEqual(history.first?.editStamp, pending.stamp)
        XCTAssertEqual(history.dropFirst().first?.recoverySource?.copyID, fixture.receipt.id)
    }

    func testRestoreBarrierRetainsPreviouslyUnobservedWorkBeforePendingGuard() async throws {
        let fixture = try await RestoreFixture()
        defer { fixture.remove() }
        let trace = RestoreStorageTrace(base: fixture.storage, saveFailure: .contentLimit)
        let session = try await fixture.session(storage: await trace.storage())
        let seed = session.makeCanvasSeed()
        let drawing = PKDrawing(strokes: [NotebookTestFixtures.stroke(x: 300)])
        let observation = NotebookCanvasObservation(
            generation: 1, drawing: drawing, capturedAt: Date(timeIntervalSince1970: 20), uptime: 20
        )
        session.attachCanvas(ownerID: seed.ownerID, observations: { observation })
        let restored = await session.restoreRecoveryEdit(copyID: fixture.receipt.id, editID: fixture.state.id)
        XCTAssertFalse(restored)
        XCTAssertEqual(session.pendingEdits.map { $0.snapshot.drawing.strokes.map(\.id) }, [drawing.strokes.map(\.id)])
        XCTAssertEqual(session.pendingEdits.first?.stamp.capturedAt, observation.capturedAt)
        XCTAssertEqual(session.pendingEdits.first?.stamp.uptime, observation.uptime)
        await session.waitUntilSettled()
        let loads = await trace.targetLoadCalls
        XCTAssertEqual(loads, 0)
        XCTAssertEqual(session.workingDrawing.strokes.map(\.id), drawing.strokes.map(\.id))
    }

    func testActiveToolBlocksRestoreBeforeSelectedDataIsRead() async throws {
        let fixture = try await RestoreFixture()
        defer { fixture.remove() }
        let trace = RestoreStorageTrace(base: fixture.storage)
        let session = try await fixture.session(storage: await trace.storage())
        let seed = session.makeCanvasSeed()
        session.attachCanvas(ownerID: seed.ownerID, observations: { nil }, controls: NotebookCanvasControls(
            undo: {}, redo: {}, setPaletteSuppressed: { _ in }, applyPageCount: { _ in },
            currentAvailability: { NotebookUndoAvailability(canUndo: false, canRedo: false, isUsingTool: true) }
        ))
        let original = session.workingDrawing.strokes.map(\.id)
        let restored = await session.restoreRecoveryEdit(copyID: fixture.receipt.id, editID: fixture.state.id)
        XCTAssertFalse(restored)
        let reads = await trace.targetLoadCalls
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(session.workingDrawing.strokes.map(\.id), original)
        XCTAssertTrue(session.pendingEdits.isEmpty)
    }

    func testLateObservationDuringSelectedLoadRejectsRestoreWithoutLosingIt() async throws {
        let fixture = try await RestoreFixture()
        defer { fixture.remove() }
        let trace = RestoreStorageTrace(base: fixture.storage, suspendTarget: true)
        let session = try await fixture.session(storage: await trace.storage())
        let owner = try XCTUnwrap(session.canvasOwnerID)
        let originalGeneration = session.canvasGeneration
        let task = Task { await session.restoreRecoveryEdit(copyID: fixture.receipt.id, editID: fixture.state.id) }
        do {
            try await NotebookTestFixtures.waitUntil { await trace.targetEntered }
            XCTAssertEqual(session.inputGate, .recovering)
            let late = PKDrawing(strokes: [NotebookTestFixtures.stroke(x: 350)])
            session.recordObservation(
                NotebookCanvasObservation(generation: 1, drawing: late,
                                          capturedAt: Date(timeIntervalSince1970: 30), uptime: 30), ownerID: owner
            )
            let pendingID = try XCTUnwrap(session.pendingEdits.first?.id)
            try await NotebookTestFixtures.waitUntil { session.pendingEdits.isEmpty }
            XCTAssertTrue(session.pendingEdits.isEmpty)
            let selectedBeforeRelease = try await fixture.repository.load(id: fixture.notebookID)
            XCTAssertEqual(selectedBeforeRelease?.content.strokes.map(\.id), late.strokes.map(\.id))
            XCTAssertEqual(selectedBeforeRelease?.content.editStamp?.capturedAt, Date(timeIntervalSince1970: 30))
            await trace.releaseAll()
            let restored = await task.value
            XCTAssertFalse(restored)
            await session.waitUntilSettled()
            XCTAssertEqual(session.canvasGeneration, originalGeneration)
            XCTAssertEqual(session.workingDrawing.strokes.map(\.id), late.strokes.map(\.id))
            let offered = await trace.offered
            XCTAssertEqual(offered.map(\.id), [pendingID])
            XCTAssertEqual(offered.first?.content.editStamp?.capturedAt, Date(timeIntervalSince1970: 30))
            XCTAssertNil(offered.first?.content.recoverySource)
            let retained = try await fixture.recovery.loadStates(id: fixture.receipt.id)
            XCTAssertEqual(retained.edits, [fixture.state])
        } catch {
            await trace.releaseAll()
            _ = await task.value
            await session.waitUntilSettled()
            throw error
        }
    }

    func testCancelledRestoreKeepsCurrentCanvasAndSourceCopy() async throws {
        let fixture = try await RestoreFixture()
        defer { fixture.remove() }
        let trace = RestoreStorageTrace(base: fixture.storage, suspendTarget: true)
        let session = try await fixture.session(storage: await trace.storage())
        let owner = session.canvasOwnerID
        let generation = session.canvasGeneration
        let original = session.workingDrawing.strokes.map(\.id)
        let task = Task { await session.restoreRecoveryEdit(copyID: fixture.receipt.id, editID: fixture.state.id) }
        do {
            try await NotebookTestFixtures.waitUntil { await trace.targetEntered }
            task.cancel()
            await trace.releaseAll()
            let restored = await task.value
            XCTAssertFalse(restored)
            XCTAssertEqual(session.canvasOwnerID, owner)
            XCTAssertEqual(session.canvasGeneration, generation)
            XCTAssertEqual(session.workingDrawing.strokes.map(\.id), original)
            XCTAssertTrue(session.pendingEdits.isEmpty)
            XCTAssertNil(session.recoveryFailure)
            XCTAssertEqual(session.inputGate, .open)
        } catch {
            task.cancel()
            await trace.releaseAll()
            _ = await task.value
            throw error
        }
    }

    func testRetirementObservationRejectsRestoreAndRecreatesCurrentCanvas() async throws {
        let fixture = try await RestoreFixture()
        defer { fixture.remove() }
        let trace = RestoreStorageTrace(base: fixture.storage, saveFailure: .contentLimit)
        let session = try await fixture.session(storage: await trace.storage())
        let seed = session.makeCanvasSeed()
        let generation = session.canvasGeneration
        let late = PKDrawing(strokes: [NotebookTestFixtures.stroke(x: 400)])
        var retireCalls = 0
        session.attachCanvas(ownerID: seed.ownerID, observations: { nil }, controls: NotebookCanvasControls(
            undo: {}, redo: {}, setPaletteSuppressed: { _ in }, applyPageCount: { _ in },
            retire: {
                retireCalls += 1
                XCTAssertEqual(session.canvasOwnerID, seed.ownerID)
                session.recordObservation(
                    NotebookCanvasObservation(generation: 1, drawing: late,
                                              capturedAt: Date(timeIntervalSince1970: 40), uptime: 40),
                    ownerID: seed.ownerID
                )
                session.detachCanvas(ownerID: seed.ownerID)
            }
        ))
        let restored = await session.restoreRecoveryEdit(copyID: fixture.receipt.id, editID: fixture.state.id)
        XCTAssertFalse(restored)
        XCTAssertEqual(retireCalls, 1)
        XCTAssertNotEqual(session.canvasGeneration, generation)
        XCTAssertNil(session.canvasOwnerID)
        XCTAssertEqual(session.pendingEdits.count, 1)
        XCTAssertEqual(session.pendingEdits.first?.stamp.capturedAt, Date(timeIntervalSince1970: 40))
        XCTAssertNil(session.pendingEdits.first?.snapshot.recoverySource)
        XCTAssertEqual(session.workingDrawing.strokes.map(\.id), late.strokes.map(\.id))
        await session.waitUntilSettled()
    }

    func testEmergencyCountAndLegacyExtentRemainInspectableButCannotReplaceNormalState() async throws {
        for (count, pages) in [(10_001, 5), (1, 14)] {
            let fixture = try await RestoreFixture(strokeCount: count, pageCount: pages)
            do {
                let session = try await fixture.session()
                let original = session.workingDrawing.strokes.map(\.id)
                let metadata = try await session.inspectRecoveryCopy(id: fixture.receipt.id)
                XCTAssertEqual(metadata.edits.first?.strokeCount, count)
                XCTAssertEqual(metadata.edits.first?.pageCount, pages)
                let restored = await session.restoreRecoveryEdit(copyID: fixture.receipt.id, editID: fixture.state.id)
                XCTAssertFalse(restored)
                XCTAssertEqual(session.recoveryFailure, .contentLimit)
                XCTAssertEqual(session.workingDrawing.strokes.map(\.id), original)
                XCTAssertTrue(session.pendingEdits.isEmpty)
                let retained = try await fixture.recovery.inspect(id: fixture.receipt.id)
                XCTAssertEqual(retained.receipt, fixture.receipt)
            } catch {
                fixture.remove()
                throw error
            }
            fixture.remove()
        }
    }

    func testPairedPreservationAndReopenUseFullStatesWithoutLegacyArchives() async throws {
        let fixture = try await RestoreFixture()
        defer { fixture.remove() }
        let trace = RestoreStorageTrace(base: fixture.storage, saveFailure: .contentLimit, rejectLegacy: true)
        let session = try await fixture.session(storage: await trace.storage())
        let owner = try XCTUnwrap(session.canvasOwnerID)
        let waiting = PKDrawing(strokes: [NotebookTestFixtures.stroke(x: 450)])
        session.recordObservation(
            NotebookCanvasObservation(generation: 1, drawing: waiting,
                                      capturedAt: Date(timeIntervalSince1970: 50), uptime: 50), ownerID: owner
        )
        await session.waitUntilSettled()
        let pending = session.pendingEdits
        await session.saveRecoveryCopy()
        XCTAssertNil(session.recoveryFailure)
        await session.refreshRecoveryCopies()
        let preserved = session.recoveryCopies.filter { $0.id != fixture.receipt.id }
        XCTAssertEqual(preserved.count, 1)
        let receipt = try XCTUnwrap(preserved.first)
        let states = try await fixture.recovery.loadStates(id: receipt.id)
        XCTAssertEqual(states.edits.map(\.id), pending.map(\.id))
        XCTAssertEqual(states.edits.map(\.stamp), pending.map(\.stamp))
        XCTAssertEqual(states.edits.first?.strokes.map(\.id), waiting.strokes.map(\.id))
        XCTAssertTrue(session.canReopenSaved)
        await session.reopenSavedNotebook()
        XCTAssertTrue(session.pendingEdits.isEmpty)
        XCTAssertEqual(session.workingDrawing.strokes.map(\.id), fixture.initial.content.strokes.map(\.id))
        XCTAssertNil(session.recoveryFailure)
        let retained = try await fixture.recovery.loadStates(id: receipt.id)
        XCTAssertEqual(retained, states)
    }

    func testReopenRetirementObservationRetainsEveryUncoveredPendingEdit() async throws {
        let fixture = try await RestoreFixture()
        defer { fixture.remove() }
        let trace = RestoreStorageTrace(base: fixture.storage, saveFailure: .contentLimit, rejectLegacy: true)
        let session = try await fixture.session(storage: await trace.storage())
        let seed = session.makeCanvasSeed()
        session.attachCanvas(ownerID: seed.ownerID, observations: { nil })
        let waiting = PKDrawing(strokes: [NotebookTestFixtures.stroke(x: 500)])
        session.recordObservation(
            NotebookCanvasObservation(generation: 1, drawing: waiting,
                                      capturedAt: Date(timeIntervalSince1970: 60), uptime: 60), ownerID: seed.ownerID
        )
        await session.waitUntilSettled()
        let originalPending = try XCTUnwrap(session.pendingEdits.first)
        await session.saveRecoveryCopy()
        XCTAssertNil(session.recoveryFailure)
        await session.refreshRecoveryCopies()
        let preserved = session.recoveryCopies.filter { $0.id != fixture.receipt.id }
        XCTAssertEqual(preserved.count, 1)
        _ = try XCTUnwrap(preserved.first)
        let generation = session.canvasGeneration
        let late = PKDrawing(strokes: [NotebookTestFixtures.stroke(x: 550)])
        session.attachCanvas(ownerID: seed.ownerID, observations: { nil }, controls: NotebookCanvasControls(
            undo: {}, redo: {}, setPaletteSuppressed: { _ in }, applyPageCount: { _ in },
            retire: {
                XCTAssertEqual(session.canvasOwnerID, seed.ownerID)
                session.recordObservation(
                    NotebookCanvasObservation(generation: 2, drawing: late,
                                              capturedAt: Date(timeIntervalSince1970: 70), uptime: 70),
                    ownerID: seed.ownerID
                )
                session.detachCanvas(ownerID: seed.ownerID)
            }
        ))
        await session.reopenSavedNotebook()
        XCTAssertNotEqual(session.canvasGeneration, generation)
        XCTAssertEqual(session.pendingEdits.count, 2)
        XCTAssertEqual(session.pendingEdits.first?.id, originalPending.id)
        XCTAssertEqual(session.pendingEdits.first?.stamp, originalPending.stamp)
        XCTAssertEqual(session.pendingEdits.last?.stamp.capturedAt, Date(timeIntervalSince1970: 70))
        XCTAssertEqual(session.workingDrawing.strokes.map(\.id), late.strokes.map(\.id))
        XCTAssertFalse(session.canReopenSaved)
        XCTAssertNotNil(session.recoveryFailure)
    }

    func testDamagedOtherEditStillAllowsAuthenticatedSelectedInspectionAndRestore() async throws {
        let fixture = try await RestoreFixture()
        defer { fixture.remove() }
        let secondStroke = try await InkCodec(profile: .recovery).encode(
            PKDrawing(strokes: [NotebookTestFixtures.stroke(x: 600)])
        )
        let second = NotebookRecoveryStrokeEdit(
            id: UUID(), strokes: secondStroke, title: "Other edit", pageCount: 4,
            stamp: NotebookTestFixtures.stamp(90)
        )
        let receipt = try await fixture.recovery.preserveStates(NotebookRecoveryStrokeBatch(
            notebookID: fixture.notebookID, baseRevisionID: fixture.initial.revisionID,
            edits: [fixture.state, second]
        ))
        let data = try XCTUnwrap(secondStroke.first?.data)
        let alphabet = Array("0123456789abcdef".utf8)
        let digest = String(decoding: SHA256.hash(data: data).flatMap {
            [alphabet[Int($0) >> 4], alphabet[Int($0) & 15]]
        }, as: UTF8.self)
        let path = fixture.copies.appendingPathComponent(receipt.id.uuidString.lowercased())
            .appendingPathComponent("assets").appendingPathComponent(digest + ".stroke")
        var damaged = data
        damaged[damaged.startIndex] ^= 1
        try damaged.write(to: path)
        let session = try await fixture.session()
        await session.refreshRecoveryCopies()
        XCTAssertFalse(session.recoveryCopies.contains(where: { $0.id == receipt.id }))
        XCTAssertTrue(session.recoveryIssues.contains(where: { $0.copyID == receipt.id && $0.kind == .damagedData }))
        let metadata = try await session.inspectRecoveryCopy(id: receipt.id)
        XCTAssertEqual(metadata.receipt, receipt)
        XCTAssertEqual(metadata.edits.map(\.id), [fixture.state.id, second.id])
        let drawing = try await session.openRecoveryDrawing(copyID: receipt.id, editID: fixture.state.id)
        XCTAssertEqual(drawing.strokes.map(\.id), fixture.state.strokes.map(\.id))
        let restored = await session.restoreRecoveryEdit(copyID: receipt.id, editID: fixture.state.id)
        XCTAssertTrue(restored)
        await session.waitUntilSettled()
        XCTAssertEqual(try Data(contentsOf: path), damaged)
        let loaded = try await fixture.repository.load(id: fixture.notebookID)
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.content.recoverySource?.copyID, receipt.id)
        XCTAssertEqual(saved.content.strokes.map(\.id), fixture.state.strokes.map(\.id))
    }

    func testChangedFullCoverageCannotBeAuthorizedByTargetedInspection() async throws {
        let fixture = try await RestoreFixture()
        defer { fixture.remove() }
        let trace = RestoreStorageTrace(
            base: fixture.storage, saveFailure: .contentLimit, rejectLegacy: true, corruptFullStates: true
        )
        let session = try await fixture.session(storage: await trace.storage())
        let owner = try XCTUnwrap(session.canvasOwnerID)
        session.recordObservation(
            NotebookCanvasObservation(generation: 1, drawing: PKDrawing(strokes: [NotebookTestFixtures.stroke(x: 650)]),
                                      capturedAt: Date(timeIntervalSince1970: 100), uptime: 100), ownerID: owner
        )
        await session.waitUntilSettled()
        let originalPending = session.pendingEdits
        await session.saveRecoveryCopy()
        XCTAssertNil(session.recoveryFailure)
        await session.refreshRecoveryCopies()
        let preserved = session.recoveryCopies.filter { $0.id != fixture.receipt.id }
        XCTAssertEqual(preserved.count, 1)
        let receipt = try XCTUnwrap(preserved.first)
        _ = try await session.inspectRecoveryCopy(id: receipt.id)
        let generation = session.canvasGeneration
        await session.reopenSavedNotebook()
        XCTAssertEqual(session.pendingEdits.map(\.id), originalPending.map(\.id))
        XCTAssertEqual(session.pendingEdits.map(\.stamp), originalPending.map(\.stamp))
        XCTAssertEqual(session.canvasGeneration, generation)
        XCTAssertEqual(session.recoveryFailure, .corruptData)
        XCTAssertFalse(session.canReopenSaved)
        let retained = try await fixture.recovery.loadStates(id: receipt.id)
        XCTAssertEqual(retained.edits.map(\.id), originalPending.map(\.id))
        XCTAssertEqual(retained.edits.map(\.stamp), originalPending.map(\.stamp))
    }

    func testMountedNativeRestoreRetiresOldOwnerAndUndoBeforeReplacingCanvas() async throws {
        let fixture = try await RestoreFixture()
        defer { fixture.remove() }
        let session = try await fixture.session()
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let hosting = UIHostingController(rootView: NotebookScreen(session: session))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1_024, height: 1_366)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        do {
            try await NotebookTestFixtures.waitUntil {
                guard let controller = self.notebookController(in: hosting) else { return false }
                return controller.isCanvasVisible && controller.canvasView.window != nil
                    && controller.canvasView.isFirstResponder && session.canvasOwnerID != nil
            }
            let old = try XCTUnwrap(notebookController(in: hosting))
            await session.waitUntilSettled()
            session.flush()
            await session.waitUntilSettled()
            let originalOwner = try XCTUnwrap(session.canvasOwnerID)
            let oldGeneration = session.canvasGeneration
            let manager = try XCTUnwrap(old.canvasView.undoManager)
            let target = NSObject()
            manager.beginUndoGrouping()
            manager.registerUndo(withTarget: target) { _ in }
            manager.endUndoGrouping()
            XCTAssertTrue(manager.canUndo)
            let restored = await session.restoreRecoveryEdit(copyID: fixture.receipt.id, editID: fixture.state.id)
            XCTAssertTrue(restored)
            XCTAssertFalse(manager.canUndo)
            XCTAssertFalse(manager.canRedo)
            XCTAssertFalse(old.isCanvasVisible)
            XCTAssertNotEqual(session.canvasGeneration, oldGeneration)
            try await NotebookTestFixtures.waitUntil {
                guard let controller = self.notebookController(in: hosting), controller !== old else { return false }
                return controller.isCanvasVisible && session.canvasOwnerID != nil
            }
            XCTAssertNotEqual(session.canvasOwnerID, originalOwner)
            await session.waitUntilSettled()
            let current = try XCTUnwrap(notebookController(in: hosting))
            XCTAssertEqual(current.canvasView.drawing.strokes.map(\.id), fixture.state.strokes.map(\.id))
            XCTAssertEqual(session.pageCount, fixture.state.pageCount)
            let history = try await fixture.repository.history(id: fixture.notebookID)
            let restoredEvents = history.filter { $0.recoverySource?.copyID == fixture.receipt.id }
            XCTAssertEqual(restoredEvents.count, 1)
            XCTAssertEqual(restoredEvents.first?.recoverySource?.originalStamp, fixture.state.stamp)
            XCTAssertNotEqual(restoredEvents.first?.editStamp, fixture.state.stamp)
            XCTAssertEqual(session.integrityModel.state, .verified(revisions: 1))
            let retained = try await fixture.recovery.loadStates(id: fixture.receipt.id)
            XCTAssertEqual(retained.edits, [fixture.state])
        } catch {
            notebookController(in: hosting)?.tearDown()
            window.isHidden = true
            window.rootViewController = nil
            await session.waitUntilSettled()
            throw error
        }
        notebookController(in: hosting)?.tearDown()
        window.isHidden = true
        window.rootViewController = nil
        await session.waitUntilSettled()
    }

    private func notebookController(in controller: UIViewController) -> NotebookViewController? {
        if let notebook = controller as? NotebookViewController { return notebook }
        for child in controller.children {
            if let notebook = notebookController(in: child) { return notebook }
        }
        return nil
    }

    func testRepositoryCASConflictRetainsFreshRestoredPendingEditAndOriginalCopy() async throws {
        let fixture = try await RestoreFixture()
        defer { fixture.remove() }
        let trace = RestoreStorageTrace(base: fixture.storage, suspendSave: true)
        let session = try await fixture.session(storage: await trace.storage())
        let originalGeneration = session.canvasGeneration
        let restored = await session.restoreRecoveryEdit(copyID: fixture.receipt.id, editID: fixture.state.id)
        XCTAssertTrue(restored)
        do {
            try await NotebookTestFixtures.waitUntil { await trace.saveEntered }
            let pending = try XCTUnwrap(session.pendingEdits.first)
            let foreign = try await fixture.repository.save(
                id: fixture.notebookID,
                content: NotebookContent(title: "Different current revision", pageCount: 4,
                                         strokes: fixture.initial.content.strokes,
                                         editStamp: NotebookTestFixtures.stamp(120)),
                expectedRevisionID: fixture.initial.revisionID
            )
            await trace.releaseAll()
            await session.waitUntilSettled()
            XCTAssertEqual(session.pendingEdits.map(\.id), [pending.id])
            XCTAssertEqual(session.pendingEdits.first?.stamp, pending.stamp)
            XCTAssertEqual(session.pendingEdits.first?.snapshot.recoverySource, pending.snapshot.recoverySource)
            XCTAssertEqual(session.pendingEdits.first?.snapshot.recoverySource?.baseRevisionID, fixture.initial.revisionID)
            XCTAssertEqual(session.pendingEdits.first?.snapshot.drawing.strokes.map(\.id), fixture.state.strokes.map(\.id))
            XCTAssertEqual(session.saveState, .failed(.revisionConflict))
            XCTAssertNotEqual(session.canvasGeneration, originalGeneration)
            XCTAssertEqual(session.integrityModel.state, .verified(revisions: 1))
            let committed = await trace.receipts
            XCTAssertTrue(committed.isEmpty)
            let current = try await fixture.repository.load(id: fixture.notebookID)
            XCTAssertEqual(current?.revisionID, foreign.revisionID)
            XCTAssertEqual(current?.content, foreign.content)
            let history = try await fixture.repository.history(id: fixture.notebookID)
            XCTAssertEqual(history.count, 2)
            XCTAssertFalse(history.contains(where: { $0.recoverySource?.copyID == fixture.receipt.id }))
            let retained = try await fixture.recovery.loadStates(id: fixture.receipt.id)
            XCTAssertEqual(retained.edits, [fixture.state])
        } catch {
            await trace.releaseAll()
            await session.waitUntilSettled()
            throw error
        }
    }
}

@MainActor
private final class RestoreFixture {
    let root: URL
    let copies: URL
    let notebookID = UUID()
    let repository: NotebookRepository
    let recovery: NotebookRecoveryStore
    let initial: StoredNotebook
    let state: NotebookRecoveryStrokeEdit
    let receipt: NotebookRecoveryReceipt
    let storage: NotebookStorage

    init(strokeCount: Int = 1, pageCount: Int = 5) async throws {
        let createdRoot = NotebookTestFixtures.root()
        root = createdRoot
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: createdRoot) }
        }
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        copies = root.appendingPathComponent("copies", isDirectory: true)
        repository = try NotebookRepository(rootURL: notes)
        recovery = try NotebookRecoveryStore(rootURL: copies)
        let initialStroke = try await InkCodec().encode(PKDrawing(strokes: [NotebookTestFixtures.stroke()]))
        initial = try await repository.save(
            id: notebookID,
            content: NotebookContent(title: "Current notebook", pageCount: 3, strokes: initialStroke,
                                     editStamp: NotebookTestFixtures.stamp(100)),
            expectedRevisionID: nil
        )
        let encoded = try await InkCodec(profile: .recovery).encode(
            PKDrawing(strokes: [NotebookTestFixtures.stroke(x: 200)])
        )
        let archive = try XCTUnwrap(encoded.first?.data)
        let strokes = (0..<strokeCount).map { _ in NotebookStroke(id: UUID(), data: archive) }
        state = NotebookRecoveryStrokeEdit(
            id: UUID(), strokes: strokes, title: "Preserved title", pageCount: pageCount,
            stamp: NotebookTestFixtures.stamp(1)
        )
        if pageCount > 12 {
            let drawing = try await InkCodec(profile: .recovery).decode(strokes)
            receipt = try await recovery.preserve(NotebookRecoveryBatch(
                notebookID: notebookID, baseRevisionID: initial.revisionID,
                edits: [NotebookRecoveryEdit(
                    id: state.id, drawingData: drawing.dataRepresentation(), strokeIDs: strokes.map(\.id),
                    title: state.title, pageCount: pageCount, stamp: state.stamp
                )]
            ))
        } else {
            receipt = try await recovery.preserveStates(NotebookRecoveryStrokeBatch(
                notebookID: notebookID, baseRevisionID: initial.revisionID, edits: [state]
            ))
        }
        let library = NotebookLibraryAccess(
            libraryRoot: notes, recoveryRoot: copies, repository: repository, recoveryStore: recovery
        )
        storage = await library.storage(notebookID: notebookID)
        completed = true
    }

    func session(storage override: NotebookStorage? = nil) async throws -> NotebookSession {
        let supplied = override ?? storage
        let session = NotebookSession(notebookID: notebookID, openStorage: { supplied })
        await session.load()
        XCTAssertEqual(session.loadState, .ready)
        try await NotebookTestFixtures.waitUntil { session.integrityModel.state != .checking }
        let seed = session.makeCanvasSeed()
        session.attachCanvas(ownerID: seed.ownerID, observations: { nil })
        return session
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor RestoreStorageTrace {
    let base: NotebookStorage
    private var suspendSave: Bool
    private var suspendTarget: Bool
    private let saveFailure: NotebookSaveFailure?
    private let rejectLegacy: Bool
    private let corruptFullStates: Bool
    private var saveContinuation: CheckedContinuation<Void, Never>?
    private var targetContinuation: CheckedContinuation<Void, Never>?
    private(set) var saveEntered = false
    private(set) var targetEntered = false
    private(set) var targetLoadCalls = 0
    private(set) var offered: [NotebookSaveEdit] = []
    private(set) var receipts: [NotebookCommittedEdit] = []
    private(set) var expectedRevisions: [UUID?] = []

    init(
        base: NotebookStorage, suspendSave: Bool = false, suspendTarget: Bool = false,
        saveFailure: NotebookSaveFailure? = nil, rejectLegacy: Bool = false,
        corruptFullStates: Bool = false
    ) {
        self.base = base
        self.suspendSave = suspendSave
        self.suspendTarget = suspendTarget
        self.saveFailure = saveFailure
        self.rejectLegacy = rejectLegacy
        self.corruptFullStates = corruptFullStates
    }

    func storage() -> NotebookStorage {
        let base = self.base
        return NotebookStorage(
            load: base.load, save: base.save,
            preserve: { try await self.preserveLegacy($0) }, listRecovery: base.listRecovery,
            loadRecovery: { try await self.loadLegacy($0) }, storageMetrics: base.storageMetrics,
            openForEditing: base.openForEditing, captureHistoryPin: base.captureHistoryPin,
            auditHistory: base.auditHistory, recoveryStates: base.recoveryStates.map { access in
                NotebookRecoveryStateAccess(preserveStates: access.preserveStates, loadStates: { try await self.loadFull($0) })
            },
            inspectRecovery: base.inspectRecovery, loadRecoveryEdit: { try await self.loadTarget($0, editID: $1) },
            saveBatch: { try await self.save($0, revision: $1) }
        )
    }

    func releaseAll() {
        suspendSave = false
        suspendTarget = false
        let save = saveContinuation
        let target = targetContinuation
        saveContinuation = nil
        targetContinuation = nil
        save?.resume()
        target?.resume()
    }

    private func loadTarget(_ copyID: UUID, editID: UUID) async throws -> NotebookRecoveredEdit {
        targetLoadCalls += 1
        targetEntered = true
        if suspendTarget { await withCheckedContinuation { targetContinuation = $0 } }
        guard let load = base.loadRecoveryEdit else { throw NotebookSaveFailure.storageUnavailable }
        return try await load(copyID, editID)
    }

    private func save(_ edits: [NotebookSaveEdit], revision: UUID?) async throws -> NotebookBatchSaveResult {
        saveEntered = true
        expectedRevisions.append(revision)
        if suspendSave { await withCheckedContinuation { saveContinuation = $0 } }
        if let saveFailure { throw saveFailure }
        let result = try await base.saveBatch(edits, revision)
        offered.append(contentsOf: edits.prefix(result.committed.count))
        receipts.append(contentsOf: result.committed)
        return result
    }

    private func loadFull(_ id: UUID) async throws -> NotebookRecoveryStrokeBatch {
        guard let access = base.recoveryStates else { throw NotebookSaveFailure.storageUnavailable }
        let batch = try await access.loadStates(id)
        guard corruptFullStates else { return batch }
        return NotebookRecoveryStrokeBatch(
            notebookID: batch.notebookID, baseRevisionID: batch.baseRevisionID,
            edits: batch.edits.map {
                NotebookRecoveryStrokeEdit(
                    id: $0.id, strokes: $0.strokes, title: $0.title + " changed", pageCount: $0.pageCount,
                    stamp: $0.stamp, recoverySource: $0.recoverySource
                )
            }
        )
    }

    private func preserveLegacy(_ batch: NotebookRecoveryBatch) async throws -> NotebookRecoveryReceipt {
        if rejectLegacy { throw NotebookSaveFailure.invalidContent }
        return try await base.preserve(batch)
    }

    private func loadLegacy(_ id: UUID) async throws -> NotebookRecoveryBatch {
        if rejectLegacy { throw NotebookSaveFailure.invalidContent }
        return try await base.loadRecovery(id)
    }
}
