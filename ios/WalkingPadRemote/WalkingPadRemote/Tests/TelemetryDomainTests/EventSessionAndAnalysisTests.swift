import Foundation
import TelemetryDomain
import XCTest

final class EventSessionAndAnalysisTests: XCTestCase {
    func testControlDecisionPreservesActualObservationReferencesAndContext() throws {
        let decision = makeDecision()

        XCTAssertEqual(decision.observationsUsed, [.heartRate(TelemetryDomainFixtures.observationID)])
        XCTAssertEqual(decision.configurationSnapshotID, TelemetryDomainFixtures.configurationID)
        try assertCodableRoundTrip(decision)
    }

    func testEveryCommandLifecycleCaseRoundTripsWithCausalIDs() throws {
        let commandID = CommandID()
        let decisionID = DecisionID()
        let firstAttempt = CommandAttemptID()
        let secondAttempt = CommandAttemptID()
        let cases: [(CommandLifecycle, CommandAttemptID?)] = [
            (
                .enqueued(kind: .setSpeed(CommandedSpeed(nativeValue: 50, nativeUnit: .controllerNative(code: "tenths")))),
                nil
            ),
            (.sendAttempt(attemptID: firstAttempt, attemptNumber: 1), firstAttempt),
            (.acknowledged(attemptID: firstAttempt), firstAttempt),
            (.timedOut(attemptID: firstAttempt), firstAttempt),
            (
                .retryScheduled(
                previousAttemptID: firstAttempt,
                nextAttemptID: secondAttempt,
                nextAttemptNumber: 2
                ),
                secondAttempt
            ),
            (.cancelled(reason: .sessionEnded), nil),
            (.failed(attemptID: secondAttempt, reason: .transportUnavailable), secondAttempt),
            (.failed(attemptID: nil, reason: .encodingFailed), nil),
        ]

        for (offset, entry) in cases.enumerated() {
            let event = makeEvent(
                payload: .commandLifecycle(CommandLifecycleRecord(
                    commandID: commandID,
                    decisionID: offset == 0 ? nil : decisionID,
                    lifecycle: entry.0
                ))
            )
            XCTAssertEqual(event.commandID, commandID)
            XCTAssertEqual(event.decisionID, offset == 0 ? nil : decisionID)
            XCTAssertEqual(event.attemptID, entry.1)
            try assertCodableRoundTrip(event)
        }
    }

    func testControlDecisionEventDerivesDecisionIDFromPayload() throws {
        let decision = makeDecision()
        let event = makeEvent(payload: .controlDecision(decision))

        XCTAssertEqual(event.decisionID, decision.decisionID)
        XCTAssertNil(event.commandID)
        XCTAssertNil(event.attemptID)
        try assertCodableRoundTrip(event)
    }

