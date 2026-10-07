import NottyCore
import PencilKit
import UIKit
import UIKit.UIGestureRecognizerSubclass

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
    /// True while the canvas takes a replaced paper's drawing, whose own change report would carry
    /// the old page count; the replacement reports the drawing itself, with the new one.
    private var isReplacingPaper = false

    var onObservation: ((NotebookCanvasObservation) -> NotebookInputGate)?
    /// Hears the paper replaced whole, by a page deletion or its undo or redo: the new drawing and
    /// page count, to be kept as one edit. Only a canvas given this deletes pages.
    var onPaperReplacement: ((NotebookCanvasObservation, Int) -> NotebookInputGate)?
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
        didSet { updateEndOfNotebookCard() }
    }
    private(set) var pageCount: Int
    private var previousViewportSize = CGSize.zero
    private var isAdjustingLayout = false
    private var observesToolStore = false
    private var toolbarKeepsAccess = false
    /// The room for the status bar, header and home indicator the host last measured.
    private(set) var chrome = NotebookCanvasChrome.none
    /// The store whose toolbar the host draws over this canvas.
    private weak var overlayStore: NotebookSceneToolStore?
    private var resizeCapture: ResizeCapture?
    /// Paper behind the status bar, between the canvas and the chrome drawn over it.
    private(set) lazy var statusVeil = NotebookStatusVeil(accessibility: paperView.accessibility)
    /// The card a pull past the last page reveals beneath it.
    let endOfNotebookCard = NotebookEndOfNotebookCard()
    /// The frost that clears down a page added where the user can see it; nil for a viewer, which
    /// never adds pages.
    let pageUnfold: NotebookPageUnfold?
    /// Hears the last finger leave the page, which ends a scroll the user stopped with a tap.
    let fingerLiftObserver = NotebookFingerLiftObserver()
    /// How long after the canvas appears the card is first built, clear of the work of opening
    /// the notebook; replaceable in tests before the canvas appears.
    var endCardPreparationDelay: TimeInterval = 0.5
    /// Adds a page at the end of the notebook for the card's Add page, as a page the user asked
    /// for. Only a canvas given this offers the end of notebook card.
    var onAddPage: (() -> Void)? {
        didSet {
            guard isViewLoaded else { return }
            updateEndOfNotebookAccess()
        }
    }
    /// Whether the card shows beneath the lifted page, with room kept below the last page for it.
    private(set) var isEndCardRevealed = false
    /// The room kept below the last page for the revealed card. It never shrinks while the card
    /// shows, as that would pull the lifted page back down.
    private var endCardRoom: CGFloat = 0
    /// A drag that began with the page resting at its end, which may pull the card into view.
    private var endPull: EndPull?
    /// A fling bound to overshoot the end of the paper far enough to reveal the card.
    private var endMomentum: EndMomentum?
    /// The scroll that brings a page added at the user's request into view.
    private var arrival: PageArrival?

    /// How far past the end of the paper a pull must be when released, or UIKit's rubber band
    /// would carry a fling, to reveal the card; both feel alike because both are measured as the
    /// same overshoot. Under the rubber band a pull takes roughly 140 points of finger travel on a
    /// 1,366-point canvas, and a fling overshoots this far arriving at the end at a little over
    /// 2,000 points a second, a deliberate fling, while one that merely runs out at the end
    /// bounces back well short.
    static let endRevealPull: CGFloat = 72
    /// How far UIKit's rubber band carries a fling past the end of the paper, in milliseconds of
    /// the speed it arrives at: 31 to 37 measured for arrivals from 1.9 to 7 points a millisecond.
    static let flingOvershootTime: CGFloat = 34
    /// How fast, in points per millisecond, a pull may still be heading back toward the page when
    /// released and reveal the card. A finger held at its depth lifts with a little drift either
    /// way; one already pushing the page back has taken the pull back.
    static let endPullReturnSpeed: CGFloat = 0.1
    /// How close to its end the page must rest for a drag to count as a pull past it, and how
    /// close to the end UIKit must aim a fling for it to head past the end.
    static let endRestTolerance: CGFloat = 1
    static let endCardActionName = "End of notebook options"
    /// The undo and redo menus' name for a page deletion.
    static let deletePageActionName = "Delete Page"
    /// The shortest the scroll on to an added page may take, in seconds, however late it sets off.
    private static let shortestArrival: CFTimeInterval = PageUnfoldTimeline.arrivalDuration / 2_000

    /// A pull past the end of the paper, from the drag that began it until the page settles.
    private struct EndPull {
        /// Prepared as the drag begins, so the tick plays on time when the card is revealed.
        let feedback: UIImpactFeedbackGenerator
        var isReleased = false
    }

    /// A fling let go short of the end of the paper and bound to overshoot it by `endRevealPull`,
    /// from the release until it comes to rest.
    private struct EndMomentum {
        /// Prepared as the drag ends, so the tick plays on time when the card is revealed.
        let feedback: UIImpactFeedbackGenerator
        /// Where the latest frame of the fling left the page.
        var offset: CGFloat
        /// How far the latest frame that moved the page moved it.
        var step: CGFloat = 0
        /// The card was revealed, so a deceleration cut short finishes the lift.
        var hasRevealed = false
    }

    /// The paper a page deletion, its undo or its redo puts on the canvas or replaces.
    private struct PaperState {
        let drawing: PKDrawing
        let pageCount: Int
    }

    /// The scroll that follows a page added at the user's request, from where the paper rested
    /// until the new page's top reaches the top of the visible area.
    private struct PageArrival {
        let link: CADisplayLink
        let from: CGFloat
        let to: CGFloat
        /// When the page comes to rest: as its frost finishes clearing.
        let end: CFTimeInterval
        /// The frame the scroll sets off from: the first the display link is asked for.
        var start: CFTimeInterval?
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

    /// - Parameter pageUnfold: the frost for added pages; an editing canvas makes its own when
    ///   given none, and its shaders compile in the background.
    init(
        pageCount: Int, initialDrawing: PKDrawing, toolStore: NotebookSceneToolStore? = nil,
        allowsEditing: Bool = true, paperView: NotebookPaperView? = nil, pageUnfold: NotebookPageUnfold? = nil
    ) {
        self.injectedToolStore = toolStore
        self.allowsEditing = allowsEditing
        self.paperView = paperView ?? NotebookPaperView(frame: .zero)
        self.pageUnfold = allowsEditing ? pageUnfold ?? NotebookPageUnfold() : nil
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

        fingerLiftObserver.onLift = { [weak self] in self?.fingersLifted() }
        canvas.addGestureRecognizer(fingerLiftObserver)
        view.addSubview(paperView)
        view.addSubview(canvas)
        endOfNotebookCard.onAddPage = { [weak self] in self?.addPageFromEndCard() }
        addChild(endOfNotebookCard.host)
        view.addSubview(endOfNotebookCard)
        endOfNotebookCard.host.didMove(toParent: self)
        view.addSubview(statusVeil)
        registerForTraitChanges(
            [UITraitPreferredContentSizeCategory.self]
        ) { (controller: NotebookViewController, _: UITraitCollection) in
            controller.updateEndOfNotebookCard()
        }
        updatePaperGeometry()
        updateContentExtent()
        updateEndOfNotebookAccess()
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
            releaseEndCardOnceLeftView()
            return
        }

        let hadViewport = previousViewportSize.width > 0
        // A scroll on to an added page aims at the end it had before the resize.
        stopArrival()
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

        adjustingLayout {
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
        }
        finishResizeIfSettled()
        updatePaperViewport()
        releaseEndCardOnceLeftView()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + endCardPreparationDelay) { [weak self] in
            self?.prepareEndCard()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isAppearing = false
        isCanvasVisible = false
        stopArrival()
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
        canvas.hasActiveTool = false
        if let pendingTool { applyTool(pendingTool) }
        endHaltedFling()
        releaseHeldInsets()
        publishUndoAvailability()
    }

    /// - Parameter replacingPaper: true when the paper was replaced whole, so the drawing goes to
    ///   the session with its page count as one edit.
    private func observeDrawing(signature: InkDrawingSignature? = nil, replacingPaper: Bool = false) {
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
        if replacingPaper {
            if let onPaperReplacement { setInputGate(onPaperReplacement(observation, pageCount)) }
        } else if let onObservation {
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

    /// Grows the paper; every way of adding a page ends here. The page stays where it is, a card
    /// shown beneath the old last page gives way to the new one, and a single page added where
    /// the user can see it clears in with the frost.
    ///
    /// - Parameter bringingIntoView: true when the user asked for the page, with Add page on the
    ///   end of notebook card or in the Notebook menu. If its top shows, the paper then scrolls on
    ///   until that top rests at the top of the visible area, below the room kept for the header
    ///   and the toolbar, so the frost is seen clearing down from it. Pages the notebook adds on
    ///   its own, as when writing reaches the foot of the last page, never move the paper.
    func setPageCount(_ requestedCount: Int, bringingIntoView: Bool = false) {
        let boundedCount = min(max(requestedCount, 1), Self.maximumPageCount)
        // Reducing the paper extent could hide existing ink; only a page deletion, which moves
        // the ink with it, shrinks the paper.
        guard boundedCount > pageCount else { return }
        let previousHeight = logicalHeight
        let added = boundedCount - pageCount
        pageCount = boundedCount
        guard isViewLoaded else { return }
        stopArrival()
        endMomentum = nil
        let offset = canvas.contentOffset
        updatePaperGeometry()
        adjustingLayout {
            updateContentExtent()
            canvas.setContentOffset(offset, animated: false)
        }
        // The new page lies where the card was, so giving up the card's room moves nothing, even
        // where the whole notebook still fits on screen and the card would otherwise stay.
        dismissEndCard()
        updatePaperViewport()
        let page = CGRect(x: 0, y: previousHeight, width: logicalWidth, height: logicalHeight - previousHeight)
        guard added == 1, !isTornDown, isAppearing || isCanvasVisible, view.window != nil,
              NotebookPageUnfold.isVisible(page: page, in: canvas) else { return }
        unfold(page)
        if bringingIntoView { bringIntoView(page) }
    }

    /// Plays the frost over `page`, the added page in page points, which the user can see.
    private func unfold(_ page: CGRect) {
        guard let pageUnfold else { return }
        let source = pageUnfold.needsSource
            ? paperView.blankPageImage(page, screenPixelsPerPoint: traitCollection.displayScale * canvas.zoomScale)
            : nil
        // Inside the paper's content, over the grain and under the lines, so the frost scrolls and
        // zooms with the page and the canvas above keeps its ink and its touches.
        pageUnfold.play(page: page, source: source, in: paperView.contentLayer, above: paperView.grainLayer) {}
    }

    // MARK: - Bringing an added page into view

    /// Scrolls on from a glimpse of `page`, just added, until its top rests at the top of the
    /// visible area, as the frost clears down it; on a page taller than that area the clearing
    /// finishes below the screen. A deliberate move the user asked for, never made while a stroke,
    /// a touch, a drag or a pinch is under way, as the page must not move under the pen or the
    /// finger. Under Reduce Motion the paper is set there at once while the page fades in. Only a
    /// read-only canvas lacks the frost, and it never adds a page.
    private func bringIntoView(_ page: CGRect) {
        guard let pageUnfold, arrivalMayContinue else { return }
        let from = canvas.contentOffset.y
        let to = min(endOffsetY, page.minY * canvas.zoomScale - canvas.contentInset.top)
        guard to > from + 0.5 else { return }
        if pageUnfold.prefersReducedMotion {
            adjustingLayout {
                canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: to), animated: false)
            }
            updatePaperViewport()
            prepareEndCardSoon()
            return
        }
        let link = CADisplayLink(target: ArrivalLinkTarget(self), selector: #selector(ArrivalLinkTarget.tick(_:)))
        // The common modes keep it running through tracking, as the frost's own link does.
        link.add(to: .main, forMode: .common)
        // Without Metal, or before its shaders are ready, no frost plays, and the scroll keeps its
        // own time.
        let end = pageUnfold.clearingEnd ?? CACurrentMediaTime() + PageUnfoldTimeline.arrivalDuration / 1_000
        arrival = PageArrival(link: link, from: from, to: to, end: end)
    }

    /// Whether the scroll on to an added page may move the paper now.
    private var arrivalMayContinue: Bool {
        !isTornDown && view.window != nil && !canvas.hasActiveTool && !canvas.isTracking && !canvas.isDragging
            && !canvas.isZooming && !canvas.isZoomBouncing
    }

    fileprivate func advanceArrival(_ link: CADisplayLink) {
        guard let arrival, arrival.link === link else {
            link.invalidate()
            return
        }
        guard arrivalMayContinue else {
            stopArrival()
            return
        }
        // Setting off from the first frame the link is asked for, once the work of adding the page
        // is done, the page eases off from rest instead of jumping by however long that work took.
        // It still lands as the frost clears, unless that leaves too little time for a smooth scroll.
        let start = arrival.start ?? link.targetTimestamp
        self.arrival?.start = start
        let span = max(arrival.end - start, Self.shortestArrival)
        let elapsed = (link.targetTimestamp - start) / span * PageUnfoldTimeline.arrivalDuration
        let progress = PageUnfoldTimeline.arrivalProgress(at: elapsed)
        var y = arrival.from + (arrival.to - arrival.from) * CGFloat(progress)
        let isDone = progress >= 1 || abs(arrival.to - y) < 0.5
        if isDone { y = arrival.to }
        adjustingLayout {
            canvas.setContentOffset(clampedOffset(CGPoint(x: canvas.contentOffset.x, y: y)), animated: false)
        }
        updatePaperViewport()
        guard isDone else { return }
        stopArrival()
        prepareEndCardSoon()
    }

    /// Ends the scroll on to an added page where it is.
    private func stopArrival() {
        arrival?.link.invalidate()
        arrival = nil
    }

    /// Whether the paper is scrolling on to a page added at the user's request.
    var isBringingAddedPageIntoView: Bool { arrival != nil }

    // MARK: - Deleting a page

    /// The page filling the most of the paper the user can see, between the room kept for the
    /// header and toolbar at the top and the room for the home indicator and a bottom toolbar
    /// below; where pages fill it equally, as whole pages do zoomed out, the one at the centre of
    /// the view. The Notebook menu offers this page for deletion.
    var mostVisiblePage: Int {
        let scale = max(canvas.zoomScale, 0.001)
        let top = (canvas.contentOffset.y + canvas.contentInset.top) / scale
        let bottom = (canvas.contentOffset.y + canvas.bounds.height - chromeBottomInset) / scale
        return geometry.mostVisiblePage(top: Double(top), bottom: Double(bottom), pageCount: pageCount)
    }

    /// Whether a page can be deleted now: the notebook is open for writing, no stroke is under
    /// way, and another page would remain.
    var canDeletePage: Bool {
        isViewLoaded && allowsEditing && !isTornDown && inputGate.allowsMutation && !paletteSuppressed
            && !canvas.hasActiveTool && pageCount > 1 && onPaperReplacement != nil
    }

    /// Deletes `page`, counted from zero: its ink goes and the later pages move up to close the
    /// gap, kept as one edit through the session's saves. One undo restores the exact drawing and
    /// page count, and redo deletes the page again; pages added in between stay.
    ///
    /// The canvas's undo stack is cleared before the deletion is registered on it. Its earlier
    /// entries are PencilKit's own stroke actions, recorded against the drawing being replaced,
    /// and the SDK does not say what they do to any other drawing; cleared, none can run against
    /// the paper the deletion leaves, or after its undo. The strokes they covered stay in the
    /// notebook's saved history. The canvas shares the manager along the responder chain, so any
    /// other responder's entries would go as well, as they do on teardown; none registers there
    /// beside the canvas, as the colour picker's fields keep their own.
    @discardableResult
    func deletePage(_ page: Int) -> Bool {
        refreshUndoManager()
        guard canDeletePage, retainedUndoManager != nil,
              let deletion = PaperPageDeletion(page: page, pageCount: pageCount, geometry: geometry) else {
            return false
        }
        // The session keeps the drawing being replaced before it is.
        _ = captureBarrier()
        guard canDeletePage, let manager = retainedUndoManager else { return false }
        let before = PaperState(drawing: canvas.drawing, pageCount: pageCount)
        let after = PaperState(drawing: deletion.apply(to: before.drawing), pageCount: deletion.remainingPageCount)
        replacePaper(with: after)
        manager.removeAllActions()
        registerRestore(of: before, over: after.pageCount, in: manager)
        publishUndoAvailability()
        return true
    }

    /// Registers the step that puts `state` back on paper of `pageCount` pages. Run by an undo, it
    /// registers the redo, and the other way round, from the paper as the step finds it rather
    /// than as it was registered: pages added since may hold ink that the steps above it on the
    /// stack bring back, so the reverse step must keep them.
    ///
    /// Nor does a step take away pages added since it was registered, which are not the
    /// deletion's: it changes the page count only by the page the deletion took or its undo gave
    /// back, within the page limit, and never restores fewer pages than `state` had.
    private func registerRestore(of state: PaperState, over pageCount: Int, in manager: UndoManager) {
        manager.registerUndo(withTarget: self) { [weak manager] controller in
            guard !controller.isTornDown, let manager else { return }
            // The session keeps the drawing being replaced before it is.
            _ = controller.captureBarrier()
            let replaced = PaperState(drawing: controller.canvas.drawing, pageCount: controller.pageCount)
            let added = max(replaced.pageCount - pageCount, 0)
            let restored = PaperState(
                drawing: state.drawing, pageCount: min(state.pageCount + added, Self.maximumPageCount)
            )
            controller.replacePaper(with: restored)
            controller.registerRestore(of: replaced, over: restored.pageCount, in: manager)
        }
        manager.setActionName(Self.deletePageActionName)
    }

    /// Puts `state` on the canvas in place of its paper and reports the drawing with its page
    /// count as one edit. The paper keeps its offset, held only to its new end: after a deletion
    /// the page that followed takes the deleted page's place on screen, an undo puts the page
    /// back there, and deleting the last page shows the end of the one before.
    private func replacePaper(with state: PaperState) {
        stopArrival()
        endMomentum = nil
        // A frost still clearing belongs to a page that has moved or gone.
        pageUnfold?.finish()
        let offset = canvas.contentOffset
        adjustingLayout {
            isReplacingPaper = true
            canvas.drawing = state.drawing
            isReplacingPaper = false
            pageCount = state.pageCount
            updatePaperGeometry()
            updateContentExtent()
            canvas.setContentOffset(clampedOffset(offset), animated: false)
        }
        updatePaperViewport()
        releaseEndCardOnceLeftView()
        observeDrawing(replacingPaper: true)
        prepareEndCardSoon()
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
        pageUnfold?.finish()
        stopArrival()
        endPull = nil
        endMomentum = nil
        endOfNotebookCard.onAddPage = nil
        canvas.accessibilityCustomActions = nil
        withoutAnimations { endOfNotebookCard.isHidden = true }
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
        onPaperReplacement = nil
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
        updateEndOfNotebookCard()
    }

    // MARK: - End of notebook

    private var offersEndCard: Bool { allowsEditing && onAddPage != nil && !isTornDown }

    /// The offset that rests the last page at the end of the scroll range as it stands, the
    /// card's room included.
    private var endOffsetY: CGFloat {
        max(-canvas.contentInset.top, canvas.contentSize.height - canvas.bounds.height + canvas.contentInset.bottom)
    }

    /// The offset that rests the last page at its end above the bottom chrome, without the card.
    private var restingEndOffsetY: CGFloat {
        max(-canvas.contentInset.top, canvas.contentSize.height - canvas.bounds.height + chromeBottomInset)
    }

    /// Whether a pull or an overshoot has lifted the page past its resting end, opening space
    /// below it. A pinch near the end is no lift: the card would not zoom with the page.
    private var isPastRestingEnd: Bool {
        canvas.contentOffset.y > restingEndOffsetY + 0.5 && !canvas.isZooming && !canvas.isZoomBouncing
    }

    /// Offers the card's VoiceOver action to a canvas that can add pages: it reveals the card for
    /// anyone who cannot pull the page past its end.
    private func updateEndOfNotebookAccess() {
        canvas.accessibilityCustomActions = offersEndCard
            ? [UIAccessibilityCustomAction(name: Self.endCardActionName) { [weak self] _ in
                self?.revealEndCardForAssistiveTechnology() ?? false
            }]
            : nil
        updateEndOfNotebookCard()
    }

    /// Places the card centred under the visible part of the last page, its top `endCardGap`
    /// below it on screen, while it is revealed or the page is lifted past its end, by a pull or
    /// by a fling's overshoot and bounce. It only moves as the paper scrolls; its content changes
    /// with the gate, the page limit, the width and the text size.
    private func updateEndOfNotebookCard() {
        guard isViewLoaded else { return }
        let card = endOfNotebookCard
        guard offersEndCard, isEndCardRevealed || isPastRestingEnd else {
            if !card.isHidden { withoutAnimations { card.isHidden = true } }
            return
        }
        configureEndCard()
        let size = card.bounds.size
        let offsetX = canvas.contentOffset.x
        let pageLeft = max(-offsetX, 0)
        let pageRight = min(logicalWidth * canvas.zoomScale - offsetX, view.bounds.width)
        let pixel = 1 / max(traitCollection.displayScale, 1)
        // Whole device pixels keep the labels sharp at any zoom.
        let origin = CGPoint(
            x: (((pageLeft + pageRight) - size.width) / 2 / pixel).rounded() * pixel,
            y: (endCardTop / pixel).rounded() * pixel
        )
        let frame = CGRect(origin: origin, size: size)
        let hidden = frame.minY >= view.bounds.height || frame.maxY <= 0
        withoutAnimations {
            if card.frame != frame { card.frame = frame }
            if card.isHidden != hidden { card.isHidden = hidden }
        }
    }

    private func configureEndCard() {
        let addPage: NotebookEndOfNotebookCard.AddPage = pageCount >= Self.maximumPageCount
            ? .limitReached : inputGate.allowsMutation ? .available : .paused
        // The card keeps the same margin from the window's sides as from the page above it.
        endOfNotebookCard.configure(
            addPage: addPage, contentSize: traitCollection.preferredContentSizeCategory,
            maximumWidth: view.bounds.width - 2 * NotebookTheme.endCardGap
        )
        // A taller card at a larger text size needs more room at once; a shorter one keeps the
        // room it has until the card is dismissed, so the lifted page never drops.
        if isEndCardRevealed, endCardRoomNeeded > endCardRoom {
            endCardRoom = endCardRoomNeeded
            updateInsets()
        }
    }

    /// The card with its gap above and below.
    private var endCardRoomNeeded: CGFloat {
        endOfNotebookCard.bounds.height + 2 * NotebookTheme.endCardGap
    }

    /// Where the card's top lies in the canvas's frame: `endCardGap` below the last page.
    private var endCardTop: CGFloat {
        logicalHeight * canvas.zoomScale - canvas.contentOffset.y + NotebookTheme.endCardGap
    }

    /// Builds the card for the gate, the page limit, the width and the text size as they stand,
    /// while the canvas is at rest. Building it costs a frame or more; paid beneath a moving page,
    /// it would stall the page just as a pull or a fling reaches the end. A stroke, a scroll, a zoom
    /// or the scroll on to an added page puts it off until that ends, and a card already built for
    /// them costs nothing.
    private func prepareEndCard() {
        guard offersEndCard, isCanvasVisible, view.window != nil, !canvas.hasActiveTool, !canvas.isTracking,
              !canvas.isDecelerating, !canvas.isZooming, !canvas.isZoomBouncing, arrival == nil else { return }
        configureEndCard()
    }

    /// Prepares the card on the next turn of the main queue, outside the callback of the stroke or
    /// the scroll that has just ended.
    private func prepareEndCardSoon() {
        DispatchQueue.main.async { [weak self] in self?.prepareEndCard() }
    }

    /// Keeps room below the last page for the card and shows it there.
    @discardableResult
    private func revealEndCard() -> Bool {
        guard offersEndCard else { return false }
        isEndCardRevealed = true
        configureEndCard()
        endCardRoom = max(endCardRoom, endCardRoomNeeded)
        updateInsets()
        updateEndOfNotebookCard()
        return true
    }

    /// The VoiceOver action: brings the page to its end, lifted, with the card below it, and
    /// moves VoiceOver to the card.
    private func revealEndCardForAssistiveTechnology() -> Bool {
        guard revealEndCard() else { return false }
        stopArrival()
        adjustingLayout {
            canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: endOffsetY), animated: false)
        }
        updatePaperViewport()
        UIAccessibility.post(notification: .layoutChanged, argument: endOfNotebookCard)
        return true
    }

    /// Dismisses the card once scrolling or zooming has taken it below the part of the window the
    /// bottom chrome leaves clear. Where the whole notebook fits on screen the page cannot leave
    /// its resting end, so the card stays while it is in view.
    private func releaseEndCardOnceLeftView() {
        // A fling that adopted the room ahead of the end carries the page on to the card.
        guard isEndCardRevealed, endMomentum?.hasRevealed != true,
              endCardTop >= view.bounds.height - chromeBottomInset - 0.5 else { return }
        dismissEndCard()
    }

    /// Dismisses the card and gives up its room once the page rests no lower than it would
    /// without that room, so the release only ever clamps; a stroke in progress keeps the room
    /// until it ends.
    private func dismissEndCard() {
        guard isEndCardRevealed, canvas.contentOffset.y <= restingEndOffsetY + 0.5 else { return }
        isEndCardRevealed = false
        endCardRoom = 0
        endPull = nil
        updateInsets()
        updateEndOfNotebookCard()
    }

    /// The pull or the fling past the end has run its course: the card stays if it was revealed
    /// and leaves with the page otherwise, as it does when a tap stops a fling short of the end.
    private func settleEnd() {
        let pulled = endPull?.isReleased ?? false
        let flung = endMomentum?.hasRevealed ?? false
        if pulled { endPull = nil }
        let withdrawn = withdrawFlingRevealShortOfEnd()
        endMomentum = nil
        guard pulled || flung, !withdrawn else { return }
        // A release with no speed left, or a tap that stops the bounce, can leave the lifted page
        // short of its new end. Animated, it eases there; its frames are neither a drag nor a
        // deceleration, so the writing view does not count them as the user's scrolling.
        if isEndCardRevealed, canvas.contentOffset.y < endOffsetY - 0.5, !canvas.isDecelerating {
            adjustingLayout {
                canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: endOffsetY), animated: true)
            }
        }
        updateEndOfNotebookCard()
    }

    /// How far past `end` UIKit's rubber band would carry a fling let go at `offset` at `speed`
    /// points a millisecond: `flingOvershootTime` of the speed it has left on reaching the end.
    static func flingOvershoot(
        from offset: CGFloat, speed: CGFloat, end: CGFloat, decelerationRate: UIScrollView.DecelerationRate
    ) -> CGFloat {
        // Decaying by the rate every millisecond, a deceleration sheds speed in proportion to the
        // distance it covers.
        let arrival = speed + log(decelerationRate.rawValue) * max(end - offset, 0)
        return max(arrival, 0) * flingOvershootTime
    }

    /// Reveals the card for a fling bound to overshoot the threshold, adopting its room within two
    /// frames of the page reaching the end. Only the room is adopted, never an offset. Adopted
    /// while the page is still short of the end, it lets UIKit's deceleration run on into the room
    /// untouched and bounce at the lifted end, as for a page that ended with the card; two frames
    /// ahead, a frame the display drops still finds it in place.
    ///
    /// Should dropped frames carry the page past the end first, the room is adopted only while the
    /// page heads out within the lifted end. Beyond it UIKit pulls the page straight back to the
    /// grown range's end, and adopted on the way back the room turns the page round again, so such
    /// a fling bounces back without the card, as one short of the threshold does.
    private func continueEndMomentum() {
        guard var momentum = endMomentum, !momentum.hasRevealed, offersEndCard, !isEndCardRevealed,
              !canvas.isZooming, !canvas.isZoomBouncing else { return }
        let y = canvas.contentOffset.y
        if y != momentum.offset {
            momentum.step = y - momentum.offset
            momentum.offset = y
            endMomentum = momentum
        }
        guard momentum.step > 0, y + 2 * momentum.step > restingEndOffsetY + 0.5 else { return }
        configureEndCard()
        let pixel = 1 / max(traitCollection.displayScale, 1)
        let liftedEnd = max(
            -canvas.contentInset.top,
            canvas.contentSize.height - canvas.bounds.height + chromeBottomInset + endCardRoomNeeded
        )
        guard y <= liftedEnd + pixel / 2, revealEndCard() else { return }
        endMomentum?.hasRevealed = true
        momentum.feedback.impactOccurred(at: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.maxY))
    }

    /// Whether a fling adopted the card's room ahead of the end and has stopped short of it, so it
    /// never lifted the page.
    private var isFlingRevealShortOfEnd: Bool {
        endMomentum?.hasRevealed == true && isEndCardRevealed && canvas.contentOffset.y <= restingEndOffsetY
    }

    /// Gives back the room a fling adopted ahead of the end when a tap or a stroke stops the page
    /// short of it: the fling never lifted the page, and giving the room back leaves the page where
    /// it stopped.
    @discardableResult
    private func withdrawFlingRevealShortOfEnd() -> Bool {
        guard isFlingRevealShortOfEnd else { return false }
        dismissEndCard()
        return true
    }

    /// Ends a fling that a stroke, or the canvas leaving the screen, has halted, giving back the
    /// room it adopted if it stopped short of the end.
    private func endHaltedFling() {
        guard !isTornDown else { return }
        withdrawFlingRevealShortOfEnd()
        endMomentum = nil
    }

    /// The card's Add page key, which the card offers only while a page can be added. The host
    /// adds the page as one the user asked for, so it is brought into view.
    private func addPageFromEndCard() {
        guard isEndCardRevealed else { return }
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

    /// The room below the last page for the home indicator and a toolbar at the bottom, so the
    /// page rests at its end above them.
    private var chromeBottomInset: CGFloat {
        max(chrome.bottom, 0) + max(toolbarObstruction.bottom, 0)
    }

    /// Edge insets add scroll range to reveal covered writing. Reserving range never moves the
    /// page; releasing it only pulls a page scrolled past the new end back to that end, and
    /// waits until a stroke in progress ends. The one exception is a confirmed resize: a page
    /// that rested at its revealed top when the resize began stays there instead of ending up
    /// under the header or toolbar. Horizontally the page stays centred. A revealed end of
    /// notebook card adds its room below the last page.
    private func updateInsets(followingResize: Bool = false) {
        guard isViewLoaded, canvas.bounds.width > 0 else { return }
        let obstruction = toolbarObstruction
        var top = max(max(chrome.top, 0) + max(obstruction.top, 0), chrome.coveredTop)
        var bottom = chromeBottomInset + (isEndCardRevealed ? endCardRoom : 0)
        if canvas.hasActiveTool {
            // A smaller inset pulls an offset beyond it back into range, which would move the
            // page under the stroke; the space is released when the stroke ends.
            top = max(top, canvas.contentInset.top)
            bottom = max(bottom, canvas.contentInset.bottom)
        }
        let horizontalInset = max((canvas.bounds.width - logicalWidth * canvas.zoomScale) / 2, 0)
        let insets = UIEdgeInsets(top: top, left: horizontalInset, bottom: bottom, right: horizontalInset)
        let indicatorInsets = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        let offset = canvas.contentOffset
        let isNested = isAdjustingLayout
        adjustingLayout {
            if canvas.contentInset != insets {
                canvas.contentInset = insets
            }
            if canvas.verticalScrollIndicatorInsets != indicatorInsets {
                canvas.verticalScrollIndicatorInsets = indicatorInsets
            }
            if followingResize, let resizeCapture, resizeCapture.isConfirmed, resizeCapture.restedAtRevealedTop,
               !canvas.hasActiveTool, !isAtTopOfPaper {
                canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: -top), animated: false)
            }
        }
        // The writes' own scroll events were ignored, so the paper catches up with a moved page here.
        if !isNested, canvas.contentOffset != offset { updatePaperViewport() }
    }

    /// Makes inset, offset and zoom writes layout rather than scrolling. The scroll events they
    /// cause move neither the paper nor the writing view, and the caller may be inside a SwiftUI
    /// update, where the writing view must not publish. Once the outermost adjustment ends, the
    /// writing view carries on a user scroll from wherever layout left the page.
    private func adjustingLayout(_ changes: () -> Void) {
        let isNested = isAdjustingLayout
        isAdjustingLayout = true
        changes()
        isAdjustingLayout = isNested
        guard !isNested else { return }
        writingChrome?.layoutMovedPage(in: canvas)
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
        // A stroke halts a deceleration without reporting its end, and the page holds still under
        // the pen. A fling it stops short of the end keeps the room it adopted ahead of the end
        // until the stroke ends, as no inset shrinks under the pen; any other claim ends here.
        if !isFlingRevealShortOfEnd { endMomentum = nil }
        stopArrival()
        toolBeginGeneration = observedGeneration
        toolBeginSignature = try? InkDrawingSignature(canvas.drawing)
        if let toolBeginSignature { observationWork.add(toolBeginSignature.constructionWork) }
        canvas.hasActiveTool = true
        writingChrome?.toolBegan()
        publishUndoAvailability()
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isReplacingPaper else { return }
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
        writingChrome?.toolEnded()
        if let pendingTool { applyTool(pendingTool) }
        endHaltedFling()
        releaseHeldInsets()
        publishUndoAvailability()
        prepareEndCardSoon()
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
        prepareEndCardSoon()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isAdjustingLayout else { return }
        continueEndMomentum()
        updatePaperViewport()
        writingChrome?.userScrollMoved(in: scrollView)
        releaseEndCardOnceLeftView()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // The user moving the page ends any claim that it rested at its top when a resize began.
        resizeCapture = nil
        endMomentum = nil
        stopArrival()
        let offset = canvas.contentOffset.y
        let end = endOffsetY
        // Only a new drag from a page resting at its end pulls past it; a drag carried on past it
        // never does, though a fling let go short of the end may reveal the card.
        if offersEndCard, !isEndCardRevealed, abs(offset - end) <= Self.endRestTolerance {
            let feedback = UIImpactFeedbackGenerator(style: .light, view: canvas)
            feedback.prepare()
            endPull = EndPull(feedback: feedback)
        } else {
            endPull = nil
        }
        writingChrome?.userScrollBegan(in: scrollView)
        updateEndOfNotebookCard()
    }

    /// Reveals the card for a pull from the end released far enough past it and not already
    /// heading back, and readies the tick for a fling let go short of the end that UIKit's rubber
    /// band would carry the threshold past it. The deceleration and its bounce are UIKit's own.
    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        let offset = canvas.contentOffset.y
        let end = endOffsetY
        if endPull != nil {
            endPull?.isReleased = true
            // UIKit holds the offset to whole device pixels, so the threshold allows one.
            let pixel = 1 / max(traitCollection.displayScale, 1)
            if offset - end >= Self.endRevealPull - pixel, velocity.y >= -Self.endPullReturnSpeed,
               let feedback = endPull?.feedback, revealEndCard() {
                targetContentOffset.pointee.y = endOffsetY
                feedback.impactOccurred(at: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.maxY))
                return
            }
        }
        // UIKit aims a fling that would run past the end at the end itself. A page let go already
        // past the end only springs back.
        guard offersEndCard, !isEndCardRevealed, offset < end,
              targetContentOffset.pointee.y >= end - Self.endRestTolerance,
              Self.flingOvershoot(from: offset, speed: velocity.y, end: end, decelerationRate: canvas.decelerationRate)
                >= Self.endRevealPull else { return }
        let feedback = endPull?.feedback ?? UIImpactFeedbackGenerator(style: .light, view: canvas)
        feedback.prepare()
        endMomentum = EndMomentum(feedback: feedback, offset: offset)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else { return }
        writingChrome?.userScrollEnded()
        settleEnd()
        prepareEndCardSoon()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        writingChrome?.userScrollEnded()
        settleEnd()
        prepareEndCardSoon()
    }

    /// A drag still under way, or the deceleration it started, reports its own end. A tap that
    /// stops a fling reports neither, so the fling ends here.
    private func fingersLifted() {
        guard !canvas.isDragging, !canvas.isDecelerating else { return }
        writingChrome?.fingersLifted()
        settleEnd()
        prepareEndCardSoon()
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        // A pinch takes over from any fling, so its bounce at the foot of the paper is its own.
        endMomentum = nil
        stopArrival()
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        // The status-bar tap's own scroll takes over from the scroll on to an added page.
        stopArrival()
        return true
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        writingChrome?.scrolledToTop()
        prepareEndCardSoon()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard !isAdjustingLayout else { return }
        adjustingLayout {
            updateContentExtent()
            updateInsets()
        }
        updatePaperViewport()
        releaseEndCardOnceLeftView()
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

/// Holds the controller weakly: a display link retains its target, and the scroll on to an added
/// page must not outlive its canvas.
@MainActor
private final class ArrivalLinkTarget: NSObject {
    private weak var controller: NotebookViewController?

    init(_ controller: NotebookViewController) {
        self.controller = controller
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let controller else {
            link.invalidate()
            return
        }
        controller.advanceArrival(link)
    }
}

/// Reports each time the last finger leaves the canvas. It never recognises, so it takes nothing
/// from scrolling, zooming or drawing, and it sees fingers only, never Apple Pencil.
@MainActor
final class NotebookFingerLiftObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onLift: (() -> Void)?
    private var fingers = 0

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesEnded = false
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        fingers += touches.count
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        lift(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        lift(touches)
    }

    override func reset() {
        super.reset()
        fingers = 0
    }

    private func lift(_ touches: Set<UITouch>) {
        fingers -= touches.count
        guard fingers <= 0 else { return }
        state = .failed
        onLift?()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
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
