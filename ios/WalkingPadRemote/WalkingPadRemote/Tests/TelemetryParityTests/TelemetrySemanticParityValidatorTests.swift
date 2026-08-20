import Foundation
import TelemetryDomain
import TelemetryParity
import TelemetryPersistence
import TelemetryRuntime
import XCTest

final class TelemetrySemanticParityValidatorTests: XCTestCase {
    func testCompleteSemanticEvidencePassesWhileDeviceTruthStaysInconclusive() throws {
        let legacy = evidence(origin: .legacyJSONL)
        let v2 = evidence(origin: .telemetryV2)

        let report = TelemetrySemanticParityValidator.validate(
            legacy: legacy,
            telemetryV2: v2
        )

        XCTAssertEqual(report.overallStatus, .pass)
        XCTAssertEqual(result(.causalAssociation, in: report).status, .pass)
        XCTAssertEqual(result(.physicalDeviceTruth, in: report).status, .inconclusive)
        XCTAssertEqual(report.causalCoverage.honestlyUnknownCount, 1)
        XCTAssertEqual(report.causalCoverage.unsupportedClaimCount, 0)
        let firstJSON = try report.machineReadableJSON()
        let secondJSON = try report.machineReadableJSON()
        XCTAssertEqual(firstJSON, secondJSON)
        XCTAssertTrue(report.humanReadableText().contains("deviceOnlyUnverified"))
    }

    func testActualControlMismatchFailsWithoutBeingCalledRecorderLoss() {
        let legacy = evidence(origin: .legacyJSONL)
        let mismatchedDecision = TelemetryParityDecisionEvidence(
            source: "heartRateControl",
            action: "setSpeed",
            desiredSpeedKilometresPerHour: 4.8,
            elapsedMilliseconds: 1_000
        )
        let v2 = evidence(origin: .telemetryV2, decisions: [mismatchedDecision])

        let report = TelemetrySemanticParityValidator.validate(
            legacy: legacy,
            telemetryV2: v2
        )
        let control = result(.controlDecisions, in: report)

        XCTAssertEqual(report.overallStatus, .fail)
        XCTAssertEqual(control.status, .fail)
        XCTAssertEqual(control.findings.first?.classification, .actualSemanticMismatch)
    }

    func testKnownRecorderLossFailsAsRecorderDataLoss() {
        let legacy = evidence(origin: .legacyJSONL)
        let v2 = evidence(
            origin: .telemetryV2,
            completeness: .incomplete,
            integrity: TelemetryParityIntegrityEvidence(lostNativeRecordCount: 1)
        )

        let report = TelemetrySemanticParityValidator.validate(
            legacy: legacy,
            telemetryV2: v2
        )
        let integrity = result(.recordIntegrity, in: report)

        XCTAssertEqual(report.overallStatus, .fail)
        XCTAssertTrue(integrity.findings.contains {
            $0.classification == .v2RecorderOrDataLoss && $0.impact == .fail
        })
    }

    func testIncompleteEvidenceWithoutProvenLossIsInconclusive() {
        let legacy = evidence(origin: .legacyJSONL)
        let v2 = evidence(origin: .telemetryV2, completeness: .incomplete)

        let report = TelemetrySemanticParityValidator.validate(
            legacy: legacy,
            telemetryV2: v2
        )

        XCTAssertEqual(report.overallStatus, .inconclusive)
        XCTAssertEqual(result(.recordIntegrity, in: report).status, .inconclusive)
    }

    func testLegacySourceLimitationRemainsDistinctAndInconclusive() {
        let limitation = TelemetryParitySourceLimitation(
            category: .treadmillFacts,
            code: "legacy-modelled-speed",
            detail: "Legacy value is modelled, not factual."
        )
        let legacy = evidence(origin: .legacyJSONL, limitations: [limitation])
        let v2 = evidence(origin: .telemetryV2)

        let report = TelemetrySemanticParityValidator.validate(
            legacy: legacy,
            telemetryV2: v2
        )
        let treadmill = result(.treadmillFacts, in: report)

        XCTAssertEqual(treadmill.status, .inconclusive)
        XCTAssertEqual(treadmill.findings.first?.classification, .sourceLegacyLimitation)
    }

