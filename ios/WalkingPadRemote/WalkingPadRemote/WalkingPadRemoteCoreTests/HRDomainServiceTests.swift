import XCTest
@testable import WalkingPadCoreLogic

final class HRDomainServiceTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
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

    func testCooldownSpeedSnapshotPrefersFactualSpeedOverStaleControllerTarget() {
        let snapshot = HRDomainService.cooldownSpeedSnapshot(
            desiredSpeedKmh: 3.5,
            deviceTargetSpeedKmh: 4.7,
            appReportedSpeedKmh: 3.5,
            rawReportedSpeedKmh: 3.9,
            currentActualSpeedKmh: 3.5
        )

        XCTAssertEqual(snapshot.observedSpeedKmh, 3.5, accuracy: 0.0001)
        XCTAssertEqual(snapshot.controllerSpeedKmh, 4.7, accuracy: 0.0001)
        XCTAssertEqual(snapshot.factualSpeedKmh ?? 0, 3.5, accuracy: 0.0001)
    }

    func testCooldownSpeedSnapshotFallsBackToControllerWhenNoFactualSpeedExists() {
        let snapshot = HRDomainService.cooldownSpeedSnapshot(
            desiredSpeedKmh: 4.7,
            deviceTargetSpeedKmh: 4.5,
            appReportedSpeedKmh: 0,
            rawReportedSpeedKmh: 0,
            currentActualSpeedKmh: 0
        )

        XCTAssertEqual(snapshot.observedSpeedKmh, 4.7, accuracy: 0.0001)
        XCTAssertEqual(snapshot.controllerSpeedKmh, 4.7, accuracy: 0.0001)
        XCTAssertNil(snapshot.factualSpeedKmh)
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

    func testCooldownNextTargetSpeedReducesImmediatelyWhenAboveMinSpeed() {
        let target = HRDomainService.cooldownNextTargetSpeedKmh(
            currentSentSpeedKmh: 6.0,
            minSpeedKmh: 3.5,
            reductionStepKmh: 0.5
        )

        XCTAssertEqual(target ?? 0, 5.5, accuracy: 0.0001)
    }

    func testCooldownNextTargetSpeedDoesNotEmitChangeAtMinSpeed() {
        let target = HRDomainService.cooldownNextTargetSpeedKmh(
            currentSentSpeedKmh: 3.5,
            minSpeedKmh: 3.5,
            reductionStepKmh: 0.5
        )

        XCTAssertNil(target)
    }

    func testHeartRateStartAffordanceDependsOnlyOnConnectionAndCurrentHeartRate() {
        enum TelemetryState: CaseIterable {
            case sinkAbsent
            case degraded
            case failed
            case metadataMalformed
        }

        for _ in TelemetryState.allCases {
            XCTAssertTrue(
                HRDomainService.heartRateStartAffordanceAvailable(
                    treadmillConnected: true,
                    currentHeartRateVisible: true
                )
            )
        }

        XCTAssertFalse(
            HRDomainService.heartRateStartAffordanceAvailable(
                treadmillConnected: false,
                currentHeartRateVisible: true
            )
        )
        XCTAssertFalse(
            HRDomainService.heartRateStartAffordanceAvailable(
                treadmillConnected: true,
                currentHeartRateVisible: false
            )
        )
    }

    func testHeartRateAffordanceAndRuntimeAuthorizationRemainSeparate() {
        XCTAssertTrue(
            HRDomainService.heartRateStartAffordanceAvailable(
                treadmillConnected: true,
                currentHeartRateVisible: true
            )
        )
        XCTAssertTrue(
            HRDomainService.heartRateRuntimePrerequisitesAllowStart(
                treadmillConnected: true,
                watchReachable: true,
                currentHeartRateVisible: true
            )
        )
        XCTAssertFalse(
            HRDomainService.heartRateRuntimePrerequisitesAllowStart(
                treadmillConnected: true,
                watchReachable: false,
                currentHeartRateVisible: true
            )
        )
    }

    func testFixedHeartRateTracePreservesControllerOrderAndBoundaries() {
        let inputs = [120, 120, 119, 121]
        var current = 0
        var lastKnown = 0
        var lastReceivedAt: Date?
        var predictorInputs: [Int] = []

        for input in inputs {
            HRDomainService.applyHeartRateDelivery(
                input,
                now: { baseDate },
                updateCurrent: { current = $0 },
                updateLastKnown: { lastKnown = $0 },
                updateLastReceivedAt: { lastReceivedAt = $0 },
                recordPredictorInput: { predictorInputs.append($0) }
            )
        }

        XCTAssertEqual(predictorInputs, inputs)
        XCTAssertEqual(current, 121)
        XCTAssertEqual(lastKnown, 121)
        XCTAssertEqual(lastReceivedAt, baseDate)

        XCTAssertTrue(
            HRDomainService.heartRateStreamIsActive(
                beatsPerMinute: current,
                hasLastReceivedAt: lastReceivedAt != nil,
                ageSeconds: 7,
                staleThresholdSeconds: 7
            )
        )
        XCTAssertFalse(
            HRDomainService.heartRateStreamIsActive(
                beatsPerMinute: current,
                hasLastReceivedAt: lastReceivedAt != nil,
                ageSeconds: 8,
                staleThresholdSeconds: 7
            )
        )
        XCTAssertTrue(
            HRDomainService.isWithinInitialHeartRateGrace(
                startedAt: baseDate,
                now: baseDate.addingTimeInterval(14.999),
                graceSeconds: 15
            )
        )
        XCTAssertFalse(
            HRDomainService.isWithinInitialHeartRateGrace(
                startedAt: baseDate,
                now: baseDate.addingTimeInterval(15),
                graceSeconds: 15
            )
        )
        XCTAssertEqual(
            HRDomainService.missingHeartRateSignalSeconds(
                lastReceivedAt: baseDate,
                now: baseDate.addingTimeInterval(59.999),
                noDataMaximumSeconds: 60
            ),
            59
        )
        XCTAssertEqual(
            HRDomainService.missingHeartRateSignalSeconds(
                lastReceivedAt: baseDate,
                now: baseDate.addingTimeInterval(60),
                noDataMaximumSeconds: 60
            ),
            60
        )
        XCTAssertEqual(
            HRDomainService.missingHeartRateSignalSeconds(
                lastReceivedAt: nil,
                now: baseDate,
                noDataMaximumSeconds: 60
            ),
            60
        )
        XCTAssertFalse(
            HRDomainService.shouldStopForMissingHeartRateSignal(
                missingSeconds: 59,
                noDataMaximumSeconds: 60
            )
        )
        XCTAssertTrue(
            HRDomainService.shouldStopForMissingHeartRateSignal(
                missingSeconds: 60,
                noDataMaximumSeconds: 60
            )
        )
    }
}
