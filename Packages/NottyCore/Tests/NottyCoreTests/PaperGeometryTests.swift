import XCTest
@testable import NottyCore

final class PaperGeometryTests: XCTestCase {
    func testDefaultPaperMaintainsA4AspectRatio() {
        let geometry = PaperGeometry()
        XCTAssertEqual(geometry.pageWidth, 794)
        XCTAssertEqual(geometry.pageHeight / geometry.pageWidth, 297.0 / 210.0, accuracy: 1e-12)
    }

    func testOneSectionHasNoInternalDivider() {
        let geometry = PaperGeometry(pageWidth: 210)
        XCTAssertTrue(geometry.boundaryPositions(pageCount: 1).isEmpty)
        XCTAssertEqual(geometry.contentHeight(pageCount: 1), 297, accuracy: 1e-12)
    }

    func testThreeSectionsHaveTwoDividersAndContinuousHeight() {
        let geometry = PaperGeometry(pageWidth: 210)
        let boundaries = geometry.boundaryPositions(pageCount: 3)
        XCTAssertEqual(boundaries.count, 2)
        XCTAssertEqual(boundaries[0], 297, accuracy: 1e-12)
        XCTAssertEqual(boundaries[1], 594, accuracy: 1e-12)
        XCTAssertEqual(geometry.contentHeight(pageCount: 3), 891, accuracy: 1e-12)
    }

    func testNonpositiveSectionCountsProduceNoPaper() {
        let geometry = PaperGeometry()
        for count in [Int.min, -10, -1, 0] {
            XCTAssertTrue(geometry.boundaryPositions(pageCount: count).isEmpty)
            XCTAssertEqual(geometry.contentHeight(pageCount: count), 0)
        }
    }

    func testDividersUseHalfOpenIntervalsAcrossDifferentWidths() {
        for width in [1.0, 210.0, 794.0, 1024.0, 2000.0] {
            let geometry = PaperGeometry(pageWidth: width)
            for section in 1...1_000 {
                let divider = geometry.boundaryPosition(at: section)
                XCTAssertEqual(geometry.sectionIndex(atVerticalPosition: divider.nextDown), section - 1)
                XCTAssertEqual(geometry.sectionIndex(atVerticalPosition: divider), section)
                XCTAssertEqual(geometry.sectionIndex(atVerticalPosition: divider.nextUp), section)
            }
        }
    }

    func testCoordinatesInsideSectionsResolveToTheirSection() {
        let geometry = PaperGeometry()
        for section in 0..<20 {
            let middle = (Double(section) + 0.5) * geometry.pageHeight
            XCTAssertEqual(geometry.sectionIndex(atVerticalPosition: middle), section)
        }
    }

    func testScalingPaperPreservesSectionMembership() {
        let original = PaperGeometry(pageWidth: 400)
        let scaled = PaperGeometry(pageWidth: 800)
        XCTAssertEqual(scaled.pageHeight, original.pageHeight * 2)
        for fraction in [0.0, 0.25, 0.75, 1.25, 2.5, 9.75] {
            let position = original.pageHeight * fraction
            XCTAssertEqual(original.sectionIndex(atVerticalPosition: position),
                           scaled.sectionIndex(atVerticalPosition: position * 2))
        }
    }

    func testUnusualCoordinatesHaveDeliberateResults() {
        let geometry = PaperGeometry()
        for position in [-Double.infinity, -100.0, -0.0, 0.0, Double.nan] {
            XCTAssertEqual(geometry.sectionIndex(atVerticalPosition: position), 0)
        }
        XCTAssertEqual(geometry.sectionIndex(atVerticalPosition: .infinity), Int.max)
        XCTAssertEqual(geometry.sectionIndex(atVerticalPosition: .greatestFiniteMagnitude), Int.max)
    }

    func testScalarDividersDoNotRequireAnArray() {
        let geometry = PaperGeometry()
        XCTAssertEqual(geometry.boundaryPosition(at: Int.min), 0)
        XCTAssertEqual(geometry.boundaryPosition(at: 0), 0)
        XCTAssertEqual(geometry.boundaryPosition(at: 1_000_000), geometry.pageHeight * 1_000_000)
    }

    func testHeightOverflowRemainsExplicit() {
        let geometry = PaperGeometry(pageWidth: Double.greatestFiniteMagnitude / 4)
        XCTAssertTrue(geometry.contentHeight(pageCount: 2).isFinite)
        XCTAssertEqual(geometry.contentHeight(pageCount: 4), .infinity)
        XCTAssertEqual(geometry.boundaryPosition(at: 4), .infinity)
    }
}
