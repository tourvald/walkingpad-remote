import Foundation

public protocol ControlCycleObservation: Sendable {
    func measureControlCycle(_ operation: () -> Void)
}

/// Hosted deterministic replay for the non-hardware soak harness. Its private
/// HR reference is assembled from existing primitive helpers and is not a
/// production control authority. Only the checksum leaves this helper; replay
/// inputs and outputs are never logged or persisted.
public enum DeterministicControlReplay {
    public static func checksum(
        durationSeconds: Int,
        observation: any ControlCycleObservation
    ) -> String {
        var checksum: UInt64 = 14_695_981_039_346_656_037
        var cooldownState: CooldownRuntimeEngine.State?
        var cooldownSpeedKmh = 6.0

        for elapsedSecond in 0..<max(1, durationSeconds) {
            var heartRateReference: HarnessHeartRateReference?
            observation.measureControlCycle {
                heartRateReference = makeHarnessHeartRateReference(
                    elapsedSecond: elapsedSecond
                )
            }
            if let heartRateReference {
                checksum = updateChecksum(checksum, reference: heartRateReference)
            }

            var cooldownOutput: CooldownRuntimeEngine.Output?
            observation.measureControlCycle {
                if elapsedSecond.isMultiple(of: 180) || cooldownState == nil {
                    cooldownSpeedKmh = 6.0
                    cooldownOutput = CooldownRuntimeEngine.start(
                        config: cooldownConfig,
                        input: CooldownRuntimeEngine.StartInput(
                            currentBpm: 138,
                            deviceTargetSpeedKmh: cooldownSpeedKmh,
                            actualSpeedKmh: cooldownSpeedKmh,
                            sessionAggregates: cooldownAggregates
                        )
                    )
                } else if let cooldownState {
                    let bpm = 136 - (elapsedSecond % 36)
                    cooldownOutput = CooldownRuntimeEngine.tick(
                        state: cooldownState,
                        config: cooldownConfig,
                        input: CooldownRuntimeEngine.TickInput(
                            hrBpm: bpm,
                            decisionBpm: bpm,
                            hrAvailable: true,
                            speedSnapshot: HRDomainService.CooldownSpeedSnapshot(
                                observedSpeedKmh: cooldownSpeedKmh,
                                controllerSpeedKmh: cooldownSpeedKmh,
                                factualSpeedKmh: cooldownSpeedKmh
                            ),
                            sessionAggregates: cooldownAggregates
                        )
                    )
                }
            }
            if let cooldownOutput {
                cooldownState = cooldownOutput.state
                for effect in cooldownOutput.effects {
                    if case let .setSpeed(speedEffect) = effect {
                        cooldownSpeedKmh = speedEffect.targetKmh
                    }
                }
                checksum = updateChecksum(
                    checksum,
                    bytes: String(reflecting: cooldownOutput).utf8
                )
            }
        }

        return String(format: "%016llx", checksum)
    }

    private struct HarnessHeartRateReference {
        let predictedBpm: Int?
        let effectiveBpm: Int
        let diffBpm: Int
        let diffPercent: Double
        let deadbandBpm: Int
        let stepLevel: Int
        let stepKmh: Double
        let speedBeforeKmh: Double
        let speedAfterKmh: Double
        let branch: String
    }

