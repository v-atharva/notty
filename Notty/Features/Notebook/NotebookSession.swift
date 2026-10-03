import Combine
import Foundation
import NottyCore
import PencilKit

@MainActor
final class NotebookSession: ObservableObject {
    enum LoadState: Equatable {
        case loading
        case ready
        case failed(NotebookSaveFailure)
    }

    struct CanvasSeed {
        let ownerID: UUID
        let drawing: PKDrawing
        let pageCount: Int
    }

    private struct RecoveryCoverage: Equatable {
        let generation: UInt64
        let editIDs: [UUID]
        let baseRevisionID: UUID?
    }

    private struct PreservedState {
        let receipt: NotebookRecoveryReceipt
        let fingerprint: NotebookRecoveryFingerprint
        let coverage: RecoveryCoverage
    }

    static let defaultNotebookID = UUID(uuidString: "E1E7AC14-D496-4893-B04B-A9169925D2A4")!
    let notebookID: UUID

    @Published private(set) var loadState = LoadState.loading
    @Published private(set) var pageCount = 3
    @Published private(set) var title = "Personal notebook"
    @Published private(set) var canvasGeneration = UUID()
    @Published private(set) var isPerformingRecovery = false
    @Published private(set) var recoveryMessage: String?
    @Published private(set) var recoveryFailure: NotebookSaveFailure?
    @Published private(set) var recoveryCopies: [NotebookRecoveryReceipt] = []
    @Published private(set) var unavailableRecoveryCopyIDs: [UUID] = []
    @Published private(set) var isLoadingRecoveryCopies = false
    @Published private(set) var recoveryListFailure: NotebookSaveFailure?

    private(set) var workingDrawing = PKDrawing()
    private let openStorage: @Sendable () async throws -> NotebookStorage
    private let codec = InkCodec()
    private let recoveryCodec = NotebookRecoveryCodec()
    private let editSessionID = UUID()
    private let backgroundLease: NotebookBackgroundLease
    private var storage: NotebookStorage?
    private var coordinator: NotebookSaveCoordinator<NotebookDrawingSnapshot>?
    private var coordinatorObservation: AnyCancellable?
    private var loadStarted = false
    private var activeCanvasOwner: UUID?
    private var snapshotProvider: (() -> PKDrawing?)?
    private var preservedState: PreservedState?
    private struct BackgroundFlush {
        let id: UUID
        let coordinatorID: ObjectIdentifier
        var token: NotebookBackgroundLease.Token?
    }

    private var backgroundFlush: BackgroundFlush?
    private var backgroundWaiter: Task<Void, Never>?

    var saveState: NotebookSaveStatus { coordinator?.status ?? .idle }
    var pendingEdits: [NotebookPendingEdit<NotebookDrawingSnapshot>] {
        coordinator?.pendingEdits ?? []
    }
    var inputPaused: Bool { !canEdit }
    var canEdit: Bool {
        loadState == .ready && !isPerformingRecovery
            && (coordinator?.canAcceptInput ?? false)
    }
    var canPreserveRecovery: Bool {
        coordinator?.failure != nil && !pendingEdits.isEmpty && !isPerformingRecovery
    }
    var canReopenSaved: Bool {
        guard !isPerformingRecovery, let preservedState else { return false }
        return matches(preservedState.coverage)
    }

    init(
        notebookID: UUID = NotebookSession.defaultNotebookID,
        libraryRoot: URL? = nil,
        recoveryRoot: URL? = nil,
        backgroundLease: NotebookBackgroundLease? = nil,
        openStorage: (@Sendable () async throws -> NotebookStorage)? = nil
    ) {
        self.notebookID = notebookID
        self.backgroundLease = backgroundLease ?? NotebookBackgroundLease()
        self.openStorage = openStorage ?? {
            try await NotebookStorage.open(
                notebookID: notebookID, libraryRoot: libraryRoot, recoveryRoot: recoveryRoot
            )
        }
    }

    func load() async {
        guard !loadStarted else { return }
        loadStarted = true
        loadState = .loading
        do {
            let opened = try await openStorage()
            storage = opened
            let stored = try await opened.load()
            let drawing: PKDrawing
            if let stored {
                try validateExtent(stored.content.pageCount)
                drawing = try await codec.decode(stored.content.strokes)
            } else {
                drawing = PKDrawing()
            }
            install(stored: stored, drawing: drawing)
            if stored == nil { enqueueCurrentDrawing() }
        } catch {
            loadState = .failed(NotebookSaveFailure.classify(error))
            loadStarted = false
        }
    }

    func makeCanvasSeed() -> CanvasSeed {
        captureWorkingInk()
        let owner = UUID()
        activeCanvasOwner = owner
        snapshotProvider = nil
        return CanvasSeed(ownerID: owner, drawing: workingDrawing, pageCount: pageCount)
    }

