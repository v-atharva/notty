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
    private var loadStarted = false
    private var activeCanvasOwner: UUID?
    private var snapshotProvider: (() -> PKDrawing?)?
    private var observationProvider: (() -> NotebookCanvasObservation?)?
    private var canvasGateSink: ((NotebookInputGate) -> Void)?
    private var lastPushedCanvasGate: NotebookInputGate?
    private var latestCanvasGeneration: UInt64 = 0
    private var workingSignature: InkDrawingSignature?
    let gateModel = NotebookCanvasGateModel()
    let statusModel = NotebookSavePresentationModel()
    let renderDiagnostics = NotebookRenderDiagnostics()
    private var presentationObservation: AnyCancellable?
    private var preservedState: PreservedState?
    private var preservationTask: Task<Void, Never>?
    private var preservationID: UUID?
    private var recoveryWaiters: [CheckedContinuation<Void, Never>] = []
    private struct BackgroundFlush {
        let id: UUID
        let coordinatorID: ObjectIdentifier
        var token: NotebookBackgroundLease.Token?
    }

    private var backgroundFlush: BackgroundFlush?
    private var backgroundWaiter: Task<Void, Never>?

    var canvasOwnerID: UUID? { activeCanvasOwner }
    var saveState: NotebookSaveStatus { coordinator?.status ?? .idle }
    var pendingEdits: [NotebookPendingEdit<NotebookDrawingSnapshot>] {
        coordinator?.pendingEdits ?? []
    }
    var inputGate: NotebookInputGate {
        guard loadState == .ready else { return .failed }
        if isPerformingRecovery { return .recovering }
        guard let coordinator, coordinator.failure == nil else { return .failed }
        return coordinator.canAcceptInput ? .open : .capacity
    }
    var inputPaused: Bool { !inputGate.allowsMutation }
    var canEdit: Bool { inputGate.allowsMutation }

    func inputGateForCanvas(ownerID: UUID) -> NotebookInputGate {
        activeCanvasOwner == ownerID ? inputGate : .readOnly
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
        presentationObservation = objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPresentation() }
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
        observationProvider = nil
        canvasGateSink = nil
        lastPushedCanvasGate = nil
        latestCanvasGeneration = 0
        return CanvasSeed(ownerID: owner, drawing: workingDrawing, pageCount: pageCount)
    }

    func attachCanvas(ownerID: UUID, snapshot: @escaping () -> PKDrawing?) {
        guard activeCanvasOwner == ownerID else { return }
        observationProvider = nil
        canvasGateSink = nil
        lastPushedCanvasGate = nil
        snapshotProvider = snapshot
    }

    func attachCanvas(
        ownerID: UUID, observations: @escaping () -> NotebookCanvasObservation?,
        applyInputGate: @escaping (NotebookInputGate) -> Void = { _ in }
    ) {
        guard activeCanvasOwner == ownerID else { return }
        observationProvider = observations
        snapshotProvider = nil
        canvasGateSink = applyInputGate
        lastPushedCanvasGate = nil
        refreshPresentation()
    }

    func detachCanvas(ownerID: UUID) {
        guard activeCanvasOwner == ownerID else { return }
        captureWorkingInk()
        activeCanvasOwner = nil
        snapshotProvider = nil
        observationProvider = nil
        canvasGateSink = nil
        lastPushedCanvasGate = nil
    }

    @discardableResult
    func recordCompletedEdit(_ drawing: PKDrawing, ownerID: UUID) -> Bool {
        guard loadState == .ready, activeCanvasOwner == ownerID else { return false }
        retain(drawing)
        return canEdit
    }

    @discardableResult
    func recordObservation(_ observation: NotebookCanvasObservation, ownerID: UUID) -> Bool {
        guard loadState == .ready, activeCanvasOwner == ownerID,
              observation.generation > latestCanvasGeneration else { return false }
        latestCanvasGeneration = observation.generation
        workingDrawing = observation.drawing
        if let signature = observation.signature {
            workingSignature = signature
        } else {
            workingSignature = try? InkDrawingSignature(observation.drawing)
            if let workingSignature { renderDiagnostics.observationWork.add(workingSignature.constructionWork) }
        }
        enqueueCurrentDrawing(stamp: NotebookEditStamp(
            capturedAt: observation.capturedAt, uptime: observation.uptime, sessionID: editSessionID
        ))
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
        guard let coordinator, coordinator.pendingCount > 0 else { return }
        if coordinator.failure != nil, let preservedState, matches(preservedState.coverage) { return }
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
            while ownsBackgroundFlush(id: id, coordinator: coordinator) {
                await coordinator.waitUntilSettled()
                guard ownsBackgroundFlush(id: id, coordinator: coordinator) else { return }
                await waitUntilRecoveryFinished()
                guard ownsBackgroundFlush(id: id, coordinator: coordinator) else { return }
                captureWorkingInk()
                if coordinator.pendingEdits.isEmpty { break }
                if coordinator.failure == nil { continue }
                if let preservedState, matches(preservedState.coverage) { break }
                await saveRecoveryCopy()
                if recoveryFailure != nil { break }
            }
            finishBackgroundFlush(id: id)
        }
    }

    func waitUntilSettled() async {
        await coordinator?.waitUntilSettled()
        await backgroundWaiter?.value
    }

    private func ownsBackgroundFlush(
        id: UUID, coordinator: NotebookSaveCoordinator<NotebookDrawingSnapshot>
    ) -> Bool {
        !Task.isCancelled && self.coordinator === coordinator
            && backgroundFlush?.id == id
            && backgroundFlush?.coordinatorID == ObjectIdentifier(coordinator)
    }

    private func waitUntilRecoveryFinished() async {
        while isPerformingRecovery {
            await withCheckedContinuation { recoveryWaiters.append($0) }
        }
    }

    private func finishRecoveryOperation() {
        isPerformingRecovery = false
        let waiters = recoveryWaiters
        recoveryWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func finishBackgroundFlush(id: UUID) {
        guard let active = backgroundFlush, active.id == id else { return }
        if let token = active.token { backgroundLease.finish(token) }
        backgroundFlush = nil
        backgroundWaiter?.cancel()
        backgroundWaiter = nil
    }

    func saveRecoveryCopy() async {
        captureWorkingInk()
        if let preservationTask {
            await preservationTask.value
            return
        }
        guard canPreserveRecovery, let storage, let coordinator else { return }
        if let preservedState, matches(preservedState.coverage) { return }
        let id = UUID()
        preservationID = id
        isPerformingRecovery = true
        recoveryMessage = nil
        recoveryFailure = nil
        // The session owns this work even if a caller stops waiting.
        let task = Task { [self] in
            await preserveRecoveryCopy(storage: storage, coordinator: coordinator, id: id)
        }
        preservationTask = task
        await task.value
    }

    private func preserveRecoveryCopy(
        storage: NotebookStorage,
        coordinator: NotebookSaveCoordinator<NotebookDrawingSnapshot>,
        id: UUID
    ) async {
        let coverage = currentCoverage()
        let edits = coordinator.pendingEdits
        defer {
            if preservationID == id {
                preservationTask = nil
                preservationID = nil
                finishRecoveryOperation()
            }
        }
        do {
            let batch = try await recoveryCodec.encode(
                notebookID: notebookID, baseRevisionID: coverage.baseRevisionID, edits: edits
            )
            guard self.coordinator === coordinator, preservationID == id else { return }
            captureWorkingInk()
            let unchangedAfterEncoding = matches(coverage)
            let fingerprint = await recoveryCodec.fingerprint(batch)
            guard self.coordinator === coordinator, preservationID == id else { return }
            captureWorkingInk()
            let unchangedAfterFingerprint = matches(coverage)
            let receipt = try await storage.preserve(batch)
            guard self.coordinator === coordinator, preservationID == id else { return }
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
            guard self.coordinator === coordinator, preservationID == id else { return }
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
        defer { finishRecoveryOperation() }
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
        if let observation = observationProvider?(), let ownerID = activeCanvasOwner {
            recordObservation(observation, ownerID: ownerID)
        } else if let drawing = snapshotProvider?() {
            retain(drawing)
        }
    }

    private func retain(_ drawing: PKDrawing) {
        let signature = try? InkDrawingSignature(drawing)
        if let signature { renderDiagnostics.observationWork.add(signature.constructionWork) }
        if let signature, let workingSignature {
            let comparison = signature.compared(to: workingSignature)
            renderDiagnostics.observationWork.add(comparison.work)
            if comparison.isEqual { return }
        }
        workingSignature = signature
        workingDrawing = drawing
        enqueueCurrentDrawing()
    }

    private func enqueueCurrentDrawing(stamp: NotebookEditStamp? = nil) {
        guard let coordinator else { return }
        coordinator.enqueue(edit: NotebookPendingEdit(
            snapshot: NotebookDrawingSnapshot(drawing: workingDrawing, pageCount: pageCount, title: title),
            stamp: stamp ?? NotebookEditStamp(
                capturedAt: Date(), uptime: ProcessInfo.processInfo.systemUptime, sessionID: editSessionID
            )
        ))
        refreshPresentation()
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
        workingSignature = try? InkDrawingSignature(drawing)
        latestCanvasGeneration = 0
        activeCanvasOwner = nil
        snapshotProvider = nil
        observationProvider = nil
        pageCount = stored?.content.pageCount ?? 3
        title = stored?.content.title ?? "Personal notebook"
        let initial = NotebookDrawingSnapshot(drawing: drawing, pageCount: pageCount, title: title)
        let codec = self.codec
        let coordinator = NotebookSaveCoordinator(
            initialSnapshot: stored == nil ? nil : initial,
            expectedRevisionID: stored?.revisionID, savedAt: stored?.savedAt,
            saveBatch: { edits, revision in
                var encoded: [NotebookSaveEdit] = []
                var codecFailure: NotebookPendingFailure?
                for (index, edit) in edits.enumerated() {
                    do {
                        let strokes = try await codec.encode(edit.snapshot.drawing)
                        encoded.append(NotebookSaveEdit(
                            id: edit.id,
                            content: NotebookContent(
                                title: edit.snapshot.title, pageCount: edit.snapshot.pageCount,
                                strokes: strokes, editStamp: edit.stamp
                            )
                        ))
                    } catch {
                        codecFailure = NotebookPendingFailure(
                            index: index, editID: edit.id, cause: NotebookSaveFailure.classify(error)
                        )
                        break
                    }
                }
                if encoded.isEmpty {
                    return NotebookSaveBatchOutcome(committed: [], rejection: codecFailure)
                }
                let result = try await storage.saveBatch(encoded, revision)
                let rejection = result.rejection.map {
                    NotebookPendingFailure(
                        index: $0.index, editID: $0.editID, cause: NotebookSaveFailure.classify($0.error)
                    )
                }
                let reachedCodecFailure = result.committed.count == encoded.count
                    && result.rejection == nil
                return NotebookSaveBatchOutcome(
                    committed: result.committed,
                    rejection: rejection ?? (reachedCodecFailure ? codecFailure : nil)
                )
            }
        )
        coordinator.onStateChange = { [weak self, weak coordinator] in
            guard let self, let coordinator, self.coordinator === coordinator else { return }
            self.refreshPresentation()
        }
        self.coordinator = coordinator
        canvasGeneration = UUID()
        loadState = .ready
        refreshPresentation()
    }

    private func refreshPresentation() {
        if activeCanvasOwner != nil, let canvasGateSink, lastPushedCanvasGate != inputGate {
            lastPushedCanvasGate = inputGate
            canvasGateSink(inputGate)
        }
        gateModel.update(pageCount: pageCount, inputGate: inputGate)
        statusModel.update(NotebookSavePresentation(
            status: saveState, inputPaused: inputPaused, performingRecovery: isPerformingRecovery,
            canPreserveRecovery: canPreserveRecovery, canReopenSaved: canReopenSaved,
            recoveryMessage: recoveryMessage, recoveryFailure: recoveryFailure
        ))
    }
}

struct NotebookCanvasObservation: Sendable {
    let generation: UInt64
    let drawing: PKDrawing
    let capturedAt: Date
    let uptime: TimeInterval
    let signature: InkDrawingSignature?

    init(
        generation: UInt64, drawing: PKDrawing, capturedAt: Date, uptime: TimeInterval,
        signature: InkDrawingSignature? = nil
    ) {
        self.generation = generation
        self.drawing = drawing
        self.capturedAt = capturedAt
        self.uptime = uptime
        self.signature = signature
    }
}

@MainActor
final class NotebookCanvasGateModel: ObservableObject {
    struct State: Equatable {
        let pageCount: Int
        let inputGate: NotebookInputGate
    }

    @Published private(set) var state = State(pageCount: 3, inputGate: .failed)

    func update(pageCount: Int, inputGate: NotebookInputGate) {
        let next = State(pageCount: pageCount, inputGate: inputGate)
        if next != state { state = next }
    }
}

struct NotebookSavePresentation: Equatable {
    let status: NotebookSaveStatus
    let inputPaused: Bool
    let performingRecovery: Bool
    let canPreserveRecovery: Bool
    let canReopenSaved: Bool
    let recoveryMessage: String?
    let recoveryFailure: NotebookSaveFailure?
}

@MainActor
final class NotebookSavePresentationModel: ObservableObject {
    @Published private(set) var state = NotebookSavePresentation(
        status: .idle, inputPaused: true, performingRecovery: false,
        canPreserveRecovery: false, canReopenSaved: false,
        recoveryMessage: nil, recoveryFailure: nil
    )

    func update(_ next: NotebookSavePresentation) {
        if next != state { state = next }
    }
}

@MainActor
final class NotebookRenderDiagnostics {
    var screenBodyCount = 0
    var canvasUpdateCount = 0
    var observationWork = NotebookObservationWork()
}

struct NotebookObservationWork {
    private(set) var serializedStrokes = 0
    private(set) var copiedArchiveBytes = 0
    private(set) var hashedArchiveBytes = 0
    private(set) var propertyListRenderStates = 0
    private(set) var nativeDrawingFallbackSnapshots = 0
    private(set) var nativeDrawingEqualityFallbacks = 0
    private(set) var maskFallbacks = 0
    private(set) var comparedPoints = 0
    private(set) var signatureChecks = 0
    private(set) var maskSnapshots = 0
    private(set) var comparedMaskPaths = 0
    private(set) var encodedRenderStates = 0
    private(set) var renderStateBytes = 0
    private(set) var renderStateFallbacks = 0

    mutating func add(_ work: InkCodec.WorkMetrics) {
        serializedStrokes += work.serializedStrokes
        copiedArchiveBytes += work.copiedArchiveBytes
        hashedArchiveBytes += work.hashedArchiveBytes
        propertyListRenderStates += work.propertyListRenderStates
        nativeDrawingFallbackSnapshots += work.nativeDrawingFallbackSnapshots
        nativeDrawingEqualityFallbacks += work.nativeDrawingEqualityFallbacks
        maskFallbacks += work.maskFallbacks
        comparedPoints += work.comparedPoints
        signatureChecks += work.signatureChecks
        maskSnapshots += work.maskSnapshots
        comparedMaskPaths += work.comparedMaskPaths
        encodedRenderStates += work.encodedRenderStates
        renderStateBytes += work.renderStateBytes
        renderStateFallbacks += work.renderStateFallbacks
    }

    var values: [String: Int] {
        [
            "serializations": serializedStrokes, "copiedArchiveBytes": copiedArchiveBytes,
            "assetSHABytes": hashedArchiveBytes,
            "propertyListRenderStates": propertyListRenderStates,
            "nativeDrawingFallbackSnapshots": nativeDrawingFallbackSnapshots,
            "nativeDrawingEqualityFallbacks": nativeDrawingEqualityFallbacks,
            "maskFallbacks": maskFallbacks, "pointComparisons": comparedPoints,
            "signatureChecks": signatureChecks, "maskSnapshots": maskSnapshots,
            "maskComparisons": comparedMaskPaths, "renderStateEncodings": encodedRenderStates,
            "renderStateBytes": renderStateBytes, "renderStateFallbacks": renderStateFallbacks
        ]
    }
}
