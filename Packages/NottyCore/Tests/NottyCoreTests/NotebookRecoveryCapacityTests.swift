import CryptoKit
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
final class NotebookRecoveryCapacityTests: XCTestCase {
    func testEightPendingTenThousandStrokeEditsPreserveExactOrderedContentAndProvenance() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let batch = largeBatch()
        XCTAssertEqual(batch.edits.count, 8)
        XCTAssertTrue(batch.edits.allSatisfy { $0.strokeIDs.count == 10_000 })
        let beforeRSS = try processPeakResidentBytes()
        let store = try NotebookRecoveryStore(rootURL: root)
        let receipt = try await store.preserve(batch)
        let reopened = try NotebookRecoveryStore(rootURL: root)
        let loaded = try await reopened.load(id: receipt.id)
        let afterRSS = try processPeakResidentBytes()
        XCTAssertEqual(loaded, batch)
        XCTAssertEqual(receipt.editCount, 8)
        XCTAssertEqual(loaded.edits.map(\.id), batch.edits.map(\.id))
        XCTAssertEqual(loaded.edits.map(\.stamp), batch.edits.map(\.stamp))
        for (actual, expected) in zip(loaded.edits, batch.edits) {
            XCTAssertEqual(actual.strokeIDs, expected.strokeIDs)
            XCTAssertEqual(actual.drawingData, expected.drawingData)
            XCTAssertEqual(actual.title, expected.title)
            XCTAssertEqual(actual.pageCount, expected.pageCount)
        }
        let directory = root.appendingPathComponent(receipt.id.uuidString.lowercased(), isDirectory: true)
        let manifestBytes = try Data(contentsOf: directory.appendingPathComponent("manifest.json")).count
        XCTAssertLessThan(manifestBytes, 256 * 1_024)
        let manifest = try object(at: directory.appendingPathComponent("manifest.json"))
        XCTAssertEqual(manifest["schemaVersion"] as? Int, 2)
        let references = try XCTUnwrap(manifest["edits"] as? [[String: Any]])
        XCTAssertEqual(references.count, batch.edits.count)
        var identityBytes = 0
        var archiveBytes = 0
        for (reference, edit) in zip(references, batch.edits) {
            XCTAssertNil(reference["strokeIDs"])
            XCTAssertEqual(reference["strokeCount"] as? Int, 10_000)
            let identityData = try Data(contentsOf: identityURL(bundle: directory, editID: edit.id))
            XCTAssertEqual(identityData.count, 10_000 * 16)
            XCTAssertEqual(try NotebookRecoveryIdentityFormat.decode(identityData, count: 10_000), edit.strokeIDs)
            XCTAssertEqual(reference["strokeIDsDigest"] as? String, digest(identityData))
            identityBytes += identityData.count
            archiveBytes += try directory.appendingPathComponent(
                "archives/\(edit.id.uuidString.lowercased()).drawing"
            ).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        }
        XCTAssertEqual(identityBytes, 8 * 10_000 * 16)
        XCTAssertEqual(archiveBytes, batch.edits.reduce(0) { $0 + $1.drawingData.count })
        try writeMetrics([
            "manifestBytes": manifestBytes, "identityBytes": identityBytes,
            "archiveBytes": archiveBytes, "editCount": 8, "strokeCount": 10_000,
            "processPeakRSSBeforeBytes": beforeRSS, "processPeakRSSAfterBytes": afterRSS
        ])
    }

    func testBinaryIdentityFormatUsesStableSixteenByteUUIDsAtTheDeclaredCapacity() throws {
        let known = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        let expected = Data((0..<16).map { UInt8($0 * 17) })
        XCTAssertEqual(try NotebookRecoveryIdentityFormat.encode([known]), expected)
        XCTAssertEqual(try NotebookRecoveryIdentityFormat.decode(expected, count: 1), [known])
        XCTAssertEqual(try NotebookRecoveryIdentityFormat.decode(Data(), count: 0), [])
        let identities = (0..<20_000).map { _ in UUID() }
        var totalBytes = 0
        for _ in 0..<NotebookRecoveryStore.maximumEditCount {
            let data = try NotebookRecoveryIdentityFormat.encode(identities)
            XCTAssertEqual(data.count, 320_000)
            XCTAssertEqual(try NotebookRecoveryIdentityFormat.decode(data, count: identities.count), identities)
            totalBytes += data.count
        }
        XCTAssertEqual(totalBytes, 10_240_000)
        XCTAssertThrowsError(try NotebookRecoveryIdentityFormat.encode(identities + [UUID()])) {
            guard case .sizeLimitExceeded? = $0 as? NotebookRepositoryError else {
                return XCTFail("Unexpected identity bound error: \($0)")
            }
        }
        XCTAssertThrowsError(try NotebookRecoveryIdentityFormat.encode([known, known])) {
            guard case .invalidContent? = $0 as? NotebookRepositoryError else {
                return XCTFail("Unexpected duplicate identity error: \($0)")
            }
        }
        for count in [-1, 20_001, Int.max] {
            XCTAssertThrowsError(try NotebookRecoveryIdentityFormat.decode(Data(), count: count)) {
                guard case .corruptData? = $0 as? NotebookRepositoryError else {
                    return XCTFail("Unexpected stored identity bound error: \($0)")
                }
            }
        }
    }

    func testIdentityFilesRejectDamageMissingBytesDuplicatesAndOversizeWithoutChangingTheBundle() async throws {
        for damage in ["sameLength", "truncated", "extended", "duplicate", "oversized", "missing"] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let batch = smallBatch()
            let store = try NotebookRecoveryStore(rootURL: root)
            let receipt = try await store.preserve(batch)
            let directory = bundle(root: root, receiptID: receipt.id)
            let url = identityURL(bundle: directory, editID: batch.edits[0].id)
            var bytes = try Data(contentsOf: url)
            switch damage {
            case "sameLength":
                bytes[0] ^= 1
                try bytes.write(to: url)
            case "truncated":
                try bytes.dropLast().write(to: url)
            case "extended":
                bytes.append(0)
                try bytes.write(to: url)
            case "duplicate":
                let duplicated = bytes.prefix(16) + bytes.prefix(16)
                try duplicated.write(to: url)
                try mutateManifest(bundle: directory) { manifest in
                    var edits = manifest["edits"] as! [[String: Any]]
                    edits[0]["strokeIDsDigest"] = digest(duplicated)
                    manifest["edits"] = edits
                }
            case "oversized":
                try Data(repeating: 0, count: 320_001).write(to: url)
            default:
                try FileManager.default.removeItem(at: url)
            }
            let before = try snapshot(in: directory)
            await assertCorruptLoad(store, receiptID: receipt.id)
            do {
                _ = try await store.list(notebookID: batch.notebookID)
                XCTFail("Identity damage must prevent a validated receipt.")
            } catch NotebookRepositoryError.corruptData(_) {}
            let scan = try await store.scan(notebookID: batch.notebookID)
            XCTAssertTrue(scan.copies.isEmpty)
            XCTAssertEqual(scan.unavailableCopyIDs, [receipt.id])
            XCTAssertEqual(try snapshot(in: directory), before)
        }
    }

    func testIdentityFilesAndDirectoryLinksAreRejectedWithoutFollowingTargets() async throws {
        for linkDirectory in [false, true] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let batch = smallBatch()
            let store = try NotebookRecoveryStore(rootURL: root)
            let receipt = try await store.preserve(batch)
            let directory = bundle(root: root, receiptID: receipt.id)
            let identities = directory.appendingPathComponent("identities", isDirectory: true)
            let target = root.appendingPathComponent("outside", isDirectory: linkDirectory)
            let link: URL
            if linkDirectory {
                try FileManager.default.moveItem(at: identities, to: target)
                link = identities
            } else {
                link = identityURL(bundle: directory, editID: batch.edits[0].id)
                try FileManager.default.copyItem(at: link, to: target)
                try FileManager.default.removeItem(at: link)
            }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let original = linkDirectory ? try snapshot(in: target) : ["file": try Data(contentsOf: target)]
            do {
                _ = try await store.load(id: receipt.id)
                XCTFail("Recovery identity links must not be followed.")
            } catch NotebookRepositoryError.unsafePath(_) {}
            let after = linkDirectory ? try snapshot(in: target) : ["file": try Data(contentsOf: target)]
            XCTAssertEqual(after, original)
            XCTAssertTrue(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        }
    }

    func testVersionTwoIdentityReferencesRejectContradictoryAndUnboundedMetadata() async throws {
        for change in ["negativeCount", "hugeCount", "countMismatch", "badDigest", "missingDigest", "inlineIDs", "mixedSchema"] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try NotebookRecoveryStore(rootURL: root)
            let receipt = try await store.preserve(smallBatch())
            let directory = bundle(root: root, receiptID: receipt.id)
            try mutateManifest(bundle: directory) { manifest in
                var edits = manifest["edits"] as! [[String: Any]]
                switch change {
                case "negativeCount": edits[0]["strokeCount"] = -1
                case "hugeCount": edits[0]["strokeCount"] = 20_001
                case "countMismatch": edits[0]["strokeCount"] = 3
                case "badDigest": edits[0]["strokeIDsDigest"] = "../../outside"
                case "missingDigest": edits[0].removeValue(forKey: "strokeIDsDigest")
                case "inlineIDs": edits[0]["strokeIDs"] = [UUID().uuidString, UUID().uuidString]
                default: manifest["schemaVersion"] = 1
                }
                manifest["edits"] = edits
            }
            let before = try snapshot(in: directory)
            await assertCorruptLoad(store, receiptID: receipt.id)
            XCTAssertEqual(try snapshot(in: directory), before)
        }
    }

    func testLegacyInlineIdentityCopiesRemainReadableAndUnchangedBesideVersionTwoCopies() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let batch = smallBatch()
        let receipt = try writeLegacy(batch, root: root)
        let directory = bundle(root: root, receiptID: receipt.id)
        let original = try snapshot(in: directory)
        let store = try NotebookRecoveryStore(rootURL: root)
        let loaded = try await store.load(id: receipt.id)
        XCTAssertEqual(loaded, batch)
        let current = try await store.preserve(batch)
        let reloaded = try await store.load(id: current.id)
        XCTAssertEqual(reloaded, batch)
        let listed = try await store.list(notebookID: batch.notebookID)
        XCTAssertEqual(Set(listed.map(\.id)), Set([receipt.id, current.id]))
        let scan = try await store.scan(notebookID: batch.notebookID)
        XCTAssertEqual(Set(scan.copies.map(\.id)), Set([receipt.id, current.id]))
        XCTAssertTrue(scan.unavailableCopyIDs.isEmpty)
        XCTAssertEqual(try snapshot(in: directory), original)
    }

    func testStoredMetadataSizeLimitRemainsTwoMiBForBothRecoverySchemas() async throws {
        for legacy in [false, true] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try NotebookRecoveryStore(rootURL: root)
            let batch = smallBatch()
            let receipt = legacy ? try writeLegacy(batch, root: root) : try await store.preserve(batch)
            let directory = bundle(root: root, receiptID: receipt.id)
            let url = directory.appendingPathComponent("manifest.json")
            try Data(repeating: 0, count: 2 * 1_024 * 1_024 + 1).write(to: url)
            let before = try snapshot(in: directory)
            await assertCorruptLoad(store, receiptID: receipt.id)
            XCTAssertEqual(try snapshot(in: directory), before)
        }
    }

    func testArchiveWithReboundDigestStillMustMatchItsAuthoritativeIdentityCount() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotebookRecoveryStore(rootURL: root)
        let batch = smallBatch()
        let receipt = try await store.preserve(batch)
        let directory = bundle(root: root, receiptID: receipt.id)
        let data = PKDrawing().dataRepresentation()
        let url = directory.appendingPathComponent(
            "archives/\(batch.edits[0].id.uuidString.lowercased()).drawing"
        )
        try data.write(to: url)
        try mutateManifest(bundle: directory) { manifest in
            var edits = manifest["edits"] as! [[String: Any]]
            edits[0]["archiveDigest"] = digest(data)
            edits[0]["archiveBytes"] = data.count
            manifest["edits"] = edits
        }
        await assertCorruptLoad(store, receiptID: receipt.id)
    }

    private func smallBatch() -> NotebookRecoveryBatch {
        let drawing = PKDrawing(strokes: [stroke(), stroke()])
        let edit = NotebookRecoveryEdit(
            id: UUID(), drawingData: drawing.dataRepresentation(), strokeIDs: [UUID(), UUID()],
            title: "Authoritative identities", pageCount: 3,
            stamp: NotebookEditStamp(
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                uptime: 5, sessionID: UUID()
            )
        )
        XCTAssertEqual(drawing.strokes.count, edit.strokeIDs.count)
        return NotebookRecoveryBatch(notebookID: UUID(), baseRevisionID: UUID(), edits: [edit])
    }

    private func bundle(root: URL, receiptID: UUID) -> URL {
        root.appendingPathComponent(receiptID.uuidString.lowercased(), isDirectory: true)
    }

    private func identityURL(bundle: URL, editID: UUID) -> URL {
        bundle.appendingPathComponent("identities/\(editID.uuidString.lowercased()).ids")
    }

    private func object(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func mutateManifest(
        bundle: URL, mutation: (inout [String: Any]) -> Void
    ) throws {
        let url = bundle.appendingPathComponent("manifest.json")
        var manifest = try object(at: url)
        mutation(&manifest)
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try data.write(to: url)
        let receiptURL = bundle.appendingPathComponent("RECEIPT.json")
        var receipt = try object(at: receiptURL)
        receipt["manifestDigest"] = digest(data)
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]).write(to: receiptURL)
    }

    private func snapshot(in directory: URL) throws -> [String: Data] {
        let canonical = directory.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = canonical.path + "/"
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: canonical, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ))
        var files: [String: Data] = [:]
        for case let url as URL in enumerator {
            let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { continue }
            let file = url.standardizedFileURL.resolvingSymlinksInPath()
            guard file.path.hasPrefix(prefix) else {
                throw NotebookRepositoryError.unsafePath("A preservation fixture escaped its root.")
            }
            files[String(file.path.dropFirst(prefix.count))] = try Data(contentsOf: file)
        }
        return files
    }

    private func assertCorruptLoad(_ store: NotebookRecoveryStore, receiptID: UUID) async {
        do {
            _ = try await store.load(id: receiptID)
            XCTFail("Corrupt recovery identities or archives were accepted.")
        } catch NotebookRepositoryError.corruptData(_) {
        } catch {
            XCTFail("Unexpected recovery corruption error: \(error)")
        }
    }

    private func writeLegacy(_ batch: NotebookRecoveryBatch, root: URL) throws -> NotebookRecoveryReceipt {
        let receipt = NotebookRecoveryReceipt(
            id: UUID(), notebookID: batch.notebookID, editCount: batch.edits.count,
            savedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let directory = bundle(root: root, receiptID: receipt.id)
        let archives = directory.appendingPathComponent("archives", isDirectory: true)
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
        let references = batch.edits.map { edit in
            LegacyReference(
                id: edit.id, archiveDigest: digest(edit.drawingData), archiveBytes: edit.drawingData.count,
                strokeIDs: edit.strokeIDs, title: edit.title, pageCount: edit.pageCount, stamp: edit.stamp
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifest = try encoder.encode(LegacyManifest(
            schemaVersion: 1, receiptID: receipt.id, notebookID: receipt.notebookID,
            baseRevisionID: batch.baseRevisionID, savedAt: receipt.savedAt, edits: references
        ))
        try manifest.write(to: directory.appendingPathComponent("manifest.json"))
        try encoder.encode(LegacyReceipt(
            schemaVersion: 1, id: receipt.id, notebookID: receipt.notebookID,
            editCount: receipt.editCount, savedAt: receipt.savedAt, manifestDigest: digest(manifest)
        )).write(to: directory.appendingPathComponent("RECEIPT.json"))
        for edit in batch.edits {
            try edit.drawingData.write(to: archives.appendingPathComponent(edit.id.uuidString.lowercased() + ".drawing"))
        }
        return receipt
    }

    private struct LegacyReference: Codable {
        let id: UUID
        let archiveDigest: String
        let archiveBytes: Int
        let strokeIDs: [UUID]
        let title: String
        let pageCount: Int
        let stamp: NotebookEditStamp
    }

    private struct LegacyManifest: Codable {
        let schemaVersion: Int
        let receiptID: UUID
        let notebookID: UUID
        let baseRevisionID: UUID?
        let savedAt: Date
        let edits: [LegacyReference]
    }

    private struct LegacyReceipt: Codable {
        let schemaVersion: Int
        let id: UUID
        let notebookID: UUID
        let editCount: Int
        let savedAt: Date
        let manifestDigest: String
    }

    private func largeBatch() -> NotebookRecoveryBatch {
        let template = stroke()
        let originals = (0..<10_000).map { _ in
            var copy = template
            copy.id = UUID()
            return copy
        }
        let sessionID = UUID()
        let edits = (0..<8).map { index in
            var strokes = originals
            strokes[index].transform = CGAffineTransform(translationX: CGFloat(index + 1), y: 10)
            let drawing = PKDrawing(strokes: strokes)
            return NotebookRecoveryEdit(
                id: UUID(), drawingData: drawing.dataRepresentation(),
                strokeIDs: drawing.strokes.map(\.id),
                title: String(repeating: "t", count: 4_096), pageCount: 12,
                stamp: NotebookEditStamp(
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                    uptime: Double(index), sessionID: sessionID
                )
            )
        }
        return NotebookRecoveryBatch(notebookID: UUID(), baseRevisionID: UUID(), edits: edits)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
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
                timeOffset: Double(index) * 0.02, size: CGSize(width: 3, height: 3),
                opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
            )
        }
        return PKStroke(
            ink: PKInk(.pen, color: color),
            path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1_000))
        )
    }

    private func processPeakResidentBytes() throws -> Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            throw NotebookRepositoryError.ioFailure(errno)
        }
        return Int64(usage.ru_maxrss)
    }

    private func writeMetrics(_ metrics: [String: Any]) throws {
        guard let path = ProcessInfo.processInfo.environment["NOTTY_RECOVERY_METRICS_DIRECTORY"] else { return }
        guard !path.isEmpty else {
            throw NotebookRepositoryError.invalidContent("The recovery metrics directory is empty.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys, .prettyPrinted])
            .write(to: directory.appendingPathComponent("recovery-8-edits-10000-strokes.json"), options: .atomic)
    }
}
