import XCTest
@testable import WalkingPadCoreLogic

final class PlankTimerTimingTests: XCTestCase {
    func testDelayedTickIncludesAllElapsedSecondsAndClampsCompletion() {
        let start = ContinuousClock.now
        for (elapsed, expected) in [(0.0, 0), (0.99, 0), (1.0, 1), (8.9, 8), (60.0, 60), (1900.0, 1800)] {
            XCTAssertEqual(PlankTimerTiming.elapsedSeconds(since: start,
                at: start.advanced(by: .seconds(elapsed)), limit: 1800), expected)
        }
    }

    func testRestartUsesNewAnchorAndNeverReturnsNegativeTime() {
        let start = ContinuousClock.now
        let restart = start.advanced(by: .seconds(45))
        XCTAssertEqual(PlankTimerTiming.elapsedSeconds(since: restart,
            at: start, limit: 1800), 0)
        XCTAssertEqual(PlankTimerTiming.elapsedSeconds(since: restart,
            at: restart.advanced(by: .seconds(3)), limit: 1800), 3)
    }
}
