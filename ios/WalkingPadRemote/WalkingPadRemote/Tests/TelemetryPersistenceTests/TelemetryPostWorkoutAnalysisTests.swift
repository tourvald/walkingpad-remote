import Foundation
import TelemetryAnalysis
import TelemetryDomain
@testable import TelemetryPersistence
import XCTest

final class TelemetryPostWorkoutAnalysisTests: XCTestCase {
    func testOnlyTerminalSessionsAreEligible() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let running = fixtureSession(seed: 40, lifecycle: .running)
        try await store.insertSession(running)

        let outcome = try await store.analyzeTerminalWorkout(
            sessionID: running.sessionID,
            generatedAt: TelemetryPersistenceFixtures.baseDate
        )

        XCTAssertEqual(outcome.triggerResult, .ineligible)
        XCTAssertNil(outcome.analysis)
        let counts = try await store.counts()
        XCTAssertEqual(counts.analyses, 0)
    }

    func testTerminalAnalysisIsIdempotentAndLeavesRawEvidenceImmutable() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let session = fixtureSession(seed: 41, lifecycle: .completed)
        let source = TelemetryPersistenceFixtures.source(seed: 41, kind: .watchMediated)
        try await store.insertSession(session)
        try await store.insertSource(
            source,
            firstSeen: session.startedAt,
            lastSeen: session.endedAt!
        )
        for index in 1...12 {
            try await store.insertHeartRate(
                TelemetryPersistenceFixtures.heartRate(
                    seed: UInt8(41 + index),
                    session: session,
                    source: source,
                    arrivalOrder: UInt64(index),
                    bpm: UInt16(95 + index),
                    timestamp: TelemetryPersistenceFixtures.timestamp(
                        elapsedMicroseconds: Int64(index - 1) * 5_000_000
                    )
                )
            )
        }
        try await store.insertEvent(phaseEvent(
            seed: 71,
            session: session,
            elapsedSeconds: 0,
            previous: nil,
            current: .main
        ))
        try await store.insertEvent(phaseEvent(
            seed: 72,
            session: session,
            elapsedSeconds: 60,
            previous: .main,
            current: .finished
        ))
        let heartRateBefore = try await store.fetchHeartRate(sessionID: session.sessionID)
        let eventsBefore = try await store.fetchEvents(sessionID: session.sessionID)

        let first = try await store.analyzeTerminalWorkout(
            sessionID: session.sessionID,
            generatedAt: session.endedAt!
        )
        let second = try await store.analyzeTerminalWorkout(
            sessionID: session.sessionID,
            generatedAt: session.endedAt!.addingTimeInterval(10)
        )

        XCTAssertEqual(first.triggerResult, .inserted)
        XCTAssertEqual(second.triggerResult, .existing)
        XCTAssertEqual(first.analysis?.analysisID, second.analysis?.analysisID)
        XCTAssertEqual(first.analysis?.generatedAt, second.analysis?.generatedAt)
        let counts = try await store.counts()
        let heartRateAfter = try await store.fetchHeartRate(sessionID: session.sessionID)
        let eventsAfter = try await store.fetchEvents(sessionID: session.sessionID)
        XCTAssertEqual(counts.analyses, 1)
        XCTAssertEqual(heartRateAfter, heartRateBefore)
        XCTAssertEqual(eventsAfter, eventsBefore)
        let stored = try await store.fetchAnalyses(
            sessionID: session.sessionID,
            analyzerVersion: WorkoutAnalyzerV1.analyzerVersion
        )
        XCTAssertEqual(stored.count, 1)
        let detail = try JSONDecoder().decode(
            WorkoutAnalysisDetailV1.self,
            from: try XCTUnwrap(stored.first?.versionedDetailPayload)
        )
        XCTAssertEqual(detail.metricDefinitionVersion, WorkoutAnalyzerV1.metricDefinitionVersion)
        XCTAssertGreaterThan(detail.quality.heartRateCoverage.coveredSeconds, 0)
    }

    func testResumeAnalyzesEveryPendingTerminalSessionWithoutDuplicatingExistingResult() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let complete = fixtureSession(seed: 50, lifecycle: .completed)
        let incomplete = fixtureSession(
            seed: 51,
            lifecycle: .incomplete,
            recorderComplete: false,
            incompleteReason: "fixture-recorder-loss"
        )
        let running = fixtureSession(seed: 52, lifecycle: .running)
        for session in [complete, incomplete, running] {
            try await store.insertSession(session)
        }
        _ = try await store.analyzeTerminalWorkout(
            sessionID: complete.sessionID,
            generatedAt: complete.endedAt!
        )

        let results = await store.resumePendingWorkoutAnalyses()

        XCTAssertEqual(results, [.existing, .inserted])
        let counts = try await store.counts()
        XCTAssertEqual(counts.analyses, 2)
        let incompleteAnalysis = try await store.fetchAnalyses(
            sessionID: incomplete.sessionID,
            analyzerVersion: WorkoutAnalyzerV1.analyzerVersion
        )
        XCTAssertEqual(incompleteAnalysis.count, 1)
        XCTAssertNotEqual(incompleteAnalysis[0].qualityGrade, .high)
        XCTAssertTrue(incompleteAnalysis[0].exclusions.contains {
            $0.code == "sourceCoverageUnavailable.incomplete-session"
                && $0.detail == "fixture-recorder-loss"
        })
        let runningAnalyses = try await store.fetchAnalyses(
            sessionID: running.sessionID,
            analyzerVersion: WorkoutAnalyzerV1.analyzerVersion
        )
        XCTAssertTrue(runningAnalyses.isEmpty)
    }

    private func fixtureSession(
        seed: UInt8,
        lifecycle: SessionLifecycleState,
        recorderComplete: Bool = true,
        incompleteReason: String? = nil
    ) -> WorkoutSessionRecord {
        let base = TelemetryPersistenceFixtures.session(seed: seed)
        let terminal = lifecycle == .completed || lifecycle == .incomplete || lifecycle == .cancelled
        let configuration = ImmutableConfigurationSnapshot(
            id: base.configuration.id,
            formatVersion: 1,
            format: .canonicalJSON,
            canonicalPayload: Data(
                #"{"targetHeartRate":100,"heartRateZones":[90,110,130,150],"cooldownTargetHeartRate":115,"cooldownMinimumSpeedKilometresPerHour":2.0}"#.utf8
            ),
            contentHash: base.configuration.contentHash
        )
        return WorkoutSessionRecord(
            recordID: base.recordID,
            sessionID: base.sessionID,
            profileLocalIdentifier: base.profileLocalIdentifier,
            lifecycleState: lifecycle,
            workoutMode: base.workoutMode,
            startedAt: base.startedAt,
            endedAt: terminal ? base.startedAt.addingTimeInterval(60) : nil,
            endedElapsed: terminal ? ElapsedDuration(microseconds: 60_000_000) : nil,
            incompleteReason: incompleteReason,
            appContext: base.appContext,
            versions: RuntimeVersionContext(
                telemetrySchema: TelemetrySchemaVersion(rawValue: "1.0.0"),
                algorithm: base.versions.algorithm,
                safetyPolicy: base.versions.safetyPolicy,
                workoutProtocol: base.versions.workoutProtocol
            ),
            configuration: configuration,
            healthKitWorkoutIdentifier: base.healthKitWorkoutIdentifier,
            treadmill: base.treadmill,
            recorderHealth: RecorderHealthSummary(
                isComplete: recorderComplete,
                lostCriticalRecordCount: 0,
                lostNativeRecordCount: recorderComplete ? 0 : 2,
                lastPersistedElapsed: terminal ? ElapsedDuration(microseconds: 60_000_000) : nil
            )
        )
    }

    private func phaseEvent(
        seed: UInt8,
        session: WorkoutSessionRecord,
        elapsedSeconds: Int64,
        previous: WorkoutPhase?,
        current: WorkoutPhase
    ) -> WorkoutEvent {
        let elapsed = ElapsedDuration(microseconds: elapsedSeconds * 1_000_000)
        return WorkoutEvent(
            recordID: RecordID(rawValue: UUID(uuid: (
                seed, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, seed
            ))),
            sessionID: session.sessionID,
            timestamp: EventTimestamp(
                occurredAt: session.startedAt.addingTimeInterval(Double(elapsedSeconds)),
                recordedAt: session.startedAt.addingTimeInterval(Double(elapsedSeconds) + 0.01),
                occurredElapsed: elapsed,
                recordedElapsed: ElapsedDuration(microseconds: elapsed.microseconds + 10_000)
            ),
            sourceID: nil,
            payload: EventPayloadEnvelope(
                schemaVersion: 1,
                payload: .workoutPhase(WorkoutPhaseTransition(previous: previous, current: current))
            )
        )
    }
}
