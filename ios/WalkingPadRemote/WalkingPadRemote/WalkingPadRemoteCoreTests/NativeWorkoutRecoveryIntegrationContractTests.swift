import Foundation
import XCTest

final class NativeWorkoutRecoveryIntegrationContractTests: XCTestCase {
    func testSceneFlagRequestsExactlyOneAppleRecoveryCall() throws {
        let app = try source("WalkingPadRemote/WalkingPadRemoteApp.swift")

        XCTAssertTrue(app.contains("options.shouldHandleActiveWorkoutRecovery"))
        XCTAssertEqual(app.components(separatedBy: "recoverActiveWorkoutSession").count - 1, 1)
        XCTAssertTrue(app.contains("ActiveWorkoutRecoveryRequestGate"))
        assertOrdered([
            "deliverRecoveryRequest()",
            "healthStore.recoverActiveWorkoutSession",
        ], in: app)
        XCTAssertTrue(app.contains("handleActiveWorkoutRecoveryRequest()"))
        XCTAssertTrue(app.contains("handleActiveWorkoutRecovery(session: session, error: error)"))
    }

    func testMissingAppleRecoveryFlagClearsPreflightButRetainsFinishUntilSavedProof() throws {
        let app = try source("WalkingPadRemote/WalkingPadRemoteApp.swift")
        let manager = try source("WalkingPadRemote/BluetoothManager.swift")
        let configuration = try functionBody(
            "func application(",
            in: app
        )
        let reconcile = try functionBody(
            "private func processNoActiveWorkoutRecoveryIfPossible()",
            in: manager
        )

        assertOrdered([
            "deliverRecoveryAvailability(options.shouldHandleActiveWorkoutRecovery)",
            "deliverRecoveryRequest()",
            "healthStore.recoverActiveWorkoutSession",
        ], in: configuration)
        XCTAssertTrue(app.contains("handleActiveWorkoutRecoveryAvailability("))
        XCTAssertTrue(reconcile.contains("!nativeHealthKitWorkoutCommitted"))
        XCTAssertTrue(reconcile.contains("!nativeHeartRateFlowOwnsController"))
        XCTAssertTrue(reconcile.contains("!nativeHealthKitWorkoutFinishInFlight"))
        XCTAssertTrue(reconcile.contains("resolveWithoutActiveRecoveryRequest"))
        XCTAssertTrue(reconcile.contains("case .discardPreflight"))
        XCTAssertTrue(reconcile.contains("case .reconcileFinished(let record)"))
        XCTAssertTrue(reconcile.contains("healthKitStopActivityAt"))
        let finishedBranch = try XCTUnwrap(
            reconcile.components(
                separatedBy: "case .reconcileFinished(let record):"
            ).last
        )
        XCTAssertTrue(finishedBranch.contains("retainDeferredNativeHealthKitLinkage("))
        XCTAssertTrue(finishedBranch.contains("resolveDeferredNativeHealthKitLinkageIfPossible()"))
        XCTAssertFalse(finishedBranch.contains("clearNativeWorkoutRecoveryRecord()"))
        for token in ["stopBelt", "sendTreadmill", "writeCommand", "enqueue"] {
            XCTAssertFalse(reconcile.contains(token), token)
        }

        let idle = try functionBody(
            "private func completeNativeWorkoutRecoveryToIdle()",
            in: manager
        )
        XCTAssertTrue(idle.contains("isNativeHeartRatePreflightActive = false"))
        XCTAssertTrue(idle.contains("recomputeHrStartAllowed()"))
    }

    func testRecoveredProviderReusesAssociatedBuilderAndOnlyRecreatesDataSource() throws {
        let provider = try source(
            "WalkingPadRemote/IPhoneHealthKitLiveHeartRateProvider.swift"
        )
        let recovery = try functionBody("func recoverWorkout(", in: provider)

        XCTAssertTrue(recovery.contains("recoveredSession.associatedWorkoutBuilder()"))
        XCTAssertTrue(recovery.contains("configureDataSource("))
        XCTAssertTrue(recovery.contains("recoveredSession.delegate = self"))
        XCTAssertTrue(recovery.contains("builder.delegate = self"))
        XCTAssertFalse(recovery.contains("HKWorkoutSession("))
        XCTAssertFalse(recovery.contains("createWorkout"))
    }

