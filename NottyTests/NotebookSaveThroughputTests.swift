import CoreGraphics
import Foundation
import PencilKit
import QuartzCore
import UIKit
import XCTest
@testable import Notty
@testable import NottyCore

@MainActor
final class NotebookSaveThroughputTests: XCTestCase {
    func testRealStorageRetainsEveryNativeObservationAtFourScheduledOffersPerSecond() async throws {
        executionTimeAllowance = 120
        let root = NotebookTestFixtures.root()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library", isDirectory: true)
        let recovery = root.appendingPathComponent("recovery", isDirectory: true)
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        )
        let hostLibrary = support.appendingPathComponent("NottyLibrary", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: hostLibrary.path))

        let id = UUID()
        let real = try await NotebookStorage.open(
            notebookID: id, libraryRoot: library, recoveryRoot: recovery
        )
        let readMetrics = try XCTUnwrap(real.storageMetrics)
        let initialDrawing = PKDrawing(strokes: (0..<2_000).map {
            NotebookTestFixtures.stroke(x: CGFloat($0 % 60) * 10 + 20)
        })
        let seedCodec = InkCodec()
        let initial = NotebookContent(
            title: String(repeating: "x", count: 4_096), pageCount: 3,
            strokes: try await seedCodec.encode(initialDrawing)
        )
        let first = try await real.save(initial, nil)
        let trace = ThroughputStorageTrace(storage: real, metrics: readMetrics)
        let forwarded = await trace.forwardedStorage()
        let session = NotebookSession(notebookID: id, openStorage: { forwarded })
        await session.load()
        XCTAssertEqual(session.loadState, .ready)
        let seed = session.makeCanvasSeed()
        let controller = NotebookViewController(
            pageCount: seed.pageCount, initialDrawing: seed.drawing
        )
        var observed: [ObservedState] = []
        var highWater = 0
        var ready: XCTestExpectation?
        var expectedLastStrokeID: UUID?
        controller.onObservation = { observation in
            session.recordObservation(observation, ownerID: seed.ownerID)
            guard let pending = session.pendingEdits.last else {
                XCTFail("A delivered observation did not retain its pending identity.")
                return .failed
            }
            observed.append(ObservedState(observation: observation, pending: pending))
            highWater = max(highWater, session.pendingEdits.count)
            if let expectedLastStrokeID,
               observation.drawing.strokes.last?.id == expectedLastStrokeID,
               let expectation = ready {
                ready = nil
                expectation.fulfill()
            }
            return session.inputGateForCanvas(ownerID: seed.ownerID)
        }
        session.attachCanvas(
            ownerID: seed.ownerID,
            observations: { [weak controller] in controller?.captureBarrier() },
            applyInputGate: { [weak controller] in controller?.setInputGate($0) }
        )
        controller.onDetach = { session.detachCanvas(ownerID: seed.ownerID) }
        controller.setInputGate(session.inputGate)
        let window = present(controller)
        var didTearDown = false
        defer {
            if !didTearDown { controller.tearDown() }
            window.isHidden = true
        }
        try await requireReady {
            controller.view.window === window && controller.canvasView.isFirstResponder
                && controller.canvasView.delegate === controller
                && session.canvasOwnerID == seed.ownerID
                && !controller.canvasView.bounds.isEmpty
                && controller.canvasView.contentSize.width > 0
                && controller.currentDrawing.strokes.count == 2_000
        }
        try await waitForRenderedFrames()
        await session.waitUntilSettled()
        XCTAssertTrue(session.pendingEdits.isEmpty)
        XCTAssertTrue(session.canEdit)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hostLibrary.path))

        var baseline: (
            storage: NotebookStorageMetrics, codec: InkCodec.WorkMetrics,
            trace: ThroughputTraceSnapshot, observations: Int
        )?
        for _ in 0..<20 {
            await session.waitUntilSettled()
            let count = observed.count
            let storage = try await readMetrics()
            let codec = await session.codecWorkMetrics()
            let captured = await trace.snapshot()
            if session.pendingEdits.isEmpty, count == observed.count,
               captured.committed.count == count {
                baseline = (storage, codec, captured, count)
                break
            }
        }
        let stable = try XCTUnwrap(baseline)
        let repositoryBefore = stable.storage
        let codecBefore = stable.codec
        let traceBefore = stable.trace
        let observedBefore = stable.observations
        let barrierBefore = controller.observationWork.values
        highWater = 0
        let clock = ContinuousClock()
        let started = clock.now
        var sourceDrawing = seed.drawing
        var intendedLastIDs: [UUID] = []
        var offerTimes: [Int] = []
        var lateness: [Int] = []
        var admissionWaits: [Int] = []
        var blockedOffers = 0

        for index in 0..<60 {
            let deadline = started.advanced(by: .milliseconds(index * 250))
            try await clock.sleep(until: deadline)
            let admissionStarted = clock.now
            if !session.canEdit {
                blockedOffers += 1
                try await requireReady { session.canEdit }
            }
            admissionWaits.append(ThroughputMetrics.microseconds(
                admissionStarted.duration(to: clock.now)
            ))
            XCTAssertTrue(controller.canvasView.delegate === controller)
            XCTAssertEqual(session.canvasOwnerID, seed.ownerID)
            XCTAssertTrue(controller.canvasView.isDrawingEnabled)
            let stroke = NotebookTestFixtures.stroke(x: CGFloat(index % 60) * 10 + 20)
            var strokes = sourceDrawing.strokes
            strokes.append(stroke)
            sourceDrawing = PKDrawing(strokes: strokes)
            intendedLastIDs.append(stroke.id)
            expectedLastStrokeID = stroke.id
            let callback = expectation(description: "Native drawing assignment \(index + 1)")
            ready = callback
            let countBefore = observed.count
            let offeredAt = clock.now
            offerTimes.append(ThroughputMetrics.microseconds(started.duration(to: offeredAt)))
            lateness.append(max(0, ThroughputMetrics.microseconds(deadline.duration(to: offeredAt))))
            // Keep the real SDK delegate installed; assignment must deliver the observation.
            controller.canvasView.drawing = sourceDrawing
            controller.view.layoutIfNeeded()
            CATransaction.flush()
            let completion = await XCTWaiter.fulfillment(of: [callback], timeout: 5)
            guard completion == .completed else { throw ThroughputFailure.readiness }
            try await waitForRenderedFrames()
            XCTAssertGreaterThan(observed.count, countBefore)
            XCTAssertEqual(controller.currentDrawing.strokes.last?.id, stroke.id)
        }

        expectedLastStrokeID = nil
        let nativeObservedCount = observed.count - observedBefore
        _ = controller.captureBarrier()
        await session.waitUntilSettled()
        controller.tearDown()
        didTearDown = true
        await session.waitUntilSettled()
        let benchmarkElapsed = ThroughputMetrics.microseconds(started.duration(to: clock.now))
        let repositoryAfter = try await readMetrics()
        let codecAfter = await session.codecWorkMetrics()
        let barrierAfter = controller.observationWork.values
        let captured = await trace.snapshot()
        XCTAssertTrue(session.pendingEdits.isEmpty)
        guard case .saved = session.saveState else { throw ThroughputFailure.batchShape }
        XCTAssertGreaterThanOrEqual(nativeObservedCount, 60)
        XCTAssertEqual(Set(observed.map(\.pending.id)).count, observed.count)
        XCTAssertTrue(observed.enumerated().allSatisfy { $0.element.observation.generation == UInt64($0.offset + 1) })
        for pair in zip(observed, observed.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.pending.stamp.capturedAt, pair.1.pending.stamp.capturedAt)
            XCTAssertLessThanOrEqual(pair.0.pending.stamp.uptime, pair.1.pending.stamp.uptime)
        }
        XCTAssertEqual(captured.metricsFailures, 0)
        XCTAssertEqual(captured.invalidShapes, 0)
        XCTAssertTrue(captured.committed.map(\.edit.id) == observed.map(\.pending.id))
        for (record, state) in zip(captured.committed, observed) {
            XCTAssertEqual(state.pending.stamp.capturedAt, state.observation.capturedAt)
            XCTAssertEqual(state.pending.stamp.uptime, state.observation.uptime)
            XCTAssertEqual(record.edit.content.editStamp, state.pending.stamp)
            XCTAssertEqual(record.edit.content.title, state.pending.snapshot.title)
            XCTAssertEqual(record.edit.content.pageCount, state.pending.snapshot.pageCount)
            XCTAssertTrue(
                record.edit.content.strokes.map(\.id) == state.observation.drawing.strokes.map(\.id),
                "An observed drawing changed its ordered stroke identities."
            )
        }
        let represented = observed.map { $0.observation.drawing.strokes.last?.id }
        var cursor = 0
        for intended in intendedLastIDs {
            guard let next = represented[cursor...].firstIndex(of: intended) else {
                throw ThroughputFailure.missingIntendedState
            }
            cursor = next + 1
        }
        let measuredBatches = Array(captured.batches.dropFirst(traceBefore.batches.count))
        let storageWork = ThroughputMetrics.storage(repositoryBefore, repositoryAfter)
        XCTAssertGreaterThan(storageWork["headPublications", default: 0], 0)
        XCTAssertEqual(storageWork["headPublications"], measuredBatches.count)
        XCTAssertTrue(measuredBatches.allSatisfy { (1...8).contains($0.committedCount) })
        XCTAssertEqual(
            measuredBatches.reduce(0) { $0 + $1.committedCount },
            observed.count - observedBefore
        )

        // Verification follows the timed workload; direct byte comparisons visit each distinct asset once.
        let verificationStarted = clock.now
        let verification = try await Task.detached(priority: .utility) {
            try await ThroughputHistory.verify(
                library: library, notebookID: id, first: first, committed: captured.committed
            )
        }.value
        let reopened = NotebookSession(notebookID: id, libraryRoot: library, recoveryRoot: recovery)
        await reopened.load()
        XCTAssertEqual(reopened.loadState, .ready)
        var nativeArchives: [String: PKStroke] = [:]
        XCTAssertTrue(try verifyArchivedState(first.content, drawing: initialDrawing, archives: &nativeArchives))
        for (record, state) in zip(captured.committed, observed) {
            XCTAssertTrue(
                try verifyArchivedState(
                    record.edit.content, drawing: state.observation.drawing, archives: &nativeArchives
                ),
                "An observed native state changed after its own archive restoration."
            )
        }
        XCTAssertTrue(
            zip(session.workingDrawing.strokes, reopened.workingDrawing.strokes).allSatisfy {
                equivalent($0.0, $0.1)
            },
            "The fresh session changed the final native drawing."
        )
        XCTAssertTrue(
            reopened.workingDrawing.strokes.map(\.id) == sourceDrawing.strokes.map(\.id),
            "The reopened drawing changed its final order."
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: hostLibrary.path))
        let intervals = zip(offerTimes, offerTimes.dropFirst()).map { $0.1 - $0.0 }
        let bursts = measuredBatches.filter { $0.work["checkpointPublications", default: 0] > 0 }
        let metrics: [String: Any] = [
            "initialStrokeCount": 2_000, "intendedOffers": 60,
            "scheduledIntervalMicroseconds": 250_000,
            "nativeObservedBeforeFinalBarrier": nativeObservedCount,
            "retainedGenerations": observed.count - observedBefore,
            "afterOfferDrainGenerations": observed.count - observedBefore - nativeObservedCount,
            "blockedOffers": blockedOffers, "queueHighWater": highWater,
            "benchmarkElapsedMicroseconds": benchmarkElapsed,
            "offerLatenessMicroseconds": lateness, "offerIntervalsMicroseconds": intervals,
            "admissionWaitMicroseconds": admissionWaits,
            "batchSizes": measuredBatches.map(\.committedCount),
            "batchSaveElapsedMicroseconds": measuredBatches.map(\.saveElapsedMicroseconds),
            "checkpointBurstCount": bursts.count,
            "checkpointBurstElapsedMicroseconds": bursts.map(\.saveElapsedMicroseconds),
            "storageWork": storageWork,
            "codecWork": ThroughputMetrics.codec(codecBefore, codecAfter),
            "barrierWork": ThroughputMetrics.dictionary(barrierBefore, barrierAfter),
            "verifiedRevisions": verification.revisions,
            "verifiedDistinctAssets": verification.assets,
            "verifiedNativeArchiveVersions": nativeArchives.count,
            "verificationElapsedMicroseconds": ThroughputMetrics.microseconds(
                verificationStarted.duration(to: clock.now)
            )
        ]
        let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
        print("NOTTY_THROUGHPUT_METRIC \(String(decoding: data, as: UTF8.self))")
        if let directory = ProcessInfo.processInfo.environment["NOTTY_SAVE_METRICS_DIRECTORY"] {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try data.write(to: output.appendingPathComponent("native-throughput-2000-60.json"), options: .atomic)
        }
    }

    private struct ObservedState {
        let observation: NotebookCanvasObservation
        let pending: NotebookPendingEdit<NotebookDrawingSnapshot>
    }

    private func waitForRenderedFrames() async throws {
        let completed = expectation(description: "Live canvas display frames")
        let waiter = ThroughputFrameWaiter(completed: completed)
        let link = CADisplayLink(target: waiter, selector: #selector(ThroughputFrameWaiter.advance(_:)))
        link.add(to: .main, forMode: .common)
        defer { link.invalidate() }
        let result = await XCTWaiter.fulfillment(of: [completed], timeout: 5)
        guard result == .completed else { throw ThroughputFailure.readiness }
    }

    private func requireReady(_ predicate: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard clock.now < deadline else { throw ThroughputFailure.readiness }
            try await clock.sleep(for: .milliseconds(5))
        }
    }

    private func present(_ controller: NotebookViewController) -> UIWindow {
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_024, height: 1_366))
        }
        window.frame = CGRect(x: 0, y: 0, width: 1_024, height: 1_366)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return window
    }

    private func verifyArchivedState(
        _ content: NotebookContent, drawing: PKDrawing, archives: inout [String: PKStroke]
    ) throws -> Bool {
        let strokes = drawing.strokes
        guard strokes.count == content.strokes.count else { return false }
        for (original, stored) in zip(strokes, content.strokes) {
            let digest = stored.cachedDigest ?? NotebookDigest.sha256(stored.data)
            let decoded: PKStroke
            if let cached = archives[digest] {
                decoded = cached
            } else {
                decoded = try autoreleasepool {
                    let drawing = try PKDrawing(data: stored.data)
                    guard drawing.strokes.count == 1 else { throw ThroughputFailure.asset }
                    return drawing.strokes[0]
                }
                archives[digest] = decoded
            }
            var authoritative = decoded
            authoritative.id = stored.id
            guard equivalent(original, authoritative) else { return false }
        }
        return true
    }

    private func equivalent(_ first: PKStroke, _ second: PKStroke) -> Bool {
        guard first.id == second.id, first.transform == second.transform,
              first.ink.inkType == second.ink.inkType, equivalentColor(first.ink.color, second.ink.color),
              first.randomSeed == second.randomSeed, first.renderGroupID == second.renderGroupID,
              first.mask?.cgPath == second.mask?.cgPath,
              first.mask?.usesEvenOddFillRule == second.mask?.usesEvenOddFillRule,
              first.path.id == second.path.id, first.path.creationDate == second.path.creationDate,
              first.path.count == second.path.count else { return false }
        do {
            let firstState = try renderState(first)
            let secondState = try renderState(second)
            guard firstState == secondState else { return false }
        } catch { return false }
        return zip(first.path, second.path).allSatisfy { pair in
            let first = pair.0
            let second = pair.1
            return first.location == second.location && first.timeOffset == second.timeOffset
                && first.size == second.size && first.opacity == second.opacity && first.force == second.force
                && first.azimuth == second.azimuth && first.altitude == second.altitude
                && first.secondaryScale == second.secondaryScale && first.threshold == second.threshold
                && first.lateralJitter == second.lateralJitter
        }
    }

    private func equivalentColor(_ first: UIColor, _ second: UIColor) -> Bool {
        guard let space = CGColorSpace(name: CGColorSpace.extendedSRGB),
              let first = first.cgColor.converted(to: space, intent: .relativeColorimetric, options: nil)?.components,
              let second = second.cgColor.converted(to: space, intent: .relativeColorimetric, options: nil)?.components,
              first.count == 4, second.count == 4 else { return false }
        // Archive color spaces may differ; compare RGBA components in one space.
        return zip(first, second).allSatisfy {
            $0.0.isFinite && $0.1.isFinite && abs($0.0 - $0.1) <= 0.000_001
        }
    }

    private func renderState(_ stroke: PKStroke) throws -> Data? {
        guard let state = stroke.renderState else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        return try encoder.encode(state)
    }
}

