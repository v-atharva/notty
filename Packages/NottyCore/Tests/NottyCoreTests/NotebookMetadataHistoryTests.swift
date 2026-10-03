import Foundation
import XCTest
@testable import NottyCore

final class NotebookMetadataHistoryTests: XCTestCase {
    private typealias Fixtures = NotebookHistoryTestFixtures

    func testPaginatedHistoryReadsMetadataWithoutVerifyingArchiveBytes() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let writer = try NotebookRepository(rootURL: root)
        var expected: [StoredNotebook] = []
        for content in Fixtures.contents() {
            expected.append(try await writer.save(
                id: id, content: content, expectedRevisionID: expected.last?.revisionID
            ))
        }
        let verified = Fixtures.VerificationLog()
        let reader = try NotebookRepository(
            rootURL: root, assetVerificationObserver: { verified.record($0) }
        )
        let before = await reader.storageMetrics()
        var summaries: [NotebookRevisionSummary] = []
        var cursor: UUID?
        while true {
            let page = try await reader.history(id: id, beforeRevisionID: cursor, limit: 3)
            summaries.append(contentsOf: page)
            guard page.count == 3 else { break }
            cursor = page.last?.revisionID
        }
        XCTAssertEqual(summaries.count, expected.count)
        for (summary, stored) in zip(summaries, expected.reversed()) {
            XCTAssertEqual(summary.notebookID, stored.id)
            XCTAssertEqual(summary.revisionID, stored.revisionID)
            XCTAssertEqual(summary.sequence, stored.sequence)
            XCTAssertEqual(summary.title, stored.content.title)
            XCTAssertEqual(summary.pageCount, stored.content.pageCount)
            XCTAssertEqual(summary.strokeCount, stored.content.strokes.count)
            XCTAssertEqual(summary.editStamp, stored.content.editStamp)
            XCTAssertEqual(summary.savedAt, stored.savedAt)
        }
        let after = await reader.storageMetrics()
        XCTAssertTrue(verified.snapshot().isEmpty)
        XCTAssertEqual(after.assetReadCalls - before.assetReadCalls, 0)
        XCTAssertEqual(after.assetReadBytes - before.assetReadBytes, 0)
        XCTAssertEqual(after.assetHashBytes - before.assetHashBytes, 0)
    }

    func testHistoricalLoadingReadsOnlyTheRequestedStatesArchives() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let writer = try NotebookRepository(rootURL: root)
        let strokes = (1...3).map { Fixtures.asset(index: $0) }
        var revisions: [StoredNotebook] = []
        for (index, stroke) in strokes.enumerated() {
            revisions.append(try await writer.save(
                id: id,
                content: NotebookContent(
                    title: "Revision \(index)", pageCount: index + 3,
                    strokes: [stroke], editStamp: Fixtures.stamp(index)
                ),
                expectedRevisionID: revisions.last?.revisionID
            ))
        }
        let directory = Fixtures.noteDirectory(root: root, id: id)
        let headURL = directory.appendingPathComponent("HEAD.json")
        let headBytes = try Data(contentsOf: headURL)
        for stroke in [strokes[0], strokes[2]] {
            try Data("unrelated damaged archive".utf8).write(
                to: directory.appendingPathComponent("assets/\(NotebookDigest.sha256(stroke.data)).stroke")
            )
        }
        let verified = Fixtures.VerificationLog()
        let reader = try NotebookRepository(
            rootURL: root, assetVerificationObserver: { verified.record($0) }
        )
        let before = await reader.storageMetrics()
        let historical = try await reader.loadRevision(id: id, revisionID: revisions[1].revisionID)
        Fixtures.assertSame(historical, revisions[1])
        let after = await reader.storageMetrics()
        XCTAssertEqual(verified.snapshot(), [NotebookDigest.sha256(strokes[1].data)])
        XCTAssertEqual(after.assetReadCalls - before.assetReadCalls, 1)
        XCTAssertEqual(after.assetReadBytes - before.assetReadBytes, strokes[1].data.count)
        XCTAssertEqual(after.assetHashBytes - before.assetHashBytes, strokes[1].data.count)
        XCTAssertEqual(try Data(contentsOf: headURL), headBytes)
    }
    func testOneThousandMetadataSummariesPreserveMutationsAndCursorsWithoutReadingAssets() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let writer = try NotebookRepository(rootURL: root)
        var strokes = [Fixtures.asset(index: 1), Fixtures.asset(index: 2)]
        var expected: [StoredNotebook] = []
        var title = "Sections"
        var pageCount = 3
        for index in 0..<1_000 {
            switch index % 7 {
            case 0: strokes.append(Fixtures.asset(index: index + 10))
            case 1:
                strokes[0] = Fixtures.asset(index: index + 10_000, id: strokes[0].id)
            case 2: strokes.reverse()
            case 3:
                if strokes.count > 1 { strokes.removeLast() }
            default: break
            }
            if index % 17 == 0 { title = "Sections \(index)" }
            if index % 29 == 0 { pageCount = index % 12 + 1 }
            expected.append(try await writer.save(
                id: id,
                content: NotebookContent(
                    title: title, pageCount: pageCount, strokes: strokes, editStamp: Fixtures.stamp(index)
                ),
                expectedRevisionID: expected.last?.revisionID
            ))
        }
        let directory = Fixtures.noteDirectory(root: root, id: id)
        let headURL = directory.appendingPathComponent("HEAD.json")
        let headBytes = try Data(contentsOf: headURL)
        let oldDigest = NotebookDigest.sha256(expected[0].content.strokes[0].data)
        let currentDigest = NotebookDigest.sha256(try XCTUnwrap(expected.last?.content.strokes.first).data)
        for digest in Set([oldDigest, currentDigest]) {
            try Data("unread archive damage".utf8).write(
                to: directory.appendingPathComponent("assets/\(digest).stroke")
            )
        }
        let verified = Fixtures.VerificationLog()
        let reader = try NotebookRepository(
            rootURL: root, assetVerificationObserver: { verified.record($0) }
        )
        let layout = try Fixtures.layout(root: root, id: id)
        let pageLimit = 50
        var baselineOffset = expected.count - pageLimit
        while true {
            let event = try Fixtures.object(at: layout.eventURL(expected[baselineOffset].revisionID))
            if event["checkpointDigest"] is String { break }
            guard baselineOffset > 0 else {
                XCTFail("The metadata fixture must have a reachable checkpoint baseline.")
                return
            }
            baselineOffset -= 1
        }
        let prefixLength = expected.count - baselineOffset
        XCTAssertLessThan(prefixLength, 100, "Actual byte-funded checkpoints must keep this fixture's first page local.")
        let before = await reader.storageMetrics()
        let firstPage = try await reader.history(id: id, limit: pageLimit)
        XCTAssertEqual(firstPage.map(\.revisionID), expected.suffix(pageLimit).reversed().map(\.revisionID))
        let afterFirst = await reader.storageMetrics()
        XCTAssertGreaterThan(afterFirst.metadataReadCalls - before.metadataReadCalls, 0)
        XCTAssertLessThanOrEqual(
            afterFirst.metadataReadCalls - before.metadataReadCalls, 2 * prefixLength + 4
        )
        XCTAssertLessThan(afterFirst.metadataReadCalls - before.metadataReadCalls, expected.count / 2)
        let repeated = try await reader.history(id: id, limit: pageLimit)
        XCTAssertEqual(repeated, firstPage)
        let afterRepeat = await reader.storageMetrics()
        XCTAssertEqual(afterRepeat.metadataReadCalls - afterFirst.metadataReadCalls, 1)
        XCTAssertEqual(afterRepeat.metadataReadBytes - afterFirst.metadataReadBytes, headBytes.count)
        do {
            _ = try await reader.captureHistoryPin(id: id, expectedRevisionID: UUID())
            XCTFail("A stale expected revision must invalidate cached verification.")
        } catch NotebookRepositoryError.revisionConflict {}
        let beforeRefresh = await reader.storageMetrics()
        let refreshed = try await reader.history(id: id, limit: pageLimit)
        XCTAssertEqual(refreshed, firstPage)
        let afterRefresh = await reader.storageMetrics()
        XCTAssertGreaterThan(afterRefresh.metadataReadCalls - beforeRefresh.metadataReadCalls, 1)
        XCTAssertLessThanOrEqual(
            afterRefresh.metadataReadCalls - beforeRefresh.metadataReadCalls, 2 * prefixLength + 4
        )
        var summaries: [NotebookRevisionSummary] = []
        var cursor: UUID?
        while true {
            let page = try await reader.history(id: id, beforeRevisionID: cursor, limit: 137)
            summaries.append(contentsOf: page)
            guard page.count == 137 else { break }
            cursor = page.last?.revisionID
        }
        XCTAssertEqual(summaries.count, 1_000)
        XCTAssertEqual(Set(summaries.map(\.revisionID)).count, 1_000)
        for (summary, stored) in zip(summaries, expected.reversed()) {
            XCTAssertEqual(summary, NotebookRevisionSummary(
                notebookID: id, revisionID: stored.revisionID, sequence: stored.sequence,
                title: stored.content.title, pageCount: stored.content.pageCount,
                strokeCount: stored.content.strokes.count, editStamp: stored.content.editStamp,
                savedAt: stored.savedAt
            ))
        }
        let oldest = try XCTUnwrap(expected.first)
        let empty = try await reader.history(id: id, beforeRevisionID: oldest.revisionID, limit: 137)
        XCTAssertTrue(empty.isEmpty)
        for limit in [0, 201] {
            do {
                _ = try await reader.history(id: id, limit: limit)
                XCTFail("Invalid metadata history page bounds must be refused.")
            } catch NotebookRepositoryError.invalidContent(_) {}
        }
        do {
            _ = try await reader.history(id: id, beforeRevisionID: UUID(), limit: 137)
            XCTFail("An unselected cursor must be refused.")
        } catch NotebookRepositoryError.invalidContent(_) {}
        let after = await reader.storageMetrics()
        XCTAssertTrue(verified.snapshot().isEmpty)
        XCTAssertEqual(after.assetReadCalls - before.assetReadCalls, 0)
        XCTAssertEqual(after.assetReadBytes - before.assetReadBytes, 0)
        XCTAssertEqual(after.assetHashBytes - before.assetHashBytes, 0)
        XCTAssertGreaterThan(after.metadataReadCalls - before.metadataReadCalls, 0)
        XCTAssertEqual(try Data(contentsOf: headURL), headBytes)
    }

    func testHistoricalTargetDeduplicatesItsOwnReferencesAndNeverSelectsAValidOrphan() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = Fixtures.asset(index: 1)
        let references = [shared, NotebookStroke(id: UUID(), data: shared.data)]
        let fixture = try Fixtures.writeLegacy(root: root, contents: [
            NotebookContent(title: "Target", pageCount: 3, strokes: references, editStamp: Fixtures.stamp(1)),
            NotebookContent(title: "Current", pageCount: 5, strokes: [Fixtures.asset(index: 2)])
        ])
        let verified = Fixtures.VerificationLog()
        let reader = try NotebookRepository(
            rootURL: root, assetVerificationObserver: { verified.record($0) }
        )
        let before = await reader.storageMetrics()
        let target = try await reader.loadRevision(
            id: fixture.notebookID, revisionID: try XCTUnwrap(fixture.states.first).revisionID
        )
        Fixtures.assertSame(target, try XCTUnwrap(fixture.states.first))
        let after = await reader.storageMetrics()
        XCTAssertEqual(verified.snapshot(), [NotebookDigest.sha256(shared.data)])
        XCTAssertEqual(after.assetReadCalls - before.assetReadCalls, 1)
        XCTAssertEqual(after.assetReadBytes - before.assetReadBytes, shared.data.count)
        XCTAssertEqual(after.assetHashBytes - before.assetHashBytes, shared.data.count)
        do {
            _ = try await reader.loadRevision(id: fixture.notebookID, revisionID: fixture.orphanRevisionID)
            XCTFail("A structurally valid legacy orphan is outside selected history.")
        } catch NotebookRepositoryError.invalidContent(_) {}
        try Fixtures.assertOriginalFiles(fixture, root: root, includeHead: true)
    }

    func testAuthenticatedCurrentCheckpointCannotHideMalformedDeltaOperations() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let writer = try NotebookRepository(rootURL: root)
        let saved = try await writer.save(
            id: id,
            content: NotebookContent(title: "Shape", pageCount: 3, strokes: [
                Fixtures.asset(index: 1), Fixtures.asset(index: 2)
            ]),
            expectedRevisionID: nil
        )
        let layout = try Fixtures.layout(root: root, id: id)
        let eventURL = layout.eventURL(saved.revisionID)
        let headURL = layout.notebookDirectory.appendingPathComponent("HEAD.json")
        let originalEvent = try Data(contentsOf: eventURL)
        let originalHead = try Data(contentsOf: headURL)
        defer {
            try? originalEvent.write(to: eventURL)
            try? originalHead.write(to: headURL)
        }
        let event = try Fixtures.object(at: eventURL)
        XCTAssertNotNil(event["checkpointDigest"])
        let delta = try XCTUnwrap(event["delta"] as? [String: Any])
        let upserts = try XCTUnwrap(delta["upserts"] as? [[String: Any]])
        let first = try XCTUnwrap(upserts.first)
        let firstID = try XCTUnwrap(first["id"] as? String)
        let variants = [
            "digest", "upsert identities", "removal identities", "conflicting removal",
            "placement identities", "placement index", "conflicting order", "replacement identities",
            "title bound", "page bound"
        ]
        for variant in variants {
            var malformed = delta
            switch variant {
            case "digest":
                var changed = upserts
                changed[0]["digest"] = "invalid"
                malformed["upserts"] = changed
            case "upsert identities": malformed["upserts"] = upserts + [first]
            case "removal identities":
                let removed = UUID().uuidString
                malformed["removedIDs"] = [removed, removed]
            case "conflicting removal": malformed["removedIDs"] = [firstID]
            case "placement identities":
                malformed["placements"] = [
                    ["id": firstID, "index": 0], ["id": firstID, "index": 0]
                ]
            case "placement index": malformed["placements"] = [["id": firstID, "index": -1]]
            case "conflicting order":
                malformed["placements"] = [["id": firstID, "index": 0]]
                malformed["replacementOrder"] = upserts.compactMap { $0["id"] as? String }
            case "replacement identities": malformed["replacementOrder"] = [firstID, firstID]
            case "title bound": malformed["titleChange"] = String(repeating: "t", count: 4_097)
            case "page bound": malformed["pageCountChange"] = 0
            default: throw Fixtures.FixtureError.malformedMetadata
            }
            var damagedEvent = event
            damagedEvent["delta"] = malformed
            let bytes = try JSONSerialization.data(withJSONObject: damagedEvent, options: [.sortedKeys])
            try bytes.write(to: eventURL)
            var head = try JSONSerialization.jsonObject(with: originalHead) as? [String: Any]
            head?["revisionDigest"] = NotebookDigest.sha256(bytes)
            let selectedHead = try JSONSerialization.data(
                withJSONObject: try XCTUnwrap(head), options: [.sortedKeys]
            )
            try selectedHead.write(to: headURL)
            let reader = try NotebookRepository(rootURL: root)
            do {
                _ = try await reader.open(id: id)
                XCTFail("A current checkpoint must not bypass malformed \(variant).")
            } catch NotebookRepositoryError.corruptData(_) {}
            do {
                _ = try await reader.history(id: id, limit: 1)
                XCTFail("Metadata summaries must reject malformed \(variant).")
            } catch NotebookRepositoryError.corruptData(_) {}
            XCTAssertEqual(try Data(contentsOf: headURL), selectedHead)
        }
    }

}
