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

public enum SemanticControlReplayScenario: String, Codable, CaseIterable, Sendable {
    case normalHeartRateControl
    case delayedHeartRate
    case missingHeartRate
    case overshootPrediction
    case speedLimits
    case disconnect
    case cooldown
    case stop
    case startAffordanceRuntimeAuthorization
}

public enum SemanticControlReplayOutput: Codable, Equatable, Sendable {
    case start(speedKilometresPerHour: Double)
    case setSpeed(kilometresPerHour: Double)
    case hold(reason: String)
    case waitForHeartRate
    case stop(reason: String)
    case runtimeAuthorizationBlocked
}

public struct SemanticControlReplayResult: Codable, Equatable, Sendable {
    public let scenario: SemanticControlReplayScenario
    public let startAffordanceAvailable: Bool
    public let runtimeAuthorizationAllowed: Bool
    public let outputs: [SemanticControlReplayOutput]

    public init(
        scenario: SemanticControlReplayScenario,
        startAffordanceAvailable: Bool,
        runtimeAuthorizationAllowed: Bool,
        outputs: [SemanticControlReplayOutput]
    ) {
        self.scenario = scenario
        self.startAffordanceAvailable = startAffordanceAvailable
        self.runtimeAuthorizationAllowed = runtimeAuthorizationAllowed
        self.outputs = outputs
    }
}

public struct SemanticControlReplayObservation: Codable, Equatable, Sendable {
    public let scenario: SemanticControlReplayScenario
    public let step: String
    public let heartRateBpm: Int?
    public let targetHeartRateBpm: Int
    public let controllerSpeedKilometresPerHour: Double

    public init(
        scenario: SemanticControlReplayScenario,
        step: String,
        heartRateBpm: Int?,
        targetHeartRateBpm: Int,
        controllerSpeedKilometresPerHour: Double
    ) {
        self.scenario = scenario
        self.step = step
        self.heartRateBpm = heartRateBpm
        self.targetHeartRateBpm = targetHeartRateBpm
        self.controllerSpeedKilometresPerHour = controllerSpeedKilometresPerHour
    }
}

public protocol SemanticControlReplayTelemetryObserver: AnyObject, Sendable {
    func observe(_ observation: SemanticControlReplayObservation)
}

public extension DeterministicControlReplay {
    /// Replays normalized harness observations through the current pure controller
    /// helpers. The optional observer is write-only: no telemetry-derived value is
    /// read while choosing outputs, and the harness never reaches BLE transport.
    static func run(
        scenario: SemanticControlReplayScenario,
        telemetryObserver: (any SemanticControlReplayTelemetryObserver)? = nil
    ) -> SemanticControlReplayResult {
        let treadmillConnected = scenario != .disconnect
        let currentHeartRateVisible = scenario != .missingHeartRate
        let watchReachable = scenario != .startAffordanceRuntimeAuthorization
        let affordance = HRDomainService.heartRateStartAffordanceAvailable(
            treadmillConnected: treadmillConnected,
            currentHeartRateVisible: currentHeartRateVisible
        )
        let runtimeAuthorization = HRDomainService.heartRateRuntimePrerequisitesAllowStart(
            treadmillConnected: treadmillConnected,
            watchReachable: watchReachable,
            currentHeartRateVisible: currentHeartRateVisible
        )

        let outputs: [SemanticControlReplayOutput]
        switch scenario {
        case .normalHeartRateControl:
            outputs = [heartRateOutput(
                scenario: scenario,
                heartRateBpm: 90,
                predictedBpm: nil,
                currentSpeed: 4.0,
                observer: telemetryObserver
            )]

        case .delayedHeartRate:
            telemetryObserver?.observe(
                observation(
                    scenario: scenario,
                    step: "within_initial_grace",
                    heartRateBpm: nil,
                    speed: 4.0
                )
            )
            outputs = [
                .waitForHeartRate,
                heartRateOutput(
                    scenario: scenario,
                    heartRateBpm: 92,
                    predictedBpm: nil,
                    currentSpeed: 4.0,
                    observer: telemetryObserver
                ),
            ]

        case .missingHeartRate:
            let missingSeconds = HRDomainService.missingHeartRateSignalSeconds(
                lastReceivedAt: nil,
                now: Date(timeIntervalSince1970: 100),
                noDataMaximumSeconds: 30
            )
            telemetryObserver?.observe(
                observation(
                    scenario: scenario,
                    step: "missing_heart_rate",
                    heartRateBpm: nil,
                    speed: 4.0
                )
            )
            outputs = HRDomainService.shouldStopForMissingHeartRateSignal(
                missingSeconds: missingSeconds,
                noDataMaximumSeconds: 30
            ) ? [.stop(reason: "missingHeartRate")] : [.hold(reason: "missingHeartRate")]

        case .overshootPrediction:
            outputs = [heartRateOutput(
                scenario: scenario,
                heartRateBpm: 108,
                predictedBpm: 116,
                currentSpeed: 6.0,
                observer: telemetryObserver
            )]

        case .speedLimits:
            outputs = [heartRateOutput(
                scenario: scenario,
                heartRateBpm: 80,
                predictedBpm: nil,
                currentSpeed: 12.0,
                observer: telemetryObserver
            )]

        case .disconnect:
            telemetryObserver?.observe(
                observation(
                    scenario: scenario,
                    step: "connection_lost",
                    heartRateBpm: 105,
                    speed: 5.0
                )
            )
            outputs = [.stop(reason: "disconnect")]

        case .cooldown:
            let config = CooldownRuntimeEngine.Config(
                targetBpm: 110,
                minSpeedKmh: 3.5,
                maxMinutes: 2,
                holdSeconds: 8,
                baseStepKmh: 0.5,
                stepIntervalSeconds: 10
            )
            let aggregates = CooldownRuntimeEngine.SessionAggregates(
                sessionPeakBpm: 168,
                mainAvgBpm: 148,
                mainPeakBpm: 171,
                zoneSeconds: [10, 20, 30, 40, 50],
                zone4PlusSeconds: 90
            )
            telemetryObserver?.observe(
                observation(
                    scenario: scenario,
                    step: "cooldown_start",
                    heartRateBpm: 145,
                    speed: 6.0
                )
            )
            let cooldown = CooldownRuntimeEngine.start(
                config: config,
                input: CooldownRuntimeEngine.StartInput(
                    currentBpm: 145,
                    deviceTargetSpeedKmh: 6.0,
                    actualSpeedKmh: 6.0,
                    sessionAggregates: aggregates
                )
            )
            outputs = cooldown.effects.compactMap { effect in
                guard case let .setSpeed(speed) = effect else { return nil }
                return .setSpeed(kilometresPerHour: speed.targetKmh)
            }

        case .stop:
            telemetryObserver?.observe(
                observation(
                    scenario: scenario,
                    step: "manual_stop",
                    heartRateBpm: 105,
                    speed: 5.0
                )
            )
            outputs = [.stop(reason: "manualStop")]

        case .startAffordanceRuntimeAuthorization:
            telemetryObserver?.observe(
                observation(
                    scenario: scenario,
                    step: "post_tap_runtime_authorization",
                    heartRateBpm: 100,
                    speed: 0
                )
            )
            outputs = runtimeAuthorization
                ? [.start(speedKilometresPerHour: 3.0)]
                : [.runtimeAuthorizationBlocked]
        }

        return SemanticControlReplayResult(
            scenario: scenario,
            startAffordanceAvailable: affordance,
            runtimeAuthorizationAllowed: runtimeAuthorization,
            outputs: outputs
        )
    }

