import Foundation
@testable import WalkingPadCoreLogic
import XCTest

final class DeterministicSemanticControlReplayTests: XCTestCase {
    func testTelemetryOnAndOffProduceIdenticalOutputsForEveryRequiredScenario() {
        for scenario in SemanticControlReplayScenario.allCases {
            let collector = ReplayObservationCollector()

            let disabled = DeterministicControlReplay.run(scenario: scenario)
            let enabled = DeterministicControlReplay.run(
                scenario: scenario,
                telemetryObserver: collector
            )

            XCTAssertEqual(disabled, enabled, "scenario=\(scenario.rawValue)")
            XCTAssertFalse(collector.observations.isEmpty, "scenario=\(scenario.rawValue)")
        }
    }

    func testNormalDelayedAndPredictionScenariosPreserveExpectedBranches() {
        let normal = DeterministicControlReplay.run(scenario: .normalHeartRateControl)
        let delayed = DeterministicControlReplay.run(scenario: .delayedHeartRate)
        let prediction = DeterministicControlReplay.run(scenario: .overshootPrediction)

        XCTAssertEqual(normal.outputs, [.setSpeed(kilometresPerHour: 4.1)])
        XCTAssertEqual(
            delayed.outputs,
            [.waitForHeartRate, .setSpeed(kilometresPerHour: 4.1)]
        )
        guard case let .setSpeed(predictedSpeed) = prediction.outputs.first else {
            return XCTFail("Prediction scenario must produce a speed decision")
        }
        XCTAssertLessThan(predictedSpeed, 6.0)
    }

    func testMissingHeartRateDisconnectAndManualStopFailSafe() {
        let missing = DeterministicControlReplay.run(scenario: .missingHeartRate)
        let disconnect = DeterministicControlReplay.run(scenario: .disconnect)
        let stop = DeterministicControlReplay.run(scenario: .stop)

        XCTAssertEqual(missing.outputs, [.stop(reason: "missingHeartRate")])
        XCTAssertEqual(disconnect.outputs, [.stop(reason: "disconnect")])
        XCTAssertEqual(stop.outputs, [.stop(reason: "manualStop")])
    }

    func testSpeedLimitAndCooldownUseExistingPureHelpers() {
        let speedLimit = DeterministicControlReplay.run(scenario: .speedLimits)
        let cooldown = DeterministicControlReplay.run(scenario: .cooldown)

        XCTAssertEqual(speedLimit.outputs, [.hold(reason: "speedLimit")])
        guard case let .setSpeed(cooldownSpeed) = cooldown.outputs.first else {
            return XCTFail("Cooldown must apply its immediate pure-engine speed step")
        }
        XCTAssertLessThan(cooldownSpeed, 6.0)
        XCTAssertGreaterThanOrEqual(cooldownSpeed, 3.5)
    }

    func testStartAffordanceRemainsSeparateFromPostTapRuntimeAuthorization() {
        let result = DeterministicControlReplay.run(
            scenario: .startAffordanceRuntimeAuthorization
        )

        XCTAssertTrue(result.startAffordanceAvailable)
        XCTAssertFalse(result.runtimeAuthorizationAllowed)
        XCTAssertEqual(result.outputs, [.runtimeAuthorizationBlocked])
        XCTAssertFalse(result.outputs.contains { output in
            if case .start = output { return true }
            return false
        })
    }
}

private final class ReplayObservationCollector: SemanticControlReplayTelemetryObserver,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var stored: [SemanticControlReplayObservation] = []

    var observations: [SemanticControlReplayObservation] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func observe(_ observation: SemanticControlReplayObservation) {
        lock.lock()
        stored.append(observation)
        lock.unlock()
    }
}
