import XCTest
@testable import WalkingPadCoreLogic

final class TrainingLogMaintenanceLaunchActionTests: XCTestCase {
    func testClearTrainingLogsArgumentIsRecognized() {
        XCTAssertTrue(TrainingLogMaintenanceLaunchAction.shouldClearTrainingLogs(
            arguments: ["WalkingPadRemote", "--clear-training-logs-on-launch"]
        ))
    }

    func testDefaultLaunchDoesNotClearTrainingLogs() {
        XCTAssertFalse(TrainingLogMaintenanceLaunchAction.shouldClearTrainingLogs(
            arguments: ["WalkingPadRemote"]
        ))
    }
}
