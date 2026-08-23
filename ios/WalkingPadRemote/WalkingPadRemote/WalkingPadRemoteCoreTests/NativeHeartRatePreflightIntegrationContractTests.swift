import XCTest

final class NativeHeartRatePreflightIntegrationContractTests: XCTestCase {
    private lazy var packageDirectory: URL = {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return testsDirectory.deletingLastPathComponent()
    }()
    private lazy var managerSource: String = {
        try! String(
            contentsOf: packageDirectory.appendingPathComponent(
                "WalkingPadRemote/BluetoothManager.swift"
            ),
            encoding: .utf8
        )
    }()
    private lazy var contentSource: String = {
        try! String(
            contentsOf: packageDirectory.appendingPathComponent(
                "WalkingPadRemote/ContentView.swift"
            ),
            encoding: .utf8
        )
    }()
    private lazy var providerSource: String = {
        try! String(
            contentsOf: packageDirectory.appendingPathComponent(
                "WalkingPadRemote/IPhoneHealthKitLiveHeartRateProvider.swift"
            ),
            encoding: .utf8
        )
    }()

    func testStartAndCollectionPreflightContainNoProductionMotionTimingOrV2() throws {
        let start = try functionBody("func startHrControl()", in: managerSource)
        let collection = try functionBody(
            "private func startNativeHeartRateCollection(",
            in: managerSource
        )
        for body in [start, collection] {
            XCTAssertFalse(body.contains("isHrControlRunning = true"))
            XCTAssertFalse(body.contains("beginTelemetryV2Session"))
            XCTAssertFalse(body.contains("startWithSpeed"))
            XCTAssertFalse(body.contains("sendTreadmill"))
            XCTAssertFalse(body.contains("hrRemainingSeconds"))
        }
        XCTAssertTrue(start.contains("nativeHeartRatePreflightEngine.requestStart"))
        XCTAssertTrue(collection.contains("iPhoneHealthKitHeartRateProvider.start"))
    }

    func testCommitIsTheSingleProductionStartBoundaryWithFrozenIntent() throws {
        let commit = try functionBody(
            "private func commitNativeHeartRatePreflight(",
            in: managerSource
        )
        let productionStart = try functionBody(
            "private func commitExistingHrControl(preflightLatencySeconds: TimeInterval)",
            in: managerSource
        )

        assertOrdered([
            "observation.isQualifying(",
            "RuntimePolicy.permitsProductionCommit(",
            "hrTargetBPM = intent.targetBPM",
            "hrDurationMinutes = intent.durationMinutes",
            "nativeHealthKitWorkoutCommitted = true",
            "commitExistingHrControl(preflightLatencySeconds: latency)",
        ], in: commit)
        assertOrdered([
            "controllerUnitsGateDecision()",
            "isHrControlRunning = true",
            "beginTelemetryV2Session(legacySessionID: legacySessionID)",
            "startWithSpeed",
        ], in: productionStart)
        XCTAssertEqual(productionStart.components(separatedBy: "isHrControlRunning = true").count - 1, 1)
    }

    func testRuntimeSafetyFixesUseBehavioralPoliciesAtProductionBoundaries() throws {
        let safety = try functionBody(
            "private func nativeHeartRateSafetyFacts(",
            in: managerSource
        )
        let warm = try functionBody(
            "private func warmNativeHeartRateProviderIfPossible()",
            in: managerSource
        )
        let collection = try functionBody(
            "private func startNativeHeartRateCollection(",
            in: managerSource
        )
        XCTAssertTrue(safety.contains("RuntimePolicy.stopInProgress("))
        XCTAssertTrue(safety.contains("RuntimePolicy\n                .hasConflictingWorkout("))
        XCTAssertTrue(warm.contains("RuntimePolicy.canWarmPrepare("))
        XCTAssertTrue(warm.contains("providerIsIdle: iPhoneHealthKitHeartRateProvider.state == .idle"))
        XCTAssertTrue(collection.contains("collectionStarted("))
        XCTAssertTrue(collection.contains("now: Date()"))
    }

