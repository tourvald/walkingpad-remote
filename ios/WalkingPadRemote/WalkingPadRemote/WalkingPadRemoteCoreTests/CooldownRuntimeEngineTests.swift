import XCTest
@testable import WalkingPadCoreLogic

final class CooldownRuntimeEngineTests: XCTestCase {
    private let aggregates = CooldownRuntimeEngine.SessionAggregates(
        sessionPeakBpm: 168,
        mainAvgBpm: 148,
        mainPeakBpm: 171,
        zoneSeconds: [10, 20, 30, 40, 50],
        zone4PlusSeconds: 90
    )

    private func makeConfig(
        targetBpm: Int = 110,
        minSpeedKmh: Double = 3.5,
        maxMinutes: Int = 1,
        baseStepKmh: Double = 0.5,
        stepIntervalSeconds: Int = 10
    ) -> CooldownRuntimeEngine.Config {
        CooldownRuntimeEngine.Config(
            targetBpm: targetBpm,
            minSpeedKmh: minSpeedKmh,
            maxMinutes: maxMinutes,
            baseStepKmh: baseStepKmh,
            stepIntervalSeconds: stepIntervalSeconds
        )
    }

    private func makeSpeedSnapshot(
        observedSpeedKmh: Double,
        controllerSpeedKmh: Double,
        factualSpeedKmh: Double? = nil
    ) -> HRDomainService.CooldownSpeedSnapshot {
        HRDomainService.CooldownSpeedSnapshot(
            observedSpeedKmh: observedSpeedKmh,
            controllerSpeedKmh: controllerSpeedKmh,
            factualSpeedKmh: factualSpeedKmh
        )
    }

    private func startOutput(
        config: CooldownRuntimeEngine.Config = CooldownRuntimeEngine.Config(
            targetBpm: 110,
            minSpeedKmh: 3.5,
            maxMinutes: 1,
            baseStepKmh: 0.5,
            stepIntervalSeconds: 10
        ),
        currentBpm: Int = 130,
        deviceTargetSpeedKmh: Double = 6.0,
        actualSpeedKmh: Double = 6.0
    ) -> CooldownRuntimeEngine.Output {
        CooldownRuntimeEngine.start(
            config: config,
            input: CooldownRuntimeEngine.StartInput(
                currentBpm: currentBpm,
                deviceTargetSpeedKmh: deviceTargetSpeedKmh,
                actualSpeedKmh: actualSpeedKmh,
                sessionAggregates: aggregates
            )
        )
    }

    private func tickOutput(
        state: CooldownRuntimeEngine.State,
        config: CooldownRuntimeEngine.Config,
        hrBpm: Int,
        decisionBpm: Int? = nil,
        hrAvailable: Bool = true,
        observedSpeedKmh: Double,
        controllerSpeedKmh: Double,
        factualSpeedKmh: Double? = nil
    ) -> CooldownRuntimeEngine.Output {
        CooldownRuntimeEngine.tick(
            state: state,
            config: config,
            input: CooldownRuntimeEngine.TickInput(
                hrBpm: hrBpm,
                decisionBpm: decisionBpm ?? hrBpm,
                hrAvailable: hrAvailable,
                speedSnapshot: makeSpeedSnapshot(
                    observedSpeedKmh: observedSpeedKmh,
                    controllerSpeedKmh: controllerSpeedKmh,
                    factualSpeedKmh: factualSpeedKmh
                ),
                sessionAggregates: aggregates
            )
        )
    }

    func testStartEmitsImmediateSpeedReductionWhenAboveMinSpeed() {
        let output = startOutput()

        let speedEffect = output.effects.first {
            if case .setSpeed = $0 { return true }
            return false
        }

        guard case let .setSpeed(effect)? = speedEffect else {
            return XCTFail("Expected immediate cooldown speed effect")
        }

        XCTAssertEqual(effect.targetKmh, 5.2, accuracy: 0.0001)
        XCTAssertEqual(effect.elapsedSeconds, 0)
        XCTAssertEqual(effect.trigger, "cooldown_start")
    }

    func testStartDoesNotEmitSpeedReductionAtMinSpeed() {
        let output = startOutput(
            currentBpm: 120,
            deviceTargetSpeedKmh: 3.5,
            actualSpeedKmh: 3.5
        )

        XCTAssertFalse(output.effects.contains {
            if case .setSpeed = $0 { return true }
            return false
        })
    }

    func testTickPrefersFactualSpeedOverStaleControllerTargetForMinSpeedCheck() {
        let config = makeConfig()
        let started = startOutput(config: config)

        let output = tickOutput(
            state: started.state,
            config: config,
            hrBpm: 108,
            observedSpeedKmh: 3.5,
            controllerSpeedKmh: 4.7,
            factualSpeedKmh: 3.5
        )

        let stateEffect = output.effects.first {
            if case .telemetry(.state) = $0 { return true }
            return false
        }

        guard case let .telemetry(.state(effect))? = stateEffect else {
            return XCTFail("Expected cooldown_state telemetry")
        }

        XCTAssertTrue(effect.minSpeedOk)
        XCTAssertTrue(effect.hrOk)
        XCTAssertTrue(effect.stableOk)
        XCTAssertEqual(effect.blocker, "ready")
    }

