import NottyCore
import PencilKit
import UIKit

enum NotebookInputGate: Sendable, Equatable {
    case open
    case capacity
    case failed
    case recovering
    case readOnly

    var allowsMutation: Bool { self == .open }
    var keepsPalette: Bool { self == .open || self == .capacity }
}

@MainActor
final class NotebookViewController: UIViewController {
    static let maximumPageCount = 12

    private let geometry = NotebookPaperMetrics.geometry
    private let logicalWidth = CGFloat(NotebookPaperMetrics.pageWidth)
    private let canvas = NotebookCanvasView()
    let paperView: NotebookPaperView
    private let injectedToolPicker: PKToolPicker?
    private let allowsEditing: Bool
    private var scenePickerOwner: NotebookSceneToolPicker?
    private var toolPicker: PKToolPicker?
    private var undoObservers: [NSObjectProtocol] = []
    private var retainedUndoManager: UndoManager?
    private var capacityHistoryActionReserved = false
    private var paletteSuppressed = false
    private var isTornDown = false
    private var isPublishingUndoAvailability = false
    private var toolBeginSignature: InkDrawingSignature?
    private var toolBeginGeneration: UInt64?

    var onObservation: ((NotebookCanvasObservation) -> NotebookInputGate)?
    var onCompletedEdit: ((PKDrawing) -> NotebookInputGate)?
    var onDetach: (() -> Void)?
    var canvasView: PKCanvasView { canvas }
    var drawingToolPicker: PKToolPicker? { toolPicker }
    var onUndoAvailabilityChange: ((NotebookUndoAvailability) -> Void)?
    var onToolCompletion: ((NotebookToolCompletion) -> Void)?
    var onInteractionInterrupted: (() -> Void)?
    var canPerformHistoryAction: (() -> Bool)?
    var reserveHistoryAction: (() -> Bool)?
    var currentUndoAvailability: NotebookUndoAvailability {
        let admitted = !isTornDown && !paletteSuppressed && !canvas.hasActiveTool
            && (inputGate == .open || (inputGate == .capacity && !capacityHistoryActionReserved))
        return NotebookUndoAvailability(
            canUndo: admitted && (retainedUndoManager?.canUndo ?? false),
            canRedo: admitted && (retainedUndoManager?.canRedo ?? false),
            isUsingTool: canvas.hasActiveTool
        )
    }
    var currentDrawing: PKDrawing { canvas.drawing }

    private let initialDrawing: PKDrawing
    private var lastDeliveredSignature: InkDrawingSignature?
    private var observedGeneration: UInt64 = 0
    private var lastObservation: NotebookCanvasObservation?
    private(set) var observationWork = NotebookObservationWork()
    var barrierPointComparisons: Int { observationWork.comparedPoints }
    var barrierSignatureChecks: Int { observationWork.signatureChecks }
    private(set) var inputGate = NotebookInputGate.open
    private var pageCount: Int
    private var previousViewportSize = CGSize.zero
    private var isAdjustingLayout = false
    private var observesToolPicker = false
    private var paletteKeepsAccess = false

    private var logicalHeight: CGFloat {
        CGFloat(geometry.pageHeight) * CGFloat(pageCount)
    }

