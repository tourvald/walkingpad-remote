import Foundation

enum CooldownRuntimeEngine {
    struct Config: Equatable {
        let targetBpm: Int
        let minSpeedKmh: Double
        let maxMinutes: Int
        let holdSeconds: Int
        let baseStepKmh: Double
        let stepIntervalSeconds: Int
    }

    struct SessionAggregates: Equatable {
        let sessionPeakBpm: Int
        let mainAvgBpm: Int
        let mainPeakBpm: Int
        let zoneSeconds: [Int]
        let zone4PlusSeconds: Int

        init(
            sessionPeakBpm: Int,
            mainAvgBpm: Int,
            mainPeakBpm: Int,
            zoneSeconds: [Int],
            zone4PlusSeconds: Int
        ) {
            self.sessionPeakBpm = sessionPeakBpm
            self.mainAvgBpm = mainAvgBpm
            self.mainPeakBpm = mainPeakBpm
            self.zoneSeconds = Self.normalizedZoneSeconds(zoneSeconds)
            self.zone4PlusSeconds = zone4PlusSeconds
        }

        private static func normalizedZoneSeconds(_ zoneSeconds: [Int]) -> [Int] {
            var normalized = Array(zoneSeconds.prefix(5))
            while normalized.count < 5 {
                normalized.append(0)
            }
            return normalized
        }
    }

    struct StartInput: Equatable {
        let currentBpm: Int
        let deviceTargetSpeedKmh: Double
        let actualSpeedKmh: Double
        let sessionAggregates: SessionAggregates
    }

    struct TickInput: Equatable {
        let hrBpm: Int
        let decisionBpm: Int
        let hrAvailable: Bool
        let speedSnapshot: HRDomainService.CooldownSpeedSnapshot
        let sessionAggregates: SessionAggregates
    }

    struct State: Equatable {
        let baseMaxSeconds: Int
        let totalSeconds: Int
        var remainingSeconds: Int
        let startSpeedKmh: Double
        var lastSentSpeedKmh: Double
        let baseStepKmh: Double
        let stepIntervalSeconds: Int
        let holdSeconds: Int
        var startBpm: Int
        var endBpm: Int
        var peakBpm: Int
        var targetHitElapsedSeconds: Int?
        var firstMinSpeedElapsedSeconds: Int?
        var firstStableElapsedSeconds: Int?
        var belowTargetSeconds: Int
        var minSpeedSeconds: Int
        var targetAndMinSpeedSeconds: Int
        var maxStableStreakSeconds: Int
        var stableSeconds: Int
        var finishReason: String
        var timeoutBlocker: String

        var elapsedSeconds: Int {
            max(0, totalSeconds - remainingSeconds)
        }

        var progress: Double {
            guard totalSeconds > 0 else { return 0 }
            return 1.0 - (Double(remainingSeconds) / Double(totalSeconds))
        }

        var hrDropBpm: Int {
            guard startBpm > 0, endBpm > 0 else { return 0 }
            return startBpm - endBpm
        }

        var recoveryBpmPerMinute: Double {
            let elapsed = elapsedSeconds
            guard elapsed > 0 else { return 0 }
            return (Double(hrDropBpm) * 60.0) / Double(elapsed)
        }
    }

    struct Presentation: Equatable {
        let statusLine: String
        let decisionDetails: String
        let remainingSeconds: Int
        let progress: Double
    }

    struct StartTelemetry: Equatable {
        let fromSpeedKmh: Double
        let targetBpm: Int
        let minSpeedKmh: Double
        let stepKmh: Double
        let intervalSeconds: Int
        let baseMaxSeconds: Int
        let maxSeconds: Int
        let extraSeconds: Int
        let startBpm: Int
        let sessionAggregates: SessionAggregates
    }

    struct SpeedSetTelemetry: Equatable {
        let hrBpm: Int
        let targetBpm: Int
        let adaptiveFactor: Double
        let stepKmh: Double
        let speedBeforeKmh: Double
        let speedAfterKmh: Double
        let elapsedSeconds: Int
        let trigger: String
    }

