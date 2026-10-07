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
    var keepsToolbar: Bool { self == .open || self == .capacity }
}

@MainActor
final class NotebookViewController: UIViewController {
    static let maximumPageCount = 12

    private let geometry = NotebookPaperMetrics.geometry
    private let logicalWidth = CGFloat(NotebookPaperMetrics.pageWidth)
    private let canvas = NotebookCanvasView()
    let paperView: NotebookPaperView
    private let injectedToolStore: NotebookSceneToolStore?
    private let allowsEditing: Bool
    private var toolStore: NotebookSceneToolStore?
    private var pencilInteraction: UIPencilInteraction?
    /// A tool chosen while a stroke is in progress, applied once the stroke ends.
    private var pendingTool: EditorToolState?
    private var undoObservers: [NSObjectProtocol] = []
    private var retainedUndoManager: UndoManager?
    private var capacityHistoryActionReserved = false
    private var paletteSuppressed = false
    private var isTornDown = false
    private var isAppearing = false
    private(set) var isCanvasVisible = false
    private var isPublishingUndoAvailability = false
    private var toolBeginSignature: InkDrawingSignature?
    private var toolBeginGeneration: UInt64?

    var onObservation: ((NotebookCanvasObservation) -> NotebookInputGate)?
    var onCompletedEdit: ((PKDrawing) -> NotebookInputGate)?
    var onDetach: (() -> Void)?
    var canvasView: PKCanvasView { canvas }
    var drawingToolStore: NotebookSceneToolStore? { toolStore }
    var onUndoAvailabilityChange: ((NotebookUndoAvailability) -> Void)?
    var onToolCompletion: ((NotebookToolCompletion) -> Void)?
    var onInteractionInterrupted: (() -> Void)?
    /// Hears the user's own scrolling and tool use, which hide and reveal the header and tools.
    weak var writingChrome: NotebookWritingChrome?
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
    private(set) var inputGate = NotebookInputGate.open {
        didSet { updateEndOfPaperTab() }
    }
    private var pageCount: Int
    private var previousViewportSize = CGSize.zero
    private var isAdjustingLayout = false
    private var observesToolStore = false
    private var toolbarKeepsAccess = false
    private var chrome = NotebookCanvasChrome.none
    /// The store whose toolbar the host draws over this canvas.
    private weak var overlayStore: NotebookSceneToolStore?
    private var resizeCapture: ResizeCapture?
    /// Paper behind the status bar, between the canvas and the chrome drawn over it.
    private(set) lazy var statusVeil = NotebookStatusVeil(accessibility: paperView.accessibility)
    /// The "Add page" tab on the stone below the last page.
    let endOfPaperTab = NotebookEndOfPaperTab()
    /// Adds a page at the end of the notebook. Only a canvas given this shows the end-of-paper
    /// tab and keeps room below the last page for it.
    var onAddPage: (() -> Void)? {
        didSet {
            guard isViewLoaded else { return }
            updateInsets()
            updateEndOfPaperTab()
        }
    }

    /// Whether the page rested at its revealed top when a resize began. It is taken at the first
    /// sign of the resize, before any of its changes apply, and every layout and inset change of
    /// that resize reads it: an inset change or layout clamp within the resize can move a page
    /// that was merely near its top onto it.
    private struct ResizeCapture {
        /// The size the canvas was laid out at when the resize began.
        let from: CGSize
        let restedAtRevealedTop: Bool
        /// False while the only sign is a toolbar re-measured for a new control area, which a
        /// header change at the same canvas size causes as well.
        var isConfirmed: Bool
    }

    private var logicalHeight: CGFloat {
        CGFloat(geometry.pageHeight) * CGFloat(pageCount)
    }

