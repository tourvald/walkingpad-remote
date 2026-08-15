import Foundation
import TelemetryDomain
import TelemetryPersistence
import TelemetryRecorder
import XCTest

final class TelemetryRecorderPersistenceAdapterTests: XCTestCase {
    func testRecorderBatchUsesOneOrderedStoreBoundary() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let session = runningSession(seed: 1)
        let source = TelemetryPersistenceFixtures.source(seed: 2)
        let heartRate = TelemetryPersistenceFixtures.heartRate(
            seed: 3,
            session: session,
            source: source,
            arrivalOrder: 1,
            bpm: 121
        )
        let event = TelemetryPersistenceFixtures.event(
            seed: 4,
            session: session,
            kind: .manualStop,
            elapsed: 2_000_000
        )
        try await store.beginSession(session)

        try await store.persistBatch([
            SequencedTelemetryRecord(
                recorderSequence: 1,
                record: .source(
                    TelemetrySourceRecord(
                        identity: source,
                        firstSeen: TelemetryPersistenceFixtures.baseDate,
                        lastSeen: TelemetryPersistenceFixtures.baseDate
                    )
                )
            ),
            SequencedTelemetryRecord(recorderSequence: 2, record: .heartRate(heartRate)),
            SequencedTelemetryRecord(recorderSequence: 3, record: .event(event)),
        ])

        let storedSources = try await store.fetchSources().map(\.identity)
        let storedHeartRate = try await store.fetchHeartRate(sessionID: session.sessionID)
        let storedEvents = try await store.fetchEvents(sessionID: session.sessionID)
        XCTAssertEqual(storedSources, [source])
        XCTAssertEqual(storedHeartRate, [heartRate])
        XCTAssertEqual(storedEvents, [event])
    }

    func testRecorderBatchRejectsNonMonotonicSequenceBeforeWriting() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let session = runningSession(seed: 5)
        let source = TelemetryPersistenceFixtures.source(seed: 6)
        try await store.beginSession(session)

        do {
            try await store.persistBatch([
                SequencedTelemetryRecord(
                    recorderSequence: 2,
                    record: .source(
                        TelemetrySourceRecord(
                            identity: source,
                            firstSeen: TelemetryPersistenceFixtures.baseDate,
                            lastSeen: TelemetryPersistenceFixtures.baseDate
                        )
                    )
                ),
                SequencedTelemetryRecord(
                    recorderSequence: 1,
                    record: .event(
                        TelemetryPersistenceFixtures.event(
                            seed: 7,
                            session: session,
                            kind: .manualStop,
                            elapsed: 1
                        )
                    )
                ),
            ])
            XCTFail("Expected a non-monotonic recorder batch to fail.")
        } catch let error as TelemetryPersistenceOperationError {
            XCTAssertEqual(
                error,
                .commitOutcomeUnknown(code: "swiftdata-batch")
            )
        }
        let storedSources = try await store.fetchSources()
        let storedEvents = try await store.fetchEvents(sessionID: session.sessionID)
        XCTAssertTrue(storedSources.isEmpty)
        XCTAssertTrue(storedEvents.isEmpty)
    }

    func testUnfinishedDiscoveryAndFinalizationPersistIncompleteState() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let session = runningSession(seed: 8)
        try await store.beginSession(session)

        let unfinished = try await store.unfinishedSessions().map(\.sessionID)
        XCTAssertEqual(unfinished, [session.sessionID])
        let finalization = TelemetrySessionFinalization(
            sessionID: session.sessionID,
            lifecycleState: .incomplete,
            endedAt: nil,
            endedElapsed: nil,
            incompleteReason: "test-recovery",
            recorderHealth: RecorderHealthSummary(
                isComplete: false,
                lostCriticalRecordCount: 1,
                lostNativeRecordCount: 2,
                lastPersistedElapsed: ElapsedDuration(microseconds: 3)
            )
        )
        try await store.finalizeSession(finalization)

        let storedSessions = try await store.fetchSessions()
        let reopened = try XCTUnwrap(storedSessions.first { $0.sessionID == session.sessionID })
        XCTAssertEqual(reopened.lifecycleState, .incomplete)
        XCTAssertNil(reopened.endedAt)
        XCTAssertNil(reopened.endedElapsed)
        XCTAssertEqual(reopened.incompleteReason, "test-recovery")
        XCTAssertEqual(reopened.recorderHealth, finalization.recorderHealth)
    }

    private func runningSession(seed: UInt8) -> WorkoutSessionRecord {
        let base = TelemetryPersistenceFixtures.session(seed: seed)
        return WorkoutSessionRecord(
            recordID: base.recordID,
            sessionID: base.sessionID,
            profileLocalIdentifier: base.profileLocalIdentifier,
            lifecycleState: .running,
            workoutMode: base.workoutMode,
            startedAt: base.startedAt,
            endedAt: nil,
            endedElapsed: nil,
            incompleteReason: nil,
            appContext: base.appContext,
            versions: base.versions,
            configuration: base.configuration,
            healthKitWorkoutIdentifier: base.healthKitWorkoutIdentifier,
            treadmill: base.treadmill,
            recorderHealth: RecorderHealthSummary(
                isComplete: false,
                lostCriticalRecordCount: 0,
                lostNativeRecordCount: 0,
                lastPersistedElapsed: nil
            )
        )
    }
}
