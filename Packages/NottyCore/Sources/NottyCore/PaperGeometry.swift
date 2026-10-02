/// A continuous paper coordinate space with A4 export section boundaries.
public struct PaperGeometry: Sendable, Equatable {
    public let pageWidth: Double
    public let pageHeight: Double

    public init(pageWidth: Double = 794) {
        let pageHeight = pageWidth * (297.0 / 210.0)
        precondition(
            pageWidth.isFinite && pageWidth > 0
                && pageHeight.isFinite && pageHeight > 0,
            "Paper dimensions must be finite and positive."
        )
        self.pageWidth = pageWidth
        self.pageHeight = pageHeight
    }

    /// Returns an export divider's vertical position. Nonpositive indices return zero.
    public func boundaryPosition(at sectionIndex: Int) -> Double {
        guard sectionIndex > 0 else { return 0 }
        return Double(sectionIndex) * pageHeight
    }

    /// Returns internal dividers for a bounded number of sections.
    /// For long notes, calculate visible dividers with `boundaryPosition(at:)`.
    public func boundaryPositions(pageCount: Int) -> [Double] {
        guard pageCount > 1 else { return [] }
        return (1..<pageCount).map { boundaryPosition(at: $0) }
    }

    /// Returns zero for nonpositive counts and infinity if the height overflows.
    public func contentHeight(pageCount: Int) -> Double {
        guard pageCount > 0 else { return 0 }
        return Double(pageCount) * pageHeight
    }

    /// Locates a coordinate in half-open sections: `[start, end)`.
    /// Negative and NaN coordinates resolve to zero. Unrepresentable indices saturate.
    public func sectionIndex(atVerticalPosition position: Double) -> Int {
        guard !position.isNaN, position > 0 else { return 0 }
        let quotient = position / pageHeight
        guard quotient.isFinite, quotient < Double(Int.max) else {
            return Int.max
        }

        var index = Int(quotient.rounded(.down))
        // Division can round across a divider; compare against its actual position.
        if index > 0, position < boundaryPosition(at: index) {
            index -= 1
        } else if index < Int.max,
                  position >= boundaryPosition(at: index + 1) {
            index += 1
        }
        return index
    }
}
