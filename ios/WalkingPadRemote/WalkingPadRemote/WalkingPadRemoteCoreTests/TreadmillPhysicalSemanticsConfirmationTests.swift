import Foundation
import XCTest
@testable import WalkingPadCoreLogic

final class TreadmillPhysicalSemanticsConfirmationTests: XCTestCase {
    private let deviceA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let deviceB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    func testConfirmationPersistsPerPeripheral() {
        let defaults = makeDefaults()
        let store = TreadmillPhysicalSemanticsConfirmationStore(defaults: defaults)
        let confirmation = makeConfirmation(peripheralId: deviceA, semantics: .confirmedImperial)

        store.save(confirmation)

        XCTAssertEqual(store.confirmation(for: deviceA), confirmation)
        XCTAssertNil(store.confirmation(for: deviceB))
    }

    func testDeviceAConfirmationDoesNotApplyToDeviceB() {
        let confirmation = makeConfirmation(peripheralId: deviceA, semantics: .confirmedImperial)
        let state = validImperialState(rawParamsHex: confirmation.fingerprint.controllerParamsRawHex)

        let resolved = TreadmillPhysicalSemanticsConfirmationResolver.resolvedUnitsState(
            state,
            confirmation: confirmation,
            currentFingerprint: makeFingerprint(peripheralId: deviceB)
        )

        XCTAssertEqual(resolved.physicalSpeedConfidence, .unknown)
    }

    func testConfirmationIgnoredWhenChecksumFailed() {
        let confirmation = makeConfirmation(peripheralId: deviceA, semantics: .confirmedImperial)
        let failedState = TreadmillUnitsState(
            nativeUnits: .imperial,
            source: .queryParams,
            parseStatus: .failedChecksum,
            readAt: Date(timeIntervalSince1970: 1),
            rawParamsHex: confirmation.fingerprint.controllerParamsRawHex
        )

        let resolved = TreadmillPhysicalSemanticsConfirmationResolver.resolvedUnitsState(
            failedState,
            confirmation: confirmation,
            currentFingerprint: confirmation.fingerprint
        )

        XCTAssertEqual(resolved.physicalSpeedConfidence, .unknown)
    }

    func testConfirmationIgnoredWhenUnitIsNotImperial() {
        let confirmation = makeConfirmation(peripheralId: deviceA, semantics: .confirmedImperial)
        let metricState = TreadmillUnitsState(
            nativeUnits: .metric,
            source: .queryParams,
            parseStatus: .validChecksum,
            readAt: Date(timeIntervalSince1970: 1),
            rawParamsHex: confirmation.fingerprint.controllerParamsRawHex
        )
        let metricFingerprint = makeFingerprint(
            peripheralId: deviceA,
            controllerUnitPref: .metric
        )

        let resolved = TreadmillPhysicalSemanticsConfirmationResolver.resolvedUnitsState(
            metricState,
            confirmation: confirmation,
            currentFingerprint: metricFingerprint
        )

        XCTAssertEqual(resolved.physicalSpeedConfidence, .unknown)
    }

    func testConfirmationIgnoredWhenParamsRawChanged() {
        let confirmation = makeConfirmation(peripheralId: deviceA, semantics: .confirmedImperial)
        let state = validImperialState(rawParamsHex: "F8 A6 CHANGED FD")
        let changedFingerprint = makeFingerprint(
            peripheralId: deviceA,
            controllerParamsRawHex: "F8 A6 CHANGED FD"
        )

        let resolved = TreadmillPhysicalSemanticsConfirmationResolver.resolvedUnitsState(
            state,
            confirmation: confirmation,
            currentFingerprint: changedFingerprint
        )

        XCTAssertEqual(resolved.physicalSpeedConfidence, .unknown)
    }

    func testConfirmedImperialUpdatesPhysicalSpeedConfidence() {
        let confirmation = makeConfirmation(peripheralId: deviceA, semantics: .confirmedImperial)
        let state = validImperialState(rawParamsHex: confirmation.fingerprint.controllerParamsRawHex)

        let resolved = TreadmillPhysicalSemanticsConfirmationResolver.resolvedUnitsState(
            state,
            confirmation: confirmation,
            currentFingerprint: confirmation.fingerprint
        )

        XCTAssertEqual(resolved.physicalSpeedConfidence, .confirmedImperial)
    }

    func testHrControlStillBlockedOnImperialEvenWhenConfirmedImperial() {
        let confirmedState = TreadmillUnitsState(
            nativeUnits: .imperial,
            source: .queryParams,
            parseStatus: .validChecksum,
            readAt: Date(timeIntervalSince1970: 1),
            rawParamsHex: "F8 A6 01 FD",
            physicalSpeedConfidence: .confirmedImperial
        )

        XCTAssertFalse(TreadmillUnitsSafetyPolicy.allowsHrControl(confirmedState))
        XCTAssertEqual(
            TreadmillUnitsSafetyPolicy.blockReason(for: confirmedState),
            .manualStopAcknowledgementRequired
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "walkingpad-confirmation-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeConfirmation(
        peripheralId: UUID,
        semantics: TreadmillPhysicalSemantics
    ) -> TreadmillPhysicalSemanticsConfirmation {
        TreadmillPhysicalSemanticsConfirmation(
            fingerprint: makeFingerprint(peripheralId: peripheralId),
            semantics: semantics,
            source: .operatorVisualConfirmation,
            confirmedAt: Date(timeIntervalSince1970: 1_800),
            diagnosticSessionId: "session-1",
            diagnosticProfile: "imperial_units_discriminator_60s",
            rawTenths: 30,
            nativeCommand: 3.0
        )
    }

    private func makeFingerprint(
        peripheralId: UUID,
        controllerParamsRawHex: String = "F8 A6 01 FD",
        controllerUnitPref: TreadmillNativeUnits = .imperial
    ) -> TreadmillPhysicalSemanticsFingerprint {
        TreadmillPhysicalSemanticsFingerprint(
            peripheralId: peripheralId,
            peripheralName: "KS-F0",
            protocolName: "WalkingPad",
            controllerParamsRawHex: controllerParamsRawHex,
            controllerUnitPref: controllerUnitPref,
            controllerParamsChecksumOk: true
        )
    }

    private func validImperialState(rawParamsHex: String) -> TreadmillUnitsState {
        TreadmillUnitsState(
            nativeUnits: .imperial,
            source: .queryParams,
            parseStatus: .validChecksum,
            readAt: Date(timeIntervalSince1970: 1),
            rawParamsHex: rawParamsHex
        )
    }
}