    func testPreflightMarkerPrecedesCollectionAndCommitMarkerPrecedesMotionBoundary() throws {
        let manager = try source("WalkingPadRemote/BluetoothManager.swift")
        let collection = try functionBody(
            "private func startNativeHeartRateCollection(",
            in: manager
        )
        assertOrdered([
            "persistNativeWorkoutRecoveryRecord(recoveryRecord)",
            "iPhoneHealthKitHeartRateProvider.start(at: acquisitionStartedAt)",
        ], in: collection)

        let commit = try functionBody(
            "private func commitNativeHeartRatePreflight(",
            in: manager
        )
        assertOrdered([
            "persistNativeWorkoutRecoveryRecord(committedRecoveryRecord)",
            "nativeHealthKitWorkoutCommitted = true",
            "commitExistingHrControl(preflightLatencySeconds: latency)",
        ], in: commit)
    }

    func testRecoveryCannotAuthorizeMotionOrCreateSecondTelemetrySession() throws {
        let manager = try source("WalkingPadRemote/BluetoothManager.swift")
        let process = try functionBody(
            "private func processPendingActiveWorkoutRecoveryIfPossible()",
            in: manager
        )
        let restore = try functionBody(
            "private func restoreCommittedNativeWorkout(",
            in: manager
        )
        let unavailable = try functionBody(
            "private func handleUnavailableActiveWorkoutRecovery(error: Error?)",
            in: manager
        )
        let forbidden = [
            "startWithSpeed", "sendTreadmill", "writeCommand", "enqueue",
            "beginTelemetryV2Session", "isHrControlRunning = true",
        ]
        for body in [process, restore, unavailable] {
            for token in forbidden {
                XCTAssertFalse(body.contains(token), token)
            }
        }
        XCTAssertTrue(process.contains(
            "recoveredCollectionStarted: lifecycle.collectionStarted"
        ))
        XCTAssertTrue(restore.contains("pendingHealthkitTelemetryV2SessionID"))
        XCTAssertTrue(restore.contains("nativeWorkoutRecoverySessionRecovered = true"))
    }

    func testEveryNonStopMotionEntryPointIsRecoveryGated() throws {
        let manager = try source("WalkingPadRemote/BluetoothManager.swift")
        let sharedGate = try functionBody(
            "private var blocksNonStopTreadmillMotion: Bool",
            in: manager
        )
        XCTAssertTrue(sharedGate.contains("pendingNativeWorkoutStopTerminalRequest != nil"))
        for signature in [
            "func startWithSpeed(",
            "func setTargetSpeedFromSlider(",
            "func adjustSpeed(",
            "private func sendTreadmillSetSpeed(",
            "func startStopTruthExperiment()",
            "private func invokeStopTruthExperimentTransport(",
        ] {
            XCTAssertTrue(
                try functionBody(signature, in: manager).contains(
                    "blocksNonStopTreadmillMotion"
                ),
                signature
            )
        }
        XCTAssertTrue(
            try functionBody("var canStartTreadmillTestRun: Bool", in: manager)
                .contains("blocksNonStopTreadmillMotion")
        )
    }

    func testCommittedIdentityDrivesStructuredLogAndTelemetryV2Session() throws {
        let manager = try source("WalkingPadRemote/BluetoothManager.swift")
        let structuredLog = try functionBody(
            "private func startTrainingStructuredLog(",
            in: manager
        )
        let commit = try functionBody(
            "private func commitExistingHrControl(",
            in: manager
        )

        XCTAssertTrue(structuredLog.contains("return resolvedSessionID"))
        XCTAssertEqual(
            structuredLog.components(separatedBy: "return resolvedSessionID").count - 1,
            3
        )
        assertOrdered([
            "let legacySessionID = startTrainingStructuredLog(trigger: \"start_hr\")",
            "beginTelemetryV2Session(legacySessionID: legacySessionID)",
        ], in: commit)
    }

    func testPendingRequestBlocksProviderWarmAndUnprovenMarkerCannotPresentElapsedTime() throws {
        let manager = try source("WalkingPadRemote/BluetoothManager.swift")
        let outstanding = try functionBody(
            "private var hasOutstandingNativeWorkoutRecovery: Bool",
            in: manager
        )
        let presentation = try functionBody(
            "var shouldPresentActiveWorkout: Bool",
            in: manager
        )

        XCTAssertTrue(outstanding.contains("activeWorkoutRecoveryRequestPending"))
        XCTAssertTrue(presentation.contains("case .record(let record)"))
        XCTAssertTrue(presentation.contains("record.phase == .committed"))
    }

    func testRecoveredPreflightDiscardHasZeroTreadmillWrites() throws {
        let manager = try source("WalkingPadRemote/BluetoothManager.swift")
        let discard = try functionBody(
            "private func discardRecoveredUncommittedWorkout()",
            in: manager
        )

        XCTAssertTrue(discard.contains("iPhoneHealthKitHeartRateProvider.discard"))
        XCTAssertTrue(discard.contains("clearNativeWorkoutRecoveryRecord()"))
        for token in ["stopBelt", "startWithSpeed", "sendTreadmill", "writeCommand", "enqueue"] {
            XCTAssertFalse(discard.contains(token), token)
        }
    }

