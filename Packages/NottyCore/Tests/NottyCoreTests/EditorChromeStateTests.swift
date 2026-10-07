import CoreGraphics
import XCTest
@testable import NottyCore

final class EditorChromeStateTests: XCTestCase {
    private let hide = EditorChromeState.hideTravel
    private let reveal = EditorChromeState.revealTravel

    private func assertShows(
        _ state: EditorChromeState, header: Bool, tools: Bool, handle: Bool,
        _ message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(state.showsHeader, header, "header \(message)", file: file, line: line)
        XCTAssertEqual(state.showsTools, tools, "tools \(message)", file: file, line: line)
        XCTAssertEqual(state.showsRevealHandle, handle, "handle \(message)", file: file, line: line)
    }

    /// Scrolled away from the top, with whatever the mode can hide hidden.
    private func scrolledDown(in mode: EditorChromeMode) -> EditorChromeState {
        var state = EditorChromeState(mode: mode)
        state.userScrolled(by: 100, isAtTop: false)
        return state
    }

    private func transientToken(_ state: inout EditorChromeState) throws -> UInt64 {
        try XCTUnwrap(state.reveal(.transient).transientToken)
    }

    // MARK: Modes

    func testEveryModeStartsWithHeaderAndToolsShownAndFocusIsTheDefault() {
        XCTAssertEqual(EditorChromeState().mode, .focus)
        for mode in EditorChromeMode.allCases {
            assertShows(EditorChromeState(mode: mode), header: true, tools: true, handle: false, mode.rawValue)
        }
    }

    func testFocusModeHidesHeaderAndToolsWhenAStrokeEndsNotWhenItBegins() {
        var state = EditorChromeState()
        XCTAssertFalse(state.toolBegan())
        assertShows(state, header: true, tools: true, handle: false, "nothing moves as the pen lands")

        XCTAssertTrue(state.toolEnded())
        assertShows(state, header: false, tools: false, handle: true)
        XCTAssertFalse(state.toolBegan())
        XCTAssertFalse(state.toolEnded(), "already hidden")
    }

    func testAStrokeEndingWithoutABeginningStillHidesInFocusMode() {
        var state = EditorChromeState()
        XCTAssertTrue(state.toolEnded())
        assertShows(state, header: false, tools: false, handle: true)
    }

    func testOverlayModeKeepsEverythingThroughStrokesAndScrollsOnlyTheHeaderAway() {
        var state = EditorChromeState(mode: .overlay)
        XCTAssertFalse(state.toolBegan())
        XCTAssertFalse(state.toolEnded())
        assertShows(state, header: true, tools: true, handle: false, "strokes leave the header alone")

        XCTAssertTrue(state.userScrolled(by: hide, isAtTop: false))
        assertShows(state, header: false, tools: true, handle: false)
        XCTAssertFalse(state.toolEnded())
        XCTAssertTrue(state.userScrolled(by: -reveal, isAtTop: false))
        assertShows(state, header: true, tools: true, handle: false)
    }

    func testPinnedModeNeverHidesAnything() {
        var state = EditorChromeState(mode: .pinned)
        XCTAssertFalse(state.toolBegan())
        XCTAssertFalse(state.toolEnded())
        XCTAssertFalse(state.userScrolled(by: 500, isAtTop: false))
        XCTAssertFalse(state.toggle())
        XCTAssertFalse(state.reveal(.sticky).visibilityChanged)
        XCTAssertFalse(state.reveal(.transient).visibilityChanged)
        XCTAssertFalse(state.userScrolled(by: -500, isAtTop: true))
        assertShows(state, header: true, tools: true, handle: false)
    }

    func testChangingModeShowsEverythingButChoosingTheSameModeChangesNothing() {
        var state = EditorChromeState()
        state.toolEnded()
        XCTAssertFalse(state.setMode(.focus))
        assertShows(state, header: false, tools: false, handle: true)

        XCTAssertTrue(state.setMode(.overlay))
        XCTAssertEqual(state.mode, .overlay)
        assertShows(state, header: true, tools: true, handle: false)

        state.userScrolled(by: hide, isAtTop: false)
        XCTAssertTrue(state.setMode(.focus))
        assertShows(state, header: true, tools: true, handle: false, "a chosen mode starts fully shown")

        XCTAssertFalse(state.setMode(.pinned), "everything was already shown")
        XCTAssertEqual(state.mode, .pinned)
    }

