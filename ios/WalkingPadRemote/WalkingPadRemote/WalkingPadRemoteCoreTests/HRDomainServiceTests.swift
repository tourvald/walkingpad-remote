import XCTest
import TelemetryDomain
@testable import WalkingPadCoreLogic

final class HRDomainServiceTests: XCTestCase {
    func testPacedIncreaseRetainsOriginalSampleAndCannotAdvanceTargetWhenCancelled() throws {
        let measuredAt = Date(timeIntervalSince1970: 1000)
        let decidedAt = measuredAt.addingTimeInterval(6.99)
        let sentAt = decidedAt.addingTimeInterval(1.99)
        XCTAssertTrue(HRDomainService.heartRateDecisionIsDue(sampleAgeSeconds: 6.99,
            elapsedSinceLastDecision: .seconds(9), intervalSeconds: 9))
        let context = HRDomainService.SpeedCommand(targetKmh: 6.2, increaseSampleAt: measuredAt)
        var queue = [CommandQueueService.Command(data: Data([1]), label: "SPEED HR", heartRateSpeed: context)]
        let next = queue.removeFirst()
        let pending = try XCTUnwrap(next.heartRateSpeed)
        var targetKmh = 6.0
        var writes = 0
        var nextAllowedAt = sentAt
        let blocked = HRDomainService.speedCommandBlockReason(pending, isRunning: true, unitsAllowed: true, now: sentAt)
        if blocked == nil {
            writes += 1
            targetKmh = pending.targetKmh
            nextAllowedAt = sentAt.addingTimeInterval(2)
        }
        XCTAssertEqual(blocked, "hr_increase_sample_stale_before_write")
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(targetKmh, 6.0)
        XCTAssertEqual(nextAllowedAt, sentAt)
        // A separately arrived sample cannot renew the queued command's original timestamp.
        let newer = HRDomainService.SpeedCommand(targetKmh: 6.2, increaseSampleAt: sentAt)
        XCTAssertNil(HRDomainService.speedCommandBlockReason(newer, isRunning: true, unitsAllowed: true, now: sentAt))
        XCTAssertEqual(pending.increaseSampleAt, measuredAt)
    }

    func testWriteGuardRejectsInvalidAgesAndProtectsUnitsAndSessionForBothDirections() {
        let now = Date(timeIntervalSince1970: 1000)
        for age in [-0.001, 0, 7, 7.001, Double.nan, .infinity] {
            let command = HRDomainService.SpeedCommand(targetKmh: 6.2, increaseSampleAt: now.addingTimeInterval(-age))
            let reason = HRDomainService.speedCommandBlockReason(command, isRunning: true, unitsAllowed: true, now: now)
            XCTAssertEqual(reason == nil, age.isFinite && (0...7).contains(age))
        }
        for sampleAt in [now, nil] as [Date?] {
            let command = HRDomainService.SpeedCommand(targetKmh: 5.8, increaseSampleAt: sampleAt)
            XCTAssertEqual(HRDomainService.speedCommandBlockReason(command, isRunning: true, unitsAllowed: false, now: now),
                "hr_units_blocked_before_write")
            XCTAssertEqual(HRDomainService.speedCommandBlockReason(command, isRunning: false, unitsAllowed: true, now: now),
                "hr_session_ended_before_write")
        }
        let decrease = HRDomainService.SpeedCommand(targetKmh: 5.8, increaseSampleAt: nil)
        XCTAssertNil(HRDomainService.speedCommandBlockReason(decrease, isRunning: true, unitsAllowed: true, now: now))
    }

    func testRunningWriteGuardRespectsEveryControllerUnitsFailureAndProtocolExemption() {
        let epoch = UUID(), at = Date(timeIntervalSince1970: 1000)
        let command = HRDomainService.SpeedCommand(targetKmh: 6.2, increaseSampleAt: at)
        for (units, status, observedAt, truthEpoch) in [
            (ControllerUnits.metric, ControllerUnitsTruthStatus.valid, at.addingTimeInterval(-31), epoch),
            (.imperial, .valid, at, epoch), (.unknown, .valid, at, epoch),
            (.metric, .invalidChecksum, at, epoch), (.metric, .malformed, at, epoch),
            (.metric, .valid, at, UUID())
        ] {
            let truth = ControllerUnitsTruth(connectionEpoch: truthEpoch, units: units,
                status: status, observedAt: observedAt, rawHex: nil)
            let gate = ControllerUnitsSafetyPolicy.evaluate(path: .hrControl, state: truth,
                currentConnectionEpoch: epoch, now: at, requiresFreshMetricTruth: true)
            XCTAssertFalse(gate.allowed)
            XCTAssertEqual(HRDomainService.speedCommandBlockReason(command, isRunning: true,
                unitsAllowed: gate.allowed, now: at), "hr_units_blocked_before_write")
        }
        let exempt = ControllerUnitsSafetyPolicy.evaluate(path: .hrControl, state: .disconnected,
            currentConnectionEpoch: nil, now: at, requiresFreshMetricTruth: false)
        XCTAssertNil(HRDomainService.speedCommandBlockReason(command, isRunning: true,
            unitsAllowed: exempt.allowed, now: at))
    }

