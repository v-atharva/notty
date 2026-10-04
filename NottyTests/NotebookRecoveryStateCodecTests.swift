import CryptoKit
import Foundation
import NottyCore
import PencilKit
import UIKit
import XCTest
@testable import Notty

@MainActor
final class NotebookRecoveryStateCodecTests: XCTestCase {
    func testPairedStatesRetainOriginalEditsAndReuseUnchangedOwnedArchives() async throws {
        let notebookID = UUID()
        let baseID = UUID()
        let first = NotebookTestFixtures.stroke()
        let second = NotebookTestFixtures.stroke(x: 120)
        var moved = second
        moved.transform = CGAffineTransform(translationX: 25, y: 30)
        let source = NotebookRecoveryProvenance(
            notebookID: notebookID, copyID: UUID(), editID: UUID(),
            originalStamp: NotebookTestFixtures.stamp(20), baseRevisionID: UUID()
        )
        let edits = [
            pending(PKDrawing(strokes: [first, second]), index: 1, source: source),
            pending(PKDrawing(strokes: [first, moved]), index: 2),
            pending(PKDrawing(strokes: [moved]), index: 3)
        ]
        let codec = NotebookRecoveryCodec()
        let encoded = try await codec.encodeStates(
            notebookID: notebookID, baseRevisionID: baseID, edits: edits
        )
        let batch = encoded.strokeBatch
        XCTAssertEqual(batch.notebookID, notebookID)
        XCTAssertEqual(batch.baseRevisionID, baseID)
        XCTAssertEqual(batch.edits.map(\.id), edits.map(\.id))
        XCTAssertEqual(batch.edits.map(\.stamp), edits.map(\.stamp))
        XCTAssertEqual(batch.edits.map(\.title), edits.map { $0.snapshot.title })
        XCTAssertEqual(batch.edits.map(\.pageCount), edits.map { $0.snapshot.pageCount })
        XCTAssertEqual(batch.edits.map(\.recoverySource), [source, nil, nil])
        XCTAssertEqual(batch.edits[0].strokes.map(\.id), [first.id, second.id])
        XCTAssertEqual(batch.edits[1].strokes.map(\.id), [first.id, second.id])
        XCTAssertEqual(batch.edits[2].strokes.map(\.id), [second.id])
        XCTAssertEqual(batch.edits[0].strokes[0].data, batch.edits[1].strokes[0].data)
        XCTAssertEqual(batch.edits[1].strokes[1].data, batch.edits[2].strokes[0].data)
        XCTAssertEqual(encoded.fingerprint, try NotebookRecoveryStateFingerprint(validating: batch))
        XCTAssertEqual(encoded.fingerprint.workMetrics.assetHashCalls, 0)
        XCTAssertEqual(encoded.fingerprint.workMetrics.assetCopiedBytes, 0)
        let work = await codec.stateWorkMetrics()
        XCTAssertEqual(work.serializedStrokes, 3)
        XCTAssertGreaterThan(work.hashedArchiveBytes, 0)
    }

