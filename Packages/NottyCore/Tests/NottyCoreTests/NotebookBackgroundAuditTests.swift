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
    func testCurrentOpeningVerifiesOnePhysicalArchiveButAccountsForEveryReference() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let shared = Fixtures.asset(index: 1, bytes: 4 * 1_024 * 1_024).data
        let strokes = (0..<16).map { _ in NotebookStroke(id: UUID(), data: shared) }
        let writer = try NotebookRepository(rootURL: root)
        let saved = try await writer.save(
            id: id,
            content: NotebookContent(title: "Logical budget", pageCount: 3, strokes: strokes),
            expectedRevisionID: nil
        )
        let verified = Fixtures.VerificationLog()
        let reader = try NotebookRepository(
            rootURL: root, assetVerificationObserver: { verified.record($0) }
        )
        let before = await reader.storageMetrics()
        let loaded = try await reader.load(id: id)
        Fixtures.assertSame(try XCTUnwrap(loaded), saved)
        let after = await reader.storageMetrics()
        XCTAssertEqual(verified.snapshot(), [NotebookDigest.sha256(shared)])
        XCTAssertEqual(after.assetReadCalls - before.assetReadCalls, 1)
        XCTAssertEqual(after.assetReadBytes - before.assetReadBytes, shared.count)
        XCTAssertEqual(after.assetHashBytes - before.assetHashBytes, shared.count)
    }

    func testPersistedCurrentLogicalBudgetCannotHideBehindSharedArchiveBytes() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = Fixtures.asset(index: 1, bytes: 4 * 1_024 * 1_024).data
        let oversized = NotebookContent(
            title: "Oversized", pageCount: 3,
            strokes: (0..<17).map { _ in NotebookStroke(id: UUID(), data: shared) }
        )
        let fixture = try Fixtures.writeLegacy(root: root, contents: [oversized])
        let reader = try NotebookRepository(rootURL: root)
        do {
            _ = try await reader.load(id: fixture.notebookID)
            XCTFail("Seventeen logical references exceed 64 MiB even when one archive is stored.")
        } catch NotebookRepositoryError.corruptData(_) {}
        try Fixtures.assertOriginalFiles(fixture, root: root, includeHead: true)
    }

    func testAtomicOpenAndFreshPinsMatchExactSelectedRevisions() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let repository = try NotebookRepository(rootURL: root)
        let content = NotebookContent(title: "Pinned", pageCount: 3, strokes: [Fixtures.asset(index: 1)])
        let missing = try await repository.open(id: id)
        XCTAssertNil(missing)
        let first = try await repository.save(id: id, content: content, expectedRevisionID: nil)
        let result = try await repository.open(id: id)
        let opened = try XCTUnwrap(result)
        Fixtures.assertSame(opened.notebook, first)
        XCTAssertEqual(opened.historyPin.notebookID, first.id)
        XCTAssertEqual(opened.historyPin.revisionID, first.revisionID)
        XCTAssertEqual(opened.historyPin.sequence, first.sequence)
        XCTAssertFalse(opened.historyPin.requiresFirstPublicationRefresh)
        let before = await repository.storageMetrics()
        let same = try await repository.captureHistoryPin(id: id, expectedRevisionID: first.revisionID)
        let after = await repository.storageMetrics()
        XCTAssertEqual(same, opened.historyPin)
        XCTAssertEqual(after.assetReadCalls - before.assetReadCalls, 0)
        XCTAssertEqual(after.assetReadBytes - before.assetReadBytes, 0)
        XCTAssertLessThanOrEqual(after.metadataReadCalls - before.metadataReadCalls, 2)

        let foreign = try NotebookRepository(rootURL: root)
        let second = try await foreign.save(
            id: id,
            content: NotebookContent(
                title: content.title, pageCount: content.pageCount, strokes: content.strokes,
                editStamp: Fixtures.stamp(1)
            ),
            expectedRevisionID: first.revisionID
        )
        do {
            _ = try await repository.captureHistoryPin(id: id, expectedRevisionID: first.revisionID)
            XCTFail("A stale expected revision cannot acquire the newer head's pin.")
        } catch NotebookRepositoryError.revisionConflict {}
        let next = try await repository.captureHistoryPin(id: id, expectedRevisionID: second.revisionID)
        XCTAssertEqual(next.revisionID, second.revisionID)
        XCTAssertEqual(next.sequence, second.sequence)
        XCTAssertNotEqual(next, opened.historyPin)
        XCTAssertTrue(next.hasSameHistoryGeneration(as: opened.historyPin))
        let report = try await repository.auditHistory(pin: opened.historyPin)
        XCTAssertEqual(report.headRevisionID, first.revisionID)
        XCTAssertEqual(report.revisionCount, 1)
    }

    func testPinsBindRepositoryAndExactHeadBytesWithoutClaimingAncestry() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let repository = try NotebookRepository(rootURL: root)
        let saved = try await repository.save(
            id: id, content: NotebookContent(title: "Head bytes", pageCount: 3, strokes: []),
            expectedRevisionID: nil
        )
        let result = try await repository.open(id: id)
        let original = try XCTUnwrap(result).historyPin
        let headURL = Fixtures.noteDirectory(root: root, id: id).appendingPathComponent("HEAD.json")
        let object = try Fixtures.object(at: headURL)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
            .write(to: headURL)
        let recaptured = try await repository.captureHistoryPin(id: id, expectedRevisionID: saved.revisionID)
        XCTAssertNotEqual(original, recaptured)
        XCTAssertTrue(original.hasSameHistoryGeneration(as: recaptured))
        let sameRootOtherRepository = try NotebookRepository(rootURL: root)
        do {
            _ = try await sameRootOtherRepository.auditHistory(pin: original)
            XCTFail("Opaque pins are bound to the repository that captured them.")
        } catch NotebookRepositoryError.invalidContent(_) {}
        let otherRoot = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        let otherRepository = try NotebookRepository(rootURL: otherRoot)
        do {
            _ = try await otherRepository.auditHistory(pin: original)
            XCTFail("A different storage root must refuse the pin.")
        } catch NotebookRepositoryError.invalidContent(_) {}
        let report = try await repository.auditHistory(pin: original)
        XCTAssertEqual(report.headRevisionID, saved.revisionID)
        XCTAssertEqual(report.revisionCount, 1)

        let legacyRoot = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: legacyRoot) }
        let legacyFixture = try Fixtures.writeLegacy(root: legacyRoot)
        let legacyRepository = try NotebookRepository(rootURL: legacyRoot)
        let legacyResult = try await legacyRepository.open(id: legacyFixture.notebookID)
        let legacy = try XCTUnwrap(legacyResult).historyPin
        let legacyHeadURL = Fixtures.noteDirectory(root: legacyRoot, id: legacyFixture.notebookID)
            .appendingPathComponent("HEAD.json")
        try JSONSerialization.data(
            withJSONObject: Fixtures.object(at: legacyHeadURL), options: [.sortedKeys, .prettyPrinted]
        ).write(to: legacyHeadURL)
        let rewrittenLegacy = try await legacyRepository.captureHistoryPin(
            id: legacyFixture.notebookID, expectedRevisionID: legacy.revisionID
        )
        XCTAssertNotEqual(legacy, rewrittenLegacy)
        XCTAssertTrue(legacy.hasSameHistoryGeneration(as: rewrittenLegacy))
        XCTAssertTrue(rewrittenLegacy.hasSameHistoryGeneration(as: legacy))
        _ = try await legacyRepository.migrateHistory(
            id: legacyFixture.notebookID, expectedRevisionID: legacy.revisionID
        )
        let migrated = try await legacyRepository.captureHistoryPin(
            id: legacyFixture.notebookID, expectedRevisionID: legacy.revisionID
        )
        XCTAssertFalse(legacy.hasSameHistoryGeneration(as: migrated))
        XCTAssertFalse(migrated.hasSameHistoryGeneration(as: legacy))
    }

    func testPinnedAuditDoesNotBlockSameRepositoryOrForeignWritersAndKeepsItsOriginalHead() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let repository = try NotebookRepository(rootURL: root)
        let firstAsset = Fixtures.asset(index: 1)
        let first = try await repository.save(
            id: id, content: NotebookContent(title: "Pinned writer", pageCount: 3, strokes: [firstAsset]),
            expectedRevisionID: nil
        )
        let result = try await repository.open(id: id)
        let opened = try XCTUnwrap(result)
        let foreign = try NotebookRepository(rootURL: root)
        let reached = AuditSignal(expectation(description: "Utility audit reached its gate"))
        let gate = AuditGate(boundary: .begin, reached: reached)
        let operation = AuditMetricsLog()
        defer { gate.release() }
        let audit = Task {
            try await repository.auditHistory(
                pin: opened.historyPin, progress: { gate.observe($0) },
                metricsObserver: { operation.record($0) }
            )
        }
        let started = await XCTWaiter.fulfillment(of: [reached.expectation], timeout: 5)
        guard started == .completed else {
            gate.release()
            _ = try? await audit.value
            throw AuditTestFailure.timeout
        }
        XCTAssertTrue(gate.isPaused)
        let finished = AuditSignal(expectation(description: "Both writers completed while audit was paused"))
        let writing = Task {
            defer { finished.mark() }
            let second = try await repository.save(
                id: id,
                content: NotebookContent(
                    title: "Same repository", pageCount: 4, strokes: [firstAsset, Fixtures.asset(index: 2)],
                    editStamp: Fixtures.stamp(1)
                ),
                expectedRevisionID: first.revisionID
            )
            return try await foreign.save(
                id: id,
                content: NotebookContent(
                    title: "Foreign repository", pageCount: 5, strokes: [Fixtures.asset(index: 3)],
                    editStamp: Fixtures.stamp(2)
                ),
                expectedRevisionID: second.revisionID
            )
        }
        let completed = await XCTWaiter.fulfillment(of: [finished.expectation], timeout: 5)
        let completedWhilePaused = completed == .completed && gate.isPaused
        gate.release()
        let written = await writing.result
        let audited = await audit.result
        let latest = try written.get()
        let report = try audited.get()
        XCTAssertTrue(completedWhilePaused, "Neither the repository actor nor writer lock may be held by the audit.")
        XCTAssertEqual(report.notebookID, id)
        XCTAssertEqual(report.headRevisionID, first.revisionID)
        XCTAssertEqual(report.revisionCount, 1)
        XCTAssertEqual(report.verifiedAssetCount, 1)
        XCTAssertEqual(operation.snapshot().count, 1)
        let work = try XCTUnwrap(operation.snapshot().first)
        XCTAssertEqual(work.assetReadCalls, 1)
        XCTAssertEqual(work.assetReadBytes, firstAsset.data.count)
        XCTAssertEqual(work.assetHashBytes, firstAsset.data.count)
        XCTAssertEqual(work.headPublications, 0)
        XCTAssertEqual(
            gate.snapshot().compactMap { progress -> String? in
                if case .willReadAsset(let digest) = progress { return digest }
                return nil
            },
            [NotebookDigest.sha256(firstAsset.data)]
        )
        let selected = try await repository.load(id: id)
        Fixtures.assertSame(try XCTUnwrap(selected), latest)
    }

    func testCancellationAtEveryAuditBoundaryStopsFurtherReadsAndKeepsWarmSavesValid() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let repository = try NotebookRepository(rootURL: root)
        let asset = Fixtures.asset(index: 1)
        var latest = try await repository.save(
            id: id, content: NotebookContent(title: "Cancellation", pageCount: 3, strokes: [asset]),
            expectedRevisionID: nil
        )
        let result = try await repository.open(id: id)
        let opened = try XCTUnwrap(result)
        for (index, boundary) in AuditBoundary.allCases.enumerated() {
            let reached = AuditSignal(expectation(description: "Audit paused at \(boundary.rawValue)"))
            let gate = AuditGate(boundary: boundary, reached: reached)
            let operation = AuditMetricsLog()
            defer { gate.release() }
            let audit = Task {
                try await repository.auditHistory(
                    pin: opened.historyPin, progress: { gate.observe($0) },
                    metricsObserver: { operation.record($0) }
                )
            }
            let started = await XCTWaiter.fulfillment(of: [reached.expectation], timeout: 5)
            guard started == .completed else {
                gate.release()
                _ = try? await audit.value
                throw AuditTestFailure.timeout
            }
            let sampled = AuditSignal(expectation(description: "Actor metrics available during utility audit"))
            let sampling = Task {
                defer { sampled.mark() }
                return await repository.storageMetrics()
            }
            let sampleReady = await XCTWaiter.fulfillment(of: [sampled.expectation], timeout: 5)
            guard sampleReady == .completed else {
                audit.cancel()
                gate.release()
                _ = await sampling.result
                _ = try? await audit.value
                throw AuditTestFailure.timeout
            }
            let pausedWork = await sampling.value
            let pausedProgress = gate.snapshot()
            audit.cancel()
            gate.release()
            do {
                _ = try await audit.value
                XCTFail("Cancellation at \(boundary.rawValue) must not produce a successful audit.")
            } catch is CancellationError {}
            let cancelledWork = await repository.storageMetrics()
            XCTAssertEqual(operation.snapshot().count, 1, boundary.rawValue)
            let work = try XCTUnwrap(operation.snapshot().first)
            XCTAssertEqual(work.headPublications, 0, boundary.rawValue)
            XCTAssertEqual(work.assetWrittenBytes, 0, boundary.rawValue)
            XCTAssertLessThanOrEqual(work.assetReadCalls, 1, boundary.rawValue)
            if boundary == .begin {
                XCTAssertEqual(work.metadataReadCalls, 0)
                XCTAssertEqual(work.assetReadCalls, 0)
            }
            XCTAssertEqual(gate.snapshot(), pausedProgress, boundary.rawValue)
            XCTAssertEqual(cancelledWork.metadataReadCalls, pausedWork.metadataReadCalls, boundary.rawValue)
            XCTAssertEqual(cancelledWork.assetReadCalls, pausedWork.assetReadCalls, boundary.rawValue)
            XCTAssertEqual(cancelledWork.assetReadBytes, pausedWork.assetReadBytes, boundary.rawValue)
            XCTAssertEqual(cancelledWork.assetHashBytes, pausedWork.assetHashBytes, boundary.rawValue)
            let beforeSave = await repository.storageMetrics()
            latest = try await repository.save(
                id: id,
                content: NotebookContent(
                    title: "Cancellation", pageCount: 3, strokes: [asset], editStamp: Fixtures.stamp(index + 1)
                ),
                expectedRevisionID: latest.revisionID
            )
            let afterSave = await repository.storageMetrics()
            XCTAssertEqual(afterSave.assetReadCalls - beforeSave.assetReadCalls, 0, boundary.rawValue)
        }
        let healthy = try await repository.auditHistory(pin: opened.historyPin)
        XCTAssertEqual(healthy.headRevisionID, opened.historyPin.revisionID)
        XCTAssertEqual(healthy.revisionCount, 1)
        XCTAssertEqual(healthy.verifiedAssetCount, 1)
    }

    func testAuditFailureDuringPublicationCannotBlessTheInflightVerificationEpoch() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let reached = AuditSignal(expectation(description: "Writer paused before HEAD publication"))
        let gate = AuditGate(boundary: .begin, reached: reached)
        let publication = PublicationGate(gate: gate)
        defer { gate.release() }
        let repository = try NotebookRepository(rootURL: root, faultInjector: { publication.intercept($0) })
        let asset = Fixtures.asset(index: 1)
        let first = try await repository.save(
            id: id, content: NotebookContent(title: "Epoch", pageCount: 3, strokes: [asset]),
            expectedRevisionID: nil
        )
        let result = try await repository.open(id: id)
        let opened = try XCTUnwrap(result)
        publication.arm()
        let writing = Task {
            try await repository.save(
                id: id,
                content: NotebookContent(
                    title: "Epoch", pageCount: 3, strokes: [asset], editStamp: Fixtures.stamp(1)
                ),
                expectedRevisionID: first.revisionID
            )
        }
        let started = await XCTWaiter.fulfillment(of: [reached.expectation], timeout: 5)
        guard started == .completed else {
            gate.release()
            _ = try? await writing.value
            throw AuditTestFailure.timeout
        }
        let assetURL = Fixtures.noteDirectory(root: root, id: id)
            .appendingPathComponent("assets/\(NotebookDigest.sha256(asset.data)).stroke")
        do {
            try Data("damage detected during publication".utf8).write(to: assetURL)
        } catch {
            gate.release()
            _ = try? await writing.value
            throw error
        }
        let finished = AuditSignal(expectation(description: "Failed audit invalidated verification while writer was paused"))
        let audit = Task {
            defer { finished.mark() }
            return try await repository.auditHistory(pin: opened.historyPin)
        }
        let completed = await XCTWaiter.fulfillment(of: [finished.expectation], timeout: 5)
        let completedWhilePaused = completed == .completed && gate.isPaused
        gate.release()
        let written = await writing.result
        let audited = await audit.result
        let second = try written.get()
        do {
            _ = try audited.get()
            XCTFail("The pinned audit must detect the damaged current asset.")
        } catch NotebookRepositoryError.corruptData(_) {}
        XCTAssertTrue(completedWhilePaused, "Audit failure invalidation must not need the writer actor or lock.")
        let before = await repository.storageMetrics()
        let repaired = try await repository.save(
            id: id,
            content: NotebookContent(
                title: "Epoch", pageCount: 3, strokes: [asset], editStamp: Fixtures.stamp(2)
            ),
            expectedRevisionID: second.revisionID
        )
        let after = await repository.storageMetrics()
        XCTAssertEqual(after.assetReadCalls - before.assetReadCalls, 1)
        XCTAssertEqual(try Data(contentsOf: assetURL), asset.data)
        let loaded = try await repository.load(id: id)
        Fixtures.assertSame(try XCTUnwrap(loaded), repaired)
    }

    func testPinnedAuditVerifiesSharedArchiveOnceWhileEnforcingEveryHistoricalReference() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let repository = try NotebookRepository(rootURL: root)
        let shared = Fixtures.asset(index: 1, bytes: 4 * 1_024 * 1_024).data
        let first = try await repository.save(
            id: id,
            content: NotebookContent(
                title: "Shared", pageCount: 3,
                strokes: (0..<16).map { _ in NotebookStroke(id: UUID(), data: shared) }
            ),
            expectedRevisionID: nil
        )
        let latest = try await repository.save(
            id: id, content: NotebookContent(title: "Empty current", pageCount: 3, strokes: []),
            expectedRevisionID: first.revisionID
        )
        let result = try await repository.open(id: id)
        let opened = try XCTUnwrap(result)
        Fixtures.assertSame(opened.notebook, latest)
        let operation = AuditMetricsLog()
        let report = try await repository.auditHistory(
            pin: opened.historyPin, progress: nil, metricsObserver: { operation.record($0) }
        )
        XCTAssertEqual(report.revisionCount, 2)
        XCTAssertEqual(report.verifiedAssetCount, 1)
        XCTAssertEqual(operation.snapshot().count, 1)
        let work = try XCTUnwrap(operation.snapshot().first)
        XCTAssertEqual(work.assetReadCalls, 1)
        XCTAssertEqual(work.assetReadBytes, shared.count)
        XCTAssertEqual(work.assetHashBytes, shared.count)

        let legacyRoot = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: legacyRoot) }
        let oversized = NotebookContent(
            title: "Oversized old state", pageCount: 3,
            strokes: (0..<17).map { _ in NotebookStroke(id: UUID(), data: shared) }
        )
        let fixture = try Fixtures.writeLegacy(
            root: legacyRoot, contents: [oversized, NotebookContent(title: "Empty", pageCount: 3, strokes: [])]
        )
        let legacyRepository = try NotebookRepository(rootURL: legacyRoot)
        let legacyResult = try await legacyRepository.open(id: fixture.notebookID)
        let legacyOpened = try XCTUnwrap(legacyResult)
        XCTAssertTrue(legacyOpened.historyPin.requiresFirstPublicationRefresh)
        let failedOperation = AuditMetricsLog()
        do {
            _ = try await legacyRepository.auditHistory(
                pin: legacyOpened.historyPin, progress: nil,
                metricsObserver: { failedOperation.record($0) }
            )
            XCTFail("The complete audit must count seventeen historical references toward the logical limit.")
        } catch NotebookRepositoryError.corruptData(_) {}
        XCTAssertEqual(failedOperation.snapshot().count, 1)
        XCTAssertEqual(try XCTUnwrap(failedOperation.snapshot().first).assetReadCalls, 1)
        try Fixtures.assertOriginalFiles(fixture, root: legacyRoot, includeHead: true)
    }

    func testCurrentReconstructionMetadataAndAssetDamageStillFailAtomicOpening() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let writer = try NotebookRepository(rootURL: root)
        var latest: StoredNotebook?
        for content in Fixtures.contents() {
            latest = try await writer.save(id: id, content: content, expectedRevisionID: latest?.revisionID)
        }
        let saved = try XCTUnwrap(latest)
        let layout = try Fixtures.layout(root: root, id: id)
        let headURL = layout.notebookDirectory.appendingPathComponent("HEAD.json")
        let headBytes = try Data(contentsOf: headURL)
        var checkpointEventID = saved.revisionID
        var checkpointDigest: String?
        for _ in 0..<saved.sequence {
            let event = try Fixtures.object(at: layout.eventURL(checkpointEventID))
            if let digest = event["checkpointDigest"] as? String {
                checkpointDigest = digest
                break
            }
            checkpointEventID = try XCTUnwrap(
                (event["parentRevisionID"] as? String).flatMap(UUID.init(uuidString:))
            )
        }
        let checkpoint = try XCTUnwrap(checkpointDigest)
        let asset = try XCTUnwrap(saved.content.strokes.first)
        let paths = [
            layout.eventURL(saved.revisionID), layout.checkpointURL(checkpoint),
            layout.notebookDirectory.appendingPathComponent("assets/\(NotebookDigest.sha256(asset.data)).stroke")
        ]
        for path in paths {
            let original = try Data(contentsOf: path)
            defer { try? original.write(to: path) }
            try Data("damaged selected reconstruction".utf8).write(to: path)
            let reader = try NotebookRepository(rootURL: root)
            do {
                _ = try await reader.open(id: id)
                XCTFail("Atomic opening must reject damaged current reconstruction.")
            } catch NotebookRepositoryError.corruptData(_) {}
            XCTAssertEqual(try Data(contentsOf: headURL), headBytes)
        }
    }

    func testLegacyPinRefreshAndReceiptCaptureRemainBoundedAtOneThousandRevisions() async throws {
        for count in [4, 1_000] {
            let root = try Fixtures.root()
            defer { try? FileManager.default.removeItem(at: root) }
            let shared = Fixtures.asset(index: 1)
            let contents = (0..<count).map { index in
                NotebookContent(
                    title: String(repeating: "t", count: 4_096), pageCount: index % 12 + 1,
                    strokes: [shared], editStamp: Fixtures.stamp(index)
                )
            }
            let fixture = try Fixtures.writeLegacy(root: root, contents: contents)
            let repository = try NotebookRepository(rootURL: root)
            let result = try await repository.open(id: fixture.notebookID)
            let legacy = try XCTUnwrap(result)
            Fixtures.assertSame(legacy.notebook, try XCTUnwrap(fixture.states.last))
            XCTAssertTrue(legacy.historyPin.requiresFirstPublicationRefresh)
            let receipt = try await repository.migrateHistory(
                id: fixture.notebookID, expectedRevisionID: legacy.notebook.revisionID
            )
            XCTAssertEqual(receipt.revisionCount, count)
            let migrated = try await repository.captureHistoryPin(
                id: fixture.notebookID, expectedRevisionID: legacy.notebook.revisionID
            )
            XCTAssertEqual(migrated.revisionID, legacy.historyPin.revisionID)
            XCTAssertEqual(migrated.sequence, count)
            XCTAssertFalse(migrated.requiresFirstPublicationRefresh)
            XCTAssertFalse(migrated.hasSameHistoryGeneration(as: legacy.historyPin))
            let latest = try await repository.save(
                id: fixture.notebookID,
                content: NotebookContent(
                    title: "After migration", pageCount: 3, strokes: [shared], editStamp: Fixtures.stamp(count)
                ),
                expectedRevisionID: migrated.revisionID
            )
            let before = await repository.storageMetrics()
            let current = try await repository.captureHistoryPin(
                id: fixture.notebookID, expectedRevisionID: latest.revisionID
            )
            let after = await repository.storageMetrics()
            XCTAssertEqual(current.sequence, count + 1)
            XCTAssertTrue(current.hasSameHistoryGeneration(as: migrated))
            XCTAssertEqual(after.assetReadCalls - before.assetReadCalls, 0)
            XCTAssertEqual(after.assetReadBytes - before.assetReadBytes, 0)
            XCTAssertEqual(after.assetHashBytes - before.assetHashBytes, 0)
            XCTAssertLessThanOrEqual(after.metadataReadCalls - before.metadataReadCalls, 5)
            let values = [
                "legacyRevisionCount": count,
                "metadataReadCalls": after.metadataReadCalls - before.metadataReadCalls,
                "metadataReadBytes": after.metadataReadBytes - before.metadataReadBytes,
                "metadataHashBytes": after.metadataHashBytes - before.metadataHashBytes,
                "assetReadCalls": after.assetReadCalls - before.assetReadCalls
            ]
            let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
            print("NOTTY_SAVE_METRIC history-pin-capture-\(count) \(String(decoding: data, as: UTF8.self))")
            let report = try await repository.auditHistory(pin: current)
            XCTAssertEqual(report.revisionCount, count + 1)
            XCTAssertEqual(report.verifiedAssetCount, 1)
        }
    }

    func testSelectedReceiptDamageFailsBoundedCaptureWhileUnselectedLegacyDamageRemainsReadable() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Fixtures.writeLegacy(root: root)
        let repository = try NotebookRepository(rootURL: root)
        let original = try XCTUnwrap(fixture.states.last)
        _ = try await repository.migrateHistory(id: fixture.notebookID, expectedRevisionID: original.revisionID)
        let latest = try await repository.save(
            id: fixture.notebookID,
            content: NotebookContent(title: "Current", pageCount: 3, strokes: [], editStamp: Fixtures.stamp(100)),
            expectedRevisionID: original.revisionID
        )
        let layout = try Fixtures.layout(root: root, id: fixture.notebookID)
        let headURL = layout.notebookDirectory.appendingPathComponent("HEAD.json")
        let headBytes = try Data(contentsOf: headURL)
        let firstLegacy = try XCTUnwrap(fixture.states.first)
        let legacyURL = layout.notebookDirectory.appendingPathComponent(
            "revisions/\(firstLegacy.revisionID.uuidString.lowercased()).json"
        )
        let legacyBytes = try Data(contentsOf: legacyURL)
        defer { try? legacyBytes.write(to: legacyURL) }
        try Data("unselected legacy damage".utf8).write(to: legacyURL)
        let openedResult = try await repository.open(id: fixture.notebookID)
        let opened = try XCTUnwrap(openedResult)
        Fixtures.assertSame(opened.notebook, latest)
        let audit = try await repository.auditHistory(pin: opened.historyPin)
        XCTAssertEqual(audit.revisionCount, fixture.states.count + 1)
        let receiptURL = layout.generationDirectory.appendingPathComponent("migration.json")
        let receiptBytes = try Data(contentsOf: receiptURL)
        defer {
            try? receiptBytes.write(to: receiptURL)
            try? headBytes.write(to: headURL)
        }
        try Data("damaged selected receipt".utf8).write(to: receiptURL)
        do {
            _ = try await repository.captureHistoryPin(
                id: fixture.notebookID, expectedRevisionID: latest.revisionID
            )
            XCTFail("Selected receipt integrity belongs to bounded pin capture.")
        } catch NotebookRepositoryError.corruptData(_) {}
        do {
            _ = try await repository.open(id: fixture.notebookID)
            XCTFail("Atomic opening must reject a damaged selected receipt.")
        } catch NotebookRepositoryError.corruptData(_) {}
        XCTAssertEqual(try Data(contentsOf: headURL), headBytes)
        try receiptBytes.write(to: receiptURL)
        var record = try Fixtures.object(at: receiptURL)
        var receipt = try XCTUnwrap(record["receipt"] as? [String: Any])
        receipt["revisionCount"] = fixture.states.count + 1
        record["receipt"] = receipt
        let invalidRecord = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        try invalidRecord.write(to: receiptURL)
        var head = try Fixtures.object(at: headURL)
        head["migrationReceiptDigest"] = NotebookDigest.sha256(invalidRecord)
        let invalidHead = try JSONSerialization.data(withJSONObject: head, options: [.sortedKeys])
        try invalidHead.write(to: headURL)
        do {
            _ = try await repository.captureHistoryPin(
                id: fixture.notebookID, expectedRevisionID: latest.revisionID
            )
            XCTFail("A rehashed receipt with inconsistent anchor sequence must be rejected.")
        } catch NotebookRepositoryError.corruptData(_) {}
        XCTAssertEqual(try Data(contentsOf: headURL), invalidHead)
    }


    func testStructurallyValidUnselectedMigrationAnchorIsDeferredToFullAudit() async throws {
        let root = try Fixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Fixtures.writeLegacy(root: root)
        let repository = try NotebookRepository(rootURL: root)
        let original = try XCTUnwrap(fixture.states.last)
        _ = try await repository.migrateHistory(
            id: fixture.notebookID, expectedRevisionID: original.revisionID
        )
        let latest = try await repository.save(
            id: fixture.notebookID,
            content: NotebookContent(
                title: "After migration", pageCount: 3, strokes: [], editStamp: Fixtures.stamp(100)
            ),
            expectedRevisionID: original.revisionID
        )
        let originalPin = try await repository.captureHistoryPin(
            id: fixture.notebookID, expectedRevisionID: latest.revisionID
        )
        let layout = try Fixtures.layout(root: root, id: fixture.notebookID)
        let headURL = layout.notebookDirectory.appendingPathComponent("HEAD.json")
        let receiptURL = layout.generationDirectory.appendingPathComponent("migration.json")
        let legacyHeadURL = layout.generationDirectory.appendingPathComponent("legacy-head.json")
        let headBytes = try Data(contentsOf: headURL)
        let receiptBytes = try Data(contentsOf: receiptURL)
        let legacyHeadBytes = try Data(contentsOf: legacyHeadURL)
        defer {
            try? headBytes.write(to: headURL)
            try? receiptBytes.write(to: receiptURL)
            try? legacyHeadBytes.write(to: legacyHeadURL)
        }
        let orphanID = UUID()
        var record = try Fixtures.object(at: receiptURL)
        var anchor = try XCTUnwrap(record["anchor"] as? [String: Any])
        let anchorID = try XCTUnwrap((anchor["revisionID"] as? String).flatMap(UUID.init(uuidString:)))
        var orphan = try Fixtures.object(at: layout.eventURL(anchorID))
        orphan["revisionID"] = orphanID.uuidString
        if let checkpointDigest = orphan["checkpointDigest"] as? String {
            var checkpoint = try Fixtures.object(at: layout.checkpointURL(checkpointDigest))
            checkpoint["revisionID"] = orphanID.uuidString
            let bytes = try JSONSerialization.data(withJSONObject: checkpoint, options: [.sortedKeys])
            let digest = NotebookDigest.sha256(bytes)
            try bytes.write(to: layout.checkpointURL(digest))
            orphan["checkpointDigest"] = digest
        }
        let orphanBytes = try JSONSerialization.data(withJSONObject: orphan, options: [.sortedKeys])
        try orphanBytes.write(to: layout.eventURL(orphanID))
        anchor["revisionID"] = orphanID.uuidString
        anchor["revisionDigest"] = NotebookDigest.sha256(orphanBytes)
        record["anchor"] = anchor
        var receipt = try XCTUnwrap(record["receipt"] as? [String: Any])
        receipt["revisionID"] = orphanID.uuidString
        record["receipt"] = receipt
        var legacyHead = try Fixtures.object(at: legacyHeadURL)
        legacyHead["revisionID"] = orphanID.uuidString
        let revisedLegacyHead = try JSONSerialization.data(withJSONObject: legacyHead, options: [.sortedKeys])
        try revisedLegacyHead.write(to: legacyHeadURL)
        record["legacyHeadDigest"] = NotebookDigest.sha256(revisedLegacyHead)
        let revisedReceipt = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        try revisedReceipt.write(to: receiptURL)
        var head = try Fixtures.object(at: headURL)
        head["migrationReceiptDigest"] = NotebookDigest.sha256(revisedReceipt)
        let revisedHead = try JSONSerialization.data(withJSONObject: head, options: [.sortedKeys])
        try revisedHead.write(to: headURL)
        let reader = try NotebookRepository(rootURL: root)
        let opening = try await reader.open(id: fixture.notebookID)
        let opened = try XCTUnwrap(opening)
        Fixtures.assertSame(opened.notebook, latest)
        XCTAssertEqual(opened.historyPin.sequence, fixture.states.count + 1)
        XCTAssertNotEqual(opened.historyPin.revisionID, orphanID)
        let before = await reader.storageMetrics()
        let captured = try await reader.captureHistoryPin(
            id: fixture.notebookID, expectedRevisionID: latest.revisionID
        )
        let after = await reader.storageMetrics()
        XCTAssertEqual(captured, opened.historyPin)
        XCTAssertLessThanOrEqual(after.metadataReadCalls - before.metadataReadCalls, 5)
        XCTAssertEqual(after.assetReadCalls - before.assetReadCalls, 0)
        XCTAssertEqual(after.assetHashBytes - before.assetHashBytes, 0)
        do {
            _ = try await reader.auditHistory(pin: captured)
            XCTFail("Full audit must reject a valid receipt anchor outside selected ancestry.")
        } catch NotebookRepositoryError.corruptData(_) {}
        XCTAssertEqual(try Data(contentsOf: headURL), revisedHead)
        let restored = try NotebookRepository(rootURL: root)
        try headBytes.write(to: headURL)
        try receiptBytes.write(to: receiptURL)
        try legacyHeadBytes.write(to: legacyHeadURL)
        let restoredPin = try await restored.captureHistoryPin(
            id: fixture.notebookID, expectedRevisionID: latest.revisionID
        )
        XCTAssertEqual(restoredPin.revisionID, originalPin.revisionID)
        let report = try await restored.auditHistory(pin: restoredPin)
        XCTAssertEqual(report.revisionCount, fixture.states.count + 1)
    }
}

