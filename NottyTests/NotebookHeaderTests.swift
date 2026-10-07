import Combine
import NottyCore
import PencilKit
import SwiftUI
import UIKit
import XCTest
@testable import Notty

@MainActor
final class NotebookHeaderTests: XCTestCase {
    // MARK: - Layout

    func testHeaderLayoutGivesWayAsTheShellNarrows() {
        // 11-inch portrait, 12.9-inch portrait, two-thirds Split View on the 12.9-inch, and narrower.
        let wide = NotebookHeaderLayout(shellWidth: 810, typeSize: .large)
        XCTAssertTrue(wide.showsNameplate)
        XCTAssertFalse(wide.isCompact)
        XCTAssertTrue(wide.showsSaveCaption)
        XCTAssertEqual(wide.leadingInset, NotebookTheme.nameplateLeadingInset)
        XCTAssertEqual(wide.trailingGroupGap, NotebookTheme.headerTrailingGap)
        XCTAssertEqual(NotebookHeaderLayout(shellWidth: 1_000, typeSize: .large), wide)
        XCTAssertEqual(NotebookHeaderLayout(shellWidth: 654, typeSize: .large), wide, "Split View keeps the nameplate.")

        let noNameplate = NotebookHeaderLayout(shellWidth: 540, typeSize: .large)
        XCTAssertFalse(noNameplate.showsNameplate)
        XCTAssertEqual(noNameplate.leadingInset, NotebookTheme.headerPadding)
        XCTAssertTrue(noNameplate.showsSaveCaption)

        let compact = NotebookHeaderLayout(shellWidth: 470, typeSize: .large)
        XCTAssertTrue(compact.isCompact)
        XCTAssertFalse(compact.showsSaveCaption, "The save readout keeps only its glyph.")
        XCTAssertTrue(compact.showsCaptions, "Unusual history states keep their word.")
        XCTAssertEqual(compact.trailingGroupGap, NotebookTheme.headerPadding)

        let accessibility = NotebookHeaderLayout(shellWidth: 810, typeSize: .accessibility1)
        XCTAssertFalse(accessibility.showsNameplate)
        XCTAssertFalse(accessibility.showsCaptions)
        XCTAssertFalse(accessibility.showsSaveCaption)

        // Redo gives way last, where the title could no longer keep 96 pt: 8 + 14 + 96 + 12 + 44
        // + 8 for the padding, tray and save glyph, then Undo, Redo, the divider, the menu key and
        // the trailing pad.
        XCTAssertEqual(NotebookHeaderLayout.redoMinimumShellWidth, 337)
        for width in [810, 540, 470, 396, 337] as [CGFloat] {
            XCTAssertTrue(NotebookHeaderLayout(shellWidth: width, typeSize: .large).showsRedo, "\(width)")
        }
        XCTAssertFalse(NotebookHeaderLayout(shellWidth: 336, typeSize: .large).showsRedo)
        XCTAssertFalse(NotebookHeaderLayout(shellWidth: 296, typeSize: .large).showsRedo, "Slide Over")
    }

    /// The header spans the window less 12 pt each side, 6 pt below the status bar and 60 pt tall,
    /// and a docked toolbar sits 8 pt below it. The tray takes 480 pt where it fits.
    func testHeaderGeometryAndTrayWidthAcrossWindowWidths() async throws {
        // The 11-inch and 12.9-inch iPads in portrait, and two-thirds Split View on the 12.9-inch.
        let windows: [(width: CGFloat, height: CGFloat, tray: CGFloat)] = [
            (834, 1_210, 480), (1_024, 1_366, 480), (678, 1_366, 406),
        ]
        for (width, height, tray) in windows {
            let editor = try await mountEditor(width: width, height: height)
            defer { editor.close() }
            let safeTop = editor.window.safeAreaInsets.top
            let host = editor.frameInWindow(editor.header.view)
            XCTAssertEqual(host.minX, NotebookTheme.headerSideInset, accuracy: 0.5, "\(width)")
            XCTAssertEqual(host.width, width - 2 * NotebookTheme.headerSideInset, accuracy: 0.5, "\(width)")
            XCTAssertEqual(host.minY, safeTop, accuracy: 0.5, "\(width)")
            let shell = editor.shellFrame
            XCTAssertEqual(shell.minY, safeTop + NotebookTheme.headerTopGap, accuracy: 0.5, "\(width)")
            XCTAssertEqual(shell.height, NotebookTheme.headerHeight, accuracy: 0.5, "\(width)")

            // The docked toolbar starts 8 pt below the header, and the canvas reserves the header.
            let canvas = editor.controller.canvasView
            let reserved = safeTop + NotebookScreen.headerReservation
            XCTAssertEqual(canvas.contentInset.top - editor.store.overlayObstruction.top, reserved, accuracy: 0.5)
            let toolbarHeight = NotebookToolbarComposition(preferences: editor.store.toolbar, horizontalSizeClass: .regular)
                .toolbarSize(forHostWidth: width).height
            let toolbarTop = reserved + editor.store.overlayObstruction.top - toolbarHeight
            XCTAssertEqual(toolbarTop, shell.maxY + NotebookTheme.headerToolbarGap, accuracy: 0.5, "\(width)")

            let trayEdges = try editor.trayEdges()
            XCTAssertEqual(trayEdges.width, tray, accuracy: 3, "\(width): \(trayEdges)")
            XCTAssertGreaterThan(trayEdges.minX, shell.minX + NotebookTheme.nameplateLeadingInset + 30,
                "\(width): the nameplate leads the tray.")
        }
    }

    /// Split View, Slide Over and the narrowest windows: the nameplate and captions give way, then
    /// Redo, so the title keeps at least 96 pt and the menu key keeps its place inside the shell.
    func testNarrowHeadersKeepEveryControlInsideTheShell() async throws {
        for width in [420, 320] as [CGFloat] {
            let editor = try await mountEditor(width: width, sizeClass: .compact)
            defer { editor.close() }
            let shell = editor.shellFrame
            XCTAssertEqual(shell.width, width - 2 * NotebookTheme.headerSideInset, accuracy: 0.5)
            let pixels = try editor.renderedPixels()
            let accent = try XCTUnwrap(editor.accentKeySpan(in: pixels), "\(width): the menu key is drawn")
            let keyInset = (NotebookTheme.controlSize - NotebookTheme.accentKeySize.width) / 2
            XCTAssertEqual(accent.upperBound, shell.maxX - NotebookTheme.headerPadding - keyInset, accuracy: 1,
                "\(width): the menu key ends the header, inside it")
            let tray = try editor.trayEdges(in: pixels)
            XCTAssertEqual(tray.minX, shell.minX + NotebookTheme.headerPadding, accuracy: 1,
                "\(width): without the nameplate the tray starts at the padding")

            let showsRedo = NotebookHeaderLayout(shellWidth: shell.width, typeSize: .large).showsRedo
            XCTAssertEqual(showsRedo, width == 420, "\(width)")
            let keys: CGFloat = showsRedo ? 3 : 2
            let trailingGroup = NotebookTheme.controlSize * keys + NotebookTheme.itemSpacing * keys
                + 2 * NotebookTheme.dividerPadding + NotebookTheme.dividerThickness
            XCTAssertEqual(tray.minX + tray.width,
                shell.maxX - NotebookTheme.headerPadding - trailingGroup - NotebookTheme.headerPadding, accuracy: 1.5,
                "\(width): the tray reaches the compact gap before Undo")
            let titleRoom = tray.width - NotebookTheme.trayContentInset - NotebookTheme.readoutPadding
                - NotebookTheme.controlSize
            XCTAssertGreaterThanOrEqual(titleRoom, NotebookTheme.headerTitleMinimumWidth - 1,
                "\(width): the title keeps its least room beside the save glyph")
        }
    }