    func testDecisionRequiresFreshMeasurementAndInclusiveMonotonicInterval() {
        func due(age: Double = 0, elapsed: Duration = .seconds(9), interval: Int = 9) -> Bool {
            HRDomainService.heartRateDecisionIsDue(sampleAgeSeconds: age,
                elapsedSinceLastDecision: elapsed, intervalSeconds: interval)
        }
        XCTAssertTrue(due())
        XCTAssertTrue(due(age: 7))
        for age in [-0.001, 7.001, .nan, .infinity] { XCTAssertFalse(due(age: age)) }
        XCTAssertFalse(due(elapsed: .milliseconds(8_999)))
        XCTAssertFalse(due(elapsed: .seconds(-1)))
        XCTAssertFalse(due(elapsed: .seconds(8), interval: 1))
        XCTAssertTrue(due(interval: 1))
        XCTAssertFalse(due(interval: 12))
        XCTAssertTrue(due(elapsed: .seconds(12), interval: 12))
    }

    func testFrequentAndBatchedSamplesCannotBurstOrConsumeIntervalWhenStale() {
        let deliveries: [(milliseconds: Int, age: Double)] = [
            (0, 0), (5_000, 0), (9_000, 7.1), (10_000, 4.4),
            (10_001, 0), (10_002, 0), (15_000, 0), (19_000, 7), (20_000, 0),
        ]
        var lastDecision: Duration = .zero
        var decisions: [Int] = []
        for delivery in deliveries {
            let now = Duration.milliseconds(delivery.milliseconds)
            if HRDomainService.heartRateDecisionIsDue(sampleAgeSeconds: delivery.age,
                elapsedSinceLastDecision: now - lastDecision, intervalSeconds: 9) {
                decisions.append(delivery.milliseconds)
                lastDecision = now
            }
        }
        XCTAssertEqual(decisions, [10_000, 19_000])
    }

    func testDecisionCountdownIsPresentationOnlyAndRoundsUp() {
        for (elapsed, expected) in [(0, 9), (1, 9), (8_999, 1), (9_000, 0), (20_000, 0)] {
            XCTAssertEqual(HRDomainService.heartRateDecisionRemainingSeconds(
                elapsedSinceLastDecision: .milliseconds(elapsed), intervalSeconds: 9), expected)
        }
    }

    func testCooldownEvidenceRequiresFreshCurrentSessionTimestamp() {
        let start = Date(timeIntervalSince1970: 100)
        let now = start.addingTimeInterval(30)
        for limit in [2.0, 7.0] {
            for age in [0.0, limit] {
                XCTAssertTrue(HRDomainService.cooldownEvidenceIsCurrent(
                    observedAt: now.addingTimeInterval(-age), sessionStartedAt: start,
                    now: now, freshnessLimit: limit))
            }
            for observed in [nil, start.addingTimeInterval(-1), now.addingTimeInterval(1),
                             now.addingTimeInterval(-limit - 0.001)] as [Date?] {
                XCTAssertFalse(HRDomainService.cooldownEvidenceIsCurrent(
                    observedAt: observed, sessionStartedAt: start, now: now, freshnessLimit: limit))
            }
            XCTAssertFalse(HRDomainService.cooldownEvidenceIsCurrent(
                observedAt: now, sessionStartedAt: nil, now: now, freshnessLimit: limit))
        }
    }

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

    func testCooldownSpeedSnapshotRequiresFreshFactualCurrentConnectionEvidence() {
        let epoch = TreadmillConnectionEpoch(rawValue: UUID())
        let start = Date(timeIntervalSince1970: 100)
        let now = start.addingTimeInterval(30)
        func snapshot(rawSpeed: Int? = 350, age: Double = 0,
                      sourceEpoch: TreadmillConnectionEpoch? = nil) -> HRDomainService.CooldownSpeedSnapshot {
            var normalizer = TreadmillObservationNormalizer()
            let observation = normalizer.normalize(
                .ftms(speedRawHundredthsKmh: rawSpeed, rawState: nil, deviceState: .moving,
                      connectionEpoch: sourceEpoch ?? epoch, receivedAt: now.addingTimeInterval(-age)),
                unitsTruth: nil, observationID: ObservationID(), recordedAt: now)
            return HRDomainService.cooldownSpeedSnapshot(
                desiredSpeedKmh: 3.5, deviceTargetSpeedKmh: 4.7, observation: observation,
                connectionEpoch: epoch, sessionStartedAt: start, now: now, freshnessLimit: 2)
        }
        for age in [0.0, 2.0] {
            let current = snapshot(age: age)
            XCTAssertEqual(current.factualSpeedKmh, 3.5)
            XCTAssertEqual(current.observedSpeedKmh, 3.5)
            XCTAssertEqual(current.controllerSpeedKmh, 4.7)
        }
        XCTAssertEqual(snapshot(rawSpeed: 0).factualSpeedKmh, 0)
        for rejected in [snapshot(rawSpeed: nil), snapshot(age: 2.001), snapshot(age: -1),
                         snapshot(age: 31), snapshot(sourceEpoch: TreadmillConnectionEpoch(rawValue: UUID()))] {
            XCTAssertNil(rejected.factualSpeedKmh)
            XCTAssertEqual(rejected.observedSpeedKmh, 4.7)
        }
        let missing = HRDomainService.cooldownSpeedSnapshot(
            desiredSpeedKmh: 3.5, deviceTargetSpeedKmh: 4.7, observation: nil,
            connectionEpoch: epoch, sessionStartedAt: start, now: now, freshnessLimit: 2)
        XCTAssertNil(missing.factualSpeedKmh)
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
