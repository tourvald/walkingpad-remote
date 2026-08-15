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
        let unfinishedAfterFinalization = try await store.unfinishedSessions()
        XCTAssertTrue(unfinishedAfterFinalization.isEmpty)
    }

    func testCancelledSessionIsTerminalAndExcludedFromRecoveryDiscovery() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let session = runningSession(seed: 9)
        try await store.beginSession(session)

        try await store.finalizeSession(
            TelemetrySessionFinalization(
                sessionID: session.sessionID,
                lifecycleState: .cancelled,
                endedAt: nil,
                endedElapsed: nil,
                incompleteReason: "recorder-cancelled",
                recorderHealth: RecorderHealthSummary(
                    isComplete: false,
                    lostCriticalRecordCount: 1,
                    lostNativeRecordCount: 0,
                    lastPersistedElapsed: nil
                )
            )
        )

        let storedSessions = try await store.fetchSessions()
        let reopened = try XCTUnwrap(storedSessions.first { $0.sessionID == session.sessionID })
        let unfinished = try await store.unfinishedSessions()
        XCTAssertEqual(reopened.lifecycleState, .cancelled)
        XCTAssertFalse(unfinished.contains { $0.sessionID == session.sessionID })
    }

    func testRecoveryTargetsOnlyNonterminalSessionsAndIsSemanticallyIdempotent() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let created = session(seed: 10, lifecycleState: .created)
        let running = session(seed: 11, lifecycleState: .running)
        let paused = session(seed: 12, lifecycleState: .paused)
        let completed = session(seed: 13, lifecycleState: .completed)
        let cancelled = session(
            seed: 14,
            lifecycleState: .cancelled,
            incompleteReason: "original-cancelled"
        )
        let originalIncompleteHealth = RecorderHealthSummary(
            isComplete: false,
            lostCriticalRecordCount: 7,
            lostNativeRecordCount: 9,
            lastPersistedElapsed: ElapsedDuration(microseconds: 11_000)
        )
        let incomplete = session(
            seed: 15,
            lifecycleState: .incomplete,
            incompleteReason: "original-incomplete-reason",
            recorderHealth: originalIncompleteHealth
        )
        let allSessions = [created, running, paused, completed, cancelled, incomplete]
        for record in allSessions {
            try await store.beginSession(record)
        }

        let discoveredBeforeRecovery = try await store.unfinishedSessions()
        XCTAssertEqual(
            Set(discoveredBeforeRecovery.map(\.sessionID)),
            Set([created.sessionID, running.sessionID, paused.sessionID])
        )

        let firstRecovery = try await TelemetryRecorder.recoverUnfinishedSessions(using: store)
        let secondRecovery = try await TelemetryRecorder.recoverUnfinishedSessions(using: store)
        XCTAssertEqual(
            Set(firstRecovery.map(\.sessionID)),
            Set([created.sessionID, running.sessionID, paused.sessionID])
        )
        XCTAssertTrue(secondRecovery.isEmpty)

        let stored = Dictionary(
            uniqueKeysWithValues: try await store.fetchSessions().map { ($0.sessionID, $0) }
        )
        for recoveredID in [created.sessionID, running.sessionID, paused.sessionID] {
            XCTAssertEqual(stored[recoveredID]?.lifecycleState, .incomplete)
            XCTAssertEqual(
                stored[recoveredID]?.incompleteReason,
                "recorder-recovered-unfinished-session"
            )
        }
        XCTAssertEqual(stored[completed.sessionID]?.lifecycleState, .completed)
        XCTAssertEqual(stored[cancelled.sessionID]?.lifecycleState, .cancelled)
        XCTAssertEqual(stored[incomplete.sessionID]?.lifecycleState, .incomplete)
        XCTAssertEqual(
            stored[incomplete.sessionID]?.incompleteReason,
            "original-incomplete-reason"
        )
        XCTAssertEqual(stored[incomplete.sessionID]?.recorderHealth, originalIncompleteHealth)
    }

    private func runningSession(seed: UInt8) -> WorkoutSessionRecord {
        session(seed: seed, lifecycleState: .running)
    }

    private func session(
        seed: UInt8,
        lifecycleState: SessionLifecycleState,
        incompleteReason: String? = nil,
        recorderHealth: RecorderHealthSummary? = nil
    ) -> WorkoutSessionRecord {
        let base = TelemetryPersistenceFixtures.session(seed: seed)
        let isCompleted = lifecycleState == .completed
        return WorkoutSessionRecord(
            recordID: base.recordID,
            sessionID: base.sessionID,
            profileLocalIdentifier: base.profileLocalIdentifier,
            lifecycleState: lifecycleState,
            workoutMode: base.workoutMode,
            startedAt: base.startedAt,
            endedAt: isCompleted
                ? TelemetryPersistenceFixtures.baseDate.addingTimeInterval(1)
                : nil,
            endedElapsed: isCompleted ? ElapsedDuration(microseconds: 1_000_000) : nil,
            incompleteReason: incompleteReason,
            appContext: base.appContext,
            versions: base.versions,
            configuration: base.configuration,
            healthKitWorkoutIdentifier: base.healthKitWorkoutIdentifier,
            treadmill: base.treadmill,
            recorderHealth: recorderHealth ?? RecorderHealthSummary(
                isComplete: isCompleted,
                lostCriticalRecordCount: 0,
                lostNativeRecordCount: 0,
                lastPersistedElapsed: nil
            )
        )
    }
}