    func attachCanvas(ownerID: UUID, snapshot: @escaping () -> PKDrawing?) {
        guard activeCanvasOwner == ownerID else { return }
        snapshotProvider = snapshot
    }

    func detachCanvas(ownerID: UUID) {
        guard activeCanvasOwner == ownerID else { return }
        captureWorkingInk()
        activeCanvasOwner = nil
        snapshotProvider = nil
    }

    @discardableResult
    func recordCompletedEdit(_ drawing: PKDrawing, ownerID: UUID) -> Bool {
        guard loadState == .ready, activeCanvasOwner == ownerID else { return false }
        retain(drawing)
        return canEdit
    }

    func extendPaper() {
        guard canEdit, pageCount < NotebookViewController.maximumPageCount else { return }
        captureWorkingInk()
        guard canEdit else { return }
        pageCount += 1
        enqueueCurrentDrawing()
    }

    func retrySave() {
        guard !isPerformingRecovery else { return }
        coordinator?.retry()
    }

    func flush() {
        guard loadState == .ready else { return }
        captureWorkingInk()
        guard let coordinator, coordinator.pendingCount > 0,
              coordinator.failure == nil else { return }
        let coordinatorID = ObjectIdentifier(coordinator)
        if var existing = backgroundFlush, existing.coordinatorID == coordinatorID {
            existing.token = backgroundLease.start()
            backgroundFlush = existing
            return
        }
        if let existing = backgroundFlush { finishBackgroundFlush(id: existing.id) }
        let id = UUID()
        backgroundFlush = BackgroundFlush(
            id: id, coordinatorID: coordinatorID, token: backgroundLease.start()
        )
        backgroundWaiter = Task { [self] in
            await coordinator.waitUntilSettled()
            finishBackgroundFlush(id: id)
        }
    }

    func waitUntilSettled() async {
        await coordinator?.waitUntilSettled()
        await backgroundWaiter?.value
    }

    private func finishBackgroundFlush(id: UUID) {
        guard let active = backgroundFlush, active.id == id else { return }
        if let token = active.token { backgroundLease.finish(token) }
        backgroundFlush = nil
        backgroundWaiter?.cancel()
        backgroundWaiter = nil
    }

    func saveRecoveryCopy() async {
        guard canPreserveRecovery, let storage, let coordinator else { return }
        captureWorkingInk()
        let coverage = currentCoverage()
        let edits = coordinator.pendingEdits
        isPerformingRecovery = true
        recoveryMessage = nil
        recoveryFailure = nil
        defer { isPerformingRecovery = false }
        do {
            let batch = try await recoveryCodec.encode(
                notebookID: notebookID, baseRevisionID: coverage.baseRevisionID, edits: edits
            )
            captureWorkingInk()
            let unchangedAfterEncoding = matches(coverage)
            let fingerprint = await recoveryCodec.fingerprint(batch)
            captureWorkingInk()
            let unchangedAfterFingerprint = matches(coverage)
            let receipt = try await storage.preserve(batch)
            captureWorkingInk()
            guard receipt.notebookID == notebookID, receipt.editCount == edits.count else {
                throw NotebookSaveFailure.corruptData
            }
            preservedState = PreservedState(
                receipt: receipt, fingerprint: fingerprint, coverage: coverage
            )
            if unchangedAfterEncoding && unchangedAfterFingerprint && matches(coverage) {
                recoveryMessage = "All waiting edits are preserved. You can reopen the saved notebook."
            } else {
                recoveryMessage = "A copy was preserved. Newer waiting edits need another copy before reopening."
            }
        } catch {
            captureWorkingInk()
            recoveryFailure = NotebookSaveFailure.classify(error)
            recoveryMessage = "The recovery copy could not be saved. Your waiting edits remain here."
        }
    }

