import Foundation
import XCTest

final class HeartRateLegacyBehaviorContractTests: XCTestCase {
    private lazy var managerSource = source(
        relativePath: "WalkingPadRemote/BluetoothManager.swift"
    )
    private lazy var contentViewSource = source(
        relativePath: "WalkingPadRemote/ContentView.swift"
    )
    private lazy var watchSource = source(
        relativePath: "WalkingPadRemoteWatch Watch App/WatchHeartRateManager.swift"
    )
    private lazy var normalizationSource = source(
        relativePath: "Sources/TelemetryDomain/HeartRateNormalization.swift"
    )

    func testLegacyWatchPayloadCarriesHeartRateValue() throws {
        let body = try functionBody(
            "private func sendHeartRate(_ value: Double, callbackObservedAt: Date)",
            in: watchSource
        )

        XCTAssertTrue(body.contains("\"hr\": value"))
        XCTAssertTrue(body.contains("\"hr_callback_observed_at\""))
        XCTAssertTrue(body.contains("\"hr_sequence\""))
        XCTAssertTrue(body.contains("session.sendMessage(payload"))
        XCTAssertTrue(body.contains("session.updateApplicationContext(payload)"))
    }

    func testEveryValidLegacyPayloadUpdatesControllerStateAndPredictorInOrder() throws {
        let body = try functionBody(
            "private func handleWatchPayload(_ payload: [String: Any])",
            in: managerSource
        )

        assertOrdered(
            [
                "HRDomainService.applyHeartRateDelivery(",
                "self.observeHeartRateDelivery(",
            ],
            in: body
        )
        let delivery = try functionBody(
            "static func applyHeartRateDelivery(",
            in: source(relativePath: "WalkingPadRemote/HRDomainService.swift")
        )
        assertOrdered(
            [
                "updateCurrent(beatsPerMinute)",
                "updateLastKnown(beatsPerMinute)",
                "updateLastReceivedAt(now())",
                "recordPredictorInput(beatsPerMinute)",
            ],
            in: delivery
        )
        XCTAssertFalse(body.contains("HeartRateLegacyControlSemantics"))
        XCTAssertFalse(body.contains("dedup"))
        XCTAssertFalse(body.contains("sorted"))
        XCTAssertFalse(body.contains("debounce"))
        XCTAssertTrue(body.contains("let phoneReceivedAt = Date()"))
        XCTAssertFalse(body.contains("Task"))
        XCTAssertFalse(body.contains("await"))
        XCTAssertFalse(body.contains("TelemetryRecorder"))
        XCTAssertFalse(body.contains("TelemetryPersistence"))
        XCTAssertFalse(body.contains("SwiftData"))
    }

    func testActualControlUseIsObservedAtTheExistingSpeedDecisionBranch() throws {
        let tick = try functionBody("private func tickTelemetry()", in: managerSource)

        assertOrdered(
            [
                "guard hrStreamingActive, heartRateBPM > 0",
                "let trend = currentHrTrendBpmPerSecond()",
                "let controlUseEvidence = makeHeartRateControlUseEvidence(",
                "defer { observeHeartRateControlUse(controlUseEvidence) }",
                "let effectiveBpm = max(heartRateBPM",
            ],
            in: tick
        )
        XCTAssertFalse(
            try functionBody(
                "private func observeHeartRateDelivery(",
                in: managerSource
            ).contains("usedForControl")
        )
    }

