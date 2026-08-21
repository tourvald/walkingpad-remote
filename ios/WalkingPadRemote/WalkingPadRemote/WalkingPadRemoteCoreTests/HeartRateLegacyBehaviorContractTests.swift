import Foundation
import XCTest

final class HeartRateLegacyBehaviorContractTests: XCTestCase {
    private lazy var managerSource = source(
        relativePath: "WalkingPadRemote/BluetoothManager.swift"
    )
    private lazy var contentViewSource = source(
        relativePath: "WalkingPadRemote/ContentView.swift"
    )
    private lazy var trainingLogsCardSource = source(
        relativePath: "WalkingPadRemote/DebugTrainingLogsCard.swift"
    )
    private lazy var telemetryRuntimeSource = source(
        relativePath: "Sources/TelemetryRuntime/TelemetryV2RuntimeCoordinator.swift"
    )
    private lazy var watchSource = source(
        relativePath: "WalkingPadRemoteWatch Watch App/WatchHeartRateManager.swift"
    )
    private lazy var normalizationSource = source(
        relativePath: "Sources/TelemetryDomain/HeartRateNormalization.swift"
    )
    private lazy var deterministicReplaySource = source(
        relativePath: "WalkingPadRemote/DeterministicControlReplay.swift"
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
                "let performanceInterval = telemetryPerformanceObservation",
                ".beginControlCycle()",
                "telemetryPerformanceObservation.endControlCycle(",
                "let predictedValue = trend.map",
                "let predictedBpm = predictedValue.map",
                "let effectiveBpm = max(heartRateBPM",
                "let diff = effectiveBpm - hrTargetBPM",
                "let fixedStep = max(0.1, min(2.0, hrSpeedStepKmh))",
                "let absDiff = abs(diff)",
                "let adaptiveThresholds = adaptiveThresholdPercentsSnapshot()",
                "let absDiffPercent = adaptiveDiffPercent(",
                "let deadbandBpm = adaptiveDeadbandBpm(",
                "let direction: Double = diff > 0 ? -1.0 : 1.0",
                "let stepSelection: AdaptiveStepSelection",
                "let step = quantizeSpeedStep(stepSelection.stepKmh)",
                "let currentTarget = (deviceTargetSpeedKmh > 0.1)",
                "if absDiff <= deadbandBpm",
                "if direction > 0, let trend, trend > 0, let predictedValue",
                "let threshold = Double(hrTargetBPM - hrPredictMarginBpm)",
                "let nextSpeed = clampRunningSpeedKmh(currentTarget + direction * step)",
                "if nextSpeed != currentTarget",
            ],
            in: tick
        )
        XCTAssertFalse(tick.contains("heartRateControlDecision"))
        XCTAssertFalse(tick.contains("instrumentationEnabled"))
        XCTAssertFalse(tick.contains("TelemetryPerformanceInstrumentation"))
        XCTAssertFalse(
            try functionBody(
                "private func observeHeartRateDelivery(",
                in: managerSource
            ).contains("usedForControl")
        )
    }

    func testEveryLegacyHrDecisionEmitsOnePassiveSemanticDecisionInBranchOrder() throws {
        let tick = try functionBody("private func tickTelemetry()", in: managerSource)
        let observer = try functionBody(
            "private func observeSemanticHeartRateDecision(",
            in: managerSource
        )

        XCTAssertEqual(
            tick.components(separatedBy: "logTrainingEvent(\"hr_decision\"").count - 1,
            4
        )
        XCTAssertEqual(
            tick.components(separatedBy: "observeSemanticHeartRateDecision(").count - 1,
            4
        )
        assertOrdered(
            [
                "if absDiff <= deadbandBpm",
                "\"decision\": \"hold\"",
                "reason: .withinTarget",
                "if direction > 0, let trend, trend > 0, let predictedValue",
                "\"decision\": \"inertia_hold\"",
                "reason: .heartRateInertiaHold",
                "let nextSpeed = clampRunningSpeedKmh(currentTarget + direction * step)",
                "if nextSpeed != currentTarget",
                "let telemetryDecision = makeTreadmillDecision(",
                "defer { observeTreadmillDecision(telemetryDecision) }",
                "sendTreadmillSetSpeed(",
                "\"decision\": \"set\"",
                "action: .enqueueSpeed(",
                "\"decision\": \"limit\"",
                "reason: .heartRateSpeedLimit",
            ],
            in: tick
        )
        XCTAssertFalse(tick.contains("if observeSemanticHeartRateDecision"))
        XCTAssertFalse(tick.contains("guard observeSemanticHeartRateDecision"))
        XCTAssertFalse(tick.contains("return observeSemanticHeartRateDecision"))

        XCTAssertTrue(
            observer.contains("_ = telemetryV2Coordinator.observeHeartRateControlDecision(")
        )
        for forbidden in [
            "TelemetryStore", "TelemetryPersistence", "TelemetryRecorder", "FileManager",
            "FileHandle", "Task", "await ", "logTrainingEvent", "sendTreadmill",
        ] {
            XCTAssertFalse(observer.contains(forbidden), "Decision observer contains \(forbidden)")
        }
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
            XCTAssertFalse(body.contains("telemetryV2WriterHealthSnapshot"))
            XCTAssertFalse(body.contains("telemetryPerformanceObservation"))
            XCTAssertFalse(body.contains("TelemetryPerformanceInstrumentation"))
        }

        XCTAssertTrue(affordance.contains("HRDomainService.heartRateStartAffordanceAvailable"))
        XCTAssertTrue(affordance.contains("treadmillConnected: isConnected"))
        XCTAssertTrue(affordance.contains("currentHeartRateVisible: hrStreamingActive"))
        XCTAssertFalse(affordance.contains("watchReachable"))
        XCTAssertFalse(affordance.contains("controllerUnits"))
        XCTAssertFalse(affordance.contains("telemetry"))
        XCTAssertFalse(affordance.contains("telemetryV2WriterHealthSnapshot"))

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

    func testLegacyMigrationIsStartupOnlyAndCannotEnterControlOrSafetyPaths() throws {
        let schedule = try functionBody(
            "private func scheduleLegacyTelemetryMigration()",
            in: managerSource
        )
        let startLifecycle = try functionBody("func start()", in: managerSource)
        let controlStart = try functionBody("func startHrControl()", in: managerSource)
        let recompute = try functionBody(
            "private func recomputeHrStartAllowed()",
            in: managerSource
        )
        let controlTick = try functionBody("private func tickTelemetry()", in: managerSource)

        XCTAssertTrue(schedule.contains("scheduleLegacyMigrationInBackground"))
        XCTAssertTrue(schedule.contains("LegacyTelemetryMigrationSourceDiscovery.makeRequest"))
        XCTAssertTrue(schedule.contains("sortedProfiles(userProfiles)"))
        XCTAssertFalse(schedule.contains("activeUserProfileID"))
        for forbidden in [
            "sendTreadmill", "startHrControl", "stopHrControl", "recomputeHrStartAllowed",
            "hrStartAllowed", "controllerUnits", "speedTargetKmh", "tickTelemetry",
        ] {
            XCTAssertFalse(schedule.contains(forbidden), "Migration scheduling contains \(forbidden)")
        }

        assertOrdered(
            [
                "loadProfilesState()",
                "telemetryV2Coordinator.prepareStoreAndRecover()",
                "scheduleLegacyTelemetryMigration()",
                "recomputeHrStartAllowed()",
            ],
            in: startLifecycle
        )
        for controlPath in [controlStart, recompute, controlTick] {
            XCTAssertFalse(controlPath.contains("LegacyTelemetryMigration"))
            XCTAssertFalse(controlPath.contains("scheduleLegacyMigration"))
            XCTAssertFalse(controlPath.contains("workout_history_v1"))
            XCTAssertFalse(controlPath.contains("TrainingLogs"))
        }
    }

    func testInstrumentationCannotAuthorizeControlStopCooldownOrWatchBehavior() throws {
        let start = try functionBody("func startHrControl()", in: managerSource)
        let stop = try functionBody("func stopHrControl()", in: managerSource)
        let stopBelt = try functionBody(
            "private func stopBeltWithToggle(reason: String)",
            in: managerSource
        )
        let sendWatch = try functionBody(
            "private func sendWatchCommand(_ cmd: String)",
            in: managerSource
        )
        let tick = try functionBody("private func tickTelemetry()", in: managerSource)

        for body in [start, stop, stopBelt, sendWatch] {
            XCTAssertFalse(body.contains("telemetryPerformanceObservation"))
            XCTAssertFalse(body.contains("TelemetryPerformanceInstrumentation"))
            XCTAssertFalse(body.contains("instrumentationEnabled"))
        }
        XCTAssertFalse(managerSource.contains("instrumentationEnabled"))
        XCTAssertFalse(managerSource.contains("TelemetryPerformanceInstrumentation"))
        XCTAssertFalse(watchSource.contains("TelemetryPerformanceInstrumentation"))
        XCTAssertTrue(tick.contains("telemetryPerformanceObservation.measureControlCycle"))
        XCTAssertTrue(tick.contains("CooldownRuntimeEngine.start("))
        XCTAssertTrue(tick.contains("CooldownRuntimeEngine.tick("))
        XCTAssertFalse(tick.contains("if telemetryPerformanceObservation"))
        XCTAssertFalse(tick.contains("guard telemetryPerformanceObservation"))
    }

    func testDeterministicReplayIsHarnessOnlyAndNotProductionAuthority() {
        XCTAssertFalse(managerSource.contains("DeterministicControlReplay"))
        XCTAssertFalse(managerSource.contains("heartRateControlDecision"))
        XCTAssertTrue(
            deterministicReplaySource.contains("private struct HarnessHeartRateReference")
        )
        XCTAssertTrue(deterministicReplaySource.contains("HRDomainService.diffPercent("))
        XCTAssertTrue(deterministicReplaySource.contains("HRDomainService.deadbandBpm("))
        XCTAssertTrue(deterministicReplaySource.contains("HRDomainService.stepFromDiff("))
        XCTAssertTrue(
            deterministicReplaySource.contains("TreadmillSpeedBoundsService.clampRunningSpeed(")
        )
        XCTAssertFalse(deterministicReplaySource.contains("heartRateControlDecision"))
    }

    func testTelemetryV2WriterHealthIsWiredOnlyIntoDeveloperDiagnostics() throws {
        let metrics = try functionBody(
            "private var telemetryV2WriterHealthMetrics",
            in: contentViewSource
        )
        let details = try functionBody(
            "private var telemetryV2WriterHealthDetailLines",
            in: contentViewSource
        )
        let presentation = try functionBody(
            "private var trainingLogsCardPresentation",
            in: contentViewSource
        )
        let cardBody = try functionBody("var body: some View", in: trainingLogsCardSource)

        XCTAssertTrue(metrics.contains("manager.telemetryV2WriterHealthSnapshot"))
        XCTAssertTrue(metrics.contains("snapshot.queueDepth"))
        XCTAssertTrue(metrics.contains("snapshot.lostCriticalCount"))
        XCTAssertTrue(metrics.contains("snapshot.writerFailureCount"))
        XCTAssertTrue(metrics.contains("snapshot.successfulFlushCount"))
        XCTAssertTrue(details.contains("mostRecentFlushDuration"))
        XCTAssertTrue(presentation.contains("writerHealthMetrics: telemetryV2WriterHealthMetrics"))
        XCTAssertTrue(
            presentation.contains("writerHealthDetailLines: telemetryV2WriterHealthDetailLines")
        )
        XCTAssertTrue(cardBody.contains("Telemetry V2 Writer"))
        XCTAssertTrue(cardBody.contains("presentation.writerHealthMetrics"))
        XCTAssertTrue(cardBody.contains("presentation.writerHealthDetailLines"))
    }

    func testTelemetryV2WriterHealthDiagnosticSurfaceExcludesPrivateWorkoutData() throws {
        let snapshot = try functionBody(
            "public struct TelemetryV2WriterHealthSnapshot",
            in: telemetryRuntimeSource
        )
        let metrics = try functionBody(
            "private var telemetryV2WriterHealthMetrics",
            in: contentViewSource
        )
        let details = try functionBody(
            "private var telemetryV2WriterHealthDetailLines",
            in: contentViewSource
        )
        let diagnosticSurface = snapshot + metrics + details

        for forbidden in [
            "beatsPerMinute", "heartRate", "speed", "profileLocalIdentifier",
            "stableLocalIdentifier", "sessionID", "rawBLE", "rawPayload",
            "healthPayload", "workoutExport",
        ] {
            XCTAssertFalse(
                diagnosticSurface.contains(forbidden),
                "Writer-health diagnostic surface contains \(forbidden)"
            )
        }

        let recompute = try functionBody(
            "private func recomputeHrStartAllowed()",
            in: managerSource
        )
        let start = try functionBody("func startHrControl()", in: managerSource)
        let affordance = try functionBody(
            "var isHrControlStartAffordanceAvailable: Bool",
            in: managerSource
        )
        for controlPath in [recompute, start, affordance] {
            XCTAssertFalse(controlPath.contains("telemetryV2WriterHealthSnapshot"))
            XCTAssertFalse(controlPath.contains("writerHealthSnapshot"))
        }
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