    init(
        pageCount: Int, initialDrawing: PKDrawing, toolStore: NotebookSceneToolStore? = nil,
        allowsEditing: Bool = true, paperView: NotebookPaperView? = nil
    ) {
        self.injectedToolStore = toolStore
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
        view.backgroundColor = NotebookTheme.backdropStone.uiColor
        view.clipsToBounds = true
        // The paper is always light; PencilKit would otherwise adapt ink colours for dark mode.
        overrideUserInterfaceStyle = .light

        canvas.drawing = initialDrawing
        canvas.delegate = self
        canvas.permitsMutation = inputGate.allowsMutation
        canvas.permitsHistoryAccess = inputGate.keepsToolbar
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
        // The status veil stands in for the system's edge effects, which would tint the paper.
        canvas.topEdgeEffect.isHidden = true
        canvas.bottomEdgeEffect.isHidden = true

        // Without Apple's tool picker, Pencil tap and squeeze reach the app only through its own interaction.
        if allowsEditing, !isTornDown {
            let interaction = UIPencilInteraction(delegate: self)
            canvas.addInteraction(interaction)
            pencilInteraction = interaction
        }

        view.addSubview(paperView)
        view.addSubview(canvas)
        endOfPaperTab.addTarget(self, action: #selector(addPage), for: .touchUpInside)
        view.addSubview(endOfPaperTab)
        view.addSubview(statusVeil)
        registerForTraitChanges(
            [UITraitPreferredContentSizeCategory.self]
        ) { (controller: NotebookViewController, _: UITraitCollection) in
            controller.updateEndOfPaperTab()
        }
        updatePaperGeometry()
        updateContentExtent()
        refreshUndoManager()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if isAppearing || isCanvasVisible {
            acquireToolStore()
            applyToolbarGate()
        }
        let newSize = view.bounds.size
        guard newSize.width > 0, newSize.height > 0 else { return }

        guard newSize != previousViewportSize else {
            updateInsets()
            updatePaperViewport()
            return
        }

        let hadViewport = previousViewportSize.width > 0
        // A resize the toolbar or chrome measurement announced was captured before it changed
        // the insets; otherwise this layout is its first sign.
        var capture = resizeCapture.flatMap { $0.from == previousViewportSize ? $0 : nil }
            ?? ResizeCapture(
                from: previousViewportSize, restedAtRevealedTop: hadViewport && isAtTopOfPaper, isConfirmed: true
            )
        capture.isConfirmed = true
        let restsAtTop = hadViewport && capture.restedAtRevealedTop
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
            // Preserve the leading scroll edge across a resize; elsewhere keep the page centre.
            proposedOffset = CGPoint(
                x: logicalCenter.x * scale - newSize.width / 2,
                y: restsAtTop ? -canvas.contentInset.top : logicalCenter.y * scale - newSize.height / 2
            )
        } else {
            proposedOffset = CGPoint(x: -canvas.contentInset.left, y: 0)
        }
        canvas.setContentOffset(clampedOffset(proposedOffset), animated: false)
        previousViewportSize = newSize
        resizeCapture = hadViewport ? capture : nil
        isAdjustingLayout = false
        finishResizeIfSettled()
        updatePaperViewport()
        paperView.finishZoom()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !isTornDown else { return }
        isAppearing = true
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        guard !isTornDown else { return }
        acquireToolStore()
        applyToolbarGate(force: true)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !isTornDown else { return }
        isAppearing = false
        isCanvasVisible = true
        acquireToolStore()
        applyToolbarGate(force: true)
        updatePaperViewport()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isAppearing = false
        isCanvasVisible = false
        _ = captureBarrier()
        onInteractionInterrupted?()
        resetActiveTool()
        if ownsToolStore { toolStore?.setToolbarAvailable(false, for: self) }
        canvas.resignFirstResponder()
        refreshUndoManager()
        toolbarKeepsAccess = false
    }

    private var ownsToolStore: Bool {
        observesToolStore && (toolStore?.belongs(to: self) ?? false)
    }

    private func acquireToolStore() {
        guard allowsEditing, inputGate.keepsToolbar, !paletteSuppressed, !isTornDown,
              isAppearing || isCanvasVisible, !observesToolStore,
              let scene = view.window?.windowScene else { return }
        let store = injectedToolStore ?? NotebookSceneToolStore.owner(for: scene)
        toolStore = store
        store.attach(self)
        observesToolStore = true
        store.setToolActive(canvas.hasActiveTool, for: self)
        applyTool(store.tool)
        updateInsets()
    }

    /// Applies an app toolbar selection to the native canvas. Drawing admission is
    /// untouched: a tool choice can never reopen a paused canvas.
    func applyTool(_ state: EditorToolState) {
        guard !isTornDown, ownsToolStore else { return }
        guard !canvas.hasActiveTool else {
            pendingTool = state
            return
        }
        pendingTool = nil
        canvas.tool = state.nativeTool
        canvas.isRulerActive = state.isRulerActive
    }

    /// Performs the user's Apple Pencil tap or squeeze setting. Only the owning controller
    /// forwards it, and only while its own gate keeps the toolbar; the store additionally
    /// requires toolbar availability, so failed, recovering, suppressed and read-only
    /// canvases ignore gestures.
    func handlePencilPreference(_ preference: EditorPencilTapPreference) {
        guard !isTornDown, allowsEditing, inputGate.keepsToolbar, !paletteSuppressed,
              ownsToolStore, let toolStore else { return }
        toolStore.handlePencil(preference, from: self)
    }

