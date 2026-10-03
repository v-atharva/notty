import Foundation
import XCTest
@testable import NottyCore

@MainActor
final class NotebookIncrementalStorageTests: XCTestCase {
    func testCheckpointSizeMatchesEncodedEscapingCountsAndSequenceBoundaries() throws {
        typealias Format = NotebookRevisionFormat
        let references = (0..<10_000).map { _ in
            Format.Reference(id: UUID(), digest: String(repeating: "a", count: 64))
        }
        let titles = ["", "quotes \" slash / backslash \\ controls \n\t\u{0001}", "é中🙂", String(repeating: "x", count: 4_096)]
        for title in titles {
            let size = try Format.CheckpointSize(title: title)
            for count in [0, 1, 10, 10_000] {
                for sequence in [1, 9, 10, 99, 100, Int.max] {
                    for pages in [1, 12] {
                        let checkpoint = Format.Checkpoint(
                            schemaVersion: 2, notebookID: UUID(), revisionID: UUID(), sequence: sequence,
                            state: Format.State(title: title, pageCount: pages, strokes: Array(references.prefix(count)))
                        )
                        XCTAssertEqual(
                            try size.bytes(strokeCount: count, pageCount: pages, sequence: sequence),
                            try Format.encode(checkpoint).count
                        )
                    }
                }
            }
        }
    }