    init(
        pageCount: Int, initialDrawing: PKDrawing, toolPicker: PKToolPicker? = nil,
        allowsEditing: Bool = true, paperView: NotebookPaperView? = nil
    ) {
        self.injectedToolPicker = toolPicker
        self.allowsEditing = allowsEditing
        self.paperView = paperView ?? NotebookPaperView(frame: .zero)
        self.initialDrawing = initialDrawing
        self.lastDeliveredSignature = try? InkDrawingSignature(initialDrawing)
        self.pageCount = min(max(pageCount, 1), Self.maximumPageCount)
        self.inputGate = allowsEditing ? .open : .readOnly
        super.init(nibName: nil, bundle: nil)
        if let lastDeliveredSignature { observationWork.add(lastDeliveredSignature.constructionWork) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(pageCount:initialDrawing:).")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = NotebookPaperView.paperColor
        view.clipsToBounds = true

        canvas.drawing = initialDrawing
        canvas.delegate = self
        canvas.permitsMutation = inputGate.allowsMutation
        canvas.permitsHistoryAccess = inputGate.keepsPalette
        canvas.onUndo = { [weak self] in self?.performUndo() }
        canvas.onRedo = { [weak self] in self?.performRedo() }
        canvas.historyAvailability = { [weak self] in self?.currentUndoAvailability ?? .unavailable }
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        #if targetEnvironment(simulator)
        canvas.drawingPolicy = .anyInput
        #else
        canvas.drawingPolicy = .pencilOnly
        let directTouches = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        canvas.panGestureRecognizer.allowedTouchTypes = directTouches
        canvas.pinchGestureRecognizer?.allowedTouchTypes = directTouches
        #endif
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.automaticallyAdjustsScrollIndicatorInsets = false
        canvas.alwaysBounceVertical = false
        canvas.alwaysBounceHorizontal = false
        canvas.bouncesZoom = true
        canvas.showsHorizontalScrollIndicator = false
        canvas.showsVerticalScrollIndicator = true
        canvas.accessibilityLabel = "Notebook paper"
        canvas.accessibilityHint =
            "Write with Apple Pencil. Use a finger to scroll and pinch to zoom."

        view.addSubview(paperView)
        view.addSubview(canvas)
        updatePaperGeometry()
        updateContentExtent()
        refreshUndoManager()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let newSize = view.bounds.size
        guard newSize.width > 0, newSize.height > 0 else { return }

        guard newSize != previousViewportSize else {
            updateInsets()
            updatePaperViewport()
            return
        }

        let hadViewport = previousViewportSize.width > 0
        let oldScale = max(canvas.zoomScale, 0.001)
        let oldFit = previousViewportSize.width / logicalWidth
        let wasWidthFitted = !hadViewport || abs(oldScale - oldFit) < 0.01
        let logicalCenter = CGPoint(
            x: (canvas.contentOffset.x + previousViewportSize.width / 2) / oldScale,
            y: (canvas.contentOffset.y + previousViewportSize.height / 2) / oldScale
        )

        isAdjustingLayout = true
        paperView.frame = view.bounds
        canvas.frame = view.bounds
        let fitScale = newSize.width / logicalWidth
        let maximumScale = max(3, fitScale * 4)
        canvas.maximumZoomScale = maximumScale
        let minimumScale = min(fitScale * 0.5, newSize.height / CGFloat(geometry.pageHeight))
        canvas.minimumZoomScale = minimumScale
        let requestedScale = wasWidthFitted ? fitScale : oldScale
        let scale = min(max(requestedScale, minimumScale), maximumScale)
        canvas.setZoomScale(scale, animated: false)
        updateContentExtent()
        updateInsets()

        let proposedOffset: CGPoint
        if hadViewport {
            proposedOffset = CGPoint(
                x: logicalCenter.x * scale - newSize.width / 2,
                y: logicalCenter.y * scale - newSize.height / 2
            )
        } else {
            proposedOffset = CGPoint(x: -canvas.contentInset.left, y: -canvas.contentInset.top)
        }
        canvas.setContentOffset(clampedOffset(proposedOffset), animated: false)
        previousViewportSize = newSize
        isAdjustingLayout = false
        updatePaperViewport()
        paperView.finishZoom()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !isTornDown else { return }
        acquireToolPicker()
        refreshUndoManager()
        applyPaletteGate(force: true)
        updatePaperViewport()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        _ = captureBarrier()
        onInteractionInterrupted?()
        resetActiveTool()
        if ownsToolPicker { toolPicker?.setVisible(false, forFirstResponder: canvas) }
        canvas.resignFirstResponder()
        paletteKeepsAccess = false
    }

    private var ownsToolPicker: Bool {
        observesToolPicker && (scenePickerOwner?.belongs(to: self) ?? true)
    }

    private func acquireToolPicker() {
        guard allowsEditing, inputGate.keepsPalette, !isTornDown, !observesToolPicker, let scene = view.window?.windowScene else { return }
        if let injectedToolPicker {
            toolPicker = injectedToolPicker
            injectedToolPicker.showsDrawingPolicyControls = false
            injectedToolPicker.addObserver(canvas)
            injectedToolPicker.addObserver(self)
        } else {
            let owner = NotebookSceneToolPicker.owner(for: scene)
            scenePickerOwner = owner
            toolPicker = owner.picker
            owner.attach(self)
        }
        observesToolPicker = true
    }

    func setEditingEnabled(_ enabled: Bool) {
        setInputGate(enabled ? .open : .readOnly)
    }

    func setInputGate(_ gate: NotebookInputGate) {
        let gate = allowsEditing && !isTornDown ? gate : .readOnly
        guard gate != inputGate else { return }
        inputGate = gate
        if gate == .open { capacityHistoryActionReserved = false }
        guard isViewLoaded else { return }
        canvas.permitsMutation = gate.allowsMutation
        canvas.permitsHistoryAccess = gate.keepsPalette
        if gate == .open { acquireToolPicker() }
        refreshUndoManager()
        publishUndoAvailability()
        applyPaletteGate()
    }

    func setPaletteSuppressed(_ suppressed: Bool) {
        guard paletteSuppressed != suppressed else { return }
        paletteSuppressed = suppressed
        publishUndoAvailability()
        applyPaletteGate()
    }

    private func applyPaletteGate(force: Bool = false) {
        let visible = allowsEditing && inputGate.keepsPalette && !paletteSuppressed
            && view.window != nil && ownsToolPicker && !isTornDown
        guard !canvas.hasActiveTool, force || paletteKeepsAccess != visible else { return }
        paletteKeepsAccess = visible
        toolPicker?.setVisible(visible, forFirstResponder: canvas)
        if visible {
            canvas.becomeFirstResponder()
        } else {
            canvas.resignFirstResponder()
        }
        updateInsets()
    }

    private func refreshUndoManager() {
        guard let manager = canvas.nativeUndoManager, manager !== retainedUndoManager else { return }
        for observer in undoObservers { NotificationCenter.default.removeObserver(observer) }
        undoObservers.removeAll()
        retainedUndoManager = manager
        for name in [
            Notification.Name.NSUndoManagerDidUndoChange,
            Notification.Name.NSUndoManagerDidRedoChange,
            Notification.Name.NSUndoManagerDidCloseUndoGroup
        ] {
            undoObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: manager, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.publishUndoAvailability() }
            })
        }
        publishUndoAvailability()
    }

    private func publishUndoAvailability() {
        guard !isPublishingUndoAvailability else { return }
        isPublishingUndoAvailability = true
        defer { isPublishingUndoAvailability = false }
        onUndoAvailabilityChange?(currentUndoAvailability)
    }

    func performUndo() { performHistoryAction(isRedo: false) }
    func performRedo() { performHistoryAction(isRedo: true) }

    private func performHistoryAction(isRedo: Bool) {
        refreshUndoManager()
        let availability = currentUndoAvailability
        guard isRedo ? availability.canRedo : availability.canUndo,
              canPerformHistoryAction?() ?? true,
              reserveHistoryAction?() ?? true,
              let manager = retainedUndoManager else { return }
        let current = currentUndoAvailability
        guard isRedo ? current.canRedo : current.canUndo else { return }
        if inputGate == .capacity { capacityHistoryActionReserved = true }
        publishUndoAvailability()
        if isRedo { manager.redo() } else { manager.undo() }
        _ = captureBarrier()
        publishUndoAvailability()
    }

    private func resetActiveTool() {
        toolBeginSignature = nil
        toolBeginGeneration = nil
        canvas.hasActiveTool = false
        publishUndoAvailability()
    }

    private func observeDrawing(signature: InkDrawingSignature? = nil) {
        let drawing = canvas.drawing
        let capturedAt = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let capturedSignature: InkDrawingSignature?
        if let signature {
            capturedSignature = signature
        } else {
            capturedSignature = try? InkDrawingSignature(drawing)
            if let capturedSignature { observationWork.add(capturedSignature.constructionWork) }
        }
        let observation = NotebookCanvasObservation(
            generation: observedGeneration + 1, drawing: drawing,
            capturedAt: capturedAt, uptime: uptime, signature: capturedSignature
        )
        observedGeneration = observation.generation
        lastObservation = observation
        lastDeliveredSignature = capturedSignature
        if let onObservation {
            setInputGate(onObservation(observation))
        } else if let onCompletedEdit {
            setInputGate(onCompletedEdit(observation.drawing))
        }
        refreshUndoManager()
        publishUndoAvailability()
    }

    func captureBarrier() -> NotebookCanvasObservation? {
        let signature = try? InkDrawingSignature(canvas.drawing)
        if let signature { observationWork.add(signature.constructionWork) }
        if let signature, let previous = lastDeliveredSignature {
            let comparison = signature.compared(to: previous)
            observationWork.add(comparison.work)
            if comparison.isEqual { return lastObservation }
        }
        observeDrawing(signature: signature)
        return lastObservation
    }

    func setPageCount(_ requestedCount: Int) {
        let boundedCount = min(max(requestedCount, 1), Self.maximumPageCount)
        // Reducing the paper extent could hide existing ink.
        guard boundedCount > pageCount else { return }
        pageCount = boundedCount
        guard isViewLoaded else { return }
        let offset = canvas.contentOffset
        updatePaperGeometry()
        isAdjustingLayout = true
        updateContentExtent()
        canvas.setContentOffset(offset, animated: false)
        isAdjustingLayout = false
        updatePaperViewport()
    }

    func tearDown() {
        guard !isTornDown else { return }
        _ = captureBarrier()
        isTornDown = true
        onUndoAvailabilityChange = nil
        for observer in undoObservers { NotificationCenter.default.removeObserver(observer) }
        undoObservers.removeAll()
        retainedUndoManager?.removeAllActions()
        retainedUndoManager = nil
        onDetach?()
        onDetach = nil
        inputGate = .readOnly
        canvas.permitsMutation = false
        canvas.permitsHistoryAccess = false
        resetActiveTool()
        if let scenePickerOwner {
            scenePickerOwner.detach(self)
        } else if observesToolPicker {
            toolPicker?.setVisible(false, forFirstResponder: canvas)
            toolPicker?.removeObserver(canvas)
            toolPicker?.removeObserver(self)
        }
        observesToolPicker = false
        paletteKeepsAccess = false
        canvas.resignFirstResponder()
        canvas.delegate = nil
        canvas.onUndo = nil
        canvas.onRedo = nil
        canvas.historyAvailability = nil
        onCompletedEdit = nil
        onObservation = nil
        onToolCompletion = nil
        onInteractionInterrupted = nil
        canPerformHistoryAction = nil
        reserveHistoryAction = nil
    }

    private func updateContentExtent() {
        let scale = max(canvas.zoomScale, 0.001)
        let expectedSize = CGSize(width: logicalWidth * scale, height: logicalHeight * scale)
        if abs(canvas.contentSize.width - expectedSize.width) > 0.5
            || abs(canvas.contentSize.height - expectedSize.height) > 0.5 {
            canvas.contentSize = expectedSize
        }
    }

    private func updatePaperGeometry() {
        let boundaries = geometry.boundaryPositions(pageCount: pageCount)
            .map { CGFloat($0) }
            .filter { $0 > 0 && $0 < logicalHeight }
        paperView.setGeometry(width: logicalWidth, height: logicalHeight, boundaries: boundaries)
    }

    private func updatePaperViewport() {
        paperView.setViewport(scale: canvas.zoomScale, offset: canvas.contentOffset)
    }

    private func updateInsets() {
        guard isViewLoaded, canvas.bounds.width > 0 else { return }
        let horizontalInset = max((canvas.bounds.width - logicalWidth * canvas.zoomScale) / 2, 0)
        let obscuredFrame = ownsToolPicker && paletteKeepsAccess
            ? toolPicker?.frameObscured(in: view) ?? .null : .null
        let intersection = view.bounds.intersection(obscuredFrame)
        let coversBottom = !intersection.isNull && !intersection.isEmpty
            && intersection.maxY >= view.bounds.maxY - 1
        let bottomInset = coversBottom ? max(view.bounds.maxY - intersection.minY, 0) : 0
        let insets = UIEdgeInsets(top: 0, left: horizontalInset, bottom: bottomInset, right: horizontalInset)
        if canvas.contentInset != insets {
            canvas.contentInset = insets
        }
        canvas.verticalScrollIndicatorInsets = UIEdgeInsets(
            top: 0, left: 0, bottom: bottomInset, right: 0
        )
    }

    private func clampedOffset(_ proposed: CGPoint) -> CGPoint {
        let insets = canvas.contentInset
        let minimumX = -insets.left
        let minimumY = -insets.top
        let maximumX = max(minimumX, canvas.contentSize.width - canvas.bounds.width + insets.right)
        let maximumY = max(minimumY, canvas.contentSize.height - canvas.bounds.height + insets.bottom)
        return CGPoint(
            x: min(max(proposed.x, minimumX), maximumX),
            y: min(max(proposed.y, minimumY), maximumY)
        )
    }
}

