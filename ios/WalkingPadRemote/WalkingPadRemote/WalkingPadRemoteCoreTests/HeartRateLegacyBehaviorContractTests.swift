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
        let commit = try functionBody(
            "private func commitExistingHrControl(preflightLatencySeconds: TimeInterval)",
            in: managerSource
        )

        for body in [recompute, start, commit] {
            XCTAssertFalse(body.contains("HeartRateControlStartEligibility"))
            XCTAssertFalse(body.contains("HeartRateLegacyControlSemantics"))
            XCTAssertFalse(body.contains("TelemetryRecorder"))
            XCTAssertFalse(body.contains("TelemetryPersistence"))
            XCTAssertFalse(body.contains("telemetry health"))
            XCTAssertFalse(body.contains("telemetryV2WriterHealthSnapshot"))
            XCTAssertFalse(body.contains("telemetryPerformanceObservation"))
            XCTAssertFalse(body.contains("TelemetryPerformanceInstrumentation"))
        }
        XCTAssertTrue(recompute.contains("nativeHeartRateSafetyFacts"))
        XCTAssertTrue(recompute.contains("controllerUnitsGateDecision"))
        XCTAssertTrue(start.contains("nativeHeartRatePreflightEngine.requestStart"))
        XCTAssertTrue(commit.contains("controllerUnitsGateDecision"))

        XCTAssertTrue(affordance.contains("isHrControlStartAllowed"))
        XCTAssertTrue(affordance.contains("!isNativeHeartRatePreflightActive"))
        XCTAssertFalse(affordance.contains("watchReachable"))
        XCTAssertFalse(affordance.contains("controllerUnits"))
        XCTAssertFalse(affordance.contains("telemetry"))
        XCTAssertFalse(affordance.contains("telemetryV2WriterHealthSnapshot"))

        XCTAssertTrue(
            contentViewSource.contains(
                "startEnabled: manager.isHrControlStartAffordanceAvailable"
            )
        )
        XCTAssertFalse(
            contentViewSource.contains(
                "manager.isHrControlStartAllowed && manager.watchReachable && manager.hrStreamingActive"
            )
        )
        XCTAssertTrue(contentViewSource.contains("onStart: { manager.startHrControl() }"))

        assertOrdered(
            [
                "nativeHeartRatePreflightEngine.requestStart(",
                "guard nativeHeartRatePreflightEngine.hasStartIntent",
                "nativeHeartRateFlowOwnsController = true",
                "applyNativeHeartRatePreflightEffects(effects)",
            ],
            in: start
        )
        assertOrdered(
            [
                "let unitsDecision = controllerUnitsGateDecision()",
                "guard nativeHeartRateSafetyFacts().permitsCommit",
                "let legacySessionID = startTrainingStructuredLog(trigger: \"start_hr\")",
                "isHrControlRunning = true",
                "beginTelemetryV2Session(legacySessionID: legacySessionID)",
                "startWithSpeed",
            ],
            in: commit
        )
    }

    func testTrainingHubPresentationStaysGenericAndPreviewOnlyModesCannotStart() throws {
        let mapping = try functionBody(
            "private func makeHRControlTrainingHubPresentation(",
            in: contentViewSource
        )
        let production = try functionBody(
            "private func makeProductionTrainingHubPresentation(",
            in: contentViewSource
        )
        let previewFixtures = try functionBody(
            "private func trainingHubPreviewPresentation(named name: String)",
            in: contentViewSource
        )
        let hubBody = try functionBody(
            "private struct TrainingHubView: View",
            in: contentViewSource
        )
        let contentBody = try functionBody(
            "struct ContentView: View",
            in: contentViewSource
        )

        XCTAssertTrue(mapping.contains("targetTitle: \"Зона "))
        XCTAssertTrue(mapping.contains("targetValue: \"\\(targetRange.lowerBound)–\\(targetRange.upperBound) bpm\""))
        XCTAssertTrue(mapping.contains("title: \"Пульс\""))
        XCTAssertTrue(
            mapping.contains("TrainingUIHeartRateReadinessPresentationPolicy.presentation(")
        )
        XCTAssertTrue(mapping.contains("sourceLabel: heartRateSourceLabel"))
        XCTAssertTrue(mapping.contains("startEnabled: startEnabled"))
        XCTAssertFalse(mapping.contains("startEnabled: heartRateReadiness.isReady"))
        XCTAssertFalse(mapping.contains("watchReachable"))
        XCTAssertFalse(mapping.contains("Apple Watch"))
        XCTAssertFalse(mapping.contains("Telemetry"))
        XCTAssertFalse(mapping.contains("history"))

        XCTAssertTrue(production.contains("startEnabled: manager.isHrControlStartAffordanceAvailable"))
        XCTAssertTrue(production.contains("let heartRate = manager.trainingUIHeartRateSnapshot"))
        XCTAssertTrue(production.contains("heartRateSourceLabel: heartRate.sourceLabel"))
        XCTAssertFalse(production.contains("watchReachable"))
        XCTAssertFalse(production.contains("telemetry"))

        for fixture in [
            "ready-unknown-source",
            "ready-known-source",
            "treadmill-unavailable",
            "hr-unavailable",
            "preparing",
            "intervals",
            "weekly-zones",
        ] {
            XCTAssertTrue(previewFixtures.contains("case \"\(fixture)\""), fixture)
        }
        XCTAssertTrue(previewFixtures.contains("modeTitle: \"Интервалы\""))
        XCTAssertTrue(previewFixtures.contains("modeTitle: \"Недельные зоны\""))
        XCTAssertTrue(previewFixtures.contains("startEnabled: false"))
        XCTAssertTrue(previewFixtures.contains("isPreview: true"))
        XCTAssertFalse(previewFixtures.contains("startHrControl"))
        XCTAssertFalse(previewFixtures.contains("sendTreadmill"))

        XCTAssertTrue(hubBody.contains("Label(\"Интервалы · Скоро\""))
        XCTAssertTrue(hubBody.contains(".disabled(true)"))
        XCTAssertTrue(hubBody.contains("guard !presentation.isPreview else { return }"))
        XCTAssertTrue(hubBody.contains("onStart()"))
        XCTAssertFalse(hubBody.contains("BluetoothManager"))
        XCTAssertFalse(hubBody.contains(".safeAreaInset"))
        assertOrdered(
            [
                "TrainingReadinessStrip(",
                "hero",
                "startArea",
                ".padding(.top, 6)",
            ],
            in: hubBody
        )

        let controlView = try functionBody(
            "private struct ControlSwipeView: View",
            in: contentViewSource
        )
        XCTAssertTrue(controlView.contains(".navigationTitle(\"Тренировка\")"))
        XCTAssertTrue(controlView.contains(".navigationBarTitleDisplayMode(.inline)"))
        XCTAssertTrue(
            controlView.contains(
                ".toolbar(usesCompactNavigationTitle ? .visible : .hidden, for: .navigationBar)"
            )
        )
        XCTAssertFalse(
            controlView.contains(
                ".navigationBarTitleDisplayMode(usesCompactNavigationTitle ? .inline : .large)"
            )
        )

        XCTAssertTrue(contentBody.contains("private var isTrainingPreviewLaunch: Bool"))
        XCTAssertTrue(contentBody.contains("--training-hub-preview="))
        XCTAssertTrue(contentBody.contains("--active-workout-preview="))
        XCTAssertTrue(contentBody.contains("--training-result-preview="))
        XCTAssertTrue(contentBody.contains("--training-ui-pressure-baseline"))
        XCTAssertTrue(contentViewSource.contains("managerPublishedEvents"))
        XCTAssertTrue(contentViewSource.contains("potentialAvoidableManagerDrivenInvalidations"))
        XCTAssertTrue(contentViewSource.contains("eventToVisibleChangeRatio"))
        XCTAssertTrue(contentViewSource.contains("rawManagerPublications"))
        XCTAssertFalse(contentViewSource.contains("publicationToVisibleChangeRatio"))
        XCTAssertEqual(
            contentBody.components(separatedBy: "guard !isTrainingPreviewLaunch else { return }").count - 1,
            2
        )
        assertOrdered(
            [
                "TrainingUIUpdatePressureHarness.run(manager: manager)",
                "guard !isTrainingPreviewLaunch else { return }",
                "manager.start()",
                "guard !isTrainingPreviewLaunch else { return }",
                "manager.pingWatch()",
            ],
            in: contentBody
        )
    }

    func testTrainingTreadmillUIPublicationCannotBecomeFactualTruth() throws {
        let activePresentation = try functionBody(
            "private func makeProductionActiveWorkoutPresentation(",
            in: contentViewSource
        )
        let cooldownSnapshot = try functionBody(
            "private func currentCooldownSpeedSnapshot()",
            in: managerSource
        )
        let telemetryPayload = try functionBody(
            "private func makeTrainingLogPayload(event: String, fields: [String: Any])",
            in: managerSource
        )
        let uiPublisher = try functionBody(
            "private func publishTrainingUITreadmillSpeedIfNeeded()",
            in: managerSource
        )

        XCTAssertTrue(activePresentation.contains("manager.trainingUITreadmillSpeedKmh"))
        XCTAssertFalse(activePresentation.contains("manager.deviceReportedAppSpeedKmh"))
        XCTAssertFalse(activePresentation.contains("manager.deviceReportedSpeedKmh"))

        for factualConsumer in [cooldownSnapshot, telemetryPayload] {
            XCTAssertTrue(factualConsumer.contains("deviceReportedAppSpeedKmh"))
            XCTAssertTrue(factualConsumer.contains("deviceReportedSpeedKmh"))
            XCTAssertFalse(factualConsumer.contains("trainingUITreadmillSpeedKmh"))
        }

        XCTAssertTrue(managerSource.contains("let treadmillFactualObservationPublisher"))
        XCTAssertTrue(managerSource.contains("publishTrainingUITreadmillSpeedIfNeeded()"))
        XCTAssertFalse(managerSource.contains("@Published var deviceReportedSpeedKmh"))
        XCTAssertFalse(managerSource.contains("@Published var deviceReportedAppSpeedKmh"))
        XCTAssertEqual(
            managerSource.components(
                separatedBy: "self.publishTrainingUITreadmillSpeedIfNeeded()"
            ).count - 1,
            4
        )
        XCTAssertTrue(uiPublisher.contains("treadmillFactualObservationPublisher.publish()"))
        XCTAssertTrue(uiPublisher.contains("trainingUITreadmillSpeedKmh ="))
        XCTAssertFalse(uiPublisher.contains("DispatchQueue"))
        XCTAssertFalse(uiPublisher.contains("Task"))
        XCTAssertFalse(uiPublisher.contains("debounce"))
        XCTAssertTrue(
            contentViewSource.contains(
                "@ObservedObject var publisher: TreadmillFactualObservationPublisher"
            )
        )
    }

    func testTrainingHeartRateUIPublicationCannotBecomeFactualTruth() throws {
        let activePresentation = try functionBody(
            "private func makeProductionActiveWorkoutPresentation(",
            in: contentViewSource
        )
        let controlDecision = try functionBody(
            "private func tickTelemetry()",
            in: managerSource
        )
        let telemetryPayload = try functionBody(
            "private func makeTrainingLogPayload(event: String, fields: [String: Any])",
            in: managerSource
        )
        let uiPublisher = try functionBody(
            "private func publishTrainingUIHeartRateIfNeeded()",
            in: managerSource
        )
        let nativeDelivery = try functionBody(
            "private func handleNativeHeartRateObservation(",
            in: managerSource
        )
        let staleTimer = try functionBody(
            "private func startHrStaleTimer()",
            in: managerSource
        )

        XCTAssertTrue(activePresentation.contains("manager.trainingUIHeartRateSnapshot"))
        XCTAssertFalse(activePresentation.contains("manager.heartRateBPM"))
        XCTAssertFalse(activePresentation.contains("manager.hrLastValueAt"))

        for factualConsumer in [controlDecision, telemetryPayload] {
            XCTAssertTrue(factualConsumer.contains("heartRateBPM"))
            XCTAssertFalse(factualConsumer.contains("trainingUIHeartRateSnapshot"))
        }
        XCTAssertTrue(telemetryPayload.contains("lastKnownHeartRateBPM"))

        XCTAssertTrue(managerSource.contains("let heartRateFactualState"))
        XCTAssertTrue(managerSource.contains("@Published fileprivate(set) var heartRateBPM"))
        XCTAssertTrue(managerSource.contains("var heartRateBPM: Int {"))
        XCTAssertTrue(managerSource.contains("var lastKnownHeartRateBPM: Int {"))
        XCTAssertFalse(managerSource.contains("@Published var hrLastValueAt"))
        XCTAssertEqual(
            contentViewSource.components(separatedBy: "manager.trainingUIHeartRateSnapshot")
                .count - 1,
            2
        )
        XCTAssertFalse(nativeDelivery.contains("trainingUIHeartRateSnapshot"))
        XCTAssertFalse(staleTimer.contains("trainingUIHeartRateSnapshot"))
        assertOrdered(
            [
                "HRDomainService.applyHeartRateDelivery(",
                "hrDataStaleSeconds = ageSeconds",
                "hrStreamingActive = HRDomainService.heartRateStreamIsActive(",
                "isNativeHeartRateCurrent = hrStreamingActive",
                "let normalization = normalizeHeartRateDelivery",
                "logTrainingEvent(\"hr_sample\"",
            ],
            in: nativeDelivery
        )
        XCTAssertTrue(uiPublisher.contains("guard nextSnapshot != trainingUIHeartRateSnapshot"))
        XCTAssertTrue(uiPublisher.contains("trainingUIHeartRateSnapshot = nextSnapshot"))
        XCTAssertFalse(uiPublisher.contains("DispatchQueue"))
        XCTAssertFalse(uiPublisher.contains("Task"))
        XCTAssertFalse(uiPublisher.contains("debounce"))
        XCTAssertTrue(
            contentViewSource.contains(
                "@ObservedObject var state: HeartRateFactualState"
            )
        )
        XCTAssertEqual(
            contentViewSource.components(
                separatedBy: "TrainingUIHeartRateReadinessPresentationPolicy.presentation("
            ).count - 1,
            1
        )
        XCTAssertFalse(
            managerSource.contains("TrainingUIHeartRateReadinessPresentationPolicy")
        )
        XCTAssertFalse(
            source(
                relativePath: "WalkingPadRemote/NativeHeartRatePreflightEngine.swift"
            ).contains("TrainingUIHeartRateReadinessPresentationPolicy")
        )
    }

    func testTrainingHubDurationPresetsAreDirectTruthfulAndCooldownFree() throws {
        let mapping = try functionBody(
            "private func makeHRControlTrainingHubPresentation(",
            in: contentViewSource
        )
        let selector = try functionBody(
            "private struct TrainingDurationPresetSelector: View",
            in: contentViewSource
        )
        let controlView = try functionBody(
            "private struct ControlSwipeView: View",
            in: contentViewSource
        )
        let previewFixtures = try functionBody(
            "private func trainingHubPreviewPresentation(named name: String)",
            in: contentViewSource
        )

        XCTAssertTrue(contentViewSource.contains(
            "private let trainingDurationPresets = [20, 25, 30, 35, 40, 45]"
        ))
        XCTAssertTrue(mapping.contains("durationMinutes: durationMinutes"))
        XCTAssertTrue(mapping.contains("metrics: []"))
        XCTAssertFalse(mapping.contains("cooldownTargetBPM"))
        XCTAssertFalse(mapping.contains("title: \"Заминка\""))

        XCTAssertTrue(selector.contains("trainingDurationPresets.contains(selectedMinutes)"))
        XCTAssertTrue(selector.contains("if !hasPresetSelection"))
        XCTAssertTrue(selector.contains("Text(\"Текущее: \\(selectedMinutes) мин\")"))
        XCTAssertTrue(selector.contains("guard interactive else { return }"))
        XCTAssertTrue(selector.contains("onSelect(minutes)"))
        XCTAssertFalse(selector.contains("onAppear"))
        XCTAssertFalse(selector.contains("@State"))
        XCTAssertFalse(selector.contains("@Binding"))

        XCTAssertTrue(controlView.contains(
            "onDurationSelect: { manager.hrDurationMinutes = $0 }"
        ))
        XCTAssertFalse(controlView.contains("showDurationSheet"))
        XCTAssertFalse(contentViewSource.contains("HRDurationWheelSheet"))

        for fixture in [
            "duration-20",
            "duration-30",
            "duration-45",
            "duration-legacy-10",
            "duration-legacy-60",
        ] {
            XCTAssertTrue(previewFixtures.contains("case \"\(fixture)\""), fixture)
        }
    }

    func testActiveWorkoutShellIsObservationalSparseAndTransportFree() throws {
        let mapping = try functionBody(
            "private func makeHRControlActivePresentation(",
            in: contentViewSource
        )
        let shell = try functionBody(
            "private struct ActiveWorkoutShell: View",
            in: contentViewSource
        )
        let scale = try functionBody(
            "private struct TrainingZoneScale: View",
            in: contentViewSource
        )
        let controlView = try functionBody(
            "private struct ControlSwipeView: View",
            in: contentViewSource
        )
        let production = try functionBody(
            "private func makeProductionActiveWorkoutPresentation(",
            in: contentViewSource
        )
        let fixtures = try functionBody(
            "private func activeWorkoutPreviewPresentation(named name: String)",
            in: contentViewSource
        )

        XCTAssertTrue(mapping.contains("currentHeartRateBPM"))
        XCTAssertTrue(mapping.contains("factualHeartRate < selectedRange.lowerBound"))
        XCTAssertTrue(mapping.contains("factualHeartRate > selectedRange.upperBound"))
        XCTAssertTrue(mapping.contains("selectedRange.lowerBound)–\\(selectedRange.upperBound) bpm"))
        XCTAssertTrue(mapping.contains("≤ \\(cooldownTargetBPM) bpm"))
        XCTAssertTrue(mapping.contains("title: \"Скорость\""))
        XCTAssertTrue(mapping.contains("title: \"Прошло\""))
        XCTAssertTrue(mapping.contains("factualSpeedKmh.map"))
        XCTAssertTrue(mapping.contains("?? \"—\""))
        for forbidden in [
            "hrTargetBPM", "deadband", "predictor", "hrDecision", "Telemetry",
            "watchReachable", "Apple Watch", "steps", "average", "beatsPerMeter",
        ] {
            XCTAssertFalse(mapping.contains(forbidden), "Active mapping contains \(forbidden)")
        }

        XCTAssertTrue(shell.contains("presentation.primaryValue"))
        XCTAssertTrue(shell.contains("TrainingZoneScale("))
        XCTAssertTrue(shell.contains("presentation.statusTitle"))
        XCTAssertTrue(shell.contains("Button(\"+5 мин\")"))
        XCTAssertTrue(shell.contains(".controlSize(.large)"))
        XCTAssertTrue(shell.contains(".frame(height: 48)"))
        XCTAssertTrue(shell.contains("Label(\"Стоп\""))
        XCTAssertTrue(shell.contains("guard !presentation.isPreview else { return }"))
        XCTAssertFalse(shell.contains("BluetoothManager"))
        for removedFocusDetail in [
            "Решение алгоритма", "След. решение", "Прогноз", "Удары/м",
            "Средн. пульс", "Средняя скорость", "Шаги", "arrow.up.arrow.down",
        ] {
            XCTAssertFalse(shell.contains(removedFocusDetail), removedFocusDetail)
        }

        XCTAssertTrue(scale.contains("liveMarkerBPM"))
        XCTAssertTrue(scale.contains("targetThresholdBPM"))
        XCTAssertTrue(scale.contains("accessibilityReduceMotion"))
        XCTAssertFalse(scale.contains("BluetoothManager"))
        XCTAssertFalse(scale.contains("manager."))
        XCTAssertFalse(scale.contains("sendTreadmill"))

        XCTAssertTrue(controlView.contains("makeProductionActiveWorkoutPresentation("))
        XCTAssertTrue(production.contains("makeHRControlActivePresentation("))
        assertOrdered(
            [
                "guard manager.isConnected else { return nil }",
                "return manager.trainingUITreadmillSpeedKmh",
                "factualSpeedKmh: factualSpeedKmh",
            ],
            in: production
        )
        for forbiddenSpeedFallback in [
            "HRDomainService.cooldownSpeedSnapshot(",
            "currentActualSpeedKmh:",
            "manager.speedKmh",
            "manager.desiredSpeedKmh",
            "manager.deviceTargetSpeedKmh",
        ] {
            XCTAssertFalse(
                production.contains(forbiddenSpeedFallback),
                "Active presentation contains \(forbiddenSpeedFallback)"
            )
        }
        XCTAssertTrue(controlView.contains("onExtend: { manager.extendHrSession(minutes: 5) }"))
        XCTAssertTrue(controlView.contains("onStop: { manager.stopHrControl() }"))
        XCTAssertFalse(controlView.contains("CommonInfoCard()"))
        XCTAssertFalse(controlView.contains("HRControlPanel"))
        XCTAssertFalse(controlView.contains("applewatch"))

        for fixture in [
            "active-below", "active-in-zone", "active-above", "active-known-source",
            "active-no-hr", "active-no-speed", "active-disconnected",
            "cooldown-above", "cooldown-reached", "active-intervals", "active-weekly-zones",
        ] {
            XCTAssertTrue(fixtures.contains("case \"\(fixture)\""), fixture)
        }
        XCTAssertTrue(
            fixtures.contains(
                "case \"active-no-speed\":\n" +
                "        return hrControl(true, true, 152, nil, nil, false, 115)"
            )
        )
        XCTAssertFalse(fixtures.contains("startHrControl"))
        XCTAssertFalse(fixtures.contains("stopHrControl"))
        XCTAssertFalse(fixtures.contains("sendTreadmill"))
    }

    func testWorkoutResultFlowUsesExactNativeProjectionAndFactualPresentationData() throws {
        let ending = try functionBody(
            "private struct TrainingWorkoutEndingView: View",
            in: contentViewSource
        )
        let summary = try functionBody(
            "private struct TrainingWorkoutSummaryView: View",
            in: contentViewSource
        )
        let unavailable = try functionBody(
            "private struct TrainingWorkoutUnavailableView: View",
            in: contentViewSource
        )
        let fixtures = try functionBody(
            "private func trainingResultPreview(named name: String)",
            in: contentViewSource
        )
        let controlView = try functionBody(
            "private struct ControlSwipeView: View",
            in: contentViewSource
        )
        let distanceReading = try functionBody(
            "private func currentFactualDistanceReading()",
            in: contentViewSource
        )
        let distanceDelta = try functionBody(
            "private func factualSessionDistanceKilometres(",
            in: contentViewSource
        )
        let begin = try functionBody(
            "private func beginTrainingPresentationSession()",
            in: contentViewSource
        )
        let finish = try functionBody(
            "private func finishTrainingPresentationSession()",
            in: contentViewSource
        )
        let resolve = try functionBody(
            "private func resolveTrainingResultIfPossible()",
            in: contentViewSource
        )

        XCTAssertTrue(ending.contains("Text(\"Завершаем тренировку…\")"))
        XCTAssertTrue(ending.contains("trainingEndingStatus(from: stopStatusText)"))
        for fabricatedEndingDetail in [
            "Подготавливаем итог", "Сохраняем", "ProgressView", "Timer", "asyncAfter",
        ] {
            XCTAssertFalse(ending.contains(fabricatedEndingDetail), fabricatedEndingDetail)
        }

        XCTAssertTrue(summary.contains("result.distanceKilometres"))
        XCTAssertTrue(summary.contains("result.projection.durationSeconds"))
        XCTAssertTrue(summary.contains("result.projection.averageHeartRate"))
        XCTAssertTrue(summary.contains("speed.evidenceKind == .factual"))
        XCTAssertTrue(summary.contains("result.projection.zoneSeconds"))
        XCTAssertTrue(summary.contains("values.count == 5"))
        XCTAssertTrue(summary.contains("formattedWorkoutResultDuration"))
        XCTAssertTrue(summary.contains("Button(\"Готово\", action: onDone)"))
        XCTAssertTrue(summary.contains("Button(\"Открыть статистику\", action: onOpenStatistics)"))
        XCTAssertTrue(summary.contains("accessibilityLabel(\"Зона "))
        XCTAssertFalse(summary.contains("lowerBound"))
        XCTAssertFalse(summary.contains("upperBound"))
        XCTAssertFalse(summary.contains("BluetoothManager"))
        XCTAssertFalse(summary.contains("distKm"))
        XCTAssertFalse(unavailable.contains("projection."))
        XCTAssertFalse(unavailable.contains("distanceKilometres"))

        for fixture in [
            "ending-confirming", "ending-confirmed", "summary-complete",
            "summary-duration-fallback", "summary-partial", "summary-unavailable",
        ] {
            XCTAssertTrue(fixtures.contains("case \"\(fixture)\""), fixture)
        }

        assertOrdered(
            [
                "manager.isConnected",
                "manager.connectedPeripheralId",
                "manager.controllerUnitsTruth.connectionEpoch",
                "manager.controllerUnitsTruth.status == .valid",
                "manager.controllerUnitsTruth.units == .metric",
                "manager.deviceReportedChecksumOk",
                "!manager.deviceReportedRawHex.isEmpty",
                "manager.deviceReportedDistance10m >= 0",
                "StopObservationPolicy.freshnessInterval",
                "counter10m: manager.deviceReportedDistance10m",
            ],
            in: distanceReading
        )
        XCTAssertTrue(distanceDelta.contains("start.peripheralID == end.peripheralID"))
        XCTAssertTrue(distanceDelta.contains("start.connectionEpoch == end.connectionEpoch"))
        XCTAssertTrue(distanceDelta.contains("end.counter10m >= start.counter10m"))
        XCTAssertTrue(distanceDelta.contains("* 10.0 / 1_000.0"))
        XCTAssertFalse(distanceDelta.contains("speed"))
        XCTAssertFalse(distanceDelta.contains("distKm"))

        XCTAssertTrue(begin.contains("manager.telemetryV2WorkoutHistoryState == .loaded"))
        XCTAssertTrue(begin.contains(".filter { $0.origin == .nativeV2 }"))
        XCTAssertTrue(begin.contains(".map(\\.id)"))
        XCTAssertTrue(finish.contains("projectionGenerationAtEnd: manager.telemetryV2ProjectionGeneration"))
        XCTAssertTrue(resolve.contains("manager.telemetryV2ProjectionGeneration"))
        XCTAssertTrue(resolve.contains("> pendingTrainingResult.projectionGenerationAtEnd"))
        XCTAssertTrue(resolve.contains("$0.origin == .nativeV2 && !baselineIDs.contains($0.id)"))
        XCTAssertTrue(resolve.contains("candidates.count == 1"))
        XCTAssertFalse(resolve.contains("sorted"))
        XCTAssertFalse(resolve.contains("last"))
        XCTAssertFalse(resolve.contains("first(where"))

        XCTAssertTrue(controlView.contains("onDone: clearTrainingResultPresentation"))
        XCTAssertTrue(controlView.contains("onOpenStatistics: openStatistics"))
        XCTAssertTrue(controlView.contains("onOpenStatistics()"))
        XCTAssertTrue(controlView.contains("reduceMotion ? nil"))
        for forbiddenRuntimeMutation in [
            "manager.distKm", "manager.workoutHistory =", "manager.telemetryV2WorkoutHistory =",
            "sendTreadmill", "startTrainingStructuredLog", "endTelemetryV2Session",
        ] {
            XCTAssertFalse(controlView.contains(forbiddenRuntimeMutation), forbiddenRuntimeMutation)
        }
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
                "stopLegacyWatchHeartRateIfNeeded()",
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
                "stopLegacyWatchHeartRateIfNeeded()",
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
        let commit = try functionBody(
            "private func commitExistingHrControl(preflightLatencySeconds: TimeInterval)",
            in: managerSource
        )
        let stop = try functionBody("func stopHrControl()", in: managerSource)
        let begin = try functionBody(
            "private func beginTelemetryV2Session(legacySessionID: UUID?)",
            in: managerSource
        )
        let end = try functionBody(
            "private func endTelemetryV2Session(reason: String)",
            in: managerSource
        )

        for productPath in [start, commit, stop] {
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
            in: commit
        )
        assertOrdered(
            [
                "stopTrainingStructuredLog(reason: \"manual_stop\")",
                "isHrControlRunning = false",
                "stopBeltWithToggle(reason: \"hr\")",
                "stopLegacyWatchHeartRateIfNeeded()",
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
