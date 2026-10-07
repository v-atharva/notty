import NottyCore
import PencilKit
import SwiftUI
import UIKit
import XCTest
@testable import Notty

@MainActor
final class NotebookToolbarHostTests: XCTestCase {
    private static let windowFrame = CGRect(x: 0, y: 0, width: 1_024, height: 1_366)

    // MARK: - Dragging

    func testDropUsesTheClampedPreviewSoTheShownDockIsWhereTheToolbarLands() {
        let usable = CGRect(x: 0, y: 0, width: 1_024, height: 1_200)
        let size = CGSize(width: 640, height: 112)
        let resolver = NotebookToolbarDragResolver(
            placement: .floating(CGPoint(x: 0.5, y: 0.5)), size: size, usable: usable
        )
        // The finger leaves the canvas over the navigation bar; the preview stays pinned on the top row.
        let pastTheTop = CGSize(width: 0, height: -2_000)
        let preview = resolver.previewFrame(translation: pastTheTop)
        XCTAssertEqual(preview.minY, usable.minY)
        XCTAssertEqual(resolver.targetedDock(translation: pastTheTop), .topCenter)
        XCTAssertEqual(resolver.placement(translation: pastTheTop), .docked(.topCenter))

        // Pinned in the corner, the rail is pushed to the right edge by the finger.
        let pastTheTrailingCorner = CGSize(width: 3_000, height: -2_000)
        let atTheEdge = CGPoint(x: usable.maxX - 4, y: 30)
        XCTAssertEqual(resolver.targetedDock(translation: pastTheTrailingCorner, pointer: atTheEdge), .rightEdge)
        XCTAssertEqual(resolver.placement(translation: pastTheTrailingCorner, pointer: atTheEdge), .docked(.rightEdge))

        let session = NotebookToolbarDragSession()
        let actions = NotebookToolbarActions(store: NotebookTestFixtures.toolStore())
        session.move(to: pastTheTop, resolver: resolver, actions: actions)
        XCTAssertEqual(session.previewFrame, preview)
        XCTAssertEqual(session.targetedDock, .topCenter, "The highlighted slot matches the release result.")
    }

    func testSnapFeedbackPlaysOnlyWhenTheDockChanges() {
        let usable = CGRect(x: 0, y: 0, width: 1_024, height: 1_200)
        let size = CGSize(width: 640, height: 112)
        let docked = NotebookToolbarDragResolver(placement: .docked(.topCenter), size: size, usable: usable)
        XCTAssertFalse(docked.snapsToNewDock(.docked(.topCenter)), "Dropped back on its own dock.")
        XCTAssertTrue(docked.snapsToNewDock(.docked(.leftEdge)))
        XCTAssertFalse(docked.snapsToNewDock(.floating(CGPoint(x: 0.5, y: 0.5))))
        XCTAssertFalse(docked.snapsToNewDock(docked.placement(translation: CGSize(width: 10, height: 6))))

        let floating = NotebookToolbarDragResolver(placement: .floating(CGPoint(x: 0.5, y: 0.5)), size: size, usable: usable)
        XCTAssertTrue(floating.snapsToNewDock(.docked(.topCenter)))
        XCTAssertFalse(floating.snapsToNewDock(.floating(CGPoint(x: 0.2, y: 0.5))))
    }

    /// A collapsed handle docks at the top anywhere along the top marker, and at a side wherever
    /// the finger lets go on that side's marker; between the markers it floats.
    func testCollapsedHandleDroppedOnADockMarkerDocksThere() throws {
        let usable = CGRect(x: 0, y: 0, width: 1_366, height: 950)
        let composition = NotebookToolbarComposition(preferences: .standard, horizontalSizeClass: .regular)
        let sizes = composition.dockSizes(in: usable.size)
        let handle = NotebookTheme.collapsedHandleSize
        let resolver = NotebookToolbarDragResolver(
            placement: .floating(CGPoint(x: 0.5, y: 0.6)), size: handle, dockSizes: sizes, usable: usable
        )
        let markers = NotebookDockMarkers.frames(dockSizes: sizes, in: usable, sideDocks: true)
        let top = try XCTUnwrap(markers[.topCenter])
        for centreX in [top.minX + handle.width / 2, top.midX, top.maxX - handle.width / 2] {
            let translation = CGSize(width: centreX - resolver.startFrame.midX, height: top.minY - resolver.startFrame.minY)
            XCTAssertEqual(resolver.targetedDock(translation: translation), .topCenter, "\(centreX)")
            XCTAssertEqual(resolver.placement(translation: translation), .docked(.topCenter), "\(centreX)")
        }
        for dock in [EditorToolbarDock.leftEdge, .rightEdge] {
            let marker = try XCTUnwrap(markers[dock])
            for pointer in [CGPoint(x: marker.minX, y: marker.minY + 1), CGPoint(x: marker.midX, y: marker.midY),
                            CGPoint(x: marker.maxX, y: marker.maxY - 1)] {
                let translation = CGSize(width: pointer.x - resolver.startFrame.midX, height: pointer.y - resolver.startFrame.midY)
                XCTAssertEqual(resolver.targetedDock(translation: translation, pointer: pointer), dock, "\(dock) \(pointer)")
                XCTAssertEqual(resolver.placement(translation: translation, pointer: pointer), .docked(dock), "\(dock) \(pointer)")
            }
        }
        let between = CGPoint(x: usable.midX, y: usable.midY)
        let away = CGSize(width: between.x - resolver.startFrame.midX, height: between.y - resolver.startFrame.midY)
        XCTAssertNil(resolver.targetedDock(translation: away, pointer: between), "Away from the markers the handle floats.")
    }

    /// A side marker runs down the edge inside the margins, beyond the frame the rail takes on end,
    /// since a finger brought that near the edge docks the rail there at any height. Where the top
    /// rail spans the window, as in portrait, the strip starts below the top dock's frame, where a
    /// rail held near the top lands instead; in landscape the top rail clears the edges.
    func testASideMarkerRunsDownTheEdgeAFingerDocksTheRailAlong() throws {
        let composition = NotebookToolbarComposition(preferences: .standard, horizontalSizeClass: .regular)
        let margin = EditorToolbarLayout.margin
        for usable in [CGRect(x: 0, y: 0, width: 834, height: 1_104), CGRect(x: 0, y: 0, width: 1_210, height: 690)] {
            let sizes = composition.dockSizes(in: usable.size)
            let markers = NotebookDockMarkers.frames(dockSizes: sizes, in: usable, sideDocks: true)
            let resolver = NotebookToolbarDragResolver(
                placement: .docked(.topCenter), size: sizes.horizontal, dockSizes: sizes, usable: usable
            )
            let top = resolver.startFrame
            let spansTheWindow = top.width > usable.width - 2 * EditorToolbarLayout.edgeSnapDistance
            XCTAssertEqual(spansTheWindow, usable.width < usable.height, "\(usable.size)")
            let grip = CGPoint(x: top.minX + 22, y: top.midY)
            for dock in [EditorToolbarDock.leftEdge, .rightEdge] {
                let label = "\(usable.size) \(dock)"
                let marker = try XCTUnwrap(markers[dock])
                let slot = EditorToolbarLayout.frame(for: .docked(dock), size: sizes.vertical, in: usable)
                XCTAssertEqual(marker.minY, spansTheWindow ? top.maxY + margin : usable.minY + margin, label)
                XCTAssertEqual(marker.maxY, usable.maxY - margin, label)
                XCTAssertFalse(marker.intersects(top), "\(label): it never crosses the top dock's frame.")
                XCTAssertGreaterThanOrEqual(marker.maxY, slot.maxY, "\(label): it runs to the foot of the rail's frame or past it.")
                // By the screen edge, since the grip may start within reach of the left one and must still head there.
                let x = dock == .leftEdge ? marker.minX + 2 : marker.maxX - 2
                for pointer in [CGPoint(x: x, y: marker.minY + 1), CGPoint(x: x, y: marker.maxY - 1)] {
                    let translation = CGSize(width: pointer.x - grip.x, height: pointer.y - grip.y)
                    XCTAssertEqual(resolver.targetedDock(translation: translation, pointer: pointer), dock, "\(label) \(pointer)")
                    XCTAssertEqual(
                        resolver.placement(translation: translation, pointer: pointer), .docked(dock), "\(label) \(pointer)"
                    )
                }
            }
        }
    }

    /// A rail on end stays at its side when dropped near it, and docks at the top when the finger
    /// takes it up there; the dock it lands in is lit, and a drop in place plays no snap.
    func testAVerticalRailMovesBetweenItsSideAndTheTop() {
        let usable = CGRect(x: 0, y: 0, width: 834, height: 1_104)
        var preferences = EditorToolbarPreferences.standard
        preferences.place(.docked(.leftEdge))
        let composition = NotebookToolbarComposition(preferences: preferences, horizontalSizeClass: .regular)
        let sizes = composition.dockSizes(in: usable.size)
        let rail = composition.rail(in: usable.size)
        XCTAssertEqual(rail.size, sizes.vertical)
        let resolver = NotebookToolbarDragResolver(
            placement: preferences.placement, size: rail.size, dockSizes: sizes, usable: usable
        )
        XCTAssertEqual(resolver.startFrame, composition.frame(in: usable))
        let inPlace = CGSize(width: 20, height: 60)
        let placement = resolver.placement(translation: inPlace, pointer: CGPoint(x: 120, y: 500))
        XCTAssertEqual(placement, .docked(.leftEdge))
        XCTAssertFalse(resolver.snapsToNewDock(placement))

        let top = EditorToolbarLayout.frame(for: .docked(.topCenter), size: sizes.horizontal, in: usable)
        let grip = CGPoint(x: resolver.startFrame.minX + 22, y: resolver.startFrame.midY)
        let atTheTop = CGPoint(x: top.midX, y: 30)
        let toTheTop = CGSize(width: atTheTop.x - grip.x, height: atTheTop.y - grip.y)
        XCTAssertEqual(resolver.targetedDock(translation: toTheTop, pointer: atTheTop), .topCenter)
        let docked = resolver.placement(translation: toTheTop, pointer: atTheTop)
        XCTAssertEqual(docked, .docked(.topCenter))
        XCTAssertTrue(resolver.snapsToNewDock(docked))

        let intoThePage = CGSize(width: 300, height: 0)
        guard case .floating = resolver.placement(translation: intoThePage, pointer: CGPoint(x: 420, y: 500)) else {
            return XCTFail("Dragged into the page, a rail on end floats and lies in rows again.")
        }
    }

    /// In landscape a rail on end fills the height, so its top lies by the top dock's wherever it is
    /// dragged. Taken sideways into the middle of the page by its grip, it floats; only the finger
    /// taken up to the top docks it there.
    func testARailOnEndDraggedIntoTheMiddleInLandscapeFloats() {
        let usable = CGRect(x: 0, y: 0, width: 1_210, height: 690)
        var preferences = EditorToolbarPreferences.standard
        preferences.place(.docked(.rightEdge))
        let composition = NotebookToolbarComposition(preferences: preferences, horizontalSizeClass: .regular)
        let sizes = composition.dockSizes(in: usable.size)
        let resolver = NotebookToolbarDragResolver(
            placement: preferences.placement, size: sizes.vertical, dockSizes: sizes, usable: usable
        )
        let top = EditorToolbarLayout.frame(for: .docked(.topCenter), size: sizes.horizontal, in: usable)
        XCTAssertLessThan(
            abs(resolver.startFrame.minY - top.minY), EditorToolbarLayout.snapDistance, "Its top lies by the top dock's."
        )
        let grip = CGPoint(x: resolver.startFrame.maxX - 22, y: resolver.startFrame.midY)
        let sideways = CGSize(width: usable.midX - resolver.startFrame.midX, height: 0)
        let middle = CGPoint(x: grip.x + sideways.width, y: grip.y)
        XCTAssertEqual(resolver.previewFrame(translation: sideways).midX, top.midX, accuracy: 0.001)
        XCTAssertNil(resolver.targetedDock(translation: sideways, pointer: middle))
        guard case .floating = resolver.placement(translation: sideways, pointer: middle) else {
            return XCTFail("Dragged sideways into the middle, a rail on end floats.")
        }
        let atTheTop = CGPoint(x: middle.x, y: 20)
        XCTAssertEqual(
            resolver.placement(translation: CGSize(width: sideways.width, height: atTheTop.y - grip.y), pointer: atTheTop),
            .docked(.topCenter)
        )
    }

    /// While dragging, every dock shows its marker; the targeted side's strip fills in and the frame
    /// the rail takes on end is outlined solid.
    func testDragOutlinesTheSideFrameTheRailLandsIn() throws {
        let usable = CGRect(x: 0, y: 0, width: 834, height: 700)
        let composition = NotebookToolbarComposition(preferences: .standard, horizontalSizeClass: .regular)
        let sizes = composition.dockSizes(in: usable.size)
        let drag = NotebookToolbarDragSession()
        let resolver = NotebookToolbarDragResolver(
            placement: .docked(.topCenter), size: sizes.horizontal, dockSizes: sizes, usable: usable
        )
        drag.move(
            to: CGSize(width: -20, height: 300), pointer: CGPoint(x: 20, y: 360), resolver: resolver,
            actions: NotebookToolbarActions(store: NotebookTestFixtures.toolStore())
        )
        XCTAssertEqual(drag.targetedDock, .leftEdge)
        let pixels = try RenderedPixels(rendering:
            NotebookDockTargets(drag: drag, dockSizes: sizes, usable: usable, sideDocks: true)
                .frame(width: usable.width, height: usable.height)
        )
        let markers = NotebookDockMarkers.frames(dockSizes: sizes, in: usable, sideDocks: true)
        let left = try XCTUnwrap(markers[.leftEdge])
        let right = try XCTUnwrap(markers[.rightEdge])
        let slot = EditorToolbarLayout.frame(for: .docked(.leftEdge), size: sizes.vertical, in: usable)
        XCTAssertGreaterThan(
            pixels.rgba(at: CGPoint(x: left.midX, y: left.midY))[3], pixels.rgba(at: CGPoint(x: right.midX, y: right.midY))[3],
            "The targeted side fills in more than the other."
        )
        let edge = stride(from: slot.midY - 60, through: slot.midY + 60, by: 1).map {
            pixels.rgba(at: CGPoint(x: slot.maxX - 1, y: $0))
        }
        XCTAssertGreaterThan(edge.map { Int($0[3]) }.min() ?? 0, 60, "The landing frame's edge is drawn")
        XCTAssertLessThan(
            (edge.map { Int($0[3]) }.max() ?? 0) - (edge.map { Int($0[3]) }.min() ?? 0), 8, "and solid."
        )
        XCTAssertEqual(pixels.rgba(at: CGPoint(x: slot.maxX + 20, y: slot.midY))[3], 0, "Nothing is drawn beyond it.")
    }