    func testRecoveredStopRequiresFreshControlReadinessAndExplicitUserAction() throws {
        let manager = try source("WalkingPadRemote/BluetoothManager.swift")
        let readiness = try functionBody(
            "var canStopPresentedWorkout: Bool",
            in: manager
        )
        let stop = try functionBody(
            "private func stopRecoveredNativeWorkout()",
            in: manager
        )
        let performWrite = try functionBody(
            "private func performWrite(",
            in: manager
        )
        let stopBelt = try functionBody(
            "private func stopBeltWithToggle(",
            in: manager
        )
        let beginTerminal = try functionBody(
            "private func beginNativeWorkoutStopTerminalRequestIfNeeded()",
            in: manager
        )
        let invoked = try functionBody(
            "private func nativeWorkoutStopTransportInvokedIfNeeded()",
            in: manager
        )

        XCTAssertTrue(readiness.contains("record.phase == .committed"))
        XCTAssertTrue(readiness.contains("record.phase == .stopping"))
        XCTAssertTrue(readiness.contains("&& isTreadmillControlReady"))
        assertOrdered([
            "guard canStopPresentedWorkout else { return }",
            "stopBeltWithToggle(reason: \"recovered_hr_manual_stop\")",
        ], in: stop)
        XCTAssertFalse(stop.contains("record.finishing"))
        XCTAssertFalse(stop.contains("finishNativeHealthKitWorkoutIfNeeded"))
        assertOrdered([
            "beginNativeWorkoutStopTerminalRequestIfNeeded()",
            "stopBeltOnce(",
        ], in: stopBelt)
        XCTAssertTrue(beginTerminal.contains("record.stopping(requestedAt: requestedAt)"))
        XCTAssertFalse(beginTerminal.contains("nativeHealthKitWorkoutCommitted"))
        assertOrdered([
            "p.writeValue(data, for: ch, type: type)",
            "nativeWorkoutStopTransportInvokedIfNeeded()",
        ], in: performWrite)
        assertOrdered([
            "guard nativeHealthKitWorkoutCommitted else",
            "pending.record.finishing(requestedAt: pending.requestedAt)",
            "finishNativeHealthKitWorkoutIfNeeded()",
        ], in: invoked)
    }

    func testFinishingRecoveryResumesHealthKitTerminalWorkWithoutSecondTreadmillStop() throws {
        let manager = try source("WalkingPadRemote/BluetoothManager.swift")
        let resume = try functionBody(
            "private func resumeFinishingNativeWorkout(",
            in: manager
        )

        XCTAssertTrue(resume.contains("finishNativeHealthKitWorkoutIfNeeded()"))
        XCTAssertFalse(resume.contains("stopBelt"))
        XCTAssertFalse(resume.contains("sendTreadmill"))
        XCTAssertFalse(resume.contains("writeCommand"))
    }

    func testRecoveryCallbackAndTerminalClearAreIdempotent() throws {
        let manager = try source("WalkingPadRemote/BluetoothManager.swift")
        let callback = try functionBody(
            "func handleActiveWorkoutRecovery(",
            in: manager
        )
        let finish = try functionBody(
            "private func finishNativeHealthKitWorkoutIfNeeded()",
            in: manager
        )

        XCTAssertTrue(callback.contains(
            "guard !didHandleActiveWorkoutRecoveryCallback else { return }"
        ))
        XCTAssertTrue(finish.contains("if terminalSaveProven"))
        XCTAssertTrue(finish.contains(
            "guard pendingNativeWorkoutStopTerminalRequest == nil else { return }"
        ))
        XCTAssertTrue(finish.contains("guard !isConnected else"))
        XCTAssertTrue(finish.contains("record.finishing(requestedAt: finishRequestedAt)"))
        XCTAssertEqual(
            finish.components(separatedBy: "clearNativeWorkoutRecoveryRecord()").count - 1,
            1
        )
    }

    func testStoppedRecoveryPersistsTruthBeforeCollectionEndAndNeverUsesRelaunchFallback() throws {
        let provider = try source(
            "WalkingPadRemote/IPhoneHealthKitLiveHeartRateProvider.swift"
        )
        let core = try source("WalkingPadRemote/IPhoneHealthKitHeartRateProviderCore.swift")
        let recovery = try functionBody("func recoverWorkout(", in: provider)
        let stop = try functionBody("func stopActivity(at date: Date)", in: provider)

        XCTAssertFalse(recovery.contains("endDate ?? Date()"))
        XCTAssertFalse(stop.contains("endDate ?? date"))
        assertOrdered([
            "persistStoppedAt(stoppedAt)",
            "driver.endCollection(at: stoppedAt)",
            "driver.finishWorkout()",
        ], in: core)
        XCTAssertTrue(core.contains("missingRecoveredStopDate"))
    }