    func testLeavingPinnedModeStartsFromEverythingShown() {
        var state = EditorChromeState(mode: .pinned)
        state.userScrolled(by: 500, isAtTop: false)
        XCTAssertFalse(state.setMode(.focus))
        assertShows(state, header: true, tools: true, handle: false)
        XCTAssertFalse(state.userScrolled(by: hide - 1, isAtTop: false), "travel restarts with the new mode")
        XCTAssertTrue(state.userScrolled(by: 1, isAtTop: false))
    }

    // MARK: Scrolling

    func testDownwardTravelHidesOnceItReachesTheThreshold() {
        var state = EditorChromeState()
        XCTAssertFalse(state.userScrolled(by: hide - 1, isAtTop: false))
        assertShows(state, header: true, tools: true, handle: false)
        XCTAssertTrue(state.userScrolled(by: 1, isAtTop: false))
        assertShows(state, header: false, tools: false, handle: true)
        XCTAssertFalse(state.userScrolled(by: 300, isAtTop: false), "already hidden")
    }

    func testUpwardTravelRevealsOnceItReachesTheThreshold() {
        var state = scrolledDown(in: .focus)
        XCTAssertFalse(state.userScrolled(by: -(reveal - 1), isAtTop: false))
        assertShows(state, header: false, tools: false, handle: true)
        XCTAssertTrue(state.userScrolled(by: -1, isAtTop: false))
        assertShows(state, header: true, tools: true, handle: false)
        XCTAssertFalse(state.userScrolled(by: -300, isAtTop: false), "already shown")
    }

    /// Under Reduce Motion the header fades out after 28 pt down and back in after 28 pt up, the same
    /// distances that hide and reveal it otherwise.
    func testBothThresholdsAreTwentyEightPoints() {
        XCTAssertEqual(EditorChromeState.hideTravel, 28)
        XCTAssertEqual(EditorChromeState.revealTravel, 28)
    }

    /// A slow drag reverses by a point now and then; its whole net distance still counts, in
    /// either direction.
    func testASlowDragsSmallReversalsStillCountItsWholeDistance() {
        var state = EditorChromeState()
        var travelled: [CGFloat] = []
        for delta in [9, 9, 9, -1] as [CGFloat] {
            XCTAssertFalse(state.userScrolled(by: delta, isAtTop: false), "\(delta)")
            travelled.append(state.headerTravel)
        }
        XCTAssertEqual(travelled, [9, 18, 27, 26])
        XCTAssertTrue(state.userScrolled(by: 9, isAtTop: false), "35 pt net hides")
        assertShows(state, header: false, tools: false, handle: true)

        var revealing = scrolledDown(in: .focus)
        for delta in [-9, -9, -9, 1] as [CGFloat] {
            XCTAssertFalse(revealing.userScrolled(by: delta, isAtTop: false), "\(delta)")
        }
        XCTAssertTrue(revealing.userScrolled(by: -9, isAtTop: false), "35 pt net back up reveals")
    }

    /// Scrolling back takes from the distance counted, so reading on after a small correction
    /// reveals nothing, and scrolling back up before the threshold cancels a hide in progress.
    func testTravelIsNetOfScrollingBack() {
        var hidden = scrolledDown(in: .focus)
        for delta in [-(reveal - 8), 50, -(reveal - 8)] as [CGFloat] {
            XCTAssertFalse(hidden.userScrolled(by: delta, isAtTop: false), "\(delta)")
        }
        assertShows(hidden, header: false, tools: false, handle: true, "each correction alone is short")

        var shown = EditorChromeState()
        XCTAssertFalse(shown.userScrolled(by: 20, isAtTop: false))
        XCTAssertEqual(shown.headerTravel, 20)
        XCTAssertFalse(shown.userScrolled(by: -30, isAtTop: false))
        XCTAssertEqual(shown.headerTravel, 0, "never below zero")
        XCTAssertFalse(shown.userScrolled(by: hide - 1, isAtTop: false), "the earlier 20 was scrolled back")
        XCTAssertTrue(shown.userScrolled(by: 1, isAtTop: false))
    }