    func testStateAndLegacyMetadataPreflightKeepInvalidContentSeparateFromLimits() async throws {
        let valid = pending(PKDrawing(strokes: [NotebookTestFixtures.stroke()]), index: 1)
        let notebookID = UUID()
        let wrongSource = NotebookRecoveryProvenance(
            notebookID: UUID(), copyID: UUID(), editID: UUID(),
            originalStamp: NotebookTestFixtures.stamp(2)
        )
        let snapshots: [(NotebookDrawingSnapshot, NotebookSaveFailure)] = [
            (NotebookDrawingSnapshot(drawing: valid.snapshot.drawing, pageCount: 0, title: "Invalid"), .invalidContent),
            (NotebookDrawingSnapshot(drawing: valid.snapshot.drawing, pageCount: 13, title: "Invalid"), .invalidContent),
            (NotebookDrawingSnapshot(drawing: valid.snapshot.drawing, pageCount: 1, title: String(repeating: "t", count: 4_097)), .contentLimit),
            (NotebookDrawingSnapshot(drawing: valid.snapshot.drawing, pageCount: 1, title: "Invalid", recoverySource: wrongSource), .invalidContent)
        ]
        var cases: [([NotebookPendingEdit<NotebookDrawingSnapshot>], NotebookSaveFailure)] =
            snapshots.map { ([NotebookPendingEdit(snapshot: $0.0, stamp: valid.stamp)], $0.1) }
        cases.append(([], .invalidContent))
        cases.append(([valid, valid], .invalidContent))
        cases.append(((0..<33).map { _ in
            NotebookPendingEdit(snapshot: valid.snapshot, stamp: valid.stamp)
        }, .contentLimit))
        for uptime in [-1.0, Double.infinity, Double.nan] {
            cases.append(([NotebookPendingEdit(
                snapshot: valid.snapshot,
                stamp: NotebookEditStamp(capturedAt: Date(), uptime: uptime, sessionID: UUID())
            )], .invalidContent))
        }
        for (edits, expected) in cases {
            for legacy in [false, true] {
                let codec = NotebookRecoveryCodec()
                do {
                    if legacy {
                        _ = try await codec.encode(notebookID: notebookID, baseRevisionID: nil, edits: edits)
                    } else {
                        _ = try await codec.encodeStates(notebookID: notebookID, baseRevisionID: nil, edits: edits)
                    }
                    XCTFail("Invalid metadata must fail before native encoding.")
                } catch {
                    XCTAssertEqual(NotebookSaveFailure.classify(error), expected)
                }
                let work = await codec.stateWorkMetrics()
                let legacyCount = await codec.legacySerializedDrawingCount
                XCTAssertEqual(work.serializedStrokes, 0)
                XCTAssertEqual(work.hashedArchiveBytes, 0)
                XCTAssertEqual(legacyCount, 0)
            }
        }
    }

    func testSnapshotAndLegacyFingerprintRetainSourceWithoutReplacingOriginalArchiveProof() async throws {
        let drawing = PKDrawing(strokes: [NotebookTestFixtures.stroke()])
        let identity = UUID()
        let notebookID = UUID()
        let source = NotebookRecoveryProvenance(
            notebookID: notebookID, copyID: UUID(), editID: UUID(),
            originalStamp: NotebookTestFixtures.stamp(7)
        )
        let ordinary = NotebookDrawingSnapshot(drawing: drawing, pageCount: 2, title: "Notes", identity: identity)
        let recovered = NotebookDrawingSnapshot(
            drawing: drawing, pageCount: 2, title: "Notes", identity: identity, recoverySource: source
        )
        XCTAssertNil(ordinary.recoverySource)
        XCTAssertNotEqual(ordinary, recovered)
        let queued = NotebookPendingEdit(snapshot: recovered, stamp: NotebookTestFixtures.stamp(8))
        let codec = NotebookRecoveryCodec()
        let legacy = try await codec.encode(notebookID: notebookID, baseRevisionID: nil, edits: [queued])
        let fingerprint = await codec.fingerprint(legacy)
        XCTAssertEqual(legacy.edits[0].drawingData, drawing.dataRepresentation())
        XCTAssertEqual(legacy.edits[0].recoverySource, source)
        XCTAssertEqual(fingerprint.edits[0].archiveDigest, Data(SHA256.hash(data: legacy.edits[0].drawingData)))
        XCTAssertEqual(fingerprint.edits[0].recoverySource, source)
        var changed = legacy.edits[0].drawingData
        changed[changed.startIndex] ^= 1
        let altered = NotebookRecoveryBatch(
            notebookID: notebookID, baseRevisionID: nil,
            edits: [NotebookRecoveryEdit(
                id: queued.id, drawingData: changed, strokeIDs: legacy.edits[0].strokeIDs,
                title: recovered.title, pageCount: recovered.pageCount, stamp: queued.stamp,
                recoverySource: source
            )]
        )
        let changedFingerprint = await codec.fingerprint(altered)
        XCTAssertNotEqual(fingerprint, changedFingerprint)
    }