    // MARK: - Scroll follow

    /// Programmatic offsets never move the header; a user drag moves it with the page until it is
    /// gone, invisible and letting touches through, and no SwiftUI body runs on the way.
    func testOnlyUserScrollingMovesTheHeaderAndRunsNoBodyPerFrame() async throws {
        let editor = try await mountEditor(width: 834)
        defer { editor.close() }
        let canvas = editor.controller.canvasView
        let header = editor.header.headerView
        let shellCentre = CGPoint(x: editor.shellFrame.midX, y: editor.shellFrame.midY)
        XCTAssertTrue(NotebookTestFixtures.hit(shellCentre, in: editor.window).isDescendant(of: editor.header.view))

        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: 400), animated: false)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: 0), animated: false)
        XCTAssertEqual(header.transform, .identity, "A programmatic offset never moves the header.")
        XCTAssertEqual(editor.chrome.travel, 0)

        let headerBodies = editor.session.renderDiagnostics.headerBodyCount
        let screenBodies = editor.session.renderDiagnostics.screenBodyCount
        // The writing view publishes nothing while the page scrolls, and the store only the one
        // change the toolbar draws: the tools leaving.
        var chromeChanges = 0
        var storeChanges = 0
        let chromeWatch = editor.chrome.objectWillChange.sink { chromeChanges += 1 }
        let storeWatch = editor.store.objectWillChange.sink { storeChanges += 1 }
        defer {
            chromeWatch.cancel()
            storeWatch.cancel()
        }
        editor.controller.scrollViewWillBeginDragging(canvas)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: 10), animated: false)
        XCTAssertEqual(header.transform.ty, -10, accuracy: 0.01, "The header follows the page one to one.")
        XCTAssertEqual(header.alpha, 1)
        XCTAssertFalse(header.isUserInteractionEnabled, "A header on its way out takes no touches.")
        let leaving = NotebookTestFixtures.hit(shellCentre, in: editor.window)
        XCTAssertTrue(leaving.isDescendant(of: editor.controller.view), "Touches reach the page: \(leaving)")
        for step in 1...20 {
            canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: 10 + CGFloat(step) * 5), animated: false)
        }
        XCTAssertEqual(header.transform.ty, -NotebookWritingChrome.fullTravel, accuracy: 0.01)
        XCTAssertEqual(header.alpha, 0)
        XCTAssertTrue(editor.store.areToolsHidden, "Focus hides the tools as the page scrolls on.")
        let through = NotebookTestFixtures.hit(shellCentre, in: editor.window)
        XCTAssertTrue(through.isDescendant(of: editor.controller.view), "Touches reach the page: \(through)")
        editor.controller.scrollViewDidEndDragging(canvas, willDecelerate: false)
        XCTAssertEqual(editor.chrome.travel, NotebookWritingChrome.fullTravel)

        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(editor.session.renderDiagnostics.headerBodyCount, headerBodies, "No header body per scroll frame.")
        XCTAssertEqual(editor.session.renderDiagnostics.screenBodyCount, screenBodies)
        XCTAssertEqual(chromeChanges, 0, "The writing view invalidates no view while the page scrolls.")
        XCTAssertEqual(storeChanges, 1, "The toolbar hears only that the tools left.")

        // Scrolling back up brings it back, and a part-way header settles to the end the state chose.
        editor.controller.scrollViewWillBeginDragging(canvas)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: canvas.contentOffset.y - 30), animated: false)
        XCTAssertEqual(header.transform, .identity)
        XCTAssertEqual(header.alpha, 1)
        XCTAssertTrue(header.isUserInteractionEnabled)
        XCTAssertFalse(editor.store.areToolsHidden)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: canvas.contentOffset.y + 15), animated: false)
        XCTAssertEqual(header.transform.ty, -15, accuracy: 0.01)
        editor.controller.scrollViewDidEndDragging(canvas, willDecelerate: false)
        XCTAssertEqual(header.transform, .identity, "Short of hiding, the header settles back in place.")
    }

    func testAlwaysOnToolsScrollsTheHeaderAwayAndKeepsTheTools() async throws {
        let editor = try await mountEditor(width: 834)
        defer { editor.close() }
        editor.chrome.setMode(.overlay)
        let canvas = editor.controller.canvasView
        XCTAssertNotNil(editor.accentKeySpan(in: try editor.renderedPixels()), "The header is drawn at first.")

        editor.controller.scrollViewWillBeginDragging(canvas)
        for step in 1...20 {
            canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: CGFloat(step) * 6), animated: false)
        }
        editor.controller.scrollViewDidEndDragging(canvas, willDecelerate: false)
        XCTAssertEqual(editor.header.headerView.alpha, 0)
        XCTAssertFalse(editor.store.areToolsHidden)
        // On screen the page has taken the header's place, and keeps it once the page rests: no
        // accent key, and paper where the tray was.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(editor.header.headerView.alpha, 0)
        let away = try editor.renderedPixels()
        XCTAssertNil(editor.accentKeySpan(in: away), "The header is gone from the screen.")
        let shell = editor.shellFrame
        for x in stride(from: shell.minX + 120, to: shell.minX + 400, by: 40) {
            let pixel = away.rgba(at: CGPoint(x: x, y: shell.midY)).map { CGFloat($0) / 255 }
            let luminance = 0.2126 * pixel[0] + 0.7152 * pixel[1] + 0.0722 * pixel[2]
            XCTAssertGreaterThan(luminance, 0.85, "\(x): paper, not the title tray")
            XCTAssertGreaterThan(pixel[0], pixel[2], "\(x): the paper's warm tone")
        }
        editor.controller.canvasViewDidBeginUsingTool(canvas)
        editor.controller.canvasViewDidEndUsingTool(canvas)
        XCTAssertFalse(editor.store.areToolsHidden, "Strokes never hide the tools here.")

        editor.chrome.setMode(.pinned)
        XCTAssertEqual(editor.header.headerView.alpha, 1, "Pinned shows the header at once.")
        editor.controller.scrollViewWillBeginDragging(canvas)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: canvas.contentOffset.y + 120), animated: false)
        editor.controller.scrollViewDidEndDragging(canvas, willDecelerate: false)
        XCTAssertEqual(editor.header.headerView.transform, .identity, "Pinned never moves the header.")
        XCTAssertEqual(editor.header.headerView.alpha, 1)
    }

    // MARK: - Strokes, pins and reveals

    func testFocusHidesTheHeaderAndToolsWhenAStrokeEndsAndTheRevealTabBringsThemBack() async throws {
        let editor = try await mountEditor(width: 834)
        defer { editor.close() }
        let canvas = editor.controller.canvasView
        editor.controller.canvasViewDidBeginUsingTool(canvas)
        XCTAssertFalse(editor.store.areToolsHidden, "Nothing moves as a stroke starts.")
        XCTAssertEqual(editor.header.headerView.alpha, 1)
        editor.controller.canvasViewDidEndUsingTool(canvas)
        XCTAssertTrue(editor.store.areToolsHidden)
        XCTAssertEqual(editor.header.headerView.alpha, 0)
        XCTAssertFalse(editor.header.headerView.isUserInteractionEnabled)

        editor.store.revealTools()
        XCTAssertFalse(editor.store.areToolsHidden)
        XCTAssertEqual(editor.header.headerView.alpha, 1)
        XCTAssertEqual(editor.header.headerView.transform, .identity)

        // A reveal asked for during a stroke waits for the pen to lift, then stays.
        editor.controller.canvasViewDidBeginUsingTool(canvas)
        editor.controller.canvasViewDidEndUsingTool(canvas)
        editor.controller.canvasViewDidBeginUsingTool(canvas)
        editor.chrome.toggle()
        XCTAssertTrue(editor.store.areToolsHidden, "Nothing starts moving under the pen.")
        editor.controller.canvasViewDidEndUsingTool(canvas)
        XCTAssertFalse(editor.store.areToolsHidden)
        XCTAssertEqual(editor.header.headerView.alpha, 1)
    }

    func testAFailedSaveKeepsTheHeaderAndToolsInSight() async throws {
        let editor = try await mountEditor(width: 834)
        defer { editor.close() }
        let canvas = editor.controller.canvasView
        editor.controller.canvasViewDidBeginUsingTool(canvas)
        editor.controller.canvasViewDidEndUsingTool(canvas)
        XCTAssertTrue(editor.store.areToolsHidden)

        await editor.probe.setSaveFailure(.storageFull)
        let owner = try XCTUnwrap(editor.session.canvasOwnerID)
        editor.session.recordObservation(
            NotebookCanvasObservation(
                generation: 1, drawing: PKDrawing(strokes: [NotebookTestFixtures.stroke()]),
                capturedAt: Date(timeIntervalSince1970: 100), uptime: 10
            ), ownerID: owner
        )
        await editor.session.waitUntilSettled()
        try await NotebookTestFixtures.waitUntil { editor.chrome.state.pins.contains(.saveProblem) }
        XCTAssertFalse(editor.store.areToolsHidden)
        XCTAssertEqual(editor.header.headerView.alpha, 1)

        editor.controller.scrollViewWillBeginDragging(canvas)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: canvas.contentOffset.y + 150), animated: false)
        editor.controller.scrollViewDidEndDragging(canvas, willDecelerate: false)
        XCTAssertEqual(editor.header.headerView.transform, .identity, "A problem is never scrolled out of sight.")
        XCTAssertFalse(editor.store.areToolsHidden)
    }

    // MARK: - Keyboard and system overlays

    func testWritingViewShortcutsReachTheCanvasResponderChain() async throws {
        let editor = try await mountEditor(width: 834)
        defer { editor.close() }
        let commands = editor.controller.canvasView.notebookKeyCommands
        func command(_ input: String, _ modifiers: UIKeyModifierFlags) -> UIKeyCommand? {
            commands.first { $0.input == input && $0.modifierFlags == modifiers }
        }
        XCTAssertNotNil(command("t", [.command, .alternate]), "Option-Command-T: \(commands.map(\.input))")
        XCTAssertNotNil(command(UIKeyCommand.inputEscape, []), "Escape")
        for key in ["1", "2", "3"] {
            XCTAssertNotNil(command(key, [.command, .control]), "Control-Command-\(key)")
        }

        // Escape closes an open popover or sheet instead of asking for the chrome.
        let presentation = UUID()
        editor.chrome.setPresentation(presentation, isPresented: true)
        func hasEscape() -> Bool {
            editor.controller.canvasView.notebookKeyCommands.contains { $0.input == UIKeyCommand.inputEscape }
        }
        try await NotebookTestFixtures.waitUntil { !hasEscape() }
        editor.chrome.setPresentation(presentation, isPresented: false)
        try await NotebookTestFixtures.waitUntil { hasEscape() }

        let pinned = try XCTUnwrap(command("2", [.command, .control]))
        let action = try XCTUnwrap(pinned.action)
        UIApplication.shared.sendAction(action, to: nil, from: pinned, for: nil)
        try await NotebookTestFixtures.waitUntil { editor.chrome.mode == .pinned }
        XCTAssertEqual(editor.store.toolbar.chromeMode, .pinned)

        editor.chrome.setMode(.focus)
        editor.controller.canvasViewDidBeginUsingTool(editor.controller.canvasView)
        editor.controller.canvasViewDidEndUsingTool(editor.controller.canvasView)
        XCTAssertTrue(editor.store.areToolsHidden)
        let toggle = try XCTUnwrap(command("t", [.command, .alternate]))
        UIApplication.shared.sendAction(try XCTUnwrap(toggle.action), to: nil, from: toggle, for: nil)
        try await NotebookTestFixtures.waitUntil { !editor.store.areToolsHidden }
        XCTAssertEqual(editor.header.headerView.alpha, 1)

        editor.controller.canvasViewDidBeginUsingTool(editor.controller.canvasView)
        editor.controller.canvasViewDidEndUsingTool(editor.controller.canvasView)
        XCTAssertTrue(editor.store.areToolsHidden)
        let escape = try XCTUnwrap(
            editor.controller.canvasView.notebookKeyCommands.first { $0.input == UIKeyCommand.inputEscape }
        )
        UIApplication.shared.sendAction(try XCTUnwrap(escape.action), to: nil, from: escape, for: nil)
        try await NotebookTestFixtures.waitUntil { !editor.store.areToolsHidden }
        XCTAssertTrue(editor.chrome.state.showsHeader, "Escape brings the title back with the tools.")
    }

    func testFocusLetsTheHomeIndicatorHide() async throws {
        let editor = try await mountEditor(width: 834)
        defer { editor.close() }
        // UIKit asks the controller its children defer to.
        func prefersHidden() -> Bool {
            var controller: UIViewController = editor.hosting
            while let child = controller.childForHomeIndicatorAutoHidden { controller = child }
            return controller.prefersHomeIndicatorAutoHidden
        }
        try await NotebookTestFixtures.waitUntil(seconds: 3) { prefersHidden() }
        editor.chrome.setMode(.pinned)
        try await NotebookTestFixtures.waitUntil(seconds: 3) { !prefersHidden() }
    }

    // MARK: - Writing-view controller

    func testScrollingDownHidesAndScrollingUpRevealsAtTheStateThresholds() async throws {
        let hide = EditorChromeState.hideTravel
        let rig = try await NotebookChromeRig()
        rig.chrome.userScrollBegan(in: rig.scrollView)
        rig.scroll(by: hide - 1)
        XCTAssertTrue(rig.chrome.state.showsHeader)
        XCTAssertEqual(rig.header.transform.ty, -(hide - 1), accuracy: 0.01)
        rig.scroll(by: 1)
        XCTAssertFalse(rig.chrome.state.showsHeader)
        XCTAssertTrue(rig.store.areToolsHidden)
        XCTAssertEqual(rig.header.transform.ty, -hide, accuracy: 0.01)
        rig.scroll(by: -(EditorChromeState.revealTravel - 1))
        XCTAssertEqual(rig.header.transform.ty, -hide, accuracy: 0.01, "A hidden header never follows the page back.")
        rig.scroll(by: -1)
        XCTAssertTrue(rig.chrome.state.showsHeader)
        XCTAssertEqual(rig.header.transform, .identity)
        XCTAssertFalse(rig.store.areToolsHidden)

        // Stopping part-way settles back, and the next drag starts from nothing.
        rig.scroll(by: 20)
        XCTAssertEqual(rig.header.transform.ty, -20, accuracy: 0.01)
        rig.chrome.userScrollEnded()
        XCTAssertEqual(rig.header.transform, .identity)
        rig.drag(by: 10)
        XCTAssertEqual(rig.header.transform, .identity, "The earlier 20 pt settled back with the header.")
        XCTAssertTrue(rig.chrome.state.showsHeader)
        rig.drag(by: hide)
        XCTAssertEqual(rig.header.transform.ty, -NotebookWritingChrome.fullTravel, accuracy: 0.01)
        XCTAssertEqual(rig.header.alpha, 0)
    }

    /// A slow drag reverses by a point now and then. The header and the state count the same net
    /// distance, so a header that has left is never brought back when the drag ends.
    func testASlowDragsSmallReversalsKeepTheHeaderAndTheStateInAgreement() async throws {
        let rig = try await NotebookChromeRig()
        rig.chrome.userScrollBegan(in: rig.scrollView)
        var y = rig.scrollView.contentOffset.y
        var left = false
        for delta in [9, 9, 9, -1, 9, 9, 9, -1, 9, 9, 9] as [CGFloat] {
            y += delta
            rig.move(to: y)
            let state = rig.chrome.state
            if state.showsHeader {
                XCTAssertEqual(rig.header.transform.ty, -state.headerTravel, accuracy: 0.01, "\(y)")
            }
            if rig.header.alpha == 0 {
                XCTAssertFalse(state.showsHeader, "\(y): a header that has gone is hidden")
                left = true
            }
            XCTAssertFalse(left && rig.header.alpha > 0, "\(y): a header that has gone stays gone")
        }
        XCTAssertFalse(rig.chrome.state.showsHeader)
        XCTAssertTrue(rig.store.areToolsHidden, "Focus clears the tools for the read on.")
        rig.chrome.userScrollEnded()
        XCTAssertEqual(rig.header.transform.ty, -NotebookWritingChrome.fullTravel, accuracy: 0.01)
        XCTAssertEqual(rig.header.alpha, 0)
        XCTAssertFalse(rig.header.isUserInteractionEnabled)
        XCTAssertFalse(rig.chrome.state.showsHeader)
    }

    /// Pulling past the top and letting go bounces the page back down to its top. That is not
    /// reading on, so the header never moves.
    func testTheBounceBackFromPastTheTopNeverMovesTheHeader() async throws {
        let rig = try await NotebookChromeRig()
        let top = -rig.scrollView.contentInset.top
        rig.scrollView.contentOffset.y = top
        rig.chrome.userScrollBegan(in: rig.scrollView)
        for y in [top - 20, top - 40, top - 30, top - 20, top - 10, top] {
            rig.move(to: y)
            XCTAssertEqual(rig.header.transform, .identity, "\(y - top)")
            XCTAssertEqual(rig.header.alpha, 1)
        }
        rig.chrome.userScrollEnded()
        XCTAssertEqual(rig.header.transform, .identity)
        XCTAssertTrue(rig.chrome.state.showsHeader)
        XCTAssertFalse(rig.store.areToolsHidden)
    }

    func testSpringingBackFromPastTheLastPageRevealsNothing() async throws {
        let rig = try await NotebookChromeRig()
        rig.drag(by: 200)
        XCTAssertFalse(rig.chrome.state.showsHeader)
        let end = rig.scrollView.contentSize.height - rig.scrollView.bounds.height + rig.scrollView.contentInset.bottom
        rig.chrome.userScrollBegan(in: rig.scrollView)
        rig.move(to: end)
        for overshoot in [40, 80, 40, 0] as [CGFloat] { rig.move(to: end + overshoot) }
        rig.chrome.userScrollEnded()
        XCTAssertFalse(rig.chrome.state.showsHeader, "The spring back past the end is not an upward scroll.")
        XCTAssertTrue(rig.store.areToolsHidden)
    }

    func testArrivingAtTheTopOrTappingTheStatusBarRevealsTheHeader() async throws {
        let rig = try await NotebookChromeRig()
        rig.drag(by: 200)
        XCTAssertFalse(rig.chrome.state.showsHeader)
        rig.scrollView.contentOffset.y = -rig.scrollView.contentInset.top
        rig.chrome.scrolledToTop()
        XCTAssertTrue(rig.chrome.state.showsHeader)
        XCTAssertEqual(rig.header.alpha, 1)

        rig.drag(by: 200)
        rig.chrome.userScrollBegan(in: rig.scrollView)
        rig.move(to: -rig.scrollView.contentInset.top - 30)
        XCTAssertTrue(rig.chrome.state.showsHeader, "Pulling past the top reveals as any arrival there.")
    }

    /// The header fades out after 28 pt down and back in after 28 pt up, without moving.
    func testReduceMotionFadesTheHeaderWithoutMovingIt() async throws {
        let rig = try await NotebookChromeRig(reduceMotion: true)
        rig.chrome.userScrollBegan(in: rig.scrollView)
        rig.scroll(by: 27)
        XCTAssertEqual(rig.header.transform, .identity)
        XCTAssertEqual(rig.header.alpha, 1, "Under Reduce Motion the header does not follow.")
        XCTAssertTrue(rig.header.isUserInteractionEnabled)
        rig.scroll(by: 1)
        XCTAssertEqual(rig.header.transform, .identity)
        XCTAssertEqual(rig.header.alpha, 0, "28 pt down fades it out.")
        XCTAssertFalse(rig.header.isUserInteractionEnabled)
        rig.chrome.userScrollEnded()
        XCTAssertEqual(rig.header.alpha, 0)

        rig.chrome.userScrollBegan(in: rig.scrollView)
        rig.scroll(by: -27)
        XCTAssertEqual(rig.header.alpha, 0)
        rig.scroll(by: -1)
        XCTAssertEqual(rig.header.transform, .identity)
        XCTAssertEqual(rig.header.alpha, 1, "28 pt up fades it back in.")
        XCTAssertTrue(rig.header.isUserInteractionEnabled)
        rig.chrome.userScrollEnded()
    }

    func testEveryPinKeepsTheHeaderAndToolsInSight() async throws {
        let rig = try await NotebookChromeRig()
        let id = UUID()
        rig.chrome.setPresentation(id, isPresented: true)
        XCTAssertTrue(rig.chrome.isPresenting)
        rig.drag(by: 200)
        XCTAssertEqual(rig.header.transform, .identity)
        XCTAssertFalse(rig.store.areToolsHidden)
        rig.chrome.setPresentation(id, isPresented: false)
        XCTAssertFalse(rig.chrome.isPresenting)

        // The toolbar's own popovers and sheets report through the store.
        let panel = UUID()
        rig.store.setToolbarPresentation(panel, isPresented: true)
        XCTAssertTrue(rig.chrome.isPresenting)
        XCTAssertTrue(rig.chrome.state.pins.contains(.presentation))
        rig.store.setToolbarPresentation(panel, isPresented: false)
        XCTAssertFalse(rig.chrome.isPresenting)

        rig.store.setToolbarDragging(true)
        XCTAssertTrue(rig.chrome.state.pins.contains(.dragging))
        rig.chrome.toolBegan()
        rig.chrome.toolEnded()
        XCTAssertFalse(rig.store.areToolsHidden, "A dragged toolbar never hides under the finger.")
        rig.store.setToolbarDragging(false)
        XCTAssertTrue(rig.store.areToolsHidden, "Requests made under the pin take effect once it clears.")

        rig.gate.update(pageCount: 3, inputGate: .readOnly)
        try await NotebookTestFixtures.waitUntil { rig.chrome.state.pins.contains(.inputPaused) }
        XCTAssertFalse(rig.store.areToolsHidden)
        XCTAssertEqual(rig.header.alpha, 1)

        let assisted = try await NotebookChromeRig(assistiveTechnology: true)
        XCTAssertEqual(assisted.chrome.state.pins, [.assistiveTechnology])
        assisted.drag(by: 200)
        XCTAssertEqual(assisted.header.alpha, 1)
    }

    /// Saves catching up pause writing, usually for a moment. A brief pause never brings the
    /// header and tools over the page; one that lasts does, until writing resumes.
    func testSavesCatchingUpPinTheChromeOnlyOnceThePauseLasts() async throws {
        let rig = try await NotebookChromeRig()
        rig.chrome.toolBegan()
        rig.chrome.toolEnded()
        XCTAssertTrue(rig.store.areToolsHidden)
        var shown = 0
        let watch = rig.store.$areToolsHidden.dropFirst().sink { if !$0 { shown += 1 } }
        defer { watch.cancel() }

        rig.gate.update(pageCount: 3, inputGate: .capacity)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertFalse(rig.chrome.state.pins.contains(.inputPaused), "The pause has only begun.")
        rig.gate.update(pageCount: 3, inputGate: .open)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(rig.chrome.state.pins.isEmpty)
        XCTAssertEqual(shown, 0, "A brief pause never flashes the tools.")
        XCTAssertEqual(rig.header.alpha, 0)

        rig.gate.update(pageCount: 3, inputGate: .capacity)
        try await NotebookTestFixtures.waitUntil { rig.chrome.state.pins.contains(.inputPaused) }
        XCTAssertFalse(rig.store.areToolsHidden, "A lasting pause shows why writing stopped.")
        XCTAssertEqual(rig.header.alpha, 1)
        rig.gate.update(pageCount: 3, inputGate: .open)
        try await NotebookTestFixtures.waitUntil { rig.chrome.state.pins.isEmpty }
        XCTAssertTrue(rig.store.areToolsHidden, "Writing resumed, the page is clear again.")
        XCTAssertEqual(NotebookWritingChrome.catchUpPinDelay, .seconds(1))
    }

    func testAPencilToolSwitchShowsTheToolsBriefly() async throws {
        let rig = try await NotebookChromeRig()
        rig.chrome.toolBegan()
        rig.chrome.toolEnded()
        XCTAssertTrue(rig.store.areToolsHidden)
        rig.chrome.reveal(.transient)
        XCTAssertFalse(rig.store.areToolsHidden, "The new tool shows.")
        XCTAssertEqual(rig.header.alpha, 0, "The header stays away.")
        try await NotebookTestFixtures.waitUntil { rig.store.areToolsHidden }

        rig.chrome.reveal(.sticky)
        XCTAssertFalse(rig.store.areToolsHidden)
        XCTAssertEqual(rig.header.alpha, 1)
    }

    /// A canvas that disappears or is torn down mid-stroke never reports the stroke's end; the
    /// screen's canvas tells the writing view it was cancelled.
    func testACanvasLeavingMidStrokeLetsScrollingCountAgain() async throws {
        let editor = try await mountEditor(width: 834)
        defer { editor.close() }
        let canvas = editor.controller.canvasView
        editor.controller.canvasViewDidBeginUsingTool(canvas)
        let interrupted = try XCTUnwrap(editor.controller.onInteractionInterrupted)
        interrupted()
        editor.controller.scrollViewWillBeginDragging(canvas)
        for step in 1...20 {
            canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: CGFloat(step) * 5), animated: false)
        }
        editor.controller.scrollViewDidEndDragging(canvas, willDecelerate: false)
        XCTAssertFalse(editor.chrome.state.showsHeader, "Scrolling counts again once the stroke is cancelled.")
        XCTAssertEqual(editor.header.headerView.alpha, 0)
    }

    /// The scene's store follows the writing view of the notebook shown last. An older notebook's,
    /// which can outlive its screen, leaves the tools alone until its notebook is shown again.
    func testAnOlderNotebooksWritingViewLeavesTheToolsAlone() async throws {
        let store = NotebookTestFixtures.toolStore()
        let older = try await NotebookChromeRig(store: store)
        let current = try await NotebookChromeRig(store: store)
        XCTAssertTrue(store.isWritingChrome(current.chrome))
        XCTAssertFalse(store.isWritingChrome(older.chrome))
        current.chrome.toolBegan()
        current.chrome.toolEnded()
        XCTAssertTrue(store.areToolsHidden)

        older.gate.update(pageCount: 3, inputGate: .failed)
        try await NotebookTestFixtures.waitUntil { older.chrome.state.pins.contains(.inputPaused) }
        older.chrome.reveal(.sticky)
        older.drag(by: -100)
        XCTAssertTrue(store.areToolsHidden, "The older notebook's problem and requests stay with it.")

        store.revealTools()
        XCTAssertTrue(current.chrome.state.showsHeader, "The reveal tab reaches the notebook shown.")
        XCTAssertFalse(store.areToolsHidden)
        current.chrome.toolBegan()
        current.chrome.toolEnded()
        XCTAssertTrue(store.areToolsHidden)

        older.chrome.attach(to: store)
        try await NotebookTestFixtures.waitUntil { store.isWritingChrome(older.chrome) }
        XCTAssertFalse(store.areToolsHidden, "Shown again, its failed state keeps the tools in sight.")
    }

    /// Only focus in the header or toolbar keeps them in sight; a key on the page does not.
    func testFocusOnThePageLeavesTheWritingViewFree() {
        let controller = NotebookViewController(pageCount: 1, initialDrawing: PKDrawing(), allowsEditing: false)
        defer { controller.tearDown() }
        controller.loadViewIfNeeded()
        let pageKey = UIButton()
        controller.view.addSubview(pageKey)
        XCTAssertTrue(NotebookWritingChrome.isOnPage(pageKey))
        XCTAssertTrue(NotebookWritingChrome.isOnPage(controller.canvasView))
        let header = UIView()
        let headerKey = UIButton()
        header.addSubview(headerKey)
        XCTAssertFalse(NotebookWritingChrome.isOnPage(headerKey))
    }

    func testAStrokeCutShortLetsScrollingCountAgain() async throws {
        let rig = try await NotebookChromeRig()
        rig.chrome.toolBegan()
        rig.drag(by: 100)
        XCTAssertTrue(rig.chrome.state.showsHeader, "The header holds still under the pen.")
        XCTAssertEqual(rig.header.transform, .identity)
        rig.chrome.toolCancelled()
        XCTAssertTrue(rig.chrome.state.showsHeader, "A stroke that never ended hides nothing.")
        rig.drag(by: 100)
        XCTAssertFalse(rig.chrome.state.showsHeader)
    }

    /// The stored writing view reaches the chrome a turn after it changes. A newer choice made in
    /// between is never undone by the older value arriving late.
    func testALateStoredModeNeverUndoesANewerChoice() async throws {
        let rig = try await NotebookChromeRig()
        var other = rig.store.toolbar
        other.setChromeMode(.pinned)
        rig.store.updateToolbar(other)
        rig.chrome.setMode(.overlay)
        rig.drag(by: 100)
        XCTAssertFalse(rig.chrome.state.showsHeader)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(rig.chrome.mode, .overlay)
        XCTAssertFalse(rig.chrome.state.showsHeader, "The header stays away.")
        XCTAssertEqual(rig.header.alpha, 0)
    }

    func testTheWritingViewIsStoredWithTheToolbarPreferences() async throws {
        let suite = NotebookTestFixtures.temporaryDefaultsSuite()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = NotebookSceneToolStore(identifier: suite, defaults: defaults)
        let rig = try await NotebookChromeRig(store: store)
        XCTAssertEqual(rig.chrome.mode, .focus, "A missing mode means Focus.")
        rig.chrome.setMode(.pinned)
        XCTAssertEqual(rig.chrome.mode, .pinned)
        XCTAssertEqual(store.toolbar.chromeMode, .pinned)
        let stored = EditorToolbarPreferences.decode(defaults.data(forKey: NotebookSceneToolStore.toolbarDefaultsKey))
        XCTAssertEqual(stored.chromeMode, .pinned)
        XCTAssertEqual(stored.placement, store.toolbar.placement, "The mode travels with the rest of the toolbar.")

        let reopened = try await NotebookChromeRig(store: NotebookSceneToolStore(identifier: suite, defaults: defaults))
        XCTAssertEqual(reopened.chrome.mode, .pinned)

        // Moving the toolbar, which stores a copy of the preferences, keeps the mode.
        var moved = store.toolbar
        moved.place(.docked(.topLeading))
        store.updateToolbar(moved)
        XCTAssertEqual(store.toolbar.chromeMode, .pinned)
        XCTAssertEqual(rig.chrome.mode, .pinned)
    }

    // MARK: - Notebook menu

    /// At the popover's width every description keeps to one line, so each row is 52 pt tall.
    func testWritingViewRowsKeepTheirDescriptionsToOneLine() throws {
        let width = NotebookTheme.popoverWidth - 2 * NotebookTheme.popoverPadding
        for mode in EditorChromeMode.allCases {
            for selected in [false, true] {
                let pixels = try RenderedPixels(rendering:
                    NotebookWritingViewRow(mode: mode, isSelected: selected) {}.frame(width: width)
                )
                XCTAssertEqual(pixels.size.height, NotebookTheme.writingViewRowHeight, accuracy: 0.5, "\(mode)")
            }
        }
    }

    /// Every piece of text in the selected writing view row darkens, so it keeps its contrast on the well.
    func testTheSelectedWritingViewRowDarkensAllItsText() throws {
        func hintTone(selected: Bool) throws -> CGFloat {
            let width = NotebookTheme.popoverWidth - 2 * NotebookTheme.popoverPadding
            let pixels = try RenderedPixels(rendering:
                NotebookWritingViewRow(mode: .pinned, isSelected: selected) {}.frame(width: width)
            )
            var darkest: CGFloat = 1
            let hint = (width - NotebookTheme.menuRowInset - 30)..<(width - NotebookTheme.menuRowInset)
            for y in stride(from: 0, to: pixels.size.height, by: 0.5) {
                for x in stride(from: hint.lowerBound, to: hint.upperBound, by: 0.5) {
                    let pixel = pixels.rgba(at: CGPoint(x: x, y: y)).map { CGFloat($0) / 255 }
                    guard pixel[3] == 1 else { continue }
                    darkest = min(darkest, 0.2126 * pixel[0] + 0.7152 * pixel[1] + 0.0722 * pixel[2])
                }
            }
            return darkest
        }
        func luminance(_ tone: NotebookTheme.Tone) -> CGFloat {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
            tone.uiColor.getRed(&red, green: &green, blue: &blue, alpha: nil)
            return 0.2126 * red + 0.7152 * green + 0.0722 * blue
        }
        XCTAssertEqual(try hintTone(selected: false), luminance(NotebookTheme.glyphSecondary), accuracy: 0.03)
        XCTAssertEqual(try hintTone(selected: true), luminance(NotebookTheme.glyph), accuracy: 0.03)
    }

    /// The hint sits at the row's trailing edge, centred on the row, and every glyph centres in its
    /// column, clear of the selected row's mark.
    func testWritingViewRowsPlaceTheirGlyphAndHintAsSpecified() throws {
        let width = NotebookTheme.popoverWidth - 2 * NotebookTheme.popoverPadding
        for mode in EditorChromeMode.allCases {
            let pixels = try RenderedPixels(rendering:
                NotebookWritingViewRow(mode: mode, isSelected: false) {}.frame(width: width)
            )
            func inked(_ xs: Range<CGFloat>) -> [CGPoint] {
                var points: [CGPoint] = []
                for y in stride(from: 0, to: pixels.size.height, by: 0.5) {
                    for x in stride(from: xs.lowerBound, to: xs.upperBound, by: 0.5) {
                        if pixels.rgba(at: CGPoint(x: x, y: y))[3] > 128 { points.append(CGPoint(x: x, y: y)) }
                    }
                }
                return points
            }
            // Glyphs centre in a 20 pt column; even the broadest keeps 4 pt clear of the mark.
            let glyph = inked(0..<(NotebookTheme.menuGlyphInset + NotebookTheme.menuGlyphColumnWidth + 6))
            let glyphStart = try XCTUnwrap(glyph.map(\.x).min(), "\(mode)")
            let glyphEnd = try XCTUnwrap(glyph.map(\.x).max(), "\(mode)")
            XCTAssertGreaterThanOrEqual(glyphStart,
                NotebookTheme.selectionMarkInset + NotebookTheme.rowMarkSize.width + 4, "\(mode): clear of the mark")
            XCTAssertEqual((glyphStart + glyphEnd + 0.5) / 2,
                NotebookTheme.menuGlyphInset + NotebookTheme.menuGlyphColumnWidth / 2, accuracy: 1.5, "\(mode)")

            let hint = inked((width - NotebookTheme.menuRowInset - 32)..<(width - NotebookTheme.menuRowInset))
            let top = try XCTUnwrap(hint.map(\.y).min(), "\(mode)")
            let bottom = try XCTUnwrap(hint.map(\.y).max(), "\(mode)")
            XCTAssertEqual((top + bottom) / 2, pixels.size.height / 2, accuracy: 2, "\(mode): the hint is centred")
            let hintEnd = try XCTUnwrap(hint.map(\.x).max())
            // The digit's ink stops a little short of its advance.
            XCTAssertEqual(hintEnd, width - NotebookTheme.menuRowInset, accuracy: 3.5, "\(mode): at the trailing edge")
        }
    }

    /// The disclosure chevron of "Coming later" is drawn in the secondary glyph tone, like the rest
    /// of the row, not in black.
    func testComingLaterDrawsItsChevronInTheSecondaryTone() throws {
        let width = NotebookTheme.popoverWidth - 2 * NotebookTheme.popoverPadding
        let pixels = try RenderedPixels(rendering:
            NotebookComingLater(isExpanded: .constant(false)).frame(width: width)
        )
        var darkest: (luminance: CGFloat, rgb: [CGFloat])?
        for y in stride(from: 0, to: min(pixels.size.height, NotebookTheme.menuRowHeight), by: 0.5) {
            for x in stride(from: width - NotebookTheme.menuRowInset - 24, to: width, by: 0.5) {
                let pixel = pixels.rgba(at: CGPoint(x: x, y: y)).map { CGFloat($0) / 255 }
                guard pixel[3] == 1 else { continue }
                let luminance = 0.2126 * pixel[0] + 0.7152 * pixel[1] + 0.0722 * pixel[2]
                if luminance < darkest?.luminance ?? 2 { darkest = (luminance, Array(pixel.prefix(3))) }
            }
        }
        let chevron = try XCTUnwrap(darkest, "The chevron is drawn at the row's trailing end.")
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        NotebookTheme.glyphSecondary.uiColor.getRed(&red, green: &green, blue: &blue, alpha: nil)
        for (drawn, expected) in zip(chevron.rgb, [red, green, blue]) {
            XCTAssertEqual(drawn, expected, accuracy: 0.03, "\(chevron.rgb)")
        }
    }

    /// A header too narrow for Redo hands it to the menu, which then lists it first among the
    /// notebook's actions.
    func testTheMenuOffersRedoOnlyWhenTheHeaderCannotShowIt() throws {
        let session = NotebookSession()
        let width = NotebookTheme.popoverWidth - 2 * NotebookTheme.popoverPadding
        func height(offeringRedo offersRedo: Bool) throws -> CGFloat {
            try RenderedPixels(rendering:
                NotebookMenuActions(
                    session: session, gate: session.gateModel, commands: session.commandModel,
                    offersRedo: offersRedo, addPage: {}, openRecoveryCopies: {}
                )
                .frame(width: width)
            ).size.height
        }
        XCTAssertEqual(try height(offeringRedo: false), 2 * NotebookTheme.menuRowHeight + NotebookTheme.itemSpacing,
            accuracy: 0.5)
        XCTAssertEqual(try height(offeringRedo: true) - height(offeringRedo: false),
            NotebookTheme.menuRowHeight + NotebookTheme.itemSpacing, accuracy: 0.5)
    }

    // MARK: - Fixtures

    /// The notebook screen in its own window on the host's scene, using the scene's store.
    @MainActor
    private struct MountedEditor {
        let hosting: AppearanceTrackingHostingController<NotebookScreen>
        let window: UIWindow
        let session: NotebookSession
        let probe: NotebookStorageProbe
        let store: NotebookSceneToolStore
        let controller: NotebookViewController
        let header: NotebookHeaderHostController

        var chrome: NotebookWritingChrome { session.writingChrome }

        func frameInWindow(_ view: UIView) -> CGRect {
            view.convert(view.bounds, to: window)
        }

        var shellFrame: CGRect {
            let host = frameInWindow(header.view)
            return NotebookHeaderHostController.shellFrame(in: header.view.bounds).offsetBy(dx: host.minX, dy: host.minY)
        }

        func renderedPixels() throws -> RenderedPixels {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            return try RenderedPixels(try XCTUnwrap(image.cgImage), scale: image.scale)
        }

        /// Where the accent key's periwinkle face spans across the header's middle; the shell, the
        /// tray and every other key are warm greys.
        func accentKeySpan(in pixels: RenderedPixels) -> ClosedRange<CGFloat>? {
            let y = shellFrame.midY - NotebookTheme.accentKeySize.height / 4
            let accent = stride(from: shellFrame.minX, to: shellFrame.maxX, by: 0.5).filter { x in
                let pixel = pixels.rgba(at: CGPoint(x: x, y: y)).map { CGFloat($0) / 255 }
                return pixel[2] - pixel[0] > 0.2
            }
            guard let first = accent.first, let last = accent.last else { return nil }
            return first...(last + 0.5)
        }

        /// The tray's drawn edges: the longest run across the header's middle that is darker than
        /// the shell. The title and readouts inside it are darker still; the gap before the
        /// nameplate and the space before Undo are shell.
        func trayEdges(in rendered: RenderedPixels? = nil) throws -> (minX: CGFloat, width: CGFloat) {
            let pixels = try rendered ?? renderedPixels()
            let y = shellFrame.midY
            func luminance(_ x: CGFloat) -> CGFloat {
                let pixel = pixels.rgba(at: CGPoint(x: x, y: y)).map { CGFloat($0) / 255 }
                return 0.2126 * pixel[0] + 0.7152 * pixel[1] + 0.0722 * pixel[2]
            }
            let shell = luminance(shellFrame.minX + 4)
            var best = (start: CGFloat(0), end: CGFloat(0))
            var start: CGFloat?
            for x in stride(from: shellFrame.minX, through: shellFrame.maxX, by: 0.5) {
                if luminance(x) < shell - 0.04, x < shellFrame.maxX {
                    if start == nil { start = x }
                } else if let runStart = start {
                    if x - runStart > best.end - best.start { best = (runStart, x) }
                    start = nil
                }
            }
            return (best.start, best.end - best.start)
        }

        func close() {
            session.flush()
            store.setToolsHidden(false)
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    /// - Parameters:
    ///   - height: the window height; the host screen's when nil.
    ///   - sizeClass: the horizontal size class to impose, as Split View and Slide Over do.
    private func mountEditor(
        width: CGFloat, height: CGFloat? = nil, sizeClass: UIUserInterfaceSizeClass? = nil
    ) async throws -> MountedEditor {
        let id = UUID()
        let root = NotebookTestFixtures.root()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let probe = try NotebookStorageProbe(stored: try await NotebookTestFixtures.stored(id: id), recoveryRoot: root)
        let storage = await probe.storage(notebookID: id)
        let session = NotebookSession(notebookID: id, openStorage: { storage })
        let scene = try NotebookTestFixtures.windowScene()
        NotebookTestFixtures.restoreSceneToolDefaults(for: scene, after: self)
        let store = NotebookSceneToolStore.owner(for: scene)
        let tool = store.tool
        let toolbar = store.toolbar
        // Teardown blocks run last-registered first, so the stored keys are restored after these writes.
        addTeardownBlock { @MainActor in
            store.update { $0 = tool }
            store.updateToolbar(toolbar)
            store.setToolsHidden(false)
        }
        store.updateToolbar(.standard)
        let previousKeyWindow = scene.keyWindow
        addTeardownBlock { @MainActor in previousKeyWindow?.makeKey() }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(
            x: 0, y: 0, width: width, height: height ?? scene.effectiveGeometry.coordinateSpace.bounds.height
        )
        let hosting = AppearanceTrackingHostingController(rootView: NotebookScreen(session: session))
        if let sizeClass { hosting.traitOverrides.horizontalSizeClass = sizeClass }
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        do {
            try await NotebookTestFixtures.waitUntilAppeared(hosting)
            var controller: NotebookViewController?
            var header: NotebookHeaderHostController?
            try await NotebookTestFixtures.waitUntil {
                controller = NotebookTestFixtures.notebookController(in: hosting)
                header = Self.headerHost(in: hosting)
                return controller?.isCanvasVisible == true && store.isToolbarAvailable
                    && session.writingChrome.store === store && session.writingChrome.state.pins.isEmpty
                    && header?.headerView.bounds.width ?? 0 > 0 && store.overlayObstruction.top > 0
            }
            hosting.view.layoutIfNeeded()
            // Tests move the page with programmatic offsets between the drag callbacks.
            session.writingChrome.scrollIsUserDriven = { _ in true }
            return MountedEditor(
                hosting: hosting, window: window, session: session, probe: probe, store: store,
                controller: try XCTUnwrap(controller), header: try XCTUnwrap(header)
            )
        } catch {
            session.flush()
            window.isHidden = true
            window.rootViewController = nil
            throw error
        }
    }

    static func headerHost(in controller: UIViewController) -> NotebookHeaderHostController? {
        if let header = controller as? NotebookHeaderHostController { return header }
        return controller.children.lazy.compactMap { headerHost(in: $0) }.first
    }
}

extension UIResponder {
    /// The key commands of this responder and those after it, short of the application, whose own
    /// Escape command unlocks a locked pointer and is not the editor's.
    var notebookKeyCommands: [UIKeyCommand] {
        var commands: [UIKeyCommand] = []
        var responder: UIResponder? = self
        while let current = responder, !(current is UIApplication) {
            commands += current.keyCommands ?? []
            responder = current.next
        }
        return commands
    }
}

/// A writing-view controller driven by a plain scroll view, with models open for writing.
@MainActor
struct NotebookChromeRig {
    let chrome: NotebookWritingChrome
    let gate = NotebookCanvasGateModel()
    let saves = NotebookSavePresentationModel()
    let integrity = NotebookIntegrityPresentationModel()
    let store: NotebookSceneToolStore
    let header = UIView(frame: CGRect(x: 0, y: 0, width: 810, height: 84))
    let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 834, height: 1_000))

    init(
        store: NotebookSceneToolStore = NotebookTestFixtures.toolStore(), reduceMotion: Bool = false,
        assistiveTechnology: Bool = false
    ) async throws {
        self.store = store
        gate.update(pageCount: 3, inputGate: .open)
        saves.update(NotebookSavePresentation(
            status: .idle, inputPaused: false, performingRecovery: false, canPreserveRecovery: false,
            canReopenSaved: false, recoveryMessage: nil, recoveryFailure: nil
        ))
        chrome = NotebookWritingChrome(
            gate: gate, saves: saves, integrity: integrity,
            prefersReducedMotion: { reduceMotion }, assistiveTechnologyRunning: { assistiveTechnology },
            delay: { _ in try await Task.sleep(for: .milliseconds(50)) }
        )
        chrome.attachHeader(header)
        // A plain scroll view reports no touches, so its programmatic offsets stand in for a drag.
        chrome.scrollIsUserDriven = { _ in true }
        chrome.attach(to: store)
        let chrome = chrome
        try await NotebookTestFixtures.waitUntil { chrome.store === store }
        scrollView.contentSize = CGSize(width: 834, height: 5_000)
        scrollView.contentInset = UIEdgeInsets(top: 160, left: 0, bottom: 40, right: 0)
        scrollView.contentOffset = CGPoint(x: 0, y: 300)
    }

    /// A whole user drag by `distance`.
    func drag(by distance: CGFloat) {
        chrome.userScrollBegan(in: scrollView)
        scroll(by: distance)
        chrome.userScrollEnded()
    }

    /// Moves a drag in progress by `distance`, in small steps.
    func scroll(by distance: CGFloat) {
        let steps = max(Int(abs(distance) / 4), 1)
        let start = scrollView.contentOffset.y
        for step in 1...steps {
            move(to: start + distance * CGFloat(step) / CGFloat(steps))
        }
    }

    func move(to y: CGFloat) {
        scrollView.contentOffset.y = y
        chrome.userScrollMoved(in: scrollView)
    }
}