    func setEditingEnabled(_ enabled: Bool) {
        setInputGate(enabled ? .open : .readOnly)
    }

    func setInputGate(_ gate: NotebookInputGate) {
        let gate = allowsEditing && !isTornDown ? gate : .readOnly
        guard gate != inputGate else {
            if isViewLoaded { applyToolbarGate() }
            return
        }
        inputGate = gate
        if gate == .open { capacityHistoryActionReserved = false }
        guard isViewLoaded else { return }
        canvas.permitsMutation = gate.allowsMutation
        canvas.permitsHistoryAccess = gate.keepsToolbar
        if gate == .open { acquireToolStore() }
        applyToolbarGate()
        refreshUndoManager()
        publishUndoAvailability()
    }

    func setPaletteSuppressed(_ suppressed: Bool) {
        guard paletteSuppressed != suppressed else {
            if isViewLoaded { applyToolbarGate() }
            return
        }
        paletteSuppressed = suppressed
        if !suppressed { acquireToolStore() }
        applyToolbarGate()
        publishUndoAvailability()
    }

    private func applyToolbarGate(force: Bool = false) {
        let visible = allowsEditing && inputGate.keepsToolbar && !paletteSuppressed
            && (isAppearing || isCanvasVisible) && view.window != nil && ownsToolStore && !isTornDown
        let responderMismatch = canvas.isFirstResponder != visible
        let availabilityMismatch = ownsToolStore && toolStore?.isToolbarAvailable != visible
        // Tool choices stop as soon as the gate closes; resigning or restoring access waits for the stroke to end.
        if !visible, ownsToolStore { toolStore?.setToolbarAvailable(false, for: self) }
        guard !canvas.hasActiveTool,
              force || toolbarKeepsAccess != visible || responderMismatch || availabilityMismatch else { return }
        toolbarKeepsAccess = visible
        if ownsToolStore { toolStore?.setToolbarAvailable(visible, for: self) }
        if visible {
            canvas.becomeFirstResponder()
        } else {
            canvas.resignFirstResponder()
        }
        refreshUndoManager()
        updateInsets()
    }

    private func refreshUndoManager() {
        guard !isTornDown else { return }
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
        setToolActive(false)
        if let pendingTool { applyTool(pendingTool) }
        releaseHeldInsets()
        publishUndoAvailability()
    }

    /// The store is scene-wide, so only its owner's tool use is mirrored there.
    private func setToolActive(_ active: Bool) {
        canvas.hasActiveTool = active
        if ownsToolStore { toolStore?.setToolActive(active, for: self) }
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
        isAppearing = false
        isCanvasVisible = false
        onUndoAvailabilityChange = nil
        for observer in undoObservers { NotificationCenter.default.removeObserver(observer) }
        undoObservers.removeAll()
        let manager = retainedUndoManager ?? canvas.nativeUndoManager
        manager?.removeAllActions()
        onInteractionInterrupted?()
        // A stroke cut short by teardown never reports its end, so the writing view is told it was
        // cancelled. Telling it twice, as the interruption callback may, changes nothing.
        writingChrome?.toolCancelled()
        writingChrome = nil
        inputGate = .readOnly
        canvas.permitsMutation = false
        canvas.permitsHistoryAccess = false
        resetActiveTool()
        manager?.removeAllActions()
        if let currentManager = canvas.nativeUndoManager, currentManager !== manager {
            currentManager.removeAllActions()
        }
        retainedUndoManager = nil
        onDetach?()
        onDetach = nil
        toolStore?.detach(self)
        observesToolStore = false
        overlayStore?.uncover(self)
        overlayStore = nil
        if let pencilInteraction {
            pencilInteraction.delegate = nil
            canvas.removeInteraction(pencilInteraction)
        }
        pencilInteraction = nil
        pendingTool = nil
        toolbarKeepsAccess = false
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
        statusVeil.update(
            width: view.bounds.width, safeTop: view.safeAreaInsets.top,
            isOverPaper: canvas.zoomScale >= view.bounds.width / logicalWidth * 0.999
        )
        updateEndOfPaperTab()
    }

    private var showsEndOfPaperTab: Bool { allowsEditing && onAddPage != nil }

