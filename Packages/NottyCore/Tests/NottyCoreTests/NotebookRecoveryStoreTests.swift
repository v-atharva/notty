import CryptoKit
import Foundation
import PencilKit
import XCTest
@testable import NottyCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class NotebookRecoveryStoreTests: XCTestCase {
    func testFullBatchRoundtripPreservesEveryOrderedEditAndOriginalStamp() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstStroke = stroke()
        var moved = firstStroke
        moved.transform = CGAffineTransform(translationX: 40, y: 60)
        let authoritativeID = UUID()
        let edits = [
            edit(
                drawing: PKDrawing(strokes: [firstStroke]),
                ids: [authoritativeID], title: "Before", pages: 3, uptime: 10
            ),
            edit(
                drawing: PKDrawing(strokes: [moved]),
                ids: [authoritativeID], title: "Moved", pages: 14, uptime: 11
            ),
            edit(drawing: PKDrawing(), title: "Erased", pages: 14, uptime: 12)
        ]
        let batch = NotebookRecoveryBatch(
            notebookID: UUID(), baseRevisionID: UUID(), edits: edits
        )
        let writer = try NotebookRecoveryStore(rootURL: root)
        let receipt = try await writer.preserve(batch)
        let reader = try NotebookRecoveryStore(rootURL: root)
        let reopened = try await reader.load(id: receipt.id)
        let listed = try await reader.list(notebookID: batch.notebookID)

        XCTAssertEqual(reopened, batch)
        XCTAssertEqual(receipt.notebookID, batch.notebookID)
        XCTAssertEqual(receipt.editCount, 3)
        XCTAssertEqual(listed, [receipt])
        let first = try PKDrawing(data: reopened.edits[0].drawingData)
        let second = try PKDrawing(data: reopened.edits[1].drawingData)
        XCTAssertEqual(first.strokes.count, 1)
        XCTAssertEqual(second.strokes[0].transform, moved.transform)
        XCTAssertEqual(reopened.edits[0].strokeIDs, [authoritativeID])
        XCTAssertTrue(try PKDrawing(data: reopened.edits[2].drawingData).strokes.isEmpty)
    }

    func testRecoveryCanPreserveARealArchiveAboveTheNormalStrokeLimit() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let template = stroke()
        let strokes = (0...InkCodec.maximumStrokeCount).map { _ in
            var copy = template
            copy.id = UUID()
            return copy
        }
        let drawing = PKDrawing(strokes: strokes)
        XCTAssertGreaterThan(drawing.strokes.count, InkCodec.maximumStrokeCount)
        let batch = NotebookRecoveryBatch(
            notebookID: UUID(), baseRevisionID: nil, edits: [edit(drawing: drawing)]
        )
        let store = try NotebookRecoveryStore(rootURL: root)
        let receipt = try await store.preserve(batch)
        let loaded = try await store.load(id: receipt.id)

        XCTAssertEqual(loaded, batch)
        XCTAssertEqual(
            try PKDrawing(data: loaded.edits[0].drawingData).strokes.count,
            drawing.strokes.count
        )
    }

    func testEachPublicationFaultRetainsOlderCopiesAndRemovesOwnedTransaction() async throws {
        for target in NotebookRecoveryWriteStage.allCases {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let batch = sampleBatch()
            let healthy = try NotebookRecoveryStore(rootURL: root)
            let original = try await healthy.preserve(batch)
            let before = try snapshot(root: root)
            let faulty = try NotebookRecoveryStore(rootURL: root) { stage in
                if stage == target { throw InjectedFailure.stop }
            }
            do {
                _ = try await faulty.preserve(sampleBatch(notebookID: batch.notebookID))
                XCTFail("Recovery fault \(target) did not stop publication.")
            } catch {
                XCTAssertTrue(error is InjectedFailure)
            }
            XCTAssertEqual(try snapshot(root: root), before)
            let listed = try await healthy.list(notebookID: batch.notebookID)
            XCTAssertEqual(listed, [original])
            let reopened = try await healthy.load(id: original.id)
            XCTAssertEqual(reopened, batch)
            let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
            XCTAssertFalse(entries.contains { $0.hasPrefix(".recovery-") })
        }
    }

    func testReopenRemovesPrivateCrashResidueWithoutPublishingIt() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let batch = sampleBatch()
        let store = try NotebookRecoveryStore(rootURL: root)
        let receipt = try await store.preserve(batch)
        let original = bundle(root: root, id: receipt.id)
        let before = try snapshot(root: original)
        let transaction = root.appendingPathComponent(
            ".recovery-\(UUID().uuidString.lowercased())", isDirectory: true
        )
        try FileManager.default.copyItem(at: original, to: transaction)
        let unrelated = root.appendingPathComponent(".recovery-unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        let reopened = try NotebookRecoveryStore(rootURL: root)
        let listed = try await reopened.list(notebookID: batch.notebookID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertEqual(listed, [receipt])
        XCTAssertEqual(try snapshot(root: original), before)
    }

    func testPublishedReceiptsAndBatchesRemainImmutableAcrossMoreCopies() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let batch = sampleBatch()
        let store = try NotebookRecoveryStore(rootURL: root)
        let first = try await store.preserve(batch)
        let before = try snapshot(root: bundle(root: root, id: first.id))
        let second = try await store.preserve(batch)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(try snapshot(root: bundle(root: root, id: first.id)), before)
        let firstBatch = try await store.load(id: first.id)
        let secondBatch = try await store.load(id: second.id)
        XCTAssertEqual(firstBatch, batch)
        XCTAssertEqual(secondBatch, batch)
        let listed = try await store.list(notebookID: batch.notebookID)
        XCTAssertEqual(Set(listed.map(\.id)), Set([first.id, second.id]))
        let others = try await store.list(notebookID: UUID())
        XCTAssertTrue(others.isEmpty)
    }

    func testDamagedReceiptManifestAndArchiveFailWithoutModifyingTheBundle() async throws {
        for damaged in ["receipt", "manifest", "archive"] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let batch = sampleBatch()
            let store = try NotebookRecoveryStore(rootURL: root)
            let receipt = try await store.preserve(batch)
            let directory = bundle(root: root, id: receipt.id)
            let target: URL
            switch damaged {
            case "receipt": target = directory.appendingPathComponent("RECEIPT.json")
            case "manifest": target = directory.appendingPathComponent("manifest.json")
            default: target = archive(root: root, receiptID: receipt.id, editID: batch.edits[0].id)
            }
            try Data("damaged".utf8).write(to: target)
            let before = try snapshot(root: directory)
            do {
                _ = try await store.load(id: receipt.id)
                XCTFail("Damaged recovery \(damaged) was accepted.")
            } catch {
                guard case .corruptData? = error as? NotebookRepositoryError else {
                    return XCTFail("Unexpected corruption error: \(error)")
                }
            }
            XCTAssertEqual(try snapshot(root: directory), before)
        }
    }

    func testMissingArchivesFailOnLoadAndListRatherThanBecomingEmptyDrawings() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let batch = sampleBatch()
        let store = try NotebookRecoveryStore(rootURL: root)
        let receipt = try await store.preserve(batch)
        try FileManager.default.removeItem(
            at: archive(root: root, receiptID: receipt.id, editID: batch.edits[0].id)
        )
        do {
            _ = try await store.load(id: receipt.id)
            XCTFail("A missing archive became an empty state.")
        } catch {
            guard case .corruptData? = error as? NotebookRepositoryError else {
                return XCTFail("Unexpected archive error: \(error)")
            }
        }
        do {
            _ = try await store.list(notebookID: batch.notebookID)
            XCTFail("A damaged recovery copy was presented as validated.")
        } catch {
            guard case .corruptData? = error as? NotebookRepositoryError else {
                return XCTFail("Unexpected listing error: \(error)")
            }
        }
    }

    func testNativeArchiveAndManifestStrokeCountMustMatch() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotebookRecoveryStore(rootURL: root)
        let malformed = edit(drawing: PKDrawing(strokes: [stroke()]), ids: [UUID(), UUID()])
        do {
            _ = try await store.preserve(NotebookRecoveryBatch(
                notebookID: UUID(), baseRevisionID: nil, edits: [malformed]
            ))
            XCTFail("An archive-count mismatch was preserved.")
        } catch {
            guard case .invalidContent? = error as? NotebookRepositoryError else {
                return XCTFail("Unexpected native validation error: \(error)")
            }
        }
        let batch = sampleBatch()
        let receipt = try await store.preserve(batch)
        try modifyManifest(root: root, receipt: receipt.id) { manifest in
            var edits = manifest["edits"] as! [[String: Any]]
            edits[0]["strokeIDs"] = [UUID().uuidString, UUID().uuidString]
            manifest["edits"] = edits
        }
        do {
            _ = try await store.load(id: receipt.id)
            XCTFail("A stored archive-count mismatch was accepted.")
        } catch {
            guard case .corruptData? = error as? NotebookRepositoryError else {
                return XCTFail("Unexpected stored native error: \(error)")
            }
        }
    }

    func testUnsupportedSchemasAndMismatchedIdentityAreRejected() async throws {
        for change in ["receiptVersion", "manifestVersion", "identity", "duplicateEdit", "badDigest"] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try NotebookRecoveryStore(rootURL: root)
            let receipt = try await store.preserve(sampleBatch())
            if change == "receiptVersion" {
                let url = bundle(root: root, id: receipt.id).appendingPathComponent("RECEIPT.json")
                var object = try object(at: url)
                object["schemaVersion"] = 99
                try write(object, to: url)
            } else {
                try modifyManifest(root: root, receipt: receipt.id) { manifest in
                    switch change {
                    case "manifestVersion": manifest["schemaVersion"] = 99
                    case "identity": manifest["notebookID"] = UUID().uuidString
                    default:
                        var edits = manifest["edits"] as! [[String: Any]]
                        if change == "duplicateEdit" {
                            edits[1]["id"] = edits[0]["id"]
                        } else {
                            edits[0]["archiveDigest"] = "../../outside"
                        }
                        manifest["edits"] = edits
                    }
                }
            }
            do {
                _ = try await store.load(id: receipt.id)
                XCTFail("Invalid recovery metadata \(change) was accepted.")
            } catch {
                if change.hasSuffix("Version") {
                    XCTAssertEqual(error as? NotebookRepositoryError, .unsupportedVersion(99))
                } else {
                    guard case .corruptData? = error as? NotebookRepositoryError else {
                        return XCTFail("Unexpected metadata error: \(error)")
                    }
                }
            }
        }
    }

    func testRootArchiveAndPrivateTransactionLinksAreRejectedWithoutTouchingTargets() async throws {
        let parent = try makeRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("recovery", isDirectory: true)
        let batch = sampleBatch()
        let store = try NotebookRecoveryStore(rootURL: root)
        let receipt = try await store.preserve(batch)
        let outside = parent.appendingPathComponent("outside")
        try Data("untouched".utf8).write(to: outside)
        let archiveURL = archive(root: root, receiptID: receipt.id, editID: batch.edits[0].id)
        try FileManager.default.removeItem(at: archiveURL)
        try FileManager.default.createSymbolicLink(at: archiveURL, withDestinationURL: outside)
        do {
            _ = try await store.load(id: receipt.id)
            XCTFail("A recovery archive link was followed.")
        } catch {
            guard case .unsafePath? = error as? NotebookRepositoryError else {
                return XCTFail("Unexpected archive link error: \(error)")
            }
        }
        let transaction = root.appendingPathComponent(".recovery-\(UUID().uuidString.lowercased())")
        try FileManager.default.createSymbolicLink(at: transaction, withDestinationURL: outside)
        XCTAssertThrowsError(try NotebookRecoveryStore(rootURL: root)) {
            guard case .unsafePath? = $0 as? NotebookRepositoryError else {
                return XCTFail("Unexpected transaction link error: \($0)")
            }
        }
        let rootLink = parent.appendingPathComponent("root-link")
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: root)
        XCTAssertThrowsError(try NotebookRecoveryStore(rootURL: rootLink))
        XCTAssertEqual(try Data(contentsOf: outside), Data("untouched".utf8))
    }

    func testReplacingTheRootAfterInitializationRejectsAllOperations() async throws {
        let root = try makeRoot().resolvingSymlinksInPath()
        let alternate = try makeRoot().resolvingSymlinksInPath()
        let moved = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: moved)
            try? FileManager.default.removeItem(at: alternate)
        }
        let batch = sampleBatch()
        let store = try NotebookRecoveryStore(rootURL: root)
        let receipt = try await store.preserve(batch)
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: alternate)
        let before = try snapshot(root: moved)
        do {
            _ = try await store.preserve(batch)
            XCTFail("A replaced recovery root allowed preservation.")
        } catch {
            guard case .unsafePath? = error as? NotebookRepositoryError else {
                return XCTFail("Unexpected replacement error: \(error)")
            }
        }
        do {
            _ = try await store.load(id: receipt.id)
            XCTFail("A replaced recovery root allowed loading.")
        } catch {
            guard case .unsafePath? = error as? NotebookRepositoryError else {
                return XCTFail("Unexpected replacement error: \(error)")
            }
        }
        do {
            _ = try await store.list(notebookID: batch.notebookID)
            XCTFail("A replaced recovery root allowed listing.")
        } catch {
            guard case .unsafePath? = error as? NotebookRepositoryError else {
                return XCTFail("Unexpected replacement error: \(error)")
            }
        }
        XCTAssertEqual(try snapshot(root: moved), before)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: alternate.path).isEmpty)
    }

    func testInvalidCountsIdentitiesPagesAndTimestampsFailBeforePublication() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotebookRecoveryStore(rootURL: root)
        let valid = edit(drawing: PKDrawing(strokes: [stroke()]))
        let invalidTimes = NotebookRecoveryEdit(
            id: UUID(), drawingData: valid.drawingData, strokeIDs: valid.strokeIDs,
            title: "Invalid", pageCount: 1,
            stamp: NotebookEditStamp(capturedAt: Date(), uptime: -1, sessionID: UUID())
        )
        let invalidPages = NotebookRecoveryEdit(
            id: UUID(), drawingData: valid.drawingData, strokeIDs: valid.strokeIDs,
            title: "Invalid", pageCount: 0, stamp: valid.stamp
        )
        let duplicateIDs = NotebookRecoveryEdit(
            id: UUID(), drawingData: valid.drawingData,
            strokeIDs: [valid.strokeIDs[0], valid.strokeIDs[0]],
            title: "Invalid", pageCount: 1, stamp: valid.stamp
        )
        let oversizedIDs = NotebookRecoveryEdit(
            id: UUID(), drawingData: valid.drawingData,
            strokeIDs: (0...NotebookRecoveryStore.maximumStrokeIDs).map { _ in UUID() },
            title: "Invalid", pageCount: 1, stamp: valid.stamp
        )
        let invalid = [
            [], [valid, valid], [invalidTimes], [invalidPages], [duplicateIDs], [oversizedIDs],
            (0...NotebookRecoveryStore.maximumEditCount).map { _ in edit(drawing: PKDrawing()) }
        ]
        for edits in invalid {
            do {
                _ = try await store.preserve(NotebookRecoveryBatch(
                    notebookID: UUID(), baseRevisionID: nil, edits: edits
                ))
                XCTFail("Invalid recovery content was published.")
            } catch {
                XCTAssertNotNil(error as? NotebookRepositoryError)
            }
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(entries, [".writer.lock"])
    }

    func testIndependentArchiveAndAggregateBoundsRejectBeforeNativeDecode() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotebookRecoveryStore(rootURL: root)
        let oversized = Data(repeating: 0, count: NotebookRecoveryStore.maximumArchiveBytes + 1)
        let shared = Data(repeating: 0, count: NotebookRecoveryStore.maximumArchiveBytes)
        let stamp = NotebookEditStamp(capturedAt: Date(), uptime: 1, sessionID: UUID())
        let cases = [
            [NotebookRecoveryEdit(
                id: UUID(), drawingData: oversized, strokeIDs: [],
                title: "Oversized", pageCount: 1, stamp: stamp
            )],
            (0..<5).map { _ in
                NotebookRecoveryEdit(
                    id: UUID(), drawingData: shared, strokeIDs: [],
                    title: "Aggregate", pageCount: 1, stamp: stamp
                )
            }
        ]
        for edits in cases {
            do {
                _ = try await store.preserve(NotebookRecoveryBatch(
                    notebookID: UUID(), baseRevisionID: nil, edits: edits
                ))
                XCTFail("Oversized recovery data reached native decoding.")
            } catch {
                guard case .sizeLimitExceeded? = error as? NotebookRepositoryError else {
                    return XCTFail("Unexpected size error: \(error)")
                }
            }
        }
    }

    func testMetadataBudgetRejectsBeforeDecodingADeclaredLargeDrawing() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotebookRecoveryStore(rootURL: root)
        let edits = (0..<3).map { _ in
            edit(
                drawing: PKDrawing(),
                ids: (0..<NotebookRecoveryStore.maximumStrokeIDs).map { _ in UUID() }
            )
        }
        do {
            _ = try await store.preserve(NotebookRecoveryBatch(
                notebookID: UUID(), baseRevisionID: nil, edits: edits
            ))
            XCTFail("Oversized metadata was published.")
        } catch {
            guard case .sizeLimitExceeded? = error as? NotebookRepositoryError else {
                return XCTFail("Unexpected manifest-bound error: \(error)")
            }
        }
    }

    func testRecoveryRemainsUsableWhenTheSeparateLibraryRootIsUnsafe() async throws {
        let parent = try makeRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let library = parent.appendingPathComponent("NottyLibrary")
        try FileManager.default.createSymbolicLink(at: library, withDestinationURL: outside)
        XCTAssertThrowsError(try NotebookRepository(rootURL: library))
        let store = try NotebookRecoveryStore(
            rootURL: parent.appendingPathComponent("NottyRecovery", isDirectory: true)
        )
        let batch = sampleBatch()
        let receipt = try await store.preserve(batch)
        let loaded = try await store.load(id: receipt.id)

        XCTAssertEqual(loaded, batch)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    private enum InjectedFailure: Error {
        case stop
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func sampleBatch(notebookID: UUID = UUID()) -> NotebookRecoveryBatch {
        let first = stroke()
        var moved = first
        moved.transform = CGAffineTransform(translationX: 10, y: 20)
        return NotebookRecoveryBatch(
            notebookID: notebookID, baseRevisionID: UUID(),
            edits: [
                edit(drawing: PKDrawing(strokes: [first]), uptime: 1),
                edit(drawing: PKDrawing(strokes: [moved]), uptime: 2),
                edit(drawing: PKDrawing(), uptime: 3)
            ]
        )
    }

    private func edit(
        drawing: PKDrawing,
        ids: [UUID]? = nil,
        title: String = "Recovered",
        pages: Int = 3,
        uptime: TimeInterval = 1
    ) -> NotebookRecoveryEdit {
        NotebookRecoveryEdit(
            id: UUID(),
            drawingData: drawing.dataRepresentation(),
            strokeIDs: ids ?? drawing.strokes.map(\.id),
            title: title,
            pageCount: pages,
            stamp: NotebookEditStamp(
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + uptime),
                uptime: uptime, sessionID: UUID()
            )
        )
    }

    private func stroke() -> PKStroke {
        #if canImport(UIKit)
        let color = UIColor.black
        #else
        let color = NSColor.black
        #endif
        let points = (0..<4).map { index in
            PKStrokePoint(
                location: CGPoint(x: CGFloat(index) * 10, y: 40),
                timeOffset: Double(index) * 0.02,
                size: CGSize(width: 3, height: 3),
                opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
            )
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1_000))
        return PKStroke(ink: PKInk(.pen, color: color), path: path)
    }

    private func bundle(root: URL, id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    private func archive(root: URL, receiptID: UUID, editID: UUID) -> URL {
        bundle(root: root, id: receiptID).appendingPathComponent(
            "archives/\(editID.uuidString.lowercased()).drawing"
        )
    }

    private func snapshot(root: URL) throws -> [String: Data] {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        )
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            result[String(url.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: url)
        }
        return result
    }

    private func object(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }

    private func modifyManifest(
        root: URL, receipt: UUID, mutation: (inout [String: Any]) -> Void
    ) throws {
        let directory = bundle(root: root, id: receipt)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        var manifest = try object(at: manifestURL)
        mutation(&manifest)
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try data.write(to: manifestURL)
        let receiptURL = directory.appendingPathComponent("RECEIPT.json")
        var record = try object(at: receiptURL)
        record["manifestDigest"] = SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
        try write(record, to: receiptURL)
    }
}
