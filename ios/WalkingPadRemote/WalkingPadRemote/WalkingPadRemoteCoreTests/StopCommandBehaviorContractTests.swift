import Foundation
import XCTest

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

    func testDirectStopKeepsHighPriorityAndTwoExistingRetries() throws {
        let body = try functionBody("func stopBelt()")
        let initial = "writeCommand(packet, label: \"STOP\", highPriority: true)"
        let retry2 = "scheduleWrite(packet, label: \"STOP retry\", after: 2.0)"
        let retry4 = "scheduleWrite(packet, label: \"STOP retry\", after: 4.0)"

        assertOrdered([initial, retry2, retry4], in: body)
        XCTAssertEqual(body.components(separatedBy: initial).count - 1, 1)
        XCTAssertEqual(body.components(separatedBy: retry2).count - 1, 1)
        XCTAssertEqual(body.components(separatedBy: retry4).count - 1, 1)
    }

    func testManualAndHrStopSequenceKeepsStopToggleAndConditionalRetryOrder() throws {
        let body = try functionBody("private func stopBeltWithToggle(reason: String)")
        let initial = "stopBeltOnce()"
        let togglePacket = "let toggle = buildCmdPacket(cmd: 0x04, value: 0x01)"
        let toggleDelay = "scheduleWrite(toggle, label: \"START/STOP TOGGLE\", after: 2.0)"
        let retryDelay = "DispatchQueue.main.asyncAfter(deadline: .now() + 4.0)"
        let conditionalRetry = "self.writeCommand(stopPacket, label: \"STOP retry\")"

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
                "stopBeltOnce()",
                "scheduleWrite(toggle, label: \"START/STOP TOGGLE\", after: 2.0)",
                "DispatchQueue.main.asyncAfter(deadline: .now() + 4.0)",
                "beginStopObservation(source: reason)"
            ],
            in: body
        )
        let onceBody = try functionBody("private func stopBeltOnce()")
        XCTAssertTrue(onceBody.contains("writeCommand(packet, label: \"STOP\", highPriority: true)"))

        let directBody = try functionBody("func stopBelt()")
        assertOrdered(
            [
                "scheduleWrite(packet, label: \"STOP retry\", after: 4.0)",
                "beginStopObservation(source: \"direct\")"
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
        XCTAssertTrue(startBody.contains("controllerUnitsGateDecision"))
        XCTAssertTrue(startBody.contains("guard existingGatesAllowStart"))
        XCTAssertTrue(startBody.contains("guard unitsDecision.allowed"))
    }

    func testStopTruthAnchorsToActualInitialWriteAndPersistsUnavailableOutcome() throws {
        let writeBody = try functionBody("private func performWrite(_ data: Data, label: String)")
        assertOrdered(
            [
                "lastCommandSentAt = Date()",
                "if label == \"STOP\"",
                "markInitialStopCommandSent",
                "p.writeValue(data, for: ch, type: type)"
            ],
            in: writeBody
        )

        let beginBody = try functionBody("private func beginStopObservation(source: String, now: Date = Date())")
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
        let setSpeedBody = try functionBody("private func sendTreadmillSetSpeed(_ kmh: Double, label: String)")
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
