import CoreGraphics
import PencilKit

extension PaperGeometry {
    /// The page that fills the most of the visible paper, the span `top..<bottom` in paper points.
    /// Where pages fill it equally, as whole pages do when zoomed out, the one holding the span's
    /// centre wins, or failing that the one nearest it. The span is clipped to the paper first, so
    /// the head margin and the space below the last page count for nothing; a span wholly above
    /// or below the paper picks the nearer end page, and one that cannot be measured the first.
    public func mostVisiblePage(top: Double, bottom: Double, pageCount: Int) -> Int {
        guard pageCount > 1, top.isFinite, bottom.isFinite else { return 0 }
        let end = contentHeight(pageCount: pageCount)
        let lower = min(max(top, 0), end)
        let upper = min(max(bottom, 0), end)
        guard upper > lower else { return lower >= end ? pageCount - 1 : 0 }
        let centre = page(holding: (lower + upper) / 2, pageCount: pageCount)
        // Divider positions are products, so two whole pages can differ by a rounding error.
        let tolerance = pageHeight * 1e-9
        var best = centre
        var bestShown = -Double.infinity
        for index in page(holding: lower, pageCount: pageCount)...page(holding: upper, pageCount: pageCount) {
            let shown = min(upper, boundaryPosition(at: index + 1)) - max(lower, boundaryPosition(at: index))
            let isTie = abs(shown - bestShown) <= tolerance
            if shown > bestShown + tolerance || (isTie && abs(index - centre) < abs(best - centre)) {
                best = index
                bestShown = shown
            }
        }
        return best
    }

    /// The page holding the vertical position `y`; positions above the paper belong to the first
    /// page and positions below it to the last, so every position has one page.
    public func page(holding y: Double, pageCount: Int) -> Int {
        min(sectionIndex(atVerticalPosition: y), max(pageCount - 1, 0))
    }
}

/// Removing one page from the paper. The ink on that page goes, and the ink on every later page
/// moves up by exactly one page height to close the gap, so each later page keeps its writing.
///
/// A stroke belongs to the page holding the vertical midpoint of its rendered bounds, so a stroke
/// crossing a divider goes with the page holding most of its height. Ink above the first page or
/// below the last belongs to that end page. A stroke with no measurable bounds draws nothing and
/// is kept where it is.
public struct PaperPageDeletion: Sendable, Equatable {
    public enum Fate: Sendable, Equatable {
        /// On an earlier page: unchanged.
        case kept
        /// On the deleted page: removed.
        case removed
        /// On a later page: moved up by one page height.
        case movedUp
    }

    /// The deleted page, counted from zero.
    public let page: Int
    public let pageCount: Int
    public let geometry: PaperGeometry

    /// Nil unless `page` is one of `pageCount` pages and at least one page would remain.
    public init?(page: Int, pageCount: Int, geometry: PaperGeometry) {
        guard pageCount > 1, (0..<pageCount).contains(page) else { return nil }
        self.page = page
        self.pageCount = pageCount
        self.geometry = geometry
    }

    public var remainingPageCount: Int { pageCount - 1 }

    /// How far ink on later pages moves vertically: up by one page height.
    public var verticalShift: Double { -geometry.pageHeight }

    /// What becomes of a stroke whose rendered bounds run from `minY` to `maxY`.
    public func fate(ofStrokeFrom minY: Double, to maxY: Double) -> Fate {
        let midpoint = (minY + maxY) / 2
        guard midpoint.isFinite else { return .kept }
        let holder = geometry.page(holding: midpoint, pageCount: pageCount)
        if holder < page { return .kept }
        return holder == page ? .removed : .movedUp
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension PaperPageDeletion {
    /// `drawing` with the page removed. The remaining strokes keep their order and their native
    /// identities; a moved stroke's transform gains the shift, which carries its path and its
    /// eraser mask together, so the codec stores it again under the same identity.
    public func apply(to drawing: PKDrawing) -> PKDrawing {
        let shift = CGAffineTransform(translationX: 0, y: CGFloat(verticalShift))
        var strokes: [PKStroke] = []
        strokes.reserveCapacity(drawing.strokes.count)
        for var stroke in drawing.strokes {
            let bounds = stroke.renderBounds
            switch fate(ofStrokeFrom: Double(bounds.minY), to: Double(bounds.maxY)) {
            case .kept:
                strokes.append(stroke)
            case .removed:
                continue
            case .movedUp:
                stroke.transform = stroke.transform.concatenating(shift)
                strokes.append(stroke)
            }
        }
        return PKDrawing(strokes: strokes)
    }
}
