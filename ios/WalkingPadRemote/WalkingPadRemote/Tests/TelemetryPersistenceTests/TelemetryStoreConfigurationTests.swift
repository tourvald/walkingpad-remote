import Foundation
import TelemetryDomain
import TelemetryPersistence
import XCTest

final class TelemetryStoreConfigurationTests: XCTestCase {
    func testInMemoryStoresAreIsolated() async throws {
        let first = try TelemetryStoreFactory.make(.inMemory)
        let second = try TelemetryStoreFactory.make(.inMemory)
        let session = TelemetryPersistenceFixtures.session(seed: 7)

        try await first.insertSession(session)

        let firstSessions = try await first.fetchSessions()
        let secondSessions = try await second.fetchSessions()
        XCTAssertEqual(firstSessions, [session])
        XCTAssertTrue(secondSessions.isEmpty)
    }

    func testOnDiskStoreReopensWithEquivalentEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("telemetry-reopen-\(UUID().uuidString)", isDirectory: true)
        let storeURL = directory.appendingPathComponent("TelemetryV2.store")
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = TelemetryPersistenceFixtures.session(seed: 8)
        let source = TelemetryPersistenceFixtures.source(seed: 8, kind: .unknown)
        let heartRate = TelemetryPersistenceFixtures.heartRate(
            seed: 8,
            session: session,
            source: source,
            arrivalOrder: 1,
            bpm: 119
        )

        var writer: TelemetryStore? = try TelemetryStoreFactory.make(.onDisk(storeURL))
        try await writer?.insertSession(session)
        try await writer?.insertSource(
            source,
            firstSeen: TelemetryPersistenceFixtures.baseDate,
            lastSeen: TelemetryPersistenceFixtures.baseDate
        )
        try await writer?.insertHeartRate(heartRate)
        writer = nil

        let reader = try TelemetryStoreFactory.make(.onDisk(storeURL))
        let sessions = try await reader.fetchSessions()
        let heartRates = try await reader.fetchHeartRate(sessionID: session.sessionID)
        let sources = try await reader.fetchSources()
        XCTAssertEqual(sessions, [session])
        XCTAssertEqual(heartRates, [heartRate])
        XCTAssertEqual(sources.map(\.identity), [source])
    }

    func testMissingRelationshipsFailWithoutCreatingFallbackRecords() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let session = TelemetryPersistenceFixtures.session(seed: 9)
        let source = TelemetryPersistenceFixtures.source(seed: 9)
        let observation = TelemetryPersistenceFixtures.heartRate(
            seed: 9,
            session: session,
            source: source,
            arrivalOrder: 1,
            bpm: 118
        )

        do {
            try await store.insertHeartRate(observation)
            XCTFail("Expected missing-session failure")
        } catch {
            XCTAssertEqual(error as? TelemetryStoreError, .missingSession(session.sessionID))
        }
        let missingSessionCounts = try await store.counts()
        XCTAssertEqual(missingSessionCounts.heartRateSamples, 0)

        try await store.insertSession(session)
        do {
            try await store.insertHeartRate(observation)
            XCTFail("Expected missing-source failure")
        } catch {
            XCTAssertEqual(error as? TelemetryStoreError, .missingSource(source.id))
        }
        let counts = try await store.counts()
        XCTAssertEqual(counts.heartRateSamples, 0)
        XCTAssertEqual(counts.sources, 0)
    }
}
