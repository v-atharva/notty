import Foundation
import NottyCore
import PencilKit
import SwiftUI
import UIKit
import XCTest
@testable import Notty
@testable import NottyCore

@MainActor
final class NotebookIntegritySessionTests: XCTestCase {
    private struct Fixture {
        let session: NotebookSession
        let probe: IntegrityStorageProbe
        let root: URL
        let initial: NotebookHistoryPin?
    }

    private func fixture(legacy: Bool = false, empty: Bool = false) async throws -> Fixture {
        let root = NotebookTestFixtures.root()
        let id = UUID()
        if legacy { try IntegrityStorageProbe.writeLegacy(root: root, id: id) }
        let probe = try IntegrityStorageProbe(root: root, notebookID: id)
        if !legacy && !empty { try await probe.seed() }
        let storage = await probe.storage()
        let session = NotebookSession(notebookID: id, openStorage: { storage })
        await session.load()
        let initial = await probe.openings.first?.historyPin
        return Fixture(session: session, probe: probe, root: root, initial: initial)
    }

    private func wait(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The gated integrity operation did not become ready.")
        throw NotebookSaveFailure.unexpected
    }

    private func observe(
        _ session: NotebookSession, owner: UUID, generation: UInt64, drawing: PKDrawing = PKDrawing()
    ) {
        session.recordObservation(NotebookCanvasObservation(
            generation: generation, drawing: drawing,
            capturedAt: Date(timeIntervalSince1970: Double(generation) + 100),
            uptime: Double(generation) + 200
        ), ownerID: owner)
    }