extension NotebookViewController: PKCanvasViewDelegate {
    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        guard !isTornDown else { return }
        toolBeginGeneration = observedGeneration
        toolBeginSignature = try? InkDrawingSignature(canvas.drawing)
        if let toolBeginSignature { observationWork.add(toolBeginSignature.constructionWork) }
        canvas.hasActiveTool = true
        publishUndoAvailability()
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        observeDrawing()
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        guard !isTornDown else { return }
        let observation = captureBarrier()
        let begin = toolBeginSignature
        let beginGeneration = toolBeginGeneration
        toolBeginSignature = nil
        toolBeginGeneration = nil
        canvas.hasActiveTool = false
        publishUndoAvailability()
        if let begin, let end = lastDeliveredSignature, let beginGeneration,
           begin.constructionWork.nativeDrawingFallbackSnapshots == 0,
           begin.constructionWork.uncacheableStrokeSignatures == 0,
           end.constructionWork.nativeDrawingFallbackSnapshots == 0,
           end.constructionWork.uncacheableStrokeSignatures == 0,
           observedGeneration > beginGeneration, let observation {
            let comparison = begin.compared(to: end)
            observationWork.add(comparison.work)
            if !comparison.isEqual {
                onToolCompletion?(NotebookToolCompletion(
                    generation: observedGeneration, pageCount: pageCount,
                    nearPaperEnd: NotebookPaperMetrics.isNearPaperEnd(canvas.drawing, pageCount: pageCount),
                    capturedAt: observation.capturedAt, uptime: observation.uptime
                ))
            }
        }
        applyPaletteGate()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        paperView.finishZoom()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isAdjustingLayout else { return }
        updatePaperViewport()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard !isAdjustingLayout else { return }
        isAdjustingLayout = true
        updateContentExtent()
        updateInsets()
        isAdjustingLayout = false
        updatePaperViewport()
    }
}