private enum AuditTestFailure: Error {
    case timeout
}

private enum AuditBoundary: String, CaseIterable {
    case begin, event, checkpoint, asset, report

    func matches(_ progress: NotebookHistoryAuditProgress) -> Bool {
        switch (self, progress) {
        case (.begin, .willBeginAudit), (.event, .willReadEvent(_)),
             (.checkpoint, .willReadCheckpoint(_)), (.asset, .willReadAsset(_)),
             (.report, .willReturnReport): return true
        default: return false
        }
    }
}

private final class AuditSignal: @unchecked Sendable {
    let expectation: XCTestExpectation
    private let lock = NSLock()
    private var marked = false

    init(_ expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func mark() {
        lock.lock()
        guard !marked else {
            lock.unlock()
            return
        }
        marked = true
        lock.unlock()
        expectation.fulfill()
    }
}

private final class AuditGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let boundary: AuditBoundary
    private let reached: AuditSignal
    private var entered = false
    private var released = false
    private var progress: [NotebookHistoryAuditProgress] = []

    init(boundary: AuditBoundary, reached: AuditSignal) {
        self.boundary = boundary
        self.reached = reached
    }

    var isPaused: Bool {
        condition.lock()
        defer { condition.unlock() }
        return entered && !released
    }

    func snapshot() -> [NotebookHistoryAuditProgress] {
        condition.lock()
        defer { condition.unlock() }
        return progress
    }

    func observe(_ event: NotebookHistoryAuditProgress) {
        condition.lock()
        defer { condition.unlock() }
        progress.append(event)
        if boundary.matches(event) { holdUnderLock() }
    }

    func hold() {
        condition.lock()
        defer { condition.unlock() }
        holdUnderLock()
    }

    private func holdUnderLock() {
        guard !entered else { return }
        entered = true
        reached.mark()
        while !released { condition.wait() }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class PublicationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let gate: AuditGate
    private var armed = false

    init(gate: AuditGate) { self.gate = gate }

    func arm() {
        lock.lock()
        armed = true
        lock.unlock()
    }

    func intercept(_ stage: NotebookWriteStage) {
        guard stage == .beforeHeadPublication else { return }
        lock.lock()
        let shouldPause = armed
        armed = false
        lock.unlock()
        if shouldPause { gate.hold() }
    }
}

private final class AuditMetricsLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [NotebookStorageMetrics] = []

    func record(_ report: NotebookStorageMetrics) {
        lock.lock()
        reports.append(report)
        lock.unlock()
    }

    func snapshot() -> [NotebookStorageMetrics] {
        lock.lock()
        defer { lock.unlock() }
        return reports
    }
}