    struct StateTelemetry: Equatable {
        let hrBpm: Int
        let targetBpm: Int
        let observedSpeedKmh: Double
        let controllerSpeedKmh: Double
        let elapsedSeconds: Int
        let stableSeconds: Int
        let stableRequiredSeconds: Int
        let remainingSeconds: Int
        let targetHitElapsedSeconds: Int?
        let hrOk: Bool
        let minSpeedOk: Bool
        let stableOk: Bool
        let blocker: String
        let firstMinSpeedElapsedSeconds: Int?
        let firstStableElapsedSeconds: Int?
        let belowTargetSeconds: Int
        let minSpeedSeconds: Int
        let targetAndMinSpeedSeconds: Int
        let maxStableStreakSeconds: Int
        let startBpm: Int
        let sessionAggregates: SessionAggregates
    }

    struct FinalTelemetry: Equatable {
        let reason: String
        let timeoutBlocker: String
        let hrBpm: Int
        let targetBpm: Int
        let observedSpeedKmh: Double
        let controllerSpeedKmh: Double
        let hrOk: Bool
        let minSpeedOk: Bool
        let stableOk: Bool
        let blocker: String
        let firstMinSpeedElapsedSeconds: Int?
        let firstStableElapsedSeconds: Int?
        let belowTargetSeconds: Int
        let minSpeedSeconds: Int
        let targetAndMinSpeedSeconds: Int
        let maxStableStreakSeconds: Int
        let stableSeconds: Int
        let stableRequiredSeconds: Int
        let elapsedSeconds: Int
        let plannedSeconds: Int
        let remainingSeconds: Int
        let targetHitElapsedSeconds: Int?
        let startBpm: Int
        let endBpm: Int
        let peakBpm: Int
        let hrDropBpm: Int
        let recoveryBpmPerMinute: Double
        let sessionAggregates: SessionAggregates
    }

    struct InsufficientTelemetry: Equatable {
        let hrBpm: Int
        let targetBpm: Int
        let excessBpm: Int
        let finishReason: String
        let timeoutBlocker: String
        let observedSpeedKmh: Double
        let controllerSpeedKmh: Double
        let firstMinSpeedElapsedSeconds: Int?
        let firstStableElapsedSeconds: Int?
        let belowTargetSeconds: Int
        let minSpeedSeconds: Int
        let targetAndMinSpeedSeconds: Int
        let maxStableStreakSeconds: Int
        let elapsedSeconds: Int
        let plannedSeconds: Int
        let startBpm: Int
        let endBpm: Int
        let hrDropBpm: Int
        let recoveryBpmPerMinute: Double
        let sessionAggregates: SessionAggregates
    }

    enum TelemetryEffect: Equatable {
        case start(StartTelemetry)
        case speedSet(SpeedSetTelemetry)
        case state(StateTelemetry)
        case analysis(FinalTelemetry)
        case complete(FinalTelemetry)
        case insufficient(InsufficientTelemetry)
    }

    struct SetSpeedEffect: Equatable {
        let targetKmh: Double
        let stepKmh: Double
        let adaptiveFactor: Double
        let speedBeforeKmh: Double
        let speedAfterKmh: Double
        let elapsedSeconds: Int
        let trigger: String
        let hrBpm: Int
    }

    struct CompletionEffect: Equatable {
        let reason: String
        let timeoutBlocker: String
        let shouldRecordWorkout: Bool
        let shouldStopSession: Bool
        let shouldStopBelt: Bool
        let shouldStopWatch: Bool
        let structuredLogReason: String
    }

    enum Effect: Equatable {
        case status(Presentation)
        case setSpeed(SetSpeedEffect)
        case telemetry(TelemetryEffect)
        case complete(CompletionEffect)
    }

