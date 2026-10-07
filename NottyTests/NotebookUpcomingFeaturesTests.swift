import NottyCore
import PencilKit
import SwiftUI
import UIKit
import XCTest
@testable import Notty

@MainActor
final class NotebookUpcomingFeaturesTests: XCTestCase {
    // MARK: - Catalogue

    func testCatalogueListsEachPlannedFeatureOnceInItsPlacement() {
        let catalogue = NotebookUpcomingFeature.catalogue
        XCTAssertEqual(Set(catalogue.map(\.title)).count, catalogue.count, "Every feature appears once.")
        XCTAssertEqual(
            NotebookUpcomingFeature.placed(.toolStrip).map(\.title), ["Text", "Insert", "Record audio", "Bookmark"]
        )
        XCTAssertEqual(NotebookUpcomingFeature.placed(.navigationLeading).map(\.title), ["Notebooks"])
        XCTAssertEqual(
            NotebookUpcomingFeature.placed(.navigationTrailing).map(\.title), ["Search", "Summarize", "Export", "Backup"]
        )
        let placed = NotebookUpcomingFeature.Placement.allCases.flatMap(NotebookUpcomingFeature.placed)
        XCTAssertEqual(placed.count, catalogue.count, "Every feature has exactly one placement.")
    }

    func testEverySymbolResolvesAndEveryLabelSaysComingLater() {
        for feature in NotebookUpcomingFeature.catalogue {
            XCTAssertNotNil(UIImage(systemName: feature.symbol), "\(feature.title): \(feature.symbol)")
            XCTAssertEqual(feature.accessibilityLabel, "\(feature.title), coming later")
        }
        XCTAssertNotNil(UIImage(systemName: NotebookUpcomingFeature.menuSymbol))
        XCTAssertEqual(Set(NotebookUpcomingFeature.catalogue.map(\.symbol)).count, NotebookUpcomingFeature.catalogue.count)
    }

    // MARK: - Toolbar strip

    func testEveryExpandedToolbarEndsItsToolRowWithTheStripPlaceholdersOnce() {
        let floating = EditorToolbarPreferences(
            placement: .floating(CGPoint(x: 0.5, y: 0.5)), isCollapsed: false, customSwatches: []
        )
        var collapsed = floating
        collapsed.setCollapsed(true)
        for preferences in [EditorToolbarPreferences.standard, floating] {
            for sizeClass in [UserInterfaceSizeClass.regular, .compact, nil] {
                let composition = NotebookToolbarComposition(preferences: preferences, horizontalSizeClass: sizeClass)
                XCTAssertEqual(
                    composition.upcomingTools.map(\.title), ["Text", "Insert", "Record audio", "Bookmark"], "\(preferences)"
                )
            }
        }
        let handle = NotebookToolbarComposition(preferences: collapsed, horizontalSizeClass: .regular)
        XCTAssertTrue(handle.upcomingTools.isEmpty, "A collapsed toolbar is only its reveal handle.")
    }

    /// SwiftUI frames are not readable from a hosted test, so a tool row that needs no scrolling
    /// stands in for "every placeholder and the mark are on screen before any paging".
    func testWideToolRowShowsEveryPlaceholderWithoutScrolling() async throws {
        // A full-screen 12.9-inch iPad in landscape.
        for placement in [EditorToolbarPlacement.docked(.topCenter), .floating(CGPoint(x: 0.5, y: 0.5))] {
            let fixture = try await NotebookTestFixtures.mountToolbarHost(store: toolStore(placedAt: placement), width: 1_366)
            defer { fixture.close() }
            let strip = try XCTUnwrap(fixture.strips.first, "\(placement)")
            XCTAssertLessThanOrEqual(
                strip.contentSize.width, strip.bounds.width + 0.5,
                "\(placement): the working tools, the mark and every placeholder fit without paging."
            )
            XCTAssertEqual(strip.contentOffset.x, 0)
            assertPlaceholderTouchesStayInTheStrip(strip, fixture: fixture)
        }
    }

