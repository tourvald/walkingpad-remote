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
        holdSeconds: Int = 3,
        baseStepKmh: Double = 0.5,
        stepIntervalSeconds: Int = 10
    ) -> CooldownRuntimeEngine.Config {
        CooldownRuntimeEngine.Config(
            targetBpm: targetBpm,
            minSpeedKmh: minSpeedKmh,
            maxMinutes: maxMinutes,
            holdSeconds: holdSeconds,
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
            holdSeconds: 3,
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
        let config = makeConfig(holdSeconds: 1)
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
        let config = makeConfig(holdSeconds: 5)
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

    func testStableReachedAfterHoldSeconds() {
        let config = makeConfig(holdSeconds: 3)
        var state = startOutput(config: config, currentBpm: 118, deviceTargetSpeedKmh: 4.0, actualSpeedKmh: 4.0).state
        var output = startOutput(config: config, currentBpm: 118, deviceTargetSpeedKmh: 4.0, actualSpeedKmh: 4.0)

        for _ in 0..<3 {
            output = tickOutput(
                state: state,
                config: config,
                hrBpm: 108,
                observedSpeedKmh: 3.5,
                controllerSpeedKmh: 3.5,
                factualSpeedKmh: 3.5
            )
            state = output.state
        }

        let completion = output.effects.first {
            if case .complete = $0 { return true }
            return false
        }

        guard case let .complete(effect)? = completion else {
            return XCTFail("Expected cooldown completion")
        }

        XCTAssertEqual(effect.reason, "stable_reached")
        XCTAssertEqual(effect.timeoutBlocker, "")
        XCTAssertEqual(output.state.finishReason, "stable_reached")
    }

    func testTimeoutEmitsCorrectBlocker() {
        let config = makeConfig(holdSeconds: 3)
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
        let config = makeConfig(holdSeconds: 3)
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

        let stableConfig = makeConfig(holdSeconds: 1)
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
        let config = makeConfig(holdSeconds: 20, stepIntervalSeconds: 10)
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