    /// A header left part-way settles back when the scroll stops, so the next scroll starts from
    /// nothing, in either direction.
    func testAScrollComingToRestDropsTravelShortOfAThreshold() {
        var state = EditorChromeState()
        state.userScrolled(by: hide - 1, isAtTop: false)
        state.userScrollEnded()
        XCTAssertEqual(state.headerTravel, 0)
        XCTAssertFalse(state.userScrolled(by: hide - 1, isAtTop: false))
        XCTAssertTrue(state.userScrolled(by: 1, isAtTop: false))

        state.userScrolled(by: -(reveal - 1), isAtTop: false)
        state.userScrollEnded()
        XCTAssertFalse(state.userScrolled(by: -(reveal - 1), isAtTop: false))
        XCTAssertTrue(state.userScrolled(by: -1, isAtTop: false))
    }

    /// The travel a following header shows: the net descent while it is shown and free to move.
    func testHeaderTravelIsTheNetDescentWhileTheHeaderCanFollow() {
        var state = EditorChromeState(mode: .overlay)
        state.userScrolled(by: 12, isAtTop: false)
        XCTAssertEqual(state.headerTravel, 12)
        state.userScrolled(by: -5, isAtTop: false)
        XCTAssertEqual(state.headerTravel, 7)
        state.userScrolled(by: 30, isAtTop: false)
        XCTAssertFalse(state.showsHeader)
        XCTAssertEqual(state.headerTravel, 0, "a hidden header has left")

        var pinned = EditorChromeState(mode: .pinned)
        pinned.userScrolled(by: 12, isAtTop: false)
        XCTAssertEqual(pinned.headerTravel, 0, "pinned keeps the header in place")

        var forced = EditorChromeState()
        forced.setPins([.presentation])
        forced.userScrolled(by: 12, isAtTop: false)
        XCTAssertEqual(forced.headerTravel, 0, "a pin keeps the header in place")
    }

    /// A pin holds a following header in place, so once the pins clear the header follows the
    /// page again from there rather than from the travel counted before or under them.
    func testPinsRestartTheTravelOfAFollowingHeader() {
        var state = EditorChromeState()
        state.userScrolled(by: 15, isAtTop: false)
        XCTAssertEqual(state.headerTravel, 15)
        state.setPins([.presentation])
        XCTAssertEqual(state.headerTravel, 0)
        state.userScrolled(by: 5, isAtTop: false)
        state.setPins([.presentation, .dragging])
        XCTAssertFalse(state.setPins([]))
        XCTAssertEqual(state.headerTravel, 0, "neither the 15 before the pin nor the 5 under it")
        state.userScrolled(by: 1, isAtTop: false)
        XCTAssertEqual(state.headerTravel, 1)

        state.setPins([.saveProblem])
        state.userScrolled(by: hide, isAtTop: false)
        XCTAssertTrue(state.setPins([]), "scrolling far enough under a pin still hides once it clears")
        assertShows(state, header: false, tools: false, handle: true)
    }

    /// The bounce back from a pull past the top is not reading on, so a header following the
    /// page stays where it is.
    func testSettlingBackAtTheTopNeverMovesAFollowingHeader() {
        var state = EditorChromeState()
        for delta in [-20, -20, 10, 10, 10, 10] as [CGFloat] {
            state.userScrolled(by: delta, isAtTop: true)
            XCTAssertEqual(state.headerTravel, 0, "\(delta)")
        }
        assertShows(state, header: true, tools: true, handle: false)
    }

    func testArrivingAtTheTopRevealsButStayingThereDoesNot() {
        var state = scrolledDown(in: .focus)
        XCTAssertTrue(state.userScrolled(by: -5, isAtTop: true), "arrival needs no travel")
        assertShows(state, header: true, tools: true, handle: false)

        XCTAssertTrue(state.toolEnded())
        XCTAssertFalse(state.userScrolled(by: -5, isAtTop: true), "writing at the top keeps a clean page")
        XCTAssertFalse(state.userScrolled(by: 0, isAtTop: true))
        assertShows(state, header: false, tools: false, handle: true)
    }