@MainActor
private final class ThroughputFrameWaiter: NSObject {
    private let completed: XCTestExpectation
    private var remaining = 2

    init(completed: XCTestExpectation) {
        self.completed = completed
        super.init()
    }

    @objc func advance(_ link: CADisplayLink) {
        guard remaining > 0 else { return }
        remaining -= 1
        if remaining == 0 { completed.fulfill() }
    }
}

private struct ThroughputCommittedState: Sendable {
    let edit: NotebookSaveEdit
    let receipt: NotebookCommittedEdit
}

private struct ThroughputBatch: Sendable {
    let committedCount: Int
    let saveElapsedMicroseconds: Int
    let work: [String: Int]
}

private struct ThroughputTraceSnapshot: Sendable {
    let committed: [ThroughputCommittedState]
    let batches: [ThroughputBatch]
    let metricsFailures: Int
    let invalidShapes: Int
}

private actor ThroughputStorageTrace {
    private let storage: NotebookStorage
    private let metrics: @Sendable () async throws -> NotebookStorageMetrics
    private var committed: [ThroughputCommittedState] = []
    private var batches: [ThroughputBatch] = []
    private var metricsFailures = 0
    private var invalidShapes = 0

    init(storage: NotebookStorage, metrics: @escaping @Sendable () async throws -> NotebookStorageMetrics) {
        self.storage = storage
        self.metrics = metrics
    }

    func forwardedStorage() -> NotebookStorage {
        NotebookStorage(
            load: storage.load, save: storage.save, preserve: storage.preserve,
            listRecovery: storage.listRecovery, loadRecovery: storage.loadRecovery,
            storageMetrics: storage.storageMetrics,
            saveBatch: { try await self.saveBatch($0, revision: $1) }
        )
    }

    func snapshot() -> ThroughputTraceSnapshot {
        ThroughputTraceSnapshot(
            committed: committed, batches: batches, metricsFailures: metricsFailures,
            invalidShapes: invalidShapes
        )
    }

    private func saveBatch(_ edits: [NotebookSaveEdit], revision: UUID?) async throws -> NotebookBatchSaveResult {
        let before = try? await metrics()
        let clock = ContinuousClock()
        let started = clock.now
        let result = try await storage.saveBatch(edits, revision)
        let elapsed = ThroughputMetrics.microseconds(started.duration(to: clock.now))
        let after = try? await metrics()
        if before == nil || after == nil { metricsFailures += 1 }
        if result.rejection != nil || result.committed.isEmpty || result.committed.count > edits.count
            || !zip(result.committed, edits).allSatisfy({ $0.0.editID == $0.1.id }) {
            invalidShapes += 1
        }
        for (receipt, edit) in zip(result.committed, edits) {
            committed.append(ThroughputCommittedState(edit: edit, receipt: receipt))
        }
        batches.append(ThroughputBatch(
            committedCount: result.committed.count, saveElapsedMicroseconds: elapsed,
            work: before.flatMap { start in after.map { ThroughputMetrics.storage(start, $0) } } ?? [:]
        ))
        return result
    }
}

