import Foundation

public protocol ControlCycleObservation: Sendable {
    func measureControlCycle(_ operation: () -> Void)
}

/// Hosted deterministic replay of the pure HR-decision and cooldown seams used
/// by the application. Only the checksum leaves this helper; replay inputs and
/// outputs are never logged or persisted.
public enum DeterministicControlReplay {
    public static func checksum(
        durationSeconds: Int,
        observation: any ControlCycleObservation
    ) -> String {
        var checksum: UInt64 = 14_695_981_039_346_656_037
        var cooldownState: CooldownRuntimeEngine.State?
        var cooldownSpeedKmh = 6.0

        for elapsedSecond in 0..<max(1, durationSeconds) {
            var heartRateDecision: HRDomainService.HeartRateControlDecision?
            observation.measureControlCycle {
                heartRateDecision = makeHeartRateDecision(
                    elapsedSecond: elapsedSecond
                )
            }
            if let heartRateDecision {
                checksum = updateChecksum(
                    checksum,
                    bytes: String(reflecting: heartRateDecision).utf8
                )
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

    private static func makeHeartRateDecision(
        elapsedSecond: Int
    ) -> HRDomainService.HeartRateControlDecision {
        let currentBpm = 92 + (elapsedSecond * 7) % 48
        let trend: Double? = elapsedSecond.isMultiple(of: 5)
            ? 0.18
            : (elapsedSecond.isMultiple(of: 7) ? -0.12 : nil)
        let predictedValue = trend.map { Double(currentBpm) + $0 * 15.0 }
        let predictedBpm = predictedValue.map { Int(round($0)) }
        let currentTarget = 0.5 + Double((elapsedSecond * 3) % 116) / 10.0
        return HRDomainService.heartRateControlDecision(
            currentBpm: currentBpm,
            predictedBpm: predictedBpm,
            predictedValue: predictedValue,
            trendBpmPerSecond: trend,
            targetBpm: 110,
            predictMarginBpm: 2,
            adaptiveStepEnabled: !elapsedSecond.isMultiple(of: 11),
            fixedStepKmh: 0.5,
            thresholds: HRDomainService.AdaptiveThresholdPercents(
                deadband: 3.0,
                downLevel2Start: 8.0,
                downLevel3Start: 15.0,
                downLevel4Start: 23.0,
                upLevel2Start: 23.0,
                upLevel3Start: 31.0,
                upLevel4Start: 46.0
            ),
            currentTargetSpeedKmh: currentTarget,
            speedBounds: TreadmillSpeedBoundsService.normalized(
                min: 0.5,
                max: 12.0,
                increment: 0.1
            )
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
}
