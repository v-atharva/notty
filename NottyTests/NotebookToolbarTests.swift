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
                    .modifier(NotebookRailFade(hiddenAmount: hiddenAmount, offset: -8, isHidden: isHidden))
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
            try RenderedPixels(rendering: keys.modifier(NotebookRailFade(hiddenAmount: 0, offset: -8, isHidden: isHidden)))
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
                .modifier(NotebookRailFade(hiddenAmount: 0, offset: -8, isHidden: isHidden)))
        }
        XCTAssertTrue(try paused(isHidden: true).rgba == paused(isHidden: false).rgba)
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

        let dock = EditorToolbarLayout.frame(for: .docked(.topLeading), size: size, in: usable)
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
        XCTAssertEqual(session.targetedDock, .topLeading)

        let placement = session.end(at: release, actions: actions)
        XCTAssertEqual(placement, .docked(.topLeading))
        XCTAssertEqual(store.toolbar.placement, .docked(.topLeading))
        XCTAssertFalse(session.isActive)
        XCTAssertNil(session.end(at: release, actions: actions))
        XCTAssertEqual(emissions.count, 1)
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

        let towardsLeading = CGSize(width: -180, height: 0)
        let recomputed = NotebookToolbarDragResolver(placement: .docked(.topTrailing), size: size, usable: usable)
        XCTAssertEqual(recomputed.placement(translation: towardsLeading), .docked(.topCenter))
        session.move(to: towardsLeading, resolver: resolver, actions: actions)
        let docked = session.end(at: towardsLeading, resolver: recomputed, actions: actions)
        XCTAssertEqual(docked, .docked(.topLeading), "The resolver fixed at the start of the drag decides.")
        XCTAssertEqual(emissions.count, 2)

        store.detach(owner)
        XCTAssertNil(session.end(at: translation, resolver: resolver, actions: actions))
        XCTAssertEqual(emissions.count, 2, "An unavailable toolbar never persists a drag.")
    }

    // MARK: - Collapse and reveal

    func testFloatingRailHoldsItsCollapseKeyInTheGripColumn() {
        let floating = EditorToolbarPreferences(
            placement: .floating(CGPoint(x: 0.5, y: 0.5)), isCollapsed: false, customSwatches: []
        )
        for width in [834.0, 1_024, 1_366] as [CGFloat] {
            let docked = NotebookToolbarComposition(preferences: .standard, horizontalSizeClass: .regular)
            let composition = NotebookToolbarComposition(preferences: floating, horizontalSizeClass: .regular)
            XCTAssertTrue(composition.showsCollapseControl)
            XCTAssertEqual(composition.toolCapWidth, docked.toolCapWidth, "The key sits under the grip, not after the rows.")
            XCTAssertEqual(composition.rail(forHostWidth: width), docked.rail(forHostWidth: width), "\(width)")
        }
        XCTAssertEqual(NotebookToolbarComposition.gripColumnWidth, NotebookTheme.controlSize)
        let compact = NotebookToolbarComposition(preferences: floating, horizontalSizeClass: .compact)
        let compactDocked = NotebookToolbarComposition(preferences: .standard, horizontalSizeClass: .compact)
        XCTAssertTrue(compact.showsCollapseControl)
        XCTAssertEqual(
            compact.toolCapWidth, compactDocked.toolCapWidth + NotebookTheme.itemSpacing + NotebookTheme.controlSize,
            "The single compact row keeps its collapse key after the current-ink chip."
        )
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
        XCTAssertEqual(store.toolbar.placement, .docked(.topTrailing))
        XCTAssertFalse(store.toolbar.isCollapsed)
        let composition = NotebookToolbarComposition(preferences: store.toolbar, horizontalSizeClass: .regular)
        XCTAssertFalse(composition.showsRevealHandle)
        XCTAssertFalse(composition.showsCollapseControl, "Docked toolbars never offer to collapse.")

        let (available, owner) = availableStore()
        defer { available.detach(owner) }
        let actions = NotebookToolbarActions(store: available)
        actions.place(.docked(.topLeading))
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

        XCTAssertTrue(actions.place(.docked(.topTrailing)))
        store.setToolsHidden(true)
        actions.showTools()
        XCTAssertFalse(store.areToolsHidden, "The reveal tab asks for the tools back.")
        XCTAssertEqual(store.toolbar.placement, .docked(.topTrailing))

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
        store.handlePencil(.showInkAttributes, from: fixture.controller)
        XCTAssertEqual(store.revealRequest, 1)
        try await NotebookTestFixtures.waitUntil { !store.toolbar.isCollapsed }
        XCTAssertEqual(store.toolbar.placement, collapsed.placement)
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
        fixture.store.handlePencil(.showColorPalette, from: fixture.controller)
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

        let handle = EditorToolbarLayout.frame(
            for: collapsed.placement, size: NotebookTheme.collapsedHandleSize, in: host.bounds
        )
        let expanded = EditorToolbarLayout.frame(
            for: collapsed.placement,
            size: NotebookToolbarComposition(preferences: .standard, horizontalSizeClass: .regular)
                .toolbarSize(forHostWidth: host.bounds.width),
            in: host.bounds
        )
        let besideHandle = CGPoint(x: expanded.minX + 20, y: expanded.minY + 4)
        XCTAssertFalse(handle.contains(besideHandle))
        XCTAssertFalse(fixture.hit(CGPoint(x: handle.midX, y: handle.midY)).isDescendant(of: fixture.controller.view))
        XCTAssertTrue(
            fixture.hit(besideHandle).isDescendant(of: canvas),
            "A collapsed toolbar leaves the rest of its expanded frame to the canvas."
        )
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

    // MARK: - Custom colour picker

    func testColourPickerAddsOnlyTheColourShowingWhenItCloses() throws {
        let (store, owner) = availableStore()
        defer { store.detach(owner) }
        let actions = NotebookToolbarActions(store: store)
        let emissions = countToolbarEmissions(of: store)
        let tool = store.tool
        let pick = NotebookColorPick()
        var closeRequests = 0
        let coordinator = NotebookColorPicker.Coordinator(pick: pick) { closeRequests += 1 }
        let picker = UIColorPickerViewController()

        let passedThrough = (1...6).map { UIColor(red: CGFloat($0) / 10, green: 0.3, blue: 0.5, alpha: 1) }
        for (index, color) in passedThrough.enumerated() {
            coordinator.colorPickerViewController(picker, didSelect: color, continuously: index < passedThrough.count - 1)
        }
        XCTAssertEqual(emissions.count, 0, "Colours passed on the way are never stored.")
        XCTAssertEqual(store.tool, tool, "Colours passed on the way never change the ink.")

        coordinator.colorPickerViewControllerDidFinish(picker)
        XCTAssertEqual(closeRequests, 1)
        XCTAssertEqual(emissions.count, 0, "Finishing only closes the picker; the well keeps the colour once it has closed.")

        pick.finish(with: actions)
        let kept = NotebookSwatchShelf.color(from: try XCTUnwrap(passedThrough.last))
        XCTAssertEqual(store.toolbar.customSwatches, [kept])
        XCTAssertEqual(store.tool.color, kept)
        XCTAssertEqual(emissions.count, 1)

        pick.finish(with: actions)
        XCTAssertEqual(emissions.count, 1, "A closed picker keeps its colour once.")

        coordinator.colorPickerViewController(picker, didSelect: .systemTeal, continuously: false)
        store.setToolbarAvailable(false, for: owner)
        pick.finish(with: actions)
        store.setToolbarAvailable(true, for: owner)
        pick.finish(with: actions)
        XCTAssertEqual(store.toolbar.customSwatches, [kept], "A picker closed while writing is paused changes nothing.")
        XCTAssertEqual(emissions.count, 1)
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
            try RenderedPixels(
                rendering: NotebookKeyStyle.Background(
                    shape: .well, isSelected: selected, isPressed: pressed, isFocused: focused
                )
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
    func testRailWidthFollowsTheDockAndPlannedToolRules() {
        struct Case {
            let width: CGFloat
            let customColors: Int
            var textSize = DynamicTypeSize.large
            let rail: CGFloat
            let docksShared: Bool
            let showsUpcoming: Bool
        }
        let cases = [
            Case(width: 834, customColors: 0, rail: 807, docksShared: true, showsUpcoming: false),
            Case(width: 834, customColors: 2, rail: 810, docksShared: true, showsUpcoming: false),
            Case(width: 834, customColors: 4, rail: 810, docksShared: true, showsUpcoming: false),
            Case(width: 834, customColors: 8, rail: 810, docksShared: true, showsUpcoming: false),
            Case(width: 1_194, customColors: 0, rail: 807, docksShared: false, showsUpcoming: false),
            Case(width: 1_194, customColors: 2, rail: 870, docksShared: false, showsUpcoming: false),
            Case(width: 1_194, customColors: 4, rail: 870, docksShared: false, showsUpcoming: false),
            Case(width: 1_194, customColors: 8, rail: 870, docksShared: false, showsUpcoming: false),
            Case(width: 1_024, customColors: 0, rail: 965, docksShared: true, showsUpcoming: true),
            Case(width: 1_024, customColors: 2, rail: 965, docksShared: true, showsUpcoming: true),
            Case(width: 1_024, customColors: 4, rail: 991, docksShared: true, showsUpcoming: true),
            Case(width: 1_024, customColors: 8, rail: 1_000, docksShared: true, showsUpcoming: true),
            Case(width: 1_366, customColors: 0, rail: 965, docksShared: false, showsUpcoming: true),
            Case(width: 1_366, customColors: 2, rail: 965, docksShared: false, showsUpcoming: true),
            Case(width: 1_366, customColors: 4, rail: 991, docksShared: false, showsUpcoming: true),
            Case(width: 1_366, customColors: 8, rail: 1_042, docksShared: false, showsUpcoming: true),
            Case(width: 678, customColors: 0, rail: 654, docksShared: true, showsUpcoming: false),
            Case(width: 678, customColors: 2, rail: 654, docksShared: true, showsUpcoming: false),
            Case(width: 678, customColors: 4, rail: 654, docksShared: true, showsUpcoming: false),
            Case(width: 678, customColors: 8, rail: 654, docksShared: true, showsUpcoming: false),

            Case(width: 834, customColors: 0, textSize: .xxLarge, rail: 810, docksShared: true, showsUpcoming: false),
            Case(width: 834, customColors: 2, textSize: .xxLarge, rail: 810, docksShared: true, showsUpcoming: false),
            Case(width: 834, customColors: 4, textSize: .xxLarge, rail: 810, docksShared: true, showsUpcoming: false),
            Case(width: 834, customColors: 8, textSize: .xxLarge, rail: 810, docksShared: true, showsUpcoming: false),
            Case(width: 1_194, customColors: 0, textSize: .xxLarge, rail: 854, docksShared: false, showsUpcoming: false),
            Case(width: 1_194, customColors: 2, textSize: .xxLarge, rail: 870, docksShared: false, showsUpcoming: false),
            Case(width: 1_194, customColors: 4, textSize: .xxLarge, rail: 870, docksShared: false, showsUpcoming: false),
            Case(width: 1_194, customColors: 8, textSize: .xxLarge, rail: 870, docksShared: false, showsUpcoming: false),
            Case(width: 1_024, customColors: 0, textSize: .xxLarge, rail: 965, docksShared: true, showsUpcoming: true),
            Case(width: 1_024, customColors: 2, textSize: .xxLarge, rail: 965, docksShared: true, showsUpcoming: true),
            Case(width: 1_024, customColors: 4, textSize: .xxLarge, rail: 1_000, docksShared: true, showsUpcoming: true),
            Case(width: 1_024, customColors: 8, textSize: .xxLarge, rail: 1_000, docksShared: true, showsUpcoming: true),
            Case(width: 1_366, customColors: 0, textSize: .xxLarge, rail: 965, docksShared: false, showsUpcoming: true),
            Case(width: 1_366, customColors: 2, textSize: .xxLarge, rail: 965, docksShared: false, showsUpcoming: true),
            Case(width: 1_366, customColors: 4, textSize: .xxLarge, rail: 1_038, docksShared: false, showsUpcoming: true),
            Case(width: 1_366, customColors: 8, textSize: .xxLarge, rail: 1_042, docksShared: false, showsUpcoming: true),
            Case(width: 678, customColors: 0, textSize: .xxLarge, rail: 654, docksShared: true, showsUpcoming: false),
            Case(width: 678, customColors: 2, textSize: .xxLarge, rail: 654, docksShared: true, showsUpcoming: false),
            Case(width: 678, customColors: 4, textSize: .xxLarge, rail: 654, docksShared: true, showsUpcoming: false),
            Case(width: 678, customColors: 8, textSize: .xxLarge, rail: 654, docksShared: true, showsUpcoming: false),
        ]
        for test in cases {
            let preferences = toolbar(customColors: test.customColors)
            let label = "\(test.width) with \(test.customColors) custom colours at \(test.textSize)"
            let rail = self.rail(for: preferences, hostWidth: test.width, textSize: test.textSize)
            XCTAssertEqual(rail.size.width, test.rail, accuracy: 0.001, label)
            XCTAssertEqual(rail.size.height, 2 * NotebookTheme.rowHeight + NotebookTheme.rowSpacing, label)
            XCTAssertEqual(rail.docksShared, test.docksShared, label)
            XCTAssertEqual(rail.showsUpcoming, test.showsUpcoming, label)
            XCTAssertEqual(rail.toolRow.slots.contains { $0.item.isPlaceholder }, test.showsUpcoming, label)
            XCTAssertEqual(
                rail.toolRow.slots.contains { $0.item == .upcomingLabel }, test.showsUpcoming,
                "\(label): the planned tools show as a whole group or not at all."
            )
            let available = test.width - 2 * EditorToolbarLayout.margin
            if test.docksShared {
                XCTAssertLessThanOrEqual(rail.size.width, available, label)
            } else {
                XCTAssertGreaterThanOrEqual((available - rail.size.width) / 2, NotebookToolbarComposition.minimumDockTravel, label)
            }
            var floating = preferences
            floating.place(.floating(CGPoint(x: 0.5, y: 0.5)))
            XCTAssertEqual(self.rail(for: floating, hostWidth: test.width, textSize: test.textSize).size, rail.size,
                "\(label): floating and docked rails share one width.")
        }
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
        XCTAssertTrue(rail.docksShared)
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

        actions.place(.docked(.topTrailing))
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
            .frame(for: fixture.store.toolbar.placement, in: host.bounds)
        // The shell padding above the first row has no control, so only the toolbar's own shape claims it.
        let shellEdge = CGPoint(x: toolbar.midX, y: toolbar.minY + 2)
        let beside = CGPoint(x: toolbar.midX, y: toolbar.maxY + 40)

        for point in [CGPoint(x: toolbar.midX, y: toolbar.midY), shellEdge] {
            XCTAssertFalse(fixture.hit(point).isDescendant(of: fixture.controller.view), "\(point)")
        }
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
        let fixture = try await NotebookTestFixtures.mountToolbarHost()
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
            .frame(for: fixture.store.toolbar.placement, in: host.bounds)
        let grip = CGPoint(x: toolbar.minX + NotebookToolbarComposition.gripColumnWidth / 2, y: toolbar.midY)
        let target = fixture.hit(grip)
        XCTAssertFalse(target.isDescendant(of: fixture.controller.view), "The grip never passes touches to the canvas.")
        XCTAssertFalse(strips.contains { target.isDescendant(of: $0) }, "Dragging the grip never scrolls a strip.")
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
