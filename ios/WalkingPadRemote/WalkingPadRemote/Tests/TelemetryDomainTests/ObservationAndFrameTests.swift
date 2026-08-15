import Foundation
import TelemetryDomain
import XCTest

final class ObservationAndFrameTests: XCTestCase {
    func testHeartRateCarriesArrivalQualityAndActualControlUse() throws {
        let observation = TelemetryDomainFixtures.heartRate

        XCTAssertEqual(observation.arrivalOrder, 7)
        XCTAssertTrue(observation.quality.contains(.measurementOutOfArrivalOrder))
        XCTAssertTrue(observation.controlUse.acceptedForControl)
        XCTAssertTrue(observation.controlUse.usedForControl)
        try assertCodableRoundTrip(observation)
    }

    func testMissingFactualSpeedStaysUnavailableForUnknownNativeUnit() throws {
        let native = NativeTreadmillSpeed(value: 8, unit: .unknown)
        let factual = FactualSpeedKilometresPerHour.normalized(
            from: native,
            provenance: .reportedByProvider
        )
        let observation = makeTreadmill(native: native)

        XCTAssertNil(factual)
        XCTAssertNil(observation.factualSpeed)
        try assertCodableRoundTrip(observation)
    }

    func testKnownNativeUnitProducesExplicitFactualConversion() {
        let metric = FactualSpeedKilometresPerHour.normalized(
            from: NativeTreadmillSpeed(value: 6.2, unit: .kilometresPerHour),
            provenance: .decodedDeviceReport
        )
        let imperial = FactualSpeedKilometresPerHour.normalized(
            from: NativeTreadmillSpeed(value: 4, unit: .milesPerHour),
            provenance: .reportedByProvider
        )

        XCTAssertEqual(metric?.value, 6.2)
        XCTAssertEqual(imperial?.value ?? 0, 6.437_376, accuracy: 0.000_001)
    }

    func testFactualSpeedDecodingRejectsInvalidValue() throws {
        let invalid = Data(
            #"{"value":-1,"provenance":"decodedDeviceReport"}"#.utf8
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(FactualSpeedKilometresPerHour.self, from: invalid)
        )
    }

    func testDesiredCommandedAndEstimatedSpeedRemainSeparateTypes() throws {
        let desired = DesiredSpeedKilometresPerHour(value: 5.5)
        let commanded = CommandedSpeed(nativeValue: 55, nativeUnit: .controllerNative(code: "tenths"))
        let estimated = EstimatedSpeedKilometresPerHour(
            value: 5.4,
            method: "last-command",
            version: "1"
        )

        XCTAssertNil(
            FactualSpeedKilometresPerHour.normalized(
                from: NativeTreadmillSpeed(value: commanded.nativeValue, unit: commanded.nativeUnit),
                provenance: .reportedByProvider
            )
        )
        try assertCodableRoundTrip(desired)
        try assertCodableRoundTrip(commanded)
        try assertCodableRoundTrip(estimated)
    }

    func testCanonicalFrameReferencesEvidenceWithoutCreatingObservation() throws {
        let observation = TelemetryDomainFixtures.heartRate
        let evidence = HeartRateFrameEvidence(
            observationID: observation.observationID,
            recordID: observation.recordID,
            sourceID: observation.source.id,
            beatsPerMinute: observation.beatsPerMinute,
            measuredAt: observation.timestamp.measuredAt,
            receivedAt: observation.timestamp.receivedAt,
            evidenceElapsed: observation.timestamp.effectiveElapsed,
            ageAtMaterialization: ElapsedDuration(microseconds: 790_000),
            freshness: .fresh,
            provenance: observation.provenance
        )
        let frame = CanonicalFrame(
            frameID: FrameID(),
            recordID: RecordID(),
            sessionID: observation.sessionID,
            canonicalElapsedSecond: 2,
            materializedAt: RecordTimestamp(
                recordedAt: TelemetryDomainFixtures.baseDate.addingTimeInterval(2),
                elapsed: ElapsedDuration(microseconds: 2_000_000)
            ),
            heartRateEvidence: evidence,
            treadmillEvidence: nil,
            precedingGap: CanonicalGapBoundary(
                missingSinceElapsedSecond: 0,
                kind: .runtimeSuspensionOrStall
            )
        )

        XCTAssertEqual(frame.heartRateEvidence?.observationID, observation.observationID)
        XCTAssertEqual(frame.heartRateEvidence?.receivedAt, observation.timestamp.receivedAt)
        XCTAssertEqual(frame.precedingGap?.missingSinceElapsedSecond, 0)
        XCTAssertEqual(frame.canonicalElapsedSecond, 2)
        try assertCodableRoundTrip(frame)
    }

    private func makeTreadmill(native: NativeTreadmillSpeed) -> TreadmillObservation {
        TreadmillObservation(
            recordID: RecordID(),
            observationID: ObservationID(),
            sessionID: TelemetryDomainFixtures.sessionID,
            source: SignalSourceIdentity(
                id: SourceID(),
                providerKind: .treadmillProtocol,
                stableLocalKey: "test-treadmill"
            ),
            nativeSpeed: native,
            deviceState: .unknown,
            arrivalOrder: 1,
            timestamp: TelemetryDomainFixtures.observationTimestamp,
            provenance: .reportedByProvider,
            freshness: TelemetryDomainFixtures.freshness,
            quality: []
        )
    }
}