    struct Output: Equatable {
        let state: State
        let presentation: Presentation
        let effects: [Effect]
    }

    static func start(config: Config, input: StartInput) -> Output {
        let baseMaxSeconds = max(60, config.maxMinutes * 60)
        let startBpm = max(0, input.currentBpm)
        let cooldownPlan = HRDomainService.cooldownPlan(
            baseMinutes: config.maxMinutes,
            startBpm: startBpm,
            targetBpm: config.targetBpm
        )
        let startSpeedKmh = max(
            config.minSpeedKmh,
            input.deviceTargetSpeedKmh > 0.1 ? input.deviceTargetSpeedKmh : input.actualSpeedKmh
        )

        var state = State(
            baseMaxSeconds: baseMaxSeconds,
            totalSeconds: cooldownPlan.totalSeconds,
            remainingSeconds: cooldownPlan.totalSeconds,
            startSpeedKmh: startSpeedKmh,
            lastSentSpeedKmh: startSpeedKmh,
            baseStepKmh: max(0.1, min(2.0, config.baseStepKmh)),
            stepIntervalSeconds: max(1, config.stepIntervalSeconds),
            holdSeconds: max(1, config.holdSeconds),
            startBpm: startBpm,
            endBpm: startBpm,
            peakBpm: startBpm,
            targetHitElapsedSeconds: nil,
            firstMinSpeedElapsedSeconds: nil,
            firstStableElapsedSeconds: nil,
            belowTargetSeconds: 0,
            minSpeedSeconds: 0,
            targetAndMinSpeedSeconds: 0,
            maxStableStreakSeconds: 0,
            stableSeconds: 0,
            finishReason: "",
            timeoutBlocker: ""
        )

        var effects: [Effect] = []
        let initialPresentation = startPresentation(config: config, state: state)
        effects.append(.status(initialPresentation))
        effects.append(.telemetry(.start(StartTelemetry(
            fromSpeedKmh: state.startSpeedKmh,
            targetBpm: config.targetBpm,
            minSpeedKmh: config.minSpeedKmh,
            stepKmh: state.baseStepKmh,
            intervalSeconds: state.stepIntervalSeconds,
            baseMaxSeconds: baseMaxSeconds,
            maxSeconds: cooldownPlan.totalSeconds,
            extraSeconds: cooldownPlan.totalSeconds - baseMaxSeconds,
            startBpm: state.startBpm,
            sessionAggregates: input.sessionAggregates
        ))))

        let initialDecisionBpm = state.startBpm > 0 ? state.startBpm : config.targetBpm
        if let speedEffect = makeSetSpeedEffectIfNeeded(
            state: &state,
            config: config,
            currentBpm: initialDecisionBpm,
            controllerSpeedKmh: input.deviceTargetSpeedKmh,
            elapsedSeconds: 0,
            trigger: "cooldown_start"
        ) {
            effects.append(.setSpeed(speedEffect))
            effects.append(.telemetry(.speedSet(SpeedSetTelemetry(
                hrBpm: speedEffect.hrBpm,
                targetBpm: config.targetBpm,
                adaptiveFactor: speedEffect.adaptiveFactor,
                stepKmh: speedEffect.stepKmh,
                speedBeforeKmh: speedEffect.speedBeforeKmh,
                speedAfterKmh: speedEffect.speedAfterKmh,
                elapsedSeconds: speedEffect.elapsedSeconds,
                trigger: speedEffect.trigger
            ))))
        }

        return Output(
            state: state,
            presentation: initialPresentation,
            effects: effects
        )
    }

