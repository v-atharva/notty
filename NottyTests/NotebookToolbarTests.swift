import Combine
import NottyCore
import PencilKit
import SwiftUI
import UIKit
import XCTest
@testable import Notty

@MainActor
final class NotebookToolbarTests: XCTestCase {
    // MARK: - Actions

    func testToolbarActionsUpdateTheStoreAndTheMountedCanvas() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost()
        defer { fixture.close() }
        let canvas = fixture.controller.canvasView
        let actions = NotebookToolbarActions(store: fixture.store)
        XCTAssertTrue(actions.isEnabled)

        for family in EditorInkFamily.allCases {
            actions.select(.ink(family))
            XCTAssertEqual(fixture.store.tool.kind, .ink(family))
            XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, family.inkType)
        }

        actions.select(.eraser(.bitmap))
        XCTAssertEqual(fixture.store.tool.kind, .eraser(.bitmap))
        XCTAssertEqual((canvas.tool as? PKEraserTool)?.eraserType, .bitmap)
        actions.select(.ink(.pen))
        actions.selectEraser()
        XCTAssertEqual(fixture.store.tool.kind, .eraser(.bitmap), "The eraser button restores the last eraser mode.")
        actions.select(.eraser(.vector))
        XCTAssertEqual((canvas.tool as? PKEraserTool)?.eraserType, .vector)

        actions.select(.lasso)
        XCTAssertEqual(fixture.store.tool.kind, .lasso)
        XCTAssertTrue(canvas.tool is PKLassoTool)

        actions.toggleRuler()
        XCTAssertTrue(fixture.store.tool.isRulerActive)
        XCTAssertTrue(canvas.isRulerActive)
        actions.toggleRuler()
        XCTAssertFalse(canvas.isRulerActive)

        let preset = try XCTUnwrap(EditorInkCatalog.presets.first { $0.family == .fountainPen })
        actions.apply(preset)
        XCTAssertEqual(fixture.store.tool.activePresetID, preset.id)
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, .fountainPen)

        actions.select(.lasso)
        let swatch = EditorInkCatalog.swatches[2]
        actions.selectColor(swatch)
        XCTAssertEqual(fixture.store.tool.kind, .ink(.fountainPen), "Choosing a colour returns to the last ink.")
        XCTAssertEqual(fixture.store.tool.color, swatch)
        XCTAssertNil(fixture.store.tool.activePresetID)
        let ink = try XCTUnwrap(canvas.tool as? PKInkingTool)
        var red: CGFloat = 0
        ink.color.getRed(&red, green: nil, blue: nil, alpha: nil)
        XCTAssertEqual(Double(red), swatch.red, accuracy: 0.01)

        actions.selectWidth(.bold)
        XCTAssertEqual(fixture.store.tool.widthStep, .bold)
        let range = PKInkingTool.InkType.fountainPen.validWidthRange
        let expected = EditorInkCatalog.width(for: .bold, in: Double(range.lowerBound)...Double(range.upperBound))
        XCTAssertEqual(Double(try XCTUnwrap(canvas.tool as? PKInkingTool).width), expected, accuracy: 0.01)
    }

    func testUnavailableToolbarIsNonInteractiveAndChangesNothing() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost()
        defer { fixture.close() }
        let store = fixture.store
        let actions = NotebookToolbarActions(store: store)
        XCTAssertTrue(actions.isEnabled)
        assertPresentedAsAvailable(actions)

        for gate in [NotebookInputGate.failed, .recovering, .readOnly] {
            fixture.controller.setInputGate(gate)
            XCTAssertFalse(store.isToolbarAvailable)
            XCTAssertFalse(actions.isEnabled)
            assertPresentedAsUnavailable(actions)
            assertActionsChangeNothing(actions, store: store)
            fixture.controller.setInputGate(.open)
            XCTAssertTrue(actions.isEnabled)
            assertPresentedAsAvailable(actions)
        }

        fixture.controller.setPaletteSuppressed(true)
        XCTAssertFalse(actions.isEnabled)
        assertPresentedAsUnavailable(actions)
        assertActionsChangeNothing(actions, store: store)
        fixture.controller.setPaletteSuppressed(false)
        XCTAssertTrue(actions.isEnabled)

        let detached = NotebookTestFixtures.toolStore()
        XCTAssertFalse(NotebookToolbarActions(store: detached).isEnabled)
        assertActionsChangeNothing(NotebookToolbarActions(store: detached), store: detached)
    }

    func testUnavailableToolbarDisablesEveryControlItContains() async throws {
        let (store, owner) = availableStore()
        defer { store.detach(owner) }
        let probe = EnabledProbe()
        let composition = NotebookToolbarComposition(preferences: store.toolbar, horizontalSizeClass: .regular)
        let hosting = AppearanceTrackingHostingController(
            rootView: NotebookToolbar(
                store: store, composition: composition, rail: composition.rail(forHostWidth: 800), collapse: {}
            ) {
                EnabledProbeView(probe: probe)
            }
        )
        let scene = try NotebookTestFixtures.windowScene()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 800, height: 200)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await NotebookTestFixtures.waitUntilAppeared(hosting)

        try await NotebookTestFixtures.waitUntil { probe.isEnabled == true }
        store.setToolbarAvailable(false, for: owner)
        try await NotebookTestFixtures.waitUntil { probe.isEnabled == false }
        store.setToolbarAvailable(true, for: owner)
        try await NotebookTestFixtures.waitUntil { probe.isEnabled == true }
    }

    /// A hiding rail's keys leave keyboard focus as the hide begins, between strokes, rather than
    /// when the fade ends, and are live again from the first frame of a reveal.
    func testRailKeysLeaveKeyboardFocusAsTheHideBegins() async throws {
        for (hiddenAmount, isHidden) in [(0.0, false), (0.0, true), (0.5, true), (1.0, true), (0.5, false)] {
            let probe = EnabledProbe()
            let hosting = AppearanceTrackingHostingController(
                rootView: EnabledProbeView(probe: probe)
                    .modifier(NotebookRailFade(hiddenAmount: hiddenAmount, offset: CGSize(width: 0, height: -8), isHidden: isHidden))
            )
            let window = try NotebookTestFixtures.window(showing: hosting, width: 200)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            try await NotebookTestFixtures.waitUntilAppeared(hosting)
            try await NotebookTestFixtures.waitUntil { probe.isEnabled != nil }
            XCTAssertEqual(probe.isEnabled, !isHidden, "\(hiddenAmount) of the way, heading \(isHidden ? "out" : "in")")
        }
    }

    /// In the mounted toolbar a hidden rail's keys are disabled too, so keyboard focus cannot reach
    /// keys nobody can see, and they come back with the tools.
    func testAHiddenRailInTheHostDisablesItsKeys() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost()
        defer { fixture.close() }
        let key = try eraserKey(in: fixture.host)
        XCTAssertTrue(key.isEnabled)
        fixture.store.setToolsHidden(true)
        try await NotebookTestFixtures.waitUntil { !key.isEnabled }
        fixture.store.setToolsHidden(false)
        try await NotebookTestFixtures.waitUntil { key.isEnabled }
    }

    /// Disabled as the hide begins, the keys still fade out as they were: no key is drawn again in
    /// the disabled tone or without its selection, so the fade does no work beyond its opacity.
    func testAHidingRailsKeysFadeOutUnchanged() throws {
        let placeholder = try XCTUnwrap(NotebookUpcomingFeature.placed(.toolStrip).first)
        let keys = HStack(spacing: 0) {
            Button {} label: { NotebookToolGlyph(symbol: "pencil.tip", isSelected: true) }
                .buttonStyle(NotebookKeyStyle(isSelected: true))
            Button {} label: { NotebookToolGlyph(symbol: "lasso", isSelected: false) }
                .buttonStyle(NotebookKeyStyle())
            NotebookPresetChip(preset: EditorInkCatalog.presets[0], isSelected: true) {}
            NotebookUpcomingToolButton(feature: placeholder)
        }
        func drawn(isHidden: Bool) throws -> RenderedPixels {
            try RenderedPixels(rendering: keys.modifier(NotebookRailFade(hiddenAmount: 0, offset: CGSize(width: 0, height: -8), isHidden: isHidden)))
        }
        let shown = try drawn(isHidden: false)
        XCTAssertTrue(try drawn(isHidden: true).rgba == shown.rgba, "A hiding rail's keys look as they did.")
        XCTAssertFalse(
            try RenderedPixels(rendering: keys.disabled(true)).rgba == shown.rgba,
            "Disabled for any other reason, the same keys change their look."
        )

        // A paused rail keeps its paused look while it hides.
        func paused(isHidden: Bool) throws -> RenderedPixels {
            try RenderedPixels(rendering: keys.disabled(true).environment(\.notebookKeysPaused, true)
                .modifier(NotebookRailFade(hiddenAmount: 0, offset: CGSize(width: 0, height: -8), isHidden: isHidden)))
        }
        XCTAssertTrue(try paused(isHidden: true).rgba == paused(isHidden: false).rgba)
    }

    /// The whole rail looks at the moment its hide begins exactly as it did shown: the swatches,
    /// width dots, eraser key, colour well, current-ink chip and chevrons as much as the keys
    /// above, whether writing is open or paused. Disabled for any other reason, the same rail
    /// changes its look, so the comparison would notice.
    func testAWholeRailLooksTheSameAsItsHideBegins() async throws {
        struct Case {
            let name: String
            let sizeClass: UserInterfaceSizeClass
            let width: CGFloat
            let isAvailable: Bool
            let tool: EditorToolKind
            var customColors = 0
        }
        let cases = [
            Case(name: "regular", sizeClass: .regular, width: 1_024, isAvailable: true, tool: .eraser(.vector)),
            Case(
                name: "regular with a scrolling ink row", sizeClass: .regular, width: 834, isAvailable: true,
                tool: .ink(.pen), customColors: 6
            ),
            Case(name: "compact", sizeClass: .compact, width: 420, isAvailable: true, tool: .eraser(.bitmap)),
            Case(name: "paused", sizeClass: .regular, width: 1_024, isAvailable: false, tool: .eraser(.vector)),
        ]
        for test in cases {
            let (store, owner) = availableStore()
            defer { store.detach(owner) }
            store.update { $0.select(test.tool) }
            store.updateToolbar(toolbar(customColors: test.customColors))
            if !test.isAvailable { store.setToolbarAvailable(false, for: owner) }
            let composition = NotebookToolbarComposition(preferences: store.toolbar, horizontalSizeClass: test.sizeClass)
            let rail = composition.rail(forHostWidth: test.width)
            if let inkRow = rail.inkRow {
                XCTAssertTrue(inkRow.slots.contains { if case .swatch = $0.item { true } else { false } }, test.name)
                XCTAssertTrue(rail.toolRow.slots.contains { $0.item == .width(.medium) }, "\(test.name): width dots")
            } else {
                XCTAssertTrue(composition.foldsInkOptions, "\(test.name): the current-ink chip stands in for the ink row")
            }
            if test.width < 1_000 {
                XCTAssertTrue(rail.toolRowOverflows || rail.inkRowOverflows, "\(test.name): a strip scrolls, with its chevron")
            }

            func render(hiding: Bool = false, disabled: Bool = false) async throws -> RenderedPixels {
                let shown = try await showRail(
                    store: store, sizeClass: test.sizeClass, width: test.width, hiding: hiding, disabled: disabled
                )
                defer { shown.close() }
                return try await shown.settledRender()
            }
            let shown = try await render()
            let unchanged = differingPoints(shown, try await render())
            XCTAssertTrue(unchanged.isEmpty, "\(test.name): \(unchanged.count) points differ between two renders")
            let hiding = differingPoints(shown, try await render(hiding: true))
            XCTAssertTrue(hiding.isEmpty, "\(test.name): \(hiding.count) points change as the hide begins")
            if test.isAvailable {
                let disabled = differingPoints(shown, try await render(disabled: true))
                XCTAssertFalse(disabled.isEmpty, "\(test.name): disabled for another reason, the rail changes its look")
            }
        }
    }

    func testUnavailableInkPanelDrawsEveryControlDisabled() throws {
        let (store, owner) = availableStore()
        defer { store.detach(owner) }
        let panel = NotebookInkControls(store: store)
        let available = try RenderedPixels(rendering: panel)
        XCTAssertTrue(try RenderedPixels(rendering: panel).rgba == available.rgba, "The panel renders deterministically.")
        store.setToolbarAvailable(false, for: owner)
        XCTAssertTrue(
            try RenderedPixels(rendering: panel).rgba != available.rgba,
            "The popover panel turns its own controls to the disabled tone while writing is paused."
        )
        store.setToolbarAvailable(true, for: owner)
        XCTAssertTrue(try RenderedPixels(rendering: panel).rgba == available.rgba)
    }

    // MARK: - Dragging

    func testDragEndingNearADockDocksAndPersistsOnce() throws {
        let (store, owner) = availableStore()
        defer { store.detach(owner) }
        let actions = NotebookToolbarActions(store: store)
        actions.place(.floating(CGPoint(x: 0.5, y: 0.5)))
        let emissions = countToolbarEmissions(of: store)
        let usable = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let size = CGSize(width: 600, height: 108)
        let resolver = NotebookToolbarDragResolver(placement: store.toolbar.placement, size: size, usable: usable)
        XCTAssertEqual(resolver.startFrame.midX, 500, accuracy: 0.001)
        XCTAssertEqual(resolver.startFrame.midY, 400, accuracy: 0.001)

        let dock = EditorToolbarLayout.frame(for: .docked(.topCenter), size: size, in: usable)
        let release = CGSize(width: dock.midX - 500 + 10, height: dock.midY - 400 + 5)
        let session = NotebookToolbarDragSession()
        for step in 1...5 {
            let fraction = CGFloat(step) / 5
            session.move(
                to: CGSize(width: release.width * fraction, height: release.height * fraction), resolver: resolver,
                actions: actions
            )
            XCTAssertTrue(session.isActive)
            XCTAssertEqual(store.toolbar.placement, .floating(CGPoint(x: 0.5, y: 0.5)))
        }
        XCTAssertEqual(emissions.count, 0, "Intermediate drag positions never persist.")
        XCTAssertEqual(session.previewFrame?.midX ?? 0, dock.midX + 10, accuracy: 0.001)
        XCTAssertEqual(session.targetedDock, .topCenter)

        let placement = session.end(at: release, actions: actions)
        XCTAssertEqual(placement, .docked(.topCenter))
        XCTAssertEqual(store.toolbar.placement, .docked(.topCenter))
        XCTAssertFalse(session.isActive)
        XCTAssertNil(session.end(at: release, actions: actions))
        XCTAssertEqual(emissions.count, 1)
    }

    /// A rail held by its grip barely moves sideways when it spans the window, so the finger says
    /// which edge it is pushed to; the dock it lands in stands it on end, at the vertical size. The
    /// grip starts within reach of the left edge, so only a finger moving toward it docks there:
    /// dragged straight down into the page, the rail floats.
    func testDragPushedToASideDocksTheRailOnEnd() throws {
        let (store, owner) = availableStore()
        defer { store.detach(owner) }
        let actions = NotebookToolbarActions(store: store)
        let emissions = countToolbarEmissions(of: store)
        let usable = CGRect(x: 0, y: 0, width: 834, height: 1_104)
        let composition = NotebookToolbarComposition(preferences: store.toolbar, horizontalSizeClass: .regular)
        let sizes = composition.dockSizes(in: usable.size)
        let resolver = NotebookToolbarDragResolver(
            placement: .docked(.topCenter), size: sizes.horizontal, dockSizes: sizes, usable: usable
        )
        let session = NotebookToolbarDragSession()
        let grip = CGPoint(x: resolver.startFrame.minX + 22, y: resolver.startFrame.midY)

        XCTAssertLessThan(grip.x, EditorToolbarLayout.edgeSnapDistance, "The grip starts within reach of the left edge.")
        func finger(_ x: CGFloat) -> (translation: CGSize, pointer: CGPoint) {
            (CGSize(width: x - grip.x, height: 400), CGPoint(x: x, y: grip.y + 400))
        }

        // Straight down into the page, the finger still on the grip: it floats.
        let down = finger(grip.x)
        session.move(to: down.translation, pointer: down.pointer, resolver: resolver, actions: actions)
        XCTAssertNil(session.targetedDock)
        // Pushed on toward the left edge, it docks there.
        let pushed = finger(grip.x - EditorToolbarLayout.edgeApproachDistance)
        session.move(to: pushed.translation, pointer: pushed.pointer, resolver: resolver, actions: actions)
        XCTAssertEqual(session.targetedDock, .leftEdge)
        // Away from the edge it floats; pushed across to the far side it docks there.
        let away = finger(300)
        session.move(to: away.translation, pointer: away.pointer, resolver: resolver, actions: actions)
        XCTAssertNil(session.targetedDock)
        let (across, farSide) = finger(820)
        session.move(to: across, pointer: farSide, resolver: resolver, actions: actions)
        XCTAssertEqual(session.targetedDock, .rightEdge)
        XCTAssertEqual(emissions.count, 0)

        let placement = session.end(at: across, pointer: farSide, actions: actions)
        XCTAssertEqual(placement, .docked(.rightEdge))
        XCTAssertEqual(store.toolbar.placement, .docked(.rightEdge))
        XCTAssertEqual(emissions.count, 1)
        let docked = NotebookToolbarComposition(preferences: store.toolbar, horizontalSizeClass: .regular)
        let rail = docked.rail(in: usable.size)
        XCTAssertEqual(rail.orientation, .rightEdge)
        XCTAssertEqual(rail.size, sizes.vertical)
        let frame = docked.frame(in: usable)
        XCTAssertEqual(frame.maxX, usable.maxX - EditorToolbarLayout.margin, accuracy: 0.001)

        // Without side docks, as at compact width, the same push floats the rail instead.
        let compact = NotebookToolbarDragResolver(
            placement: .docked(.topCenter), size: sizes.horizontal, dockSizes: sizes, usable: usable, sideDocks: false
        )
        guard case .floating = compact.placement(translation: across, pointer: farSide) else {
            return XCTFail("A window without side docks floats a rail pushed to a side.")
        }
    }

    /// Where the side docks are not offered a rail stored at a side rests at the top; dropping it
    /// back there keeps the side it was stored at, for when the window widens.
    func testADropInPlaceKeepsASideDockTheWindowDoesNotOffer() {
        let usable = CGRect(x: 0, y: 0, width: 507, height: 1_290)
        let size = CGSize(width: 483, height: 52)
        let resolver = NotebookToolbarDragResolver(
            placement: .docked(.leftEdge), size: size, usable: usable, sideDocks: false
        )
        XCTAssertEqual(resolver.startFrame.minY, EditorToolbarLayout.margin, "It rests at the top.")
        XCTAssertEqual(resolver.placement(translation: CGSize(width: 0, height: 10)), .docked(.leftEdge))
        XCTAssertEqual(resolver.targetedDock(translation: CGSize(width: 0, height: 10)), .topCenter,
            "The marker lights the top, where the rail shows.")
    }

    func testDragEndingAwayFromDocksFloatsAtTheClampedFraction() throws {
        let (store, owner) = availableStore()
        defer { store.detach(owner) }
        let actions = NotebookToolbarActions(store: store)
        let emissions = countToolbarEmissions(of: store)
        let usable = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let size = CGSize(width: 600, height: 108)
        let resolver = NotebookToolbarDragResolver(placement: .docked(.topCenter), size: size, usable: usable)
        let session = NotebookToolbarDragSession()
        let translation = CGSize(width: 900, height: 1_200)
        session.move(to: translation, resolver: resolver, actions: actions)
        let preview = try XCTUnwrap(session.previewFrame)
        XCTAssertTrue(usable.contains(preview), "The dragged toolbar stays inside the canvas area.")
        XCTAssertNil(session.targetedDock)

        let placement = try XCTUnwrap(session.end(at: translation, actions: actions))
        guard case let .floating(fraction) = placement else { return XCTFail("Expected a floating placement") }
        let margin = EditorToolbarLayout.margin
        XCTAssertEqual(fraction.x, (usable.maxX - margin - size.width / 2) / usable.width, accuracy: 0.0001)
        XCTAssertEqual(fraction.y, (usable.maxY - margin - size.height / 2) / usable.height, accuracy: 0.0001)
        XCTAssertEqual(store.toolbar.placement, placement)
        XCTAssertFalse(store.toolbar.isCollapsed)
        XCTAssertEqual(emissions.count, 1)
    }

    func testCancelledOrUnavailableDragNeverPersists() throws {
        let (store, owner) = availableStore()
        let actions = NotebookToolbarActions(store: store)
        let emissions = countToolbarEmissions(of: store)
        let resolver = NotebookToolbarDragResolver(
            placement: .docked(.topCenter), size: CGSize(width: 400, height: 60),
            usable: CGRect(x: 0, y: 0, width: 900, height: 700)
        )
        let session = NotebookToolbarDragSession()
        session.move(to: CGSize(width: 0, height: 300), resolver: resolver, actions: actions)
        session.cancel()
        XCTAssertFalse(session.isActive)
        XCTAssertNil(session.previewFrame)
        XCTAssertNil(session.end(at: CGSize(width: 0, height: 300), actions: actions))

        store.detach(owner)
        XCTAssertFalse(actions.isEnabled)
        session.move(to: CGSize(width: 0, height: 300), resolver: resolver, actions: actions)
        XCTAssertNil(session.end(at: CGSize(width: 0, height: 300), actions: actions))
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(store.toolbar, .standard)
        XCTAssertEqual(emissions.count, 0)
    }

    func testDragEndPersistsOnceEvenWhenTheGestureStateResetsFirst() throws {
        let (store, owner) = availableStore()
        defer { store.detach(owner) }
        let actions = NotebookToolbarActions(store: store)
        let emissions = countToolbarEmissions(of: store)
        let usable = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let size = CGSize(width: 600, height: 108)
        let resolver = NotebookToolbarDragResolver(placement: .docked(.topCenter), size: size, usable: usable)
        let translation = CGSize(width: 0, height: 400)
        let session = NotebookToolbarDragSession()
        session.move(to: translation, resolver: resolver, actions: actions)

        // SwiftUI may reset the gesture state, which clears the preview, before it delivers onEnded.
        session.cancel()
        let placement = session.end(at: translation, resolver: resolver, actions: actions)
        XCTAssertEqual(placement, resolver.placement(translation: translation))
        XCTAssertEqual(store.toolbar.placement, placement)
        XCTAssertNil(session.previewFrame)
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(emissions.count, 1)

        let towardsLeft = CGSize(width: -180, height: 300)
        let pointer = CGPoint(x: 20, y: 400)
        let recomputed = NotebookToolbarDragResolver(
            placement: .docked(.topCenter), size: size, usable: usable, sideDocks: false
        )
        guard case .floating = recomputed.placement(translation: towardsLeft, pointer: pointer) else {
            return XCTFail("The later resolver would float the toolbar.")
        }
        session.move(to: towardsLeft, pointer: pointer, resolver: resolver, actions: actions)
        let docked = session.end(at: towardsLeft, pointer: pointer, resolver: recomputed, actions: actions)
        XCTAssertEqual(docked, .docked(.leftEdge), "The resolver fixed at the start of the drag decides.")
        XCTAssertEqual(emissions.count, 2)

        store.detach(owner)
        XCTAssertNil(session.end(at: translation, resolver: resolver, actions: actions))
        XCTAssertEqual(emissions.count, 2, "An unavailable toolbar never persists a drag.")
    }

    // MARK: - Collapse and reveal

    /// A floating rail ends its first row with its collapse key, so the key shows whether or not the
    /// second row does. Where the second row is the wider, as on the 11-inch iPad in portrait, the
    /// key takes room the first row leaves. Where the first row is the wider and the window fits the
    /// key as well, as in landscape on the 12.9-inch iPad, the rail grows by the key's room alone and
    /// still shows every planned tool. Where it cannot fit both, as in portrait on the 12.9-inch iPad,
    /// the planned tools yield to the key and the second row governs again. The dock slots keep the
    /// docked rail's size. The single compact row keeps the docked width, its strip giving up the room.
    func testFloatingRailEndsItsFirstRowWithItsCollapseKey() {
        let floating = EditorToolbarPreferences(
            placement: .floating(CGPoint(x: 0.5, y: 0.5)), isCollapsed: false, customSwatches: []
        )
        let key = NotebookToolbarComposition.groupGap + NotebookTheme.controlSize
        for isOpen in [false, true] {
            let docked = NotebookToolbarComposition(preferences: .standard, horizontalSizeClass: .regular, isInkRowOpen: isOpen)
            let composition = NotebookToolbarComposition(
                preferences: floating, horizontalSizeClass: .regular, isInkRowOpen: isOpen
            )
            XCTAssertTrue(composition.showsCollapseControl)
            XCTAssertFalse(docked.showsCollapseControl)
            XCTAssertEqual(composition.toolCapWidth, docked.toolCapWidth + key, "The key closes the first row.")
            XCTAssertEqual(
                composition.rail(forHostWidth: 834), docked.rail(forHostWidth: 834),
                "The second row governs the width, so the key takes room the first row leaves."
            )
            let landscape = composition.rail(forHostWidth: 1_366)
            let dockedLandscape = docked.rail(forHostWidth: 1_366)
            XCTAssertEqual(landscape.size.width, dockedLandscape.size.width + key, accuracy: 0.5)
            XCTAssertEqual(landscape.size.height, dockedLandscape.size.height)
            XCTAssertTrue(landscape.showsUpcoming)
            XCTAssertFalse(landscape.toolRowOverflows)

            let portrait = composition.rail(forHostWidth: 1_024)
            XCTAssertTrue(docked.rail(forHostWidth: 1_024).showsUpcoming)
            XCTAssertFalse(portrait.showsUpcoming, "The planned tools yield to the key.")
            XCTAssertEqual(portrait.toolRow, docked.toolRow(includingUpcoming: false))
            XCTAssertFalse(portrait.toolRowOverflows, "Every working tool and the key show.")
            XCTAssertEqual(portrait.size, composition.rail(forHostWidth: 834).size, "The second row governs again.")
            for size in [CGSize(width: 834, height: 1_194), CGSize(width: 1_024, height: 1_366), CGSize(width: 1_366, height: 1_024)] {
                XCTAssertEqual(composition.dockSizes(in: size), docked.dockSizes(in: size), "\(size)")
                XCTAssertEqual(composition.shownDockSizes(in: size), docked.shownDockSizes(in: size), "\(size)")
            }
        }
        XCTAssertEqual(NotebookToolbarComposition.gripColumnWidth, NotebookTheme.controlSize)
        let compact = NotebookToolbarComposition(preferences: floating, horizontalSizeClass: .compact)
        let compactDocked = NotebookToolbarComposition(preferences: .standard, horizontalSizeClass: .compact)
        XCTAssertTrue(compact.showsCollapseControl)
        XCTAssertEqual(
            compact.toolCapWidth, compactDocked.toolCapWidth + NotebookTheme.itemSpacing + NotebookTheme.controlSize,
            "The single compact row keeps its collapse key after the current-ink chip."
        )
        XCTAssertEqual(compact.rail(forHostWidth: 507).size, compactDocked.rail(forHostWidth: 507).size)
    }

    /// The collapsed handle centres across the first row of the rail it stands for, which shows
    /// whether or not the second row does, so collapsing and expanding the rail moves nothing in
    /// sight. A dragged handle stores the point that puts that row where the handle was let go,
    /// and the handle comes back to rest there when collapsed again.
    func testCollapsedHandleRestsOnTheFirstRowAndADropKeepsTheRowWhereItWasLetGo() throws {
        let usable = CGRect(x: 0, y: 0, width: 1_024, height: 1_300)
        let placement = EditorToolbarPlacement.floating(CGPoint(x: 0.5, y: 0.4))
        let expanded = NotebookToolbarComposition(
            preferences: EditorToolbarPreferences(placement: placement, isCollapsed: false, customSwatches: []),
            horizontalSizeClass: .regular
        )
        let collapsed = NotebookToolbarComposition(
            preferences: EditorToolbarPreferences(placement: placement, isCollapsed: true, customSwatches: []),
            horizontalSizeClass: .regular
        )
        let room = expanded.frame(in: usable)
        let handle = collapsed.frame(in: usable)
        XCTAssertEqual(handle.size, NotebookTheme.collapsedHandleSize)
        XCTAssertEqual(handle.midX, room.midX, accuracy: 0.001)
        XCTAssertEqual(handle.midY, room.minY + NotebookTheme.rowHeight / 2, accuracy: 0.001, "Across the first row.")
        XCTAssertEqual(collapsed.handleFrame(in: usable), handle, "A hidden floating rail leaves its stand-in there too.")
        XCTAssertEqual(expanded.handleFrame(in: usable), handle)

        let rail = collapsed.rail(in: usable.size)
        let resolver = NotebookToolbarDragResolver(
            placement: placement, size: collapsed.toolbarSize(of: rail), dockSizes: collapsed.dockSizes(in: usable.size),
            usable: usable, centreOffset: collapsed.centreOffset
        )
        XCTAssertEqual(resolver.startFrame, handle, "The drag starts from where the handle is drawn.")
        let translation = CGSize(width: -260, height: 330)
        let dropped = try XCTUnwrap({ () -> CGPoint? in
            guard case let .floating(point) = resolver.placement(translation: translation) else { return nil }
            return point
        }())
        let landed = NotebookToolbarComposition(
            preferences: EditorToolbarPreferences(placement: .floating(dropped), isCollapsed: false, customSwatches: []),
            horizontalSizeClass: .regular
        )
        let letGo = resolver.previewFrame(translation: translation)
        let landedRoom = landed.frame(in: usable)
        XCTAssertEqual(landedRoom.minY + NotebookTheme.rowHeight / 2, letGo.midY, accuracy: 0.001, "The first row lands where the handle was let go.")
        XCTAssertEqual(landed.handleFrame(in: usable).origin.x, letGo.origin.x, accuracy: 0.001)
        XCTAssertEqual(landed.handleFrame(in: usable).origin.y, letGo.origin.y, accuracy: 0.001, "Collapsed again, it rests there.")

        let compact = NotebookToolbarComposition(
            preferences: EditorToolbarPreferences(placement: placement, isCollapsed: true, customSwatches: []),
            horizontalSizeClass: .compact
        )
        XCTAssertEqual(compact.handleOffset, .zero, "The single compact row is the whole rail, so its handle centres on the point.")
    }

    func testRestoredFloatingCollapsedToolbarShowsTheRevealControl() throws {
        let floating = EditorToolbarPreferences(
            placement: .floating(CGPoint(x: 0.3, y: 0.7)), isCollapsed: true, customSwatches: []
        )
        let store = storeWithToolbarData(floating.encoded())
        XCTAssertEqual(store.toolbar, floating)
        let composition = NotebookToolbarComposition(preferences: store.toolbar, horizontalSizeClass: .regular)
        XCTAssertTrue(composition.showsRevealHandle)
        XCTAssertFalse(composition.showsCollapseControl)
        XCTAssertEqual(composition.toolbarSize(forHostWidth: 900), NotebookTheme.collapsedHandleSize)
    }

    func testDockedRestoreIsNeverCollapsed() throws {
        let stored = #"{"version":1,"placement":{"dock":"topTrailing"},"collapsed":true,"swatches":[]}"#
        let store = storeWithToolbarData(Data(stored.utf8))
        XCTAssertEqual(store.toolbar.placement, .docked(.rightEdge))
        XCTAssertFalse(store.toolbar.isCollapsed)
        let composition = NotebookToolbarComposition(preferences: store.toolbar, horizontalSizeClass: .regular)
        XCTAssertFalse(composition.showsRevealHandle)
        XCTAssertFalse(composition.showsCollapseControl, "Docked toolbars never offer to collapse.")

        let (available, owner) = availableStore()
        defer { available.detach(owner) }
        let actions = NotebookToolbarActions(store: available)
        actions.place(.docked(.leftEdge))
        actions.setCollapsed(true)
        XCTAssertFalse(available.toolbar.isCollapsed)
        actions.place(.floating(CGPoint(x: 0.5, y: 0.5)))
        actions.setCollapsed(true)
        XCTAssertTrue(available.toolbar.isCollapsed)
        actions.place(.docked(.topCenter))
        XCTAssertFalse(available.toolbar.isCollapsed, "Docking expands a collapsed toolbar.")
    }

    /// The reveal tab, the handle a hidden floating rail leaves and the user's collapsed handle all
    /// perform this one action.
    func testEveryStandInTapShowsTheWholeRail() {
        let (store, owner) = availableStore()
        defer { store.detach(owner) }
        let actions = NotebookToolbarActions(store: store)

        XCTAssertTrue(actions.place(.docked(.rightEdge)))
        store.setToolsHidden(true)
        actions.showTools()
        XCTAssertFalse(store.areToolsHidden, "The reveal tab asks for the tools back.")
        XCTAssertEqual(store.toolbar.placement, .docked(.rightEdge))

        let floating = EditorToolbarPlacement.floating(CGPoint(x: 0.5, y: 0.5))
        XCTAssertTrue(actions.place(floating))
        store.setToolsHidden(true)
        actions.showTools()
        XCTAssertFalse(store.areToolsHidden, "So does the handle a hidden floating rail leaves.")
        XCTAssertFalse(store.toolbar.isCollapsed)
        XCTAssertEqual(store.toolbar.placement, floating)

        actions.setCollapsed(true)
        store.setToolsHidden(true)
        XCTAssertTrue(store.toolbar.isCollapsed, "Hiding the tools leaves the user's own collapse alone.")
        actions.showTools()
        XCTAssertFalse(store.areToolsHidden)
        XCTAssertFalse(store.toolbar.isCollapsed, "One tap on a collapsed handle shows the whole rail.")

        actions.setCollapsed(true)
        actions.showTools()
        XCTAssertFalse(store.areToolsHidden)
        XCTAssertFalse(store.toolbar.isCollapsed, "Without hidden tools the tap only expands.")

        actions.setCollapsed(true)
        store.setToolsHidden(true)
        store.setToolbarAvailable(false, for: owner)
        actions.showTools()
        XCTAssertFalse(store.areToolsHidden, "The tools come back even while writing is paused.")
        XCTAssertTrue(store.toolbar.isCollapsed, "A paused toolbar keeps its preferences.")
    }

    /// The stand-ins offer the tools back first, then each writing view, which the notebook shown in
    /// the scene adopts and stores.
    func testStandInsOfferTheToolsFirstThenEachWritingView() async throws {
        let (store, owner) = availableStore()
        defer { store.detach(owner) }
        let rig = try await NotebookChromeRig(store: store)
        let offered = NotebookToolsRevealAction.standInActions(for: store, animation: nil)
        XCTAssertEqual(offered.map(\.name), [
            "Show tools and title", "Writing view: Focus", "Writing view: Pinned", "Writing view: Always-on tools",
        ])
        XCTAssertEqual(NotebookToolsRevealAction.showTools(from: store, animation: nil).name, offered[0].name)

        rig.chrome.toolBegan()
        rig.chrome.toolEnded()
        XCTAssertTrue(store.areToolsHidden)
        offered[0].perform()
        XCTAssertFalse(store.areToolsHidden, "The first action is the one every stand-in's tap performs.")
        XCTAssertTrue(rig.chrome.state.showsHeader)

        offered[2].perform()
        XCTAssertEqual(rig.chrome.mode, .pinned)
        XCTAssertEqual(store.toolbar.chromeMode, .pinned, "The choice is stored.")
        offered[3].perform()
        XCTAssertEqual(rig.chrome.mode, .overlay)
        offered[1].perform()
        XCTAssertEqual(store.toolbar.chromeMode, .focus)

        let bare = NotebookTestFixtures.toolStore()
        NotebookToolsRevealAction.standInActions(for: bare, animation: nil)[2].perform()
        XCTAssertEqual(bare.toolbar.chromeMode, .pinned, "Without a writing view the choice is stored alone.")
    }

    func testPencilRevealRequestExpandsTheMountedCollapsedToolbar() async throws {
        let collapsed = EditorToolbarPreferences(
            placement: .floating(CGPoint(x: 0.5, y: 0.4)), isCollapsed: true, customSwatches: []
        )
        let store = storeWithToolbarData(collapsed.encoded())
        let fixture = try await NotebookTestFixtures.mountToolbarHost(store: store)
        defer { fixture.close() }
        XCTAssertTrue(store.toolbar.isCollapsed)
        XCTAssertFalse(store.isInkRowOpen)
        store.handlePencil(.showInkAttributes, from: fixture.controller)
        XCTAssertEqual(store.revealRequest, 1)
        try await NotebookTestFixtures.waitUntil { !store.toolbar.isCollapsed }
        XCTAssertEqual(store.toolbar.placement, collapsed.placement)
        XCTAssertTrue(store.isInkRowOpen, "The rail expands with its colours in sight.")
    }

    func testEveryLayoutAnswersAPencilRevealRequestVisibly() {
        let floating = EditorToolbarPreferences(
            placement: .floating(CGPoint(x: 0.5, y: 0.5)), isCollapsed: false, customSwatches: []
        )
        var collapsed = floating
        collapsed.setCollapsed(true)
        let expected: [(EditorToolbarPreferences, UserInterfaceSizeClass?, NotebookToolbarRevealResponse)] = [
            (.standard, .regular, .showInkRow),
            (.standard, .compact, .openInkPanel),
            (.standard, nil, .showInkRow),
            (floating, .regular, .showInkRow),
            (floating, .compact, .openInkPanel),
            (floating, nil, .showInkRow),
            (collapsed, .regular, .expand),
            (collapsed, .compact, .expand),
            (collapsed, nil, .expand)
        ]
        for (preferences, sizeClass, response) in expected {
            let composition = NotebookToolbarComposition(preferences: preferences, horizontalSizeClass: sizeClass)
            XCTAssertEqual(composition.pencilRevealResponse, response, "\(preferences) \(String(describing: sizeClass))")
        }
    }

    func testPencilRevealBringsTheColoursJustClearOfTheLeadingChevron() async throws {
        // A full shelf makes the ink row much wider than an 11-inch iPad in portrait.
        let store = NotebookTestFixtures.toolStore()
        var preferences = store.toolbar
        for index in 0..<EditorToolbarPreferences.maximumCustomSwatches {
            preferences.addCustomSwatch(EditorInkColor(red: 0.1, green: Double(index) / 10, blue: 0.6))
        }
        store.updateToolbar(preferences)
        let fixture = try await NotebookTestFixtures.mountToolbarHost(store: store, width: 834)
        defer { fixture.close() }
        let strips = fixture.strips
        XCTAssertEqual(strips.count, 2, "The regular toolbar shows the tool strip and the ink strip.")
        let ink = try XCTUnwrap(strips.last)
        XCTAssertGreaterThan(ink.contentSize.width, ink.bounds.width, "The ink strip scrolls with custom colours.")
        XCTAssertEqual(ink.contentOffset.x, 0, accuracy: 0.5)

        let row = try XCTUnwrap(rail(for: store.toolbar, hostWidth: 834).inkRow)
        let firstSwatch = try XCTUnwrap(row.slots.first { if case .swatch = $0.item { true } else { false } })
        let target = firstSwatch.minX - NotebookStripRow.leadingClearance
        XCTAssertLessThan(target, row.maximumOffset(containerWidth: ink.bounds.width))
        XCTAssertFalse(fixture.store.isInkRowOpen, "The colours start out of sight on the closed second row.")
        fixture.store.handlePencil(.showColorPalette, from: fixture.controller)
        // The toolbar answers the request in its next update.
        try await NotebookTestFixtures.waitUntil { fixture.store.isInkRowOpen }
        // Paging ends exactly on its target; a flick's snapping never applies to it.
        try await NotebookTestFixtures.waitUntil { abs(ink.contentOffset.x - target) < 0.01 }
        XCTAssertEqual(
            firstSwatch.minX - ink.contentOffset.x, NotebookStripRow.leadingClearance, accuracy: 0.5,
            "The first colour lands just clear of the leading chevron."
        )
        XCTAssertTrue(fixture.store.isToolbarAvailable)
        XCTAssertNil(fixture.hosting.presentedViewController, "A regular toolbar answers in place.")
    }

    func testInkRowLeadsWithThePresetsSoTheyShowAtRest() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost(width: 1_024)
        defer { fixture.close() }
        let ink = try XCTUnwrap(fixture.strips.last)
        let row = try XCTUnwrap(rail(for: fixture.store.toolbar, hostWidth: 1_024).inkRow)
        XCTAssertEqual(row.slots.prefix(4).map(\.item), EditorInkCatalog.presets.map { .preset($0) })
        XCTAssertLessThanOrEqual(ink.contentSize.width, ink.bounds.width + 0.5, "On the 12.9-inch iPad the ink row fits.")
        XCTAssertEqual(ink.contentSize.width, row.contentWidth, accuracy: 0.5, "The strip lays out the slots it was measured with.")

        // With nothing to scroll, the reveal only highlights the colours: the well of an unselected
        // swatch tints around its colour while the strip stays where it was.
        let swatches = row.slots.filter { if case .swatch = $0.item { true } else { false } }
        let swatch = try XCTUnwrap(swatches.dropFirst().first)
        let strip = fixture.frame(of: ink)
        let wellCorner = CGPoint(x: strip.minX + swatch.minX + 5, y: strip.midY)
        let unlit = try rendered(fixture.window).rgba(at: wellCorner)
        fixture.store.handlePencil(.showColorPalette, from: fixture.controller)
        try await NotebookTestFixtures.waitUntil { (try? self.rendered(fixture.window).rgba(at: wellCorner)) != unlit }
        XCTAssertEqual(ink.contentOffset.x, 0, accuracy: 0.5)
    }

    func testPencilRevealOpensTheCompactInkPanelAndPausingWritingClosesIt() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost(horizontalSizeClass: .compact)
        defer { fixture.close() }
        XCTAssertEqual(fixture.strips.count, 1, "At compact width the ink strip folds into the current-ink chip.")
        XCTAssertNil(fixture.hosting.presentedViewController)

        fixture.store.handlePencil(.showContextualPalette, from: fixture.controller)
        try await NotebookTestFixtures.waitUntil { fixture.hosting.presentedViewController != nil }
        XCTAssertFalse(fixture.store.isInkRowOpen, "The compact rail has no second row to open.")

        fixture.controller.setInputGate(.failed)
        XCTAssertFalse(fixture.store.isToolbarAvailable)
        try await NotebookTestFixtures.waitUntil { fixture.hosting.presentedViewController == nil }
        fixture.store.handlePencil(.showContextualPalette, from: fixture.controller)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(fixture.hosting.presentedViewController, "A paused toolbar does not open its ink panel.")
    }

    /// Writing can pause, resume and pause again in quick succession. Every change reaches the
    /// compact ink panel, so it closes and stays closed while writing is paused.
    func testInkPanelClosesWhenWritingPausesAgainInQuickSuccession() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost(horizontalSizeClass: .compact)
        defer { fixture.close() }
        fixture.store.handlePencil(.showContextualPalette, from: fixture.controller)
        try await NotebookTestFixtures.waitUntil { fixture.hosting.presentedViewController != nil }
        // Each change on a turn of its own, all within a frame or two.
        for gate in [NotebookInputGate.failed, .open, .failed, .open, .failed] {
            fixture.controller.setInputGate(gate)
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertFalse(fixture.store.isToolbarAvailable)
        try await NotebookTestFixtures.waitUntil { fixture.hosting.presentedViewController == nil }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(fixture.hosting.presentedViewController, "The panel stays closed while writing is paused.")
    }

    func testMountedCollapsedToolbarShowsOnlyTheRevealHandle() async throws {
        let collapsed = EditorToolbarPreferences(
            placement: .floating(CGPoint(x: 0.5, y: 0.5)), isCollapsed: true, customSwatches: []
        )
        let store = storeWithToolbarData(collapsed.encoded())
        let fixture = try await NotebookTestFixtures.mountToolbarHost(store: store)
        defer { fixture.close() }
        let canvas = fixture.controller.canvasView
        let host = fixture.hosting.view!
        try await NotebookTestFixtures.waitUntil { abs(canvas.bounds.height - host.bounds.height) < 0.5 }
        host.layoutIfNeeded()

        let handle = NotebookToolbarComposition(preferences: collapsed, horizontalSizeClass: .regular)
            .frame(in: host.bounds)
        var floating = collapsed
        floating.setCollapsed(false)
        let expanded = NotebookToolbarComposition(preferences: floating, horizontalSizeClass: .regular)
            .frame(in: host.bounds)
        let besideHandle = CGPoint(x: expanded.minX + 20, y: expanded.minY + 4)
        XCTAssertFalse(handle.contains(besideHandle))
        XCTAssertFalse(fixture.hit(CGPoint(x: handle.midX, y: handle.midY)).isDescendant(of: fixture.controller.view))
        XCTAssertTrue(
            fixture.hit(besideHandle).isDescendant(of: canvas),
            "A collapsed toolbar leaves the rest of its expanded frame to the canvas."
        )
    }

    // MARK: - Second row

    /// The second row starts closed in every launch: opening it writes nothing to the defaults,
    /// and a store made again from the same defaults shows the first row alone.
    func testTheSecondRowStartsClosedAndIsNeverStored() {
        let suite = NotebookTestFixtures.temporaryDefaultsSuite()
        let defaults = UserDefaults(suiteName: suite)!
        let store = NotebookSceneToolStore(identifier: suite, defaults: defaults)
        XCTAssertFalse(store.isInkRowOpen, "A new scene shows the first row alone.")
        let owner = NotebookViewController(pageCount: 1, initialDrawing: PKDrawing())
        store.attach(owner)
        store.setToolbarAvailable(true, for: owner)
        defer { store.detach(owner) }
        let stored = defaults.persistentDomain(forName: suite) ?? [:]
        NotebookToolbarActions(store: store).openInkRow()
        XCTAssertTrue(store.isInkRowOpen)
        XCTAssertEqual(
            NSDictionary(dictionary: defaults.persistentDomain(forName: suite) ?? [:]), NSDictionary(dictionary: stored),
            "Opening the row stores nothing."
        )
        XCTAssertFalse(NotebookSceneToolStore(identifier: suite, defaults: defaults).isInkRowOpen, "The next launch starts closed.")
    }

    /// An ink's key opens the second row and selects the ink; the key of the ink in use closes the
    /// open row, and opens it again; another ink's key keeps it open and shows that ink's settings.
    func testAnInksKeyOpensItsSettingsAndTheSameKeyClosesThem() {
        let (store, owner) = availableStore()
        defer { store.detach(owner) }
        let actions = NotebookToolbarActions(store: store)
        XCTAssertEqual(store.tool.kind, .ink(.pen))
        XCTAssertFalse(store.isInkRowOpen)

        actions.chooseInk(.pen)
        XCTAssertTrue(store.isInkRowOpen, "The ink in use opens its settings.")
        actions.chooseInk(.pen)
        XCTAssertFalse(store.isInkRowOpen, "The same key closes them.")
        actions.chooseInk(.pen)
        XCTAssertTrue(store.isInkRowOpen, "and opens them again.")
        XCTAssertEqual(store.tool.kind, .ink(.pen))

        actions.chooseInk(.pencil)
        XCTAssertEqual(store.tool.kind, .ink(.pencil))
        XCTAssertTrue(store.isInkRowOpen, "Another ink keeps the row open, showing its own settings.")
        actions.chooseInk(.pencil)
        XCTAssertFalse(store.isInkRowOpen)
        actions.chooseInk(.marker)
        XCTAssertEqual(store.tool.kind, .ink(.marker))
        XCTAssertTrue(store.isInkRowOpen, "A closed row opens with the ink a key selects.")
    }

    /// The eraser, lasso and ruler have no settings on the second row: each closes an open row and
    /// none opens a closed one. The ink settings on the first and second rows leave it as it is.
    func testToolsWithoutInkSettingsCloseTheSecondRowAndNeverOpenIt() throws {
        let (store, owner) = availableStore()
        defer { store.detach(owner) }
        let actions = NotebookToolbarActions(store: store)
        let closing: [(String, () -> Void)] = [
            ("the eraser key", { actions.selectEraser() }),
            ("a mode from the eraser's menu", { actions.select(.eraser(.bitmap)) }),
            ("the lasso", { actions.select(.lasso) }),
            ("the ruler", { actions.toggleRuler() }),
        ]
        for (name, choose) in closing {
            actions.chooseInk(.fountainPen)
            XCTAssertTrue(store.isInkRowOpen)
            choose()
            XCTAssertFalse(store.isInkRowOpen, "\(name) closes the row.")
            choose()
            XCTAssertFalse(store.isInkRowOpen, "\(name) never opens it.")
        }

        actions.chooseInk(.fountainPen)
        let preset = try XCTUnwrap(EditorInkCatalog.presets.first { $0.family == .marker })
        let keeping: [(String, () -> Void)] = [
            ("a preset", { actions.apply(preset) }),
            ("a colour", { actions.selectColor(EditorInkCatalog.swatches[3]) }),
            ("a width", { actions.selectWidth(.bold) }),
            ("a custom colour", { actions.addCustomColor(EditorInkColor(red: 0.2, green: 0.4, blue: 0.7)) }),
        ]
        for (name, choose) in keeping {
            choose()
            XCTAssertTrue(store.isInkRowOpen, "\(name) keeps the row open.")
        }
        XCTAssertEqual(store.tool.kind, .ink(.marker))
        actions.chooseInk(.marker)
        XCTAssertFalse(store.isInkRowOpen)
        actions.selectWidth(.fine)
        XCTAssertFalse(store.isInkRowOpen, "A width on the first row never opens the second.")
    }

    /// At compact width the current-ink chip holds the ink settings, so an ink's key only selects
    /// the ink and never opens or closes a second row the rail does not have.
    func testWithoutASecondRowAnInksKeyOnlySelectsIt() {
        let (store, owner) = availableStore()
        defer { store.detach(owner) }
        let actions = NotebookToolbarActions(store: store)
        actions.chooseInk(.pen, opensSettings: false)
        actions.chooseInk(.crayon, opensSettings: false)
        XCTAssertEqual(store.tool.kind, .ink(.crayon))
        XCTAssertFalse(store.isInkRowOpen)
        actions.openInkRow()
        actions.chooseInk(.crayon, opensSettings: false)
        XCTAssertTrue(store.isInkRowOpen, "It leaves the row as it was.")

        let compact = NotebookToolbarComposition(
            preferences: .standard, horizontalSizeClass: .compact, isInkRowOpen: true
        ).rail(forHostWidth: 507)
        XCTAssertNil(compact.inkRow)
        XCTAssertFalse(compact.showsInkRow)
        XCTAssertEqual(compact.shownSize, compact.size)
    }

    /// While writing is paused no key, gesture or request opens or closes the second row.
    func testAPausedToolbarNeitherOpensNorClosesTheSecondRow() {
        let store = NotebookTestFixtures.toolStore()
        XCTAssertFalse(store.isToolbarAvailable)
        let actions = NotebookToolbarActions(store: store)
        actions.chooseInk(.pen)
        actions.openInkRow()
        XCTAssertFalse(store.isInkRowOpen)

        let (available, owner) = availableStore()
        let open = NotebookToolbarActions(store: available)
        open.chooseInk(.pen)
        XCTAssertTrue(available.isInkRowOpen)
        available.setToolbarAvailable(false, for: owner)
        open.chooseInk(.pen)
        open.select(.lasso)
        open.selectEraser()
        open.toggleRuler()
        XCTAssertTrue(available.isInkRowOpen, "A paused rail keeps its row as it was.")
        available.detach(owner)
    }

    /// An Apple Pencil gesture that switches the tool leaves the second row alone, so the rail at the
    /// page's edge never moves while the user writes; returning to the ink shows its row as it was.
    func testPencilToolSwitchesLeaveTheSecondRowAlone() {
        let (store, owner) = availableStore()
        defer { store.detach(owner) }
        NotebookToolbarActions(store: store).chooseInk(.pen)
        XCTAssertTrue(store.isInkRowOpen)
        store.handlePencil(.switchEraser, from: owner)
        XCTAssertEqual(store.tool.kind, .eraser(.vector))
        XCTAssertTrue(store.isInkRowOpen)
        store.handlePencil(.switchEraser, from: owner)
        XCTAssertEqual(store.tool.kind, .ink(.pen))
        XCTAssertTrue(store.isInkRowOpen)
        store.handlePencil(.switchPrevious, from: owner)
        XCTAssertTrue(store.isInkRowOpen)
    }

    /// An ink's key tells VoiceOver whether its settings show on the second row and what a tap does
    /// to them; without a second row it says nothing of one.
    func testInkKeysDescribeTheSecondRowToAssistiveTechnologies() {
        func rail(open: Bool, sizeClass: UserInterfaceSizeClass = .regular) -> NotebookToolbarRail {
            NotebookToolbarComposition(preferences: .standard, horizontalSizeClass: sizeClass, isInkRowOpen: open)
                .rail(forHostWidth: 1_024)
        }
        let shown = rail(open: true).inkKeyAccessibility(isSelected: true)
        XCTAssertEqual(shown.value, "Presets and colors shown")
        XCTAssertEqual(shown.hint, "Hides the presets and colors.")
        let hidden = rail(open: false).inkKeyAccessibility(isSelected: true)
        XCTAssertEqual(hidden.value, "Presets and colors hidden")
        XCTAssertEqual(hidden.hint, "Shows the presets and colors.")
        for open in [false, true] {
            let other = rail(open: open).inkKeyAccessibility(isSelected: false)
            XCTAssertNil(other.value, "Another ink's key has no row of its own to report.")
            XCTAssertEqual(other.hint, "Selects this ink and shows its presets and colors.")
            let compact = rail(open: open, sizeClass: .compact).inkKeyAccessibility(isSelected: true)
            XCTAssertNil(compact.value)
            XCTAssertNil(compact.hint)
        }
    }

    /// The second row eases in on a spring of about 0.3 seconds as the rail grows toward the page,
    /// slipping a little out from under the first, and eases out the same way. Under Reduce Motion
    /// it only fades: the rail takes its new size at once as the row opens, and only once the row
    /// has faded as it closes.
    func testTheSecondRowEasesInAndOutAndOnlyFadesUnderReduceMotion() {
        let standard = NotebookInkRowTransition(reduceMotion: false)
        XCTAssertEqual(standard.hiddenOffset(for: .horizontal), CGSize(width: 0, height: -8), "Tucked under the first row.")
        XCTAssertEqual(standard.hiddenOffset(for: .leftEdge), CGSize(width: -8, height: 0), "Tucked toward the tools.")
        XCTAssertEqual(standard.hiddenOffset(for: .rightEdge), CGSize(width: 8, height: 0))
        XCTAssertEqual(standard.extent(opening: true), .spring(duration: 0.3, bounce: 0))
        XCTAssertEqual(standard.extent(opening: false), .spring(duration: 0.3, bounce: 0))
        XCTAssertEqual(standard.content, .spring(duration: 0.3, bounce: 0))

        let reduced = NotebookInkRowTransition(reduceMotion: true)
        for orientation in [NotebookRailOrientation.horizontal, .leftEdge, .rightEdge] {
            XCTAssertEqual(reduced.hiddenOffset(for: orientation), .zero, "Under Reduce Motion nothing slides.")
        }
        XCTAssertNil(reduced.extent(opening: true), "The rail takes the open size at once, then the row fades in.")
        XCTAssertEqual(reduced.extent(opening: false), .linear(duration: 1.0 / 60).delay(0.15), "It shrinks once the row has faded.")
        XCTAssertEqual(reduced.content, .linear(duration: 0.15))
    }

    /// The toolbar keeps the expanded rail's room whether or not the second row shows, so opening
    /// it never moves the rail or the page: every placement rests in the same frame and reports the
    /// same docks, while the rail is drawn at its first row alone against the edge it rests at.
    func testTheRailKeepsRoomForItsSecondRowAndDrawsItsFirstRowAlone() {
        let usable = CGRect(x: 0, y: 0, width: 834, height: 1_104)
        let placements: [EditorToolbarPlacement] = [
            .docked(.topCenter), .docked(.leftEdge), .docked(.rightEdge), .floating(CGPoint(x: 0.5, y: 0.3)),
        ]
        for placement in placements {
            var preferences = EditorToolbarPreferences.standard
            preferences.place(placement)
            func composition(open: Bool) -> NotebookToolbarComposition {
                NotebookToolbarComposition(preferences: preferences, horizontalSizeClass: .regular, isInkRowOpen: open)
            }
            let closed = composition(open: false).rail(in: usable.size)
            let open = composition(open: true).rail(in: usable.size)
            XCTAssertFalse(closed.showsInkRow, "\(placement)")
            XCTAssertTrue(open.showsInkRow, "\(placement)")
            XCTAssertEqual(closed.size, open.size, "\(placement): the room kept is the expanded rail's.")
            XCTAssertEqual(
                composition(open: false).frame(of: closed, in: usable), composition(open: true).frame(of: open, in: usable),
                "\(placement): opening the row never moves the rail."
            )
            XCTAssertEqual(composition(open: false).dockSizes(in: usable.size), composition(open: true).dockSizes(in: usable.size))
            XCTAssertEqual(open.shownSize, open.size, "\(placement): open, the whole rail shows.")
            if placement.axis == .horizontal {
                XCTAssertEqual(closed.shownSize, CGSize(width: closed.size.width, height: NotebookTheme.rowHeight), "\(placement)")
                XCTAssertEqual(closed.orientation.anchor, .top)
            } else {
                XCTAssertEqual(closed.shownSize, CGSize(width: 96, height: closed.size.height), "\(placement)")
            }
        }
        let closedSizes = NotebookToolbarComposition(preferences: .standard, horizontalSizeClass: .regular)
            .shownDockSizes(in: usable.size)
        let openSizes = NotebookToolbarComposition(preferences: .standard, horizontalSizeClass: .regular, isInkRowOpen: true)
            .shownDockSizes(in: usable.size)
        XCTAssertEqual(closedSizes.horizontal.height, NotebookTheme.rowHeight, "The top dock's target outlines one row.")
        XCTAssertEqual(closedSizes.vertical.width, 96, "A side dock's target outlines the grip and the tools.")
        XCTAssertEqual(openSizes, NotebookToolbarComposition(preferences: .standard, horizontalSizeClass: .regular).dockSizes(in: usable.size))
    }

    // MARK: - Swatches, folding and strips

    func testPickedColoursAreStoredAndSelectedAtPickerPrecision() throws {
        let (store, owner) = availableStore()
        defer { store.detach(owner) }
        let actions = NotebookToolbarActions(store: store)
        actions.select(.lasso)

        let picked = NotebookSwatchShelf.color(from: UIColor(red: 0.5, green: 0.25, blue: 0.75, alpha: 1))
        let nearlySame = NotebookSwatchShelf.color(from: UIColor(red: 0.500_001, green: 0.25, blue: 0.75, alpha: 1))
        XCTAssertEqual(picked, nearlySame)
        XCTAssertEqual(picked, picked.quantized)
        actions.addCustomColor(picked)
        actions.addCustomColor(nearlySame)
        XCTAssertEqual(store.toolbar.customSwatches, [picked])
        XCTAssertNotNil(store.tool.inkFamily, "Adding a colour returns to the last ink.")

        let fullPrecision = EditorInkColor(red: 0.123_456, green: 0.654_321, blue: 0.333_333)
        actions.addCustomColor(fullPrecision)
        XCTAssertEqual(store.toolbar.customSwatches.first, fullPrecision.quantized)
        XCTAssertEqual(store.tool.color, store.toolbar.customSwatches.first, "The selected ink is the stored swatch.")

        for swatch in EditorInkCatalog.swatches {
            let shelf = store.toolbar.customSwatches
            actions.addCustomColor(NotebookSwatchShelf.color(from: swatch.platformColor))
            XCTAssertEqual(store.toolbar.customSwatches, shelf, "A quick swatch is never duplicated as a custom colour.")
            XCTAssertEqual(store.tool.color, swatch)
            let marks = NotebookInkMarks(tool: store.tool, custom: store.toolbar.customSwatches)
            XCTAssertEqual(marks.color, swatch)
            XCTAssertFalse(marks.marksCustomColor)
        }
    }

    /// Colours stored before the picker rounded them can lie within one step of another swatch.
    /// The shelf shows each visible colour once, so every strip control keeps its own id.
    func testShelfShowsEachVisibleColourOnceWithItsOwnID() throws {
        let charcoal = EditorInkCatalog.swatches[0].quantized
        let green = EditorInkColor(red: 51 / 255, green: 128 / 255, blue: 77 / 255)
        let nearGreen = EditorInkColor(red: 51.3 / 255, green: 128 / 255, blue: 77 / 255)
        let nearCharcoal = EditorInkColor(red: charcoal.red + 0.4 / 255, green: charcoal.green, blue: charcoal.blue)
        let stored = EditorToolbarPreferences(
            placement: .docked(.topCenter), isCollapsed: false, customSwatches: [green, nearGreen, nearCharcoal]
        )
        XCTAssertEqual(stored.customSwatches.count, 3, "Stored colours are kept as they were saved.")
        XCTAssertEqual(NotebookSwatchShelf.displayed(custom: stored.customSwatches), EditorInkCatalog.swatches + [green])
        for width in [834.0, 1_366] as [CGFloat] {
            let rail = self.rail(for: stored, hostWidth: width)
            for row in [rail.toolRow, try XCTUnwrap(rail.inkRow)] {
                let ids = row.slots.map(\.id)
                XCTAssertEqual(Set(ids).count, ids.count, "\(width): every control has its own id.")
            }
        }
    }

    func testPickingTheCurrentPresetColorKeepsItsIdentity() {
        let (store, owner) = availableStore()
        defer { store.detach(owner) }
        let actions = NotebookToolbarActions(store: store)
        for preset in EditorInkCatalog.presets {
            actions.apply(preset)
            let original = store.tool
            actions.addCustomColor(NotebookSwatchShelf.color(from: preset.color.platformColor))
            XCTAssertEqual(store.tool, original, preset.id)
            XCTAssertEqual(store.tool.activePresetID, preset.id)
            let shelfColor = NotebookSwatchShelf.displayed(custom: store.toolbar.customSwatches)
                .first { $0.quantized == preset.color.quantized }
            XCTAssertNotNil(shelfColor, preset.id)
            let marks = NotebookInkMarks(tool: store.tool, custom: store.toolbar.customSwatches)
            XCTAssertEqual(marks.color, shelfColor, preset.id)
            XCTAssertFalse(marks.marksCustomColor, preset.id)
        }
    }

    func testPresetSelectionKeepsTheChipSizeStable() throws {
        for preset in EditorInkCatalog.presets {
            func size(selected: Bool) -> CGSize {
                let host = UIHostingController(rootView: NotebookPresetChip(
                    preset: preset, isSelected: selected, action: {}
                ))
                return host.sizeThatFits(in: CGSize(width: 1_000, height: 1_000))
            }
            let idle = size(selected: false)
            let selected = size(selected: true)
            XCTAssertGreaterThan(idle.width, 0)
            XCTAssertEqual(idle.width, selected.width, accuracy: 0.1, preset.id)
            XCTAssertEqual(idle.height, selected.height, accuracy: 0.1, preset.id)
        }
    }

    func testCustomSwatchSelectionMarksStayReadable() {
        let mediumGray = EditorInkColor(red: 0.6, green: 0.6, blue: 0.6)
        XCTAssertEqual(NotebookSwatchContrast.mark(for: mediumGray, contrast: .standard).uiColor, NotebookTheme.glyph.uiColor)
        let colors = EditorInkCatalog.swatches + (0...20).flatMap { index in
            [1.0, 0.5, 0.0].map { alpha in
                let channel = Double(index) / 20
                return EditorInkColor(red: channel, green: channel, blue: channel, alpha: alpha)
            }
        }
        for contrast in [ColorSchemeContrast.standard, .increased] {
            for color in colors {
                let mark = NotebookSwatchShelf.color(from: NotebookSwatchContrast.mark(for: color, contrast: contrast).uiColor)
                XCTAssertGreaterThanOrEqual(
                    mark.contrastRatio(against: NotebookSwatchContrast.background(for: color, contrast: contrast)), 3,
                    "Selection must remain visible on \(color) with \(contrast) contrast."
                )
            }
        }
    }

    func testSwatchMarksResolveTheWellForTheViewsContrast() {
        let clear = EditorInkColor(red: 0, green: 0, blue: 0, alpha: 0)
        let standard = NotebookSwatchContrast.background(for: clear, contrast: .standard)
        let increased = NotebookSwatchContrast.background(for: clear, contrast: .increased)
        let wells = [UIAccessibilityContrast.normal, .high].map { contrast in
            NotebookSwatchShelf.color(from: NotebookTheme.selectedWell.uiColor.resolvedColor(
                with: UITraitCollection(accessibilityContrast: contrast)
            ))
        }
        XCTAssertEqual(standard, wells[0], "A transparent ink shows the standard well.")
        XCTAssertEqual(increased, wells[1], "Under Increase Contrast the darker well is measured, whatever the current traits.")
        XCTAssertNotEqual(standard, increased)
    }

    func testFaintSwatchesGetADarkRingAndCatalogueSwatchesKeepTheSoftOne() {
        for swatch in EditorInkCatalog.swatches + EditorInkCatalog.presets.map(\.color) {
            XCTAssertFalse(NotebookSwatchContrast.isFaint(swatch), "\(swatch) stands out from the ink row by itself.")
        }
        for faint in [
            EditorInkColor(red: 0.95, green: 0.94, blue: 0.9), EditorInkColor(red: 1, green: 1, blue: 0.6),
            EditorInkColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 0.1),
        ] {
            XCTAssertTrue(NotebookSwatchContrast.isFaint(faint), "\(faint) needs a dark ring.")
        }
        let shell = NotebookSwatchContrast.inkRowShell
        XCTAssertEqual(shell.red * 255, 230, accuracy: 1)
        XCTAssertEqual(shell.green * 255, 227, accuracy: 1)
        XCTAssertEqual(shell.blue * 255, 220, accuracy: 1)
    }

    func testAddingCustomColoursSelectsThemAndKeepsTheShelfBounded() throws {
        let (store, owner) = availableStore()
        defer { store.detach(owner) }
        let actions = NotebookToolbarActions(store: store)
        actions.select(.lasso)
        let colors = (0..<9).map { EditorInkColor(red: 26.0 / 255, green: Double($0 * 25) / 255, blue: 77.0 / 255) }
        for color in colors { actions.addCustomColor(color) }
        XCTAssertEqual(store.toolbar.customSwatches.count, 8)
        XCTAssertEqual(store.toolbar.customSwatches.first, colors.last)
        XCTAssertEqual(store.tool.color, colors.last)
        XCTAssertNotNil(store.tool.inkFamily)
        actions.addCustomColor(colors[4])
        XCTAssertEqual(store.toolbar.customSwatches.first, colors[4])
        XCTAssertEqual(store.toolbar.customSwatches.count, 8)
        XCTAssertEqual(NotebookSwatchShelf.displayed(custom: store.toolbar.customSwatches).count, EditorInkCatalog.swatches.count + 8)
        XCTAssertEqual(
            NotebookSwatchShelf.displayed(custom: [colors[0], EditorInkCatalog.swatches[1], colors[0]]),
            EditorInkCatalog.swatches + [colors[0]],
            "The shelf shows each colour once."
        )
    }

    // MARK: - Selection, pressed and focus states

    func testInkMarksAreLitOnlyForTheInkInUse() throws {
        let (store, owner) = availableStore()
        defer { store.detach(owner) }
        let actions = NotebookToolbarActions(store: store)
        let preset = try XCTUnwrap(EditorInkCatalog.presets.first)
        actions.apply(preset)
        var marks = NotebookInkMarks(tool: store.tool, custom: store.toolbar.customSwatches)
        XCTAssertEqual(marks.color, preset.color)
        XCTAssertFalse(marks.marksCustomColor)
        XCTAssertEqual(marks.width, preset.widthStep)
        XCTAssertEqual(marks.presetID, preset.id)

        for kind in [EditorToolKind.eraser(.vector), .eraser(.bitmap), .lasso] {
            actions.select(kind)
            marks = NotebookInkMarks(tool: store.tool, custom: store.toolbar.customSwatches)
            XCTAssertEqual(marks, .unlit, "Colour, width and preset marks are not lit while using \(kind).")
        }

        actions.addCustomColor(EditorInkColor(red: 0.2, green: 0.6, blue: 0.4))
        marks = NotebookInkMarks(tool: store.tool, custom: store.toolbar.customSwatches)
        XCTAssertEqual(marks.color, store.tool.color, "A colour on the shelf is marked on its swatch.")
        XCTAssertFalse(marks.marksCustomColor)

        // Another scene may have replaced the shared shelf since this colour was chosen.
        marks = NotebookInkMarks(tool: store.tool, custom: [])
        XCTAssertNil(marks.color)
        XCTAssertTrue(marks.marksCustomColor, "A colour missing from the shelf is marked on the custom colour well.")
        XCTAssertEqual(marks.width, store.tool.widthStep)
    }

    func testControlStatesDrawDistinctShapes() throws {
        func rendered(selected: Bool = false, pressed: Bool = false, focused: Bool = false) throws -> RenderedPixels {
            try renderedAlone(
                NotebookKeyStyle.Background(shape: .well, isSelected: selected, isPressed: pressed, isFocused: focused)
                    .frame(width: NotebookTheme.controlSize, height: NotebookTheme.controlSize)
            )
        }
        let rest = try rendered()
        XCTAssertTrue(rest.alpha.allSatisfy { $0 == 0 }, "A control at rest draws nothing behind it.")
        let states = [
            "rest": rest,
            "pressed": try rendered(pressed: true),
            "selected": try rendered(selected: true),
            "focused": try rendered(focused: true)
        ]
        for (first, firstPixels) in states {
            for (second, secondPixels) in states where first < second {
                XCTAssertTrue(
                    firstPixels.alpha != secondPixels.alpha, "\(first) and \(second) must differ in shape or opacity, not only in hue."
                )
            }
        }
        XCTAssertTrue(
            try rendered(selected: true, pressed: true).rgba != XCTUnwrap(states["selected"]).rgba,
            "Pressing a selected control still responds."
        )
        XCTAssertTrue(
            try rendered(selected: true, focused: true).rgba != XCTUnwrap(states["selected"]).rgba,
            "Focus stays visible on a selected control."
        )

        let unmarked = try RenderedPixels(rendering: NotebookToolGlyph(symbol: "pencil", isSelected: false))
        let marked = try RenderedPixels(rendering: NotebookToolGlyph(symbol: "pencil", isSelected: true))
        XCTAssertTrue(unmarked.alpha != marked.alpha, "A selected tool carries a mark, not only a colour.")
    }

    func testCompactWidthFoldsTheSwatchRowIntoTheCurrentInkChip() {
        let regular = NotebookToolbarComposition(preferences: .standard, horizontalSizeClass: .regular)
        let compact = NotebookToolbarComposition(preferences: .standard, horizontalSizeClass: .compact)
        XCTAssertFalse(regular.foldsInkOptions)
        XCTAssertTrue(compact.foldsInkOptions)
        XCTAssertEqual(regular.rowCount, 2)
        XCTAssertEqual(compact.rowCount, 1)
        XCTAssertLessThan(compact.expandedHeight, regular.expandedHeight)
        XCTAssertGreaterThanOrEqual(compact.expandedHeight, NotebookTheme.controlSize)

        let narrow = regular.toolbarSize(forHostWidth: 360)
        XCTAssertEqual(narrow.width, 360 - 2 * EditorToolbarLayout.margin)
        let wide = regular.toolbarSize(forHostWidth: 1_400)
        XCTAssertLessThan(wide.width, 1_400 - 2 * EditorToolbarLayout.margin, "Docked positions stay distinct on wide screens.")
        XCTAssertEqual(wide.height, regular.expandedHeight)
    }

    func testInkGlyphsResolveAndAreDistinct() {
        let symbols = EditorInkFamily.allCases.map(\.symbol)
        for (family, symbol) in zip(EditorInkFamily.allCases, symbols) {
            XCTAssertNotNil(UIImage(systemName: symbol), "\(family): \(symbol)")
        }
        XCTAssertEqual(Set(symbols).count, symbols.count, "Every ink has its own glyph.")
        XCTAssertNotEqual(EditorInkFamily.monoline.symbol, "scribble", "Monoline and Crayon no longer share a scribble.")
    }

    func testStripOverflowShowsChevronsOnlyWhereToolsAreHidden() {
        let fits = NotebookStripOverflow(offset: 0, contentWidth: 300, containerWidth: 400)
        XCTAssertFalse(fits.hidesLeading)
        XCTAssertFalse(fits.hidesTrailing)

        let start = NotebookStripOverflow(offset: 0, contentWidth: 900, containerWidth: 400)
        XCTAssertFalse(start.hidesLeading)
        XCTAssertTrue(start.hidesTrailing)

        let end = NotebookStripOverflow(offset: 500, contentWidth: 900, containerWidth: 400)
        XCTAssertTrue(end.hidesLeading)
        XCTAssertFalse(end.hidesTrailing)

        XCTAssertEqual(fits.hiddenEdges, .none)
        let scrolling = (100...400).map { NotebookStripOverflow(offset: CGFloat($0), contentWidth: 900, containerWidth: 400) }
        XCTAssertTrue(
            scrolling.allSatisfy { $0.hiddenEdges == scrolling[0].hiddenEdges },
            "Scrolling between the edges never changes what the strip draws."
        )
        XCTAssertEqual(scrolling[0].hiddenEdges, NotebookStripOverflow.HiddenEdges(leading: true, trailing: true))
        XCTAssertEqual(end.hiddenEdges, NotebookStripOverflow.HiddenEdges(leading: true, trailing: false))
    }

    /// The ink strip of an 11-inch iPad in portrait with two custom colours: presets, then six of
    /// the nine swatches before the trailing chevron.
    func testRestingStripShowsOnlyWholeControls() throws {
        let preferences = toolbar(customColors: 2)
        let rail = self.rail(for: preferences, hostWidth: 834)
        let row = try XCTUnwrap(rail.inkRow)
        XCTAssertTrue(rail.inkRowOverflows)
        let width = inkStripWidth(rail)
        let swatches = row.slots.filter { if case .swatch = $0.item { true } else { false } }
        XCTAssertEqual(swatches.count, 9)

        let atStart = row.restingMask(for: stripOverflow(of: row, at: 0, in: width))
        XCTAssertEqual(atStart.start, 0)
        XCTAssertEqual(atStart.end, swatches[5].maxX, accuracy: 0.001, "The strip ends after the sixth whole swatch.")
        XCTAssertGreaterThan(swatches[6].maxX, width, "The seventh would show in part, so it is masked.")
        for slot in row.slots where !slot.item.isDivider {
            let shown = slot.minX >= atStart.start && slot.maxX <= atStart.end
            let hidden = slot.maxX <= atStart.start || slot.minX >= atStart.end
            XCTAssertTrue(shown || hidden, "\(slot.id) is either whole or masked.")
        }

        // Anywhere a drag leaves it, the mask still shows only whole controls clear of the chevron.
        for offset in stride(from: CGFloat(1.5), through: row.maximumOffset(containerWidth: width), by: 7) {
            let overflow = stripOverflow(of: row, at: offset, in: width)
            let mask = row.restingMask(for: overflow)
            XCTAssertGreaterThanOrEqual(mask.start, NotebookTheme.controlSize - 0.5, "\(offset)")
            for slot in row.slots where !slot.item.isDivider {
                let minX = slot.minX - offset
                let maxX = slot.maxX - offset
                let shown = minX >= mask.start - 0.001 && maxX <= mask.end + 0.001
                let hidden = maxX <= mask.start + 0.001 || minX >= mask.end - 0.001
                XCTAssertTrue(shown || hidden, "\(slot.id) at \(offset)")
            }
        }
    }

    func testChevronsPageByWholeControlsAndFlicksRestOnThem() throws {
        let rail = self.rail(for: toolbar(customColors: 8), hostWidth: 834)
        let row = try XCTUnwrap(rail.inkRow)
        let width = inkStripWidth(rail)
        let maximum = row.maximumOffset(containerWidth: width)
        let controls = row.slots.filter { !$0.item.isDivider }
        var overflow = stripOverflow(of: row, at: 0, in: width)
        var pages = 0
        while overflow.hidesTrailing {
            let hidden = try XCTUnwrap(controls.first { $0.maxX > overflow.offset + width + 0.5 })
            let next = row.trailingPage(from: overflow)
            XCTAssertGreaterThan(next, overflow.offset)
            if next < maximum {
                XCTAssertEqual(hidden.minX - next, NotebookStripRow.leadingClearance, accuracy: 0.001,
                    "The first control hidden becomes the first one shown.")
            }
            overflow = stripOverflow(of: row, at: next, in: width)
            pages += 1
        }
        XCTAssertEqual(overflow.offset, maximum, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(pages, 1)

        while overflow.hidesLeading {
            let hidden = try XCTUnwrap(controls.last { $0.minX < overflow.offset + NotebookStripRow.leadingClearance - 0.5 })
            let previous = row.leadingPage(from: overflow)
            XCTAssertLessThan(previous, overflow.offset)
            XCTAssertLessThanOrEqual(hidden.maxX, previous + width + 0.5, "The nearest hidden control comes into view.")
            overflow = stripOverflow(of: row, at: previous, in: width)
        }
        XCTAssertEqual(overflow.offset, 0)

        let stops = row.restingOffsets(containerWidth: width)
        XCTAssertEqual(stops.first, 0)
        XCTAssertEqual(stops.last, maximum)
        for proposed in stride(from: CGFloat(-40), through: maximum + 40, by: 13) {
            let rest = row.restingOffset(near: proposed, containerWidth: width)
            XCTAssertTrue(stops.contains(rest))
            if rest > 0 {
                XCTAssertTrue(controls.contains { abs($0.minX - rest - NotebookStripRow.leadingClearance) < 0.001 },
                    "A flick rests with a whole control just clear of the leading chevron, at the end too.")
            }
        }
    }

    /// Scrolled to its end, a strip shows its first control just clear of the leading chevron, as
    /// at every other stop, and its last control whole; the width left over shows after the last
    /// control rather than as a gap before the first.
    func testAStripAtItsEndLeavesItsSpareWidthAfterTheLastControl() throws {
        var rows: [(label: String, row: NotebookStripRow, width: CGFloat)] = []
        for custom in [0, 2, 4, 8] {
            for hostWidth in [678.0, 834, 1_194] as [CGFloat] {
                let rail = self.rail(for: toolbar(customColors: custom), hostWidth: hostWidth)
                guard rail.inkRowOverflows else { continue }
                rows.append(("ink row, \(hostWidth) with \(custom)", try XCTUnwrap(rail.inkRow), inkStripWidth(rail)))
            }
        }
        for (sizeClass, hostWidth) in [(UserInterfaceSizeClass.regular, CGFloat(678)), (.compact, 507)] {
            let composition = NotebookToolbarComposition(preferences: .standard, horizontalSizeClass: sizeClass)
            let rail = composition.rail(forHostWidth: hostWidth)
            XCTAssertTrue(rail.toolRowOverflows)
            // The rail less its grip column, the cap after the strip and the trailing chevron's slot.
            let width = rail.size.width - NotebookToolbarComposition.gripColumnWidth - composition.toolCapWidth
                - NotebookTheme.controlSize
            rows.append(("tool row, \(hostWidth)", rail.toolRow, width))
        }
        XCTAssertGreaterThanOrEqual(rows.count, 8)
        // A stop further on would show a whole control more: at most the widest chip and a divider.
        let widestStep = NotebookPresetChip.width(for: EditorInkCatalog.presets[1], at: .xxLarge)
            + NotebookToolbarComposition.groupGap

        for (label, row, width) in rows {
            let maximum = row.maximumOffset(containerWidth: width)
            // The strip pads its content with the trailing room, so this is the width it scrolls through.
            let scrollWidth = row.contentWidth + row.trailingRoom(containerWidth: width)
            XCTAssertEqual(scrollWidth - width, maximum, accuracy: 0.001, label)
            let end = NotebookStripOverflow(offset: maximum, contentWidth: scrollWidth, containerWidth: width)
            XCTAssertTrue(end.hidesLeading, label)
            XCTAssertFalse(end.hidesTrailing, "\(label): nothing is left to page to.")
            let mask = row.restingMask(for: end)
            XCTAssertEqual(mask.start, NotebookStripRow.leadingClearance, accuracy: 0.001, "\(label): no gap before it.")
            XCTAssertEqual(mask.end, width, label)
            let last = try XCTUnwrap(row.slots.last { !$0.item.isDivider })
            let spare = width - (last.maxX - maximum)
            XCTAssertGreaterThanOrEqual(spare, -0.001, "\(label): the last control shows whole.")
            XCTAssertLessThan(spare, widestStep, "\(label): less than one control is left over.")
            XCTAssertEqual(row.restingOffsets(containerWidth: width).last, maximum, label)
        }
        let fits = try XCTUnwrap(self.rail(for: .standard, hostWidth: 1_024).inkRow)
        XCTAssertEqual(fits.trailingRoom(containerWidth: 900), 0, "A strip that fits gains no room.")
    }

    // MARK: - Rail width rule

    /// The rail in the 11-inch and 12.9-inch iPads' regular-width windows, with 0, 2, 4 and 8 custom
    /// colours, at the default text size and at the rail's xxLarge limit. Larger chips widen the ink
    /// row by 47 points there, which is what moves the eleven-inch landscape rail apart from its limit.
    /// One top dock, so the rail grows to the window's width inside its margins, showing the
    /// planned tools wherever the whole group fits. A floating rail measures the same way with its
    /// collapse key closing the first row.
    func testRailWidthFollowsThePlannedToolRules() throws {
        struct Case {
            let width: CGFloat
            let customColors: Int
            var textSize = DynamicTypeSize.large
            let rail: CGFloat
            let showsUpcoming: Bool
        }
        let cases = [
            Case(width: 834, customColors: 0, rail: 807, showsUpcoming: false),
            Case(width: 834, customColors: 2, rail: 810, showsUpcoming: false),
            Case(width: 834, customColors: 4, rail: 810, showsUpcoming: false),
            Case(width: 834, customColors: 8, rail: 810, showsUpcoming: false),
            Case(width: 1_194, customColors: 0, rail: 965, showsUpcoming: true),
            Case(width: 1_194, customColors: 2, rail: 965, showsUpcoming: true),
            Case(width: 1_194, customColors: 4, rail: 991, showsUpcoming: true),
            Case(width: 1_194, customColors: 8, rail: 1_170, showsUpcoming: true),
            Case(width: 1_024, customColors: 0, rail: 965, showsUpcoming: true),
            Case(width: 1_024, customColors: 2, rail: 965, showsUpcoming: true),
            Case(width: 1_024, customColors: 4, rail: 991, showsUpcoming: true),
            Case(width: 1_024, customColors: 8, rail: 1_000, showsUpcoming: true),
            Case(width: 1_366, customColors: 0, rail: 965, showsUpcoming: true),
            Case(width: 1_366, customColors: 2, rail: 965, showsUpcoming: true),
            Case(width: 1_366, customColors: 4, rail: 991, showsUpcoming: true),
            Case(width: 1_366, customColors: 8, rail: 1_175, showsUpcoming: true),
            Case(width: 678, customColors: 0, rail: 654, showsUpcoming: false),
            Case(width: 678, customColors: 2, rail: 654, showsUpcoming: false),
            Case(width: 678, customColors: 4, rail: 654, showsUpcoming: false),
            Case(width: 678, customColors: 8, rail: 654, showsUpcoming: false),

            Case(width: 834, customColors: 0, textSize: .xxLarge, rail: 810, showsUpcoming: false),
            Case(width: 834, customColors: 2, textSize: .xxLarge, rail: 810, showsUpcoming: false),
            Case(width: 834, customColors: 4, textSize: .xxLarge, rail: 810, showsUpcoming: false),
            Case(width: 834, customColors: 8, textSize: .xxLarge, rail: 810, showsUpcoming: false),
            Case(width: 1_194, customColors: 0, textSize: .xxLarge, rail: 965, showsUpcoming: true),
            Case(width: 1_194, customColors: 2, textSize: .xxLarge, rail: 965, showsUpcoming: true),
            Case(width: 1_194, customColors: 4, textSize: .xxLarge, rail: 1_038, showsUpcoming: true),
            Case(width: 1_194, customColors: 8, textSize: .xxLarge, rail: 1_170, showsUpcoming: true),
            Case(width: 1_024, customColors: 0, textSize: .xxLarge, rail: 965, showsUpcoming: true),
            Case(width: 1_024, customColors: 2, textSize: .xxLarge, rail: 965, showsUpcoming: true),
            Case(width: 1_024, customColors: 4, textSize: .xxLarge, rail: 1_000, showsUpcoming: true),
            Case(width: 1_024, customColors: 8, textSize: .xxLarge, rail: 1_000, showsUpcoming: true),
            Case(width: 1_366, customColors: 0, textSize: .xxLarge, rail: 965, showsUpcoming: true),
            Case(width: 1_366, customColors: 2, textSize: .xxLarge, rail: 965, showsUpcoming: true),
            Case(width: 1_366, customColors: 4, textSize: .xxLarge, rail: 1_038, showsUpcoming: true),
            Case(width: 1_366, customColors: 8, textSize: .xxLarge, rail: 1_222, showsUpcoming: true),
            Case(width: 678, customColors: 0, textSize: .xxLarge, rail: 654, showsUpcoming: false),
            Case(width: 678, customColors: 2, textSize: .xxLarge, rail: 654, showsUpcoming: false),
            Case(width: 678, customColors: 4, textSize: .xxLarge, rail: 654, showsUpcoming: false),
            Case(width: 678, customColors: 8, textSize: .xxLarge, rail: 654, showsUpcoming: false),
        ]
        for test in cases {
            let preferences = toolbar(customColors: test.customColors)
            let label = "\(test.width) with \(test.customColors) custom colours at \(test.textSize)"
            let rail = self.rail(for: preferences, hostWidth: test.width, textSize: test.textSize)
            XCTAssertEqual(rail.size.width, test.rail, accuracy: 0.001, label)
            XCTAssertEqual(rail.size.height, 2 * NotebookTheme.rowHeight + NotebookTheme.rowSpacing, label)
            XCTAssertEqual(rail.orientation, .horizontal, label)
            XCTAssertEqual(rail.showsUpcoming, test.showsUpcoming, label)
            XCTAssertEqual(rail.toolRow.slots.contains { $0.item.isPlaceholder }, test.showsUpcoming, label)
            XCTAssertEqual(
                rail.toolRow.slots.contains { $0.item == .upcomingLabel }, test.showsUpcoming,
                "\(label): the planned tools show as a whole group or not at all."
            )
            XCTAssertLessThanOrEqual(rail.size.width, test.width - 2 * EditorToolbarLayout.margin, label)
            // A floating rail ends its first row with the collapse key; the planned tools yield to it
            // where both cannot fit, and the rail grows by the key only where that row governs.
            var floating = preferences
            floating.place(.floating(CGPoint(x: 0.5, y: 0.5)))
            let floatingRail = self.rail(for: floating, hostWidth: test.width, textSize: test.textSize)
            let key = NotebookToolbarComposition.groupGap + NotebookTheme.controlSize
            let grip = NotebookToolbarComposition.gripColumnWidth
            let available = test.width - 2 * EditorToolbarLayout.margin
            let inkWidth = try XCTUnwrap(rail.inkRow, label).contentWidth + NotebookToolbarComposition.inkCapWidth
            let keepsGroup = test.showsUpcoming
                && grip + rail.toolRow.contentWidth + NotebookTheme.stripInsets.right + key <= available
            XCTAssertEqual(floatingRail.showsUpcoming, keepsGroup, "\(label): the planned tools yield to the collapse key.")
            let row = floatingRail.toolRow.contentWidth + NotebookTheme.stripInsets.right + key
            XCTAssertEqual(floatingRail.size.width, min(grip + max(row, inkWidth), available), accuracy: 0.001, label)
            XCTAssertEqual(floatingRail.size.height, rail.size.height, label)
            XCTAssertEqual(floatingRail.toolRowOverflows, grip + row > available + 0.5, label)
        }
    }

    /// On end at a side the rail is the grip column and two 52-point columns wide, and as tall as its
    /// longer column up to the height below the header, on the 11-inch and 13-inch iPads in both
    /// orientations. The planned tools show only as a whole group, and a column that cannot fit
    /// scrolls and keeps a slot for its chevron.
    func testVerticalRailFitsBelowTheHeaderInEveryOrientation() {
        struct Case {
            let name: String
            /// The toolbar layer's height: the screen less the status bar, the header and the home indicator.
            let height: CGFloat
            let customColors: Int
            let length: CGFloat
            let showsUpcoming: Bool
            let toolsScroll: Bool
            let inkScrolls: Bool
        }
        let cases = [
            Case(name: "11-inch portrait", height: 1_104, customColors: 0, length: 921, showsUpcoming: true, toolsScroll: false, inkScrolls: false),
            Case(name: "11-inch portrait", height: 1_104, customColors: 8, length: 956, showsUpcoming: true, toolsScroll: false, inkScrolls: false),
            Case(name: "11-inch landscape", height: 728, customColors: 0, length: 680, showsUpcoming: false, toolsScroll: false, inkScrolls: false),
            Case(name: "11-inch landscape", height: 728, customColors: 2, length: 680, showsUpcoming: false, toolsScroll: false, inkScrolls: false),
            Case(name: "11-inch landscape", height: 728, customColors: 8, length: 704, showsUpcoming: false, toolsScroll: false, inkScrolls: true),
            Case(name: "13-inch portrait", height: 1_270, customColors: 0, length: 921, showsUpcoming: true, toolsScroll: false, inkScrolls: false),
            Case(name: "13-inch portrait", height: 1_270, customColors: 8, length: 956, showsUpcoming: true, toolsScroll: false, inkScrolls: false),
            Case(name: "13-inch landscape", height: 926, customColors: 0, length: 680, showsUpcoming: false, toolsScroll: false, inkScrolls: false),
            Case(name: "13-inch landscape", height: 926, customColors: 4, length: 772, showsUpcoming: false, toolsScroll: false, inkScrolls: false),
            Case(name: "13-inch landscape", height: 926, customColors: 8, length: 902, showsUpcoming: false, toolsScroll: false, inkScrolls: true),
            Case(name: "short window", height: 500, customColors: 0, length: 476, showsUpcoming: false, toolsScroll: true, inkScrolls: true),
        ]
        for test in cases {
            for dock in [EditorToolbarDock.leftEdge, .rightEdge] {
                var preferences = toolbar(customColors: test.customColors)
                preferences.place(.docked(dock))
                let label = "\(test.name) with \(test.customColors) custom colours at the \(dock)"
                let composition = NotebookToolbarComposition(preferences: preferences, horizontalSizeClass: .regular)
                let usable = CGRect(x: 0, y: 0, width: 834, height: test.height)
                let rail = composition.rail(in: usable.size)
                XCTAssertEqual(rail.orientation, dock == .leftEdge ? .leftEdge : .rightEdge, label)
                XCTAssertEqual(rail.size.width, 152, label)
                XCTAssertEqual(rail.size.height, test.length, accuracy: 0.001, label)
                XCTAssertLessThanOrEqual(rail.size.height, test.height - 2 * EditorToolbarLayout.margin, label)
                XCTAssertEqual(rail.showsUpcoming, test.showsUpcoming, label)
                XCTAssertEqual(rail.toolRowOverflows, test.toolsScroll, label)
                XCTAssertEqual(rail.inkRowOverflows, test.inkScrolls, label)
                XCTAssertEqual(rail.toolRow.slots.contains { $0.item == .upcomingLabel }, test.showsUpcoming, label)
                let ink = try? XCTUnwrap(rail.inkRow)
                XCTAssertTrue(
                    ink?.slots.allSatisfy { $0.item.isDivider || $0.width == NotebookTheme.controlSize } ?? false,
                    "\(label): every control in a column, presets included, is a square key."
                )
                XCTAssertEqual(composition.dockSizes(in: usable.size).vertical, rail.size, label)

                let frame = composition.frame(of: rail, in: usable)
                XCTAssertEqual(frame.midY, usable.midY, accuracy: 0.001, "\(label): centred along its edge.")
                XCTAssertTrue(usable.insetBy(dx: 11.999, dy: 11.999).contains(frame), label)
            }
        }
    }

    /// At a side the rail stands on end from the screen edge toward the page, mirrored per side: the
    /// grip against the edge, the tools beside it, and the ink column nearest the page, where the
    /// second row opens, so the first row alone is the grip and the tools facing the page. At compact
    /// width, where a column cannot hold the folded ink, a stored side rests at the top in rows and
    /// keeps its side for a wider window.
    func testSideDocksStandTheRailOnEndFromTheScreenEdgeTowardThePage() {
        let sides: [(EditorToolbarDock, NotebookRailOrientation, [NotebookRailColumn], Alignment)] = [
            (.leftEdge, .leftEdge, [.grip, .tools, .ink], .leading),
            (.rightEdge, .rightEdge, [.ink, .tools, .grip], .trailing),
        ]
        for (dock, orientation, columns, anchor) in sides {
            let preferences = EditorToolbarPreferences(placement: .docked(dock), isCollapsed: false, customSwatches: [])
            let regular = NotebookToolbarComposition(preferences: preferences, horizontalSizeClass: .regular)
            XCTAssertTrue(regular.offersSideDocks)
            XCTAssertEqual(regular.shownDock, dock)
            XCTAssertEqual(regular.orientation, orientation)
            XCTAssertEqual(orientation.axis, .vertical)
            XCTAssertEqual(orientation.columns, columns, "\(dock): from left to right")
            XCTAssertEqual(orientation.anchor, anchor, "\(dock): drawn against the screen edge")
            let wide = CGRect(x: 0, y: 0, width: 1_024, height: 1_290)
            let rail = regular.rail(in: wide.size)
            XCTAssertEqual(
                rail.firstRowSize, CGSize(width: NotebookToolbarComposition.gripColumnWidth + NotebookTheme.rowHeight, height: rail.size.height),
                "\(dock): the first row on end is the grip and the tool column."
            )

            let compact = NotebookToolbarComposition(preferences: preferences, horizontalSizeClass: .compact)
            XCTAssertFalse(compact.offersSideDocks)
            XCTAssertEqual(compact.storedDock, dock)
            XCTAssertEqual(compact.shownDock, .topCenter)
            XCTAssertEqual(compact.orientation, .horizontal)
            let usable = CGRect(x: 0, y: 0, width: 507, height: 1_290)
            XCTAssertEqual(compact.rail(in: usable.size), compact.rail(forHostWidth: 507))
            let top = EditorToolbarLayout.frame(
                for: .docked(.topCenter), size: compact.toolbarSize(of: compact.rail(in: usable.size)), in: usable
            )
            XCTAssertEqual(compact.frame(in: usable), top, "\(dock): it rests at the top.")
            let side = EditorToolbarLayout.frame(for: .docked(dock), size: regular.toolbarSize(of: rail), in: wide)
            XCTAssertEqual(regular.frame(in: wide), side, "\(dock): a wider window shows it at its side.")
        }
        let floating = NotebookToolbarComposition(
            preferences: EditorToolbarPreferences(placement: .floating(CGPoint(x: 0.1, y: 0.5)), isCollapsed: false, customSwatches: []),
            horizontalSizeClass: .regular
        )
        XCTAssertNil(floating.shownDock)
        XCTAssertEqual(floating.orientation, .horizontal, "A floating rail always lies in rows.")
        XCTAssertEqual(floating.orientation.columns, [])
        XCTAssertEqual(floating.orientation.anchor, .top, "Rows open downward, below the tools.")
    }

    func testRowsCountEveryDividerAndChipTheyLayOut() {
        let composition = NotebookToolbarComposition(preferences: .standard, horizontalSizeClass: .regular)
        let inset = NotebookTheme.stripInsets.right
        XCTAssertEqual(NotebookToolbarComposition.dividerWidth, 9)
        XCTAssertEqual(NotebookToolbarComposition.groupGap, 13)
        XCTAssertEqual(composition.toolRow(includingUpcoming: false).contentWidth + inset, 680)
        XCTAssertEqual(composition.toolRow(includingUpcoming: true).contentWidth + inset, 921)
        let chips = EditorInkCatalog.presets.map { NotebookPresetChip.width(for: $0, at: .large) }
        XCTAssertEqual(chips, [77, 98, 96, 80], "Sepia, Charcoal, Graphite and Ochre at the default text size.")
        for custom in 0...8 {
            let swatches = EditorInkCatalog.swatches + (0..<custom).map { EditorInkColor(red: 0.1, green: Double($0) / 10, blue: 0.6) }
            XCTAssertEqual(
                composition.inkRow(swatches).contentWidth + NotebookToolbarComposition.inkCapWidth,
                763 + 46 * CGFloat(custom), "\(custom) custom colours"
            )
        }
        let large = NotebookToolbarComposition(preferences: .standard, horizontalSizeClass: .regular, dynamicTypeSize: .xxLarge)
        let accessibility = NotebookToolbarComposition(
            preferences: .standard, horizontalSizeClass: .regular, dynamicTypeSize: .accessibility5
        )
        XCTAssertEqual(accessibility, large, "Text sizes above the rail's limit lay out as its limit.")
        let largeChips = EditorInkCatalog.presets.map { NotebookPresetChip.width(for: $0, at: .xxLarge) }
        XCTAssertEqual(largeChips.reduce(0, +) + 3 * NotebookTheme.itemSpacing, 404, accuracy: 4, "About 404 pt at xxLarge.")
        XCTAssertEqual(large.toolRow(includingUpcoming: true), composition.toolRow(includingUpcoming: true),
            "The tool row keeps its size at every text size.")
    }

    func testLargeTextNarrowsTheInkRowOnTheElevenInchIPad() throws {
        let composition = NotebookToolbarComposition(
            preferences: .standard, horizontalSizeClass: .regular, dynamicTypeSize: .xxLarge
        )
        let rail = composition.rail(forHostWidth: 834)
        XCTAssertEqual(rail.size.width, 810)
        XCTAssertFalse(rail.showsUpcoming)
        XCTAssertTrue(rail.inkRowOverflows)
        let row = try XCTUnwrap(rail.inkRow)
        let width = inkStripWidth(rail)
        let mask = row.restingMask(for: stripOverflow(of: row, at: 0, in: width))
        let shown = row.slots.filter { !$0.item.isDivider && $0.maxX <= mask.end + 0.001 }
        XCTAssertEqual(shown.filter { if case .preset = $0.item { true } else { false } }.count, 4, "Every preset shows.")
        XCTAssertEqual(shown.filter { if case .swatch = $0.item { true } else { false } }.count, 5)
    }

    func testPresetChipsUseShortLabelsThatFitTheirMeasuredWidth() {
        XCTAssertEqual(EditorInkCatalog.presets.map(NotebookPresetChip.shortTitle), ["Sepia", "Charcoal", "Graphite", "Ochre"])
        for size in [DynamicTypeSize.large, .xxLarge] {
            for weight in [LegibilityWeight.regular, .bold] {
                for preset in EditorInkCatalog.presets {
                    let title = NotebookPresetChip.shortTitle(for: preset)
                    let text = UIHostingController(rootView: Text(title).font(NotebookTheme.controlLabel.font).fixedSize()
                        .environment(\.dynamicTypeSize, size).environment(\.legibilityWeight, weight))
                    let rendered = text.sizeThatFits(in: CGSize(width: 1_000, height: 1_000)).width
                    let measured = NotebookPresetChip.labelWidth(title, at: size, isBold: weight == .bold)
                    XCTAssertGreaterThanOrEqual(measured, rendered - 0.01, "\(title) at \(size), \(weight)")
                    XCTAssertLessThan(measured, rendered + 1, "\(title) at \(size), \(weight)")
                }
            }
        }
    }

    /// Bold Text sets the preset labels wider. The rail counts the wider chips, and each chip lays
    /// itself out at exactly the width counted for it.
    func testBoldTextWidensThePresetChipsTheRailCounts() throws {
        let charcoal = try XCTUnwrap(EditorInkCatalog.presets.first { $0.id == "charcoal-monoline" })
        XCTAssertGreaterThan(
            NotebookPresetChip.labelWidth("Charcoal", at: .large, isBold: true),
            NotebookPresetChip.labelWidth("Charcoal", at: .large, isBold: false)
        )
        for preset in EditorInkCatalog.presets {
            let chip = try RenderedPixels(rendering: NotebookPresetChip(preset: preset, isSelected: preset == charcoal) {}
                .environment(\.legibilityWeight, .bold))
            XCTAssertEqual(chip.size.width, NotebookPresetChip.width(for: preset, at: .large, isBold: true), preset.id)
        }
        let regular = NotebookToolbarComposition(preferences: .standard, horizontalSizeClass: .regular)
        let bold = NotebookToolbarComposition(
            preferences: .standard, horizontalSizeClass: .regular, legibilityWeight: .bold
        )
        let boldChips = EditorInkCatalog.presets.map { NotebookPresetChip.width(for: $0, at: .large, isBold: true) }
        let regularChips = EditorInkCatalog.presets.map { NotebookPresetChip.width(for: $0, at: .large) }
        XCTAssertEqual(
            bold.inkRow(EditorInkCatalog.swatches).contentWidth - regular.inkRow(EditorInkCatalog.swatches).contentWidth,
            boldChips.reduce(0, +) - regularChips.reduce(0, +), accuracy: 0.01, "The ink row counts the wider chips."
        )
    }

    /// The compact ink panel is presented outside the rail's text-size limit, so each chip keeps
    /// to it by itself: at accessibility sizes it draws exactly as at the limit, its label never
    /// spilling past the capsule measured for it.
    func testPresetChipsDrawAtTheRailsTextLimitWherever() throws {
        for preset in EditorInkCatalog.presets {
            func chip(at size: DynamicTypeSize) throws -> RenderedPixels {
                try RenderedPixels(rendering: NotebookPresetChip(preset: preset, isSelected: false) {}
                    .environment(\.dynamicTypeSize, size))
            }
            let limit = try chip(at: NotebookToolbarComposition.textSizeLimit)
            XCTAssertEqual(limit.size.width, NotebookPresetChip.width(for: preset, at: .xxLarge), preset.id)
            for size in [DynamicTypeSize.accessibility1, .accessibility3, .accessibility5] {
                let large = try chip(at: size)
                XCTAssertEqual(large.size, limit.size, "\(preset.id) at \(size)")
                XCTAssertTrue(large.rgba == limit.rgba, "\(preset.id) at \(size) draws as at the limit.")
            }
        }
    }

    // MARK: - Placement around the real canvas

    func testEveryPlacementOverlaysTheFullCanvasWithoutMovingThePage() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost()
        defer { fixture.close() }
        let store = fixture.store
        let canvas = fixture.controller.canvasView
        let actions = NotebookToolbarActions(store: store)
        let hostHeight = fixture.hosting.view.bounds.height
        XCTAssertEqual(store.toolbar.placement, .docked(.topCenter))
        XCTAssertEqual(canvas.bounds.height, hostHeight, accuracy: 0.5)
        XCTAssertEqual(fixture.canvasFrame.minY, 0, accuracy: 0.5)

        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: 900), animated: false)
        let centre = logicalCentre(canvas)
        let zoom = canvas.zoomScale

        actions.place(.floating(CGPoint(x: 0.5, y: 0.3)))
        try await NotebookTestFixtures.waitUntil { abs(canvas.bounds.height - hostHeight) < 0.5 }
        XCTAssertEqual(fixture.canvasFrame.minY, 0, accuracy: 0.5)
        XCTAssertEqual(canvas.zoomScale, zoom, accuracy: 0.001)
        XCTAssertEqual(logicalCentre(canvas).x, centre.x, accuracy: 0.5)
        XCTAssertEqual(logicalCentre(canvas).y, centre.y, accuracy: 0.5)

        actions.place(.docked(.rightEdge))
        try await NotebookTestFixtures.waitUntil { abs(canvas.bounds.height - (hostHeight)) < 0.5 }
        XCTAssertEqual(logicalCentre(canvas).y, centre.y, accuracy: 0.5)
        XCTAssertEqual(canvas.zoomScale, zoom, accuracy: 0.001)
        XCTAssertTrue(store.isToolbarAvailable)
        XCTAssertTrue(canvas.isFirstResponder)
    }

    func testToolbarConsumesItsTouchesAndLeavesTheRestToTheCanvas() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost()
        defer { fixture.close() }
        let canvas = fixture.controller.canvasView
        let host = fixture.hosting.view!
        NotebookToolbarActions(store: fixture.store).place(.floating(CGPoint(x: 0.5, y: 0.5)))
        try await NotebookTestFixtures.waitUntil { abs(canvas.bounds.height - host.bounds.height) < 0.5 }
        host.layoutIfNeeded()

        let toolbar = NotebookToolbarComposition(preferences: fixture.store.toolbar, horizontalSizeClass: .regular)
            .frame(in: host.bounds)
        // The shell padding above the first row has no control, so only the toolbar's own shape claims it.
        let shellEdge = CGPoint(x: toolbar.midX, y: toolbar.minY + 2)
        let firstRow = CGPoint(x: toolbar.midX, y: toolbar.minY + NotebookTheme.rowHeight / 2)
        let secondRow = CGPoint(x: toolbar.midX, y: toolbar.maxY - NotebookTheme.rowHeight / 2)
        let beside = CGPoint(x: toolbar.midX, y: toolbar.maxY + 40)

        for point in [firstRow, shellEdge] {
            XCTAssertFalse(fixture.hit(point).isDescendant(of: fixture.controller.view), "\(point)")
        }
        XCTAssertTrue(fixture.hit(secondRow).isDescendant(of: canvas), "The closed second row's room leaves its touches to the canvas.")
        XCTAssertTrue(fixture.hit(beside).isDescendant(of: canvas), "Touches beside the toolbar reach the canvas.")

        fixture.controller.setInputGate(.failed)
        XCTAssertFalse(fixture.store.isToolbarAvailable)
        host.layoutIfNeeded()
        XCTAssertFalse(
            fixture.hit(shellEdge).isDescendant(of: fixture.controller.view),
            "A disabled toolbar still keeps its touches from the canvas."
        )
    }

    func testStripsAndGripClaimTheirOwnTouches() async throws {
        let store = NotebookTestFixtures.toolStore()
        store.setInkRowOpen(true)
        let fixture = try await NotebookTestFixtures.mountToolbarHost(store: store)
        defer { fixture.close() }
        let host = fixture.hosting.view!
        let strips = fixture.strips
        XCTAssertEqual(strips.count, 2)
        let ink = try XCTUnwrap(strips.last)

        for scrolled in [false, true] {
            if scrolled {
                ink.setContentOffset(CGPoint(x: ink.contentSize.width - ink.bounds.width, y: 0), animated: false)
                host.layoutIfNeeded()
            }
            for strip in strips {
                let frame = fixture.frame(of: strip)
                for x in [frame.minX + frame.width / 4, frame.midX, frame.maxX - frame.width / 4] {
                    let target = fixture.hit(CGPoint(x: x, y: frame.midY))
                    XCTAssertFalse(target.isDescendant(of: fixture.controller.view), "\(x)")
                    XCTAssertTrue(target.isDescendant(of: strip), "A touch inside a strip goes to that strip's scrolling.")
                }
            }
        }

        let toolbar = NotebookToolbarComposition(preferences: fixture.store.toolbar, horizontalSizeClass: .regular)
            .frame(in: host.bounds)
        for isOpen in [true, false] {
            store.setInkRowOpen(isOpen)
            try await Task.sleep(for: .seconds(NotebookTheme.inkRowDuration + 0.15))
            host.layoutIfNeeded()
            let height = isOpen ? toolbar.height : NotebookTheme.rowHeight
            let grip = CGPoint(x: toolbar.minX + NotebookToolbarComposition.gripColumnWidth / 2, y: toolbar.minY + height / 2)
            let target = fixture.hit(grip)
            XCTAssertFalse(target.isDescendant(of: fixture.controller.view), "The grip never passes touches to the canvas.")
            XCTAssertFalse(strips.contains { target.isDescendant(of: $0) }, "Dragging the grip never scrolls a strip.")
        }
    }

    func testSceneToolbarAndCanvasShareTheSceneStore() async throws {
        let scene = try NotebookTestFixtures.windowScene()
        NotebookTestFixtures.restoreSceneToolDefaults(for: scene, after: self)
        let sceneStore = NotebookSceneToolStore.owner(for: scene)
        let originalTool = sceneStore.tool
        let originalToolbar = sceneStore.toolbar

        let id = UUID()
        let root = NotebookTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = try NotebookStorageProbe(stored: try await NotebookTestFixtures.stored(id: id), recoveryRoot: root)
        let storage = await probe.storage(notebookID: id)
        let session = NotebookSession(notebookID: id, openStorage: { storage })
        await session.load()
        XCTAssertEqual(session.loadState, .ready)

        let hosting = AppearanceTrackingHostingController(rootView: NotebookScreen(session: session))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1_024, height: 1_366)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        var mounted: NotebookViewController?
        defer {
            sceneStore.update { $0 = originalTool }
            sceneStore.updateToolbar(originalToolbar)
            mounted?.tearDown()
            window.isHidden = true
            window.rootViewController = nil
        }
        try await NotebookTestFixtures.waitUntilAppeared(hosting)
        try await NotebookTestFixtures.waitUntil {
            mounted = NotebookTestFixtures.notebookController(in: hosting)
            guard let controller = mounted else { return false }
            return controller.drawingToolStore === sceneStore && sceneStore.isToolbarAvailable
                && controller.canvasView.bounds.height > 0
        }
        let controller = try XCTUnwrap(mounted)
        let canvas = controller.canvasView
        let actions = NotebookToolbarActions(store: sceneStore)

        actions.place(.docked(.topCenter))
        try await settled { canvas.bounds.height }
        let dockedHeight = canvas.bounds.height
        actions.place(.floating(CGPoint(x: 0.5, y: 0.4)))
        try await NotebookTestFixtures.waitUntil { abs(canvas.bounds.height - dockedHeight) < 0.5 }

        actions.select(.lasso)
        XCTAssertTrue(canvas.tool is PKLassoTool, "The scene toolbar drives the scene's canvas.")
        actions.select(.ink(.marker))
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, .marker)
    }

    // MARK: - Eraser key

    /// A tap selects the eraser in the mode used last and a second tap keeps it; a touch and hold
    /// offers both modes with the one in use checked. The key reads as before to assistive
    /// technology, and a paused toolbar's key takes no tap.
    func testTheEraserKeyTapsToItsLastModeAndHoldsForTheModeMenu() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost()
        defer { fixture.close() }
        let store = fixture.store
        let canvas = fixture.controller.canvasView
        let actions = NotebookToolbarActions(store: store)
        let key = try eraserKey(in: fixture.host)
        XCTAssertFalse(key.showsMenuAsPrimaryAction, "A tap selects; only a touch and hold opens the menu.")
        XCTAssertTrue(key.isEnabled)
        XCTAssertEqual(key.accessibilityLabel, "Eraser")
        XCTAssertEqual(key.accessibilityHint, "Touch and hold to choose object or pixel erasing.")
        XCTAssertNil(key.accessibilityValue)
        XCTAssertTrue(key.isAccessibilityElement)
        XCTAssertEqual(key.accessibilityTraits, .button)
        XCTAssertEqual(key.interactions.compactMap { ($0 as? UIToolTipInteraction)?.defaultToolTip }, ["Eraser"])
        XCTAssertTrue(key.showsLargeContentViewer)
        XCTAssertEqual(key.largeContentTitle, "Eraser")
        XCTAssertTrue(key.interactions.contains { $0 is UILargeContentViewerInteraction })
        XCTAssertEqual(try checkedModes(of: key), ["Object eraser": false, "Pixel eraser": false])

        actions.select(.eraser(.bitmap))
        actions.select(.ink(.pen))
        key.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(store.tool.kind, .eraser(.bitmap), "A tap returns to the eraser mode used last.")
        XCTAssertEqual((canvas.tool as? PKEraserTool)?.eraserType, .bitmap)
        key.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(store.tool.kind, .eraser(.bitmap), "A second tap keeps the eraser.")
        try await NotebookTestFixtures.waitUntil { key.accessibilityValue == "Pixel" }
        XCTAssertEqual(key.accessibilityTraits, [.button, .selected])
        XCTAssertEqual(try checkedModes(of: key), ["Object eraser": false, "Pixel eraser": true])

        try modeAction("Object eraser", of: key).performWithSender(nil, target: nil)
        XCTAssertEqual(store.tool.kind, .eraser(.vector))
        XCTAssertEqual((canvas.tool as? PKEraserTool)?.eraserType, .vector)
        try await NotebookTestFixtures.waitUntil { key.accessibilityValue == "Object" }
        XCTAssertEqual(try checkedModes(of: key), ["Object eraser": true, "Pixel eraser": false])

        actions.select(.ink(.pen))
        fixture.controller.setInputGate(.failed)
        try await NotebookTestFixtures.waitUntil { !key.isEnabled }
        XCTAssertEqual(key.accessibilityTraits, [.button, .notEnabled])
        XCTAssertTrue(key.isAccessibilityElement, "A paused rail stays in sight, dimmed.")
        let centre = fixture.host.convert(CGPoint(x: key.bounds.midX, y: key.bounds.midY), from: key)
        XCTAssertFalse(fixture.hit(centre).isDescendant(of: fixture.controller.view), "Its touches stay off the page.")
        key.sendActions(for: .primaryActionTriggered)
        try modeAction("Pixel eraser", of: key).performWithSender(nil, target: nil)
        XCTAssertEqual(store.tool.kind, .ink(.pen), "A paused toolbar's eraser changes nothing.")
        fixture.controller.setInputGate(.open)
        try await NotebookTestFixtures.waitUntil { key.isEnabled }

        // A hidden rail's key gives up its touches, keyboard focus and place among assistive
        // technology's elements itself, as SwiftUI's hit testing does not reach inside a UIKit view.
        store.setToolsHidden(true)
        try await NotebookTestFixtures.waitUntil { !key.isUserInteractionEnabled }
        XCTAssertFalse(key.isAccessibilityElement)
        XCTAssertFalse(key.canBecomeFocused)
        XCTAssertFalse(fixture.hit(centre).isDescendant(of: key))
        store.setToolsHidden(false)
        try await NotebookTestFixtures.waitUntil { key.isUserInteractionEnabled && fixture.hit(centre) === key }
        XCTAssertTrue(key.isAccessibilityElement)
    }

    /// While the eraser's mode menu is open, neither a brief reveal running out, the keyboard
    /// shortcut nor a stroke ending hides the tools behind it; what they asked for takes effect
    /// once it ends. The menu opening again before its end is reported keeps the tools in sight.
    func testTheEraserMenuKeepsTheToolsInSightWhileOpen() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost()
        defer { fixture.close() }
        let clock = NotebookTestClock()
        let rig = try await NotebookChromeRig(store: fixture.store, delay: { await clock.wait($0) })
        do {
            let key = try eraserKey(in: fixture.host)
            rig.chrome.toolBegan()
            rig.chrome.toolEnded()
            XCTAssertTrue(rig.store.areToolsHidden)
            // An Apple Pencil tool switch shows the tools briefly; the menu opens before that runs out.
            rig.chrome.reveal(.transient)
            XCTAssertFalse(rig.store.areToolsHidden)
            let expiry = try await NotebookTestFixtures.waitForValue {
                await clock.requests(for: EditorChromeState.transientRevealDuration).first
            }

            try openMenu(of: key)
            XCTAssertTrue(key.isMenuPresented)
            XCTAssertTrue(rig.chrome.isPresenting, "The menu holds the tools from the moment it opens.")
            XCTAssertTrue(rig.chrome.state.pins.contains(.presentation))
            await clock.release(expiry)
            await NotebookTestFixtures.drainMainQueue()
            XCTAssertFalse(rig.store.areToolsHidden, "The brief reveal never runs out under the menu.")
            rig.chrome.reveal(.sticky)
            rig.chrome.toggle()
            XCTAssertFalse(rig.store.areToolsHidden, "The keyboard shortcut never hides the tools under the menu.")
            rig.chrome.toolBegan()
            rig.chrome.toolEnded()
            XCTAssertFalse(rig.store.areToolsHidden, "Nor does a stroke ending.")

            try closeMenu(of: key)
            try openMenu(of: key)
            await NotebookTestFixtures.drainMainQueue()
            XCTAssertTrue(rig.chrome.isPresenting, "An end reported late never clears a menu opened again.")
            try closeMenu(of: key)
            XCTAssertFalse(key.isMenuPresented)
            try await NotebookTestFixtures.waitUntil { !rig.chrome.isPresenting }
            XCTAssertTrue(rig.store.areToolsHidden, "The hide takes effect once the menu ends.")
            await clock.releaseAll()
        } catch {
            await clock.releaseAll()
            throw error
        }
    }

    /// A key removed with its menu open, as when the toolbar leaves the screen, stops holding the
    /// tools in sight.
    func testAnEraserKeyRemovedWithItsMenuOpenStopsHoldingTheTools() async throws {
        let (store, owner) = availableStore()
        defer { store.detach(owner) }
        let rig = try await NotebookChromeRig(store: store)
        let presence = ToolbarPresence()
        let hosting = AppearanceTrackingHostingController(rootView: RemovableToolbar(presence: presence, store: store))
        let window = try NotebookTestFixtures.window(showing: hosting, width: 1_024)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await NotebookTestFixtures.waitUntilAppeared(hosting)
        let key = try eraserKey(in: hosting.view)
        try openMenu(of: key)
        XCTAssertTrue(rig.chrome.isPresenting)
        presence.showsToolbar = false
        try await NotebookTestFixtures.waitUntil { key.window == nil }
        try await NotebookTestFixtures.waitUntil { !rig.chrome.isPresenting }
    }

    /// The button's press reaches the key beneath, which sinks as every key does; nothing else in
    /// the rail changes, and the key comes back up once released.
    func testPressingTheEraserSinksItsKeyAlone() async throws {
        let (store, owner) = availableStore()
        defer { store.detach(owner) }
        let shown = try await showRail(store: store, sizeClass: .regular, width: 1_024)
        defer { shown.close() }
        let key = try eraserKey(in: shown.hosting.view)
        let frame = key.convert(key.bounds, to: shown.hosting.view)
        let rest = try await shown.settledRender()
        key.isHighlighted = true
        try await NotebookTestFixtures.waitUntil {
            (try? shown.render()).map { !self.differingPoints(rest, $0).isEmpty } ?? false
        }
        // The glass passes through a frame or two of its own as the shading appears.
        let pressed = try await shown.settledRender()
        XCTAssertFalse(differingPoints(rest, pressed).isEmpty)
        // Beside the key the glass and a selected key's frosted lens may shift faintly with the
        // shading; another key sinking would shade its well and drop its label, far more than that.
        let sunk = differingPoints(rest, pressed, beyond: Self.glassShiftTolerance)
        XCTAssertTrue(sunk.allSatisfy { frame.insetBy(dx: -0.5, dy: -0.5).contains($0) }, "Only the eraser key sinks.")
        key.isHighlighted = false
        try await NotebookTestFixtures.waitUntil { (try? shown.render()).map { self.differingPoints(rest, $0).isEmpty } ?? false }
    }

    // MARK: - Fixtures

    /// A strip's scroll state at `offset`, as the strip reports it: its content padded with the
    /// trailing room.
    private func stripOverflow(of row: NotebookStripRow, at offset: CGFloat, in width: CGFloat) -> NotebookStripOverflow {
        NotebookStripOverflow(
            offset: offset, contentWidth: row.contentWidth + row.trailingRoom(containerWidth: width), containerWidth: width
        )
    }

    private func rendered(_ window: UIWindow) throws -> RenderedPixels {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return try RenderedPixels(try XCTUnwrap(image.cgImage), scale: image.scale)
    }

    /// Waits until a measurement stops changing between two layout passes.
    private func settled(_ measure: @escaping @MainActor () -> CGFloat) async throws {
        var previous = measure()
        try await NotebookTestFixtures.waitUntil {
            let current = measure()
            defer { previous = current }
            return current > 0 && abs(current - previous) < 0.5
        }
        try await Task.sleep(for: .milliseconds(100))
    }

    private func toolbar(customColors: Int) -> EditorToolbarPreferences {
        var preferences = EditorToolbarPreferences.standard
        for index in 0..<customColors {
            preferences.addCustomSwatch(EditorInkColor(red: 0.1, green: Double(index) / 10, blue: 0.6))
        }
        XCTAssertEqual(preferences.customSwatches.count, customColors)
        return preferences
    }

    private func rail(
        for preferences: EditorToolbarPreferences, hostWidth: CGFloat, textSize: DynamicTypeSize = .large
    ) -> NotebookToolbarRail {
        NotebookToolbarComposition(preferences: preferences, horizontalSizeClass: .regular, dynamicTypeSize: textSize)
            .rail(forHostWidth: hostWidth)
    }

    /// The ink strip's width in a rail: the row less its fixed cap and, when it scrolls, the chevron.
    private func inkStripWidth(_ rail: NotebookToolbarRail) -> CGFloat {
        rail.size.width - NotebookTheme.controlSize - NotebookToolbarComposition.inkCapWidth
            - (rail.inkRowOverflows ? NotebookTheme.controlSize : 0)
    }

    private func eraserKey(in view: UIView) throws -> NotebookEraserMenuButton {
        func find(_ view: UIView) -> NotebookEraserMenuButton? {
            (view as? NotebookEraserMenuButton) ?? view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(find(view), "The tool strip holds the eraser key.")
    }

    /// Each eraser mode the key's menu offers, and whether it is checked as the one in use.
    private func checkedModes(of key: NotebookEraserMenuButton) throws -> [String: Bool] {
        let actions = try XCTUnwrap(key.menu?.children as? [UIAction])
        return Dictionary(uniqueKeysWithValues: actions.map { ($0.title, $0.image != nil) })
    }

    /// The menu's entry for an eraser mode, as UIKit performs it when chosen.
    private func modeAction(_ title: String, of key: NotebookEraserMenuButton) throws -> any UIMenuLeaf {
        try XCTUnwrap((key.menu?.children as? [UIAction])?.first { $0.title == title })
    }

    /// What UIKit tells the key as a touch and hold opens its menu, with the configuration the key
    /// itself provides, and as the menu ends.
    private func openMenu(of key: NotebookEraserMenuButton) throws {
        let (interaction, configuration) = try menuConfiguration(of: key)
        key.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: nil)
    }

    private func closeMenu(of key: NotebookEraserMenuButton) throws {
        let (interaction, configuration) = try menuConfiguration(of: key)
        key.contextMenuInteraction(interaction, willEndFor: configuration, animator: nil)
    }

    private func menuConfiguration(
        of key: NotebookEraserMenuButton
    ) throws -> (UIContextMenuInteraction, UIContextMenuConfiguration) {
        let interaction = try XCTUnwrap(key.contextMenuInteraction, "The key's menu opens through UIKit's own interaction.")
        let centre = CGPoint(x: key.bounds.midX, y: key.bounds.midY)
        let configuration = try XCTUnwrap(key.contextMenuInteraction(interaction, configurationForMenuAtLocation: centre))
        return (interaction, configuration)
    }

    /// The rail alone in a window as wide as `width`, optionally at the moment the writing view
    /// begins to hide it, or disabled for some other reason.
    private func showRail(
        store: NotebookSceneToolStore, sizeClass: UserInterfaceSizeClass, width: CGFloat, hiding: Bool = false,
        disabled: Bool = false
    ) async throws -> ShownRail {
        let composition = NotebookToolbarComposition(preferences: store.toolbar, horizontalSizeClass: sizeClass)
        let rail = composition.rail(forHostWidth: width)
        let content = NotebookToolbar(store: store, composition: composition, rail: rail, collapse: {}) { Color.clear }
            .frame(width: rail.size.width, height: rail.size.height)
            .modifier(NotebookRailFade(hiddenAmount: 0, offset: CGSize(width: 0, height: -8), isHidden: hiding))
            .disabled(disabled)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
        let hosting = AppearanceTrackingHostingController(rootView: content)
        hosting.safeAreaRegions = []
        hosting.traitOverrides.horizontalSizeClass = sizeClass == .compact ? .compact : .regular
        let window = try NotebookTestFixtures.window(showing: hosting, width: width)
        window.frame = CGRect(x: 0, y: 0, width: width, height: rail.size.height + 40)
        let shown = ShownRail(hosting: hosting, window: window, composition: composition, rail: rail)
        do {
            try await NotebookTestFixtures.waitUntilAppeared(hosting)
            // The strips measure themselves once laid out, which shows their chevrons.
            try await Task.sleep(for: .milliseconds(400))
        } catch {
            shown.close()
            throw error
        }
        return shown
    }

    /// Renders `content` at twice its point size into a cleared bitmap of its own. ImageRenderer's
    /// own image of a view that draws nothing can hold the last render of the same size.
    private func renderedAlone<Content: View>(_ content: Content) throws -> RenderedPixels {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var image: CGImage?
        ImageRenderer(content: content).render(rasterizationScale: 2) { size, render in
            let width = Int((size.width * 2).rounded(.up))
            let height = Int((size.height * 2).rounded(.up))
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: 2, y: 2)
            render(context)
            image = context.makeImage()
        }
        return try RenderedPixels(try XCTUnwrap(image), scale: 2)
    }

    /// Levels by which the rail's glass may shift beside a key whose shading changes: about half
    /// the change a pressed well's shading makes.
    private static let glassShiftTolerance = 16

    /// Points, in points, where two renders of the same size differ by more than `tolerance` levels;
    /// by default more than the few levels the rail's glass dithers by from one frame to the next.
    private func differingPoints(_ first: RenderedPixels, _ second: RenderedPixels, beyond tolerance: Int = 8) -> [CGPoint] {
        guard first.rgba.count == second.rgba.count else { return [CGPoint(x: -1, y: -1)] }
        return stride(from: 0, to: first.rgba.count, by: 4).compactMap { index in
            let differs = (index..<index + 4).contains { abs(Int(first.rgba[$0]) - Int(second.rgba[$0])) > tolerance }
            guard differs else { return nil }
            let pixel = index / 4
            return CGPoint(x: CGFloat(pixel % first.width) / first.scale, y: CGFloat(pixel / first.width) / first.scale)
        }
    }

    /// A store that admits toolbar actions without mounting a canvas.
    private func availableStore() -> (NotebookSceneToolStore, NotebookViewController) {
        let store = NotebookTestFixtures.toolStore()
        let owner = NotebookViewController(pageCount: 1, initialDrawing: PKDrawing())
        store.attach(owner)
        store.setToolbarAvailable(true, for: owner)
        XCTAssertTrue(store.isToolbarAvailable)
        return (store, owner)
    }

    private func storeWithToolbarData(_ data: Data) -> NotebookSceneToolStore {
        let suite = NotebookTestFixtures.temporaryDefaultsSuite()
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(data, forKey: NotebookSceneToolStore.toolbarDefaultsKey)
        return NotebookSceneToolStore(identifier: suite, defaults: defaults)
    }

    private func assertActionsChangeNothing(
        _ actions: NotebookToolbarActions, store: NotebookSceneToolStore,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let tool = store.tool
        let toolbar = store.toolbar
        actions.select(.ink(.marker))
        actions.select(.eraser(.bitmap))
        actions.selectEraser()
        actions.select(.lasso)
        actions.toggleRuler()
        actions.apply(EditorInkCatalog.presets[0])
        actions.selectColor(EditorInkCatalog.swatches[3])
        actions.selectWidth(.bold)
        actions.addCustomColor(EditorInkColor(red: 0.9, green: 0.1, blue: 0.1))
        actions.place(.floating(CGPoint(x: 0.2, y: 0.8)))
        actions.setCollapsed(true)
        actions.revealIfCollapsed()
        XCTAssertEqual(store.tool, tool, file: file, line: line)
        XCTAssertEqual(store.toolbar, toolbar, file: file, line: line)
    }

    private func assertPresentedAsAvailable(
        _ actions: NotebookToolbarActions, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actions.contentOpacity(), 1, file: file, line: line)
        XCTAssertEqual(actions.contentOpacity(for: .increased), 1, file: file, line: line)
        XCTAssertEqual(actions.dragGestureMask, .all, file: file, line: line)
    }

    private func assertPresentedAsUnavailable(
        _ actions: NotebookToolbarActions, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertLessThan(actions.contentOpacity(), 1, "An unavailable toolbar is visibly dimmed.", file: file, line: line)
        XCTAssertEqual(actions.contentOpacity(), NotebookTheme.disabledOpacity, file: file, line: line)
        XCTAssertEqual(actions.contentOpacity(for: .increased), NotebookTheme.disabledOpacityIncreased,
            "Increase Contrast dims less, so paused tools stay legible.", file: file, line: line)
        XCTAssertEqual(actions.dragGestureMask, .none, "An unavailable toolbar cannot be dragged.", file: file, line: line)
    }

    private func countToolbarEmissions(of store: NotebookSceneToolStore) -> EmissionCounter {
        let counter = EmissionCounter()
        counter.subscription = store.$toolbar.dropFirst().sink { _ in
            MainActor.assumeIsolated { counter.count += 1 }
        }
        return counter
    }

    private func logicalCentre(_ canvas: PKCanvasView) -> CGPoint {
        CGPoint(
            x: (canvas.contentOffset.x + canvas.bounds.width / 2) / canvas.zoomScale,
            y: (canvas.contentOffset.y + canvas.bounds.height / 2) / canvas.zoomScale
        )
    }
}

