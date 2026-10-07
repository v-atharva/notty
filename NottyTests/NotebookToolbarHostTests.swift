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

        let pastTheTrailingCorner = CGSize(width: 3_000, height: -2_000)
        XCTAssertEqual(resolver.targetedDock(translation: pastTheTrailingCorner), .topTrailing)
        XCTAssertEqual(resolver.placement(translation: pastTheTrailingCorner), .docked(.topTrailing))

        let session = NotebookToolbarDragSession()
        session.move(to: pastTheTop, resolver: resolver)
        XCTAssertEqual(session.previewFrame, preview)
        XCTAssertEqual(session.targetedDock, .topCenter, "The highlighted slot matches the release result.")
    }

    func testSnapFeedbackPlaysOnlyWhenTheDockChanges() {
        let usable = CGRect(x: 0, y: 0, width: 1_024, height: 1_200)
        let size = CGSize(width: 640, height: 112)
        let docked = NotebookToolbarDragResolver(placement: .docked(.topCenter), size: size, usable: usable)
        XCTAssertFalse(docked.snapsToNewDock(.docked(.topCenter)), "Dropped back on its own dock.")
        XCTAssertTrue(docked.snapsToNewDock(.docked(.topLeading)))
        XCTAssertFalse(docked.snapsToNewDock(.floating(CGPoint(x: 0.5, y: 0.5))))
        XCTAssertFalse(docked.snapsToNewDock(docked.placement(translation: CGSize(width: 10, height: 6))))

        let floating = NotebookToolbarDragResolver(placement: .floating(CGPoint(x: 0.5, y: 0.5)), size: size, usable: usable)
        XCTAssertTrue(floating.snapsToNewDock(.docked(.topCenter)))
        XCTAssertFalse(floating.snapsToNewDock(.floating(CGPoint(x: 0.2, y: 0.5))))
    }

    func testCollapsedHandleDroppedOnADockMarkerDocksThere() throws {
        // A 12.9-inch iPad in landscape keeps its docks apart.
        let usable = CGRect(x: 0, y: 0, width: 1_366, height: 1_000)
        let rail = NotebookToolbarComposition(preferences: .standard, horizontalSizeClass: .regular)
            .rail(forHostWidth: usable.width)
        XCTAssertFalse(rail.docksShared)
        let dockSize = rail.size
        let handle = NotebookTheme.collapsedHandleSize
        let resolver = NotebookToolbarDragResolver(
            placement: .floating(CGPoint(x: 0.5, y: 0.6)), size: handle, dockSize: dockSize, usable: usable
        )
        let markers = NotebookDockMarkers.frames(slotSize: dockSize, in: usable, docksShared: false)
        for dock in EditorToolbarDock.allCases {
            let marker = try XCTUnwrap(markers[dock])
            // The handle at the start, the middle and the end of the marker.
            for centreX in [marker.minX + handle.width / 2, marker.midX, marker.maxX - handle.width / 2] {
                let translation = CGSize(
                    width: centreX - resolver.startFrame.midX, height: marker.midY - resolver.startFrame.midY
                )
                XCTAssertEqual(resolver.targetedDock(translation: translation), dock, "\(dock) \(centreX)")
                XCTAssertEqual(resolver.placement(translation: translation), .docked(dock), "\(dock) \(centreX)")
            }
        }
        let belowTheMarkers = CGSize(width: 0, height: dockSize.height + 120 - resolver.startFrame.minY)
        XCTAssertNil(resolver.targetedDock(translation: belowTheMarkers), "Away from the markers the handle floats.")
    }

    func testDropOnDocksThatShareOneFrameKeepsTheStartingDock() {
        // Narrower than the toolbar, as in Slide Over: every dock has the same frame.
        let usable = CGRect(x: 0, y: 0, width: 500, height: 900)
        let rail = NotebookToolbarComposition(preferences: .standard, horizontalSizeClass: .regular)
            .rail(forHostWidth: usable.width)
        let size = rail.size
        XCTAssertTrue(rail.docksShared)
        XCTAssertEqual(
            NotebookDockMarkers.frames(slotSize: size, in: usable, docksShared: rail.docksShared).count, 1,
            "One slot stands for every dock."
        )
        let nudge = CGSize(width: 8, height: 4)
        for dock in EditorToolbarDock.allCases {
            let resolver = NotebookToolbarDragResolver(placement: .docked(dock), size: size, usable: usable)
            let placement = resolver.placement(translation: nudge)
            XCTAssertEqual(placement, .docked(dock), "A drop in place keeps \(dock).")
            XCTAssertFalse(resolver.snapsToNewDock(placement), "\(dock): no snap feedback for a drop in place.")
        }
        let floating = NotebookToolbarDragResolver(
            placement: .floating(CGPoint(x: 0.5, y: 0.5)), size: size, usable: usable
        )
        let toTheTop = CGSize(width: 0, height: -1_000)
        XCTAssertEqual(floating.placement(translation: toTheTop), .docked(.topCenter), "A new dock is the standard one.")
    }

    /// On a 12.9-inch iPad in portrait the docks lie too close to tell apart, so the rail rests in
    /// the centre whichever dock is stored, and a drop on the one slot keeps that dock.
    func testSharedDockSlotDropKeepsTheStoredDock() throws {
        let usable = CGRect(x: 0, y: 0, width: 1_024, height: 1_200)
        let composition = NotebookToolbarComposition(preferences: .standard, horizontalSizeClass: .regular)
        let rail = composition.rail(forHostWidth: usable.width)
        XCTAssertTrue(rail.docksShared)
        let centre = EditorToolbarLayout.frame(for: .docked(.topCenter), size: rail.size, in: usable)
        XCTAssertNotEqual(
            EditorToolbarLayout.frame(for: .docked(.topLeading), size: rail.size, in: usable), centre,
            "The docks would differ by a few points without sharing."
        )
        let markers = NotebookDockMarkers.frames(slotSize: rail.size, in: usable, docksShared: true)
        XCTAssertEqual(markers, [.topCenter: centre], "One centred slot is drawn.")

        for dock in EditorToolbarDock.allCases {
            XCTAssertEqual(composition.frame(for: .docked(dock), in: usable), centre, "\(dock) rests in the centre.")
            let resolver = NotebookToolbarDragResolver(
                placement: .docked(dock), size: rail.size, dockSize: rail.size, usable: usable, docksShared: true
            )
            XCTAssertEqual(resolver.startFrame, centre, "\(dock) is dragged from where it shows.")
            // Dropped on the slot, wherever on it the toolbar lands.
            for nudge in [CGSize(width: -30, height: 10), CGSize(width: 6, height: 4), CGSize(width: 40, height: 20)] {
                let placement = resolver.placement(translation: nudge)
                XCTAssertEqual(placement, .docked(dock), "\(dock) \(nudge): the stored dock is kept.")
                XCTAssertFalse(resolver.snapsToNewDock(placement))
                XCTAssertEqual(resolver.targetedDock(translation: nudge), dock)
            }
            let away = CGSize(width: 0, height: 500)
            guard case .floating = resolver.placement(translation: away) else {
                return XCTFail("\(dock): a drop away from the slot floats.")
            }
        }

        let floating = NotebookToolbarDragResolver(
            placement: .floating(CGPoint(x: 0.5, y: 0.5)), size: rail.size, dockSize: rail.size, usable: usable,
            docksShared: true
        )
        let toTheSlot = CGSize(width: centre.midX - floating.startFrame.midX - 20, height: centre.midY - floating.startFrame.midY + 8)
        let docked = floating.placement(translation: toTheSlot)
        XCTAssertEqual(docked, .docked(.topCenter), "A floating rail dropped on the slot docks in the centre.")
        XCTAssertTrue(floating.snapsToNewDock(docked))

        let handle = NotebookToolbarDragResolver(
            placement: .floating(CGPoint(x: 0.5, y: 0.6)), size: NotebookTheme.collapsedHandleSize,
            dockSize: rail.size, usable: usable, docksShared: true
        )
        let atTheSlotsStart = CGSize(
            width: centre.minX + NotebookTheme.collapsedHandleSize.width / 2 - handle.startFrame.midX,
            height: centre.midY - handle.startFrame.midY
        )
        XCTAssertEqual(handle.placement(translation: atTheSlotsStart), .docked(.topCenter),
            "A handle at either end of the shared slot docks in the centre too.")
    }

    /// Where the docks share one slot, a drag shows that slot alone, filled and outlined solid as
    /// the frame the rail lands in, with nothing beside it.
    func testSharedDocksDrawOneCentredTarget() throws {
        let usable = CGRect(x: 0, y: 0, width: 834, height: 400)
        let rail = NotebookToolbarComposition(preferences: .standard, horizontalSizeClass: .regular).rail(forHostWidth: 834)
        XCTAssertTrue(rail.docksShared)
        let drag = NotebookToolbarDragSession()
        let resolver = NotebookToolbarDragResolver(
            placement: .docked(.topTrailing), size: rail.size, usable: usable, docksShared: true
        )
        drag.move(to: CGSize(width: 30, height: 6), resolver: resolver)
        XCTAssertEqual(drag.targetedDock, .topTrailing, "The stored dock stays targeted on the shared slot.")
        let pixels = try RenderedPixels(rendering:
            NotebookDockTargets(drag: drag, slotSize: rail.size, usable: usable, docksShared: true)
                .frame(width: usable.width, height: usable.height)
        )
        let slot = EditorToolbarLayout.frame(for: .docked(.topCenter), size: rail.size, in: usable)
        for x in [slot.minX + 20, slot.midX, slot.maxX - 20] {
            XCTAssertGreaterThan(pixels.rgba(at: CGPoint(x: x, y: slot.midY))[3], 100, "The slot is filled as targeted at \(x).")
        }
        let edge = stride(from: slot.midX - 60, through: slot.midX + 60, by: 1).map {
            pixels.rgba(at: CGPoint(x: $0, y: slot.minY + 1))
        }
        XCTAssertLessThan(
            (edge.map { Int($0[3]) }.max() ?? 0) - (edge.map { Int($0[3]) }.min() ?? 0), 8,
            "Its outline is solid, as the frame the rail lands in."
        )
        for point in [CGPoint(x: slot.minX - 6, y: slot.midY), CGPoint(x: slot.maxX + 6, y: slot.midY),
                      CGPoint(x: slot.midX, y: slot.maxY + 20)] {
            XCTAssertEqual(pixels.rgba(at: point)[3], 0, "Nothing is drawn beside the slot at \(point).")
        }
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
            session.move(to: translation, resolver: resolver)
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

    func testExpandedCanvasReservesHeaderAndHomeIndicatorApartFromTheToolbar() {
        let canvas = CGSize(width: 500, height: 900)
        // The control area in the canvas's own coordinates, below the header and above the home indicator.
        let controls = CGRect(x: 0, y: 96, width: 500, height: 784)
        let chrome = NotebookCanvasChrome(canvasSize: canvas, controlArea: controls)
        XCTAssertEqual(chrome, NotebookCanvasChrome(top: 96, bottom: 20, canvasSize: canvas))
        XCTAssertEqual(NotebookCanvasChrome(canvasSize: canvas, controlArea: nil), .none)
        XCTAssertEqual(NotebookCanvasChrome(canvasSize: .zero, controlArea: controls), .none)

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
        let toolbar = toolbarFrame(for: owner.toolbar, in: host.bounds)
        try await NotebookTestFixtures.waitUntil {
            probe.window != nil && !NotebookTestFixtures.hit(toolbar.center, in: host).isDescendant(of: probe)
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
        XCTAssertTrue(store.isToolActive)
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
        XCTAssertTrue(actions.place(.docked(.topLeading)))
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

    /// Each placement reaches the canvas even when the next one follows within the same frame,
    /// which a per-frame change handler would drop as an update loop.
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

        for dock in EditorToolbarDock.allCases {
            actions.place(.docked(dock))
            try await settle(host)
            let toolbar = toolbarFrame(for: fixture.store.toolbar, in: host.bounds)
            XCTAssertEqual(fixture.canvasFrame, host.bounds)
            XCTAssertFalse(fixture.hit(toolbar.center).isDescendant(of: fixture.controller.view))
            XCTAssertTrue(fixture.hit(CGPoint(x: toolbar.midX, y: toolbar.minY / 2)).isDescendant(of: canvas))

            canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: 450), animated: false)
            try await NotebookTestFixtures.waitUntil { abs(CATransform3DGetAffineTransform(paper.contentLayer.transform).ty + 450) < 0.5 }
            XCTAssertEqual(toolbarFrame(for: fixture.store.toolbar, in: host.bounds), toolbar)
            XCTAssertFalse(fixture.hit(toolbar.center).isDescendant(of: fixture.controller.view))
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
            EditorToolbarPlacement.docked(.topCenter), .docked(.topLeading), .docked(.topTrailing),
            .floating(CGPoint(x: 0.4, y: 0.6))
        ] {
            actions.place(placement)
            XCTAssertEqual(fixture.canvasFrame.minY, 0, accuracy: 0.5)
            try await settle(host)
            let toolbar = toolbarFrame(for: store.toolbar, in: host.bounds)
            let grip = CGPoint(x: toolbar.minX + NotebookTheme.dragHandleHitSize.width / 2, y: toolbar.midY)
            let toolRow = CGPoint(x: toolbar.midX, y: toolbar.minY + NotebookTheme.rowHeight / 2)
            let inkRow = CGPoint(
                x: toolbar.midX, y: toolbar.minY + NotebookTheme.rowHeight + NotebookTheme.rowSpacing + NotebookTheme.rowHeight / 2
            )
            for point in [grip, toolRow, inkRow] {
                XCTAssertFalse(fixture.hit(point).isDescendant(of: controller.view), "\(placement) \(point)")
            }
            let belowTheToolbar = CGPoint(x: toolbar.midX, y: toolbar.maxY + EditorToolbarLayout.margin / 2)
            XCTAssertTrue(fixture.hit(belowTheToolbar).isDescendant(of: controller.canvasView), "\(placement)")
        }

        actions.setCollapsed(true)
        try await settle(host)
        let handle = toolbarFrame(for: store.toolbar, in: host.bounds)
        XCTAssertEqual(handle.size, NotebookTheme.collapsedHandleSize)
        XCTAssertFalse(fixture.hit(handle.center).isDescendant(of: controller.view), "The collapsed handle keeps its touches.")

        XCTAssertEqual(observations, 0, "Moving the overlay never reports a drawing change.")
        XCTAssertEqual(controller.canvasView.drawing.dataRepresentation(), drawing.dataRepresentation())
    }

    // MARK: - Collapsed handle

    func testRevealHandlePressesLikeAToolbarControlInsideItsOpaqueShell() throws {
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

        // Inside the shell but beside the glyph, where only the shell and the press well draw.
        let wellArea = CGPoint(x: inset + 3, y: size.height / 2)
        XCTAssertNotEqual(pressed.rgba(at: wellArea), rest.rgba(at: wellArea), "A press sinks the control.")
        for point in [wellArea, CGPoint(x: size.width / 2, y: inset + 2)] {
            XCTAssertEqual(rest.rgba(at: point)[3], 255, "The shell is opaque at rest.")
            XCTAssertEqual(pressed.rgba(at: point)[3], 255, "The shell stays opaque while pressed.")
        }
        // Outside the shell's rounded corner the press draws nothing.
        let corner = CGPoint(x: 1, y: 1)
        XCTAssertEqual(pressed.rgba(at: corner), rest.rgba(at: corner))
        XCTAssertLessThan(rest.rgba(at: corner)[3], 128, "The corner lies outside the shell.")
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
        let scrollWidth = row.scrollWidth(containerWidth: ink.bounds.width)
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
        let fixture = try await NotebookTestFixtures.mountToolbarHost(width: 678)
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
            let scrollWidth = row.scrollWidth(containerWidth: width)
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

    func testFloatingRailHoldsItsCollapseKeyUnderTheGrip() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost()
        defer { fixture.close() }
        let host = fixture.host
        let actions = NotebookToolbarActions(store: fixture.store)
        func darkPixels(in band: ClosedRange<CGFloat>, of rail: CGRect, _ pixels: RenderedPixels) -> Int {
            var count = 0
            for x in stride(from: rail.minX + 4, through: rail.minX + NotebookTheme.controlSize - 4, by: 1) {
                for y in stride(from: rail.minY + band.lowerBound, through: rail.minY + band.upperBound, by: 1) {
                    let pixel = pixels.rgba(at: CGPoint(x: x, y: y)).prefix(3).map { Double($0) / 255 }
                    if 0.2126 * pixel[0] + 0.7152 * pixel[1] + 0.0722 * pixel[2] < 0.45 { count += 1 }
                }
            }
            return count
        }
        let ridgesWhenFloating: ClosedRange<CGFloat> = 18...36
        let keyWhenFloating: ClosedRange<CGFloat> = 72...90

        try await settle(host)
        let docked = toolbarFrame(for: fixture.store.toolbar, in: host.bounds)
        let dockedPixels = try renderedWindow(fixture.window)
        XCTAssertEqual(darkPixels(in: ridgesWhenFloating, of: docked, dockedPixels), 0, "Docked, the ridges sit mid-column.")
        XCTAssertEqual(darkPixels(in: keyWhenFloating, of: docked, dockedPixels), 0, "Docked, there is no collapse key.")

        XCTAssertTrue(actions.place(.floating(CGPoint(x: 0.5, y: 0.5))))
        try await settle(host)
        let floating = toolbarFrame(for: fixture.store.toolbar, in: host.bounds)
        XCTAssertEqual(floating.size, docked.size, "Floating keeps the docked width.")
        let floatingPixels = try renderedWindow(fixture.window)
        XCTAssertGreaterThan(darkPixels(in: ridgesWhenFloating, of: floating, floatingPixels), 20, "The grip takes the top half.")
        XCTAssertGreaterThan(darkPixels(in: keyWhenFloating, of: floating, floatingPixels), 20, "The collapse key takes the bottom.")
        for y in [floating.minY + 27, floating.minY + 81] {
            let hit = fixture.hit(CGPoint(x: floating.minX + NotebookTheme.controlSize / 2, y: y))
            XCTAssertFalse(hit.isDescendant(of: fixture.controller.view))
            XCTAssertFalse(fixture.strips.contains { hit.isDescendant(of: $0) }, "The grip column is apart from the strips.")
        }
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
                .frame(for: store.toolbar.placement, in: fixture.host.bounds)
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
        let railCentre = CGPoint(x: rail.midX + 120, y: rail.midY)
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
        try await NotebookTestFixtures.waitUntil { (try? self.renderedWindow(fixture.window))?.rgba == shown.rgba }
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
        let railCentre = CGPoint(x: rail.midX + 120, y: rail.midY)
        let shown = try renderedWindow(fixture.window)

        for _ in 0..<20 {
            store.setToolsHidden(true)
            try await Task.sleep(for: .milliseconds(1))
            store.setToolsHidden(false)
            try await Task.sleep(for: .milliseconds(1))
        }
        try await NotebookTestFixtures.waitUntil { (try? self.renderedWindow(fixture.window))?.rgba == shown.rgba }
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
        XCTAssertFalse(fixture.hit(CGPoint(x: rail.midX, y: rail.midY)).isDescendant(of: fixture.controller.view),
            "The handle stands where the rail floated.")
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
        let besideHandle = CGPoint(x: rail.minX + 60, y: rail.midY)
        try await NotebookTestFixtures.waitUntil { !fixture.hit(besideHandle).isDescendant(of: fixture.controller.view) }
    }

    func testToolsOnlyFadeUnderReduceMotionAndTheStandInFollowsTheHide() {
        let standard = NotebookToolsTransition(reduceMotion: false)
        XCTAssertEqual(standard.hiddenOffset, -8, "Hiding tools rise a little as they fade.")
        XCTAssertEqual(standard.hide, .easeIn(duration: 0.18))
        XCTAssertEqual(standard.reveal, .spring(duration: 0.24, bounce: 0))
        XCTAssertEqual(standard.standInAppearance, .easeOut(duration: 0.15).delay(0.18), "The stand-in waits for the hide.")

        let reduced = NotebookToolsTransition(reduceMotion: true)
        XCTAssertEqual(reduced.hiddenOffset, 0, "Under Reduce Motion nothing moves.")
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
        try await NotebookTestFixtures.waitUntil {
            owner.overlayObstruction == .zero && abs(canvas.contentInset.top - header) < 0.5
        }
        try await settle(hosting.view)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: -canvas.contentInset.top), animated: false)

        window.frame = landscape
        try await NotebookTestFixtures.waitUntil {
            canvas.bounds.size == landscape.size && owner.overlayObstruction.top > 0
                && canvas.contentInset.top > header + 0.5
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
            canvas.contentInset.bottom, window.safeAreaInsets.bottom + NotebookTheme.endScrollMinimum, accuracy: 0.5,
            "The end-of-paper tab keeps room above the home indicator."
        )
        XCTAssertEqual(canvas.contentOffset.y, 0, accuracy: 0.5, "The page opens beneath the header and toolbar.")

        let paper = controller.paperView
        let drawing = canvas.drawing
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: -canvas.contentInset.top), animated: false)
        try await NotebookTestFixtures.waitUntil { paper.contentLayer.transform.m42 >= toolbar.maxY - 0.5 }
        XCTAssertEqual(canvas.contentOffset.y, -canvas.contentInset.top, accuracy: 0.5)
        XCTAssertEqual(canvas.drawing, drawing)
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
        XCTAssertGreaterThan(toolbar.minY, bar.maxY)
        try await NotebookTestFixtures.waitUntil {
            let hit = NotebookTestFixtures.hit(toolbar.center, in: window)
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
        XCTAssertFalse(NotebookTestFixtures.hit(toolbar.center, in: window).isDescendant(of: controller.view))
        let exposedPoint = CGPoint(x: toolbar.midX, y: toolbar.maxY + 20)
        let exposedHit = NotebookTestFixtures.hit(exposedPoint, in: window)
        XCTAssertTrue(exposedHit.isDescendant(of: canvas), "Exposed paper hit: \(exposedHit)")
        XCTAssertEqual(canvas.contentInset.top, toolbar.maxY, accuracy: 0.5,
            "The canvas adds the toolbar to the header. Canvas: \(canvasFrame), host: \(hostArea), "
                + "toolbar: \(toolbar), obstruction: \(owner.overlayObstruction)")
        XCTAssertEqual(canvas.contentInset.top - owner.overlayObstruction.top, bar.maxY, accuracy: 0.5)
        XCTAssertEqual(
            canvas.contentInset.bottom, window.safeAreaInsets.bottom + NotebookTheme.endScrollMinimum, accuracy: 0.5,
            "The end-of-paper tab keeps room above the home indicator."
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
        // Teardown blocks run last-registered first, so the stored keys are restored after these writes.
        addTeardownBlock { @MainActor in
            owner.update { $0 = tool }
            owner.updateToolbar(toolbar)
        }
        return owner
    }

    private func toolbarFrame(for preferences: EditorToolbarPreferences, in area: CGRect) -> CGRect {
        NotebookToolbarComposition(preferences: preferences, horizontalSizeClass: .regular)
            .frame(for: preferences.placement, in: area)
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

    /// Pixels in `rect` dark enough to be a glyph on the shell.
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
