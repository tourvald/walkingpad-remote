import Foundation
import TelemetryDomain
import XCTest

enum TelemetryDomainFixtures {
    static let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
    static let sessionID = SessionID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    static let sourceID = SourceID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    static let observationID = ObservationID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
    static let recordID = RecordID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)
    static let configurationID = ConfigurationSnapshotID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
    )

    static let versions = RuntimeVersionContext(
        telemetrySchema: TelemetrySchemaVersion(rawValue: "2.0"),
        algorithm: AlgorithmVersion(rawValue: "algorithm-v1"),
        safetyPolicy: SafetyPolicyVersion(rawValue: "safety-v1"),
        workoutProtocol: WorkoutProtocolVersion(rawValue: "workout-v1")
    )

    static let source = SignalSourceIdentity(
        id: sourceID,
        providerKind: .healthKitSelected,
        stableLocalKey: "healthkit-selected",
        savingSource: ProviderSavingSource(bundleIdentifier: "test.provider"),
        knownDevice: nil
    )

    static let observationTimestamp = ObservationTimestamp(
        measuredAt: baseDate,
        receivedAt: baseDate.addingTimeInterval(0.2),
        recordedAt: baseDate.addingTimeInterval(0.21),
        measuredElapsed: ElapsedDuration(microseconds: 1_000_000),
        receivedElapsed: ElapsedDuration(microseconds: 1_200_000),
        recordedElapsed: ElapsedDuration(microseconds: 1_210_000)
    )

    static let freshness = EvidenceFreshness(
        state: .fresh,
        evaluatedAt: RecordTimestamp(
            recordedAt: baseDate.addingTimeInterval(0.21),
            elapsed: ElapsedDuration(microseconds: 1_210_000)
        ),
        age: ElapsedDuration(microseconds: 210_000),
        policyVersion: versions.safetyPolicy
    )

    static let configuration = ImmutableConfigurationSnapshot(
        id: configurationID,
        formatVersion: 1,
        format: .canonicalJSON,
        canonicalPayload: Data(#"{"mode":"test"}"#.utf8),
        contentHash: ContentHash(
            algorithm: .sha256,
            lowercaseHexDigest: String(repeating: "a", count: 64)
        )
    )

    static let heartRate = HeartRateObservation(
        recordID: recordID,
        observationID: observationID,
        sessionID: sessionID,
        source: source,
        beatsPerMinute: 123,
        arrivalOrder: 7,
        providerSequence: 44,
        providerSampleIdentity: ProviderNativeSampleIdentity(identifier: "provider-sample-44"),
        timestamp: observationTimestamp,
        provenance: .reportedByProvider,
        freshness: freshness,
        quality: [.measurementOutOfArrivalOrder, .unknownFreshness],
        controlUse: .acceptedAndUsed
    )
}

extension XCTestCase {
    func assertCodableRoundTrip<T: Codable & Equatable>(
        _ value: T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        let decoded = try JSONDecoder().decode(T.self, from: data)
        XCTAssertEqual(decoded, value, file: file, line: line)
    }
}
