import Foundation
import SwiftData
import TelemetryDomain
@testable import TelemetryPersistence
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

        let protectedFiles = try TelemetryStoreFilePolicy.discoveredStoreFiles(
            primaryStoreURL: storeURL
        )
        XCTAssertTrue(
            protectedFiles.map { $0.resolvingSymlinksInPath().path }
                .contains(storeURL.resolvingSymlinksInPath().path),
            "Expected primary store at \(storeURL.path); discovered \(protectedFiles.map(\.path))"
        )
        for url in protectedFiles {
            let resourceValues = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(resourceValues.isExcludedFromBackup, true)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertNotNil(attributes[.protectionKey])
        }

        var resetValues = URLResourceValues()
        resetValues.isExcludedFromBackup = false
        var mutableStoreURL = storeURL
        try mutableStoreURL.setResourceValues(resetValues)
        try await writer?.insertEvent(
            TelemetryPersistenceFixtures.event(
                seed: 8,
                session: session,
                kind: .sessionLifecycle,
                elapsed: 2_000_000
            )
        )
        XCTAssertEqual(
            try storeURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
            true
        )
        writer = nil

        let reader = try TelemetryStoreFactory.make(.onDisk(storeURL))
        let sessions = try await reader.fetchSessions()
        let heartRates = try await reader.fetchHeartRate(sessionID: session.sessionID)
        let sources = try await reader.fetchSources()
        XCTAssertEqual(sessions, [session])
        XCTAssertEqual(heartRates, [heartRate])
        XCTAssertEqual(sources.map(\.identity), [source])
    }

    func testCorruptPersistedRelationshipFailsClosed() async throws {
        let schema = Schema(versionedSchema: TelemetrySchemaV1.self)
        let configuration = ModelConfiguration(
            "TelemetryCorruptionTest",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: schema,
            migrationPlan: TelemetryMigrationPlan.self,
            configurations: [configuration]
        )
        let writer = TelemetryStore(modelContainer: container, onDiskStoreURL: nil)
        let session = TelemetryPersistenceFixtures.session(seed: 10)
        let source = TelemetryPersistenceFixtures.source(seed: 10)
        let heartRate = TelemetryPersistenceFixtures.heartRate(
            seed: 10,
            session: session,
            source: source,
            arrivalOrder: 1,
            bpm: 122
        )
        let treadmill = TelemetryPersistenceFixtures.treadmill(
            seed: 10,
            session: session,
            source: source,
            arrivalOrder: 1,
            unit: .kilometresPerHour
        )
        let event = TelemetryPersistenceFixtures.event(
            seed: 10,
            session: session,
            kind: .sessionLifecycle,
            elapsed: 2_000_000,
            sourceID: source.id
        )
        let frame = TelemetryPersistenceFixtures.frame(
            seed: 10,
            session: session,
            elapsedSecond: 2,
            heartRate: heartRate
        )
        let analysis = TelemetryPersistenceFixtures.analysis(
            seed: 10,
            session: session,
            version: "analysis-v1"
        )
        try await writer.insertSession(session)
        try await writer.insertSource(
            source,
            firstSeen: TelemetryPersistenceFixtures.baseDate,
            lastSeen: TelemetryPersistenceFixtures.baseDate
        )
        try await writer.insertHeartRate(heartRate)
        try await writer.insertTreadmill(treadmill)
        try await writer.insertEvent(event)
        try await writer.insertFrame(frame)
        try await writer.insertAnalysis(analysis)

        let corruptingContext = ModelContext(container)
        try XCTUnwrap(
            corruptingContext.fetch(FetchDescriptor<TelemetryHeartRateSampleV1>()).first
        ).session = nil
        try XCTUnwrap(
            corruptingContext.fetch(FetchDescriptor<TelemetryTreadmillSampleV1>()).first
        ).source = nil
        try XCTUnwrap(
            corruptingContext.fetch(FetchDescriptor<TelemetryWorkoutEventV1>()).first
        ).source = nil
        try XCTUnwrap(
            corruptingContext.fetch(FetchDescriptor<TelemetryWorkoutFrameV1>()).first
        ).session = nil
        try XCTUnwrap(
            corruptingContext.fetch(FetchDescriptor<TelemetryWorkoutAnalysisV1>()).first
        ).session = nil
        try corruptingContext.save()

        let reader = TelemetryStore(modelContainer: container, onDiskStoreURL: nil)
        do {
            _ = try await reader.fetchHeartRate(sessionID: session.sessionID)
            XCTFail("Expected corrupt heart-rate relationship failure")
        } catch {
            XCTAssertEqual(
                error as? TelemetryStoreError,
                .corruptStoredRecord(heartRate.observationID.description)
            )
        }
        do {
            _ = try await reader.fetchTreadmill(sessionID: session.sessionID)
            XCTFail("Expected corrupt treadmill relationship failure")
        } catch {
            XCTAssertEqual(
                error as? TelemetryStoreError,
                .corruptStoredRecord(treadmill.observationID.description)
            )
        }
        do {
            _ = try await reader.fetchEvents(sessionID: session.sessionID)
            XCTFail("Expected corrupt event relationship failure")
        } catch {
            XCTAssertEqual(
                error as? TelemetryStoreError,
                .corruptStoredRecord(event.recordID.description)
            )
        }
        do {
            _ = try await reader.fetchFrames(sessionID: session.sessionID)
            XCTFail("Expected corrupt frame relationship failure")
        } catch {
            XCTAssertEqual(
                error as? TelemetryStoreError,
                .corruptStoredRecord(frame.recordID.description)
            )
        }
        do {
            _ = try await reader.fetchAnalyses(sessionID: session.sessionID)
            XCTFail("Expected corrupt analysis relationship failure")
        } catch {
            XCTAssertEqual(
                error as? TelemetryStoreError,
                .corruptStoredRecord(analysis.analysisID.description)
            )
        }
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