    /// In portrait the toolbar keeps the docks apart, so the placeholders page into view after
    /// the working tools, which all show at rest.
    func testPortraitToolRowShowsTheWorkingToolsAndPagesToThePlaceholders() async throws {
        // The 12.9-inch and 11-inch iPads in portrait.
        let placements: [EditorToolbarPlacement] = [.docked(.topCenter), .floating(CGPoint(x: 0.5, y: 0.5))]
        let layouts: [(CGFloat, EditorToolbarPlacement)] = [1_024, 834].flatMap { width in
            placements.map { (width, $0) }
        }
        for (width, placement) in layouts {
            let fixture = try await NotebookTestFixtures.mountToolbarHost(
                store: toolStore(placedAt: placement), width: width
            )
            defer { fixture.close() }
            let state = Snapshot(fixture)
            let strip = try XCTUnwrap(fixture.strips.first, "\(placement)")
            // The divider, the mark and the placeholders that close the row.
            let upcoming = CGFloat(NotebookUpcomingFeature.placed(.toolStrip).count + 1)
                * (NotebookTheme.controlSize + NotebookTheme.itemSpacing)
                + NotebookTheme.dividerThickness + NotebookTheme.itemSpacing
            XCTAssertGreaterThan(strip.contentSize.width, strip.bounds.width, "\(width) \(placement): the placeholders page.")
            XCTAssertLessThanOrEqual(
                strip.contentSize.width - upcoming,
                strip.bounds.width - NotebookTheme.controlSize - NotebookStripOverflow.fadeLength + 0.5,
                "\(width) \(placement): every working tool shows clear of the chevron and its fade, without paging."
            )

            strip.setContentOffset(CGPoint(x: strip.contentSize.width - strip.bounds.width, y: 0), animated: false)
            fixture.host.layoutIfNeeded()
            assertPlaceholderTouchesStayInTheStrip(strip, fixture: fixture)
            try await Task.sleep(for: .milliseconds(200))
            state.assertUnchanged(fixture)
        }
    }

    /// Moving between docks is plainly visible wherever the window leaves room for it: in
    /// portrait and landscape, full screen and in regular-width Split View.
    func testNeighbouringDocksStayApartAndTheirMarkersNeverOverlap() {
        let composition = NotebookToolbarComposition(preferences: .standard, horizontalSizeClass: .regular)
        for width in [1_366.0, 1_194, 1_024, 981, 834] as [CGFloat] {
            let usable = CGRect(x: 0, y: 0, width: width, height: 1_000)
            let size = composition.toolbarSize(forHostWidth: width)
            let spare = usable.width - 2 * EditorToolbarLayout.margin - composition.workingToolsWidth
            let origins = EditorToolbarDock.allCases.map {
                EditorToolbarLayout.frame(for: .docked($0), size: size, in: usable).minX
            }
            for (leading, trailing) in zip(origins, origins.dropFirst()) {
                XCTAssertGreaterThanOrEqual(
                    trailing - leading, min(NotebookToolbarComposition.minimumDockTravel, spare / 2) - 0.5, "\(width)"
                )
            }
            let markers = EditorToolbarDock.allCases.compactMap {
                NotebookDockMarkers.frames(slotSize: size, in: usable)[$0]
            }
            XCTAssertEqual(markers.count, 3, "\(width)")
            for (index, marker) in markers.enumerated() {
                for other in markers[(index + 1)...] {
                    XCTAssertFalse(marker.intersects(other), "\(width): \(marker) overlaps \(other)")
                }
            }
        }
        let portrait = composition.toolbarSize(forHostWidth: 1_024)
        XCTAssertGreaterThanOrEqual(
            (1_024 - 2 * EditorToolbarLayout.margin - portrait.width) / 2, NotebookToolbarComposition.minimumDockTravel,
            "On the 12.9-inch iPad in portrait the docks sit a clear distance apart."
        )
    }

