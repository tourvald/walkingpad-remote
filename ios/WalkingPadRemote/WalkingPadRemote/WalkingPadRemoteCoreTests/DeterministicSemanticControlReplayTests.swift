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

    func testReplayCompositionIsAnchoredToCurrentInlineProductionBranches() throws {
        let manager = source(relativePath: "WalkingPadRemote/BluetoothManager.swift")
        let replay = source(relativePath: "WalkingPadRemote/DeterministicControlReplay.swift")
        let tick = try functionBody("private func tickTelemetry()", in: manager)
        let affordance = try functionBody(
            "var isHrControlStartAffordanceAvailable: Bool",
            in: manager
        )
        let start = try functionBody("func startHrControl()", in: manager)
        let stop = try functionBody("func stopHrControl()", in: manager)
        let disconnect = try functionBody(
            "private func disconnect(userInitiated: Bool = false)",
            in: manager
        )

        assertOrdered(
            [
                "let predictedValue = trend.map",
                "let effectiveBpm = max(heartRateBPM, predictedBpm ?? heartRateBPM)",
                "let diff = effectiveBpm - hrTargetBPM",
                "let absDiffPercent = adaptiveDiffPercent",
                "let deadbandBpm = adaptiveDeadbandBpm",
                "let stepSelection: AdaptiveStepSelection",
                "adaptiveStepFromDiff(",
                "if absDiff <= deadbandBpm",
                "if direction > 0, let trend, trend > 0, let predictedValue",
                "let nextSpeed = clampRunningSpeedKmh(currentTarget + direction * step)",
            ],
            in: tick
        )
        XCTAssertTrue(tick.contains(".missingHeartRateSignalSeconds("))
        XCTAssertTrue(tick.contains("HRDomainService.shouldStopForMissingHeartRateSignal("))
        XCTAssertTrue(tick.contains("CooldownRuntimeEngine.start("))
        XCTAssertTrue(tick.contains("CooldownRuntimeEngine.tick("))
        XCTAssertTrue(
            affordance.contains("HRDomainService.heartRateStartAffordanceAvailable(")
        )
        assertOrdered(
            [
                "HRDomainService",
                ".heartRateRuntimePrerequisitesAllowStart(",
                "guard existingGatesAllowStart",
                "isHrControlRunning = true",
                "startWithSpeed",
            ],
            in: start
        )
        XCTAssertTrue(stop.contains("stopBeltWithToggle(reason: \"hr\")"))
        XCTAssertTrue(disconnect.contains("self.isHrControlRunning = false"))
        for sharedRule in [
            "HRDomainService.diffPercent(",
            "HRDomainService.deadbandBpm(",
            "HRDomainService.stepFromDiff(",
            "TreadmillSpeedBoundsService.clampRunningSpeed(",
            "HRDomainService.shouldStopForMissingHeartRateSignal(",
            "CooldownRuntimeEngine.start(",
            "HRDomainService.heartRateStartAffordanceAvailable(",
            "HRDomainService.heartRateRuntimePrerequisitesAllowStart(",
        ] {
            XCTAssertTrue(replay.contains(sharedRule), "Replay missing shared rule: \(sharedRule)")
        }
        XCTAssertFalse(manager.contains("SemanticControlReplayScenario"))
        XCTAssertFalse(replay.contains("BluetoothManager"))
        XCTAssertFalse(replay.contains("CoreBluetooth"))
        XCTAssertFalse(replay.contains("writeValue"))
    }

    private func source(relativePath: String) -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let root = testsDirectory.deletingLastPathComponent()
        return (try? String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )) ?? ""
    }

    private func functionBody(_ signature: String, in source: String) throws -> String {
        guard let signatureRange = source.range(of: signature),
              let openingBrace = source[signatureRange.upperBound...].firstIndex(of: "{")
        else {
            throw NSError(domain: "DeterministicSemanticControlReplayTests", code: 1)
        }
        var depth = 0
        var index = openingBrace
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(source[openingBrace...index]) }
            default: break
            }
            index = source.index(after: index)
        }
        throw NSError(domain: "DeterministicSemanticControlReplayTests", code: 2)
    }

    private func assertOrdered(
        _ fragments: [String],
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var lowerBound = source.startIndex
        for fragment in fragments {
            guard let range = source.range(
                of: fragment,
                range: lowerBound..<source.endIndex
            ) else {
                XCTFail("Missing or out-of-order fragment: \(fragment)", file: file, line: line)
                return
            }
            lowerBound = range.upperBound
        }
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
