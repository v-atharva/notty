import Darwin
import Foundation
import PencilKit
import XCTest
@testable import NottyCore

@MainActor
final class NotebookRecoveryScanIsolationTests: XCTestCase {
    func testForeignReceiptsAreFilteredBeforeDamagedManifestsOrAnyArchiveRead() async throws {
        let root = try RecoveryStateFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try NotebookRecoveryStore(rootURL: root)
        var receiptBytes = 0
        for _ in 0..<2 {
            let batch = try await makeBatch(notebookID: UUID())
            let receipt = try await writer.preserveStates(batch)
            let directory = bundle(root, receipt.id)
            receiptBytes += try Data(contentsOf: directory.appendingPathComponent("RECEIPT.json")).count
            try Data([0]).write(to: directory.appendingPathComponent("manifest.json"))
            try FileManager.default.removeItem(at: directory.appendingPathComponent("assets"))
            try FileManager.default.removeItem(at: directory.appendingPathComponent("references"))
        }
        let observations = RecoveryStateFixtures.AssetObservations()
        let reader = try NotebookRecoveryStore(rootURL: root, assetVerificationObserver: { observations.record($0) })
        let scan = try await reader.scan(notebookID: UUID())
        let work = await reader.workMetrics()
        XCTAssertTrue(scan.copies.isEmpty)
        XCTAssertTrue(scan.unavailableCopyIDs.isEmpty)
        XCTAssertTrue(scan.matchingIssues.isEmpty)
        XCTAssertTrue(scan.unattributedIssues.isEmpty)
        XCTAssertEqual(work.assetReadCalls, 0)
        XCTAssertEqual(work.assetReadBytes, 0)
        XCTAssertEqual(work.assetHashCalls, 0)
        XCTAssertEqual(work.nativeArchiveValidations, 0)
        XCTAssertEqual(work.nativeStateValidations, 0)
        XCTAssertEqual(work.metadataReadCalls, 2)
        XCTAssertEqual(work.metadataReadBytes, receiptBytes)
        XCTAssertTrue(observations.snapshot().isEmpty)
        let beforeList = await reader.workMetrics()
        let list = try await reader.list(notebookID: UUID())
        let afterList = await reader.workMetrics()
        XCTAssertTrue(list.isEmpty)
        XCTAssertEqual(afterList.assetReadCalls, beforeList.assetReadCalls)
        XCTAssertEqual(afterList.metadataReadCalls - beforeList.metadataReadCalls, 2)
        XCTAssertEqual(afterList.metadataReadBytes - beforeList.metadataReadBytes, receiptBytes)
    }

    func testMatchingDamageDoesNotHideAHealthyMatchingCopyOrBlameForeignCopies() async throws {
        let root = try RecoveryStateFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let notebookID = UUID()
        let store = try NotebookRecoveryStore(rootURL: root)
        let healthyBatch = try await makeBatch(notebookID: notebookID)
        let damagedBatch = try await makeBatch(notebookID: notebookID)
        let foreignBatch = try await makeBatch(notebookID: UUID())
        let healthy = try await store.preserveStates(healthyBatch)
        let damaged = try await store.preserveStates(damagedBatch)
        let foreign = try await store.preserveStates(foreignBatch)
        for receipt in [damaged, foreign] {
            try Data([0]).write(to: bundle(root, receipt.id).appendingPathComponent("manifest.json"))
        }
        let reader = try NotebookRecoveryStore(rootURL: root)
        let scan = try await reader.scan(notebookID: notebookID)
        XCTAssertEqual(scan.copies, [healthy])
        XCTAssertEqual(scan.unavailableCopyIDs, [damaged.id])
        XCTAssertEqual(scan.matchingIssues, [NotebookRecoveryScanIssue(copyID: damaged.id, kind: .damagedData)])
        XCTAssertTrue(scan.unattributedIssues.isEmpty)
        let work = await reader.workMetrics()
        XCTAssertEqual(work.assetReadCalls, 1)
        XCTAssertEqual(work.nativeArchiveValidations, 1)
        XCTAssertEqual(work.nativeStateValidations, 1)
        XCTAssertFalse(scan.unavailableCopyIDs.contains(foreign.id))
    }