    /// Places the end-of-paper tab centred on the page, its top `endTabGap` below the last page
    /// on screen. It only moves as the paper scrolls; its content changes with the gate, the
    /// page limit and the text size.
    private func updateEndOfPaperTab() {
        guard isViewLoaded else { return }
        let tab = endOfPaperTab
        guard showsEndOfPaperTab else {
            if !tab.isHidden { tab.isHidden = true }
            return
        }
        let mode: NotebookEndOfPaperTab.Mode = pageCount >= Self.maximumPageCount
            ? .limitReached : inputGate.allowsMutation ? .available : .paused
        // The tab keeps the same margin from the window's sides as from the page above it.
        tab.configure(
            mode: mode, contentSize: traitCollection.preferredContentSizeCategory,
            maximumWidth: view.bounds.width - 2 * NotebookTheme.endTabGap
        )
        let scale = canvas.zoomScale
        let size = tab.bounds.size
        let pageBottom = logicalHeight * scale - canvas.contentOffset.y
        let pixel = 1 / max(traitCollection.displayScale, 1)
        // Whole device pixels keep the label sharp at any zoom.
        let origin = CGPoint(
            x: ((logicalWidth * scale - size.width) / 2 - canvas.contentOffset.x) / pixel,
            y: (pageBottom + NotebookTheme.endTabGap) / pixel
        )
        let frame = CGRect(
            origin: CGPoint(x: origin.x.rounded() * pixel, y: origin.y.rounded() * pixel), size: size
        )
        let hidden = frame.minY >= view.bounds.height || frame.maxY <= 0
        UIView.performWithoutAnimation {
            if tab.frame != frame { tab.frame = frame }
            if tab.isHidden != hidden { tab.isHidden = hidden }
        }
    }

    @objc private func addPage() {
        guard endOfPaperTab.mode == .available else { return }
        onAddPage?()
    }

    /// Reserves the canvas edges the toolbar covers as scroll space, on top of the chrome.
    /// - Parameter followingResize: true when the toolbar was re-measured for a new control area
    ///   rather than moved. That re-measure arrives before the canvas is laid out at its new size,
    ///   and a header change at the same canvas size causes it too, so it only opens a resize
    ///   for the layout or chrome measurement that follows to confirm.
    func applyOverlayObstruction(followingResize: Bool) {
        guard !isTornDown else { return }
        if !followingResize {
            resizeCapture = nil
        } else if resizeCapture == nil, previousViewportSize.width > 0 {
            resizeCapture = ResizeCapture(
                from: previousViewportSize, restedAtRevealedTop: isAtTopOfPaper, isConfirmed: false
            )
        }
        updateInsets(followingResize: followingResize)
    }

    /// Reserves the toolbar the host draws over this canvas whether or not the canvas owns the
    /// tools, as a paused canvas can neither move nor collapse it.
    func placeUnderToolbar(of store: NotebookSceneToolStore?) {
        guard !isTornDown, store !== overlayStore else { return }
        overlayStore?.uncover(self)
        overlayStore = store
        store?.cover(self)
        updateInsets()
    }

    /// The owner reserves the toolbar it takes its tools from, and a canvas shown under the
    /// toolbar reserves it without owning the tools.
    private var toolbarObstruction: UIEdgeInsets {
        if ownsToolStore, let toolStore { return toolStore.overlayObstruction }
        if let overlayStore, overlayStore.covers(self) { return overlayStore.overlayObstruction }
        return .zero
    }

    /// Reserves the canvas edges the status bar, navigation header and home indicator cover as
    /// scroll space. Every canvas applies them, whatever its gate or toolbar ownership.
    func applyChrome(_ chrome: NotebookCanvasChrome) {
        guard !isTornDown, chrome != self.chrome else { return }
        let previous = self.chrome.canvasSize
        self.chrome = chrome
        let resized = previous != .zero && chrome.canvasSize != .zero && !Self.matches(previous, chrome.canvasSize)
        if !resized {
            // The header or home indicator changed, or was measured for the first time.
            resizeCapture = nil
        } else if var capture = resizeCapture, Self.matches(capture.from, previous) {
            capture.isConfirmed = true
            resizeCapture = capture
        } else if Self.matches(previousViewportSize, previous) {
            // Measured before the canvas is laid out at its new size, so nothing has moved yet.
            resizeCapture = ResizeCapture(
                from: previousViewportSize, restedAtRevealedTop: isAtTopOfPaper, isConfirmed: true
            )
        } else {
            // Laid out at the new size already, and the resize has ended since, as when the toolbar moved.
            resizeCapture = nil
        }
        updateInsets(followingResize: resized)
        finishResizeIfSettled()
    }

    /// Ends a resize once the canvas is laid out at its new size and the chrome, when the host
    /// measures it, has caught up.
    private func finishResizeIfSettled() {
        guard let capture = resizeCapture, capture.isConfirmed, previousViewportSize != capture.from,
              chrome.canvasSize == .zero || Self.matches(chrome.canvasSize, previousViewportSize) else { return }
        resizeCapture = nil
    }