private enum ThroughputHistory {
    struct Result: Sendable {
        let revisions: Int
        let assets: Int
    }

    nonisolated static func verify(
        library: URL, notebookID: UUID, first: StoredNotebook, committed: [ThroughputCommittedState]
    ) async throws -> Result {
        let repository = try NotebookRepository(rootURL: library)
        var summaries: [NotebookRevisionSummary] = []
        var cursor: UUID?
        while true {
            let page = try await repository.history(id: notebookID, beforeRevisionID: cursor, limit: 200)
            summaries.append(contentsOf: page)
            guard page.count == 200 else { break }
            cursor = page.last?.revisionID
        }
        let expectedIDs = [first.revisionID] + committed.map(\.receipt.revisionID)
        guard summaries.reversed().map(\.revisionID) == expectedIDs else {
            throw ThroughputFailure.historyOrder
        }
        let report = try await repository.auditHistory(id: notebookID)
        guard report.revisionCount == expectedIDs.count else { throw ThroughputFailure.historyOrder }
        let directory = library.appendingPathComponent(notebookID.uuidString.lowercased(), isDirectory: true)
        let history = NotebookHistory(directory: directory, notebookID: notebookID, assetVerificationObserver: nil)
        guard let head = try history.readHead() else { throw ThroughputFailure.historyOrder }
        let generation = try history.generationDirectory(head)
        let links = try history.selectedLinks(head)
        let replay = NotebookRevisionFormat.Replay()
        let expected = Dictionary(uniqueKeysWithValues: committed.map { ($0.receipt.revisionID, $0) })
        var assets: [String: Data] = [:]
        for (index, link) in links.enumerated() {
            let (event, _) = try history.readEvent(id: link.revisionID, digest: link.digest, generation: generation)
            try replay.apply(event.delta)
            let content: NotebookContent
            if event.revisionID == first.revisionID {
                content = first.content
                guard event.sequence == first.sequence, event.savedAt == first.savedAt else {
                    throw ThroughputFailure.state(index)
                }
            } else {
                guard let record = expected[event.revisionID],
                      event.sequence == record.receipt.sequence,
                      event.savedAt == record.receipt.savedAt else { throw ThroughputFailure.state(index) }
                content = record.edit.content
            }
            let references = content.strokes.map {
                NotebookRevisionFormat.Reference(id: $0.id, digest: $0.cachedDigest ?? NotebookDigest.sha256($0.data))
            }
            let state = NotebookRevisionFormat.State(
                title: content.title, pageCount: content.pageCount, strokes: references
            )
            guard replay.state == state, event.editStamp == content.editStamp else {
                throw ThroughputFailure.state(index)
            }
            for (reference, stroke) in zip(references, content.strokes) {
                if let existing = assets[reference.digest] {
                    guard existing == stroke.data else { throw ThroughputFailure.state(index) }
                } else {
                    assets[reference.digest] = stroke.data
                }
            }
        }
        for (digest, expectedBytes) in assets {
            let bytes = try Data(contentsOf: directory.appendingPathComponent("assets/\(digest).stroke"))
            guard bytes == expectedBytes, NotebookDigest.sha256(bytes) == digest else {
                throw ThroughputFailure.asset
            }
        }
        guard report.verifiedAssetCount == assets.count else { throw ThroughputFailure.asset }
        return Result(revisions: links.count, assets: assets.count)
    }
}