    func testHonestUnknownCausalOutcomePassesFactualIntegrity() {
        let legacy = evidence(origin: .legacyJSONL)
        let v2 = evidence(origin: .telemetryV2)

        let report = TelemetrySemanticParityValidator.validate(
            legacy: legacy,
            telemetryV2: v2
        )
        let causal = result(.causalAssociation, in: report)

        XCTAssertEqual(causal.status, .pass)
        XCTAssertEqual(causal.findings.first?.classification, .protocolRuntimeCausalAmbiguity)
        XCTAssertEqual(causal.findings.first?.impact, .pass)
    }

    func testFabricatedCausalEdgeFailsEvenWhenCountsMatch() {
        let legacy = evidence(origin: .legacyJSONL)
        let fabricated = TelemetryParityCommandEvidence(
            outcomeKind: .acknowledgement,
            semanticCommand: nil,
            elapsedMilliseconds: 2_100,
            association: .deterministicallyCorrelated,
            commandIdentifier: "command-nearest-in-time",
            attemptIdentifier: "attempt-nearest-in-time"
        )
        let v2 = evidence(
            origin: .telemetryV2,
            commandEvidence: [sentCommand(), fabricated]
        )

        let report = TelemetrySemanticParityValidator.validate(
            legacy: legacy,
            telemetryV2: v2
        )
        let causal = result(.causalAssociation, in: report)

        XCTAssertEqual(report.overallStatus, .fail)
        XCTAssertEqual(causal.status, .fail)
        XCTAssertEqual(causal.findings.first?.classification, .unsupportedCausalEdge)
        XCTAssertEqual(report.causalCoverage.unsupportedClaimCount, 1)
    }

    func testExplicitLegacyTimeoutRemainsComparableDespiteAckLimitation() {
        let limitation = TelemetryParitySourceLimitation(
            category: .commandLifecycle,
            code: "legacy-jsonl-ack-acceptance-not-explicit",
            detail: "Legacy ACK ownership is unavailable."
        )
        let timeout = TelemetryParityCommandEvidence(
            outcomeKind: .timeout,
            semanticCommand: nil,
            elapsedMilliseconds: 2_200,
            association: .unknown,
            commandIdentifier: nil,
            attemptIdentifier: nil
        )
        let legacy = evidence(
            origin: .legacyJSONL,
            commandEvidence: [sentCommand(), timeout],
            limitations: [limitation]
        )
        let v2 = evidence(origin: .telemetryV2, commandEvidence: [sentCommand()])

        let report = TelemetrySemanticParityValidator.validate(
            legacy: legacy,
            telemetryV2: v2
        )
        let commands = result(.commandLifecycle, in: report)

        XCTAssertEqual(commands.status, .fail)
        XCTAssertTrue(commands.findings.contains {
            $0.code == "timeout-count" && $0.classification == .v2RecorderOrDataLoss
        })
    }

    func testCompleteSessionWithMissingRequiredHeartRateFails() {
        let legacy = evidence(origin: .legacyJSONL)
        let v2 = evidence(origin: .telemetryV2, heartRate: [])

        let report = TelemetrySemanticParityValidator.validate(
            legacy: legacy,
            telemetryV2: v2
        )

        let heartRate = result(.heartRateObservations, in: report)
        XCTAssertEqual(heartRate.status, .fail)
        XCTAssertEqual(heartRate.findings.first?.classification, .v2RecorderOrDataLoss)
    }

    func testIncompleteSessionWithMissingHeartRateIsRecorderInconclusive() {
        let legacy = evidence(origin: .legacyJSONL)
        let v2 = evidence(origin: .telemetryV2, completeness: .incomplete, heartRate: [])

        let report = TelemetrySemanticParityValidator.validate(
            legacy: legacy,
            telemetryV2: v2
        )
        let heartRate = result(.heartRateObservations, in: report)

        XCTAssertEqual(heartRate.status, .inconclusive)
        XCTAssertEqual(heartRate.findings.first?.classification, .v2RecorderOrDataLoss)
    }

