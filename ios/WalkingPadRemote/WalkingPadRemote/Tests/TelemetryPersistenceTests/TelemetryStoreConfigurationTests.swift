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

        let protectedFiles = try assertRequiredFilePolicy(
            primaryStoreURL: storeURL,
            phase: "initial writes"
        )
        for url in protectedFiles {
            var resetValues = URLResourceValues()
            resetValues.isExcludedFromBackup = false
            var mutableURL = url
            try mutableURL.setResourceValues(resetValues)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.none],
                ofItemAtPath: url.path
            )
        }
        _ = try TelemetryStoreFilePolicy.applyRequiredAttributes(
            primaryStoreURL: storeURL
        )
        _ = try assertRequiredFilePolicy(
            primaryStoreURL: storeURL,
            phase: "explicit reapplication after file-attribute mutation"
        )

        try await writer?.insertEvent(
            TelemetryPersistenceFixtures.event(
                seed: 8,
                session: session,
                kind: .sessionLifecycle,
                elapsed: 2_000_000
            )
        )
        _ = try assertRequiredFilePolicy(
            primaryStoreURL: storeURL,
            phase: "automatic policy after subsequent write"
        )
        writer = nil

        let reader = try TelemetryStoreFactory.make(.onDisk(storeURL))
        _ = try assertRequiredFilePolicy(
            primaryStoreURL: storeURL,
            phase: "reopen"
        )
        let sessions = try await reader.fetchSessions()
        let heartRates = try await reader.fetchHeartRate(sessionID: session.sessionID)
        let sources = try await reader.fetchSources()
        XCTAssertEqual(sessions, [session])
        XCTAssertEqual(heartRates, [heartRate])
        XCTAssertEqual(sources.map(\.identity), [source])
    }

    func testStableNativeHeartRateIdentityRemainsDeduplicatedAfterReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("telemetry-native-id-\(UUID().uuidString)", isDirectory: true)
        let storeURL = directory.appendingPathComponent("TelemetryV2.store")
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = TelemetryPersistenceFixtures.session(seed: 17)
        let source = TelemetryPersistenceFixtures.source(seed: 17)
        let nativeIdentity = try XCTUnwrap(
            ProviderNativeSampleIdentity(identifier: "native-reopen-sample")
        )
        let first = TelemetryPersistenceFixtures.heartRate(
            seed: 17,
            session: session,
            source: source,
            arrivalOrder: 1,
            bpm: 119,
            providerSampleIdentity: nativeIdentity
        )
        let redelivery = TelemetryPersistenceFixtures.heartRate(
            seed: 18,
            session: session,
            source: source,
            arrivalOrder: 2,
            bpm: 119,
            providerSampleIdentity: nativeIdentity
        )

        var writer: TelemetryStore? = try TelemetryStoreFactory.make(.onDisk(storeURL))
        try await writer?.insertSession(session)
        try await writer?.insertSource(
            source,
            firstSeen: TelemetryPersistenceFixtures.baseDate,
            lastSeen: TelemetryPersistenceFixtures.baseDate
        )
        try await writer?.insertHeartRate(first)
        writer = nil

        let reopened = try TelemetryStoreFactory.make(.onDisk(storeURL))
        do {
            try await reopened.insertHeartRate(redelivery)
            XCTFail("Expected stable native identity rejection after reopen")
        } catch {
            guard case TelemetryStoreError.duplicateStableIdentity = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let stored = try await reopened.fetchHeartRate(sessionID: session.sessionID)
        XCTAssertEqual(stored, [first])
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

    func testContradictoryPersistedEventCausalProjectionFailsClosed() async throws {
        let schema = Schema(versionedSchema: TelemetrySchemaV1.self)
        let configuration = ModelConfiguration(
            "TelemetryCausalCorruptionTest",
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
        let session = TelemetryPersistenceFixtures.session(seed: 20)
        let decisionID = DecisionID()
        let commandID = CommandID()
        let previousAttemptID = CommandAttemptID()
        let nextAttemptID = CommandAttemptID()
        let event = WorkoutEvent(
            recordID: RecordID(),
            sessionID: session.sessionID,
            timestamp: EventTimestamp(
                occurredAt: TelemetryPersistenceFixtures.baseDate,
                recordedAt: TelemetryPersistenceFixtures.baseDate.addingTimeInterval(0.01),
                occurredElapsed: ElapsedDuration(microseconds: 1_000_000),
                recordedElapsed: ElapsedDuration(microseconds: 1_010_000)
            ),
            payload: EventPayloadEnvelope(
                schemaVersion: 1,
                payload: .commandLifecycle(CommandLifecycleRecord(
                    commandID: commandID,
                    decisionID: decisionID,
                    lifecycle: .retryScheduled(
                        previousAttemptID: previousAttemptID,
                        nextAttemptID: nextAttemptID,
                        nextAttemptNumber: 2
                    )
                ))
            )
        )
        try await writer.insertSession(session)
        try await writer.insertEvent(event)

        let corruptingContext = ModelContext(container)
        let model = try XCTUnwrap(
            corruptingContext.fetch(FetchDescriptor<TelemetryWorkoutEventV1>()).first
        )

        model.decisionID = nil
        try corruptingContext.save()
        await assertCorruptEventRead(
            container: container,
            sessionID: session.sessionID,
            recordID: event.recordID
        )

        model.decisionID = decisionID.description
        model.commandID = CommandID().description
        try corruptingContext.save()
        await assertCorruptEventRead(
            container: container,
            sessionID: session.sessionID,
            recordID: event.recordID
        )

        model.commandID = commandID.description
        model.attemptID = previousAttemptID.description
        try corruptingContext.save()
        await assertCorruptEventRead(
            container: container,
            sessionID: session.sessionID,
            recordID: event.recordID
        )

        model.attemptID = nextAttemptID.description
        try corruptingContext.save()
        let validReader = TelemetryStore(modelContainer: container, onDiskStoreURL: nil)
        let stored = try await validReader.fetchEvents(sessionID: session.sessionID)
        XCTAssertEqual(stored, [event])
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

    private func assertCorruptEventRead(
        container: ModelContainer,
        sessionID: SessionID,
        recordID: RecordID
    ) async {
        let reader = TelemetryStore(modelContainer: container, onDiskStoreURL: nil)
        do {
            _ = try await reader.fetchEvents(sessionID: sessionID)
            XCTFail("Expected contradictory causal projection failure")
        } catch {
            XCTAssertEqual(
                error as? TelemetryStoreError,
                .corruptStoredRecord(recordID.description)
            )
        }
    }

    private func assertRequiredFilePolicy(
        primaryStoreURL: URL,
        phase: String
    ) throws -> [URL] {
        let discovered = try TelemetryStoreFilePolicy.discoveredStoreFiles(
            primaryStoreURL: primaryStoreURL
        )
        let primaryName = primaryStoreURL.lastPathComponent
        let requiredNames: Set<String> = [
            primaryName,
            primaryName + "-shm",
            primaryName + "-wal",
        ]
        let discoveredNames = Set(discovered.map(\.lastPathComponent))
        XCTAssertTrue(
            requiredNames.isSubset(of: discoveredNames),
            "\(phase): expected primary, SHM, and WAL files; discovered \(discoveredNames.sorted())"
        )

        for url in discovered {
            let resourceValues = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(
                resourceValues.isExcludedFromBackup,
                true,
                "\(phase): \(url.lastPathComponent)"
            )
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(
                attributes[.protectionKey] as? FileProtectionType,
                .completeUntilFirstUserAuthentication,
                "\(phase): \(url.lastPathComponent)"
            )
        }
        return discovered
    }
}
