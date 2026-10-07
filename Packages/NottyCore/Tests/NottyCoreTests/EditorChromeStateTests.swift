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

    func testTravelAccumulatesInOneDirectionAndRestartsOnReversal() {
        var state = EditorChromeState()
        XCTAssertFalse(state.userScrolled(by: 10, isAtTop: false))
        XCTAssertFalse(state.userScrolled(by: 10, isAtTop: false))
        XCTAssertFalse(state.userScrolled(by: -5, isAtTop: false))
        XCTAssertFalse(state.userScrolled(by: 10, isAtTop: false), "the reversal discarded the earlier 20")
        XCTAssertTrue(state.userScrolled(by: hide - 10, isAtTop: false))

        XCTAssertFalse(state.userScrolled(by: -20, isAtTop: false))
        XCTAssertFalse(state.userScrolled(by: 1, isAtTop: false))
        XCTAssertFalse(state.userScrolled(by: -20, isAtTop: false), "the reversal discarded the earlier 20")
        XCTAssertTrue(state.userScrolled(by: -(reveal - 20), isAtTop: false))
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

    func testAFreshlyOpenedNotebookIsAlreadyAtTheTop() {
        var state = EditorChromeState()
        state.toolEnded()
        XCTAssertFalse(state.userScrolled(by: -1, isAtTop: true))
        assertShows(state, header: false, tools: false, handle: true)
    }

    func testAScrollToTopIsReportedAsItsArrival() {
        var state = scrolledDown(in: .overlay)
        XCTAssertTrue(state.userScrolled(by: 0, isAtTop: true))
        assertShows(state, header: true, tools: true, handle: false)
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