    func testTimestampDerivedAggregatesAreRecalculatedDeterministically() {
        let legacy = evidence(origin: .legacyJSONL, useDerivedAggregates: true)
        let v2 = evidence(origin: .telemetryV2, useDerivedAggregates: true)

        let report = TelemetrySemanticParityValidator.validate(
            legacy: legacy,
            telemetryV2: v2
        )

        XCTAssertEqual(result(.timestampDerivedAggregates, in: report).status, .pass)
    }

    func testTimestampDerivedAggregatesIgnoreLegacySampleCountSummary() {
        let sampleCountSummary = TelemetryParityAggregateEvidence(
            zoneSeconds: [2, 0, 0, 0, 0],
            cooldownCoveredSeconds: 99
        )
        let legacy = evidence(
            origin: .legacyJSONL,
            aggregateOverride: sampleCountSummary
        )
        let v2 = evidence(origin: .telemetryV2)

        let report = TelemetrySemanticParityValidator.validate(
            legacy: legacy,
            telemetryV2: v2
        )

        XCTAssertEqual(result(.timestampDerivedAggregates, in: report).status, .pass)
    }

    func testOutOfOrderV2EvidenceFailsRecordIntegrity() {
        let legacy = evidence(origin: .legacyJSONL)
        let v2 = evidence(
            origin: .telemetryV2,
            integrity: TelemetryParityIntegrityEvidence(outOfOrderRecordCount: 1)
        )

        let report = TelemetrySemanticParityValidator.validate(
            legacy: legacy,
            telemetryV2: v2
        )

        XCTAssertEqual(result(.recordIntegrity, in: report).status, .fail)
    }

