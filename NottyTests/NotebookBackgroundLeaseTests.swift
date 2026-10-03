import Foundation
import NottyCore
import PencilKit
import UIKit
import XCTest
@testable import Notty

@MainActor
final class NotebookBackgroundLeaseTests: XCTestCase {
    func testExpirationEndsSynchronouslyExactlyOnceAndCannotEndNextLease() throws {
        var expirations: [@MainActor @Sendable () -> Void] = []
        var ended: [UIBackgroundTaskIdentifier] = []
        var identifier = 40
        let lease = NotebookBackgroundLease(begin: { expiration in
            expirations.append(expiration)
            identifier += 1
            return UIBackgroundTaskIdentifier(rawValue: identifier)
        }, end: { ended.append($0) })
        let first = try XCTUnwrap(lease.start())
        let again = try XCTUnwrap(lease.start())
        XCTAssertEqual(first, again)
        XCTAssertEqual(expirations.count, 1)
        expirations[0]()
        XCTAssertEqual(ended.map(\.rawValue), [41])
        lease.finish(first)
        XCTAssertEqual(ended.count, 1)
        let second = try XCTUnwrap(lease.start())
        expirations[0]()
        lease.finish(first)
        XCTAssertEqual(ended.count, 1)
        lease.finish(second)
        expirations[1]()
        XCTAssertEqual(ended.map(\.rawValue), [41, 42])
    }

    func testImmediateExpirationAndUnsupportedCapabilityDoNotLeakOrEndInvalidToken() {
        var ended: [UIBackgroundTaskIdentifier] = []
        let immediate = NotebookBackgroundLease(begin: { expiration in
            expiration()
            return UIBackgroundTaskIdentifier(rawValue: 12)
        }, end: { ended.append($0) })
        XCTAssertNil(immediate.start())
        XCTAssertEqual(ended.map(\.rawValue), [12])

        let unsupported = NotebookBackgroundLease(begin: { _ in .invalid }, end: { ended.append($0) })
        XCTAssertNil(unsupported.start())
        XCTAssertNil(unsupported.start())
        XCTAssertEqual(ended.map(\.rawValue), [12])
    }

    func testSessionRenewsExpiredLeaseForPendingWriterWithoutDuplicatingSave() async throws {
        let root = NotebookTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let notebookID = UUID()
        let stored = try await NotebookTestFixtures.stored(id: notebookID)
        let probe = try NotebookStorageProbe(stored: stored, recoveryRoot: root)
        await probe.setSuspendSave()
        let storage = await probe.storage(notebookID: notebookID)
        var expirations: [@MainActor @Sendable () -> Void] = []
        var ended: [UIBackgroundTaskIdentifier] = []
        var nextIdentifier = 50
        let lease = NotebookBackgroundLease(begin: { expiration in
            expirations.append(expiration)
            nextIdentifier += 1
            return UIBackgroundTaskIdentifier(rawValue: nextIdentifier)
        }, end: { ended.append($0) })
        let session = NotebookSession(
            notebookID: notebookID, backgroundLease: lease, openStorage: { storage }
        )
        await session.load()
        let seed = session.makeCanvasSeed()
        session.recordCompletedEdit(
            PKDrawing(strokes: [NotebookTestFixtures.stroke()]), ownerID: seed.ownerID
        )
        await probe.waitForSave()
        session.flush()
        XCTAssertEqual(expirations.count, 1)
        expirations[0]()
        XCTAssertEqual(ended.map(\.rawValue), [51])
        XCTAssertEqual(session.saveState, .saving)
        session.flush()
        session.flush()
        XCTAssertEqual(expirations.count, 2)
        expirations[0]()
        XCTAssertEqual(ended.map(\.rawValue), [51])
        let calls = await probe.saveCalls
        XCTAssertEqual(calls, 1)
        await probe.releaseSave()
        await session.waitUntilSettled()
        XCTAssertTrue(session.canEdit)
        XCTAssertEqual(ended.map(\.rawValue), [51, 52])
        expirations[1]()
        XCTAssertEqual(ended.map(\.rawValue), [51, 52])
    }