    /// A notebook opens below the top of its scroll range, under the header and toolbar, so
    /// reaching the top from there is an arrival.
    func testAPageThatOpensBelowItsTopRevealsOnArrivingThere() {
        var state = EditorChromeState()
        state.pageMoved(isAtTop: false)
        state.toolEnded()
        XCTAssertTrue(state.userScrolled(by: -1, isAtTop: true))
        assertShows(state, header: true, tools: true, handle: false)
    }

    /// Layout that leaves the page at its top is no arrival, and one that moves it away from the
    /// top makes the next return there one.
    func testAMovedPageCountsArrivalsFromWhereItWasLeft() {
        var atTop = scrolledDown(in: .focus)
        atTop.pageMoved(isAtTop: true)
        XCTAssertFalse(atTop.userScrolled(by: -1, isAtTop: true))
        assertShows(atTop, header: false, tools: false, handle: true)

        var below = EditorChromeState()
        below.toolEnded()
        below.pageMoved(isAtTop: false)
        assertShows(below, header: false, tools: false, handle: true, "moving the page changes nothing by itself")
        XCTAssertTrue(below.userScrolled(by: -1, isAtTop: true))
    }

    func testAScrollToTopRevealsWhereverThePageRested() {
        var scrolled = scrolledDown(in: .overlay)
        XCTAssertTrue(scrolled.scrolledToTop())
        assertShows(scrolled, header: true, tools: true, handle: false)

        // The state still takes the page to rest at the top, as nothing has reported otherwise.
        var unreported = EditorChromeState()
        unreported.toolEnded()
        XCTAssertTrue(unreported.scrolledToTop())
        assertShows(unreported, header: true, tools: true, handle: false)

        XCTAssertTrue(unreported.toolEnded())
        XCTAssertFalse(unreported.userScrolled(by: -1, isAtTop: true), "the page now rests at the top")
        XCTAssertTrue(unreported.scrolledToTop(), "every tap is its own request")
    }

    func testAScrollToTopDuringAStrokeIsIgnored() {
        var state = scrolledDown(in: .focus)
        state.toolBegan()
        XCTAssertFalse(state.scrolledToTop())
        assertShows(state, header: false, tools: false, handle: true)
    }

    func testPullingDownAtTheTopRevealsLikeAnyUpwardScroll() {
        var state = EditorChromeState()
        state.toolEnded()
        XCTAssertFalse(state.userScrolled(by: -(reveal - 1), isAtTop: true))
        XCTAssertTrue(state.userScrolled(by: -1, isAtTop: true))
        assertShows(state, header: true, tools: true, handle: false)
    }

    func testSettlingBackWhileAtTheTopNeverCountsTowardHiding() {
        var state = EditorChromeState()
        XCTAssertFalse(state.userScrolled(by: 40, isAtTop: true))
        assertShows(state, header: true, tools: true, handle: false)
        XCTAssertFalse(state.userScrolled(by: hide - 1, isAtTop: false), "travel starts where the top is left")
        XCTAssertTrue(state.userScrolled(by: 1, isAtTop: false))
    }

    func testScrollingWhileAToolIsActiveIsIgnored() {
        var state = EditorChromeState(mode: .overlay)
        state.toolBegan()
        XCTAssertFalse(state.userScrolled(by: 500, isAtTop: false))
        XCTAssertFalse(state.toolEnded())
        assertShows(state, header: true, tools: true, handle: false)
        XCTAssertFalse(state.userScrolled(by: hide - 1, isAtTop: false), "ignored travel does not count afterwards")
        XCTAssertTrue(state.userScrolled(by: 1, isAtTop: false))

        var focus = scrolledDown(in: .focus)
        focus.toolBegan()
        XCTAssertFalse(focus.userScrolled(by: -500, isAtTop: false))
        XCTAssertFalse(focus.userScrolled(by: -500, isAtTop: true))
        assertShows(focus, header: false, tools: false, handle: true)
    }

    func testAStrokeRestartsTravel() {
        var state = EditorChromeState(mode: .overlay)
        state.userScrolled(by: hide - 1, isAtTop: false)
        state.toolBegan()
        state.toolEnded()
        XCTAssertFalse(state.userScrolled(by: 1, isAtTop: false))
    }

