import Foundation
import XCTest
@testable import NottyCore

final class NotebookBackgroundAuditTests: XCTestCase {
    private typealias Fixtures = NotebookHistoryTestFixtures

    func testCurrentOpeningDefersDamageBeforeTheNearestCheckpointToFullAudit() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let writer = try NotebookRepository(rootURL: root)
        let old = Fixtures.asset(index: 1)
        let current = Fixtures.asset(index: 2)
        let first = try await writer.save(
            id: id,
            content: NotebookContent(title: "Earlier", pageCount: 3, strokes: [old], editStamp: Fixtures.stamp(0)),
            expectedRevisionID: nil
        )
        let layout = try Fixtures.layout(root: root, id: id)
        let firstEvent = try Fixtures.object(at: layout.eventURL(first.revisionID))
        let bootstrap = try XCTUnwrap(firstEvent["checkpointDigest"] as? String)
        var latest = first
        var currentCheckpoint: String?
        for index in 1...32 {
            latest = try await writer.save(
                id: id,
                content: NotebookContent(
                    title: "Current", pageCount: 5, strokes: [current], editStamp: Fixtures.stamp(index)
                ),
                expectedRevisionID: latest.revisionID
            )
            let event = try Fixtures.object(at: layout.eventURL(latest.revisionID))
            if let digest = event["checkpointDigest"] as? String, digest != bootstrap {
                currentCheckpoint = digest
                break
            }
        }
        XCTAssertNotNil(currentCheckpoint, "The fixture must publish a checkpoint beyond the old revision.")
        _ = try XCTUnwrap(currentCheckpoint)
        let headURL = layout.notebookDirectory.appendingPathComponent("HEAD.json")
        let headBytes = try Data(contentsOf: headURL)
        let oldAssetURL = layout.notebookDirectory.appendingPathComponent(
            "assets/\(NotebookDigest.sha256(old.data)).stroke"
        )
        let damagedFiles = [
            layout.eventURL(first.revisionID), layout.checkpointURL(bootstrap), oldAssetURL
        ]
        for url in damagedFiles {
            let original = try Data(contentsOf: url)
            try Data("damaged retained history".utf8).write(to: url)
            defer { try? original.write(to: url) }
            let reader = try NotebookRepository(rootURL: root)
            let loaded = try await reader.load(id: id)
            let opened = try XCTUnwrap(loaded)
            Fixtures.assertSame(opened, latest)
            XCTAssertEqual(try Data(contentsOf: headURL), headBytes)
            do {
                _ = try await reader.auditHistory(id: id)
                XCTFail("Full auditing must reject the damaged retained file: \(url.lastPathComponent)")
            } catch NotebookRepositoryError.corruptData(_) {}
            XCTAssertEqual(try Data(contentsOf: headURL), headBytes)
        }
    }
}
