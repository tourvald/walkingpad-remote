import Foundation
import XCTest
@testable import WalkingPadCoreLogic

final class WalkingPadStatusRefreshContractTests: XCTestCase {
    func testRequestCannotPublishOrInferFactualSpeed() throws {
        let manager = try managerSource()
        let request = try functionBody(
            "private func requestWalkingPadStatusRefresh(",
            in: manager
        )

        XCTAssertTrue(request.contains("buildWalkingPadQueryStatusPacket"))
        XCTAssertTrue(request.contains("label: \"QUERY STATUS\""))
        XCTAssertFalse(request.contains("observeTreadmillProviderObservation"))
        XCTAssertFalse(request.contains("deviceReportedSpeedKmh ="))
        XCTAssertFalse(request.contains("speedKmh ="))
    }

    func testOnlyCurrentFE01CallbackCanCreateWalkingPadObservation() throws {
        let manager = try managerSource()
        let callback = try functionBody(
            "func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic:",
            in: manager
        )

        XCTAssertTrue(callback.contains("isCurrentCharacteristicCallback(characteristic)"))
        XCTAssertTrue(callback.contains("BLETransportCodec.parseWalkingPadStatus(data)"))
        XCTAssertTrue(callback.contains("observeTreadmillProviderObservation"))
        XCTAssertTrue(callback.contains("checksumValid: status.checksumOk"))
        XCTAssertTrue(callback.contains("unitsTruth: self.treadmillUnitsTruthEvidence()"))
    }

    func testDisconnectClearsStatusQueryOwnership() throws {
        let reset = try functionBody("private func resetProtocolState()", in: managerSource())
        XCTAssertTrue(reset.contains("lastWalkingPadStatusQueryAt = nil"))
        XCTAssertTrue(reset.contains("latestTreadmillObservationEvidence = nil"))
    }

    func testStatusMaintenanceUsesSameIdleWindowAsMotionSafeUnitsRefresh() throws {
        let manager = try managerSource()
        let maintenance = try functionBody(
            "private func maintainWalkingPadReadOnlyEvidenceDuringActiveWorkout(",
            in: manager
        )

        XCTAssertTrue(maintenance.contains("motionQueueIdle: commandQueue.isEmpty"))
        XCTAssertTrue(maintenance.contains("!isCommandQueueProcessing"))
        XCTAssertTrue(maintenance.contains("earliestWriteDelaySeconds: max(0, nextCommandAllowedAt.timeIntervalSince(now))"))
        XCTAssertTrue(maintenance.contains("controllerUnitsNextScheduledMotionLeadSeconds"))
        XCTAssertFalse(maintenance.contains("highPriority: true"))
        XCTAssertFalse(maintenance.contains("sendTreadmill"))
    }

    func testActualWriteOwnsStatusCadenceAndExistingCallbackRevalidatesReadOnlyWindow() throws {
        let manager = try managerSource()
        let request = try functionBody("private func requestWalkingPadStatusRefresh(", in: manager)
        XCTAssertFalse(request.contains("lastWalkingPadStatusQueryAt ="))
        let write = try functionBody("private func performWrite(", in: manager)
        let invoked = try XCTUnwrap(write.range(of: "p.writeValue"))
        let tracked = try XCTUnwrap(write.range(of: "lastWalkingPadStatusQueryAt = sentAt"))
        XCTAssertLessThan(invoked.lowerBound, tracked.lowerBound)
        let queue = try functionBody("private func processCommandQueue()", in: manager)
        XCTAssertEqual(queue.components(separatedBy: "DispatchQueue.main.asyncAfter").count - 1, 1)
        let prune = try XCTUnwrap(queue.range(of: "CommandQueueService.discardReadOnlyQueries"))
        let send = try XCTUnwrap(queue.range(of: "self.performWrite"))
        XCTAssertLessThan(prune.lowerBound, send.lowerBound)
        XCTAssertTrue(queue.contains("self.controllerUnitsNextScheduledMotionLeadSeconds <= ControllerUnitsRefreshPolicy.requiredMotionLeadSeconds"))
    }

    private func managerSource() throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try String(
            contentsOf: testsDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("WalkingPadRemote/BluetoothManager.swift"),
            encoding: .utf8
        )
    }

    private func functionBody(_ signature: String, in source: String) throws -> String {
        guard let signatureRange = source.range(of: signature),
              let openingBrace = source[signatureRange.upperBound...].firstIndex(of: "{") else {
            throw NSError(domain: "WalkingPadStatusRefreshContractTests", code: 1)
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
        throw NSError(domain: "WalkingPadStatusRefreshContractTests", code: 2)
    }
}
