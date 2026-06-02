import XCTest
@testable import WalkingPadCoreLogic

final class HRControlDecisionEngineTests: XCTestCase {
    // Default adaptive thresholds shipped by the app: deadband 3%, down L2/L3/L4 = 8/15/23%,
    // up L2/L3/L4 = 23/31/46%, with the fixed step ladder 0.1/0.2/0.3/0.4 km/h.
    private func makeConfig(
        targetBpm: Int = 130,
        adaptiveStepEnabled: Bool = true,
        fixedStepKmh: Double = 0.5,
        predictSeconds: Double = 20,
        predictMarginBpm: Int = 10,
        minSpeedKmh: Double = 0.5,
        maxSpeedKmh: Double = 12.0,
        incrementKmh: Double = 0.1
    ) -> HRControlDecisionEngine.Config {
        HRControlDecisionEngine.Config(
            targetBpm: targetBpm,
            adaptiveStepEnabled: adaptiveStepEnabled,
            fixedStepKmh: fixedStepKmh,
            thresholds: HRDomainService.AdaptiveThresholdPercents(
                deadband: 3,
                downLevel2Start: 8,
                downLevel3Start: 15,
                downLevel4Start: 23,
                upLevel2Start: 23,
                upLevel3Start: 31,
                upLevel4Start: 46
            ),
            predictSeconds: predictSeconds,
            predictMarginBpm: predictMarginBpm,
            speedBounds: TreadmillSpeedBoundsService.Bounds(
                min: minSpeedKmh,
                max: maxSpeedKmh,
                increment: incrementKmh
            )
        )
    }

    private func makeInput(
        hr: Int,
        trend: Double? = nil,
        currentTargetSpeedKmh: Double = 5.0
    ) -> HRControlDecisionEngine.Input {
        HRControlDecisionEngine.Input(
            currentHeartRateBpm: hr,
            trendBpmPerSecond: trend,
            currentTargetSpeedKmh: currentTargetSpeedKmh
        )
    }

    func testHoldWithinDeadband() {
        let d = HRControlDecisionEngine.decide(config: makeConfig(), input: makeInput(hr: 132))
        XCTAssertEqual(d.kind, .hold)
        XCTAssertEqual(d.deadbandBpm, 4) // round(130 * 3%) = 4
        XCTAssertEqual(d.diffBpm, 2)
        XCTAssertEqual(d.nextSpeedKmh, 5.0, accuracy: 0.0001)
        XCTAssertEqual(d.speedDeltaKmh, 0.0, accuracy: 0.0001)
        XCTAssertFalse(d.changesSpeed)
        XCTAssertEqual(d.modeLabel, "L0")
        XCTAssertEqual(d.stepTag, "DOWN-L0")
    }

    func testSetDownAboveTarget() {
        // HR 150 vs target 130: +20 bpm, 15.38% -> down level 3 -> 0.3 km/h.
        let d = HRControlDecisionEngine.decide(config: makeConfig(), input: makeInput(hr: 150))
        XCTAssertEqual(d.kind, .set)
        XCTAssertEqual(d.diffBpm, 20)
        XCTAssertEqual(d.stepLevel, 3)
        XCTAssertEqual(d.stepKmh, 0.3, accuracy: 0.0001)
        XCTAssertEqual(d.nextSpeedKmh, 4.7, accuracy: 0.0001)
        XCTAssertEqual(d.stepTag, "DOWN-L3")
        XCTAssertTrue(d.changesSpeed)
    }

    func testSetUpBelowTarget() {
        // HR 110 vs target 130: -20 bpm, 15.38% -> up level 1 -> 0.1 km/h.
        let d = HRControlDecisionEngine.decide(config: makeConfig(), input: makeInput(hr: 110))
        XCTAssertEqual(d.kind, .set)
        XCTAssertEqual(d.diffBpm, -20)
        XCTAssertEqual(d.stepLevel, 1)
        XCTAssertEqual(d.nextSpeedKmh, 5.1, accuracy: 0.0001)
        XCTAssertEqual(d.stepTag, "UP-L1")
    }

