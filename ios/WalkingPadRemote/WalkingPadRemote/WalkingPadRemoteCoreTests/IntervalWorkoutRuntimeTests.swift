import XCTest
import TelemetryDomain
@testable import WalkingPadCoreLogic

final class IntervalWorkoutRuntimeTests: XCTestCase {
    private func state(cycles: Int = 1) -> IntervalWorkoutRuntime.State {
        .init(plan: .init(maximumHeartRate: 200, cycles: cycles)!)
    }

    func testDeliveredSamplesWaitForTickerAtPhaseBoundaries() {
        var value = state(cycles: 2)
        XCTAssertTrue(value.permitsHeartRateDecision(at: .milliseconds(299_999)))
        XCTAssertFalse(value.permitsHeartRateDecision(at: .seconds(300)))
        value.tick(elapsed: 300, heartRate: 130, validForSeconds: 7)
        XCTAssertFalse(value.permitsHeartRateDecision(at: .seconds(299)))
        XCTAssertTrue(value.permitsHeartRateDecision(at: .seconds(300)))
        XCTAssertFalse(value.permitsHeartRateDecision(at: .seconds(540)))
        value.tick(elapsed: 540, heartRate: 180, validForSeconds: 7)
        XCTAssertTrue(value.permitsHeartRateDecision(at: .seconds(540)))
        XCTAssertFalse(value.permitsHeartRateDecision(at: .seconds(720)))
        value.tick(elapsed: 720, heartRate: 141, validForSeconds: 7)
        XCTAssertFalse(value.permitsHeartRateDecision(at: .seconds(720)))
    }

    func testTemporaryWarmupAndFixedWorkIncludeRampTime() {
        var value = state()
        XCTAssertEqual(value.durationSeconds, 300)
        XCTAssertEqual(value.targetBPM, 130)
        XCTAssertEqual(value.targetRange, 120...140)
        value.tick(elapsed: 299, heartRate: 130, validForSeconds: 7)
        XCTAssertEqual(value.phase, .warmup)
        value.tick(elapsed: 300, heartRate: 130, validForSeconds: 7)
        XCTAssertEqual(value.phase, .work)
        XCTAssertEqual(value.remainingSeconds, 240)
        XCTAssertEqual(value.targetBPM, 180)
        XCTAssertEqual(value.targetRange, 170...190)
        value.tick(elapsed: 539, heartRate: 160, validForSeconds: 7)
        XCTAssertEqual(value.phase, .work)
        value.tick(elapsed: 540, heartRate: 160, validForSeconds: 7)
        XCTAssertEqual(value.phase, .cooldown)
        XCTAssertEqual(value.finishReason, "cycles_completed")
        XCTAssertFalse(value.permitsHeartRateDecision(at: .seconds(value.elapsedSeconds)))
        XCTAssertEqual(value.workElapsedSeconds, 240)
        XCTAssertEqual(value.inRangeSeconds, 0)
        XCTAssertEqual(value.coveredWorkSeconds, 8)
    }

    func testFourCyclesHaveRecoveryOnlyBetweenWorkPhases() {
        var value = state(cycles: 4)
        XCTAssertEqual(value.plan.totalSeconds, 1800)
        value.tick(elapsed: 300, heartRate: 130, validForSeconds: 7)
        var elapsed = 300.0
        for cycle in 1...4 {
            XCTAssertEqual(value.phase, .work)
            XCTAssertEqual(value.cycle, cycle)
            elapsed += 240
            value.tick(elapsed: elapsed, heartRate: 180, validForSeconds: 7)
            if cycle < 4 {
                XCTAssertEqual(value.phase, .recovery)
                XCTAssertEqual(value.targetBPM, 140)
                elapsed += 180
                value.tick(elapsed: elapsed, heartRate: 140, validForSeconds: 7)
            }
        }
        XCTAssertEqual(value.phase, .cooldown)
        XCTAssertEqual(value.workElapsedSeconds, 960)
        XCTAssertEqual(value.finishReason, "cycles_completed")
    }

