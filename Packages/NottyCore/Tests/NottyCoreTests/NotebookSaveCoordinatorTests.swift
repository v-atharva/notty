import Foundation
import Darwin
import XCTest
@testable import NottyCore

@MainActor
final class NotebookSaveCoordinatorTests: XCTestCase {
    private func stamp(_ index: Int) -> NotebookEditStamp {
        NotebookEditStamp(
            capturedAt: Date(timeIntervalSince1970: Double(index)),
            uptime: Double(index) / 10,
            sessionID: UUID(uuidString: "6435D7F3-7945-475B-8A86-9A66B8DF32AD")!
        )
    }

    private func coordinator(
        saver: SuspendedNotebookSaver
    ) -> NotebookSaveCoordinator<String> {
        NotebookSaveCoordinator { snapshot, stamp, revision in
            try await saver.save(snapshot: snapshot, stamp: stamp, revision: revision)
        }
    }

    func testAddThenUndoPreservesOrderAndCapturedStamps() async {
        let saver = SuspendedNotebookSaver()
        let coordinator = coordinator(saver: saver)
        let added = stamp(1)
        let undone = stamp(2)
        coordinator.enqueue(snapshot: "ink", stamp: added)
        coordinator.enqueue(snapshot: "", stamp: undone)
        await saver.waitForRequests(1)

        let firstReceipt = NotebookSaveReceipt(
            revisionID: UUID(), savedAt: Date(timeIntervalSince1970: 10)
        )
        await saver.succeed(firstReceipt)
        await saver.waitForRequests(2)

        XCTAssertEqual(coordinator.status, .saving)
        XCTAssertEqual(coordinator.pendingCount, 1)
        let requests = await saver.requests
        XCTAssertEqual(requests.map(\.snapshot), ["ink", ""])
        XCTAssertEqual(requests.map(\.stamp), [added, undone])
        XCTAssertNil(requests[0].revision)
        XCTAssertEqual(requests[1].revision, firstReceipt.revisionID)

        let secondReceipt = NotebookSaveReceipt(
            revisionID: UUID(), savedAt: Date(timeIntervalSince1970: 20)
        )
        await saver.succeed(secondReceipt)
        await coordinator.waitUntilSettled()
        XCTAssertEqual(coordinator.status, .saved(secondReceipt.savedAt))
        XCTAssertEqual(coordinator.expectedRevisionID, secondReceipt.revisionID)
        let concurrency = await saver.maximumConcurrentSaves
        XCTAssertEqual(concurrency, 1)
    }

    func testFailureRetainsQueueAndRetryDoesNotDuplicateCommittedEdits() async {
        let saver = SuspendedNotebookSaver()
        let coordinator = coordinator(saver: saver)
        let firstStamp = stamp(1)
        let secondStamp = stamp(2)
        coordinator.enqueue(snapshot: "A", stamp: firstStamp)
        coordinator.enqueue(snapshot: "B", stamp: secondStamp)
        await saver.waitForRequests(1)
        await saver.fail()
        await coordinator.waitUntilSettled()

        XCTAssertEqual(coordinator.status, .failed(.storageUnavailable))
        XCTAssertEqual(coordinator.pendingCount, 2)
        XCTAssertFalse(coordinator.canAcceptInput)
        XCTAssertNil(coordinator.expectedRevisionID)

        coordinator.retry()
        coordinator.retry()
        await saver.waitForRequests(2)
        let firstReceipt = NotebookSaveReceipt(revisionID: UUID(), savedAt: Date())
        await saver.succeed(firstReceipt)
        await saver.waitForRequests(3)
        let secondReceipt = NotebookSaveReceipt(revisionID: UUID(), savedAt: Date())
        await saver.succeed(secondReceipt)
        await coordinator.waitUntilSettled()

        let requests = await saver.requests
        XCTAssertEqual(requests.map(\.snapshot), ["A", "A", "B"])
        XCTAssertEqual(requests.map(\.stamp), [firstStamp, firstStamp, secondStamp])
        XCTAssertNil(requests[0].revision)
        XCTAssertNil(requests[1].revision)
        XCTAssertEqual(requests[2].revision, firstReceipt.revisionID)
        XCTAssertEqual(coordinator.pendingCount, 0)
        XCTAssertEqual(coordinator.status, .saved(secondReceipt.savedAt))
        let concurrency = await saver.maximumConcurrentSaves
        XCTAssertEqual(concurrency, 1)
    }