    func testWorkoutEventDecodingRejectsContradictoryCausalIDs() throws {
        let decision = makeDecision()
        let controlEvent = makeEvent(payload: .controlDecision(decision))
        let commandID = CommandID()
        let decisionID = DecisionID()
        let previousAttemptID = CommandAttemptID()
        let nextAttemptID = CommandAttemptID()
        let retryEvent = makeEvent(
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
        let contradictions = [
            WorkoutEventCodingFixture(
                event: controlEvent,
                decisionID: DecisionID(),
                commandID: controlEvent.commandID,
                attemptID: controlEvent.attemptID
            ),
            WorkoutEventCodingFixture(
                event: retryEvent,
                decisionID: retryEvent.decisionID,
                commandID: CommandID(),
                attemptID: retryEvent.attemptID
            ),
            WorkoutEventCodingFixture(
                event: retryEvent,
                decisionID: nil,
                commandID: retryEvent.commandID,
                attemptID: retryEvent.attemptID
            ),
            WorkoutEventCodingFixture(
                event: retryEvent,
                decisionID: retryEvent.decisionID,
                commandID: retryEvent.commandID,
                attemptID: previousAttemptID
            ),
        ]

        for contradiction in contradictions {
            let data = try JSONEncoder().encode(contradiction)
            XCTAssertThrowsError(try JSONDecoder().decode(WorkoutEvent.self, from: data))
        }
    }

    func testTypedEventPayloadTaxonomyRoundTripsWithoutSparseUniversalFields() throws {
        let payloads: [(WorkoutEventKind, WorkoutEventPayload)] = [
            (.sessionLifecycle, .sessionLifecycle(SessionLifecycleEvent(previous: .created, current: .running))),
            (.workoutPhase, .workoutPhase(WorkoutPhaseTransition(previous: .warmup, current: .main))),
            (.sourceTransition, .sourceTransition(SourceTransition(previousSourceID: nil, currentSourceID: TelemetryDomainFixtures.sourceID, reason: "selected"))),
            (.connectionTransition, .connectionTransition(ConnectionTransition(previous: .connecting, current: .connected))),
            (.controlDecision, .controlDecision(makeDecision())),
            (.commandLifecycle, .commandLifecycle(CommandLifecycleRecord(commandID: CommandID(), decisionID: nil, lifecycle: .enqueued(kind: .stop)))),
            (.cooldown, .cooldown(CooldownEvent(lifecycle: .started, targetHeartRate: 100))),
            (.manualStop, .manualStop(ManualStopEvent(reason: "user"))),
            (.safety, .safety(SafetyEvent(policy: TelemetryDomainFixtures.versions.safetyPolicy, gate: "stale-hr", outcome: .blocked, evidence: []))),
            (.stopEvidence, .stopEvidence(StopEvidenceEvent(conclusion: .unconfirmed(reason: "missing factual evidence"), freshness: nil, deviceState: nil, factualSpeed: nil))),
            (.recorderHealth, .recorderHealth(RecorderHealthEvent(kind: .loss, affectedRecordClass: "native", count: 2))),
        ]

        for (offset, entry) in payloads.enumerated() {
            let event = WorkoutEvent(
                recordID: RecordID(),
                sessionID: TelemetryDomainFixtures.sessionID,
                timestamp: EventTimestamp(
                    occurredAt: TelemetryDomainFixtures.baseDate.addingTimeInterval(Double(offset)),
                    recordedAt: TelemetryDomainFixtures.baseDate.addingTimeInterval(Double(offset) + 0.01),
                    occurredElapsed: ElapsedDuration(microseconds: Int64(offset) * 1_000_000),
                    recordedElapsed: ElapsedDuration(microseconds: Int64(offset) * 1_000_000 + 10_000)
                ),
                payload: EventPayloadEnvelope(schemaVersion: 1, payload: entry.1)
            )
            XCTAssertEqual(event.kind, entry.0)
            try assertCodableRoundTrip(event)
        }
    }

    func testWorkoutSessionAndAnalysisRoundTrip() throws {
        let session = WorkoutSessionRecord(
            recordID: RecordID(),
            sessionID: TelemetryDomainFixtures.sessionID,
            profileLocalIdentifier: "profile-local-1",
            lifecycleState: .completed,
            workoutMode: .heartRateControlled,
            startedAt: TelemetryDomainFixtures.baseDate,
            endedAt: TelemetryDomainFixtures.baseDate.addingTimeInterval(1_800),
            endedElapsed: ElapsedDuration(microseconds: 1_800_000_000),
            incompleteReason: nil,
            appContext: AppRuntimeContext(
                appVersion: "1.0",
                buildNumber: "42",
                operatingSystemVersion: "iOS 26.0"
            ),
            versions: TelemetryDomainFixtures.versions,
            configuration: TelemetryDomainFixtures.configuration,
            healthKitWorkoutIdentifier: nil,
            treadmill: KnownTreadmillMetadata(model: "known-model", protocolName: "known-protocol"),
            recorderHealth: RecorderHealthSummary(
                isComplete: true,
                lostCriticalRecordCount: 0,
                lostNativeRecordCount: 0,
                lastPersistedElapsed: ElapsedDuration(microseconds: 1_800_000_000)
            )
        )
        let analysis = WorkoutAnalysisResult(
            analysisID: AnalysisID(),
            recordID: RecordID(),
            sessionID: session.sessionID,
            analyzerVersion: AnalyzerVersion(rawValue: "analyzer-v1"),
            evidenceHash: ContentHash(
                algorithm: .sha256,
                lowercaseHexDigest: String(repeating: "b", count: 64)
            ),
            generatedAt: TelemetryDomainFixtures.baseDate.addingTimeInterval(1_900),
            qualityGrade: .high,
            exclusions: [],
            keyMetrics: AnalysisKeyMetrics(
                coveredDuration: ElapsedDuration(microseconds: 1_700_000_000),
                averageHeartRate: 122.4,
                maximumHeartRate: 145,
                averageFactualSpeedKilometresPerHour: 5.7
            ),
            detailSchemaVersion: 1,
            versionedDetailPayload: Data(#"{"metric":"value"}"#.utf8)
        )

        try assertCodableRoundTrip(session)
        try assertCodableRoundTrip(analysis)
    }

    private func makeDecision() -> ControlDecision {
        ControlDecision(
            decisionID: DecisionID(),
            observationsUsed: [.heartRate(TelemetryDomainFixtures.observationID)],
            target: .heartRate(beatsPerMinute: 120),
            action: .enqueueSpeed(DesiredSpeedKilometresPerHour(value: 5.5)),
            reason: .aboveTarget,
            versions: TelemetryDomainFixtures.versions,
            configurationSnapshotID: TelemetryDomainFixtures.configurationID
        )
    }

    private func makeEvent(payload: WorkoutEventPayload) -> WorkoutEvent {
        WorkoutEvent(
            recordID: RecordID(),
            sessionID: TelemetryDomainFixtures.sessionID,
            timestamp: EventTimestamp(
                occurredAt: TelemetryDomainFixtures.baseDate,
                recordedAt: TelemetryDomainFixtures.baseDate.addingTimeInterval(0.01),
                occurredElapsed: ElapsedDuration(microseconds: 1_000_000),
                recordedElapsed: ElapsedDuration(microseconds: 1_010_000)
            ),
            payload: EventPayloadEnvelope(schemaVersion: 1, payload: payload)
        )
    }
}

private struct WorkoutEventCodingFixture: Encodable {
    let recordID: RecordID
    let sessionID: SessionID
    let kind: WorkoutEventKind
    let timestamp: EventTimestamp
    let sourceID: SourceID?
    let decisionID: DecisionID?
    let commandID: CommandID?
    let attemptID: CommandAttemptID?
    let payload: EventPayloadEnvelope

    init(
        event: WorkoutEvent,
        decisionID: DecisionID?,
        commandID: CommandID?,
        attemptID: CommandAttemptID?
    ) {
        recordID = event.recordID
        sessionID = event.sessionID
        kind = event.kind
        timestamp = event.timestamp
        sourceID = event.sourceID
        self.decisionID = decisionID
        self.commandID = commandID
        self.attemptID = attemptID
        payload = event.payload
    }
}
