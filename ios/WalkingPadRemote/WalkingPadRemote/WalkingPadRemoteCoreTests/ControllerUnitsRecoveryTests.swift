import Foundation
import XCTest
@testable import WalkingPadCoreLogic

final class ControllerUnitsRecoveryTests: XCTestCase {
    func testProductionRecoveryCommandSendsOnlyMetricPreferencePacket() {
        let metricCommand = ControllerUnitsRecovery.productionCommand(to: .metric)

        XCTAssertEqual(metricCommand?.packetHex, "F7 A6 08 00 00 00 00 AE FD")
        XCTAssertEqual(metricCommand?.targetUnits, .metric)
        XCTAssertNil(ControllerUnitsRecovery.productionCommand(to: .imperial))
        XCTAssertNil(ControllerUnitsRecovery.productionCommand(to: .unknown))
    }

    func testRecoveryConfirmationTextMatchesRequiredPersistentPreferenceWarning() {
        XCTAssertEqual(
            ControllerUnitsRecovery.confirmationText,
            """
            This writes a persistent controller preference.
            Metric mode is required because imperial mode breaks stop on this treadmill.
            Use only if you understand this changes controller units.
            """
        )
    }

    func testRecoveryRequiresExplicitOwnerApprovalAndNeverAutoSwitchesOnConnect() {
        let imperial = unitsState(unit: .imperial, raw: "F8 A6 IMPERIAL FD")

        XCTAssertTrue(ControllerUnitsRecovery.shouldOfferManualRecovery(for: imperial))
        XCTAssertFalse(ControllerUnitsRecovery.shouldAutoSwitchOnConnect(for: imperial))
    }

    func testRecoverySuccessOnlyAfterMetricReadbackWithValidChecksum() {
        let before = unitsState(unit: .imperial, raw: "F8 A6 IMPERIAL FD")
        let metricAfter = unitsState(unit: .metric, raw: "F8 A6 METRIC FD")
        let imperialAfter = unitsState(unit: .imperial, raw: "F8 A6 STILL IMPERIAL FD")
        let failedChecksumAfter = TreadmillUnitsState(
            nativeUnits: .metric,
            source: .queryParams,
            parseStatus: .failedChecksum,
            readAt: Date(timeIntervalSince1970: 2),
            rawParamsHex: "F8 A6 BAD FD"
        )

        XCTAssertEqual(
            ControllerUnitsRecovery.readbackResult(before: before, after: metricAfter),
            .success
        )
        XCTAssertEqual(
            ControllerUnitsRecovery.readbackResult(before: metricAfter, after: metricAfter),
            .unchanged
        )
        XCTAssertEqual(
            ControllerUnitsRecovery.readbackResult(before: before, after: imperialAfter),
            .failed
        )
        XCTAssertEqual(
            ControllerUnitsRecovery.readbackResult(before: before, after: failedChecksumAfter),
            .parseFailed
        )
        XCTAssertEqual(
            ControllerUnitsRecovery.readbackResult(before: before, after: nil),
            .noResponse
        )
    }

    func testTelemetryFieldsExposeUnitsReadbackResultAndStopSafetyTransition() {
        let before = unitsState(unit: .imperial, raw: "F8 A6 IMPERIAL FD")
        let after = unitsState(unit: .metric, raw: "F8 A6 METRIC FD")

        let fields = ControllerUnitsRecovery.readbackFields(
            before: before,
            after: after,
            result: .success
        )

        XCTAssertEqual(fields["unit_before"] as? String, "imperial")
        XCTAssertEqual(fields["unit_after"] as? String, "metric")
        XCTAssertEqual(fields["raw_params_hex"] as? String, "F8 A6 METRIC FD")
        XCTAssertEqual(fields["result"] as? String, "success")
        XCTAssertEqual(fields["stop_safety_before"] as? String, "broken_imperial_units")
        XCTAssertEqual(fields["stop_safety_after"] as? String, "ready")
        XCTAssertEqual(fields["checksum_ok"] as? Bool, true)
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