    func testCapacityPausesThenResumesAsReceiptsArrive() async {
        let saver = SuspendedNotebookSaver()
        let coordinator = coordinator(saver: saver)
        for index in 1...8 {
            XCTAssertTrue(coordinator.canAcceptInput)
            coordinator.enqueue(snapshot: String(index), stamp: stamp(index))
        }
        XCTAssertEqual(coordinator.pendingCount, 8)
        XCTAssertFalse(coordinator.canAcceptInput)
        await saver.waitForRequests(1)
        await saver.succeed(NotebookSaveReceipt(revisionID: UUID(), savedAt: Date()))
        await saver.waitForRequests(2)
        XCTAssertEqual(coordinator.pendingCount, 7)
        XCTAssertTrue(coordinator.canAcceptInput)

        for index in 2...8 {
            await saver.succeed(NotebookSaveReceipt(revisionID: UUID(), savedAt: Date()))
            if index < 8 { await saver.waitForRequests(index + 1) }
        }
        await coordinator.waitUntilSettled()
        let requests = await saver.requests
        XCTAssertEqual(requests.map(\.snapshot), (1...8).map(String.init))
        XCTAssertEqual(requests.map(\.stamp), (1...8).map(stamp))
        XCTAssertEqual(coordinator.pendingCount, 0)
        XCTAssertTrue(coordinator.canAcceptInput)
    }

    func testNoOpDedupUsesLastQueuedSnapshot() async {
        let saver = SuspendedNotebookSaver()
        let coordinator = coordinator(saver: saver)
        coordinator.enqueue(snapshot: "A", stamp: stamp(1))
        coordinator.enqueue(snapshot: "A", stamp: stamp(2))
        coordinator.enqueue(snapshot: "B", stamp: stamp(3))
        XCTAssertEqual(coordinator.pendingCount, 2)
        await saver.waitForRequests(1)
        await saver.succeed(NotebookSaveReceipt(revisionID: UUID(), savedAt: Date()))
        await saver.waitForRequests(2)
        await saver.succeed(NotebookSaveReceipt(revisionID: UUID(), savedAt: Date()))
        await coordinator.waitUntilSettled()
        let requests = await saver.requests
        XCTAssertEqual(requests.map(\.stamp), [stamp(1), stamp(3)])
    }

