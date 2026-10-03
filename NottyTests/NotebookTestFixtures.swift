import Foundation
import NottyCore
import PencilKit
import UIKit
@testable import Notty

enum NotebookTestFixtures {
    static func stroke(id: UUID = UUID(), x: CGFloat = 20) -> PKStroke {
        let points = (0..<4).map { index in
            PKStrokePoint(
                location: CGPoint(x: x + CGFloat(index) * 10, y: 40),
                timeOffset: Double(index) * 0.02,
                size: CGSize(width: 3, height: 3),
                opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
            )
        }
        var stroke = PKStroke(
            ink: PKInk(.pen, color: .black),
            path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1_000))
        )
        stroke.id = id
        return stroke
    }

    static func stamp(_ index: Int) -> NotebookEditStamp {
        NotebookEditStamp(
            capturedAt: Date(timeIntervalSince1970: Double(index)),
            uptime: Double(index) / 10,
            sessionID: UUID(uuidString: "6435D7F3-7945-475B-8A86-9A66B8DF32AD")!
        )
    }

    static func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    static func stored(drawing: PKDrawing = PKDrawing(), id: UUID) async throws -> StoredNotebook {
        StoredNotebook(
            id: id, revisionID: UUID(), sequence: 1,
            content: NotebookContent(
                title: "Notebook", pageCount: 3, strokes: try await InkCodec().encode(drawing)
            ),
            savedAt: Date(timeIntervalSince1970: 1_000)
        )
    }
}

actor NotebookStorageProbe {
    let recovery: NotebookRecoveryStore
    private var stored: StoredNotebook?
    private var saveFailure: NotebookSaveFailure?
    private var loadFailure: NotebookSaveFailure?
    private var preserveFailure: NotebookSaveFailure?
    private var suspendLoad = false
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private var suspendPreserve = false
    private var preserveContinuation: CheckedContinuation<Void, Never>?
    private var preserveWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var saveCalls = 0
    private(set) var preservedBatch: NotebookRecoveryBatch?

    init(stored: StoredNotebook?, recoveryRoot: URL) throws {
        self.stored = stored
        recovery = try NotebookRecoveryStore(rootURL: recoveryRoot)
    }

    func setSaveFailure(_ failure: NotebookSaveFailure?) { saveFailure = failure }
    func setLoadFailure(_ failure: NotebookSaveFailure?) { loadFailure = failure }
    func setPreserveFailure(_ failure: NotebookSaveFailure?) { preserveFailure = failure }
    func setSuspendLoad() { suspendLoad = true }
    func setSuspendPreserve() { suspendPreserve = true }

    func storage(notebookID: UUID) -> NotebookStorage {
        NotebookStorage(
            load: { try await self.load() },
            save: { try await self.save($0, revision: $1, notebookID: notebookID) },
            preserve: { try await self.preserve($0) },
            listRecovery: { try await self.recovery.list(notebookID: notebookID) },
            loadRecovery: { try await self.recovery.load(id: $0) }
        )
    }

    private func load() async throws -> StoredNotebook? {
        if suspendLoad {
            await withCheckedContinuation { continuation in
                loadContinuation = continuation
                let waiters = loadWaiters
                loadWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        if let loadFailure { throw loadFailure }
        return stored
    }

    func waitForLoad() async {
        if loadContinuation != nil { return }
        await withCheckedContinuation { loadWaiters.append($0) }
    }

    func releaseLoad() {
        suspendLoad = false
        let continuation = loadContinuation
        loadContinuation = nil
        continuation?.resume()
    }

    private func save(_ content: NotebookContent, revision: UUID?, notebookID: UUID) throws -> StoredNotebook {
        saveCalls += 1
        if let saveFailure { throw saveFailure }
        let next = StoredNotebook(
            id: notebookID, revisionID: UUID(), sequence: (stored?.sequence ?? 0) + 1,
            content: content, savedAt: Date()
        )
        stored = next
        return next
    }

    private func preserve(_ batch: NotebookRecoveryBatch) async throws -> NotebookRecoveryReceipt {
        if let preserveFailure { throw preserveFailure }
        preservedBatch = batch
        if suspendPreserve {
            await withCheckedContinuation { continuation in
                preserveContinuation = continuation
                let waiters = preserveWaiters
                preserveWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        return try await recovery.preserve(batch)
    }

    func waitForPreserve() async {
        if preserveContinuation != nil { return }
        await withCheckedContinuation { preserveWaiters.append($0) }
    }

    func releasePreserve() {
        suspendPreserve = false
        let continuation = preserveContinuation
        preserveContinuation = nil
        continuation?.resume()
    }
}