private enum ThroughputFailure: Error {
    case readiness
    case missingIntendedState
    case batchShape
    case historyOrder
    case state(Int)
    case asset
}

private enum ThroughputMetrics {
    nonisolated static func microseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(components.seconds * 1_000_000 + components.attoseconds / 1_000_000_000_000)
    }

    nonisolated static func dictionary(_ before: [String: Int], _ after: [String: Int]) -> [String: Int] {
        after.reduce(into: [:]) { result, entry in
            result[entry.key] = entry.value - before[entry.key, default: 0]
        }
    }

    nonisolated static func storage(_ before: NotebookStorageMetrics, _ after: NotebookStorageMetrics) -> [String: Int] {
        [
            "assetCopiedBytes": after.assetCopiedBytes - before.assetCopiedBytes,
            "assetHashBytes": after.assetHashBytes - before.assetHashBytes,
            "metadataHashBytes": after.metadataHashBytes - before.metadataHashBytes,
            "assetReadCalls": after.assetReadCalls - before.assetReadCalls,
            "assetReadBytes": after.assetReadBytes - before.assetReadBytes,
            "metadataReadCalls": after.metadataReadCalls - before.metadataReadCalls,
            "metadataReadBytes": after.metadataReadBytes - before.metadataReadBytes,
            "assetWrittenBytes": after.assetWrittenBytes - before.assetWrittenBytes,
            "metadataWrittenBytes": after.metadataWrittenBytes - before.metadataWrittenBytes,
            "metadataEncodedBytes": after.metadataEncodedBytes - before.metadataEncodedBytes,
            "headPublications": after.headPublications - before.headPublications,
            "checkpointEncodings": after.checkpointEncodings - before.checkpointEncodings,
            "checkpointPublications": after.checkpointPublications - before.checkpointPublications,
            "checkpointWrittenBytes": after.checkpointWrittenBytes - before.checkpointWrittenBytes,
            "inputReferenceVisits": after.inputReferenceVisits - before.inputReferenceVisits,
            "referenceComparisons": after.referenceComparisons - before.referenceComparisons
        ]
    }

    nonisolated static func codec(_ before: InkCodec.WorkMetrics, _ after: InkCodec.WorkMetrics) -> [String: Int] {
        [
            "serializations": after.serializedStrokes - before.serializedStrokes,
            "assetSHABytes": after.hashedArchiveBytes - before.hashedArchiveBytes,
            "copiedArchiveBytes": after.copiedArchiveBytes - before.copiedArchiveBytes,
            "pointComparisons": after.comparedPoints - before.comparedPoints,
            "signatureChecks": after.signatureChecks - before.signatureChecks,
            "maskSnapshots": after.maskSnapshots - before.maskSnapshots,
            "maskComparisons": after.comparedMaskPaths - before.comparedMaskPaths,
            "renderStateEncodings": after.encodedRenderStates - before.encodedRenderStates,
            "renderStateBytes": after.renderStateBytes - before.renderStateBytes,
            "renderStateFallbacks": after.renderStateFallbacks - before.renderStateFallbacks,
            "propertyListRenderStates": after.propertyListRenderStates - before.propertyListRenderStates,
            "nativeDrawingFallbackSnapshots": after.nativeDrawingFallbackSnapshots - before.nativeDrawingFallbackSnapshots,
            "nativeDrawingEqualityFallbacks": after.nativeDrawingEqualityFallbacks - before.nativeDrawingEqualityFallbacks,
            "maskFallbacks": after.maskFallbacks - before.maskFallbacks,
            "uncacheableStrokeSignatures": after.uncacheableStrokeSignatures - before.uncacheableStrokeSignatures
        ]
    }
}
