import Foundation
import TelemetryDomain
import XCTest
@testable import WalkingPadCoreLogic

final class TreadmillTelemetryBoundaryTests: XCTestCase {
    private lazy var managerSource = try! source("BluetoothManager.swift")
    private lazy var queueSource = try! source("CommandQueueService.swift")
    private lazy var sidecarSource = try! source("TreadmillCommandTelemetrySidecar.swift")
    private lazy var truthSource = try! telemetryDomainSource("TreadmillTruth.swift")

    func testCommandIdentityRemainsOutsideLegacyEqualityAndQueueDecisions() throws {
        let command = try declarationBody("struct Command: Equatable", in: queueSource)
        XCTAssertTrue(command.contains("let data: Data"))
        XCTAssertTrue(command.contains("let label: String"))
        XCTAssertFalse(command.contains("CommandID"))
        XCTAssertFalse(command.contains("DecisionID"))
        XCTAssertFalse(command.contains("AttemptID"))

        XCTAssertFalse(sidecarSource.contains("Data"))
        XCTAssertFalse(sidecarSource.contains("writeValue"))
        XCTAssertFalse(sidecarSource.contains("CommandQueueService"))
    }

    func testTelemetryHotPathHasNoPersistenceAsyncOrRawPacketSurface() {
        let forbidden = [
            "TelemetryRecorder",
            "TelemetryPersistence",
            "TelemetryStore",
            "SwiftData",
            "ModelContext",
            "FileHandle",
            "URLSession",
            "Task {",
            "await ",
            "Data",
            "rawHex",
            "hex(",
        ]
        for token in forbidden {
            XCTAssertFalse(truthSource.contains(token), "Treadmill truth exposes \(token)")
            XCTAssertFalse(sidecarSource.contains(token), "Treadmill sidecar exposes \(token)")
        }
        XCTAssertFalse(managerSource.contains("TreadmillTelemetrySinkDisposition"))
    }

    func testLegacyAcknowledgementObservationMirrorsAcceptedRuntimeMutation() throws {
        let callback = try functionBody(
            "func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor",
            in: managerSource
        )
        XCTAssertTrue(callback.contains("isLegacyAcknowledgementSignal"))
        XCTAssertTrue(callback.contains("LegacyAcknowledgementObservationSeam.evaluate("))
        XCTAssertTrue(
            callback.contains("isAwaitingAcknowledgement: lastCommandAwaitingAck")
        )
        XCTAssertTrue(callback.contains("sentAt: lastCommandSentAt"))
        XCTAssertTrue(callback.contains("timeout: commandAckTimeoutSeconds"))
        XCTAssertTrue(
            callback.contains("isQualifyingSignal: isLegacyAcknowledgementSignal")
        )
        XCTAssertTrue(callback.contains("legacyAcknowledgementDecision.observation"))
        XCTAssertTrue(
            callback.contains("if legacyAcknowledgementDecision.isAcceptedByLegacyRuntime")
        )
        XCTAssertFalse(callback.contains("deterministicallyAssociated"))
        XCTAssertFalse(callback.contains("observeAcknowledgement"))
        XCTAssertFalse(callback.contains("lastCommandSentAt.map"))
        XCTAssertFalse(callback.contains("if lastCommandAwaitingAck,"))
    }

    func testRoutineWalkingPadStatusWithoutPendingAckProducesNoObservation() {
        let statusPacket: [UInt8] = [0xF8, 0xA2, 0x00, 0x00]
        let decision = acknowledgementDecision(
            isAwaiting: false,
            sentAt: Date(timeIntervalSince1970: 100),
            receivedAt: Date(timeIntervalSince1970: 101),
            isQualifyingSignal: statusPacket.first == 0xF8
        )

        XCTAssertFalse(decision.isAcceptedByLegacyRuntime)
        XCTAssertTrue([decision.observation].compactMap { $0 }.isEmpty)
    }