    func testARevealRequiresFreshTravelBeforeHidingAgain() {
        var state = scrolledDown(in: .focus)
        XCTAssertTrue(state.reveal(.sticky).visibilityChanged)
        XCTAssertFalse(state.userScrolled(by: hide - 1, isAtTop: false))
        XCTAssertTrue(state.userScrolled(by: 1, isAtTop: false))
    }

    func testZeroAndNonFiniteDeltasAreIgnored() {
        var state = EditorChromeState()
        for delta in [0, CGFloat.nan, .infinity, -.infinity] {
            XCTAssertFalse(state.userScrolled(by: delta, isAtTop: false), "\(delta)")
        }
        XCTAssertFalse(state.userScrolled(by: hide - 1, isAtTop: false))
        XCTAssertTrue(state.userScrolled(by: 1, isAtTop: false))
    }

    // MARK: Cancelled strokes

    func testACancelledStrokeLetsScrollingCountAgainWithoutHiding() {
        var focus = EditorChromeState()
        focus.toolBegan()
        XCTAssertFalse(focus.toolCancelled())
        assertShows(focus, header: true, tools: true, handle: false, "a stroke cut short is not finished")
        XCTAssertFalse(focus.userScrolled(by: hide - 1, isAtTop: false))
        XCTAssertTrue(focus.userScrolled(by: 1, isAtTop: false))

        var hidden = scrolledDown(in: .focus)
        hidden.toolBegan()
        XCTAssertFalse(hidden.toolCancelled())
        assertShows(hidden, header: false, tools: false, handle: true)
        XCTAssertTrue(hidden.userScrolled(by: -reveal, isAtTop: false))

        var overlay = EditorChromeState(mode: .overlay)
        overlay.toolBegan()
        XCTAssertFalse(overlay.toolCancelled())
        XCTAssertTrue(overlay.userScrolled(by: hide, isAtTop: false))
        assertShows(overlay, header: false, tools: true, handle: false)
    }

    func testCancellingWithoutAStrokeChangesNothing() {
        for mode in EditorChromeMode.allCases {
            var state = EditorChromeState(mode: mode)
            XCTAssertFalse(state.toolCancelled(), mode.rawValue)
            assertShows(state, header: true, tools: true, handle: false, mode.rawValue)
        }
        var hidden = scrolledDown(in: .focus)
        XCTAssertFalse(hidden.toolCancelled())
        assertShows(hidden, header: false, tools: false, handle: true)
    }

    func testACancelledStrokeLeavesATransientToExpire() throws {
        var state = scrolledDown(in: .focus)
        let token = try transientToken(&state)
        state.toolBegan()
        XCTAssertFalse(state.toolCancelled())
        assertShows(state, header: false, tools: true, handle: false)
        XCTAssertTrue(state.expireTransient(token), "a cancelled stroke is not a hide trigger")
        assertShows(state, header: false, tools: false, handle: true)
    }

    func testACancelledStrokeUnderAPinHidesNothingOnceThePinClears() {
        var state = EditorChromeState()
        state.setPins([.inputPaused])
        state.toolBegan()
        XCTAssertFalse(state.toolCancelled())
        XCTAssertFalse(state.setPins([]), "nothing was asked to hide underneath")
        assertShows(state, header: true, tools: true, handle: false)
    }

    // MARK: Pins

    func testEveryPinShowsEverythingInEveryModeUntilCleared() {
        for mode in [EditorChromeMode.focus, .overlay] {
            let toolsStay = mode == .overlay
            for pin in EditorChromePin.allCases {
                var state = scrolledDown(in: mode)
                XCTAssertTrue(state.setPins([pin]), "\(mode) \(pin)")
                assertShows(state, header: true, tools: true, handle: false, "\(mode) \(pin)")
                XCTAssertTrue(state.setPins([]), "\(mode) \(pin)")
                assertShows(state, header: false, tools: toolsStay, handle: !toolsStay, "\(mode) \(pin) returns")
            }
        }
        var pinned = EditorChromeState(mode: .pinned)
        XCTAssertFalse(pinned.setPins(Set(EditorChromePin.allCases)))
        XCTAssertFalse(pinned.setPins([]))
    }

