import CryptoKit
import Foundation
import PencilKit
import Darwin
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
        XCTAssertEqual(try files(root: root, id: id, folder: "events", extension: "json").count, 2)
        XCTAssertEqual(second.sequence, 2)
        let loaded = try await requiredNotebook(repository, id: id)
        XCTAssertEqual(loaded.content.strokes.map(\.id), [stroke.id, secondStroke.id])
    }

    func testSaveVerifiesEachCommittedDigestOnceWithoutRereadingUnchangedAssets() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let shared = Data("unchanged".utf8)
        let retained = NotebookStroke(id: UUID(), data: shared)
        let duplicateArchive = NotebookStroke(id: UUID(), data: shared)
        let removed = NotebookStroke(id: UUID(), data: Data("removed".utf8))
        let initial = try NotebookRepository(rootURL: root)
        let first = try await initial.save(
            id: id,
            content: content(strokes: [retained, duplicateArchive, removed]),
            expectedRevisionID: nil
        )
        let counter = NotebookAssetVerificationCounter()
        let repository = try NotebookRepository(
            rootURL: root, assetVerificationObserver: { counter.record($0) }
        )
        let added = NotebookStroke(id: UUID(), data: Data("new archive".utf8))
        let next = content(strokes: [retained, duplicateArchive, added])
        let second = try await repository.save(
            id: id, content: next, expectedRevisionID: first.revisionID
        )

        let counts = counter.snapshot()
        XCTAssertEqual(counts.count, 2)
        XCTAssertTrue(counts.values.allSatisfy { $0 == 1 })
        XCTAssertEqual(counts[digest(shared)], 1)
        XCTAssertEqual(counts[digest(removed.data)], 1)
        XCTAssertNil(counts[digest(added.data)])
        counter.reset()
        _ = try await repository.save(
            id: id, content: next, expectedRevisionID: second.revisionID
        )
        XCTAssertTrue(counter.snapshot().isEmpty)
    }

    func testUnpublishedExistingDigestIsVerifiedOnceWhenSeveralStrokesReuseIt() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let data = Data("unpublished archive".utf8)
        let stroke = NotebookStroke(id: UUID(), data: data)
        let originalRepository = try NotebookRepository(rootURL: root)
        let committed = try await originalRepository.save(
            id: id, content: content(), expectedRevisionID: nil
        )
        let faulty = try NotebookRepository(rootURL: root, faultInjector: { stage in
            if stage == .revisionStaged { throw InjectedFailure.stop }
        })
        do {
            _ = try await faulty.save(
                id: id, content: content(strokes: [stroke]), expectedRevisionID: committed.revisionID
            )
            XCTFail("The injected fault did not occur.")
        } catch {
            XCTAssertTrue(error is InjectedFailure)
        }
        let counter = NotebookAssetVerificationCounter()
        let repository = try NotebookRepository(
            rootURL: root, assetVerificationObserver: { counter.record($0) }
        )
        _ = try await repository.save(
            id: id,
            content: content(strokes: [
                stroke, NotebookStroke(id: UUID(), data: data)
            ]),
            expectedRevisionID: committed.revisionID
        )
        XCTAssertEqual(counter.snapshot(), [digest(data): 1])
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
        XCTAssertEqual(try files(root: root, id: id, folder: "events", extension: "json").count, 3)
        let firstManifest = try object(at: revisionURL(root: root, id: id, revision: first.revisionID))
        let secondManifest = try object(at: revisionURL(root: root, id: id, revision: second.revisionID))
        let thirdManifest = try object(at: revisionURL(root: root, id: id, revision: third.revisionID))
        let firstReference = try XCTUnwrap(((firstManifest["delta"] as? [String: Any])?["upserts"] as? [[String: Any]])?.first)
        let secondReference = try XCTUnwrap(((secondManifest["delta"] as? [String: Any])?["upserts"] as? [[String: Any]])?.first)
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

    func testConcurrentCreationAcrossRepositoriesPublishesExactlyOneHead() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let firstRepository = try NotebookRepository(rootURL: root)
        let secondRepository = try NotebookRepository(rootURL: root)
        async let first = Self.tryCreation(firstRepository, id: id)
        async let second = Self.tryCreation(secondRepository, id: id)
        let (firstSucceeded, secondSucceeded) = try await (first, second)

        XCTAssertNotEqual(firstSucceeded, secondSucceeded)
        let loaded = try await requiredNotebook(firstRepository, id: id)
        XCTAssertEqual(loaded.sequence, 1)
        XCTAssertEqual(try files(root: root, id: id, folder: "events", extension: "json").count, 1)
    }

    func testEveryPrepublicationFaultPreservesThePreviousHeadAndAllowsRetry() async throws {
        for target in NotebookWriteStage.allCases.filter({ $0 != .beforeNotebookPublication }) {
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
            let faulty = try NotebookRepository(rootURL: root, faultInjector: { stage in
                if stage == target { throw InjectedFailure.stop }
            })
            do {
                _ = try await faulty.save(id: id, content: next, expectedRevisionID: first.revisionID)
                XCTFail("Publication fault \(target) did not interrupt the save.")
            } catch {
                XCTAssertTrue(error is InjectedFailure)
            }
            XCTAssertFalse(
                try fileSnapshot(root: noteURL(root: root, id: id)).keys.contains { $0.hasSuffix(".tmp") }
            )
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

    func testEveryFirstCreationFaultLeavesNoPublishedNotebookAndAllowsRetry() async throws {
        for target in NotebookWriteStage.allCases {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let id = UUID()
            let item = content(strokes: [NotebookStroke(id: UUID(), data: Data("new archive".utf8))])
            let faulty = try NotebookRepository(rootURL: root, faultInjector: { stage in
                if stage == target { throw InjectedFailure.stop }
            })
            do {
                _ = try await faulty.save(id: id, content: item, expectedRevisionID: nil)
                XCTFail("Creation fault \(target) did not interrupt publication.")
            } catch {
                XCTAssertTrue(error is InjectedFailure)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: noteURL(root: root, id: id).path))
            let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
            XCTAssertFalse(entries.contains { $0.hasPrefix(".creation-") })
            let reopened = try NotebookRepository(rootURL: root)
            let absent = try await reopened.load(id: id)
            XCTAssertNil(absent)
            let saved = try await reopened.save(id: id, content: item, expectedRevisionID: nil)
            XCTAssertEqual(saved.sequence, 1)
            XCTAssertEqual(saved.content, item)
        }
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
                url = try revisionURL(root: root, id: id, revision: saved.revisionID)
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
                    var delta = manifest["delta"] as! [String: Any]
                    var references = delta["upserts"] as! [[String: Any]]
                    if mutation == "digest" {
                        references[0]["digest"] = "../../outside"
                    } else {
                        references.append(references[0])
                    }
                    delta["upserts"] = references
                    manifest["delta"] = delta
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

    func testRootReplacedBySymbolicLinkAfterInitializationRejectsReadsAndWrites() async throws {
        let root = try makeRoot().resolvingSymlinksInPath()
        let alternateRoot = try makeRoot().resolvingSymlinksInPath()
        let movedRoot = root.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: movedRoot)
            try? FileManager.default.removeItem(at: alternateRoot)
        }

        let id = UUID()
        let originalRepository = try NotebookRepository(rootURL: root)
        let original = try await originalRepository.save(
            id: id,
            content: content(
                title: "Original",
                strokes: [NotebookStroke(id: UUID(), data: Data("original archive".utf8))]
            ),
            expectedRevisionID: nil
        )
        let alternateRepository = try NotebookRepository(rootURL: alternateRoot)
        let alternate = try await alternateRepository.save(
            id: id,
            content: content(
                title: "Alternate",
                strokes: [NotebookStroke(id: UUID(), data: Data("alternate archive".utf8))]
            ),
            expectedRevisionID: nil
        )

        try FileManager.default.moveItem(at: root, to: movedRoot)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: alternateRoot)
        let originalFiles = try fileSnapshot(root: movedRoot)
        let alternateFiles = try fileSnapshot(root: alternateRoot)

        do {
            _ = try await originalRepository.load(id: id)
            XCTFail("A replaced storage root was followed while loading.")
        } catch {
            guard case .unsafePath? = error as? NotebookRepositoryError else {
                return XCTFail("Unexpected replaced-root load error: \(error)")
            }
        }
        do {
            _ = try await originalRepository.save(
                id: id,
                content: content(
                    title: "Unwanted write",
                    strokes: [NotebookStroke(id: UUID(), data: Data("unwanted archive".utf8))]
                ),
                expectedRevisionID: original.revisionID
            )
            XCTFail("A replaced storage root was followed while saving.")
        } catch {
            guard case .unsafePath? = error as? NotebookRepositoryError else {
                return XCTFail("Unexpected replaced-root save error: \(error)")
            }
        }

        XCTAssertEqual(try fileSnapshot(root: movedRoot), originalFiles)
        XCTAssertEqual(try fileSnapshot(root: alternateRoot), alternateFiles)
        let movedRepository = try NotebookRepository(rootURL: movedRoot)
        let recoveredOriginal = try await requiredNotebook(movedRepository, id: id)
        let preservedAlternate = try await requiredNotebook(alternateRepository, id: id)
        XCTAssertEqual(recoveredOriginal.revisionID, original.revisionID)
        XCTAssertEqual(recoveredOriginal.content, original.content)
        XCTAssertEqual(preservedAlternate.revisionID, alternate.revisionID)
        XCTAssertEqual(preservedAlternate.content, alternate.content)
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

        for location in ["head", "asset", "events"] {
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
                original = try eventsURL(root: root, id: id)
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

    func testCorruptedUnpublishedAssetIsRepairedDuringRetry() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let stroke = NotebookStroke(id: UUID(), data: Data("archive".utf8))
        let originalRepository = try NotebookRepository(rootURL: root)
        let committed = try await originalRepository.save(
            id: id, content: content(), expectedRevisionID: nil
        )
        let faulty = try NotebookRepository(rootURL: root, faultInjector: { stage in
            if stage == .assetPublished { throw InjectedFailure.stop }
        })
        do {
            _ = try await faulty.save(
                id: id, content: content(strokes: [stroke]), expectedRevisionID: committed.revisionID
            )
            XCTFail("The injected failure did not occur.")
        } catch {
            XCTAssertTrue(error is InjectedFailure)
        }
        let asset = try XCTUnwrap(
            files(root: root, id: id, folder: "assets", extension: "stroke").first
        )
        try Data("tampered".utf8).write(to: asset)
        let healthy = try NotebookRepository(rootURL: root)
        let repaired = try await healthy.save(
            id: id, content: content(strokes: [stroke]), expectedRevisionID: committed.revisionID
        )
        XCTAssertEqual(try Data(contentsOf: asset), stroke.data)
        let loaded = try await requiredNotebook(healthy, id: id)
        XCTAssertEqual(loaded.revisionID, repaired.revisionID)
        XCTAssertEqual(loaded.content.strokes, [stroke])
        let history = try await healthy.auditHistory(id: id)
        XCTAssertEqual(history.revisionCount, 2)
        let report = await healthy.maintenanceReport()
        XCTAssertEqual(report[.repairedAsset], 1)
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
            guard case .corruptData? = error as? NotebookRepositoryError else {
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

    func testMissingCommittedHeadRequiresRecoveryAndPreservesAllOriginalFiles() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let repository = try NotebookRepository(rootURL: root)
        let saved = try await repository.save(
            id: id,
            content: content(strokes: [NotebookStroke(id: UUID(), data: Data("original".utf8))]),
            expectedRevisionID: nil
        )
        let directory = noteURL(root: root, id: id)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("HEAD.json"))
        let before = try fileSnapshot(root: directory)
        do {
            _ = try await repository.load(id: id)
            XCTFail("Missing publication metadata became an absent notebook.")
        } catch {
            XCTAssertEqual(error as? NotebookRepositoryError, .recoveryRequired)
        }
        for expectedRevision in [nil, saved.revisionID] {
            do {
                _ = try await repository.save(
                    id: id, content: content(title: "Blank replacement"),
                    expectedRevisionID: expectedRevision
                )
                XCTFail("Missing publication metadata allowed replacement.")
            } catch {
                XCTAssertEqual(error as? NotebookRepositoryError, .recoveryRequired)
            }
        }
        XCTAssertEqual(try fileSnapshot(root: directory), before)
    }

    func testLegacyNoHeadResidueFailsClosedRatherThanPromotingARevision() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let directory = noteURL(root: root, id: id)
        let revisions = directory.appendingPathComponent("revisions", isDirectory: true)
        try FileManager.default.createDirectory(at: revisions, withIntermediateDirectories: true)
        try Data("legacy or unpublished revision".utf8).write(
            to: revisions.appendingPathComponent("\(UUID().uuidString.lowercased()).json")
        )
        let repository = try NotebookRepository(rootURL: root)
        let before = try fileSnapshot(root: directory)
        do {
            _ = try await repository.load(id: id)
            XCTFail("Ambiguous legacy residue became an empty notebook.")
        } catch {
            XCTAssertEqual(error as? NotebookRepositoryError, .recoveryRequired)
        }
        do {
            _ = try await repository.save(id: id, content: content(), expectedRevisionID: nil)
            XCTFail("Ambiguous legacy residue was overwritten.")
        } catch {
            XCTAssertEqual(error as? NotebookRepositoryError, .recoveryRequired)
        }
        XCTAssertEqual(try fileSnapshot(root: directory), before)
    }

    func testReopenSweepsPrivateCreationResidueWithoutPromotingIt() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceID = UUID()
        let repository = try NotebookRepository(rootURL: root)
        let source = try await repository.save(id: sourceID, content: content(), expectedRevisionID: nil)
        let privateCopy = root.appendingPathComponent(
            ".creation-\(UUID().uuidString.lowercased())", isDirectory: true
        )
        try FileManager.default.copyItem(
            at: noteURL(root: root, id: sourceID), to: privateCopy
        )
        let before = try fileSnapshot(root: noteURL(root: root, id: sourceID))
        let unrelated = root.appendingPathComponent(".creation-not-a-uuid", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        let reopened = try NotebookRepository(rootURL: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: privateCopy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        let absent = try await reopened.load(id: UUID())
        XCTAssertNil(absent)
        let loaded = try await requiredNotebook(reopened, id: sourceID)
        XCTAssertEqual(loaded.revisionID, source.revisionID)
        XCTAssertEqual(try fileSnapshot(root: noteURL(root: root, id: sourceID)), before)
    }

    func testCommittedOpenSweepsOnlyOwnedRegularStageNames() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let repository = try NotebookRepository(rootURL: root)
        let saved = try await repository.save(id: id, content: content(), expectedRevisionID: nil)
        let directory = noteURL(root: root, id: id)
        let owned = [
            directory.appendingPathComponent(".head-\(UUID().uuidString).tmp"),
            directory.appendingPathComponent("assets/.\(UUID().uuidString).tmp"),
            try eventsURL(root: root, id: id).appendingPathComponent(".\(UUID().uuidString).tmp")
        ]
        for stage in owned { try Data("process residue".utf8).write(to: stage) }
        let unrelated = directory.appendingPathComponent("notes.tmp")
        try Data("unrelated".utf8).write(to: unrelated)
        let reopened = try NotebookRepository(rootURL: root)
        let loaded = try await requiredNotebook(reopened, id: id)

        XCTAssertEqual(loaded.revisionID, saved.revisionID)
        for stage in owned { XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path)) }
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("unrelated".utf8))
    }

    func testPartialStageWriteIsRemovedWhenWritingThrows() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stage = root.appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try NotebookFileSystem.writeSynchronized(Data("complete data".utf8), to: stage) { handle, data in
                try handle.write(contentsOf: Data(data.prefix(2)))
                throw InjectedFailure.stop
            }
            XCTFail("The partial write did not fail.")
        } catch {
            XCTAssertTrue(error is InjectedFailure)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
    }

    func testUnsafeStageAndPrivateTransactionLinksAreNotFollowed() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let repository = try NotebookRepository(rootURL: root)
        let saved = try await repository.save(id: id, content: content(), expectedRevisionID: nil)
        let outside = root.appendingPathComponent("outside")
        try Data("untouched".utf8).write(to: outside)
        let stage = noteURL(root: root, id: id).appendingPathComponent(".head-\(UUID().uuidString).tmp")
        try FileManager.default.createSymbolicLink(at: stage, withDestinationURL: outside)
        let counter = NotebookMaintenanceCounter()
        let reader = try NotebookRepository(
            rootURL: root, maintenanceObserver: { counter.record($0) }
        )
        counter.reset()
        let loaded = try await requiredNotebook(reader, id: id)
        XCTAssertEqual(loaded.revisionID, saved.revisionID)
        XCTAssertEqual(loaded.content, saved.content)
        XCTAssertEqual(counter.count(.skippedNonRegularStage), 1)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: stage.path), outside.path)
        XCTAssertEqual(try Data(contentsOf: outside), Data("untouched".utf8))
        try FileManager.default.removeItem(at: stage)
        let transaction = root.appendingPathComponent(".creation-\(UUID().uuidString.lowercased())")
        try FileManager.default.createSymbolicLink(at: transaction, withDestinationURL: outside)
        let tolerant = try NotebookRepository(rootURL: root)
        let reopened = try await requiredNotebook(tolerant, id: id)
        XCTAssertEqual(reopened.revisionID, saved.revisionID)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: transaction.path), outside.path)
        let report = await tolerant.maintenanceReport()
        XCTAssertEqual(report[.failed(.unsafePath)], 1)
        XCTAssertEqual(try Data(contentsOf: outside), Data("untouched".utf8))
    }

    func testStrayStageDirectoryDoesNotBlockVerifiedNotebookLoad() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let first = NotebookStroke(id: UUID(), data: Data("original ink".utf8))
        let second = NotebookStroke(id: UUID(), data: Data("later ink".utf8))
        let writer = try NotebookRepository(rootURL: root)
        let initial = try await writer.save(
            id: id, content: content(strokes: [first]), expectedRevisionID: nil
        )
        let expected = NotebookContent(
            title: "Healthy notebook", pageCount: 5, strokes: [second, first],
            editStamp: NotebookEditStamp(
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                uptime: 123, sessionID: UUID()
            )
        )
        let saved = try await writer.save(
            id: id, content: expected, expectedRevisionID: initial.revisionID
        )
        let directory = noteURL(root: root, id: id)
        let stray = directory.appendingPathComponent("assets/.\(UUID().uuidString).tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: false)
        let child = stray.appendingPathComponent("retained")
        try Data("directory contents".utf8).write(to: child)
        let before = try fileSnapshot(root: directory)
        let reader = try NotebookRepository(rootURL: root)

        let loaded = try await requiredNotebook(reader, id: id)

        XCTAssertEqual(loaded.id, id)
        XCTAssertEqual(loaded.revisionID, saved.revisionID)
        XCTAssertEqual(loaded.sequence, saved.sequence)
        XCTAssertEqual(loaded.savedAt, saved.savedAt)
        XCTAssertEqual(loaded.content, expected)
        XCTAssertEqual(try fileSnapshot(root: directory), before)
        XCTAssertEqual(try NotebookFileSystem.kind(stray), .directory)
        XCTAssertEqual(try Data(contentsOf: child), Data("directory contents".utf8))
        let report = await reader.maintenanceReport()
        XCTAssertEqual(report[.skippedNonRegularStage], 1)
        XCTAssertEqual(report[.directoryEnumeration(.library)], 1)
        XCTAssertNil(report[.failed(.io)])
    }

    func testSecondConsecutiveCleanSavePerformsNoMaintenanceEnumeration() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let stroke = NotebookStroke(id: UUID(), data: Data("kept".utf8))
        let baseline = try await NotebookRepository(rootURL: root).save(
            id: id, content: content(strokes: [stroke]), expectedRevisionID: nil
        )
        let counter = NotebookMaintenanceCounter()
        let repository = try NotebookRepository(
            rootURL: root, maintenanceObserver: { counter.record($0) }
        )
        XCTAssertEqual(counter.count(.directoryEnumeration(.library)), 1)
        counter.reset()
        let first = try await repository.save(
            id: id, content: content(title: "First", strokes: [stroke]),
            expectedRevisionID: baseline.revisionID
        )
        XCTAssertEqual(counter.enumerationCount, 5)
        XCTAssertEqual(counter.count(.directoryEnumeration(.library)), 0)
        counter.reset()

        let second = try await repository.save(
            id: id, content: content(title: "Second", strokes: [stroke]),
            expectedRevisionID: first.revisionID
        )

        XCTAssertEqual(counter.enumerationCount, 0)
        XCTAssertTrue(counter.snapshot().isEmpty)
        let reopened = try await requiredNotebook(NotebookRepository(rootURL: root), id: id)
        XCTAssertEqual(reopened.revisionID, second.revisionID)
        XCTAssertEqual(reopened.content, second.content)
    }

    func testMaintenanceAdmissionIsIndependentForEachNotebook() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let idA = UUID()
        let idB = UUID()
        let writer = try NotebookRepository(rootURL: root)
        let savedA = try await writer.save(
            id: idA, content: content(title: "A"), expectedRevisionID: nil
        )
        let savedB = try await writer.save(
            id: idB, content: content(title: "B"), expectedRevisionID: nil
        )
        let stageA = noteURL(root: root, id: idA).appendingPathComponent("assets/.\(UUID().uuidString).tmp")
        let stageB = try eventsURL(root: root, id: idB).appendingPathComponent(".\(UUID().uuidString).tmp")
        try Data("left A".utf8).write(to: stageA)
        try Data("left B".utf8).write(to: stageB)
        let counter = NotebookMaintenanceCounter()
        let repository = try NotebookRepository(
            rootURL: root, maintenanceObserver: { counter.record($0) }
        )
        counter.reset()
        let loadedA = try await requiredNotebook(repository, id: idA)
        XCTAssertEqual(loadedA.content, savedA.content)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stageA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stageB.path))
        XCTAssertEqual(counter.enumerationCount, 5)
        counter.reset()

        let updatedB = try await repository.save(
            id: idB, content: content(title: "Updated B"), expectedRevisionID: savedB.revisionID
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: stageB.path))
        XCTAssertEqual(counter.enumerationCount, 5)
        XCTAssertEqual(counter.count(.removedStage), 1)
        counter.reset()
        _ = try await repository.save(
            id: idB, content: content(title: "Clean B"), expectedRevisionID: updatedB.revisionID
        )
        XCTAssertEqual(counter.enumerationCount, 0)
        let unchangedA = try await requiredNotebook(repository, id: idA)
        XCTAssertEqual(unchangedA.revisionID, savedA.revisionID)
        XCTAssertEqual(unchangedA.content, savedA.content)
    }

    func testFailedSaveRearmsNoteAndPrivateCreationMaintenance() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let stroke = NotebookStroke(id: UUID(), data: Data("committed ink".utf8))
        let baseline = try await NotebookRepository(rootURL: root).save(
            id: id, content: content(strokes: [stroke]), expectedRevisionID: nil
        )
        let fault = NotebookMaintenanceFaultBudget(failures: 1)
        let counter = NotebookMaintenanceCounter()
        let repository = try NotebookRepository(
            rootURL: root,
            faultInjector: { stage in
                if stage == .beforeHeadPublication { try fault.failIfNeeded() }
            },
            maintenanceObserver: { counter.record($0) }
        )
        _ = try await requiredNotebook(repository, id: id)
        counter.reset()
        do {
            _ = try await repository.save(
                id: id, content: content(title: "Waiting", strokes: [stroke]),
                expectedRevisionID: baseline.revisionID
            )
            XCTFail("The publication fault did not fail the save.")
        } catch {
            XCTAssertEqual(error as? NotebookRepositoryError, .ioFailure(EIO))
        }
        XCTAssertEqual(counter.enumerationCount, 0)
        let directory = noteURL(root: root, id: id)
        let stage = directory.appendingPathComponent("assets/.\(UUID().uuidString).tmp")
        try Data("process stage".utf8).write(to: stage)
        let transaction = root.appendingPathComponent(".creation-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: false)
        try Data("unpublished creation".utf8).write(to: transaction.appendingPathComponent("private"))
        let committedBytes = try Data(contentsOf: revisionURL(root: root, id: id, revision: baseline.revisionID))
        counter.reset()

        let retry = try await repository.save(
            id: id, content: content(title: "Waiting", strokes: [stroke]),
            expectedRevisionID: baseline.revisionID
        )

        XCTAssertEqual(counter.count(.directoryEnumeration(.library)), 1)
        XCTAssertEqual(counter.count(.directoryEnumeration(.privateTransaction)), 1)
        XCTAssertEqual(counter.count(.directoryEnumeration(.notebook)), 1)
        XCTAssertEqual(counter.count(.directoryEnumeration(.assets)), 1)
        XCTAssertEqual(counter.count(.directoryEnumeration(.events)), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.path))
        XCTAssertEqual(
            try Data(contentsOf: revisionURL(root: root, id: id, revision: baseline.revisionID)),
            committedBytes
        )
        XCTAssertEqual(retry.content.strokes, [stroke])
        counter.reset()
        _ = try await repository.save(
            id: id, content: content(title: "Clean", strokes: [stroke]),
            expectedRevisionID: retry.revisionID
        )
        XCTAssertEqual(counter.enumerationCount, 0)
    }

    func testMaintenanceErrorsDoNotRejectValidatedLoadOrSaveAndRemainScheduled() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let stroke = NotebookStroke(id: UUID(), data: Data("retained".utf8))
        let baseline = try await NotebookRepository(rootURL: root).save(
            id: id, content: content(strokes: [stroke]), expectedRevisionID: nil
        )
        let stage = try eventsURL(root: root, id: id).appendingPathComponent(".\(UUID().uuidString).tmp")
        try Data("retry cleanup".utf8).write(to: stage)
        let counter = NotebookMaintenanceCounter()
        let fault = NotebookMaintenanceFaultBudget(failures: 2)
        let repository = try NotebookRepository(
            rootURL: root, maintenanceObserver: { counter.record($0) },
            maintenanceFaultInjector: { try fault.failIfNeeded() }
        )
        counter.reset()

        let loaded = try await requiredNotebook(repository, id: id)
        XCTAssertEqual(loaded.revisionID, baseline.revisionID)
        XCTAssertEqual(loaded.content, baseline.content)
        XCTAssertEqual(counter.count(.failed(.io)), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path))
        let first = try await repository.save(
            id: id, content: content(title: "Accepted", strokes: [stroke]),
            expectedRevisionID: baseline.revisionID
        )
        XCTAssertEqual(counter.count(.failed(.io)), 2)
        let failedReport = await repository.maintenanceReport()
        XCTAssertEqual(failedReport[.failed(.io)], 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path))
        counter.reset()
        let second = try await repository.save(
            id: id, content: content(title: "Cleanup recovered", strokes: [stroke]),
            expectedRevisionID: first.revisionID
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
        XCTAssertEqual(counter.enumerationCount, 5)
        XCTAssertEqual(counter.count(.removedStage), 1)
        let recoveredReport = await repository.maintenanceReport()
        XCTAssertEqual(recoveredReport[.failed(.io)], 2)
        XCTAssertEqual(recoveredReport[.removedStage], 1)
        counter.reset()
        let third = try await repository.save(
            id: id, content: content(title: "Clean again", strokes: [stroke]),
            expectedRevisionID: second.revisionID
        )
        XCTAssertEqual(counter.enumerationCount, 0)
        let reopened = try await requiredNotebook(NotebookRepository(rootURL: root), id: id)
        XCTAssertEqual(reopened.revisionID, third.revisionID)
        XCTAssertEqual(reopened.content, third.content)
    }

    func testCommittedCorruptionFailsBeforeOpportunisticMaintenance() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let stroke = NotebookStroke(id: UUID(), data: Data("original".utf8))
        let saved = try await NotebookRepository(rootURL: root).save(
            id: id, content: content(strokes: [stroke]), expectedRevisionID: nil
        )
        let directory = noteURL(root: root, id: id)
        let stage = directory.appendingPathComponent(".head-\(UUID().uuidString).tmp")
        try Data("keep until validated".utf8).write(to: stage)
        let asset = directory.appendingPathComponent("assets/\(digest(stroke.data)).stroke")
        try Data("damaged".utf8).write(to: asset)
        let before = try fileSnapshot(root: directory)
        let counter = NotebookMaintenanceCounter()
        let repository = try NotebookRepository(
            rootURL: root, maintenanceObserver: { counter.record($0) }
        )
        counter.reset()
        do {
            _ = try await repository.load(id: id)
            XCTFail("Committed corruption was hidden by cleanup.")
        } catch {
            guard case .corruptData? = error as? NotebookRepositoryError else {
                return XCTFail("Unexpected committed corruption error: \(error)")
            }
        }
        do {
            _ = try await repository.save(
                id: id, content: content(strokes: []), expectedRevisionID: saved.revisionID
            )
            XCTFail("A corrupt committed asset without candidate bytes was replaced.")
        } catch {
            guard case .corruptData? = error as? NotebookRepositoryError else {
                return XCTFail("Unexpected corrupt save error: \(error)")
            }
        }
        XCTAssertEqual(counter.enumerationCount, 0)
        XCTAssertEqual(try fileSnapshot(root: directory), before)
    }

    func testStageMaintenanceRemovalBudgetIsObservableAndPreservesHistory() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let saved = try await NotebookRepository(rootURL: root).save(
            id: id, content: content(), expectedRevisionID: nil
        )
        let directory = noteURL(root: root, id: id)
        let stages = (0..<65).map { _ in directory.appendingPathComponent(".\(UUID().uuidString).tmp") }
        for stage in stages { try Data("residue".utf8).write(to: stage) }
        let revision = try revisionURL(root: root, id: id, revision: saved.revisionID)
        let historyBytes = try Data(contentsOf: revision)
        let counter = NotebookMaintenanceCounter()
        let repository = try NotebookRepository(
            rootURL: root, maintenanceObserver: { counter.record($0) }
        )
        counter.reset()

        let loaded = try await requiredNotebook(repository, id: id)

        XCTAssertEqual(loaded.content, saved.content)
        XCTAssertEqual(counter.count(.removedStage), 64)
        XCTAssertEqual(counter.count(.limitReached), 1)
        XCTAssertEqual(stages.filter { FileManager.default.fileExists(atPath: $0.path) }.count, 1)
        XCTAssertEqual(try Data(contentsOf: revision), historyBytes)
    }

    func testMaintenanceDiagnosticsAggregateRepeatedEventsWithoutGrowingTheReport() {
        let diagnostics = NotebookFileSystem.MaintenanceDiagnostics()
        for _ in 0..<10_000 {
            diagnostics.record(.skippedNonRegularStage)
            diagnostics.record(.failed(.io))
        }
        let report = diagnostics.snapshot()
        XCTAssertEqual(report.count, 2)
        XCTAssertEqual(report[.skippedNonRegularStage], 10_000)
        XCTAssertEqual(report[.failed(.io)], 10_000)
    }

    func testCandidateRepairsCommittedAssetAndPreservesHistoricalStates() async throws {
        for oversized in [false, true] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let id = UUID()
            let stroke = NotebookStroke(id: UUID(), data: Data("verified archive".utf8))
            let repository = try NotebookRepository(rootURL: root)
            let first = try await repository.save(
                id: id, content: content(strokes: [stroke]), expectedRevisionID: nil
            )
            let asset = noteURL(root: root, id: id).appendingPathComponent("assets/\(digest(stroke.data)).stroke")
            if oversized {
                try makeSparseFile(asset, size: NotebookRepository.maximumAssetBytes + 1)
            } else {
                try Data("wrong bytes".utf8).write(to: asset)
            }
            do {
                _ = try await repository.auditHistory(id: id)
                XCTFail("Candidate-free audit accepted a damaged archive.")
            } catch {
                guard case .corruptData? = error as? NotebookRepositoryError else {
                    return XCTFail("Unexpected damaged archive error: \(error)")
                }
            }
            let second = try await repository.save(
                id: id, content: content(title: "Repaired", strokes: [stroke]),
                expectedRevisionID: first.revisionID
            )
            XCTAssertEqual(try Data(contentsOf: asset), stroke.data)
            let historical = try await repository.loadRevision(id: id, revisionID: first.revisionID)
            XCTAssertEqual(historical.content, first.content)
            let loaded = try await requiredNotebook(repository, id: id)
            XCTAssertEqual(loaded.revisionID, second.revisionID)
            let audit = try await repository.auditHistory(id: id)
            XCTAssertEqual(audit.revisionCount, 2)
            XCTAssertEqual(audit.verifiedAssetCount, 1)
            let report = await repository.maintenanceReport()
            XCTAssertEqual(report[.repairedAsset], 1)
        }
    }

    func testOversizedUnpublishedAssetIsRepairedFromCandidateBytes() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let stroke = NotebookStroke(id: UUID(), data: Data("candidate archive".utf8))
        let repository = try NotebookRepository(rootURL: root)
        let first = try await repository.save(id: id, content: content(), expectedRevisionID: nil)
        let asset = noteURL(root: root, id: id).appendingPathComponent("assets/\(digest(stroke.data)).stroke")
        try makeSparseFile(asset, size: NotebookRepository.maximumAssetBytes + 1)
        let second = try await repository.save(
            id: id, content: content(strokes: [stroke]), expectedRevisionID: first.revisionID
        )
        XCTAssertEqual(try Data(contentsOf: asset), stroke.data)
        let loaded = try await requiredNotebook(repository, id: id)
        XCTAssertEqual(loaded.revisionID, second.revisionID)
        let audit = try await repository.auditHistory(id: id)
        XCTAssertEqual(audit.verifiedAssetCount, 1)
        let report = await repository.maintenanceReport()
        XCTAssertEqual(report[.repairedAsset], 1)
    }

    func testAssetRepairPublicationFaultsKeepHeadAndPermitRetry() async throws {
        for committed in [false, true] {
            for target in [NotebookWriteStage.assetStaged, .assetPublished] {
                let root = try makeRoot()
                defer { try? FileManager.default.removeItem(at: root) }
                let id = UUID()
                let stroke = NotebookStroke(id: UUID(), data: Data("correct archive".utf8))
                let healthy = try NotebookRepository(rootURL: root)
                let first = try await healthy.save(
                    id: id, content: content(strokes: committed ? [stroke] : []), expectedRevisionID: nil
                )
                let directory = noteURL(root: root, id: id)
                let headURL = directory.appendingPathComponent("HEAD.json")
                let headBytes = try Data(contentsOf: headURL)
                let asset = directory.appendingPathComponent("assets/\(digest(stroke.data)).stroke")
                let damaged = Data("damaged archive".utf8)
                try damaged.write(to: asset)
                let faulty = try NotebookRepository(rootURL: root, faultInjector: { stage in
                    if stage == target { throw InjectedFailure.stop }
                })
                do {
                    _ = try await faulty.save(
                        id: id, content: content(strokes: [stroke]), expectedRevisionID: first.revisionID
                    )
                    XCTFail("The asset repair fault did not occur.")
                } catch {
                    XCTAssertTrue(error is InjectedFailure)
                }
                XCTAssertEqual(try Data(contentsOf: headURL), headBytes)
                XCTAssertEqual(try Data(contentsOf: asset), target == .assetStaged ? damaged : stroke.data)
                XCTAssertFalse(try fileSnapshot(root: directory).keys.contains { $0.hasSuffix(".tmp") })
                let retry = try NotebookRepository(rootURL: root)
                let second = try await retry.save(
                    id: id, content: content(strokes: [stroke]), expectedRevisionID: first.revisionID
                )
                XCTAssertEqual(try Data(contentsOf: asset), stroke.data)
                XCTAssertEqual(second.sequence, 2)
                let audit = try await retry.auditHistory(id: id)
                XCTAssertEqual(audit.revisionCount, 2)
            }
        }
    }

    func testCandidateAssetRepairRefusesDirectoriesAndSymbolicLinks() async throws {
        for committed in [false, true] {
            for linked in [false, true] {
                let root = try makeRoot()
                defer { try? FileManager.default.removeItem(at: root) }
                let id = UUID()
                let stroke = NotebookStroke(id: UUID(), data: Data("candidate".utf8))
                let repository = try NotebookRepository(rootURL: root)
                let first = try await repository.save(
                    id: id, content: content(strokes: committed ? [stroke] : []), expectedRevisionID: nil
                )
                let directory = noteURL(root: root, id: id)
                let headURL = directory.appendingPathComponent("HEAD.json")
                let headBytes = try Data(contentsOf: headURL)
                let asset = directory.appendingPathComponent("assets/\(digest(stroke.data)).stroke")
                if committed { try FileManager.default.removeItem(at: asset) }
                let outside = root.appendingPathComponent("outside")
                try Data("untouched".utf8).write(to: outside)
                if linked {
                    try FileManager.default.createSymbolicLink(at: asset, withDestinationURL: outside)
                } else {
                    try FileManager.default.createDirectory(at: asset, withIntermediateDirectories: false)
                    try Data("untouched".utf8).write(to: asset.appendingPathComponent("child"))
                }
                let refreshed = try NotebookRepository(rootURL: root)
                do {
                    _ = try await refreshed.save(
                        id: id, content: content(strokes: [stroke]), expectedRevisionID: first.revisionID
                    )
                    XCTFail("An unsafe asset entry was repaired.")
                } catch {
                    guard case .unsafePath? = error as? NotebookRepositoryError else {
                        return XCTFail("Unexpected unsafe repair error: \(error)")
                    }
                }
                XCTAssertEqual(try Data(contentsOf: headURL), headBytes)
                XCTAssertEqual(try Data(contentsOf: outside), Data("untouched".utf8))
                if linked {
                    XCTAssertEqual(
                        try FileManager.default.destinationOfSymbolicLink(atPath: asset.path), outside.path
                    )
                } else {
                    XCTAssertEqual(
                        try Data(contentsOf: asset.appendingPathComponent("child")), Data("untouched".utf8)
                    )
                }
            }
        }
    }

    func testStaleWriterCannotRepairAnAssetBeforeRevisionAdmission() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let stroke = NotebookStroke(id: UUID(), data: Data("candidate".utf8))
        let repository = try NotebookRepository(rootURL: root)
        let first = try await repository.save(
            id: id, content: content(strokes: [stroke]), expectedRevisionID: nil
        )
        let second = try await repository.save(
            id: id, content: content(title: "Newer", strokes: [stroke]), expectedRevisionID: first.revisionID
        )
        let asset = noteURL(root: root, id: id).appendingPathComponent("assets/\(digest(stroke.data)).stroke")
        let damaged = Data("damaged".utf8)
        try damaged.write(to: asset)
        do {
            _ = try await repository.save(
                id: id, content: content(strokes: [stroke]), expectedRevisionID: first.revisionID
            )
            XCTFail("A stale writer repaired storage.")
        } catch {
            XCTAssertEqual(error as? NotebookRepositoryError, .revisionConflict)
        }
        XCTAssertEqual(try Data(contentsOf: asset), damaged)
        let head = try object(at: noteURL(root: root, id: id).appendingPathComponent("HEAD.json"))
        XCTAssertEqual(head["revisionID"] as? String, second.revisionID.uuidString)
    }

    func testOversizedAndLinkedPrivateTransactionsDoNotBlockHealthyStorage() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let first = try await NotebookRepository(rootURL: root).save(
            id: id, content: content(), expectedRevisionID: nil
        )
        let oversized = root.appendingPathComponent(".migration-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: oversized, withIntermediateDirectories: false)
        let large = oversized.appendingPathComponent("large")
        let size = 600 * 1_024 * 1_024 + 1
        try makeSparseFile(large, size: size)
        let linked = root.appendingPathComponent(".creation-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: false)
        let target = root.appendingPathComponent("outside")
        try Data("untouched".utf8).write(to: target)
        let child = linked.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: child, withDestinationURL: target)
        let healthy = root.appendingPathComponent(".creation-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: healthy, withIntermediateDirectories: false)
        try Data("leftover".utf8).write(to: healthy.appendingPathComponent("private"))
        let counter = NotebookMaintenanceCounter()
        let repository = try NotebookRepository(rootURL: root, maintenanceObserver: { counter.record($0) })
        XCTAssertEqual(counter.count(.failed(.sizeLimit)), 1)
        XCTAssertEqual(counter.count(.failed(.unsafePath)), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: healthy.path))
        let loaded = try await requiredNotebook(repository, id: id)
        XCTAssertEqual(loaded.revisionID, first.revisionID)
        do {
            _ = try await repository.save(
                id: id, content: content(title: "Stale"), expectedRevisionID: UUID()
            )
            XCTFail("The stale writer was accepted.")
        } catch {
            XCTAssertEqual(error as? NotebookRepositoryError, .revisionConflict)
        }
        counter.reset()
        let second = try await repository.save(
            id: id, content: content(title: "Updated"), expectedRevisionID: first.revisionID
        )
        XCTAssertEqual(counter.count(.failed(.sizeLimit)), 1)
        XCTAssertEqual(counter.count(.failed(.unsafePath)), 1)
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: large.path)[.size] as? NSNumber)?.intValue, size
        )
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: child.path), target.path)
        XCTAssertEqual(try Data(contentsOf: target), Data("untouched".utf8))
        counter.reset()
        _ = try await repository.save(
            id: id, content: content(title: "Clean"), expectedRevisionID: second.revisionID
        )
        XCTAssertEqual(counter.enumerationCount, 0)
        XCTAssertTrue(counter.snapshot().isEmpty)
    }


    func testSelectionBootstrapPublishesOnlyTheOpenedFreshNotebook() async throws {
        let notes = try makeRoot()
        let recovery = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: notes)
            try? FileManager.default.removeItem(at: recovery)
        }
        let repository = try NotebookRepository(rootURL: notes)
        let legacyID = UUID()
        guard case .empty(let token) = try await repository.readSelection(
            legacyNotebookID: legacyID, recoveryRootURL: recovery
        ) else { return XCTFail("Empty paired roots must provide a bootstrap token.") }
        let targetID = UUID()
        let saved = try await repository.save(
            id: targetID, content: content(strokes: []), expectedRevisionID: nil
        )
        let opened = try await repository.open(id: targetID)
        let pin = try XCTUnwrap(opened?.historyPin)
        guard case .selected(let selected, _) = try await repository.selectNotebook(
            pin: pin, expectedSelection: token
        ) else { return XCTFail("Publication must return the exact selected ID.") }
        XCTAssertEqual(selected, targetID)
        let reader = try NotebookRepository(rootURL: notes)
        guard case .selected(let reopened, _) = try await reader.readSelection(
            legacyNotebookID: legacyID, recoveryRootURL: recovery
        ) else { return XCTFail("A published pointer must survive reopening.") }
        XCTAssertEqual(reopened, targetID)
        let loaded = try await requiredNotebook(reader, id: targetID)
        XCTAssertEqual(loaded.revisionID, saved.revisionID)
        XCTAssertEqual(loaded.content, saved.content)
    }

    func testSelectionEmptyTokenRejectsForeignNoteOrCopyArrivingBeforePublication() async throws {
        for arrival in ["note", "copy"] {
            let notes = try makeRoot()
            let recovery = try makeRoot()
            defer {
                try? FileManager.default.removeItem(at: notes)
                try? FileManager.default.removeItem(at: recovery)
            }
            let repository = try NotebookRepository(rootURL: notes)
            let legacyID = UUID()
            guard case .empty(let token) = try await repository.readSelection(
                legacyNotebookID: legacyID, recoveryRootURL: recovery
            ) else { return XCTFail("The fixture must begin empty.") }
            let targetID = UUID()
            _ = try await repository.save(id: targetID, content: content(strokes: []), expectedRevisionID: nil)
            let opened = try await repository.open(id: targetID)
            let pin = try XCTUnwrap(opened?.historyPin)
            if arrival == "note" {
                let foreign = try NotebookRepository(rootURL: notes)
                _ = try await foreign.save(id: UUID(), content: content(strokes: []), expectedRevisionID: nil)
            } else {
                let store = try NotebookRecoveryStore(rootURL: recovery)
                _ = try await store.preserve(NotebookRecoveryBatch(
                    notebookID: UUID(), baseRevisionID: nil,
                    edits: [NotebookRecoveryEdit(
                        id: UUID(), drawingData: PKDrawing().dataRepresentation(), strokeIDs: [],
                        title: "Retained", pageCount: 1,
                        stamp: NotebookEditStamp(capturedAt: Date(timeIntervalSince1970: 100), uptime: 1, sessionID: UUID())
                    )]
                ))
            }
            let beforeNotes = try fileSnapshot(root: notes)
            let beforeRecovery = try fileSnapshot(root: recovery)
            do {
                _ = try await repository.selectNotebook(pin: pin, expectedSelection: token)
                XCTFail("A stale empty-library token must not select a blank notebook after foreign publication.")
            } catch {
                XCTAssertEqual(error as? NotebookRepositoryError, .revisionConflict)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: notes.appendingPathComponent("SELECTION.json").path))
            XCTAssertEqual(try fileSnapshot(root: notes), beforeNotes)
            XCTAssertEqual(try fileSnapshot(root: recovery), beforeRecovery)
            guard case .recoveryRequired = try await repository.readSelection(
                legacyNotebookID: legacyID, recoveryRootURL: recovery
            ) else { return XCTFail("Retained unselected content must never be automatically promoted.") }
            let retained = try await requiredNotebook(repository, id: targetID)
            XCTAssertEqual(retained.revisionID, pin.revisionID)
        }
    }

    func testSelectionFaultsRetainOldPointerAndBothNotebookHistories() async throws {
        for targetStage in NotebookSelectionWriteStage.allCases {
            let notes = try makeRoot()
            let recovery = try makeRoot()
            defer {
                try? FileManager.default.removeItem(at: notes)
                try? FileManager.default.removeItem(at: recovery)
            }
            let healthy = try NotebookRepository(rootURL: notes)
            let oldID = UUID()
            _ = try await healthy.save(id: oldID, content: content(strokes: []), expectedRevisionID: nil)
            guard case .selected(_, let initialToken) = try await healthy.readSelection(
                legacyNotebookID: oldID, recoveryRootURL: recovery
            ) else { return XCTFail("The existing fixed legacy directory is the compatibility selection.") }
            let oldOpen = try await healthy.open(id: oldID)
            _ = try await healthy.selectNotebook(
                pin: try XCTUnwrap(oldOpen?.historyPin), expectedSelection: initialToken
            )
            let outsideFile = recovery.appendingPathComponent("retained-outside")
            let retainedLink = notes.appendingPathComponent("retained-link")
            let outsideBytes = Data("retained outside target".utf8)
            try outsideBytes.write(to: outsideFile)
            try FileManager.default.createSymbolicLink(at: retainedLink, withDestinationURL: outsideFile)
            let faulty = try NotebookRepository(rootURL: notes, selectionFaultInjector: { stage in
                if stage == targetStage { throw InjectedFailure.stop }
            })
            guard case .selected(_, let token) = try await faulty.readSelection(
                legacyNotebookID: oldID, recoveryRootURL: recovery
            ) else { return XCTFail("The fixture must retain its selected pointer.") }
            let newID = UUID()
            _ = try await faulty.save(id: newID, content: content(strokes: []), expectedRevisionID: nil)
            let opened = try await faulty.open(id: newID)
            let before = try fileSnapshot(root: notes)
            do {
                _ = try await faulty.selectNotebook(pin: try XCTUnwrap(opened?.historyPin), expectedSelection: token)
                XCTFail("The injected selection fault must propagate before publication.")
            } catch { XCTAssertTrue(error is InjectedFailure) }
            XCTAssertEqual(try fileSnapshot(root: notes), before)
            XCTAssertTrue(try retainedLink.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: retainedLink.path), outsideFile.path)
            XCTAssertEqual(try Data(contentsOf: outsideFile), outsideBytes)
            let reader = try NotebookRepository(rootURL: notes)
            guard case .selected(let id, _) = try await reader.readSelection(
                legacyNotebookID: oldID, recoveryRootURL: recovery
            ) else { return XCTFail("Failure must retain the old selection.") }
            XCTAssertEqual(id, oldID)
            let oldAudit = try await reader.auditHistory(id: oldID)
            let newAudit = try await reader.auditHistory(id: newID)
            XCTAssertEqual(oldAudit.revisionCount, 1)
            XCTAssertEqual(newAudit.revisionCount, 1)
        }
    }

    func testSelectionRejectsForeignPinStaleHeadAndFreshCurrentAssetDamage() async throws {
        for invalid in ["foreign", "head", "asset"] {
            let notes = try makeRoot()
            let recovery = try makeRoot()
            defer {
                try? FileManager.default.removeItem(at: notes)
                try? FileManager.default.removeItem(at: recovery)
            }
            let repository = try NotebookRepository(rootURL: notes)
            let legacyID = UUID()
            guard case .empty(let token) = try await repository.readSelection(
                legacyNotebookID: legacyID, recoveryRootURL: recovery
            ) else { return XCTFail("The fixture must begin empty.") }
            let id = UUID()
            let asset = NotebookStroke(id: UUID(), data: Data("validated archive".utf8))
            let saved = try await repository.save(id: id, content: content(strokes: [asset]), expectedRevisionID: nil)
            let opened = try await repository.open(id: id)
            var pin = try XCTUnwrap(opened?.historyPin)
            if invalid == "foreign" {
                let foreign = try NotebookRepository(rootURL: notes)
                let foreignOpen = try await foreign.open(id: id)
                pin = try XCTUnwrap(foreignOpen?.historyPin)
            } else if invalid == "head" {
                let foreign = try NotebookRepository(rootURL: notes)
                _ = try await foreign.save(
                    id: id, content: NotebookContent(title: "Changed", pageCount: 3, strokes: [asset]),
                    expectedRevisionID: saved.revisionID
                )
            } else {
                let path = noteURL(root: notes, id: id).appendingPathComponent("assets/\(digest(asset.data)).stroke")
                try Data("tampered".utf8).write(to: path)
            }
            let before = try fileSnapshot(root: notes)
            do {
                _ = try await repository.selectNotebook(pin: pin, expectedSelection: token)
                XCTFail("Selection must validate repository ownership, exact HEAD and fresh current assets.")
            } catch {
                switch (invalid, error as? NotebookRepositoryError) {
                case ("foreign", .invalidContent?), ("head", .revisionConflict?), ("asset", .corruptData?): break
                default: XCTFail("Unexpected selection validation error: \(error)")
                }
            }
            XCTAssertEqual(try fileSnapshot(root: notes), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: notes.appendingPathComponent("SELECTION.json").path))
        }
    }

    func testSelectionRecoveryRequiredEscapeRetainsAmbiguousContentAndDamagedLegacySelection() async throws {
        let notes = try makeRoot()
        let recovery = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: notes)
            try? FileManager.default.removeItem(at: recovery)
        }
        let repository = try NotebookRepository(rootURL: notes)
        let legacyID = UUID()
        let legacyDirectory = noteURL(root: notes, id: legacyID)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: false)
        try Data("damaged".utf8).write(to: legacyDirectory.appendingPathComponent("HEAD.json"))
        guard case .selected(let legacy, _) = try await repository.readSelection(
            legacyNotebookID: legacyID, recoveryRootURL: recovery
        ) else { return XCTFail("An existing legacy directory must remain selected even when its HEAD is damaged.") }
        XCTAssertEqual(legacy, legacyID)
        guard case .recoveryRequired(let token) = try await repository.readSelection(
            legacyNotebookID: UUID(), recoveryRootURL: recovery
        ) else { return XCTFail("A nondefault retained directory without a pointer requires explicit recovery.") }
        let retainedBefore = try fileSnapshot(root: legacyDirectory)
        let target = UUID()
        _ = try await repository.save(id: target, content: content(strokes: []), expectedRevisionID: nil)
        let opened = try await repository.open(id: target)
        _ = try await repository.selectNotebook(pin: try XCTUnwrap(opened?.historyPin), expectedSelection: token)
        XCTAssertEqual(try fileSnapshot(root: legacyDirectory), retainedBefore)
        guard case .selected(let selected, _) = try await repository.readSelection(
            legacyNotebookID: legacyID, recoveryRootURL: recovery
        ) else { return XCTFail("Only the explicitly selected fresh note must be selected.") }
        XCTAssertEqual(selected, target)
    }

    func testSelectionInvalidPointerAndUnsafePairedRootsNeverBecomeEmptyTokens() async throws {
        for invalid in ["malformed", "version", "link", "directory", "overlap", "aliasOverlap", "recoveryLink"] {
            let notes = try makeRoot()
            let recovery = try makeRoot()
            let outside = try makeRoot()
            defer {
                try? FileManager.default.removeItem(at: notes)
                try? FileManager.default.removeItem(at: recovery)
                try? FileManager.default.removeItem(at: outside)
            }
            let repository = try NotebookRepository(rootURL: notes)
            let pointer = notes.appendingPathComponent("SELECTION.json")
            var recoveryURL = recovery
            switch invalid {
            case "malformed": try Data("invalid".utf8).write(to: pointer)
            case "version": try writeObject(["schemaVersion": 99], to: pointer)
            case "link":
                let target = outside.appendingPathComponent("pointer")
                try Data("retained".utf8).write(to: target)
                try FileManager.default.createSymbolicLink(at: pointer, withDestinationURL: target)
            case "directory": try FileManager.default.createDirectory(at: pointer, withIntermediateDirectories: false)
            case "overlap": recoveryURL = notes.appendingPathComponent("nested")
            case "aliasOverlap":
                let alias = outside.appendingPathComponent("notes-alias")
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: notes)
                recoveryURL = alias.appendingPathComponent("nested")
            default:
                recoveryURL = outside.appendingPathComponent("recovery-link")
                try FileManager.default.createSymbolicLink(at: recoveryURL, withDestinationURL: recovery)
            }
            let before = try fileSnapshot(root: notes)
            do {
                _ = try await repository.readSelection(legacyNotebookID: UUID(), recoveryRootURL: recoveryURL)
                XCTFail("Malformed pointer and unsafe roots must never mint an absence token.")
            } catch {
                switch (invalid, error as? NotebookRepositoryError) {
                case ("malformed", .corruptData?), ("version", .unsupportedVersion(99)?): break
                case ("link", .unsafePath?), ("directory", .unsafePath?),
                     ("overlap", .unsafePath?), ("aliasOverlap", .unsafePath?),
                     ("recoveryLink", .unsafePath?): break
                default: XCTFail("Unexpected unsafe selection error: \(error)")
                }
            }
            XCTAssertEqual(try fileSnapshot(root: notes), before)
            if invalid == "link" {
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: pointer.path),
                               outside.appendingPathComponent("pointer").path)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: notes.appendingPathComponent("nested").path))
        }
    }

    private func makeSparseFile(_ url: URL, size: Int) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(size))
    }


    func testSelectionExistingPointerCompareAndSwapRetainsTheNewerSelectedNotebook() async throws {
        let notes = try makeRoot()
        let recovery = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: notes)
            try? FileManager.default.removeItem(at: recovery)
        }
        let repository = try NotebookRepository(rootURL: notes)
        let firstID = UUID()
        _ = try await repository.save(id: firstID, content: content(strokes: []), expectedRevisionID: nil)
        guard case .selected(_, let initial) = try await repository.readSelection(
            legacyNotebookID: firstID, recoveryRootURL: recovery
        ) else { return XCTFail("The legacy directory must be selected for compatibility.") }
        let firstOpen = try await repository.open(id: firstID)
        let firstPin = try XCTUnwrap(firstOpen?.historyPin)
        guard case .selected(_, let stale) = try await repository.selectNotebook(
            pin: firstPin, expectedSelection: initial
        ) else { return XCTFail("The fixture must publish its first pointer.") }
        let secondID = UUID()
        _ = try await repository.save(id: secondID, content: content(strokes: []), expectedRevisionID: nil)
        let secondOpen = try await repository.open(id: secondID)
        _ = try await repository.selectNotebook(
            pin: try XCTUnwrap(secondOpen?.historyPin), expectedSelection: stale
        )
        let before = try fileSnapshot(root: notes)
        do {
            _ = try await repository.selectNotebook(pin: firstPin, expectedSelection: stale)
            XCTFail("An old existing-pointer token must not replace the newer selection.")
        } catch { XCTAssertEqual(error as? NotebookRepositoryError, .revisionConflict) }
        XCTAssertEqual(try fileSnapshot(root: notes), before)
        guard case .selected(let selected, _) = try await repository.readSelection(
            legacyNotebookID: firstID, recoveryRootURL: recovery
        ) else { return XCTFail("The newer selected notebook must remain selected.") }
        XCTAssertEqual(selected, secondID)
    }

    func testSelectionRechecksEmptyInventoryAfterThePublicationCallback() async throws {
        let notes = try makeRoot()
        let recovery = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: notes)
            try? FileManager.default.removeItem(at: recovery)
        }
        let foreignID = UUID()
        let foreignDirectory = noteURL(root: notes, id: foreignID)
        let repository = try NotebookRepository(rootURL: notes, selectionFaultInjector: { stage in
            if stage == .beforeSelectionPublication {
                try FileManager.default.createDirectory(at: foreignDirectory, withIntermediateDirectories: false)
            }
        })
        let legacyID = UUID()
        guard case .empty(let token) = try await repository.readSelection(
            legacyNotebookID: legacyID, recoveryRootURL: recovery
        ) else { return XCTFail("The fixture must begin empty.") }
        let targetID = UUID()
        let saved = try await repository.save(id: targetID, content: content(strokes: []), expectedRevisionID: nil)
        let opened = try await repository.open(id: targetID)
        let targetBefore = try fileSnapshot(root: noteURL(root: notes, id: targetID))
        do {
            _ = try await repository.selectNotebook(pin: try XCTUnwrap(opened?.historyPin), expectedSelection: token)
            XCTFail("A retained entry arriving at the publication callback must invalidate empty bootstrap.")
        } catch { XCTAssertEqual(error as? NotebookRepositoryError, .revisionConflict) }
        XCTAssertTrue(try NotebookFileSystem.existingDirectory(foreignDirectory))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: foreignDirectory.path), [])
        XCTAssertEqual(try fileSnapshot(root: noteURL(root: notes, id: targetID)), targetBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: notes.appendingPathComponent("SELECTION.json").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: notes.path).contains { $0.hasSuffix(".tmp") })
        guard case .recoveryRequired = try await repository.readSelection(
            legacyNotebookID: legacyID, recoveryRootURL: recovery
        ) else { return XCTFail("Neither retained directory may be automatically selected.") }
        let loaded = try await requiredNotebook(repository, id: targetID)
        XCTAssertEqual(loaded.revisionID, saved.revisionID)
        XCTAssertEqual(loaded.content, saved.content)
    }

    func testSelectionAbsentPointerClassifiesRetainedCopyPrivateOrphanAndUnknownContentConservatively() async throws {
        for retained in ["copy", "private", "orphan", "regular", "many"] {
            let notes = try makeRoot()
            let recovery = try makeRoot()
            defer {
                try? FileManager.default.removeItem(at: notes)
                try? FileManager.default.removeItem(at: recovery)
            }
            let repository = try NotebookRepository(rootURL: notes)
            let legacyID = UUID()
            switch retained {
            case "copy":
                let store = try NotebookRecoveryStore(rootURL: recovery)
                _ = try await store.preserve(NotebookRecoveryBatch(
                    notebookID: UUID(), baseRevisionID: nil,
                    edits: [NotebookRecoveryEdit(
                        id: UUID(), drawingData: PKDrawing().dataRepresentation(), strokeIDs: [],
                        title: "Retained", pageCount: 1,
                        stamp: NotebookEditStamp(capturedAt: Date(timeIntervalSince1970: 100), uptime: 1, sessionID: UUID())
                    )]
                ))
            case "private":
                try FileManager.default.createDirectory(
                    at: notes.appendingPathComponent(".creation-\(UUID().uuidString.lowercased())"),
                    withIntermediateDirectories: false
                )
            case "orphan":
                _ = try await repository.save(id: UUID(), content: content(strokes: []), expectedRevisionID: nil)
            case "regular": try Data("retained".utf8).write(to: notes.appendingPathComponent("unknown"))
            default:
                for index in 0..<65 {
                    try Data([UInt8(index)]).write(to: notes.appendingPathComponent("unknown-\(index)"))
                }
            }
            let beforeNotes = try fileSnapshot(root: notes)
            let beforeRecovery = try fileSnapshot(root: recovery)
            guard case .recoveryRequired = try await repository.readSelection(
                legacyNotebookID: legacyID, recoveryRootURL: recovery
            ) else { return XCTFail("Retained \(retained) content cannot be classified as an empty library.") }
            XCTAssertEqual(try fileSnapshot(root: notes), beforeNotes)
            // Selection may initialize only the regular zero-byte recovery writer lock.
            var afterRecovery = try fileSnapshot(root: recovery)
            afterRecovery.removeValue(forKey: ".writer.lock")
            var retainedRecovery = beforeRecovery
            retainedRecovery.removeValue(forKey: ".writer.lock")
            XCTAssertEqual(afterRecovery, retainedRecovery)
            XCTAssertFalse(FileManager.default.fileExists(atPath: notes.appendingPathComponent("SELECTION.json").path))
        }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func tryCreation(
        _ repository: NotebookRepository,
        id: UUID
    ) async throws -> Bool {
        do {
            _ = try await repository.save(
                id: id,
                content: NotebookContent(title: "Concurrent", pageCount: 1, strokes: []),
                expectedRevisionID: nil
            )
            return true
        } catch NotebookRepositoryError.revisionConflict {
            return false
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

    private func eventsURL(root: URL, id: UUID) throws -> URL {
        let head = try object(at: noteURL(root: root, id: id).appendingPathComponent("HEAD.json"))
        let generation = try XCTUnwrap(head["generationID"] as? String)
        return noteURL(root: root, id: id)
            .appendingPathComponent("history/\(generation.lowercased())/events", isDirectory: true)
    }

    private func revisionURL(root: URL, id: UUID, revision: UUID) throws -> URL {
        try eventsURL(root: root, id: id).appendingPathComponent("\(revision.uuidString.lowercased()).json")
    }

    private func files(
        root: URL,
        id: UUID,
        folder: String,
        extension suffix: String
    ) throws -> [URL] {
        let directory: URL
        if folder == "events" {
            directory = try eventsURL(root: root, id: id)
        } else {
            directory = noteURL(root: root, id: id).appendingPathComponent(folder, isDirectory: true)
        }
        return try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == suffix }
    }

    private func fileSnapshot(root: URL) throws -> [String: Data] {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
        )
        var snapshot: [String: Data] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relativePath = String(url.path.dropFirst(root.path.count + 1))
            snapshot[relativePath] = try Data(contentsOf: url)
        }
        return snapshot
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
        let revisionURL = try revisionURL(root: root, id: id, revision: revision)
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

private final class NotebookAssetVerificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func record(_ digest: String) {
        lock.lock()
        defer { lock.unlock() }
        counts[digest, default: 0] += 1
    }

    func snapshot() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        counts.removeAll()
    }
}


private final class NotebookMaintenanceCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [NotebookFileSystem.MaintenanceEvent] = []

    var enumerationCount: Int {
        snapshot().filter {
            if case .directoryEnumeration = $0 { return true }
            return false
        }.count
    }

    func record(_ event: NotebookFileSystem.MaintenanceEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    func count(_ event: NotebookFileSystem.MaintenanceEvent) -> Int {
        snapshot().filter { $0 == event }.count
    }

    func snapshot() -> [NotebookFileSystem.MaintenanceEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        events.removeAll()
    }
}

private final class NotebookMaintenanceFaultBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int

    init(failures: Int) {
        remaining = failures
    }

    func failIfNeeded() throws {
        lock.lock()
        defer { lock.unlock() }
        guard remaining > 0 else { return }
        remaining -= 1
        throw NotebookRepositoryError.ioFailure(EIO)
    }
}
