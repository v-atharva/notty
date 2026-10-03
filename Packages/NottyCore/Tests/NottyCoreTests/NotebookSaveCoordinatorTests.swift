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
