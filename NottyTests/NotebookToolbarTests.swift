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
        let hosting = UIHostingController(
            rootView: NotebookToolbar(store: store, composition: composition, collapse: {}) {
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

        try await NotebookTestFixtures.waitUntil { probe.isEnabled == true }
        store.setToolbarAvailable(false, for: owner)
        try await NotebookTestFixtures.waitUntil { probe.isEnabled == false }
        store.setToolbarAvailable(true, for: owner)
        try await NotebookTestFixtures.waitUntil { probe.isEnabled == true }
    }

    func testUnavailableInkPanelDrawsEveryControlDisabled() throws {
        let (store, owner) = availableStore()
        defer { store.detach(owner) }
        let panel = NotebookInkControls(store: store, layout: .panel)
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
            session.move(to: CGSize(width: release.width * fraction, height: release.height * fraction), resolver: resolver)
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
        session.move(to: translation, resolver: resolver)
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
        session.move(to: CGSize(width: 0, height: 300), resolver: resolver)
        session.cancel()
        XCTAssertFalse(session.isActive)
        XCTAssertNil(session.previewFrame)
        XCTAssertNil(session.end(at: CGSize(width: 0, height: 300), actions: actions))

        store.detach(owner)
        XCTAssertFalse(actions.isEnabled)
        session.move(to: CGSize(width: 0, height: 300), resolver: resolver)
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
        session.move(to: translation, resolver: resolver)

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
        session.move(to: towardsLeading, resolver: resolver)
        let docked = session.end(at: towardsLeading, resolver: recomputed, actions: actions)
        XCTAssertEqual(docked, .docked(.topLeading), "The resolver fixed at the start of the drag decides.")
        XCTAssertEqual(emissions.count, 2)

        store.detach(owner)
        XCTAssertNil(session.end(at: translation, resolver: resolver, actions: actions))
        XCTAssertEqual(emissions.count, 2, "An unavailable toolbar never persists a drag.")
    }

    // MARK: - Collapse and reveal

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
        XCTAssertEqual(composition.dockBandHeight, 0)
    }

    func testDockedRestoreIsNeverCollapsed() throws {
        let stored = #"{"version":1,"placement":{"dock":"topTrailing"},"collapsed":true,"swatches":[]}"#
        let store = storeWithToolbarData(Data(stored.utf8))
        XCTAssertEqual(store.toolbar.placement, .docked(.topTrailing))
        XCTAssertFalse(store.toolbar.isCollapsed)
        let composition = NotebookToolbarComposition(preferences: store.toolbar, horizontalSizeClass: .regular)
        XCTAssertFalse(composition.showsRevealHandle)
        XCTAssertFalse(composition.showsCollapseControl, "Docked toolbars never offer to collapse.")
        XCTAssertGreaterThan(composition.dockBandHeight, 0)

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

    func testPencilRevealBringsTheColoursIntoViewOnTheInkStrip() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost()
        defer { fixture.close() }
        let strips = fixture.strips
        XCTAssertEqual(strips.count, 2, "The regular toolbar shows the tool strip and the ink strip.")
        let ink = try XCTUnwrap(strips.last)
        XCTAssertGreaterThan(ink.contentSize.width, ink.bounds.width, "The ink strip scrolls at the default width.")
        XCTAssertEqual(ink.contentOffset.x, 0, accuracy: 0.5)

        fixture.store.handlePencil(.showColorPalette, from: fixture.controller)
        try await NotebookTestFixtures.waitUntil { ink.contentOffset.x > 1 }
        XCTAssertTrue(fixture.store.isToolbarAvailable)
        XCTAssertNil(fixture.hosting.presentedViewController, "A regular toolbar answers in place.")
    }

    /// SwiftUI frames are not readable from a hosted test, so the colour group's position, to
    /// which a Pencil reveal scrolls, measures what is laid out before it.
    func testInkRowShowsEveryWidthBeforeTheColoursAndAnyPaging() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost()
        defer { fixture.close() }
        let actions = NotebookToolbarActions(store: fixture.store)
        // A full shelf makes the colour group as long as it gets.
        for index in 0..<EditorToolbarPreferences.maximumCustomSwatches {
            actions.addCustomColor(EditorInkColor(red: 0.1, green: Double(index) / 10, blue: 0.6))
        }
        let ink = try XCTUnwrap(fixture.strips.last)
        try await NotebookTestFixtures.waitUntil { ink.contentSize.width > ink.bounds.width }
        XCTAssertEqual(ink.contentOffset.x, 0, accuracy: 0.5, "The ink row opens at its start.")

        fixture.store.handlePencil(.showColorPalette, from: fixture.controller)
        try await NotebookTestFixtures.waitUntil { ink.contentOffset.x > 1 }
        try await settled { ink.contentOffset.x }
        // Something comes before the colours, or the reveal would not have scrolled, and it is
        // short: the three widths, not the preset chips, so all of it shows at rest.
        XCTAssertLessThan(ink.contentOffset.x, ink.bounds.width / 2, "Only the widths come before the colours.")
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
        }
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
                rendering: NotebookControlBackground(
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
        XCTAssertEqual(regular.dockBandHeight, regular.expandedHeight + 2 * EditorToolbarLayout.margin)
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
        XCTAssertGreaterThan(start.nextTrailingOffset, 0)
        XCTAssertLessThanOrEqual(start.nextTrailingOffset, 500)

        let end = NotebookStripOverflow(offset: 500, contentWidth: 900, containerWidth: 400)
        XCTAssertTrue(end.hidesLeading)
        XCTAssertFalse(end.hidesTrailing)
        XCTAssertEqual(end.nextTrailingOffset, 500)
        XCTAssertLessThan(end.nextLeadingOffset, 500)
        XCTAssertGreaterThanOrEqual(end.nextLeadingOffset, 0)

        XCTAssertEqual(fits.hiddenEdges, .none)
        let scrolling = (100...400).map { NotebookStripOverflow(offset: CGFloat($0), contentWidth: 900, containerWidth: 400) }
        XCTAssertTrue(
            scrolling.allSatisfy { $0.hiddenEdges == scrolling[0].hiddenEdges },
            "Scrolling between the edges never changes what the strip draws."
        )
        XCTAssertEqual(scrolling[0].hiddenEdges, NotebookStripOverflow.HiddenEdges(leading: true, trailing: true))
        XCTAssertEqual(end.hiddenEdges, NotebookStripOverflow.HiddenEdges(leading: true, trailing: false))
    }

    // MARK: - Placement around the real canvas

    func testDockedBandShrinksTheCanvasAndFloatingRestoresItWithoutMovingThePage() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost()
        defer { fixture.close() }
        let store = fixture.store
        let canvas = fixture.controller.canvasView
        let actions = NotebookToolbarActions(store: store)
        let composition = NotebookToolbarComposition(preferences: store.toolbar, horizontalSizeClass: .regular)
        let hostHeight = fixture.hosting.view.bounds.height
        XCTAssertEqual(store.toolbar.placement, .docked(.topCenter))
        XCTAssertEqual(canvas.bounds.height, hostHeight - composition.dockBandHeight, accuracy: 0.5)
        XCTAssertEqual(fixture.canvasFrame.minY, composition.dockBandHeight, accuracy: 0.5)

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
        try await NotebookTestFixtures.waitUntil { abs(canvas.bounds.height - (hostHeight - composition.dockBandHeight)) < 0.5 }
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

        let composition = NotebookToolbarComposition(preferences: fixture.store.toolbar, horizontalSizeClass: .regular)
        let toolbar = EditorToolbarLayout.frame(
            for: fixture.store.toolbar.placement, size: composition.toolbarSize(forHostWidth: host.bounds.width),
            in: host.bounds
        )
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

        let composition = NotebookToolbarComposition(preferences: fixture.store.toolbar, horizontalSizeClass: .regular)
        let toolbar = EditorToolbarLayout.frame(
            for: fixture.store.toolbar.placement, size: composition.toolbarSize(forHostWidth: host.bounds.width),
            in: host.bounds
        )
        let grip = CGPoint(x: toolbar.minX + NotebookTheme.dragHandleHitSize.width / 2, y: toolbar.midY)
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

        let hosting = UIHostingController(rootView: NotebookScreen(session: session))
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
        let band = NotebookToolbarComposition(preferences: .standard, horizontalSizeClass: .regular).dockBandHeight
        try await NotebookTestFixtures.waitUntil { abs(canvas.bounds.height - (dockedHeight + band)) < 0.5 }

        actions.select(.lasso)
        XCTAssertTrue(canvas.tool is PKLassoTool, "The scene toolbar drives the scene's canvas.")
        actions.select(.ink(.marker))
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, .marker)
    }

    // MARK: - Fixtures

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
        XCTAssertEqual(actions.contentOpacity, 1, file: file, line: line)
        XCTAssertEqual(actions.dragGestureMask, .all, file: file, line: line)
    }

    private func assertPresentedAsUnavailable(
        _ actions: NotebookToolbarActions, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertLessThan(actions.contentOpacity, 1, "An unavailable toolbar is visibly dimmed.", file: file, line: line)
        XCTAssertEqual(actions.contentOpacity, NotebookTheme.disabledOpacity, file: file, line: line)
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