@MainActor
private final class EmissionCounter {
    var count = 0
    var subscription: AnyCancellable?
}

/// The rail shown alone in its own window.
@MainActor
private struct ShownRail {
    let hosting: UIViewController
    let window: UIWindow
    let composition: NotebookToolbarComposition
    let rail: NotebookToolbarRail

    /// The render once two taken a moment apart agree, so no transition still under way is caught.
    func settledRender() async throws -> RenderedPixels {
        var previous = try render()
        return try await NotebookTestFixtures.waitForValue {
            try? await Task.sleep(for: .milliseconds(100))
            guard let current = try? render() else { return nil }
            defer { previous = current }
            return current.looksLike(previous) ? current : nil
        }
    }

    /// The window's content as drawn on screen, UIKit views included, at twice its point size.
    func render() throws -> RenderedPixels {
        let view = try XCTUnwrap(hosting.view)
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        return try RenderedPixels(try XCTUnwrap(image.cgImage), scale: 2)
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
    }
}

@MainActor
private final class ToolbarPresence: ObservableObject {
    @Published var showsToolbar = true
}

/// The rail, until the test takes it away.
private struct RemovableToolbar: View {
    @ObservedObject var presence: ToolbarPresence
    let store: NotebookSceneToolStore

    var body: some View {
        let composition = NotebookToolbarComposition(preferences: store.toolbar, horizontalSizeClass: .regular)
        let rail = composition.rail(forHostWidth: 1_024)
        ZStack(alignment: .topLeading) {
            Color.clear
            if presence.showsToolbar {
                NotebookToolbar(store: store, composition: composition, rail: rail, collapse: {}) { Color.clear }
                    .frame(width: rail.size.width, height: rail.size.height)
            }
        }
        .ignoresSafeArea()
    }
}

/// Records the enabled state the toolbar passes down to the controls it contains.
@MainActor
private final class EnabledProbe {
    var isEnabled: Bool?
}

private struct EnabledProbeView: View {
    let probe: EnabledProbe
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Color.clear
            .frame(width: 44, height: 44)
            .onChange(of: isEnabled, initial: true) { _, enabled in probe.isEnabled = enabled }
    }
}
