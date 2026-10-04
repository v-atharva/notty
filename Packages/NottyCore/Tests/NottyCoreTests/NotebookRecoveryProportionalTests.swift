import Darwin
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
final class NotebookRecoveryProportionalTests: XCTestCase {
    func testEightStatesPublishSharedNativeAssetsWithProportionalBytes() async throws {
        let root = try RecoveryStateFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await makeStates(strokeCount: 64, points: 256)
        let store = try NotebookRecoveryStore(rootURL: root)
        let receipt = try await store.preserveStates(fixture.batch)
        let loaded = try await store.loadStates(id: receipt.id)
        XCTAssertEqual(loaded, fixture.batch)
        XCTAssertEqual(
            try NotebookRecoveryStateFingerprint(validating: loaded),
            try NotebookRecoveryStateFingerprint(validating: fixture.batch)
        )
        let published = try RecoveryStateFixtures.regularBytes(in: root.appendingPathComponent(receipt.id.uuidString.lowercased()))
        XCTAssertGreaterThan(fixture.baselineUniqueAssetBytes, 0)
        XCTAssertLessThan(published, fixture.baselineUniqueAssetBytes * 2)
        XCTAssertEqual(loaded.edits.map(\.id), fixture.batch.edits.map(\.id))
        XCTAssertEqual(loaded.edits.map(\.stamp), fixture.batch.edits.map(\.stamp))
        XCTAssertEqual(loaded.edits.map(\.title), fixture.batch.edits.map(\.title))
        XCTAssertEqual(loaded.edits.map(\.pageCount), fixture.batch.edits.map(\.pageCount))
        let work = await fixture.codec.workMetrics
        XCTAssertEqual(work.serializedStrokes, 64 + 7)
        let files = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent(receipt.id.uuidString.lowercased()).appendingPathComponent("references"),
            includingPropertiesForKeys: [.fileSizeKey]
        )
        XCTAssertEqual(files.count, 8)
        for file in files {
            XCTAssertEqual(try Data(contentsOf: file).count, 64 * 48)
        }
    }

    func testFullLoadReadsEachUniquePhysicalArchiveOnceButRetainsEveryLogicalReference() async throws {
        let root = try RecoveryStateFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = PKDrawing(strokes: [RecoveryStateFixtures.stroke()]).dataRepresentation()
        let notebookID = UUID()
        let edits = (0..<8).map { index in
            RecoveryStateFixtures.edit(
                strokes: (0..<4).map { _ in NotebookStroke(id: UUID(), data: data) }, index: index
            )
        }
        let batch = NotebookRecoveryStrokeBatch(notebookID: notebookID, edits: edits)
        let writer = try NotebookRecoveryStore(rootURL: root)
        let receipt = try await writer.preserveStates(batch)
        let observations = RecoveryStateFixtures.AssetObservations()
        let reader = try NotebookRecoveryStore(rootURL: root, assetVerificationObserver: { observations.record($0) })
        let loaded = try await reader.loadStates(id: receipt.id)
        XCTAssertEqual(loaded, batch)
        let work = await reader.workMetrics()
        XCTAssertEqual(work.assetReadCalls, 1)
        XCTAssertEqual(work.assetReadBytes, data.count)
        XCTAssertEqual(work.assetHashCalls, 1)
        XCTAssertEqual(work.assetHashBytes, data.count)
        XCTAssertEqual(work.nativeArchiveValidations, 1)
        XCTAssertEqual(work.nativeStateValidations, 8)
        XCTAssertEqual(work.inputReferenceVisits, 32)
        XCTAssertEqual(observations.snapshot(), [NotebookDigest.sha256(data): 1])
        for edit in loaded.edits {
            let drawing = try await InkCodec(profile: .recovery).decode(edit.strokes)
            XCTAssertEqual(drawing.strokes.map(\.id), edit.strokes.map(\.id))
            XCTAssertEqual(drawing.strokes.count, 4)
        }
    }

    func testEmptyHistoricalStatesRetainTheirOriginalMetadataAndOrder() async throws {
        let root = try RecoveryStateFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let codec = InkCodec(profile: .recovery)
        let assets = try await codec.encode(PKDrawing(strokes: [RecoveryStateFixtures.stroke()]))
        let batch = NotebookRecoveryStrokeBatch(notebookID: UUID(), baseRevisionID: UUID(), edits: [
            RecoveryStateFixtures.edit(strokes: [], index: 0),
            RecoveryStateFixtures.edit(strokes: assets, index: 1),
            RecoveryStateFixtures.edit(strokes: [], index: 2)
        ])
        let store = try NotebookRecoveryStore(rootURL: root)
        let receipt = try await store.preserveStates(batch)
        let loaded = try await store.loadStates(id: receipt.id)
        XCTAssertEqual(loaded, batch)
        XCTAssertEqual(loaded.edits.map { $0.strokes.count }, [0, 1, 0])
        for index in [0, 2] {
            let references = root.appendingPathComponent(receipt.id.uuidString.lowercased())
                .appendingPathComponent("references")
                .appendingPathComponent(batch.edits[index].id.uuidString.lowercased() + ".refs")
            XCTAssertEqual(try Data(contentsOf: references).count, 0)
            let selected = try await store.loadEdit(id: receipt.id, editID: batch.edits[index].id)
            XCTAssertEqual(selected.state, batch.edits[index])
        }
    }

    func testFingerprintBindsEveryOrderedIdentityAndMetadataField() async throws {
        let codec = InkCodec(profile: .recovery)
        let strokes = try await codec.encode(PKDrawing(strokes: [
            RecoveryStateFixtures.stroke(), RecoveryStateFixtures.stroke(x: 120)
        ]))
        let notebookID = UUID()
        let baseID = UUID()
        let original = RecoveryStateFixtures.edit(strokes: strokes, index: 0)
        let next = RecoveryStateFixtures.edit(strokes: strokes, index: 1)
        let batch = NotebookRecoveryStrokeBatch(notebookID: notebookID, baseRevisionID: baseID, edits: [original, next])
        let fingerprint = try NotebookRecoveryStateFingerprint(validating: batch)
        let source = NotebookRecoveryProvenance(
            notebookID: notebookID, copyID: UUID(), editID: UUID(),
            originalStamp: RecoveryStateFixtures.stamp(10), baseRevisionID: UUID()
        )
        let variants = [
            NotebookRecoveryStrokeEdit(id: UUID(), strokes: strokes, title: original.title, pageCount: original.pageCount, stamp: original.stamp),
            NotebookRecoveryStrokeEdit(id: original.id, strokes: Array(strokes.reversed()), title: original.title, pageCount: original.pageCount, stamp: original.stamp),
            NotebookRecoveryStrokeEdit(id: original.id, strokes: [NotebookStroke(id: UUID(), data: strokes[0].data), strokes[1]], title: original.title, pageCount: original.pageCount, stamp: original.stamp),
            NotebookRecoveryStrokeEdit(id: original.id, strokes: strokes, title: "Changed", pageCount: original.pageCount, stamp: original.stamp),
            NotebookRecoveryStrokeEdit(id: original.id, strokes: strokes, title: original.title, pageCount: 12, stamp: original.stamp),
            NotebookRecoveryStrokeEdit(id: original.id, strokes: strokes, title: original.title, pageCount: original.pageCount, stamp: RecoveryStateFixtures.stamp(20)),
            NotebookRecoveryStrokeEdit(id: original.id, strokes: strokes, title: original.title, pageCount: original.pageCount, stamp: original.stamp, recoverySource: source)
        ]
        for variant in variants {
            XCTAssertNotEqual(fingerprint, try NotebookRecoveryStateFingerprint(validating:
                NotebookRecoveryStrokeBatch(notebookID: notebookID, baseRevisionID: baseID, edits: [variant, next])
            ))
        }
        for changed in [
            NotebookRecoveryStrokeBatch(notebookID: UUID(), baseRevisionID: baseID, edits: batch.edits),
            NotebookRecoveryStrokeBatch(notebookID: notebookID, baseRevisionID: UUID(), edits: batch.edits),
            NotebookRecoveryStrokeBatch(notebookID: notebookID, baseRevisionID: baseID, edits: Array(batch.edits.reversed()))
        ] {
            XCTAssertNotEqual(fingerprint, try NotebookRecoveryStateFingerprint(validating: changed))
        }
        XCTAssertEqual(fingerprint.workMetrics.assetHashCalls, 0)
        XCTAssertEqual(fingerprint.workMetrics.assetCopiedBytes, 0)
        var changedBytes = strokes[0].data
        changedBytes[changedBytes.startIndex] ^= 1
        let changed = NotebookRecoveryStrokeBatch(notebookID: notebookID, baseRevisionID: baseID, edits: [
            NotebookRecoveryStrokeEdit(
                id: original.id, strokes: [NotebookStroke(id: strokes[0].id, data: changedBytes), strokes[1]],
                title: original.title, pageCount: original.pageCount, stamp: original.stamp
            ), next
        ])
        XCTAssertNotEqual(fingerprint, try NotebookRecoveryStateFingerprint(validating: changed))
    }

    func testPublicAliasedInputCannotMutateAnAlreadyCapturedFingerprint() throws {
        let data = PKDrawing(strokes: [RecoveryStateFixtures.stroke()]).dataRepresentation()
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: data.count, alignment: 1)
        defer { pointer.deallocate() }
        data.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: data.count)
        let aliased = Data(bytesNoCopy: pointer, count: data.count, deallocator: .none)
        let id = UUID()
        let editID = UUID()
        let notebookID = UUID()
        let batch = NotebookRecoveryStrokeBatch(notebookID: notebookID, edits: [
            NotebookRecoveryStrokeEdit(id: editID, strokes: [NotebookStroke(id: id, data: aliased)],
                title: "Aliased", pageCount: 1, stamp: RecoveryStateFixtures.stamp(0))
        ])
        let fingerprint = try NotebookRecoveryStateFingerprint(validating: batch)
        let owned = NotebookRecoveryStrokeBatch(notebookID: notebookID, edits: [
            NotebookRecoveryStrokeEdit(id: editID, strokes: [NotebookStroke(id: id, data: data)],
                title: "Aliased", pageCount: 1, stamp: RecoveryStateFixtures.stamp(0))
        ])
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: data.count)
        XCTAssertEqual(fingerprint, try NotebookRecoveryStateFingerprint(validating: owned))
        XCTAssertNotEqual(fingerprint, try NotebookRecoveryStateFingerprint(validating: batch))
        XCTAssertEqual(fingerprint.workMetrics.assetCopiedBytes, data.count)
        XCTAssertEqual(fingerprint.workMetrics.assetHashCalls, 1)
        XCTAssertEqual(fingerprint.workMetrics.assetHashBytes, data.count)
    }

    func testEveryStatePublicationFaultRetainsExactPriorCopyAndRemovesOwnedStage() async throws {
        for stage in NotebookRecoveryWriteStage.allCases {
            let root = try RecoveryStateFixtures.makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let codec = InkCodec(profile: .recovery)
            let strokes = try await codec.encode(PKDrawing(strokes: [RecoveryStateFixtures.stroke()]))
            let batch = NotebookRecoveryStrokeBatch(notebookID: UUID(), edits: [
                RecoveryStateFixtures.edit(strokes: strokes, index: 0),
                RecoveryStateFixtures.edit(strokes: strokes, index: 1)
            ])
            let healthy = try NotebookRecoveryStore(rootURL: root)
            let original = try await healthy.preserveStates(batch)
            let directory = root.appendingPathComponent(original.id.uuidString.lowercased())
            let before = try RecoveryStateFixtures.fileSnapshot(in: directory)
            let faulty = try NotebookRecoveryStore(rootURL: root) { current in
                if current == stage { throw InjectedFailure.stop }
            }
            do {
                _ = try await faulty.preserveStates(batch)
                XCTFail("The selected publication fault must be reached.")
            } catch InjectedFailure.stop {}
            XCTAssertEqual(try RecoveryStateFixtures.fileSnapshot(in: directory), before)
            let loaded = try await healthy.loadStates(id: original.id)
            XCTAssertEqual(loaded, batch)
            let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
            XCTAssertFalse(entries.contains { $0.hasPrefix(".recovery-") })
            XCTAssertEqual(entries.filter { UUID(uuidString: $0) != nil }, [original.id.uuidString.lowercased()])
            let work = await faulty.workMetrics()
            XCTAssertEqual(work.publications, 0)
        }
    }

    private enum InjectedFailure: Error { case stop }

    #if NOTTY_RECOVERY_STRESS
    func testEightLargeNativeStatesRetainEveryEditWithProportionalPublishedBytes() async throws {
        guard ProcessInfo.processInfo.environment["NOTTY_RUN_RECOVERY_STRESS"] == "1" else {
            XCTFail("The dedicated recovery workload requires explicit execution.")
            throw NotebookRepositoryError.invalidContent("The recovery stress environment is missing.")
        }
        let beforePeak = try processPeakResidentBytes()
        let root = try RecoveryStateFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let template = RecoveryStateFixtures.stroke(points: 8_192)
        let templateBytes = PKDrawing(strokes: [template]).dataRepresentation().count
        guard templateBytes > 0 else { throw NotebookRepositoryError.invalidContent("The native template is empty.") }
        let count = (61 * 1_024 * 1_024 + templateBytes - 1) / templateBytes
        XCTAssertGreaterThan(count, 0)
        XCTAssertLessThanOrEqual(count, 10_000)
        guard (1...10_000).contains(count) else {
            throw NotebookRepositoryError.invalidContent("The native workload cannot meet its bounded stroke count.")
        }
        let fixture = try await makeStates(strokeCount: count, template: template)
        let stateBytes = fixture.batch.edits.map { $0.strokes.reduce(0) { $0 + $1.data.count } }
        for bytes in stateBytes {
            XCTAssertGreaterThanOrEqual(bytes, 60 * 1_024 * 1_024)
            XCTAssertLessThanOrEqual(bytes, 64 * 1_024 * 1_024)
        }
        let totalLogical = stateBytes.reduce(0, +)
        XCTAssertLessThanOrEqual(totalLogical, 512 * 1_024 * 1_024)
        let store = try NotebookRecoveryStore(rootURL: root)
        let receipt = try await store.preserveStates(fixture.batch)
        let writerWork = await store.workMetrics()
        let observations = RecoveryStateFixtures.AssetObservations()
        let reader = try NotebookRecoveryStore(rootURL: root, assetVerificationObserver: { observations.record($0) })
        let loaded = try await reader.loadStates(id: receipt.id)
        XCTAssertEqual(loaded, fixture.batch)
        XCTAssertEqual(try NotebookRecoveryStateFingerprint(validating: loaded),
            try NotebookRecoveryStateFingerprint(validating: fixture.batch))
        let readerWork = await reader.workMetrics()
        var unique: [String: Data] = [:]
        for edit in fixture.batch.edits {
            for stroke in edit.strokes { unique[try XCTUnwrap(stroke.cachedDigest)] = stroke.data }
        }
        let uniqueBytes = unique.values.reduce(0) { $0 + $1.count }
        XCTAssertEqual(writerWork.assetWriteCalls, unique.count)
        XCTAssertEqual(writerWork.assetWrittenBytes, uniqueBytes)
        XCTAssertEqual(readerWork.assetReadCalls, unique.count)
        XCTAssertEqual(readerWork.assetReadBytes, uniqueBytes)
        XCTAssertEqual(readerWork.assetHashCalls, unique.count)
        XCTAssertEqual(readerWork.assetHashBytes, uniqueBytes)
        XCTAssertEqual(readerWork.nativeArchiveValidations, unique.count)
        XCTAssertEqual(readerWork.nativeStateValidations, 8)
        XCTAssertEqual(readerWork.inputReferenceVisits, count * 8)
        XCTAssertEqual(observations.snapshot(), unique.mapValues { _ in 1 })
        var native: [String: PKStroke] = [:]
        for (digest, data) in unique {
            let drawing = try PKDrawing(data: data)
            XCTAssertEqual(drawing.strokes.count, 1)
            native[digest] = try XCTUnwrap(drawing.strokes.first)
        }
        for (index, edit) in loaded.edits.enumerated() {
            let strokes = try edit.strokes.map { asset -> PKStroke in
                var stroke = try XCTUnwrap(native[try XCTUnwrap(asset.cachedDigest)])
                stroke.id = asset.id
                return stroke
            }
            let drawing = PKDrawing(strokes: strokes)
            XCTAssertEqual(drawing.strokes.map(\.id), fixture.batch.edits[index].strokes.map(\.id))
            XCTAssertEqual(drawing.strokes.map(\.transform), fixture.transforms[index])
            XCTAssertEqual(drawing.strokes.map { $0.path.count }, Array(repeating: template.path.count, count: count))
            for stroke in drawing.strokes {
                for point in [0, template.path.count / 2, template.path.count - 1] {
                    XCTAssertEqual(stroke.path[point].location.x, template.path[point].location.x, accuracy: 0.001)
                    XCTAssertEqual(stroke.path[point].location.y, template.path[point].location.y, accuracy: 0.001)
                    XCTAssertEqual(stroke.path[point].force, template.path[point].force, accuracy: 0.001)
                    XCTAssertEqual(stroke.path[point].timeOffset, template.path[point].timeOffset, accuracy: 0.001)
                }
            }
        }
        let directory = root.appendingPathComponent(receipt.id.uuidString.lowercased())
        let published = try RecoveryStateFixtures.regularBytes(in: directory)
        let assetBytes = try RecoveryStateFixtures.regularBytes(in: directory.appendingPathComponent("assets"))
        let referenceBytes = try RecoveryStateFixtures.regularBytes(in: directory.appendingPathComponent("references"))
        XCTAssertEqual(assetBytes, uniqueBytes)
        XCTAssertGreaterThanOrEqual(fixture.baselineUniqueAssetBytes, 60 * 1_024 * 1_024)
        XCTAssertLessThan(published, fixture.baselineUniqueAssetBytes * 2)
        let sourceBefore = try RecoveryStateFixtures.fileSnapshot(in: directory)
        let lastState = try XCTUnwrap(loaded.edits.last)
        let overBatch = NotebookRecoveryStrokeBatch(
            notebookID: fixture.batch.notebookID, baseRevisionID: fixture.batch.baseRevisionID,
            edits: fixture.batch.edits + [NotebookRecoveryStrokeEdit(
                id: UUID(), strokes: lastState.strokes, title: "Over limit",
                pageCount: 12, stamp: RecoveryStateFixtures.stamp(9)
            )]
        )
        do {
            _ = try await store.preserveStates(overBatch)
            XCTFail("Dedup must not expand the 512 MiB logical batch allowance.")
        } catch NotebookRepositoryError.sizeLimitExceeded {}
        let overState = NotebookRecoveryStrokeBatch(notebookID: fixture.batch.notebookID, edits: [
            RecoveryStateFixtures.edit(strokes: (0..<3).flatMap { _ in
                loaded.edits[0].strokes.map { NotebookStroke(id: UUID(), data: $0.data) }
            }, index: 10)
        ])
        do {
            _ = try await store.preserveStates(overState)
            XCTFail("Repeated native references must still obey the 128 MiB state allowance.")
        } catch NotebookRepositoryError.sizeLimitExceeded {}
        XCTAssertEqual(try RecoveryStateFixtures.fileSnapshot(in: directory), sourceBefore)
        let codecWork = await fixture.codec.workMetrics
        XCTAssertEqual(codecWork.serializedStrokes, count + 7)
        let afterPeak = try processPeakResidentBytes()
        let metrics: [String: Any] = [
            "editCount": 8, "strokeCount": count, "pointCount": template.path.count,
            "logicalStateBytes": stateBytes, "totalLogicalBytes": totalLogical,
            "baselineUniqueAssetBytes": fixture.baselineUniqueAssetBytes, "uniqueAssetBytes": uniqueBytes,
            "publishedRegularFileBytes": published, "referenceBytes": referenceBytes,
            "metadataBytes": published - assetBytes - referenceBytes,
            "serializedStrokes": codecWork.serializedStrokes,
            "codecHashedArchiveBytes": codecWork.hashedArchiveBytes,
            "codecCopiedArchiveBytes": codecWork.copiedArchiveBytes,
            "codecSignatureChecks": codecWork.signatureChecks, "codecComparedPoints": codecWork.comparedPoints,
            "storeAssetWrittenBytes": writerWork.assetWrittenBytes,
            "storeMetadataWrittenBytes": writerWork.metadataWrittenBytes,
            "storeAssetHashBytes": writerWork.assetHashBytes,
            "readerAssetReadCalls": readerWork.assetReadCalls, "readerAssetReadBytes": readerWork.assetReadBytes,
            "readerAssetHashBytes": readerWork.assetHashBytes,
            "readerNativeArchiveValidations": readerWork.nativeArchiveValidations,
            "readerNativeStateValidations": readerWork.nativeStateValidations,
            "writer": metricsDictionary(writerWork), "reader": metricsDictionary(readerWork),
            "processPeakRSSBeforeBytes": beforePeak, "processPeakRSSAfterBytes": afterPeak
        ]
        let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
        print("NOTTY_RECOVERY_STRESS_METRIC \(String(decoding: data, as: UTF8.self))")
        if let path = ProcessInfo.processInfo.environment["NOTTY_RECOVERY_METRICS_DIRECTORY"] {
            guard !path.isEmpty else { throw NotebookRepositoryError.invalidContent("The metrics directory is empty.") }
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("recovery-native-8-states-60mib.json"), options: .atomic)
        }
    }

    private func metricsDictionary(_ work: NotebookRecoveryWorkMetrics) -> [String: Int] {
        [
            "assetCopiedBytes": work.assetCopiedBytes, "inputReferenceVisits": work.inputReferenceVisits,
            "assetHashCalls": work.assetHashCalls, "assetHashBytes": work.assetHashBytes,
            "assetReadCalls": work.assetReadCalls, "assetReadBytes": work.assetReadBytes,
            "assetWriteCalls": work.assetWriteCalls, "assetWrittenBytes": work.assetWrittenBytes,
            "metadataHashCalls": work.metadataHashCalls, "metadataHashBytes": work.metadataHashBytes,
            "metadataReadCalls": work.metadataReadCalls, "metadataReadBytes": work.metadataReadBytes,
            "metadataWriteCalls": work.metadataWriteCalls, "metadataWrittenBytes": work.metadataWrittenBytes,
            "metadataEncodeCalls": work.metadataEncodeCalls, "metadataEncodedBytes": work.metadataEncodedBytes,
            "nativeArchiveValidations": work.nativeArchiveValidations,
            "nativeStateValidations": work.nativeStateValidations,
            "nativeArchiveSerializations": work.nativeArchiveSerializations,
            "nativeSerializedBytes": work.nativeSerializedBytes, "publications": work.publications
        ]
    }

    private func processPeakResidentBytes() throws -> Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw NotebookRepositoryError.ioFailure(errno) }
        return Int64(usage.ru_maxrss)
    }
    #endif

    private struct StateFixture {
        let batch: NotebookRecoveryStrokeBatch
        let baselineUniqueAssetBytes: Int
        let transforms: [[CGAffineTransform]]
        let codec: InkCodec
    }

    private func makeStates(strokeCount: Int, points: Int) async throws -> StateFixture {
        try await makeStates(strokeCount: strokeCount, template: RecoveryStateFixtures.stroke(points: points))
    }

    private func makeStates(strokeCount: Int, template: PKStroke) async throws -> StateFixture {
        var strokes = (0..<strokeCount).map { index in
            var stroke = template
            stroke.id = UUID()
            stroke.transform = template.transform.translatedBy(x: CGFloat(index) * 0.25, y: CGFloat(index) * 0.125)
            return stroke
        }
        let codec = InkCodec(profile: .recovery)
        var edits: [NotebookRecoveryStrokeEdit] = []
        var transforms: [[CGAffineTransform]] = []
        var baseline = 0
        for index in 0..<8 {
            if index > 0 { strokes[0].transform = CGAffineTransform(translationX: CGFloat(index), y: CGFloat(index * 2)) }
            let drawing = PKDrawing(strokes: strokes)
            XCTAssertEqual(drawing.strokes.map(\.id), strokes.map(\.id))
            let assets = try await codec.encode(drawing)
            if index == 0 {
                var unique: [String: Data] = [:]
                for asset in assets { unique[try XCTUnwrap(asset.cachedDigest)] = asset.data }
                baseline = unique.values.reduce(0) { $0 + $1.count }
            }
            edits.append(RecoveryStateFixtures.edit(strokes: assets, index: index))
            transforms.append(strokes.map(\.transform))
        }
        return StateFixture(
            batch: NotebookRecoveryStrokeBatch(notebookID: UUID(), baseRevisionID: UUID(), edits: edits),
            baselineUniqueAssetBytes: baseline, transforms: transforms, codec: codec
        )
    }
}

