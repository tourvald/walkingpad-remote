import Foundation
import TelemetryAnalysis
import TelemetryDomain
@testable import TelemetryPersistence
import XCTest

final class WorkoutAnalysisExportTests: XCTestCase {

    func testStoredAnalysisMetadataSeparatesReportedPhasesAndPopulatedFrames() async throws {
        for scenario in ["ordinary", "invalid-phase", "stale-hr", "delayed-hr", "custom-policy"] {
            let store = try TelemetryStoreFactory.make(.inMemory)
            let session = semanticsSession()
            let source = TelemetryPersistenceFixtures.source(seed: 51)
            try await store.insertSession(session)
            try await store.insertSource(source, firstSeen: session.startedAt, lastSeen: session.endedAt!)
            var observations: [HeartRateObservation] = []
            for index in 0..<(scenario == "stale-hr" || scenario == "delayed-hr" ? 1 : 12) {
                let elapsed = Int64(index * 5) * 1_000_000
                let timestamp = scenario == "delayed-hr" ? ObservationTimestamp(
                    measuredAt: session.startedAt, receivedAt: session.startedAt.addingTimeInterval(20),
                    recordedAt: session.startedAt.addingTimeInterval(21),
                    measuredElapsed: .init(microseconds: 0), receivedElapsed: .init(microseconds: 20_000_000),
                    recordedElapsed: .init(microseconds: 21_000_000)
                ) : TelemetryPersistenceFixtures.timestamp(elapsedMicroseconds: elapsed)
                let original = TelemetryPersistenceFixtures.heartRate(seed: UInt8(60 + index), session: session,
                    source: source, arrivalOrder: UInt64(index), bpm: 120, timestamp: timestamp)
                let hr = HeartRateObservation(recordID: original.recordID, observationID: original.observationID,
                    sessionID: session.sessionID, source: source, beatsPerMinute: 120, arrivalOrder: UInt64(index),
                    providerSequence: Int64(index), providerSampleIdentity: nil, timestamp: timestamp, provenance: original.provenance,
                    freshness: .init(state: scenario == "delayed-hr" ? .stale : .fresh,
                        evaluatedAt: .init(recordedAt: timestamp.recordedAt, elapsed: timestamp.recordedElapsed),
                        age: .init(microseconds: timestamp.recordedElapsed.microseconds - timestamp.effectiveElapsed.microseconds),
                        policyVersion: session.versions.safetyPolicy),
                    quality: [], controlUse: original.controlUse)
                observations.append(hr)
                try await store.insertHeartRate(hr)
            }
            let treadmillSource = TelemetryPersistenceFixtures.source(seed: 52, kind: .bluetooth)
            try await store.insertSource(treadmillSource, firstSeen: session.startedAt, lastSeen: session.endedAt!)
            let treadmill = (0..<(scenario == "custom-policy" ? 1 : 12)).map {
                TelemetryPersistenceFixtures.treadmill(seed: UInt8(80 + $0), session: session,
                    source: treadmillSource, arrivalOrder: UInt64($0 * 5), unit: .kilometresPerHour)
            }
            for observation in treadmill { try await store.insertTreadmill(observation) }
            for second in 0..<60 {
                let observation = treadmill[min(second / 5, treadmill.count - 1)]
                let materializedElapsed = Int64(second) * 1_000_000 + 50_000
                let age = materializedElapsed - observation.timestamp.effectiveElapsed.microseconds
                let speed = TreadmillFrameEvidence(observationID: observation.observationID,
                    recordID: observation.recordID, sourceID: observation.source.id,
                    nativeSpeed: observation.nativeSpeed, factualSpeed: observation.factualSpeed,
                    deviceState: observation.deviceState, measuredAt: observation.timestamp.measuredAt,
                    receivedAt: observation.timestamp.receivedAt, evidenceElapsed: observation.timestamp.effectiveElapsed,
                    ageAtMaterialization: .init(microseconds: age), freshness: age < 5_000_000 ? .fresh : .stale,
                    provenance: observation.provenance)
                let hr = observations[min(second / 5, observations.count - 1)]
                let original = frame(seed: 2000 + second, session: session, second: Int64(second), heartRate: nil, treadmill: nil)
                let hrAge = materializedElapsed - hr.timestamp.effectiveElapsed.microseconds
                let hrEvidence = HeartRateFrameEvidence(observationID: hr.observationID, recordID: hr.recordID,
                    sourceID: hr.source.id, beatsPerMinute: hr.beatsPerMinute, measuredAt: hr.timestamp.measuredAt,
                    receivedAt: hr.timestamp.receivedAt, evidenceElapsed: hr.timestamp.effectiveElapsed,
                    ageAtMaterialization: .init(microseconds: hrAge), freshness: hrAge < 7_000_000 ? .fresh : .stale,
                    provenance: hr.provenance)
                try await store.insertFrame(CanonicalFrame(frameID: original.frameID, recordID: original.recordID,
                    sessionID: session.sessionID, canonicalElapsedSecond: Int64(second),
                    materializedAt: .init(recordedAt: session.startedAt.addingTimeInterval(Double(materializedElapsed) / 1_000_000),
                        elapsed: .init(microseconds: materializedElapsed)),
                    heartRateEvidence: scenario == "delayed-hr" && second < 20 ? nil : hrEvidence,
                    treadmillEvidence: speed, precedingGap: nil))
            }
            try await store.insertEvent(semanticsEvent(seed: 130, session: session, elapsedMicroseconds: 0,
                payload: .workoutPhase(.init(previous: nil, current: .main))))
            try await store.insertEvent(semanticsEvent(seed: 131, session: session, elapsedMicroseconds: 30_000_000,
                payload: .workoutPhase(.init(previous: .main, current: .cooldown))))
            try await store.insertEvent(semanticsEvent(seed: 132, session: session,
                elapsedMicroseconds: scenario == "invalid-phase" ? 62_000_000 : 60_000_000,
                payload: .workoutPhase(.init(previous: .cooldown, current: .finished))))
            let policy = scenario == "custom-policy" ? AnalyzerV1Policy(
                heartRateFreshnessSeconds: 3, treadmillFreshnessSeconds: 2, settlingWindowSeconds: 30,
                stableSpeedMinimumSeconds: 30, stableSpeedToleranceKilometresPerHour: 0.1,
                informativeSpeedDeltaKilometresPerHour: 0.2, eventResponseWindowSeconds: 10,
                minimumWindowCoverageRatio: 0.5) : .default
            let outcome = try await store.analyzeTerminalWorkout(sessionID: session.sessionID,
                generatedAt: session.endedAt!.addingTimeInterval(1), policy: policy)
            let analysis = try XCTUnwrap(outcome.analysis)
            let detail = try JSONDecoder().decode(WorkoutAnalysisDetailV1.self, from: analysis.versionedDetailPayload)
            let before = try await store.counts()
            let artifact = try await store.exportWorkoutAnalysis(.init(sessionID: session.sessionID,
                exactProfileLocalIdentifier: session.profileLocalIdentifier, batchSize: 2))
            defer { try? FileManager.default.removeItem(at: artifact.fileURL.deletingLastPathComponent()) }
            let rows = try parseCSV(artifact.fileURL)
            let metadata = metadataRows(rows)
            XCTAssertEqual(metadata["phase_semantics"], "reported-producer-phase-transitions")
            XCTAssertEqual(metadata["frame_coverage_semantics"], "populated-frame-row-ratio")
            XCTAssertEqual(metadata["stored_analysis_detail_status"], "available")
            XCTAssertEqual(metadata["stored_analysis_metric_definition_version"], detail.metricDefinitionVersion)
            let populatedRatio = scenario == "delayed-hr" ? "0.666667" : "1.000000"
            XCTAssertEqual(metadata["heart_rate_frame_coverage_ratio"], populatedRatio)
            let coverage = try jsonObject(metadata["stored_analysis_heart_rate_duration_coverage_json"])
            XCTAssertEqual(coverage["coveredSeconds"] as? Double, detail.quality.heartRateCoverage.coveredSeconds)
            XCTAssertEqual(coverage["coverageRatio"] as? Double, detail.quality.heartRateCoverage.coverageRatio)
            let speed = try jsonObject(metadata["stored_analysis_factual_speed_duration_coverage_json"])
            XCTAssertEqual(speed["coveredSeconds"] as? Double, detail.quality.treadmillFactualCoverage.coveredSeconds)
            XCTAssertEqual(metadata["factual_speed_frame_coverage_ratio"], "1.000000")
            if scenario == "custom-policy" { XCTAssertEqual(speed["coveredSeconds"] as? Double, 2) }
            if scenario == "ordinary" { XCTAssertEqual(speed["coveredSeconds"] as? Double, 60) }
            let storedPolicy = try jsonObject(metadata["stored_analysis_policy_json"])
            XCTAssertEqual(storedPolicy["heartRateFreshnessSeconds"] as? Double, policy.heartRateFreshnessSeconds)
            XCTAssertEqual(storedPolicy["treadmillFreshnessSeconds"] as? Double, policy.treadmillFreshnessSeconds)
            let expectedPolicy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)) as? [String: Any])
            XCTAssertTrue((storedPolicy as NSDictionary).isEqual(to: expectedPolicy))
            let phasesData = try XCTUnwrap(metadata["stored_analysis_phase_summaries_json"]?.data(using: .utf8))
            let phases = try XCTUnwrap(JSONSerialization.jsonObject(with: phasesData) as? [[String: Any]])
            XCTAssertEqual(phases.compactMap { $0["phase"] as? String }, detail.quality.phases.map(\.phase))
            let expectedPhases = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(detail.quality.phases)) as? [[String: Any]])
            XCTAssertTrue((phases as NSArray).isEqual(to: expectedPhases))
            if scenario == "ordinary" {
                XCTAssertEqual(detail.quality.phases.map(\.phase), ["main", "cooldown"])
                XCTAssertEqual(detail.quality.phases.map(\.durationSeconds), [30, 30])
                XCTAssertEqual(detail.quality.heartRateCoverage.coverageRatio, 1)
                XCTAssertEqual(detail.quality.treadmillFactualCoverage.coverageRatio, 1)
                XCTAssertEqual(detail.quality.sessionGrade, .high)
                XCTAssertTrue(detail.quality.phases.allSatisfy { $0.exclusionCodes.isEmpty })
            }
            if scenario == "invalid-phase" {
                XCTAssertEqual(phases.compactMap { $0["phase"] as? String }, ["unknown"])
                XCTAssertTrue(rows.contains { $0.count > 5 && $0[1] == "frame" && $0[5] == "cooldown" })
            }
            if scenario == "stale-hr" || scenario == "delayed-hr" {
                XCTAssertLessThan(try XCTUnwrap(coverage["coverageRatio"] as? Double), 1)
            }
            let after = try await store.counts()
            XCTAssertEqual(before, after)
            XCTAssertEqual(rows[0].count, 39)
            XCTAssertLessThanOrEqual(artifact.diagnostics.maximumStoreFetchLimit, 2)
            XCTAssertLessThanOrEqual(artifact.diagnostics.maximumBufferedTimelineRows, 4)
            // A legacy consumer sees the same rows without the additive metadata.
            let keyIndex = try XCTUnwrap(rows[0].firstIndex(of: "metadata_key"))
            let additive = Set(metadata.keys.filter { $0.hasPrefix("stored_analysis_") || $0 == "phase_semantics" || $0 == "frame_coverage_semantics" })
            let legacyRows = rows.filter { $0.count <= keyIndex || !additive.contains($0[keyIndex]) }
            XCTAssertFalse(metadataRows(legacyRows).keys.contains("stored_analysis_detail_status"))
            XCTAssertEqual(metadataRows(legacyRows)["heart_rate_frame_coverage_ratio"], populatedRatio)
        }
    }

    func testUnavailableStoredDetailDoesNotFabricateZeroCoverage() async throws {
        for (schema, payload, expected) in [(UInt16(1), Optional<Data>.none, "unavailable-missing"),
            (UInt16(2), Data("{}".utf8), "unavailable-unsupported-schema"),
            (UInt16(1), Data("not-json".utf8), "unavailable-malformed")] {
            let store = try TelemetryStoreFactory.make(.inMemory)
            let session = semanticsSession()
            try await store.insertSession(session)
            if let payload {
                let base = TelemetryPersistenceFixtures.analysis(seed: 10, session: session, version: "workout-analyzer-v1.2")
                try await store.insertAnalysis(copyAnalysis(base, schema: schema, payload: payload))
            }
            let artifact = try await store.exportWorkoutAnalysis(.init(sessionID: session.sessionID,
                exactProfileLocalIdentifier: session.profileLocalIdentifier))
            defer { try? FileManager.default.removeItem(at: artifact.fileURL.deletingLastPathComponent()) }
            let metadata = metadataRows(try parseCSV(artifact.fileURL))
            XCTAssertEqual(metadata["stored_analysis_detail_status"], expected)
            XCTAssertEqual(metadata["stored_analysis_heart_rate_duration_coverage_json"], "")
            XCTAssertEqual(metadata["stored_analysis_phase_summaries_json"], "")
            XCTAssertEqual(metadata["stored_analysis_detail_schema_version"], payload == nil ? "" : String(schema))
        }
    }

    func testStoredDetailProjectionPreservesNullAndSanitizesPrivateStrings() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let session = semanticsSession()
        try await store.insertSession(session)
        let input = WorkoutAnalysisInput(session: session, heartRate: [], treadmill: [], events: [], frames: [])
        let base = try WorkoutAnalyzerV1.analyze(input, generatedAt: session.startedAt)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: base.versionedDetailPayload) as? [String: Any])
        json["metricDefinitionVersion"] = "private-profile-sentinel"
        var quality = try XCTUnwrap(json["quality"] as? [String: Any])
        quality["sessionDurationSeconds"] = 0
        quality["heartRateCoverage"] = ["coveredSeconds": 0, "uncoveredSeconds": 0, "coverageRatio": NSNull()]
        quality["treadmillFactualCoverage"] = ["coveredSeconds": 0, "uncoveredSeconds": 0, "coverageRatio": NSNull()]
        quality["phases"] = [["phase": "private-device-sentinel", "durationSeconds": 0,
            "heartRateCoverage": ["coveredSeconds": 0, "uncoveredSeconds": 0, "coverageRatio": NSNull()],
            "treadmillCoverage": ["coveredSeconds": 0, "uncoveredSeconds": 0, "coverageRatio": NSNull()],
            "grade": "unusable", "exclusionCodes": ["private-source-sentinel"]]]
        json["quality"] = quality
        let payload = try JSONSerialization.data(withJSONObject: json)
        // A historical selected result must not be relabeled with today's analyzer semantics.
        try await store.insertAnalysis(copyAnalysis(base, version: "workout-analyzer-v1.2", payload: payload))
        let artifact = try await store.exportWorkoutAnalysis(.init(sessionID: session.sessionID,
            exactProfileLocalIdentifier: session.profileLocalIdentifier))
        defer { try? FileManager.default.removeItem(at: artifact.fileURL.deletingLastPathComponent()) }
        let metadata = metadataRows(try parseCSV(artifact.fileURL))
        XCTAssertEqual(metadata["stored_analysis_detail_status"], "available")
        XCTAssertEqual(metadata["analyzer_version"], "workout-analyzer-v1.2")
        XCTAssertFalse(try XCTUnwrap(metadata["stored_analysis_coverage_semantics"]).contains("v1.4"))
        let coverage = try jsonObject(metadata["stored_analysis_heart_rate_duration_coverage_json"])
        XCTAssertEqual(coverage["coveredSeconds"] as? Double, 0)
        XCTAssertTrue(coverage["coverageRatio"] is NSNull)
        let csv = try String(contentsOf: artifact.fileURL, encoding: .utf8)
        for sentinel in ["private-profile-sentinel", "private-device-sentinel", "private-source-sentinel"] {
            XCTAssertFalse(csv.contains(sentinel))
        }
        XCTAssertTrue(csv.contains("opaque-metric-definition"))
        XCTAssertTrue(csv.contains("opaque-analysis-exclusion"))
    }

    private func metadataRows(_ rows: [[String]]) -> [String: String] {
        guard let header = rows.first, let key = header.firstIndex(of: "metadata_key"),
              let value = header.firstIndex(of: "metadata_value") else { return [:] }
        return Dictionary(uniqueKeysWithValues: rows.dropFirst().filter { $0[1] == "metadata" }.map { ($0[key], $0[value]) })
    }

    private func jsonObject(_ value: String?) throws -> [String: Any] {
        let data = try XCTUnwrap(value?.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func copyAnalysis(_ base: WorkoutAnalysisResult, version: String? = nil,
                              schema: UInt16 = 1, payload: Data) -> WorkoutAnalysisResult {
        WorkoutAnalysisResult(analysisID: base.analysisID, recordID: base.recordID, sessionID: base.sessionID,
            analyzerVersion: version.map(AnalyzerVersion.init(rawValue:)) ?? base.analyzerVersion,
            evidenceHash: base.evidenceHash, generatedAt: base.generatedAt, qualityGrade: base.qualityGrade,
            exclusions: base.exclusions, keyMetrics: base.keyMetrics, detailSchemaVersion: schema,
            versionedDetailPayload: payload)
    }

    private func semanticsEvent(seed: Int, session: WorkoutSessionRecord, elapsedMicroseconds: Int64,
                                payload: WorkoutEventPayload) -> WorkoutEvent {
        let original = event(seed: seed, session: session, elapsedMicroseconds: elapsedMicroseconds, payload: payload)
        return WorkoutEvent(recordID: original.recordID, sessionID: original.sessionID,
            timestamp: .init(occurredAt: original.timestamp.occurredAt, recordedAt: original.timestamp.occurredAt,
                occurredElapsed: original.timestamp.occurredElapsed, recordedElapsed: original.timestamp.occurredElapsed),
            payload: original.payload)
    }

    private func semanticsSession(duration: Int64 = 60) -> WorkoutSessionRecord {
        let base = session(profile: "semantics-profile", configuration: configuration(target: 120), seed: 145)
        let configuration = ImmutableConfigurationSnapshot(id: base.configuration.id, formatVersion: 1,
            format: .canonicalJSON, canonicalPayload: Data(
                #"{"targetHeartRate":120,"heartRateZones":[90,110,130,150],"cooldownTargetHeartRate":115,"cooldownMinimumSpeedKilometresPerHour":2.0}"#.utf8),
            contentHash: base.configuration.contentHash)
        return WorkoutSessionRecord(recordID: base.recordID, sessionID: base.sessionID,
            profileLocalIdentifier: base.profileLocalIdentifier, lifecycleState: .completed,
            workoutMode: base.workoutMode, startedAt: base.startedAt,
            endedAt: base.startedAt.addingTimeInterval(Double(duration)), endedElapsed: .init(microseconds: duration * 1_000_000),
            incompleteReason: nil, appContext: base.appContext,
            versions: .init(telemetrySchema: .init(rawValue: "1.0.0"), algorithm: base.versions.algorithm,
                safetyPolicy: base.versions.safetyPolicy, workoutProtocol: base.versions.workoutProtocol),
            configuration: configuration, healthKitWorkoutIdentifier: base.healthKitWorkoutIdentifier,
            treadmill: base.treadmill, recorderHealth: .init(isComplete: true, lostCriticalRecordCount: 0,
                lostNativeRecordCount: 0, lastPersistedElapsed: .init(microseconds: duration * 1_000_000)))
    }

    func testCooldownCompletionReasonsRemainTruthfulInExport() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let session = session(profile: "cooldown-reasons", configuration: configuration(target: 110), seed: 123)
        try await store.insertSession(session)
        let reasons = ["cooldown_target_and_min_speed_reached", "cooldown_stable_reached", "cooldown_timeout"]
        for (index, reason) in reasons.enumerated() {
            try await store.insertEvent(event(
                seed: 200 + index, session: session, elapsedMicroseconds: Int64(index) * 1_000,
                payload: .sessionLifecycle(SessionLifecycleEvent(
                    previous: .running, current: .completed, reason: reason))))
        }
        let artifact = try await store.exportWorkoutAnalysis(WorkoutAnalysisExportRequest(
            sessionID: session.sessionID, exactProfileLocalIdentifier: session.profileLocalIdentifier))
        defer { try? FileManager.default.removeItem(at: artifact.fileURL.deletingLastPathComponent()) }
        let csv = try String(contentsOf: artifact.fileURL, encoding: .utf8)
        for reason in reasons { XCTAssertTrue(csv.contains(reason)) }
        XCTAssertFalse(csv.contains("opaque-reason"))
    }

    func testRollbackCompatibleLifecycleEvidenceRemainsInAnalysisExport() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let session = session(
            profile: "profile-lifecycle",
            configuration: configuration(target: 135),
            seed: 122
        )
        try await store.insertSession(session)
        let lifecycle = AppLifecycleEvent(
            previousState: .inactive,
            currentState: .background,
            workoutStage: .cooldown,
            hasCommittedWorkout: true,
            policyAction: .continueEventDriven,
            policyReason: "committed_workout_background_event_driven",
            controlLoopPermitted: true,
            heartRateProviderState: "collecting",
            lastHeartRateFactualAt: TelemetryPersistenceFixtures.baseDate,
            lastHeartRateReceivedAt: TelemetryPersistenceFixtures.baseDate
                .addingTimeInterval(1),
            lastHeartRateAgeSeconds: 2,
            treadmillConnectionState: .connected,
            treadmillControlReady: true,
            treadmillProtocol: "WalkingPad"
        )
        let payload = try AppLifecycleEvidencePersistence.payload(for: lifecycle)
        try await store.insertEvent(event(
            seed: 122,
            session: session,
            elapsedMicroseconds: 1_000_000,
            payload: payload
        ))

        let stored = try await store.fetchEvents(sessionID: session.sessionID)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(
            AppLifecycleEvidencePersistence.event(from: stored[0].payload.payload),
            lifecycle
        )

        let artifact = try await store.exportWorkoutAnalysis(
            WorkoutAnalysisExportRequest(
                sessionID: session.sessionID,
                exactProfileLocalIdentifier: session.profileLocalIdentifier
            )
        )
        defer {
            try? FileManager.default.removeItem(
                at: artifact.fileURL.deletingLastPathComponent()
            )
        }
        let csv = try String(contentsOf: artifact.fileURL, encoding: .utf8)
        XCTAssertTrue(csv.contains("app_lifecycle_background"))
        XCTAssertTrue(csv.contains("cooldown;continueEventDriven;"))
    }

    func testSingleWorkoutCSVPreservesTruthTimelineMetadataPrivacyAndDeterminism() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let configuration = ImmutableConfigurationSnapshot(
            id: ConfigurationSnapshotID(rawValue: uuid(900)),
            formatVersion: 1,
            format: .canonicalJSON,
            canonicalPayload: Data(
                #"{"targetHeartRate":135,"durationMinutes":30,"decisionIntervalSeconds":10,"adaptiveStepEnabled":true,"maximumStepKilometresPerHour":0.4,"heartRateZones":[100,120,140,160,180,200],"cooldownTargetHeartRate":115,"cooldownMinimumSpeedKilometresPerHour":1.0,"cooldownMaximumMinutes":5,"treadmill":{"protocolName":"ftms","protocolVersion":"1","minimumSpeedKilometresPerHour":0.5,"maximumSpeedKilometresPerHour":12.0,"speedIncrementKilometresPerHour":0.1}}"#.utf8
            ),
            contentHash: ContentHash(
                algorithm: .sha256,
                lowercaseHexDigest: String(repeating: "c", count: 64)
            )
        )
        let session = session(profile: "private-profile-id", configuration: configuration)
        try await store.insertSession(session)
        try await store.insertAnalysis(
            TelemetryPersistenceFixtures.analysis(
                seed: 20,
                session: session,
                version: "analyzer-v1"
            )
        )

        let heartRateSource = TelemetryPersistenceFixtures.source(seed: 21)
        let treadmillSource = TelemetryPersistenceFixtures.source(seed: 22, kind: .bluetooth)
        let heartRate = TelemetryPersistenceFixtures.heartRate(
            seed: 23,
            session: session,
            source: heartRateSource,
            arrivalOrder: 0,
            bpm: 128
        )
        let treadmill = treadmillEvidence(source: treadmillSource)
        try await store.insertFrame(
            frame(
                seed: 1,
                session: session,
                second: 0,
                heartRate: heartRate,
                treadmill: treadmill
            )
        )
        try await store.insertFrame(
            frame(
                seed: 2,
                session: session,
                second: 1,
                heartRate: heartRate,
                treadmill: nil
            )
        )
        try await store.insertFrame(
            frame(
                seed: 3,
                session: session,
                second: 3,
                heartRate: nil,
                treadmill: nil,
                gap: CanonicalGapBoundary(
                    missingSinceElapsedSecond: 2,
                    kind: .runtimeSuspensionOrStall
                )
            )
        )

        let decisionID = DecisionID(rawValue: uuid(300))
        let commandID = CommandID(rawValue: uuid(301))
        let attemptID = CommandAttemptID(rawValue: uuid(302))
        let events: [WorkoutEvent] = [
            event(
                seed: 10,
                session: session,
                elapsedMicroseconds: 0,
                payload: .workoutPhase(WorkoutPhaseTransition(previous: nil, current: .main))
            ),
            event(
                seed: 11,
                session: session,
                elapsedMicroseconds: 1_200_000,
                payload: .controlDecision(
                    ControlDecision(
                        decisionID: decisionID,
                        observationsUsed: [.heartRate(heartRate.observationID)],
                        target: .heartRate(beatsPerMinute: 135),
                        action: .enqueueSpeed(DesiredSpeedKilometresPerHour(value: 5.6)),
                        reason: .belowTarget,
                        versions: session.versions,
                        configurationSnapshotID: configuration.id
                    )
                )
            ),
            event(
                seed: 12,
                session: session,
                elapsedMicroseconds: 1_300_000,
                payload: .commandLifecycle(
                    CommandLifecycleRecord(
                        commandID: commandID,
                        decisionID: decisionID,
                        lifecycle: .enqueued(
                            kind: .setSpeed(
                                CommandedSpeed(
                                    nativeValue: 560,
                                    nativeUnit: .controllerNative(code: "ftms_hundredths_kmh")
                                )
                            )
                        )
                    )
                )
            ),
            event(
                seed: 13,
                session: session,
                elapsedMicroseconds: 1_400_000,
                payload: .commandLifecycle(
                    CommandLifecycleRecord(
                        commandID: commandID,
                        decisionID: decisionID,
                        lifecycle: .sendAttempt(attemptID: attemptID, attemptNumber: 1)
                    )
                )
            ),
            event(
                seed: 14,
                session: session,
                elapsedMicroseconds: 2_000_000,
                payload: .cooldown(CooldownEvent(lifecycle: .started, targetHeartRate: 115))
            ),
            event(
                seed: 15,
                session: session,
                elapsedMicroseconds: 2_100_000,
                payload: .treadmillEvidence(
                    .unitsTruth(
                        TreadmillUnitsTruthEvidence(
                            truth: .notRead(
                                connectionEpoch: TreadmillConnectionEpoch(rawValue: uuid(400))
                            ),
                            observedAt: session.startedAt
                        )
                    )
                )
            ),
        ]
        for event in events { try await store.insertEvent(event) }

        let request = WorkoutAnalysisExportRequest(
            sessionID: session.sessionID,
            exactProfileLocalIdentifier: session.profileLocalIdentifier,
            batchSize: 2
        )
        let beforeCounts = try await store.counts()
        let first = try await store.exportWorkoutAnalysis(request)
        defer { try? FileManager.default.removeItem(at: first.fileURL.deletingLastPathComponent()) }
        let second = try await store.exportWorkoutAnalysis(request)
        defer { try? FileManager.default.removeItem(at: second.fileURL.deletingLastPathComponent()) }

        XCTAssertEqual(
            try Data(contentsOf: first.fileURL),
            try Data(contentsOf: second.fileURL),
            "The same stored workout must produce byte-identical CSV content"
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: first.fileURL.deletingLastPathComponent(),
                includingPropertiesForKeys: nil
            ).count,
            1
        )
        XCTAssertEqual(first.diagnostics.frameRowCount, 3)
        XCTAssertEqual(first.diagnostics.eventRowCount, 5)
        XCTAssertLessThanOrEqual(first.diagnostics.maximumStoreFetchLimit, 2)
        XCTAssertLessThanOrEqual(first.diagnostics.maximumBufferedTimelineRows, 4)
        let afterCounts = try await store.counts()
        XCTAssertEqual(afterCounts, beforeCounts)

        let rows = try parseCSV(first.fileURL)
        XCTAssertTrue(rows.allSatisfy { $0.count == rows[0].count })
        let header = rows[0]
        let timeline = rows.dropFirst().map { Dictionary(uniqueKeysWithValues: zip(header, $0)) }
        let frames = timeline.filter { $0["row_type"] == "frame" }
        let exportedEvents = timeline.filter { $0["row_type"] == "event" }
        let metadata = Dictionary(
            uniqueKeysWithValues: timeline.filter { $0["row_type"] == "metadata" }.map {
                ($0["metadata_key"]!, $0["metadata_value"]!)
            }
        )

        XCTAssertEqual(frames.map { $0["elapsed_s"]! }, ["0.000000", "1.000000", "3.000000"])
        XCTAssertEqual(frames[0]["phase"], "main", "Exact event must precede a same-time frame")
        XCTAssertEqual(frames[0]["hr_evidence_ref"], frames[1]["hr_evidence_ref"])
        XCTAssertNotEqual(frames[0]["hr_evidence_ref"], heartRate.observationID.description)
        XCTAssertEqual(frames[1]["factual_speed_kmh"], "")
        XCTAssertEqual(frames[1]["treadmill_availability"], "unavailable")
        XCTAssertEqual(frames[2]["hr_bpm"], "")
        XCTAssertEqual(frames[2]["factual_speed_kmh"], "")
        XCTAssertEqual(frames[2]["gap_missing_since_s"], "2")
        XCTAssertEqual(frames[2]["gap_kind"], "runtimeSuspensionOrStall")
        XCTAssertTrue(frames[2]["quality_flags"]!.contains("factual-speed-unavailable"))
        XCTAssertFalse(frames[2].values.contains("0.000000"), "Missing evidence must not become zero")

        let decision = try XCTUnwrap(exportedEvents.first { $0["event_name"] == "control_decision" })
        XCTAssertEqual(decision["desired_speed_kmh"], "5.600000")
        XCTAssertEqual(decision["commanded_speed_native_value"], "")
        let enqueued = try XCTUnwrap(exportedEvents.first { $0["event_name"] == "command_enqueued_set_speed" })
        XCTAssertEqual(enqueued["desired_speed_kmh"], "")
        XCTAssertEqual(enqueued["commanded_speed_native_value"], "560.000000")
        XCTAssertEqual(enqueued["commanded_speed_native_unit"], "controller-native:ftms-hundredths-kmh")
        XCTAssertFalse(exportedEvents.contains { $0["event_kind"] == "treadmillEvidence" })
        XCTAssertEqual(metadata["schema_version"], WorkoutAnalysisExportArtifact.schemaVersion)
        XCTAssertEqual(metadata["analyzer_version"], "analyzer-v1")
        XCTAssertEqual(metadata["heart_rate_zones_bpm"], "100;120;140;160;180;200")
        XCTAssertEqual(metadata["treadmill_protocol"], "ftms")
        XCTAssertEqual(metadata["frame_row_count"], "3")
        XCTAssertEqual(metadata["event_row_count"], "5")
        XCTAssertEqual(metadata["heart_rate_frame_coverage_ratio"], "0.666667")
        XCTAssertEqual(metadata["factual_speed_frame_coverage_ratio"], "0.333333")
        XCTAssertEqual(metadata["gap_boundary_row_count"], "1")
        XCTAssertTrue(metadata["quality_warnings"]!.contains("canonical-gaps-present:1"))

        let csv = try String(contentsOf: first.fileURL, encoding: .utf8)
        for privateValue in [
            "private-profile-id", "private-device-model", "private-treadmill-id",
            heartRateSource.stableLocalKey, treadmillSource.stableLocalKey,
            heartRate.observationID.description, commandID.description, attemptID.description,
        ] {
            XCTAssertFalse(csv.contains(privateValue), "CSV leaked \(privateValue)")
        }
    }

    func testProductionWalkingPadCommandEvidenceAppearsWithoutDiagnosticChatter() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let session = session(
            profile: "profile-production-command",
            configuration: configuration(target: 135),
            seed: 30
        )
        try await store.insertSession(session)

        let treadmillSource = TelemetryPersistenceFixtures.source(seed: 201, kind: .bluetooth)
        try await store.insertFrame(
            frame(
                seed: 301,
                session: session,
                second: 2,
                heartRate: nil,
                treadmill: treadmillEvidence(source: treadmillSource)
            )
        )

        let decisionID = DecisionID(rawValue: uuid(3_001))
        let commandID = CommandID(rawValue: uuid(3_002))
        let attemptID = CommandAttemptID(rawValue: uuid(3_003))
        let epoch = TreadmillConnectionEpoch(rawValue: uuid(3_004))
        let enqueuedAt = session.startedAt.addingTimeInterval(1.1)
        let sentAt = session.startedAt.addingTimeInterval(1.234_567)
        var normalizer = TreadmillObservationNormalizer()
        let observation = normalizer.normalize(
            .walkingPad(
                speedRawTenths: 55,
                rawState: 2,
                deviceState: .moving,
                checksumValid: true,
                connectionEpoch: epoch,
                receivedAt: session.startedAt.addingTimeInterval(1.4)
            ),
            unitsTruth: .valid(
                unit: .kilometresPerHour,
                connectionEpoch: epoch,
                observedAt: session.startedAt
            ),
            observationID: ObservationID(rawValue: uuid(3_005)),
            recordedAt: session.startedAt.addingTimeInterval(1.401)
        )
        let events: [(Int64, WorkoutEventPayload)] = [
            (
                1_000_000,
                .controlDecision(ControlDecision(
                    decisionID: decisionID,
                    observationsUsed: [],
                    target: .heartRate(beatsPerMinute: 135),
                    action: .enqueueSpeed(DesiredSpeedKilometresPerHour(value: 5.6)),
                    reason: .belowTarget,
                    versions: session.versions,
                    configurationSnapshotID: session.configuration.id
                ))
            ),
            (
                1_050_000,
                .treadmillEvidence(.decision(TreadmillControlDecisionEvidence(
                    decisionID: decisionID,
                    source: .heartRateControl,
                    intent: .other("private-production-decision-detail"),
                    heartRateInputs: [],
                    occurredAt: session.startedAt.addingTimeInterval(1.05),
                    connectionEpoch: epoch
                )))
            ),
            (
                1_100_000,
                .treadmillEvidence(.commandEnqueued(TreadmillCommandEnqueuedEvidence(
                    commandID: commandID,
                    decisionID: decisionID,
                    kind: .setSpeed(
                        TreadmillCommandedSpeedRepresentation.walkingPad(
                            rawControllerTenths: 56
                        )
                    ),
                    protocolKind: .walkingPad,
                    connectionEpoch: epoch,
                    enqueuedAt: enqueuedAt
                )))
            ),
            (
                1_234_567,
                .treadmillEvidence(.commandQueueDelay(TreadmillCommandQueueDelayEvidence(
                    commandID: commandID,
                    decisionID: decisionID,
                    connectionEpoch: epoch,
                    enqueuedAt: enqueuedAt,
                    sentAt: sentAt
                )))
            ),
            (
                1_234_567,
                .treadmillEvidence(.sendAttempt(TreadmillCommandSendAttemptEvidence(
                    commandID: commandID,
                    decisionID: decisionID,
                    attemptID: attemptID,
                    attemptNumber: 1,
                    protocolKind: .walkingPad,
                    connectionEpoch: epoch,
                    sentAt: sentAt,
                    writeType: .withoutResponse
                )))
            ),
            (
                1_300_000,
                .treadmillEvidence(.unitsTruth(TreadmillUnitsTruthEvidence(
                    truth: .valid(
                        unit: .kilometresPerHour,
                        connectionEpoch: epoch,
                        observedAt: session.startedAt
                    ),
                    observedAt: session.startedAt.addingTimeInterval(1.3)
                )))
            ),
            (1_401_000, .treadmillEvidence(.observation(observation))),
        ]
        for (index, item) in events.enumerated() {
            try await store.insertEvent(event(
                seed: 300 + index,
                session: session,
                elapsedMicroseconds: item.0,
                payload: item.1
            ))
        }

        let request = WorkoutAnalysisExportRequest(
            sessionID: session.sessionID,
            exactProfileLocalIdentifier: session.profileLocalIdentifier,
            batchSize: 2
        )
        let first = try await store.exportWorkoutAnalysis(request)
        defer { try? FileManager.default.removeItem(at: first.fileURL.deletingLastPathComponent()) }
        let second = try await store.exportWorkoutAnalysis(request)
        defer { try? FileManager.default.removeItem(at: second.fileURL.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: first.fileURL), try Data(contentsOf: second.fileURL))

        let rows = try parseCSV(first.fileURL)
        let header = rows[0]
        let timeline = rows.dropFirst().map { Dictionary(uniqueKeysWithValues: zip(header, $0)) }
        let frames = timeline.filter { $0["row_type"] == "frame" }
        let exportedEvents = timeline.filter { $0["row_type"] == "event" }
        let decision = try XCTUnwrap(
            exportedEvents.first { $0["event_name"] == "control_decision" }
        )
        let enqueued = try XCTUnwrap(
            exportedEvents.first { $0["event_name"] == "command_enqueued_set_speed" }
        )
        let sent = try XCTUnwrap(
            exportedEvents.first { $0["event_name"] == "command_send_attempt" }
        )

        XCTAssertEqual(
            Set(exportedEvents.compactMap { $0["event_name"] }),
            ["control_decision", "command_enqueued_set_speed", "command_send_attempt"]
        )
        XCTAssertEqual(enqueued["event_kind"], "treadmillEvidence")
        XCTAssertEqual(sent["event_kind"], "treadmillEvidence")
        XCTAssertEqual(decision["desired_speed_kmh"], "5.600000")
        XCTAssertEqual(decision["commanded_speed_native_value"], "")
        XCTAssertEqual(enqueued["desired_speed_kmh"], "")
        XCTAssertEqual(enqueued["commanded_speed_native_value"], "56.000000")
        XCTAssertEqual(
            enqueued["commanded_speed_native_unit"],
            "controller-native:walkingpad-tenths"
        )
        XCTAssertEqual(sent["elapsed_s"], "1.234567")
        XCTAssertEqual(sent["command_attempt_number"], "1")
        XCTAssertEqual(sent["event_detail"], "protocol=walkingpad;write=without-response")
        XCTAssertEqual(enqueued["command_ref"], sent["command_ref"])
        XCTAssertEqual(enqueued["decision_ref"], sent["decision_ref"])
        XCTAssertFalse(sent["attempt_ref"]!.isEmpty)
        XCTAssertEqual(try XCTUnwrap(frames.first)["factual_speed_kmh"], "5.500000")
        XCTAssertEqual(try XCTUnwrap(frames.first)["command_ref"], "")
        XCTAssertFalse(exportedEvents.contains { event in
            [
                "treadmill_decision", "treadmill_observation", "treadmill_units_truth",
                "command_queue_delay",
            ]
                .contains(event["event_name"]!)
        })

        let csv = try String(contentsOf: first.fileURL, encoding: .utf8)
        for privateValue in [
            commandID.description, attemptID.description, decisionID.description,
            epoch.description, observation.observationID.description,
            treadmillSource.stableLocalKey, "private-production-decision-detail",
        ] {
            XCTAssertFalse(csv.contains(privateValue), "CSV leaked \(privateValue)")
        }
    }

    func testProductionCommandTerminalFactsKeepUnknownAssociationAndRedactStrings() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let sentinel = "private-command@example.com/raw-protocol-label"
        let session = session(
            profile: "profile-production-terminal",
            configuration: configuration(target: 135),
            seed: 31
        )
        try await store.insertSession(session)

        let decisionID = DecisionID(rawValue: uuid(3_101))
        let commandID = CommandID(rawValue: uuid(3_102))
        let attemptID = CommandAttemptID(rawValue: uuid(3_103))
        let epoch = TreadmillConnectionEpoch(rawValue: uuid(3_104))
        let base = session.startedAt
        let payloads: [WorkoutEventPayload] = [
            .treadmillEvidence(.commandEnqueued(TreadmillCommandEnqueuedEvidence(
                commandID: commandID,
                decisionID: decisionID,
                kind: .other(sentinel),
                protocolKind: .walkingPad,
                connectionEpoch: epoch,
                enqueuedAt: base
            ))),
            .treadmillEvidence(.acknowledgement(.unresolved(
                protocolKind: .walkingPad,
                connectionEpoch: epoch,
                receivedAt: base.addingTimeInterval(1),
                recordedAt: base.addingTimeInterval(1.001)
            ))),
            .treadmillEvidence(.commandTimeout(LegacyCommandTimeoutObservation(
                protocolKind: .walkingPad,
                connectionEpoch: epoch,
                occurredAt: base.addingTimeInterval(2)
            ))),
            .treadmillEvidence(.commandFailed(TreadmillCommandFailureObservation(
                commandID: commandID,
                decisionID: decisionID,
                attemptID: attemptID,
                connectionEpoch: epoch,
                occurredAt: base.addingTimeInterval(3),
                reason: .other(sentinel)
            ))),
            .treadmillEvidence(.commandCancelled(TreadmillCommandCancellationObservation(
                commandID: commandID,
                decisionID: decisionID,
                connectionEpoch: epoch,
                occurredAt: base.addingTimeInterval(4),
                reason: .safetyGate(sentinel)
            ))),
            .treadmillEvidence(.writeResult(LegacyWriteResultObservation(
                protocolKind: .walkingPad,
                connectionEpoch: epoch,
                occurredAt: base.addingTimeInterval(5),
                status: .succeeded
            ))),
            .treadmillEvidence(.unassociatedWrite(UnassociatedLegacyWriteObservation(
                protocolKind: .walkingPad,
                connectionEpoch: epoch,
                sentAt: base.addingTimeInterval(6),
                writeType: .withoutResponse
            ))),
        ]
        for (index, payload) in payloads.enumerated() {
            try await store.insertEvent(event(
                seed: 400 + index,
                session: session,
                elapsedMicroseconds: Int64(index) * 1_000_000,
                payload: payload
            ))
        }

        let artifact = try await store.exportWorkoutAnalysis(
            WorkoutAnalysisExportRequest(
                sessionID: session.sessionID,
                exactProfileLocalIdentifier: session.profileLocalIdentifier,
                batchSize: 2
            )
        )
        defer { try? FileManager.default.removeItem(at: artifact.fileURL.deletingLastPathComponent()) }
        let rows = try parseCSV(artifact.fileURL)
        let header = rows[0]
        let events = rows.dropFirst()
            .map { Dictionary(uniqueKeysWithValues: zip(header, $0)) }
            .filter { $0["row_type"] == "event" }
        let names = Set(events.compactMap { $0["event_name"] })

        XCTAssertTrue(names.isSuperset(of: [
            "command_enqueued_other", "command_acknowledged", "command_timed_out",
            "command_failed", "command_cancelled",
        ]))
        XCTAssertFalse(names.contains("command_write_result_succeeded"))
        XCTAssertFalse(names.contains("unassociated_write"))
        for name in ["command_acknowledged", "command_timed_out"] {
            let event = try XCTUnwrap(events.first { $0["event_name"] == name })
            XCTAssertEqual(event["command_ref"], "")
            XCTAssertEqual(event["attempt_ref"], "")
            XCTAssertEqual(event["event_detail"], "association=unresolved;protocol=walkingpad")
        }
        let failed = try XCTUnwrap(events.first { $0["event_name"] == "command_failed" })
        let cancelled = try XCTUnwrap(
            events.first { $0["event_name"] == "command_cancelled" }
        )
        XCTAssertFalse(failed["command_ref"]!.isEmpty)
        XCTAssertFalse(failed["attempt_ref"]!.isEmpty)
        XCTAssertEqual(failed["event_detail"], "other")
        XCTAssertFalse(cancelled["command_ref"]!.isEmpty)
        XCTAssertEqual(cancelled["attempt_ref"], "")
        XCTAssertEqual(cancelled["event_detail"], "safety-gate")

        let csv = try String(contentsOf: artifact.fileURL, encoding: .utf8)
        XCTAssertFalse(csv.contains(sentinel))
        for privateValue in [
            commandID.description, attemptID.description, decisionID.description,
            epoch.description,
        ] {
            XCTAssertFalse(csv.contains(privateValue), "CSV leaked \(privateValue)")
        }
        XCTAssertTrue(csv.contains("opaque-command-kind"))
    }

    func testCrossProfileAndNonNativeSessionRequestsAreRejectedBeforeTimelineReads() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let session = session(profile: "profile-a", configuration: configuration(target: 135))
        try await store.insertSession(session)

        for request in [
            WorkoutAnalysisExportRequest(
                sessionID: session.sessionID,
                exactProfileLocalIdentifier: "profile-b"
            ),
            WorkoutAnalysisExportRequest(
                sessionID: SessionID(rawValue: uuid(999)),
                exactProfileLocalIdentifier: "profile-a"
            ),
        ] {
            do {
                _ = try await store.exportWorkoutAnalysis(request)
                XCTFail("Unowned or non-native selection must be rejected")
            } catch let error as TelemetryWorkoutReadError {
                XCTAssertEqual(error, .unavailable("selected-native-workout-unavailable"))
            }
        }
        let uuidProfile = "A1000000-0000-0000-0000-000000000001"
        let historicalCaseSession = self.session(
            profile: uuidProfile.lowercased(),
            configuration: configuration(target: 135),
            seed: 2
        )
        try await store.insertSession(historicalCaseSession)
        let historicalCaseArtifact = try await store.exportWorkoutAnalysis(
            WorkoutAnalysisExportRequest(
                sessionID: historicalCaseSession.sessionID,
                exactProfileLocalIdentifier: uuidProfile
            )
        )
        defer {
            try? FileManager.default.removeItem(
                at: historicalCaseArtifact.fileURL.deletingLastPathComponent()
            )
        }
        let counts = try await store.counts()
        XCTAssertEqual(counts.sessions, 2)
    }

    func testSelectedWorkoutExportIsIndependentOfUnrelatedHistorySize() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let selected = session(
            profile: "profile-selected",
            configuration: configuration(target: 135),
            seed: 10
        )
        try await store.insertSession(selected)
        try await store.insertFrame(
            frame(
                seed: 50,
                session: selected,
                second: 0,
                heartRate: nil,
                treadmill: nil
            )
        )
        let request = WorkoutAnalysisExportRequest(
            sessionID: selected.sessionID,
            exactProfileLocalIdentifier: selected.profileLocalIdentifier,
            batchSize: 16
        )
        let before = try await store.exportWorkoutAnalysis(request)
        defer { try? FileManager.default.removeItem(at: before.fileURL.deletingLastPathComponent()) }

        for index in 0..<500 {
            try await store.insertSession(
                session(
                    profile: "unrelated-profile-\(index)",
                    configuration: configuration(target: 135),
                    seed: 1_000 + index
                )
            )
        }
        let after = try await store.exportWorkoutAnalysis(request)
        defer { try? FileManager.default.removeItem(at: after.fileURL.deletingLastPathComponent()) }

        XCTAssertEqual(try Data(contentsOf: before.fileURL), try Data(contentsOf: after.fileURL))
        XCTAssertEqual(before.diagnostics.storeFetchCount, after.diagnostics.storeFetchCount)
        XCTAssertEqual(before.diagnostics.frameRowCount, after.diagnostics.frameRowCount)
        XCTAssertEqual(before.diagnostics.eventRowCount, after.diagnostics.eventRowCount)
    }

    func testFreeFormDomainStringsAreRedactedFromAnalysisCSV() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let sentinel = "private-person@example.com/device-123"
        let session = session(
            profile: "profile-private-strings",
            configuration: configuration(target: 135),
            seed: 15,
            incompleteReason: sentinel
        )
        try await store.insertSession(session)
        let decisionID = DecisionID(rawValue: uuid(610))
        let commandID = CommandID(rawValue: uuid(611))
        let events: [WorkoutEventPayload] = [
            .sessionLifecycle(SessionLifecycleEvent(
                previous: .running,
                current: .incomplete,
                incompleteReason: sentinel,
                reason: sentinel
            )),
            .workoutPhase(WorkoutPhaseTransition(previous: .main, current: .other(sentinel))),
            .sourceTransition(SourceTransition(
                previousSourceID: nil,
                currentSourceID: SourceID(rawValue: uuid(612)),
                reason: sentinel
            )),
            .connectionTransition(ConnectionTransition(
                previous: .connected,
                current: .degraded,
                reason: sentinel
            )),
            .controlDecision(ControlDecision(
                decisionID: decisionID,
                observationsUsed: [],
                target: .heartRate(beatsPerMinute: 135),
                action: .noCommand,
                reason: .safetyGate(sentinel),
                versions: session.versions,
                configurationSnapshotID: session.configuration.id
            )),
            .commandLifecycle(CommandLifecycleRecord(
                commandID: commandID,
                decisionID: decisionID,
                lifecycle: .enqueued(kind: .other(sentinel))
            )),
            .commandLifecycle(CommandLifecycleRecord(
                commandID: commandID,
                decisionID: decisionID,
                lifecycle: .cancelled(reason: .other(sentinel))
            )),
            .manualStop(ManualStopEvent(reason: sentinel)),
            .safety(SafetyEvent(
                policy: SafetyPolicyVersion(rawValue: sentinel),
                gate: sentinel,
                outcome: .blocked,
                evidence: []
            )),
            .stopEvidence(StopEvidenceEvent(
                conclusion: .unconfirmed(reason: sentinel),
                freshness: nil,
                deviceState: nil,
                factualSpeed: nil
            )),
            .recorderHealth(RecorderHealthEvent(
                kind: .loss,
                affectedRecordClass: sentinel,
                count: 1,
                detailCode: sentinel
            )),
        ]
        for (index, payload) in events.enumerated() {
            try await store.insertEvent(event(
                seed: 100 + index,
                session: session,
                elapsedMicroseconds: Int64(index) * 1_000,
                payload: payload
            ))
        }

        let artifact = try await store.exportWorkoutAnalysis(
            WorkoutAnalysisExportRequest(
                sessionID: session.sessionID,
                exactProfileLocalIdentifier: session.profileLocalIdentifier,
                batchSize: 2
            )
        )
        defer { try? FileManager.default.removeItem(at: artifact.fileURL.deletingLastPathComponent()) }
        let csv = try String(contentsOf: artifact.fileURL, encoding: .utf8)

        XCTAssertFalse(csv.contains(sentinel))
        XCTAssertTrue(csv.contains("opaque-reason"))
        XCTAssertTrue(csv.contains("reason-present"))
        XCTAssertTrue(csv.contains("opaque-command-kind"))
        XCTAssertTrue(csv.contains("opaque-record-class"))
        XCTAssertTrue(csv.contains("opaque-detail-code"))
    }

    func testCancelledWorkoutAnalysisExportRemovesOnlyTemporaryFile() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let session = session(
            profile: "profile-cancel",
            configuration: configuration(target: 135),
            seed: 20
        )
        try await store.insertSession(session)
        for second in 0..<200 {
            try await store.insertFrame(
                frame(
                    seed: 1_000 + second,
                    session: session,
                    second: Int64(second),
                    heartRate: nil,
                    treadmill: nil
                )
            )
        }
        let beforeDirectories = try analysisExportDirectories()
        let beforeCounts = try await store.counts()
        let created = expectation(description: "Temporary export file created")
        let resumeExport = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { resumeExport.continuation.finish() }
        let task = Task {
            try await store.exportWorkoutAnalysis(
                WorkoutAnalysisExportRequest(
                    sessionID: session.sessionID,
                    exactProfileLocalIdentifier: session.profileLocalIdentifier,
                    batchSize: 1
                ),
                temporaryFileCreatedForTesting: {
                    created.fulfill()
                    for await _ in resumeExport.stream { break }
                }
            )
        }
        await fulfillment(of: [created], timeout: 5)
        let activeDirectories = try analysisExportDirectories()
        XCTAssertNotEqual(
            activeDirectories,
            beforeDirectories,
            "Cancellation must occur after the export creates its temporary directory"
        )
        task.cancel()
        resumeExport.continuation.yield(())
        do {
            _ = try await task.value
            XCTFail("Cancelled analysis export unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(try analysisExportDirectories(), beforeDirectories)
        let afterCounts = try await store.counts()
        XCTAssertEqual(afterCounts, beforeCounts)
    }

    private func session(
        profile: String,
        configuration: ImmutableConfigurationSnapshot,
        seed: Int = 1,
        incompleteReason: String? = nil
    ) -> WorkoutSessionRecord {
        WorkoutSessionRecord(
            recordID: RecordID(rawValue: uuid(seed * 2 + 1)),
            sessionID: SessionID(rawValue: uuid(seed * 2 + 2)),
            profileLocalIdentifier: profile,
            lifecycleState: .completed,
            workoutMode: .heartRateControlled,
            startedAt: TelemetryPersistenceFixtures.baseDate,
            endedAt: TelemetryPersistenceFixtures.baseDate.addingTimeInterval(600),
            endedElapsed: ElapsedDuration(microseconds: 600_000_000),
            incompleteReason: incompleteReason,
            appContext: AppRuntimeContext(
                appVersion: "1.2.3",
                buildNumber: "456",
                operatingSystemVersion: "iOS 26",
                deviceModel: "private-device-model"
            ),
            versions: TelemetryPersistenceFixtures.versions(),
            configuration: configuration,
            healthKitWorkoutIdentifier: uuid(700),
            treadmill: KnownTreadmillMetadata(
                stableLocalIdentifier: "private-treadmill-id",
                model: "private-treadmill-model",
                protocolName: "ftms"
            ),
            recorderHealth: RecorderHealthSummary(
                isComplete: true,
                lostCriticalRecordCount: 0,
                lostNativeRecordCount: 0,
                lastPersistedElapsed: ElapsedDuration(microseconds: 600_000_000)
            )
        )
    }

    private func configuration(target: Int) -> ImmutableConfigurationSnapshot {
        ImmutableConfigurationSnapshot(
            id: ConfigurationSnapshotID(rawValue: uuid(800)),
            formatVersion: 1,
            format: .canonicalJSON,
            canonicalPayload: Data("{\"targetHeartRate\":\(target)}".utf8),
            contentHash: ContentHash(
                algorithm: .sha256,
                lowercaseHexDigest: String(repeating: "d", count: 64)
            )
        )
    }

    private func treadmillEvidence(source: SignalSourceIdentity) -> TreadmillFrameEvidence {
        let native = NativeTreadmillSpeed(value: 5.5, unit: .kilometresPerHour)
        return TreadmillFrameEvidence(
            observationID: ObservationID(rawValue: uuid(200)),
            recordID: RecordID(rawValue: uuid(201)),
            sourceID: source.id,
            nativeSpeed: native,
            factualSpeed: FactualSpeedKilometresPerHour.normalized(
                from: native,
                provenance: .decodedDeviceReport
            ),
            deviceState: .moving,
            measuredAt: TelemetryPersistenceFixtures.baseDate,
            receivedAt: TelemetryPersistenceFixtures.baseDate,
            evidenceElapsed: ElapsedDuration(microseconds: 0),
            ageAtMaterialization: ElapsedDuration(microseconds: 0),
            freshness: .fresh,
            provenance: .decodedDeviceReport
        )
    }

    private func frame(
        seed: Int,
        session: WorkoutSessionRecord,
        second: Int64,
        heartRate: HeartRateObservation?,
        treadmill: TreadmillFrameEvidence?,
        gap: CanonicalGapBoundary? = nil
    ) -> CanonicalFrame {
        let heartRateEvidence = heartRate.map {
            HeartRateFrameEvidence(
                observationID: $0.observationID,
                recordID: $0.recordID,
                sourceID: $0.source.id,
                beatsPerMinute: $0.beatsPerMinute,
                measuredAt: $0.timestamp.measuredAt,
                receivedAt: $0.timestamp.receivedAt,
                evidenceElapsed: $0.timestamp.effectiveElapsed,
                ageAtMaterialization: ElapsedDuration(microseconds: second * 1_000_000),
                freshness: second == 0 ? .fresh : .stale,
                provenance: $0.provenance
            )
        }
        return CanonicalFrame(
            frameID: FrameID(rawValue: uuid(100 + seed)),
            recordID: RecordID(rawValue: uuid(110 + seed)),
            sessionID: session.sessionID,
            canonicalElapsedSecond: second,
            materializedAt: RecordTimestamp(
                recordedAt: session.startedAt.addingTimeInterval(Double(second)),
                elapsed: ElapsedDuration(microseconds: second * 1_000_000)
            ),
            heartRateEvidence: heartRateEvidence,
            treadmillEvidence: treadmill,
            precedingGap: gap
        )
    }

    private func event(
        seed: Int,
        session: WorkoutSessionRecord,
        elapsedMicroseconds: Int64,
        payload: WorkoutEventPayload
    ) -> WorkoutEvent {
        WorkoutEvent(
            recordID: RecordID(rawValue: uuid(500 + seed)),
            sessionID: session.sessionID,
            timestamp: EventTimestamp(
                occurredAt: session.startedAt.addingTimeInterval(
                    Double(elapsedMicroseconds) / 1_000_000
                ),
                recordedAt: session.startedAt.addingTimeInterval(
                    Double(elapsedMicroseconds + 1_000) / 1_000_000
                ),
                occurredElapsed: ElapsedDuration(microseconds: elapsedMicroseconds),
                recordedElapsed: ElapsedDuration(microseconds: elapsedMicroseconds + 1_000)
            ),
            payload: EventPayloadEnvelope(schemaVersion: 1, payload: payload)
        )
    }

    private func parseCSV(_ url: URL) throws -> [[String]] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" {
                let next = text.index(after: index)
                if quoted, next < text.endIndex, text[next] == "\"" {
                    field.append("\"")
                    index = next
                } else {
                    quoted.toggle()
                }
            } else if character == ",", !quoted {
                row.append(field)
                field = ""
            } else if character == "\n", !quoted {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else if character != "\r" || quoted {
                field.append(character)
            }
            index = text.index(after: index)
        }
        return rows
    }

    private func analysisExportDirectories() throws -> Set<String> {
        Set(
            try FileManager.default.contentsOfDirectory(
                at: FileManager.default.temporaryDirectory,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent).filter { $0.hasPrefix("WorkoutAnalysisExport_") }
        )
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", value))!
    }
}
