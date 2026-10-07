import NottyCore
import PencilKit
import SwiftUI
import UIKit
import XCTest
@testable import Notty

/// The end of the notebook: a fling stops at the last page, a deliberate pull past it lifts the
/// page over the end card, and a page added where the user can see it clears in with the frost.
/// UIKit's own drag and deceleration cannot be driven from a hosted test, so these tests call the
/// scroll delegate as UIKit does and move the page with offsets in between; UIKit holds offsets to
/// whole device pixels. SwiftUI builds no accessibility elements without an assistive technology
/// running, so the card's labels are read from the face it shows and its key is pressed through
/// the action that face gives it.
@MainActor
final class NotebookEndOfNotebookTests: XCTestCase {
    private static let size = CGSize(width: 834, height: 1_194)
    /// The header and toolbar room at the top and the home indicator, as the toolbar host measures them.
    private static let chrome = NotebookCanvasChrome(top: 110, bottom: 20, canvasSize: size)
    /// Where the captures and the timing report go, when the run names a directory.
    private static let shotsDirectory = ProcessInfo.processInfo.environment["NOTTY_FEATURE_SHOTS_DIRECTORY"]

    // MARK: - Fling

    func testAFlingFromAboveTheEndIsAimedAtTheEndAndStopsThere() async throws {
        let rig = try await present()
        defer { rig.close() }
        let controller = rig.controller
        let canvas = rig.canvas
        let end = Self.endOffset(of: canvas)
        XCTAssertEqual(canvas.contentInset.bottom, 20, accuracy: 0.5, "The page rests at its end above the home indicator.")
        XCTAssertEqual(end, canvas.contentSize.height - canvas.bounds.height + 20, accuracy: 0.5)

        scroll(canvas, to: -canvas.contentInset.top)
        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: 300)
        // However far past the end the deceleration was projected, it is aimed at the end itself.
        for projected in [end, end + 900] {
            XCTAssertEqual(release(controller, velocity: 9, target: projected), end, "projected to \(projected)")
        }
        // Should UIKit carry the fling on to bounce, it stops at the end.
        scroll(canvas, to: end - 400)
        scroll(canvas, to: end + 45)
        XCTAssertEqual(canvas.contentOffset.y, end, accuracy: 0.5, "The fling stops at the last page.")
        controller.scrollViewDidEndDecelerating(canvas)
        XCTAssertFalse(controller.isEndCardRevealed, "A fling arriving at the end never reveals the card.")

