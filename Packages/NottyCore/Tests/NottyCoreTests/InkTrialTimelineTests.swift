import XCTest
@testable import NottyCore

final class InkTrialTimelineTests: XCTestCase {
    private let hold = InkTrialTimeline.holdDuration

    func testNothingShowsUntilTheFirstStroke() {
        XCTAssertEqual(hold, 3.5)
        var trial = InkTrialTimeline()
        trial.changeColor(at: 2)
        for time in [0.0, 2, 50] {
            XCTAssertEqual(trial.phase(at: time), .untried, "Choosing colours alone never starts a trial.")
            XCTAssertEqual(trial.borderProgress(at: time, reduceMotion: false), 0)
            XCTAssertEqual(trial.borderProgress(at: time, reduceMotion: true), 0, "Nothing shows under Reduce Motion either.")
            XCTAssertFalse(trial.showsToast(at: time))
        }
        XCTAssertNil(trial.retainsAt)
    }

    func testTheBorderDrawsEvenlyAndClosesExactlyAsTheHoldEnds() {
        var trial = InkTrialTimeline()
        trial.beginStroke(at: 10)
        XCTAssertEqual(trial.retainsAt, 13.5)
        XCTAssertEqual(trial.phase(at: 10), .trying)
        XCTAssertEqual(trial.borderProgress(at: 10, reduceMotion: false), 0, "It starts from its first point.")
        XCTAssertEqual(trial.borderProgress(at: 10 + hold / 2, reduceMotion: false), 0.5, accuracy: 1e-12)
        XCTAssertEqual(trial.borderProgress(at: 10 + hold / 4, reduceMotion: false), 0.25, accuracy: 1e-12)
        XCTAssertEqual(trial.phase(at: 13.4999), .trying)
        XCTAssertFalse(trial.showsToast(at: 13.4999))
        XCTAssertLessThan(trial.borderProgress(at: 13.4999, reduceMotion: false), 1)

        XCTAssertEqual(trial.phase(at: 13.5), .retained, "Green the moment the border closes.")
        XCTAssertEqual(trial.borderProgress(at: 13.5, reduceMotion: false), 1)
        XCTAssertTrue(trial.showsToast(at: 13.5), "The toast arrives with the green.")
        XCTAssertEqual(trial.borderProgress(at: 100, reduceMotion: false), 1, "It never overruns.")
        XCTAssertEqual(trial.borderProgress(at: 9, reduceMotion: false), 0, "Nor runs backwards.")
    }

    func testLaterStrokesLeaveTheTrialRunning() {
        var trial = InkTrialTimeline()
        trial.beginStroke(at: 10)
        trial.beginStroke(at: 12)
        XCTAssertEqual(trial.retainsAt, 13.5)
        trial.beginStroke(at: 20)
        XCTAssertEqual(trial.phase(at: 20), .retained, "A stroke on a retained colour keeps it retained.")
        XCTAssertTrue(trial.showsToast(at: 20))
    }

    func testAColourChangeAfterTheFirstStrokeRestartsTheBorderFromItsStart() {
        var trial = InkTrialTimeline()
        trial.beginStroke(at: 10)
        trial.changeColor(at: 12)
        XCTAssertEqual(trial.borderProgress(at: 12, reduceMotion: false), 0, "Back to the top centre.")
        XCTAssertEqual(trial.phase(at: 13.6), .trying, "The hold restarts from the change.")
        XCTAssertEqual(trial.phase(at: 15.5), .retained)

        trial.changeColor(at: 20)
        XCTAssertEqual(trial.phase(at: 20), .trying, "A retained colour changed returns to yellow.")
        XCTAssertFalse(trial.showsToast(at: 20), "The toast leaves with the change.")
        XCTAssertEqual(trial.borderProgress(at: 20, reduceMotion: false), 0)
        XCTAssertEqual(trial.retainsAt, 23.5)
        XCTAssertEqual(trial.phase(at: 23.5), .retained)
    }

    func testUnderReduceMotionTheBorderShowsWholeAndOnlyTurnsGreen() {
        var trial = InkTrialTimeline()
        trial.beginStroke(at: 10)
        XCTAssertEqual(trial.borderProgress(at: 10, reduceMotion: true), 1, "Complete in yellow from the first stroke.")
        XCTAssertEqual(trial.phase(at: 11), .trying, "The hold itself is unchanged.")
        XCTAssertEqual(trial.phase(at: 13.5), .retained)
        trial.changeColor(at: 14)
        XCTAssertEqual(trial.borderProgress(at: 14, reduceMotion: true), 1)
        XCTAssertEqual(trial.phase(at: 14), .trying)
    }
}
