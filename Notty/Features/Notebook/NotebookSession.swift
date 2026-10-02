import Combine
import Foundation
import NottyCore
import PencilKit
import UIKit

@MainActor
final class NotebookSession: ObservableObject {
    enum LoadState: Equatable {
        case loading
        case ready
        case failed
    }

    enum SaveState: Equatable {
        case idle
        case saving
        case saved(Date)
        case failed
    }

    private struct PendingEdit {
        let drawing: PKDrawing
        let pageCount: Int
        let stamp: NotebookEditStamp
    }

    static let maximumPendingEdits = 8
    let notebookID = UUID(uuidString: "E1E7AC14-D496-4893-B04B-A9169925D2A4")!

    @Published private(set) var loadState = LoadState.loading
    @Published private(set) var saveState = SaveState.idle
    @Published private(set) var pageCount = 3
    @Published private(set) var inputPaused = false
    @Published private(set) var title = "Personal notebook"

    private(set) var initialDrawing = PKDrawing()
    var snapshotProvider: (() -> PKDrawing?)?

    private let codec = InkCodec()
    private let editSessionID = UUID()
    private var repository: NotebookRepository?
    private var revisionID: UUID?
    private var latestDrawing = PKDrawing()
    private var pending: [PendingEdit] = []
    private var writer: Task<Void, Never>?
    private var loadStarted = false
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    var canEdit: Bool {
        loadState == .ready && !inputPaused && saveState != .failed
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
                revisionID = stored.revisionID
                saveState = .saved(stored.savedAt)
            } else {
                drawing = PKDrawing()
                pageCount = 3
                revisionID = nil
            }

            self.repository = repository
            initialDrawing = drawing
            latestDrawing = drawing
            loadState = .ready

            if stored == nil {
                enqueue(drawing: drawing, pageCount: pageCount)
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
            enqueue(drawing: drawing, pageCount: pageCount)
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
        enqueue(drawing: drawing, pageCount: pageCount)
    }

    func retrySave() {
        guard loadState == .ready, saveState == .failed else { return }
        saveState = .saving
        inputPaused = pending.count >= Self.maximumPendingEdits
        startWriter()
    }

    func flush() {
        guard loadState == .ready else { return }
        if let drawing = snapshotProvider?() {
            recordCompletedEdit(drawing)
        }
        guard !pending.isEmpty else { return }

        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(
                withName: "Save notebook"
            ) { [weak self] in
                Task { @MainActor in
                    self?.endBackgroundTask()
                }
            }
        }
        startWriter()
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

    private func enqueue(drawing: PKDrawing, pageCount: Int) {
        pending.append(PendingEdit(
            drawing: drawing,
            pageCount: pageCount,
            stamp: NotebookEditStamp(
                capturedAt: Date(),
                uptime: ProcessInfo.processInfo.systemUptime,
                sessionID: editSessionID
            )
        ))
        inputPaused = pending.count >= Self.maximumPendingEdits
        if saveState != .failed {
            saveState = .saving
            startWriter()
        }
    }

    private func startWriter() {
        guard writer == nil, saveState != .failed, !pending.isEmpty else {
            if pending.isEmpty { endBackgroundTask() }
            return
        }

        writer = Task { [self] in
            await drain()
            writer = nil
        }
    }

    private func drain() async {
        guard let repository else { return }

        while let edit = pending.first {
            do {
                let strokes = try await codec.encode(edit.drawing)
                let content = NotebookContent(
                    title: title,
                    pageCount: edit.pageCount,
                    strokes: strokes,
                    editStamp: edit.stamp
                )
                let stored = try await repository.save(
                    id: notebookID,
                    content: content,
                    expectedRevisionID: revisionID
                )
                revisionID = stored.revisionID
                pending.removeFirst()
                inputPaused = pending.count >= Self.maximumPendingEdits
                saveState = pending.isEmpty ? .saved(stored.savedAt) : .saving
            } catch {
                saveState = .failed
                inputPaused = true
                break
            }
        }
        endBackgroundTask()
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
