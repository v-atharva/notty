import CoreGraphics
import Foundation
import XCTest
@testable import NottyCore

final class EditorToolbarLayoutTests: XCTestCase {
    private let usable = CGRect(x: 0, y: 40, width: 1000, height: 700)
    private let size = CGSize(width: 400, height: 96)

    func testDockedFramesSitAtTheTopEdgeInsideTheMargin() {
        let margin = EditorToolbarLayout.margin
        let leading = EditorToolbarLayout.frame(for: .docked(.topLeading), size: size, in: usable)
        let center = EditorToolbarLayout.frame(for: .docked(.topCenter), size: size, in: usable)
        let trailing = EditorToolbarLayout.frame(for: .docked(.topTrailing), size: size, in: usable)

        XCTAssertEqual(leading.origin, CGPoint(x: margin, y: 40 + margin))
        XCTAssertEqual(center.midX, usable.midX)
        XCTAssertEqual(trailing.maxX, usable.maxX - margin)
        XCTAssertEqual(Set([leading.minY, center.minY, trailing.minY]), [40 + margin])
    }

    func testFloatingPositionIsProportionalSoRotationKeepsItsPlace() {
        let placement = EditorToolbarPlacement.floating(CGPoint(x: 0.5, y: 0.5))
        let landscape = EditorToolbarLayout.frame(for: placement, size: size, in: usable)
        let portrait = EditorToolbarLayout.frame(
            for: placement, size: size, in: CGRect(x: 0, y: 40, width: 700, height: 1000)
        )
        XCTAssertEqual(landscape.midX, 500)
        XCTAssertEqual(portrait.midX, 350)
        XCTAssertEqual(portrait.midY, 540)
    }

    func testFloatingFramesAreClampedInsideReachableBounds() {
        let corner = EditorToolbarLayout.frame(for: .floating(CGPoint(x: 1, y: 1)), size: size, in: usable)
        XCTAssertLessThanOrEqual(corner.maxX, usable.maxX - EditorToolbarLayout.margin)
        XCTAssertLessThanOrEqual(corner.maxY, usable.maxY - EditorToolbarLayout.margin)

        let wide = EditorToolbarLayout.frame(
            for: .docked(.topTrailing), size: CGSize(width: 1200, height: 96), in: usable
        )
        XCTAssertEqual(wide.minX, usable.minX + EditorToolbarLayout.margin, "an oversized toolbar keeps its leading tools reachable")
    }

    func testDragEndingNearADockSnapsAndElsewhereFloats() {
        let centerDock = EditorToolbarLayout.frame(for: .docked(.topCenter), size: size, in: usable)
        let nearCenter = CGPoint(x: centerDock.midX + 20, y: centerDock.midY + 15)
        XCTAssertEqual(
            EditorToolbarLayout.placement(forDragEndingAt: nearCenter, size: size, in: usable),
            .docked(.topCenter)
        )

        let middle = CGPoint(x: 500, y: 400)
        guard case let .floating(fraction) = EditorToolbarLayout.placement(
            forDragEndingAt: middle, size: size, in: usable
        ) else { return XCTFail("expected floating") }
        XCTAssertEqual(fraction.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(fraction.y, (400 - 40) / 700, accuracy: 0.001)
    }

    func testDragOutsideBoundsFloatsAtTheClampedPosition() {
        guard case let .floating(fraction) = EditorToolbarLayout.placement(
            forDragEndingAt: CGPoint(x: 5000, y: 5000), size: size, in: usable
        ) else { return XCTFail("expected floating") }
        let frame = EditorToolbarLayout.frame(for: .floating(fraction), size: size, in: usable)
        XCTAssertTrue(usable.insetBy(dx: EditorToolbarLayout.margin - 0.001, dy: EditorToolbarLayout.margin - 0.001).contains(frame))
    }

    func testDegenerateBoundsNeverProduceNonFiniteFrames() {
        for bounds in [CGRect.zero, CGRect(x: 0, y: 0, width: 10, height: 10)] {
            for placement in [EditorToolbarPlacement.docked(.topCenter), .floating(CGPoint(x: 0.3, y: 0.7))] {
                let frame = EditorToolbarLayout.frame(for: placement, size: size, in: bounds)
                XCTAssertTrue(frame.origin.x.isFinite && frame.origin.y.isFinite)
            }
        }
    }

    func testDragsInBoundsWithoutAreaDockInsteadOfDividingByZero() {
        let farFromEveryDock = CGPoint(x: 900, y: 600)
        for bounds in [CGRect.zero, CGRect(x: 0, y: 40, width: 1000, height: 0), CGRect(x: 0, y: 40, width: 0, height: 700)] {
            XCTAssertEqual(
                EditorToolbarLayout.placement(forDragEndingAt: farFromEveryDock, size: size, in: bounds),
                .docked(.topCenter),
                "\(bounds)"
            )
        }
    }
}

final class EditorToolbarPreferencesTests: XCTestCase {
    private let customized = EditorToolbarPreferences(
        placement: .floating(CGPoint(x: 0.25, y: 0.75)), isCollapsed: true,
        customSwatches: [EditorInkColor(red: 0.2, green: 0.4, blue: 0.6)]
    )

