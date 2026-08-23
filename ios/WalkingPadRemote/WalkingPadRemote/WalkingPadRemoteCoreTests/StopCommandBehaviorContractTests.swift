import Foundation
import XCTest
@testable import WalkingPadCoreLogic

final class StopCommandBehaviorContractTests: XCTestCase {
    private lazy var source: String = {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("WalkingPadRemote/BluetoothManager.swift")
        return (try? String(contentsOf: sourceURL, encoding: .utf8)) ?? ""
    }()

    func testLegacyStopPacketBytesRemainSpeedRawZero() throws {
        let body = try functionBody("private func buildTreadmillStopPacket() -> Data?")

        XCTAssertTrue(body.contains("case .walkingPad:\n            return buildCmdPacket(cmd: 0x01, value: 0x00)"))

        let bytes: [UInt8] = [0xF7, 0xA2, 0x01, 0x00, 0xA3, 0xFD]
        XCTAssertEqual(bytes.map { String(format: "%02X", $0) }.joined(separator: " "), "F7 A2 01 00 A3 FD")
    }

    func testProductionWalkingPadCodecBytesRemainEquivalent() throws {
        let codecURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("WalkingPadRemote/BLETransportCodec.swift")
        let codec = try String(contentsOf: codecURL)
        XCTAssertTrue(codec.contains("private static func buildWalkingPadCommandPacket(command: UInt8, value: UInt8)"))
        XCTAssertTrue(source.contains("private func buildCmdPacket(cmd: UInt8, value: UInt8)"))
        XCTAssertEqual(
            BLETransportCodec.buildStopTruthExperimentPacket(role: .initialStop),
            Data([0xF7, 0xA2, 0x01, 0x00, 0xA3, 0xFD])
        )
        XCTAssertEqual(
            BLETransportCodec.buildStopTruthExperimentPacket(role: .productionStopRecovery),
            Data([0xF7, 0xA2, 0x04, 0x01, 0xA7, 0xFD])
        )
        XCTAssertEqual(
            BLETransportCodec.buildStopTruthExperimentPacket(role: .speedRaw5),
            Data([0xF7, 0xA2, 0x01, 0x05, 0xA8, 0xFD])
        )
    }

    func testProductionCallsDoNotRouteThroughExperimentExecutor() throws {
        for signature in [
            "func manualGo(targetSpeed: Double)",
            "func manualStop()",
            "func startWithSpeed(_ kmh: Double)",
            "func startHrControl()",
            "func stopHrControl()",
            "private func stopBeltWithToggle(reason: String)"
        ] {
            XCTAssertFalse(try functionBody(signature).contains("stopTruthExperiment"), signature)
        }
    }

    func testWalkingPadQueueMinimumIntervalRemainsTwoSeconds() {
        XCTAssertTrue(source.contains("private let commandMinIntervalWalkingPadSeconds: TimeInterval = 2.0"))
    }

    func testExistingNotifyFE01SemanticsRemainNormalizedWithoutRawHex() throws {
        let notifyRange = try XCTUnwrap(source.range(of: "logTrainingEvent(\"notify_fe01\", fields: ["))
        let suffix = source[notifyRange.lowerBound...]
        let close = try XCTUnwrap(suffix.range(of: "])"))
        let event = String(suffix[..<close.upperBound])
        XCTAssertFalse(event.contains("raw_hex"))
        XCTAssertTrue(event.contains("checksum_ok"))
    }

    func testDirectStopKeepsHighPriorityAndTwoExistingRetries() throws {
        let body = try functionBody("func stopBelt()")
        assertOrdered(
            [
                "writeCommand(",
                "label: \"STOP\"",
                "highPriority: true",
                "scheduleWrite(",
                "label: \"STOP retry\"",
                "after: 2.0",
                "scheduleWrite(",
                "label: \"STOP retry\"",
                "after: 4.0",
            ],
            in: body
        )
        XCTAssertEqual(body.components(separatedBy: "label: \"STOP\"").count - 1, 1)
        XCTAssertEqual(body.components(separatedBy: "label: \"STOP retry\"").count - 1, 2)
        XCTAssertEqual(body.components(separatedBy: "after: 2.0").count - 1, 1)
        XCTAssertEqual(body.components(separatedBy: "after: 4.0").count - 1, 1)
    }

    func testManualAndHrStopSequenceKeepsStopToggleAndConditionalRetryOrder() throws {
        let body = try functionBody("private func stopBeltWithToggle(reason: String)")
        let initial = "let stopCommandWasEnqueued = stopBeltOnce("
        let togglePacket = "let toggle = buildCmdPacket(cmd: 0x04, value: 0x01)"
        let toggleDelay = "label: \"START/STOP TOGGLE\""
        let retryDelay = "DispatchQueue.main.asyncAfter(deadline: .now() + 4.0)"
        let conditionalRetry = "self.writeCommand("

        assertOrdered([initial, togglePacket, toggleDelay, retryDelay, conditionalRetry], in: body)
        XCTAssertEqual(body.components(separatedBy: togglePacket).count - 1, 1)
        XCTAssertEqual(body.components(separatedBy: toggleDelay).count - 1, 1)
        XCTAssertEqual(body.components(separatedBy: retryDelay).count - 1, 1)
        XCTAssertEqual(body.components(separatedBy: conditionalRetry).count - 1, 1)
    }