    func testDockTargetsTurnOpaqueAndSolidForAccessibilitySettings() throws {
        let environment = EnvironmentValues()
        let standard = UITraitCollection(accessibilityContrast: .normal)
        func components(_ color: UIColor) -> [CGFloat] {
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            color.resolvedColor(with: standard).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return [red, green, blue, alpha]
        }
        let well = components(NotebookTheme.selectedWell.uiColor)
        let paper = components(NotebookTheme.paperIvory.uiColor)
        let fills: [(NotebookDockTarget.Fill, Double, NotebookTheme.Tone)] = [
            (.idle, NotebookTheme.dockSlotFillOpacity, NotebookTheme.dockSlotOpaqueFill),
            (.targeted, NotebookTheme.dockSlotTargetedFillOpacity, NotebookTheme.dockSlotTargetedOpaqueFill),
            (.landing, NotebookTheme.dockSlotLandingFillOpacity, NotebookTheme.dockSlotLandingOpaqueFill),
        ]
        for (fill, opacity, opaque) in fills {
            let translucent = NotebookDockTarget.tone(for: fill, reduceTransparency: false).resolve(in: environment)
            XCTAssertEqual(Double(translucent.opacity), opacity, accuracy: 0.001, "\(fill)")
            let solid = NotebookDockTarget.tone(for: fill, reduceTransparency: true).resolve(in: environment)
            XCTAssertEqual(solid.opacity, 1, "\(fill) is opaque under Reduce Transparency.")
            XCTAssertEqual(solid, opaque.color.resolve(in: environment), "\(fill)")
            // The opaque tone is the translucent well composited over the paper in advance.
            let composited = (0..<3).map { well[$0] * opacity + paper[$0] * (1 - opacity) }
            for (expected, actual) in zip(composited, components(opaque.uiColor).prefix(3)) {
                XCTAssertEqual(actual, expected, accuracy: 0.002, "\(fill)")
            }
        }

        let marker = NotebookDockTarget.outline(isLanding: false, contrast: .standard)
        XCTAssertEqual(marker.style, StrokeStyle(lineWidth: 1.5, dash: [6, 4]), "Markers are dashed.")
        XCTAssertEqual(Double(marker.color.resolve(in: environment).opacity), 0.6, accuracy: 0.001)
        let landing = NotebookDockTarget.outline(isLanding: true, contrast: .standard)
        XCTAssertEqual(landing.style, StrokeStyle(lineWidth: 2), "The landing frame is solid.")
        for isLanding in [false, true] {
            let increased = NotebookDockTarget.outline(isLanding: isLanding, contrast: .increased)
            XCTAssertEqual(increased.style, StrokeStyle(lineWidth: 2), "Increase Contrast draws every outline solid.")
            XCTAssertEqual(increased.color.resolve(in: environment).opacity, 1, "and at full strength.")
        }
    }