    func testPublishedStatesAndSelectedNativeDecodeRetainEveryHistoricalState() async throws {
        let root = NotebookTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = NotebookTestFixtures.stroke()
        let second = NotebookTestFixtures.stroke(x: 120)
        var moved = second
        moved.transform = CGAffineTransform(translationX: 20, y: 30)
        var masked = first
        masked.mask = UIBezierPath(rect: CGRect(x: 20, y: 30, width: 15, height: 25))
        let drawings = [
            PKDrawing(strokes: [first, second]), PKDrawing(strokes: [masked, moved]),
            PKDrawing(strokes: [masked]), PKDrawing(), PKDrawing(strokes: [first, moved])
        ]
        let edits = drawings.enumerated().map { pending($0.element, index: $0.offset + 1) }
        let codec = NotebookRecoveryCodec()
        let encoded = try await codec.encodeStates(notebookID: UUID(), baseRevisionID: UUID(), edits: edits)
        let store = try NotebookRecoveryStore(rootURL: root)
        let receipt = try await store.preserveStates(encoded.strokeBatch)
        let loaded = try await store.loadStates(id: receipt.id)
        XCTAssertEqual(loaded, encoded.strokeBatch)
        XCTAssertEqual(try NotebookRecoveryStateFingerprint(validating: loaded), encoded.fingerprint)
        for (index, edit) in edits.enumerated() {
            let selected = try await store.loadEdit(id: receipt.id, editID: edit.id)
            XCTAssertEqual(selected.state, loaded.edits[index])
            XCTAssertEqual(selected.source.copyID, receipt.id)
            XCTAssertEqual(selected.source.notebookID, encoded.strokeBatch.notebookID)
            XCTAssertEqual(selected.source.editID, edit.id)
            XCTAssertEqual(selected.source.originalStamp, edit.stamp)
            XCTAssertEqual(selected.source.baseRevisionID, encoded.strokeBatch.baseRevisionID)
            let drawing = try await codec.decodeSelected(selected)
            XCTAssertEqual(drawing.strokes.map(\.id), drawings[index].strokes.map(\.id))
            XCTAssertEqual(drawing.strokes.map(\.transform), drawings[index].strokes.map(\.transform))
            XCTAssertEqual(drawing.strokes.map { $0.path.creationDate }, drawings[index].strokes.map { $0.path.creationDate })
            XCTAssertEqual(drawing.strokes.map { $0.mask?.cgPath }, drawings[index].strokes.map { $0.mask?.cgPath })
        }
    }

    func testSelectedStateIsolatedFromAnUnrelatedDamagedArchive() async throws {
        let root = NotebookTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let edits = [
            pending(PKDrawing(strokes: [NotebookTestFixtures.stroke()]), index: 1),
            pending(PKDrawing(strokes: [NotebookTestFixtures.stroke(x: 240)]), index: 2)
        ]
        let codec = NotebookRecoveryCodec()
        let encoded = try await codec.encodeStates(notebookID: UUID(), baseRevisionID: nil, edits: edits)
        let store = try NotebookRecoveryStore(rootURL: root)
        let receipt = try await store.preserveStates(encoded.strokeBatch)
        let data = encoded.strokeBatch.edits[1].strokes[0].data
        let alphabet = Array("0123456789abcdef".utf8)
        let digest = String(decoding: SHA256.hash(data: data).flatMap {
            [alphabet[Int($0) >> 4], alphabet[Int($0) & 15]]
        }, as: UTF8.self)
        let path = root.appendingPathComponent(receipt.id.uuidString.lowercased())
            .appendingPathComponent("assets").appendingPathComponent(digest + ".stroke")
        var damaged = data
        damaged[damaged.startIndex] ^= 1
        try damaged.write(to: path)
        let before = await store.workMetrics()
        let metadata = try await store.inspect(id: receipt.id)
        let after = await store.workMetrics()
        XCTAssertEqual(metadata.edits.map(\.id), edits.map(\.id))
        XCTAssertEqual(after.assetReadCalls, before.assetReadCalls)
        let selected = try await store.loadEdit(id: receipt.id, editID: edits[0].id)
        let drawing = try await codec.decodeSelected(selected)
        XCTAssertEqual(drawing.strokes.map(\.id), edits[0].snapshot.drawing.strokes.map(\.id))
        do {
            _ = try await store.loadStates(id: receipt.id)
            XCTFail("Targeted inspection cannot authorize full pending coverage.")
        } catch NotebookRepositoryError.corruptData {}
        try data.write(to: path)
        let restored = try await store.loadStates(id: receipt.id)
        XCTAssertEqual(try NotebookRecoveryStateFingerprint(validating: restored), encoded.fingerprint)
    }

    private func pending(
        _ drawing: PKDrawing, index: Int, source: NotebookRecoveryProvenance? = nil
    ) -> NotebookPendingEdit<NotebookDrawingSnapshot> {
        NotebookPendingEdit(
            snapshot: NotebookDrawingSnapshot(
                drawing: drawing, pageCount: index + 1, title: "State \(index)", recoverySource: source
            ),
            stamp: NotebookTestFixtures.stamp(index)
        )
    }
}
