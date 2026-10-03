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
}