    func testInitialStopRemainsHighPriorityBeforeObservationStarts() throws {
        let body = try functionBody("private func stopBeltWithToggle(reason: String)")

        assertOrdered(
            [
                "let stopCommandWasEnqueued = stopBeltOnce(",
                "label: \"START/STOP TOGGLE\"",
                "DispatchQueue.main.asyncAfter(deadline: .now() + 4.0)",
                "beginStopObservation(source: reason, telemetryChain: telemetryChain)"
            ],
            in: body
        )
        let onceBody = try functionBody("private func stopBeltOnce(")
        assertOrdered(
            ["writeCommand(", "label: \"STOP\"", "highPriority: true"],
            in: onceBody
        )

        let directBody = try functionBody("func stopBelt()")
        assertOrdered(
            [
                "after: 4.0",
                "beginStopObservation(source: \"direct\", telemetryChain: telemetryChain)"
            ],
            in: directBody
        )
    }

    func testHrCleanupAndUnitsGateCallsRemainBeforeStopOrMotion() throws {
        let stopHrBody = try functionBody("func stopHrControl()")
        assertOrdered(
            [
                "stopTrainingStructuredLog(reason: \"manual_stop\")",
                "recordHrWorkoutIfNeeded(durationOverride: elapsed, failed: false)",
                "stopBeltWithToggle(reason: \"hr\")"
            ],
            in: stopHrBody
        )

        let startBody = try functionBody("func startHrControl()")
        let commitBody = try functionBody(
            "private func commitExistingHrControl(preflightLatencySeconds: TimeInterval)"
        )
        XCTAssertTrue(startBody.contains("nativeHeartRatePreflightEngine.requestStart"))
        XCTAssertTrue(commitBody.contains("controllerUnitsGateDecision"))
        XCTAssertTrue(commitBody.contains("guard nativeHeartRateSafetyFacts().permitsCommit"))
    }

    func testStopTruthAnchorsToActualInitialWriteAndPersistsUnavailableOutcome() throws {
        let writeBody = try functionBody("private func performWrite(")
        assertOrdered(
            [
                "lastCommandSentAt = Date()",
                "if label == \"STOP\"",
                "markInitialStopCommandSent",
                "p.writeValue(data, for: ch, type: type)"
            ],
            in: writeBody
        )

        let beginBody = try functionBody("private func beginStopObservation(")
        assertOrdered(
            [
                "if let pendingAttemptID = unavailableStopAttempt?.id",
                "finalizeUnavailableStopAttempt(attemptID: pendingAttemptID)",
                "recordUnavailableStopAttempt(source: source, attemptedAt: now)"
            ],
            in: beginBody
        )
        XCTAssertTrue(beginBody.contains("recordUnavailableStopAttempt(source: source, attemptedAt: now)"))
        let unavailableBody = try functionBody("private func recordUnavailableStopAttempt(source: String, attemptedAt: Date)")
        XCTAssertTrue(unavailableBody.contains("unavailableStopAttempt = UnavailableStopAttempt"))
        XCTAssertTrue(unavailableBody.contains("\"stop_command_status\"") && unavailableBody.contains("\"queued\"") && unavailableBody.contains("\"not_sent\""))
        let finalizeBody = try functionBody("private func finalizeUnavailableStopAttempt(attemptID: UUID)")
        XCTAssertTrue(finalizeBody.contains("StopObservationFinalResult.unconfirmed.rawValue"))
        XCTAssertTrue(finalizeBody.contains("stop_command_not_sent_transport_unavailable"))
        XCTAssertTrue(finalizeBody.contains("confirmation_context_unavailable"))
        let markBody = try functionBody("private func markInitialStopCommandSent(at sentAt: Date)")
        XCTAssertTrue(markBody.contains("if var attempt = unavailableStopAttempt"))
        XCTAssertTrue(markBody.contains("logTrainingEvent(\"stop_command_sent\""))

        let skippedBody = try functionBody("private func markInitialStopCommandNotSent(reason: String, at now: Date = Date())")
        XCTAssertTrue(skippedBody.contains("stop_command_not_sent_\\(reason)"))
        let telemetryBody = try functionBody("private func stopObservationTelemetryFields(")
        XCTAssertTrue(telemetryBody.contains("\"stop_command_status\": lifecycle.commandStatus"))
    }

    func testNewMotionIntentAndCurrentFreshnessInvalidateConfirmedStopStatus() throws {
        let setSpeedBody = try functionBody("private func sendTreadmillSetSpeed(")
        assertOrdered(
            [
                "if kmh > 0.1",
                "endStopObservationForNewMotion()",
                "switch treadmillProtocol"
            ],
            in: setSpeedBody
        )

        let observationBody = try functionBody("private func recordStopObservation(")
        XCTAssertTrue(observationBody.contains("guard lifecycle.finalResult == nil"))
        XCTAssertTrue(observationBody.contains("lifecycle.record("))
        XCTAssertTrue(observationBody.contains("refreshStopTruthStatus"))
        XCTAssertTrue(observationBody.contains("scheduleStopObservationFreshnessRefresh"))

        let statusBody = try functionBody("private func updateTreadmillStatus()")
        XCTAssertTrue(statusBody.contains("lifecycle.currentEvaluation(at: now)"))
    }

    private func functionBody(_ signature: String) throws -> String {
        guard let signatureRange = source.range(of: signature),
              let openingBrace = source[signatureRange.upperBound...].firstIndex(of: "{") else {
            throw NSError(domain: "StopCommandBehaviorContractTests", code: 1)
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
        throw NSError(domain: "StopCommandBehaviorContractTests", code: 2)
    }

    private func assertOrdered(
        _ fragments: [String],
        in text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var searchStart = text.startIndex
        for fragment in fragments {
            guard let range = text.range(of: fragment, range: searchStart..<text.endIndex) else {
                XCTFail("Missing or out-of-order fragment: \(fragment)", file: file, line: line)
                return
            }
            searchStart = range.upperBound
        }
    }
}
