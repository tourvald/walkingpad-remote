import XCTest

final class TestRunHeartRateDiagnosticIntegrationContractTests: XCTestCase {
    private lazy var packageDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    private lazy var managerSource = try! source("WalkingPadRemote/BluetoothManager.swift")
    private lazy var diagnosticSource = try! source(
        "WalkingPadRemote/TestRunHeartRateDiagnosticService.swift"
    )

    func testTreadmillStartRemainsIndependentAndRunsBeforeDiagnosticProbe() throws {
        let start = try functionBody("func startTreadmillTestRun()", in: managerSource)

        assertOrdered([
            "treadmillTestRunService.start(",
            "executeTreadmillTestRunActions(transition.actions)",
            "startTreadmillTestRunHeartRateDiagnostic(runID: runID)",
        ], in: start)
        XCTAssertFalse(start.contains("guard startTreadmillTestRunHeartRateDiagnostic"))
        XCTAssertFalse(start.contains("await"))
    }

    func testDiagnosticReusesProductionProviderAndQualificationBoundaries() throws {
        let start = try functionBody(
            "private func startTreadmillTestRunHeartRateDiagnostic(runID: UUID)",
            in: managerSource
        )
        let receive = try functionBody(
            "private func handleTreadmillTestRunHeartRateObservation(",
            in: managerSource
        )

        XCTAssertTrue(start.contains("IPhoneHealthKitLiveHeartRateProvider(healthStore: healthStore)"))
        XCTAssertTrue(start.contains("HKWorkoutConfiguration()"))
        XCTAssertTrue(start.contains("provider.prepare("))
        XCTAssertTrue(start.contains("provider.start(at: collectionStartedAt)"))
        XCTAssertTrue(receive.contains("NativeHeartRatePreflightEngine.Observation("))
        XCTAssertTrue(diagnosticSource.contains("observation.isQualifying("))
        XCTAssertTrue(diagnosticSource.contains("HRDomainService.heartRateStreamIsActive("))
        for forbidden in [
            "heartRateBPM =",
            "hrStreamingActive =",
            "isNativeHeartRateCurrent =",
            "publishHeartRateNormalization",
            "recordHrSample",
        ] {
            XCTAssertFalse(receive.contains(forbidden))
        }
    }

    func testDiagnosticCannotTakeProductionOwnershipOrPersistWorkout() throws {
        let start = try functionBody(
            "private func startTreadmillTestRunHeartRateDiagnostic(runID: UUID)",
            in: managerSource
        )
        let finish = try functionBody(
            "private func finishTreadmillTestRunHeartRateDiagnostic(",
            in: managerSource
        )
        let discard = try functionBody(
            "private func discardTreadmillTestRunHeartRateProvider(expectedRunID: UUID)",
            in: managerSource
        )

        XCTAssertTrue(start.contains("iPhoneHealthKitHeartRateProvider.state == .idle"))
        XCTAssertTrue(start.contains("!nativeHeartRatePreflightEngine.ownsUncommittedWorkout"))
        XCTAssertTrue(start.contains("!hasOutstandingNativeWorkoutRecovery"))
        XCTAssertTrue(start.contains("!nativeHealthKitWorkoutCommitted"))
        XCTAssertTrue(start.contains("!nativeHealthKitWorkoutFinishInFlight"))
        XCTAssertTrue(discard.contains("provider.discard(at: Date())"))
        for body in [start, finish, discard] {
            XCTAssertFalse(body.contains("provider.finish("))
            XCTAssertFalse(body.contains("persistNativeWorkoutRecoveryRecord"))
            XCTAssertFalse(body.contains("beginTelemetryV2Session"))
            XCTAssertFalse(body.contains("startWithSpeed"))
            XCTAssertFalse(body.contains("setTargetSpeed"))
            XCTAssertFalse(body.contains("manualStop"))
        }
    }

    func testProductionWarmPreparationYieldsToActiveDiagnosticSlot() throws {
        let warm = try functionBody(
            "private func warmNativeHeartRateProviderIfPossible()",
            in: managerSource
        )

        XCTAssertEqual(
            warm.components(separatedBy: "treadmillTestRunHeartRateProvider == nil").count - 1,
            2
        )
        XCTAssertEqual(
            warm.components(separatedBy: "!treadmillTestRunHeartRateCleanupInFlight").count - 1,
            2
        )
        XCTAssertEqual(
            warm.components(separatedBy: "!treadmillTestRunIsActive").count - 1,
            2
        )
    }

    func testAllTreadmillTerminalPathsDiscardDiagnosticProvider() throws {
        let advance = try functionBody(
            "private func advanceTreadmillTestRun(expectedRunID: UUID)",
            in: managerSource
        )
        let cancel = try functionBody(
            "private func cancelTreadmillTestRun(",
            in: managerSource
        )
        let timeout = try functionBody(
            "private func tickTreadmillTestRunHeartRateDiagnostic(expectedRunID: UUID)",
            in: managerSource
        )
        let failure = try functionBody(
            "private func treadmillTestRunHeartRateProviderFailed(",
            in: managerSource
        )

        XCTAssertTrue(advance.contains("reason: .testRunCompleted"))
        XCTAssertTrue(cancel.contains("treadmillTestRunHeartRateTerminalReason(for: reason)"))
        XCTAssertTrue(timeout.contains("timeoutIfNeeded("))
        XCTAssertTrue(timeout.contains("discardTreadmillTestRunHeartRateProvider"))
        XCTAssertTrue(failure.contains("reason: .providerFailure"))
        XCTAssertTrue(managerSource.contains("case .appInactive: return .appInactive"))
        XCTAssertTrue(managerSource.contains("case .connectionInvalidated: return .connectionInvalidated"))
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: packageDirectory.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func functionBody(_ signature: String, in source: String) throws -> String {
        guard let signatureRange = source.range(of: signature),
              let openingBrace = source[signatureRange.upperBound...].firstIndex(of: "{") else {
            throw NSError(domain: "TestRunHeartRateDiagnosticIntegrationContractTests", code: 1)
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
        throw NSError(domain: "TestRunHeartRateDiagnosticIntegrationContractTests", code: 2)
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