    func testTickUpdatesCooldownCounters() {
        let config = makeConfig()
        let started = startOutput(config: config, currentBpm: 118, deviceTargetSpeedKmh: 4.0, actualSpeedKmh: 4.0)

        let output = tickOutput(
            state: started.state,
            config: config,
            hrBpm: 109,
            observedSpeedKmh: 3.5,
            controllerSpeedKmh: 3.5,
            factualSpeedKmh: 3.5
        )

        XCTAssertEqual(output.state.remainingSeconds, output.state.totalSeconds - 1)
        XCTAssertEqual(output.state.targetHitElapsedSeconds, 1)
        XCTAssertEqual(output.state.firstMinSpeedElapsedSeconds, 1)
        XCTAssertEqual(output.state.firstStableElapsedSeconds, 1)
        XCTAssertEqual(output.state.belowTargetSeconds, 1)
        XCTAssertEqual(output.state.minSpeedSeconds, 1)
        XCTAssertEqual(output.state.targetAndMinSpeedSeconds, 1)
        XCTAssertEqual(output.state.stableSeconds, 1)
    }

    func testFirstSimultaneousFactualTargetHitCompletesWithoutHold() {
        let config = makeConfig()
        let start = startOutput(config: config)
        let output = tickOutput(state: start.state, config: config, hrBpm: 110,
                                observedSpeedKmh: 3.55, controllerSpeedKmh: 4.7,
                                factualSpeedKmh: 3.55)
        guard case let .complete(effect)? = output.effects.first(where: {
            if case .complete = $0 { return true }; return false
        }) else { return XCTFail("Expected completion on first qualifying evaluation") }
        XCTAssertEqual(effect.reason, "target_and_min_speed_reached")
        XCTAssertTrue(effect.shouldStopBelt)
        XCTAssertTrue(effect.shouldStopWatch)
        XCTAssertTrue(effect.shouldStopSession)
        XCTAssertTrue(effect.shouldRecordWorkout)
        XCTAssertEqual(output.state.elapsedSeconds, 1)
        XCTAssertEqual(output.state.finishReason, "target_and_min_speed_reached")
    }

    func testIncompleteOrNonFactualInputsNeverCompleteRecovery() {
        let config = makeConfig()
        let start = startOutput(config: config)
        let cases: [(Int, Bool, Double?)] = [
            (110, true, 3.56), (111, true, 3.5), (110, false, 3.5),
            (0, true, 3.5), (110, true, nil), (110, true, .nan),
            (110, true, .infinity), (110, true, -1)
        ]
        for (hr, available, factual) in cases {
            let output = tickOutput(state: start.state, config: config, hrBpm: hr,
                                    hrAvailable: available, observedSpeedKmh: 3.5,
                                    controllerSpeedKmh: 3.5, factualSpeedKmh: factual)
            XCTAssertFalse(output.effects.contains { if case .complete = $0 { return true }; return false })
            XCTAssertEqual(output.state.finishReason, "")
        }
    }

    func testEarlierTargetHitDoesNotLatchAcrossAboveTargetHeartRate() {
        let config = makeConfig()
        let start = startOutput(config: config)
        let hit = tickOutput(state: start.state, config: config, hrBpm: 110,
                             observedSpeedKmh: 4, controllerSpeedKmh: 4, factualSpeedKmh: 4)
        let rebound = tickOutput(state: hit.state, config: config, hrBpm: 111,
                                 observedSpeedKmh: 3.5, controllerSpeedKmh: 3.5, factualSpeedKmh: 3.5)
        XCTAssertEqual(rebound.state.targetHitElapsedSeconds, 1)
        XCTAssertEqual(rebound.state.firstStableElapsedSeconds, nil)
        XCTAssertFalse(rebound.effects.contains { if case .complete = $0 { return true }; return false })
        let recovered = tickOutput(state: rebound.state, config: config, hrBpm: 110,
                                   observedSpeedKmh: 3.5, controllerSpeedKmh: 3.5, factualSpeedKmh: 3.5)
        XCTAssertEqual(recovered.state.finishReason, "target_and_min_speed_reached")
        guard case let .telemetry(.complete(telemetry))? = recovered.effects.first(where: {
            if case .telemetry(.complete) = $0 { return true }; return false
        }) else { return XCTFail("Expected factual completion telemetry") }
        XCTAssertEqual(telemetry.stableRequiredSeconds, 0)
        XCTAssertTrue(telemetry.hrOk && telemetry.minSpeedOk)
        XCTAssertEqual(telemetry.elapsedSeconds, 3)
        XCTAssertFalse(recovered.presentation.decisionDetails.contains("20"))
        XCTAssertFalse(recovered.effects.contains { if case .setSpeed = $0 { return true }; return false })
    }

