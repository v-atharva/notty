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
    private(set) var recoveryMessage: String?
    private(set) var recoveryFailure: NotebookSaveFailure?
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
    private var workingSnapshotIdentity = UUID()
    private var workingSignature: InkDrawingSignature?
    let gateModel = NotebookCanvasGateModel()
    let statusModel: NotebookSavePresentationModel
    let limitsModel = NotebookLimitsPresentationModel()
    let commandModel = NotebookCanvasCommandModel()
    private var canvasControls: NotebookCanvasControls?
    private var undoAvailability = NotebookUndoAvailability.unavailable
    private var paletteSuppressed = false
    private var isRefreshingPresentation = false
    private struct ExtentIntent {
        let installation: UUID
        let ownerID: UUID
        let completion: NotebookToolCompletion
    }
    private var extentIntent: ExtentIntent?
    private let feedbackDelay: @Sendable (Duration) async throws -> Void
    private var feedbackID = UUID()
    private var feedbackTask: Task<Void, Never>?
    let integrityModel = NotebookIntegrityPresentationModel()
    private var installationID = UUID()
    private var openingPin: NotebookHistoryPin?
    private var requiresPinRefresh = false
    private var integrityFailure: NotebookSaveFailure?
    private var auditID = UUID()
    private var auditTask: Task<Void, Never>?
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
        if integrityFailure != nil { return .readOnly }
        return coordinator.canAcceptInput ? .open : .capacity
    }
    var inputPaused: Bool { !inputGate.allowsMutation }
    var canEdit: Bool { inputGate.allowsMutation }

    func inputGateForCanvas(ownerID: UUID) -> NotebookInputGate {
        activeCanvasOwner == ownerID ? inputGate : .readOnly
    }
    var canPreserveRecovery: Bool {
        (coordinator?.failure != nil || integrityFailure != nil)
            && !pendingEdits.isEmpty && !isPerformingRecovery
    }
    var canReopenSaved: Bool {
        let availability = canvasControls?.currentAvailability() ?? undoAvailability
        guard !isPerformingRecovery, !availability.isUsingTool, let preservedState else { return false }
        return matches(preservedState.coverage)
    }

    init(
        notebookID: UUID = NotebookSession.defaultNotebookID,
        libraryRoot: URL? = nil,
        recoveryRoot: URL? = nil,
        backgroundLease: NotebookBackgroundLease? = nil,
        openStorage: (@Sendable () async throws -> NotebookStorage)? = nil,
        feedbackDelay: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.notebookID = notebookID
        self.feedbackDelay = feedbackDelay
        self.statusModel = NotebookSavePresentationModel(delay: feedbackDelay)
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
            let opening = try await readOpening(opened)
            let stored = opening.notebook
            let drawing: PKDrawing
            if let stored {
                try validateExtent(stored.content.pageCount)
                drawing = try await codec.decode(stored.content.strokes)
            } else {
                drawing = PKDrawing()
            }
            install(opening: opening, drawing: drawing)
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
        resetCanvasCommands()
        return CanvasSeed(ownerID: owner, drawing: workingDrawing, pageCount: pageCount)
    }

    func attachCanvas(ownerID: UUID, snapshot: @escaping () -> PKDrawing?) {
        guard activeCanvasOwner == ownerID else { return }
        observationProvider = nil
        canvasGateSink = nil
        lastPushedCanvasGate = nil
        snapshotProvider = snapshot
        resetCanvasCommands()
    }

    func attachCanvas(
        ownerID: UUID, observations: @escaping () -> NotebookCanvasObservation?,
        applyInputGate: @escaping (NotebookInputGate) -> Void = { _ in },
        controls: NotebookCanvasControls? = nil
    ) {
        guard activeCanvasOwner == ownerID else { return }
        observationProvider = observations
        snapshotProvider = nil
        canvasGateSink = applyInputGate
        canvasControls = controls
        lastPushedCanvasGate = nil
        controls?.setPaletteSuppressed(paletteSuppressed)
        if let controls { undoAvailability = controls.currentAvailability() }
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
        resetCanvasCommands()
        refreshPresentation()
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
        extentIntent = nil
        pageCount += 1
        canvasControls?.applyPageCount(pageCount)
        enqueueCurrentDrawing()
    }


    func updateUndoAvailability(_ availability: NotebookUndoAvailability, ownerID: UUID) {
        guard activeCanvasOwner == ownerID else { return }
        undoAvailability = availability
        refreshPresentation()
    }

    func canPerformHistoryAction(ownerID: UUID) -> Bool {
        guard activeCanvasOwner == ownerID, !paletteSuppressed,
              inputGate == .open || inputGate == .capacity else { return false }
        let availability = canvasControls?.currentAvailability() ?? undoAvailability
        return !availability.isUsingTool
    }

    // The native controller owns the capacity reservation; the session checks admission.
    func reserveHistoryAction(ownerID: UUID) -> Bool {
        canPerformHistoryAction(ownerID: ownerID)
    }

    func undo() {
        guard let owner = activeCanvasOwner, canPerformHistoryAction(ownerID: owner) else { return }
        canvasControls?.undo()
    }

    func redo() {
        guard let owner = activeCanvasOwner, canPerformHistoryAction(ownerID: owner) else { return }
        canvasControls?.redo()
    }

    @discardableResult
    func beginRecoveryCopiesPresentation() -> Bool {
        let availability = canvasControls?.currentAvailability() ?? undoAvailability
        guard !availability.isUsingTool else { return false }
        paletteSuppressed = true
        canvasControls?.setPaletteSuppressed(true)
        refreshPresentation()
        return true
    }

    func endRecoveryCopiesPresentation() {
        paletteSuppressed = false
        canvasControls?.setPaletteSuppressed(false)
        refreshPresentation()
    }

    func cancelCanvasToolCompletion(ownerID: UUID) {
        guard activeCanvasOwner == ownerID else { return }
        extentIntent = nil
    }

    func completedTool(_ completion: NotebookToolCompletion, ownerID: UUID) {
        guard activeCanvasOwner == ownerID,
              completion.pageCount == pageCount,
              completion.generation > 0,
              completion.generation <= latestCanvasGeneration,
              completion.nearPaperEnd,
              completion.capturedAt.timeIntervalSince1970.isFinite,
              completion.uptime.isFinite, completion.uptime >= 0,
              pageCount < NotebookViewController.maximumPageCount,
              inputGate == .open || inputGate == .capacity else { return }
        guard extentIntent == nil else { return }
        extentIntent = ExtentIntent(
            installation: installationID, ownerID: ownerID, completion: completion
        )
        refreshPresentation()
    }

    private func applyExtentIntentIfReady() {
        guard let intent = extentIntent else { return }
        guard intent.installation == installationID, intent.ownerID == activeCanvasOwner,
              intent.completion.pageCount == pageCount,
              latestCanvasGeneration >= intent.completion.generation,
              pageCount < NotebookViewController.maximumPageCount else {
            extentIntent = nil
            return
        }
        let availability = canvasControls?.currentAvailability() ?? undoAvailability
        guard !availability.isUsingTool else { return }
        guard NotebookPaperMetrics.isNearPaperEnd(workingDrawing, pageCount: pageCount) else {
            extentIntent = nil
            return
        }
        // The request is conditional on current content, not on later callback provenance.
        extentIntent = nil
        pageCount += 1
        canvasControls?.applyPageCount(pageCount)
        enqueueCurrentDrawing(stamp: NotebookEditStamp(
            capturedAt: intent.completion.capturedAt, uptime: intent.completion.uptime,
            sessionID: editSessionID
        ))
    }

    private func resetCanvasCommands() {
        canvasControls = nil
        undoAvailability = .unavailable
        extentIntent = nil
        commandModel.update(NotebookCanvasCommandModel.State(
            canUndo: false, canRedo: false, isUsingTool: false, canOpenRecoveryCopies: true
        ))
    }

    private func refreshCommandAvailability() {
        if let canvasControls { undoAvailability = canvasControls.currentAvailability() }
        let canAct = activeCanvasOwner.map { canPerformHistoryAction(ownerID: $0) } ?? false
        commandModel.update(NotebookCanvasCommandModel.State(
            canUndo: canAct && undoAvailability.canUndo,
            canRedo: canAct && undoAvailability.canRedo,
            isUsingTool: undoAvailability.isUsingTool,
            canOpenRecoveryCopies: !undoAvailability.isUsingTool
        ))
    }

    private func clearRecoveryFeedback() {
        feedbackTask?.cancel()
        feedbackTask = nil
        feedbackID = UUID()
        recoveryMessage = nil
        recoveryFailure = nil
        refreshPresentation()
    }

    private func setRecoveryFeedback(_ message: String, failure: NotebookSaveFailure? = nil) {
        clearRecoveryFeedback()
        recoveryMessage = message
        recoveryFailure = failure
        refreshPresentation()
        guard failure == nil else { return }
        let installation = installationID
        let id = feedbackID
        let delay = feedbackDelay
        feedbackTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            do { try await delay(.seconds(5)) } catch { return }
            guard !Task.isCancelled, let self,
                  self.installationID == installation, self.feedbackID == id,
                  self.recoveryFailure == nil else { return }
            self.recoveryMessage = nil
            self.feedbackTask = nil
            self.refreshPresentation()
        }
    }

    func retrySave() {
        guard !isPerformingRecovery, let coordinator,
              coordinator.failure?.canRetry == true, coordinator.pendingCount > 0 else { return }
        clearRecoveryFeedback()
        coordinator.retry()
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

    func codecWorkMetrics() async -> InkCodec.WorkMetrics {
        await codec.workMetrics
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
        clearRecoveryFeedback()
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
                setRecoveryFeedback("All waiting edits are preserved. You can reopen the saved notebook.")
            } else {
                setRecoveryFeedback("A copy was preserved. Newer waiting edits need another copy before reopening.")
            }
        } catch {
            guard self.coordinator === coordinator, preservationID == id else { return }
            captureWorkingInk()
            setRecoveryFeedback(
                "The recovery copy could not be saved. Your waiting edits remain here.",
                failure: NotebookSaveFailure.classify(error)
            )
        }
    }

    func reopenSavedNotebook() async {
        captureWorkingInk()
        guard canReopenSaved, let preservedState, let storage else { return }
        let coverage = preservedState.coverage
        retireAudit()
        isPerformingRecovery = true
        clearRecoveryFeedback()
        extentIntent = nil
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
            let opening = try await readOpening(storage)
            let stored = opening.notebook
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
            install(opening: opening, drawing: drawing)
            self.preservedState = nil
            setRecoveryFeedback("Saved notebook reopened. Your recovery copy remains available.")
        } catch {
            captureWorkingInk()
            if !recoveryVerified { self.preservedState = nil }
            setRecoveryFeedback(
                "The saved notebook could not be reopened. Your waiting edits remain here.",
                failure: NotebookSaveFailure.classify(error)
            )
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
        let snapshot = NotebookDrawingSnapshot(drawing: workingDrawing, pageCount: pageCount, title: title)
        workingSnapshotIdentity = snapshot.identity
        limitsModel.beginSnapshot(
            identity: snapshot.identity, installation: installationID,
            strokeCount: workingDrawing.strokes.count
        )
        coordinator.enqueue(edit: NotebookPendingEdit(
            snapshot: snapshot,
            stamp: stamp ?? NotebookEditStamp(
                capturedAt: Date(), uptime: ProcessInfo.processInfo.systemUptime, sessionID: editSessionID
            )
        ))
        refreshPresentation()
    }

    private func recordEncodedBytes(_ count: Int, identity: UUID, installation: UUID) {
        guard installationID == installation, workingSnapshotIdentity == identity else { return }
        limitsModel.recordEncodedBytes(count, identity: identity, installation: installation)
    }

    private func validateExtent(_ count: Int) throws {
        guard (1...NotebookViewController.maximumPageCount).contains(count) else {
            throw NotebookSaveFailure.unsupportedFormat
        }
    }

    private func install(opening: NotebookOpening, drawing: PKDrawing) {
        let stored = opening.notebook
        guard let storage else { return }
        if let active = backgroundFlush { finishBackgroundFlush(id: active.id) }
        retireAudit()
        installationID = UUID()
        clearRecoveryFeedback()
        statusModel.reset()
        resetCanvasCommands()
        openingPin = opening.historyPin
        requiresPinRefresh = storage.auditHistory != nil && opening.requiresFirstPublicationRefresh
        integrityFailure = nil
        integrityModel.update(nil)
        let installedID = installationID
        workingDrawing = drawing
        workingSignature = try? InkDrawingSignature(drawing)
        latestCanvasGeneration = 0
        activeCanvasOwner = nil
        snapshotProvider = nil
        observationProvider = nil
        pageCount = stored?.content.pageCount ?? 3
        title = stored?.content.title ?? "Personal notebook"
        let initial = NotebookDrawingSnapshot(drawing: drawing, pageCount: pageCount, title: title)
        workingSnapshotIdentity = initial.identity
        limitsModel.beginSnapshot(
            identity: initial.identity, installation: installedID, strokeCount: drawing.strokes.count
        )
        if let stored {
            limitsModel.recordEncodedBytes(
                stored.content.strokes.reduce(0) { $0 + $1.data.count },
                identity: initial.identity, installation: installedID
            )
        }
        let codec = self.codec
        let coordinator = NotebookSaveCoordinator(
            initialSnapshot: stored == nil ? nil : initial,
            expectedRevisionID: stored?.revisionID, savedAt: stored?.savedAt,
            saveBatch: { [weak self] edits, revision in
                var encoded: [NotebookSaveEdit] = []
                var codecFailure: NotebookPendingFailure?
                for (index, edit) in edits.enumerated() {
                    do {
                        let strokes = try await codec.encode(edit.snapshot.drawing)
                        await self?.recordEncodedBytes(
                            strokes.reduce(0) { $0 + $1.data.count },
                            identity: edit.snapshot.identity, installation: installedID
                        )
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
                    await self?.refreshHistoryPin(
                        installation: installedID, expectedRevisionID: revision, published: false
                    )
                    return NotebookSaveBatchOutcome(committed: [], rejection: codecFailure)
                }
                let result: NotebookBatchSaveResult
                do {
                    result = try await storage.saveBatch(encoded, revision)
                } catch {
                    await self?.refreshHistoryPin(
                        installation: installedID, expectedRevisionID: revision, published: false
                    )
                    throw error
                }
                await self?.refreshHistoryPin(
                    installation: installedID,
                    expectedRevisionID: result.committed.last?.revisionID ?? revision,
                    published: !result.committed.isEmpty
                )
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
        if let pin = openingPin {
            startAudit(pin: pin)
        } else if storage.auditHistory != nil {
            integrityModel.update(stored == nil ? .checking : .incomplete(.storageUnavailable))
        }
        refreshPresentation()
    }


    private func readOpening(_ storage: NotebookStorage) async throws -> NotebookOpening {
        let opening: NotebookOpening
        if let open = storage.openForEditing {
            opening = try await open()
        } else {
            opening = NotebookOpening(notebook: try await storage.load(), historyPin: nil)
        }
        if let pin = opening.historyPin {
            guard pin.notebookID == notebookID,
                  pin.revisionID == opening.notebook?.revisionID,
                  pin.sequence == opening.notebook?.sequence else {
                throw NotebookSaveFailure.corruptData
            }
        }
        return opening
    }

    private func retireAudit() {
        auditID = UUID()
        auditTask?.cancel()
        auditTask = nil
        if integrityModel.state == .checking { integrityModel.update(nil) }
    }

    private func startAudit(pin: NotebookHistoryPin) {
        guard let audit = storage?.auditHistory else { return }
        retireAudit()
        let id = auditID
        let installation = installationID
        if integrityFailure == nil { integrityModel.update(.checking) }
        auditTask = Task { [weak self] in
            let outcome = await audit(pin)
            guard !Task.isCancelled, let self,
                  self.installationID == installation, self.auditID == id else { return }
            self.auditTask = nil
            switch outcome {
            case .verified(let report):
                guard report.notebookID == pin.notebookID,
                      report.headRevisionID == pin.revisionID,
                      report.revisionCount == pin.sequence, report.revisionCount > 0,
                      report.verifiedAssetCount >= 0 else {
                    self.integrityFailure = .corruptData
                    self.integrityModel.update(.damaged(.corruptData))
                    self.refreshPresentation()
                    return
                }
                if self.integrityFailure == nil {
                    self.integrityModel.update(.verified(revisions: report.revisionCount))
                }
            case .damaged(let failure):
                self.integrityFailure = failure
                self.integrityModel.update(.damaged(failure))
            case .incomplete(let failure):
                if self.integrityFailure == nil { self.integrityModel.update(.incomplete(failure)) }
            case .cancelled:
                if self.integrityFailure == nil { self.integrityModel.update(nil) }
            }
            self.refreshPresentation()
        }
    }

    private func refreshHistoryPin(
        installation: UUID, expectedRevisionID: UUID?, published: Bool
    ) async {
        guard installationID == installation, requiresPinRefresh, let storage else { return }
        let previousPin = openingPin
        // Migration may select its equivalent anchor even when the following save fails.
        retireAudit()
        if published { requiresPinRefresh = false }
        guard let revision = expectedRevisionID, let capture = storage.captureHistoryPin else {
            if integrityFailure == nil { integrityModel.update(.incomplete(.storageUnavailable)) }
            refreshPresentation()
            return
        }
        do {
            let pin = try await capture(revision)
            guard installationID == installation else { return }
            guard pin.notebookID == notebookID, pin.revisionID == revision else {
                throw NotebookSaveFailure.revisionConflict
            }
            if let previousPin, previousPin.requiresFirstPublicationRefresh,
               !pin.requiresFirstPublicationRefresh,
               !previousPin.hasSameHistoryGeneration(as: pin) {
                integrityFailure = nil
                integrityModel.update(nil)
            }
            requiresPinRefresh = pin.requiresFirstPublicationRefresh
            openingPin = pin
            startAudit(pin: pin)
        } catch {
            guard installationID == installation else { return }
            if integrityFailure == nil {
                integrityModel.update(.incomplete(NotebookSaveFailure.classify(error)))
            }
        }
        refreshPresentation()
    }

    deinit {
        auditTask?.cancel()
        feedbackTask?.cancel()
    }

    private func refreshPresentation() {
        guard !isRefreshingPresentation else { return }
        isRefreshingPresentation = true
        defer { isRefreshingPresentation = false }
        if inputGate == .failed || inputGate == .readOnly || inputGate == .recovering {
            extentIntent = nil
        }
        if inputGate == .open {
            applyExtentIntentIfReady()
        }
        if activeCanvasOwner != nil, let canvasGateSink, lastPushedCanvasGate != inputGate {
            lastPushedCanvasGate = inputGate
            canvasGateSink(inputGate)
        }
        refreshCommandAvailability()
        gateModel.update(pageCount: pageCount, inputGate: inputGate)
        statusModel.update(NotebookSavePresentation(
            status: saveState, inputPaused: inputPaused, performingRecovery: isPerformingRecovery,
            canPreserveRecovery: canPreserveRecovery, canReopenSaved: canReopenSaved,
            recoveryMessage: recoveryMessage, recoveryFailure: recoveryFailure,
            isReady: loadState == .ready
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
    let isReady: Bool

    init(
        status: NotebookSaveStatus, inputPaused: Bool, performingRecovery: Bool,
        canPreserveRecovery: Bool, canReopenSaved: Bool,
        recoveryMessage: String?, recoveryFailure: NotebookSaveFailure?, isReady: Bool = true
    ) {
        self.status = status
        self.inputPaused = inputPaused
        self.performingRecovery = performingRecovery
        self.canPreserveRecovery = canPreserveRecovery
        self.canReopenSaved = canReopenSaved
        self.recoveryMessage = recoveryMessage
        self.recoveryFailure = recoveryFailure
        self.isReady = isReady
    }
}

@MainActor
final class NotebookSavePresentationModel: ObservableObject {
    @Published private(set) var state = NotebookSavePresentation(
        status: .idle, inputPaused: true, performingRecovery: false,
        canPreserveRecovery: false, canReopenSaved: false,
        recoveryMessage: nil, recoveryFailure: nil, isReady: false
    )

    @Published private(set) var displayedStatus = NotebookSaveStatus.idle
    private let delay: @Sendable (Duration) async throws -> Void
    private var savingTask: Task<Void, Never>?
    private var episode = UUID()

    init(delay: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.delay = delay
    }

    func reset() {
        savingTask?.cancel()
        savingTask = nil
        episode = UUID()
        displayedStatus = .idle
    }

    func update(_ next: NotebookSavePresentation) {
        if next != state { state = next }
        if next.status == .saving {
            guard savingTask == nil, displayedStatus != .saving else { return }
            let id = episode
            let delay = delay
            savingTask = Task { @MainActor [weak self] in
                guard !Task.isCancelled else { return }
                do { try await delay(.milliseconds(400)) } catch { return }
                guard !Task.isCancelled, let self, self.episode == id,
                      self.state.status == .saving else { return }
                self.displayedStatus = .saving
                self.savingTask = nil
            }
        } else {
            savingTask?.cancel()
            savingTask = nil
            episode = UUID()
            if displayedStatus != next.status { displayedStatus = next.status }
        }
    }

    deinit { savingTask?.cancel() }
}

@MainActor
final class NotebookCanvasCommandModel: ObservableObject {
    struct State: Equatable {
        let canUndo: Bool
        let canRedo: Bool
        let isUsingTool: Bool
        let canOpenRecoveryCopies: Bool
    }

    @Published private(set) var state = State(
        canUndo: false, canRedo: false, isUsingTool: false, canOpenRecoveryCopies: true
    )

    func update(_ next: State) {
        if state != next { state = next }
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
    private(set) var uncacheableStrokeSignatures = 0

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
        uncacheableStrokeSignatures += work.uncacheableStrokeSignatures
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
            "renderStateBytes": renderStateBytes, "renderStateFallbacks": renderStateFallbacks,
            "uncacheableStrokeSignatures": uncacheableStrokeSignatures
        ]
    }
}

enum NotebookIntegrityState: Equatable {
    case checking
    case verified(revisions: Int)
    case damaged(NotebookSaveFailure)
    case incomplete(NotebookSaveFailure)

    var label: String {
        switch self {
        case .checking: "Checking notebook history"
        case .verified: "Notebook history verified"
        case .damaged: "Notebook history is damaged"
        case .incomplete: "Notebook history check is incomplete"
        }
    }

    var detail: String {
        switch self {
        case .checking:
            "You can keep writing while older edits are checked."
        case .verified(let count):
            "\(count) saved revisions were verified."
        case .damaged:
            "New writing is paused. You can read, scroll and zoom. Waiting edits continue saving; unsaved edits can be preserved in a recovery copy."
        case .incomplete:
            "Older edits could not be fully checked. You can keep writing and check again when you reopen the notebook."
        }
    }
}

@MainActor
final class NotebookIntegrityPresentationModel: ObservableObject {
    @Published private(set) var state: NotebookIntegrityState?

    func update(_ next: NotebookIntegrityState?) {
        if next != state { state = next }
    }
}


@MainActor
final class NotebookLimitsPresentationModel: ObservableObject {
    struct State: Equatable {
        let strokeCount: Int
        let encodedBytes: Int?

        var isNearLimit: Bool {
            strokeCount >= 9_000 || (encodedBytes.map { $0 >= 60_397_978 } ?? false)
        }
    }

    @Published private(set) var state = State(strokeCount: 0, encodedBytes: nil)
    private var identity: UUID?
    private var installation: UUID?

    func beginSnapshot(identity: UUID, installation: UUID, strokeCount: Int) {
        self.identity = identity
        self.installation = installation
        update(State(strokeCount: strokeCount, encodedBytes: nil))
    }

    func recordEncodedBytes(_ count: Int, identity: UUID, installation: UUID) {
        guard count >= 0, self.identity == identity, self.installation == installation else { return }
        update(State(strokeCount: state.strokeCount, encodedBytes: count))
    }

    private func update(_ next: State) {
        guard next != state else { return }
        state = next
    }
}