enum RecoveryStateFixtures {
    static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func stamp(_ index: Int) -> NotebookEditStamp {
        NotebookEditStamp(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
            uptime: Double(index), sessionID: UUID(uuidString: "3C7EE03A-00F7-4DB5-81CB-B3A96563FBA4")!
        )
    }

    static func edit(strokes: [NotebookStroke], index: Int) -> NotebookRecoveryStrokeEdit {
        NotebookRecoveryStrokeEdit(
            id: UUID(), strokes: strokes, title: "State \(index)", pageCount: min(index + 1, 12), stamp: stamp(index)
        )
    }

    static func stroke(points count: Int = 4, x: CGFloat = 20) -> PKStroke {
        #if canImport(UIKit)
        let color = UIColor.black
        #else
        let color = NSColor.black
        #endif
        var state: UInt64 = 17
        let points = (0..<count).map { index -> PKStrokePoint in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let dx = CGFloat((state >> 16) % 1_500) / 4
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let dy = CGFloat((state >> 16) % 1_500) / 4
            return PKStrokePoint(
                location: CGPoint(x: x + dx, y: 40 + dy), timeOffset: Double(index) * 0.02,
                size: CGSize(width: 3, height: 3), opacity: 1, force: 0.75,
                azimuth: 0, altitude: .pi / 2, secondaryScale: 0.75, threshold: 0.25, lateralJitter: 0.125
            )
        }
        return PKStroke(
            ink: PKInk(.pen, color: color),
            path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1_000)),
            transform: .identity, mask: nil, randomSeed: 17,
            id: UUID(), renderGroupID: nil, renderState: nil
        )
    }

    static func regularBytes(in directory: URL) throws -> Int {
        let base = directory.standardizedFileURL.resolvingSymlinksInPath()
        let failure = EnumerationFailure()
        guard let enumerator = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            errorHandler: { _, error in failure.record(error); return false }
        ) else { throw NotebookRepositoryError.invalidContent("The published bundle could not be enumerated.") }
        var bytes = 0
        for case let url as URL in enumerator {
            let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard resource.isSymbolicLink != true else { throw NotebookRepositoryError.unsafePath("A published bundle contains a link.") }
            guard resource.isRegularFile == true else { continue }
            let file = url.standardizedFileURL.resolvingSymlinksInPath()
            guard file.path.hasPrefix(base.path + "/"), let size = resource.fileSize else {
                throw NotebookRepositoryError.unsafePath("A published file escaped its bundle or has no size.")
            }
            bytes += size
        }
        try failure.check()
        return bytes
    }

    static func fileSnapshot(in directory: URL) throws -> [String: Data] {
        let base = directory.standardizedFileURL.resolvingSymlinksInPath()
        let failure = EnumerationFailure()
        guard let enumerator = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            errorHandler: { _, error in failure.record(error); return false }
        ) else { throw NotebookRepositoryError.invalidContent("The published bundle could not be enumerated.") }
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard resource.isSymbolicLink != true else { throw NotebookRepositoryError.unsafePath("A published bundle contains a link.") }
            guard resource.isRegularFile == true else { continue }
            let file = url.standardizedFileURL.resolvingSymlinksInPath()
            guard file.path.hasPrefix(base.path + "/") else { throw NotebookRepositoryError.unsafePath("A published file escaped its bundle.") }
            result[String(file.path.dropFirst(base.path.count + 1))] = try Data(contentsOf: file)
        }
        try failure.check()
        return result
    }

    private final class EnumerationFailure: @unchecked Sendable {
        private let lock = NSLock()
        private var error: (any Error)?
        func record(_ error: any Error) {
            lock.lock()
            self.error = error
            lock.unlock()
        }
        func check() throws {
            lock.lock()
            let captured = error
            lock.unlock()
            if let captured { throw captured }
        }
    }

    final class AssetObservations: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        func record(_ digest: String) {
            lock.lock()
            counts[digest, default: 0] += 1
            lock.unlock()
        }
        func snapshot() -> [String: Int] {
            lock.lock()
            defer { lock.unlock() }
            return counts
        }
    }
}