    static func tick(state: State, config: Config, input: TickInput) -> Output {
        var nextState = state
        nextState.remainingSeconds = max(0, nextState.remainingSeconds - 1)

        if input.hrAvailable && input.hrBpm > 0 {
            if nextState.startBpm <= 0 {
                nextState.startBpm = input.hrBpm
            }
            nextState.endBpm = input.hrBpm
            nextState.peakBpm = max(nextState.peakBpm, input.hrBpm)
        }

        let elapsed = nextState.elapsedSeconds
        let observedSpeed = input.speedSnapshot.observedSpeedKmh
        let hrOk = input.hrAvailable && input.hrBpm <= config.targetBpm
        let minSpeedOk = observedSpeed <= config.minSpeedKmh + 0.05
        let stableOk = hrOk && minSpeedOk
        let blocker = stabilityBlocker(
            hrAvailable: input.hrAvailable,
            hrOk: hrOk,
            minSpeedOk: minSpeedOk
        )

        if hrOk && nextState.targetHitElapsedSeconds == nil {
            nextState.targetHitElapsedSeconds = elapsed
        }
        if minSpeedOk && nextState.firstMinSpeedElapsedSeconds == nil {
            nextState.firstMinSpeedElapsedSeconds = elapsed
        }
        if hrOk {
            nextState.belowTargetSeconds += 1
        }
        if minSpeedOk {
            nextState.minSpeedSeconds += 1
        }
        if stableOk && nextState.firstStableElapsedSeconds == nil {
            nextState.firstStableElapsedSeconds = elapsed
        }
        if stableOk {
            nextState.stableSeconds += 1
            nextState.targetAndMinSpeedSeconds += 1
            nextState.maxStableStreakSeconds = max(nextState.maxStableStreakSeconds, nextState.stableSeconds)
        } else {
            nextState.stableSeconds = 0
        }
        if blocker != "ready" {
            nextState.timeoutBlocker = blocker
        }

        var effects: [Effect] = []
        effects.append(.telemetry(.state(StateTelemetry(
            hrBpm: input.hrBpm,
            targetBpm: config.targetBpm,
            observedSpeedKmh: observedSpeed,
            controllerSpeedKmh: input.speedSnapshot.controllerSpeedKmh,
            elapsedSeconds: elapsed,
            stableSeconds: nextState.stableSeconds,
            stableRequiredSeconds: nextState.holdSeconds,
            remainingSeconds: nextState.remainingSeconds,
            targetHitElapsedSeconds: nextState.targetHitElapsedSeconds,
            hrOk: hrOk,
            minSpeedOk: minSpeedOk,
            stableOk: stableOk,
            blocker: blocker,
            firstMinSpeedElapsedSeconds: nextState.firstMinSpeedElapsedSeconds,
            firstStableElapsedSeconds: nextState.firstStableElapsedSeconds,
            belowTargetSeconds: nextState.belowTargetSeconds,
            minSpeedSeconds: nextState.minSpeedSeconds,
            targetAndMinSpeedSeconds: nextState.targetAndMinSpeedSeconds,
            maxStableStreakSeconds: nextState.maxStableStreakSeconds,
            startBpm: nextState.startBpm,
            sessionAggregates: input.sessionAggregates
        ))))

        if nextState.totalSeconds > 0,
           nextState.stepIntervalSeconds > 0,
           elapsed % nextState.stepIntervalSeconds == 0,
           let speedEffect = makeSetSpeedEffectIfNeeded(
                state: &nextState,
                config: config,
                currentBpm: input.decisionBpm,
                controllerSpeedKmh: input.speedSnapshot.controllerSpeedKmh,
                elapsedSeconds: elapsed,
                trigger: "interval"
           ) {
            effects.append(.setSpeed(speedEffect))
            effects.append(.telemetry(.speedSet(SpeedSetTelemetry(
                hrBpm: speedEffect.hrBpm,
                targetBpm: config.targetBpm,
                adaptiveFactor: speedEffect.adaptiveFactor,
                stepKmh: speedEffect.stepKmh,
                speedBeforeKmh: speedEffect.speedBeforeKmh,
                speedAfterKmh: speedEffect.speedAfterKmh,
                elapsedSeconds: speedEffect.elapsedSeconds,
                trigger: speedEffect.trigger
            ))))
        }

        let completionReason: String?
        if nextState.stableSeconds >= nextState.holdSeconds {
            completionReason = "stable_reached"
        } else if nextState.remainingSeconds == 0 {
            completionReason = "timeout"
        } else {
            completionReason = nil
        }

        let presentation: Presentation
        if let completionReason {
            let timeoutBlocker = completionReason == "timeout"
                ? (blocker == "ready" ? "hold_not_satisfied" : blocker)
                : ""
            nextState.finishReason = completionReason
            nextState.timeoutBlocker = timeoutBlocker

            let finalTelemetry = FinalTelemetry(
                reason: completionReason,
                timeoutBlocker: timeoutBlocker,
                hrBpm: input.hrBpm,
                targetBpm: config.targetBpm,
                observedSpeedKmh: observedSpeed,
                controllerSpeedKmh: input.speedSnapshot.controllerSpeedKmh,
                hrOk: hrOk,
                minSpeedOk: minSpeedOk,
                stableOk: stableOk,
                blocker: blocker,
                firstMinSpeedElapsedSeconds: nextState.firstMinSpeedElapsedSeconds,
                firstStableElapsedSeconds: nextState.firstStableElapsedSeconds,
                belowTargetSeconds: nextState.belowTargetSeconds,
                minSpeedSeconds: nextState.minSpeedSeconds,
                targetAndMinSpeedSeconds: nextState.targetAndMinSpeedSeconds,
                maxStableStreakSeconds: nextState.maxStableStreakSeconds,
                stableSeconds: nextState.stableSeconds,
                stableRequiredSeconds: nextState.holdSeconds,
                elapsedSeconds: nextState.elapsedSeconds,
                plannedSeconds: nextState.totalSeconds,
                remainingSeconds: nextState.remainingSeconds,
                targetHitElapsedSeconds: nextState.targetHitElapsedSeconds,
                startBpm: nextState.startBpm,
                endBpm: nextState.endBpm,
                peakBpm: nextState.peakBpm,
                hrDropBpm: nextState.hrDropBpm,
                recoveryBpmPerMinute: nextState.recoveryBpmPerMinute,
                sessionAggregates: input.sessionAggregates
            )
            effects.append(.telemetry(.analysis(finalTelemetry)))
            effects.append(.telemetry(.complete(finalTelemetry)))
            if completionReason == "timeout", input.hrBpm > config.targetBpm {
                effects.append(.telemetry(.insufficient(InsufficientTelemetry(
                    hrBpm: input.hrBpm,
                    targetBpm: config.targetBpm,
                    excessBpm: input.hrBpm - config.targetBpm,
                    finishReason: completionReason,
                    timeoutBlocker: timeoutBlocker,
                    observedSpeedKmh: observedSpeed,
                    controllerSpeedKmh: input.speedSnapshot.controllerSpeedKmh,
                    firstMinSpeedElapsedSeconds: nextState.firstMinSpeedElapsedSeconds,
                    firstStableElapsedSeconds: nextState.firstStableElapsedSeconds,
                    belowTargetSeconds: nextState.belowTargetSeconds,
                    minSpeedSeconds: nextState.minSpeedSeconds,
                    targetAndMinSpeedSeconds: nextState.targetAndMinSpeedSeconds,
                    maxStableStreakSeconds: nextState.maxStableStreakSeconds,
                    elapsedSeconds: nextState.elapsedSeconds,
                    plannedSeconds: nextState.totalSeconds,
                    startBpm: nextState.startBpm,
                    endBpm: nextState.endBpm,
                    hrDropBpm: nextState.hrDropBpm,
                    recoveryBpmPerMinute: nextState.recoveryBpmPerMinute,
                    sessionAggregates: input.sessionAggregates
                ))))
            }
            presentation = Presentation(
                statusLine: "Заминка завершена",
                decisionDetails: runningDecisionDetails(
                    hrBpm: input.hrBpm,
                    targetBpm: config.targetBpm,
                    observedSpeedKmh: observedSpeed,
                    stableSeconds: nextState.stableSeconds,
                    holdSeconds: nextState.holdSeconds
                ),
                remainingSeconds: nextState.remainingSeconds,
                progress: nextState.progress
            )
            effects.append(.status(presentation))
            effects.append(.complete(CompletionEffect(
                reason: completionReason,
                timeoutBlocker: timeoutBlocker,
                shouldRecordWorkout: true,
                shouldStopSession: true,
                shouldStopBelt: true,
                shouldStopWatch: true,
                structuredLogReason: "cooldown_\(completionReason)"
            )))
        } else {
            presentation = Presentation(
                statusLine: "Заминка",
                decisionDetails: runningDecisionDetails(
                    hrBpm: input.hrBpm,
                    targetBpm: config.targetBpm,
                    observedSpeedKmh: observedSpeed,
                    stableSeconds: nextState.stableSeconds,
                    holdSeconds: nextState.holdSeconds
                ),
                remainingSeconds: nextState.remainingSeconds,
                progress: nextState.progress
            )
            effects.insert(.status(presentation), at: 0)
        }

        return Output(
            state: nextState,
            presentation: presentation,
            effects: effects
        )
    }