    func reopenSavedNotebook() async {
        captureWorkingInk()
        guard canReopenSaved, let preservedState, let storage else { return }
        let coverage = preservedState.coverage
        isPerformingRecovery = true
        recoveryFailure = nil
        recoveryMessage = nil
        defer { isPerformingRecovery = false }
        var recoveryVerified = false
        do {
            let batch = try await storage.loadRecovery(preservedState.receipt.id)
            captureWorkingInk()
            guard matches(coverage) else { throw NotebookSaveFailure.invalidContent }
            let fingerprint = await recoveryCodec.fingerprint(batch)
            captureWorkingInk()
            guard matches(coverage) else { throw NotebookSaveFailure.invalidContent }
            guard fingerprint == preservedState.fingerprint else {
                throw NotebookSaveFailure.corruptData
            }
            recoveryVerified = true
            let stored = try await storage.load()
            captureWorkingInk()
            guard matches(coverage) else { throw NotebookSaveFailure.invalidContent }
            guard let stored else { throw NotebookSaveFailure.corruptData }
            try validateExtent(stored.content.pageCount)
            let drawing = try await codec.decode(stored.content.strokes)
            captureWorkingInk()
            guard matches(coverage) else { throw NotebookSaveFailure.invalidContent }
            // Invalidate the previous controller before publishing a new saved session.
            activeCanvasOwner = nil
            snapshotProvider = nil
            install(stored: stored, drawing: drawing)
            self.preservedState = nil
            recoveryMessage = "Saved notebook reopened. Your recovery copy remains available."
        } catch {
            captureWorkingInk()
            if !recoveryVerified { self.preservedState = nil }
            recoveryFailure = NotebookSaveFailure.classify(error)
            recoveryMessage = "The saved notebook could not be reopened. Your waiting edits remain here."
        }
    }

    func refreshRecoveryCopies() async {
        guard !isLoadingRecoveryCopies else { return }
        guard let storage else {
            recoveryListFailure = .storageUnavailable
            return
        }
        isLoadingRecoveryCopies = true
        recoveryListFailure = nil
        defer { isLoadingRecoveryCopies = false }
        do {
            let scan = try await storage.listRecovery()
            guard scan.copies.allSatisfy({ $0.notebookID == notebookID }),
                  Set(scan.copies.map(\.id)).count == scan.copies.count,
                  Set(scan.unavailableCopyIDs).count == scan.unavailableCopyIDs.count,
                  Set(scan.copies.map(\.id)).isDisjoint(with: scan.unavailableCopyIDs) else {
                throw NotebookSaveFailure.corruptData
            }
            recoveryCopies = scan.copies
            unavailableRecoveryCopyIDs = scan.unavailableCopyIDs
        } catch {
            recoveryListFailure = NotebookSaveFailure.classify(error)
        }
    }

    func openRecoveryCopy(id: UUID) async throws -> NotebookRecoveryBatch {
        guard let storage else { throw NotebookSaveFailure.storageUnavailable }
        let batch = try await storage.loadRecovery(id)
        guard batch.notebookID == notebookID else { throw NotebookSaveFailure.corruptData }
        return batch
    }

    private func currentCoverage() -> RecoveryCoverage {
        RecoveryCoverage(
            generation: coordinator?.generation ?? 0,
            editIDs: pendingEdits.map(\.id),
            baseRevisionID: coordinator?.expectedRevisionID
        )
    }

    private func matches(_ coverage: RecoveryCoverage) -> Bool {
        !coverage.editIDs.isEmpty && coverage == currentCoverage()
    }

    private func captureWorkingInk() {
        if let drawing = snapshotProvider?() { retain(drawing) }
    }

    private func retain(_ drawing: PKDrawing) {
        guard drawing != workingDrawing else { return }
        workingDrawing = drawing
        enqueueCurrentDrawing()
    }

    private func enqueueCurrentDrawing() {
        coordinator?.enqueue(
            snapshot: NotebookDrawingSnapshot(drawing: workingDrawing, pageCount: pageCount, title: title),
            stamp: NotebookEditStamp(
                capturedAt: Date(), uptime: ProcessInfo.processInfo.systemUptime, sessionID: editSessionID
            )
        )
    }

    private func validateExtent(_ count: Int) throws {
        guard (1...NotebookViewController.maximumPageCount).contains(count) else {
            throw NotebookSaveFailure.unsupportedFormat
        }
    }

    private func install(stored: StoredNotebook?, drawing: PKDrawing) {
        guard let storage else { return }
        if let active = backgroundFlush { finishBackgroundFlush(id: active.id) }
        workingDrawing = drawing
        pageCount = stored?.content.pageCount ?? 3
        title = stored?.content.title ?? "Personal notebook"
        let initial = NotebookDrawingSnapshot(drawing: drawing, pageCount: pageCount, title: title)
        let codec = self.codec
        let coordinator = NotebookSaveCoordinator(
            initialSnapshot: stored == nil ? nil : initial,
            expectedRevisionID: stored?.revisionID, savedAt: stored?.savedAt
        ) { snapshot, stamp, revision in
            let strokes = try await codec.encode(snapshot.drawing)
            let content = NotebookContent(
                title: snapshot.title, pageCount: snapshot.pageCount, strokes: strokes, editStamp: stamp
            )
            let result = try await storage.save(content, revision)
            return NotebookSaveReceipt(revisionID: result.revisionID, savedAt: result.savedAt)
        }
        coordinatorObservation = coordinator.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        self.coordinator = coordinator
        canvasGeneration = UUID()
        loadState = .ready
    }
}