    func testProviderAsyncWorkIsGenerationBoundAndRetryWaitsForCleanup() throws {
        let start = try functionBody("func startHrControl()", in: managerSource)
        let prepare = try functionBody(
            "private func prepareNativeHeartRateProvider()",
            in: managerSource
        )
        let collection = try functionBody(
            "private func startNativeHeartRateCollection(",
            in: managerSource
        )
        let discard = try functionBody(
            "private func discardNativeHeartRatePreflight(",
            in: managerSource
        )
        let delivery = try functionBody(
            "private func handleNativeHeartRateObservation(",
            in: managerSource
        )

        XCTAssertTrue(start.contains("!nativeHeartRateProviderLifecycle.cleanupInFlight"))
        XCTAssertTrue(start.contains("bindAttempt(intent.id)"))
        XCTAssertTrue(prepare.contains("beginProviderLifecycle()"))
        XCTAssertTrue(prepare.contains("acceptsProviderCompletion("))
        XCTAssertTrue(collection.contains("attemptID: intent.id"))
        assertOrdered([
            "beginCleanup()",
            "iPhoneHealthKitHeartRateProvider.discard",
            "completeCleanup(",
            "recomputeHrStartAllowed()",
        ], in: discard)
        assertOrdered([
            "acceptsObservation(",
            "HRDomainService.applyHeartRateDelivery(",
        ], in: delivery)
    }

    func testExactQualifyingNormalizationIsEnqueuedBeforeMotionAndThenReferenced() throws {
        let delivery = try functionBody(
            "private func handleNativeHeartRateObservation(",
            in: managerSource
        )
        let productionStart = try functionBody(
            "private func commitExistingHrControl(preflightLatencySeconds: TimeInterval)",
            in: managerSource
        )
        let persist = try functionBody(
            "private func persistQualifyingNativeHeartRateBeforeMotion()",
            in: managerSource
        )

        XCTAssertTrue(delivery.contains("let normalization = normalizeHeartRateDelivery("))
        XCTAssertTrue(delivery.contains("pendingNativePreflightHeartRate = normalization"))
        assertOrdered([
            "beginTelemetryV2Session(legacySessionID: legacySessionID)",
            "persistQualifyingNativeHeartRateBeforeMotion()",
            "startWithSpeed",
        ], in: productionStart)
        assertOrdered([
            "let result = pendingNativePreflightHeartRate",
            "heartRateTelemetrySink?.observeHeartRate(result)",
            "latestHeartRateDelivery = result.delivery",
            "inputs: [result.delivery.causalReference]",
        ], in: persist)
        XCTAssertFalse(persist.contains("heartRateObservationNormalizer.normalize"))
    }

    func testNativeHeartRateMarksFreshImmediatelyAndLegacyWatchCannotRace() throws {
        let nativeDelivery = try functionBody(
            "private func handleNativeHeartRateObservation(",
            in: managerSource
        )
        let watchPayload = try functionBody(
            "private func handleWatchPayload(_ payload: [String: Any])",
            in: managerSource
        )

        assertOrdered([
            "hrStreamingActive = HRDomainService.heartRateStreamIsActive(",
            "isNativeHeartRateCurrent = hrStreamingActive",
            "nativeHeartRatePreflightEngine.receive(",
        ], in: nativeDelivery)
        XCTAssertTrue(watchPayload.contains("guard !self.nativeHeartRateFlowOwnsController"))
        XCTAssertTrue(watchPayload.contains("Ignored legacy Watch HR"))
        XCTAssertTrue(watchPayload.contains("Ignored legacy Watch workout UUID"))
    }

    func testLifecycleAndCancellationStayPrecommitOnly() throws {
        let discard = try functionBody(
            "private func discardNativeHeartRatePreflight(",
            in: managerSource
        )
        XCTAssertTrue(managerSource.contains("nativeHeartRatePreflightEngine.cancel(reason: .user)"))
        XCTAssertTrue(managerSource.contains("nativeHeartRateAppActivity = .inactive"))
        XCTAssertTrue(managerSource.contains("nativeHeartRateAppActivity = .background"))
        XCTAssertTrue(managerSource.contains("nativeHeartRatePreflightEngine.tick(now: Date())"))
        XCTAssertTrue(discard.contains("iPhoneHealthKitHeartRateProvider.discard"))
        XCTAssertFalse(discard.contains("stopBelt"))
        XCTAssertFalse(discard.contains("sendTreadmill"))
        XCTAssertTrue(discard.contains("Пульс не получен"))
        XCTAssertFalse(discard.contains("Нет разрешения на пульс"))
    }

