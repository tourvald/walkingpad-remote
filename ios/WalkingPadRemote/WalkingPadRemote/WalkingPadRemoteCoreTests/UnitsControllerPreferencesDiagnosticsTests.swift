import Foundation
import XCTest
@testable import WalkingPadCoreLogic

final class UnitsControllerPreferencesDiagnosticsTests: XCTestCase {
    func testWhitelistedPacketsAcceptOnlyQueryAndKnownUnitPreferencePackets() {
        let query = BLETransportCodec.buildWalkingPadQueryParamsPacket()
        let metric = BLETransportCodec.buildWalkingPadUnitPreferencePacket(nativeUnits: .metric)!
        let imperial = BLETransportCodec.buildWalkingPadUnitPreferencePacket(nativeUnits: .imperial)!
        let nonWhitelistedKey = Data([0xF7, 0xA6, 0x02, 0x00, 0x00, 0x00, 0x00, 0xA8, 0xFD])

        XCTAssertTrue(UnitsControllerPreferencesDiagnostics.isWhitelistedPacket(query))
        XCTAssertTrue(UnitsControllerPreferencesDiagnostics.isWhitelistedPacket(metric))
        XCTAssertTrue(UnitsControllerPreferencesDiagnostics.isWhitelistedPacket(imperial))
        XCTAssertFalse(UnitsControllerPreferencesDiagnostics.isWhitelistedPacket(nonWhitelistedKey))
    }

    func testDangerousActionsRequireConfirmation() {
        XCTAssertFalse(UnitsControllerPreferencesDiagnostics.Action.readControllerUnits.requiresConfirmation)
        XCTAssertTrue(UnitsControllerPreferencesDiagnostics.Action.setMetric.requiresConfirmation)
        XCTAssertTrue(UnitsControllerPreferencesDiagnostics.Action.setImperial.requiresConfirmation)
        XCTAssertFalse(UnitsControllerPreferencesDiagnostics.Action.readBackVerify.requiresConfirmation)
        XCTAssertFalse(UnitsControllerPreferencesDiagnostics.Action.clearState.requiresConfirmation)
    }

    func testCommandDefinitionsExposePacketsAndDangerFlags() {
        let metric = UnitsControllerPreferencesDiagnostics.command(for: .setMetric)
        let imperial = UnitsControllerPreferencesDiagnostics.command(for: .setImperial)
        let query = UnitsControllerPreferencesDiagnostics.command(for: .readControllerUnits)

        XCTAssertEqual(metric?.packetHex, "F7 A6 08 00 00 00 00 AE FD")
        XCTAssertEqual(metric?.key, 8)
        XCTAssertEqual(metric?.value, 0)
        XCTAssertEqual(metric?.dangerousDebug, true)
        XCTAssertEqual(metric?.testControllerRequired, true)

        XCTAssertEqual(imperial?.packetHex, "F7 A6 08 00 00 00 01 AF FD")
        XCTAssertEqual(imperial?.key, 8)
        XCTAssertEqual(imperial?.value, 1)

        XCTAssertEqual(query?.packetHex, "F7 A6 00 00 00 00 00 A6 FD")
        XCTAssertNil(query?.key)
        XCTAssertNil(query?.value)
        XCTAssertEqual(query?.dangerousDebug, false)
        XCTAssertNil(UnitsControllerPreferencesDiagnostics.command(for: .clearState))
    }

    func testReadbackClassifiesChangedUnchangedParseFailedAndNoResponse() {
        let before = unitsState(unit: .imperial, raw: "before")
        let metricAfter = unitsState(unit: .metric, raw: "after")
        let sameAfter = unitsState(unit: .imperial, raw: "after-same")
        let failed = TreadmillUnitsState(
            nativeUnits: .unknown,
            source: .queryParams,
            parseStatus: .failedChecksum,
            readAt: Date(timeIntervalSince1970: 2),
            rawParamsHex: "bad"
        )

        XCTAssertEqual(
            UnitsControllerPreferencesDiagnostics.readbackResult(before: before, after: metricAfter),
            .changed
        )
        XCTAssertEqual(
            UnitsControllerPreferencesDiagnostics.readbackResult(before: before, after: sameAfter),
            .unchanged
        )
        XCTAssertEqual(
            UnitsControllerPreferencesDiagnostics.readbackResult(before: before, after: failed),
            .parseFailed
        )
        XCTAssertEqual(
            UnitsControllerPreferencesDiagnostics.readbackResult(before: before, after: nil),
            .noResponse
        )
    }

    func testTelemetryFieldsIncludeActionCommandReadbackAndFinishedData() {
        let before = unitsState(unit: .imperial, raw: "F8 A6 BEFORE FD")
        let after = unitsState(unit: .metric, raw: "F8 A6 AFTER FD")
        let command = UnitsControllerPreferencesDiagnostics.command(for: .setMetric)!

        let started = UnitsControllerPreferencesDiagnostics.actionStartedFields(
            action: .setMetric,
            controllerState: "running",
            currentUnitsState: before,
            connectedPeripheralID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
            connectedPeripheralName: "KS-F0"
        )
        XCTAssertEqual(started["action"] as? String, "set_metric")
        XCTAssertEqual(started["controller_state"] as? String, "running")
        XCTAssertEqual(started["current_units_state"] as? String, "imperial")
        XCTAssertEqual(started["last_query_params_raw_hex"] as? String, "F8 A6 BEFORE FD")
        XCTAssertEqual(started["connected_peripheral_name"] as? String, "KS-F0")

        let sent = UnitsControllerPreferencesDiagnostics.commandSentFields(
            action: .setMetric,
            command: command,
            purpose: "write"
        )
        XCTAssertEqual(sent["packet_hex"] as? String, "F7 A6 08 00 00 00 00 AE FD")
        XCTAssertEqual(sent["command_family"] as? String, "A6")
        XCTAssertEqual(sent["key"] as? Int, 8)
        XCTAssertEqual(sent["value"] as? Int, 0)
        XCTAssertEqual(sent["dangerous_debug"] as? Bool, true)
        XCTAssertEqual(sent["test_controller_required"] as? Bool, true)

        let readback = UnitsControllerPreferencesDiagnostics.readbackFields(
            before: before,
            after: after,
            result: .changed
        )
        XCTAssertEqual(readback["raw_params_hex"] as? String, "F8 A6 AFTER FD")
        XCTAssertEqual(readback["unit_before"] as? String, "imperial")
        XCTAssertEqual(readback["unit_after"] as? String, "metric")
        XCTAssertEqual(readback["checksum_ok"] as? Bool, true)
        XCTAssertEqual(readback["changed"] as? Bool, true)
        XCTAssertEqual(readback["result"] as? String, "changed")

        let finished = UnitsControllerPreferencesDiagnostics.actionFinishedFields(
            action: .setMetric,
            result: .changed,
            error: nil
        )
        XCTAssertEqual(finished["action"] as? String, "set_metric")
        XCTAssertEqual(finished["result"] as? String, "changed")
        XCTAssertEqual(finished["error"] as? String, "")
    }

    private func unitsState(unit: TreadmillNativeUnits, raw: String) -> TreadmillUnitsState {
        TreadmillUnitsState(
            nativeUnits: unit,
            source: .queryParams,
            parseStatus: .validChecksum,
            readAt: Date(timeIntervalSince1970: 1),
            rawParamsHex: raw
        )
    }
}