    func testChangingBetweenPinsReportsNoChange() {
        var state = scrolledDown(in: .focus)
        XCTAssertTrue(state.setPins([.dragging]))
        XCTAssertFalse(state.setPins([.dragging, .keyboardFocus]))
        XCTAssertFalse(state.setPins([.keyboardFocus]))
        XCTAssertEqual(state.pins, [.keyboardFocus])
        XCTAssertTrue(state.setPins([]))
    }

    func testInputsWhilePinnedTakeEffectWhenThePinsClear() {
        var state = EditorChromeState()
        XCTAssertFalse(state.setPins([.presentation]))
        XCTAssertFalse(state.toolEnded())
        assertShows(state, header: true, tools: true, handle: false)
        XCTAssertTrue(state.setPins([]))
        assertShows(state, header: false, tools: false, handle: true)

        state.setPins([.saveProblem])
        XCTAssertFalse(state.reveal(.sticky).visibilityChanged)
        XCTAssertFalse(state.setPins([]), "the reveal made while pinned stays")
        assertShows(state, header: true, tools: true, handle: false)

        var overlay = EditorChromeState(mode: .overlay)
        overlay.setPins([.inputPaused])
        XCTAssertFalse(overlay.userScrolled(by: 100, isAtTop: false))
        XCTAssertTrue(overlay.setPins([]))
        assertShows(overlay, header: false, tools: true, handle: false)
    }

    // MARK: Reveals

    func testStickyRevealShowsEverythingUntilTheNextHideTrigger() {
        var state = scrolledDown(in: .focus)
        let outcome = state.reveal(.sticky)
        XCTAssertEqual(outcome, EditorChromeRevealOutcome(visibilityChanged: true, transientToken: nil))
        assertShows(state, header: true, tools: true, handle: false)
        XCTAssertFalse(state.reveal(.sticky).visibilityChanged)
        XCTAssertTrue(state.toolEnded())
    }

    func testStickyRevealBringsBackTheHeaderInOverlayMode() {
        var state = scrolledDown(in: .overlay)
        assertShows(state, header: false, tools: true, handle: false)
        XCTAssertEqual(state.reveal(.sticky), EditorChromeRevealOutcome(visibilityChanged: true, transientToken: nil))
        assertShows(state, header: true, tools: true, handle: false)
        XCTAssertFalse(state.reveal(.sticky).visibilityChanged)
        XCTAssertFalse(state.userScrolled(by: hide - 1, isAtTop: false), "travel restarts with the reveal")
        XCTAssertTrue(state.userScrolled(by: 1, isAtTop: false))
        assertShows(state, header: false, tools: true, handle: false)
    }

    func testTransientRevealShowsOnlyTheToolsUntilItExpires() throws {
        var state = scrolledDown(in: .focus)
        let outcome = state.reveal(.transient)
        XCTAssertTrue(outcome.visibilityChanged)
        let token = try XCTUnwrap(outcome.transientToken)
        assertShows(state, header: false, tools: true, handle: false)

        XCTAssertTrue(state.expireTransient(token))
        assertShows(state, header: false, tools: false, handle: true)
        XCTAssertFalse(state.expireTransient(token), "already expired")
    }

    func testTransientTokensAreDistinct() throws {
        var state = EditorChromeState()
        var tokens: Set<UInt64> = []
        for mode in EditorChromeMode.allCases {
            state.setMode(mode)
            tokens.insert(try transientToken(&state))
            tokens.insert(try transientToken(&state))
        }
        XCTAssertEqual(tokens.count, EditorChromeMode.allCases.count * 2)
    }

    func testANewerTransientSupersedesTheOlder() throws {
        var state = scrolledDown(in: .focus)
        let first = try transientToken(&state)
        let newer = state.reveal(.transient)
        XCTAssertFalse(newer.visibilityChanged, "the tools were already shown")

        XCTAssertFalse(state.expireTransient(first))
        assertShows(state, header: false, tools: true, handle: false)
        XCTAssertTrue(state.expireTransient(try XCTUnwrap(newer.transientToken)))
        assertShows(state, header: false, tools: false, handle: true)
    }

    func testAStickyRevealSupersedesATransient() throws {
        var state = scrolledDown(in: .focus)
        let token = try transientToken(&state)
        XCTAssertTrue(state.reveal(.sticky).visibilityChanged, "the header joins the tools")
        XCTAssertFalse(state.expireTransient(token))
        assertShows(state, header: true, tools: true, handle: false)
    }

