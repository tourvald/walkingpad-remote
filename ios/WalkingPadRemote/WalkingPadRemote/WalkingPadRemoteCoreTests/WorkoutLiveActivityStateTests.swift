import XCTest
@testable import WalkingPadCoreLogic

final class WorkoutLiveActivityStateTests: XCTestCase {
    private let sessionID = UUID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func input(
        id: UUID? = nil, running: Bool = true, recovering: Bool = false,
        main: Int = 1800, cooldown: Int = 0
    ) -> WorkoutLiveActivityInput {
        WorkoutLiveActivityInput(
            sessionID: id ?? sessionID, isRunning: running, isRecovering: recovering,
            mainRemainingSeconds: main, cooldownRemainingSeconds: cooldown
        )
    }

    func testNormalHourOfTicksNeedsOnlyInitialActivityContent() {
        var state: WorkoutLiveActivityState?
        var changes = 0
        for elapsed in 0..<3600 {
            let next = WorkoutLiveActivityState.resolve(
                input(main: 3600 - elapsed), previous: state,
                now: now.addingTimeInterval(Double(elapsed))
            )
            if next != state { changes += 1 }
            state = next
        }
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(state?.deadline, now.addingTimeInterval(3600))
    }

    func testExtensionChangesDeadlineOnce() {
        let original = WorkoutLiveActivityState.resolve(input(), previous: nil, now: now)
        let extended = WorkoutLiveActivityState.resolve(input(main: 2090), previous: original, now: now.addingTimeInterval(10))
        XCTAssertEqual(extended?.deadline, now.addingTimeInterval(2100))
        XCTAssertEqual(WorkoutLiveActivityState.resolve(input(main: 2089), previous: extended, now: now.addingTimeInterval(11)), extended)
    }

    func testCooldownIsSeparateDeadlineAndCanEndEarly() {
        let main = WorkoutLiveActivityState.resolve(input(main: 1), previous: nil, now: now)
        let cooldown = WorkoutLiveActivityState.resolve(input(main: 0, cooldown: 240), previous: main, now: now.addingTimeInterval(1))
        XCTAssertEqual(cooldown?.phase, .cooldown)
        XCTAssertEqual(cooldown?.deadline, now.addingTimeInterval(241))
        XCTAssertNil(WorkoutLiveActivityState.resolve(input(running: false, main: 0, cooldown: 130), previous: cooldown, now: now.addingTimeInterval(111)))
    }

    func testZeroIsFinishingAndNeverFabricatesStoppedEvidence() {
        let state = WorkoutLiveActivityState.resolve(input(main: 0), previous: nil, now: now)
        XCTAssertEqual(state?.phase, .finishing)
        XCTAssertNil(state?.deadline)
    }

    func testNoActiveIdentityOrRecoveryProducesNoActivity() {
        let unknown = WorkoutLiveActivityInput(sessionID: nil, isRunning: true, isRecovering: false, mainRemainingSeconds: 60, cooldownRemainingSeconds: 0)
        XCTAssertNil(WorkoutLiveActivityState.resolve(unknown, previous: nil, now: now))
        XCTAssertNil(WorkoutLiveActivityState.resolve(input(recovering: true), previous: nil, now: now))
        XCTAssertNil(WorkoutLiveActivityState.resolve(input(running: false), previous: nil, now: now))
    }

    func testNewSessionCannotReuseOldDeadline() {
        let old = WorkoutLiveActivityState.resolve(input(), previous: nil, now: now)
        let nextID = UUID()
        let new = WorkoutLiveActivityState.resolve(input(id: nextID), previous: old, now: now.addingTimeInterval(1))
        XCTAssertEqual(new?.sessionID, nextID)
        XCTAssertEqual(new?.deadline, now.addingTimeInterval(1801))
    }

    func testPublicationJitterIsIgnoredButClockOrCountdownDriftCorrects() {
        let state = WorkoutLiveActivityState.resolve(input(), previous: nil, now: now)
        XCTAssertEqual(WorkoutLiveActivityState.resolve(input(main: 1799), previous: state, now: now.addingTimeInterval(2.5)), state)
        let corrected = WorkoutLiveActivityState.resolve(input(main: 1799), previous: state, now: now.addingTimeInterval(5))
        XCTAssertEqual(corrected?.deadline, now.addingTimeInterval(1804))
    }
}
