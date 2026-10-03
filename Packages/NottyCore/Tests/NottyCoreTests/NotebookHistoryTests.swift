import Foundation
import XCTest
@testable import NottyCore

@MainActor
final class NotebookHistoryTests: XCTestCase {
    private typealias Fixtures = NotebookHistoryTestFixtures

    func testThreeHundredDistinctAssetsKeepAllMetadataBelowOneAndAHalfTimesAssetsWithLargeTitle() async throws {
        try await assertLinearHistory(strokeCount: 300, title: String(repeating: "t", count: 4_096))
    }

    #if NOTTY_STORAGE_STRESS
    func testTwoThousandDistinctAssetsKeepAllMetadataBelowOneAndAHalfTimesAssets() async throws {
        try await assertLinearHistory(strokeCount: 2_000, title: String(repeating: "t", count: 4_096))
    }
    #endif

    private func assertLinearHistory(strokeCount: Int, title: String) async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let repository = try NotebookRepository(rootURL: root)
        var strokes: [NotebookStroke] = []
        var latest: StoredNotebook?
        for index in 1...strokeCount {
            strokes.append(Fixtures.asset(index: index))
            latest = try await repository.save(
                id: id,
                content: NotebookContent(
                    title: title, pageCount: 3, strokes: strokes, editStamp: Fixtures.stamp(index)
                ),
                expectedRevisionID: latest?.revisionID
            )
            if [100, 300, 500, 800, 1_000, 2_000].contains(index) {
                let layout = try Fixtures.layout(root: root, id: id)
                let eventBytes = try Fixtures.byteCount(in: layout.eventsDirectory)
                let checkpointBytes = try Fixtures.byteCount(in: layout.checkpointsDirectory)
                let assetBytes = try Fixtures.byteCount(
                    in: layout.notebookDirectory.appendingPathComponent("assets", isDirectory: true)
                )
                let checkpoints = try Fixtures.regularFiles(in: layout.checkpointsDirectory).count
                print(
                    "History growth n=\(index) events=\(eventBytes) checkpoints=\(checkpointBytes) " +
                    "assets=\(assetBytes) checkpointCount=\(checkpoints) " +
                    "ratio=\(Double(eventBytes + checkpointBytes) / Double(assetBytes))"
                )
                try Fixtures.writeGrowthMetrics(
                    workloadEdits: strokeCount, edits: index, eventBytes: eventBytes,
                    checkpointBytes: checkpointBytes, assetBytes: assetBytes,
                    checkpointCount: checkpoints
                )
            }
        }
        let saved = try XCTUnwrap(latest)
        let layout = try Fixtures.layout(root: root, id: id)
        let events = try Fixtures.regularFiles(in: layout.eventsDirectory)
        let checkpoints = try Fixtures.regularFiles(in: layout.checkpointsDirectory)
        XCTAssertEqual(events.filter { $0.pathExtension == "json" }.count, strokeCount)
        XCTAssertGreaterThan(checkpoints.filter { $0.pathExtension == "json" }.count, 1)
        let metadataBytes = try Fixtures.byteCount(in: layout.generationDirectory)
        let assets = layout.notebookDirectory.appendingPathComponent("assets", isDirectory: true)
        let assetFiles = try Fixtures.regularFiles(in: assets)
        let assetBytes = try Fixtures.byteCount(in: assets)
        XCTAssertEqual(assetFiles.count, strokeCount)
        XCTAssertEqual(assetBytes, strokeCount * 1_024)
        XCTAssertGreaterThan(metadataBytes, 0)
        XCTAssertLessThanOrEqual(
            metadataBytes, assetBytes + assetBytes / 2,
            "All selected-generation metadata must stay within 1.5 times distinct archive bytes."
        )
        let reopened = try NotebookRepository(rootURL: root)
        let loaded = try await reopened.load(id: id)
        Fixtures.assertSame(try XCTUnwrap(loaded), saved)
        let audit = try await reopened.auditHistory(id: id)
        XCTAssertEqual(audit.notebookID, id)
        XCTAssertEqual(audit.headRevisionID, saved.revisionID)
        XCTAssertEqual(audit.revisionCount, strokeCount)
        XCTAssertEqual(audit.verifiedAssetCount, strokeCount)
    }

    func testEveryHistoricalStatePreservesIdentityBytesOrderProvenanceAndSaveTime() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let repository = try NotebookRepository(rootURL: root)
        let contents = Fixtures.contents()
        var saved: [StoredNotebook] = []
        for content in contents {
            saved.append(try await repository.save(
                id: id, content: content, expectedRevisionID: saved.last?.revisionID
            ))
        }
        let reopened = try NotebookRepository(rootURL: root)
        var summaries: [NotebookRevisionSummary] = []
        var cursor: UUID?
        while true {
            let page = try await reopened.history(id: id, beforeRevisionID: cursor, limit: 3)
            if page.isEmpty { break }
            XCTAssertLessThanOrEqual(page.count, 3)
            summaries.append(contentsOf: page)
            cursor = page.last?.revisionID
        }
        XCTAssertEqual(summaries.map(\.revisionID), saved.reversed().map(\.revisionID))
        XCTAssertEqual(Set(summaries.map(\.revisionID)).count, saved.count)
        for (summary, expected) in zip(summaries, saved.reversed()) {
            XCTAssertEqual(summary.notebookID, id)
            XCTAssertEqual(summary.revisionID, expected.revisionID)
            XCTAssertEqual(summary.sequence, expected.sequence)
            XCTAssertEqual(summary.title, expected.content.title)
            XCTAssertEqual(summary.pageCount, expected.content.pageCount)
            XCTAssertEqual(summary.strokeCount, expected.content.strokes.count)
            XCTAssertEqual(summary.editStamp, expected.content.editStamp)
            XCTAssertEqual(summary.savedAt, expected.savedAt)
            let state = try await reopened.loadRevision(id: id, revisionID: expected.revisionID)
            Fixtures.assertSame(state, expected)
        }
        let audit = try await reopened.auditHistory(id: id)
        let digests = Set(contents.flatMap { $0.strokes.map { Fixtures.digest($0.data) } })
        XCTAssertEqual(audit.revisionCount, saved.count)
        XCTAssertEqual(audit.verifiedAssetCount, digests.count)
    }

    func testCorruptHistoricalFilesOutsideCurrentPathOpenAndFailFullAudit() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let repository = try NotebookRepository(rootURL: root)
        var saved: [StoredNotebook] = []
        for content in Fixtures.contents() {
            saved.append(try await repository.save(
                id: id, content: content, expectedRevisionID: saved.last?.revisionID
            ))
        }
        let layout = try Fixtures.layout(root: root, id: id)
        let first = try XCTUnwrap(saved.first)
        let firstEvent = layout.eventURL(first.revisionID)
        let eventObject = try Fixtures.object(at: firstEvent)
        let checkpointDigest = try XCTUnwrap(eventObject["checkpointDigest"] as? String)
        let checkpoint = layout.checkpointURL(checkpointDigest)
        let historicalStroke = saved[1].content.strokes[0]
        XCTAssertFalse(saved.last!.content.strokes.contains { $0.data == historicalStroke.data })
        let asset = layout.notebookDirectory.appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent(Fixtures.digest(historicalStroke.data) + ".stroke")
        for url in [firstEvent, checkpoint, asset] {
            let original = try Data(contentsOf: url)
            try Data([0, 1, 2, 3]).write(to: url)
            let reader = try NotebookRepository(rootURL: root)
            let opened = try await reader.load(id: id)
            Fixtures.assertSame(try XCTUnwrap(opened), try XCTUnwrap(saved.last))
            do {
                _ = try await reader.auditHistory(id: id)
                XCTFail("The historical audit must reject reachable corruption.")
            } catch NotebookRepositoryError.corruptData(_) {}
            try original.write(to: url)
            let restoredReader = try NotebookRepository(rootURL: root)
            let restored = try await restoredReader.load(id: id)
            Fixtures.assertSame(try XCTUnwrap(restored), try XCTUnwrap(saved.last))
        }
    }

    func testOversizedHistoricalFilesOutsideCurrentPathFailAuditWithoutChangingHead() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let repository = try NotebookRepository(rootURL: root)
        var saved: [StoredNotebook] = []
        for content in Fixtures.contents() {
            saved.append(try await repository.save(
                id: id, content: content, expectedRevisionID: saved.last?.revisionID
            ))
        }
        let layout = try Fixtures.layout(root: root, id: id)
        let first = try XCTUnwrap(saved.first)
        let oldEvent = layout.eventURL(first.revisionID)
        let eventObject = try Fixtures.object(at: oldEvent)
        let checkpointDigest = try XCTUnwrap(eventObject["checkpointDigest"] as? String)
        let oldCheckpoint = layout.checkpointURL(checkpointDigest)
        let historicalStroke = saved[1].content.strokes[0]
        XCTAssertFalse(saved.last!.content.strokes.contains { $0.data == historicalStroke.data })
        let historicalAsset = layout.notebookDirectory.appendingPathComponent(
            "assets/\(Fixtures.digest(historicalStroke.data)).stroke"
        )
        let headURL = layout.notebookDirectory.appendingPathComponent("HEAD.json")
        let originalHead = try Data(contentsOf: headURL)
        for (url, bytes) in [
            (oldEvent, 2 * 1_024 * 1_024 + 1),
            (oldCheckpoint, 2 * 1_024 * 1_024 + 1),
            (historicalAsset, 10 * 1_024 * 1_024 + 1)
        ] {
            let original = try Data(contentsOf: url)
            try Data(repeating: 0, count: bytes).write(to: url)
            let reader = try NotebookRepository(rootURL: root)
            let opened = try await reader.load(id: id)
            Fixtures.assertSame(try XCTUnwrap(opened), try XCTUnwrap(saved.last))
            do {
                _ = try await reader.auditHistory(id: id)
                XCTFail("Oversized retained history is corrupt committed data.")
            } catch NotebookRepositoryError.corruptData(_) {}
            XCTAssertEqual(try Data(contentsOf: headURL), originalHead)
            try original.write(to: url)
        }
        let restored = try await repository.load(id: id)
        Fixtures.assertSame(try XCTUnwrap(restored), try XCTUnwrap(saved.last))
    }

    func testMalformedUnreferencedEventsCheckpointsAssetsAndGenerationsRemainIrrelevant() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let repository = try NotebookRepository(rootURL: root)
        let saved = try await repository.save(
            id: id,
            content: NotebookContent(title: "Notes", pageCount: 3, strokes: [Fixtures.asset(index: 1)]),
            expectedRevisionID: nil
        )
        let layout = try Fixtures.layout(root: root, id: id)
        let orphanID = UUID()
        try Data([1]).write(to: layout.eventURL(orphanID))
        try Data([2]).write(to: layout.checkpointURL(String(repeating: "0", count: 64)))
        try Data([3]).write(
            to: layout.notebookDirectory.appendingPathComponent("assets", isDirectory: true)
                .appendingPathComponent(String(repeating: "f", count: 64) + ".stroke")
        )
        let unselected = layout.notebookDirectory.appendingPathComponent("history", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: unselected, withIntermediateDirectories: true)
        try Data([4]).write(to: unselected.appendingPathComponent("unreadable.json"))
        let reopened = try NotebookRepository(rootURL: root)
        let loaded = try await reopened.load(id: id)
        Fixtures.assertSame(try XCTUnwrap(loaded), saved)
        let audit = try await reopened.auditHistory(id: id)
        XCTAssertEqual(audit.revisionCount, 1)
        XCTAssertEqual(audit.verifiedAssetCount, 1)
        do {
            _ = try await reopened.loadRevision(id: id, revisionID: orphanID)
            XCTFail("A revision outside the selected ancestry must not be returned.")
        } catch NotebookRepositoryError.invalidContent(_) {}
        do {
            _ = try await reopened.history(id: id, beforeRevisionID: orphanID, limit: 2)
            XCTFail("An unreachable cursor must not page arbitrary files.")
        } catch NotebookRepositoryError.invalidContent(_) {}
    }

    func testHistoryRejectsUnknownRevisionsAndInvalidPageBounds() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let repository = try NotebookRepository(rootURL: root)
        let saved = try await repository.save(
            id: id, content: NotebookContent(title: "Notes", pageCount: 3, strokes: []),
            expectedRevisionID: nil
        )
        for limit in [0, 201] {
            do {
                _ = try await repository.history(id: id, limit: limit)
                XCTFail("History page bounds must be enforced.")
            } catch NotebookRepositoryError.invalidContent(_) {}
        }
        let empty = try await repository.history(id: id, beforeRevisionID: saved.revisionID, limit: 1)
        XCTAssertTrue(empty.isEmpty)
        do {
            _ = try await repository.loadRevision(id: id, revisionID: UUID())
            XCTFail("Unknown revision identity must fail.")
        } catch NotebookRepositoryError.invalidContent(_) {}
        do {
            _ = try await repository.history(id: id, beforeRevisionID: UUID(), limit: 1)
            XCTFail("Unknown cursor identity must fail.")
        } catch NotebookRepositoryError.invalidContent(_) {}
    }

    func testSharedDigestCountsOnceInAuditButEveryReferenceConsumesStateByteBudget() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let repository = try NotebookRepository(rootURL: root)
        let shared = Fixtures.asset(index: 1, bytes: 4 * 1_024 * 1_024).data
        let atLimit = (0..<16).map { _ in NotebookStroke(id: UUID(), data: shared) }
        let first = try await repository.save(
            id: id, content: NotebookContent(title: "Notes", pageCount: 3, strokes: atLimit),
            expectedRevisionID: nil
        )
        let saved = try await repository.save(
            id: id,
            content: NotebookContent(title: "Notes", pageCount: 3, strokes: atLimit, editStamp: Fixtures.stamp(2)),
            expectedRevisionID: first.revisionID
        )
        let log = Fixtures.VerificationLog()
        let auditor = try NotebookRepository(rootURL: root, assetVerificationObserver: { log.record($0) })
        let audit = try await auditor.auditHistory(id: id)
        XCTAssertEqual(audit.revisionCount, 2)
        XCTAssertEqual(audit.verifiedAssetCount, 1)
        XCTAssertEqual(log.snapshot(), [Fixtures.digest(shared)])
        let headURL = Fixtures.noteDirectory(root: root, id: id).appendingPathComponent("HEAD.json")
        let head = try Data(contentsOf: headURL)
        let overLimit = atLimit + [NotebookStroke(id: UUID(), data: shared)]
        do {
            _ = try await repository.save(
                id: id, content: NotebookContent(title: "Notes", pageCount: 3, strokes: overLimit),
                expectedRevisionID: saved.revisionID
            )
            XCTFail("Seventeen references to a shared 4 MiB asset exceed 64 MiB.")
        } catch NotebookRepositoryError.sizeLimitExceeded(_) {}
        XCTAssertEqual(try Data(contentsOf: headURL), head)
        let current = try await repository.load(id: id)
        Fixtures.assertSame(try XCTUnwrap(current), saved)
    }

    func testOversizedLegacyHistoricalStateOpensSmallHeadAndFailsAuditAndMigration() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = Fixtures.asset(index: 1, bytes: 4 * 1_024 * 1_024).data
        let oversized = NotebookContent(
            title: "Oversized", pageCount: 3,
            strokes: (0..<17).map { _ in NotebookStroke(id: UUID(), data: shared) },
            editStamp: Fixtures.stamp(1)
        )
        let current = NotebookContent(title: "Empty head", pageCount: 3, strokes: [])
        let fixture = try Fixtures.writeLegacy(root: root, contents: [oversized, current])
        let repository = try NotebookRepository(rootURL: root)
        let opened = try await repository.load(id: fixture.notebookID)
        Fixtures.assertSame(try XCTUnwrap(opened), try XCTUnwrap(fixture.states.last))
        do {
            _ = try await repository.auditHistory(id: fixture.notebookID)
            XCTFail("The full audit must reject an oversized historical logical state.")
        } catch NotebookRepositoryError.corruptData(_) {}
        do {
            _ = try await repository.migrateHistory(
                id: fixture.notebookID, expectedRevisionID: fixture.states.last!.revisionID
            )
            XCTFail("Migration must validate logical archive bytes in every old state.")
        } catch NotebookRepositoryError.corruptData(_) {}
        try Fixtures.assertOriginalFiles(fixture, root: root, includeHead: true)
    }

    func testCheckpointPublicationWaitsForEncodedByteCreditOnLargeUnchangedState() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let repository = try NotebookRepository(rootURL: root)
        let strokes = (1...128).map { Fixtures.asset(index: $0) }
        let title = String(repeating: "t", count: 4_096)
        var saved = try await repository.save(
            id: id,
            content: NotebookContent(title: title, pageCount: 3, strokes: strokes, editStamp: Fixtures.stamp(0)),
            expectedRevisionID: nil
        )
        let layout = try Fixtures.layout(root: root, id: id)
        let firstEvent = try Fixtures.object(at: layout.eventURL(saved.revisionID))
        let bootstrapDigest = try XCTUnwrap(firstEvent["checkpointDigest"] as? String)
        let bootstrapBytes = try Data(contentsOf: layout.checkpointURL(bootstrapDigest)).count
        var credit = 0
        var checkpoints = 0
        for index in 1...100 {
            saved = try await repository.save(
                id: id,
                content: NotebookContent(
                    title: title, pageCount: 3, strokes: strokes, editStamp: Fixtures.stamp(index)
                ),
                expectedRevisionID: saved.revisionID
            )
            let eventURL = layout.eventURL(saved.revisionID)
            let object = try Fixtures.object(at: eventURL)
            let delta = try XCTUnwrap(object["delta"] as? [String: Any])
            XCTAssertNil(delta["titleChange"])
            XCTAssertNil(delta["pageCountChange"])
            XCTAssertNil(delta["upserts"])
            XCTAssertNil(delta["replacementOrder"])
            credit += try Data(contentsOf: eventURL).count
            if let digest = object["checkpointDigest"] as? String {
                let bytes = try Data(contentsOf: layout.checkpointURL(digest)).count
                XCTAssertGreaterThanOrEqual(credit, bytes, "An emitted checkpoint must be funded by encoded events.")
                checkpoints += 1
                credit = 0
            } else if credit < bootstrapBytes {
                XCTAssertEqual(try Fixtures.regularFiles(in: layout.checkpointsDirectory).count, checkpoints + 1)
            }
            if index == 20 {
                XCTAssertLessThan(credit, bootstrapBytes)
                XCTAssertEqual(checkpoints, 0, "A fixed edit interval cannot fund this large checkpoint.")
            }
        }
        XCTAssertGreaterThan(checkpoints, 0, "Enough real event bytes must eventually fund a checkpoint.")
        let events = try Fixtures.regularFiles(in: layout.eventsDirectory)
        let eventBytes = try Fixtures.byteCount(in: layout.eventsDirectory)
        let checkpointBytes = try Fixtures.byteCount(in: layout.checkpointsDirectory)
        XCTAssertEqual(events.count, 101)
        XCTAssertLessThanOrEqual(checkpointBytes, eventBytes + bootstrapBytes)
        let reopened = try NotebookRepository(rootURL: root)
        let current = try await reopened.load(id: id)
        Fixtures.assertSame(try XCTUnwrap(current), saved)
    }

    func testAuthenticatedUnfundedCheckpointOpensCurrentStateAndFailsFullAudit() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let repository = try NotebookRepository(rootURL: root)
        let strokes = (1...128).map { Fixtures.asset(index: $0) }
        let content = NotebookContent(title: String(repeating: "t", count: 4_096), pageCount: 3, strokes: strokes)
        let initial = try await repository.save(id: id, content: content, expectedRevisionID: nil)
        let latest = try await repository.save(id: id, content: content, expectedRevisionID: initial.revisionID)
        let layout = try Fixtures.layout(root: root, id: id)
        let initialObject = try Fixtures.object(at: layout.eventURL(initial.revisionID))
        let initialDigest = try XCTUnwrap(initialObject["checkpointDigest"] as? String)
        var checkpoint = try Fixtures.object(at: layout.checkpointURL(initialDigest))
        checkpoint["revisionID"] = latest.revisionID.uuidString
        checkpoint["sequence"] = latest.sequence
        let checkpointData = try JSONSerialization.data(withJSONObject: checkpoint, options: [.sortedKeys])
        let checkpointDigest = Fixtures.digest(checkpointData)
        try checkpointData.write(to: layout.checkpointURL(checkpointDigest))
        var event = try Fixtures.object(at: layout.eventURL(latest.revisionID))
        XCTAssertNil(event["checkpointDigest"])
        event["checkpointDigest"] = checkpointDigest
        let eventData = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        XCTAssertLessThan(eventData.count, checkpointData.count)
        try eventData.write(to: layout.eventURL(latest.revisionID))
        let headURL = layout.notebookDirectory.appendingPathComponent("HEAD.json")
        var head = try Fixtures.object(at: headURL)
        head["revisionDigest"] = Fixtures.digest(eventData)
        try Fixtures.writeObject(head, to: headURL)
        let reopened = try NotebookRepository(rootURL: root)
        let opened = try await reopened.load(id: id)
        Fixtures.assertSame(try XCTUnwrap(opened), latest)
        do {
            _ = try await reopened.auditHistory(id: id)
            XCTFail("The full audit must reject an unfunded authenticated checkpoint.")
        } catch NotebookRepositoryError.corruptData(_) {}
    }

}