    func testEveryHideTriggerCancelsATransient() throws {
        var stroke = scrolledDown(in: .focus)
        let strokeToken = try transientToken(&stroke)
        XCTAssertTrue(stroke.toolEnded())
        XCTAssertFalse(stroke.expireTransient(strokeToken))
        assertShows(stroke, header: false, tools: false, handle: true)

        var scroll = scrolledDown(in: .focus)
        let scrollToken = try transientToken(&scroll)
        XCTAssertTrue(scroll.userScrolled(by: hide, isAtTop: false))
        XCTAssertFalse(scroll.expireTransient(scrollToken))

        var toggled = EditorChromeState()
        let toggledToken = try transientToken(&toggled)
        XCTAssertTrue(toggled.toggle())
        XCTAssertFalse(toggled.expireTransient(toggledToken))
        assertShows(toggled, header: false, tools: false, handle: true)
    }

    func testAModeChangeCancelsATransient() throws {
        var state = scrolledDown(in: .focus)
        let token = try transientToken(&state)
        XCTAssertTrue(state.setMode(.overlay))
        XCTAssertFalse(state.setMode(.focus), "everything was already shown")
        XCTAssertFalse(state.expireTransient(token))
        assertShows(state, header: true, tools: true, handle: false)
    }

    func testTransientRevealsOutsideFocusModeChangeNothing() throws {
        var overlay = scrolledDown(in: .overlay)
        let outcome = overlay.reveal(.transient)
        XCTAssertFalse(outcome.visibilityChanged)
        XCTAssertFalse(overlay.expireTransient(try XCTUnwrap(outcome.transientToken)))
        assertShows(overlay, header: false, tools: true, handle: false)

        var pinned = EditorChromeState(mode: .pinned)
        let token = try transientToken(&pinned)
        XCTAssertFalse(pinned.expireTransient(token))
        XCTAssertFalse(pinned.setMode(.focus))
        XCTAssertTrue(pinned.toolEnded())
        assertShows(pinned, header: false, tools: false, handle: true, "no transient carried into focus mode")
    }

    func testATransientExpiringUnderAPinKeepsTheToolsUntilTheNextHideTrigger() throws {
        var state = scrolledDown(in: .focus)
        let token = try transientToken(&state)
        XCTAssertTrue(state.setPins([.dragging]))
        XCTAssertFalse(state.expireTransient(token))
        XCTAssertTrue(state.setPins([]))
        assertShows(state, header: false, tools: true, handle: false)

        XCTAssertTrue(state.toolEnded())
        assertShows(state, header: false, tools: false, handle: true)
    }

    // MARK: Toggle

    func testToggleHidesAndRevealsWhatTheModeCanHide() {
        var focus = EditorChromeState()
        XCTAssertTrue(focus.toggle())
        assertShows(focus, header: false, tools: false, handle: true)
        XCTAssertTrue(focus.toggle())
        assertShows(focus, header: true, tools: true, handle: false)

        var overlay = EditorChromeState(mode: .overlay)
        XCTAssertTrue(overlay.toggle())
        assertShows(overlay, header: false, tools: true, handle: false)
        XCTAssertTrue(overlay.toggle())
        assertShows(overlay, header: true, tools: true, handle: false)

        var pinned = EditorChromeState(mode: .pinned)
        XCTAssertFalse(pinned.toggle())
        assertShows(pinned, header: true, tools: true, handle: false)
    }

    func testToggleWithOnlyTransientToolsRevealsToStay() throws {
        var state = scrolledDown(in: .focus)
        let token = try transientToken(&state)
        XCTAssertTrue(state.toggle())
        assertShows(state, header: true, tools: true, handle: false)
        XCTAssertFalse(state.expireTransient(token), "the reveal stays after the transient's time")
        assertShows(state, header: true, tools: true, handle: false)
    }

    func testToggleWhilePinnedActsOnTheRequestedState() {
        var state = EditorChromeState()
        state.setPins([.keyboardFocus])
        XCTAssertFalse(state.toggle())
        assertShows(state, header: true, tools: true, handle: false)
        XCTAssertTrue(state.setPins([]))
        assertShows(state, header: false, tools: false, handle: true)
    }
}