    /// The host's measured size and the size UIKit lays the canvas out at may differ by pixel rounding.
    private static func matches(_ size: CGSize, _ other: CGSize) -> Bool {
        abs(size.width - other.width) < 0.5 && abs(size.height - other.height) < 0.5
    }

    /// Applies insets held back while a stroke was in progress.
    private func releaseHeldInsets() {
        guard !isTornDown else { return }
        updateInsets()
    }

    /// Edge insets add scroll range to reveal covered writing. Reserving range never moves the
    /// page; releasing it only pulls a page scrolled past the new end back to that end, and
    /// waits until a stroke in progress ends. The one exception is a confirmed resize: a page
    /// that rested at its revealed top when the resize began stays there instead of ending up
    /// under the header or toolbar. Horizontally the page stays centred.
    private func updateInsets(followingResize: Bool = false) {
        guard isViewLoaded, canvas.bounds.width > 0 else { return }
        let obstruction = toolbarObstruction
        var top = max(chrome.top, 0) + max(obstruction.top, 0)
        // The end-of-paper tab needs room below the last page, clear of the home indicator.
        let chromeBottom = showsEndOfPaperTab
            ? max(chrome.bottom, view.safeAreaInsets.bottom, 0) + NotebookTheme.endScrollMinimum
            : max(chrome.bottom, 0)
        var bottom = chromeBottom + max(obstruction.bottom, 0)
        if canvas.hasActiveTool {
            // A smaller inset pulls an offset beyond it back into range, which would move the
            // page under the stroke; the space is released when the stroke ends.
            top = max(top, canvas.contentInset.top)
            bottom = max(bottom, canvas.contentInset.bottom)
        }
        let horizontalInset = max((canvas.bounds.width - logicalWidth * canvas.zoomScale) / 2, 0)
        let insets = UIEdgeInsets(top: top, left: horizontalInset, bottom: bottom, right: horizontalInset)
        if canvas.contentInset != insets {
            canvas.contentInset = insets
        }
        let indicatorInsets = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        if canvas.verticalScrollIndicatorInsets != indicatorInsets {
            canvas.verticalScrollIndicatorInsets = indicatorInsets
        }
        if followingResize, let resizeCapture, resizeCapture.isConfirmed, resizeCapture.restedAtRevealedTop,
           !canvas.hasActiveTool, !isAtTopOfPaper {
            canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: -top), animated: false)
        }
    }

    /// True while the top of the first page sits at the top of the scrollable range.
    private var isAtTopOfPaper: Bool {
        abs(canvas.contentOffset.y + canvas.contentInset.top) < 0.5
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
        setToolActive(true)
        writingChrome?.toolBegan()
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
        setToolActive(false)
        writingChrome?.toolEnded()
        if let pendingTool { applyTool(pendingTool) }
        releaseHeldInsets()
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
        applyToolbarGate()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        paperView.finishZoom()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isAdjustingLayout else { return }
        updatePaperViewport()
        writingChrome?.userScrollMoved(in: scrollView)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // The user moving the page ends any claim that it rested at its top when a resize began.
        resizeCapture = nil
        writingChrome?.userScrollBegan(in: scrollView)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { writingChrome?.userScrollEnded() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        writingChrome?.userScrollEnded()
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        writingChrome?.scrolledToTop()
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

extension NotebookViewController: UIPencilInteractionDelegate {
    /// The user's system setting for a double tap.
    static func tapPreference() -> EditorPencilTapPreference {
        EditorPencilTapPreference(UIPencilInteraction.preferredTapAction)
    }

    /// The user's system setting for a squeeze, or nil before it ends: a held squeeze can
    /// report began and changed phases first, and acting on each would undo itself.
    static func squeezePreference(for phase: UIPencilInteraction.Phase) -> EditorPencilTapPreference? {
        guard phase == .ended else { return nil }
        return EditorPencilTapPreference(UIPencilInteraction.preferredSqueezeAction)
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        handlePencilPreference(Self.tapPreference())
    }

    func pencilInteraction(
        _ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
    ) {
        guard let preference = Self.squeezePreference(for: squeeze.phase) else { return }
        handlePencilPreference(preference)
    }
}

extension EditorPencilTapPreference {
    init(_ action: UIPencilPreferredAction) {
        switch action {
        case .ignore: self = .ignore
        case .switchEraser: self = .switchEraser
        case .switchPrevious: self = .switchPrevious
        case .showColorPalette: self = .showColorPalette
        case .showInkAttributes: self = .showInkAttributes
        case .showContextualPalette: self = .showContextualPalette
        case .runSystemShortcut: self = .runSystemShortcut
        @unknown default: self = .ignore
        }
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