    func testPermanentFailuresRetainIdentitiesStampsAndCursorWithoutRetrying() async {
        for cause in [NotebookSaveFailure.contentLimit, .revisionConflict, .corruptData,
                      .unsupportedFormat, .unsafeStorage, .invalidContent, .unexpected] {
            let saver = SuspendedNotebookSaver()
            let baseRevision = UUID()
            let coordinator = NotebookSaveCoordinator<String>(
                initialSnapshot: "", expectedRevisionID: baseRevision
            ) { snapshot, stamp, revision in
                try await saver.save(snapshot: snapshot, stamp: stamp, revision: revision)
            }
            coordinator.enqueue(snapshot: "A", stamp: stamp(1))
            coordinator.enqueue(snapshot: "B", stamp: stamp(2))
            let original = coordinator.pendingEdits
            let generation = coordinator.generation
            await saver.waitForRequests(1)
            await saver.fail(cause)
            await coordinator.waitUntilSettled()
            coordinator.retry()
            await coordinator.waitUntilSettled()
            XCTAssertEqual(coordinator.status, .failed(cause))
            XCTAssertEqual(coordinator.pendingEdits, original)
            XCTAssertEqual(coordinator.generation, generation)
            XCTAssertEqual(coordinator.expectedRevisionID, baseRevision)
            XCTAssertFalse(coordinator.canAcceptInput)
            let requests = await saver.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testGenerationAndStableIDsDistinguishEqualCountsAndLateCompletedEdits() async {
        let saver = SuspendedNotebookSaver()
        let coordinator = coordinator(saver: saver)
        coordinator.enqueue(snapshot: "A", stamp: stamp(1))
        coordinator.enqueue(snapshot: "B", stamp: stamp(2))
        let captured = coordinator.pendingEdits
        let generation = coordinator.generation
        await saver.waitForRequests(1)
        await saver.fail(NotebookSaveFailure.storageFull)
        await coordinator.waitUntilSettled()
        coordinator.enqueue(snapshot: "A", stamp: stamp(3))
        XCTAssertEqual(Array(coordinator.pendingEdits.prefix(2)), captured)
        XCTAssertEqual(coordinator.pendingEdits.map(\.stamp), [stamp(1), stamp(2), stamp(3)])
        XCTAssertEqual(Set(coordinator.pendingEdits.map(\.id)).count, 3)
        XCTAssertGreaterThan(coordinator.generation, generation)
        coordinator.retry()
        await saver.waitForRequests(2)
        await saver.succeed(NotebookSaveReceipt(revisionID: UUID(), savedAt: Date()))
        await saver.waitForRequests(3)
        XCTAssertEqual(coordinator.pendingCount, captured.count)
        XCTAssertNotEqual(coordinator.pendingEdits.map(\.id), captured.map(\.id))
        XCTAssertGreaterThan(coordinator.generation, generation)
        await saver.succeed(NotebookSaveReceipt(revisionID: UUID(), savedAt: Date()))
        await saver.waitForRequests(4)
        await saver.succeed(NotebookSaveReceipt(revisionID: UUID(), savedAt: Date()))
        await coordinator.waitUntilSettled()
    }

    func testBatchBudgetPrefixDrainsLateTailWithoutChangingIdentitiesOrStamps() async {
        let saver = SuspendedNotebookBatchSaver()
        let base = UUID()
        let coordinator = NotebookSaveCoordinator<String>(
            expectedRevisionID: base, saveBatch: { try await saver.save($0, revision: $1) }
        )
        coordinator.enqueue(edit: NotebookPendingEdit(snapshot: "0", stamp: stamp(0)))
        await saver.waitForRequests(1)
        for index in 1...8 {
            coordinator.enqueue(edit: NotebookPendingEdit(snapshot: String(index), stamp: stamp(index)))
        }
        let original = coordinator.pendingEdits
        await saver.succeed(committedCount: 1)
        await saver.waitForRequests(2)
        let second = await saver.requests[1]
        XCTAssertEqual(second.edits.map(\.id), Array(original.dropFirst()).map(\.id))
        XCTAssertEqual(second.edits.map(\.stamp), Array(original.dropFirst()).map(\.stamp))
        XCTAssertEqual(second.edits.count, 8)
        coordinator.enqueue(edit: NotebookPendingEdit(snapshot: "late", stamp: stamp(99)))
        let tail = coordinator.pendingEdits
        await saver.succeed(committedCount: 3)
        await saver.waitForRequests(3)
        let third = await saver.requests[2]
        XCTAssertEqual(third.edits, Array(tail.dropFirst(3)))
        XCTAssertEqual(coordinator.pendingEdits, third.edits)
        await saver.succeed(committedCount: third.edits.count)
        await coordinator.waitUntilSettled()
        let requests = await saver.requests
        XCTAssertEqual(requests[0].revision, base)
        XCTAssertNotEqual(requests[1].revision, base)
        XCTAssertNotEqual(requests[2].revision, requests[1].revision)
        XCTAssertTrue(coordinator.pendingEdits.isEmpty)
        XCTAssertTrue(coordinator.canAcceptInput)
    }

    func testBatchIndexedFailureCommitsOnlyMatchingPrefixAndRetryKeepsTail() async {
        let saver = SuspendedNotebookBatchSaver()
        let coordinator = NotebookSaveCoordinator<String>(
            saveBatch: { try await saver.save($0, revision: $1) }
        )
        for index in 0..<4 {
            coordinator.enqueue(edit: NotebookPendingEdit(snapshot: String(index), stamp: stamp(index)))
        }
        let original = coordinator.pendingEdits
        await saver.waitForRequests(1)
        await saver.succeed(committedCount: 2, failure: .storageUnavailable)
        await coordinator.waitUntilSettled()
        XCTAssertEqual(coordinator.pendingEdits, Array(original.dropFirst(2)))
        XCTAssertEqual(coordinator.status, .failed(.storageUnavailable))
        let revision = coordinator.expectedRevisionID
        XCTAssertNotNil(revision)
        coordinator.retry()
        await saver.waitForRequests(2)
        let request = await saver.requests[1]
        XCTAssertEqual(request.edits, Array(original.dropFirst(2)))
        XCTAssertEqual(request.revision, revision)
        await saver.succeed(committedCount: 2)
        await coordinator.waitUntilSettled()
        XCTAssertTrue(coordinator.pendingEdits.isEmpty)
    }

    func testMalformedBatchOutcomesAcknowledgeNothingAndNeverSpin() async {
        for variant in 0..<7 {
            let saver = SuspendedNotebookBatchSaver()
            let base = UUID()
            let coordinator = NotebookSaveCoordinator<String>(
                expectedRevisionID: base, saveBatch: { try await saver.save($0, revision: $1) }
            )
            for index in 0..<3 {
                coordinator.enqueue(edit: NotebookPendingEdit(snapshot: String(index), stamp: stamp(index)))
            }
            let original = coordinator.pendingEdits
            await saver.waitForRequests(1)
            let first = NotebookCommittedEdit(
                editID: original[0].id, revisionID: UUID(), sequence: 1, savedAt: Date()
            )
            let wrong = NotebookCommittedEdit(
                editID: original[1].id, revisionID: first.revisionID, sequence: 1, savedAt: Date()
            )
            let outcome: NotebookSaveBatchOutcome
            switch variant {
            case 0: outcome = NotebookSaveBatchOutcome(committed: [])
            case 1: outcome = NotebookSaveBatchOutcome(committed: [wrong])
            case 2: outcome = NotebookSaveBatchOutcome(committed: [first, wrong])
            case 3: outcome = NotebookSaveBatchOutcome(
                committed: [first], rejection: NotebookPendingFailure(
                    index: 2, editID: original[2].id, cause: .storageFull
                )
            )
            case 4: outcome = NotebookSaveBatchOutcome(
                committed: [first], rejection: NotebookPendingFailure(
                    index: 1, editID: UUID(), cause: .storageFull
                )
            )
            case 5: outcome = NotebookSaveBatchOutcome(committed: [
                NotebookCommittedEdit(
                    editID: original[0].id, revisionID: UUID(), sequence: 0, savedAt: Date()
                )
            ])
            default: outcome = NotebookSaveBatchOutcome(committed: [
                NotebookCommittedEdit(
                    editID: original[0].id, revisionID: base, sequence: 1, savedAt: Date()
                )
            ])
            }
            await saver.finish(outcome)
            await coordinator.waitUntilSettled()
            XCTAssertEqual(coordinator.pendingEdits, original)
            XCTAssertEqual(coordinator.expectedRevisionID, base)
            XCTAssertEqual(coordinator.status, .failed(.corruptData))
            let requests = await saver.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testExplicitObservedEditsKeepEqualStatesWithDifferentIDsAndStamps() async {
        let saver = SuspendedNotebookBatchSaver()
        let coordinator = NotebookSaveCoordinator<String>(
            saveBatch: { try await saver.save($0, revision: $1) }
        )
        let edits = (0..<3).map {
            NotebookPendingEdit(snapshot: "same", stamp: stamp($0))
        }
        edits.forEach { coordinator.enqueue(edit: $0) }
        await saver.waitForRequests(1)
        let request = await saver.requests[0]
        XCTAssertEqual(request.edits, edits)
        await saver.succeed(committedCount: 3)
        await coordinator.waitUntilSettled()
        XCTAssertTrue(coordinator.pendingEdits.isEmpty)
    }

    func testFailuresUseTypedRepositoryCodecAndUnderlyingOperatingSystemCodes() {
        XCTAssertEqual(NotebookSaveFailure.classify(NotebookRepositoryError.recoveryRequired), .corruptData)
        XCTAssertEqual(NotebookSaveFailure.classify(NotebookRepositoryError.revisionConflict), .revisionConflict)
        XCTAssertEqual(NotebookSaveFailure.classify(NotebookRepositoryError.unsafePath("path")), .unsafeStorage)
        XCTAssertEqual(NotebookSaveFailure.classify(InkCodec.CodecError.tooManyStrokes), .contentLimit)
        XCTAssertEqual(NotebookSaveFailure.classify(InkCodec.CodecError.duplicateStrokeID), .invalidContent)
        XCTAssertEqual(NotebookSaveFailure.classify(
            NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteOutOfSpace.rawValue)
        ), .storageFull)
        XCTAssertEqual(NotebookSaveFailure.classify(
            NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteVolumeReadOnly.rawValue)
        ), .storageUnavailable)
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let wrapped = NSError(
            domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )
        XCTAssertEqual(NotebookSaveFailure.classify(wrapped), .storageFull)
        XCTAssertFalse(NotebookSaveFailure.contentLimit.canRetry)
        XCTAssertTrue(NotebookSaveFailure.storageFull.canRetry)
        XCTAssertTrue(NotebookSaveFailure.storageUnavailable.canRetry)
    }

}

private actor SuspendedNotebookSaver {
    struct Request: Sendable {
        let snapshot: String
        let stamp: NotebookEditStamp
        let revision: UUID?
    }

    private(set) var requests: [Request] = []
    private(set) var maximumConcurrentSaves = 0
    private var activeSaves = 0
    private var continuation: CheckedContinuation<NotebookSaveReceipt, Error>?
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func save(
        snapshot: String,
        stamp: NotebookEditStamp,
        revision: UUID?
    ) async throws -> NotebookSaveReceipt {
        activeSaves += 1
        maximumConcurrentSaves = max(maximumConcurrentSaves, activeSaves)
        requests.append(Request(snapshot: snapshot, stamp: stamp, revision: revision))
        let ready = waiters.filter { requests.count >= $0.0 }
        waiters.removeAll { requests.count >= $0.0 }
        ready.forEach { $0.1.resume() }

        do {
            let receipt = try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
            activeSaves -= 1
            return receipt
        } catch {
            activeSaves -= 1
            throw error
        }
    }

    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    func succeed(_ receipt: NotebookSaveReceipt) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: receipt)
    }