    func testCompactWidthToolRowPagesToThePlaceholdersAndKeepsTheirTouches() async throws {
        // Half of a 12.9-inch iPad in Split View.
        let fixture = try await NotebookTestFixtures.mountToolbarHost(horizontalSizeClass: .compact, width: 507)
        defer { fixture.close() }
        let state = Snapshot(fixture)
        let strip = try XCTUnwrap(fixture.strips.first)
        XCTAssertGreaterThan(strip.contentSize.width, strip.bounds.width, "The ink chip leaves less room at compact width.")

        strip.setContentOffset(CGPoint(x: strip.contentSize.width - strip.bounds.width, y: 0), animated: false)
        fixture.host.layoutIfNeeded()
        assertPlaceholderTouchesStayInTheStrip(strip, fixture: fixture)

        try await Task.sleep(for: .milliseconds(200))
        state.assertUnchanged(fixture)
    }

    func testPlaceholderGlyphIsDrawnInTheDisabledTone() throws {
        let feature = try XCTUnwrap(NotebookUpcomingFeature.placed(.toolStrip).first)
        let placeholder = try darkestLuminance(of: NotebookUpcomingToolButton(feature: feature))
        let enabled = try darkestLuminance(of: NotebookToolGlyph(symbol: feature.symbol, isSelected: false))
        let disabledTone = luminance(NotebookTheme.disabledGlyph.uiColor)
        XCTAssertEqual(placeholder, disabledTone, accuracy: 0.03, "The placeholder glyph uses the disabled tone.")
        XCTAssertLessThan(enabled, placeholder - 0.1, "A working tool is drawn darker than a placeholder.")
    }

    func testSoonMarkIsAQuietCaptionThatDimsWithTheToolbar() throws {
        let enabled = try darkestLuminance(of: NotebookUpcomingMark())
        let paused = try darkestLuminance(of: NotebookUpcomingMark().environment(\.isEnabled, false))
        XCTAssertEqual(enabled, luminance(NotebookTheme.paperControlTint.uiColor), accuracy: 0.03)
        XCTAssertGreaterThan(enabled, luminance(NotebookTheme.glyph.uiColor) + 0.05, "Lighter than a working tool glyph.")
        XCTAssertEqual(paused, luminance(NotebookTheme.disabledGlyph.uiColor), accuracy: 0.03)
    }

    // MARK: - Navigation bar

    func testNavigationPlaceholdersAreDisabledAndCarryNoAction() async throws {
        let screen = try await mountScreen(width: 1_024)
        defer { screen.close() }
        let canvas = screen.controller.canvasView
        let tool = screen.store.tool
        let toolbar = screen.store.toolbar
        let drawing = canvas.drawing.dataRepresentation()
        let saveCalls = await screen.probe.saveCalls

        for feature in NotebookUpcomingFeature.placed(.navigationLeading) {
            let matches = screen.leading.filter { $0.title == feature.accessibilityLabel }
            XCTAssertEqual(matches.count, 1, feature.title)
            let button = try XCTUnwrap(matches.first)
            XCTAssertFalse(button.isEnabled, "\(feature.title) is disabled.")
            XCTAssertNil(button.menu)
            XCTAssertNil(button.customView, "A native bar button, which VoiceOver reads by its title.")
            XCTAssertNil(button.primaryAction, "\(feature.title) has no action to perform.")
            XCTAssertNil(button.action, "\(feature.title) sends nothing.")
        }

        // The menu builds its entries when opened, so its contents are checked through the entries it lists.
        let menus = screen.trailing.filter { $0.menu != nil }
        XCTAssertEqual(menus.count, 1, "The trailing placeholders share one menu.")
        let menuItem = try XCTUnwrap(menus.first)
        XCTAssertEqual(menuItem.title, NotebookUpcomingMenu.title)
        XCTAssertTrue(menuItem.isEnabled, "The menu opens to show the disabled entries.")
        XCTAssertEqual(NotebookUpcomingMenu.entries, NotebookUpcomingFeature.placed(.navigationTrailing))
        let barTitles = (screen.leading + screen.trailing).compactMap(\.title)
        for feature in NotebookUpcomingFeature.catalogue where feature.placement != .navigationLeading {
            XCTAssertFalse(
                barTitles.contains { $0.hasPrefix(feature.title) }, "\(feature.title) is not a bar button of its own."
            )
        }
        for title in ["Undo", "Recovery copies", "Extend paper"] {
            XCTAssertTrue(barTitles.contains(title), "\(title) is still in the bar.")
        }

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(screen.store.tool, tool)
        XCTAssertEqual(screen.store.toolbar, toolbar)
        XCTAssertEqual(canvas.drawing.dataRepresentation(), drawing)
        let savesAfter = await screen.probe.saveCalls
        XCTAssertEqual(savesAfter, saveCalls)
        XCTAssertNil(screen.hosting.presentedViewController)
        XCTAssertEqual(screen.session.loadState, .ready)
    }

