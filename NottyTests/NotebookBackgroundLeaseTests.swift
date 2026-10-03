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

}