    func testOpeningBecomesWritableBeforeGatedAuditFinishes() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await wait { await f.probe.auditCount == 1 }
        XCTAssertEqual(f.session.loadState, .ready)
        XCTAssertEqual(f.session.integrityModel.state, .checking)
        XCTAssertEqual(f.session.inputGate, .open)
        XCTAssertTrue(f.session.workingDrawing.strokes.isEmpty)
        let generation = f.session.canvasGeneration
        await f.probe.finishAudit(0)
        try await wait { f.session.integrityModel.state == .verified(revisions: 1) }
        XCTAssertEqual(f.session.canvasGeneration, generation)
        XCTAssertEqual(f.session.inputGate, .open)
    }

    func testOwnAppendKeepsOpeningAuditAndDamageSurvivesSuccessfulSave() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await wait { await f.probe.auditCount == 1 }
        let owner = f.session.makeCanvasSeed().ownerID
        observe(f.session, owner: owner, generation: 1)
        let first = f.session.pendingEdits
        await f.session.waitUntilSettled()
        XCTAssertTrue(f.session.pendingEdits.isEmpty)
        let calls = await f.probe.capturedRevisions
        XCTAssertTrue(calls.isEmpty)
        await f.probe.finishAudit(0, outcome: .damaged(.corruptData))
        try await wait { f.session.inputGate == .readOnly }
        XCTAssertEqual(f.session.loadState, .ready)
        let generation = f.session.canvasGeneration
        // A late callback belongs to already accepted native input.
        observe(f.session, owner: owner, generation: 2)
        let second = f.session.pendingEdits
        await f.session.waitUntilSettled()
        XCTAssertTrue(f.session.pendingEdits.isEmpty)
        XCTAssertEqual(f.session.integrityModel.state, .damaged(.corruptData))
        XCTAssertEqual(f.session.inputGate, .readOnly)
        XCTAssertEqual(f.session.canvasGeneration, generation)
        let committed = await f.probe.committed
        XCTAssertEqual(committed.map(\.id), (first + second).map(\.id))
        XCTAssertEqual(committed.map(\.content.editStamp), (first + second).map { Optional($0.stamp) })
        let pins = await f.probe.auditPins
        XCTAssertEqual(pins, [try XCTUnwrap(f.initial)])
    }

    func testVerifiedOpeningAuditRemainsValidAfterOwnedAppend() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await wait { await f.probe.auditCount == 1 }
        let owner = f.session.makeCanvasSeed().ownerID
        observe(f.session, owner: owner, generation: 1)
        await f.session.waitUntilSettled()
        let selected = try await f.probe.current()
        XCTAssertNotEqual(selected?.revisionID, f.initial?.revisionID)
        await f.probe.finishAudit(0)
        try await wait { f.session.integrityModel.state == .verified(revisions: 1) }
        XCTAssertEqual(f.session.inputGate, .open)
        let counts = await f.probe.counts()
        XCTAssertEqual(counts.audits, 1)
        XCTAssertEqual(counts.captures, 0)
    }

    func testIncompleteAuditRemainsWritableAndCancelledAuditIsQuiet() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await wait { await f.probe.auditCount == 1 }
        await f.probe.finishAudit(0, outcome: .incomplete(.storageUnavailable))
        try await wait { f.session.integrityModel.state == .incomplete(.storageUnavailable) }
        XCTAssertEqual(f.session.inputGate, .open)
        let owner = f.session.makeCanvasSeed().ownerID
        observe(f.session, owner: owner, generation: 1)
        await f.session.waitUntilSettled()
        XCTAssertTrue(f.session.pendingEdits.isEmpty)
        XCTAssertEqual(f.session.integrityModel.state, .incomplete(.storageUnavailable))

        let cancelled = try await fixture()
        defer { try? FileManager.default.removeItem(at: cancelled.root) }
        try await wait { await cancelled.probe.auditCount == 1 }
        await cancelled.probe.finishAudit(0, outcome: .cancelled)
        try await wait { cancelled.session.integrityModel.state == nil }
        XCTAssertEqual(cancelled.session.inputGate, .open)
        XCTAssertNil(cancelled.session.recoveryFailure)
    }

    func testAuditFailureClassificationSeparatesDamageFromIO() {
        for error in [
            NotebookRepositoryError.corruptData("Historical bytes changed."),
            .unsafePath("Historical path is unsafe."), .unsupportedVersion(99), .recoveryRequired
        ] {
            guard case .damaged = NotebookIntegrityOutcome.failure(error) else {
                return XCTFail("Persistent history damage must stop new input.")
            }
        }
        for error in [NotebookRepositoryError.ioFailure(5), .revisionConflict] {
            guard case .incomplete = NotebookIntegrityOutcome.failure(error) else {
                return XCTFail("An incomplete check must leave input writable.")
            }
        }
    }

    func testDamageDuringActiveToolRetainsObservedAndEndBarrierStatesAndDrainsFIFO() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.probe.suspendSaves()
        try await wait { await f.probe.auditCount == 1 }
        let seed = f.session.makeCanvasSeed()
        let controller = NotebookViewController(pageCount: seed.pageCount, initialDrawing: seed.drawing)
        controller.loadViewIfNeeded()
        // Deliver controlled synchronous observations without duplicate SDK assignment callbacks.
        controller.canvasView.delegate = nil
        controller.onObservation = { f.session.recordObservation($0, ownerID: seed.ownerID); return f.session.inputGate }
        f.session.attachCanvas(
            ownerID: seed.ownerID, observations: { controller.captureBarrier() },
            applyInputGate: { controller.setInputGate($0) }
        )
        defer { controller.tearDown() }
        controller.canvasViewDidBeginUsingTool(controller.canvasView)
        let first = NotebookTestFixtures.stroke()
        let second = NotebookTestFixtures.stroke(x: 100)
        let third = NotebookTestFixtures.stroke(x: 200)
        controller.canvasView.drawing = PKDrawing(strokes: [first])
        controller.canvasViewDrawingDidChange(controller.canvasView)
        try await wait { await f.probe.hasSuspendedSave }
        await f.probe.finishAudit(0, outcome: .damaged(.corruptData))
        try await wait { f.session.inputGate == .readOnly }
        XCTAssertEqual(controller.inputGate, .readOnly)
        XCTAssertTrue(controller.canvasView.drawingGestureRecognizer.isEnabled)
        XCTAssertTrue(f.session.canPreserveRecovery)
        controller.canvasView.drawing = PKDrawing(strokes: [first, second])
        controller.canvasViewDrawingDidChange(controller.canvasView)
        controller.canvasView.drawing = PKDrawing(strokes: [first, second, third])
        controller.canvasViewDidEndUsingTool(controller.canvasView)
        let original = f.session.pendingEdits
        XCTAssertEqual(original.map { $0.snapshot.drawing.strokes.map(\.id) }, [
            [first.id], [first.id, second.id], [first.id, second.id, third.id]
        ])
        XCTAssertFalse(controller.canvasView.drawingGestureRecognizer.isEnabled)
        XCTAssertTrue(controller.canvasView.panGestureRecognizer.isEnabled)
        await f.probe.releaseSave()
        await f.session.waitUntilSettled()
        XCTAssertTrue(f.session.pendingEdits.isEmpty)
        XCTAssertEqual(f.session.integrityModel.state, .damaged(.corruptData))
        let committed = await f.probe.committed
        XCTAssertEqual(committed.map(\.id), original.map(\.id))
        XCTAssertEqual(committed.map(\.content.editStamp), original.map { Optional($0.stamp) })
        let selected = try await f.probe.current()
        XCTAssertEqual(selected?.content.strokes.map(\.id), [first.id, second.id, third.id])
        XCTAssertEqual(selected?.sequence, 4)
    }

    func testDamageAndRealSaveFailureAllowVerifiedRecoveryWithoutLosingWaitingEdits() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.probe.suspendSaves()
        await f.probe.setSaveFailure(.ioFailure(28))
        try await wait { await f.probe.auditCount == 1 }
        let owner = f.session.makeCanvasSeed().ownerID
        observe(f.session, owner: owner, generation: 1, drawing: PKDrawing(strokes: [NotebookTestFixtures.stroke()]))
        try await wait { await f.probe.hasSuspendedSave }
        let original = f.session.pendingEdits
        await f.probe.finishAudit(0, outcome: .damaged(.corruptData))
        try await wait { f.session.integrityModel.state == .damaged(.corruptData) }
        await f.probe.releaseSave()
        await f.session.waitUntilSettled()
        XCTAssertEqual(f.session.saveState, .failed(.storageFull))
        XCTAssertTrue(f.session.canPreserveRecovery)
        await f.session.saveRecoveryCopy()
        XCTAssertTrue(f.session.canReopenSaved)
        XCTAssertEqual(f.session.pendingEdits, original)
        await f.session.refreshRecoveryCopies()
        let batch = try await f.session.openRecoveryCopy(id: XCTUnwrap(f.session.recoveryCopies.first).id)
        XCTAssertEqual(batch.edits.map(\.id), original.map(\.id))
        XCTAssertEqual(batch.edits.map(\.stamp), original.map(\.stamp))
        XCTAssertEqual(f.session.integrityModel.state, .damaged(.corruptData))
    }

    func testReopenCancelsOldAuditAndRejectsItsLateDamageWithoutReplacingNewOwner() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await wait { await f.probe.auditCount == 1 }
        await f.probe.setSaveFailure(.sizeLimitExceeded("Full."))
        let old = f.session.makeCanvasSeed().ownerID
        observe(f.session, owner: old, generation: 1)
        await f.session.waitUntilSettled()
        await f.session.saveRecoveryCopy()
        XCTAssertTrue(f.session.canReopenSaved)
        await f.probe.suspendRecoveryRead()
        let reopening = Task { await f.session.reopenSavedNotebook() }
        try await wait { await f.probe.hasSuspendedRecoveryRead }
        await f.probe.finishAudit(0, outcome: .damaged(.corruptData))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(f.session.integrityModel.state)
        XCTAssertEqual(f.session.inputGate, .recovering)
        await f.probe.releaseRecoveryRead()
        await reopening.value
        try await wait { await f.probe.auditCount == 2 }
        let generation = f.session.canvasGeneration
        let owner = f.session.makeCanvasSeed().ownerID
        XCTAssertEqual(f.session.integrityModel.state, .checking)
        XCTAssertEqual(f.session.inputGate, .open)
        XCTAssertFalse(f.session.recordObservation(
            NotebookCanvasObservation(generation: 2, drawing: PKDrawing(), capturedAt: Date(), uptime: 1),
            ownerID: old
        ))
        XCTAssertEqual(f.session.canvasOwnerID, owner)
        XCTAssertEqual(f.session.canvasGeneration, generation)
        await f.probe.finishAudit(1)
        try await wait { f.session.integrityModel.state == .verified(revisions: 1) }
    }

    func testInitialPublicationCapturesOnePinAndLaterOrdinarySavesDoNotRecapture() async throws {
        let f = try await fixture(empty: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.session.waitUntilSettled()
        try await wait { await f.probe.auditCount == 1 }
        XCTAssertNil(f.initial)
        let captured = await f.probe.capturedRevisions
        let current = try await f.probe.current()
        XCTAssertEqual(captured, [try XCTUnwrap(current).revisionID])
        await f.probe.finishAudit(0)
        try await wait { f.session.integrityModel.state == .verified(revisions: 1) }
        let owner = f.session.makeCanvasSeed().ownerID
        for index in 1...3 {
            observe(f.session, owner: owner, generation: UInt64(index))
            await f.session.waitUntilSettled()
        }
        let counts = await f.probe.counts()
        XCTAssertEqual(counts.captures, 1)
        XCTAssertEqual(counts.audits, 1)
        XCTAssertTrue(f.session.pendingEdits.isEmpty)
    }

    func testSuccessfulLegacySaveRetiresOldAuditAndPinsNewGeneration() async throws {
        let f = try await fixture(legacy: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await wait { await f.probe.auditCount == 1 }
        let old = try XCTUnwrap(f.initial)
        XCTAssertTrue(old.requiresFirstPublicationRefresh)
        let owner = f.session.makeCanvasSeed().ownerID
        observe(f.session, owner: owner, generation: 1)
        await f.session.waitUntilSettled()
        try await wait { await f.probe.auditCount == 2 }
        let pins = await f.probe.auditPins
        XCTAssertFalse(pins[1].requiresFirstPublicationRefresh)
        XCTAssertFalse(old.hasSameHistoryGeneration(as: pins[1]))
        let current = try await f.probe.current()
        XCTAssertEqual(pins[1].revisionID, current?.revisionID)
        XCTAssertEqual(pins[1].sequence, 2)
        await f.probe.finishAudit(0, outcome: .damaged(.corruptData))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(f.session.integrityModel.state, .checking)
        await f.probe.finishAudit(1)
        try await wait { f.session.integrityModel.state == .verified(revisions: 2) }
        XCTAssertTrue(f.session.pendingEdits.isEmpty)
        XCTAssertEqual(f.session.inputGate, .open)
    }

    func testFailedSaveAfterMigrationAnchorStillReplacesLegacyPinAndPreservesOriginalFailure() async throws {
        let f = try await fixture(legacy: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await wait { await f.probe.auditCount == 1 }
        await f.probe.failAfterMigration()
        let owner = f.session.makeCanvasSeed().ownerID
        observe(f.session, owner: owner, generation: 1)
        let original = f.session.pendingEdits
        await f.session.waitUntilSettled()
        try await wait { await f.probe.auditCount == 2 }
        let pins = await f.probe.auditPins
        XCTAssertEqual(pins[1].revisionID, pins[0].revisionID)
        XCTAssertFalse(pins[1].requiresFirstPublicationRefresh)
        XCTAssertFalse(pins[1].hasSameHistoryGeneration(as: pins[0]))
        let captured = await f.probe.capturedRevisions
        XCTAssertEqual(captured, [pins[0].revisionID])
        XCTAssertEqual(f.session.saveState, .failed(.storageUnavailable))
        XCTAssertEqual(f.session.pendingEdits, original)
        await f.probe.finishAudit(0, outcome: .damaged(.corruptData))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(f.session.integrityModel.state, .checking)
        await f.probe.finishAudit(1)
        try await wait { f.session.integrityModel.state == .verified(revisions: 1) }
        XCTAssertEqual(f.session.saveState, .failed(.storageUnavailable))
        XCTAssertEqual(f.session.pendingEdits, original)
    }

    func testCaptureFailureLeavesPublishedAcknowledgmentIntactAndHistoryIncomplete() async throws {
        let legacy = try await fixture(legacy: true)
        defer { try? FileManager.default.removeItem(at: legacy.root) }
        try await wait { await legacy.probe.auditCount == 1 }
        await legacy.probe.setCaptureFailure(.corruptData("The new pin could not be read."))
        let owner = legacy.session.makeCanvasSeed().ownerID
        observe(legacy.session, owner: owner, generation: 1)
        await legacy.session.waitUntilSettled()
        XCTAssertTrue(legacy.session.pendingEdits.isEmpty)
        guard case .saved = legacy.session.saveState else { return XCTFail("Published edit was not acknowledged.") }
        XCTAssertEqual(legacy.session.integrityModel.state, .incomplete(.corruptData))
        XCTAssertEqual(legacy.session.inputGate, .open)
        await legacy.probe.finishAudit(0, outcome: .damaged(.corruptData))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(legacy.session.integrityModel.state, .incomplete(.corruptData))
        observe(legacy.session, owner: owner, generation: 2)
        await legacy.session.waitUntilSettled()
        let legacyCounts = await legacy.probe.counts()
        XCTAssertEqual(legacyCounts.captures, 1)
        XCTAssertEqual(legacyCounts.audits, 1)
    }

    func testCaptureFailurePreservesOriginalThrownSaveAndIndexedRejectionTail() async throws {
        let f = try await fixture(legacy: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await wait { await f.probe.auditCount == 1 }
        await f.probe.failAfterMigration()
        await f.probe.setCaptureFailure(.revisionConflict)
        let owner = f.session.makeCanvasSeed().ownerID
        observe(f.session, owner: owner, generation: 1)
        let original = f.session.pendingEdits
        await f.session.waitUntilSettled()
        XCTAssertEqual(f.session.saveState, .failed(.storageUnavailable))
        XCTAssertEqual(f.session.pendingEdits, original)
        XCTAssertEqual(f.session.integrityModel.state, .incomplete(.revisionConflict))
        await f.probe.finishAudit(0)

        let partial = try await fixture(legacy: true)
        defer { try? FileManager.default.removeItem(at: partial.root) }
        try await wait { await partial.probe.auditCount == 1 }
        await partial.probe.setCaptureFailure(.revisionConflict)
        await partial.probe.rejectAfterFirst()
        let partialOwner = partial.session.makeCanvasSeed().ownerID
        for index in 1...3 { observe(partial.session, owner: partialOwner, generation: UInt64(index)) }
        let all = partial.session.pendingEdits
        await partial.session.waitUntilSettled()
        XCTAssertEqual(partial.session.saveState, .failed(.contentLimit))
        XCTAssertEqual(partial.session.pendingEdits, Array(all.dropFirst()))
        XCTAssertEqual(partial.session.integrityModel.state, .incomplete(.revisionConflict))
        let committed = await partial.probe.committed
        XCTAssertEqual(committed.map(\.id), [all[0].id])
        XCTAssertEqual(committed[0].content.editStamp, all[0].stamp)
        await partial.probe.finishAudit(0)
    }

    func testForeignCapturePinIsIncompleteAndNeverAudited() async throws {
        let f = try await fixture(legacy: true)
        let other = try await fixture()
        defer {
            try? FileManager.default.removeItem(at: f.root)
            try? FileManager.default.removeItem(at: other.root)
        }
        try await wait {
            let first = await f.probe.auditCount
            let second = await other.probe.auditCount
            return first == 1 && second == 1
        }
        await f.probe.overrideCapture(try XCTUnwrap(other.initial))
        let owner = f.session.makeCanvasSeed().ownerID
        observe(f.session, owner: owner, generation: 1)
        await f.session.waitUntilSettled()
        XCTAssertEqual(f.session.integrityModel.state, .incomplete(.revisionConflict))
        XCTAssertEqual(f.session.inputGate, .open)
        XCTAssertTrue(f.session.pendingEdits.isEmpty)
        let counts = await f.probe.counts()
        XCTAssertEqual(counts.audits, 1)
        await f.probe.finishAudit(0)
        await other.probe.finishAudit(0)
    }

    func testIntegrityTransitionsAndTwentySavesKeepCanvasAndScreenStable() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let hosting = UIHostingController(rootView: NotebookScreen(session: f.session))
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
        defer {
            notebookController(in: hosting)?.tearDown()
            window.isHidden = true
        }
        try await wait {
            let audits = await f.probe.auditCount
            return f.session.renderDiagnostics.screenBodyCount > 0
                && f.session.renderDiagnostics.canvasUpdateCount > 0
                && self.notebookController(in: hosting) != nil
                && audits == 1
        }
        try await Task.sleep(for: .milliseconds(80))
        hosting.view.layoutIfNeeded()
        let controller = try XCTUnwrap(notebookController(in: hosting))
        let identity = ObjectIdentifier(controller)
        let owner = try XCTUnwrap(f.session.canvasOwnerID)
        let generation = f.session.canvasGeneration
        let screen = f.session.renderDiagnostics.screenBodyCount
        let canvas = f.session.renderDiagnostics.canvasUpdateCount
        for index in 1...20 {
            observe(f.session, owner: owner, generation: UInt64(index))
            await f.session.waitUntilSettled()
        }
        await f.probe.finishAudit(0, outcome: .damaged(.corruptData))
        try await wait { controller.inputGate == .readOnly }
        try await Task.sleep(for: .milliseconds(80))
        hosting.view.layoutIfNeeded()
        XCTAssertEqual(f.session.renderDiagnostics.screenBodyCount, screen)
        XCTAssertEqual(f.session.renderDiagnostics.canvasUpdateCount, canvas)
        XCTAssertEqual(notebookController(in: hosting).map(ObjectIdentifier.init), identity)
        XCTAssertEqual(f.session.canvasGeneration, generation)
        XCTAssertTrue(f.session.pendingEdits.isEmpty)
        let committed = await f.probe.committed
        XCTAssertEqual(committed.count, 20)
        print("Notty integrity UI work: edits=20 screenBodies=\(f.session.renderDiagnostics.screenBodyCount - screen) canvasUpdates=\(f.session.renderDiagnostics.canvasUpdateCount - canvas)")
    }


    func testAppliedLegacyDamageIsRetiredOnlyWhenMigrationChangesHistoryGeneration() async throws {
        let f = try await fixture(legacy: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await wait { await f.probe.auditCount == 1 }
        await f.probe.failAfterMigration()
        await f.probe.suspendMigrationOutcome()
        let owner = f.session.makeCanvasSeed().ownerID
        observe(f.session, owner: owner, generation: 1)
        let original = f.session.pendingEdits
        try await wait { await f.probe.hasSuspendedMigration }
        await f.probe.finishAudit(0, outcome: .damaged(.corruptData))
        try await wait { f.session.integrityModel.state == .damaged(.corruptData) }
        await f.probe.releaseMigrationOutcome()
        await f.session.waitUntilSettled()
        try await wait { await f.probe.auditCount == 2 }
        XCTAssertEqual(f.session.integrityModel.state, .checking)
        XCTAssertEqual(f.session.saveState, .failed(.storageUnavailable))
        XCTAssertEqual(f.session.pendingEdits, original)
        let pins = await f.probe.auditPins
        XCTAssertFalse(pins[0].hasSameHistoryGeneration(as: pins[1]))
        await f.probe.finishAudit(1)
        try await wait { f.session.integrityModel.state == .verified(revisions: 1) }
        XCTAssertEqual(f.session.saveState, .failed(.storageUnavailable))
        XCTAssertEqual(f.session.pendingEdits, original)
    }


    func testLegacyWhitespaceChangeCannotClearAppliedDamage() async throws {
        let f = try await fixture(legacy: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await wait { await f.probe.auditCount == 1 }
        await f.probe.finishAudit(0, outcome: .damaged(.corruptData))
        try await wait { f.session.integrityModel.state == .damaged(.corruptData) }
        await f.probe.setSaveFailure(.ioFailure(5))
        try await f.probe.rewriteLegacyHeadWhitespace()
        let owner = f.session.makeCanvasSeed().ownerID
        observe(f.session, owner: owner, generation: 1)
        let original = f.session.pendingEdits
        await f.session.waitUntilSettled()
        try await wait { await f.probe.auditCount == 2 }
        let pins = await f.probe.auditPins
        XCTAssertTrue(pins[1].requiresFirstPublicationRefresh)
        XCTAssertTrue(pins[0].hasSameHistoryGeneration(as: pins[1]))
        await f.probe.finishAudit(1)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(f.session.integrityModel.state, .damaged(.corruptData))
        XCTAssertEqual(f.session.saveState, .failed(.storageUnavailable))
        XCTAssertEqual(f.session.pendingEdits, original)
    }

    func testMalformedVerifiedReportCannotMarkHistoryVerified() async throws {
        for invalidAssets in [false, true] {
            let f = try await fixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            try await wait { await f.probe.auditCount == 1 }
            let pin = try XCTUnwrap(f.initial)
            await f.probe.finishAudit(0, outcome: .verified(NotebookHistoryAudit(
                notebookID: pin.notebookID, headRevisionID: pin.revisionID,
                revisionCount: invalidAssets ? pin.sequence : pin.sequence + 1,
                verifiedAssetCount: invalidAssets ? -1 : 0
            )))
            try await wait { f.session.integrityModel.state == .damaged(.corruptData) }
            XCTAssertEqual(f.session.inputGate, .readOnly)
        }
    }

    private func notebookController(in controller: UIViewController) -> NotebookViewController? {
        if let notebook = controller as? NotebookViewController { return notebook }
        for child in controller.children {
            if let notebook = notebookController(in: child) { return notebook }
        }
        return nil
    }
}

private actor IntegrityStorageProbe {
    let repository: NotebookRepository
    let recovery: NotebookRecoveryStore
    let notebookID: UUID
    private let libraryRoot: URL
    private(set) var openings: [NotebookOpening] = []
    private(set) var auditPins: [NotebookHistoryPin] = []
    private(set) var capturedRevisions: [UUID] = []
    private(set) var committed: [NotebookSaveEdit] = []
    private var auditContinuations: [Int: CheckedContinuation<NotebookIntegrityOutcome, Never>] = [:]
    private var recoveryReadContinuation: CheckedContinuation<Void, Never>?
    private var suspendRecovery = false
    var hasSuspendedRecoveryRead: Bool { recoveryReadContinuation != nil }
    private var saveContinuation: CheckedContinuation<Void, Never>?
    private var shouldSuspendSave = false
    private var saveFailure: NotebookRepositoryError?
    private var captureFailure: NotebookRepositoryError?
    private var captureOverride: NotebookHistoryPin?
    private var migrateBeforeFailure = false
    private var rejectTail = false
    private var suspendAfterMigration = false
    private var migrationContinuation: CheckedContinuation<Void, Never>?
    var hasSuspendedMigration: Bool { migrationContinuation != nil }

    var auditCount: Int { auditPins.count }
    var hasSuspendedSave: Bool { saveContinuation != nil }

    init(root: URL, notebookID: UUID) throws {
        let library = root.appendingPathComponent("library")
        self.libraryRoot = library
        self.repository = try NotebookRepository(rootURL: library)
        self.recovery = try NotebookRecoveryStore(rootURL: root.appendingPathComponent("recovery"))
        self.notebookID = notebookID
    }

    func seed() async throws {
        _ = try await repository.save(
            id: notebookID, content: NotebookContent(title: "Notebook", pageCount: 3, strokes: []),
            expectedRevisionID: nil
        )
    }

    func current() async throws -> StoredNotebook? { try await repository.load(id: notebookID) }
    func counts() -> (audits: Int, captures: Int) { (auditPins.count, capturedRevisions.count) }
    func suspendSaves() { shouldSuspendSave = true }
    func setSaveFailure(_ error: NotebookRepositoryError) { saveFailure = error }
    func setCaptureFailure(_ error: NotebookRepositoryError) { captureFailure = error }
    func overrideCapture(_ pin: NotebookHistoryPin) { captureOverride = pin }
    func failAfterMigration() { migrateBeforeFailure = true; saveFailure = .ioFailure(5) }
    func rejectAfterFirst() { rejectTail = true }
    func suspendMigrationOutcome() { suspendAfterMigration = true }
    func releaseMigrationOutcome() {
        suspendAfterMigration = false
        let continuation = migrationContinuation
        migrationContinuation = nil
        continuation?.resume()
    }

    func suspendRecoveryRead() { suspendRecovery = true }
    func releaseRecoveryRead() {
        suspendRecovery = false
        let continuation = recoveryReadContinuation
        recoveryReadContinuation = nil
        continuation?.resume()
    }

    func rewriteLegacyHeadWhitespace() throws {
        let head = libraryRoot.appendingPathComponent(notebookID.uuidString.lowercased())
            .appendingPathComponent("HEAD.json")
        var data = try Data(contentsOf: head)
        data.append(10)
        try data.write(to: head)
    }

    func releaseSave() {
        shouldSuspendSave = false
        let continuation = saveContinuation
        saveContinuation = nil
        continuation?.resume()
    }

    func storage() -> NotebookStorage {
        NotebookStorage(
            load: { try await self.current() },
            save: { try await self.repository.save(id: self.notebookID, content: $0, expectedRevisionID: $1) },
            preserve: { try await self.recovery.preserve($0) },
            listRecovery: { try await self.recovery.scan(notebookID: self.notebookID) },
            loadRecovery: { try await self.readRecovery($0) },
            openForEditing: { try await self.open() },
            captureHistoryPin: { try await self.capture($0) },
            auditHistory: { await self.audit($0) },
            saveBatch: { try await self.save($0, revision: $1) }
        )
    }

    private func readRecovery(_ id: UUID) async throws -> NotebookRecoveryBatch {
        if suspendRecovery {
            await withCheckedContinuation { recoveryReadContinuation = $0 }
        }
        return try await recovery.load(id: id)
    }

    private func open() async throws -> NotebookOpening {
        let result = try await repository.open(id: notebookID)
        let opening = NotebookOpening(notebook: result?.notebook, historyPin: result?.historyPin)
        openings.append(opening)
        return opening
    }

    private func capture(_ revision: UUID) async throws -> NotebookHistoryPin {
        capturedRevisions.append(revision)
        if let captureFailure { throw captureFailure }
        if let captureOverride { return captureOverride }
        return try await repository.captureHistoryPin(id: notebookID, expectedRevisionID: revision)
    }

    private func audit(_ pin: NotebookHistoryPin) async -> NotebookIntegrityOutcome {
        let index = auditPins.count
        auditPins.append(pin)
        // Ignore cancellation here to test the session's stale-result ownership guard.
        return await withCheckedContinuation { auditContinuations[index] = $0 }
    }

    func finishAudit(_ index: Int, outcome: NotebookIntegrityOutcome? = nil) {
        guard let continuation = auditContinuations.removeValue(forKey: index) else { return }
        let pin = auditPins[index]
        continuation.resume(returning: outcome ?? .verified(NotebookHistoryAudit(
            notebookID: pin.notebookID, headRevisionID: pin.revisionID,
            revisionCount: pin.sequence, verifiedAssetCount: 0
        )))
    }

    private func save(_ edits: [NotebookSaveEdit], revision: UUID?) async throws -> NotebookBatchSaveResult {
        if shouldSuspendSave {
            await withCheckedContinuation { saveContinuation = $0 }
        }
        if migrateBeforeFailure, let revision {
            _ = try await repository.migrateHistory(id: notebookID, expectedRevisionID: revision)
            migrateBeforeFailure = false
            if suspendAfterMigration {
                await withCheckedContinuation { migrationContinuation = $0 }
            }
        }
        if let saveFailure { throw saveFailure }
        if rejectTail, edits.count > 1 {
            let result = try await repository.saveBatch(
                id: notebookID, edits: [edits[0]], expectedRevisionID: revision
            )
            committed.append(edits[0])
            return NotebookBatchSaveResult(
                committed: result.committed,
                rejection: NotebookBatchFailure(
                    index: 1, editID: edits[1].id, error: .sizeLimitExceeded("The later edit exceeds capacity.")
                )
            )
        }
        let result = try await repository.saveBatch(id: notebookID, edits: edits, expectedRevisionID: revision)
        committed.append(contentsOf: edits.prefix(result.committed.count))
        return result
    }

    static func writeLegacy(root: URL, id: UUID) throws {
        let directory = root.appendingPathComponent("library", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        let revisions = directory.appendingPathComponent("revisions", isDirectory: true)
        try FileManager.default.createDirectory(at: revisions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("assets", isDirectory: true), withIntermediateDirectories: true
        )
        let revisionID = UUID()
        let revision = NotebookRevisionFormat.LegacyRevision(
            schemaVersion: 1, notebookID: id, revisionID: revisionID, parentRevisionID: nil,
            sequence: 1, title: "Notebook", pageCount: 3, strokes: [], editStamp: nil,
            savedAt: Date(timeIntervalSince1970: 1_000)
        )
        let data = try NotebookRevisionFormat.encode(revision)
        try data.write(to: revisions.appendingPathComponent(revisionID.uuidString.lowercased() + ".json"))
        let head = NotebookRevisionFormat.Head(
            schemaVersion: 1, notebookID: id, revisionID: revisionID,
            revisionDigest: NotebookRevisionFormat.digest(data), generationID: nil, migrationReceiptDigest: nil
        )
        try NotebookRevisionFormat.encode(head).write(to: directory.appendingPathComponent("HEAD.json"))
    }
}