    func testDragFramesMoveTheToolbarWithoutRebuildingIt() async throws {
        let usable = CGRect(x: 0, y: 0, width: 800, height: 600)
        let resolver = NotebookToolbarDragResolver(
            placement: .floating(CGPoint(x: 0.5, y: 0.5)), size: CGSize(width: 200, height: 60), usable: usable
        )
        let session = NotebookToolbarDragSession()
        let actions = NotebookToolbarActions(store: NotebookTestFixtures.toolStore())
        let counter = BodyCounter()
        // A closure property, like the toolbar's own, must not make the content compare as changed.
        let content = CountedContent(counter: counter, action: { _ = counter })
            .modifier(NotebookToolbarDragPosition(drag: session, restingFrame: resolver.startFrame))
        let hosting = AppearanceTrackingHostingController(
            rootView: ZStack(alignment: .topLeading) { content }.frame(width: usable.width, height: usable.height)
        )
        hosting.safeAreaRegions = []
        let window = UIWindow(windowScene: try NotebookTestFixtures.windowScene())
        try await show(hosting, in: window)
        defer { close(window) }
        try await settle(hosting.view)
        let bodies = counter.bodies
        XCTAssertGreaterThan(bodies, 0)
        let resting = counter.view.convert(counter.view.bounds, to: hosting.view)
        XCTAssertEqual(resting.size, resolver.startFrame.size)

        for step in 1...10 {
            let translation = CGSize(width: CGFloat(step) * -12, height: CGFloat(step) * 7)
            session.move(to: translation, resolver: resolver, actions: actions)
            hosting.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(5))
            hosting.view.layoutIfNeeded()
            let shown = counter.view.convert(counter.view.bounds, to: hosting.view)
            let preview = resolver.previewFrame(translation: translation)
            XCTAssertEqual(shown.minX - resting.minX, preview.minX - resolver.startFrame.minX, accuracy: 0.5)
            XCTAssertEqual(shown.minY - resting.minY, preview.minY - resolver.startFrame.minY, accuracy: 0.5)
        }
        XCTAssertEqual(counter.bodies, bodies, "Drag frames reposition the toolbar without evaluating it again.")
    }

    func testFloatingToolbarReservesScrollSpaceOnlyAgainstTheEdgeItCrowds() {
        let area = CGRect(x: 0, y: 100, width: 1_000, height: 1_000)
        let size = CGSize(width: 600, height: 112)
        func toolbar(minY: CGFloat) -> CGRect { CGRect(origin: CGPoint(x: 200, y: minY), size: size) }

        let atTheBottom = toolbar(minY: area.maxY - 12 - size.height)
        XCTAssertEqual(
            NotebookToolbarObstruction.insets(toolbar: atTheBottom, area: area),
            UIEdgeInsets(top: 0, left: 0, bottom: area.maxY - atTheBottom.minY, right: 0)
        )
        let atTheTop = toolbar(minY: area.minY + 12)
        XCTAssertEqual(
            NotebookToolbarObstruction.insets(toolbar: atTheTop, area: area),
            UIEdgeInsets(top: atTheTop.maxY - area.minY, left: 0, bottom: 0, right: 0)
        )
        let quarterDown = toolbar(minY: area.minY + area.height / 4 - size.height / 2)
        XCTAssertEqual(
            NotebookToolbarObstruction.insets(toolbar: quarterDown, area: area), .zero,
            "The default floating position leaves the page where it opens."
        )
        XCTAssertEqual(
            NotebookToolbarObstruction.insets(toolbar: toolbar(minY: area.minY + size.height), area: area),
            .zero
        )
        let handle = CGRect(origin: CGPoint(x: 20, y: area.maxY - 12 - 44), size: NotebookTheme.collapsedHandleSize)
        XCTAssertEqual(
            NotebookToolbarObstruction.insets(toolbar: handle, area: area).bottom,
            area.maxY - handle.minY, "A collapsed handle at the edge reserves its own height."
        )
        XCTAssertEqual(
            NotebookToolbarObstruction.insets(toolbar: toolbar(minY: 2_000), area: area), .zero
        )
    }

    /// A host given the scene's store draws the rail in the same pass as its canvas. One left to find
    /// the scene's store itself can do so only a turn after it first shows, so its rail arrives late;
    /// the notebook screen therefore resolves the store while the notebook opens and hands it over.
    func testAHostGivenTheScenesStoreDrawsTheRailInItsFirstPass() async throws {
        let scene = try NotebookTestFixtures.windowScene()
        let owner = preserveSceneStore(for: scene)
        owner.updateToolbar(.standard)
        func strips(in view: UIView) -> [UIScrollView] {
            let own = (view as? UIScrollView).map { [$0] } ?? []
            return own + view.subviews.flatMap(strips)
        }
        for handsOverStore in [true, false] {
            let hosting = AppearanceTrackingHostingController(
                rootView: NotebookToolbarHost(store: handsOverStore ? owner : nil) { Color.clear }
            )
            let window = UIWindow(windowScene: scene)
            window.frame = Self.windowFrame
            window.rootViewController = hosting
            window.makeKeyAndVisible()
            defer { close(window) }
            hosting.view.layoutIfNeeded()
            XCTAssertEqual(strips(in: hosting.view).isEmpty, !handsOverStore, "In the first pass")
            try await NotebookTestFixtures.waitUntilAppeared(hosting)
            try await NotebookTestFixtures.waitUntil { strips(in: hosting.view).count == 2 }
        }
    }

    func testExpandedCanvasReservesHeaderAndHomeIndicatorApartFromTheToolbar() {
        let canvas = CGSize(width: 500, height: 900)
        // The control area in the canvas's own coordinates, below the header and above the home indicator.
        let controls = CGRect(x: 0, y: 96, width: 500, height: 784)
        let chrome = NotebookCanvasChrome(canvasSize: canvas, controlArea: controls)
        XCTAssertEqual(chrome, NotebookCanvasChrome(top: 96, bottom: 20, canvasSize: canvas))
        XCTAssertEqual(NotebookCanvasChrome(canvasSize: canvas, controlArea: nil), .none)
        XCTAssertEqual(NotebookCanvasChrome(canvasSize: .zero, controlArea: controls), .none)
        // A header reaching past where the toolbar's area begins stays covered however little the
        // toolbar takes.
        XCTAssertEqual(
            chrome.reserving(top: 62, atLeast: 66),
            NotebookCanvasChrome(top: 158, bottom: 20, canvasSize: canvas, coveredTop: 162)
        )
        XCTAssertEqual(NotebookCanvasChrome.none.reserving(top: 62, atLeast: 66), .none)

        let usable = CGRect(origin: .zero, size: controls.size)
        let compact = CGRect(x: 12, y: 12, width: 450, height: 52)
        let docked = NotebookToolbarObstruction.Measurement(toolbar: compact, area: usable)
        XCTAssertEqual(docked.insets, UIEdgeInsets(top: 64, left: 0, bottom: 0, right: 0))
        XCTAssertEqual(docked.area, usable.size)
        XCTAssertEqual(chrome.top + docked.insets.top, 160, "A canvas under the toolbar reserves the header and the toolbar.")
        let floating = NotebookToolbarObstruction.Measurement(toolbar: compact.offsetBy(dx: 0, dy: 300), area: usable)
        XCTAssertEqual(floating.insets, .zero, "A toolbar clear of both ends leaves only the chrome.")
        let resized = NotebookToolbarObstruction.Measurement(
            toolbar: compact, area: CGRect(origin: .zero, size: CGSize(width: 700, height: 600))
        )
        XCTAssertEqual(resized.insets, docked.insets)
        XCTAssertNotEqual(resized, docked, "A resize is a new measurement even when the toolbar keeps its insets.")
    }

    // MARK: - Overlay and canvas

    func testFloatingRestoreLaysTheContentOutOnceWhileTheSceneStoreResolves() async throws {
        let scene = try NotebookTestFixtures.windowScene()
        let owner = preserveSceneStore(for: scene)
        var floating = owner.toolbar
        floating.place(.floating(CGPoint(x: 0.5, y: 0.5)))
        owner.updateToolbar(floating)

        let probe = LayoutProbeView()
        let window = UIWindow(windowScene: scene)
        let hosting = AppearanceTrackingHostingController(rootView: NotebookToolbarHost { LayoutProbe(view: probe) })
        hosting.safeAreaRegions = []
        try await show(hosting, in: window)
        defer { close(window) }

        let host = hosting.view!
        let tools = firstRowCentre(for: owner.toolbar, in: host.bounds)
        try await NotebookTestFixtures.waitUntil {
            probe.window != nil && !NotebookTestFixtures.hit(tools, in: host).isDescendant(of: probe)
        }
        try await settle(host)

        XCTAssertEqual(probe.laidOutSizes, [host.bounds.size], "Restoring the toolbar never reserves space outside the canvas.")
    }

    func testPlacementChangesDuringAStrokeKeepTheViewportStable() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost()
        defer { fixture.close() }
        let store = fixture.store
        let canvas = fixture.controller.canvasView
        let host = fixture.hosting.view!
        let actions = NotebookToolbarActions(store: store)
        XCTAssertEqual(canvas.bounds.height, host.bounds.height, accuracy: 0.5)

        fixture.controller.canvasViewDidBeginUsingTool(canvas)
        XCTAssertTrue(fixture.controller.currentUndoAvailability.isUsingTool)
        let bounds = canvas.bounds
        let frame = fixture.canvasFrame
        let offset = canvas.contentOffset
        XCTAssertTrue(actions.place(.floating(CGPoint(x: 0.5, y: 0.5))))
        XCTAssertEqual(store.toolbar.placement, .floating(CGPoint(x: 0.5, y: 0.5)), "The placement is stored at once.")
        try await settle(host)
        XCTAssertEqual(canvas.bounds, bounds, "The canvas keeps its size under the stroke.")
        XCTAssertEqual(fixture.canvasFrame, frame)
        XCTAssertEqual(canvas.contentOffset, offset)

        fixture.controller.canvasViewDidEndUsingTool(canvas)
        try await NotebookTestFixtures.waitUntil { abs(canvas.bounds.height - host.bounds.height) < 0.5 }

        fixture.controller.canvasViewDidBeginUsingTool(canvas)
        let floatingBounds = canvas.bounds
        XCTAssertTrue(actions.place(.docked(.leftEdge)))
        try await settle(host)
        XCTAssertEqual(canvas.bounds, floatingBounds)
        fixture.controller.canvasViewDidEndUsingTool(canvas)
        try await NotebookTestFixtures.waitUntil { abs(canvas.bounds.height - host.bounds.height) < 0.5 }
        XCTAssertEqual(fixture.canvasFrame.minY, 0, accuracy: 0.5)

        // Edge scroll space changes without moving the page under an active stroke.
        fixture.controller.canvasViewDidBeginUsingTool(canvas)
        XCTAssertTrue(actions.place(.floating(CGPoint(x: 0.5, y: 1))))
        try await NotebookTestFixtures.waitUntil { store.overlayObstruction.bottom > 0 }
        XCTAssertEqual(fixture.canvasFrame.minY, 0, accuracy: 0.5)
        let toolbar = toolbarFrame(for: store.toolbar, in: host.bounds)
        XCTAssertEqual(store.overlayObstruction.bottom, fixture.canvasFrame.maxY - toolbar.minY, accuracy: 0.5)
        fixture.controller.canvasViewDidEndUsingTool(canvas)
        try await NotebookTestFixtures.waitUntil { abs(canvas.bounds.height - host.bounds.height) < 0.5 }
    }

    func testFloatingToolbarAtTheBottomKeepsTheEndOfTheLastPageReachable() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost()
        defer { fixture.close() }
        let store = fixture.store
        let canvas = fixture.controller.canvasView
        let host = fixture.hosting.view!
        let actions = NotebookToolbarActions(store: store)
        try await NotebookTestFixtures.waitUntil { store.overlayObstruction.top > 0 }

        actions.place(.floating(CGPoint(x: 0.5, y: 1)))
        try await NotebookTestFixtures.waitUntil { abs(canvas.bounds.height - host.bounds.height) < 0.5 && store.overlayObstruction.bottom > 0 }
        let toolbar = toolbarFrame(for: store.toolbar, in: host.bounds)
        let covered = fixture.canvasFrame.maxY - toolbar.minY
        XCTAssertEqual(store.overlayObstruction.bottom, covered, accuracy: 0.5)
        XCTAssertEqual(store.overlayObstruction.top, 0)
        XCTAssertEqual(canvas.contentInset.bottom, covered, accuracy: 0.5)

        let lastOffset = canvas.contentSize.height - canvas.bounds.height + canvas.contentInset.bottom
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: lastOffset), animated: false)
        let paperEnd = fixture.controller.view.convert(
            CGPoint(x: 0, y: canvas.contentSize.height - canvas.contentOffset.y), to: host
        )
        XCTAssertLessThanOrEqual(paperEnd.y, toolbar.minY + 0.5, "The end of the last page scrolls clear of the toolbar.")

        actions.place(.floating(CGPoint(x: 0.5, y: 0.25)))
        try await NotebookTestFixtures.waitUntil { store.overlayObstruction == .zero }
        actions.place(.floating(CGPoint(x: 0.5, y: 0)))
        try await NotebookTestFixtures.waitUntil { store.overlayObstruction.top > 0 }
        XCTAssertEqual(store.overlayObstruction.bottom, 0)
        actions.place(.docked(.topCenter))
        try await NotebookTestFixtures.waitUntil { store.overlayObstruction.top > 0 && canvas.contentInset.top > 0 }
    }

    /// Placements made in quick succession all reach the canvas. Each waits only until the one
    /// before it has landed, which can be within the frame that applied it, where a change handler
    /// would drop the next placement as an update loop.
    func testPlacementsInQuickSuccessionAllReachTheCanvas() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost()
        defer { fixture.close() }
        let store = fixture.store
        let canvas = fixture.controller.canvasView
        let actions = NotebookToolbarActions(store: store)
        try await NotebookTestFixtures.waitUntil { store.overlayObstruction.top > 0 }
        for _ in 0..<30 {
            XCTAssertTrue(actions.place(.floating(CGPoint(x: 0.5, y: 1))))
            try await NotebookTestFixtures.waitUntil { store.overlayObstruction.bottom > 0 }
            XCTAssertTrue(actions.place(.floating(CGPoint(x: 0.5, y: 0))))
            try await NotebookTestFixtures.waitUntil { store.overlayObstruction.top > 0 }
            XCTAssertEqual(store.overlayObstruction.bottom, 0)
        }
        XCTAssertTrue(actions.place(.floating(CGPoint(x: 0.5, y: 0.25))))
        try await NotebookTestFixtures.waitUntil { store.overlayObstruction == .zero && canvas.contentInset.top == 0 }
    }

    func testEveryTopAnchorLetsPaperScrollBehindTheToolbarAndRevealItsFirstLines() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost()
        defer { fixture.close() }
        let canvas = fixture.controller.canvasView
        let paper = fixture.controller.paperView
        let actions = NotebookToolbarActions(store: fixture.store)
        let host = fixture.host
        XCTAssertEqual(canvas.contentOffset.y, 0, accuracy: 0.5, "Opening keeps paper beneath the overlay.")
        var observations = 0
        fixture.controller.onObservation = { _ in observations += 1; return .open }
        let drawing = canvas.drawing

        for placement in [EditorToolbarPlacement.docked(.topCenter), .floating(CGPoint(x: 0.5, y: 0))] {
            actions.place(placement)
            try await settle(host)
            let toolbar = toolbarFrame(for: fixture.store.toolbar, in: host.bounds)
            let tools = firstRowCentre(for: fixture.store.toolbar, in: host.bounds)
            XCTAssertEqual(fixture.canvasFrame, host.bounds)
            XCTAssertFalse(fixture.hit(tools).isDescendant(of: fixture.controller.view))
            XCTAssertTrue(fixture.hit(CGPoint(x: toolbar.midX, y: toolbar.minY / 2)).isDescendant(of: canvas))

            canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: 450), animated: false)
            try await NotebookTestFixtures.waitUntil { abs(CATransform3DGetAffineTransform(paper.contentLayer.transform).ty + 450) < 0.5 }
            XCTAssertEqual(toolbarFrame(for: fixture.store.toolbar, in: host.bounds), toolbar)
            XCTAssertFalse(fixture.hit(tools).isDescendant(of: fixture.controller.view))
            XCTAssertEqual(canvas.contentOffset.y, 450, accuracy: 0.5)

            canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: -canvas.contentInset.top), animated: false)
            try await NotebookTestFixtures.waitUntil { CATransform3DGetAffineTransform(paper.contentLayer.transform).ty >= toolbar.maxY - 0.5 }
            XCTAssertGreaterThanOrEqual(CATransform3DGetAffineTransform(paper.contentLayer.transform).ty, toolbar.maxY - 0.5,
                "The first lines can be scrolled clear of every top anchor.")
        }
        XCTAssertEqual(canvas.drawing, drawing)
        XCTAssertEqual(observations, 0)
    }

    func testResizeKeepsARevealedFirstLineClearOfAFloatingToolbar() async throws {
        let narrow = CGRect(x: 0, y: 0, width: 700, height: 1_000)
        let fixture = try await NotebookTestFixtures.mountToolbarHost()
        defer { fixture.close() }
        let store = fixture.store
        let canvas = fixture.controller.canvasView
        let paper = fixture.controller.paperView
        let host = fixture.host
        let actions = NotebookToolbarActions(store: store)
        let wide = fixture.window.frame
        // Near the top, where the toolbar follows the window's height, so a resize changes what it covers.
        actions.place(.floating(CGPoint(x: 0.5, y: 0.08)))
        fixture.window.frame = narrow
        try await NotebookTestFixtures.waitUntil {
            canvas.bounds.size == narrow.size
                && abs(canvas.contentInset.top - self.toolbarFrame(for: store.toolbar, in: host.bounds).maxY) < 0.5
        }
        try await settle(host)
        let narrowTop = canvas.contentInset.top
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: -narrowTop), animated: false)

        // Keeping the page's centre across this resize would leave the first lines under the toolbar.
        fixture.window.frame = wide
        try await NotebookTestFixtures.waitUntil {
            canvas.bounds.size == wide.size && canvas.contentInset.top > narrowTop + 0.5
        }
        try await settle(host)
        let toolbar = toolbarFrame(for: store.toolbar, in: host.bounds)
        XCTAssertEqual(canvas.contentInset.top, toolbar.maxY, accuracy: 0.5)
        XCTAssertEqual(canvas.contentOffset.y, -canvas.contentInset.top, accuracy: 0.5,
            "A page resting at its revealed top stays there after the resize.")
        XCTAssertGreaterThanOrEqual(paper.contentLayer.transform.m42, toolbar.maxY - 0.5,
            "The first lines stay clear of the toolbar.")

        let revealed = canvas.contentOffset
        actions.place(.floating(CGPoint(x: 0.5, y: 0.09)))
        try await NotebookTestFixtures.waitUntil { canvas.contentInset.top > toolbar.maxY + 0.5 }
        try await settle(host)
        XCTAssertEqual(canvas.contentOffset, revealed, "Moving the toolbar down without a resize never pushes the page.")
    }

    // MARK: - Touches

    func testMovingOrDockingTheToolbarNeverReachesTheCanvas() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost()
        defer { fixture.close() }
        let store = fixture.store
        let controller = fixture.controller
        let host = fixture.hosting.view!
        let actions = NotebookToolbarActions(store: store)
        var observations = 0
        controller.onObservation = { _ in
            observations += 1
            return .open
        }
        let drawing = controller.canvasView.drawing

        for placement in [
            EditorToolbarPlacement.docked(.topCenter), .docked(.leftEdge), .docked(.rightEdge),
            .floating(CGPoint(x: 0.4, y: 0.6))
        ] {
            actions.place(placement)
            XCTAssertEqual(fixture.canvasFrame.minY, 0, accuracy: 0.5)
            for isOpen in [false, true] {
                store.setInkRowOpen(isOpen)
                try await settleSecondRow(host)
                let toolbar = toolbarFrame(for: store.toolbar, in: host.bounds)
                let grip = NotebookToolbarComposition.gripColumnWidth / 2
                let tools = firstRowCentre(for: store.toolbar, in: host.bounds)
                let ink = secondRowCentre(for: store.toolbar, in: host.bounds)
                let label = "\(placement), second row \(isOpen ? "open" : "closed")"
                let gripPoint: CGPoint
                let beside: CGPoint
                switch placement {
                case .docked(.leftEdge):
                    gripPoint = CGPoint(x: toolbar.minX + grip, y: toolbar.midY)
                    beside = CGPoint(x: toolbar.maxX + EditorToolbarLayout.margin / 2, y: toolbar.midY)
                case .docked(.rightEdge):
                    gripPoint = CGPoint(x: toolbar.maxX - grip, y: toolbar.midY)
                    beside = CGPoint(x: toolbar.minX - EditorToolbarLayout.margin / 2, y: toolbar.midY)
                default:
                    gripPoint = CGPoint(x: toolbar.minX + grip, y: tools.y)
                    beside = CGPoint(x: toolbar.midX, y: toolbar.maxY + EditorToolbarLayout.margin / 2)
                }
                for point in [gripPoint, tools] {
                    XCTAssertFalse(fixture.hit(point).isDescendant(of: controller.view), "\(label) \(point)")
                }
                XCTAssertEqual(
                    fixture.hit(ink).isDescendant(of: controller.canvasView), !isOpen,
                    "\(label): the second row's room keeps its touches only while the row shows."
                )
                XCTAssertTrue(fixture.hit(beside).isDescendant(of: controller.canvasView), label)
            }
            store.setInkRowOpen(false)
        }

        actions.setCollapsed(true)
        try await settle(host)
        let handle = toolbarFrame(for: store.toolbar, in: host.bounds)
        XCTAssertEqual(handle.size, NotebookTheme.collapsedHandleSize)
        XCTAssertFalse(fixture.hit(handle.center).isDescendant(of: controller.view), "The collapsed handle keeps its touches.")

        XCTAssertEqual(observations, 0, "Moving the overlay never reports a drawing change.")
        XCTAssertEqual(controller.canvasView.drawing.dataRepresentation(), drawing.dataRepresentation())
    }

    // MARK: - Contrast on glass

    /// The keys keep their contrast on the rail's glass over the ivory paper and over the black below
    /// the last page, under the default and Increase Contrast settings, measured from the drawn window,
    /// which renders the glass as the screen does: mid gray over black, lifted toward white over the
    /// paper. Live symbols, the width dots, the grip and a selected key on its lens reach 3:1; the
    /// planned tools' caption and the preset labels, which are text, reach 4.5:1. The placeholders are
    /// inactive controls, which WCAG 1.4.11 exempts: they keep the system's secondary style, dimmer
    /// than every live key and still legible.
    func testRailKeysKeepTheirContrastOnTheGlassOverThePaperAndOverBlack() async throws {
        let underlays: [(String, UIColor)] = [("paper", NotebookTheme.paperIvory.uiColor), ("black", .black)]
        for setting in [UIAccessibilityContrast.normal, .high] {
            for (name, underlay) in underlays {
                let fixture = try await NotebookTestFixtures.mountToolbarHost(width: 1_366)
                defer { fixture.close() }
                fixture.hosting.traitOverrides.accessibilityContrast = setting
                let cover = UIView(frame: fixture.controller.view.bounds)
                cover.backgroundColor = underlay
                cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                fixture.controller.view.addSubview(cover)
                fixture.store.setInkRowOpen(true)
                try await settleSecondRow(fixture.host)
                let rail = toolbarFrame(for: fixture.store.toolbar, in: fixture.host.bounds)
                let layout = NotebookToolbarComposition(
                    preferences: fixture.store.toolbar, horizontalSizeClass: .regular, isInkRowOpen: true
                ).rail(forHostWidth: fixture.host.bounds.width)
                let pixels = try renderedWindow(fixture.window)
                func key(_ slot: NotebookStripSlot, row: Int) -> CGRect {
                    CGRect(
                        x: rail.minX + NotebookToolbarComposition.gripColumnWidth + slot.minX,
                        y: rail.minY + CGFloat(row) * (NotebookTheme.rowHeight + NotebookTheme.rowSpacing)
                            + NotebookTheme.stripInsets.top,
                        width: slot.width, height: NotebookTheme.controlSize
                    )
                }
                let label = "\(name), contrast \(setting.rawValue)"
                var live: [Double] = []
                var placeholders: [Double] = []
                for slot in layout.toolRow.slots where !slot.item.isDivider {
                    let ratio = markContrast(in: key(slot, row: 0), of: pixels)
                    switch slot.item {
                    case .upcoming:
                        placeholders.append(ratio)
                    case .upcomingLabel:
                        XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(label): the caption")
                    default:
                        XCTAssertGreaterThanOrEqual(ratio, 3, "\(label): \(slot.id)")
                        live.append(ratio)
                    }
                }
                for slot in try XCTUnwrap(layout.inkRow).slots {
                    guard case .preset = slot.item else { continue }
                    XCTAssertGreaterThanOrEqual(markContrast(in: key(slot, row: 1), of: pixels), 4.5, "\(label): \(slot.id)")
                }
                let grip = CGRect(
                    x: rail.minX, y: rail.minY + NotebookTheme.stripInsets.top,
                    width: NotebookToolbarComposition.gripColumnWidth, height: NotebookTheme.controlSize
                )
                XCTAssertGreaterThanOrEqual(markContrast(in: grip, of: pixels), 3, "\(label): the grip")
                XCTAssertEqual(placeholders.count, NotebookUpcomingFeature.placed(.toolStrip).count, label)
                for ratio in placeholders {
                    XCTAssertLessThan(ratio, try XCTUnwrap(live.min()), "\(label): a placeholder reads as unavailable")
                    XCTAssertGreaterThanOrEqual(ratio, 2.5, "\(label): and stays legible.")
                }
            }
        }
    }

    // MARK: - Collapsed handle

    /// The handle presses like every rail control inside its pane of glass. An offscreen render draws
    /// the glass flat, so this checks where the pane lies and how the press shows, not what the
    /// glass lets through.
    func testRevealHandlePressesLikeAToolbarControlInsideItsGlass() throws {
        func rendered(pressed: Bool) throws -> RenderedPixels {
            try RenderedPixels(rendering: NotebookRevealHandleBody(
                label: NotebookToolGlyph(symbol: "pencil.tip.crop.circle", isSelected: false), isPressed: pressed
            ))
        }
        let rest = try rendered(pressed: false)
        let pressed = try rendered(pressed: true)
        let size = NotebookTheme.collapsedHandleSize
        let inset = NotebookTheme.stripInsets.top
        XCTAssertEqual(rest.size, size)

        // Inside the glass but beside the glyph, where only the glass and the press well draw.
        let wellArea = CGPoint(x: inset + 3, y: size.height / 2)
        XCTAssertNotEqual(pressed.rgba(at: wellArea), rest.rgba(at: wellArea), "A press sinks the control.")
        for point in [wellArea, CGPoint(x: size.width / 2, y: inset + 2)] {
            XCTAssertGreaterThan(rest.rgba(at: point)[3], 0, "The glass covers the handle at rest")
            XCTAssertGreaterThan(pressed.rgba(at: point)[3], 0, "and while pressed.")
        }
        // Outside the pane's rounded corner the press draws nothing.
        let corner = CGPoint(x: 1, y: 1)
        XCTAssertEqual(pressed.rgba(at: corner), rest.rgba(at: corner))
        XCTAssertLessThan(rest.rgba(at: corner)[3], 128, "The corner lies outside the glass.")
    }

    // MARK: - Strip ends

    /// An 11-inch iPad in portrait: all four presets show whole at rest, and wherever the strip is
    /// left, a control it cuts is masked rather than drawn in part.
    func testPortraitInkStripShowsEveryPresetWholeAndMasksCutControls() async throws {
        let store = NotebookTestFixtures.toolStore()
        var preferences = store.toolbar
        preferences.addCustomSwatch(EditorInkColor(red: 0.2, green: 0.5, blue: 0.3))
        preferences.addCustomSwatch(EditorInkColor(red: 0.6, green: 0.2, blue: 0.5))
        store.updateToolbar(preferences)
        store.setInkRowOpen(true)
        let fixture = try await NotebookTestFixtures.mountToolbarHost(store: store, width: 834)
        defer { fixture.close() }
        let strips = fixture.strips
        XCTAssertEqual(strips.count, 2)
        let tools = try XCTUnwrap(strips.first)
        let ink = try XCTUnwrap(strips.last)
        let row = try XCTUnwrap(
            NotebookToolbarComposition(preferences: store.toolbar, horizontalSizeClass: .regular).rail(forHostWidth: 834).inkRow
        )
        try await settle(fixture.host)

        XCTAssertLessThanOrEqual(tools.contentSize.width, tools.bounds.width + 0.5, "Every tool shows without paging.")
        XCTAssertEqual(ink.contentOffset.x, 0, accuracy: 0.5)
        let scrollWidth = row.contentWidth + row.trailingRoom(containerWidth: ink.bounds.width)
        XCTAssertEqual(ink.contentSize.width, scrollWidth, accuracy: 0.5, "The strip lays out the slots it measures.")
        func mask(at offset: CGFloat) -> NotebookStripMask {
            let overflow = NotebookStripOverflow(offset: offset, contentWidth: scrollWidth, containerWidth: ink.bounds.width)
            return row.restingMask(for: overflow)
        }
        let presets = row.slots.filter { if case .preset = $0.item { true } else { false } }
        XCTAssertEqual(presets.count, 4)
        for preset in presets {
            XCTAssertLessThanOrEqual(preset.maxX, mask(at: 0).end, "\(preset.id) shows whole at rest.")
            XCTAssertLessThanOrEqual(preset.maxX, ink.bounds.width)
        }
        let strip = fixture.frame(of: ink)
        let swatches = row.slots.filter { if case .swatch = $0.item { true } else { false } }
        XCTAssertEqual(mask(at: 0).end, swatches[5].maxX, accuracy: 0.001, "At rest the strip ends after the sixth swatch.")
        let atRest = try renderedWindow(fixture.window)
        XCTAssertTrue(showsPlainShell(atRest, across: strip, from: strip.minX + mask(at: 0).end + 2, to: strip.maxX - 2))
        XCTAssertFalse(
            showsPlainShell(atRest, across: strip, from: strip.minX + swatches[5].minX + 10, to: strip.minX + swatches[5].maxX - 10),
            "The sixth swatch is drawn."
        )

        // Left between resting places, the strip cuts the first preset under the leading chevron
        // and the seventh swatch at its end.
        let offset: CGFloat = 20
        ink.setContentOffset(CGPoint(x: offset, y: 0), animated: false)
        try await settle(fixture.host)
        let shown = mask(at: offset)
        let first = presets[0]
        let second = presets[1]
        XCTAssertLessThan(first.minX - offset, NotebookTheme.controlSize)
        XCTAssertEqual(shown.start, second.minX - offset, accuracy: 0.001)
        let cut = try XCTUnwrap(row.slots.first { $0.minX - offset < ink.bounds.width && $0.maxX - offset > ink.bounds.width })
        XCTAssertGreaterThanOrEqual(cut.minX - offset, shown.end)
        XCTAssertGreaterThan(ink.bounds.width - (cut.minX - offset), 20, "Most of a swatch would show without the mask.")

        let pixels = try renderedWindow(fixture.window)
        XCTAssertTrue(
            showsPlainShell(pixels, across: strip, from: strip.minX + NotebookTheme.controlSize + 2, to: strip.minX + shown.start - 2),
            "No part of the first preset shows beside the leading chevron."
        )
        XCTAssertTrue(
            showsPlainShell(pixels, across: strip, from: strip.minX + shown.end + 2, to: strip.maxX - 2),
            "No part of the cut swatch shows at the strip's end."
        )
        XCTAssertFalse(
            showsPlainShell(
                pixels, across: strip, from: strip.minX + second.minX - offset + 14, to: strip.minX + second.maxX - offset - 14
            ),
            "The first whole preset is drawn."
        )
        XCTAssertFalse(
            showsPlainShell(pixels, across: strip, from: strip.minX + shown.end - 30, to: strip.minX + shown.end - 14),
            "The last whole swatch is drawn."
        )
    }

    /// Two thirds of a 12.9-inch iPad in Split View. Both rows are cut at rest, the tool row in
    /// the widths and the ink row in its third swatch; each ends at its last whole control and
    /// offers its trailing chevron.
    func testSplitViewRowsShowOnlyWholeControlsAtRest() async throws {
        let store = NotebookTestFixtures.toolStore()
        store.setInkRowOpen(true)
        let fixture = try await NotebookTestFixtures.mountToolbarHost(store: store, width: 678)
        defer { fixture.close() }
        let rail = NotebookToolbarComposition(preferences: fixture.store.toolbar, horizontalSizeClass: .regular)
            .rail(forHostWidth: 678)
        XCTAssertTrue(rail.toolRowOverflows)
        XCTAssertTrue(rail.inkRowOverflows)
        try await settle(fixture.host)
        let strips = fixture.strips
        XCTAssertEqual(strips.count, 2)
        let pixels = try renderedWindow(fixture.window)
        for (strip, row) in zip(strips, [rail.toolRow, try XCTUnwrap(rail.inkRow)]) {
            XCTAssertEqual(strip.contentOffset.x, 0, accuracy: 0.5)
            let width = strip.bounds.width
            let scrollWidth = row.contentWidth + row.trailingRoom(containerWidth: width)
            XCTAssertEqual(strip.contentSize.width, scrollWidth, accuracy: 0.5)
            let mask = row.restingMask(for: NotebookStripOverflow(offset: 0, contentWidth: scrollWidth, containerWidth: width))
            let cut = try XCTUnwrap(row.slots.first { !$0.item.isDivider && $0.minX < width && $0.maxX > width })
            let last = try XCTUnwrap(row.slots.last { !$0.item.isDivider && $0.maxX <= mask.end + 0.001 })
            XCTAssertGreaterThanOrEqual(cut.minX, mask.end - 0.001)
            let frame = fixture.frame(of: strip)
            XCTAssertTrue(
                showsPlainShell(pixels, across: frame, from: frame.minX + mask.end + 2, to: frame.maxX - 2),
                "No part of \(cut.id) shows."
            )
            XCTAssertFalse(
                showsPlainShell(pixels, across: frame, from: frame.minX + last.minX + 8, to: frame.minX + last.maxX - 8),
                "\(last.id) is drawn."
            )
            let chevron = CGRect(x: frame.maxX + 14, y: frame.midY - 8, width: 16, height: 16)
            XCTAssertGreaterThan(darkPixelCount(pixels, in: chevron), 4, "The row offers its trailing chevron.")
        }

        // Scrolled to their ends, both rows start just clear of the leading chevron and leave what
        // is spare after their last control.
        for (strip, row) in zip(strips, [rail.toolRow, try XCTUnwrap(rail.inkRow)]) {
            let maximum = row.maximumOffset(containerWidth: strip.bounds.width)
            strip.setContentOffset(CGPoint(x: maximum, y: 0), animated: false)
        }
        try await settle(fixture.host)
        let atEnd = try renderedWindow(fixture.window)
        for (strip, row) in zip(strips, [rail.toolRow, try XCTUnwrap(rail.inkRow)]) {
            let offset = strip.contentOffset.x
            XCTAssertEqual(offset, row.maximumOffset(containerWidth: strip.bounds.width), accuracy: 0.5)
            let frame = fixture.frame(of: strip)
            let first = try XCTUnwrap(row.slots.first { !$0.item.isDivider && $0.minX >= offset + NotebookTheme.controlSize })
            XCTAssertEqual(first.minX - offset, NotebookStripRow.leadingClearance, accuracy: 0.5)
            let firstShown = frame.minX + first.minX - offset
            XCTAssertFalse(
                showsPlainShell(atEnd, across: frame, from: firstShown + 8, to: firstShown + first.width - 8),
                "\(first.id) is drawn just clear of the leading chevron."
            )
            let last = try XCTUnwrap(row.slots.last { !$0.item.isDivider })
            XCTAssertLessThanOrEqual(last.maxX - offset, strip.bounds.width + 0.5)
            XCTAssertTrue(showsPlainShell(atEnd, across: frame, from: frame.minX + last.maxX - offset + 2, to: frame.maxX - 2))
        }
    }

    // MARK: - Grip column

    /// Docked or floating, the grip's ridges stand level with the first row, where opening the second
    /// row leaves them, and the grip column holds nothing else. A floating rail ends its first row
    /// with its collapse key, in sight and live whether or not the second row shows; the docked rail
    /// has none there.
    func testFloatingRailEndsItsFirstRowWithItsCollapseKeyWhateverTheSecondRow() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost()
        defer { fixture.close() }
        let host = fixture.host
        let store = fixture.store
        let actions = NotebookToolbarActions(store: store)
        func darkPixels(in area: CGRect, _ pixels: RenderedPixels) -> Int {
            var count = 0
            for x in stride(from: area.minX, through: area.maxX, by: 1) {
                for y in stride(from: area.minY, through: area.maxY, by: 1) {
                    let pixel = pixels.rgba(at: CGPoint(x: x, y: y)).prefix(3).map { Double($0) / 255 }
                    if 0.2126 * pixel[0] + 0.7152 * pixel[1] + 0.0722 * pixel[2] < 0.45 { count += 1 }
                }
            }
            return count
        }
        let grip = NotebookTheme.controlSize

        for placement in [EditorToolbarPlacement.docked(.topCenter), .floating(CGPoint(x: 0.5, y: 0.5))] {
            XCTAssertTrue(actions.place(placement))
            let isFloating = placement != .docked(.topCenter)
            for isOpen in [false, true] {
                store.setInkRowOpen(isOpen)
                try await settleSecondRow(host)
                let rail = toolbarFrame(for: store.toolbar, in: host.bounds)
                let label = "\(placement), second row \(isOpen ? "open" : "closed")"
                let pixels = try renderedWindow(fixture.window)
                // The 24-point ridges centred on the 52-point first row, and the grip column's second row.
                let ridges = CGRect(x: rail.minX + 4, y: rail.minY + 16, width: grip - 8, height: 20)
                let belowRidges = CGRect(x: rail.minX + 4, y: rail.minY + 72, width: grip - 8, height: 18)
                XCTAssertGreaterThan(darkPixels(in: ridges, pixels), 20, "\(label): the ridges stand level with the first row.")
                XCTAssertLessThan(darkPixels(in: belowRidges, pixels), 20, "\(label): nothing else in the grip column.")

                let key = CGPoint(
                    x: rail.maxX - NotebookTheme.stripInsets.right - NotebookTheme.controlSize / 2,
                    y: rail.minY + NotebookTheme.rowHeight / 2
                )
                let hit = fixture.hit(key)
                if isFloating {
                    XCTAssertFalse(hit.isDescendant(of: fixture.controller.view), "\(label): the key keeps its touches.")
                    XCTAssertFalse(fixture.strips.contains { hit.isDescendant(of: $0) }, "\(label): apart from the strip.")
                    let glyph = CGRect(x: key.x - 10, y: key.y - 10, width: 20, height: 20)
                    XCTAssertGreaterThan(darkPixels(in: glyph, pixels), 20, "\(label): the collapse key is drawn there.")
                } else {
                    XCTAssertEqual(rail.size, NotebookToolbarComposition(preferences: .standard, horizontalSizeClass: .regular)
                        .rail(forHostWidth: host.bounds.width).size, label)
                }
            }
        }
        store.setInkRowOpen(false)
    }

    /// Half of a 12.9-inch iPad in Split View. The single compact row keeps the one-control grip
    /// column; floating, it adds the collapse key after the current-ink chip, and the tool strip
    /// gives up that room.
    func testCompactFloatingRowKeepsItsCollapseKeyAfterTheInkChip() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost(horizontalSizeClass: .compact, width: 507)
        defer { fixture.close() }
        let store = fixture.store
        func rail() -> CGRect {
            NotebookToolbarComposition(preferences: store.toolbar, horizontalSizeClass: .compact)
                .frame(in: fixture.host.bounds)
        }
        try await settle(fixture.host)
        let dockedRail = rail()
        let dockedStrip = fixture.frame(of: try XCTUnwrap(fixture.strips.first))
        XCTAssertEqual(dockedStrip.minX - dockedRail.minX, NotebookTheme.controlSize, accuracy: 0.5)

        XCTAssertTrue(NotebookToolbarActions(store: store).place(.floating(CGPoint(x: 0.5, y: 0.5))))
        try await settle(fixture.host)
        let floatingRail = rail()
        let floatingStrip = fixture.frame(of: try XCTUnwrap(fixture.strips.first))
        XCTAssertEqual(floatingRail.width, dockedRail.width, accuracy: 0.5)
        XCTAssertEqual(floatingStrip.minX - floatingRail.minX, NotebookTheme.controlSize, accuracy: 0.5,
            "The grip column stays one control wide.")
        XCTAssertEqual(
            floatingStrip.width, dockedStrip.width - NotebookTheme.itemSpacing - NotebookTheme.controlSize, accuracy: 0.5
        )
        let key = CGPoint(
            x: floatingRail.maxX - NotebookTheme.stripInsets.right - NotebookTheme.controlSize / 2, y: floatingRail.midY
        )
        let hit = fixture.hit(key)
        XCTAssertFalse(hit.isDescendant(of: fixture.controller.view))
        XCTAssertFalse(fixture.strips.contains { hit.isDescendant(of: $0) })
        let glyph = CGRect(x: key.x - 10, y: key.y - 10, width: 20, height: 20)
        XCTAssertGreaterThan(darkPixelCount(try renderedWindow(fixture.window), in: glyph), 20, "The collapse key is drawn there.")
    }

    /// A collapsed handle that writing has paused dims its content like the paused rail: its glyph
    /// keeps the live glyph's colour at the paused opacity, rather than a disabled tone dimmed again.
    func testPausedCollapsedHandleDimsItsGlyphToThePausedOpacity() async throws {
        let store = NotebookTestFixtures.toolStore()
        store.updateToolbar(EditorToolbarPreferences(
            placement: .floating(CGPoint(x: 0.5, y: 0.5)), isCollapsed: true, customSwatches: []
        ))
        let fixture = try await NotebookTestFixtures.mountToolbarHost(store: store)
        defer { fixture.close() }
        try await settle(fixture.host)
        let handle = toolbarFrame(for: store.toolbar, in: fixture.host.bounds)
        XCTAssertEqual(handle.size, NotebookTheme.collapsedHandleSize)
        func luminance(_ rgb: [Double]) -> Double { 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2] }
        // The tool symbol at the handle's centre, clear of the ink bead below and after it, and the
        // glass beside it, level with its darkest point.
        let glyphPoints = stride(from: handle.midX - 10, to: handle.midX + 4, by: 0.5).flatMap { x in
            stride(from: handle.midY - 10, to: handle.midY + 4, by: 0.5).map { CGPoint(x: x, y: $0) }
        }
        func glyphAndShell() throws -> (glyph: [Double], shell: [Double]) {
            let pixels = try renderedWindow(fixture.window)
            func components(_ point: CGPoint) -> [Double] {
                pixels.rgba(at: point).prefix(3).map { Double($0) / 255 }
            }
            let darkest = try XCTUnwrap(glyphPoints.min { luminance(components($0)) < luminance(components($1)) })
            return (components(darkest), components(CGPoint(x: handle.minX + 3, y: darkest.y)))
        }
        let live = try glyphAndShell()
        fixture.controller.setInputGate(.failed)
        XCTAssertFalse(store.isToolbarAvailable)
        try await settle(fixture.host)
        let paused = try glyphAndShell()
        let alpha = (0..<3).map { (paused.shell[$0] - paused.glyph[$0]) / (live.shell[$0] - live.glyph[$0]) }.reduce(0, +) / 3
        XCTAssertEqual(alpha, NotebookTheme.disabledOpacity, accuracy: 0.03, "drawn \(paused.glyph) on \(paused.shell), live \(live.glyph)")
    }

    // MARK: - Hidden tools

    func testHiddenDockedToolsLeaveARevealTabWhereTheRailRests() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost()
        defer { fixture.close() }
        let store = fixture.store
        let canvas = fixture.controller.canvasView
        try await NotebookTestFixtures.waitUntil { store.overlayObstruction.top > 0 }
        try await settle(fixture.host)
        let rail = toolbarFrame(for: store.toolbar, in: fixture.host.bounds)
        let obstruction = store.overlayObstruction
        let insets = canvas.contentInset
        let offset = canvas.contentOffset
        let railCentre = CGPoint(x: rail.midX + 120, y: rail.minY + NotebookTheme.rowHeight / 2)
        let tab = CGPoint(x: rail.midX, y: rail.minY + 8)
        XCTAssertFalse(fixture.hit(railCentre).isDescendant(of: fixture.controller.view))
        let shown = try renderedWindow(fixture.window)

        store.setToolsHidden(true)
        try await NotebookTestFixtures.waitUntil { fixture.hit(railCentre).isDescendant(of: canvas) }
        XCTAssertFalse(fixture.hit(tab).isDescendant(of: fixture.controller.view), "The tab takes its own touches.")
        // The tab fades in once the rail has gone, hanging from the rail's resting top over plain paper.
        let families = CGRect(x: rail.minX + 60, y: rail.minY + 14, width: 160, height: 24)
        let chevron = CGRect(x: rail.midX - 10, y: rail.minY + 2, width: 20, height: 16)
        try await NotebookTestFixtures.waitUntil {
            guard let pixels = try? self.renderedWindow(fixture.window) else { return false }
            return self.darkPixelCount(pixels, in: families) == 0 && self.darkPixelCount(pixels, in: chevron) > 5
        }
        XCTAssertEqual(store.overlayObstruction, obstruction, "Hiding the tools never changes the scroll space.")
        XCTAssertEqual(canvas.contentInset, insets)
        XCTAssertEqual(canvas.contentOffset, offset, "Hiding the tools never moves the page.")

        store.revealTools()
        try await NotebookTestFixtures.waitUntil { !fixture.hit(railCentre).isDescendant(of: fixture.controller.view) }
        XCTAssertEqual(store.overlayObstruction, obstruction)
        XCTAssertEqual(canvas.contentOffset, offset)
        // The rail comes back exactly as it was: its keys are live again, not left in the disabled
        // tone they took while hidden, and the tab has gone.
        try await NotebookTestFixtures.waitUntil { (try? self.renderedWindow(fixture.window))?.looksLike(shown) ?? false }
    }

    /// The writing view may hide and bring back the tools more than once within a frame, as when
    /// a scroll ends just as the pen lifts; the rail always ends up as the store last asked.
    func testToolsHiddenAndShownInQuickSuccessionEndAsLastAsked() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost()
        defer { fixture.close() }
        let store = fixture.store
        let canvas = fixture.controller.canvasView
        try await NotebookTestFixtures.waitUntil { store.overlayObstruction.top > 0 }
        try await settle(fixture.host)
        let rail = toolbarFrame(for: store.toolbar, in: fixture.host.bounds)
        let railCentre = CGPoint(x: rail.midX + 120, y: rail.minY + NotebookTheme.rowHeight / 2)
        let shown = try renderedWindow(fixture.window)

        for _ in 0..<20 {
            store.setToolsHidden(true)
            try await Task.sleep(for: .milliseconds(1))
            store.setToolsHidden(false)
            try await Task.sleep(for: .milliseconds(1))
        }
        try await NotebookTestFixtures.waitUntil { (try? self.renderedWindow(fixture.window))?.looksLike(shown) ?? false }
        XCTAssertFalse(fixture.hit(railCentre).isDescendant(of: fixture.controller.view))

        for _ in 0..<20 {
            store.setToolsHidden(false)
            try await Task.sleep(for: .milliseconds(1))
            store.setToolsHidden(true)
            try await Task.sleep(for: .milliseconds(1))
        }
        let families = CGRect(x: rail.minX + 60, y: rail.minY + 14, width: 160, height: 24)
        try await NotebookTestFixtures.waitUntil {
            guard let pixels = try? self.renderedWindow(fixture.window) else { return false }
            return self.darkPixelCount(pixels, in: families) == 0
        }
        XCTAssertTrue(fixture.hit(railCentre).isDescendant(of: canvas))
    }

    func testHiddenFloatingToolsLeaveTheirHandleWhereTheRailFloated() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost()
        defer { fixture.close() }
        let store = fixture.store
        let canvas = fixture.controller.canvasView
        let actions = NotebookToolbarActions(store: store)
        XCTAssertTrue(actions.place(.floating(CGPoint(x: 0.5, y: 0.5))))
        try await settle(fixture.host)
        let rail = toolbarFrame(for: store.toolbar, in: fixture.host.bounds)
        let besideHandle = CGPoint(x: rail.minX + 20, y: rail.minY + 10)

        store.setToolsHidden(true)
        try await NotebookTestFixtures.waitUntil { fixture.hit(besideHandle).isDescendant(of: canvas) }
        let firstRow = CGPoint(x: rail.midX, y: rail.minY + NotebookTheme.rowHeight / 2)
        XCTAssertFalse(fixture.hit(firstRow).isDescendant(of: fixture.controller.view),
            "The handle stands where the rail's first row floated.")
        XCTAssertFalse(store.toolbar.isCollapsed, "Hiding is not the user's own collapse.")
        store.revealTools()
        try await NotebookTestFixtures.waitUntil { !fixture.hit(besideHandle).isDescendant(of: fixture.controller.view) }
        XCTAssertFalse(store.toolbar.isCollapsed)
    }

    func testHiddenToolsLeaveAUserCollapsedHandleAsItWas() async throws {
        let store = NotebookTestFixtures.toolStore()
        store.updateToolbar(EditorToolbarPreferences(
            placement: .floating(CGPoint(x: 0.5, y: 0.5)), isCollapsed: true, customSwatches: []
        ))
        let fixture = try await NotebookTestFixtures.mountToolbarHost(store: store)
        defer { fixture.close() }
        try await settle(fixture.host)
        let handle = toolbarFrame(for: store.toolbar, in: fixture.host.bounds)
        XCTAssertEqual(handle.size, NotebookTheme.collapsedHandleSize)

        store.setToolsHidden(true)
        try await settle(fixture.host)
        XCTAssertTrue(store.toolbar.isCollapsed, "Hiding the tools never changes the user's collapse.")
        XCTAssertFalse(fixture.hit(handle.center).isDescendant(of: fixture.controller.view), "The handle stays in place.")
        XCTAssertGreaterThan(
            darkPixelCount(try renderedWindow(fixture.window), in: handle.insetBy(dx: 12, dy: 8)), 20, "and in sight."
        )

        NotebookToolbarActions(store: store).showTools()
        XCTAssertFalse(store.areToolsHidden)
        let rail = toolbarFrame(for: store.toolbar, in: fixture.host.bounds)
        let besideHandle = CGPoint(x: rail.minX + 60, y: rail.minY + NotebookTheme.rowHeight / 2)
        try await NotebookTestFixtures.waitUntil { !fixture.hit(besideHandle).isDescendant(of: fixture.controller.view) }
    }

    /// Collapsing a floating rail leaves its handle across the first row, where the rail showed it,
    /// rather than in the middle of the room kept for the second row; a floating rail the writing
    /// view hides leaves its stand-in in the same place.
    func testCollapsedOrHiddenFloatingRailLeavesItsHandleOnTheFirstRow() async throws {
        let store = NotebookTestFixtures.toolStore()
        store.updateToolbar(EditorToolbarPreferences(
            placement: .floating(CGPoint(x: 0.5, y: 0.5)), isCollapsed: false, customSwatches: []
        ))
        let fixture = try await NotebookTestFixtures.mountToolbarHost(store: store)
        defer { fixture.close() }
        let host = fixture.host
        try await settle(host)
        let row = firstRowCentre(for: store.toolbar, in: host.bounds)
        let room = toolbarFrame(for: store.toolbar, in: host.bounds)
        // Inside a handle centred on the room, and clear of one centred on the first row.
        let roomMiddle = CGPoint(x: room.midX, y: room.midY + 10)
        XCTAssertTrue(fixture.hit(roomMiddle).isDescendant(of: fixture.controller.canvasView), "The closed row's room is the page's.")

        NotebookToolbarActions(store: store).setCollapsed(true)
        try await settle(host)
        let handle = toolbarFrame(for: store.toolbar, in: host.bounds)
        XCTAssertEqual(handle.midX, row.x, accuracy: 0.5)
        XCTAssertEqual(handle.midY, row.y, accuracy: 0.5)
        XCTAssertFalse(fixture.hit(row).isDescendant(of: fixture.controller.view), "The handle rests across the first row")
        XCTAssertGreaterThan(
            darkPixelCount(try renderedWindow(fixture.window), in: handle.insetBy(dx: 12, dy: 8)), 20, "and is drawn there,"
        )
        XCTAssertTrue(fixture.hit(roomMiddle).isDescendant(of: fixture.controller.canvasView), "not in the room's middle.")

        NotebookToolbarActions(store: store).setCollapsed(false)
        store.setToolsHidden(true)
        try await NotebookTestFixtures.waitUntil { !fixture.hit(row).isDescendant(of: fixture.controller.view) }
        XCTAssertTrue(fixture.hit(roomMiddle).isDescendant(of: fixture.controller.canvasView), "The stand-in rests there too.")
        // It fades in once the rail has gone.
        try await Task.sleep(for: .seconds(NotebookTheme.toolsHideDuration + NotebookTheme.toolsFadeDuration + 0.1))
        XCTAssertGreaterThan(
            darkPixelCount(try renderedWindow(fixture.window), in: handle.insetBy(dx: 12, dy: 8)), 20, "It is drawn there."
        )
    }

    /// The rail shows its first row alone until an ink's key opens the second; another ink keeps it
    /// open and the ink in use closes it. The toolbar keeps the second row's room either way: its
    /// obstruction, the canvas's insets and the page's place never change, during the animation as
    /// after it, and the closed row's room shows the page and leaves its touches to it.
    func testTheSecondRowOpensAndClosesInItsRoomWithoutMovingThePage() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost()
        defer { fixture.close() }
        let store = fixture.store
        let canvas = fixture.controller.canvasView
        let actions = NotebookToolbarActions(store: store)
        try await NotebookTestFixtures.waitUntil { store.overlayObstruction.top > 0 }
        try await settle(fixture.host)
        let rail = toolbarFrame(for: store.toolbar, in: fixture.host.bounds)
        XCTAssertEqual(store.overlayObstruction.top, rail.maxY, accuracy: 0.5, "Both rows' room is kept from the start.")
        let obstruction = store.overlayObstruction
        let insets = canvas.contentInset
        let offset = canvas.contentOffset
        let tools = firstRowCentre(for: store.toolbar, in: fixture.host.bounds)
        let ink = secondRowCentre(for: store.toolbar, in: fixture.host.bounds)
        let inkStrip = try XCTUnwrap(fixture.strips.last)
        let colours = CGRect(
            x: rail.minX + NotebookToolbarComposition.gripColumnWidth + 16, y: ink.y - 12, width: rail.width - 120, height: 24
        )
        func assertPageStill(_ moment: String) {
            XCTAssertEqual(store.overlayObstruction, obstruction, moment)
            XCTAssertEqual(canvas.contentInset, insets, moment)
            XCTAssertEqual(canvas.contentOffset, offset, moment)
        }
        func assertShows(secondRow: Bool, _ moment: String) throws {
            XCTAssertEqual(store.isInkRowOpen, secondRow, moment)
            XCTAssertFalse(fixture.hit(tools).isDescendant(of: fixture.controller.view), "\(moment): the first row")
            XCTAssertEqual(fixture.hit(ink).isDescendant(of: inkStrip), secondRow, "\(moment): the second row's touches")
            XCTAssertEqual(fixture.hit(ink).isDescendant(of: canvas), !secondRow, "\(moment): the page's touches")
            let drawn = darkPixelCount(try renderedWindow(fixture.window), in: colours)
            XCTAssertEqual(drawn > 20, secondRow, "\(moment): \(drawn) dark pixels where the colours are")
        }

        try assertShows(secondRow: false, "at launch")
        let steps: [(EditorInkFamily, Bool, String)] = [
            (.pen, true, "the ink in use opens its settings"),
            (.pencil, true, "another ink keeps them open"),
            (.pencil, false, "the ink in use closes them"),
            (.marker, true, "another ink opens them again"),
            (.marker, false, "and closes them"),
        ]
        for (family, opens, moment) in steps {
            actions.chooseInk(family)
            try await Task.sleep(for: .milliseconds(80))
            assertPageStill("\(moment), mid-animation")
            if !opens {
                XCTAssertFalse(fixture.hit(ink).isDescendant(of: inkStrip), "\(moment): a closing row takes no touches as it fades.")
            }
            try await settleSecondRow(fixture.host)
            assertPageStill(moment)
            try assertShows(secondRow: opens, moment)
        }
    }

    /// A rail on end overlays the page's edge: it reserves no scroll space, so the page keeps its
    /// full width and its place, and hiding or showing the rail at any dock never changes the insets.
    func testASideRailReservesNothingAndHidingNeverChangesTheInsets() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost()
        defer { fixture.close() }
        let store = fixture.store
        let canvas = fixture.controller.canvasView
        let host = fixture.hosting.view!
        let actions = NotebookToolbarActions(store: store)
        let width = canvas.bounds.width
        let top = canvas.contentInset.top
        let reserved = store.overlayObstruction.top
        XCTAssertGreaterThan(reserved, 0, "The top dock reserves its depth.")

        for dock in [EditorToolbarDock.leftEdge, .rightEdge, .topCenter] {
            actions.place(.docked(dock))
            try await settle(host)
            if dock.axis == .vertical {
                XCTAssertEqual(store.overlayObstruction, .zero, "\(dock): a side rail reserves nothing.")
                XCTAssertEqual(canvas.contentInset.top, top - reserved, accuracy: 0.5)
            } else {
                XCTAssertEqual(canvas.contentInset.top, top, accuracy: 0.5)
            }
            XCTAssertEqual(canvas.bounds.width, width, accuracy: 0.5, "\(dock): the page keeps its full width.")
            XCTAssertEqual(fixture.canvasFrame.minX, 0, accuracy: 0.5)
            let insets = canvas.contentInset
            let obstruction = store.overlayObstruction
            store.setToolsHidden(true)
            try await settle(host)
            XCTAssertEqual(canvas.contentInset, insets, "\(dock): hiding the rail leaves the insets alone.")
            XCTAssertEqual(store.overlayObstruction, obstruction)
            store.setToolsHidden(false)
            try await settle(host)
            XCTAssertEqual(canvas.contentInset, insets, "\(dock): showing it again does too.")
        }
    }

    /// On end at either side the grip stands against the screen edge and the tool column next to it,
    /// facing the page, mirrored per side; the ink column opens beside the tools toward the page.
    /// Hidden in Focus, the rail leaves its tab at the screen edge it rests against, which takes its
    /// own touches while the page takes the rest.
    func testSideRailsFaceThePageAndLeaveTheirTabAtTheirEdge() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost()
        defer { fixture.close() }
        let store = fixture.store
        let host = fixture.host
        let actions = NotebookToolbarActions(store: store)
        func eraser() throws -> UIView {
            func find(_ view: UIView) -> UIView? {
                (view is NotebookEraserMenuButton ? view : nil) ?? view.subviews.lazy.compactMap(find).first
            }
            return try XCTUnwrap(find(host))
        }
        try await settle(host)
        let top = toolbarFrame(for: store.toolbar, in: host.bounds)
        let topGrip = CGRect(x: top.minX, y: top.minY, width: 44, height: NotebookTheme.rowHeight)
        let upright = darkExtent(try renderedWindow(fixture.window), in: topGrip)
        XCTAssertGreaterThan(upright.height, 2 * upright.width, "Across the top rail the grip's ridges stand upright.")
        for dock in [EditorToolbarDock.leftEdge, .rightEdge] {
            actions.place(.docked(dock))
            try await settle(host)
            let rail = toolbarFrame(for: store.toolbar, in: host.bounds)
            XCTAssertEqual(rail.width, 152, "\(dock): the room kept holds both columns.")
            let key = try eraser()
            let toolStrip = try XCTUnwrap(fixture.strips.first { key.isDescendant(of: $0) })
            let inkStrip = try XCTUnwrap(fixture.strips.first { $0 !== toolStrip })
            let toward = dock == .leftEdge ? CGFloat(1) : -1
            let outer = dock == .leftEdge ? rail.minX : rail.maxX
            let grip = CGPoint(x: outer + toward * 22, y: rail.midY)
            let tools = CGPoint(x: outer + toward * (44 + 26), y: rail.midY)
            let ink = CGPoint(x: outer + toward * (44 + 52 + 4 + 26), y: rail.midY)
            XCTAssertFalse(fixture.hit(grip).isDescendant(of: fixture.controller.view), "\(dock): the grip")
            XCTAssertFalse(fixture.strips.contains { fixture.hit(grip).isDescendant(of: $0) }, "\(dock): the grip is no strip")
            XCTAssertTrue(fixture.hit(tools).isDescendant(of: toolStrip), "\(dock): tools beside the grip")
            XCTAssertTrue(fixture.hit(ink).isDescendant(of: fixture.controller.canvasView), "\(dock): the page beside the tools")
            let gripColumn = CGRect(x: dock == .leftEdge ? rail.minX : rail.maxX - 44, y: rail.midY - 30, width: 44, height: 60)
            let level = darkExtent(try renderedWindow(fixture.window), in: gripColumn)
            XCTAssertGreaterThan(level.width, 2 * level.height, "\(dock): on end the ridges lie level across the rail.")

            actions.chooseInk(.pen)
            try await settleSecondRow(host)
            XCTAssertTrue(fixture.hit(tools).isDescendant(of: toolStrip), "\(dock): the tools stay where they were")
            XCTAssertTrue(fixture.hit(ink).isDescendant(of: inkStrip), "\(dock): the ink opens toward the page")
            XCTAssertEqual(store.overlayObstruction, .zero, "\(dock): neither column reserves space.")
            actions.chooseInk(.pen)
            try await settleSecondRow(host)
            XCTAssertTrue(fixture.hit(ink).isDescendant(of: fixture.controller.canvasView), "\(dock): and closes again")

            store.setToolsHidden(true)
            let railMiddle = CGPoint(x: tools.x, y: rail.midY - 120)
            try await NotebookTestFixtures.waitUntil { fixture.hit(railMiddle).isDescendant(of: fixture.controller.canvasView) }
            let tab = CGPoint(x: outer + toward * 10, y: rail.midY)
            XCTAssertFalse(fixture.hit(tab).isDescendant(of: fixture.controller.view), "\(dock): the tab at the edge")
            store.setToolsHidden(false)
            try await NotebookTestFixtures.waitUntil { !fixture.hit(railMiddle).isDescendant(of: fixture.controller.view) }
        }
    }

    /// In a window too short for the tool column, the column scrolls vertically within the rail,
    /// which keeps inside the window; it lays out exactly the slots the rail measured.
    func testAShortSideRailScrollsItsColumnsVertically() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost()
        defer { fixture.close() }
        let store = fixture.store
        let host = fixture.host
        fixture.window.frame = CGRect(x: 0, y: 0, width: 1_024, height: 560)
        NotebookToolbarActions(store: store).place(.docked(.rightEdge))
        try await settle(host)
        let composition = NotebookToolbarComposition(preferences: store.toolbar, horizontalSizeClass: .regular)
        let rail = composition.rail(in: host.bounds.size)
        XCTAssertTrue(rail.toolRowOverflows)
        let frame = toolbarFrame(for: store.toolbar, in: host.bounds)
        XCTAssertTrue(host.bounds.insetBy(dx: 11.5, dy: 11.5).contains(frame), "The rail keeps inside the window.")
        func eraser(_ view: UIView) -> UIView? {
            (view is NotebookEraserMenuButton ? view : nil) ?? view.subviews.lazy.compactMap(eraser).first
        }
        let key = try XCTUnwrap(eraser(host))
        let strip = try XCTUnwrap(fixture.strips.first { key.isDescendant(of: $0) })
        try await NotebookTestFixtures.waitUntil { strip.contentSize.height > strip.bounds.height + 0.5 }
        XCTAssertEqual(strip.contentSize.width, strip.bounds.width, accuracy: 0.5, "It never scrolls sideways.")
        XCTAssertEqual(
            strip.contentSize.height,
            rail.toolRow.contentWidth + rail.toolRow.trailingRoom(containerWidth: strip.bounds.height), accuracy: 0.5
        )
        let end = rail.toolRow.maximumOffset(containerWidth: strip.bounds.height)
        strip.setContentOffset(CGPoint(x: 0, y: end), animated: false)
        try await settle(host)
        XCTAssertEqual(strip.contentOffset.y, end, accuracy: 0.5)
        XCTAssertTrue(key.convert(key.bounds, to: host).intersects(frame), "The eraser scrolls into the rail.")
    }

    /// A flick that would end between resting places carries on to the nearest one: along the top
    /// rail's row, and down a side rail's column, where it comes to rest with a whole control just
    /// clear of the leading chevron and no control cut at the column's end.
    func testFlickedStripsComeToRestOnWholeControlsAlongEitherAxis() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost()
        defer { fixture.close() }
        let store = fixture.store
        let host = fixture.host
        let windows = [(EditorToolbarDock.topCenter, CGSize(width: 678, height: 900)), (.leftEdge, CGSize(width: 1_024, height: 560))]
        for (dock, window) in windows {
            fixture.window.frame = CGRect(origin: .zero, size: window)
            NotebookToolbarActions(store: store).place(.docked(dock))
            try await settle(host)
            let rail = NotebookToolbarComposition(preferences: store.toolbar, horizontalSizeClass: .regular)
                .rail(in: host.bounds.size)
            XCTAssertEqual(rail.orientation.axis, dock.axis == .vertical ? .vertical : .horizontal, "\(dock)")
            XCTAssertTrue(rail.toolRowOverflows, "\(dock)")
            let strip = try toolStrip(in: fixture)
            let isVertical = dock.axis == .vertical
            func along(_ point: CGPoint) -> CGFloat { isVertical ? point.y : point.x }
            func across(_ point: CGPoint) -> CGFloat { isVertical ? point.x : point.y }
            func point(along value: CGFloat) -> CGPoint {
                isVertical ? CGPoint(x: 0, y: value) : CGPoint(x: value, y: 0)
            }
            let length = isVertical ? strip.bounds.height : strip.bounds.width
            try await NotebookTestFixtures.waitUntil {
                (isVertical ? strip.contentSize.height : strip.contentSize.width) > length + 0.5
            }
            let row = rail.toolRow
            let stops = row.restingOffsets(containerWidth: length)
            XCTAssertGreaterThan(stops.count, 2, "\(dock)")

            for (stop, next) in zip(stops, stops.dropFirst()) {
                for proposed in [stop + (next - stop) / 3, next - (next - stop) / 3] {
                    // Where UIKit reports a flick would end, which SwiftUI answers with the strip's
                    // target behaviour.
                    var target = point(along: proposed)
                    strip.delegate?.scrollViewWillEndDragging?(
                        strip, withVelocity: point(along: 0.5), targetContentOffset: &target
                    )
                    let nearest = row.restingOffset(near: proposed, containerWidth: length)
                    XCTAssertEqual(along(target), nearest, accuracy: 0.5, "\(dock): a flick ending at \(proposed)")
                    XCTAssertEqual(across(target), 0, "\(dock): it never comes to rest across the strip.")
                }
            }

            // Where a flick part-way along leaves it, a whole control shows first and none is cut.
            var target = point(along: (stops[1] + stops[2]) / 2 + 3)
            strip.delegate?.scrollViewWillEndDragging?(
                strip, withVelocity: point(along: 0.5), targetContentOffset: &target
            )
            strip.setContentOffset(target, animated: false)
            try await settle(host)
            let offset = along(strip.contentOffset)
            XCTAssertTrue(stops.contains { abs($0 - offset) < 0.5 }, "\(dock): it rests at \(offset)")
            let scrollLength = row.contentWidth + row.trailingRoom(containerWidth: length)
            let mask = row.restingMask(for: NotebookStripOverflow(offset: offset, contentWidth: scrollLength, containerWidth: length))
            XCTAssertEqual(mask.start, NotebookStripRow.leadingClearance, accuracy: 0.5, "\(dock)")
            let first = try XCTUnwrap(row.slots.first { !$0.item.isDivider && abs($0.minX - offset - mask.start) < 0.5 })
            let pixels = try renderedWindow(fixture.window)
            let frame = fixture.frame(of: strip)
            XCTAssertGreaterThan(
                darkPixels(pixels, along: frame, isVertical: isVertical, from: mask.start + 8, to: mask.start + first.width - 8), 4,
                "\(dock): \(first.id) is drawn whole first."
            )
            if mask.end < length - 4 {
                XCTAssertEqual(
                    darkPixels(pixels, along: frame, isVertical: isVertical, from: mask.end + 2, to: length - 2), 0,
                    "\(dock): no part of a control shows after the last whole one."
                )
            }
        }
    }

    /// Left between resting places, a side rail's column masks the control cut under its leading
    /// chevron and the one cut at its end, as a row does.
    func testASideRailColumnMasksTheControlsItCuts() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost()
        defer { fixture.close() }
        let host = fixture.host
        fixture.window.frame = CGRect(x: 0, y: 0, width: 1_024, height: 560)
        NotebookToolbarActions(store: fixture.store).place(.docked(.rightEdge))
        try await settle(host)
        let rail = NotebookToolbarComposition(preferences: fixture.store.toolbar, horizontalSizeClass: .regular)
            .rail(in: host.bounds.size)
        let column = try toolStrip(in: fixture)
        let length = column.bounds.height
        try await NotebookTestFixtures.waitUntil { column.contentSize.height > length + 0.5 }
        let row = rail.toolRow
        let offset: CGFloat = 20
        column.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
        try await settle(host)
        XCTAssertEqual(column.contentOffset.y, offset, accuracy: 0.5)
        let scrollLength = row.contentWidth + row.trailingRoom(containerWidth: length)
        let mask = row.restingMask(for: NotebookStripOverflow(offset: offset, contentWidth: scrollLength, containerWidth: length))
        let controls = row.slots.filter { !$0.item.isDivider }
        let leadingCut = try XCTUnwrap(controls.first { $0.maxX - offset > NotebookTheme.controlSize + 8 })
        XCTAssertLessThan(leadingCut.minX - offset, NotebookTheme.controlSize, "A control sits part-way under the chevron.")
        XCTAssertEqual(mask.start, try XCTUnwrap(controls.first { $0.minX - offset >= NotebookTheme.controlSize }).minX - offset)
        let trailingCut = try XCTUnwrap(controls.first { $0.minX - offset < length && $0.maxX - offset > length })
        XCTAssertGreaterThan(length - (trailingCut.minX - offset), 20, "Most of a control would show without the mask.")
        XCTAssertGreaterThanOrEqual(trailingCut.minX - offset, mask.end)

        let pixels = try renderedWindow(fixture.window)
        let frame = fixture.frame(of: column)
        XCTAssertEqual(
            darkPixels(pixels, along: frame, isVertical: true, from: NotebookTheme.controlSize + 2, to: mask.start - 2), 0,
            "No part of \(leadingCut.id) shows below the leading chevron."
        )
        XCTAssertEqual(
            darkPixels(pixels, along: frame, isVertical: true, from: mask.end + 2, to: length - 2), 0,
            "No part of \(trailingCut.id) shows at the column's end."
        )
        let lastWhole = try XCTUnwrap(controls.last { $0.maxX - offset <= mask.end + 0.5 })
        XCTAssertGreaterThan(
            darkPixels(pixels, along: frame, isVertical: true, from: lastWhole.minX - offset + 8, to: lastWhole.maxX - offset - 8), 4,
            "\(lastWhole.id), the last whole control, is drawn."
        )
    }

    /// The tab a hidden rail leaves sits where the rail comes back from: hanging from the middle of
    /// the top rail, or standing at the middle of a side rail's outer edge, pointing at the page.
    func testTheRevealTabStandsWhereTheRailRests() {
        let hit = NotebookTheme.revealTabHitSize
        let top = CGRect(x: 100, y: 12, width: 800, height: 108)
        let tab = NotebookToolsRevealTab.frame(standingFor: top, dock: .topCenter)
        XCTAssertEqual(tab, CGRect(x: top.midX - hit.width / 2, y: top.minY, width: hit.width, height: hit.height))

        let left = CGRect(x: 12, y: 90, width: 152, height: 921)
        let leftTab = NotebookToolsRevealTab.frame(standingFor: left, dock: .leftEdge)
        XCTAssertEqual(leftTab.minX, left.minX)
        XCTAssertEqual(leftTab.midY, left.midY)
        XCTAssertEqual(leftTab.size, CGSize(width: hit.height, height: hit.width), "It stands on end.")

        let right = CGRect(x: 670, y: 90, width: 152, height: 921)
        let rightTab = NotebookToolsRevealTab.frame(standingFor: right, dock: .rightEdge)
        XCTAssertEqual(rightTab.maxX, right.maxX)
        XCTAssertEqual(rightTab.midY, right.midY)

        XCTAssertEqual(NotebookToolsRevealTab.symbol(for: .topCenter), "chevron.compact.down")
        XCTAssertEqual(NotebookToolsRevealTab.symbol(for: .leftEdge), "chevron.compact.right")
        XCTAssertEqual(NotebookToolsRevealTab.symbol(for: .rightEdge), "chevron.compact.left")
    }

    func testToolsOnlyFadeUnderReduceMotionAndTheStandInFollowsTheHide() {
        let standard = NotebookToolsTransition(reduceMotion: false)
        XCTAssertEqual(standard.hiddenOffset(for: .horizontal), CGSize(width: 0, height: -8), "Hiding tools rise a little as they fade.")
        XCTAssertEqual(standard.hiddenOffset(for: .leftEdge), CGSize(width: -8, height: 0), "At a side they slip toward the edge.")
        XCTAssertEqual(standard.hiddenOffset(for: .rightEdge), CGSize(width: 8, height: 0))
        XCTAssertEqual(standard.hide, .easeIn(duration: 0.18))
        XCTAssertEqual(standard.reveal, .spring(duration: 0.24, bounce: 0))
        XCTAssertEqual(standard.standInAppearance, .easeOut(duration: 0.15).delay(0.18), "The stand-in waits for the hide.")

        let reduced = NotebookToolsTransition(reduceMotion: true)
        for orientation in [NotebookRailOrientation.horizontal, .leftEdge, .rightEdge] {
            XCTAssertEqual(reduced.hiddenOffset(for: orientation), .zero, "Under Reduce Motion nothing moves.")
        }
        XCTAssertEqual(reduced.hide, .linear(duration: 0.15))
        XCTAssertEqual(reduced.reveal, .linear(duration: 0.15))
        XCTAssertEqual(reduced.standInAppearance, .easeOut(duration: 0.15).delay(0), "The stand-in fades in at once.")
    }

    // MARK: - Production wiring

    func testNotebookScreenFillsTheWindowWithScrollingPaperBeneathFloatingControls() async throws {
        try await verifyFullScreenPaper(preloadsNotebook: true)
    }

    func testOpeningTransitionKeepsTheFullScreenPaperAndFloatingControlsUsable() async throws {
        try await verifyFullScreenPaper(preloadsNotebook: false)
    }

    func testReadOnlyCanvasCanScrollItsFirstLineClearOfTheHeaderAndToolbar() async throws {
        let id = UUID()
        let root = NotebookTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NotebookRepository(rootURL: root.appendingPathComponent("Library", isDirectory: true))
        let stored = try await repository.save(
            id: id, content: NotebookContent(title: "Notebook", pageCount: 3, strokes: []), expectedRevisionID: nil
        )
        let opened = try await repository.open(id: id)
        let pin = try XCTUnwrap(opened).historyPin
        let probe = try NotebookStorageProbe(
            stored: stored, recoveryRoot: root.appendingPathComponent("Recovery", isDirectory: true)
        )
        let base = await probe.storage(notebookID: id)
        let storage = NotebookStorage(
            load: base.load, save: base.save, preserve: base.preserve,
            listRecovery: base.listRecovery, loadRecovery: base.loadRecovery,
            openForEditing: { NotebookOpening(notebook: stored, historyPin: pin) },
            auditHistory: { _ in .damaged(.corruptData) }
        )
        let session = NotebookSession(notebookID: id, openStorage: { storage })
        await session.load()
        try await NotebookTestFixtures.waitUntil { session.inputGate == .readOnly }
        try await verifyClearanceOfAScreenOpenedPaused(session: session, gate: .readOnly)
    }

    func testFailedCanvasCanScrollItsFirstLineClearOfTheHeaderAndToolbar() async throws {
        let id = UUID()
        let root = NotebookTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = try NotebookStorageProbe(stored: try await NotebookTestFixtures.stored(id: id), recoveryRoot: root)
        let storage = await probe.storage(notebookID: id)
        let session = NotebookSession(notebookID: id, openStorage: { storage })
        await session.load()
        await probe.setSaveFailure(.storageFull)
        let seed = session.makeCanvasSeed()
        session.recordCompletedEdit(PKDrawing(strokes: [NotebookTestFixtures.stroke()]), ownerID: seed.ownerID)
        await session.waitUntilSettled()
        XCTAssertEqual(session.inputGate, .failed)
        try await verifyClearanceOfAScreenOpenedPaused(session: session, gate: .failed)
    }

    func testCanvasRecreatedUnderTheToolbarReservesTheHeaderAndToolbar() async throws {
        let id = UUID()
        let root = NotebookTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = try NotebookStorageProbe(stored: try await NotebookTestFixtures.stored(id: id), recoveryRoot: root)
        let storage = await probe.storage(notebookID: id)
        let session = NotebookSession(notebookID: id, openStorage: { storage })
        await session.load()
        await probe.setSaveFailure(.storageFull)
        let scene = try NotebookTestFixtures.windowScene()
        let previousKeyWindow = scene.keyWindow
        let owner = preserveSceneStore(for: scene)
        owner.updateToolbar(.standard)
        let (window, hosting) = showScreen(session, in: scene)
        defer {
            session.flush()
            close(window)
            previousKeyWindow?.makeKey()
        }
        try await NotebookTestFixtures.waitUntil {
            guard let controller = NotebookTestFixtures.notebookController(in: hosting) else { return false }
            return hosting.hasAppeared && controller.isCanvasVisible && owner.isToolbarAvailable
                && owner.overlayObstruction.top > 0
        }
        let retired = try XCTUnwrap(NotebookTestFixtures.notebookController(in: hosting))
        XCTAssertTrue(retired.drawingToolStore === owner)
        retired.canvasView.drawing = PKDrawing(strokes: [NotebookTestFixtures.stroke()])
        retired.canvasViewDrawingDidChange(retired.canvasView)
        await session.waitUntilSettled()
        XCTAssertEqual(session.inputGate, .failed)
        await session.saveRecoveryCopy()
        XCTAssertTrue(session.canReopenSaved)

        // Ink the canvas delivers only as it is retired keeps the reopen from replacing the waiting
        // edits, so the session recreates the canvas, still failed, under the same toolbar.
        let late = PKDrawing(strokes: [NotebookTestFixtures.stroke(), NotebookTestFixtures.stroke(x: 200)])
        let ownerID = try XCTUnwrap(session.canvasOwnerID)
        session.attachCanvas(
            ownerID: ownerID,
            observations: { [weak retired] in retired?.captureBarrier() },
            applyInputGate: { [weak retired] in retired?.setInputGate($0) },
            controls: NotebookCanvasControls(
                undo: { [weak retired] in retired?.performUndo() },
                redo: { [weak retired] in retired?.performRedo() },
                setPaletteSuppressed: { [weak retired] in retired?.setPaletteSuppressed($0) },
                applyPageCount: { [weak retired] in retired?.setPageCount($0) },
                currentAvailability: { [weak retired] in retired?.currentUndoAvailability ?? .unavailable },
                retire: { [weak retired] in
                    retired?.canvasView.drawing = late
                    retired?.tearDown()
                }
            )
        )
        let generation = session.canvasGeneration
        await session.reopenSavedNotebook()
        XCTAssertNotEqual(session.canvasGeneration, generation)
        XCTAssertEqual(session.inputGate, .failed)
        XCTAssertEqual(session.workingDrawing.strokes.map(\.id), late.strokes.map(\.id))
        try await NotebookTestFixtures.waitUntil {
            guard let controller = NotebookTestFixtures.notebookController(in: hosting) else { return false }
            return controller !== retired && controller.isCanvasVisible && controller.canvasView.contentInset.top > 0
        }
        try await settle(hosting.view)
        let replacement = try XCTUnwrap(NotebookTestFixtures.notebookController(in: hosting))
        XCTAssertEqual(replacement.canvasView.drawing.strokes.map(\.id), late.strokes.map(\.id))
        XCTAssertTrue(owner.covers(replacement), "The host draws the same toolbar over the replacement.")
        try await verifyFirstLineClearance(of: replacement, gate: .failed, owner: owner, hosting: hosting, window: window)
    }

    func testScreenRotationKeepsARevealedFirstLineClearOfTheHeaderAndToolbar() async throws {
        let id = UUID()
        let root = NotebookTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = try NotebookStorageProbe(stored: try await NotebookTestFixtures.stored(id: id), recoveryRoot: root)
        let storage = await probe.storage(notebookID: id)
        let session = NotebookSession(notebookID: id, openStorage: { storage })
        await session.load()
        let scene = try NotebookTestFixtures.windowScene()
        let previousKeyWindow = scene.keyWindow
        let owner = preserveSceneStore(for: scene)
        owner.updateToolbar(.standard)
        let (window, hosting) = showScreen(session, in: scene)
        defer {
            session.flush()
            close(window)
            previousKeyWindow?.makeKey()
        }
        try await NotebookTestFixtures.waitUntil {
            guard let controller = NotebookTestFixtures.notebookController(in: hosting) else { return false }
            return hosting.hasAppeared && controller.isCanvasVisible && owner.isToolbarAvailable
                && owner.overlayObstruction.top > 0
        }
        try await settle(hosting.view)
        let controller = try XCTUnwrap(NotebookTestFixtures.notebookController(in: hosting))
        let canvas = controller.canvasView
        let paper = controller.paperView
        let header = try headerBand(in: hosting, window: window).maxY
        let shell = try headerShell(in: hosting, window: window)
        let footer = window.safeAreaInsets.bottom
        let portrait = window.frame
        let landscape = CGRect(x: 0, y: 0, width: portrait.height, height: portrait.width)

        // A floating toolbar takes space from the top once its centre is less than one and a half
        // of its heights below the control area's top. Placed between the two orientations'
        // limits, it covers the first lines only in the shorter landscape area.
        func floating(at y: CGFloat) -> EditorToolbarPreferences {
            EditorToolbarPreferences(placement: .floating(CGPoint(x: 0.5, y: y)), isCollapsed: false, customSwatches: [])
        }
        let height = NotebookToolbarComposition(preferences: floating(at: 0), horizontalSizeClass: .regular)
            .toolbarSize(forHostWidth: portrait.width).height
        let reach = 1.5 * height
        let fraction = (reach / (portrait.height - header - footer) + reach / (landscape.height - header - footer)) / 2
        owner.updateToolbar(floating(at: fraction))
        // The toolbar takes nothing from the top, and the canvas still keeps the whole header
        // covered, though the toolbar's margin begins inside it.
        try await NotebookTestFixtures.waitUntil {
            owner.overlayObstruction == .zero && abs(canvas.contentInset.top - shell.maxY) < 0.5
        }
        try await settle(hosting.view)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: -canvas.contentInset.top), animated: false)

        window.frame = landscape
        try await NotebookTestFixtures.waitUntil {
            canvas.bounds.size == landscape.size && owner.overlayObstruction.top > 0
                && canvas.contentInset.top > shell.maxY + 0.5
        }
        try await settle(hosting.view)
        let bar = try headerBand(in: hosting, window: window)
        let hostArea = CGRect(x: 0, y: bar.maxY, width: window.bounds.width,
            height: window.bounds.height - bar.maxY - window.safeAreaInsets.bottom)
        let toolbar = toolbarFrame(for: owner.toolbar, in: hostArea)
        XCTAssertEqual(canvas.contentInset.top, toolbar.maxY, accuracy: 0.5)
        XCTAssertEqual(canvas.contentOffset.y, -canvas.contentInset.top, accuracy: 0.5,
            "A page resting at its revealed top stays there after the rotation.")
        XCTAssertGreaterThanOrEqual(paper.contentLayer.transform.m42, toolbar.maxY - 0.5,
            "The first lines stay clear of the header and the toolbar now over them.")

        let revealed = canvas.contentOffset
        owner.updateToolbar(floating(at: fraction + 0.01))
        try await NotebookTestFixtures.waitUntil { canvas.contentInset.top > toolbar.maxY + 0.5 }
        try await settle(hosting.view)
        XCTAssertEqual(canvas.contentOffset, revealed, "Moving the toolbar down without a resize never pushes the page.")
    }

    /// Opens the screen on a canvas whose gate keeps it from ever taking the tools.
    private func verifyClearanceOfAScreenOpenedPaused(session: NotebookSession, gate: NotebookInputGate) async throws {
        let scene = try NotebookTestFixtures.windowScene()
        let previousKeyWindow = scene.keyWindow
        let owner = preserveSceneStore(for: scene)
        owner.updateToolbar(.standard)
        let (window, hosting) = showScreen(session, in: scene)
        defer {
            session.flush()
            close(window)
            previousKeyWindow?.makeKey()
        }
        try await NotebookTestFixtures.waitUntil {
            guard let controller = NotebookTestFixtures.notebookController(in: hosting) else { return false }
            return hosting.hasAppeared && controller.isCanvasVisible && controller.canvasView.contentInset.top > 0
                && owner.overlayObstruction.top > 0
        }
        try await settle(hosting.view)
        let controller = try XCTUnwrap(NotebookTestFixtures.notebookController(in: hosting))
        try await verifyFirstLineClearance(of: controller, gate: gate, owner: owner, hosting: hosting, window: window)
    }

    /// The host draws the toolbar, dimmed, over a canvas whose gate keeps it from taking the tools,
    /// so the canvas reserves the toolbar as well as the header and its first line scrolls clear
    /// of both.
    private func verifyFirstLineClearance(
        of controller: NotebookViewController, gate: NotebookInputGate, owner: NotebookSceneToolStore,
        hosting: UIViewController, window: UIWindow
    ) async throws {
        XCTAssertEqual(controller.inputGate, gate)
        XCTAssertNil(controller.drawingToolStore, "A canvas in this gate never takes the tools.")
        let bar = try headerBand(in: hosting, window: window)
        let hostArea = CGRect(x: 0, y: bar.maxY, width: window.bounds.width,
            height: window.bounds.height - bar.maxY - window.safeAreaInsets.bottom)
        let toolbar = toolbarFrame(for: owner.toolbar, in: hostArea)
        let canvas = controller.canvasView
        XCTAssertEqual(controller.view.convert(controller.view.bounds, to: window), window.bounds)
        XCTAssertEqual(canvas.contentInset.top, toolbar.maxY, accuracy: 0.5,
            "The header and the toolbar drawn over the canvas are reserved. Toolbar: \(toolbar), "
                + "obstruction: \(owner.overlayObstruction)")
        XCTAssertEqual(canvas.contentInset.top - owner.overlayObstruction.top, bar.maxY, accuracy: 0.5)
        XCTAssertEqual(
            canvas.contentInset.bottom, window.safeAreaInsets.bottom, accuracy: 0.5,
            "The last page rests at its end above the home indicator."
        )
        XCTAssertEqual(canvas.contentOffset.y, 0, accuracy: 0.5, "The page opens beneath the header and toolbar.")

        let paper = controller.paperView
        let drawing = canvas.drawing
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: -canvas.contentInset.top), animated: false)
        try await NotebookTestFixtures.waitUntil { paper.contentLayer.transform.m42 >= toolbar.maxY - 0.5 }
        XCTAssertEqual(canvas.contentOffset.y, -canvas.contentInset.top, accuracy: 0.5)
        XCTAssertEqual(canvas.drawing, drawing)

        // Floating clear of the top, the toolbar takes nothing; the first line still scrolls clear of
        // the whole header, which reaches below where the toolbar's control area begins.
        let shell = try headerShell(in: hosting, window: window)
        XCTAssertGreaterThan(shell.maxY, bar.maxY)
        owner.updateToolbar(
            EditorToolbarPreferences(placement: .floating(CGPoint(x: 0.5, y: 0.5)), isCollapsed: false, customSwatches: [])
        )
        try await NotebookTestFixtures.waitUntil { owner.overlayObstruction == .zero }
        try await settle(hosting.view)
        XCTAssertEqual(canvas.contentInset.top, shell.maxY, accuracy: 0.5, "The header stays covered.")
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: -canvas.contentInset.top), animated: false)
        try await NotebookTestFixtures.waitUntil { paper.contentLayer.transform.m42 >= shell.maxY - 0.5 }
    }

    private func verifyFullScreenPaper(preloadsNotebook: Bool) async throws {
        let id = UUID()
        let root = NotebookTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let stored = try await NotebookTestFixtures.stored(id: id)
        let probe = try NotebookStorageProbe(stored: stored, recoveryRoot: root)
        let storage = await probe.storage(notebookID: id)
        let session = NotebookSession(notebookID: id, openStorage: { storage })
        if preloadsNotebook { await session.load() }
        let scene = try NotebookTestFixtures.windowScene()
        let previousKeyWindow = scene.keyWindow
        let owner = preserveSceneStore(for: scene)
        owner.updateToolbar(.standard)

        let (window, hosting) = showScreen(session, in: scene)
        defer {
            session.flush()
            close(window)
            previousKeyWindow?.makeKey()
        }
        try await NotebookTestFixtures.waitUntil {
            guard let controller = NotebookTestFixtures.notebookController(in: hosting) else { return false }
            return hosting.hasAppeared && controller.isCanvasVisible && controller.canvasView.isFirstResponder && owner.isToolbarAvailable
        }
        try await settle(hosting.view)
        let controller = try XCTUnwrap(NotebookTestFixtures.notebookController(in: hosting))
        XCTAssertTrue(controller.drawingToolStore === owner, "The screen's canvas uses the scene's store.")

        let bar = try headerBand(in: hosting, window: window)
        let canvasFrame = controller.view.convert(controller.view.bounds, to: window)
        XCTAssertEqual(canvasFrame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(canvasFrame.minY, 0, accuracy: 0.5, "Paper reaches behind the navigation and status regions.")
        XCTAssertEqual(canvasFrame.width, window.bounds.width, accuracy: 0.5)
        XCTAssertEqual(canvasFrame.maxY, window.bounds.maxY, accuracy: 0.5, "Paper reaches behind the home indicator.")
        XCTAssertEqual(controller.canvasView.contentOffset.y, 0, accuracy: 0.5)
        let hostArea = CGRect(x: 0, y: bar.maxY, width: window.bounds.width,
            height: window.bounds.height - bar.maxY - window.safeAreaInsets.bottom)
        let toolbar = toolbarFrame(for: owner.toolbar, in: hostArea)
        let tools = firstRowCentre(for: owner.toolbar, in: hostArea)
        XCTAssertGreaterThan(toolbar.minY, bar.maxY)
        try await NotebookTestFixtures.waitUntil {
            let hit = NotebookTestFixtures.hit(tools, in: window)
            return owner.overlayObstruction.top > 0 && hit !== window && hit !== hosting.view
                && !hit.isDescendant(of: controller.view)
        }

        XCTAssertEqual(controller.canvasView.contentOffset.y, 0, accuracy: 0.5,
            "Publishing overlay scroll space leaves paper beneath the controls.")
        let family: EditorInkFamily = owner.tool.kind == .ink(.marker) ? .pencil : .marker
        NotebookToolbarActions(store: owner).select(.ink(family))
        XCTAssertEqual((controller.canvasView.tool as? PKInkingTool)?.inkType, family.inkType)

        let rendered = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let pixels = try RenderedPixels(try XCTUnwrap(rendered.cgImage), scale: rendered.scale)
        // Beside the header, in its side inset, the writing paper shows through.
        let shell = try headerShell(in: hosting, window: window)
        let sample = pixels.rgba(at: CGPoint(x: shell.minX / 2, y: shell.midY)).map { Double($0) / 255 }
        let luminance = 0.2126 * sample[0] + 0.7152 * sample[1] + 0.0722 * sample[2]
        XCTAssertGreaterThan(luminance, 0.85, "Ivory paper reaches beside the header.")
        XCTAssertGreaterThan(sample[0], sample[2], "The paper keeps its warm tone.")
        let canvas = controller.canvasView
        let paper = controller.paperView
        let drawing = canvas.drawing
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: 450), animated: false)
        try await NotebookTestFixtures.waitUntil { abs(paper.contentLayer.transform.m42 + 450) < 0.5 }
        XCTAssertFalse(NotebookTestFixtures.hit(tools, in: window).isDescendant(of: controller.view))
        let exposedPoint = CGPoint(x: toolbar.midX, y: toolbar.maxY + 20)
        let exposedHit = NotebookTestFixtures.hit(exposedPoint, in: window)
        XCTAssertTrue(exposedHit.isDescendant(of: canvas), "Exposed paper hit: \(exposedHit)")
        XCTAssertEqual(canvas.contentInset.top, toolbar.maxY, accuracy: 0.5,
            "The canvas adds the toolbar, its second row's room included, to the header. Canvas: \(canvasFrame), "
                + "host: \(hostArea), toolbar: \(toolbar), obstruction: \(owner.overlayObstruction)")
        XCTAssertEqual(canvas.contentInset.top - owner.overlayObstruction.top, bar.maxY, accuracy: 0.5)
        XCTAssertEqual(
            canvas.contentInset.bottom, window.safeAreaInsets.bottom, accuracy: 0.5,
            "The last page rests at its end above the home indicator."
        )
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: -canvas.contentInset.top), animated: false)
        try await NotebookTestFixtures.waitUntil { paper.contentLayer.transform.m42 >= toolbar.maxY - 0.5 }
        XCTAssertEqual(canvas.drawing, drawing)
    }

    // MARK: - Fixtures

    /// The header's drawn shell, measured from the header the screen shows.
    private func headerShell(in hosting: UIViewController, window: UIWindow) throws -> CGRect {
        func headerHost(in controller: UIViewController) -> NotebookHeaderHostController? {
            controller as? NotebookHeaderHostController ?? controller.children.lazy.compactMap(headerHost).first
        }
        let header = try XCTUnwrap(headerHost(in: hosting), "The screen shows its header.")
        let host = header.view.convert(header.view.bounds, to: window)
        return NotebookHeaderHostController.shellFrame(in: header.view.bounds).offsetBy(dx: host.minX, dy: host.minY)
    }

    /// The band above the toolbar's control area: the status bar and the header, down to the gap a
    /// docked toolbar keeps below the header, less the toolbar's own margin.
    private func headerBand(in hosting: UIViewController, window: UIWindow) throws -> CGRect {
        let shell = try headerShell(in: hosting, window: window)
        let bottom = shell.maxY + NotebookTheme.headerToolbarGap - EditorToolbarLayout.margin
        return CGRect(x: 0, y: 0, width: window.bounds.width, height: bottom)
    }

    private func showScreen(
        _ session: NotebookSession, in scene: UIWindowScene
    ) -> (UIWindow, AppearanceTrackingHostingController<NotebookScreen>) {
        let window = UIWindow(windowScene: scene)
        let hosting = AppearanceTrackingHostingController(rootView: NotebookScreen(session: session))
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        hosting.view.layoutIfNeeded()
        return (window, hosting)
    }

    /// Shows `hosting` in `window`, returning once it has appeared and closing the window if it never does.
    private func show(_ hosting: some AppearanceTracking, in window: UIWindow) async throws {
        window.frame = Self.windowFrame
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        hosting.view.layoutIfNeeded()
        do {
            try await NotebookTestFixtures.waitUntilAppeared(hosting)
        } catch {
            close(window)
            throw error
        }
    }

    private func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    /// The scene-owned store, with its tool and toolbar restored in memory and on disk when the test ends.
    private func preserveSceneStore(for scene: UIWindowScene) -> NotebookSceneToolStore {
        NotebookTestFixtures.restoreSceneToolDefaults(for: scene, after: self)
        let owner = NotebookSceneToolStore.owner(for: scene)
        let tool = owner.tool
        let toolbar = owner.toolbar
        let inkRowOpen = owner.isInkRowOpen
        // Teardown blocks run last-registered first, so the stored keys are restored after these writes.
        addTeardownBlock { @MainActor in
            owner.update { $0 = tool }
            owner.updateToolbar(toolbar)
            owner.setInkRowOpen(inkRowOpen)
        }
        owner.setInkRowOpen(false)
        return owner
    }

    private func toolbarFrame(for preferences: EditorToolbarPreferences, in area: CGRect) -> CGRect {
        NotebookToolbarComposition(preferences: preferences, horizontalSizeClass: .regular)
            .frame(in: area)
    }

    /// The middle of the rail's first row, which shows whether or not the second does: of the tools
    /// along the top or floating, and of the tool column beside the grip on end.
    private func firstRowCentre(for preferences: EditorToolbarPreferences, in area: CGRect) -> CGPoint {
        let composition = NotebookToolbarComposition(preferences: preferences, horizontalSizeClass: .regular)
        let room = composition.frame(in: area)
        let column = NotebookToolbarComposition.gripColumnWidth + NotebookTheme.rowHeight / 2
        return switch composition.orientation {
        case .horizontal: CGPoint(x: room.midX, y: room.minY + NotebookTheme.rowHeight / 2)
        case .leftEdge: CGPoint(x: room.minX + column, y: room.midY)
        case .rightEdge: CGPoint(x: room.maxX - column, y: room.midY)
        }
    }

    /// The middle of the room the rail keeps for its second row: below the tools, or beside them
    /// toward the page on end.
    private func secondRowCentre(for preferences: EditorToolbarPreferences, in area: CGRect) -> CGPoint {
        let composition = NotebookToolbarComposition(preferences: preferences, horizontalSizeClass: .regular)
        let room = composition.frame(in: area)
        let offset = NotebookTheme.rowHeight + NotebookTheme.rowSpacing + NotebookTheme.rowHeight / 2
        return switch composition.orientation {
        case .horizontal: CGPoint(x: room.midX, y: room.minY + offset)
        case .leftEdge: CGPoint(x: room.minX + NotebookToolbarComposition.gripColumnWidth + offset, y: room.midY)
        case .rightEdge: CGPoint(x: room.maxX - NotebookToolbarComposition.gripColumnWidth - offset, y: room.midY)
        }
    }

    /// The window as drawn, masks and all.
    private func renderedWindow(_ window: UIWindow) throws -> RenderedPixels {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return try RenderedPixels(try XCTUnwrap(image.cgImage), scale: image.scale)
    }

    /// Whether the window shows only plain shell from `start` to `end` across the middle of
    /// `strip`, compared at each height with the shell just past the strip's end.
    private func showsPlainShell(_ pixels: RenderedPixels, across strip: CGRect, from start: CGFloat, to end: CGFloat) -> Bool {
        for y in stride(from: strip.midY - 12, through: strip.midY + 12, by: 2) {
            let shell = pixels.rgba(at: CGPoint(x: strip.maxX + 3, y: y))
            for x in stride(from: start, through: end, by: 1) {
                let pixel = pixels.rgba(at: CGPoint(x: x, y: y))
                let difference = zip(pixel.prefix(3), shell.prefix(3)).map { abs(Int($0) - Int($1)) }.max() ?? 0
                if difference > 6 { return false }
            }
        }
        return true
    }

    /// Glyph pixels across the middle of `strip`, from `start` to `end` along it.
    private func darkPixels(
        _ pixels: RenderedPixels, along strip: CGRect, isVertical: Bool, from start: CGFloat, to end: CGFloat
    ) -> Int {
        guard end > start else { return 0 }
        let band = isVertical
            ? CGRect(x: strip.midX - 12, y: strip.minY + start, width: 24, height: end - start)
            : CGRect(x: strip.minX + start, y: strip.midY - 12, width: end - start, height: 24)
        return darkPixelCount(pixels, in: band)
    }

    /// The scrolling strip holding the tool keys.
    private func toolStrip(in fixture: NotebookToolbarHostFixture) throws -> UIScrollView {
        func eraser(_ view: UIView) -> UIView? {
            (view is NotebookEraserMenuButton ? view : nil) ?? view.subviews.lazy.compactMap(eraser).first
        }
        let key = try XCTUnwrap(eraser(fixture.host))
        return try XCTUnwrap(fixture.strips.first { key.isDescendant(of: $0) })
    }

    /// The bounds of the pixels in `rect` dark enough to be a glyph on the shell.
    private func darkExtent(_ pixels: RenderedPixels, in rect: CGRect) -> CGSize {
        var bounds = CGRect.null
        for x in stride(from: rect.minX, through: rect.maxX, by: 0.5) {
            for y in stride(from: rect.minY, through: rect.maxY, by: 0.5) {
                let pixel = pixels.rgba(at: CGPoint(x: x, y: y)).prefix(3).map { Double($0) / 255 }
                if 0.2126 * pixel[0] + 0.7152 * pixel[1] + 0.0722 * pixel[2] < 0.45 {
                    bounds = bounds.union(CGRect(x: x, y: y, width: 0.5, height: 0.5))
                }
            }
        }
        return bounds.isNull ? .zero : bounds.size
    }

    /// Pixels in `rect` dark enough to be a glyph on the shell.
    /// The contrast of a key's mark with what lies right around it: the median of the darkest 1% of
    /// the key's inner pixels against the median of four small squares just inside its corners, on the
    /// glass or on a selected key's lens. Every mark on the rail is darker than its glass.
    private func markContrast(in key: CGRect, of pixels: RenderedPixels) -> Double {
        func linear(_ channel: UInt8) -> Double {
            let value = Double(channel) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        func luminance(_ pixel: [UInt8]) -> Double {
            0.2126 * linear(pixel[0]) + 0.7152 * linear(pixel[1]) + 0.0722 * linear(pixel[2])
        }
        func samples(_ rect: CGRect) -> [Double] {
            stride(from: rect.minX, to: rect.maxX, by: 0.5).flatMap { x in
                stride(from: rect.minY, to: rect.maxY, by: 0.5).map { luminance(pixels.rgba(at: CGPoint(x: x, y: $0))) }
            }.sorted()
        }
        let side: CGFloat = 4
        let inset: CGFloat = 7
        let corners = [
            CGPoint(x: key.minX + inset, y: key.minY + inset), CGPoint(x: key.maxX - inset - side, y: key.minY + inset),
            CGPoint(x: key.minX + inset, y: key.maxY - inset - side), CGPoint(x: key.maxX - inset - side, y: key.maxY - inset - side),
        ].flatMap { samples(CGRect(origin: $0, size: CGSize(width: side, height: side))) }.sorted()
        let ground = corners[corners.count / 2]
        let inner = samples(key.insetBy(dx: 6, dy: 6))
        let darkest = inner.prefix(max(1, inner.count / 100))
        let mark = darkest[darkest.startIndex + darkest.count / 2]
        return (max(ground, mark) + 0.05) / (min(ground, mark) + 0.05)
    }

    private func darkPixelCount(_ pixels: RenderedPixels, in rect: CGRect) -> Int {
        var count = 0
        for x in stride(from: rect.minX, through: rect.maxX, by: 1) {
            for y in stride(from: rect.minY, through: rect.maxY, by: 1) {
                let pixel = pixels.rgba(at: CGPoint(x: x, y: y)).prefix(3).map { Double($0) / 255 }
                if 0.2126 * pixel[0] + 0.7152 * pixel[1] + 0.0722 * pixel[2] < 0.45 { count += 1 }
            }
        }
        return count
    }

    /// Lets the second row finish opening or closing.
    private func settleSecondRow(_ view: UIView) async throws {
        try await Task.sleep(for: .seconds(NotebookTheme.inkRowDuration + 0.15))
        try await settle(view)
    }

    /// Lets SwiftUI and UIKit finish any pending update and layout passes.
    private func settle(_ view: UIView) async throws {
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(20))
            view.layoutIfNeeded()
        }
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

@MainActor
private final class BodyCounter {
    var bodies = 0
    let view = UIView()
}

private struct CountedContent: View {
    let counter: BodyCounter
    let action: () -> Void

    var body: some View {
        let _ = counter.bodies += 1
        CounterProbe(view: counter.view)
            .onTapGesture(perform: action)
    }
}

private struct CounterProbe: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView { view }

    func updateUIView(_ view: UIView, context: Context) {}
}

/// Records every distinct size it is laid out at.
private final class LayoutProbeView: UIView {
    private(set) var laidOutSizes: [CGSize] = []

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, laidOutSizes.last != bounds.size else { return }
        laidOutSizes.append(bounds.size)
    }
}

private struct LayoutProbe: UIViewRepresentable {
    let view: LayoutProbeView

    func makeUIView(context: Context) -> LayoutProbeView { view }

    func updateUIView(_ view: LayoutProbeView, context: Context) {}
}