    func testDurationExtensionAndLegacyIdentityPersistBeforeRuntimeExposure() throws {
        let manager = try source("WalkingPadRemote/BluetoothManager.swift")
        let extend = try functionBody("func extendHrSession(", in: manager)
        let legacy = try functionBody(
            "private func recordHrWorkoutIfNeeded(durationOverride: Int?, failed: Bool?)",
            in: manager
        )

        assertOrdered([
            "recoveryRecord.planningDuration(seconds: newTotalSeconds)",
            "hrSessionTotalSeconds = newTotalSeconds",
        ], in: extend)
        assertOrdered([
            "recoveryRecord.linkingLegacyWorkout(id: entry.id)",
            "legacyShadowWorkoutHistory.insert(entry, at: 0)",
            "hrWorkoutRecorded = true",
        ], in: legacy)
    }

    func testDeferredSavedProofClearsOnlyAfterExactWorkoutMatch() throws {
        let manager = try source("WalkingPadRemote/BluetoothManager.swift")
        let resolve = try functionBody(
            "private func resolveDeferredNativeHealthKitLinkageIfPossible()",
            in: manager
        )
        let complete = try functionBody(
            "private func completeRecoveredFinishIfProven(",
            in: manager
        )

        assertOrdered([
            "guard error == nil else",
            "NativeWorkoutSavedProofPolicy.uniqueMatch(",
            "guard let workout else {",
            "let linkagePersisted = await linkDeferredNativeHealthKitWorkout(",
            "guard linkagePersisted else { return }",
            "clearDeferredNativeHealthKitLinkage(linkage)",
            "completeRecoveredFinishIfProven(linkage: linkage)",
        ], in: resolve)
        XCTAssertFalse(resolve.contains("clearNativeWorkoutRecoveryRecord()"))
        XCTAssertTrue(complete.contains("record.phase == .finishing"))
        XCTAssertTrue(complete.contains("record.appWorkoutID == recoveryAppWorkoutID"))
        XCTAssertTrue(complete.contains("clearNativeWorkoutRecoveryRecord()"))

        let becameActive = try functionBody(
            "func nativeHeartRateAppBecameActive()",
            in: manager
        )
        XCTAssertTrue(becameActive.contains(
            "resolveDeferredNativeHealthKitLinkageIfPossible()"
        ))

        let link = try functionBody(
            "private func linkDeferredNativeHealthKitWorkout(",
            in: manager
        )
        XCTAssertTrue(link.contains("NativeWorkoutRequiredLinkagePolicy.complete("))
        XCTAssertTrue(link.contains("persistHealthKitWorkoutAssociationWithTelemetryV2("))

        let exactLegacy = try functionBody(
            "private func persistExactLegacyWorkoutLink(",
            in: manager
        )
        assertOrdered([
            "guard let index = entries.firstIndex",
            "NativeWorkoutLegacyLinkPolicy.canLink(",
            "guard saveLegacyShadowWorkoutHistory",
            "return false",
        ], in: exactLegacy)

        let directLink = try functionBody(
            "private func linkNativeHealthKitWorkout(",
            in: manager
        )
        XCTAssertTrue(directLink.contains("await linkDeferredNativeHealthKitWorkout("))

        let finish = try functionBody(
            "private func finishNativeHealthKitWorkoutIfNeeded()",
            in: manager
        )
        assertOrdered([
            "guard await linkNativeHealthKitWorkout(",
            "terminalSaveProven = true",
        ], in: finish)
    }

    private func source(_ relativePath: String) throws -> String {
        let packageDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageDirectory.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func functionBody(_ signature: String, in source: String) throws -> String {
        guard let signatureRange = source.range(of: signature),
              let openingBrace = source[signatureRange.lowerBound...].firstIndex(of: "{") else {
            throw NSError(domain: "NativeWorkoutRecoveryIntegrationContractTests", code: 1)
        }
        var depth = 0
        var cursor = openingBrace
        while cursor < source.endIndex {
            if source[cursor] == "{" { depth += 1 }
            if source[cursor] == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[openingBrace...cursor])
                }
            }
            cursor = source.index(after: cursor)
        }
        throw NSError(domain: "NativeWorkoutRecoveryIntegrationContractTests", code: 2)
    }

    private func assertOrdered(
        _ tokens: [String],
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var lowerBound = source.startIndex
        for token in tokens {
            guard let range = source.range(of: token, range: lowerBound..<source.endIndex) else {
                XCTFail("Missing ordered token: \(token)", file: file, line: line)
                return
            }
            lowerBound = range.upperBound
        }
    }
}