    func testFailedFlushPreservesEveryEditOnceBeforeEndingLease() async throws {
        let fixture = try await failedSession()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pending = fixture.session.pendingEdits
        fixture.session.flush()
        await fixture.probe.waitForPreserve()
        XCTAssertEqual(fixture.leases.started, 1)
        XCTAssertTrue(fixture.leases.ended.isEmpty)
        fixture.session.flush()
        let calls = await fixture.probe.preserveCalls
        XCTAssertEqual(calls, 1)
        await fixture.probe.releasePreserve()
        await fixture.session.waitUntilSettled()
        XCTAssertEqual(fixture.leases.ended, [101])
        XCTAssertTrue(fixture.session.canReopenSaved)
        XCTAssertEqual(fixture.session.pendingEdits, pending)
        let preserved = await fixture.probe.preservedBatch
        let batch = try XCTUnwrap(preserved)
        XCTAssertEqual(batch.edits.map(\.id), pending.map(\.id))
        XCTAssertEqual(batch.edits.map(\.stamp), pending.map(\.stamp))
        fixture.session.flush()
        await fixture.session.waitUntilSettled()
        await fixture.session.refreshRecoveryCopies()
        XCTAssertEqual(fixture.session.recoveryCopies.count, 1)
        XCTAssertEqual(fixture.leases.started, 1)
        XCTAssertEqual(fixture.leases.ended, [101])
    }

