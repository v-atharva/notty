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
        let usable = CGRect(x: 0, y: 0, width: 1_024, height: 1_200)
        let dockSize = NotebookToolbarComposition(preferences: .standard, horizontalSizeClass: .regular)
            .toolbarSize(forHostWidth: usable.width)
        let handle = NotebookTheme.collapsedHandleSize
        let resolver = NotebookToolbarDragResolver(
            placement: .floating(CGPoint(x: 0.5, y: 0.6)), size: handle, dockSize: dockSize, usable: usable
        )
        let markers = NotebookDockMarkers.frames(slotSize: dockSize, in: usable)
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
        let size = NotebookToolbarComposition(preferences: .standard, horizontalSizeClass: .regular)
            .toolbarSize(forHostWidth: usable.width)
        XCTAssertEqual(NotebookDockMarkers.frames(slotSize: size, in: usable).count, 1, "One slot stands for every dock.")
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
        let hosting = UIHostingController(
            rootView: ZStack(alignment: .topLeading) { content }.frame(width: usable.width, height: usable.height)
        )
        hosting.safeAreaRegions = []
        let window = UIWindow(windowScene: try NotebookTestFixtures.windowScene())
        show(hosting, in: window)
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
        let canvas = CGRect(x: 0, y: 100, width: 1_000, height: 1_000)
        let size = CGSize(width: 600, height: 112)
        func toolbar(minY: CGFloat) -> CGRect { CGRect(origin: CGPoint(x: 200, y: minY), size: size) }

        let atTheBottom = toolbar(minY: canvas.maxY - 12 - size.height)
        XCTAssertEqual(
            NotebookToolbarObstruction.insets(toolbar: atTheBottom, canvas: canvas),
            UIEdgeInsets(top: 0, left: 0, bottom: canvas.maxY - atTheBottom.minY, right: 0)
        )
        let atTheTop = toolbar(minY: canvas.minY + 12)
        XCTAssertEqual(
            NotebookToolbarObstruction.insets(toolbar: atTheTop, canvas: canvas),
            UIEdgeInsets(top: atTheTop.maxY - canvas.minY, left: 0, bottom: 0, right: 0)
        )
        let quarterDown = toolbar(minY: canvas.minY + canvas.height / 4 - size.height / 2)
        XCTAssertEqual(
            NotebookToolbarObstruction.insets(toolbar: quarterDown, canvas: canvas), .zero,
            "The default floating position leaves the page where it opens."
        )
        XCTAssertEqual(
            NotebookToolbarObstruction.insets(toolbar: toolbar(minY: canvas.minY + size.height), canvas: canvas),
            .zero
        )
        let handle = CGRect(origin: CGPoint(x: 20, y: canvas.maxY - 12 - 44), size: NotebookTheme.collapsedHandleSize)
        XCTAssertEqual(
            NotebookToolbarObstruction.insets(toolbar: handle, canvas: canvas).bottom,
            canvas.maxY - handle.minY, "A collapsed handle at the edge reserves its own height."
        )
        XCTAssertEqual(
            NotebookToolbarObstruction.insets(toolbar: toolbar(minY: 2_000), canvas: canvas), .zero
        )
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
        let hosting = UIHostingController(rootView: NotebookToolbarHost { LayoutProbe(view: probe) })
        hosting.safeAreaRegions = []
        show(hosting, in: window)
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

    // MARK: - Production wiring

    func testNotebookScreenSharesTheSceneStoreWithItsCanvasAndShowsLeatherBehindTheNavigationBar() async throws {
        let id = UUID()
        let root = NotebookTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let stored = try await NotebookTestFixtures.stored(id: id)
        let probe = try NotebookStorageProbe(stored: stored, recoveryRoot: root)
        let storage = await probe.storage(notebookID: id)
        let session = NotebookSession(notebookID: id, openStorage: { storage })
        let scene = try NotebookTestFixtures.windowScene()
        let owner = preserveSceneStore(for: scene)

        let window = UIWindow(windowScene: scene)
        let hosting = UIHostingController(rootView: NotebookScreen(session: session))
        show(hosting, in: window)
        defer {
            session.flush()
            close(window)
        }
        try await NotebookTestFixtures.waitUntil(seconds: 10) {
            guard let controller = NotebookTestFixtures.notebookController(in: hosting) else { return false }
            return controller.isCanvasVisible && controller.canvasView.isFirstResponder && owner.isToolbarAvailable
        }
        let controller = try XCTUnwrap(NotebookTestFixtures.notebookController(in: hosting))
        XCTAssertTrue(controller.drawingToolStore === owner, "The screen's canvas uses the scene's store.")

        let hostArea = controller.view.convert(controller.view.bounds, to: window)
        let toolbar = toolbarFrame(for: owner.toolbar, in: hostArea)
        try await NotebookTestFixtures.waitUntil {
            !NotebookTestFixtures.hit(toolbar.center, in: window).isDescendant(of: controller.view)
        }

        let family: EditorInkFamily = owner.tool.kind == .ink(.marker) ? .pencil : .marker
        NotebookToolbarActions(store: owner).select(.ink(family))
        XCTAssertEqual((controller.canvasView.tool as? PKInkingTool)?.inkType, family.inkType)

        let navigationBar = try XCTUnwrap(NotebookTestFixtures.navigationController(in: hosting)?.navigationBar)
        let bar = navigationBar.convert(navigationBar.bounds, to: window)
        let rendered = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let pixels = try RenderedPixels(try XCTUnwrap(rendered.cgImage), scale: rendered.scale)
        // Between the wordmark and the title, where only the band backdrop shows.
        let sample = pixels.rgba(at: CGPoint(x: bar.minX + bar.width * 0.3, y: bar.midY)).map { Double($0) / 255 }
        let luminance = 0.2126 * sample[0] + 0.7152 * sample[1] + 0.0722 * sample[2]
        XCTAssertLessThan(luminance, 0.45, "Leather shows behind the navigation bar, not ivory.")
        XCTAssertGreaterThan(sample[0], sample[2], "The band is warm leather.")
    }

    // MARK: - Fixtures

    private func show(_ hosting: UIViewController, in window: UIWindow) {
        window.frame = Self.windowFrame
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        hosting.view.layoutIfNeeded()
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
        let composition = NotebookToolbarComposition(preferences: preferences, horizontalSizeClass: .regular)
        return EditorToolbarLayout.frame(
            for: preferences.placement, size: composition.toolbarSize(forHostWidth: area.width), in: area
        )
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