    func testMissingOrCorruptDataFallsBackToTheStandardPreferences() {
        XCTAssertEqual(EditorToolbarPreferences.decode(nil), .standard)
        XCTAssertEqual(EditorToolbarPreferences.decode(Data("{".utf8)), .standard)
        XCTAssertEqual(EditorToolbarPreferences.decode(Data(#"{"version":99}"#.utf8)), .standard)
    }

    func testRoundTripsEveryPlacement() {
        let samples: [EditorToolbarPreferences] = [
            .standard,
            EditorToolbarPreferences(placement: .docked(.topTrailing), isCollapsed: false, customSwatches: []),
            EditorToolbarPreferences(
                placement: .floating(CGPoint(x: 0.25, y: 0.75)), isCollapsed: true,
                customSwatches: [EditorInkColor(red: 0.1, green: 0.2, blue: 0.3)]
            ),
        ]
        for sample in samples {
            XCTAssertEqual(EditorToolbarPreferences.decode(sample.encoded()), sample)
        }
    }

    func testSanitizesOutOfRangeValues() {
        let json = #"""
        {"version":1,"placement":{"floating":{"x":4,"y":-2}},"collapsed":true,
         "swatches":[[2,0,0,1],[0,0,0,1],[0,0,0,1],[0,0,0,1],[0,0,0,1],[0,0,0,1],[0,0,0,1],[0,0,0,1],[0,0,0,1],[0,0,0,1]]}
        """#
        let decoded = EditorToolbarPreferences.decode(Data(json.utf8))
        XCTAssertEqual(decoded.placement, .floating(CGPoint(x: 1, y: 0)))
        XCTAssertEqual(decoded.customSwatches.count, EditorToolbarPreferences.maximumCustomSwatches)
        XCTAssertEqual(decoded.customSwatches.first?.red, 1)
    }

    func testDockedToolbarsAreNeverRestoredCollapsed() {
        let json = #"{"version":1,"placement":{"dock":"topLeading"},"collapsed":true,"swatches":[]}"#
        let decoded = EditorToolbarPreferences.decode(Data(json.utf8))
        XCTAssertEqual(decoded.placement, .docked(.topLeading))
        XCTAssertFalse(decoded.isCollapsed, "only floating toolbars collapse, so a docked one must stay reachable")
    }

    func testNonNumericOrOverflowingFloatingPositionFallsBackToTheStandardDock() {
        for x in [#""nan""#, "1e999", "null"] {
            let json = #"{"version":1,"placement":{"floating":{"x":"# + x + #","y":0.5}},"collapsed":false,"swatches":[]}"#
            XCTAssertEqual(EditorToolbarPreferences.decode(Data(json.utf8)), .standard, x)
        }
    }

    func testNonFiniteFloatingPositionsAreReplacedByTheStandardDockSoTheyCanBeStored() {
        for point in [CGPoint(x: .nan, y: 0.5), CGPoint(x: 0.5, y: .infinity), CGPoint(x: -.infinity, y: .nan)] {
            let preferences = EditorToolbarPreferences(placement: .floating(point), isCollapsed: true, customSwatches: [])
            XCTAssertEqual(preferences.placement, EditorToolbarPreferences.standard.placement)
            XCTAssertFalse(preferences.isCollapsed, "the replacement dock never collapses")
            XCTAssertFalse(preferences.encoded().isEmpty)
            XCTAssertEqual(EditorToolbarPreferences.decode(preferences.encoded()), preferences)

            var placed = EditorToolbarPreferences.standard
            placed.place(.floating(point))
            XCTAssertEqual(placed.placement, EditorToolbarPreferences.standard.placement)
        }
    }

    func testFloatingPositionsAreClampedOnConstruction() {
        let preferences = EditorToolbarPreferences(placement: .floating(CGPoint(x: 3, y: -1)), isCollapsed: false, customSwatches: [])
        XCTAssertEqual(preferences.placement, .floating(CGPoint(x: 1, y: 0)))
    }

    func testMutationsKeepOnlyAFloatingToolbarCollapsed() {
        var preferences = EditorToolbarPreferences.standard
        preferences.setCollapsed(true)
        XCTAssertFalse(preferences.isCollapsed, "a docked toolbar stays expanded")

        preferences.place(.floating(CGPoint(x: 0.4, y: 0.6)))
        preferences.setCollapsed(true)
        XCTAssertTrue(preferences.isCollapsed)

        preferences.place(.floating(CGPoint(x: 0.2, y: 0.2)))
        XCTAssertFalse(preferences.isCollapsed, "moving the toolbar shows it in full")

        preferences.setCollapsed(true)
        preferences.place(.docked(.topLeading))
        XCTAssertEqual(preferences.placement, .docked(.topLeading))
        XCTAssertFalse(preferences.isCollapsed)
    }

    func testReadsPreferencesStoredByTheCurrentFormat() {
        let docks: [String: EditorToolbarDock] = ["topLeading": .topLeading, "topCenter": .topCenter, "topTrailing": .topTrailing]
        XCTAssertEqual(Set(docks.values), Set(EditorToolbarDock.allCases))
        for (name, dock) in docks {
            let json = #"{"version":1,"placement":{"dock":"\#(name)"},"collapsed":false,"swatches":[]}"#
            XCTAssertEqual(EditorToolbarPreferences.decode(Data(json.utf8)).placement, .docked(dock), name)
        }
        let floating = #"""
        {"version":1,"placement":{"floating":{"x":0.25,"y":0.75}},"collapsed":true,"swatches":[[0.2,0.4,0.6,1]]}
        """#
        let decoded = EditorToolbarPreferences.decode(Data(floating.utf8))
        XCTAssertEqual(decoded.placement, .floating(CGPoint(x: 0.25, y: 0.75)))
        XCTAssertTrue(decoded.isCollapsed)
        XCTAssertEqual(decoded.customSwatches, [EditorInkColor(red: 0.2, green: 0.4, blue: 0.6)])
    }

    func testStandardPreferencesUseFocusMode() {
        XCTAssertEqual(EditorToolbarPreferences.standard.chromeMode, .focus)
        XCTAssertEqual(customized.chromeMode, .focus)
    }

    func testRoundTripsEveryWritingMode() {
        for mode in EditorChromeMode.allCases {
            var preferences = customized
            preferences.setChromeMode(mode)
            let decoded = EditorToolbarPreferences.decode(preferences.encoded())
            XCTAssertEqual(decoded, preferences, mode.rawValue)
            XCTAssertEqual(decoded.chromeMode, mode)
        }
    }

    func testWritesTheWritingModeWithoutChangingTheVersion() throws {
        var preferences = customized
        preferences.setChromeMode(.overlay)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: preferences.encoded()) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["chromeMode"] as? String, "overlay")
    }

    func testReadsEveryStoredWritingMode() {
        let modes: [String: EditorChromeMode] = ["focus": .focus, "pinned": .pinned, "overlay": .overlay]
        XCTAssertEqual(Set(modes.values), Set(EditorChromeMode.allCases))
        for (name, mode) in modes {
            let json = #"{"version":1,"placement":{"dock":"topLeading"},"collapsed":false,"swatches":[],"chromeMode":"\#(name)"}"#
            XCTAssertEqual(EditorToolbarPreferences.decode(Data(json.utf8)).chromeMode, mode, name)
        }
    }

    func testPreferencesStoredBeforeWritingModesKeepTheirValuesInFocusMode() {
        let json = #"""
        {"version":1,"placement":{"floating":{"x":0.25,"y":0.75}},"collapsed":true,"swatches":[[0.2,0.4,0.6,1]]}
        """#
        XCTAssertEqual(EditorToolbarPreferences.decode(Data(json.utf8)), customized)
    }

    func testUnknownOrMisspelledWritingModeFallsBackToFocusKeepingTheRest() {
        for mode in [#""zen""#, #""""#, #""Pinned""#, "null"] {
            let json = #"""
            {"version":1,"placement":{"floating":{"x":0.25,"y":0.75}},"collapsed":true,"swatches":[[0.2,0.4,0.6,1]],"chromeMode":\#(mode)}
            """#
            XCTAssertEqual(EditorToolbarPreferences.decode(Data(json.utf8)), customized, mode)
        }
    }

    func testOtherVersionsAreNotReadEvenWithAKnownWritingMode() {
        for version in [0, 2] {
            let json = #"{"version":\#(version),"placement":{"dock":"topLeading"},"collapsed":false,"swatches":[],"chromeMode":"pinned"}"#
            XCTAssertEqual(EditorToolbarPreferences.decode(Data(json.utf8)), .standard, "\(version)")
        }
    }

    func testMovingOrCollapsingKeepsTheWritingModeAndChoosingAModeKeepsTheRest() {
        var preferences = customized
        preferences.setChromeMode(.pinned)
        XCTAssertEqual(preferences.placement, customized.placement)
        XCTAssertTrue(preferences.isCollapsed)
        XCTAssertEqual(preferences.customSwatches, customized.customSwatches)

        preferences.setCollapsed(false)
        preferences.place(.docked(.topTrailing))
        preferences.addCustomSwatch(EditorInkColor(red: 0.9, green: 0.1, blue: 0.5))
        XCTAssertEqual(preferences.chromeMode, .pinned)
    }
}

final class EditorCustomSwatchTests: XCTestCase {
    private func eightBit(_ red: Int, _ green: Int, _ blue: Int) -> EditorInkColor {
        EditorInkColor(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }

    func testQuantizingRoundsEveryChannelToEightBits() {
        let color = EditorInkColor(red: 0.500_001, green: 0.1, blue: 1, alpha: 0.333)
        XCTAssertEqual(color.quantized, EditorInkColor(red: 128.0 / 255, green: 26.0 / 255, blue: 1, alpha: 85.0 / 255))
        XCTAssertEqual(color.quantized.quantized, color.quantized)
    }

    func testAddingPutsTheQuantizedColourFirstAndCapsTheShelf() {
        var preferences = EditorToolbarPreferences.standard
        let colors = (0..<10).map { EditorInkColor(red: Double($0) / 10, green: 0.2, blue: 0.6) }
        for color in colors { preferences.addCustomSwatch(color) }

        XCTAssertEqual(preferences.customSwatches.count, EditorToolbarPreferences.maximumCustomSwatches)
        XCTAssertEqual(preferences.customSwatches, colors.reversed().prefix(8).map(\.quantized))
        XCTAssertNotEqual(preferences.customSwatches.first, colors.last, "the stored colour is the quantized one")
    }

    func testAddingAKnownColourMovesItToTheFrontWithoutRepeating() {
        var preferences = EditorToolbarPreferences.standard
        let colors = (1...8).map { eightBit($0 * 20, 40, 60) }
        for color in colors { preferences.addCustomSwatch(color) }

        let nearlyThird = EditorInkColor(red: colors[2].red + 0.000_1, green: colors[2].green, blue: colors[2].blue)
        preferences.addCustomSwatch(nearlyThird)
        XCTAssertEqual(preferences.customSwatches.first, colors[2])
        XCTAssertEqual(preferences.customSwatches.count, 8)
        XCTAssertEqual(Set(preferences.customSwatches).count, 8)
    }

    func testQuickSwatchesAreNeverAddedAsCustomColours() {
        var preferences = EditorToolbarPreferences.standard
        preferences.addCustomSwatch(eightBit(10, 20, 30))
        let before = preferences
        for swatch in EditorInkCatalog.swatches {
            preferences.addCustomSwatch(swatch)
            preferences.addCustomSwatch(swatch.quantized)
        }
        XCTAssertEqual(preferences, before)
    }

    func testAddedSwatchesSurviveStorageExactly() {
        var preferences = EditorToolbarPreferences.standard
        for color in (0..<8).map({ EditorInkColor(red: Double($0) / 7, green: 0.123_456, blue: 0.987_654) }) {
            preferences.addCustomSwatch(color)
        }
        XCTAssertEqual(EditorToolbarPreferences.decode(preferences.encoded()), preferences)
    }
}

final class EditorInkCatalogTests: XCTestCase {
    func testWidthStepsAreFractionsOfEachInkRange() {
        let range = 2.0...20.0
        let widths = EditorWidthStep.allCases.map { EditorInkCatalog.width(for: $0, in: range) }
        XCTAssertEqual(widths, widths.sorted())
        XCTAssertTrue(widths.allSatisfy { range.contains($0) })
        XCTAssertEqual(Set(widths).count, EditorWidthStep.allCases.count)
    }

    func testPresetsAndSwatchesAreDistinctAndOpaque() {
        XCTAssertEqual(Set(EditorInkCatalog.presets.map(\.id)).count, EditorInkCatalog.presets.count)
        XCTAssertGreaterThanOrEqual(EditorInkCatalog.presets.count, 4)
        XCTAssertEqual(Set(EditorInkCatalog.swatches).count, EditorInkCatalog.swatches.count)
        XCTAssertTrue(EditorInkCatalog.swatches.allSatisfy { $0.alpha == 1 })
    }

    func testEveryInkContrastsWithTheIvoryPaper() {
        let paper = EditorInkColor(red: 0.98, green: 0.96, blue: 0.91)
        for color in EditorInkCatalog.swatches + EditorInkCatalog.presets.map(\.color) {
            XCTAssertGreaterThanOrEqual(color.contrastRatio(against: paper), 3, "\(color) is too faint on paper")
        }
    }
}