    /// Split View and Slide Over: the bar keeps every existing item and every placeholder,
    /// whether it shows them inline or folds some into its overflow.
    func testCompactWidthNavigationBarKeepsEveryItemAndPlaceholder() async throws {
        let screen = try await mountScreen(width: 420, horizontalSizeClass: .compact)
        defer { screen.close() }
        XCTAssertEqual(screen.hosting.traitCollection.horizontalSizeClass, .compact)
        let titles = (screen.leading + screen.trailing).compactMap(\.title)
        for title in ["Undo", "Recovery copies", "Extend paper", NotebookUpcomingMenu.title]
            + NotebookUpcomingFeature.placed(.navigationLeading).map(\.accessibilityLabel) {
            XCTAssertEqual(titles.filter { $0 == title }.count, 1, "\(title) is still in the bar once.")
        }
        let notebooks = screen.leading.filter { $0.title?.hasPrefix("Notebooks") == true }
        XCTAssertTrue(notebooks.allSatisfy { !$0.isEnabled })
        XCTAssertEqual(screen.session.loadState, .ready)
    }

    // MARK: - Fixtures

    /// The full notebook screen inside a navigation bar, as the app shows it.
    private struct MountedScreen {
        let hosting: UIViewController
        let window: UIWindow
        let session: NotebookSession
        let probe: NotebookStorageProbe
        let store: NotebookSceneToolStore
        let controller: NotebookViewController
        let leading: [UIBarButtonItem]
        let trailing: [UIBarButtonItem]

