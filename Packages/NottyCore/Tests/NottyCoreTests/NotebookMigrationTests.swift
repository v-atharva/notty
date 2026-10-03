import Foundation
import XCTest
@testable import NottyCore

@MainActor
final class NotebookMigrationTests: XCTestCase {
    private typealias Fixtures = NotebookHistoryTestFixtures

    private enum InjectedFailure: Error {
        case migration(NotebookMigrationStage)
        case write(NotebookWriteStage)
    }

    func testMigrationPreservesEverySelectedStateAndLegacyBytesThenRollsBackExactly() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Fixtures.writeLegacy(root: root)
        let expected = try XCTUnwrap(fixture.states.last)
        let repository = try NotebookRepository(rootURL: root)
        let before = try await repository.load(id: fixture.notebookID)
        Fixtures.assertSame(try XCTUnwrap(before), expected)
        let receipt = try await repository.migrateHistory(
            id: fixture.notebookID, expectedRevisionID: expected.revisionID
        )
        let layout = try Fixtures.layout(root: root, id: fixture.notebookID)
        XCTAssertEqual(receipt.notebookID, fixture.notebookID)
        XCTAssertEqual(receipt.revisionID, expected.revisionID)
        XCTAssertEqual(receipt.generationID, layout.generationID)
        XCTAssertEqual(receipt.revisionCount, fixture.states.count)
        try Fixtures.assertOriginalFiles(fixture, root: root, includeHead: false)
        XCTAssertEqual(
            try Data(contentsOf: layout.generationDirectory.appendingPathComponent("legacy-head.json")),
            fixture.headData
        )
        let summaries = try await repository.history(id: fixture.notebookID, limit: 200)
        XCTAssertEqual(summaries.map(\.revisionID), fixture.states.reversed().map(\.revisionID))
        for (summary, state) in zip(summaries, fixture.states.reversed()) {
            XCTAssertEqual(summary.sequence, state.sequence)
            XCTAssertEqual(summary.editStamp, state.content.editStamp)
            XCTAssertEqual(summary.savedAt, state.savedAt)
            let replayed = try await repository.loadRevision(
                id: fixture.notebookID, revisionID: state.revisionID
            )
            Fixtures.assertSame(replayed, state)
        }
        do {
            _ = try await repository.loadRevision(id: fixture.notebookID, revisionID: fixture.orphanRevisionID)
            XCTFail("Migration must not select an orphan branch.")
        } catch NotebookRepositoryError.invalidContent(_) {}
        let headURL = layout.notebookDirectory.appendingPathComponent("HEAD.json")
        let selectedHead = try Data(contentsOf: headURL)
        let generationFiles = try Fixtures.snapshot(in: layout.generationDirectory)
        let duplicate = try await repository.migrateHistory(
            id: fixture.notebookID, expectedRevisionID: expected.revisionID
        )
        XCTAssertEqual(duplicate, receipt)
        XCTAssertEqual(try Data(contentsOf: headURL), selectedHead)
        XCTAssertEqual(try Fixtures.snapshot(in: layout.generationDirectory), generationFiles)
        let rolledBack = try await repository.rollbackMigration(
            id: fixture.notebookID, expectedRevisionID: expected.revisionID
        )
        Fixtures.assertSame(rolledBack, expected)
        try Fixtures.assertOriginalFiles(fixture, root: root, includeHead: true)
        XCTAssertEqual(try Fixtures.snapshot(in: layout.generationDirectory), generationFiles)
        let reopened = try NotebookRepository(rootURL: root)
        let loaded = try await reopened.load(id: fixture.notebookID)
        Fixtures.assertSame(try XCTUnwrap(loaded), expected)
    }

    func testEveryMigrationFailureStagePreservesExactLegacyHeadAndAllHistoricalStates() async throws {
        XCTAssertEqual(NotebookMigrationStage.allCases, [
            .legacyHeadPreserved, .eventPublished, .checkpointPublished, .generationValidated,
            .beforeGenerationPublication, .generationPublished, .headStaged, .beforeHeadPublication
        ])
        for stage in NotebookMigrationStage.allCases {
            let root = try Fixtures.root()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try Fixtures.writeLegacy(root: root)
            let expected = try XCTUnwrap(fixture.states.last)
            let failing = try NotebookRepository(rootURL: root, migrationFaultInjector: {
                if $0 == stage { throw InjectedFailure.migration(stage) }
            })
            do {
                _ = try await failing.migrateHistory(
                    id: fixture.notebookID, expectedRevisionID: expected.revisionID
                )
                XCTFail("Migration fault was not reached: \(stage)")
            } catch InjectedFailure.migration(let observed) {
                XCTAssertEqual(observed, stage)
            }
            try Fixtures.assertOriginalFiles(fixture, root: root, includeHead: true)
            let reopened = try NotebookRepository(rootURL: root)
            let loaded = try await reopened.load(id: fixture.notebookID)
            Fixtures.assertSame(try XCTUnwrap(loaded), expected)
            for state in fixture.states {
                let replayed = try await reopened.loadRevision(
                    id: fixture.notebookID, revisionID: state.revisionID
                )
                Fixtures.assertSame(replayed, state)
            }
            let receipt = try await reopened.migrateHistory(
                id: fixture.notebookID, expectedRevisionID: expected.revisionID
            )
            XCTAssertEqual(receipt.revisionCount, fixture.states.count)
            let selected = try await reopened.load(id: fixture.notebookID)
            Fixtures.assertSame(try XCTUnwrap(selected), expected)
            try Fixtures.assertOriginalFiles(fixture, root: root, includeHead: false)
        }
    }

    func testIdempotentMigrationAfterNewEditReturnsOriginalReceiptButCannotRollback() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Fixtures.writeLegacy(root: root)
        let anchor = try XCTUnwrap(fixture.states.last)
        let repository = try NotebookRepository(rootURL: root)
        let receipt = try await repository.migrateHistory(
            id: fixture.notebookID, expectedRevisionID: anchor.revisionID
        )
        let advanced = try await repository.save(
            id: fixture.notebookID,
            content: NotebookContent(
                title: "New edit", pageCount: 6, strokes: [Fixtures.asset(index: 99)],
                editStamp: Fixtures.stamp(99)
            ),
            expectedRevisionID: anchor.revisionID
        )
        let headURL = Fixtures.noteDirectory(root: root, id: fixture.notebookID)
            .appendingPathComponent("HEAD.json")
        let headData = try Data(contentsOf: headURL)
        let duplicate = try await repository.migrateHistory(
            id: fixture.notebookID, expectedRevisionID: advanced.revisionID
        )
        XCTAssertEqual(duplicate, receipt)
        do {
            _ = try await repository.rollbackMigration(
                id: fixture.notebookID, expectedRevisionID: advanced.revisionID
            )
            XCTFail("An anchor rollback would discard an accepted version-2 edit.")
        } catch NotebookRepositoryError.revisionConflict {}
        XCTAssertEqual(try Data(contentsOf: headURL), headData)
        let current = try await repository.load(id: fixture.notebookID)
        Fixtures.assertSame(try XCTUnwrap(current), advanced)
        try Fixtures.assertOriginalFiles(fixture, root: root, includeHead: false)
    }

    func testMigrationAndRollbackRejectStaleExpectedRevisionWithoutChangingFiles() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Fixtures.writeLegacy(root: root)
        let anchor = try XCTUnwrap(fixture.states.last)
        let repository = try NotebookRepository(rootURL: root)
        let directory = Fixtures.noteDirectory(root: root, id: fixture.notebookID)
        let original = try Fixtures.snapshot(in: directory)
        do {
            _ = try await repository.migrateHistory(
                id: fixture.notebookID, expectedRevisionID: fixture.states[0].revisionID
            )
            XCTFail("Migration must honor compare-and-swap.")
        } catch NotebookRepositoryError.revisionConflict {}
        XCTAssertEqual(try Fixtures.snapshot(in: directory), original)
        _ = try await repository.migrateHistory(
            id: fixture.notebookID, expectedRevisionID: anchor.revisionID
        )
        let migrated = try Fixtures.snapshot(in: directory)
        for expected in [fixture.states[0].revisionID, UUID()] {
            do {
                _ = try await repository.migrateHistory(id: fixture.notebookID, expectedRevisionID: expected)
                XCTFail("Idempotence must not bypass a stale expected revision.")
            } catch NotebookRepositoryError.revisionConflict {}
            do {
                _ = try await repository.rollbackMigration(id: fixture.notebookID, expectedRevisionID: expected)
                XCTFail("Rollback must honor compare-and-swap.")
            } catch NotebookRepositoryError.revisionConflict {}
        }
        XCTAssertEqual(try Fixtures.snapshot(in: directory), migrated)
    }

    func testFreshVersionTwoNotebookHasNoMigrationReceipt() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NotebookRepository(rootURL: root)
        let id = UUID()
        let saved = try await repository.save(
            id: id, content: NotebookContent(title: "Fresh", pageCount: 3, strokes: []),
            expectedRevisionID: nil
        )
        let directory = Fixtures.noteDirectory(root: root, id: id)
        let original = try Fixtures.snapshot(in: directory)
        do {
            _ = try await repository.migrateHistory(id: id, expectedRevisionID: saved.revisionID)
            XCTFail("A fresh version-2 note was never migrated.")
        } catch NotebookRepositoryError.invalidContent(_) {}
        do {
            _ = try await repository.rollbackMigration(id: id, expectedRevisionID: saved.revisionID)
            XCTFail("A fresh note has no legacy state to restore.")
        } catch NotebookRepositoryError.invalidContent(_) {}
        XCTAssertEqual(try Fixtures.snapshot(in: directory), original)
    }

    func testNormalLegacySaveMigratesThenAppendsExactlyOneCompletedEdit() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Fixtures.writeLegacy(root: root)
        let anchor = try XCTUnwrap(fixture.states.last)
        let repository = try NotebookRepository(rootURL: root)
        let content = NotebookContent(
            title: "Continued", pageCount: 6, strokes: [Fixtures.asset(index: 77)],
            editStamp: Fixtures.stamp(77)
        )
        let saved = try await repository.save(
            id: fixture.notebookID, content: content, expectedRevisionID: anchor.revisionID
        )
        XCTAssertEqual(saved.sequence, anchor.sequence + 1)
        XCTAssertNotEqual(saved.revisionID, anchor.revisionID)
        XCTAssertEqual(saved.content, content)
        _ = try Fixtures.layout(root: root, id: fixture.notebookID)
        let summaries = try await repository.history(id: fixture.notebookID, limit: 200)
        XCTAssertEqual(
            summaries.map(\.revisionID),
            [saved.revisionID] + fixture.states.reversed().map(\.revisionID)
        )
        for state in fixture.states {
            let replayed = try await repository.loadRevision(id: fixture.notebookID, revisionID: state.revisionID)
            Fixtures.assertSame(replayed, state)
        }
        let receipt = try await repository.migrateHistory(
            id: fixture.notebookID, expectedRevisionID: saved.revisionID
        )
        XCTAssertEqual(receipt.revisionID, anchor.revisionID)
        XCTAssertEqual(receipt.revisionCount, fixture.states.count)
        try Fixtures.assertOriginalFiles(fixture, root: root, includeHead: false)
    }

    func testNormalWriteFailureAfterAutomaticMigrationKeepsEquivalentAnchorAndNoNewEdit() async throws {
        XCTAssertEqual(NotebookWriteStage.allCases, [
            .assetStaged, .assetPublished, .revisionStaged, .revisionPublished,
            .headStaged, .beforeHeadPublication, .beforeNotebookPublication
        ])
        for stage in NotebookWriteStage.allCases where stage != .beforeNotebookPublication {
            let root = try Fixtures.root()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try Fixtures.writeLegacy(root: root)
            let anchor = try XCTUnwrap(fixture.states.last)
            let content = NotebookContent(
                title: "Unpublished", pageCount: 6, strokes: [Fixtures.asset(index: 123)],
                editStamp: Fixtures.stamp(123)
            )
            let failing = try NotebookRepository(rootURL: root, faultInjector: {
                if $0 == stage { throw InjectedFailure.write(stage) }
            })
            do {
                _ = try await failing.save(
                    id: fixture.notebookID, content: content, expectedRevisionID: anchor.revisionID
                )
                XCTFail("Normal publication fault was not reached: \(stage)")
            } catch InjectedFailure.write(let observed) {
                XCTAssertEqual(observed, stage)
            }
            _ = try Fixtures.layout(root: root, id: fixture.notebookID)
            try Fixtures.assertOriginalFiles(fixture, root: root, includeHead: false)
            let reopened = try NotebookRepository(rootURL: root)
            let loaded = try await reopened.load(id: fixture.notebookID)
            Fixtures.assertSame(try XCTUnwrap(loaded), anchor)
            let audit = try await reopened.auditHistory(id: fixture.notebookID)
            XCTAssertEqual(audit.revisionCount, fixture.states.count)
            let receipt = try await reopened.migrateHistory(
                id: fixture.notebookID, expectedRevisionID: anchor.revisionID
            )
            XCTAssertEqual(receipt.revisionCount, fixture.states.count)
            let saved = try await reopened.save(
                id: fixture.notebookID, content: content, expectedRevisionID: anchor.revisionID
            )
            XCTAssertEqual(saved.sequence, anchor.sequence + 1)
            let finalAudit = try await reopened.auditHistory(id: fixture.notebookID)
            XCTAssertEqual(finalAudit.revisionCount, fixture.states.count + 1)
        }
    }

    func testMigrationRejectsMissingHistoricalParentAndMalformedLegacyFiles() async throws {
        for removeParent in [false, true] {
            let root = try Fixtures.root()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try Fixtures.writeLegacy(root: root)
            let anchor = try XCTUnwrap(fixture.states.last)
            let directory = Fixtures.noteDirectory(root: root, id: fixture.notebookID)
            let parent = directory.appendingPathComponent(
                "revisions/\(fixture.states[1].revisionID.uuidString.lowercased()).json"
            )
            if removeParent {
                try FileManager.default.removeItem(at: parent)
            } else {
                try Data([0, 1, 2]).write(to: parent)
            }
            let damaged = try Fixtures.snapshot(in: directory)
            let repository = try NotebookRepository(rootURL: root)
            do {
                _ = try await repository.migrateHistory(
                    id: fixture.notebookID, expectedRevisionID: anchor.revisionID
                )
                XCTFail("Migration must audit the complete selected legacy chain.")
            } catch NotebookRepositoryError.corruptData(_) {}
            XCTAssertEqual(try Fixtures.snapshot(in: directory), damaged)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("HEAD.json")), fixture.headData)
        }
    }

    func testRollbackRejectsStructurallyValidHistoricLegacyChangesAgainstMigrationAnchor() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Fixtures.writeLegacy(root: root)
        let anchor = try XCTUnwrap(fixture.states.last)
        let repository = try NotebookRepository(rootURL: root)
        _ = try await repository.migrateHistory(
            id: fixture.notebookID, expectedRevisionID: anchor.revisionID
        )
        let layout = try Fixtures.layout(root: root, id: fixture.notebookID)
        let headURL = layout.notebookDirectory.appendingPathComponent("HEAD.json")
        let selectedHead = try Data(contentsOf: headURL)
        let earlyRevision = layout.notebookDirectory.appendingPathComponent(
            "revisions/\(fixture.states[2].revisionID.uuidString.lowercased()).json"
        )
        let original = try Data(contentsOf: earlyRevision)
        for change in ["title", "editStamp", "strokes"] {
            var object = try Fixtures.object(at: earlyRevision)
            switch change {
            case "title":
                object["title"] = "Changed retained history"
            case "editStamp":
                let stamp = try XCTUnwrap(object["editStamp"] as? [String: Any])
                var changed = stamp
                changed["uptime"] = 9_999
                object["editStamp"] = changed
            default:
                let references = try XCTUnwrap(object["strokes"] as? [[String: Any]])
                object["strokes"] = Array(references.reversed())
            }
            try Fixtures.writeObject(object, to: earlyRevision)
            do {
                _ = try await repository.rollbackMigration(
                    id: fixture.notebookID, expectedRevisionID: anchor.revisionID
                )
                XCTFail("Rollback must compare historical equivalence, including \(change).")
            } catch NotebookRepositoryError.corruptData(_) {}
            XCTAssertEqual(try Data(contentsOf: headURL), selectedHead)
            let loaded = try await repository.load(id: fixture.notebookID)
            Fixtures.assertSame(try XCTUnwrap(loaded), anchor)
            try original.write(to: earlyRevision)
        }
    }

    func testRollbackRejectsDamagedLegacyAssetsWithoutChangingSelectedVersionTwoHead() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Fixtures.writeLegacy(root: root)
        let anchor = try XCTUnwrap(fixture.states.last)
        let repository = try NotebookRepository(rootURL: root)
        _ = try await repository.migrateHistory(
            id: fixture.notebookID, expectedRevisionID: anchor.revisionID
        )
        let layout = try Fixtures.layout(root: root, id: fixture.notebookID)
        let headURL = layout.notebookDirectory.appendingPathComponent("HEAD.json")
        let selectedHead = try Data(contentsOf: headURL)
        let historicalStroke = fixture.states[1].content.strokes[0]
        let asset = layout.notebookDirectory.appendingPathComponent(
            "assets/\(Fixtures.digest(historicalStroke.data)).stroke"
        )
        try Data([0, 1, 2]).write(to: asset)
        do {
            _ = try await repository.rollbackMigration(
                id: fixture.notebookID, expectedRevisionID: anchor.revisionID
            )
            XCTFail("Rollback must reverify all retained legacy assets.")
        } catch NotebookRepositoryError.corruptData(_) {}
        XCTAssertEqual(try Data(contentsOf: headURL), selectedHead)
    }

    func testMigrationAndRollbackRejectDamagedAuthenticatedReceiptOrPreservedHead() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Fixtures.writeLegacy(root: root)
        let anchor = try XCTUnwrap(fixture.states.last)
        let repository = try NotebookRepository(rootURL: root)
        _ = try await repository.migrateHistory(
            id: fixture.notebookID, expectedRevisionID: anchor.revisionID
        )
        let layout = try Fixtures.layout(root: root, id: fixture.notebookID)
        let headURL = layout.notebookDirectory.appendingPathComponent("HEAD.json")
        let selectedHead = try Data(contentsOf: headURL)
        for filename in ["migration.json", "legacy-head.json"] {
            let url = layout.generationDirectory.appendingPathComponent(filename)
            let original = try Data(contentsOf: url)
            try Data([0, 1, 2]).write(to: url)
            let reader = try NotebookRepository(rootURL: root)
            do {
                _ = try await reader.load(id: fixture.notebookID)
                XCTFail("Public open must authenticate selected migration metadata: \(filename).")
            } catch NotebookRepositoryError.corruptData(_) {}
            do {
                _ = try await reader.auditHistory(id: fixture.notebookID)
                XCTFail("Public audit must authenticate selected migration metadata: \(filename).")
            } catch NotebookRepositoryError.corruptData(_) {}
            do {
                _ = try await repository.migrateHistory(
                    id: fixture.notebookID, expectedRevisionID: anchor.revisionID
                )
                XCTFail("Idempotent migration must authenticate \(filename).")
            } catch NotebookRepositoryError.corruptData(_) {}
            do {
                _ = try await repository.rollbackMigration(
                    id: fixture.notebookID, expectedRevisionID: anchor.revisionID
                )
                XCTFail("Rollback must authenticate \(filename).")
            } catch NotebookRepositoryError.corruptData(_) {}
            XCTAssertEqual(try Data(contentsOf: headURL), selectedHead)
            try original.write(to: url)
        }
    }

    func testMigrationReceiptMustMatchReachableAnchorDigestAndRevisionCount() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Fixtures.writeLegacy(root: root)
        let anchor = try XCTUnwrap(fixture.states.last)
        let repository = try NotebookRepository(rootURL: root)
        _ = try await repository.migrateHistory(
            id: fixture.notebookID, expectedRevisionID: anchor.revisionID
        )
        let layout = try Fixtures.layout(root: root, id: fixture.notebookID)
        let headURL = layout.notebookDirectory.appendingPathComponent("HEAD.json")
        let receiptURL = layout.generationDirectory.appendingPathComponent("migration.json")
        let originalHead = try Data(contentsOf: headURL)
        let originalReceipt = try Data(contentsOf: receiptURL)
        for change in ["count", "digest", "identity"] {
            var record = try Fixtures.object(at: receiptURL)
            var receipt = try XCTUnwrap(record["receipt"] as? [String: Any])
            var anchorObject = try XCTUnwrap(record["anchor"] as? [String: Any])
            switch change {
            case "count":
                receipt["revisionCount"] = fixture.states.count + 1
            case "digest":
                anchorObject["revisionDigest"] = String(repeating: "0", count: 64)
            default:
                let unknown = UUID().uuidString
                receipt["revisionID"] = unknown
                anchorObject["revisionID"] = unknown
            }
            record["receipt"] = receipt
            record["anchor"] = anchorObject
            let recordData = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            try recordData.write(to: receiptURL)
            var head = try Fixtures.object(at: headURL)
            head["migrationReceiptDigest"] = Fixtures.digest(recordData)
            try Fixtures.writeObject(head, to: headURL)
            let damagedHead = try Data(contentsOf: headURL)
            let reader = try NotebookRepository(rootURL: root)
            do {
                _ = try await reader.load(id: fixture.notebookID)
                XCTFail("Public open must validate receipt \(change) against selected ancestry.")
            } catch NotebookRepositoryError.corruptData(_) {}
            do {
                _ = try await reader.auditHistory(id: fixture.notebookID)
                XCTFail("Public audit must validate receipt \(change) against selected ancestry.")
            } catch NotebookRepositoryError.corruptData(_) {}
            do {
                _ = try await repository.migrateHistory(
                    id: fixture.notebookID, expectedRevisionID: anchor.revisionID
                )
                XCTFail("Migration receipt must bind the selected \(change).")
            } catch NotebookRepositoryError.corruptData(_) {}
            XCTAssertEqual(try Data(contentsOf: headURL), damagedHead)
            try originalReceipt.write(to: receiptURL)
            try originalHead.write(to: headURL)
        }
    }

    func testRollbackPublicationFaultPreservesVersionTwoHeadAndCanRetry() async throws {
        for stage in [NotebookMigrationStage.headStaged, .beforeHeadPublication] {
            let root = try Fixtures.root()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try Fixtures.writeLegacy(root: root)
            let anchor = try XCTUnwrap(fixture.states.last)
            let repository = try NotebookRepository(rootURL: root)
            _ = try await repository.migrateHistory(
                id: fixture.notebookID, expectedRevisionID: anchor.revisionID
            )
            let directory = Fixtures.noteDirectory(root: root, id: fixture.notebookID)
            let headURL = directory.appendingPathComponent("HEAD.json")
            let selectedHead = try Data(contentsOf: headURL)
            let failing = try NotebookRepository(rootURL: root, migrationFaultInjector: {
                if $0 == stage { throw InjectedFailure.migration(stage) }
            })
            do {
                _ = try await failing.rollbackMigration(
                    id: fixture.notebookID, expectedRevisionID: anchor.revisionID
                )
                XCTFail("Rollback fault was not reached: \(stage)")
            } catch InjectedFailure.migration(let observed) {
                XCTAssertEqual(observed, stage)
            }
            XCTAssertEqual(try Data(contentsOf: headURL), selectedHead)
            let loaded = try await repository.load(id: fixture.notebookID)
            Fixtures.assertSame(try XCTUnwrap(loaded), anchor)
            _ = try await repository.rollbackMigration(
                id: fixture.notebookID, expectedRevisionID: anchor.revisionID
            )
            try Fixtures.assertOriginalFiles(fixture, root: root, includeHead: true)
        }
    }

    func testUnsupportedSchemaIsReportedBeforeFormatSpecificDecoding() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let directory = Fixtures.noteDirectory(root: root, id: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Fixtures.writeObject(["schemaVersion": 99], to: directory.appendingPathComponent("HEAD.json"))
        let repository = try NotebookRepository(rootURL: root)
        do {
            _ = try await repository.load(id: id)
            XCTFail("Unknown schemas must retain their version error.")
        } catch NotebookRepositoryError.unsupportedVersion(let version) {
            XCTAssertEqual(version, 99)
        }
        do {
            _ = try await repository.migrateHistory(id: id, expectedRevisionID: UUID())
            XCTFail("Migration must not decode an unknown schema as a damaged supported format.")
        } catch NotebookRepositoryError.unsupportedVersion(let version) {
            XCTAssertEqual(version, 99)
        }
    }
}