    private static func makeHarnessHeartRateReference(
        elapsedSecond: Int
    ) -> HarnessHeartRateReference {
        let currentBpm = 92 + (elapsedSecond * 7) % 48
        let trend: Double? = elapsedSecond.isMultiple(of: 5)
            ? 0.18
            : (elapsedSecond.isMultiple(of: 7) ? -0.12 : nil)
        let predictedValue = trend.map { Double(currentBpm) + $0 * 15.0 }
        let predictedBpm = predictedValue.map { Int(round($0)) }
        let effectiveBpm = max(currentBpm, predictedBpm ?? currentBpm)
        let diffBpm = effectiveBpm - 110
        let diffPercent = HRDomainService.diffPercent(
            absDiff: abs(diffBpm),
            targetBpm: 110
        )
        let thresholds = HRDomainService.AdaptiveThresholdPercents(
            deadband: 3.0,
            downLevel2Start: 8.0,
            downLevel3Start: 15.0,
            downLevel4Start: 23.0,
            upLevel2Start: 23.0,
            upLevel3Start: 31.0,
            upLevel4Start: 46.0
        )
        let deadbandBpm = HRDomainService.deadbandBpm(
            targetBpm: 110,
            thresholds: thresholds
        )
        let direction = diffBpm > 0 ? -1.0 : 1.0
        let adaptiveStepEnabled = !elapsedSecond.isMultiple(of: 11)
        let stepSelection = adaptiveStepEnabled
            ? HRDomainService.stepFromDiff(
                diffPercent: diffPercent,
                isIncreasingSpeed: direction > 0,
                thresholds: thresholds
            )
            : HRDomainService.AdaptiveStepSelection(
                level: 4,
                stepKmh: HRDomainService.quantizeSpeedStep(0.5)
            )
        let stepKmh = HRDomainService.quantizeSpeedStep(stepSelection.stepKmh)
        let currentTarget = 0.5 + Double((elapsedSecond * 3) % 116) / 10.0
        let speedBounds = TreadmillSpeedBoundsService.normalized(
            min: 0.5,
            max: 12.0,
            increment: 0.1
        )

        let branch: String
        let nextSpeed: Double
        if abs(diffBpm) <= deadbandBpm {
            branch = "hold"
            nextSpeed = currentTarget
        } else if direction > 0,
                  let trend,
                  trend > 0,
                  let predictedValue,
                  predictedValue >= 108.0 {
            branch = "inertia_hold"
            nextSpeed = currentTarget
        } else {
            nextSpeed = TreadmillSpeedBoundsService.clampRunningSpeed(
                currentTarget + direction * stepKmh,
                bounds: speedBounds
            )
            branch = nextSpeed == currentTarget ? "speed_limit" : "set_speed"
        }

        return HarnessHeartRateReference(
            predictedBpm: predictedBpm,
            effectiveBpm: effectiveBpm,
            diffBpm: diffBpm,
            diffPercent: diffPercent,
            deadbandBpm: deadbandBpm,
            stepLevel: stepSelection.level,
            stepKmh: stepKmh,
            speedBeforeKmh: currentTarget,
            speedAfterKmh: nextSpeed,
            branch: branch
        )
    }

    private static let cooldownConfig = CooldownRuntimeEngine.Config(
        targetBpm: 110,
        minSpeedKmh: 3.5,
        maxMinutes: 2,
        holdSeconds: 8,
        baseStepKmh: 0.5,
        stepIntervalSeconds: 10
    )

    private static let cooldownAggregates = CooldownRuntimeEngine.SessionAggregates(
        sessionPeakBpm: 168,
        mainAvgBpm: 148,
        mainPeakBpm: 171,
        zoneSeconds: [10, 20, 30, 40, 50],
        zone4PlusSeconds: 90
    )

    private static func updateChecksum<Bytes: Sequence>(
        _ checksum: UInt64,
        bytes: Bytes
    ) -> UInt64 where Bytes.Element == UInt8 {
        var result = checksum
        for byte in bytes {
            result ^= UInt64(byte)
            result &*= 1_099_511_628_211
        }
        result ^= 0xff
        result &*= 1_099_511_628_211
        return result
    }

    private static func updateChecksum(
        _ checksum: UInt64,
        reference: HarnessHeartRateReference
    ) -> UInt64 {
        var result = checksum

        func append(_ value: UInt64) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes in
                result = updateChecksum(result, bytes: bytes)
            }
        }

        append(reference.predictedBpm == nil ? 0 : 1)
        append(UInt64(bitPattern: Int64(reference.predictedBpm ?? 0)))
        append(UInt64(bitPattern: Int64(reference.effectiveBpm)))
        append(UInt64(bitPattern: Int64(reference.diffBpm)))
        append(reference.diffPercent.bitPattern)
        append(UInt64(bitPattern: Int64(reference.deadbandBpm)))
        append(UInt64(bitPattern: Int64(reference.stepLevel)))
        append(reference.stepKmh.bitPattern)
        append(reference.speedBeforeKmh.bitPattern)
        append(reference.speedAfterKmh.bitPattern)
        return updateChecksum(result, bytes: reference.branch.utf8)
    }
}