    func testFreshFactualZeroSpeedCanCompleteAndMissingSpeedIsExplicit() {
        let config = makeConfig()
        let state = startOutput(config: config).state
        let zero = tickOutput(state: state, config: config, hrBpm: 110,
                              observedSpeedKmh: 0, controllerSpeedKmh: 3.5, factualSpeedKmh: 0)
        XCTAssertEqual(zero.state.finishReason, "target_and_min_speed_reached")
        let missing = tickOutput(state: state, config: config, hrBpm: 110,
                                 observedSpeedKmh: 3.5, controllerSpeedKmh: 3.5)
        XCTAssertEqual(missing.state.timeoutBlocker, "no_factual_speed")
    }

    func testTimeoutWithMissingFactsDoesNotReportSuccessfulRecovery() {
        let config = makeConfig()
        var state = startOutput(config: config).state
        state.remainingSeconds = 1
        let output = tickOutput(state: state, config: config, hrBpm: 110, hrAvailable: false,
                                observedSpeedKmh: 3.5, controllerSpeedKmh: 3.5)
        XCTAssertEqual(output.state.finishReason, "timeout")
        XCTAssertEqual(output.state.timeoutBlocker, "no_hr")
        XCTAssertTrue(output.effects.contains { if case .complete = $0 { return true }; return false })
    }

    func testTimeoutEmitsCorrectBlocker() {
        let config = makeConfig()
        var state = startOutput(config: config, currentBpm: 140, deviceTargetSpeedKmh: 4.5, actualSpeedKmh: 4.5).state
        var output: CooldownRuntimeEngine.Output?

        for _ in 0..<state.totalSeconds {
            let next = tickOutput(
                state: state,
                config: config,
                hrBpm: 130,
                observedSpeedKmh: 3.5,
                controllerSpeedKmh: 3.5,
                factualSpeedKmh: 3.5
            )
            state = next.state
            output = next
        }

        guard let output else {
            return XCTFail("Expected final timeout output")
        }

        let completion = output.effects.first {
            if case .complete = $0 { return true }
            return false
        }

        guard case let .complete(effect)? = completion else {
            return XCTFail("Expected timeout completion effect")
        }

        XCTAssertEqual(effect.reason, "timeout")
        XCTAssertEqual(effect.timeoutBlocker, "hr_above_target")
        XCTAssertEqual(output.state.timeoutBlocker, "hr_above_target")
    }

    func testCooldownInsufficientEmitsOnlyOnTimeoutAboveTarget() {
        let config = makeConfig()
        var state = startOutput(config: config, currentBpm: 140, deviceTargetSpeedKmh: 4.5, actualSpeedKmh: 4.5).state
        var output: CooldownRuntimeEngine.Output?

        for _ in 0..<state.totalSeconds {
            let next = tickOutput(
                state: state,
                config: config,
                hrBpm: 130,
                observedSpeedKmh: 3.5,
                controllerSpeedKmh: 3.5,
                factualSpeedKmh: 3.5
            )
            state = next.state
            output = next
        }

        guard let output else {
            return XCTFail("Expected timeout output")
        }

        XCTAssertTrue(output.effects.contains {
            if case .telemetry(.insufficient) = $0 { return true }
            return false
        })

        let stableConfig = makeConfig()
        let stableStart = startOutput(config: stableConfig, currentBpm: 118, deviceTargetSpeedKmh: 4.0, actualSpeedKmh: 4.0)
        let stableOutput = tickOutput(
            state: stableStart.state,
            config: stableConfig,
            hrBpm: 108,
            observedSpeedKmh: 3.5,
            controllerSpeedKmh: 3.5,
            factualSpeedKmh: 3.5
        )

        XCTAssertFalse(stableOutput.effects.contains {
            if case .telemetry(.insufficient) = $0 { return true }
            return false
        })
    }

    func testImmediateAndIntervalSpeedStepsUseSameReductionRule() {
        let config = makeConfig(stepIntervalSeconds: 10)
        let start = startOutput(config: config, currentBpm: 130, deviceTargetSpeedKmh: 6.0, actualSpeedKmh: 6.0)

        guard let startEffect = start.effects.first(where: {
            if case .setSpeed = $0 { return true }
            return false
        }), case let .setSpeed(initialSpeedEffect) = startEffect else {
            return XCTFail("Expected immediate speed effect")
        }

        var state = start.state
        var intervalOutput: CooldownRuntimeEngine.Output?
        for _ in 0..<10 {
            let next = tickOutput(
                state: state,
                config: config,
                hrBpm: 130,
                observedSpeedKmh: 5.2,
                controllerSpeedKmh: state.lastSentSpeedKmh,
                factualSpeedKmh: 5.2
            )
            state = next.state
            intervalOutput = next
        }

        guard let intervalOutput,
              let intervalEffect = intervalOutput.effects.first(where: {
                  if case .setSpeed = $0 { return true }
                  return false
              }),
              case let .setSpeed(intervalSpeedEffect) = intervalEffect else {
            return XCTFail("Expected interval speed effect")
        }

        XCTAssertEqual(initialSpeedEffect.stepKmh, intervalSpeedEffect.stepKmh, accuracy: 0.0001)
    }
}