    func testActualUpperBoundaryEndsEarlyButBoundaryItselfDoesNot() {
        var value = state()
        value.tick(elapsed: 300, heartRate: 130, validForSeconds: 7)
        value.tick(elapsed: 310, heartRate: 190, validForSeconds: 7)
        XCTAssertEqual(value.phase, .work)
        value.tick(elapsed: 311, heartRate: 191, validForSeconds: 7)
        XCTAssertEqual(value.phase, .cooldown)
        XCTAssertEqual(value.finishReason, "above_95_percent")
        XCTAssertEqual(value.workElapsedSeconds, 11)
        XCTAssertEqual(value.inRangeSeconds, 1)
    }

    func testRecoveryMustReachTargetBeforeNextWork() {
        var value = state(cycles: 2)
        value.tick(elapsed: 300, heartRate: 130, validForSeconds: 7)
        value.tick(elapsed: 540, heartRate: 180, validForSeconds: 7)
        value.tick(elapsed: 720, heartRate: 141, validForSeconds: 7)
        XCTAssertEqual(value.phase, .cooldown)
        XCTAssertEqual(value.cycle, 1)
        XCTAssertEqual(value.finishReason, "recovery_target_not_reached")
    }

    func testRecoveryNeverRoundsUpTheSeventyPercentBoundary() {
        for (bpm, expectedPhase) in [(133, IntervalWorkoutRuntime.Phase.work), (134, .cooldown)] {
            var value = IntervalWorkoutRuntime.State(plan: .init(maximumHeartRate: 191, cycles: 2)!)
            value.tick(elapsed: 300, heartRate: 125, validForSeconds: 7)
            value.tick(elapsed: 540, heartRate: 170, validForSeconds: 7)
            value.tick(elapsed: 720, heartRate: bpm, validForSeconds: 7)
            XCTAssertEqual(value.phase, expectedPhase)
        }
    }

    func testRecoveryIncludesExactIntegerSeventyPercentBoundaries() {
        for (maximum, ceiling) in [(90, 63), (170, 119), (180, 126)] {
            for (bpm, expectedPhase) in [(ceiling, IntervalWorkoutRuntime.Phase.work), (ceiling + 1, .cooldown)] {
                var value = IntervalWorkoutRuntime.State(plan: .init(maximumHeartRate: maximum, cycles: 2)!)
                value.tick(elapsed: 300, heartRate: maximum / 2, validForSeconds: 7)
                value.tick(elapsed: 540, heartRate: maximum * 90 / 100, validForSeconds: 7)
                XCTAssertEqual(value.targetBPM, ceiling)
                value.tick(elapsed: 720, heartRate: bpm, validForSeconds: 7)
                XCTAssertEqual(value.phase, expectedPhase)
            }
        }
    }

    func testAcceptedExcursionSurvivesNewerBelowLimitSampleUntilTick() {
        var value = state()
        value.tick(elapsed: 300, heartRate: 180, validForSeconds: 7)
        XCTAssertTrue(value.permitsHeartRateDecision(at: .seconds(value.elapsedSeconds)))
        XCTAssertTrue(value.observeHeartRate(191, sampleAgeSeconds: 0.5))
        XCTAssertFalse(value.permitsHeartRateDecision(at: .seconds(value.elapsedSeconds)))
        XCTAssertFalse(value.observeHeartRate(180, sampleAgeSeconds: 0.1))
        XCTAssertEqual(value.phase, .work)
        value.tick(elapsed: 301, heartRate: 180, validForSeconds: 7)
        XCTAssertEqual(value.phase, .cooldown)
        XCTAssertEqual(value.finishReason, "above_95_percent")
        var nextSession = state()
        nextSession.tick(elapsed: 1, heartRate: 130, validForSeconds: 7)
        XCTAssertEqual(nextSession.phase, .warmup)
    }

    func testStaleFutureAndInvalidAgesDoNotLatchExcursion() {
        for age in [-0.1, 7.001, Double.nan, .infinity] {
            var value = state()
            XCTAssertFalse(value.observeHeartRate(191, sampleAgeSeconds: age))
            value.tick(elapsed: 1, heartRate: 180, validForSeconds: 7)
            XCTAssertEqual(value.phase, .warmup)
        }
        var value = state()
        XCTAssertTrue(value.observeHeartRate(191, sampleAgeSeconds: 7))
    }