    func testStartAffordanceIsSeparateFromRuntimeAuthorization() throws {
        let recompute = try functionBody(
            "private func recomputeHrStartAllowed()",
            in: managerSource
        )
        let start = try functionBody("func startHrControl()", in: managerSource)
        let affordance = try functionBody(
            "var isHrControlStartAffordanceAvailable: Bool",
            in: managerSource
        )

        for body in [recompute, start] {
            XCTAssertTrue(body.contains("HRDomainService"))
            XCTAssertTrue(body.contains(".heartRateRuntimePrerequisitesAllowStart"))
            XCTAssertTrue(body.contains("controllerUnits"))
            XCTAssertFalse(body.contains("HeartRateControlStartEligibility"))
            XCTAssertFalse(body.contains("HeartRateLegacyControlSemantics"))
            XCTAssertFalse(body.contains("TelemetryRecorder"))
            XCTAssertFalse(body.contains("TelemetryPersistence"))
            XCTAssertFalse(body.contains("telemetry health"))
        }

        XCTAssertTrue(affordance.contains("HRDomainService.heartRateStartAffordanceAvailable"))
        XCTAssertTrue(affordance.contains("treadmillConnected: isConnected"))
        XCTAssertTrue(affordance.contains("currentHeartRateVisible: hrStreamingActive"))
        XCTAssertFalse(affordance.contains("watchReachable"))
        XCTAssertFalse(affordance.contains("controllerUnits"))
        XCTAssertFalse(affordance.contains("telemetry"))

        XCTAssertTrue(
            contentViewSource.contains(
                "let canStartHrControl = manager.isHrControlStartAffordanceAvailable"
            )
        )
        XCTAssertFalse(
            contentViewSource.contains(
                "manager.isHrControlStartAllowed && manager.watchReachable && manager.hrStreamingActive"
            )
        )
        XCTAssertTrue(contentViewSource.contains("enabled: !isPreviewMode && canStartHrControl"))

        assertOrdered(
            [
                ".heartRateRuntimePrerequisitesAllowStart",
                "guard existingGatesAllowStart",
                "let unitsDecision = controllerUnitsGateDecision()",
                "guard unitsDecision.allowed",
                "persistBlockedControllerUnitsStart(decision: unitsDecision)",
                "retryControllerUnitsQueryAfterBlockedStart()",
                "let legacySessionID = startTrainingStructuredLog(trigger: \"start_hr\")",
                "isHrControlRunning = true",
                "beginTelemetryV2Session(legacySessionID: legacySessionID)",
                "startWithSpeed",
            ],
            in: start
        )
    }

    func testTelemetryV2LifecycleHooksCannotPerformPersistenceOnControlPaths() throws {
        let start = try functionBody("func startHrControl()", in: managerSource)
        let begin = try functionBody(
            "private func beginTelemetryV2Session(legacySessionID: UUID?)",
            in: managerSource
        )
        let end = try functionBody(
            "private func endTelemetryV2Session(reason: String)",
            in: managerSource
        )
        let forbidden = [
            "TelemetryStore",
            "TelemetryRecorder",
            "FileManager",
            "FileHandle",
            "trainingLogQueue.sync",
            "await ",
            ".finish(",
            ".finalize",
        ]
        for body in [start, begin, end] {
            for token in forbidden {
                XCTAssertFalse(body.contains(token), "Control path contains \(token)")
            }
        }
        XCTAssertTrue(begin.contains("telemetryV2Coordinator.beginSession(descriptor)"))
        XCTAssertTrue(end.contains("telemetryV2Coordinator.endSession(reason: reason)"))
        XCTAssertFalse(start.contains("telemetryV2Status"))
    }

    func testTelemetryV2FinalizationIsAfterExistingProductStopEffects() throws {
        let manual = try functionBody("func stopHrControl()", in: managerSource)
        assertOrdered(
            [
                "stopTrainingStructuredLog(reason: \"manual_stop\")",
                "isHrControlRunning = false",
                "stopBeltWithToggle(reason: \"hr\")",
                "sendWatchCommand(\"stop_hr\")",
                "endTelemetryV2Session(reason: \"manual_stop\")",
            ],
            in: manual
        )

        let cooldown = try functionBody(
            "private func executeCooldownEffect(",
            in: managerSource
        )
        assertOrdered(
            [
                "stopTrainingStructuredLog(reason: completionEffect.structuredLogReason)",
                "sendWatchCommand(\"stop_hr\")",
                "stopBeltWithToggle(reason: \"hr_cooldown_done\")",
                "endTelemetryV2Session(reason: completionEffect.structuredLogReason)",
            ],
            in: cooldown
        )

        let disconnect = try functionBody(
            "private func disconnect(userInitiated: Bool = false)",
            in: managerSource
        )
        assertOrdered(
            [
                "stopTrainingStructuredLog(reason:",
                "central.cancelPeripheralConnection(p)",
                "self.stopTelemetry()",
                "self.isHrControlRunning = false",
                "self.endTelemetryV2Session(",
            ],
            in: disconnect
        )
    }