        // A tap that stops an aimed fling short of the end ends its stop as well.
        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: end - 500)
        XCTAssertEqual(release(controller, velocity: 9, target: end), end)
        controller.fingerLiftObserver.onLift?()
        scroll(canvas, to: end + 30)
        XCTAssertEqual(canvas.contentOffset.y, end + 30, accuracy: 0.5, "Nothing halts later motion past the end.")
        scroll(canvas, to: end)
        XCTAssertTrue(controller.endOfNotebookCard.isHidden)
        XCTAssertEqual(canvas.contentInset.bottom, 20, accuracy: 0.5)
        XCTAssertEqual(rig.pageBottom, canvas.bounds.height - 20, accuracy: 0.5, "The last page ends above the home indicator.")
    }

    func testAFlingThatFallsShortOfTheEndAndADragFromTheEndAreUntouched() async throws {
        let rig = try await present()
        defer { rig.close() }
        let controller = rig.controller
        let canvas = rig.canvas
        let end = Self.endOffset(of: canvas)

        scroll(canvas, to: 400)
        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: 600)
        XCTAssertEqual(release(controller, velocity: 3, target: end - 900), end - 900, "Short of the end, native scrolling decides.")
        controller.scrollViewDidEndDecelerating(canvas)

        // A drag from the page resting at its end is a pull: its spring back is UIKit's own.
        scroll(canvas, to: end)
        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: end + 30)
        XCTAssertEqual(release(controller, velocity: 2, target: end + 123), end + 123)
        scroll(canvas, to: end + 60)
        XCTAssertEqual(canvas.contentOffset.y, end + 60, accuracy: 0.5, "Nothing halts a pull's own motion.")
        controller.scrollViewDidEndDecelerating(canvas)

        // With the card revealed a drag from the lifted end is no pull either, and its own motion is UIKit's.
        scroll(canvas, to: end)
        try await revealByPulling(rig)
        let lifted = Self.endOffset(of: canvas)
        controller.scrollViewWillBeginDragging(canvas)
        XCTAssertEqual(release(controller, velocity: 4, target: lifted + 123), lifted + 123)
        controller.scrollViewDidEndDecelerating(canvas)

        // A drag that began above the end and carried on past it by hand springs back on its own too.
        scroll(canvas, to: end - 300)
        XCTAssertFalse(controller.isEndCardRevealed, "Scrolling back up dismissed the card.")
        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: end + 50)
        XCTAssertEqual(release(controller, velocity: 1, target: end + 77), end + 77)
        XCTAssertFalse(controller.isEndCardRevealed)
    }

    // MARK: - Pull

    /// Only a new drag that begins with the page resting at its end, released at least
    /// `endRevealPull` past it, reveals the card; anything less springs back.
    func testOnlyAPullFromRestAtTheEndReleasedPastTheThresholdRevealsTheCard() async throws {
        let rig = try await present()
        defer { rig.close() }
        let controller = rig.controller
        let canvas = rig.canvas
        let card = controller.endOfNotebookCard
        let end = Self.endOffset(of: canvas)
        XCTAssertEqual(NotebookViewController.endRevealPull, 72)

        // Resting a point and a half short of the end is not resting at it.
        scroll(canvas, to: end - 1.5)
        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: end + 140)
        XCTAssertTrue(card.isHidden, "Only a pull from the end shows the card beneath the page.")
        _ = release(controller, velocity: 0, target: end)
        XCTAssertFalse(controller.isEndCardRevealed)
        controller.scrollViewDidEndDecelerating(canvas)

        scroll(canvas, to: end)
        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: end + 71)
        XCTAssertFalse(card.isHidden, "The card shows in the space the pull opens.")
        XCTAssertEqual(card.frame.minY, rig.pageBottom + NotebookTheme.endCardGap, accuracy: 0.5)
        XCTAssertEqual(release(controller, velocity: 0, target: end), end, "Short of the threshold the page springs back.")
        XCTAssertFalse(controller.isEndCardRevealed)
        XCTAssertEqual(canvas.contentInset.bottom, 20, accuracy: 0.5)
        scroll(canvas, to: end)
        controller.scrollViewDidEndDecelerating(canvas)
        XCTAssertTrue(card.isHidden, "The card leaves with the page.")

        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: end + 72)
        let pulled = canvas.contentOffset.y
        let target = release(controller, velocity: 0.4, target: end)
        XCTAssertTrue(controller.isEndCardRevealed)
        let room = card.bounds.height + 2 * NotebookTheme.endCardGap
        XCTAssertEqual(canvas.contentInset.bottom, 20 + room, accuracy: 0.5, "Room for the card below the last page.")
        XCTAssertEqual(target, end + room, accuracy: 0.5, "The page settles lifted with the card below it.")
        XCTAssertEqual(canvas.contentOffset.y, pulled, "Revealing moves nothing by itself.")
        scroll(canvas, to: target)
        controller.scrollViewDidEndDecelerating(canvas)
        XCTAssertFalse(card.isHidden)
        XCTAssertEqual(card.frame.minY, rig.pageBottom + NotebookTheme.endCardGap, accuracy: 0.5)
        XCTAssertEqual(card.frame.maxY, canvas.bounds.height - 20 - NotebookTheme.endCardGap, accuracy: 0.5,
            "The card shows whole, clear of the home indicator.")
        XCTAssertEqual(card.frame.midX, canvas.bounds.midX, accuracy: 0.5, "Centred under the page.")
        XCTAssertLessThanOrEqual(card.bounds.width, NotebookTheme.endCardWidth)
        let scale = card.traitCollection.displayScale
        for edge in [card.frame.minX * scale, card.frame.minY * scale] {
            XCTAssertEqual(edge, edge.rounded(), accuracy: 0.001, "whole pixels")
        }
        let hit = NotebookTestFixtures.hit(CGPoint(x: card.frame.midX, y: card.frame.midY), in: controller.view)
        XCTAssertTrue(hit.isDescendant(of: card), "The card takes its own touches: \(hit)")

        // A drag from the lifted end is no new pull.
        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: target + 90)
        XCTAssertEqual(release(controller, velocity: 0, target: target), target)
        XCTAssertEqual(canvas.contentInset.bottom, 20 + room, accuracy: 0.5)
    }

    /// A pull released with no speed left would rest short of the lifted end, so the controller
    /// finishes the lift itself.
    func testAPullReleasedAtRestFinishesLiftingThePage() async throws {
        let rig = try await present()
        defer { rig.close() }
        let controller = rig.controller
        let canvas = rig.canvas
        let end = Self.endOffset(of: canvas)
        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: end + 100)
        _ = release(controller, velocity: 0, target: end)
        controller.scrollViewDidEndDragging(canvas, willDecelerate: false)
        let lifted = Self.endOffset(of: canvas)
        try await NotebookTestFixtures.waitUntil { abs(canvas.contentOffset.y - lifted) < 0.5 }
        XCTAssertTrue(controller.isEndCardRevealed)
        XCTAssertFalse(controller.endOfNotebookCard.isHidden)
    }

    /// A pull the user takes back, already pushing the page home as the finger lifts, reveals
    /// nothing; a finger merely held at its depth may drift back a little and still reveals it.
    func testAPullTakenBackAsTheFingerLiftsRevealsNothing() async throws {
        let rig = try await present()
        defer { rig.close() }
        let controller = rig.controller
        let canvas = rig.canvas
        let end = Self.endOffset(of: canvas)
        XCTAssertEqual(NotebookViewController.endPullReturnSpeed, 0.1)

        for speed in [-1, -0.11] as [CGFloat] {
            controller.scrollViewWillBeginDragging(canvas)
            scroll(canvas, to: end + 100)
            XCTAssertEqual(release(controller, velocity: speed, target: end), end, "\(speed): the spring back is UIKit's own")
            XCTAssertFalse(controller.isEndCardRevealed, "\(speed)")
            XCTAssertEqual(canvas.contentInset.bottom, 20, accuracy: 0.5, "\(speed)")
            scroll(canvas, to: end)
            controller.scrollViewDidEndDecelerating(canvas)
            XCTAssertTrue(controller.endOfNotebookCard.isHidden, "\(speed)")
        }

        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: end + 100)
        let target = release(controller, velocity: -0.09, target: end)
        XCTAssertTrue(controller.isEndCardRevealed, "A finger held at its depth reveals the card.")
        XCTAssertGreaterThan(target, end + 100, "The page settles lifted.")
    }

    // MARK: - Whole notebook on screen

    /// Zoomed out until the whole notebook fits below the header, the page cannot leave its end,
    /// which is where it rests with or without the card's room. A pull there keeps the card below
    /// the last page through layout and scrolling, and adding a page dismisses it without moving
    /// anything, even in a narrow window where the new page still leaves the card in view.
    func testAPullKeepsTheCardWhereTheWholeNotebookFitsOnScreen() async throws {
        for (size, staysInView) in [(Self.size, false), (CGSize(width: 375, height: 1_194), true)] {
            let rig = try await present(pageCount: 1, size: size)
            defer { rig.close() }
            let controller = rig.controller
            let canvas = rig.canvas
            let card = controller.endOfNotebookCard
            zoomFullyOut(rig)
            let top = -canvas.contentInset.top
            let end = Self.endOffset(of: canvas)
            XCTAssertEqual(end, top, accuracy: 0.5, "\(size.width): the whole notebook fits on screen.")

            controller.scrollViewWillBeginDragging(canvas)
            scroll(canvas, to: end + 100)
            let target = release(controller, velocity: 0.5, target: end)
            XCTAssertTrue(controller.isEndCardRevealed, "\(size.width)")
            XCTAssertEqual(target, top, accuracy: 0.5, "\(size.width): with room below the page, it need not lift.")
            scroll(canvas, to: target)
            controller.scrollViewDidEndDecelerating(canvas)
            assertCardStays(rig, "\(size.width) points wide, after the pull")
            let cardHeight = card.bounds.height

            XCTAssertTrue(press(controller), "\(size.width)")
            XCTAssertEqual(controller.pageCount, 2, "\(size.width)")
            // In the narrow window the two pages still leave the card's place on screen, so only the
            // dismissal that adding a page makes takes the card away.
            XCTAssertEqual(rig.pageBottom + NotebookTheme.endCardGap + cardHeight <= canvas.bounds.height - 20, staysInView,
                "\(size.width)")
            XCTAssertFalse(controller.isEndCardRevealed, "\(size.width): adding a page dismisses the card.")
            XCTAssertTrue(card.isHidden, "\(size.width)")
            XCTAssertEqual(canvas.contentInset.bottom, 20, accuracy: 0.5, "\(size.width): the card's room is given up.")
            XCTAssertEqual(canvas.contentOffset.y, top, accuracy: 0.5, "\(size.width): the page never moves.")
        }
    }

    /// The VoiceOver action keeps the card it reveals where the whole notebook fits on screen: a
    /// single page zoomed out, and the default three pages zoomed out in a narrow window.
    func testTheVoiceOverActionKeepsTheCardWhereTheWholeNotebookFitsOnScreen() async throws {
        for (pages, size) in [(1, Self.size), (3, CGSize(width: 375, height: 1_194))] {
            let rig = try await present(pageCount: pages, size: size)
            defer { rig.close() }
            let canvas = rig.canvas
            zoomFullyOut(rig)
            XCTAssertEqual(Self.endOffset(of: canvas), -canvas.contentInset.top, accuracy: 0.5, "\(pages) pages fit")
            let action = try XCTUnwrap(
                canvas.accessibilityCustomActions?.first { $0.name == NotebookViewController.endCardActionName }
            )
            XCTAssertTrue(try XCTUnwrap(action.actionHandler)(action))
            assertCardStays(rig, "\(pages) pages, \(size.width) points wide")
            try capture(rig.window, name: "end-card-whole-notebook-\(pages)-pages-\(Int(size.width))-wide")
        }
    }

    // MARK: - Card

    func testTheCardOffersExportComingLaterAndAddPageInEveryState() async throws {
        let rig = try await present(pageCount: 11)
        defer { rig.close() }
        let controller = rig.controller
        let card = controller.endOfNotebookCard
        try await revealByPulling(rig)
        XCTAssertEqual(card.addPage, .available)
        XCTAssertEqual(NotebookEndOfNotebookCard.title, "End of notebook")
        XCTAssertEqual(card.content.exportAccessibilityLabel, "Export as PDF, coming later")
        XCTAssertEqual(card.content.addTitle, "Add page")
        XCTAssertTrue(card.content.isAddEnabled)
        XCTAssertEqual(card.content.addHint, "Adds a page at the end of the notebook.")
        XCTAssertFalse(card.accessibilityElementsHidden, "Revealed, the card's keys are reachable.")

        for gate in [NotebookInputGate.capacity, .failed, .recovering, .readOnly] {
            controller.setInputGate(gate)
            XCTAssertEqual(card.addPage, .paused, "\(gate)")
            XCTAssertFalse(card.isHidden, "\(gate): the card stays, its key disabled")
            XCTAssertEqual(card.content.addTitle, "Add page", "\(gate)")
            XCTAssertFalse(card.content.isAddEnabled, "\(gate)")
            XCTAssertNil(card.content.addHint, "\(gate)")
            XCTAssertFalse(press(controller), "\(gate): nothing is added")
        }
        controller.setInputGate(.open)
        XCTAssertEqual(card.addPage, .available)

        // The twelfth page is the last the notebook can hold.
        XCTAssertTrue(press(controller))
        XCTAssertEqual(controller.pageCount, 12)
        XCTAssertFalse(controller.isEndCardRevealed, "Adding a page dismisses the card.")
        rig.scrollToEnd()
        try await revealByPulling(rig)
        XCTAssertEqual(card.addPage, .limitReached)
        XCTAssertEqual(card.content.addTitle, "Paper limit reached")
        XCTAssertFalse(card.content.isAddEnabled)
        XCTAssertFalse(press(controller))
        XCTAssertEqual(controller.pageCount, 12)
    }

    /// The card shows in the space a pull opens, but its key adds a page only once the card is
    /// revealed and stays.
    func testTheCardKeyWorksOnlyOnceTheCardIsRevealed() async throws {
        let rig = try await present()
        defer { rig.close() }
        let controller = rig.controller
        let canvas = rig.canvas
        let end = Self.endOffset(of: canvas)
        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: end + 60)
        XCTAssertFalse(controller.endOfNotebookCard.isHidden)
        XCTAssertFalse(controller.isEndCardRevealed)
        XCTAssertFalse(press(controller), "A card merely pulled into view adds nothing.")
        _ = release(controller, velocity: 0, target: end)
        scroll(canvas, to: end)
        controller.scrollViewDidEndDecelerating(canvas)

        try await revealByPulling(rig)
        XCTAssertTrue(press(controller))
        XCTAssertEqual(controller.pageCount, 11)
    }

    /// Tapping Add page dismisses the card and adds a page that appears where the card was, so it
    /// clears in with the frost, without moving the page.
    func testAddPageFromTheCardAppendsDismissesAndUnfoldsTheNewPage() async throws {
        let rig = try await present()
        defer { rig.close() }
        let controller = rig.controller
        let canvas = rig.canvas
        let unfold = try XCTUnwrap(controller.pageUnfold)
        let ready = await unfold.ready()
        XCTAssertTrue(ready)
        try await revealByPulling(rig)
        let offset = canvas.contentOffset
        let lastPageBottom = rig.pageBottom

        XCTAssertTrue(press(controller))
        XCTAssertEqual(controller.pageCount, 11)
        XCTAssertFalse(controller.isEndCardRevealed)
        XCTAssertTrue(controller.endOfNotebookCard.isHidden)
        XCTAssertEqual(canvas.contentInset.bottom, 20, accuracy: 0.5, "The card's room is given up.")
        XCTAssertEqual(canvas.contentOffset, offset, "The page never moves.")
        XCTAssertTrue(unfold.isPlaying, "The new page shows where the card was, so it clears in.")
        let layer = try XCTUnwrap(unfold.layer)
        let pageHeight = CGFloat(NotebookPaperMetrics.geometry.pageHeight)
        XCTAssertEqual(layer.frame.minY, pageHeight * 10, accuracy: 0.01)
        XCTAssertEqual(layer.frame.height, pageHeight, accuracy: 0.01)
        let onScreen = controller.paperView.contentLayer.convert(layer.frame, to: controller.view.layer)
        XCTAssertEqual(onScreen.minY, lastPageBottom, accuracy: 0.5, "The frost lies on the new page.")
    }

    /// The frost lies inside the paper beneath the canvas: it takes no touches, scrolls and zooms
    /// with the page, and leaves the canvas writing while it clears.
    func testTheFrostLiesBeneathTheCanvasMovesWithThePageAndNeverInterruptsWriting() async throws {
        let rig = try await present()
        defer { rig.close() }
        let controller = rig.controller
        let canvas = rig.canvas
        let paper = controller.paperView
        let unfold = try XCTUnwrap(controller.pageUnfold)
        _ = await unfold.ready()
        controller.setPageCount(11)
        let layer = try XCTUnwrap(unfold.layer, "The end of page 10 shows, so page 11 clears in.")
        rig.scrollToEnd()
        let sublayers = try XCTUnwrap(paper.contentLayer.sublayers)
        let grain = try XCTUnwrap(sublayers.firstIndex { $0 === paper.grainLayer })
        XCTAssertTrue(sublayers[grain + 1] === layer, "Over the paper's grain, under its lines.")
        XCTAssertTrue(paper.isDescendant(of: controller.view))
        let views = controller.view.subviews
        XCTAssertLessThan(try XCTUnwrap(views.firstIndex(of: paper)), try XCTUnwrap(views.firstIndex(of: canvas)),
            "The paper, and the frost in it, lie beneath the canvas.")

        let before = paper.contentLayer.convert(layer.frame, to: controller.view.layer)
        XCTAssertEqual(before.maxY, canvas.bounds.height - 20, accuracy: 0.5)
        let inside = CGPoint(x: before.midX, y: before.maxY - 200)
        XCTAssertTrue(NotebookTestFixtures.hit(inside, in: controller.view).isDescendant(of: canvas),
            "Touches over the frost reach the canvas.")
        XCTAssertTrue(canvas.drawingGestureRecognizer.isEnabled)
        XCTAssertTrue(canvas.isDrawingEnabled)

        // Writing on any page while it clears leaves the frost playing.
        controller.canvasViewDidBeginUsingTool(canvas)
        canvas.drawing = PKDrawing(strokes: [NotebookTestFixtures.stroke(x: 300)])
        controller.canvasViewDidEndUsingTool(canvas)
        XCTAssertTrue(unfold.isPlaying, "A stroke never cuts the frost short.")
        XCTAssertTrue(canvas.drawingGestureRecognizer.isEnabled)

        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: canvas.contentOffset.y - 120)
        controller.scrollViewDidEndDragging(canvas, willDecelerate: false)
        let scrolled = paper.contentLayer.convert(layer.frame, to: controller.view.layer)
        XCTAssertEqual(scrolled.minY, before.minY + 120, accuracy: 0.5, "The frost scrolls with its page.")
        XCTAssertTrue(unfold.isPlaying, "Scrolling never cuts the frost short.")
        let zoom = canvas.zoomScale
        canvas.setZoomScale(zoom * 0.75, animated: false)
        let zoomed = paper.contentLayer.convert(layer.frame, to: controller.view.layer)
        XCTAssertEqual(zoomed.height, scrolled.height * 0.75, accuracy: 0.5, "The frost zooms with its page.")
        XCTAssertTrue(unfold.isPlaying)
        XCTAssertNil(layer.hitTest(CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)))

        controller.tearDown()
        XCTAssertFalse(unfold.isPlaying, "Tear-down finishes the frost.")
        XCTAssertNil(layer.superlayer)
    }

    /// Added from the menu while the user reads page 5, page 11 is out of sight, so it is simply
    /// there; the page the user reads stays put.
    func testAPageAddedOutOfSightAppearsWithoutTheFrost() async throws {
        let rig = try await present()
        defer { rig.close() }
        let controller = rig.controller
        let canvas = rig.canvas
        let unfold = try XCTUnwrap(controller.pageUnfold)
        _ = await unfold.ready()
        let pageHeight = CGFloat(NotebookPaperMetrics.geometry.pageHeight) * canvas.zoomScale
        scroll(canvas, to: pageHeight * 4)
        let offset = canvas.contentOffset
        controller.setPageCount(11)
        XCTAssertEqual(controller.pageCount, 11)
        XCTAssertFalse(unfold.isPlaying)
        XCTAssertNil(unfold.layer)
        XCTAssertEqual(canvas.contentOffset, offset)
        XCTAssertEqual(unfold.framesDrawn, 0)
    }

    // MARK: - Dismissal

    /// Scrolling back up dismisses the card once the page is back where it rests without it, so
    /// giving up its room never moves the page.
    func testScrollingBackUpDismissesTheCardWithoutMovingThePage() async throws {
        let rig = try await present()
        defer { rig.close() }
        let controller = rig.controller
        let canvas = rig.canvas
        let resting = Self.endOffset(of: canvas)
        try await revealByPulling(rig)
        let lifted = canvas.contentOffset.y

        controller.scrollViewWillBeginDragging(canvas)
        var y = lifted - 7
        while y > resting + 1 {
            scroll(canvas, to: y)
            XCTAssertTrue(controller.isEndCardRevealed, "Kept while the page is lifted: \(y)")
            XCTAssertEqual(canvas.contentOffset.y, y, accuracy: 0.5)
            y -= 7
        }
        scroll(canvas, to: resting - 3)
        let dismissedAt = canvas.contentOffset.y
        XCTAssertFalse(controller.isEndCardRevealed)
        XCTAssertTrue(controller.endOfNotebookCard.isHidden)
        XCTAssertEqual(canvas.contentInset.bottom, 20, accuracy: 0.5)
        XCTAssertEqual(dismissedAt, resting - 3, accuracy: 0.5, "Releasing the room moved nothing.")
        controller.scrollViewDidEndDragging(canvas, willDecelerate: false)
        XCTAssertEqual(Self.endOffset(of: canvas), resting, accuracy: 0.5)
    }

    func testTheCardsRoomNeverShrinksDuringAStroke() async throws {
        let rig = try await present()
        defer { rig.close() }
        let controller = rig.controller
        let canvas = rig.canvas
        let resting = Self.endOffset(of: canvas)
        try await revealByPulling(rig)
        let room = canvas.contentInset.bottom
        XCTAssertGreaterThan(room, 20)

        controller.canvasViewDidBeginUsingTool(canvas)
        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: resting - 10)
        let offset = canvas.contentOffset.y
        XCTAssertFalse(controller.isEndCardRevealed)
        XCTAssertEqual(canvas.contentInset.bottom, room, "The room is held while the stroke is in progress.")
        controller.scrollViewDidEndDragging(canvas, willDecelerate: false)
        controller.canvasViewDidEndUsingTool(canvas)
        XCTAssertEqual(canvas.contentInset.bottom, 20, accuracy: 0.5, "Released once the stroke ends.")
        XCTAssertEqual(canvas.contentOffset.y, offset, "The release moved nothing.")
    }

    // MARK: - Assistive technology

    func testVoiceOverActionRevealsTheCard() async throws {
        let rig = try await present()
        defer { rig.close() }
        let controller = rig.controller
        let canvas = rig.canvas
        scroll(canvas, to: 500)
        let action = try XCTUnwrap(
            canvas.accessibilityCustomActions?.first { $0.name == NotebookViewController.endCardActionName }
        )
        XCTAssertEqual(action.name, "End of notebook options")
        let handled = try XCTUnwrap(action.actionHandler)(action)
        XCTAssertTrue(handled)
        XCTAssertTrue(controller.isEndCardRevealed)
        XCTAssertEqual(canvas.contentOffset.y, Self.endOffset(of: canvas), accuracy: 0.5, "At the lifted end.")
        let card = controller.endOfNotebookCard
        XCTAssertFalse(card.isHidden)
        XCTAssertLessThanOrEqual(card.frame.maxY, canvas.bounds.height - 20)
        XCTAssertFalse(card.accessibilityElementsHidden)
        XCTAssertTrue(card.host.parent === controller, "The card's SwiftUI host is the controller's child.")
        assertCardStays(rig, "after the VoiceOver action")
        XCTAssertEqual(card.content.exportAccessibilityLabel, "Export as PDF, coming later")
        XCTAssertEqual(card.content.addTitle, "Add page")

        controller.onAddPage = nil
        XCTAssertNil(canvas.accessibilityCustomActions, "Without a way to add pages there is no card.")
        XCTAssertTrue(card.isHidden)
    }

    func testAViewerHasNoCardAndNoFrost() async throws {
        let controller = NotebookViewController(pageCount: 10, initialDrawing: PKDrawing(), allowsEditing: false)
        controller.onAddPage = { XCTFail("A viewer never adds pages.") }
        let window = UIWindow(windowScene: try NotebookTestFixtures.windowScene())
        window.frame = CGRect(origin: .zero, size: Self.size)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            controller.tearDown()
            window.isHidden = true
            window.rootViewController = nil
        }
        try await NotebookTestFixtures.waitUntilAppeared(controller)
        let canvas = controller.canvasView
        XCTAssertNil(controller.pageUnfold)
        XCTAssertNil(canvas.accessibilityCustomActions)
        let end = Self.endOffset(of: canvas)
        scroll(canvas, to: end)
        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: end + 150)
        _ = release(controller, velocity: 0, target: end)
        XCTAssertFalse(controller.isEndCardRevealed)
        XCTAssertTrue(controller.endOfNotebookCard.isHidden)
        XCTAssertEqual(canvas.contentInset.bottom, 0)
    }

    // MARK: - On the notebook screen

    /// On the notebook screen, a ten-page notebook flung to its end rests with the last page above
    /// the home indicator; a pull lifts it over the card, whose Add page adds the eleventh page
    /// through the session and clears it in. The menu's Add page while reading page 5 adds the
    /// twelfth out of sight.
    func testTheEndOfATenPageNotebookOnTheNotebookScreen() async throws {
        let screen = try await mountScreen(pageCount: 10)
        defer { screen.close() }
        let controller = screen.controller
        let canvas = controller.canvasView
        let session = screen.session
        let unfold = try XCTUnwrap(controller.pageUnfold)
        _ = await unfold.ready()
        let safeBottom = screen.window.safeAreaInsets.bottom
        XCTAssertEqual(canvas.contentInset.bottom, safeBottom, accuracy: 0.5, "No room beyond the home indicator.")

        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: 200)
        let end = Self.endOffset(of: canvas)
        XCTAssertEqual(release(controller, velocity: 12, target: end), end)
        scroll(canvas, to: end)
        controller.scrollViewDidEndDecelerating(canvas)
        try await settle(screen)
        XCTAssertEqual(canvas.contentSize.height - canvas.contentOffset.y, canvas.bounds.height - safeBottom, accuracy: 0.5)
        try capture(screen.window, name: "end-at-rest-ten-pages")

        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: end + 90)
        let lifted = release(controller, velocity: 0.5, target: end)
        scroll(canvas, to: lifted)
        controller.scrollViewDidEndDecelerating(canvas)
        XCTAssertTrue(controller.isEndCardRevealed)
        try await settle(screen)
        try capture(screen.window, name: "end-card-revealed")

        XCTAssertTrue(press(controller))
        XCTAssertEqual(session.pageCount, 11)
        XCTAssertTrue(unfold.isPlaying)
        try await Task.sleep(for: .milliseconds(60))
        let inPlace = render(screen.window)
        // The user scrolls on to the new page while it clears.
        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: Self.endOffset(of: canvas))
        controller.scrollViewDidEndDragging(canvas, willDecelerate: false)
        XCTAssertTrue(unfold.isPlaying, "Scrolling never cuts the frost short.")
        try await Task.sleep(for: .milliseconds(40))
        let scrolled = render(screen.window)
        try write(inPlace, name: "unfold-after-add-page")
        try write(scrolled, name: "unfold-midway-scrolled-to-new-page")
        try await NotebookTestFixtures.waitUntil { !unfold.isPlaying }

        let pageHeight = CGFloat(NotebookPaperMetrics.geometry.pageHeight) * canvas.zoomScale
        scroll(canvas, to: pageHeight * 4 + 200)
        let offset = canvas.contentOffset
        session.extendPaper()
        XCTAssertEqual(session.pageCount, 12)
        XCTAssertFalse(unfold.isPlaying, "Page 12 is out of sight from page 5.")
        XCTAssertEqual(canvas.contentOffset, offset)
        try await settle(screen)
        try capture(screen.window, name: "menu-add-page-on-page-five")

        scroll(canvas, to: Self.endOffset(of: canvas))
        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: Self.endOffset(of: canvas) + 90)
        let liftedAtLimit = release(controller, velocity: 0.5, target: Self.endOffset(of: canvas))
        scroll(canvas, to: liftedAtLimit)
        controller.scrollViewDidEndDecelerating(canvas)
        XCTAssertEqual(controller.endOfNotebookCard.addPage, .limitReached)
        try await settle(screen)
        try capture(screen.window, name: "end-card-twelve-pages")
    }

    /// Every scroll frame moves the paper, the veil, the header and the card with plain layer and
    /// view writes: no SwiftUI view is evaluated again, and the main-thread time per frame stays
    /// small. The report records the measured times.
    func testScrollingThroughTenPagesStaysCheapPerFrame() async throws {
        let screen = try await mountScreen(pageCount: 10)
        defer { screen.close() }
        let controller = screen.controller
        let canvas = controller.canvasView
        let diagnostics = screen.session.renderDiagnostics
        let start = -canvas.contentInset.top
        let end = Self.endOffset(of: canvas)

        controller.scrollViewWillBeginDragging(canvas)
        // The header and tools leave in the first stretch; what follows is the scroll alone.
        for y in stride(from: start, through: start + 300, by: 10) { scroll(canvas, to: y) }
        try await settle(screen)
        let screenBodies = diagnostics.screenBodyCount
        let headerBodies = diagnostics.headerBodyCount
        let canvasUpdates = diagnostics.canvasUpdateCount
        let viewportUpdates = controller.paperView.viewportUpdates
        var times: [Double] = []
        var moves = 0
        let frames = 900
        for frame in 1...frames {
            let y = start + 300 + (end - start - 300) * CGFloat(frame) / CGFloat(frames)
            let previous = canvas.contentOffset.y
            let began = CACurrentMediaTime()
            canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: y), animated: false)
            CATransaction.flush()
            times.append(CACurrentMediaTime() - began)
            if canvas.contentOffset.y != previous { moves += 1 }
        }
        controller.scrollViewDidEndDragging(canvas, willDecelerate: false)
        XCTAssertEqual(controller.paperView.viewportUpdates - viewportUpdates, moves, "The paper follows every frame.")
        XCTAssertEqual(diagnostics.screenBodyCount, screenBodies, "No screen body per frame.")
        XCTAssertEqual(diagnostics.headerBodyCount, headerBodies, "No header body per frame.")
        XCTAssertEqual(diagnostics.canvasUpdateCount, canvasUpdates, "No canvas update per frame.")

        let sorted = times.sorted()
        let median = sorted[sorted.count / 2] * 1_000
        let p95 = sorted[sorted.count * 95 / 100] * 1_000
        let maximum = (sorted.last ?? 0) * 1_000
        try record([
            "scrollFrames": Double(times.count), "scrollFrameMedianMilliseconds": median,
            "scrollFrameP95Milliseconds": p95, "scrollFrameMaximumMilliseconds": maximum
        ], name: "scroll-frame-timing")
        // Smoke bounds under one 120 Hz frame; the report carries the measured times.
        XCTAssertLessThan(median, 4, "Median main-thread time per scroll frame, in milliseconds.")
        XCTAssertLessThan(p95, 8)
    }

    /// While the page is pulled over the card and lifted with it, moving the card re-evaluates
    /// none of its SwiftUI content.
    func testMovingTheCardNeverBuildsItsContentAgain() async throws {
        let rig = try await present()
        defer { rig.close() }
        let controller = rig.controller
        let canvas = rig.canvas
        let card = controller.endOfNotebookCard
        try await revealByPulling(rig)
        try await NotebookTestFixtures.waitUntil { card.diagnostics.bodyCount > 0 }
        await NotebookTestFixtures.drainMainQueue()
        CATransaction.flush()
        let bodies = card.diagnostics.bodyCount
        let lifted = canvas.contentOffset.y
        var positions = Set<CGFloat>()
        controller.scrollViewWillBeginDragging(canvas)
        for step in 0..<40 {
            scroll(canvas, to: lifted + CGFloat(step))
            CATransaction.flush()
            positions.insert(card.frame.minY)
        }
        controller.scrollViewDidEndDragging(canvas, willDecelerate: false)
        await NotebookTestFixtures.drainMainQueue()
        XCTAssertEqual(positions.count, 40, "The card follows the page.")
        XCTAssertEqual(card.diagnostics.bodyCount, bodies, "Moving the card evaluates nothing.")
        XCTAssertTrue(card.layer.animationKeys()?.isEmpty ?? true, "The card follows the page directly.")
    }

    // MARK: - Helpers

    @MainActor
    private struct Rig {
        let controller: NotebookViewController
        let window: UIWindow

        var canvas: PKCanvasView { controller.canvasView }

        /// The bottom of the last page in the controller's view.
        var pageBottom: CGFloat {
            canvas.contentSize.height - canvas.contentOffset.y
        }

        func scrollToEnd() {
            canvas.setContentOffset(
                CGPoint(x: canvas.contentOffset.x, y: NotebookEndOfNotebookTests.endOffset(of: canvas)), animated: false
            )
        }

        func close() {
            controller.tearDown()
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    /// A canvas that adds pages as the session does, under the chrome, scrolled to its end.
    private func present(pageCount: Int = 10, size: CGSize = NotebookEndOfNotebookTests.size) async throws -> Rig {
        let controller = NotebookViewController(
            pageCount: pageCount, initialDrawing: PKDrawing(), toolStore: NotebookTestFixtures.toolStore()
        )
        controller.onAddPage = { [weak controller] in
            guard let controller else { return }
            controller.setPageCount(controller.pageCount + 1)
        }
        let window = UIWindow(windowScene: try NotebookTestFixtures.windowScene())
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        let rig = Rig(controller: controller, window: window)
        do {
            try await NotebookTestFixtures.waitUntil { controller.isCanvasVisible && controller.view.window === window }
        } catch {
            rig.close()
            throw error
        }
        controller.applyChrome(NotebookCanvasChrome(top: Self.chrome.top, bottom: Self.chrome.bottom, canvasSize: size))
        rig.scrollToEnd()
        return rig
    }

    /// Zooms the canvas fully out and rests the page at its end.
    private func zoomFullyOut(_ rig: Rig) {
        rig.canvas.setZoomScale(rig.canvas.minimumZoomScale, animated: false)
        rig.controller.view.layoutIfNeeded()
        rig.scrollToEnd()
    }

    /// Lays the canvas out and reports a scroll where the page already is, as UIKit does on its
    /// own, and checks that the card stays revealed, whole and in view, with the page unmoved.
    private func assertCardStays(_ rig: Rig, _ message: String, line: UInt = #line) {
        let controller = rig.controller
        let canvas = rig.canvas
        let card = controller.endOfNotebookCard
        let offset = canvas.contentOffset
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        controller.scrollViewDidScroll(canvas)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        XCTAssertTrue(controller.isEndCardRevealed, message, line: line)
        XCTAssertFalse(card.isHidden, message, line: line)
        XCTAssertEqual(canvas.contentOffset.y, offset.y, accuracy: 0.5, "\(message): the page stays put", line: line)
        XCTAssertEqual(card.frame.minY, rig.pageBottom + NotebookTheme.endCardGap, accuracy: 0.5, message, line: line)
        XCTAssertLessThanOrEqual(card.frame.maxY, canvas.bounds.height - Self.chrome.bottom + 0.5,
            "\(message): the card shows whole, clear of the home indicator", line: line)
    }

    /// Pulls the page from rest at its end well past the threshold and lets it settle lifted.
    private func revealByPulling(_ rig: Rig) async throws {
        let controller = rig.controller
        let canvas = rig.canvas
        let end = Self.endOffset(of: canvas)
        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: end + 100)
        let target = release(controller, velocity: 0.5, target: end)
        scroll(canvas, to: target)
        controller.scrollViewDidEndDecelerating(canvas)
        XCTAssertTrue(controller.isEndCardRevealed)
        XCTAssertFalse(controller.endOfNotebookCard.isHidden)
        controller.view.layoutIfNeeded()
    }

    private static func endOffset(of canvas: UIScrollView) -> CGFloat {
        max(-canvas.contentInset.top, canvas.contentSize.height - canvas.bounds.height + canvas.contentInset.bottom)
    }

    private func scroll(_ canvas: UIScrollView, to y: CGFloat) {
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: y), animated: false)
    }

    /// Ends a drag as UIKit does, with `target` as the offset UIKit projects, and returns the
    /// offset the deceleration then heads for.
    private func release(_ controller: NotebookViewController, velocity: CGFloat, target: CGFloat) -> CGFloat {
        let canvas = controller.canvasView
        var point = CGPoint(x: canvas.contentOffset.x, y: target)
        controller.scrollViewWillEndDragging(canvas, withVelocity: CGPoint(x: 0, y: velocity), targetContentOffset: &point)
        return point.y
    }

    /// Runs the action the card's face gives its Add page key, even where the key is drawn
    /// disabled, as a tap already under way when the state changes would, and reports whether the
    /// notebook gained a page.
    private func press(_ controller: NotebookViewController) -> Bool {
        let pages = controller.pageCount
        controller.endOfNotebookCard.content.onAddPage()
        return controller.pageCount != pages
    }

    // MARK: Notebook screen

    @MainActor
    private struct MountedScreen {
        let hosting: UIViewController
        let window: UIWindow
        let session: NotebookSession
        let controller: NotebookViewController

        func close() {
            session.flush()
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    /// The notebook screen over a stored notebook of `pageCount` pages, at the 12.9-inch iPad's
    /// portrait size, with the header, the toolbar and the home indicator measured.
    private func mountScreen(pageCount: Int) async throws -> MountedScreen {
        let id = UUID()
        let root = NotebookTestFixtures.root()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let stored = StoredNotebook(
            id: id, revisionID: UUID(), sequence: 1,
            content: NotebookContent(
                title: "Lecture notes", pageCount: pageCount, strokes: try await InkCodec().encode(PKDrawing())
            ),
            savedAt: Date(timeIntervalSince1970: 1_000)
        )
        let probe = try NotebookStorageProbe(stored: stored, recoveryRoot: root)
        let storage = await probe.storage(notebookID: id)
        let session = NotebookSession(notebookID: id, openStorage: { storage })
        let scene = try NotebookTestFixtures.windowScene()
        NotebookTestFixtures.restoreSceneToolDefaults(for: scene, after: self)
        let store = NotebookSceneToolStore.owner(for: scene)
        let toolbar = store.toolbar
        addTeardownBlock { @MainActor in
            store.updateToolbar(toolbar)
            store.setToolsHidden(false)
        }
        store.updateToolbar(.standard)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1_024, height: 1_366)
        let hosting = AppearanceTrackingHostingController(rootView: NotebookScreen(session: session))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        do {
            try await NotebookTestFixtures.waitUntilAppeared(hosting)
            let controller = try await NotebookTestFixtures.waitForValue { () -> NotebookViewController? in
                guard let controller = NotebookTestFixtures.notebookController(in: hosting),
                      controller.isCanvasVisible, store.isToolbarAvailable, store.overlayObstruction.top > 0,
                      controller.canvasView.contentInset.top > 0 else { return nil }
                return controller
            }
            hosting.view.layoutIfNeeded()
            // Tests move the page with programmatic offsets between the drag callbacks.
            session.writingChrome.scrollIsUserDriven = { _ in true }
            return MountedScreen(hosting: hosting, window: window, session: session, controller: controller)
        } catch {
            session.flush()
            window.isHidden = true
            window.rootViewController = nil
            throw error
        }
    }

    private func settle(_ screen: MountedScreen) async throws {
        try await Task.sleep(for: .milliseconds(700))
        screen.window.layoutIfNeeded()
        CATransaction.flush()
    }

    // MARK: Reports

    private func capture(_ view: UIView, name: String) throws {
        try write(render(view), name: name)
    }

    private func render(_ view: UIView) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = view.traitCollection.displayScale
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
    }

    private func write(_ image: UIImage, name: String) throws {
        guard let directory = Self.shotsDirectory else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: url.appendingPathComponent("\(name).png"), options: .atomic)
    }

    private func record(_ values: [String: Double], name: String) throws {
        guard let directory = Self.shotsDirectory else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url.appendingPathComponent("\(name).json"), options: .atomic)
    }
}
