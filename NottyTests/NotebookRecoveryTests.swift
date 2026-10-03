import Foundation
import NottyCore
import PencilKit
import UIKit
import XCTest
@testable import Notty

@MainActor
final class NotebookRecoveryTests: XCTestCase {
    func testNativeArchiveStoreLoadDecodePreservesEveryOrderedEditIdentityAndStamp() async throws {
        let root = NotebookTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotebookRecoveryStore(rootURL: root)
        let notebookID = UUID()
        let revisionID = UUID()
        let first = NotebookTestFixtures.stroke()
        let second = NotebookTestFixtures.stroke(x: 120)
        var moved = second
        moved.transform = CGAffineTransform(translationX: 20, y: 30)
        var masked = first
        masked.mask = UIBezierPath(rect: CGRect(x: 20, y: 30, width: 15, height: 25))
        let drawings = [
            PKDrawing(strokes: [first, second]),
            PKDrawing(strokes: [masked, moved]),
            PKDrawing(strokes: [masked])
        ]
        let edits = drawings.enumerated().map { index, drawing in
            NotebookPendingEdit(
                snapshot: NotebookDrawingSnapshot(drawing: drawing, pageCount: 3, title: "Notes"),
                stamp: NotebookTestFixtures.stamp(index + 1)
            )
        }
        let codec = NotebookRecoveryCodec()
        let batch = try await codec.encode(
            notebookID: notebookID, baseRevisionID: revisionID, edits: edits
        )
        let receipt = try await store.preserve(batch)
        let loaded = try await store.load(id: receipt.id)
        XCTAssertEqual(loaded, batch)
        XCTAssertEqual(loaded.edits.map(\.id), edits.map(\.id))
        XCTAssertEqual(loaded.edits.map(\.stamp), edits.map(\.stamp))
        XCTAssertEqual(loaded.baseRevisionID, revisionID)
        for (edit, original) in zip(loaded.edits, drawings) {
            let decoded = try await codec.decode(edit)
            XCTAssertEqual(decoded.strokes.map(\.id), original.strokes.map(\.id))
            XCTAssertEqual(decoded.strokes.map(\.transform), original.strokes.map(\.transform))
            XCTAssertEqual(decoded.strokes.map { $0.path.creationDate }, original.strokes.map { $0.path.creationDate })
            XCTAssertEqual(decoded.strokes.map { $0.mask?.cgPath }, original.strokes.map { $0.mask?.cgPath })
        }
        let listed = try await store.list(notebookID: notebookID)
        XCTAssertEqual(listed, [receipt])
    }

    func testActualNormalSaveCountLimitCanStillPreserveAndInspectFullNativeRecovery() async throws {
        let root = NotebookTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = NotebookSession(
            notebookID: UUID(),
            libraryRoot: root.appendingPathComponent("Library", isDirectory: true),
            recoveryRoot: root.appendingPathComponent("Recovery", isDirectory: true)
        )
        await session.load()
        await session.waitUntilSettled()
        XCTAssertEqual(session.loadState, .ready)
        XCTAssertTrue(session.canEdit)
        let template = NotebookTestFixtures.stroke()
        let strokes = (0...InkCodec.maximumStrokeCount).map { _ in
            var copy = template
            copy.id = UUID()
            return copy
        }
        let drawing = PKDrawing(strokes: strokes)
        XCTAssertEqual(drawing.strokes.count, 10_001)
        let seed = session.makeCanvasSeed()
        session.recordCompletedEdit(drawing, ownerID: seed.ownerID)
        await session.waitUntilSettled()
        XCTAssertEqual(session.saveState, .failed(.contentLimit))
        let pending = session.pendingEdits
        XCTAssertEqual(pending.count, 1)
        await session.saveRecoveryCopy()
        XCTAssertNil(session.recoveryFailure)
        XCTAssertTrue(session.canReopenSaved)
        XCTAssertEqual(session.pendingEdits, pending)
        await session.refreshRecoveryCopies()
        let receipt = try XCTUnwrap(session.recoveryCopies.first)
        let batch = try await session.openRecoveryCopy(id: receipt.id)
        XCTAssertEqual(batch.edits[0].id, pending[0].id)
        XCTAssertEqual(batch.edits[0].stamp, pending[0].stamp)
        let restored = try await NotebookRecoveryCodec().decode(batch.edits[0])
        XCTAssertEqual(restored.strokes.map(\.id), drawing.strokes.map(\.id))
    }

    func testRecoveryCountLimitDoesNotCreateAnAcknowledgedCopy() async throws {
        let codec = NotebookRecoveryCodec()
        let template = NotebookTestFixtures.stroke()
        let strokes = (0...NotebookRecoveryCodec.maximumStrokeCount).map { _ in
            var copy = template
            copy.id = UUID()
            return copy
        }
        let edit = NotebookPendingEdit(
            snapshot: NotebookDrawingSnapshot(drawing: PKDrawing(strokes: strokes), pageCount: 3, title: "Notes"),
            stamp: NotebookTestFixtures.stamp(1)
        )
        do {
            _ = try await codec.encode(notebookID: UUID(), baseRevisionID: nil, edits: [edit])
            XCTFail("Recovery limits must reject excess strokes.")
        } catch NotebookSaveFailure.contentLimit {}
    }

    func testPreservedCopyRemainsAccessibleAfterRestartWithUnsafeLibraryRoot() async throws {
        let root = NotebookTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let libraryRoot = root.appendingPathComponent("Library")
        let marker = Data("existing damaged library".utf8)
        try marker.write(to: libraryRoot)
        let recoveryRoot = root.appendingPathComponent("Recovery", isDirectory: true)
        let notebookID = UUID()
        let drawing = PKDrawing(strokes: [NotebookTestFixtures.stroke()])
        let edit = NotebookPendingEdit(
            snapshot: NotebookDrawingSnapshot(drawing: drawing, pageCount: 3, title: "Notes"),
            stamp: NotebookTestFixtures.stamp(1)
        )
        let batch = try await NotebookRecoveryCodec().encode(
            notebookID: notebookID, baseRevisionID: UUID(), edits: [edit]
        )
        let store = try NotebookRecoveryStore(rootURL: recoveryRoot)
        let receipt = try await store.preserve(batch)

        let restarted = NotebookSession(
            notebookID: notebookID, libraryRoot: libraryRoot, recoveryRoot: recoveryRoot
        )
        await restarted.load()
        if case .failed = restarted.loadState {} else {
            XCTFail("An unusable library root must fail closed.")
        }
        XCTAssertFalse(restarted.canEdit)
        XCTAssertTrue(restarted.pendingEdits.isEmpty)
        await restarted.refreshRecoveryCopies()
        XCTAssertNil(restarted.recoveryListFailure)
        XCTAssertEqual(restarted.recoveryCopies, [receipt])
        let reopened = try await restarted.openRecoveryCopy(id: receipt.id)
        XCTAssertEqual(reopened, batch)
        let decoded = try await NotebookRecoveryCodec().decode(reopened.edits[0])
        XCTAssertEqual(decoded.strokes.map(\.id), drawing.strokes.map(\.id))
        XCTAssertEqual(reopened.edits[0].stamp, edit.stamp)
        XCTAssertFalse(restarted.canReopenSaved)
        XCTAssertTrue(restarted.pendingEdits.isEmpty)
        XCTAssertEqual(try Data(contentsOf: libraryRoot), marker)
    }

}