    func testFailureDuringBackgroundDrainPreservesBeforeEndingLease() async throws {
        let fixture = try await failedSession(suspendSave: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.session.flush()
        XCTAssertEqual(fixture.leases.started, 1)
        await fixture.probe.releaseSave()
        await fixture.probe.waitForPreserve()
        XCTAssertEqual(fixture.session.saveState, .failed(.contentLimit))
        XCTAssertTrue(fixture.leases.ended.isEmpty)
        await fixture.probe.releasePreserve()
        await fixture.session.waitUntilSettled()
        XCTAssertTrue(fixture.session.canReopenSaved)
        XCTAssertEqual(fixture.leases.ended, [101])
        let calls = await fixture.probe.saveCalls
        XCTAssertEqual(calls, 1)
    }

    func testFailedBackgroundPreservationRetainsEditsAndCanRetryNextFlush() async throws {
        let fixture = try await failedSession(suspendPreserve: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pending = fixture.session.pendingEdits
        await fixture.probe.setPreserveFailure(.storageFull)
        fixture.session.flush()
        await fixture.session.waitUntilSettled()
        XCTAssertEqual(fixture.session.recoveryFailure, .storageFull)
        XCTAssertNotNil(fixture.session.recoveryMessage)
        XCTAssertEqual(fixture.session.pendingEdits, pending)
        XCTAssertFalse(fixture.session.canReopenSaved)
        XCTAssertEqual(fixture.leases.ended, [101])
        let failedCalls = await fixture.probe.preserveCalls
        XCTAssertEqual(failedCalls, 1)
        await fixture.probe.setPreserveFailure(nil)
        fixture.session.flush()
        await fixture.session.waitUntilSettled()
        XCTAssertTrue(fixture.session.canReopenSaved)
        XCTAssertEqual(fixture.session.pendingEdits, pending)
        XCTAssertEqual(fixture.leases.ended, [101, 102])
    }

    func testBackgroundPreservationCoversLateCompletedEditWithoutDroppingEarlierStates() async throws {
        let fixture = try await failedSession()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = fixture.session.pendingEdits
        fixture.session.flush()
        await fixture.probe.waitForPreserve()
        let seed = fixture.session.makeCanvasSeed()
        fixture.session.recordCompletedEdit(PKDrawing(), ownerID: seed.ownerID)
        let all = fixture.session.pendingEdits
        XCTAssertEqual(all.count, original.count + 1)
        XCTAssertEqual(Array(all.prefix(original.count)), original)
        await fixture.probe.releasePreserve()
        await fixture.session.waitUntilSettled()
        XCTAssertTrue(fixture.session.canReopenSaved)
        XCTAssertEqual(fixture.session.pendingEdits, all)
        let preserved = await fixture.probe.preservedBatch
        let batch = try XCTUnwrap(preserved)
        XCTAssertEqual(batch.edits.map(\.id), all.map(\.id))
        XCTAssertEqual(batch.edits.map(\.stamp), all.map(\.stamp))
        let calls = await fixture.probe.preserveCalls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(fixture.leases.ended, [101])
    }

    func testManualPreservationAndRepeatedFlushShareWorkAcrossExpiryAndCallerCancellation() async throws {
        let fixture = try await failedSession()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manual = Task { await fixture.session.saveRecoveryCopy() }
        await fixture.probe.waitForPreserve()
        fixture.session.flush()
        fixture.session.flush()
        XCTAssertEqual(fixture.leases.started, 1)
        fixture.leases.expirations[0]()
        XCTAssertEqual(fixture.leases.ended, [101])
        fixture.session.flush()
        fixture.session.flush()
        XCTAssertEqual(fixture.leases.started, 2)
        manual.cancel()
        fixture.leases.expirations[0]()
        XCTAssertEqual(fixture.leases.ended, [101])
        await fixture.probe.releasePreserve()
        await manual.value
        await fixture.session.waitUntilSettled()
        XCTAssertTrue(fixture.session.canReopenSaved)
        XCTAssertEqual(fixture.leases.ended, [101, 102])
        fixture.leases.expirations[1]()
        XCTAssertEqual(fixture.leases.ended, [101, 102])
        let calls = await fixture.probe.preserveCalls
        XCTAssertEqual(calls, 1)
        await fixture.session.reopenSavedNotebook()
        fixture.session.flush()
        XCTAssertEqual(fixture.leases.started, 2)
        XCTAssertTrue(fixture.session.pendingEdits.isEmpty)
    }

    func testFullNativeQueueBackgroundRecoveryRetainsEveryTenThousandStrokeState() async throws {
        let fixture = try await failedSession(
            suspendSave: true, suspendPreserve: false, enqueueDrawing: false
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let seed = fixture.session.makeCanvasSeed()
        let template = NotebookTestFixtures.stroke()
        let strokes = (0..<10_000).map { _ in
            var copy = template
            copy.id = UUID()
            return copy
        }
        for index in 0..<8 {
            var changed = strokes
            changed[0].transform = CGAffineTransform(translationX: CGFloat(index), y: 0)
            fixture.session.recordCompletedEdit(PKDrawing(strokes: changed), ownerID: seed.ownerID)
        }
        await fixture.probe.waitForSave()
        let pending = fixture.session.pendingEdits
        XCTAssertEqual(pending.count, 8)
        XCTAssertEqual(fixture.session.inputGate, .capacity)
        fixture.session.flush()
        await fixture.probe.releaseSave()
        await fixture.session.waitUntilSettled()
        XCTAssertEqual(fixture.session.saveState, .failed(.contentLimit))
        XCTAssertNil(fixture.session.recoveryFailure)
        XCTAssertTrue(fixture.session.canReopenSaved)
        XCTAssertEqual(fixture.session.pendingEdits, pending)
        await fixture.session.refreshRecoveryCopies()
        let receipt = try XCTUnwrap(fixture.session.recoveryCopies.first)
        XCTAssertEqual(fixture.session.recoveryCopies.count, 1)
        let batch = try await fixture.session.openRecoveryCopy(id: receipt.id)
        XCTAssertEqual(batch.edits.map(\.id), pending.map(\.id))
        XCTAssertEqual(batch.edits.map(\.stamp), pending.map(\.stamp))
        XCTAssertEqual(batch.edits.map(\.strokeIDs), pending.map { $0.snapshot.drawing.strokes.map(\.id) })
        let codec = NotebookRecoveryCodec()
        for (edit, expected) in zip(batch.edits, pending) {
            let decoded = try await codec.decode(edit)
            XCTAssertEqual(decoded.strokes.map(\.id), expected.snapshot.drawing.strokes.map(\.id))
            XCTAssertEqual(decoded.strokes[0].transform, expected.snapshot.drawing.strokes[0].transform)
        }
        XCTAssertEqual(fixture.leases.ended, [101])
    }


    func testBackgroundFlushWaitsForReopenAndProtectsLateEditsAfterReopenIsRefused() async throws {
        let fixture = try await failedSession(suspendPreserve: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.session.saveRecoveryCopy()
        await fixture.probe.setSuspendLoad()
        let reopening = Task { await fixture.session.reopenSavedNotebook() }
        await fixture.probe.waitForLoad()
        let seed = fixture.session.makeCanvasSeed()
        fixture.session.recordCompletedEdit(PKDrawing(), ownerID: seed.ownerID)
        let pending = fixture.session.pendingEdits
        await fixture.probe.setSuspendPreserve()
        fixture.session.flush()
        XCTAssertEqual(fixture.leases.started, 1)
        await fixture.probe.releaseLoad()
        await reopening.value
        await fixture.probe.waitForPreserve()
        XCTAssertEqual(fixture.session.pendingEdits, pending)
        XCTAssertTrue(fixture.leases.ended.isEmpty)
        await fixture.probe.releasePreserve()
        await fixture.session.waitUntilSettled()
        XCTAssertTrue(fixture.session.canReopenSaved)
        XCTAssertEqual(fixture.session.pendingEdits, pending)
        XCTAssertEqual(fixture.leases.ended, [101])
        await fixture.session.reopenSavedNotebook()
        XCTAssertTrue(fixture.session.pendingEdits.isEmpty)
        XCTAssertFalse(fixture.session.recordCompletedEdit(
            PKDrawing(strokes: [NotebookTestFixtures.stroke()]), ownerID: seed.ownerID
        ))
        fixture.session.flush()
        XCTAssertEqual(fixture.leases.started, 1)
    }


    func testFlushSettlesLateHealthyCanvasWorkBeforeEndingLease() async throws {
        let fixture = try await failedSession(suspendSave: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.probe.setSaveFailure(nil)
        let seed = fixture.session.makeCanvasSeed()
        var canvasDrawing = seed.drawing
        fixture.session.attachCanvas(ownerID: seed.ownerID) { canvasDrawing }
        fixture.session.flush()
        let late = PKDrawing(strokes: [
            NotebookTestFixtures.stroke(), NotebookTestFixtures.stroke(x: 120)
        ])
        canvasDrawing = late
        await fixture.probe.releaseSave(suspendNext: true)
        await fixture.probe.waitForSave()
        let pending = fixture.session.pendingEdits
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.snapshot.drawing.strokes.map(\.id), late.strokes.map(\.id))
        XCTAssertEqual(fixture.session.saveState, .saving)
        XCTAssertEqual(fixture.leases.started, 1)
        XCTAssertTrue(fixture.leases.ended.isEmpty)
        await fixture.probe.releaseSave()
        await fixture.session.waitUntilSettled()
        XCTAssertTrue(fixture.session.pendingEdits.isEmpty)
        XCTAssertEqual(fixture.session.workingDrawing.strokes.map(\.id), late.strokes.map(\.id))
        XCTAssertEqual(fixture.leases.ended, [101])
        let calls = await fixture.probe.saveCalls
        XCTAssertEqual(calls, 2)
    }

    func testAttachedOversizedDrawingRepeatedFlushDoesNotCreateAnUnendingRecoveryTail() async throws {
        let fixture = try await failedSession(
            suspendPreserve: false, enqueueDrawing: false
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let seed = fixture.session.makeCanvasSeed()
        let controller = NotebookViewController(pageCount: seed.pageCount, initialDrawing: seed.drawing)
        controller.loadViewIfNeeded()
        controller.onObservation = { [weak session = fixture.session] observation in
            guard let session else { return .readOnly }
            session.recordObservation(observation, ownerID: seed.ownerID)
            return session.inputGateForCanvas(ownerID: seed.ownerID)
        }
        fixture.session.attachCanvas(ownerID: seed.ownerID, observations: { [weak controller] in
            controller?.captureBarrier()
        })
        defer { controller.tearDown() }
        let template = NotebookTestFixtures.stroke()
        let strokes = (0...InkCodec.maximumStrokeCount).map { _ in
            var stroke = template
            stroke.id = UUID()
            return stroke
        }
        controller.canvasView.drawing = PKDrawing(strokes: strokes)
        _ = controller.captureBarrier()
        await fixture.session.waitUntilSettled()
        XCTAssertEqual(fixture.session.saveState, .failed(.contentLimit))
        fixture.session.flush()
        await fixture.session.waitUntilSettled()
        XCTAssertTrue(fixture.session.canReopenSaved)
        let protected = fixture.session.pendingEdits
        let copies = await fixture.probe.preserveCalls
        XCTAssertFalse(protected.isEmpty)
        XCTAssertEqual(copies, 1)
        for _ in 0..<4 {
            fixture.session.flush()
            await fixture.session.waitUntilSettled()
        }
        XCTAssertEqual(fixture.session.pendingEdits, protected)
        XCTAssertTrue(fixture.session.canReopenSaved)
        let after = await fixture.probe.preserveCalls
        XCTAssertEqual(after, copies)
        XCTAssertEqual(fixture.leases.started, 1)
        XCTAssertEqual(fixture.leases.ended, [101])
    }

    private struct FailedSession {
        let session: NotebookSession
        let probe: NotebookStorageProbe
        let leases: LeaseProbe
        let root: URL
    }

    @MainActor
    private final class LeaseProbe {
        var expirations: [@MainActor @Sendable () -> Void] = []
        var ended: [Int] = []
        var started: Int { expirations.count }

        @MainActor
        func makeLease() -> NotebookBackgroundLease {
            NotebookBackgroundLease(begin: { [self] expiration in
                expirations.append(expiration)
                return UIBackgroundTaskIdentifier(rawValue: 100 + expirations.count)
            }, end: { [self] in ended.append($0.rawValue) })
        }
    }

    private func failedSession(
        suspendSave: Bool = false,
        suspendPreserve: Bool = true,
        enqueueDrawing: Bool = true
    ) async throws -> FailedSession {
        let root = NotebookTestFixtures.root()
        let id = UUID()
        let stored = try await NotebookTestFixtures.stored(id: id)
        let probe = try NotebookStorageProbe(stored: stored, recoveryRoot: root)
        await probe.setSaveFailure(.contentLimit)
        if suspendSave { await probe.setSuspendSave() }
        if suspendPreserve { await probe.setSuspendPreserve() }
        let storage = await probe.storage(notebookID: id)
        let leases = LeaseProbe()
        let session = NotebookSession(
            notebookID: id, backgroundLease: leases.makeLease(), openStorage: { storage }
        )
        await session.load()
        if enqueueDrawing {
            let seed = session.makeCanvasSeed()
            session.recordCompletedEdit(
                PKDrawing(strokes: [NotebookTestFixtures.stroke()]), ownerID: seed.ownerID
            )
            if suspendSave {
                await probe.waitForSave()
            } else {
                await session.waitUntilSettled()
            }
        }
        return FailedSession(session: session, probe: probe, leases: leases, root: root)
    }

}