extension NotebookViewController: PKToolPickerObserver {
    func toolPickerVisibilityDidChange(_ toolPicker: PKToolPicker) {
        updateInsets()
        updatePaperViewport()
    }

    func toolPickerFramesObscuredDidChange(_ toolPicker: PKToolPicker) {
        updateInsets()
        updatePaperViewport()
    }
}

@MainActor
private final class NotebookCanvasView: PKCanvasView {
    // Keep the native tool's requested mode across temporary input pauses.
    private var requestedDrawingEnabled = true
    var hasActiveTool = false {
        didSet { applyDrawingAdmission() }
    }
    var permitsMutation = true {
        didSet {
            guard oldValue != permitsMutation else { return }
            applyDrawingAdmission()
        }
    }

    override var isDrawingEnabled: Bool {
        get { super.isDrawingEnabled }
        set {
            requestedDrawingEnabled = newValue
            applyDrawingAdmission()
        }
    }

    private func applyDrawingAdmission() {
        let enabled = (permitsMutation || hasActiveTool) && requestedDrawingEnabled
        super.isDrawingEnabled = enabled
        drawingGestureRecognizer.isEnabled = enabled
    }

    override func paste(_ sender: Any?) {
        guard permitsMutation else { return }
        super.paste(sender)
    }

    override func cut(_ sender: Any?) {
        guard permitsMutation else { return }
        super.cut(sender)
    }