    func fail(_ error: any Error = NotebookSaveFailure.storageUnavailable) {
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: error)
    }
}

private actor SuspendedNotebookBatchSaver {
    struct Request: Sendable {
        let edits: [NotebookPendingEdit<String>]
        let revision: UUID?
    }

    private(set) var requests: [Request] = []
    private var continuation: CheckedContinuation<NotebookSaveBatchOutcome, Error>?
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func save(
        _ edits: [NotebookPendingEdit<String>], revision: UUID?
    ) async throws -> NotebookSaveBatchOutcome {
        requests.append(Request(edits: edits, revision: revision))
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let ready = waiters.filter { requests.count >= $0.0 }
            waiters.removeAll { requests.count >= $0.0 }
            ready.forEach { $0.1.resume() }
        }
    }

    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func succeed(committedCount: Int, failure: NotebookSaveFailure? = nil) {
        guard let request = requests.last else { return }
        let receipts = request.edits.prefix(committedCount).enumerated().map {
            NotebookCommittedEdit(
                editID: $0.element.id, revisionID: UUID(),
                sequence: $0.offset + 1, savedAt: Date()
            )
        }
        finish(NotebookSaveBatchOutcome(
            committed: receipts,
            rejection: failure.map {
                NotebookPendingFailure(
                    index: committedCount, editID: request.edits[committedCount].id, cause: $0
                )
            }
        ))
    }

    func finish(_ outcome: NotebookSaveBatchOutcome) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: outcome)
    }
}
