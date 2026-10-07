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
        XCTAssertEqual(
            NotebookUpcomingFeature.placed(.menu).map(\.title), ["Notebooks", "Search", "Summarize", "Export", "Backup"]
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

    /// The planned tools close the tool row as one group, only where the rail fits all of them; a
    /// floating rail's first row also ends with its collapse key, so in portrait on the 12.9-inch
    /// iPad the group yields to the key. The single compact row scrolls on to them, as it always has.
    func testToolRowEndsWithEveryPlaceholderOnlyWhereTheWholeGroupFits() {
        let floating = EditorToolbarPreferences(
            placement: .floating(CGPoint(x: 0.5, y: 0.5)), isCollapsed: false, customSwatches: []
        )
        // Width, size class, shown docked, shown floating.
        let expected: [(CGFloat, UserInterfaceSizeClass?, Bool, Bool)] = [
            (1_366, .regular, true, true), (1_024, .regular, true, false), (1_032, nil, true, false),
            (1_194, .regular, true, true), (834, .regular, false, false), (678, .regular, false, false),
            (507, .compact, true, true),
        ]
        for preferences in [EditorToolbarPreferences.standard, floating] {
            for (width, sizeClass, showsDocked, showsFloating) in expected {
                let shows = preferences == floating ? showsFloating : showsDocked
                let rail = NotebookToolbarComposition(preferences: preferences, horizontalSizeClass: sizeClass)
                    .rail(forHostWidth: width)
                let label = "\(width) \(String(describing: sizeClass)) \(preferences.placement)"
                XCTAssertEqual(rail.showsUpcoming, shows, label)
                let tail = rail.toolRow.slots.suffix(NotebookUpcomingFeature.placed(.toolStrip).count + 1).map(\.item)
                let placeholders = rail.toolRow.slots.compactMap { slot -> NotebookUpcomingFeature? in
                    if case let .upcoming(feature) = slot.item { feature } else { nil }
                }
                if shows {
                    XCTAssertEqual(placeholders.map(\.title), ["Text", "Insert", "Record audio", "Bookmark"], label)
                    XCTAssertEqual(
                        tail, [.upcomingLabel] + NotebookUpcomingFeature.placed(.toolStrip).map { .upcoming($0) }, label
                    )
                } else {
                    XCTAssertTrue(placeholders.isEmpty, label)
                    XCTAssertFalse(rail.toolRow.slots.contains { $0.item == .upcomingLabel }, label)
                }
            }
        }
    }

    /// SwiftUI frames are not readable from a hosted test, so a tool row that needs no scrolling
    /// stands in for "every placeholder and the caption are on screen before any paging".
    func testWideToolRowShowsEveryPlaceholderWithoutScrolling() async throws {
        // A full-screen 12.9-inch iPad in landscape and in portrait, and the 11-inch in landscape;
        // floating, the portrait rail gives the group's room to its collapse key.
        for width in [1_366.0, 1_024, 1_194] as [CGFloat] {
            let placements: [EditorToolbarPlacement] = width == 1_024
                ? [.docked(.topCenter)] : [.docked(.topCenter), .floating(CGPoint(x: 0.5, y: 0.5))]
            for placement in placements {
                let fixture = try await NotebookTestFixtures.mountToolbarHost(store: toolStore(placedAt: placement), width: width)
                defer { fixture.close() }
                let strip = try XCTUnwrap(fixture.strips.first, "\(placement)")
                XCTAssertLessThanOrEqual(
                    strip.contentSize.width, strip.bounds.width + 0.5,
                    "\(width) \(placement): the working tools, the caption and every placeholder fit without paging."
                )
                XCTAssertEqual(strip.contentOffset.x, 0)
                assertPlaceholderTouchesStayInTheStrip(strip, fixture: fixture, width: width)
            }
        }
    }

    /// Where the window cannot fit the whole group, the planned tools stay out of the rail, so
    /// every working tool shows at rest and nothing pages in part.
    func testNarrowerToolRowShowsEveryWorkingToolWithoutPlaceholders() async throws {
        // The 11-inch iPad in portrait, and a floating rail in portrait on the 12.9-inch, whose
        // collapse key takes the group's room.
        for width in [834.0, 1_024] as [CGFloat] {
            let placements: [EditorToolbarPlacement] = width == 1_024
                ? [.floating(CGPoint(x: 0.5, y: 0.5))] : [.docked(.topCenter), .floating(CGPoint(x: 0.5, y: 0.5))]
            for placement in placements {
                let fixture = try await NotebookTestFixtures.mountToolbarHost(store: toolStore(placedAt: placement), width: width)
                defer { fixture.close() }
                let strip = try XCTUnwrap(fixture.strips.first, "\(placement)")
                let rail = NotebookToolbarComposition(preferences: fixture.store.toolbar, horizontalSizeClass: .regular)
                    .rail(forHostWidth: width)
                XCTAssertFalse(rail.showsUpcoming)
                XCTAssertEqual(strip.contentSize.width, rail.toolRow.contentWidth, accuracy: 0.5)
                XCTAssertLessThanOrEqual(
                    strip.contentSize.width, strip.bounds.width + 0.5, "\(width) \(placement): every working tool shows."
                )
            }
        }
    }

    /// The three docks lie along different edges, so their markers never overlap in any regular
    /// window; at compact width only the top is a dock.
    func testDockMarkersStayApartAndCompactWidthMarksOnlyTheTop() {
        let composition = NotebookToolbarComposition(preferences: .standard, horizontalSizeClass: .regular)
        for size in [CGSize(width: 1_366, height: 950), CGSize(width: 1_024, height: 1_290), CGSize(width: 834, height: 1_104),
                     CGSize(width: 1_194, height: 728), CGSize(width: 678, height: 1_290)] {
            let usable = CGRect(origin: .zero, size: size)
            let markers = NotebookDockMarkers.frames(dockSizes: composition.dockSizes(in: size), in: usable, sideDocks: true)
            XCTAssertEqual(Set(markers.keys), Set(EditorToolbarDock.allCases), "\(size)")
            let frames = Array(markers.values)
            for (index, marker) in frames.enumerated() {
                for other in frames[(index + 1)...] {
                    XCTAssertFalse(marker.intersects(other), "\(size): \(marker) overlaps \(other)")
                }
            }
        }
        let compact = NotebookDockMarkers.frames(
            dockSizes: composition.dockSizes(in: CGSize(width: 507, height: 1_290)),
            in: CGRect(x: 0, y: 0, width: 507, height: 1_290), sideDocks: false
        )
        XCTAssertEqual(Array(compact.keys), [.topCenter])
    }

    func testCompactWidthToolRowPagesToItsEndAndKeepsItsTouches() async throws {
        // Half of a 12.9-inch iPad in Split View.
        let fixture = try await NotebookTestFixtures.mountToolbarHost(horizontalSizeClass: .compact, width: 507)
        defer { fixture.close() }
        let state = Snapshot(fixture)
        let strip = try XCTUnwrap(fixture.strips.first)
        XCTAssertEqual(fixture.strips.count, 1)
        XCTAssertGreaterThan(strip.contentSize.width, strip.bounds.width, "The ink chip leaves less room at compact width.")

        strip.setContentOffset(CGPoint(x: strip.contentSize.width - strip.bounds.width, y: 0), animated: false)
        fixture.host.layoutIfNeeded()
        let frame = fixture.frame(of: strip)
        for x in stride(from: frame.maxX - 2 * NotebookTheme.controlSize, to: frame.maxX, by: 20) {
            let target = fixture.hit(CGPoint(x: x, y: frame.midY))
            XCTAssertFalse(target.isDescendant(of: fixture.controller.view), "x \(x)")
            XCTAssertTrue(target.isDescendant(of: strip), "x \(x)")
        }

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

        // A paused rail keeps its keys in the glyph tone; a placeholder stays disabled for good.
        let paused = try darkestLuminance(of: NotebookUpcomingToolButton(feature: feature)
            .environment(\.notebookKeysPaused, true))
        XCTAssertEqual(paused, disabledTone, accuracy: 0.03, "A paused rail leaves the placeholder's tone alone.")
        let pausedKey = try darkestLuminance(of: Button {} label: {
            NotebookToolGlyph(symbol: feature.symbol, isSelected: false)
        }
        .buttonStyle(NotebookKeyStyle())
        .disabled(true)
        .environment(\.notebookKeysPaused, true))
        XCTAssertEqual(pausedKey, enabled, accuracy: 0.03, "A key only the pause disables keeps the glyph tone.")
    }

    func testSoonCaptionIsAQuietSectionLabel() throws {
        let caption = try darkestLuminance(of: NotebookUpcomingMark())
        XCTAssertEqual(caption, luminance(NotebookTheme.glyphSecondary.uiColor), accuracy: 0.03)
        XCTAssertGreaterThan(caption, luminance(NotebookTheme.glyph.uiColor) + 0.01, "Quieter than a working tool glyph.")
        let size = UIHostingController(rootView: NotebookUpcomingMark()).sizeThatFits(in: CGSize(width: 500, height: 500))
        XCTAssertEqual(size, CGSize(width: NotebookTheme.controlSize, height: NotebookTheme.controlSize),
            "One control wide, so the rail can count it.")
    }

    // MARK: - Header and notebook menu

    /// The system bar is gone, so no planned feature sits in it; every one is listed, disabled,
    /// under the notebook menu's "Coming later".
    func testHeaderReplacesTheNavigationBarAndOffersNoPlaceholderButtons() async throws {
        let screen = try await mountScreen(width: 1_024)
        defer { screen.close() }
        let navigation = try XCTUnwrap(NotebookTestFixtures.navigationController(in: screen.hosting))
        XCTAssertTrue(navigation.isNavigationBarHidden, "The editor draws its own header.")
        let item = navigation.navigationBar.topItem
        XCTAssertTrue(item?.leadingItemGroups.flatMap(\.barButtonItems).isEmpty ?? true)
        XCTAssertTrue(item?.trailingItemGroups.flatMap(\.barButtonItems).isEmpty ?? true)
        XCTAssertNotNil(NotebookHeaderTests.headerHost(in: screen.hosting))
        XCTAssertEqual(screen.session.loadState, .ready)

        XCTAssertEqual(
            NotebookMenu.comingLater.map(\.title),
            ["Notebooks", "Search", "Summarize", "Export", "Backup", "Text", "Insert", "Record audio", "Bookmark"]
        )
        XCTAssertEqual(Set(NotebookMenu.comingLater.map(\.title)), Set(NotebookUpcomingFeature.catalogue.map(\.title)))
    }

    /// The header and menu symbols say what they do: a page with a plus for adding a page, a
    /// lifebuoy for recovery, a seal for verified history and a dotted circle while saving.
    func testHeaderAndMenuSymbolsResolve() {
        let symbols = [
            "rectangle.portrait.badge.plus", "lifepreserver", "checkmark.seal", "xmark.seal", "questionmark.circle",
            "circle.dotted", "doc", "checkmark.circle", "exclamationmark.triangle.fill", "lock",
            "gauge.with.dots.needle.67percent", "line.3.horizontal", "arrow.uturn.backward", "arrow.uturn.forward",
            "rectangle.leadingthird.inset.filled", "rectangle.topthird.inset.filled",
            "rectangle.trailingthird.inset.filled", "rectangle.center.inset.filled",
        ] + EditorChromeMode.allCases.map(\.symbol)
        for symbol in symbols {
            XCTAssertNotNil(UIImage(systemName: symbol), symbol)
        }
        XCTAssertEqual(EditorChromeMode.allCases.map(\.title), ["Focus", "Pinned", "Always-on tools"])
        XCTAssertEqual(EditorChromeMode.allCases.map(\.shortcutHint), ["⌃⌘1", "⌃⌘2", "⌃⌘3"])
    }

    func testAddPageFollowsTheWritingGateAndThePageLimit() {
        typealias State = NotebookCanvasGateModel.State
        XCTAssertTrue(NotebookMenu.canAddPage(State(pageCount: 3, inputGate: .open)))
        XCTAssertTrue(NotebookMenu.canAddPage(State(pageCount: NotebookViewController.maximumPageCount - 1, inputGate: .open)))
        XCTAssertFalse(NotebookMenu.canAddPage(State(pageCount: NotebookViewController.maximumPageCount, inputGate: .open)))
        for gate in [NotebookInputGate.capacity, .failed, .recovering, .readOnly] {
            XCTAssertFalse(NotebookMenu.canAddPage(State(pageCount: 3, inputGate: gate)), "\(gate)")
        }
    }

    /// A compact window has no side docks, so a toolbar stored at a side rests at the top; the menu
    /// says so exactly then, whatever the width.
    func testToolbarPositionNotesWhenASideDockRestsAtTheTop() {
        let stored: [(EditorToolbarPreferences, Bool)] = [
            (.standard, false),
            (EditorToolbarPreferences(placement: .docked(.leftEdge), isCollapsed: false, customSwatches: []), true),
            (EditorToolbarPreferences(placement: .docked(.rightEdge), isCollapsed: false, customSwatches: []), true),
            (EditorToolbarPreferences(placement: .floating(CGPoint(x: 0.3, y: 0.7)), isCollapsed: true, customSwatches: []), false),
        ]
        for (preferences, isSide) in stored {
            for sizeClass in [UserInterfaceSizeClass.regular, .compact] {
                let label = "\(preferences.placement) \(sizeClass)"
                let noted = NotebookToolbarPositionPicker.restsAtTopInstead(preferences: preferences, sizeClass: sizeClass)
                XCTAssertEqual(noted, isSide && sizeClass == .compact, label)
                let composition = NotebookToolbarComposition(preferences: preferences, horizontalSizeClass: sizeClass)
                XCTAssertEqual(noted, composition.storedDock != composition.shownDock, "\(label): the note follows the rail.")
            }
        }
    }

    // MARK: - Fixtures

    /// The full notebook screen, as the app shows it.
    private struct MountedScreen {
        let hosting: UIViewController
        let window: UIWindow
        let session: NotebookSession
        let probe: NotebookStorageProbe
        let store: NotebookSceneToolStore
        let controller: NotebookViewController

        @MainActor
        func close() {
            session.flush()
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    private func mountScreen(width: CGFloat) async throws -> MountedScreen {
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
        let hosting = AppearanceTrackingHostingController(rootView: NotebookScreen(session: session))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        do {
            try await NotebookTestFixtures.waitUntilAppeared(hosting)
            var controller: NotebookViewController?
            try await NotebookTestFixtures.waitUntil {
                controller = NotebookTestFixtures.notebookController(in: hosting)
                return controller?.isCanvasVisible == true && store.isToolbarAvailable
            }
            return MountedScreen(
                hosting: hosting, window: window, session: session, probe: probe, store: store,
                controller: try XCTUnwrap(controller)
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
        _ strip: UIScrollView, fixture: NotebookToolbarHostFixture, width: CGFloat,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let frame = fixture.frame(of: strip)
        let rail = NotebookToolbarComposition(preferences: fixture.store.toolbar, horizontalSizeClass: .regular)
            .rail(forHostWidth: width)
        let placeholders = rail.toolRow.slots.filter { if case .upcoming = $0.item { true } else { false } }
        XCTAssertEqual(placeholders.count, NotebookUpcomingFeature.placed(.toolStrip).count, file: file, line: line)
        for slot in placeholders {
            let x = frame.minX + slot.minX + slot.width / 2 - strip.contentOffset.x
            let target = fixture.hit(CGPoint(x: x, y: frame.midY))
            XCTAssertFalse(target.isDescendant(of: fixture.controller.view), "\(slot.id)", file: file, line: line)
            XCTAssertTrue(target.isDescendant(of: strip), "\(slot.id)", file: file, line: line)
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
