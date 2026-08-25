import XCTest
@testable import WalkingPadCoreLogic

final class WorkoutLifecyclePolicyTests: XCTestCase {
    func testIdleTimerOwnershipFollowsForegroundCommittedMainAndCooldown() {
        var ownership = WorkoutIdleTimerOwnership()

        XCTAssertEqual(ownership.update(.init(
            appState: .active,
            stage: .main,
            hasCommittedWorkout: true
        )), true)
        XCTAssertTrue(ownership.isOwned)
        XCTAssertNil(ownership.update(.init(
            appState: .active,
            stage: .cooldown,
            hasCommittedWorkout: true
        )))
        XCTAssertEqual(ownership.update(.init(
            appState: .inactive,
            stage: .cooldown,
            hasCommittedWorkout: true
        )), false)
        XCTAssertFalse(ownership.isOwned)
        XCTAssertNil(ownership.update(.init(
            appState: .background,
            stage: .cooldown,
            hasCommittedWorkout: true
        )))
        XCTAssertEqual(ownership.update(.init(
            appState: .active,
            stage: .cooldown,
            hasCommittedWorkout: true
        )), true)
        XCTAssertTrue(ownership.isOwned)
    }

    func testEveryTerminalOrUncommittedStateReleasesIdleTimerOwnership() {
        let terminalInputs: [(String, WorkoutLifecyclePolicyInput)] = [
            ("stop", .init(appState: .active, stage: .stopping, hasCommittedWorkout: true)),
            ("failure", .init(appState: .active, stage: .recovery, hasCommittedWorkout: true)),
            ("end", .init(appState: .active, stage: .idle, hasCommittedWorkout: false)),
            ("cancel", .init(appState: .active, stage: .preflight, hasCommittedWorkout: false)),
            ("commit_lost", .init(appState: .active, stage: .main, hasCommittedWorkout: false)),
        ]

        for (name, terminalInput) in terminalInputs {
            var ownership = WorkoutIdleTimerOwnership()
            XCTAssertEqual(ownership.update(.init(
                appState: .active,
                stage: .main,
                hasCommittedWorkout: true
            )), true, name)
            XCTAssertEqual(ownership.update(terminalInput), false, name)
            XCTAssertFalse(ownership.isOwned, name)
        }
    }

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
