import Foundation
import XCTest
@testable import WalkingPadCoreLogic

final class TreadmillUnitsSafetyPolicyTests: XCTestCase {
    func testMetricQueryParamsWithValidChecksumAllowsAutomation() {
        let state = TreadmillUnitsState(
            nativeUnits: .metric,
            source: .queryParams,
            parseStatus: .validChecksum,
            readAt: Date(timeIntervalSince1970: 1),
            rawParamsHex: "F8 A6 ... FD"
        )

        XCTAssertTrue(TreadmillUnitsSafetyPolicy.allowsHrControl(state))
        XCTAssertTrue(TreadmillUnitsSafetyPolicy.allowsDebugTestRun(state))
        XCTAssertNil(TreadmillUnitsSafetyPolicy.blockReason(for: state))
    }

    func testImperialQueryParamsBlocksAutomation() {
        let state = TreadmillUnitsState(
            nativeUnits: .imperial,
            source: .queryParams,
            parseStatus: .validChecksum,
            readAt: Date(timeIntervalSince1970: 1),
            rawParamsHex: "F8 A6 ... FD"
        )

        XCTAssertFalse(TreadmillUnitsSafetyPolicy.allowsHrControl(state))
        XCTAssertFalse(TreadmillUnitsSafetyPolicy.allowsDebugTestRun(state))
        XCTAssertEqual(TreadmillUnitsSafetyPolicy.blockReason(for: state), .imperialUnits)
    }

    func testImperialQueryParamsAllowsOnlyConfirmedNoLoadDiagnosticTestRun() {
        let state = TreadmillUnitsState(
            nativeUnits: .imperial,
            source: .queryParams,
            parseStatus: .validChecksum,
            readAt: Date(timeIntervalSince1970: 10),
            rawParamsHex: "F8 A6"
        )

        XCTAssertFalse(TreadmillUnitsSafetyPolicy.allowsHrControl(state))
        XCTAssertTrue(TreadmillUnitsSafetyPolicy.requiresNoLoadDiagnosticConfirmation(for: state))
        XCTAssertFalse(TreadmillUnitsSafetyPolicy.allowsDebugTestRun(state))
        XCTAssertTrue(TreadmillUnitsSafetyPolicy.allowsDebugTestRun(state, confirmedNoLoadDiagnostic: true))
    }

    func testConfirmedImperialRequiresSessionManualStopAcknowledgementForHrControl() {
        let state = TreadmillUnitsState(
            nativeUnits: .imperial,
            source: .queryParams,
            parseStatus: .validChecksum,
            readAt: Date(timeIntervalSince1970: 10),
            rawParamsHex: "F8 A6",
            physicalSpeedConfidence: .confirmedImperial
        )

        XCTAssertFalse(TreadmillUnitsSafetyPolicy.allowsHrControl(state))
        XCTAssertFalse(TreadmillUnitsSafetyPolicy.allowsHrControl(state, manualStopAcknowledged: false))
        XCTAssertEqual(
            TreadmillUnitsSafetyPolicy.blockReason(for: state, manualStopAcknowledged: false),
            .manualStopAcknowledgementRequired
        )
        XCTAssertTrue(TreadmillUnitsSafetyPolicy.allowsHrControl(state, manualStopAcknowledged: true))
        XCTAssertNil(TreadmillUnitsSafetyPolicy.blockReason(for: state, manualStopAcknowledged: true))
    }

    func testManualStopAcknowledgementDoesNotAllowUnconfirmedImperialHrControl() {
        let state = TreadmillUnitsState(
            nativeUnits: .imperial,
            source: .queryParams,
            parseStatus: .validChecksum,
            readAt: Date(timeIntervalSince1970: 10),
            rawParamsHex: "F8 A6",
            physicalSpeedConfidence: .unknown
        )

        XCTAssertFalse(TreadmillUnitsSafetyPolicy.allowsHrControl(state, manualStopAcknowledged: true))
        XCTAssertEqual(
            TreadmillUnitsSafetyPolicy.blockReason(for: state, manualStopAcknowledged: true),
            .imperialUnits
        )
    }

    func testUnknownOrFailedParamsBlockAutomation() {
        let notRead = TreadmillUnitsState.notRead
        let failed = TreadmillUnitsState(
            nativeUnits: .metric,
            source: .queryParams,
            parseStatus: .failedChecksum,
            readAt: Date(timeIntervalSince1970: 1),
            rawParamsHex: "F8 A6 ... FD"
        )

        XCTAssertFalse(TreadmillUnitsSafetyPolicy.allowsHrControl(notRead))
        XCTAssertFalse(TreadmillUnitsSafetyPolicy.allowsDebugTestRun(notRead))
        XCTAssertEqual(TreadmillUnitsSafetyPolicy.blockReason(for: notRead), .unitsUnknown)

        XCTAssertFalse(TreadmillUnitsSafetyPolicy.allowsHrControl(failed))
        XCTAssertFalse(TreadmillUnitsSafetyPolicy.allowsDebugTestRun(failed))
        XCTAssertEqual(TreadmillUnitsSafetyPolicy.blockReason(for: failed), .paramsInvalid)
    }
}
