import Combine
import Foundation
import NottyCore
import PencilKit
import UIKit

private struct NotebookDrawingSnapshot: Sendable, Equatable {
    let drawing: PKDrawing
    let pageCount: Int
    let title: String
}

@MainActor
final class NotebookSession: ObservableObject {
    enum LoadState: Equatable {
        case loading
        case ready
        case failed
    }

    let notebookID = UUID(uuidString: "E1E7AC14-D496-4893-B04B-A9169925D2A4")!

    @Published private(set) var loadState = LoadState.loading
    @Published private(set) var pageCount = 3
    @Published private(set) var title = "Personal notebook"

    private(set) var initialDrawing = PKDrawing()
    var snapshotProvider: (() -> PKDrawing?)?

    private let codec = InkCodec()
    private let editSessionID = UUID()
    private var latestDrawing = PKDrawing()
    private var coordinator: NotebookSaveCoordinator<NotebookDrawingSnapshot>?
    private var coordinatorObservation: AnyCancellable?
    private var loadStarted = false
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var backgroundWaiter: Task<Void, Never>?

    var saveState: NotebookSaveStatus { coordinator?.status ?? .idle }

    var inputPaused: Bool {
        coordinator.map { !$0.canAcceptInput } ?? false
    }

    var canEdit: Bool {
        loadState == .ready && (coordinator?.canAcceptInput ?? false)
    }

    func load() async {
        guard !loadStarted, loadState != .ready else { return }
        loadStarted = true
        loadState = .loading

        do {
            let repository = try await Self.makeRepository()
            let stored = try await repository.load(id: notebookID)
            let drawing: PKDrawing

            if let stored {
                guard (1...NotebookViewController.maximumPageCount)
                    .contains(stored.content.pageCount) else {
                    throw SessionError.unsupportedPaperExtent
                }
                drawing = try await codec.decode(stored.content.strokes)
                pageCount = stored.content.pageCount
                title = stored.content.title
            } else {
                drawing = PKDrawing()
                pageCount = 3
            }

            initialDrawing = drawing
            latestDrawing = drawing
            let snapshot = NotebookDrawingSnapshot(
                drawing: drawing, pageCount: pageCount, title: title
            )
            let codec = self.codec
            let notebookID = self.notebookID
            let coordinator = NotebookSaveCoordinator<NotebookDrawingSnapshot>(
                initialSnapshot: stored == nil ? nil : snapshot,
                expectedRevisionID: stored?.revisionID,
                savedAt: stored?.savedAt
            ) { snapshot, stamp, revisionID in
                let strokes = try await codec.encode(snapshot.drawing)
                let content = NotebookContent(
                    title: snapshot.title,
                    pageCount: snapshot.pageCount,
                    strokes: strokes,
                    editStamp: stamp
                )
                let receipt = try await repository.save(
                    id: notebookID,
                    content: content,
                    expectedRevisionID: revisionID
                )
                return NotebookSaveReceipt(
                    revisionID: receipt.revisionID,
                    savedAt: receipt.savedAt
                )
            }
            self.coordinator = coordinator
            coordinatorObservation = coordinator.objectWillChange.sink { [weak self] in
                self?.objectWillChange.send()
            }
            loadState = .ready

            if stored == nil {
                enqueue(drawing: drawing)
            }
        } catch {
            loadStarted = false
            loadState = .failed
        }
    }

    @discardableResult
    func recordCompletedEdit(_ drawing: PKDrawing) -> Bool {
        guard loadState == .ready else { return false }
        if drawing != latestDrawing {
            latestDrawing = drawing
            enqueue(drawing: drawing)
        }
        return canEdit
    }

    func extendPaper() {
        guard canEdit, pageCount < NotebookViewController.maximumPageCount else {
            return
        }
        let drawing = snapshotProvider?() ?? latestDrawing
        latestDrawing = drawing
        pageCount += 1
        enqueue(drawing: drawing)
    }

    func retrySave() {
        coordinator?.retry()
    }

    func flush() {
        guard loadState == .ready else { return }
        if let drawing = snapshotProvider?() {
            recordCompletedEdit(drawing)
        }
        guard let coordinator, coordinator.pendingCount > 0 else { return }

        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(
                withName: "Save notebook"
            ) { [weak self] in
                Task { @MainActor in
                    self?.endBackgroundTask()
                }
            }
        }
        guard backgroundWaiter == nil else { return }
        backgroundWaiter = Task { [self] in
            await coordinator.waitUntilSettled()
            endBackgroundTask()
            backgroundWaiter = nil
        }
    }

    private static func makeRepository() async throws -> NotebookRepository {
        try await Task.detached(priority: .utility) {
            let root = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("NottyLibrary", isDirectory: true)
            return try NotebookRepository(rootURL: root)
        }.value
    }

    private func enqueue(drawing: PKDrawing) {
        coordinator?.enqueue(
            snapshot: NotebookDrawingSnapshot(
                drawing: drawing, pageCount: pageCount, title: title
            ),
            stamp: NotebookEditStamp(
                capturedAt: Date(),
                uptime: ProcessInfo.processInfo.systemUptime,
                sessionID: editSessionID
            )
        )
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private enum SessionError: Error {
        case unsupportedPaperExtent
    }
}
