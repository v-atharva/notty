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
    let applyPageCount: (Int) -> Void
    let currentAvailability: () -> NotebookUndoAvailability
    let retire: (() -> Void)?

    init(
        undo: @escaping () -> Void,
        redo: @escaping () -> Void,
        setPaletteSuppressed: @escaping (Bool) -> Void,
        applyPageCount: @escaping (Int) -> Void,
        currentAvailability: @escaping () -> NotebookUndoAvailability = { .unavailable },
        retire: (() -> Void)? = nil
    ) {
        self.undo = undo
        self.redo = redo
        self.setPaletteSuppressed = setPaletteSuppressed
        self.applyPageCount = applyPageCount
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
