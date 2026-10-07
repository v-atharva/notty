import CoreGraphics
import Foundation
import XCTest
@testable import NottyCore

final class EditorToolbarLayoutTests: XCTestCase {
    private let usable = CGRect(x: 0, y: 40, width: 1000, height: 700)
    private let size = CGSize(width: 400, height: 96)
    private let vertical = CGSize(width: 152, height: 500)
    private var sizes: EditorToolbarLayout.DockSizes {
        EditorToolbarLayout.DockSizes(horizontal: size, vertical: vertical)
    }

    func testTheTopDockCentresAHorizontalToolbarBelowTheMargin() {
        let margin = EditorToolbarLayout.margin
        let center = EditorToolbarLayout.frame(for: .docked(.topCenter), size: size, in: usable)
        XCTAssertEqual(center.midX, usable.midX)
        XCTAssertEqual(center.minY, 40 + margin)
        XCTAssertEqual(EditorToolbarDock.topCenter.axis, .horizontal)
    }

    func testSideDocksStandAVerticalToolbarAgainstTheirEdgeCentredAlongIt() {
        let margin = EditorToolbarLayout.margin
        let left = EditorToolbarLayout.frame(for: .docked(.leftEdge), size: vertical, in: usable)
        let right = EditorToolbarLayout.frame(for: .docked(.rightEdge), size: vertical, in: usable)
        XCTAssertEqual(left.minX, usable.minX + margin)
        XCTAssertEqual(right.maxX, usable.maxX - margin)
        XCTAssertEqual(left.midY, usable.midY)
        XCTAssertEqual(right.midY, usable.midY)
        XCTAssertEqual(EditorToolbarDock.leftEdge.axis, .vertical)
        XCTAssertEqual(EditorToolbarDock.rightEdge.axis, .vertical)
        XCTAssertEqual(EditorToolbarPlacement.floating(CGPoint(x: 0.1, y: 0.5)).axis, .horizontal)

        let tall = EditorToolbarLayout.frame(for: .docked(.leftEdge), size: CGSize(width: 152, height: 900), in: usable)
        XCTAssertEqual(tall.minY, usable.minY + margin, "A toolbar taller than the bounds keeps its first tools reachable.")
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
            for: .docked(.topCenter), size: CGSize(width: 1200, height: 96), in: usable
        )
        XCTAssertEqual(wide.minX, usable.minX + EditorToolbarLayout.margin, "an oversized toolbar keeps its leading tools reachable")
    }

    func testADragEndingNearTheTopDockSnapsByItsTopCentre() {
        let top = EditorToolbarLayout.frame(for: .docked(.topCenter), size: size, in: usable)
        let middle = CGPoint(x: 500, y: 400)
        let near = top.offsetBy(dx: 30, dy: 20)
        XCTAssertEqual(placement(near, pointer: middle), .docked(.topCenter))
        XCTAssertNotEqual(placement(top.offsetBy(dx: 0, dy: 60), pointer: middle), .docked(.topCenter))

        let handle = CGRect(x: top.midX - 28 + 20, y: top.minY + 10, width: 56, height: 44)
        XCTAssertEqual(placement(handle, pointer: middle), .docked(.topCenter), "A small handle docks by its top centre too.")
    }

    /// A vertical rail's top lies near the top dock wherever it is dragged, so only the finger taken
    /// up to the top docks it there; dragged sideways into the page, even by a grip near its top,
    /// it floats.
    func testAVerticalToolbarDocksAtTheTopOnlyWhenTheFingerIsTakenThere() {
        let top = EditorToolbarLayout.frame(for: .docked(.topCenter), size: size, in: usable)
        let column = CGRect(x: top.midX - 76, y: top.minY, width: 152, height: 500)
        let up = EditorToolbarLayout.edgeApproachDistance
        let nearTop = CGPoint(x: 500, y: 60)
        let shortOfTop = CGPoint(x: 500, y: usable.minY + EditorToolbarLayout.edgeSnapDistance + 1)
        XCTAssertEqual(placement(column, pointer: nearTop, travel: CGSize(width: 340, height: -300)), .docked(.topCenter))
        XCTAssertEqual(placement(column, pointer: nearTop, travel: CGSize(width: 0, height: -up)), .docked(.topCenter))
        guard case .floating = placement(column, pointer: CGPoint(x: 500, y: 400), travel: CGSize(width: 340, height: 0)) else {
            return XCTFail("Dragged sideways into the page by its middle, a vertical rail floats.")
        }
        guard case .floating = placement(column, pointer: nearTop, travel: CGSize(width: 340, height: 1 - up)) else {
            return XCTFail("Held near its top and dragged sideways, a vertical rail floats.")
        }
        guard case .floating = placement(column, pointer: shortOfTop, travel: CGSize(width: 0, height: -300)) else {
            return XCTFail("A finger let go short of the top floats a vertical rail.")
        }
    }

    func testAFingerLetGoNearASideDocksThereWhateverTheToolbarsWidth() {
        let wide = CGRect(x: 14, y: 300, width: 970, height: 96)
        let left = CGSize(width: -200, height: 260)
        let right = CGSize(width: 200, height: 260)
        XCTAssertEqual(placement(wide, pointer: CGPoint(x: 30, y: 340), travel: left), .docked(.leftEdge))
        XCTAssertEqual(placement(wide, pointer: CGPoint(x: 990, y: 340), travel: right), .docked(.rightEdge))
        let edge = EditorToolbarLayout.edgeSnapDistance
        XCTAssertEqual(placement(wide, pointer: CGPoint(x: edge, y: 340), travel: left), .docked(.leftEdge))
        guard case .floating = placement(wide, pointer: CGPoint(x: edge + 1, y: 340), travel: left) else {
            return XCTFail("A finger let go clear of both sides floats the toolbar.")
        }
        guard case .floating = placement(wide, pointer: CGPoint(x: 30, y: 340), travel: left, sideDocks: false) else {
            return XCTFail("Without side docks the sides are not docks.")
        }
    }

    /// A wide rail's grip starts within reach of the left edge; dragged straight down into the page
    /// it floats, and docks at a side only once the finger has moved toward it.
    func testAFingerDocksAtASideOnlyAfterMovingTowardIt() {
        let wide = CGRect(x: 14, y: 300, width: 970, height: 96)
        let approach = EditorToolbarLayout.edgeApproachDistance
        let grip = CGPoint(x: 34, y: 340)
        for drift in [0, 8, approach - 1] {
            let pointer = CGPoint(x: grip.x - drift, y: grip.y)
            guard case .floating = placement(wide, pointer: pointer, travel: CGSize(width: -drift, height: 280)) else {
                return XCTFail("Dragged down with \(drift) pt of drift toward the left, the rail floats.")
            }
        }
        let pushed = CGPoint(x: grip.x - approach, y: grip.y)
        XCTAssertEqual(placement(wide, pointer: pushed, travel: CGSize(width: -approach, height: 280)), .docked(.leftEdge))

        let farRight = CGPoint(x: 990, y: 340)
        guard case .floating = placement(wide, pointer: farRight, travel: CGSize(width: -40, height: 280)) else {
            return XCTFail("A finger moving away from a side never docks there.")
        }
        XCTAssertEqual(placement(wide, pointer: farRight, travel: CGSize(width: approach, height: 280)), .docked(.rightEdge))
    }

    func testAVerticalToolbarStaysAtItsSideWhileItsEdgeStaysNear() {
        let left = EditorToolbarLayout.frame(for: .docked(.leftEdge), size: vertical, in: usable)
        let middle = CGPoint(x: 500, y: 400)
        XCTAssertEqual(placement(left.offsetBy(dx: 40, dy: 80), pointer: middle), .docked(.leftEdge))
        guard case .floating = placement(left.offsetBy(dx: 60, dy: 80), pointer: middle) else {
            return XCTFail("Dragged clear of its side, a vertical toolbar floats.")
        }
        let right = EditorToolbarLayout.frame(for: .docked(.rightEdge), size: vertical, in: usable)
        XCTAssertEqual(placement(right.offsetBy(dx: -50, dy: 0), pointer: middle), .docked(.rightEdge))

        let horizontal = CGRect(x: left.minX, y: 300, width: size.width, height: size.height)
        guard case .floating = placement(horizontal, pointer: middle) else {
            return XCTFail("Only a vertical toolbar stays docked by its edge; a horizontal one needs the finger.")
        }
    }

    func testADragEndingElsewhereFloatsAtItsClampedCentre() {
        let frame = CGRect(x: 300, y: 312, width: size.width, height: size.height)
        guard case let .floating(fraction) = placement(frame, pointer: CGPoint(x: 500, y: 360)) else {
            return XCTFail("expected floating")
        }
        XCTAssertEqual(fraction.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(fraction.y, (360 - 40) / 700, accuracy: 0.001)

        guard case let .floating(far) = placement(
            CGRect(x: 4800, y: 4800, width: size.width, height: size.height), pointer: CGPoint(x: 500, y: 5000)
        ) else { return XCTFail("expected floating") }
        let rest = EditorToolbarLayout.frame(for: .floating(far), size: size, in: usable)
        XCTAssertTrue(usable.insetBy(dx: EditorToolbarLayout.margin - 0.001, dy: EditorToolbarLayout.margin - 0.001).contains(rest))
    }

    /// A view standing for part of a floating toolbar, such as a collapsed handle over its first
    /// row, is placed off the toolbar's point and stores that point again when dragged.
    func testAnOffsetFrameRoundTripsThroughTheToolbarsFloatingPoint() {
        let handle = CGSize(width: 56, height: 44)
        let offset = CGSize(width: 0, height: -28)
        let placement = EditorToolbarPlacement.floating(CGPoint(x: 0.3, y: 0.6))
        let toolbar = EditorToolbarLayout.frame(for: placement, size: size, in: usable)
        let standIn = EditorToolbarLayout.frame(for: placement, size: handle, in: usable, centreOffset: offset)
        XCTAssertEqual(standIn.midX, toolbar.midX)
        XCTAssertEqual(standIn.midY, toolbar.midY - 28)
        XCTAssertEqual(
            EditorToolbarLayout.frame(for: .docked(.topCenter), size: size, in: usable, centreOffset: offset),
            EditorToolbarLayout.frame(for: .docked(.topCenter), size: size, in: usable),
            "A dock ignores the offset."
        )

        let dropped = standIn.offsetBy(dx: 120, dy: 90)
        let resting = EditorToolbarLayout.placement(
            forDragEnding: dropped, finger: nil, dockSizes: sizes, in: usable, centreOffset: offset
        )
        guard case let .floating(point) = resting else { return XCTFail("expected floating") }
        XCTAssertEqual(point.x, (dropped.midX - usable.minX) / usable.width, accuracy: 0.0001)
        XCTAssertEqual(point.y, (dropped.midY + 28 - usable.minY) / usable.height, accuracy: 0.0001)
        let again = EditorToolbarLayout.frame(for: resting, size: handle, in: usable, centreOffset: offset)
        XCTAssertEqual(again.origin.x, dropped.origin.x, accuracy: 0.0001)
        XCTAssertEqual(again.origin.y, dropped.origin.y, accuracy: 0.0001)

        let top = EditorToolbarLayout.frame(for: .floating(CGPoint(x: 0.5, y: 0)), size: handle, in: usable, centreOffset: offset)
        XCTAssertEqual(top.minY, usable.minY + EditorToolbarLayout.margin, "The view stays inside the margins at its own size.")
    }

    func testDegenerateBoundsNeverProduceNonFiniteFrames() {
        for bounds in [CGRect.zero, CGRect(x: 0, y: 0, width: 10, height: 10)] {
            for placement in [
                EditorToolbarPlacement.docked(.topCenter), .docked(.leftEdge), .docked(.rightEdge),
                .floating(CGPoint(x: 0.3, y: 0.7)),
            ] {
                let frame = EditorToolbarLayout.frame(for: placement, size: size, in: bounds)
                XCTAssertTrue(frame.origin.x.isFinite && frame.origin.y.isFinite)
            }
        }
    }

    func testDragsInBoundsWithoutAreaDockInsteadOfDividingByZero() {
        let far = CGRect(x: 700, y: 560, width: size.width, height: size.height)
        for bounds in [CGRect.zero, CGRect(x: 0, y: 40, width: 1000, height: 0), CGRect(x: 0, y: 40, width: 0, height: 700)] {
            XCTAssertEqual(
                EditorToolbarLayout.placement(
                    forDragEnding: far,
                    finger: EditorToolbarDragFinger(
                        location: CGPoint(x: CGFloat.nan, y: .nan), travel: CGSize(width: CGFloat.nan, height: .nan)
                    ),
                    dockSizes: sizes, in: bounds
                ),
                .docked(.topCenter),
                "\(bounds)"
            )
        }
    }

    private func placement(
        _ frame: CGRect, pointer: CGPoint, travel: CGSize = .zero, sideDocks: Bool = true
    ) -> EditorToolbarPlacement {
        EditorToolbarLayout.placement(
            forDragEnding: frame, finger: EditorToolbarDragFinger(location: pointer, travel: travel), dockSizes: sizes,
            in: usable, sideDocks: sideDocks
        )
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
            EditorToolbarPreferences(placement: .docked(.rightEdge), isCollapsed: false, customSwatches: []),
            EditorToolbarPreferences(placement: .docked(.leftEdge), isCollapsed: false, customSwatches: []),
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
        XCTAssertEqual(decoded.placement, .docked(.leftEdge))
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
        preferences.place(.docked(.leftEdge))
        XCTAssertEqual(preferences.placement, .docked(.leftEdge))
        XCTAssertFalse(preferences.isCollapsed)
    }

    func testReadsPreferencesStoredByTheCurrentFormat() {
        let docks: [String: EditorToolbarDock] = ["topLeading": .leftEdge, "topCenter": .topCenter, "topTrailing": .rightEdge]
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

    func testTopLeftAndTopRightDocksStoredEarlierMoveToTheirSideKeepingEverythingElse() throws {
        for (stored, dock) in [("topLeading", EditorToolbarDock.leftEdge), ("topTrailing", .rightEdge)] {
            let json = #"""
            {"version":1,"placement":{"dock":"\#(stored)"},"collapsed":false,"swatches":[[0.2,0.4,0.6,1]],"chromeMode":"pinned"}
            """#
            let decoded = EditorToolbarPreferences.decode(Data(json.utf8))
            XCTAssertEqual(decoded.placement, .docked(dock), stored)
            XCTAssertEqual(decoded.customSwatches, [EditorInkColor(red: 0.2, green: 0.4, blue: 0.6)], stored)
            XCTAssertEqual(decoded.chromeMode, .pinned, stored)

            let rewritten = try XCTUnwrap(JSONSerialization.jsonObject(with: decoded.encoded()) as? [String: Any])
            let placement = try XCTUnwrap(rewritten["placement"] as? [String: Any])
            XCTAssertEqual(placement["dock"] as? String, stored, "Stored again under the same name.")
            XCTAssertEqual(rewritten["version"] as? Int, 1)
        }
    }

    /// Builds from before the side docks read only these dock names, and on any other reset the
    /// whole of the preferences to the standard ones, so a side dock written under a new name would
    /// cost the custom colours and writing mode the next time such a build saved.
    func testEveryDockIsStoredUnderANameBuildsFromBeforeTheSideDocksRead() throws {
        let earlierNames: Set = ["topLeading", "topCenter", "topTrailing"]
        for dock in EditorToolbarDock.allCases {
            XCTAssertTrue(earlierNames.contains(dock.rawValue), "\(dock) is stored as \(dock.rawValue)")
            let preferences = EditorToolbarPreferences(
                placement: .docked(dock), isCollapsed: false, customSwatches: [EditorInkColor(red: 0.2, green: 0.4, blue: 0.6)],
                chromeMode: .pinned
            )
            let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: preferences.encoded()) as? [String: Any])
            let placement = try XCTUnwrap(stored["placement"] as? [String: Any])
            XCTAssertEqual(placement["dock"] as? String, dock.rawValue)
            XCTAssertEqual(stored["version"] as? Int, 1, "Earlier builds read only version 1.")
        }
    }

    func testAnUnknownPlacementFallsBackToTheStandardDockKeepingColoursAndMode() {
        for placement in [#"{"dock":"bottomCenter"}"#, #"{"dock":""}"#, "{}"] {
            let json = #"""
            {"version":1,"placement":\#(placement),"collapsed":true,"swatches":[[0.2,0.4,0.6,1]],"chromeMode":"overlay"}
            """#
            let decoded = EditorToolbarPreferences.decode(Data(json.utf8))
            XCTAssertEqual(decoded.placement, EditorToolbarPreferences.standard.placement, placement)
            XCTAssertFalse(decoded.isCollapsed, placement)
            XCTAssertEqual(decoded.customSwatches, [EditorInkColor(red: 0.2, green: 0.4, blue: 0.6)], placement)
            XCTAssertEqual(decoded.chromeMode, .overlay, placement)
        }
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
        preferences.place(.docked(.rightEdge))
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