        @MainActor
        func close() {
            session.flush()
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    private func mountScreen(
        width: CGFloat, horizontalSizeClass: UIUserInterfaceSizeClass? = nil
    ) async throws -> MountedScreen {
        let id = UUID()
        let root = NotebookTestFixtures.root()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let probe = try NotebookStorageProbe(stored: try await NotebookTestFixtures.stored(id: id), recoveryRoot: root)
        let storage = await probe.storage(notebookID: id)
        let session = NotebookSession(notebookID: id, openStorage: { storage })
        let scene = try NotebookTestFixtures.windowScene()
        NotebookTestFixtures.restoreSceneToolDefaults(for: scene, after: self)
        let store = NotebookSceneToolStore.owner(for: scene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 1_366)
        let hosting = UIHostingController(rootView: NotebookScreen(session: session))
        if let horizontalSizeClass { hosting.traitOverrides.horizontalSizeClass = horizontalSizeClass }
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        do {
            var controller: NotebookViewController?
            try await NotebookTestFixtures.waitUntil {
                controller = NotebookTestFixtures.notebookController(in: hosting)
                return controller?.isCanvasVisible == true && store.isToolbarAvailable
            }
            let item = try XCTUnwrap(NotebookTestFixtures.navigationController(in: hosting)?.navigationBar.topItem)
            return MountedScreen(
                hosting: hosting, window: window, session: session, probe: probe, store: store,
                controller: try XCTUnwrap(controller),
                leading: item.leadingItemGroups.flatMap(\.barButtonItems),
                trailing: item.trailingItemGroups.flatMap(\.barButtonItems)
            )
        } catch {
            session.flush()
            window.isHidden = true
            window.rootViewController = nil
            throw error
        }
    }

    /// What a placeholder must never change.
    private struct Snapshot {
        let tool: EditorToolState
        let toolbar: EditorToolbarPreferences
        let canvasTool: String
        let isRulerActive: Bool
        let drawing: Data

        @MainActor
        init(_ fixture: NotebookToolbarHostFixture) {
            tool = fixture.store.tool
            toolbar = fixture.store.toolbar
            canvasTool = String(describing: type(of: fixture.controller.canvasView.tool))
            isRulerActive = fixture.controller.canvasView.isRulerActive
            drawing = fixture.controller.canvasView.drawing.dataRepresentation()
        }

        @MainActor
        func assertUnchanged(_ fixture: NotebookToolbarHostFixture, file: StaticString = #filePath, line: UInt = #line) {
            let now = Snapshot(fixture)
            XCTAssertEqual(now.tool, tool, file: file, line: line)
            XCTAssertEqual(now.toolbar, toolbar, file: file, line: line)
            XCTAssertEqual(now.canvasTool, canvasTool, file: file, line: line)
            XCTAssertEqual(now.isRulerActive, isRulerActive, file: file, line: line)
            XCTAssertEqual(now.drawing, drawing, file: file, line: line)
            XCTAssertNil(fixture.hosting.presentedViewController, file: file, line: line)
        }
    }

    private func toolStore(placedAt placement: EditorToolbarPlacement) -> NotebookSceneToolStore {
        let store = NotebookTestFixtures.toolStore()
        store.updateToolbar(EditorToolbarPreferences(placement: placement, isCollapsed: false, customSwatches: []))
        return store
    }

    /// Touches on the placeholder span stay in the tool strip and never reach the canvas. That a
    /// placeholder then does nothing is a design guarantee: its button receives only a catalogue entry.
    private func assertPlaceholderTouchesStayInTheStrip(
        _ strip: UIScrollView, fixture: NotebookToolbarHostFixture, file: StaticString = #filePath, line: UInt = #line
    ) {
        let frame = fixture.frame(of: strip)
        let placeholders = CGFloat(NotebookUpcomingFeature.placed(.toolStrip).count)
        let span = placeholders * (NotebookTheme.controlSize + NotebookTheme.itemSpacing)
        let trailing = frame.maxX - NotebookTheme.stripInsets.right
        for x in stride(from: trailing - span + NotebookTheme.controlSize / 2, to: trailing, by: 25) {
            let target = fixture.hit(CGPoint(x: x, y: frame.midY))
            XCTAssertFalse(target.isDescendant(of: fixture.controller.view), "x \(x)", file: file, line: line)
            XCTAssertTrue(target.isDescendant(of: strip), "x \(x)", file: file, line: line)
        }
    }

    private func darkestLuminance<Content: View>(of content: Content) throws -> Double {
        let pixels = try RenderedPixels(rendering: content)
        var darkest = 1.0
        for offset in stride(from: 0, to: pixels.rgba.count, by: 4) where pixels.rgba[offset + 3] == 255 {
            let pixel = UIColor(
                red: CGFloat(pixels.rgba[offset]) / 255, green: CGFloat(pixels.rgba[offset + 1]) / 255,
                blue: CGFloat(pixels.rgba[offset + 2]) / 255, alpha: 1
            )
            darkest = min(darkest, luminance(pixel))
        }
        return darkest
    }

    private func luminance(_ color: UIColor) -> Double {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: nil)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
}