    func testUnsupportedAndUnsafeReceiptsRemainUnattributed() async throws {
        let root = try RecoveryStateFixtures.makeRoot()
        let outside = try RecoveryStateFixtures.makeRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let store = try NotebookRecoveryStore(rootURL: root)
        let notebookID = UUID()
        let batch = try await makeBatch(notebookID: notebookID)
        let unsupported = try await store.preserveStates(batch)
        let unsafe = try await store.preserveStates(batch)
        let unsupportedURL = bundle(root, unsupported.id).appendingPathComponent("RECEIPT.json")
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: unsupportedURL)) as? [String: Any])
        record["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: unsupportedURL)
        let unsafeURL = bundle(root, unsafe.id).appendingPathComponent("RECEIPT.json")
        let retained = try Data(contentsOf: unsafeURL)
        let target = outside.appendingPathComponent("retained-receipt.json")
        try retained.write(to: target)
        try FileManager.default.removeItem(at: unsafeURL)
        try FileManager.default.createSymbolicLink(at: unsafeURL, withDestinationURL: target)
        let reader = try NotebookRecoveryStore(rootURL: root)
        let scan = try await reader.scan(notebookID: notebookID)
        XCTAssertTrue(scan.copies.isEmpty)
        XCTAssertTrue(scan.unavailableCopyIDs.isEmpty)
        XCTAssertTrue(scan.matchingIssues.isEmpty)
        XCTAssertEqual(scan.unattributedIssues.sorted { $0.copyID.uuidString < $1.copyID.uuidString }, [
            NotebookRecoveryScanIssue(copyID: unsupported.id, kind: .unsupportedVersion(99)),
            NotebookRecoveryScanIssue(copyID: unsafe.id, kind: .unsafePath)
        ].sorted { $0.copyID.uuidString < $1.copyID.uuidString })
        XCTAssertEqual(try Data(contentsOf: target), retained)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: unsafeURL.path), target.path)
        let work = await reader.workMetrics()
        XCTAssertEqual(work.assetReadCalls, 0)
        XCTAssertEqual(work.nativeArchiveValidations, 0)
    }

    func testAttributableArchiveIOFailureIsSeparateFromDamagedData() async throws {
        let root = try RecoveryStateFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let notebookID = UUID()
        let batch = try await makeBatch(notebookID: notebookID)
        let store = try NotebookRecoveryStore(rootURL: root)
        let receipt = try await store.preserveStates(batch)
        let asset = batch.edits[0].strokes[0]
        let path = bundle(root, receipt.id).appendingPathComponent("assets")
            .appendingPathComponent(try XCTUnwrap(asset.cachedDigest) + ".stroke")
        XCTAssertEqual(chmod(path.path, 0), 0)
        defer { _ = chmod(path.path, 0o600) }
        let reader = try NotebookRecoveryStore(rootURL: root)
        let scan = try await reader.scan(notebookID: notebookID)
        XCTAssertTrue(scan.copies.isEmpty)
        XCTAssertTrue(scan.unavailableCopyIDs.isEmpty)
        XCTAssertTrue(scan.unattributedIssues.isEmpty)
        XCTAssertEqual(scan.matchingIssues, [
            NotebookRecoveryScanIssue(copyID: receipt.id, kind: .ioFailure(EACCES))
        ])
        let work = await reader.workMetrics()
        XCTAssertEqual(work.assetReadCalls, 1)
        XCTAssertEqual(work.assetReadBytes, 0)
        XCTAssertEqual(work.assetHashCalls, 0)
        XCTAssertEqual(chmod(path.path, 0o600), 0)
        let loaded = try await reader.loadStates(id: receipt.id)
        XCTAssertEqual(loaded, batch)
    }

    func testLegacyPositiveExtentRemainsByteExactAndInspectableWhenStateConversionCannotFit() async throws {
        let root = try RecoveryStateFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let drawing = PKDrawing(strokes: [RecoveryStateFixtures.stroke()])
        let edit = NotebookRecoveryEdit(
            id: UUID(), drawingData: drawing.dataRepresentation(), strokeIDs: drawing.strokes.map(\.id),
            title: "Legacy extent", pageCount: 14, stamp: RecoveryStateFixtures.stamp(0)
        )
        let batch = NotebookRecoveryBatch(notebookID: UUID(), baseRevisionID: UUID(), edits: [edit])
        let store = try NotebookRecoveryStore(rootURL: root)
        let receipt = try await store.preserve(batch)
        let directory = bundle(root, receipt.id)
        let before = try RecoveryStateFixtures.fileSnapshot(in: directory)
        let reader = try NotebookRecoveryStore(rootURL: root)
        let loaded = try await reader.load(id: receipt.id)
        XCTAssertEqual(loaded, batch)
        let metadata = try await reader.inspect(id: receipt.id)
        XCTAssertEqual(metadata.edits[0].pageCount, 14)
        XCTAssertEqual(metadata.edits[0].id, edit.id)
        XCTAssertEqual(metadata.edits[0].stamp, edit.stamp)
        let scan = try await reader.scan(notebookID: batch.notebookID)
        XCTAssertEqual(scan.copies, [receipt])
        XCTAssertTrue(scan.matchingIssues.isEmpty)
        XCTAssertTrue(scan.unavailableCopyIDs.isEmpty)
        for selected in [false, true] {
            do {
                if selected {
                    _ = try await reader.loadEdit(id: receipt.id, editID: edit.id)
                } else {
                    _ = try await reader.loadStates(id: receipt.id)
                }
                XCTFail("An old valid copy outside new state bounds must remain preserved without returning an unsupported state.")
            } catch NotebookRepositoryError.sizeLimitExceeded {}
        }
        XCTAssertEqual(try RecoveryStateFixtures.fileSnapshot(in: directory), before)
    }

    private func makeBatch(notebookID: UUID) async throws -> NotebookRecoveryStrokeBatch {
        let strokes = try await InkCodec(profile: .recovery).encode(
            PKDrawing(strokes: [RecoveryStateFixtures.stroke()])
        )
        return NotebookRecoveryStrokeBatch(
            notebookID: notebookID, edits: [RecoveryStateFixtures.edit(strokes: strokes, index: 0)]
        )
    }

    private func bundle(_ root: URL, _ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }
}
