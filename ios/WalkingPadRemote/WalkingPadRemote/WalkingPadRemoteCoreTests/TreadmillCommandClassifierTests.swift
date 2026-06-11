import XCTest
@testable import WalkingPadCoreLogic

final class TreadmillCommandClassifierTests: XCTestCase {
    private func source(_ label: String) -> TreadmillCommandClassifier.Source {
        TreadmillCommandClassifier.source(forLabel: label)
    }

    func testManualSpeedIsUser() {
        XCTAssertEqual(source("SPEED 3.0 km/h"), .userManual)
        XCTAssertEqual(source("SPEED 3.0 km/h (FTMS)"), .userManual)
        XCTAssertEqual(source("SPEED 1.2 km/h (FitShow)"), .userManual)
    }

    func testHrCooldownTestSpeedsAreTaggedNotUser() {
        XCTAssertEqual(source("SPEED 4.0 km/h (HR)"), .hrAlgorithm)
        XCTAssertEqual(source("SPEED 4.0 km/h (HR) (FTMS)"), .hrAlgorithm)
        XCTAssertEqual(source("SPEED 2.0 km/h (cooldown)"), .cooldown)
        XCTAssertEqual(source("SPEED 3.0 km/h (test)"), .testRun)
    }

    func testStopIsStopButRetriesAndStandbyAreAssist() {
        XCTAssertEqual(source("STOP"), .stop)
        XCTAssertEqual(source("STOP retry"), .stopAssist)
        XCTAssertEqual(source("MODE STANDBY"), .stopAssist)
    }

    func testStartSequence() {
        XCTAssertEqual(source("MODE MANUAL"), .start)
        XCTAssertEqual(source("START"), .start)
        XCTAssertEqual(source("FTMS START/RESUME"), .start)
        XCTAssertEqual(source("FTMS START/RESUME (auto)"), .start)
        XCTAssertEqual(source("FitShow START/RESUME"), .start)
    }

    func testProtocolControlAndStatusQuery() {
        XCTAssertEqual(source("FTMS REQUEST CONTROL"), .protocolControl)
        XCTAssertEqual(source("FitShow STATUS"), .statusQuery)
        XCTAssertEqual(source("QUERY PARAMS"), .statusQuery)
    }

    func testUnknownIsOther() {
        XCTAssertEqual(source("PING"), .other)
        XCTAssertEqual(source(""), .other)
    }
}