    private static func heartRateOutput(
        scenario: SemanticControlReplayScenario,
        heartRateBpm: Int,
        predictedBpm: Int?,
        currentSpeed: Double,
        observer: (any SemanticControlReplayTelemetryObserver)?
    ) -> SemanticControlReplayOutput {
        let targetBpm = 110
        observer?.observe(
            observation(
                scenario: scenario,
                step: "heart_rate_decision",
                heartRateBpm: heartRateBpm,
                speed: currentSpeed
            )
        )
        let effectiveBpm = max(heartRateBpm, predictedBpm ?? heartRateBpm)
        let diff = effectiveBpm - targetBpm
        let thresholds = HRDomainService.AdaptiveThresholdPercents(
            deadband: 3.0,
            downLevel2Start: 8.0,
            downLevel3Start: 15.0,
            downLevel4Start: 23.0,
            upLevel2Start: 23.0,
            upLevel3Start: 31.0,
            upLevel4Start: 46.0
        )
        let deadband = HRDomainService.deadbandBpm(
            targetBpm: targetBpm,
            thresholds: thresholds
        )
        guard abs(diff) > deadband else { return .hold(reason: "deadband") }
        let increasing = diff < 0
        let selection = HRDomainService.stepFromDiff(
            diffPercent: HRDomainService.diffPercent(
                absDiff: abs(diff),
                targetBpm: targetBpm
            ),
            isIncreasingSpeed: increasing,
            thresholds: thresholds
        )
        let direction = increasing ? 1.0 : -1.0
        let bounds = TreadmillSpeedBoundsService.normalized(
            min: 0.5,
            max: 12.0,
            increment: 0.1
        )
        let next = TreadmillSpeedBoundsService.clampRunningSpeed(
            currentSpeed + direction * selection.stepKmh,
            bounds: bounds
        )
        guard next != currentSpeed else { return .hold(reason: "speedLimit") }
        return .setSpeed(kilometresPerHour: next)
    }

    private static func observation(
        scenario: SemanticControlReplayScenario,
        step: String,
        heartRateBpm: Int?,
        speed: Double
    ) -> SemanticControlReplayObservation {
        SemanticControlReplayObservation(
            scenario: scenario,
            step: step,
            heartRateBpm: heartRateBpm,
            targetHeartRateBpm: 110,
            controllerSpeedKilometresPerHour: speed
        )
    }
}
