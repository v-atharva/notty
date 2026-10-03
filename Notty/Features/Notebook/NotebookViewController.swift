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

    private let geometry = PaperGeometry(pageWidth: 794)
    private let logicalWidth: CGFloat = 794
    private let canvas = NotebookCanvasView()
    private let paper = PaperBackgroundView()
    private let toolPicker: PKToolPicker

    var onCompletedEdit: ((PKDrawing) -> NotebookInputGate)?
    var onDetach: (() -> Void)?
    var canvasView: PKCanvasView { canvas }
    var drawingToolPicker: PKToolPicker { toolPicker }
    var currentDrawing: PKDrawing { canvas.drawing }

    private let initialDrawing: PKDrawing
    private var lastDeliveredDrawing: PKDrawing
    private var isUsingTool = false
    private(set) var inputGate = NotebookInputGate.open
    private var pageCount: Int
    private var previousViewportSize = CGSize.zero
    private var isAdjustingLayout = false
    private var observesToolPicker = false

    private var logicalHeight: CGFloat {
        CGFloat(geometry.pageHeight) * CGFloat(pageCount)
    }

    init(pageCount: Int, initialDrawing: PKDrawing, toolPicker: PKToolPicker? = nil) {
        self.toolPicker = toolPicker ?? PKToolPicker()
        self.initialDrawing = initialDrawing
        self.lastDeliveredDrawing = initialDrawing
        self.pageCount = min(max(pageCount, 1), Self.maximumPageCount)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(pageCount:initialDrawing:).")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = PaperBackgroundView.paperColor
        view.clipsToBounds = true
        paper.isUserInteractionEnabled = false
        paper.isAccessibilityElement = false
        paper.backgroundColor = PaperBackgroundView.paperColor
        paper.isOpaque = true
        paper.contentMode = .redraw

        canvas.drawing = initialDrawing
        canvas.delegate = self
        canvas.permitsMutation = inputGate.allowsMutation
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .pencilOnly
        canvas.tool = PKInkingTool(
            .pen,
            color: UIColor(red: 0.19, green: 0.16, blue: 0.13, alpha: 1),
            width: 3
        )
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

        view.addSubview(paper)
        view.addSubview(canvas)
        updatePaperGeometry()
        updateContentExtent()
        toolPicker.addObserver(canvas)
        toolPicker.addObserver(self)
        observesToolPicker = true
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
        paper.frame = view.bounds
        canvas.frame = view.bounds
        let fitScale = newSize.width / logicalWidth
        let maximumScale = max(3, fitScale * 4)
        canvas.maximumZoomScale = maximumScale
        canvas.minimumZoomScale = fitScale
        let requestedScale = wasWidthFitted ? fitScale : oldScale
        let scale = min(max(requestedScale, fitScale), maximumScale)
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
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard observesToolPicker else { return }
        toolPicker.setVisible(inputGate.keepsPalette, forFirstResponder: canvas)
        if inputGate.keepsPalette { canvas.becomeFirstResponder() }
        updateInsets()
        updatePaperViewport()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        toolPicker.setVisible(false, forFirstResponder: canvas)
        canvas.resignFirstResponder()
    }

    func setEditingEnabled(_ enabled: Bool) {
        setInputGate(enabled ? .open : .readOnly)
    }

    func setInputGate(_ gate: NotebookInputGate) {
        guard gate != inputGate else { return }
        let previousGate = inputGate
        inputGate = gate
        guard isViewLoaded else { return }
        canvas.permitsMutation = gate.allowsMutation
        guard previousGate.keepsPalette != gate.keepsPalette else { return }
        toolPicker.setVisible(gate.keepsPalette && view.window != nil, forFirstResponder: canvas)
        if gate.keepsPalette && view.window != nil {
            canvas.becomeFirstResponder()
        } else if !gate.keepsPalette {
            canvas.resignFirstResponder()
        }
        updateInsets()
    }

    private func deliverCompletedDrawing() {
        let drawing = canvas.drawing
        guard drawing != lastDeliveredDrawing else { return }
        lastDeliveredDrawing = drawing
        if let onCompletedEdit {
            setInputGate(onCompletedEdit(drawing))
        }
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
        deliverCompletedDrawing()
        onDetach?()
        onDetach = nil
        onCompletedEdit = nil
        guard observesToolPicker else { return }
        toolPicker.setVisible(false, forFirstResponder: canvas)
        toolPicker.removeObserver(canvas)
        toolPicker.removeObserver(self)
        canvas.resignFirstResponder()
        canvas.delegate = nil
        observesToolPicker = false
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
        paper.setGeometry(width: logicalWidth, height: logicalHeight, boundaries: boundaries)
    }

    private func updatePaperViewport() {
        paper.setViewport(scale: canvas.zoomScale, offset: canvas.contentOffset)
    }

    private func updateInsets() {
        guard isViewLoaded, canvas.bounds.width > 0 else { return }
        let horizontalInset = max((canvas.bounds.width - logicalWidth * canvas.zoomScale) / 2, 0)
        let obscuredFrame = toolPicker.frameObscured(in: view)
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
        isUsingTool = true
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        if !isUsingTool {
            deliverCompletedDrawing()
        }
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        isUsingTool = false
        deliverCompletedDrawing()
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
private final class PaperBackgroundView: UIView {
    static let paperColor = UIColor(red: 0.98, green: 0.96, blue: 0.91, alpha: 1)
    private var logicalWidth: CGFloat = 794
    private var logicalHeight: CGFloat = 0
    private var boundaries: [CGFloat] = []
    private var viewportScale: CGFloat = 1
    private var viewportOffset = CGPoint.zero

    func setGeometry(width: CGFloat, height: CGFloat, boundaries: [CGFloat]) {
        logicalWidth = width
        logicalHeight = height
        self.boundaries = boundaries
        setNeedsDisplay()
    }

    func setViewport(scale: CGFloat, offset: CGPoint) {
        guard scale != viewportScale || offset != viewportOffset else { return }
        viewportScale = max(scale, 0.001)
        viewportOffset = offset
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(Self.paperColor.cgColor)
        context.fill(rect)
        let screenScale = max(window?.screen.scale ?? traitCollection.displayScale, 1)
        let lineWidth = 1 / screenScale
        let left = -viewportOffset.x
        let right = logicalWidth * viewportScale - viewportOffset.x
        let visibleLeft = max(rect.minX, left)
        let visibleRight = min(rect.maxX, right)
        guard visibleRight > visibleLeft, logicalHeight > 0 else { return }

        context.saveGState()
        context.clip(to: rect)
        context.setStrokeColor(UIColor(red: 0.47, green: 0.40, blue: 0.31, alpha: 0.30).cgColor)
        context.setLineWidth(lineWidth)
        for boundary in boundaries {
            let y = boundary * viewportScale - viewportOffset.y
            guard y >= rect.minY - lineWidth, y <= rect.maxY + lineWidth else { continue }
            let alignedY = (floor(y * screenScale) + 0.5) / screenScale
            context.move(to: CGPoint(x: visibleLeft, y: alignedY))
            context.addLine(to: CGPoint(x: visibleRight, y: alignedY))
        }
        context.strokePath()
        context.restoreGState()
    }
}

@MainActor
private final class NotebookCanvasView: PKCanvasView {
    // Keep the native tool's requested mode across temporary input pauses.
    private var requestedDrawingEnabled = true
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
        let enabled = permitsMutation && requestedDrawingEnabled
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

    override var undoManager: UndoManager? {
        permitsMutation ? super.undoManager : nil
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if !permitsMutation && Self.mutationActions.contains(action) { return false }
        return super.canPerformAction(action, withSender: sender)
    }

    override func target(forAction action: Selector, withSender sender: Any?) -> Any? {
        if !permitsMutation && Self.mutationActions.contains(action) { return nil }
        return super.target(forAction: action, withSender: sender)
    }

    private static let mutationActions: Set<Selector> = Set([
        "cut:", "paste:", "delete:", "undo:", "redo:", "duplicate:"
    ].map(NSSelectorFromString))
}