    override func delete(_ sender: Any?) {
        guard permitsMutation else { return }
        super.delete(sender)
    }

    override func paste(itemProviders: [NSItemProvider]) {
        guard permitsMutation else { return }
        super.paste(itemProviders: itemProviders)
    }

    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
        permitsMutation && super.canPaste(itemProviders)
    }

    var permitsHistoryAccess = true
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var historyAvailability: (() -> NotebookUndoAvailability)?
    var nativeUndoManager: UndoManager? { super.undoManager }

    override var undoManager: UndoManager? {
        permitsHistoryAccess ? super.undoManager : nil
    }

    @objc func undo(_ sender: Any?) { onUndo?() }
    @objc func redo(_ sender: Any?) { onRedo?() }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == NSSelectorFromString("undo:") { return historyAvailability?().canUndo ?? false }
        if action == NSSelectorFromString("redo:") { return historyAvailability?().canRedo ?? false }
        if !permitsMutation && Self.mutationActions.contains(action) { return false }
        return super.canPerformAction(action, withSender: sender)
    }

    override func target(forAction action: Selector, withSender sender: Any?) -> Any? {
        if action == NSSelectorFromString("undo:") || action == NSSelectorFromString("redo:") {
            return canPerformAction(action, withSender: sender) ? self : nil
        }
        if !permitsMutation && Self.mutationActions.contains(action) { return nil }
        return super.target(forAction: action, withSender: sender)
    }

    private static let mutationActions: Set<Selector> = Set([
        "cut:", "paste:", "delete:", "undo:", "redo:", "duplicate:"
    ].map(NSSelectorFromString))
}