    func testPendingQualifyingSignalInsideWindowMutatesLegacyStateAndEmitsOnce() throws {
        let receivedAt = Date(timeIntervalSince1970: 102)
        let decision = acknowledgementDecision(
            isAwaiting: true,
            sentAt: Date(timeIntervalSince1970: 99),
            receivedAt: receivedAt,
            isQualifyingSignal: true
        )
        var isAwaiting = true
        var acknowledgedAt: Date?
        if decision.isAcceptedByLegacyRuntime {
            isAwaiting = false
            acknowledgedAt = receivedAt
        }
        let observations = [decision.observation].compactMap { $0 }
        let observation = try XCTUnwrap(observations.first)

        XCTAssertFalse(isAwaiting)
        XCTAssertEqual(acknowledgedAt, receivedAt)
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observation.association, .unresolvedByLegacyRuntime)
        XCTAssertNil(observation.commandID)
        XCTAssertNil(observation.attemptID)
    }

    func testQualifyingSignalOutsideWindowLeavesTimeoutOwnershipAndEmitsNothing() {
        let sentAt = Date(timeIntervalSince1970: 100)
        let receivedAt = Date(timeIntervalSince1970: 103.001)
        let decision = acknowledgementDecision(
            isAwaiting: true,
            sentAt: sentAt,
            receivedAt: receivedAt,
            isQualifyingSignal: true
        )
        var isAwaiting = true
        if decision.isAcceptedByLegacyRuntime {
            isAwaiting = false
        }

        XCTAssertFalse(decision.isAcceptedByLegacyRuntime)
        XCTAssertNil(decision.observation)
        XCTAssertTrue(isAwaiting)
        XCTAssertTrue(receivedAt.timeIntervalSince(sentAt) > 3.0)
    }

    func testLegacyTimeoutOwnerRemainsOutsideNotificationCallback() throws {
        let callback = try functionBody(
            "func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor",
            in: managerSource
        )
        let update = try functionBody("private func updateTreadmillStatus()", in: managerSource)

        XCTAssertFalse(callback.contains("lastCommandTimeouts += 1"))
        XCTAssertTrue(update.contains("now.timeIntervalSince(sentAt) > commandAckTimeoutSeconds"))
        XCTAssertTrue(update.contains("lastCommandAwaitingAck = false"))
        XCTAssertTrue(update.contains("lastCommandTimeouts += 1"))
        XCTAssertTrue(update.contains("observedLegacyCommandTimeout = true"))
    }

    func testStartAffordanceAndRuntimeAuthorizationDoNotReadTreadmillTelemetry() throws {
        let affordance = try declarationBody(
            "var isHrControlStartAffordanceAvailable: Bool",
            in: managerSource
        )
        let start = try functionBody("func startHrControl()", in: managerSource)
        let commit = try functionBody(
            "private func commitExistingHrControl(preflightLatencySeconds: TimeInterval)",
            in: managerSource
        )
        XCTAssertFalse(affordance.lowercased().contains("telemetry"))
        XCTAssertFalse(affordance.contains("factual"))
        XCTAssertFalse(affordance.contains("commandID"))
        XCTAssertFalse(affordance.contains("treadmillTelemetrySink"))
        XCTAssertTrue(start.contains("nativeHeartRatePreflightEngine.requestStart"))
        XCTAssertTrue(commit.contains("controllerUnitsGateDecision"))
        XCTAssertFalse(start.contains("treadmillTelemetrySink"))
        XCTAssertFalse(commit.contains("treadmillTelemetrySink"))
    }

    func testFactualAndStopEvidenceOnlyUseDecodedObservationAndExistingPredicate() throws {
        let normalization = try functionBody(
            "private func observeTreadmillProviderObservation(",
            in: managerSource
        )
        XCTAssertFalse(normalization.contains("speedKmh"))
        XCTAssertFalse(normalization.contains("expectedSpeedKmh"))
        XCTAssertFalse(normalization.contains("desiredSpeedKmh"))
        XCTAssertFalse(normalization.contains("deviceTargetSpeedKmh"))

        let stop = try functionBody("private func observeCurrentStopTruth(", in: managerSource)
        XCTAssertTrue(managerSource.contains("evaluation: StopObservationEvaluation"))
        XCTAssertTrue(stop.contains("evaluation.isConfirmed"))
        XCTAssertFalse(stop.contains("expectedSpeedKmh"))
        XCTAssertFalse(stop.contains("desiredSpeedKmh"))
        XCTAssertFalse(stop.contains("deviceTargetSpeedKmh"))
    }

    func testCommandedSpeedUsesProtocolNativeWireScaleWithoutUnitsInference() throws {
        let mapping = try functionBody(
            "private func treadmillSetSpeedCommandKind(",
            in: managerSource
        )
        XCTAssertTrue(mapping.contains("switch treadmillProtocol"))
        XCTAssertTrue(mapping.contains("rawControllerTenths: clampSpeedTenths(kmh)"))
        XCTAssertTrue(mapping.contains("rawHundredthsKmh: raw"))
        XCTAssertTrue(mapping.contains("rawTenthsKmh: raw"))
        XCTAssertTrue(mapping.contains("nativeUnit: .unknown"))
        XCTAssertFalse(mapping.contains("nativeUnit: .kilometresPerHour"))
    }

    func testLegacyWriteResultCannotClaimCommandOrAttemptIdentity() throws {
        let callback = try functionBody(
            "func peripheral(_ peripheral: CBPeripheral, didWriteValueFor",
            in: managerSource
        )
        XCTAssertTrue(callback.contains("LegacyWriteResultObservation("))
        XCTAssertFalse(callback.contains("commandID:"))
        XCTAssertFalse(callback.contains("attemptID:"))
        XCTAssertFalse(callback.contains("deterministicallyAssociated"))
    }

    func testLegacyStopRetriesReuseTelemetryCommandIdentityWithoutChangingSchedule() throws {
        let stop = try functionBody("func stopBelt()", in: managerSource)
        XCTAssertTrue(stop.contains("after: 2.0"))
        XCTAssertTrue(stop.contains("after: 4.0"))
        XCTAssertEqual(
            stop.components(separatedBy: "telemetryRequest: telemetryRequest").count - 1,
            3
        )
    }

    func testSinkCallsOccurAfterAuthoritativeQueueAndWriteEffects() throws {
        let enqueue = try functionBody("private func enqueueCommand(", in: managerSource)
        XCTAssertLessThan(
            try XCTUnwrap(enqueue.range(of: "processCommandQueue()")?.lowerBound),
            try XCTUnwrap(enqueue.range(of: "observeTreadmillTelemetry")?.lowerBound)
        )

        let write = try functionBody("private func performWrite(", in: managerSource)
        XCTAssertTrue(write.contains("p.writeValue(data, for: ch, type: type)"))
        XCTAssertFalse(write.contains("observeTreadmillTelemetry"))

        let process = try functionBody("private func processCommandQueue()", in: managerSource)
        let writeIndex = try XCTUnwrap(process.range(of: "self.performWrite(")?.lowerBound)
        let nextAllowedIndex = try XCTUnwrap(
            process.range(of: "self.nextCommandAllowedAt =")?.lowerBound
        )
        let sinkIndex = try XCTUnwrap(
            process.range(of: "self.observeTreadmillTelemetry(evidence)")?.lowerBound
        )
        XCTAssertLessThan(writeIndex, nextAllowedIndex)
        XCTAssertLessThan(nextAllowedIndex, sinkIndex)
    }

    private func source(_ filename: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("WalkingPadRemote")
            .appendingPathComponent(filename)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func acknowledgementDecision(
        isAwaiting: Bool,
        sentAt: Date?,
        receivedAt: Date,
        isQualifyingSignal: Bool
    ) -> LegacyAcknowledgementObservationSeam {
        LegacyAcknowledgementObservationSeam.evaluate(
            isAwaitingAcknowledgement: isAwaiting,
            sentAt: sentAt,
            receivedAt: receivedAt,
            timeout: 3.0,
            isQualifyingSignal: isQualifyingSignal,
            protocolKind: .walkingPad,
            connectionEpoch: TreadmillConnectionEpoch(
                rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000044")!
            ),
            recordedAt: receivedAt
        )
    }

    private func telemetryDomainSource(_ filename: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TelemetryDomain")
            .appendingPathComponent(filename)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func functionBody(_ signature: String, in source: String) throws -> String {
        try declarationBody(signature, in: source)
    }

    private func declarationBody(_ signature: String, in source: String) throws -> String {
        guard let signatureRange = source.range(of: signature),
              let openingBrace = source[signatureRange.lowerBound...].firstIndex(of: "{") else {
            throw NSError(domain: "TreadmillTelemetryBoundaryTests", code: 1)
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
        throw NSError(domain: "TreadmillTelemetryBoundaryTests", code: 2)
    }
}
