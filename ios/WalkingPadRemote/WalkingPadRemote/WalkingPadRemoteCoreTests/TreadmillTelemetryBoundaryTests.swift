import Foundation
import XCTest

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

    func testLegacyAcknowledgementIsAlwaysObservedWithoutCausalIDs() throws {
        let callback = try functionBody(
            "func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor",
            in: managerSource
        )
        XCTAssertTrue(callback.contains("isLegacyAcknowledgementSignal"))
        XCTAssertTrue(callback.contains(".unresolved("))
        XCTAssertFalse(callback.contains("deterministicallyAssociated"))
        XCTAssertFalse(callback.contains("observeAcknowledgement"))
        XCTAssertFalse(callback.contains("lastCommandSentAt.map"))
    }

    func testStartAffordanceAndRuntimeAuthorizationDoNotReadTreadmillTelemetry() throws {
        let affordance = try declarationBody(
            "var isHrControlStartAffordanceAvailable: Bool",
            in: managerSource
        )
        let start = try functionBody("func startHrControl()", in: managerSource)
        XCTAssertFalse(affordance.lowercased().contains("telemetry"))
        XCTAssertFalse(affordance.contains("factual"))
        XCTAssertFalse(affordance.contains("commandID"))
        XCTAssertFalse(affordance.contains("treadmillTelemetrySink"))
        XCTAssertTrue(start.contains("heartRateRuntimePrerequisitesAllowStart"))
        XCTAssertTrue(start.contains("controllerUnitsGateDecision"))
        XCTAssertFalse(start.contains("treadmillTelemetrySink"))
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