    func testTelemetryV2LifecycleRaceCannotBranchProductOrLegacyOutputs() throws {
        let start = try functionBody("func startHrControl()", in: managerSource)
        let stop = try functionBody("func stopHrControl()", in: managerSource)
        let begin = try functionBody(
            "private func beginTelemetryV2Session(legacySessionID: UUID?)",
            in: managerSource
        )
        let end = try functionBody(
            "private func endTelemetryV2Session(reason: String)",
            in: managerSource
        )

        for productPath in [start, stop] {
            for forbiddenBranch in [
                "if telemetryV2",
                "guard telemetryV2",
                "telemetryV2Status",
                "telemetryV2Coordinator.status",
            ] {
                XCTAssertFalse(productPath.contains(forbiddenBranch))
            }
        }
        assertOrdered(
            [
                "let legacySessionID = startTrainingStructuredLog(trigger: \"start_hr\")",
                "isHrControlRunning = true",
                "beginTelemetryV2Session(legacySessionID: legacySessionID)",
                "startWithSpeed",
            ],
            in: start
        )
        assertOrdered(
            [
                "stopTrainingStructuredLog(reason: \"manual_stop\")",
                "isHrControlRunning = false",
                "stopBeltWithToggle(reason: \"hr\")",
                "sendWatchCommand(\"stop_hr\")",
                "endTelemetryV2Session(reason: \"manual_stop\")",
            ],
            in: stop
        )
        XCTAssertTrue(begin.contains("telemetryV2Coordinator.beginSession(descriptor)"))
        XCTAssertTrue(end.contains("telemetryV2Coordinator.endSession(reason: reason)"))
        XCTAssertFalse(begin.contains("return telemetryV2Coordinator"))
        XCTAssertFalse(end.contains("return telemetryV2Coordinator"))
    }

    func testControlSafetyAuthorityIsOutsideTelemetryNormalization() throws {
        XCTAssertTrue(managerSource.contains("private let hrStartGraceSeconds: Int = 15"))
        XCTAssertTrue(managerSource.contains("private let hrNoDataMaxSeconds: Int = 60"))
        XCTAssertTrue(managerSource.contains("private let hrStaleThresholdSeconds: Int = 7"))

        let staleTimer = try functionBody(
            "private func startHrStaleTimer()",
            in: managerSource
        )
        XCTAssertTrue(staleTimer.contains("HRDomainService.heartRateStreamIsActive("))

        let tick = try functionBody("private func tickTelemetry()", in: managerSource)
        XCTAssertTrue(tick.contains("HRDomainService.shouldStopForMissingHeartRateSignal("))
        XCTAssertTrue(tick.contains("HRDomainService.isWithinInitialHeartRateGrace("))
        XCTAssertTrue(tick.contains(".missingHeartRateSignalSeconds("))

        let recompute = try functionBody(
            "private func recomputeHrStartAllowed()",
            in: managerSource
        )
        let start = try functionBody("func startHrControl()", in: managerSource)
        for body in [start, recompute, staleTimer, tick] {
            XCTAssertFalse(body.contains("HeartRateLegacyControlSemantics"))
            XCTAssertFalse(body.contains("HeartRateControlStartEligibility"))
        }
        XCTAssertFalse(normalizationSource.contains("HeartRateLegacyControlSemantics"))
        XCTAssertFalse(normalizationSource.contains("HeartRateControlStartEligibility"))
        XCTAssertFalse(normalizationSource.contains("heartRateStartAffordanceAvailable"))
        XCTAssertFalse(normalizationSource.contains("heartRateRuntimePrerequisitesAllowStart"))
        XCTAssertFalse(normalizationSource.contains("heartRateStreamIsActive"))
        XCTAssertFalse(normalizationSource.contains("isWithinInitialHeartRateGrace"))
        XCTAssertFalse(normalizationSource.contains("missingHeartRateSignalSeconds"))
        XCTAssertFalse(normalizationSource.contains("shouldStopForMissingHeartRateSignal"))
    }

    func testWatchStartStopLifecycleRemainsOwnedByExistingCommands() throws {
        let start = try functionBody("func start()", in: watchSource)
        let stop = try functionBody("func stop()", in: watchSource)
        let command = try functionBody("private func handleCommand(_ cmd: String)", in: watchSource)

        XCTAssertTrue(start.contains("startWorkout()"))
        XCTAssertTrue(stop.contains("workoutController.endAndFinish()"))
        XCTAssertTrue(stop.contains("sendStatus(\"hr_stopped\")"))
        XCTAssertTrue(command.contains("start_hr"))
        XCTAssertTrue(command.contains("stop_hr"))
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
            throw NSError(domain: "HeartRateLegacyBehaviorContractTests", code: 1)
        }
        var depth = 0
        var index = openingBrace
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[openingBrace...index])
                }
            default: break
            }
            index = source.index(after: index)
        }
        throw NSError(domain: "HeartRateLegacyBehaviorContractTests", code: 2)
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
