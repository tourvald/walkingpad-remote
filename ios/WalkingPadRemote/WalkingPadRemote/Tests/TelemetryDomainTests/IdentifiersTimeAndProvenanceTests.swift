import Foundation
import TelemetryDomain
import XCTest

final class IdentifiersTimeAndProvenanceTests: XCTestCase {
    func testTypedIdentifiersKeepDomainsDistinct() throws {
        let raw = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let session = SessionID(rawValue: raw)
        let record = RecordID(rawValue: raw)

        func acceptsOnlySession(_ value: SessionID) -> UUID { value.rawValue }
        func acceptsOnlyRecord(_ value: RecordID) -> UUID { value.rawValue }

        XCTAssertEqual(acceptsOnlySession(session), raw)
        XCTAssertEqual(acceptsOnlyRecord(record), raw)
        XCTAssertEqual(session.description, raw.uuidString.lowercased())
        try assertCodableRoundTrip(session)
        try assertCodableRoundTrip(record)
    }

    func testElapsedDurationPreservesSignedMicrosecondsAndOrdersExactly() throws {
        let beforeOrigin = ElapsedDuration(microseconds: -1)
        let received = ElapsedDuration(microseconds: 1_234_567)
        let later = ElapsedDuration(microseconds: 1_234_568)

        XCTAssertLessThan(beforeOrigin, received)
        XCTAssertLessThan(received, later)
        XCTAssertEqual(received.seconds, 1.234_567, accuracy: 0.000_000_1)
        try assertCodableRoundTrip(received)
    }

    func testElapsedDurationRejectsOverflowingMillisecondConversion() {
        XCTAssertEqual(ElapsedDuration(milliseconds: 1_234)?.microseconds, 1_234_000)
        XCTAssertNil(ElapsedDuration(milliseconds: Int64.max))
        XCTAssertNil(ElapsedDuration(milliseconds: Int64.min))
    }

    func testMeasuredReceivedAndRecordedRolesRemainDistinct() throws {
        let timestamp = TelemetryDomainFixtures.observationTimestamp

        XCTAssertEqual(timestamp.effectiveElapsed, timestamp.measuredElapsed)
        XCTAssertLessThan(timestamp.measuredAt!, timestamp.receivedAt)
        XCTAssertLessThan(timestamp.receivedAt, timestamp.recordedAt)
        XCTAssertNotEqual(timestamp.receivedElapsed, timestamp.recordedElapsed)
        try assertCodableRoundTrip(timestamp)

        let receiveFallback = ObservationTimestamp(
            measuredAt: nil,
            receivedAt: TelemetryDomainFixtures.baseDate,
            recordedAt: TelemetryDomainFixtures.baseDate,
            measuredElapsed: nil,
            receivedElapsed: ElapsedDuration(microseconds: 9),
            recordedElapsed: ElapsedDuration(microseconds: 10)
        )
        XCTAssertEqual(receiveFallback.effectiveElapsed, receiveFallback.receivedElapsed)
    }

    func testQualityFlagsEncodeDeterministicallyAndRemainAdditive() throws {
        let first: QualityFlags = [.staleAtUse, .missingSource, .clockRegression]
        let second: QualityFlags = [.clockRegression, .staleAtUse, .missingSource]
        let encoder = JSONEncoder()

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.contains(.missingSource))
        XCTAssertEqual(try encoder.encode(first), try encoder.encode(second))
        try assertCodableRoundTrip(first)
    }

    func testUnknownSourceDoesNotInventPhysicalMetadata() throws {
        let unknown = SignalSourceIdentity(
            id: SourceID(),
            providerKind: .unknown,
            stableLocalKey: "unknown-provider",
            savingSource: nil,
            knownDevice: nil
        )

        XCTAssertNil(unknown.savingSource)
        XCTAssertNil(unknown.knownDevice)
        try assertCodableRoundTrip(unknown)
    }

    func testConfigurationAndVersionTypesRoundTrip() throws {
        try assertCodableRoundTrip(TelemetryDomainFixtures.versions)
        try assertCodableRoundTrip(TelemetryDomainFixtures.configuration)
        try assertCodableRoundTrip(
            AppRuntimeContext(
                appVersion: "1.0",
                buildNumber: "42",
                operatingSystemVersion: "iOS 26.0",
                deviceModel: nil
            )
        )
    }
}