    func testLegacyReaderDoesNotMutateInputAndPreservesKnownLimitations() throws {
        let jsonl = """
        {"ts":"2026-08-20T10:00:00.000Z","event":"session_start","session_id":"11111111-1111-1111-1111-111111111111","target_bpm":110,"duration_min":1,"decision_interval_s":10,"adaptive_step_enabled":true,"max_step_kmh":0.5,"zone_bounds":[100,120,140,160],"cooldown_target_bpm":105,"cooldown_min_speed_kmh":3.5,"cooldown_max_minutes":2,"telemetry_schema_version":"1","algorithm_version":"a","safety_policy_version":"s","workout_protocol_version":"w"}
        {"ts":"2026-08-20T10:00:01.000Z","event":"hr_sample","session_id":"11111111-1111-1111-1111-111111111111","hr_bpm":90}
        {"ts":"2026-08-20T10:00:01.500Z","event":"notify_fe01","session_id":"11111111-1111-1111-1111-111111111111","speed_kmh":4.2,"state":0,"controller_units":"metric","controller_units_fresh":true,"checksum_ok":true}
        {"ts":"2026-08-20T10:00:02.000Z","event":"session_end","session_id":"11111111-1111-1111-1111-111111111111","reason":"manual_stop"}
        """
        let data = Data(jsonl.utf8)
        let original = data

        let evidence = try LegacyTelemetryJSONLReader.read(data: data)

        XCTAssertEqual(data, original)
        XCTAssertEqual(evidence.sessionIdentifier, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(evidence.heartRate.map(\.beatsPerMinute), [90])
        XCTAssertEqual(evidence.treadmillFacts.first?.nativeUnit, "walkingpad_controller_tenths")
        XCTAssertEqual(evidence.treadmillFacts.first?.factualSpeedKilometresPerHour, 4.2)
        XCTAssertEqual(evidence.treadmillFacts.first?.deviceState, "moving")
        XCTAssertTrue(evidence.limitations.contains {
            $0.code == "legacy-jsonl-ack-acceptance-not-explicit"
        })
    }

    func testLegacyReaderNeverPromotesInvalidChecksumSpeedToFactualTruth() throws {
        let jsonl = """
        {"ts":"2026-08-20T10:00:00.000Z","event":"session_start","session_id":"11111111-1111-1111-1111-111111111111"}
        {"ts":"2026-08-20T10:00:01.000Z","event":"notify_fe01","session_id":"11111111-1111-1111-1111-111111111111","speed_kmh":4.2,"state":1,"controller_units":"metric","controller_units_fresh":true,"checksum_ok":false}
        {"ts":"2026-08-20T10:00:02.000Z","event":"notify_fitshow_speed","session_id":"11111111-1111-1111-1111-111111111111","speed_kmh":4.3,"checksum_ok":false}
        {"ts":"2026-08-20T10:00:03.000Z","event":"session_end","session_id":"11111111-1111-1111-1111-111111111111","reason":"manual_stop"}
        """

        let read = try LegacyTelemetryJSONLReader.read(data: Data(jsonl.utf8))

        XCTAssertEqual(read.treadmillFacts.map(\.nativeValue), [4.2, 4.3])
        XCTAssertEqual(read.treadmillFacts.map(\.factualSpeedKilometresPerHour), [nil, nil])
        XCTAssertEqual(read.treadmillFacts.map(\.deviceState), [nil, nil])
    }

    func testV2StoreReaderIsReadOnly() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let sessionID = SessionID(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
        let start = Date(timeIntervalSince1970: 1_000)
        let session = try makeV2Session(sessionID: sessionID, start: start)
        try await store.insertSession(session)
        let commandID = CommandID(
            rawValue: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        )
        let attemptID = CommandAttemptID(
            rawValue: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        )
        let eventTimestamp = EventTimestamp(
            occurredAt: start.addingTimeInterval(1),
            recordedAt: start.addingTimeInterval(1),
            occurredElapsed: ElapsedDuration(microseconds: 1_000_000),
            recordedElapsed: ElapsedDuration(microseconds: 1_000_000)
        )
        try await store.insertEvent(
            WorkoutEvent(
                recordID: RecordID(
                    rawValue: UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
                ),
                sessionID: sessionID,
                timestamp: eventTimestamp,
                payload: EventPayloadEnvelope(
                    schemaVersion: 1,
                    payload: .commandLifecycle(
                        CommandLifecycleRecord(
                            commandID: commandID,
                            decisionID: nil,
                            lifecycle: .enqueued(
                                kind: .setSpeed(
                                    CommandedSpeed(
                                        nativeValue: 4.2,
                                        nativeUnit: .kilometresPerHour
                                    )
                                )
                            )
                        )
                    )
                )
            )
        )
        try await store.insertEvent(
            WorkoutEvent(
                recordID: RecordID(
                    rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
                ),
                sessionID: sessionID,
                timestamp: eventTimestamp,
                payload: EventPayloadEnvelope(
                    schemaVersion: 1,
                    payload: .commandLifecycle(
                        CommandLifecycleRecord(
                            commandID: commandID,
                            decisionID: nil,
                            lifecycle: .sendAttempt(attemptID: attemptID, attemptNumber: 1)
                        )
                    )
                )
            )
        )
        let treadmillSource = SignalSourceIdentity(
            id: SourceID(),
            providerKind: .bluetooth,
            stableLocalKey: "walkingpad-test",
            savingSource: nil,
            knownDevice: nil
        )
        try await store.insertSource(
            treadmillSource,
            firstSeen: start,
            lastSeen: start.addingTimeInterval(1.5)
        )
        try await store.insertTreadmill(
            TreadmillObservation(
                recordID: RecordID(),
                observationID: ObservationID(),
                sessionID: sessionID,
                source: treadmillSource,
                nativeSpeed: NativeTreadmillSpeed(
                    value: 4.2,
                    unit: .controllerNative(code: "walkingPad-tenths")
                ),
                deviceState: .moving,
                arrivalOrder: 1,
                timestamp: ObservationTimestamp(
                    measuredAt: nil,
                    receivedAt: start.addingTimeInterval(1.5),
                    recordedAt: start.addingTimeInterval(1.5),
                    measuredElapsed: nil,
                    receivedElapsed: ElapsedDuration(microseconds: 1_500_000),
                    recordedElapsed: ElapsedDuration(microseconds: 1_500_000)
                ),
                provenance: .decodedDeviceReport,
                freshness: EvidenceFreshness(
                    state: .fresh,
                    evaluatedAt: RecordTimestamp(
                        recordedAt: start.addingTimeInterval(1.5),
                        elapsed: ElapsedDuration(microseconds: 1_500_000)
                    ),
                    age: .zero,
                    policyVersion: session.versions.safetyPolicy
                ),
                quality: []
            )
        )
        let before = try await store.counts()

        let read = try await TelemetryV2ParityReader.read(from: store, sessionID: sessionID)
        let after = try await store.counts()

        XCTAssertEqual(read.sessionIdentifier, sessionID.description)
        XCTAssertEqual(read.commandEvidence.count, 1)
        XCTAssertEqual(read.commandEvidence.first?.semanticCommand, "setSpeed")
        XCTAssertEqual(read.treadmillFacts.first?.nativeUnit, "walkingpad_controller_tenths")
        XCTAssertEqual(read.treadmillFacts.first?.deviceState, "moving")
        XCTAssertEqual(before, after)
    }

    func testV2ArrayReaderReportsOutOfOrderEventsBeforeSortingForComparison() throws {
        let sessionID = SessionID(
            rawValue: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        )
        let start = Date(timeIntervalSince1970: 1_000)
        let session = try makeV2Session(sessionID: sessionID, start: start)
        let later = makeEvent(
            sessionID: sessionID,
            start: start,
            elapsedMicroseconds: 2_000_000
        )
        let earlier = makeEvent(
            sessionID: sessionID,
            start: start,
            elapsedMicroseconds: 1_000_000
        )

        let read = try TelemetryV2ParityReader.read(
            session: session,
            heartRate: [],
            treadmill: [],
            events: [later, earlier],
            frames: []
        )

        XCTAssertEqual(read.integrity.outOfOrderRecordCount, 1)
    }

    func testV2ReaderPreservesUnassociatedObservedResponseWithNilCausalIDs() throws {
        let sessionID = SessionID(
            rawValue: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        )
        let start = Date(timeIntervalSince1970: 1_000)
        let session = try makeV2Session(sessionID: sessionID, start: start)
        let receivedAt = start.addingTimeInterval(1)
        var normalizer = TreadmillObservationNormalizer()
        let observation = normalizer.normalize(
            .ftms(
                speedRawHundredthsKmh: 420,
                rawState: 1,
                deviceState: .moving,
                connectionEpoch: TreadmillConnectionEpoch(
                    rawValue: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
                ),
                receivedAt: receivedAt
            ),
            unitsTruth: nil,
            observationID: ObservationID(),
            recordedAt: receivedAt
        )
        let event = makeEvent(
            sessionID: sessionID,
            start: start,
            elapsedMicroseconds: 1_000_000,
            payload: .treadmillEvidence(.observation(observation))
        )

        let read = try TelemetryV2ParityReader.read(
            session: session,
            heartRate: [],
            treadmill: [],
            events: [event],
            frames: []
        )

        XCTAssertEqual(read.commandEvidence.count, 1)
        XCTAssertEqual(read.commandEvidence.first?.outcomeKind, .observedResponse)
        XCTAssertEqual(read.commandEvidence.first?.association, .unknown)
        XCTAssertNil(read.commandEvidence.first?.commandIdentifier)
        XCTAssertNil(read.commandEvidence.first?.attemptIdentifier)
    }

    private func result(
        _ category: TelemetryParityCategory,
        in report: TelemetrySemanticParityReport
    ) -> TelemetryParityCategoryResult {
        report.categories.first { $0.category == category }!
    }

    private func makeV2Session(
        sessionID: SessionID,
        start: Date
    ) throws -> WorkoutSessionRecord {
        let configuration = TelemetryV2ConfigurationInput(
            profileLocalIdentifier: "profile",
            workoutMode: .heartRateControlled,
            targetHeartRate: 110,
            durationMinutes: 1,
            decisionIntervalSeconds: 10,
            adaptiveStepEnabled: true,
            maximumStepKilometresPerHour: 0.5,
            heartRateZones: [100, 120, 140, 160],
            cooldownTargetHeartRate: 105,
            cooldownMinimumSpeedKilometresPerHour: 3.5,
            cooldownMaximumMinutes: 2,
            heartRateProviderKind: "legacyWatchWorkoutStream",
            heartRateProviderStableLocalKey: "watch",
            treadmill: TelemetryV2TreadmillContext(
                stableLocalIdentifier: nil,
                model: nil,
                protocolName: "walkingPad",
                protocolVersion: nil,
                minimumSpeedKilometresPerHour: 0.5,
                maximumSpeedKilometresPerHour: 12,
                speedIncrementKilometresPerHour: 0.1
            )
        )
        return WorkoutSessionRecord(
            recordID: RecordID(),
            sessionID: sessionID,
            profileLocalIdentifier: "profile",
            lifecycleState: .completed,
            workoutMode: .heartRateControlled,
            startedAt: start,
            endedAt: start.addingTimeInterval(10),
            endedElapsed: ElapsedDuration(microseconds: 10_000_000),
            incompleteReason: nil,
            appContext: AppRuntimeContext(
                appVersion: "1",
                buildNumber: "1",
                operatingSystemVersion: "test"
            ),
            versions: RuntimeVersionContext(
                telemetrySchema: TelemetrySchemaVersion(rawValue: "1"),
                algorithm: AlgorithmVersion(rawValue: "a"),
                safetyPolicy: SafetyPolicyVersion(rawValue: "s"),
                workoutProtocol: WorkoutProtocolVersion(rawValue: "w")
            ),
            configuration: ImmutableConfigurationSnapshot(
                id: ConfigurationSnapshotID(),
                formatVersion: 1,
                format: .canonicalJSON,
                canonicalPayload: try JSONEncoder().encode(configuration),
                contentHash: ContentHash(algorithm: .sha256, lowercaseHexDigest: "00")
            ),
            healthKitWorkoutIdentifier: nil,
            treadmill: nil,
            recorderHealth: RecorderHealthSummary(
                isComplete: true,
                lostCriticalRecordCount: 0,
                lostNativeRecordCount: 0,
                lastPersistedElapsed: ElapsedDuration(microseconds: 10_000_000)
            )
        )
    }

    private func makeEvent(
        sessionID: SessionID,
        start: Date,
        elapsedMicroseconds: Int64,
        payload: WorkoutEventPayload = .manualStop(ManualStopEvent(reason: "test"))
    ) -> WorkoutEvent {
        let elapsed = ElapsedDuration(microseconds: elapsedMicroseconds)
        let occurredAt = start.addingTimeInterval(Double(elapsedMicroseconds) / 1_000_000)
        return WorkoutEvent(
            recordID: RecordID(),
            sessionID: sessionID,
            timestamp: EventTimestamp(
                occurredAt: occurredAt,
                recordedAt: occurredAt,
                occurredElapsed: elapsed,
                recordedElapsed: elapsed
            ),
            payload: EventPayloadEnvelope(
                schemaVersion: 1,
                payload: payload
            )
        )
    }

    private func evidence(
        origin: TelemetryParityEvidenceOrigin,
        completeness: TelemetryParityCompleteness = .complete,
        heartRate: [TelemetryParityHeartRateEvidence]? = nil,
        decisions: [TelemetryParityDecisionEvidence]? = nil,
        commandEvidence: [TelemetryParityCommandEvidence]? = nil,
        integrity: TelemetryParityIntegrityEvidence = TelemetryParityIntegrityEvidence(),
        limitations: [TelemetryParitySourceLimitation] = [],
        aggregateOverride: TelemetryParityAggregateEvidence? = nil,
        useDerivedAggregates: Bool = false
    ) -> TelemetryParitySessionEvidence {
        let start = Date(timeIntervalSince1970: 1_000)
        let defaultHeartRate = [
            TelemetryParityHeartRateEvidence(
                elapsedMilliseconds: 0,
                receivedAt: start,
                beatsPerMinute: 90,
                acceptedForControl: true,
                arrivalOrder: 1
            ),
            TelemetryParityHeartRateEvidence(
                elapsedMilliseconds: 5_000,
                receivedAt: start.addingTimeInterval(5),
                beatsPerMinute: 100,
                acceptedForControl: true,
                arrivalOrder: 2
            ),
        ]
        return TelemetryParitySessionEvidence(
            origin: origin,
            sessionIdentifier: "11111111-1111-1111-1111-111111111111",
            linkedLegacySessionIdentifier: "11111111-1111-1111-1111-111111111111",
            completeness: completeness,
            lifecycle: TelemetryParityLifecycleEvidence(
                startedAt: start,
                endedAt: start.addingTimeInterval(10),
                endReason: "manual_stop",
                durationMilliseconds: 10_000
            ),
            heartRate: heartRate ?? defaultHeartRate,
            phases: [
                TelemetryParityPhaseEvidence(phase: "main", elapsedMilliseconds: 0),
                TelemetryParityPhaseEvidence(phase: "cooldown", elapsedMilliseconds: 8_000),
                TelemetryParityPhaseEvidence(phase: "finished", elapsedMilliseconds: 10_000),
            ],
            configuration: TelemetryParityConfigurationEvidence(
                targetHeartRate: 110,
                durationSeconds: 60,
                decisionIntervalSeconds: 10,
                adaptiveStepEnabled: true,
                maximumStepKilometresPerHour: 0.5,
                heartRateZoneUpperBounds: [100, 120, 140, 160],
                cooldownTargetHeartRate: 105,
                cooldownMinimumSpeedKilometresPerHour: 3.5,
                cooldownMaximumSeconds: 120,
                telemetrySchemaVersion: "1",
                algorithmVersion: "a",
                safetyPolicyVersion: "s",
                workoutProtocolVersion: "w"
            ),
            decisions: decisions ?? [
                TelemetryParityDecisionEvidence(
                    source: "heartRateControl",
                    action: "setSpeed",
                    desiredSpeedKilometresPerHour: 4.1,
                    elapsedMilliseconds: 1_000
                ),
            ],
            treadmillFacts: [
                TelemetryParityTreadmillFact(
                    elapsedMilliseconds: 2_000,
                    nativeValue: 4,
                    nativeUnit: "walkingpad_controller_tenths",
                    factualSpeedKilometresPerHour: 4,
                    deviceState: "moving"
                ),
            ],
            commandEvidence: commandEvidence ?? [sentCommand(), unknownAcknowledgement()],
            aggregates: useDerivedAggregates ? nil : aggregateOverride
                ?? TelemetryParityAggregateEvidence(
                    zoneSeconds: [10, 0, 0, 0, 0],
                    cooldownCoveredSeconds: 2
                ),
            stopEvidence: [
                TelemetryParityStopEvidence(
                    conclusion: "unconfirmed",
                    factualObservationIdentifier: nil,
                    elapsedMilliseconds: 10_000
                ),
            ],
            integrity: integrity,
            limitations: limitations
        )
    }

    private func sentCommand() -> TelemetryParityCommandEvidence {
        TelemetryParityCommandEvidence(
            outcomeKind: .sent,
            semanticCommand: "setSpeed",
            elapsedMilliseconds: 2_000,
            association: .deterministicallyCorrelated,
            commandIdentifier: "command-1",
            attemptIdentifier: "attempt-1"
        )
    }

    private func unknownAcknowledgement() -> TelemetryParityCommandEvidence {
        TelemetryParityCommandEvidence(
            outcomeKind: .acknowledgement,
            semanticCommand: nil,
            elapsedMilliseconds: 2_100,
            association: .unknown,
            commandIdentifier: nil,
            attemptIdentifier: nil
        )
    }
}
