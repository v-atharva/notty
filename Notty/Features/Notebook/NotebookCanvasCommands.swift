import CoreGraphics
import Foundation
import NottyCore
import PencilKit

struct NotebookUndoAvailability: Equatable, Sendable {
    let canUndo: Bool
    let canRedo: Bool
    let isUsingTool: Bool

    static let unavailable = Self(canUndo: false, canRedo: false, isUsingTool: false)
}

@MainActor
struct NotebookCanvasControls {
    let undo: () -> Void
    let redo: () -> Void
    let setPaletteSuppressed: (Bool) -> Void
    /// Grows the paper for a page the notebook adds on its own, as when writing reaches the foot
    /// of the last page; the paper never moves for it.
    let applyPageCount: (Int) -> Void
    /// Grows the paper for a page the user asked for, which the canvas brings into view. A host
    /// that passes none has the page added as the notebook's own, and nothing scrolls to it.
    let applyRequestedPageCount: (Int) -> Void
    /// Deletes a page, counted from zero, as one edit the canvas can undo; false when the canvas
    /// cannot delete one now. Nil for a host that offers no page deletion.
    let deletePage: ((Int) -> Bool)?
    /// The page filling the most of the paper in view, the one the Notebook menu offers to delete.
    let mostVisiblePage: (() -> Int?)?
    let currentAvailability: () -> NotebookUndoAvailability
    let retire: (() -> Void)?

    init(
        undo: @escaping () -> Void,
        redo: @escaping () -> Void,
        setPaletteSuppressed: @escaping (Bool) -> Void,
        applyPageCount: @escaping (Int) -> Void,
        applyRequestedPageCount: ((Int) -> Void)? = nil,
        deletePage: ((Int) -> Bool)? = nil,
        mostVisiblePage: (() -> Int?)? = nil,
        currentAvailability: @escaping () -> NotebookUndoAvailability = { .unavailable },
        retire: (() -> Void)? = nil
    ) {
        self.undo = undo
        self.redo = redo
        self.setPaletteSuppressed = setPaletteSuppressed
        self.applyPageCount = applyPageCount
        self.applyRequestedPageCount = applyRequestedPageCount ?? applyPageCount
        self.deletePage = deletePage
        self.mostVisiblePage = mostVisiblePage
        self.currentAvailability = currentAvailability
        self.retire = retire
    }
}

struct NotebookToolCompletion: Sendable {
    let generation: UInt64
    let pageCount: Int
    let nearPaperEnd: Bool
    let capturedAt: Date
    let uptime: TimeInterval
}

enum NotebookPaperMetrics {
    static let pageWidth: Double = 794

    static var geometry: PaperGeometry { PaperGeometry(pageWidth: pageWidth) }

    static func isNearPaperEnd(_ drawing: PKDrawing, pageCount: Int) -> Bool {
        guard pageCount > 0 else { return false }
        let bounds = drawing.bounds
        guard !bounds.isNull, !bounds.isInfinite, !bounds.isEmpty,
              bounds.minX.isFinite, bounds.minY.isFinite,
              bounds.maxX.isFinite, bounds.maxY.isFinite else { return false }
        let threshold = CGFloat(geometry.pageHeight) * (CGFloat(pageCount) - 0.2)
        return threshold.isFinite && bounds.maxY > threshold
    }
}
