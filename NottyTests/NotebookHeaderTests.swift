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

    /// The space the canvas keeps can change while the user drags or the page decelerates: the
    /// toolbar is measured again, or the window resizes. Those inset and offset writes are layout,
    /// not scrolling. They can arrive inside a SwiftUI update, so they publish nothing; the header
    /// and tools hold still; and the next step of the scroll counts only its own distance.
    func testLayoutChangesMidScrollNeitherMoveTheChromeNorCountAsTravel() async throws {
        let editor = try await mountEditor(width: 834)
        defer { editor.close() }
        let canvas = editor.controller.canvasView
        let header = editor.header.headerView
        var changes = 0
        let chromeWatch = editor.chrome.objectWillChange.sink { changes += 1 }
        let storeWatch = editor.store.objectWillChange.sink { changes += 1 }
        defer {
            chromeWatch.cancel()
            storeWatch.cancel()
        }

        editor.controller.scrollViewWillBeginDragging(canvas)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: 10), animated: false)
        XCTAssertEqual(header.transform.ty, -10, accuracy: 0.01)

        let obstruction = editor.store.overlayObstruction
        let insets = canvas.contentInset
        editor.store.setOverlayObstruction(UIEdgeInsets(top: obstruction.top + 40, left: 0, bottom: 0, right: 0))
        XCTAssertEqual(canvas.contentInset.top, insets.top + 40, accuracy: 0.5)
        XCTAssertEqual(header.transform.ty, -10, accuracy: 0.01, "Mid-drag, more reserved space moves nothing.")
        editor.controller.scrollViewDidEndDragging(canvas, willDecelerate: true)
        editor.store.setOverlayObstruction(obstruction)
        XCTAssertEqual(canvas.contentInset, insets)
        XCTAssertEqual(header.transform.ty, -10, accuracy: 0.01, "Mid-deceleration, less reserved space moves nothing.")

        // A canvas resized mid-deceleration keeps its page centre, which moves the page by layout.
        let view = try XCTUnwrap(editor.controller.view)
        for widthChange in [-34, 34] as [CGFloat] {
            let offset = canvas.contentOffset.y
            let travel = header.transform.ty
            view.frame.size.width += widthChange
            view.layoutIfNeeded()
            XCTAssertGreaterThan(abs(canvas.contentOffset.y - offset), 10, "The resize moved the page.")
            XCTAssertEqual(header.transform.ty, travel, accuracy: 0.01, "Layout never moves the header.")
            canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: canvas.contentOffset.y + 2), animated: false)
            XCTAssertEqual(header.transform.ty, travel - 2, accuracy: 0.01,
                "Only the user's own 2 pt count; the jump is not travel.")
        }
        XCTAssertFalse(editor.store.areToolsHidden)
        XCTAssertEqual(changes, 0, "Layout publishes nothing.")
        editor.controller.scrollViewDidEndDecelerating(canvas)
        XCTAssertEqual(header.transform, .identity)
    }

    /// Releasing reserved space at the end of the notebook pulls the page back into range. The
    /// pull is layout, not the user scrolling up, so mid-drag it brings back neither the header
    /// nor the tools and publishes nothing, and the drag carries on from the page's new offset.
    func testReleasedSpaceThatPullsThePageBackMidDragNeitherRevealsNorPublishes() async throws {
        let editor = try await mountEditor(width: 834)
        defer { editor.close() }
        let canvas = editor.controller.canvasView
        let header = editor.header.headerView
        let obstruction = editor.store.overlayObstruction
        let released: CGFloat = 300
        editor.store.setOverlayObstruction(UIEdgeInsets(top: obstruction.top, left: 0, bottom: released, right: 0))
        let end = canvas.contentSize.height - canvas.bounds.height + canvas.contentInset.bottom
        editor.controller.scrollViewWillBeginDragging(canvas)
        var y = canvas.contentOffset.y
        while y < end {
            y = min(y + 20, end)
            canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: y), animated: false)
        }
        XCTAssertTrue(editor.store.areToolsHidden, "Reading on hid the tools.")
        XCTAssertEqual(header.transform.ty, -NotebookWritingChrome.fullTravel, accuracy: 0.01)
        var changes = 0
        let chromeWatch = editor.chrome.objectWillChange.sink { changes += 1 }
        let storeWatch = editor.store.objectWillChange.sink { changes += 1 }
        defer {
            chromeWatch.cancel()
            storeWatch.cancel()
        }

        let reading = canvas.contentOffset.y
        editor.store.setOverlayObstruction(obstruction)
        XCTAssertEqual(canvas.contentOffset.y, reading - released, accuracy: 1, "The release pulled the page back.")
        XCTAssertTrue(editor.store.areToolsHidden, "The pull is not an upward scroll.")
        XCTAssertEqual(header.transform.ty, -NotebookWritingChrome.fullTravel, accuracy: 0.01)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: canvas.contentOffset.y - 2), animated: false)
        XCTAssertTrue(editor.store.areToolsHidden, "Only the user's own 2 pt up count.")
        XCTAssertEqual(header.transform.ty, -NotebookWritingChrome.fullTravel, accuracy: 0.01)
        XCTAssertEqual(changes, 0, "Layout publishes nothing.")
        editor.controller.scrollViewDidEndDragging(canvas, willDecelerate: false)
    }

    /// The same release made by the toolbar itself: docking a toolbar that floated at the bottom
    /// frees its space while SwiftUI updates, where the writing view must not publish.
    func testDockingABottomToolbarMidDragNeitherRevealsNorPublishes() async throws {
        let editor = try await mountEditor(width: 834)
        defer { editor.close() }
        let canvas = editor.controller.canvasView
        let header = editor.header.headerView
        var preferences = editor.store.toolbar
        let docked = preferences.placement
        preferences.place(.floating(CGPoint(x: 0.5, y: 1)))
        editor.store.updateToolbar(preferences)
        try await NotebookTestFixtures.waitUntil { editor.store.overlayObstruction.bottom > 0 }
        let released = editor.store.overlayObstruction.bottom
        let end = canvas.contentSize.height - canvas.bounds.height + canvas.contentInset.bottom
        editor.controller.scrollViewWillBeginDragging(canvas)
        var y = canvas.contentOffset.y
        while y < end {
            y = min(y + 20, end)
            canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: y), animated: false)
        }
        XCTAssertTrue(editor.store.areToolsHidden, "Reading on hid the tools.")
        var changes = 0
        let chromeWatch = editor.chrome.objectWillChange.sink { changes += 1 }
        // The toolbar's own preferences publish; only the tools' visibility must not.
        let toolsWatch = editor.store.$areToolsHidden.dropFirst().sink { _ in changes += 1 }
        defer {
            chromeWatch.cancel()
            toolsWatch.cancel()
        }

        let reading = canvas.contentOffset.y
        preferences.place(docked)
        editor.store.updateToolbar(preferences)
        try await NotebookTestFixtures.waitUntil { editor.store.overlayObstruction.bottom == 0 }
        XCTAssertEqual(canvas.contentOffset.y, reading - released, accuracy: 1, "Docking pulled the page back.")
        XCTAssertTrue(editor.store.areToolsHidden)
        XCTAssertEqual(header.transform.ty, -NotebookWritingChrome.fullTravel, accuracy: 0.01)
        XCTAssertEqual(changes, 0, "Layout publishes nothing.")
        editor.controller.scrollViewDidEndDragging(canvas, willDecelerate: false)
    }

    /// Stopping a fling with a tap reports neither a drag nor the end of the deceleration. The
    /// last finger leaving the page ends the scroll, so a header left part-way settles and takes
    /// touches again.
    func testATapThatStopsAFlingSettlesAHeaderLeftPartWay() async throws {
        let editor = try await mountEditor(width: 834)
        defer { editor.close() }
        let canvas = editor.controller.canvasView
        let header = editor.header.headerView
        let observer = editor.controller.fingerLiftObserver
        XCTAssertTrue(canvas.gestureRecognizers?.contains(observer) ?? false)
        XCTAssertEqual(observer.allowedTouchTypes, [NSNumber(value: UITouch.TouchType.direct.rawValue)],
            "Apple Pencil never reaches it.")
        XCTAssertFalse(observer.cancelsTouchesInView)
        XCTAssertFalse(observer.delaysTouchesEnded)

        editor.controller.scrollViewWillBeginDragging(canvas)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: 10), animated: false)
        editor.controller.scrollViewDidEndDragging(canvas, willDecelerate: true)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: 15), animated: false)
        XCTAssertEqual(header.transform.ty, -15, accuracy: 0.01)
        XCTAssertFalse(header.isUserInteractionEnabled)

        let finger = UITouch()
        observer.touchesBegan([finger], with: UIEvent())
        observer.touchesEnded([finger], with: UIEvent())
        XCTAssertEqual(header.transform, .identity, "The header settles once the finger lifts.")
        XCTAssertTrue(header.isUserInteractionEnabled, "Undo and the menu key take touches again.")
        XCTAssertEqual(editor.chrome.travel, 0)
        XCTAssertTrue(editor.chrome.state.showsHeader)

        // The scroll has ended, so the page moving afterwards is not counted.
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: 60), animated: false)
        XCTAssertEqual(header.transform, .identity)
    }

    /// The observer reports only once every finger has left, and keeps reporting for later touches.
    func testFingerLiftObserverReportsWhenTheLastFingerLeaves() {
        let observer = NotebookFingerLiftObserver()
        var lifts = 0
        observer.onLift = { lifts += 1 }
        let first = UITouch()
        let second = UITouch()
        observer.touchesBegan([first], with: UIEvent())
        observer.touchesBegan([second], with: UIEvent())
        observer.touchesEnded([first], with: UIEvent())
        XCTAssertEqual(lifts, 0, "A finger is still down.")
        observer.touchesCancelled([second], with: UIEvent())
        XCTAssertEqual(lifts, 1)
        observer.reset()
        observer.touchesBegan([first], with: UIEvent())
        observer.touchesEnded([first], with: UIEvent())
        XCTAssertEqual(lifts, 2)
        XCTAssertTrue(observer.gestureRecognizer(observer, shouldRecognizeSimultaneouslyWith: UIPanGestureRecognizer()))
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

    /// The writing views end to end on the notebook screen, with the real header and toolbar: Focus
    /// clears both from the page when a stroke ends and leaves the reveal tab, whose tap brings both
    /// back; Pinned never hides anything; Always-on tools lets the header scroll away and keeps the
    /// tools. The page's insets and offset never change with any of it.
    func testWritingViewsHideAndRevealTheHeaderAndToolsTogetherWithoutMovingThePage() async throws {
        let editor = try await mountEditor(width: 834)
        defer { editor.close() }
        let canvas = editor.controller.canvasView
        let header = editor.header.headerView
        let store = editor.store
        let window = editor.window
        let insets = canvas.contentInset
        let shellCentre = CGPoint(x: editor.shellFrame.midX, y: editor.shellFrame.midY)
        let reserved = window.safeAreaInsets.top + NotebookScreen.headerReservation
        let rail = NotebookToolbarComposition(preferences: store.toolbar, horizontalSizeClass: .regular)
            .frame(for: store.toolbar.placement, in: CGRect(x: 0, y: reserved, width: window.bounds.width, height: 800))
        let tab = CGPoint(x: rail.midX, y: rail.minY + 10)
        let besideTab = CGPoint(x: rail.midX + 120, y: rail.midY)
        func hit(_ point: CGPoint) -> UIView { NotebookTestFixtures.hit(point, in: window) }
        func assertPageHeldStill(_ offset: CGPoint, _ phase: String, line: UInt = #line) {
            XCTAssertEqual(canvas.contentInset, insets, "\(phase): insets", line: line)
            XCTAssertEqual(canvas.contentOffset, offset, "\(phase): offset", line: line)
        }
        func stroke() {
            editor.controller.canvasViewDidBeginUsingTool(canvas)
            editor.controller.canvasViewDidEndUsingTool(canvas)
        }
        XCTAssertEqual(editor.chrome.mode, .focus, "Focus is the default.")
        XCTAssertFalse(store.areToolsHidden)
        try await NotebookTestFixtures.waitUntil { !hit(besideTab).isDescendant(of: editor.controller.view) }

        let opened = canvas.contentOffset
        stroke()
        XCTAssertEqual(editor.chrome.travel, NotebookWritingChrome.fullTravel)
        XCTAssertEqual(NotebookWritingChrome.fullTravel, 66)
        XCTAssertEqual(header.alpha, 0)
        XCTAssertFalse(header.isUserInteractionEnabled)
        XCTAssertTrue(hit(shellCentre).isDescendant(of: editor.controller.view), "The page takes the header's place.")
        XCTAssertTrue(store.areToolsHidden)
        try await NotebookTestFixtures.waitUntil {
            hit(besideTab).isDescendant(of: canvas) && !hit(tab).isDescendant(of: editor.controller.view)
        }
        assertPageHeldStill(opened, "Focus after a stroke")

        // The reveal tab's tap.
        NotebookToolbarActions(store: store).showTools()
        XCTAssertFalse(store.areToolsHidden)
        XCTAssertEqual(editor.chrome.travel, 0)
        XCTAssertEqual(header.transform, .identity)
        XCTAssertEqual(header.alpha, 1)
        XCTAssertTrue(hit(shellCentre).isDescendant(of: editor.header.view), "The header takes touches again.")
        try await NotebookTestFixtures.waitUntil { !hit(besideTab).isDescendant(of: editor.controller.view) }
        assertPageHeldStill(opened, "Focus revealed")

        editor.chrome.setMode(.pinned)
        stroke()
        editor.controller.scrollViewWillBeginDragging(canvas)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: opened.y + 150), animated: false)
        editor.controller.scrollViewDidEndDragging(canvas, willDecelerate: false)
        XCTAssertEqual(header.transform, .identity, "Pinned never moves the header")
        XCTAssertEqual(header.alpha, 1)
        XCTAssertFalse(store.areToolsHidden, "nor hides the tools.")
        assertPageHeldStill(CGPoint(x: opened.x, y: opened.y + 150), "Pinned")

        editor.chrome.setMode(.overlay)
        stroke()
        XCTAssertEqual(header.alpha, 1, "Always-on tools leaves the header after a stroke")
        XCTAssertFalse(store.areToolsHidden, "and the tools.")
        editor.controller.scrollViewWillBeginDragging(canvas)
        for step in 1...20 {
            canvas.setContentOffset(CGPoint(x: opened.x, y: opened.y + 150 + CGFloat(step) * 5), animated: false)
        }
        editor.controller.scrollViewDidEndDragging(canvas, willDecelerate: false)
        XCTAssertEqual(editor.chrome.travel, NotebookWritingChrome.fullTravel, "The header scrolls away")
        XCTAssertEqual(header.alpha, 0)
        XCTAssertFalse(store.areToolsHidden, "while the tools stay.")
        XCTAssertFalse(hit(besideTab).isDescendant(of: editor.controller.view))
        assertPageHeldStill(CGPoint(x: opened.x, y: opened.y + 250), "Always-on tools")
        try await Task.sleep(for: .milliseconds(300))
        assertPageHeldStill(CGPoint(x: opened.x, y: opened.y + 250), "Always-on tools, settled")
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

    /// Layout that moves the page mid-scroll restarts the count from the new offset; outside a
    /// scroll it changes nothing.
    func testALayoutAdjustmentMidDragIsNotCountedAsTravel() async throws {
        let rig = try await NotebookChromeRig()
        rig.chrome.userScrollBegan(in: rig.scrollView)
        rig.scroll(by: 10)
        XCTAssertEqual(rig.header.transform.ty, -10, accuracy: 0.01)
        rig.scrollView.contentOffset.y += 300
        rig.chrome.layoutMovedPage(in: rig.scrollView)
        XCTAssertEqual(rig.header.transform.ty, -10, accuracy: 0.01)
        rig.scroll(by: 2)
        XCTAssertEqual(rig.header.transform.ty, -12, accuracy: 0.01, "The 300 pt jump is not travel.")
        XCTAssertTrue(rig.chrome.state.showsHeader)
        rig.scrollView.contentOffset.y -= 300
        rig.chrome.layoutMovedPage(in: rig.scrollView)
        rig.scroll(by: -2)
        XCTAssertEqual(rig.header.transform.ty, -10, accuracy: 0.01, "Nor is a jump back.")
        rig.chrome.userScrollEnded()

        rig.chrome.layoutMovedPage(in: rig.scrollView)
        rig.chrome.fingersLifted()
        rig.move(to: rig.scrollView.contentOffset.y + 100)
        XCTAssertEqual(rig.header.transform, .identity, "Outside a scroll, neither starts one.")
        XCTAssertTrue(rig.chrome.state.showsHeader)
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

    /// The notebook opens below the top of its scroll range, under the header and toolbar. After a
    /// stroke has cleared the page, a status-bar tap brings the header and tools back.
    func testTheStatusBarTapRevealsOnANotebookJustOpened() async throws {
        let editor = try await mountEditor(width: 834)
        defer { editor.close() }
        let canvas = editor.controller.canvasView
        XCTAssertGreaterThan(canvas.contentOffset.y, -canvas.contentInset.top + 28, "The page opens below its top.")
        editor.controller.canvasViewDidBeginUsingTool(canvas)
        editor.controller.canvasViewDidEndUsingTool(canvas)
        XCTAssertTrue(editor.store.areToolsHidden)

        // The system scrolls the page to its top, then reports that it has settled there.
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: -canvas.contentInset.top), animated: false)
        editor.controller.scrollViewDidScrollToTop(canvas)
        XCTAssertTrue(editor.chrome.state.showsHeader)
        XCTAssertFalse(editor.store.areToolsHidden)

        // At the top already, the tap is still the user's request.
        editor.controller.canvasViewDidBeginUsingTool(canvas)
        editor.controller.canvasViewDidEndUsingTool(canvas)
        XCTAssertTrue(editor.store.areToolsHidden)
        editor.controller.scrollViewDidScrollToTop(canvas)
        XCTAssertTrue(editor.chrome.state.showsHeader)
        XCTAssertFalse(editor.store.areToolsHidden)
    }

    /// The writing view learns where the notebook opens, so the first scroll that reaches the top
    /// is an arrival there, however short.
    func testTheFirstArrivalAtTheTopRevealsOnANotebookJustOpened() async throws {
        let editor = try await mountEditor(width: 834)
        defer { editor.close() }
        let canvas = editor.controller.canvasView
        let top = -canvas.contentInset.top
        editor.controller.canvasViewDidBeginUsingTool(canvas)
        editor.controller.canvasViewDidEndUsingTool(canvas)
        XCTAssertTrue(editor.store.areToolsHidden)

        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: top + 10), animated: false)
        editor.controller.scrollViewWillBeginDragging(canvas)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: top), animated: false)
        editor.controller.scrollViewDidEndDragging(canvas, willDecelerate: false)
        XCTAssertTrue(editor.chrome.state.showsHeader, "A 10 pt scroll that reaches the top is an arrival.")
        XCTAssertFalse(editor.store.areToolsHidden)
    }

    /// A status-bar tap during a stroke waits for the pen to lift.
    func testAStatusBarTapDuringAStrokeRevealsOnceThePenLifts() async throws {
        let rig = try await NotebookChromeRig()
        rig.drag(by: 200)
        XCTAssertFalse(rig.chrome.state.showsHeader)
        rig.chrome.toolBegan()
        rig.chrome.scrolledToTop()
        XCTAssertFalse(rig.chrome.state.showsHeader, "Nothing moves under the pen.")
        rig.chrome.toolEnded()
        XCTAssertTrue(rig.chrome.state.showsHeader)
        XCTAssertFalse(rig.store.areToolsHidden)
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

        // A toolbar drag reports itself from its first move until it ends.
        let drag = NotebookToolbarDragSession()
        let actions = NotebookToolbarActions(store: rig.store)
        drag.move(to: CGSize(width: 0, height: 20), resolver: rig.toolbarDragResolver, actions: actions)
        XCTAssertTrue(rig.chrome.state.pins.contains(.dragging))
        rig.chrome.toolBegan()
        rig.chrome.toolEnded()
        XCTAssertFalse(rig.store.areToolsHidden, "A dragged toolbar never hides under the finger.")
        drag.move(to: CGSize(width: 0, height: 40), resolver: rig.toolbarDragResolver, actions: actions)
        XCTAssertTrue(rig.chrome.state.pins.contains(.dragging))
        drag.end(at: CGSize(width: 0, height: 40), resolver: rig.toolbarDragResolver, actions: actions)
        XCTAssertFalse(rig.chrome.state.pins.contains(.dragging))
        XCTAssertTrue(rig.store.areToolsHidden, "Requests made under the pin take effect once it clears.")

        drag.move(to: CGSize(width: 0, height: 20), resolver: rig.toolbarDragResolver, actions: actions)
        XCTAssertTrue(rig.chrome.state.pins.contains(.dragging))
        drag.cancel()
        XCTAssertFalse(rig.chrome.state.pins.contains(.dragging), "A cancelled drag ends its pin too.")

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
        let clock = NotebookTestClock()
        let rig = try await NotebookChromeRig(delay: { await clock.wait($0) })
        do {
            rig.chrome.toolBegan()
            rig.chrome.toolEnded()
            XCTAssertTrue(rig.store.areToolsHidden)
            var shown = 0
            let watch = rig.store.$areToolsHidden.dropFirst().sink { if !$0 { shown += 1 } }
            defer { watch.cancel() }

            rig.gate.update(pageCount: 3, inputGate: .capacity)
            let brief = try await waitForDelay(clock, NotebookWritingChrome.catchUpPinDelay)
            XCTAssertFalse(rig.chrome.state.pins.contains(.inputPaused), "The pause has only begun.")
            rig.gate.update(pageCount: 3, inputGate: .open)
            // Writing resumes before the grace runs out: the grace ends only once the resumption
            // has been delivered.
            await NotebookTestFixtures.drainMainQueue()
            await clock.release(brief)
            await NotebookTestFixtures.drainMainQueue()
            XCTAssertTrue(rig.chrome.state.pins.isEmpty)
            XCTAssertEqual(shown, 0, "A brief pause never flashes the tools.")
            XCTAssertEqual(rig.header.alpha, 0)

            rig.gate.update(pageCount: 3, inputGate: .capacity)
            let lasting = try await waitForDelay(clock, NotebookWritingChrome.catchUpPinDelay)
            XCTAssertFalse(rig.chrome.state.pins.contains(.inputPaused))
            await clock.release(lasting)
            try await NotebookTestFixtures.waitUntil { rig.chrome.state.pins.contains(.inputPaused) }
            XCTAssertFalse(rig.store.areToolsHidden, "A lasting pause shows why writing stopped.")
            XCTAssertEqual(rig.header.alpha, 1)
            rig.gate.update(pageCount: 3, inputGate: .open)
            try await NotebookTestFixtures.waitUntil { rig.chrome.state.pins.isEmpty }
            XCTAssertTrue(rig.store.areToolsHidden, "Writing resumed, the page is clear again.")
            XCTAssertEqual(NotebookWritingChrome.catchUpPinDelay, .seconds(1))
            await clock.releaseAll()
        } catch {
            await clock.releaseAll()
            throw error
        }
    }

    /// An Apple Pencil tool switch shows the tools briefly. A drag of the toolbar started meanwhile
    /// keeps them until it ends, and the brief reveal that ran out under it leaves them up until the
    /// next hide trigger.
    func testADragStartedDuringABriefRevealKeepsTheToolsInSight() async throws {
        let clock = NotebookTestClock()
        let rig = try await NotebookChromeRig(delay: { await clock.wait($0) })
        do {
            rig.chrome.toolBegan()
            rig.chrome.toolEnded()
            rig.chrome.reveal(.transient)
            XCTAssertFalse(rig.store.areToolsHidden)
            let expiry = try await waitForDelay(clock, EditorChromeState.transientRevealDuration)

            let drag = NotebookToolbarDragSession()
            let actions = NotebookToolbarActions(store: rig.store)
            drag.move(to: CGSize(width: 0, height: 20), resolver: rig.toolbarDragResolver, actions: actions)
            await clock.release(expiry)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertFalse(rig.store.areToolsHidden, "The brief reveal never ends under the finger.")

            drag.cancel()
            XCTAssertFalse(rig.store.areToolsHidden)
            rig.chrome.toolBegan()
            rig.chrome.toolEnded()
            XCTAssertTrue(rig.store.areToolsHidden)
            await clock.releaseAll()
        } catch {
            await clock.releaseAll()
            throw error
        }
    }

    /// The compact ink panel keeps the tools in sight, under its anchor, while it is open: no hide
    /// trigger takes them away until it closes.
    func testTheToolbarsInkPanelKeepsTheToolsInSightWhileOpen() async throws {
        let fixture = try await NotebookTestFixtures.mountToolbarHost(horizontalSizeClass: .compact)
        defer { fixture.close() }
        let rig = try await NotebookChromeRig(store: fixture.store)
        // An Apple Pencil gesture set to show the palette opens the panel through its own binding.
        fixture.store.handlePencil(.showContextualPalette, from: fixture.controller)
        try await NotebookTestFixtures.waitUntil { fixture.hosting.presentedViewController != nil }
        try await NotebookTestFixtures.waitUntil { rig.chrome.isPresenting }
        XCTAssertTrue(rig.chrome.state.pins.contains(.presentation))

        rig.chrome.toggle()
        XCTAssertFalse(rig.store.areToolsHidden, "The keyboard shortcut never hides the tools under the panel.")
        rig.chrome.toolBegan()
        rig.chrome.toolEnded()
        XCTAssertFalse(rig.store.areToolsHidden, "Nor does a stroke ending.")

        // Pausing writing closes the panel, which then stops holding the tools.
        fixture.controller.setInputGate(.failed)
        try await NotebookTestFixtures.waitUntil { !rig.chrome.isPresenting }
        XCTAssertTrue(rig.store.areToolsHidden, "The hide takes effect once the panel closes.")
    }

    /// A presentation of the toolbar reports through the store while it is open, and as closed once
    /// the view presenting it leaves.
    func testAToolbarPresentationPinsTheChromeUntilItClosesOrItsPresenterLeaves() async throws {
        let rig = try await NotebookChromeRig()
        let model = PresentationModel()
        let hosting = AppearanceTrackingHostingController(rootView: PresentingView(model: model, store: rig.store))
        let window = try NotebookTestFixtures.window(showing: hosting, width: 400)
        defer {
            hosting.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        try await NotebookTestFixtures.waitUntilAppeared(hosting)
        XCTAssertFalse(rig.chrome.isPresenting)
        // A presentation opens or closes at most once a frame, so each change waits for the next.
        func change(_ body: () -> Void) async throws {
            try await Task.sleep(for: .milliseconds(50))
            body()
        }
        try await change { model.isPresented = true }
        try await NotebookTestFixtures.waitUntil { rig.chrome.isPresenting }
        XCTAssertTrue(rig.chrome.state.pins.contains(.presentation))
        try await change { model.isPresented = false }
        try await NotebookTestFixtures.waitUntil { !rig.chrome.isPresenting }

        try await change { model.isPresented = true }
        try await NotebookTestFixtures.waitUntil { rig.chrome.isPresenting }
        try await change { model.showsPresenter = false }
        try await NotebookTestFixtures.waitUntil { !rig.chrome.isPresenting }
    }

    /// Escape is left to close the toolbar's own popover, as it is for the header's.
    func testEscapeIsLeftToTheToolbarsOwnPopover() async throws {
        let editor = try await mountEditor(width: 420, sizeClass: .compact)
        defer { editor.close() }
        func hasEscape() -> Bool {
            editor.controller.canvasView.notebookKeyCommands.contains { $0.input == UIKeyCommand.inputEscape }
        }
        XCTAssertTrue(hasEscape())
        editor.store.handlePencil(.showContextualPalette, from: editor.controller)
        try await NotebookTestFixtures.waitUntil { editor.hosting.presentedViewController != nil }
        try await NotebookTestFixtures.waitUntil { editor.chrome.isPresenting }
        try await NotebookTestFixtures.waitUntil { !hasEscape() }
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

    /// SwiftUI dismantles a canvas inside its update. A reveal held back by a stroke that the
    /// teardown cuts short is carried out a turn later, never inside that update, and not while
    /// a new stroke is under way.
    func testARevealHeldByACancelledStrokeArrivesOnTheNextTurn() async throws {
        let rig = try await NotebookChromeRig()
        rig.drag(by: 100)
        XCTAssertTrue(rig.store.areToolsHidden)
        rig.chrome.toolBegan()
        rig.chrome.reveal(.sticky)
        var changes = 0
        let watch = rig.store.objectWillChange.sink { changes += 1 }
        rig.chrome.toolCancelled()
        watch.cancel()
        XCTAssertEqual(changes, 0, "The tools do not change while the canvas is dismantled.")
        try await NotebookTestFixtures.waitUntil { !rig.store.areToolsHidden }
        XCTAssertTrue(rig.chrome.state.showsHeader)

        rig.drag(by: 100)
        rig.chrome.toolBegan()
        rig.chrome.reveal(.sticky)
        rig.chrome.toolCancelled()
        rig.chrome.toolBegan()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(rig.store.areToolsHidden, "Nothing moves under the next stroke.")
        rig.chrome.toolEnded()
        XCTAssertFalse(rig.store.areToolsHidden, "The request outlasts the stroke that ended.")
        XCTAssertTrue(rig.chrome.state.showsHeader)
    }

    /// A pin made while the header follows the page puts it back in place. Once the pin clears,
    /// the header follows on from there, never jumping to the distance counted before or under it.
    func testAPinMidScrollLetsTheHeaderFollowOnFromItsPlace() async throws {
        let rig = try await NotebookChromeRig()
        let id = UUID()
        rig.chrome.userScrollBegan(in: rig.scrollView)
        rig.scroll(by: 15)
        XCTAssertEqual(rig.header.transform.ty, -15, accuracy: 0.01)
        rig.chrome.setPresentation(id, isPresented: true)
        XCTAssertEqual(rig.header.transform, .identity)
        rig.scroll(by: 5)
        XCTAssertEqual(rig.header.transform, .identity, "A pin holds the header in place.")
        rig.chrome.setPresentation(id, isPresented: false)
        XCTAssertEqual(rig.header.transform, .identity)
        rig.scroll(by: 1)
        XCTAssertEqual(rig.header.transform.ty, -1, accuracy: 0.01)
        XCTAssertEqual(rig.header.transform.ty, -rig.chrome.state.headerTravel, accuracy: 0.01)
        rig.chrome.userScrollEnded()
        XCTAssertEqual(rig.header.transform, .identity)
    }

    /// An Apple Pencil tool switch shows the tools alone for a moment; a header the page has
    /// taken part-way up stays where it is and goes on following the page.
    func testAToolSwitchMidScrollLeavesAFollowingHeaderWhereItIs() async throws {
        let rig = try await NotebookChromeRig()
        rig.chrome.userScrollBegan(in: rig.scrollView)
        rig.scroll(by: 15)
        rig.chrome.reveal(.transient)
        XCTAssertEqual(rig.header.transform.ty, -15, accuracy: 0.01)
        rig.scroll(by: 1)
        XCTAssertEqual(rig.header.transform.ty, -16, accuracy: 0.01)
        rig.chrome.userScrollEnded()
        XCTAssertEqual(rig.header.transform, .identity)
    }

    /// A stroke that begins while the header follows the page holds it there and restarts the
    /// count. If the stroke is cut short and the page moves before the pen's requests are carried
    /// out, the header eases into line with the count rather than jumping, then follows on.
    func testAStrokeCutShortMidScrollEasesTheHeaderBackIntoLine() async throws {
        let rig = try await NotebookChromeRig()
        rig.chrome.userScrollBegan(in: rig.scrollView)
        rig.scroll(by: 15)
        XCTAssertEqual(rig.header.transform.ty, -15, accuracy: 0.01)
        rig.chrome.toolBegan()
        rig.scroll(by: 8)
        XCTAssertEqual(rig.header.transform.ty, -15, accuracy: 0.01, "The header holds still under the pen.")
        rig.chrome.toolCancelled()

        rig.header.layer.removeAllAnimations()
        rig.scroll(by: 2)
        XCTAssertEqual(rig.header.transform.ty, -2, accuracy: 0.01, "The count restarted as the stroke began.")
        XCTAssertNotNil(rig.header.layer.animation(forKey: "transform"), "It eases the 13 pt the page never moved.")
        rig.header.layer.removeAllAnimations()
        rig.scroll(by: 1)
        XCTAssertEqual(rig.header.transform.ty, -3, accuracy: 0.01)
        XCTAssertNil(rig.header.layer.animation(forKey: "transform"), "Back in line, it moves with the finger.")
        await NotebookTestFixtures.drainMainQueue()
        XCTAssertEqual(rig.header.transform.ty, -rig.chrome.state.headerTravel, accuracy: 0.01)
        rig.chrome.userScrollEnded()
    }

    /// Layout can carry the page to just below its top mid-scroll without the jump counting as
    /// travel. Arriving at the top then shows the header, which eases back into place from where
    /// the page left it.
    func testArrivingAtTheTopAfterALayoutJumpEasesTheHeaderIntoPlace() async throws {
        let rig = try await NotebookChromeRig()
        let top = -rig.scrollView.contentInset.top
        rig.chrome.userScrollBegan(in: rig.scrollView)
        rig.scroll(by: 20)
        XCTAssertEqual(rig.header.transform.ty, -20, accuracy: 0.01)
        rig.scrollView.contentOffset.y = top + 1
        rig.chrome.layoutMovedPage(in: rig.scrollView)
        rig.header.layer.removeAllAnimations()
        rig.move(to: top)
        XCTAssertTrue(rig.chrome.state.showsHeader)
        XCTAssertEqual(rig.header.transform, .identity)
        XCTAssertNotNil(rig.header.layer.animation(forKey: "transform"), "The header eases the 20 pt home.")
        rig.chrome.userScrollEnded()
    }

    /// Whatever interleaves with scrolling, a shown header sits where the count puts it whenever
    /// nothing holds it, and no step of the page moves the header further than the page moved
    /// unless it eases there.
    func testTheHeaderNeverJumpsAheadOfThePageWhateverInterleaves() async throws {
        let rig = try await NotebookChromeRig()
        var random = SeededGenerator(seed: 0x5EED)
        let top = -rig.scrollView.contentInset.top
        let end: CGFloat = 4_100
        var isScrolling = false
        var isDrawing = false
        // A stroke cut short carries out its requests on the next turn.
        var awaitsTurn = false
        var presentations: [UUID] = []
        var eased = 0
        for step in 0..<6_000 {
            switch Int.random(in: 0..<200, using: &random) {
            case 0..<110:
                if !isScrolling {
                    rig.chrome.userScrollBegan(in: rig.scrollView)
                    isScrolling = true
                }
                let from = rig.scrollView.contentOffset.y
                let to = min(max(from + CGFloat(Int.random(in: -9...12, using: &random)), top - 40), end)
                let before = rig.chrome.travel
                rig.header.layer.removeAllAnimations()
                rig.move(to: to)
                guard abs(rig.chrome.travel - before) > abs(to - from) + 0.5 else { break }
                XCTAssertNotNil(rig.header.layer.animation(forKey: "transform"), "\(step): the header jumped ahead of the page")
                eased += 1
            case 110..<120:
                rig.chrome.userScrollEnded()
                isScrolling = false
            case 120..<124:
                rig.chrome.fingersLifted()
                isScrolling = false
            case 124..<132:
                let jump = CGFloat(Int.random(in: -300...300, using: &random))
                rig.scrollView.contentOffset.y = min(max(rig.scrollView.contentOffset.y + jump, top), end)
                rig.chrome.layoutMovedPage(in: rig.scrollView)
            case 132..<135:
                rig.scrollView.contentOffset.y = top + CGFloat(Int.random(in: 1...6, using: &random))
                rig.chrome.layoutMovedPage(in: rig.scrollView)
            case 135..<138:
                let open = UUID()
                presentations.append(open)
                rig.chrome.setPresentation(open, isPresented: true)
            case 138..<146:
                guard let open = presentations.popLast() else { break }
                rig.chrome.setPresentation(open, isPresented: false)
            case 146..<148:
                rig.chrome.setToolbarDragging(true)
            case 148..<154:
                rig.chrome.setToolbarDragging(false)
            case 154..<162:
                guard !isDrawing else { break }
                rig.chrome.toolBegan()
                isDrawing = true
            case 162..<169:
                guard isDrawing else { break }
                rig.chrome.toolEnded()
                isDrawing = false
            case 169..<174:
                guard isDrawing else { break }
                rig.chrome.toolCancelled()
                isDrawing = false
                awaitsTurn = true
            case 174..<180:
                await NotebookTestFixtures.drainMainQueue()
                awaitsTurn = false
            case 180..<190:
                rig.chrome.reveal(Bool.random(using: &random) ? .sticky : .transient)
            case 190..<194:
                rig.chrome.toggle()
            case 194..<197:
                rig.chrome.setMode(EditorChromeMode.allCases.randomElement(using: &random) ?? .focus)
            default:
                rig.scrollView.contentOffset.y = top
                rig.chrome.scrolledToTop()
                isScrolling = false
            }
            let state = rig.chrome.state
            if state.showsHeader && !isDrawing && !awaitsTurn {
                XCTAssertEqual(rig.header.transform.ty, -state.headerTravel, accuracy: 0.01, "\(step): out of line")
            }
        }
        XCTAssertGreaterThan(eased, 0, "The sequence reaches a header out of line with the count.")
        for open in presentations { rig.chrome.setPresentation(open, isPresented: false) }
        rig.chrome.setToolbarDragging(false)
        if isDrawing { rig.chrome.toolEnded() }
        await NotebookTestFixtures.drainMainQueue()
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


    /// The menu lays out at the width its popover is drawn. In a window too narrow for the standard
    /// width, as Slide Over is, UIKit narrows the popover, and the menu asks for no more than that.
    func testTheMenuLaysOutAtTheWidthItsPopoverIsDrawn() async throws {
        let rig = try await NotebookChromeRig()
        let session = NotebookSession()
        let settings: [(hostWidth: CGFloat, size: DynamicTypeSize)] = [
            (320, .large), (320, .accessibility5), (420, .accessibility5), (834, .accessibility1), (1_024, .large),
        ]
        for setting in settings {
            let menu = NotebookMenu(
                session: session, chrome: rig.chrome, gate: rig.gate, commands: session.commandModel,
                hostWidth: setting.hostWidth, sizeClass: setting.hostWidth < 500 ? .compact : .regular, offersRedo: false,
                close: {}, openRecoveryCopies: {}
            )
            let hosting = AppearanceTrackingHostingController(rootView: MenuPresenter(menu: menu, size: setting.size))
            let window = try NotebookTestFixtures.window(showing: hosting, width: setting.hostWidth)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            try await NotebookTestFixtures.waitUntilAppeared(hosting)
            let presented = try await NotebookTestFixtures.waitForValue {
                hosting.presentedViewController.flatMap { $0.view.window == nil ? nil : $0 }
            }
            let expected = NotebookMenu.width(for: setting.size, hostWidth: setting.hostWidth)
            try await NotebookTestFixtures.waitUntil { abs(presented.view.bounds.width - expected) < 0.5 }
            XCTAssertLessThanOrEqual(
                presented.view.convert(presented.view.bounds, to: nil).maxX, setting.hostWidth,
                "In \(setting.hostWidth) at \(setting.size) the whole menu is in the window"
            )
            presented.dismiss(animated: false)
            try await NotebookTestFixtures.waitUntil { hosting.presentedViewController == nil }
        }
    }

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

    /// At accessibility text sizes the menu widens as far as the window allows and the shortcut hint
    /// gives way; a window too narrow for the standard width, as Slide Over is, gets the widest
    /// popover UIKit shows. Where a word of a name would not fit beside the glyph, the glyph moves
    /// above the name; where it would not fit even then, as "Always-on" in Slide Over at the
    /// largest size, it breaks at its hyphen. Either way every name and description wraps between
    /// its words rather than inside one, Bold Text included.
    func testWritingViewNamesStayWholeAtEveryTextSize() {
        XCTAssertEqual(NotebookMenu.width(for: .large, hostWidth: 834), NotebookTheme.popoverWidth)
        XCTAssertEqual(NotebookMenu.width(for: .xxxLarge, hostWidth: 1_024), NotebookTheme.popoverWidth)
        XCTAssertEqual(NotebookMenu.width(for: .accessibility1, hostWidth: 834), NotebookTheme.accessibilityPopoverWidth)
        XCTAssertEqual(NotebookMenu.width(for: .accessibility5, hostWidth: 420), 380, "Split View")
        XCTAssertEqual(NotebookMenu.width(for: .accessibility5, hostWidth: 320), 300, "Slide Over")
        XCTAssertEqual(NotebookMenu.width(for: .large, hostWidth: 320), 300, "Slide Over")
        XCTAssertTrue(NotebookWritingViewRow.showsShortcutHint(at: .xxxLarge))
        XCTAssertFalse(NotebookWritingViewRow.showsShortcutHint(at: .accessibility1))

        let standard = NotebookTheme.popoverWidth - 2 * NotebookTheme.popoverPadding
        XCTAssertEqual(NotebookWritingViewRow.Layout(rowWidth: standard, typeSize: .large, isBold: false), .init())
        let slideOver = NotebookMenu.width(for: .accessibility5, hostWidth: 320) - 2 * NotebookTheme.popoverPadding
        XCTAssertFalse(NotebookWritingViewRow.Layout(rowWidth: slideOver, typeSize: .large, isBold: false).isStandardWidth)
        for size in DynamicTypeSize.allCases where !size.isAccessibilitySize {
            let layout = NotebookWritingViewRow.Layout(rowWidth: slideOver, typeSize: size, isBold: true)
            XCTAssertFalse(layout.stacksGlyph || layout.breaksAtHyphens, "\(size)")
        }
        let accessibility3 = NotebookWritingViewRow.Layout(rowWidth: slideOver, typeSize: .accessibility3, isBold: false)
        XCTAssertFalse(accessibility3.stacksGlyph)
        let accessibility4 = NotebookWritingViewRow.Layout(rowWidth: slideOver, typeSize: .accessibility4, isBold: true)
        XCTAssertTrue(accessibility4.stacksGlyph)
        XCTAssertFalse(accessibility4.breaksAtHyphens)
        let accessibility5 = NotebookWritingViewRow.Layout(rowWidth: slideOver, typeSize: .accessibility5, isBold: false)
        XCTAssertTrue(accessibility5.stacksGlyph)
        XCTAssertTrue(accessibility5.breaksAtHyphens)

        func width(_ word: Substring, in font: UIFont) -> CGFloat {
            (String(word) as NSString).size(withAttributes: [.font: font]).width
        }
        /// A word's pieces as line breaking may set them: the word, or, where it may break at its
        /// hyphens, each part with the hyphen that ends it.
        func pieces(_ word: Substring, breaksAtHyphens: Bool) -> [Substring] {
            guard breaksAtHyphens else { return [word] }
            var parts = word.split(separator: "-", omittingEmptySubsequences: false).map { $0 + "-" }
            parts[parts.count - 1].removeLast()
            return parts.map { Substring($0) }
        }
        for size in DynamicTypeSize.allCases {
            let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
            let footnote = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits)
            for isBold in [false, true] {
                let name = NotebookWritingViewRow.nameFont(typeSize: size, isBold: isBold)
                for hostWidth in [1_024, 834, 420, 320] as [CGFloat] {
                    let row = NotebookMenu.width(for: size, hostWidth: hostWidth) - 2 * NotebookTheme.popoverPadding
                    let layout = NotebookWritingViewRow.Layout(rowWidth: row, typeSize: size, isBold: isBold)
                    var column = NotebookWritingViewRow.Layout.nameColumn(rowWidth: row, stacksGlyph: layout.stacksGlyph)
                    if NotebookWritingViewRow.showsShortcutHint(at: size) {
                        let hints = EditorChromeMode.allCases.map { width(Substring($0.shortcutHint), in: footnote) }
                        column -= hints.max() ?? 0
                    }
                    let setting = "at \(size)\(isBold ? " in bold" : "") in \(hostWidth)"
                    XCTAssertEqual(layout.isStandardWidth, hostWidth > 320, setting)
                    var widest: CGFloat = 0
                    for mode in EditorChromeMode.allCases {
                        for word in mode.title.split(separator: " ") {
                            widest = max(widest, width(word, in: name))
                            for piece in pieces(word, breaksAtHyphens: layout.breaksAtHyphens) {
                                XCTAssertLessThanOrEqual(width(piece, in: name), column, "\(piece) of \(mode.title) \(setting)")
                            }
                        }
                        for word in mode.summary.split(separator: " ") {
                            XCTAssertLessThanOrEqual(width(word, in: footnote), column, "\(word) of \(mode.summary) \(setting)")
                        }
                    }
                    guard size.isAccessibilitySize else { continue }
                    let beside = NotebookWritingViewRow.Layout.nameColumn(rowWidth: row, stacksGlyph: false)
                    XCTAssertEqual(layout.stacksGlyph, widest > beside, "The glyph moves above the name only where it must \(setting)")
                    XCTAssertEqual(layout.breaksAtHyphens, widest > column, "A name breaks at its hyphen only where it must \(setting)")
                }
            }
        }
    }

    /// In Slide Over at the two largest text sizes, plain or in bold, the stacked row draws its
    /// glyph first, scaled as the name is and starting where the name does. "Always-on" is set
    /// whole on the name's first line where it fits, and otherwise breaks only at its hyphen.
    func testAStackedWritingViewRowSetsEachWordOfItsNameWhole() throws {
        let row = NotebookMenu.width(for: .accessibility5, hostWidth: 320) - 2 * NotebookTheme.popoverPadding
        let unstacked = try RenderedPixels(rendering:
            NotebookWritingViewRow(mode: .overlay, isSelected: false) {}
                .frame(width: NotebookTheme.popoverWidth - 2 * NotebookTheme.popoverPadding)
        )
        let unstackedGlyph = try XCTUnwrap(Self.inkedRows(unstacked, columns: 0..<(
            NotebookTheme.menuGlyphInset + NotebookTheme.menuGlyphColumnWidth
        )))
        for size in [DynamicTypeSize.accessibility4, .accessibility5] {
            for weight in [LegibilityWeight.regular, .bold] {
                let setting = "\(size)\(weight == .bold ? " in bold" : "")"
                let layout = NotebookWritingViewRow.Layout(rowWidth: row, typeSize: size, isBold: weight == .bold)
                XCTAssertTrue(layout.stacksGlyph, setting)
                XCTAssertEqual(layout.breaksAtHyphens, size == .accessibility5, setting)
                let pixels = try RenderedPixels(rendering:
                    NotebookWritingViewRow(mode: .overlay, isSelected: false, layout: layout) {}
                        .frame(width: row)
                        .dynamicTypeSize(size)
                        .environment(\.legibilityWeight, weight)
                )
                let firstWord = layout.breaksAtHyphens ? "Always-" : "Always\u{2011}on"
                let word = try RenderedPixels(rendering:
                    Text(firstWord)
                        .font(.body.weight(.medium))
                        .fixedSize()
                        .dynamicTypeSize(size)
                        .environment(\.legibilityWeight, weight)
                )
                let lines = Self.inkedLines(pixels)
                XCTAssertGreaterThanOrEqual(lines.count, 4, "\(setting): glyph, two lines of name, then the description")
                guard lines.count >= 4, let glyph = Self.inkedSpan(pixels, rows: lines[0]),
                      let firstLine = Self.inkedSpan(pixels, rows: lines[1]),
                      let alone = Self.inkedSpan(word, rows: 0..<word.size.height) else { continue }
                // The glyph grows about as much as the name's text style does, so it keeps its size
                // relative to the name.
                func body(_ category: UIContentSizeCategory) -> CGFloat {
                    UIFont.preferredFont(
                        forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: category)
                    ).pointSize
                }
                let scale = body(UIContentSizeCategory(size)) / body(.large)
                let glyphHeight = lines[0].upperBound - lines[0].lowerBound
                let restingHeight = unstackedGlyph.upperBound - unstackedGlyph.lowerBound
                XCTAssertEqual(glyphHeight / restingHeight, scale, accuracy: 0.2 * scale, "\(setting): the glyph scales with the name")
                XCTAssertEqual(glyph.lowerBound, firstLine.lowerBound, accuracy: 4, "\(setting): the glyph starts where the name does")
                XCTAssertGreaterThanOrEqual(glyph.lowerBound, NotebookTheme.menuRowInset - 0.5, "\(setting): clear of the mark")
                XCTAssertGreaterThanOrEqual(firstLine.lowerBound, NotebookTheme.menuRowInset - 0.5, setting)
                XCTAssertEqual(
                    firstLine.upperBound - firstLine.lowerBound, alone.upperBound - alone.lowerBound, accuracy: 1,
                    "\(setting): the first line holds \(firstWord) whole"
                )
                XCTAssertLessThanOrEqual(firstLine.upperBound, row - NotebookTheme.menuRowInset + 0.5, setting)
            }
        }
    }

    /// Side by side, the name and description take all the room the row leaves them and wrap
    /// exactly as they would set alone in that column: at the third accessibility size in a
    /// full-width window, and in Slide Over, where even the standard size wraps rather than shrink.
    /// A line that ends short of the column, as "Tools stay; the title" does, ends there by the
    /// text system's own choice of break, not for want of room.
    func testAWritingViewRowGivesItsTextTheWholeColumn() throws {
        let settings: [(hostWidth: CGFloat, size: DynamicTypeSize)] = [(834, .accessibility3), (320, .large), (320, .xxxLarge)]
        for setting in settings {
            let row = NotebookMenu.width(for: setting.size, hostWidth: setting.hostWidth) - 2 * NotebookTheme.popoverPadding
            let layout = NotebookWritingViewRow.Layout(rowWidth: row, typeSize: setting.size, isBold: false)
            XCTAssertFalse(layout.stacksGlyph)
            let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(setting.size))
            let footnote = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits)
            for mode in EditorChromeMode.allCases {
                var column = NotebookWritingViewRow.Layout.nameColumn(rowWidth: row, stacksGlyph: false)
                if NotebookWritingViewRow.showsShortcutHint(at: setting.size) {
                    column -= (mode.shortcutHint as NSString).size(withAttributes: [.font: footnote]).width
                }
                let pixels = try RenderedPixels(rendering:
                    NotebookWritingViewRow(mode: mode, isSelected: false, layout: layout) {}
                        .frame(width: row)
                        .dynamicTypeSize(setting.size)
                )
                let alone = try RenderedPixels(rendering:
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mode.title.replacingOccurrences(of: "-", with: "\u{2011}"))
                            .font(.body.weight(.medium))
                        Text(mode.summary)
                            .font(.footnote)
                    }
                    .frame(width: column, alignment: .leading)
                    .dynamicTypeSize(setting.size)
                )
                let textStart = NotebookTheme.menuGlyphInset + NotebookTheme.menuGlyphColumnWidth + NotebookTheme.menuRowInset
                let text = textStart..<(textStart + column)
                let lines = Self.inkedLines(pixels, columns: text)
                let aloneLines = Self.inkedLines(alone)
                let name = "\(mode) at \(setting.size) in \(setting.hostWidth)"
                XCTAssertEqual(lines.count, aloneLines.count, "\(name): as many lines as set alone")
                for (line, aloneLine) in zip(lines, aloneLines) {
                    let width = try XCTUnwrap(Self.inkedSpan(pixels, rows: line, columns: text))
                    let aloneWidth = try XCTUnwrap(Self.inkedSpan(alone, rows: aloneLine))
                    XCTAssertEqual(
                        width.upperBound - width.lowerBound, aloneWidth.upperBound - aloneWidth.lowerBound, accuracy: 1,
                        "\(name): each line holds what it would set alone"
                    )
                }
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
    /// 20 pt column and stays inside it, clear of the selected row's mark.
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
            // Glyphs centre in a 20 pt column and keep inside it, well clear of the mark.
            let column = NotebookTheme.menuGlyphInset..<(NotebookTheme.menuGlyphInset + NotebookTheme.menuGlyphColumnWidth)
            let glyph = inked(0..<(column.upperBound + 6))
            let glyphStart = try XCTUnwrap(glyph.map(\.x).min(), "\(mode)")
            let glyphEnd = try XCTUnwrap(glyph.map(\.x).max(), "\(mode)")
            XCTAssertGreaterThanOrEqual(glyphStart,
                NotebookTheme.selectionMarkInset + NotebookTheme.rowMarkSize.width + 8, "\(mode): clear of the mark")
            XCTAssertGreaterThanOrEqual(glyphStart, column.lowerBound - 0.5, "\(mode): inside its column")
            XCTAssertLessThanOrEqual(glyphEnd + 0.5, column.upperBound + 0.5, "\(mode): inside its column")
            let glyphHeight = (glyph.map(\.y).max() ?? 0) - (glyph.map(\.y).min() ?? 0) + 0.5
            XCTAssertGreaterThanOrEqual(max(glyphEnd + 0.5 - glyphStart, glyphHeight), 17,
                "\(mode): about as large as the other glyphs")
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

    /// A position segment places the toolbar through the toolbar's own action, then shows as
    /// selected. Float keeps a floating toolbar where the user left it; a paused toolbar stays put.
    func testToolbarPositionSegmentsPlaceTheToolbarAndShowAsSelected() {
        let store = NotebookTestFixtures.toolStore()
        let owner = NotebookViewController(pageCount: 1, initialDrawing: PKDrawing())
        store.attach(owner)
        store.setToolbarAvailable(true, for: owner)
        defer { store.detach(owner) }
        let picker = NotebookToolbarPositionPicker(store: store, hostWidth: 1_366, sizeClass: .regular)
        let segments = NotebookToolbarPositionPicker.segments
        XCTAssertEqual(segments.map(\.label), ["Left", "Center", "Right", "Float"])
        for segment in segments {
            picker.choose(segment.placement)
            XCTAssertEqual(NotebookToolbarPositionPicker.segment(for: store.toolbar.placement)?.label, segment.label)
        }
        XCTAssertEqual(store.toolbar.placement, NotebookToolbarActions.floatingPlacement,
            "Float from a dock places the toolbar where the grip's Float action does.")

        let moved = EditorToolbarPlacement.floating(CGPoint(x: 0.3, y: 0.7))
        let actions = NotebookToolbarActions(store: store)
        XCTAssertTrue(actions.place(moved))
        actions.setCollapsed(true)
        picker.choose(NotebookToolbarActions.floatingPlacement)
        XCTAssertEqual(store.toolbar.placement, moved, "Float keeps a floating toolbar where it is")
        XCTAssertFalse(store.toolbar.isCollapsed, "and shows it in full.")
        XCTAssertEqual(NotebookToolbarPositionPicker.segment(for: store.toolbar.placement)?.label, "Float")

        picker.choose(.docked(.topLeading))
        XCTAssertEqual(store.toolbar.placement, .docked(.topLeading))
        store.setToolbarAvailable(false, for: owner)
        picker.choose(.docked(.topTrailing))
        XCTAssertEqual(store.toolbar.placement, .docked(.topLeading), "A paused toolbar keeps its place.")
    }

    /// Voice Control users name a control by the word they see. A position segment answers to its
    /// one word as well as its full name, and a preset chip to its short title, which a swatch of
    /// the same colour may share, as well as to its full name.
    func testControlsAnswerToTheWordsTheyShow() {
        for segment in NotebookToolbarPositionPicker.segments {
            XCTAssertEqual(segment.inputLabels.first, segment.label)
            XCTAssertTrue(segment.inputLabels.contains(segment.accessibilityLabel), segment.label)
        }
        for preset in EditorInkCatalog.presets {
            let spoken = NotebookPresetChip.inputLabels(for: preset)
            XCTAssertEqual(spoken.first, "\(NotebookPresetChip.shortTitle(for: preset)) preset")
            XCTAssertTrue(spoken.contains(preset.name), "\(spoken)")
            XCTAssertTrue(spoken.contains("\(preset.name) preset"), "\(spoken)")
        }
    }

    /// Each writing view row chooses its mode and stores it with the toolbar preferences, then
    /// shows as selected.
    func testWritingViewRowsChooseAndStoreTheirMode() async throws {
        let suite = NotebookTestFixtures.temporaryDefaultsSuite()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = NotebookSceneToolStore(identifier: suite, defaults: defaults)
        let rig = try await NotebookChromeRig(store: store)
        let session = NotebookSession()
        let menu = NotebookMenu(
            session: session, chrome: rig.chrome, gate: rig.gate, commands: session.commandModel, hostWidth: 834,
            sizeClass: .regular, offersRedo: false, close: {}, openRecoveryCopies: {}
        )
        for mode in [EditorChromeMode.pinned, .overlay, .focus] {
            XCTAssertFalse(menu.writingViewRow(mode).isSelected, "\(mode)")
            menu.writingViewRow(mode).choose()
            XCTAssertEqual(rig.chrome.mode, mode)
            XCTAssertEqual(store.toolbar.chromeMode, mode)
            let stored = EditorToolbarPreferences.decode(defaults.data(forKey: NotebookSceneToolStore.toolbarDefaultsKey))
            XCTAssertEqual(stored.chromeMode, mode, "\(mode) is stored.")
            XCTAssertTrue(menu.writingViewRow(mode).isSelected, "\(mode)")
        }
    }

    /// "Add page at end" draws disabled wherever no page can be added, and choosing it adds a page
    /// to the open notebook and closes the menu.
    func testAddPageRowDrawsDisabledWhenNoPageFitsAndAddsAPageAndCloses() async throws {
        let session = NotebookSession()
        let gate = NotebookCanvasGateModel()
        func glyphTone(pageCount: Int, gate inputGate: NotebookInputGate) throws -> CGFloat {
            gate.update(pageCount: pageCount, inputGate: inputGate)
            let width = NotebookTheme.popoverWidth - 2 * NotebookTheme.popoverPadding
            let pixels = try RenderedPixels(rendering:
                NotebookMenuActions(
                    session: session, gate: gate, commands: session.commandModel, offersRedo: false,
                    addPage: {}, openRecoveryCopies: {}
                )
                .frame(width: width)
                .background(NotebookTheme.panelSurface.color)
            )
            // The row's glyph, the first row's leading column.
            var darkest: CGFloat = 1
            for y in stride(from: 4, to: NotebookTheme.menuRowHeight - 4, by: 0.5) {
                for x in stride(from: NotebookTheme.menuGlyphInset, to: NotebookTheme.menuGlyphInset + 20, by: 0.5) {
                    let pixel = pixels.rgba(at: CGPoint(x: x, y: y)).map { CGFloat($0) / 255 }
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
        XCTAssertEqual(try glyphTone(pageCount: 3, gate: .open), luminance(NotebookTheme.glyph), accuracy: 0.03)
        for (pageCount, inputGate) in [(NotebookViewController.maximumPageCount, NotebookInputGate.open), (3, .readOnly)] {
            XCTAssertEqual(try glyphTone(pageCount: pageCount, gate: inputGate), luminance(NotebookTheme.disabledGlyph),
                accuracy: 0.03, "\(pageCount) pages, \(inputGate)")
        }

        let editor = try await mountEditor(width: 834)
        defer { editor.close() }
        var closes = 0
        let menu = NotebookMenu(
            session: editor.session, chrome: editor.chrome, gate: editor.session.gateModel,
            commands: editor.session.commandModel, hostWidth: 834, sizeClass: .regular, offersRedo: false,
            close: { closes += 1 }, openRecoveryCopies: {}
        )
        let pages = editor.session.pageCount
        XCTAssertTrue(NotebookMenu.canAddPage(editor.session.gateModel.state))
        menu.addPage()
        XCTAssertEqual(editor.session.pageCount, pages + 1, "The paper is extended.")
        XCTAssertEqual(closes, 1, "The menu closes over the new page.")
    }

    /// The menu's "Recovery copies" row closes the menu and asks for the sheet only once the menu
    /// has gone; the screen then opens it unless the canvas has a stroke in progress.
    func testRecoveryCopiesPassFromTheMenuToTheirSheet() async throws {
        let handOff = NotebookMenuHandOff()
        var closes = 0
        var opens = 0
        handOff.menuDidDisappear { opens += 1 }
        XCTAssertEqual(opens, 0, "A menu closed for anything else opens nothing.")
        handOff.requestRecoveryCopies { closes += 1 }
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(opens, 0, "Nothing opens while the menu is still leaving.")
        handOff.menuDidDisappear { opens += 1 }
        handOff.menuDidDisappear { opens += 1 }
        XCTAssertEqual(opens, 1, "Once the menu has gone, the sheet is asked for once.")

        let editor = try await mountEditor(width: 834)
        defer { editor.close() }
        let canvas = editor.controller.canvasView
        let openRecoveryCopies = editor.header.header.openRecoveryCopies
        editor.controller.canvasViewDidBeginUsingTool(canvas)
        openRecoveryCopies()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(editor.hosting.presentedViewController, "Never over a stroke in progress.")
        XCTAssertTrue(editor.store.isToolbarAvailable)
        editor.controller.canvasViewDidEndUsingTool(canvas)

        openRecoveryCopies()
        try await NotebookTestFixtures.waitUntil { editor.hosting.presentedViewController != nil }
        XCTAssertFalse(editor.store.isToolbarAvailable, "The tools pause while the recovery copies show.")
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
            hosting.presentedViewController?.dismiss(animated: false)
            session.flush()
            store.setToolsHidden(false)
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    /// The vertical spans, in points, of the lines of ink in a render, or in its `columns`,
    /// separated by clear rows.
    private static func inkedLines(_ pixels: RenderedPixels, columns: Range<CGFloat>? = nil) -> [Range<CGFloat>] {
        let columns = columns ?? 0..<pixels.size.width
        var lines: [Range<CGFloat>] = []
        var start: CGFloat?
        for y in stride(from: 0, to: pixels.size.height, by: 0.5) {
            let inked = stride(from: columns.lowerBound, to: min(columns.upperBound, pixels.size.width), by: 0.5)
                .contains { pixels.rgba(at: CGPoint(x: $0, y: y))[3] > 128 }
            if inked, start == nil { start = y }
            if !inked, let top = start {
                lines.append(top..<y)
                start = nil
            }
        }
        if let top = start { lines.append(top..<pixels.size.height) }
        return lines
    }

    /// The vertical span, in points, of the ink within `columns`.
    private static func inkedRows(_ pixels: RenderedPixels, columns: Range<CGFloat>) -> ClosedRange<CGFloat>? {
        var ys: [CGFloat] = []
        for x in stride(from: columns.lowerBound, to: min(columns.upperBound, pixels.size.width), by: 0.5) {
            for y in stride(from: 0, to: pixels.size.height, by: 0.5) where pixels.rgba(at: CGPoint(x: x, y: y))[3] > 128 {
                ys.append(y)
            }
        }
        guard let minY = ys.min(), let maxY = ys.max() else { return nil }
        return minY...(maxY + 0.5)
    }

    /// The horizontal span, in points, of the ink within `rows`, and within `columns` if given.
    private static func inkedSpan(
        _ pixels: RenderedPixels, rows: Range<CGFloat>, columns: Range<CGFloat>? = nil
    ) -> ClosedRange<CGFloat>? {
        let columns = columns ?? 0..<pixels.size.width
        var xs: [CGFloat] = []
        for y in stride(from: rows.lowerBound, to: rows.upperBound, by: 0.5) {
            for x in stride(from: columns.lowerBound, to: min(columns.upperBound, pixels.size.width), by: 0.5)
            where pixels.rgba(at: CGPoint(x: x, y: y))[3] > 128 {
                xs.append(x)
            }
        }
        guard let minX = xs.min(), let maxX = xs.max() else { return nil }
        return minX...(maxX + 0.5)
    }

    /// The writing view's pending wait for `duration`, once it has started one.
    private func waitForDelay(_ clock: NotebookTestClock, _ duration: Duration) async throws -> UUID {
        try await NotebookTestFixtures.waitForValue { await clock.requests(for: duration).first }
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

    /// - Parameter delay: stands in for the writing view's timed waits, the brief reveal and the
    ///   catch-up grace; a short real wait unless a test steps through them itself.
    init(
        store: NotebookSceneToolStore = NotebookTestFixtures.toolStore(), reduceMotion: Bool = false,
        assistiveTechnology: Bool = false,
        delay: @escaping @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .milliseconds(50)) }
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
            delay: delay
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

    /// Drags a toolbar of the standard size across the rig's page.
    var toolbarDragResolver: NotebookToolbarDragResolver {
        NotebookToolbarDragResolver(
            placement: store.toolbar.placement, size: CGSize(width: 600, height: 108), usable: scrollView.bounds
        )
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

/// A fixed sequence of numbers, so a long interleaving of events replays exactly.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@MainActor
private final class PresentationModel: ObservableObject {
    @Published var isPresented = false
    @Published var showsPresenter = true
}

/// Stands in for a toolbar control that presents a popover or sheet, reporting it as the toolbar's
/// own controls do.
private struct PresentingView: View {
    @ObservedObject var model: PresentationModel
    let store: NotebookSceneToolStore

    var body: some View {
        if model.showsPresenter {
            Color.clear
                .frame(width: 44, height: 44)
                .notebookToolbarPresentation(model.isPresented, store: store)
        }
    }
}

/// Opens a notebook menu in a popover from a key at the window's top, as the header does.
private struct MenuPresenter: View {
    let menu: NotebookMenu
    let size: DynamicTypeSize
    @State private var showsMenu = false

    var body: some View {
        VStack {
            Button("Notebook menu") { showsMenu = true }
                .popover(isPresented: $showsMenu) { menu.dynamicTypeSize(size) }
            Spacer()
        }
        .onAppear { showsMenu = true }
    }
}
