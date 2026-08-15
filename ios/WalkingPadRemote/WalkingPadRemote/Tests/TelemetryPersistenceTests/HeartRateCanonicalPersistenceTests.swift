import Foundation
import TelemetryDomain
import TelemetryPersistence
import XCTest

final class HeartRateCanonicalPersistenceTests: XCTestCase {
    func testReopenRestoresCanonicalTargetForLaterNativeRedelivery() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("telemetry-hr-canonical-\(UUID().uuidString)")
        let storeURL = directory.appendingPathComponent("TelemetryV2.store")
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceIdentity = HeartRateProviderIdentity(
            kind: .healthKitSelected,
            stableLocalKey: "future-provider-source"
        )
        let nativeIdentity = try XCTUnwrap(
            HeartRateProviderNativeSampleIdentity(identifier: "future-native-sample")
        )
        let canonicalID = HeartRateCanonicalObservationID()
        var normalizer = HeartRateObservationNormalizer()
        let first = normalizer.normalize(
            providerObservation(
                source: sourceIdentity,
                nativeIdentity: nativeIdentity,
                sequence: 1
            ),
            canonicalObservationID: canonicalID,
            deliveryID: HeartRateDeliveryID(),
            recordedAt: TelemetryPersistenceFixtures.baseDate
        )

        let session = TelemetryPersistenceFixtures.session(seed: 28)
        let sourceFixture = TelemetryPersistenceFixtures.source(
            seed: 28,
            kind: .healthKitSelected
        )
        let storedSource = SignalSourceIdentity(
            id: sourceFixture.id,
            providerKind: sourceFixture.providerKind,
            stableLocalKey: sourceIdentity.stableLocalKey,
            savingSource: sourceFixture.savingSource,
            knownDevice: sourceFixture.knownDevice
        )
        let domainNativeIdentity = try XCTUnwrap(
            ProviderNativeSampleIdentity(identifier: nativeIdentity.identifier)
        )
        let beatsPerMinute = try XCTUnwrap(UInt16(exactly: first.delivery.beatsPerMinute))
        let observationFixture = TelemetryPersistenceFixtures.heartRate(
            seed: 28,
            session: session,
            source: storedSource,
            arrivalOrder: first.delivery.arrivalOrder,
            bpm: beatsPerMinute,
            providerSampleIdentity: domainNativeIdentity
        )
        let scientificObservation = HeartRateObservation(
            recordID: observationFixture.recordID,
            observationID: ObservationID(rawValue: canonicalID.rawValue),
            sessionID: observationFixture.sessionID,
            source: observationFixture.source,
            beatsPerMinute: observationFixture.beatsPerMinute,
            arrivalOrder: observationFixture.arrivalOrder,
            providerSequence: observationFixture.providerSequence,
            providerSampleIdentity: observationFixture.providerSampleIdentity,
            timestamp: observationFixture.timestamp,
            provenance: observationFixture.provenance,
            freshness: observationFixture.freshness,
            quality: observationFixture.quality,
            controlUse: observationFixture.controlUse
        )

        var writer: TelemetryStore? = try TelemetryStoreFactory.make(.onDisk(storeURL))
        try await writer?.insertSession(session)
        try await writer?.insertSource(
            storedSource,
            firstSeen: TelemetryPersistenceFixtures.baseDate,
            lastSeen: TelemetryPersistenceFixtures.baseDate
        )
        try await writer?.insertHeartRate(scientificObservation)
        writer = nil

        let reopened = try TelemetryStoreFactory.make(.onDisk(storeURL))
        let persisted = try await reopened.fetchHeartRate(sessionID: session.sessionID)
        let persistedObservation = try XCTUnwrap(persisted.first)
        let restoredBinding = HeartRateCanonicalBinding(
            source: sourceIdentity,
            providerNativeIdentity: nativeIdentity,
            canonicalObservationID: HeartRateCanonicalObservationID(
                rawValue: persistedObservation.observationID.rawValue
            )
        )
        var restoredNormalizer = HeartRateObservationNormalizer(
            restoredCanonicalBindings: [restoredBinding]
        )
        let redelivery = restoredNormalizer.normalize(
            providerObservation(
                source: sourceIdentity,
                nativeIdentity: nativeIdentity,
                sequence: 2
            ),
            canonicalObservationID: HeartRateCanonicalObservationID(),
            deliveryID: HeartRateDeliveryID(),
            recordedAt: TelemetryPersistenceFixtures.baseDate.addingTimeInterval(1)
        )

        XCTAssertNil(redelivery.canonicalObservation)
        XCTAssertEqual(
            redelivery.delivery.canonicalObservationID.rawValue,
            persistedObservation.observationID.rawValue
        )
        XCTAssertTrue(redelivery.delivery.quality.contains(.duplicateProviderIdentity))
    }

    private func providerObservation(
        source: HeartRateProviderIdentity,
        nativeIdentity: HeartRateProviderNativeSampleIdentity,
        sequence: Int64
    ) -> HeartRateProviderObservation {
        HeartRateProviderObservation(
            source: source,
            beatsPerMinute: 120,
            providerSequence: sequence,
            providerNativeIdentity: nativeIdentity,
            measuredAt: nil,
            sourceCallbackObservedAt: TelemetryPersistenceFixtures.baseDate,
            sourceClockRelationship: .receiverComparable,
            receivedAt: TelemetryPersistenceFixtures.baseDate,
            metadataQuality: []
        )
    }
}