    func testFirstAuthorizationAutomaticallyContinuesAndWarmPrepareDoesNotPromptOrPoll() throws {
        let warm = try functionBody(
            "private func warmNativeHeartRateProviderIfPossible()",
            in: managerSource
        )
        let prepare = try functionBody(
            "private func prepareNativeHeartRateProvider()",
            in: managerSource
        )
        XCTAssertTrue(warm.contains("canPrepareWithoutAuthorizationPrompt"))
        XCTAssertTrue(warm.contains("requestWarmPreparation()"))
        XCTAssertTrue(prepare.contains("providerPrepared(at: Date())"))
        XCTAssertTrue(providerSource.contains("statusForAuthorizationRequest"))
        XCTAssertTrue(providerSource.contains("status == .unnecessary"))
        XCTAssertFalse(managerSource.contains("Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in\n            self?.warmNativeHeartRateProviderIfPossible"))
    }

    func testFinishUsesDirectUUIDAndPersistsUnavailableDeferredLinkageWithoutRetry() throws {
        let finish = try functionBody(
            "private func finishNativeHealthKitWorkoutIfNeeded()",
            in: managerSource
        )
        let resolver = try functionBody(
            "private func resolveDeferredNativeHealthKitLinkageIfPossible()",
            in: managerSource
        )
        XCTAssertTrue(finish.contains("iPhoneHealthKitHeartRateProvider.finish"))
        XCTAssertTrue(finish.contains("case .saved(let workout)"))
        XCTAssertTrue(finish.contains("linkNativeHealthKitWorkout"))
        XCTAssertTrue(finish.contains("case .savedWorkoutUnavailable"))
        XCTAssertTrue(finish.contains("retainDeferredNativeHealthKitLinkage"))
        XCTAssertTrue(resolver.contains("HKSampleQuery"))
        XCTAssertTrue(resolver.contains("linkNativeHealthKitWorkout"))
        XCTAssertFalse(resolver.contains(".finish("))
        XCTAssertTrue(managerSource.contains("deferred_native_healthkit_linkage_v1"))
    }

    func testTelemetryIdentityIsNativeAndCannotGateMotion() throws {
        let descriptor = try functionBody(
            "private func beginTelemetryV2Session(legacySessionID: UUID?)",
            in: managerSource
        )
        let safety = try functionBody(
            "private func nativeHeartRateSafetyFacts(",
            in: managerSource
        )
        let commit = try functionBody(
            "private func commitExistingHrControl(preflightLatencySeconds: TimeInterval)",
            in: managerSource
        )
        XCTAssertTrue(descriptor.contains("heartRateProviderKind: \"healthKitSelected\""))
        XCTAssertTrue(descriptor.contains("heartRateProviderStableLocalKey: \"iphone-healthkit-selected\""))
        XCTAssertFalse(safety.contains("telemetryV2"))
        XCTAssertFalse(commit.contains("telemetryV2Status"))
        XCTAssertFalse(commit.contains("telemetryV2WriterHealthSnapshot"))
    }

    func testPreflightUIUsesBindingIndeterminateCopyAndCancel() {
        XCTAssertTrue(contentSource.contains("Получаем пульс…"))
        XCTAssertTrue(contentSource.contains("Дорожка запустится автоматически, когда появится пульс."))
        XCTAssertTrue(contentSource.contains("Button(\"Отмена\", role: .cancel, action: onCancel)"))
        XCTAssertTrue(contentSource.contains("manager.cancelNativeHeartRatePreflight()"))
        XCTAssertFalse(contentSource.contains("30 секунд до старта"))
    }

    private func functionBody(_ signature: String, in source: String) throws -> String {
        guard let signatureRange = source.range(of: signature),
              let openingBrace = source[signatureRange.upperBound...].firstIndex(of: "{") else {
            throw NSError(domain: "NativeHeartRatePreflightIntegrationContractTests", code: 1)
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
        throw NSError(domain: "NativeHeartRatePreflightIntegrationContractTests", code: 2)
    }

    private func assertOrdered(
        _ fragments: [String],
        in text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var cursor = text.startIndex
        for fragment in fragments {
            guard let range = text[cursor...].range(of: fragment) else {
                XCTFail("Missing or out-of-order fragment: \(fragment)", file: file, line: line)
                return
            }
            cursor = range.upperBound
        }
    }
}
