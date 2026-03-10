import XCTest
@testable import WalkingPadCoreLogic

final class HRDomainServiceTests: XCTestCase {
    private let thresholds = HRDomainService.AdaptiveThresholdPercents(
        deadband: 3.0,
        downLevel2Start: 8.0,
        downLevel3Start: 15.0,
        downLevel4Start: 23.0,
        upLevel2Start: 23.0,
        upLevel3Start: 31.0,
        upLevel4Start: 46.0
    )

    func testDiffPercentUsesSafeTarget() {
        XCTAssertEqual(HRDomainService.diffPercent(absDiff: 5, targetBpm: 100), 5.0, accuracy: 0.0001)
        XCTAssertEqual(HRDomainService.diffPercent(absDiff: 1, targetBpm: 0), 100.0, accuracy: 0.0001)
    }

    func testDeadbandConversionRoundsToAtLeastOneBpm() {
        XCTAssertEqual(HRDomainService.deadbandBpm(targetBpm: 140, thresholds: thresholds), 4)
        XCTAssertEqual(HRDomainService.deadbandBpm(targetBpm: 10, thresholds: thresholds), 1)
    }

    func testStepSelectionForSpeedDecreasePath() {
        XCTAssertEqual(HRDomainService.stepFromDiff(diffPercent: 4.0, isIncreasingSpeed: false, thresholds: thresholds).level, 1)
        XCTAssertEqual(HRDomainService.stepFromDiff(diffPercent: 8.0, isIncreasingSpeed: false, thresholds: thresholds).level, 2)
        XCTAssertEqual(HRDomainService.stepFromDiff(diffPercent: 15.0, isIncreasingSpeed: false, thresholds: thresholds).level, 3)
        XCTAssertEqual(HRDomainService.stepFromDiff(diffPercent: 23.0, isIncreasingSpeed: false, thresholds: thresholds).level, 4)
    }

    func testStepSelectionForSpeedIncreasePath() {
        XCTAssertEqual(HRDomainService.stepFromDiff(diffPercent: 7.0, isIncreasingSpeed: true, thresholds: thresholds).level, 1)
        XCTAssertEqual(HRDomainService.stepFromDiff(diffPercent: 23.0, isIncreasingSpeed: true, thresholds: thresholds).level, 2)
        XCTAssertEqual(HRDomainService.stepFromDiff(diffPercent: 31.0, isIncreasingSpeed: true, thresholds: thresholds).level, 3)
        XCTAssertEqual(HRDomainService.stepFromDiff(diffPercent: 46.0, isIncreasingSpeed: true, thresholds: thresholds).level, 4)
    }

    func testStepSizeForLevel() {
        XCTAssertEqual(HRDomainService.stepForLevel(1), 0.1, accuracy: 0.0001)
        XCTAssertEqual(HRDomainService.stepForLevel(4), 0.4, accuracy: 0.0001)
        XCTAssertEqual(HRDomainService.stepForLevel(7), 0.4, accuracy: 0.0001)
    }

    func testCooldownPlanExtendsDurationForHighStartHeartRate() {
        XCTAssertEqual(
            HRDomainService.cooldownPlan(baseMinutes: 5, startBpm: 136, targetBpm: 110).totalSeconds,
            360
        )
        XCTAssertEqual(
            HRDomainService.cooldownPlan(baseMinutes: 5, startBpm: 141, targetBpm: 110).totalSeconds,
            420
        )
        XCTAssertEqual(
            HRDomainService.cooldownPlan(baseMinutes: 5, startBpm: 176, targetBpm: 110).totalSeconds,
            480
        )
    }

    func testCooldownObservedSpeedPrefersControllerAndAppSpeedOverLaggingRawValue() {
        let observed = HRDomainService.cooldownObservedSpeedKmh(
            desiredSpeedKmh: 3.5,
            deviceTargetSpeedKmh: 3.5,
            appReportedSpeedKmh: 3.5,
            rawReportedSpeedKmh: 3.9
        )

        XCTAssertEqual(observed, 3.5, accuracy: 0.0001)
    }

    func testCooldownReductionStepIsFrontLoadedForHighIntensitySessions() {
        let earlyStep = HRDomainService.cooldownReductionStepKmh(
            baseStepKmh: 0.5,
            currentBpm: 176,
            targetBpm: 110,
            startBpm: 176,
            elapsedSeconds: 0,
            totalSeconds: 480
        )
        let lateStep = HRDomainService.cooldownReductionStepKmh(
            baseStepKmh: 0.5,
            currentBpm: 127,
            targetBpm: 110,
            startBpm: 176,
            elapsedSeconds: 360,
            totalSeconds: 480
        )

        XCTAssertEqual(earlyStep, 1.0, accuracy: 0.0001)
        XCTAssertEqual(lateStep, 0.6, accuracy: 0.0001)
    }
}