    func testRecoveryTargetIncludesEveryLowerPositiveHeartRate() {
        var value = state(cycles: 2)
        value.tick(elapsed: 300, heartRate: 130, validForSeconds: 7)
        value.tick(elapsed: 540, heartRate: 180, validForSeconds: 7)
        XCTAssertEqual(value.targetBPM, 140)
        for bpm in [115, 120, 140] { XCTAssertTrue(value.targetRange.contains(bpm)) }
        XCTAssertFalse(value.targetRange.contains(141))
    }

    func testMissingHeartRateAtBoundaryDoesNotStartNewWork() {
        var value = state()
        value.tick(elapsed: 300, heartRate: nil, validForSeconds: 0)
        XCTAssertEqual(value.phase, .cooldown)
        XCTAssertEqual(value.finishReason, "heart_rate_unavailable_at_transition")
    }

    func testLateCallbackAdvancesOnlyOnePhaseAndRejectsClockRegression() {
        var value = state(cycles: 4)
        value.tick(elapsed: 1500, heartRate: 130, validForSeconds: 7)
        XCTAssertEqual(value.phase, .work)
        XCTAssertEqual(value.cycle, 1)
        XCTAssertEqual(value.remainingSeconds, 240)
        let snapshot = value
        value.tick(elapsed: 1499, heartRate: 200, validForSeconds: 7)
        XCTAssertEqual(value, snapshot)
        value.tick(elapsed: .infinity, heartRate: 200, validForSeconds: 7)
        XCTAssertEqual(value, snapshot)
    }

    func testExposureIsBoundedByFreshnessAndWorkDuration() {
        var value = state()
        value.tick(elapsed: 300, heartRate: 180, validForSeconds: 2)
        value.tick(elapsed: 310, heartRate: nil, validForSeconds: 0)
        XCTAssertEqual(value.workElapsedSeconds, 10)
        XCTAssertEqual(value.coveredWorkSeconds, 2)
        XCTAssertEqual(value.inRangeSeconds, 2)
        value.tick(elapsed: 550, heartRate: 180, validForSeconds: 7)
        XCTAssertEqual(value.workElapsedSeconds, 240)
        XCTAssertEqual(value.inRangeSeconds, 2)
    }

    func testInvalidPlansAndRecoveryNeverAccelerates() {
        for bpm in [nil, 79, 251] as [Int?] {
            XCTAssertNil(IntervalWorkoutRuntime.Plan(maximumHeartRate: bpm, cycles: 1))
        }
        for cycles in [0, 5] {
            XCTAssertNil(IntervalWorkoutRuntime.Plan(maximumHeartRate: 200, cycles: cycles))
        }
        for speed in [0.0, 1, 3, 8, 12] {
            let next = IntervalWorkoutRuntime.recoverySpeed(current: speed, minimum: 3, step: 0.4)
            XCTAssertLessThanOrEqual(next, speed)
            XCTAssertGreaterThanOrEqual(next, 0)
        }
    }

    func testRecoveryRecordKeepsModeAndOrdinarySettings() throws {
        let record = NativeWorkoutRecoveryRecord.preflight(
            appWorkoutID: UUID(), targetBPM: 164, durationMinutes: 30,
            acquisitionStartedAt: Date(), profileID: UUID(), isIntervalWorkout: true
        ).planningDuration(seconds: 540)
        let committed = record.committed(controlledWorkoutStartedAt: Date(),
            profileID: UUID(), legacySessionID: UUID(), telemetrySessionID: UUID())
        XCTAssertEqual(committed.isIntervalWorkout, true)
        XCTAssertEqual(committed.targetBPM, 164)
        XCTAssertEqual(committed.durationMinutes, 30)
        XCTAssertEqual(committed.effectivePlannedDurationSeconds, 540)
        XCTAssertEqual(committed.finishing(requestedAt: Date()).isIntervalWorkout, true)
        let encoder = JSONEncoder()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(committed)) as? [String: Any])
        json.removeValue(forKey: "isIntervalWorkout")
        let old = try JSONDecoder().decode(NativeWorkoutRecoveryRecord.self,
            from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.isIntervalWorkout)
    }
}
