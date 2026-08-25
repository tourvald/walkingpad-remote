import Foundation
import TelemetryDomain
@testable import TelemetryPersistence
import XCTest

final class WorkoutAnalysisExportTests: XCTestCase {
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
        let task = Task {
            try await store.exportWorkoutAnalysis(
                WorkoutAnalysisExportRequest(
                    sessionID: session.sessionID,
                    exactProfileLocalIdentifier: session.profileLocalIdentifier,
                    batchSize: 1
                )
            )
        }
        let startedDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        var activeDirectories = beforeDirectories
        while activeDirectories == beforeDirectories, ContinuousClock.now < startedDeadline {
            await Task.yield()
            activeDirectories = try analysisExportDirectories()
        }
        XCTAssertNotEqual(
            activeDirectories,
            beforeDirectories,
            "Cancellation must occur after the export creates its temporary directory"
        )
        task.cancel()
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