    private static func startPresentation(config: Config, state: State) -> Presentation {
        Presentation(
            statusLine: "Заминка",
            decisionDetails: "Заминка: цель \(config.targetBpm) bpm, мин. скорость \(String(format: "%.1f", config.minSpeedKmh)) км/ч",
            remainingSeconds: state.remainingSeconds,
            progress: state.progress
        )
    }

    private static func runningDecisionDetails(
        hrBpm: Int,
        targetBpm: Int,
        observedSpeedKmh: Double,
        stableSeconds: Int,
        holdSeconds: Int
    ) -> String {
        "Заминка: HR \(hrBpm) / цель \(targetBpm) · скорость \(String(format: "%.1f", observedSpeedKmh)) · стаб \(stableSeconds)/\(holdSeconds)с"
    }

    private static func stabilityBlocker(
        hrAvailable: Bool,
        hrOk: Bool,
        minSpeedOk: Bool
    ) -> String {
        if !hrAvailable { return "no_hr" }
        if !hrOk && !minSpeedOk { return "hr_above_target_and_speed_above_min" }
        if !hrOk { return "hr_above_target" }
        if !minSpeedOk { return "speed_above_min" }
        return "ready"
    }

    private static func makeSetSpeedEffectIfNeeded(
        state: inout State,
        config: Config,
        currentBpm: Int,
        controllerSpeedKmh: Double,
        elapsedSeconds: Int,
        trigger: String
    ) -> SetSpeedEffect? {
        guard state.totalSeconds > 0 else { return nil }

        let reductionStep = HRDomainService.cooldownReductionStepKmh(
            baseStepKmh: state.baseStepKmh,
            currentBpm: currentBpm,
            targetBpm: config.targetBpm,
            startBpm: state.startBpm > 0 ? state.startBpm : currentBpm,
            elapsedSeconds: elapsedSeconds,
            totalSeconds: state.totalSeconds
        )
        let adaptiveFactor = reductionStep / max(0.1, state.baseStepKmh)
        guard let target = HRDomainService.cooldownNextTargetSpeedKmh(
            currentSentSpeedKmh: state.lastSentSpeedKmh,
            minSpeedKmh: config.minSpeedKmh,
            reductionStepKmh: reductionStep
        ) else {
            return nil
        }

        state.lastSentSpeedKmh = target
        return SetSpeedEffect(
            targetKmh: target,
            stepKmh: reductionStep,
            adaptiveFactor: adaptiveFactor,
            speedBeforeKmh: controllerSpeedKmh,
            speedAfterKmh: target,
            elapsedSeconds: elapsedSeconds,
            trigger: trigger,
            hrBpm: currentBpm
        )
    }
}
