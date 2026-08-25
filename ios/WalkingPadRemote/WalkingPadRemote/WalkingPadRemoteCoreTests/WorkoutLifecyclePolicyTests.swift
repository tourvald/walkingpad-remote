import XCTest
@testable import WalkingPadCoreLogic

final class WorkoutLifecyclePolicyTests: XCTestCase {
    func testCommittedMainAndCooldownContinueAcrossInactiveAndBackground() {
        for stage in [WorkoutLifecycleStage.main, .cooldown] {
            let inactive = WorkoutLifecyclePolicy.evaluate(.init(
                appState: .inactive,
                stage: stage,
                hasCommittedWorkout: true
            ))
            XCTAssertEqual(inactive.action, .awaitingSystemTransition)
            XCTAssertTrue(inactive.permitsControlLoop)

            let background = WorkoutLifecyclePolicy.evaluate(.init(
                appState: .background,
                stage: stage,
                hasCommittedWorkout: true
            ))
            XCTAssertEqual(background.action, .continueEventDriven)
            XCTAssertTrue(background.permitsControlLoop)
        }
    }

    func testPreflightCannotAuthorizeBackgroundControl() {
        for appState in [WorkoutLifecycleAppState.inactive, .background] {
            let decision = WorkoutLifecyclePolicy.evaluate(.init(
                appState: appState,
                stage: .preflight,
                hasCommittedWorkout: false
            ))
            XCTAssertEqual(decision.action, .blockUncommitted)
            XCTAssertFalse(decision.permitsControlLoop)
        }
    }

    func testRecoveryAndStoppingNeverAuthorizeMotion() {
        let recovery = WorkoutLifecyclePolicy.evaluate(.init(
            appState: .background,
            stage: .recovery,
            hasCommittedWorkout: true
        ))
        XCTAssertEqual(recovery.action, .recoveryOnly)
        XCTAssertFalse(recovery.permitsControlLoop)

        let stopping = WorkoutLifecyclePolicy.evaluate(.init(
            appState: .background,
            stage: .stopping,
            hasCommittedWorkout: true
        ))
        XCTAssertEqual(stopping.action, .terminalOnly)
        XCTAssertFalse(stopping.permitsControlLoop)
    }

    func testIdleLifecycleNeverCreatesBackgroundOwnership() {
        let decision = WorkoutLifecyclePolicy.evaluate(.init(
            appState: .background,
            stage: .idle,
            hasCommittedWorkout: false
        ))
        XCTAssertEqual(decision.action, .noActiveWorkout)
        XCTAssertFalse(decision.permitsControlLoop)
    }
}