    func testAdaptiveDownLevels() {
        let cases: [(hr: Int, level: Int, step: Double)] = [
            (137, 1, 0.1), // +7  -> 5.38%
            (145, 2, 0.2), // +15 -> 11.54%
            (155, 3, 0.3), // +25 -> 19.23%
            (170, 4, 0.4)  // +40 -> 30.77%
        ]
        for c in cases {
            let d = HRControlDecisionEngine.decide(config: makeConfig(), input: makeInput(hr: c.hr))
            XCTAssertEqual(d.kind, .set, "hr=\(c.hr)")
            XCTAssertEqual(d.stepLevel, c.level, "hr=\(c.hr)")
            XCTAssertEqual(d.stepKmh, c.step, accuracy: 0.0001, "hr=\(c.hr)")
            XCTAssertEqual(d.modeLabel, "L\(c.level)", "hr=\(c.hr)")
        }
    }

    func testFixedStepMode() {
        let d = HRControlDecisionEngine.decide(
            config: makeConfig(adaptiveStepEnabled: false, fixedStepKmh: 0.5),
            input: makeInput(hr: 150)
        )
        XCTAssertEqual(d.kind, .set)
        XCTAssertEqual(d.modeLabel, "FIXED")
        XCTAssertEqual(d.stepKmh, 0.5, accuracy: 0.0001)
        XCTAssertEqual(d.nextSpeedKmh, 4.5, accuracy: 0.0001)
        XCTAssertEqual(d.stepTag, "DOWN-FIXED")
    }

    func testInertiaHoldWhileSpeedingUp() {
        // target 140, HR 123 but rising at 0.6 bpm/s -> predicted 135 (>= 140 - margin 10).
        // Effective diff is -5 (speeding-up path), so without inertia it would raise speed.
        let d = HRControlDecisionEngine.decide(
            config: makeConfig(targetBpm: 140, predictSeconds: 20, predictMarginBpm: 10),
            input: makeInput(hr: 123, trend: 0.6, currentTargetSpeedKmh: 6.0)
        )
        XCTAssertEqual(d.kind, .inertiaHold)
        XCTAssertEqual(d.predictedBpm, 135)
        XCTAssertEqual(d.effectiveBpm, 135)
        XCTAssertEqual(d.diffBpm, -5)
        XCTAssertEqual(d.nextSpeedKmh, 6.0, accuracy: 0.0001)
        XCTAssertFalse(d.changesSpeed)
    }

    func testDownwardPredictionDoesNotAccelerateReduction() {
        // HR 150 above target 130 with a falling trend. Prediction (138) is below HR, so the
        // effective HR stays at 150 (prediction only ever pushes effective HR up).
        let d = HRControlDecisionEngine.decide(
            config: makeConfig(),
            input: makeInput(hr: 150, trend: -0.6)
        )
        XCTAssertEqual(d.predictedBpm, 138)
        XCTAssertEqual(d.effectiveBpm, 150)
        XCTAssertEqual(d.diffBpm, 20)
        XCTAssertEqual(d.kind, .set)
    }

    func testLimitAtMaxWhileSpeedingUp() {
        let d = HRControlDecisionEngine.decide(
            config: makeConfig(targetBpm: 150, maxSpeedKmh: 12.0),
            input: makeInput(hr: 120, currentTargetSpeedKmh: 12.0)
        )
        XCTAssertEqual(d.kind, .limit)
        XCTAssertEqual(d.nextSpeedKmh, 12.0, accuracy: 0.0001)
        XCTAssertEqual(d.speedDeltaKmh, 0.0, accuracy: 0.0001)
        XCTAssertFalse(d.changesSpeed)
    }

    func testLimitAtMinWhileSlowingDown() {
        let d = HRControlDecisionEngine.decide(
            config: makeConfig(targetBpm: 120, minSpeedKmh: 0.5),
            input: makeInput(hr: 180, currentTargetSpeedKmh: 0.5)
        )
        XCTAssertEqual(d.kind, .limit)
        XCTAssertEqual(d.nextSpeedKmh, 0.5, accuracy: 0.0001)
    }
}