    func testOrdinaryAppendByteWorkIsBoundedAndSecondWarmSaveReadsOnlyHead() async throws {
        let small = try await appendMetrics(strokeCount: 100)
        let large = try await appendMetrics(strokeCount: 2_000)
        for key in [
            "assetHashBytes", "metadataHashBytes", "assetReadBytes", "metadataReadBytes",
            "assetWrittenBytes", "metadataWrittenBytes", "metadataEncodedBytes"
        ] {
            XCTAssertLessThanOrEqual(Double(large[key, default: 0]), Double(small[key, default: 0]) * 1.5, key)
        }
        XCTAssertEqual(small["assetReadCalls"], 0)
        XCTAssertEqual(large["assetReadCalls"], 0)
        XCTAssertEqual(small["metadataReadCalls"], 1)
        XCTAssertEqual(large["metadataReadCalls"], 1)
        XCTAssertEqual(small["checkpointEncodings"], 0)
        XCTAssertEqual(large["checkpointEncodings"], 0)
        XCTAssertGreaterThan(large["referenceComparisons", default: 0], small["referenceComparisons", default: 0])
        if let directory = ProcessInfo.processInfo.environment["NOTTY_SAVE_METRICS_DIRECTORY"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: ["ordinary100": small, "ordinary2000": large], options: [.sortedKeys]
            )
            try data.write(to: url.appendingPathComponent("incremental-storage.json"))
        }
    }

    func testPublicArchiveBytesHashWhileTrustedArchiveEqualityRemainsCompatible() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NotebookRepository(rootURL: root)
        let id = UUID()
        let data = Data(repeating: 23, count: 1_024)
        let publicStroke = NotebookStroke(id: UUID(), data: data)
        let trusted = NotebookStroke(id: publicStroke.id, data: data, validatedDigest: NotebookDigest.sha256(data))
        XCTAssertEqual(publicStroke, trusted)
        XCTAssertNil(publicStroke.cachedDigest)
        let first = try await repository.save(id: id, content: content([publicStroke]), expectedRevisionID: nil)
        let initial = await repository.storageMetrics()
        XCTAssertEqual(initial.assetHashCalls, 1)
        XCTAssertEqual(initial.assetHashBytes, data.count)
        _ = try await repository.save(id: id, content: content([trusted]), expectedRevisionID: first.revisionID)
        let after = await repository.storageMetrics()
        XCTAssertEqual(after.assetHashBytes, initial.assetHashBytes)
        XCTAssertEqual(after.assetReadCalls, initial.assetReadCalls)
    }

    func testBatchCommitsEveryOrderedStateAndStampWithOneHeadPublication() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NotebookRepository(rootURL: root)
        let id = UUID()
        let a = stroke(1)
        let b = stroke(2)
        let changed = NotebookStroke(id: a.id, data: Data("changed archive".utf8))
        let states = [[a], [a, b], [b, a], [b, changed], [changed], [], [b], [a, b]]
        let session = UUID()
        let edits = states.enumerated().map { index, strokes in
            NotebookSaveEdit(id: UUID(), content: NotebookContent(
                title: "State \(index)", pageCount: index % 12 + 1, strokes: strokes,
                editStamp: NotebookEditStamp(
                    capturedAt: Date(timeIntervalSinceReferenceDate: Double(index + 1)),
                    uptime: Double(index), sessionID: session
                )
            ))
        }
        let result = try await repository.saveBatch(id: id, edits: edits, expectedRevisionID: nil)
        XCTAssertEqual(result.committed.map(\.editID), edits.map(\.id))
        XCTAssertEqual(result.committed.map(\.sequence), Array(1...8))
        XCTAssertNil(result.rejection)
        let metrics = await repository.storageMetrics()
        XCTAssertEqual(metrics.headPublications, 1)
        for (edit, receipt) in zip(edits, result.committed) {
            let historical = try await repository.loadRevision(id: id, revisionID: receipt.revisionID)
            XCTAssertEqual(historical.content, edit.content)
            XCTAssertEqual(historical.savedAt, receipt.savedAt)
            XCTAssertEqual(historical.sequence, receipt.sequence)
        }
        let summaries = try await repository.history(id: id)
        XCTAssertEqual(summaries.map(\.revisionID), result.committed.reversed().map(\.revisionID))
    }

    func testValidationFailurePublishesOnlyValidPrefixAndNeverSuffixAssets() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NotebookRepository(rootURL: root)
        let id = UUID()
        let good = NotebookSaveEdit(id: UUID(), content: content([stroke(1)]))
        let invalid = NotebookSaveEdit(id: UUID(), content: NotebookContent(title: "Invalid", pageCount: 13, strokes: []))
        let suffixStroke = stroke(2)
        let suffix = NotebookSaveEdit(id: UUID(), content: content([suffixStroke]))
        let result = try await repository.saveBatch(id: id, edits: [good, invalid, suffix], expectedRevisionID: nil)
        XCTAssertEqual(result.committed.map(\.editID), [good.id])
        XCTAssertEqual(result.rejection?.index, 1)
        XCTAssertEqual(result.rejection?.editID, invalid.id)
        guard case .invalidContent? = result.rejection?.error else {
            return XCTFail("The invalid candidate was not reported.")
        }
        let loadedValue = try await repository.load(id: id)
        let loaded = try XCTUnwrap(loadedValue)
        XCTAssertEqual(loaded.content, good.content)
        let suffixAsset = notebook(root, id).appendingPathComponent("assets/\(NotebookDigest.sha256(suffixStroke.data)).stroke")
        XCTAssertFalse(FileManager.default.fileExists(atPath: suffixAsset.path))
        let repairedEdit = NotebookSaveEdit(id: invalid.id, content: content([suffixStroke]))
        let next = try await repository.saveBatch(
            id: id, edits: [repairedEdit, suffix], expectedRevisionID: loaded.revisionID
        )
        XCTAssertEqual(next.committed.map(\.editID), [invalid.id, suffix.id])
        XCTAssertEqual(next.committed.map(\.sequence), [2, 3])
    }

    func testInvalidFirstCandidateLeavesHeadUnchangedAndDuplicateEditIDRejectsItsIndex() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NotebookRepository(rootURL: root)
        let id = UUID()
        let first = try await repository.save(id: id, content: content([]), expectedRevisionID: nil)
        let head = notebook(root, id).appendingPathComponent("HEAD.json")
        let bytes = try Data(contentsOf: head)
        let invalid = NotebookSaveEdit(id: UUID(), content: NotebookContent(
            title: "Invalid", pageCount: 1, strokes: [],
            editStamp: NotebookEditStamp(capturedAt: .distantPast, uptime: .nan, sessionID: UUID())
        ))
        let none = try await repository.saveBatch(id: id, edits: [invalid], expectedRevisionID: first.revisionID)
        XCTAssertTrue(none.committed.isEmpty)
        XCTAssertEqual(none.rejection?.index, 0)
        XCTAssertEqual(try Data(contentsOf: head), bytes)
        let edit = NotebookSaveEdit(id: UUID(), content: content([stroke(1)]))
        let duplicate = try await repository.saveBatch(id: id, edits: [edit, edit], expectedRevisionID: first.revisionID)
        XCTAssertEqual(duplicate.committed.map(\.editID), [edit.id])
        XCTAssertEqual(duplicate.rejection?.index, 1)
        XCTAssertEqual(duplicate.rejection?.editID, edit.id)
    }

    func testBatchPublicationFaultsAcknowledgeNoEditsAndRetryExactStates() async throws {
        for stage in NotebookWriteStage.allCases where stage != .beforeNotebookPublication {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let id = UUID()
            let baseline = try await NotebookRepository(rootURL: root).save(
                id: id, content: content([]), expectedRevisionID: nil
            )
            let fault = PublicationFault(stage: stage, occurrence: stage == .revisionPublished ? 2 : 1)
            let repository = try NotebookRepository(rootURL: root, faultInjector: { try fault.visit($0) })
            let headURL = notebook(root, id).appendingPathComponent("HEAD.json")
            let head = try Data(contentsOf: headURL)
            let edits = (1...3).map { value in
                NotebookSaveEdit(id: UUID(), content: content([stroke(value)]))
            }
            do {
                _ = try await repository.saveBatch(id: id, edits: edits, expectedRevisionID: baseline.revisionID)
                XCTFail("A publication fault did not interrupt the transaction.")
            } catch {
                XCTAssertTrue(error is PublicationFailure, "\(stage): \(error)")
            }
            XCTAssertEqual(try Data(contentsOf: headURL), head)
            fault.disable()
            let retry = try await repository.saveBatch(id: id, edits: edits, expectedRevisionID: baseline.revisionID)
            XCTAssertEqual(retry.committed.map(\.editID), edits.map(\.id))
            XCTAssertEqual(retry.committed.map(\.sequence), [2, 3, 4])
            for (edit, receipt) in zip(edits, retry.committed) {
                let historical = try await repository.loadRevision(id: id, revisionID: receipt.revisionID)
                XCTAssertEqual(historical.content, edit.content)
            }
        }
    }

    func testBatchCapacityAndNewByteBudgetLeaveHealthyTail() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NotebookRepository(rootURL: root)
        let id = UUID()
        let edits = (0..<9).map { value in
            NotebookSaveEdit(id: UUID(), content: content([], title: "Edit \(value)"))
        }
        let first = try await repository.saveBatch(id: id, edits: edits, expectedRevisionID: nil)
        XCTAssertEqual(first.committed.count, 8)
        XCTAssertNil(first.rejection)
        let second = try await repository.saveBatch(
            id: id, edits: Array(edits.dropFirst(8)), expectedRevisionID: first.committed.last?.revisionID
        )
        XCTAssertEqual(second.committed.map(\.editID), [edits[8].id])

        let largeID = UUID()
        let large = (0..<8).map { value in
            NotebookSaveEdit(id: UUID(), content: content([
                NotebookStroke(id: UUID(), data: Data(repeating: UInt8(value), count: 9 * 1_024 * 1_024))
            ]))
        }
        let chunk = try await repository.saveBatch(id: largeID, edits: large, expectedRevisionID: nil)
        XCTAssertEqual(chunk.committed.count, 7)
        XCTAssertNil(chunk.rejection)
        let tail = try await repository.saveBatch(
            id: largeID, edits: Array(large.dropFirst(7)), expectedRevisionID: chunk.committed.last?.revisionID
        )
        XCTAssertEqual(tail.committed.map(\.editID), [large[7].id])
    }

    func testErrorForeignHeadAndRawHeadRewriteInvalidateWarmGeneration() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let archive = stroke(1)
        let repository = try NotebookRepository(rootURL: root)
        let first = try await repository.save(id: id, content: content([archive]), expectedRevisionID: nil)
        let second = try await repository.save(id: id, content: content([archive]), expectedRevisionID: first.revisionID)
        do {
            _ = try await repository.save(id: id, content: content([archive]), expectedRevisionID: first.revisionID)
            XCTFail("A stale expected revision was accepted.")
        } catch NotebookRepositoryError.revisionConflict {}
        var before = await repository.storageMetrics()
        let third = try await repository.save(id: id, content: content([archive]), expectedRevisionID: second.revisionID)
        var after = await repository.storageMetrics()
        XCTAssertGreaterThan(after.assetReadCalls, before.assetReadCalls)

        let foreign = try await NotebookRepository(rootURL: root).save(
            id: id, content: content([archive], title: "Foreign"), expectedRevisionID: third.revisionID
        )
        before = await repository.storageMetrics()
        let fourth = try await repository.save(id: id, content: content([archive]), expectedRevisionID: foreign.revisionID)
        after = await repository.storageMetrics()
        XCTAssertGreaterThan(after.assetReadCalls, before.assetReadCalls)

        let head = notebook(root, id).appendingPathComponent("HEAD.json")
        var raw = try Data(contentsOf: head)
        raw.append(contentsOf: [10, 32])
        try raw.write(to: head)
        before = await repository.storageMetrics()
        _ = try await repository.save(id: id, content: content([archive]), expectedRevisionID: fourth.revisionID)
        after = await repository.storageMetrics()
        XCTAssertGreaterThan(after.assetReadCalls, before.assetReadCalls)
    }

    func testExplicitAuditInvalidatesPriorReceiptsAndPreservesRepairPathGuards() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let archive = stroke(1)
        let repository = try NotebookRepository(rootURL: root)
        let first = try await repository.save(id: id, content: content([archive]), expectedRevisionID: nil)
        let asset = notebook(root, id).appendingPathComponent("assets/\(NotebookDigest.sha256(archive.data)).stroke")
        try Data("damaged".utf8).write(to: asset)
        let warm = try await repository.save(id: id, content: content([archive]), expectedRevisionID: first.revisionID)
        do {
            _ = try await repository.auditHistory(id: id)
            XCTFail("Audit trusted a prior verification receipt as present disk integrity.")
        } catch NotebookRepositoryError.corruptData {}
        let repaired = try await repository.save(id: id, content: content([archive]), expectedRevisionID: warm.revisionID)
        XCTAssertEqual(try Data(contentsOf: asset), archive.data)
        try FileManager.default.removeItem(at: asset)
        try FileManager.default.createDirectory(at: asset, withIntermediateDirectories: false)
        do {
            _ = try await repository.auditHistory(id: id)
            XCTFail("Audit accepted an asset directory.")
        } catch NotebookRepositoryError.unsafePath {}
        let head = try Data(contentsOf: notebook(root, id).appendingPathComponent("HEAD.json"))
        do {
            _ = try await repository.save(id: id, content: content([archive]), expectedRevisionID: repaired.revisionID)
            XCTFail("Refresh replaced an unsafe asset entry.")
        } catch NotebookRepositoryError.unsafePath {}
        XCTAssertEqual(try Data(contentsOf: notebook(root, id).appendingPathComponent("HEAD.json")), head)
    }

    func testFundedCheckpointBurstsEncodeOnlyAfterActualByteCreditAccumulates() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NotebookRepository(rootURL: root)
        let id = UUID()
        let drawing = content((0..<128).map { trustedStroke($0) }, title: String(repeating: "x", count: 4_096))
        var latest = try await repository.save(id: id, content: drawing, expectedRevisionID: nil)
        let initial = await repository.storageMetrics()
        XCTAssertEqual(initial.checkpointEncodings, 1)
        var credit = 0
        var bursts = 0
        for index in 1...100 {
            let before = await repository.storageMetrics()
            latest = try await repository.save(id: id, content: drawing, expectedRevisionID: latest.revisionID)
            let after = await repository.storageMetrics()
            let layout = try NotebookHistoryTestFixtures.layout(root: root, id: id)
            let eventData = try Data(contentsOf: layout.eventURL(latest.revisionID))
            credit += eventData.count
            let event: NotebookRevisionFormat.Event = try NotebookRevisionFormat.decode(eventData)
            if let digest = event.checkpointDigest {
                let checkpointBytes = try Data(contentsOf: layout.checkpointURL(digest)).count
                XCTAssertGreaterThanOrEqual(credit, checkpointBytes)
                XCTAssertEqual(after.checkpointEncodings - before.checkpointEncodings, 1)
                XCTAssertEqual(after.checkpointWrittenBytes - before.checkpointWrittenBytes, checkpointBytes)
                XCTAssertEqual(after.checkpointPublications - before.checkpointPublications, 1)
                bursts += 1
                credit = 0
            } else {
                XCTAssertEqual(after.checkpointEncodings, before.checkpointEncodings)
                XCTAssertEqual(after.checkpointWrittenBytes, before.checkpointWrittenBytes)
                XCTAssertEqual(after.metadataEncodeCalls - before.metadataEncodeCalls, 2)
            }
            if index <= 20 { XCTAssertNil(event.checkpointDigest) }
            XCTAssertEqual(after.assetReadCalls, before.assetReadCalls)
        }
        XCTAssertGreaterThan(bursts, 0)
        let audit = try await repository.auditHistory(id: id)
        XCTAssertEqual(audit.revisionCount, 101)
        if let directory = ProcessInfo.processInfo.environment["NOTTY_SAVE_METRICS_DIRECTORY"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let final = await repository.storageMetrics()
            let report = [
                "edits": 100, "fundedCheckpointBursts": bursts,
                "checkpointWrittenBytes": final.checkpointWrittenBytes - initial.checkpointWrittenBytes,
                "metadataWrittenBytes": final.metadataWrittenBytes - initial.metadataWrittenBytes
            ]
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
                .write(to: url.appendingPathComponent("checkpoint-storage.json"))
        }
    }

    func testMigratedWarmSavesSkipReceiptChainAndExplicitMigrationInvalidatesReceipts() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try NotebookHistoryTestFixtures.writeLegacy(root: root)
        let latest = try XCTUnwrap(fixture.states.last)
        let repository = try NotebookRepository(rootURL: root)
        _ = try await repository.migrateHistory(id: fixture.notebookID, expectedRevisionID: latest.revisionID)
        let first = try await repository.save(
            id: fixture.notebookID, content: latest.content, expectedRevisionID: latest.revisionID
        )
        var before = await repository.storageMetrics()
        let second = try await repository.save(
            id: fixture.notebookID, content: latest.content, expectedRevisionID: first.revisionID
        )
        var after = await repository.storageMetrics()
        XCTAssertEqual(after.assetReadCalls, before.assetReadCalls)
        XCTAssertEqual(after.metadataReadCalls - before.metadataReadCalls, 1)

        _ = try await repository.migrateHistory(id: fixture.notebookID, expectedRevisionID: second.revisionID)
        before = await repository.storageMetrics()
        let third = try await repository.save(
            id: fixture.notebookID, content: latest.content, expectedRevisionID: second.revisionID
        )
        after = await repository.storageMetrics()
        XCTAssertGreaterThan(after.assetReadCalls, before.assetReadCalls)
        do {
            _ = try await repository.rollbackMigration(id: fixture.notebookID, expectedRevisionID: third.revisionID)
            XCTFail("Rollback accepted a generation beyond the migration anchor.")
        } catch NotebookRepositoryError.revisionConflict {}
        before = await repository.storageMetrics()
        _ = try await repository.save(
            id: fixture.notebookID, content: latest.content, expectedRevisionID: third.revisionID
        )
        after = await repository.storageMetrics()
        XCTAssertGreaterThan(after.assetReadCalls, before.assetReadCalls)
    }

    func testSuccessfulRollbackAndRemigrationCannotReuseSameRevisionIdentityAsGeneration() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try NotebookHistoryTestFixtures.writeLegacy(root: root)
        let latest = try XCTUnwrap(fixture.states.last)
        let repository = try NotebookRepository(rootURL: root)
        let first = try await repository.migrateHistory(id: fixture.notebookID, expectedRevisionID: latest.revisionID)
        let rolledBack = try await repository.rollbackMigration(
            id: fixture.notebookID, expectedRevisionID: latest.revisionID
        )
        XCTAssertEqual(rolledBack.revisionID, latest.revisionID)
        XCTAssertEqual(rolledBack.content, latest.content)
        let saved = try await repository.save(
            id: fixture.notebookID, content: latest.content, expectedRevisionID: latest.revisionID
        )
        let layout = try NotebookHistoryTestFixtures.layout(root: root, id: fixture.notebookID)
        XCTAssertNotEqual(layout.generationID, first.generationID)
        let historical = try await repository.loadRevision(id: fixture.notebookID, revisionID: latest.revisionID)
        NotebookHistoryTestFixtures.assertSame(historical, latest)
        XCTAssertEqual(saved.sequence, latest.sequence + 1)
    }

    func testGroupRefreshRepairsRegularCandidateAssetBeforeSelectingHistory() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let archive = stroke(1)
        let baseline = try await NotebookRepository(rootURL: root).save(
            id: id, content: content([archive]), expectedRevisionID: nil
        )
        let asset = notebook(root, id).appendingPathComponent("assets/\(NotebookDigest.sha256(archive.data)).stroke")
        try Data("damaged".utf8).write(to: asset)
        let repository = try NotebookRepository(rootURL: root)
        let edits = [
            NotebookSaveEdit(id: UUID(), content: content([archive], title: "First")),
            NotebookSaveEdit(id: UUID(), content: content([archive, stroke(2)], title: "Second"))
        ]
        let result = try await repository.saveBatch(id: id, edits: edits, expectedRevisionID: baseline.revisionID)
        XCTAssertEqual(result.committed.map(\.editID), edits.map(\.id))
        XCTAssertEqual(try Data(contentsOf: asset), archive.data)
        let metrics = await repository.storageMetrics()
        XCTAssertEqual(metrics.headPublications, 1)
        let report = await repository.maintenanceReport()
        XCTAssertEqual(report[.repairedAsset], 1)
        let historical = try await repository.loadRevision(id: id, revisionID: baseline.revisionID)
        XCTAssertEqual(historical.content, baseline.content)
    }

    func testSuccessfulFullOpenSeedsFirstSaveWithOnlyHeadRead() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let saved = try await NotebookRepository(rootURL: root).save(
            id: id, content: content([stroke(1), stroke(2)]), expectedRevisionID: nil
        )
        let repository = try NotebookRepository(rootURL: root)
        let loadedValue = try await repository.load(id: id)
        let loaded = try XCTUnwrap(loadedValue)
        XCTAssertEqual(loaded.revisionID, saved.revisionID)
        XCTAssertTrue(loaded.content.strokes.allSatisfy { $0.cachedDigest != nil })
        let before = await repository.storageMetrics()
        _ = try await repository.save(id: id, content: loaded.content, expectedRevisionID: loaded.revisionID)
        let after = await repository.storageMetrics()
        XCTAssertEqual(after.assetReadCalls, before.assetReadCalls)
        XCTAssertEqual(after.assetHashBytes, before.assetHashBytes)
        XCTAssertEqual(after.metadataReadCalls - before.metadataReadCalls, 1)
    }

    func testFailedFullOpenDiscardsPriorGenerationBeforeCandidateFreeSave() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let archive = stroke(1)
        let repository = try NotebookRepository(rootURL: root)
        let first = try await repository.save(id: id, content: content([archive]), expectedRevisionID: nil)
        let asset = notebook(root, id).appendingPathComponent("assets/\(NotebookDigest.sha256(archive.data)).stroke")
        try Data("damaged".utf8).write(to: asset)
        do {
            _ = try await repository.load(id: id)
            XCTFail("Full open trusted cached verification.")
        } catch NotebookRepositoryError.corruptData {}
        let headURL = notebook(root, id).appendingPathComponent("HEAD.json")
        let bytes = try Data(contentsOf: headURL)
        do {
            _ = try await repository.save(id: id, content: content([]), expectedRevisionID: first.revisionID)
            XCTFail("Failed open left a cached generation available.")
        } catch NotebookRepositoryError.corruptData {}
        XCTAssertEqual(try Data(contentsOf: headURL), bytes)
    }

    private func appendMetrics(strokeCount: Int) async throws -> [String: Int] {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NotebookRepository(rootURL: root)
        let id = UUID()
        var strokes = (0..<strokeCount).map { trustedStroke($0) }
        let title = String(repeating: "x", count: 4_096)
        var saved = try await repository.save(id: id, content: content(strokes, title: title), expectedRevisionID: nil)
        strokes.append(trustedStroke(strokeCount))
        saved = try await repository.save(id: id, content: content(strokes, title: title), expectedRevisionID: saved.revisionID)
        let before = await repository.storageMetrics()
        strokes.append(trustedStroke(strokeCount + 1))
        _ = try await repository.save(id: id, content: content(strokes, title: title), expectedRevisionID: saved.revisionID)
        return difference(before, await repository.storageMetrics())
    }

    private func difference(_ before: NotebookStorageMetrics, _ after: NotebookStorageMetrics) -> [String: Int] {
        [
            "assetHashBytes": after.assetHashBytes - before.assetHashBytes,
            "metadataHashBytes": after.metadataHashBytes - before.metadataHashBytes,
            "assetReadCalls": after.assetReadCalls - before.assetReadCalls,
            "assetReadBytes": after.assetReadBytes - before.assetReadBytes,
            "metadataReadCalls": after.metadataReadCalls - before.metadataReadCalls,
            "metadataReadBytes": after.metadataReadBytes - before.metadataReadBytes,
            "assetWrittenBytes": after.assetWrittenBytes - before.assetWrittenBytes,
            "metadataWrittenBytes": after.metadataWrittenBytes - before.metadataWrittenBytes,
            "metadataEncodedBytes": after.metadataEncodedBytes - before.metadataEncodedBytes,
            "checkpointEncodings": after.checkpointEncodings - before.checkpointEncodings,
            "referenceComparisons": after.referenceComparisons - before.referenceComparisons
        ]
    }

    private func trustedStroke(_ value: Int) -> NotebookStroke {
        var data = Data(repeating: 11, count: 1_024)
        let prefix = Data(String(value).utf8)
        data.replaceSubrange(0..<prefix.count, with: prefix)
        return NotebookStroke(id: UUID(), data: data, validatedDigest: NotebookDigest.sha256(data))
    }

    private func stroke(_ value: Int) -> NotebookStroke {
        NotebookStroke(id: UUID(), data: Data("archive \(value)".utf8))
    }

    private func content(_ strokes: [NotebookStroke], title: String = "Notebook") -> NotebookContent {
        NotebookContent(
            title: title, pageCount: 3, strokes: strokes,
            editStamp: NotebookEditStamp(capturedAt: Date(timeIntervalSinceReferenceDate: 123), uptime: 12, sessionID: UUID())
        )
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func notebook(_ root: URL, _ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }
}

private enum PublicationFailure: Error { case stop }

private final class PublicationFault: @unchecked Sendable {
    private let lock = NSLock()
    private let stage: NotebookWriteStage
    private var remaining: Int
    private var enabled = true

    init(stage: NotebookWriteStage, occurrence: Int) {
        self.stage = stage
        self.remaining = occurrence
    }

    func visit(_ value: NotebookWriteStage) throws {
        lock.lock()
        defer { lock.unlock() }
        guard enabled, value == stage else { return }
        remaining -= 1
        if remaining == 0 { throw PublicationFailure.stop }
    }

    func disable() {
        lock.lock()
        defer { lock.unlock() }
        enabled = false
    }
}
