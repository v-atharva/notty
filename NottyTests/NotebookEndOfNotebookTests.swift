import NottyCore
import PencilKit
import SwiftUI
import UIKit
import XCTest
@testable import Notty

/// The end of the notebook: a fling overshoots and bounces as UIKit's own, showing the end card in
/// the space it opens, and a fling that overshoots far enough, or a deliberate pull past the end,
/// lifts the page over the card. A page added where the user can see it clears in with the frost.
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

    /// A fling arriving at the end is UIKit's own: never aimed, never stopped, it overshoots and
    /// bounces back. The card shows in the space each overshoot opens, moving with the page, and a
    /// fling too slow to carry the page the threshold past the end takes it away again on the way
    /// back.
    func testAFlingOvershootsAndBouncesBackNativelyWithTheCardInStep() async throws {
        let rig = try await present()
        defer { rig.close() }
        let controller = rig.controller
        let canvas = rig.canvas
        let card = controller.endOfNotebookCard
        let end = Self.endOffset(of: canvas)
        XCTAssertEqual(canvas.contentInset.bottom, 20, accuracy: 0.5, "The page rests at its end above the home indicator.")
        XCTAssertEqual(end, canvas.contentSize.height - canvas.bounds.height + 20, accuracy: 0.5)

        scroll(canvas, to: end - 1_000)
        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: end - 900)
        // Arriving at the end at 2 points a millisecond, it overshoots by about 68 points.
        XCTAssertEqual(release(controller, velocity: 3.8, target: end), end, "The fling's own target is UIKit's.")
        let writes = OffsetWrites(canvas)
        controller.scrollViewDidEndDragging(canvas, willDecelerate: true)
        decelerate(controller, through: [end - 400, end - 60, end], writes: writes)
        XCTAssertTrue(card.isHidden, "At rest at its end the page leaves no room for the card.")
        for overshoot in [12, 35, 58, 67, 61, 40, 18, 5] as [CGFloat] {
            decelerate(controller, through: [end + overshoot], writes: writes)
            XCTAssertFalse(card.isHidden, "\(overshoot) past the end: the card shows in the space opened")
            XCTAssertEqual(card.frame.minY, rig.pageBottom + NotebookTheme.endCardGap, accuracy: 0.5,
                "\(overshoot) past the end: the card moves with the page")
            XCTAssertFalse(controller.isEndCardRevealed, "\(overshoot)")
        }
        decelerate(controller, through: [end], writes: writes)
        controller.scrollViewDidEndDecelerating(canvas)
        XCTAssertTrue(card.isHidden, "The card leaves with the page.")
        XCTAssertFalse(controller.isEndCardRevealed, "Short of the threshold the bounce takes the card away.")
        XCTAssertEqual(canvas.contentInset.bottom, 20, accuracy: 0.5)
        try await assertNothingMoves(canvas, writes: writes)
    }

    /// A fling bound to overshoot the pull's threshold reveals the card as a pull does, adopting
    /// its room within two frames of reaching the end, while the page still heads there at speed.
    /// Only the room is adopted: the controller never sets the offset, and UIKit's deceleration
    /// runs on through the end into the room untouched, out past the lifted end and back to it.
    func testAFlingBoundToOvershootTheThresholdRevealsTheCardAsItReachesTheEnd() async throws {
        let rig = try await present()
        defer { rig.close() }
        let controller = rig.controller
        let canvas = rig.canvas
        let card = controller.endOfNotebookCard
        let end = Self.endOffset(of: canvas)
        scroll(canvas, to: end - 1_000)
        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: end - 900)
        XCTAssertEqual(release(controller, velocity: 6, target: end), end, "The fling's own target is UIKit's.")
        let writes = OffsetWrites(canvas)
        controller.scrollViewDidEndDragging(canvas, willDecelerate: true)
        // Frames of 100 points, as at 6 points a millisecond at 60 Hz.
        decelerate(controller, through: Array(stride(from: end - 800, through: end - 200, by: 100)), writes: writes)
        XCTAssertFalse(controller.isEndCardRevealed, "More than two frames short of the end.")
        XCTAssertEqual(canvas.contentInset.bottom, 20, accuracy: 0.5)

        decelerate(controller, through: [end - 100], writes: writes)
        XCTAssertTrue(controller.isEndCardRevealed, "Two frames short of the end, far short of the threshold.")
        let room = card.bounds.height + 2 * NotebookTheme.endCardGap
        XCTAssertEqual(canvas.contentInset.bottom, 20 + room, accuracy: 0.5, "Only the room is adopted.")
        XCTAssertTrue(card.isHidden, "The card lies below the window until the page passes the end.")
        let lifted = end + room
        XCTAssertEqual(Self.endOffset(of: canvas), lifted, accuracy: 0.5,
            "UIKit's bounce now ends at the lifted end, as a pull's settles.")

        decelerate(controller, through: [end], writes: writes)
        XCTAssertTrue(controller.isEndCardRevealed, "On its way, the page keeps the room it was given.")
        for y in [end + 95, lifted - 15, lifted + 40, lifted + 62, lifted + 30, lifted + 6, lifted] {
            decelerate(controller, through: [y], writes: writes)
            XCTAssertTrue(controller.isEndCardRevealed, "\(y - end) past the end")
            XCTAssertFalse(card.isHidden, "\(y - end) past the end")
            XCTAssertEqual(card.frame.minY, rig.pageBottom + NotebookTheme.endCardGap, accuracy: 0.5,
                "\(y - end) past the end: the card moves with the page")
        }
        controller.scrollViewDidEndDecelerating(canvas)
        XCTAssertFalse(card.isHidden)
        XCTAssertEqual(card.frame.maxY, canvas.bounds.height - 20 - NotebookTheme.endCardGap, accuracy: 0.5,
            "The same end state as a pull: the card whole, clear of the home indicator.")
        try await assertNothingMoves(canvas, writes: writes)
        XCTAssertEqual(canvas.contentOffset.y, lifted, accuracy: 0.5)

        // As after a pull, scrolling back up dismisses it.
        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: end - 3)
        XCTAssertFalse(controller.isEndCardRevealed)
        XCTAssertEqual(canvas.contentInset.bottom, 20, accuracy: 0.5)
    }

    /// Whether a fling reveals the card follows how fast it reaches the end: UIKit's deceleration
    /// sheds speed with the distance it covers, and its rubber band carries a page past the end by
    /// `flingOvershootTime` of the speed it arrives at. Just short of the pull's threshold the
    /// page bounces back alone; just beyond it the card is revealed.
    func testTheRevealFollowsTheSpeedAFlingReachesTheEndWith() async throws {
        let rig = try await present()
        defer { rig.close() }
        let controller = rig.controller
        let canvas = rig.canvas
        let end = Self.endOffset(of: canvas)
        XCTAssertEqual(NotebookViewController.flingOvershootTime, 34)
        XCTAssertEqual(canvas.decelerationRate, .normal)
        // Released 900 points short of the end, then 2,000 points short: each arrives at a little
        // over 2 points a millisecond at the faster speed and a little under it at the slower.
        for (distance, speed, reveals) in [(900, 3.85, false), (900, 4, true), (2_000, 6.05, false), (2_000, 6.2, true)]
            as [(CGFloat, CGFloat, Bool)] {
            let label = "\(speed) points a millisecond, \(distance) short of the end"
            let overshoot = NotebookViewController.flingOvershoot(
                from: end - distance, speed: speed, end: end, decelerationRate: canvas.decelerationRate
            )
            XCTAssertEqual(overshoot >= NotebookViewController.endRevealPull, reveals, "\(label): \(overshoot)")
            scroll(canvas, to: end - distance - 100)
            controller.scrollViewWillBeginDragging(canvas)
            scroll(canvas, to: end - distance)
            XCTAssertEqual(release(controller, velocity: speed, target: end), end, label)
            controller.scrollViewDidEndDragging(canvas, willDecelerate: true)
            decelerate(controller, through: [end - 40, end + 20], writes: OffsetWrites(canvas))
            XCTAssertEqual(controller.isEndCardRevealed, reveals, label)
            scroll(canvas, to: Self.endOffset(of: canvas))
            controller.scrollViewDidEndDecelerating(canvas)
            XCTAssertEqual(controller.isEndCardRevealed, reveals, label)
            controller.scrollViewWillBeginDragging(canvas)
            scroll(canvas, to: end - 3)
            XCTAssertFalse(controller.isEndCardRevealed, label)
        }

        // A fling UIKit does not aim at the end never reaches it.
        XCTAssertEqual(NotebookViewController.flingOvershoot(
            from: end - 3_000, speed: 4, end: end, decelerationRate: canvas.decelerationRate
        ), 0)
    }

    /// Dropped frames can carry a fling from more than two frames short of the end past it before
    /// the room is adopted. Within the lifted end and still heading out, the room is adopted then.
    /// Beyond the lifted end it never is: UIKit would pull the page straight back to the grown
    /// range's end, and adopted on the way back the room would turn the page round again, so the
    /// page bounces back without the card, as a fling short of the threshold does.
    func testAFlingCarriedPastTheEndByDroppedFramesAdoptsTheRoomOnlyOnItsWayOut() async throws {
        let rig = try await present()
        defer { rig.close() }
        let controller = rig.controller
        let canvas = rig.canvas
        let card = controller.endOfNotebookCard
        let end = Self.endOffset(of: canvas)
        // Shown once, the card has its size.
        scroll(canvas, to: end + 10)
        let lifted = end + card.bounds.height + 2 * NotebookTheme.endCardGap
        XCTAssertGreaterThan(lifted, end + NotebookViewController.endRevealPull + 40)

        scroll(canvas, to: end - 1_000)
        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: end - 900)
        _ = release(controller, velocity: 6, target: end)
        controller.scrollViewDidEndDragging(canvas, willDecelerate: true)
        var writes = OffsetWrites(canvas)
        decelerate(controller, through: [end - 800, end - 700, end + 60], writes: writes)
        XCTAssertTrue(controller.isEndCardRevealed, "Within the lifted end, heading out.")
        XCTAssertEqual(Self.endOffset(of: canvas), lifted, accuracy: 0.5)
        decelerate(controller, through: [lifted + 20, lifted], writes: writes)
        controller.scrollViewDidEndDecelerating(canvas)
        try await assertNothingMoves(canvas, writes: writes)
        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: end - 3)
        controller.scrollViewDidEndDragging(canvas, willDecelerate: false)
        XCTAssertFalse(controller.isEndCardRevealed)

        scroll(canvas, to: end - 1_000)
        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: end - 900)
        _ = release(controller, velocity: 11, target: end)
        writes = OffsetWrites(canvas)
        controller.scrollViewDidEndDragging(canvas, willDecelerate: true)
        decelerate(controller, through: [end - 700, end - 500, lifted + 30, lifted + 55, lifted + 20], writes: writes)
        XCTAssertFalse(controller.isEndCardRevealed, "Beyond the lifted end the room is never adopted.")
        XCTAssertEqual(canvas.contentInset.bottom, 20, accuracy: 0.5)
        XCTAssertFalse(card.isHidden, "The card shows in the overshoot all the same.")
        decelerate(controller, through: [lifted - 4, end + 60, end + 10], writes: writes)
        XCTAssertFalse(controller.isEndCardRevealed, "Nor on the way back.")
        XCTAssertEqual(canvas.contentInset.bottom, 20, accuracy: 0.5)
        decelerate(controller, through: [end], writes: writes)
        controller.scrollViewDidEndDecelerating(canvas)
        XCTAssertTrue(card.isHidden, "The card leaves with the page.")
        try await assertNothingMoves(canvas, writes: writes)
    }

    /// Only a fling let go short of the end counts: a drag carried past it by hand and let go,
    /// flung on, drifting on or heading back, springs back and takes the card with it.
    func testAPageSpringingBackFromPastTheThresholdNeverRevealsTheCard() async throws {
        let rig = try await present()
        defer { rig.close() }
        let controller = rig.controller
        let canvas = rig.canvas
        let end = Self.endOffset(of: canvas)

        for velocity in [3, 0.3, -0.5] as [CGFloat] {
            scroll(canvas, to: end - 300)
            controller.scrollViewWillBeginDragging(canvas)
            scroll(canvas, to: end + 110)
            XCTAssertEqual(release(controller, velocity: velocity, target: end), end, "\(velocity)")
            let writes = OffsetWrites(canvas)
            controller.scrollViewDidEndDragging(canvas, willDecelerate: true)
            decelerate(controller, through: [end + 116, end + 118, end + 100, end + 75], writes: writes)
            XCTAssertFalse(controller.isEndCardRevealed, "\(velocity): springing back")
            XCTAssertEqual(canvas.contentInset.bottom, 20, accuracy: 0.5, "\(velocity)")
            decelerate(controller, through: [end + 30, end], writes: writes)
            controller.scrollViewDidEndDecelerating(canvas)
            XCTAssertFalse(controller.isEndCardRevealed, "\(velocity)")
            XCTAssertTrue(controller.endOfNotebookCard.isHidden, "\(velocity)")
        }

        // Carried past it and let go at rest: no deceleration heads out.
        scroll(canvas, to: end - 300)
        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: end + 100)
        XCTAssertEqual(release(controller, velocity: 0, target: end), end)
        controller.scrollViewDidEndDragging(canvas, willDecelerate: false)
        decelerate(controller, through: [end + 90, end + 40, end], writes: OffsetWrites(canvas))
        XCTAssertFalse(controller.isEndCardRevealed)
        XCTAssertEqual(canvas.contentInset.bottom, 20, accuracy: 0.5)
    }

    /// A fling that falls short of the end is untouched: its target, its offsets and the card.
    func testAFlingThatFallsShortOfTheEndIsUntouched() async throws {
        let rig = try await present()
        defer { rig.close() }
        let controller = rig.controller
        let canvas = rig.canvas
        let end = Self.endOffset(of: canvas)
        scroll(canvas, to: 400)
        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: 600)
        XCTAssertEqual(release(controller, velocity: 3, target: end - 900), end - 900, "Native scrolling decides.")
        let writes = OffsetWrites(canvas)
        controller.scrollViewDidEndDragging(canvas, willDecelerate: true)
        decelerate(controller, through: [700, end - 1_100, end - 950, end - 900], writes: writes)
        controller.scrollViewDidEndDecelerating(canvas)
        XCTAssertTrue(controller.endOfNotebookCard.isHidden)
        XCTAssertFalse(controller.isEndCardRevealed)
        XCTAssertEqual(canvas.contentInset.bottom, 20, accuracy: 0.5)
        try await assertNothingMoves(canvas, writes: writes)
    }

    /// A stroke halts a deceleration without reporting its end, so a fling's overshoot reveals
    /// nothing once the pen is down, and the tick it readied is let go.
    func testAStrokeEndsAFlingsClaimOnTheCard() async throws {
        let rig = try await present()
        defer { rig.close() }
        let controller = rig.controller
        let canvas = rig.canvas
        let end = Self.endOffset(of: canvas)
        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: end - 900)
        _ = release(controller, velocity: 6, target: end)
        controller.scrollViewDidEndDragging(canvas, willDecelerate: true)
        decelerate(controller, through: [end - 800, end - 700, end - 600], writes: OffsetWrites(canvas))
        controller.canvasViewDidBeginUsingTool(canvas)
        scroll(canvas, to: end + 90)
        XCTAssertFalse(controller.isEndCardRevealed)
        XCTAssertEqual(canvas.contentInset.bottom, 20, accuracy: 0.5)
        controller.canvasViewDidEndUsingTool(canvas)
    }

    /// A tap or a stroke that stops a fling in the frames after it adopted the card's room, before
    /// the page reached the end, gives the room back: the fling never lifted the page, which stays
    /// where it stopped. A stroke gives it back as it ends, as no inset shrinks under the pen.
    func testAFlingStoppedJustShortOfTheEndGivesTheRoomBack() async throws {
        let rig = try await present()
        defer { rig.close() }
        let controller = rig.controller
        let canvas = rig.canvas
        let end = Self.endOffset(of: canvas)
        for stop in ["tap", "stroke"] {
            scroll(canvas, to: end - 1_000)
            controller.scrollViewWillBeginDragging(canvas)
            scroll(canvas, to: end - 900)
            _ = release(controller, velocity: 6, target: end)
            controller.scrollViewDidEndDragging(canvas, willDecelerate: true)
            decelerate(controller, through: [end - 200, end - 100], writes: OffsetWrites(canvas))
            XCTAssertTrue(controller.isEndCardRevealed, stop)
            let room = canvas.contentInset.bottom
            XCTAssertGreaterThan(room, 20, stop)
            let writes = OffsetWrites(canvas)
            if stop == "tap" {
                controller.fingerLiftObserver.onLift?()
            } else {
                controller.canvasViewDidBeginUsingTool(canvas)
                XCTAssertEqual(canvas.contentInset.bottom, room, "The room is kept while the pen is down.")
                XCTAssertTrue(controller.endOfNotebookCard.isHidden, "The card lies below the screen meanwhile.")
                try await assertNothingMoves(canvas, writes: writes)
                // Scrolls during the stroke, at the same offset, take nothing away either.
                controller.scrollViewDidScroll(canvas)
                XCTAssertEqual(canvas.contentInset.bottom, room)
                controller.canvasViewDidEndUsingTool(canvas)
            }
            XCTAssertFalse(controller.isEndCardRevealed, stop)
            XCTAssertEqual(canvas.contentInset.bottom, 20, accuracy: 0.5, stop)
            XCTAssertTrue(controller.endOfNotebookCard.isHidden, stop)
            try await assertNothingMoves(canvas, writes: writes)
            XCTAssertEqual(canvas.contentOffset.y, end - 100, accuracy: 0.5, "\(stop): the page stays where it stopped")
        }
    }

    /// A tap that stops the bounce after the card was revealed leaves the page short of its
    /// lifted end; once the finger lifts it eases there, as a pull released at rest does.
    func testATapThatStopsTheBounceFinishesTheLift() async throws {
        let rig = try await present()
        defer { rig.close() }
        let controller = rig.controller
        let canvas = rig.canvas
        let end = Self.endOffset(of: canvas)
        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: end - 900)
        _ = release(controller, velocity: 6, target: end)
        controller.scrollViewDidEndDragging(canvas, willDecelerate: true)
        decelerate(controller, through: [end, end + 80, end + 110], writes: OffsetWrites(canvas))
        XCTAssertTrue(controller.isEndCardRevealed)
        controller.fingerLiftObserver.onLift?()
        let lifted = Self.endOffset(of: canvas)
        try await NotebookTestFixtures.waitUntil { abs(canvas.contentOffset.y - lifted) < 0.5 }
        XCTAssertTrue(controller.isEndCardRevealed)
        XCTAssertFalse(controller.endOfNotebookCard.isHidden)
    }

    /// A drag from the page resting at its end is a pull; one from the lifted end with the card
    /// revealed is no pull, and its own motion is UIKit's.
    func testADragFromTheEndIsUntouchedByTheController() async throws {
        let rig = try await present()
        defer { rig.close() }
        let controller = rig.controller
        let canvas = rig.canvas
        let end = Self.endOffset(of: canvas)

        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: end + 30)
        XCTAssertEqual(release(controller, velocity: 2, target: end + 123), end + 123)
        scroll(canvas, to: end + 60)
        XCTAssertEqual(canvas.contentOffset.y, end + 60, accuracy: 0.5, "Nothing halts a pull's own motion.")
        controller.scrollViewDidEndDecelerating(canvas)

        scroll(canvas, to: end)
        try await revealByPulling(rig)
        let lifted = Self.endOffset(of: canvas)
        controller.scrollViewWillBeginDragging(canvas)
        XCTAssertEqual(release(controller, velocity: 4, target: lifted + 123), lifted + 123)
        controller.scrollViewDidEndDecelerating(canvas)
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

        // Resting a point and a half short of the end is not resting at it: the drag shows the card
        // in the space it opens, but letting go there reveals nothing.
        scroll(canvas, to: end - 1.5)
        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: end + 140)
        XCTAssertFalse(card.isHidden)
        _ = release(controller, velocity: 0, target: end)
        XCTAssertFalse(controller.isEndCardRevealed)
        scroll(canvas, to: end)
        controller.scrollViewDidEndDecelerating(canvas)
        XCTAssertTrue(card.isHidden, "The card leaves with the page.")

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

    /// Tapping Add page dismisses the card and adds a page that appears where the card was. It
    /// clears in with the frost while the paper scrolls on until the new page's top rests at the
    /// top of the visible area, below the header and toolbar room, so the frost is seen clearing
    /// down from its top edge rather than across the strip the card left; the page is taller than
    /// that area, so its foot finishes clearing below the screen.
    func testAddPageFromTheCardBringsTheNewPageIntoViewWhileItClears() async throws {
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
        XCTAssertEqual(canvas.contentOffset, offset, "Adding the page moves nothing by itself.")
        XCTAssertTrue(unfold.isPlaying, "The new page shows where the card was, so it clears in.")
        XCTAssertTrue(controller.isBringingAddedPageIntoView)
        let layer = try XCTUnwrap(unfold.layer)
        let pageHeight = CGFloat(NotebookPaperMetrics.geometry.pageHeight)
        XCTAssertEqual(layer.frame.minY, pageHeight * 10, accuracy: 0.01)
        XCTAssertEqual(layer.frame.height, pageHeight, accuracy: 0.01)
        func frostOnScreen() -> CGRect {
            controller.paperView.contentLayer.convert(layer.frame, to: controller.view.layer)
        }
        XCTAssertEqual(frostOnScreen().minY, lastPageBottom, accuracy: 0.5, "The frost lies on the new page.")

        // The page comes into view while the frost still clears.
        try await NotebookTestFixtures.waitUntil { canvas.contentOffset.y > offset.y + 300 }
        XCTAssertTrue(unfold.isPlaying, "The page comes into view while the frost still clears.")
        XCTAssertEqual(frostOnScreen().minY, rig.pageBottom - pageHeight * canvas.zoomScale, accuracy: 0.5,
            "The frost moves with its page.")
        let started = CACurrentMediaTime()
        try await NotebookTestFixtures.waitUntil { !controller.isBringingAddedPageIntoView }
        XCTAssertLessThan(CACurrentMediaTime() - started, 1)
        XCTAssertEqual(canvas.contentOffset.y, Self.arrivalOffset(of: canvas, pages: 11), accuracy: 0.5)
        XCTAssertEqual(frostOnScreen().minY, canvas.contentInset.top, accuracy: 0.5,
            "The new page's top rests at the top of the visible area.")
        XCTAssertGreaterThan(rig.pageBottom, canvas.bounds.height, "Its foot lies below the screen.")
        XCTAssertEqual(canvas.contentOffset.x, offset.x)
        let writes = OffsetWrites(canvas)
        try await assertNothingMoves(canvas, writes: writes)
    }

    /// The scroll on to the new page eases off from rest however long the work of adding it held
    /// the main thread, and comes to rest as the frost finishes clearing.
    func testTheNewPageEasesIntoViewAndLandsAsItsFrostClears() async throws {
        let rig = try await present()
        defer { rig.close() }
        let controller = rig.controller
        let canvas = rig.canvas
        let unfold = try XCTUnwrap(controller.pageUnfold)
        _ = await unfold.ready()
        try await revealByPulling(rig)
        let from = canvas.contentOffset.y
        let writes = OffsetWrites(canvas)
        XCTAssertTrue(press(controller))
        let clearingEnd = try XCTUnwrap(unfold.clearingEnd)
        // A busy main thread, as a slow save might keep it, holds back the first frame.
        let busyUntil = CACurrentMediaTime() + 0.1
        while CACurrentMediaTime() < busyUntil {}
        try await NotebookTestFixtures.waitUntil { !controller.isBringingAddedPageIntoView }
        let landed = CACurrentMediaTime()
        let first = try XCTUnwrap(writes.verticalOffsets.first)
        XCTAssertLessThan(first - from, 60, "The page eases off from rest instead of jumping.")
        XCTAssertGreaterThan(first, from)
        XCTAssertEqual(landed, clearingEnd, accuracy: 0.1, "The page comes to rest as the frost clears.")
        XCTAssertEqual(canvas.contentOffset.y, Self.arrivalOffset(of: canvas, pages: 11), accuracy: 0.5)
        XCTAssertEqual(writes.verticalOffsets.sorted(), writes.verticalOffsets, "It never turns back.")
    }

    /// Once the new page has come to rest, the card is readied for the notebook as it now stands,
    /// here at the page limit, so the next overshoot builds nothing beneath the moving page.
    func testTheCardIsReadiedAgainOnceTheNewPageComesToRest() async throws {
        let rig = try await present(pageCount: NotebookViewController.maximumPageCount - 1)
        defer { rig.close() }
        let controller = rig.controller
        let card = controller.endOfNotebookCard
        _ = await controller.pageUnfold?.ready()
        try await revealByPulling(rig)
        XCTAssertEqual(card.addPage, .available)
        XCTAssertTrue(press(controller))
        XCTAssertTrue(controller.isBringingAddedPageIntoView)
        try await NotebookTestFixtures.waitUntil { !controller.isBringingAddedPageIntoView }
        await NotebookTestFixtures.drainMainQueue()
        XCTAssertEqual(card.addPage, .limitReached)
        let bodies = card.diagnostics.bodyCount
        let canvas = rig.canvas
        let end = Self.endOffset(of: canvas)
        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: end + 30)
        XCTAssertFalse(card.isHidden)
        XCTAssertEqual(card.diagnostics.bodyCount, bodies, "The overshoot builds nothing.")
        scroll(canvas, to: end)
        controller.scrollViewDidEndDragging(canvas, willDecelerate: false)
    }

    /// Only a page the user asked for moves the paper: one the notebook adds on its own, as when
    /// writing reaches the foot of the last page, appears where it lies even with the end in view.
    func testOnlyAPageTheUserAskedForMovesThePaper() async throws {
        let rig = try await present()
        defer { rig.close() }
        let controller = rig.controller
        let canvas = rig.canvas
        let unfold = try XCTUnwrap(controller.pageUnfold)
        _ = await unfold.ready()
        let offset = canvas.contentOffset
        controller.setPageCount(11)
        XCTAssertTrue(unfold.isPlaying, "The end of page 10 shows, so page 11 clears in.")
        XCTAssertFalse(controller.isBringingAddedPageIntoView)
        let writes = OffsetWrites(canvas)
        try await assertNothingMoves(canvas, writes: writes)
        XCTAssertEqual(canvas.contentOffset, offset)

        // A page the user asked for is brought into view.
        rig.scrollToEnd()
        controller.setPageCount(12, bringingIntoView: true)
        XCTAssertTrue(controller.isBringingAddedPageIntoView)
        try await NotebookTestFixtures.waitUntil { !controller.isBringingAddedPageIntoView }
        XCTAssertEqual(canvas.contentOffset.y, Self.arrivalOffset(of: canvas, pages: 12), accuracy: 0.5)
    }

    /// A new page shorter than the visible area cannot bring its top up to the top of that area,
    /// so the paper scrolls on only as far as its end.
    func testANewPageShorterThanTheViewRestsAtTheEndOfThePaper() async throws {
        let rig = try await present()
        defer { rig.close() }
        let controller = rig.controller
        let canvas = rig.canvas
        _ = await controller.pageUnfold?.ready()
        zoomFullyOut(rig)
        try await revealByPulling(rig)
        XCTAssertTrue(press(controller))
        XCTAssertTrue(controller.isBringingAddedPageIntoView)
        try await NotebookTestFixtures.waitUntil { !controller.isBringingAddedPageIntoView }
        let pageTop = CGFloat(NotebookPaperMetrics.geometry.pageHeight) * 10 * canvas.zoomScale
        XCTAssertGreaterThan(pageTop - canvas.contentInset.top, Self.endOffset(of: canvas), "The end comes first.")
        XCTAssertEqual(canvas.contentOffset.y, Self.endOffset(of: canvas), accuracy: 0.5)
        XCTAssertEqual(rig.pageBottom, canvas.bounds.height - Self.chrome.bottom, accuracy: 0.5)
    }

    /// The page never moves under the pen or a finger: a stroke under way when the page is added
    /// keeps the paper still, and a stroke, a drag or a pinch that begins while the paper scrolls
    /// on stops it where it is.
    func testBringingTheNewPageIntoViewNeverMovesThePageUnderAStrokeOrAFinger() async throws {
        let rig = try await present(pageCount: 8)
        defer { rig.close() }
        let controller = rig.controller
        let canvas = rig.canvas
        _ = await controller.pageUnfold?.ready()

        try await revealByPulling(rig)
        controller.canvasViewDidBeginUsingTool(canvas)
        XCTAssertTrue(press(controller))
        XCTAssertFalse(controller.isBringingAddedPageIntoView, "A stroke is under way.")
        controller.canvasViewDidEndUsingTool(canvas)
        let writes = OffsetWrites(canvas)
        try await assertNothingMoves(canvas, writes: writes)

        for interruption in ["stroke", "drag", "pinch"] {
            rig.scrollToEnd()
            try await revealByPulling(rig)
            let start = canvas.contentOffset.y
            XCTAssertTrue(press(controller), interruption)
            XCTAssertTrue(controller.isBringingAddedPageIntoView, interruption)
            try await NotebookTestFixtures.waitUntil { canvas.contentOffset.y > start + 20 }
            XCTAssertTrue(controller.isBringingAddedPageIntoView, "\(interruption): still on its way")
            switch interruption {
            case "stroke": controller.canvasViewDidBeginUsingTool(canvas)
            case "drag": controller.scrollViewWillBeginDragging(canvas)
            default: controller.scrollViewWillBeginZooming(canvas, with: nil)
            }
            XCTAssertFalse(controller.isBringingAddedPageIntoView, interruption)
            let stopped = OffsetWrites(canvas)
            try await assertNothingMoves(canvas, writes: stopped)
            switch interruption {
            case "stroke": controller.canvasViewDidEndUsingTool(canvas)
            case "drag": controller.scrollViewDidEndDragging(canvas, willDecelerate: false)
            default: controller.scrollViewDidEndZooming(canvas, with: nil, atScale: canvas.zoomScale)
            }
        }
        XCTAssertEqual(controller.pageCount, 12)
    }

    /// Under Reduce Motion the paper is set at once where the scroll on to the new page would come
    /// to rest, with the page's top at the top of the visible area, while the page fades in there;
    /// nothing moves after. Under the pen the paper stays where it lies.
    func testUnderReduceMotionThePaperJumpsToTheNewPageAsItFadesIn() async throws {
        let unfold = NotebookPageUnfold(prefersReducedMotion: { true })
        _ = await unfold.ready()
        let rig = try await present(pageUnfold: unfold)
        defer { rig.close() }
        let controller = rig.controller
        let canvas = rig.canvas
        try await revealByPulling(rig)
        let offset = canvas.contentOffset
        XCTAssertTrue(press(controller))
        XCTAssertTrue(unfold.isPlaying, "The page fades in.")
        XCTAssertFalse(controller.isBringingAddedPageIntoView, "Nothing scrolls.")
        XCTAssertEqual(canvas.contentOffset.y, Self.arrivalOffset(of: canvas, pages: 11), accuracy: 0.5)
        XCTAssertEqual(canvas.contentOffset.x, offset.x)
        let layer = try XCTUnwrap(unfold.layer)
        let fadeTop = controller.paperView.contentLayer.convert(layer.frame, to: controller.view.layer).minY
        XCTAssertEqual(fadeTop, canvas.contentInset.top, accuracy: 0.5, "The page fades in at the top of the visible area.")
        let writes = OffsetWrites(canvas)
        try await assertNothingMoves(canvas, writes: writes)

        rig.scrollToEnd()
        try await revealByPulling(rig)
        let underPen = canvas.contentOffset
        controller.canvasViewDidBeginUsingTool(canvas)
        XCTAssertTrue(press(controller))
        XCTAssertEqual(canvas.contentOffset, underPen, "A stroke is under way.")
        controller.canvasViewDidEndUsingTool(canvas)
        try await assertNothingMoves(canvas, writes: OffsetWrites(canvas))
        XCTAssertEqual(controller.pageCount, 12)
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

    /// On the notebook screen, an eight-page notebook flung to its end rests with the last page
    /// above the home indicator; a pull lifts it over the card, whose Add page adds the ninth page
    /// through the session. The frost plays in full on the production path: its layer goes into
    /// the paper over the grain, it draws a frame each display frame for its whole length rather
    /// than being cut short by the slow-frame guard, and the paper scrolls on to the new page
    /// meanwhile. The menu's Add page with the end in view clears its page in too, and the paper
    /// scrolls on to it from the strip under the home indicator. Writing that reaches the foot of
    /// the last page adds the eleventh page on its own: it clears in where it lies, and the paper
    /// never moves under the pen. From page 5 the twelfth page is simply there.
    func testTheEndOfANotebookOnTheNotebookScreen() async throws {
        let screen = try await mountScreen(pageCount: 8)
        defer { screen.close() }
        let controller = screen.controller
        let canvas = controller.canvasView
        let session = screen.session
        let paper = controller.paperView
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
        try capture(screen.window, name: "end-at-rest")

        controller.scrollViewWillBeginDragging(canvas)
        scroll(canvas, to: end + 90)
        let lifted = release(controller, velocity: 0.5, target: end)
        scroll(canvas, to: lifted)
        controller.scrollViewDidEndDecelerating(canvas)
        XCTAssertTrue(controller.isEndCardRevealed)
        try await settle(screen)
        try capture(screen.window, name: "end-card-revealed")

        let pressed = CACurrentMediaTime()
        XCTAssertTrue(press(controller))
        XCTAssertEqual(session.pageCount, 9)
        XCTAssertTrue(unfold.isPlaying)
        let layer = try XCTUnwrap(unfold.layer)
        let sublayers = try XCTUnwrap(paper.contentLayer.sublayers)
        let grain = try XCTUnwrap(sublayers.firstIndex { $0 === paper.grainLayer })
        XCTAssertTrue(sublayers[grain + 1] === layer, "The frost is in the paper, over the grain.")
        XCTAssertEqual(unfold.framesDrawn, 1, "The first frame shows with the page.")
        XCTAssertTrue(controller.isBringingAddedPageIntoView)
        try await NotebookTestFixtures.waitUntil { !unfold.isPlaying }
        let played = CACurrentMediaTime() - pressed
        let frames = unfold.framesDrawn
        // The clearing lasts about 950 ms; the slow-frame guard would end it within about 120 ms.
        XCTAssertGreaterThan(played, 0.85, "The frost played its whole length.")
        XCTAssertGreaterThan(frames, 30, "A frame drawn for each display frame.")
        try await NotebookTestFixtures.waitUntil { !controller.isBringingAddedPageIntoView }
        XCTAssertEqual(canvas.contentOffset.y, Self.arrivalOffset(of: canvas, pages: 9), accuracy: 0.5,
            "The new page's top rests at the top of the visible area.")
        try record(["cardAddFrostSeconds": played, "cardAddFrostFrames": Double(frames)], name: "card-add-frost")
        try await settle(screen)
        try capture(screen.window, name: "card-add-page-arrived")

        // The menu's Add page with the end in view: the new page's top lies under the home indicator.
        scroll(canvas, to: Self.endOffset(of: canvas))
        session.extendPaper()
        XCTAssertEqual(session.pageCount, 10)
        XCTAssertTrue(unfold.isPlaying, "The new page's top shows, so it clears in.")
        let pageHeight = CGFloat(NotebookPaperMetrics.geometry.pageHeight) * canvas.zoomScale
        let newPageTop = canvas.contentSize.height - canvas.contentOffset.y - pageHeight
        XCTAssertEqual(canvas.bounds.height - newPageTop, safeBottom, accuracy: 0.5,
            "Only the strip under the home indicator shows the new page.")
        XCTAssertTrue(controller.isBringingAddedPageIntoView, "The user asked for the page, so the paper scrolls on to it.")
        try await NotebookTestFixtures.waitUntil { !unfold.isPlaying && !controller.isBringingAddedPageIntoView }
        XCTAssertEqual(canvas.contentOffset.y, Self.arrivalOffset(of: canvas, pages: 10), accuracy: 0.5,
            "The new page's top rests at the top of the visible area.")

        // Writing at the foot of the last page with the end in view: once the stroke ends, the
        // notebook adds a page of its own, which clears in where it lies.
        scroll(canvas, to: Self.endOffset(of: canvas))
        let atEnd = canvas.contentOffset
        var stroke = NotebookTestFixtures.stroke(x: 300)
        stroke.transform = CGAffineTransform(
            translationX: 0, y: CGFloat(NotebookPaperMetrics.geometry.pageHeight) * (CGFloat(session.pageCount) - 0.1)
        )
        let writes = OffsetWrites(canvas)
        controller.canvasViewDidBeginUsingTool(canvas)
        canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes + [stroke])
        controller.canvasViewDidEndUsingTool(canvas)
        try await NotebookTestFixtures.waitUntil { session.pageCount == 11 }
        XCTAssertEqual(controller.pageCount, 11)
        XCTAssertTrue(unfold.isPlaying, "The new page's top shows, so it clears in.")
        XCTAssertFalse(controller.isBringingAddedPageIntoView, "A page the notebook adds itself never moves the paper.")
        try await NotebookTestFixtures.waitUntil { !unfold.isPlaying }
        XCTAssertEqual(writes.changes, 0, "Nothing moved the page under the pen.")
        XCTAssertEqual(canvas.contentOffset, atEnd)

        scroll(canvas, to: pageHeight * 4 + 200)
        let offset = canvas.contentOffset
        session.extendPaper()
        XCTAssertEqual(session.pageCount, 12)
        XCTAssertFalse(unfold.isPlaying, "Page 12 is out of sight from page 5.")
        XCTAssertFalse(controller.isBringingAddedPageIntoView)
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

    /// The card is built soon after the canvas appears, so the first overshoot past the end shows
    /// it without building its content beneath a moving page. A stroke under way puts that off
    /// until the stroke ends.
    func testTheCardIsBuiltBeforeThePageFirstOvershoots() async throws {
        for writing in [false, true] {
            let rig = try await present()
            defer { rig.close() }
            let controller = rig.controller
            let canvas = rig.canvas
            let card = controller.endOfNotebookCard
            let end = Self.endOffset(of: canvas)
            if writing { controller.canvasViewDidBeginUsingTool(canvas) }
            XCTAssertEqual(card.bounds.height, 0, "\(writing): not built yet")
            try await Task.sleep(for: .seconds(controller.endCardPreparationDelay + 0.3))
            if writing {
                XCTAssertEqual(card.bounds.height, 0, "Never while a stroke is under way.")
                controller.canvasViewDidEndUsingTool(canvas)
                XCTAssertEqual(card.bounds.height, 0, "Not within the stroke's own callback.")
                await NotebookTestFixtures.drainMainQueue()
            }
            XCTAssertGreaterThan(card.bounds.height, 0, "\(writing): built")
            XCTAssertTrue(card.isHidden, "\(writing)")
            XCTAssertEqual(canvas.contentOffset.y, end, accuracy: 0.5, "\(writing): the page never moved")
            let bodies = card.diagnostics.bodyCount
            XCTAssertGreaterThan(bodies, 0, "\(writing)")

            controller.scrollViewWillBeginDragging(canvas)
            scroll(canvas, to: end + 30)
            CATransaction.flush()
            XCTAssertFalse(card.isHidden, "\(writing)")
            XCTAssertEqual(card.diagnostics.bodyCount, bodies, "\(writing): the first overshoot builds nothing")
            scroll(canvas, to: end)
            controller.scrollViewDidEndDragging(canvas, willDecelerate: false)
        }
    }

    /// A pinch, a touch that stops a fling or a scroll to the top builds the card as it ends, on
    /// the next turn, so a scroll on to the end soon after finds it built even where it began
    /// before the preparation that follows the canvas's appearance. These canvases put that
    /// preparation off past the test, so only the callbacks build the card, however busy the run.
    /// None builds it beneath a stroke; the stroke's own end does.
    func testTheEndOfAPinchATouchOrAScrollToTheTopBuildsTheCard() async throws {
        let ends: [(String, @MainActor (NotebookViewController, PKCanvasView) -> Void)] = [
            ("pinch", { $0.scrollViewDidEndZooming($1, with: nil, atScale: $1.zoomScale) }),
            ("touch", { controller, _ in controller.fingerLiftObserver.onLift?() }),
            ("scroll to the top", { $0.scrollViewDidScrollToTop($1) })
        ]
        for (name, end) in ends {
            for writing in [false, true] {
                let rig = try await present(endCardPreparationDelay: 600)
                defer { rig.close() }
                let controller = rig.controller
                let canvas = rig.canvas
                let card = controller.endOfNotebookCard
                XCTAssertEqual(card.bounds.height, 0, "\(name), \(writing): not built yet")
                if writing { controller.canvasViewDidBeginUsingTool(canvas) }
                end(controller, canvas)
                XCTAssertEqual(card.bounds.height, 0, "\(name), \(writing): not within the callback")
                await NotebookTestFixtures.drainMainQueue()
                if writing {
                    XCTAssertEqual(card.bounds.height, 0, "\(name): never while a stroke is under way")
                    controller.canvasViewDidEndUsingTool(canvas)
                    await NotebookTestFixtures.drainMainQueue()
                    XCTAssertGreaterThan(card.bounds.height, 0, "\(name): built once the stroke ends")
                } else {
                    XCTAssertGreaterThan(card.bounds.height, 0, "\(name): built as it ends")
                }
                XCTAssertTrue(card.isHidden, "\(name), \(writing)")
            }
        }
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
    /// - Parameter endCardPreparationDelay: how long after appearing the canvas first builds the
    ///   card, when not its own.
    private func present(
        pageCount: Int = 10, size: CGSize = NotebookEndOfNotebookTests.size, pageUnfold: NotebookPageUnfold? = nil,
        endCardPreparationDelay: TimeInterval? = nil
    ) async throws -> Rig {
        let controller = NotebookViewController(
            pageCount: pageCount, initialDrawing: PKDrawing(), toolStore: NotebookTestFixtures.toolStore(),
            pageUnfold: pageUnfold
        )
        if let endCardPreparationDelay { controller.endCardPreparationDelay = endCardPreparationDelay }
        controller.onAddPage = { [weak controller] in
            guard let controller else { return }
            controller.setPageCount(controller.pageCount + 1, bringingIntoView: true)
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

    /// Where the scroll on to the last of `pages`, just added, comes to rest: with its top at the
    /// top of the visible area below the header and toolbar room, or at the end where that comes first.
    private static func arrivalOffset(of canvas: UIScrollView, pages: Int) -> CGFloat {
        let top = CGFloat(NotebookPaperMetrics.geometry.pageHeight) * CGFloat(pages - 1) * canvas.zoomScale
        return min(endOffset(of: canvas), top - canvas.contentInset.top)
    }

    private func scroll(_ canvas: UIScrollView, to y: CGFloat) {
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: y), animated: false)
    }

    /// Moves the page through `offsets`, one frame each, as a deceleration and its bounce do, and
    /// checks that each stays where it was put: the controller sets no offset of its own.
    private func decelerate(
        _ controller: NotebookViewController, through offsets: [CGFloat], writes: OffsetWrites, line: UInt = #line
    ) {
        let canvas = controller.canvasView
        for y in offsets {
            let before = writes.changes
            scroll(canvas, to: y)
            XCTAssertEqual(canvas.contentOffset.y, y, accuracy: 0.5, "The page stays at \(y).", line: line)
            XCTAssertLessThanOrEqual(writes.changes - before, 1,
                "Only the frame itself moved the page to \(y).", line: line)
        }
    }

    /// Lets several display frames pass and checks that nothing moved the page meanwhile.
    private func assertNothingMoves(_ canvas: UIScrollView, writes: OffsetWrites, line: UInt = #line) async throws {
        let changes = writes.changes
        let offset = canvas.contentOffset
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(writes.changes, changes, "The controller moved the page.", line: line)
        XCTAssertEqual(canvas.contentOffset, offset, line: line)
    }

    /// Counts every change of the canvas's offset, whoever makes it.
    @MainActor
    private final class OffsetWrites {
        private(set) var changes = 0
        /// Each vertical offset written, in order.
        private(set) var verticalOffsets: [CGFloat] = []
        private var observation: NSKeyValueObservation?

        init(_ canvas: UIScrollView) {
            observation = canvas.observe(\.contentOffset, options: [.old, .new]) { [weak self] _, change in
                guard change.oldValue != change.newValue, let y = change.newValue?.y else { return }
                MainActor.assumeIsolated {
                    self?.changes += 1
                    self?.verticalOffsets.append(y)
                }
            }
        }
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
