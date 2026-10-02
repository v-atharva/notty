import CryptoKit
import Foundation
import XCTest
@testable import NottyCore

@MainActor
final class NotebookRepositoryTests: XCTestCase {
    func testReopenPreservesStrokeIdentityOrderAndMetadata() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let first = NotebookStroke(id: UUID(), data: Data("first".utf8))
        let second = NotebookStroke(id: UUID(), data: Data("second".utf8))
        let content = NotebookContent(title: "Mechanics", pageCount: 5, strokes: [second, first])
        let writer = try NotebookRepository(rootURL: root)
        let saved = try await writer.save(id: id, content: content, expectedRevisionID: nil)
        let reader = try NotebookRepository(rootURL: root)
        let loaded = try await requiredNotebook(reader, id: id)

        XCTAssertEqual(loaded.id, id)
        XCTAssertEqual(loaded.revisionID, saved.revisionID)
        XCTAssertEqual(loaded.sequence, 1)
        XCTAssertEqual(loaded.content, content)
        XCTAssertEqual(loaded.savedAt, saved.savedAt)
    }

    func testIdenticalAssetsAreDeduplicatedAcrossStrokeIDsAndRevisions() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let data = Data("same archive".utf8)
        let stroke = NotebookStroke(id: UUID(), data: data)
        let repository = try NotebookRepository(rootURL: root)
        let first = try await repository.save(
            id: id, content: content(strokes: [stroke]), expectedRevisionID: nil
        )
        let secondStroke = NotebookStroke(id: UUID(), data: data)
        let second = try await repository.save(
            id: id, content: content(strokes: [stroke, secondStroke]),
            expectedRevisionID: first.revisionID
        )

        XCTAssertEqual(try files(root: root, id: id, folder: "assets", extension: "stroke").count, 1)
        XCTAssertEqual(try files(root: root, id: id, folder: "revisions", extension: "json").count, 2)
        XCTAssertEqual(second.sequence, 2)
        let loaded = try await requiredNotebook(repository, id: id)
        XCTAssertEqual(loaded.content.strokes.map(\.id), [stroke.id, secondStroke.id])
    }

    func testMoveAndEraseRetainEarlierAssetsAndOrderedRevisions() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let strokeID = UUID()
        let repository = try NotebookRepository(rootURL: root)
        let original = NotebookStroke(id: strokeID, data: Data("position 1".utf8))
        let moved = NotebookStroke(id: strokeID, data: Data("position 2".utf8))
        let first = try await repository.save(
            id: id, content: content(strokes: [original]), expectedRevisionID: nil
        )
        let second = try await repository.save(
            id: id, content: content(strokes: [moved]), expectedRevisionID: first.revisionID
        )
        let third = try await repository.save(
            id: id, content: content(strokes: []), expectedRevisionID: second.revisionID
        )

        XCTAssertEqual(third.sequence, 3)
        XCTAssertEqual(try files(root: root, id: id, folder: "assets", extension: "stroke").count, 2)
        XCTAssertEqual(try files(root: root, id: id, folder: "revisions", extension: "json").count, 3)
        let firstManifest = try object(at: revisionURL(root: root, id: id, revision: first.revisionID))
        let secondManifest = try object(at: revisionURL(root: root, id: id, revision: second.revisionID))
        let thirdManifest = try object(at: revisionURL(root: root, id: id, revision: third.revisionID))
        let firstReference = try XCTUnwrap((firstManifest["strokes"] as? [[String: Any]])?.first)
        let secondReference = try XCTUnwrap((secondManifest["strokes"] as? [[String: Any]])?.first)
        XCTAssertEqual(firstReference["id"] as? String, secondReference["id"] as? String)
        XCTAssertNotEqual(firstReference["digest"] as? String, secondReference["digest"] as? String)
        XCTAssertEqual(secondManifest["parentRevisionID"] as? String, first.revisionID.uuidString)
        XCTAssertEqual(thirdManifest["parentRevisionID"] as? String, second.revisionID.uuidString)
        let loaded = try await requiredNotebook(repository, id: id)
        XCTAssertTrue(loaded.content.strokes.isEmpty)
    }

    func testStaleWriterCannotReplaceANewerHead() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let firstWriter = try NotebookRepository(rootURL: root)
        let secondWriter = try NotebookRepository(rootURL: root)
        let first = try await firstWriter.save(id: id, content: content(), expectedRevisionID: nil)
        let second = try await firstWriter.save(
            id: id, content: content(title: "Newer"), expectedRevisionID: first.revisionID
        )
        do {
            _ = try await secondWriter.save(
                id: id, content: content(title: "Stale"), expectedRevisionID: first.revisionID
            )
            XCTFail("A stale revision was accepted.")
        } catch {
            XCTAssertEqual(error as? NotebookRepositoryError, .revisionConflict)
        }
        do {
            _ = try await secondWriter.save(id: id, content: content(), expectedRevisionID: nil)
            XCTFail("A creation request replaced an existing notebook.")
        } catch {
            XCTAssertEqual(error as? NotebookRepositoryError, .revisionConflict)
        }
        let loaded = try await requiredNotebook(firstWriter, id: id)
        XCTAssertEqual(loaded.revisionID, second.revisionID)
        XCTAssertEqual(loaded.content.title, "Newer")
    }

    func testEveryPrepublicationFaultPreservesThePreviousHeadAndAllowsRetry() async throws {
        for target in NotebookWriteStage.allCases {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let id = UUID()
            let healthy = try NotebookRepository(rootURL: root)
            let first = try await healthy.save(
                id: id,
                content: content(strokes: [NotebookStroke(id: UUID(), data: Data("before".utf8))]),
                expectedRevisionID: nil
            )
            let next = content(
                title: "After",
                strokes: [NotebookStroke(id: UUID(), data: Data("after".utf8))]
            )
            let faulty = try NotebookRepository(rootURL: root) { stage in
                if stage == target { throw InjectedFailure.stop }
            }
            do {
                _ = try await faulty.save(id: id, content: next, expectedRevisionID: first.revisionID)
                XCTFail("Publication fault \(target) did not interrupt the save.")
            } catch {
                XCTAssertTrue(error is InjectedFailure)
            }
            let reopened = try NotebookRepository(rootURL: root)
            let old = try await requiredNotebook(reopened, id: id)
            XCTAssertEqual(old.revisionID, first.revisionID, "Fault: \(target)")
            XCTAssertEqual(old.content, first.content, "Fault: \(target)")
            let retried = try await reopened.save(
                id: id, content: next, expectedRevisionID: first.revisionID
            )
            XCTAssertEqual(retried.sequence, 2)
            let latest = try await requiredNotebook(reopened, id: id)
            XCTAssertEqual(latest.content, next)
        }
    }

    func testFailedFirstPublicationRemainsAbsentDespiteOrphanRevisions() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let faulty = try NotebookRepository(rootURL: root) { stage in
            if stage == .beforeHeadPublication { throw InjectedFailure.stop }
        }
        do {
            _ = try await faulty.save(id: id, content: content(), expectedRevisionID: nil)
            XCTFail("The injected failure did not occur.")
        } catch {
            XCTAssertTrue(error is InjectedFailure)
        }
        let reopened = try NotebookRepository(rootURL: root)
        let absent = try await reopened.load(id: id)
        XCTAssertNil(absent)
        XCTAssertEqual(try files(root: root, id: id, folder: "revisions", extension: "json").count, 1)
        let saved = try await reopened.save(id: id, content: content(), expectedRevisionID: nil)
        XCTAssertEqual(saved.sequence, 1)
    }

    func testUnreferencedDamagedFilesDoNotChangeTheCommittedNotebook() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let repository = try NotebookRepository(rootURL: root)
        let saved = try await repository.save(id: id, content: content(), expectedRevisionID: nil)
        try Data("unpublished".utf8).write(
            to: revisionURL(root: root, id: id, revision: UUID())
        )
        try Data("incomplete".utf8).write(
            to: noteURL(root: root, id: id).appendingPathComponent(".head-orphan.tmp")
        )
        let loaded = try await requiredNotebook(repository, id: id)
        XCTAssertEqual(loaded.revisionID, saved.revisionID)
    }

    func testCommittedHeadRevisionAndAssetCorruptionNeverBecomeAnEmptyNotebook() async throws {
        for damaged in ["head", "revision", "asset"] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let id = UUID()
            let stroke = NotebookStroke(id: UUID(), data: Data("archive".utf8))
            let repository = try NotebookRepository(rootURL: root)
            let saved = try await repository.save(
                id: id, content: content(strokes: [stroke]), expectedRevisionID: nil
            )
            let url: URL
            switch damaged {
            case "head":
                url = noteURL(root: root, id: id).appendingPathComponent("HEAD.json")
            case "revision":
                url = revisionURL(root: root, id: id, revision: saved.revisionID)
            default:
                url = try XCTUnwrap(files(root: root, id: id, folder: "assets", extension: "stroke").first)
            }
            try Data("damaged".utf8).write(to: url)
            do {
                _ = try await repository.load(id: id)
                XCTFail("Corrupted \(damaged) was accepted.")
            } catch {
                guard case .corruptData? = error as? NotebookRepositoryError else {
                    return XCTFail("Unexpected error for \(damaged): \(error)")
                }
            }
            do {
                _ = try await repository.save(
                    id: id, content: content(strokes: []), expectedRevisionID: saved.revisionID
                )
                XCTFail("Corrupted \(damaged) was silently overwritten.")
            } catch {
                XCTAssertNotNil(error as? NotebookRepositoryError)
            }
        }
    }

    func testUnknownHeadAndRevisionVersionsAreRejected() async throws {
        for location in ["head", "revision"] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let id = UUID()
            let repository = try NotebookRepository(rootURL: root)
            let saved = try await repository.save(id: id, content: content(), expectedRevisionID: nil)
            if location == "head" {
                let headURL = noteURL(root: root, id: id).appendingPathComponent("HEAD.json")
                var head = try object(at: headURL)
                head["schemaVersion"] = 99
                try writeObject(head, to: headURL)
            } else {
                try modifyRevision(root: root, id: id, revision: saved.revisionID) {
                    $0["schemaVersion"] = 99
                }
            }
            do {
                _ = try await repository.load(id: id)
                XCTFail("An unsupported \(location) schema was accepted.")
            } catch {
                XCTAssertEqual(error as? NotebookRepositoryError, .unsupportedVersion(99))
            }
        }
    }

    func testDigestPathAndNotebookIdentityMustMatchTheCommittedManifest() async throws {
        for mutation in ["digest", "identity", "duplicates"] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let id = UUID()
            let repository = try NotebookRepository(rootURL: root)
            let saved = try await repository.save(
                id: id,
                content: content(strokes: [NotebookStroke(id: UUID(), data: Data("archive".utf8))]),
                expectedRevisionID: nil
            )
            try modifyRevision(root: root, id: id, revision: saved.revisionID) { manifest in
                if mutation == "identity" {
                    manifest["notebookID"] = UUID().uuidString
                } else {
                    var references = manifest["strokes"] as! [[String: Any]]
                    if mutation == "digest" {
                        references[0]["digest"] = "../../outside"
                    } else {
                        references.append(references[0])
                    }
                    manifest["strokes"] = references
                }
            }
            do {
                _ = try await repository.load(id: id)
                XCTFail("Invalid manifest \(mutation) was accepted.")
            } catch {
                guard case .corruptData? = error as? NotebookRepositoryError else {
                    return XCTFail("Unexpected manifest error: \(error)")
                }
            }
        }
    }

    func testSymbolicLinksAtRootHeadAssetAndRevisionDirectoryAreRejected() async throws {
        let parent = try makeRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let target = parent.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let link = parent.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try NotebookRepository(rootURL: link)) {
            guard case .unsafePath? = $0 as? NotebookRepositoryError else {
                return XCTFail("Unexpected root link error: \($0)")
            }
        }

        for location in ["head", "asset", "revisions"] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let id = UUID()
            let repository = try NotebookRepository(rootURL: root)
            _ = try await repository.save(
                id: id,
                content: content(strokes: [NotebookStroke(id: UUID(), data: Data("archive".utf8))]),
                expectedRevisionID: nil
            )
            let original: URL
            switch location {
            case "head":
                original = noteURL(root: root, id: id).appendingPathComponent("HEAD.json")
            case "asset":
                original = try XCTUnwrap(files(root: root, id: id, folder: "assets", extension: "stroke").first)
            default:
                original = noteURL(root: root, id: id).appendingPathComponent("revisions", isDirectory: true)
            }
            let moved = root.appendingPathComponent("moved")
            try FileManager.default.moveItem(at: original, to: moved)
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: moved)
            do {
                _ = try await repository.load(id: id)
                XCTFail("A symbolic link at \(location) was accepted.")
            } catch {
                guard case .unsafePath? = error as? NotebookRepositoryError else {
                    return XCTFail("Unexpected link error: \(error)")
                }
            }
        }
    }

    func testContentBoundsRejectInvalidCountsDuplicateIDsAndOversizedAssets() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NotebookRepository(rootURL: root)
        let duplicate = NotebookStroke(id: UUID(), data: Data())
        let oversized = NotebookStroke(
            id: UUID(),
            data: Data(repeating: 0, count: NotebookRepository.maximumAssetBytes + 1)
        )
        let sharedLargeData = Data(repeating: 0, count: NotebookRepository.maximumAssetBytes)
        let excessiveAggregate = (0..<7).map { _ in
            NotebookStroke(id: UUID(), data: sharedLargeData)
        }
        let tooManyStrokes = (0...NotebookRepository.maximumStrokeCount).map { _ in
            NotebookStroke(id: UUID(), data: Data())
        }
        let invalid = [
            NotebookContent(title: "Invalid", pageCount: 0, strokes: []),
            NotebookContent(title: "Invalid", pageCount: 13, strokes: []),
            content(strokes: [duplicate, duplicate]),
            content(strokes: [oversized]),
            content(strokes: excessiveAggregate),
            content(strokes: tooManyStrokes),
            content(title: String(repeating: "x", count: NotebookRepository.maximumTitleBytes + 1))
        ]
        for item in invalid {
            do {
                _ = try await repository.save(id: UUID(), content: item, expectedRevisionID: nil)
                XCTFail("Invalid content was accepted.")
            } catch {
                XCTAssertNotNil(error as? NotebookRepositoryError)
            }
        }
    }

    func testOversizedMetadataIsRejectedBeforeDecoding() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let repository = try NotebookRepository(rootURL: root)
        _ = try await repository.save(id: id, content: content(), expectedRevisionID: nil)
        try Data(repeating: 0, count: NotebookRepository.maximumMetadataBytes + 1).write(
            to: noteURL(root: root, id: id).appendingPathComponent("HEAD.json")
        )
        do {
            _ = try await repository.load(id: id)
            XCTFail("Oversized metadata was accepted.")
        } catch {
            guard case .sizeLimitExceeded? = error as? NotebookRepositoryError else {
                return XCTFail("Unexpected metadata error: \(error)")
            }
        }
    }

    func testEditCaptureStampRoundTripsSeparatelyFromSaveReceipt() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let stamp = NotebookEditStamp(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            uptime: 1_234.5,
            sessionID: UUID()
        )
        let item = NotebookContent(
            title: "Timed edit", pageCount: 2, strokes: [], editStamp: stamp
        )
        let writer = try NotebookRepository(rootURL: root)
        let saved = try await writer.save(id: id, content: item, expectedRevisionID: nil)
        let reader = try NotebookRepository(rootURL: root)
        let loaded = try await requiredNotebook(reader, id: id)
        XCTAssertEqual(loaded.content.editStamp, stamp)
        XCTAssertGreaterThan(saved.savedAt, stamp.capturedAt)
    }

    func testInvalidEditCaptureTimesAreRejected() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NotebookRepository(rootURL: root)
        let stamps = [
            NotebookEditStamp(capturedAt: Date(), uptime: -1, sessionID: UUID()),
            NotebookEditStamp(capturedAt: Date(), uptime: .infinity, sessionID: UUID()),
            NotebookEditStamp(
                capturedAt: Date(timeIntervalSinceReferenceDate: .nan),
                uptime: 0,
                sessionID: UUID()
            )
        ]
        for stamp in stamps {
            do {
                _ = try await repository.save(
                    id: UUID(),
                    content: NotebookContent(title: "Invalid", pageCount: 1, strokes: [], editStamp: stamp),
                    expectedRevisionID: nil
                )
                XCTFail("Invalid capture timing was accepted.")
            } catch {
                guard case .invalidContent? = error as? NotebookRepositoryError else {
                    return XCTFail("Unexpected timestamp error: \(error)")
                }
            }
        }
    }

    private func requiredNotebook(
        _ repository: NotebookRepository,
        id: UUID
    ) async throws -> StoredNotebook {
        let stored = try await repository.load(id: id)
        return try XCTUnwrap(stored)
    }

    private enum InjectedFailure: Error {
        case stop
    }

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func content(
        title: String = "Notebook",
        strokes: [NotebookStroke] = []
    ) -> NotebookContent {
        NotebookContent(title: title, pageCount: 3, strokes: strokes)
    }

    private func noteURL(root: URL, id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    private func revisionURL(root: URL, id: UUID, revision: UUID) -> URL {
        noteURL(root: root, id: id).appendingPathComponent("revisions", isDirectory: true)
            .appendingPathComponent("\(revision.uuidString.lowercased()).json")
    }

    private func files(
        root: URL,
        id: UUID,
        folder: String,
        extension suffix: String
    ) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: noteURL(root: root, id: id).appendingPathComponent(folder, isDirectory: true),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == suffix }
    }

    private func object(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func writeObject(_ value: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url)
    }

    private func modifyRevision(
        root: URL,
        id: UUID,
        revision: UUID,
        mutation: (inout [String: Any]) -> Void
    ) throws {
        let revisionURL = revisionURL(root: root, id: id, revision: revision)
        var manifest = try object(at: revisionURL)
        mutation(&manifest)
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try data.write(to: revisionURL)
        let headURL = noteURL(root: root, id: id).appendingPathComponent("HEAD.json")
        var head = try object(at: headURL)
        head["revisionDigest"] = SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
        try writeObject(head, to: headURL)
    }
}
