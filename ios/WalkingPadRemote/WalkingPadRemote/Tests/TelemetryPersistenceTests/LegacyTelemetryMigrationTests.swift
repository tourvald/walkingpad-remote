import Foundation
import SwiftData
import TelemetryDomain
@testable import TelemetryPersistence
import XCTest

final class LegacyTelemetryMigrationTests: XCTestCase {
    private let profileID = "profile-a"

    func testJSONLAndHistoryImportReconcileExactlyAndPreserveEvidenceBoundaries() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let jsonlURL = directory.appendingPathComponent("session.jsonl")
        let healthKitID = "c9f3bda6-4642-4caf-a6a8-417124ab9c34"
        let jsonl = lines([
            object([
                "event": "session_start", "ts": 1_800_000_000,
                "session_id": "session-1", "workout_id": "workout-1",
                "healthkit_workout_uuid": healthKitID, "profile_id": profileID,
                "target_bpm": 140,
            ]),
            object([
                "event": "hr_sample", "ts": 1_800_000_002,
                "session_id": "session-1", "workout_id": "workout-1",
                "profile_id": profileID, "hr_bpm": 135, "zone_index": 2,
            ]),
            object([
                "event": "hr_sample", "ts": 1_800_000_012,
                "session_id": "session-1", "workout_id": "workout-1",
                "profile_id": profileID, "hr_bpm": 145, "zone_index": 3,
            ]),
            object([
                "event": "notify_ftms_treadmill_data", "ts": 1_800_000_015,
                "session_id": "session-1", "workout_id": "workout-1",
                "profile_id": profileID, "speed_kmh": 6.2,
            ]),
            object([
                "event": "notify_fe01", "ts": 1_800_000_016,
                "session_id": "session-1", "workout_id": "workout-1",
                "profile_id": profileID, "speed_kmh": 6.3,
            ]),
            object([
                "event": "command_write", "ts": 1_800_000_017,
                "session_id": "session-1", "workout_id": "workout-1",
                "profile_id": profileID, "command_id": "legacy-command",
                "speed_after_kmh": 6.4,
            ]),
            object([
                "event": "workout_saved", "ts": 1_800_000_030,
                "session_id": "session-1", "workout_id": "workout-1",
                "healthkit_workout_uuid": healthKitID, "profile_id": profileID,
                "duration_s": 35, "avg_bpm": 141, "avg_speed_kmh": 6.0,
                "steps": 1_234,
            ]),
            object([
                "event": "session_end", "ts": 1_800_000_040,
                "session_id": "session-1", "workout_id": "workout-1",
                "profile_id": profileID,
            ]),
            "{truncated",
        ])
        try jsonl.write(to: jsonlURL, options: .atomic)
        let history = try JSONSerialization.data(withJSONObject: [[
            "id": "workout-1",
            "healthkitWorkoutUUID": healthKitID,
            "session_id": "session-1",
            "date": 1_800_000_040,
            "durationSeconds": 40,
            "targetBpm": 140,
            "avgBpm": 139,
            "avgSpeedKmh": 5.9,
            "zoneSeconds": [0, 8, 8, 0, 0],
        ]], options: [.sortedKeys])
        let originalJSONL = try Data(contentsOf: jsonlURL)
        let originalHistory = history
        let store = try TelemetryStoreFactory.make(.inMemory)
        let report = await LegacyTelemetryMigrator(store: store).run(
            request(jsonlURL: jsonlURL, history: history)
        )

        XCTAssertEqual(report.completion, .completed)
        XCTAssertEqual(report.completedSourceCount, 2)
        XCTAssertEqual(report.failedSourceCount, 0)
        XCTAssertEqual(try Data(contentsOf: jsonlURL), originalJSONL)
        XCTAssertEqual(history, originalHistory)

        let sources = try await store.fetchLegacyMigrationSources()
        XCTAssertEqual(sources.count, 2)
        let jsonlSource = try XCTUnwrap(sources.first { $0.kind == .jsonl })
        XCTAssertEqual(jsonlSource.status, .completed)
        XCTAssertEqual(jsonlSource.parsedRecordCount, 9)
        XCTAssertEqual(jsonlSource.malformedRecordCount, 1)

        let records = try await store.fetchLegacyImportedRecords(sourceID: jsonlSource.sourceID)
        XCTAssertEqual(records.count, 8)
        XCTAssertTrue(records.allSatisfy { !$0.adaptationQualityEligible })
        XCTAssertEqual(
            try XCTUnwrap(records.first { $0.eventKind == "notify_ftms_treadmill_data" })
                .payload.speedEvidence,
            .factualDeviceReported(kilometresPerHour: 6.2, source: "ftms-treadmill-data")
        )
        XCTAssertEqual(
            try XCTUnwrap(records.first { $0.eventKind == "notify_fe01" })
                .payload.speedEvidence,
            .legacyUnknown(
                value: 6.3,
                field: "speed_kmh",
                reason: "metric-units-and-quality-not-independently-proven"
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(records.first { $0.eventKind == "command_write" })
                .payload.causalAssociation,
            .unsupportedSpecificClaim
        )
        let saved = try XCTUnwrap(records.first { $0.eventKind == "workout_saved" })
        XCTAssertTrue(saved.payload.ignoredStepFieldPresent)
        XCTAssertEqual(
            saved.payload.speedEvidence,
            .legacyEstimated(kilometresPerHour: 6.0, field: "avg_speed_kmh")
        )

        let candidates = try await store.fetchLegacyWorkoutCandidates()
        XCTAssertEqual(candidates.count, 2)
        let jsonlCandidate = try XCTUnwrap(candidates.first { $0.origin == .jsonl })
        XCTAssertEqual(jsonlCandidate.workoutIdentifier, "workout-1")
        XCTAssertEqual(jsonlCandidate.summary.timestampDerivedDurationMicroseconds, 40_000_000)
        XCTAssertEqual(jsonlCandidate.summary.legacySummaryDurationSeconds, 35)
        XCTAssertEqual(jsonlCandidate.summary.heartRateSampleCount, 2)
        XCTAssertEqual(jsonlCandidate.summary.heartRateCoveredMicroseconds, 14_000_000)
        XCTAssertEqual(jsonlCandidate.summary.heartRateUncoveredMicroseconds, 24_000_000)
        XCTAssertEqual(
            try XCTUnwrap(
                jsonlCandidate.summary.timestampDerivedAverageHeartRateBeatsPerMinute
            ),
            140.0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(jsonlCandidate.summary.timestampDerivedZoneMicroseconds?[1], 7_000_000)
        XCTAssertEqual(jsonlCandidate.summary.timestampDerivedZoneMicroseconds?[2], 7_000_000)
        XCTAssertEqual(jsonlCandidate.summary.ignoredStepFieldCount, 1)
        XCTAssertEqual(jsonlCandidate.summary.legacySessionEvidenceComplete, false)
        XCTAssertTrue(jsonlCandidate.summary.warnings.contains("legacy-records-malformed"))

        let workouts = try await store.fetchLegacyImportedWorkouts()
        XCTAssertEqual(workouts.count, 1)
        let workout = try XCTUnwrap(workouts.first)
        XCTAssertEqual(workout.identityStatus, .exact)
        XCTAssertEqual(workout.profileLocalIdentifier, profileID)
        XCTAssertEqual(workout.candidateIDs.count, 2)
        XCTAssertFalse(workout.adaptationQualityEligible)
        XCTAssertEqual(
            workout.resolvedSummary.durationMicroseconds.selected?.provenance,
            "legacy-jsonl-timestamp-derived"
        )
        XCTAssertTrue(workout.resolvedSummary.durationMicroseconds.conflict)
        XCTAssertTrue(workout.resolvedSummary.averageHeartRateBeatsPerMinute.conflict)
        XCTAssertEqual(
            workout.resolvedSummary.averageHeartRateBeatsPerMinute.selected?.provenance,
            "legacy-jsonl-timestamp-derived"
        )

        let reconciliations = try await store.fetchLegacyReconciliations()
        XCTAssertEqual(reconciliations.count, 1)
        XCTAssertEqual(reconciliations.first?.outcome, .matched)
        XCTAssertEqual(reconciliations.first?.identityKind, .workoutIdentifier)
    }

    func testCopiedJSONLAndCompletedRerunAreDeduplicatedByContent() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.jsonl")
        let copy = directory.appendingPathComponent("moved-copy.jsonl")
        let bytes = lines([
            object(["event": "session_start", "ts": 1_800_000_000, "session_id": "s1"]),
            object(["event": "session_end", "ts": 1_800_000_010, "session_id": "s1"]),
        ])
        try bytes.write(to: first)
        try bytes.write(to: copy)
        let store = try TelemetryStoreFactory.make(.inMemory)
        let migrator = LegacyTelemetryMigrator(store: store)
        let request = LegacyTelemetryMigrationRequest(
            jsonlSources: [
                .init(url: first, deterministicFallbackProfileLocalIdentifier: profileID),
                .init(url: copy, deterministicFallbackProfileLocalIdentifier: profileID),
            ],
            workoutHistorySources: [],
            knownProfileLocalIdentifiers: [profileID],
            maximumRecordsPerBatch: 1
        )

        let firstReport = await migrator.run(request)
        let firstSources = try await store.fetchLegacyMigrationSources()
        let firstRecords = try await store.fetchLegacyImportedRecords()
        let firstCandidates = try await store.fetchLegacyWorkoutCandidates()
        let firstWorkouts = try await store.fetchLegacyImportedWorkouts()
        let secondReport = await migrator.run(request)
        let secondSources = try await store.fetchLegacyMigrationSources()
        let secondRecords = try await store.fetchLegacyImportedRecords()
        let secondCandidates = try await store.fetchLegacyWorkoutCandidates()
        let secondWorkouts = try await store.fetchLegacyImportedWorkouts()

        XCTAssertEqual(firstReport.completedSourceCount, 1)
        XCTAssertEqual(firstReport.skippedSourceCount, 1)
        XCTAssertEqual(secondReport.completedSourceCount, 0)
        XCTAssertEqual(secondReport.skippedSourceCount, 2)
        XCTAssertEqual(firstSources.count, 1)
        XCTAssertEqual(firstRecords.count, 2)
        XCTAssertEqual(firstCandidates.count, 1)
        XCTAssertEqual(firstWorkouts.count, 1)
        XCTAssertEqual(secondSources, firstSources)
        XCTAssertEqual(secondRecords, firstRecords)
        XCTAssertEqual(secondCandidates, firstCandidates)
        XCTAssertEqual(secondWorkouts, firstWorkouts)
        XCTAssertEqual(try Data(contentsOf: first), bytes)
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
    }

    func testInterruptedBatchResumesFromCheckpointWithoutDuplicateRows() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("resume.jsonl")
        var fixtureRows: [Data] = []
        for index in 0..<7 {
            let event: String
            if index == 0 {
                event = "session_start"
            } else if index == 6 {
                event = "session_end"
            } else {
                event = "hr_sample"
            }
            fixtureRows.append(object([
                "event": event,
                "ts": 1_800_000_000 + index,
                "session_id": "resume-session",
                "profile_id": profileID,
                "hr_bpm": 130 + index,
            ]))
        }
        let bytes = lines(fixtureRows)
        try bytes.write(to: url)
        let store = try TelemetryStoreFactory.make(.inMemory)
        let request = LegacyTelemetryMigrationRequest(
            jsonlSources: [.init(url: url, deterministicFallbackProfileLocalIdentifier: nil)],
            workoutHistorySources: [],
            knownProfileLocalIdentifiers: [profileID],
            maximumRecordsPerBatch: 2
        )
        let interrupted = LegacyTelemetryMigrator(
            store: store,
            shouldPauseAfterCommittedBatch: { $0 == 1 }
        )

        let partial = await interrupted.run(request)
        let pausedSources = try await store.fetchLegacyMigrationSources()
        let pausedSource = try XCTUnwrap(pausedSources.first)
        let pausedRecords = try await store.fetchLegacyImportedRecords()
        XCTAssertEqual(partial.completion, .partial)
        XCTAssertEqual(pausedSource.status, .paused)
        XCTAssertEqual(pausedSource.checkpointRecordIndex, 2)
        XCTAssertEqual(pausedRecords.count, 2)
        XCTAssertEqual(try Data(contentsOf: url), bytes)

        let resumed = await LegacyTelemetryMigrator(store: store).run(request)
        let completedSources = try await store.fetchLegacyMigrationSources()
        let completedSource = try XCTUnwrap(completedSources.first)
        let records = try await store.fetchLegacyImportedRecords()
        let candidates = try await store.fetchLegacyWorkoutCandidates()
        let workouts = try await store.fetchLegacyImportedWorkouts()
        XCTAssertEqual(resumed.completion, .completed)
        XCTAssertEqual(completedSource.status, .completed)
        XCTAssertEqual(completedSource.checkpointRecordIndex, 7)
        XCTAssertEqual(records.count, 7)
        XCTAssertEqual(
            Set(records.map(\.sourceRecordIndex)),
            Set((1...7).map(Int64.init))
        )
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(workouts.count, 1)

        let rerun = await LegacyTelemetryMigrator(store: store).run(request)
        let recordsAfterRerun = try await store.fetchLegacyImportedRecords()
        XCTAssertEqual(rerun.skippedSourceCount, 1)
        XCTAssertEqual(recordsAfterRerun.count, 7)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testExactHealthKitMatchConflictsAreAuditedAndFuzzyCandidatesStaySeparate() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exactURL = directory.appendingPathComponent("exact.jsonl")
        let fuzzyURL = directory.appendingPathComponent("fuzzy.jsonl")
        let healthKitID = "18bd49c3-9ad5-4a1c-b5fa-0cb443756042"
        try lines([
            object([
                "event": "session_start", "ts": 1_800_000_000,
                "session_id": "jsonl-session", "workout_id": "jsonl-workout",
                "healthkit_workout_uuid": healthKitID, "profile_id": profileID,
            ]),
            object([
                "event": "workout_saved", "ts": 1_800_000_019,
                "session_id": "jsonl-session", "workout_id": "jsonl-workout",
                "healthkit_workout_uuid": healthKitID, "profile_id": profileID,
            ]),
            object([
                "event": "session_end", "ts": 1_800_000_020,
                "session_id": "jsonl-session", "workout_id": "jsonl-workout",
                "healthkit_workout_uuid": healthKitID, "profile_id": profileID,
            ]),
        ]).write(to: exactURL)
        try lines([
            object([
                "event": "session_start", "ts": 1_800_000_001,
                "profile_id": profileID,
            ]),
            object([
                "event": "session_end", "ts": 1_800_000_021,
                "profile_id": profileID,
            ]),
        ]).write(to: fuzzyURL)
        let history = try JSONSerialization.data(withJSONObject: [[
            "id": "history-workout",
            "healthkitWorkoutUUID": healthKitID,
            "session_id": "history-session",
            "date": 1_800_000_020,
            "durationSeconds": 20,
        ]])
        let store = try TelemetryStoreFactory.make(.inMemory)
        let request = LegacyTelemetryMigrationRequest(
            jsonlSources: [
                .init(url: exactURL, deterministicFallbackProfileLocalIdentifier: nil),
                .init(url: fuzzyURL, deterministicFallbackProfileLocalIdentifier: nil),
            ],
            workoutHistorySources: [
                .init(
                    storageKey: "workout_history_v1_profile_\(profileID)",
                    representation: history,
                    exactProfileLocalIdentifier: profileID
                ),
            ],
            knownProfileLocalIdentifiers: [profileID]
        )
        _ = await LegacyTelemetryMigrator(store: store).run(request)

        let reconciliations = try await store.fetchLegacyReconciliations()
        let candidates = try await store.fetchLegacyWorkoutCandidates()
        let importedWorkouts = try await store.fetchLegacyImportedWorkouts()
        XCTAssertEqual(reconciliations.count, 1)
        XCTAssertEqual(reconciliations.first?.outcome, .conflict)
        XCTAssertEqual(reconciliations.first?.identityKind, .healthKitWorkoutIdentifier)
        XCTAssertEqual(
            Set(reconciliations.first?.detailCodes ?? []),
            [
                "conflicting-stable-session-identifier",
                "conflicting-workout-identifier",
            ]
        )
        let exactCandidateIDs = candidates
            .filter { $0.healthKitWorkoutIdentifier == healthKitID }
            .map(\.candidateID)
        XCTAssertEqual(exactCandidateIDs.count, 2)
        XCTAssertFalse(importedWorkouts.contains {
            Set($0.candidateIDs).isSuperset(of: exactCandidateIDs)
        })
        XCTAssertEqual(
            importedWorkouts.filter {
                !$0.candidateIDs.allSatisfy { !exactCandidateIDs.contains($0) }
            }.map(\.identityStatus),
            [.conflict, .conflict]
        )
        let fuzzy = try XCTUnwrap(candidates.first {
            $0.origin == .jsonl && $0.workoutIdentifier == nil
        })
        XCTAssertTrue(fuzzy.identityUncertain)
        XCTAssertTrue(fuzzy.possibleDuplicate)
        let fuzzyWorkout = try XCTUnwrap(importedWorkouts.first {
            $0.candidateIDs == [fuzzy.candidateID]
        })
        XCTAssertEqual(fuzzyWorkout.identityStatus, .uncertain)
        XCTAssertTrue(fuzzyWorkout.possibleDuplicate)
    }

    func testHistoricalJSONLVariantsReconcileByExactStableSessionWithoutWorkoutSaved() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("historical-variant.jsonl")
        let bytes = lines([
            object([
                "event": "session_start",
                "timestamp": "2027-01-15T08:00:00Z",
                "legacy_session_id": "stable-session-34",
                "profileId": profileID,
                "target_bpm": 132,
            ]),
            object([
                "event": "hr_sample",
                "legacy_session_id": "stable-session-34",
                "profileId": profileID,
                "bpm": 131,
                "target_zone_index": 2,
            ]),
            object([
                "event": "session_end",
                "timestamp": "2027-01-15T08:00:15Z",
                "legacy_session_id": "stable-session-34",
                "profileId": profileID,
            ]),
        ])
        try bytes.write(to: url)
        let history = try JSONSerialization.data(withJSONObject: [[
            "legacy_session_id": "stable-session-34",
            "date": "2027-01-15T08:00:15Z",
            "duration_s": 15,
            "target_bpm": 132,
        ]])
        let store = try TelemetryStoreFactory.make(.inMemory)

        let report = await LegacyTelemetryMigrator(store: store).run(
            request(jsonlURL: url, history: history)
        )
        let records = try await store.fetchLegacyImportedRecords()
        let candidates = try await store.fetchLegacyWorkoutCandidates()
        let workouts = try await store.fetchLegacyImportedWorkouts()
        let reconciliations = try await store.fetchLegacyReconciliations()

        XCTAssertEqual(report.completion, .completed)
        XCTAssertFalse(records.contains { $0.eventKind == "workout_saved" })
        XCTAssertTrue(records.contains {
            $0.eventKind == "hr_sample"
                && $0.occurredAt == nil
                && $0.payload.warnings.contains("missing-or-invalid-timestamp")
        })
        XCTAssertEqual(candidates.first { $0.origin == .jsonl }?
            .summary.timestampDerivedDurationMicroseconds, 15_000_000)
        XCTAssertEqual(candidates.first { $0.origin == .jsonl }?
            .summary.missingTimestampCount, 1)
        XCTAssertEqual(candidates.first { $0.origin == .jsonl }?
            .summary.legacySessionEvidenceComplete, false)
        XCTAssertTrue(candidates.first { $0.origin == .jsonl }?
            .summary.warnings.contains("legacy-workout-saved-missing") == true)
        XCTAssertEqual(workouts.count, 1)
        XCTAssertEqual(workouts.first?.candidateIDs.count, 2)
        XCTAssertEqual(reconciliations.count, 1)
        XCTAssertEqual(reconciliations.first?.outcome, .matched)
        XCTAssertEqual(reconciliations.first?.identityKind, .stableLegacySessionIdentifier)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testExactHealthKitUUIDReconcilesWhenStrongerWorkoutIdentityIsUnavailable() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("healthkit-only.jsonl")
        let healthKitID = "e7140c31-a82f-4a1a-a36b-27a8f0dc4f9b"
        try lines([
            object([
                "event": "session_start", "ts": 1_800_000_000,
                "healthkit_workout_uuid": healthKitID, "profile_id": profileID,
            ]),
            object([
                "event": "session_end", "ts": 1_800_000_020,
                "healthkit_workout_uuid": healthKitID, "profile_id": profileID,
            ]),
        ]).write(to: url)
        let history = try JSONSerialization.data(withJSONObject: [[
            "healthkitWorkoutUUID": healthKitID,
            "date": 1_800_000_020,
            "durationSeconds": 20,
        ]])
        let store = try TelemetryStoreFactory.make(.inMemory)
        _ = await LegacyTelemetryMigrator(store: store).run(
            request(jsonlURL: url, history: history)
        )

        let workouts = try await store.fetchLegacyImportedWorkouts()
        let reconciliations = try await store.fetchLegacyReconciliations()
        XCTAssertEqual(workouts.count, 1)
        XCTAssertEqual(workouts.first?.candidateIDs.count, 2)
        XCTAssertEqual(workouts.first?.identityStatus, .exact)
        XCTAssertEqual(reconciliations.count, 1)
        XCTAssertEqual(reconciliations.first?.outcome, .matched)
        XCTAssertEqual(reconciliations.first?.identityKind, .healthKitWorkoutIdentifier)
        XCTAssertEqual(reconciliations.first?.identityValue, healthKitID)
    }

    func testTimestampWeightedHeartRateSummaryIsNotSampleCountArithmetic() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("irregular-heart-rate.jsonl")
        try lines([
            object([
                "event": "session_start", "ts": 1_800_000_000,
                "session_id": "irregular-session", "profile_id": profileID,
            ]),
            object([
                "event": "hr_sample", "ts": 1_800_000_001,
                "session_id": "irregular-session", "profile_id": profileID,
                "hr_bpm": 100, "zone_index": 1,
            ]),
            object([
                "event": "hr_sample", "ts": 1_800_000_003,
                "session_id": "irregular-session", "profile_id": profileID,
                "hr_bpm": 200, "zone_index": 5,
            ]),
            object([
                "event": "session_end", "ts": 1_800_000_010,
                "session_id": "irregular-session", "profile_id": profileID,
            ]),
        ]).write(to: url)
        let store = try TelemetryStoreFactory.make(.inMemory)
        _ = await LegacyTelemetryMigrator(store: store).run(
            LegacyTelemetryMigrationRequest(
                jsonlSources: [
                    .init(url: url, deterministicFallbackProfileLocalIdentifier: nil),
                ],
                workoutHistorySources: [],
                knownProfileLocalIdentifiers: [profileID]
            )
        )

        let candidates = try await store.fetchLegacyWorkoutCandidates()
        let candidate = try XCTUnwrap(candidates.first)
        let timestampAverage = try XCTUnwrap(
            candidate.summary.timestampDerivedAverageHeartRateBeatsPerMinute
        )
        XCTAssertEqual(candidate.summary.heartRateCoveredMicroseconds, 9_000_000)
        XCTAssertEqual(timestampAverage, 1_600.0 / 9.0, accuracy: 0.000_001)
        XCTAssertNotEqual(timestampAverage, 150.0)
    }

    func testUnknownProfilesAreUnassignedAndNeverMappedToAnActiveProfile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("unknown-profile.jsonl")
        try lines([
            object([
                "event": "session_start", "ts": 1_800_000_000,
                "session_id": "unknown-profile-session", "profile_id": "deleted-profile",
            ]),
            object([
                "event": "session_end", "ts": 1_800_000_010,
                "session_id": "unknown-profile-session", "profile_id": "deleted-profile",
            ]),
        ]).write(to: url)
        let history = try JSONSerialization.data(withJSONObject: [[
            "id": "unassigned-history", "date": 1_800_000_010,
        ]])
        let store = try TelemetryStoreFactory.make(.inMemory)
        let request = LegacyTelemetryMigrationRequest(
            jsonlSources: [
                .init(url: url, deterministicFallbackProfileLocalIdentifier: "active-profile"),
            ],
            workoutHistorySources: [
                .init(
                    storageKey: "workout_history_v1_profile_deleted-profile",
                    representation: history,
                    exactProfileLocalIdentifier: "deleted-profile"
                ),
            ],
            knownProfileLocalIdentifiers: [profileID, "active-profile"]
        )
        _ = await LegacyTelemetryMigrator(store: store).run(request)

        let records = try await store.fetchLegacyImportedRecords()
        XCTAssertTrue(records.allSatisfy { $0.profileLocalIdentifier == nil })
        XCTAssertTrue(records.contains {
            $0.payload.warnings.contains("unknown-explicit-profile")
        })
        XCTAssertTrue(records.contains {
            $0.payload.warnings.contains("profile-ownership-unknown")
        })
        let workouts = try await store.fetchLegacyImportedWorkouts()
        let activeProfileWorkouts = try await store.fetchLegacyImportedWorkouts(
            profileLocalIdentifier: "active-profile"
        )
        XCTAssertTrue(workouts.allSatisfy { $0.profileLocalIdentifier == nil })
        XCTAssertTrue(activeProfileWorkouts.isEmpty)
    }

    func testSameOriginIdentityCannotMergeAcrossProfiles() async throws {
        let history = try JSONSerialization.data(withJSONObject: [[
            "id": "shared-looking-id",
            "date": 1_800_000_000,
            "durationSeconds": 10,
        ]])
        let store = try TelemetryStoreFactory.make(.inMemory)
        _ = await LegacyTelemetryMigrator(store: store).run(
            LegacyTelemetryMigrationRequest(
                jsonlSources: [],
                workoutHistorySources: [
                    .init(
                        storageKey: "workout_history_v1_profile_profile-a",
                        representation: history,
                        exactProfileLocalIdentifier: "profile-a"
                    ),
                    .init(
                        storageKey: "workout_history_v1_profile_profile-b",
                        representation: history,
                        exactProfileLocalIdentifier: "profile-b"
                    ),
                ],
                knownProfileLocalIdentifiers: ["profile-a", "profile-b"]
            )
        )

        let workouts = try await store.fetchLegacyImportedWorkouts()
        let reconciliations = try await store.fetchLegacyReconciliations()
        XCTAssertEqual(workouts.count, 2)
        XCTAssertEqual(Set(workouts.compactMap(\.profileLocalIdentifier)), [
            "profile-a", "profile-b",
        ])
        XCTAssertTrue(reconciliations.isEmpty)
    }

    func testOverlappingHistorySnapshotsKeepSameExactIDIsolatedAcrossProfiles() async throws {
        let shared = ["id": "shared-looking-id", "durationSeconds": 10] as [String: Any]
        let profileAHistory = try JSONSerialization.data(withJSONObject: [
            shared,
            ["id": "profile-a-only", "durationSeconds": 20],
        ])
        let profileBHistory = try JSONSerialization.data(withJSONObject: [
            shared,
            ["id": "profile-b-only", "durationSeconds": 30],
        ])
        let sharedOnly = try JSONSerialization.data(withJSONObject: [shared])
        let store = try TelemetryStoreFactory.make(.inMemory)
        _ = await LegacyTelemetryMigrator(store: store).run(
            LegacyTelemetryMigrationRequest(
                jsonlSources: [],
                workoutHistorySources: [
                    .init(
                        storageKey: "profile-a-older",
                        representation: sharedOnly,
                        exactProfileLocalIdentifier: "profile-a"
                    ),
                    .init(
                        storageKey: "profile-a-newer",
                        representation: profileAHistory,
                        exactProfileLocalIdentifier: "profile-a"
                    ),
                    .init(
                        storageKey: "profile-b-older",
                        representation: sharedOnly,
                        exactProfileLocalIdentifier: "profile-b"
                    ),
                    .init(
                        storageKey: "profile-b-newer",
                        representation: profileBHistory,
                        exactProfileLocalIdentifier: "profile-b"
                    ),
                ],
                knownProfileLocalIdentifiers: ["profile-a", "profile-b"]
            )
        )

        let candidates = try await store.fetchLegacyWorkoutCandidates()
        let workouts = try await store.fetchLegacyImportedWorkouts()
        let reconciliations = try await store.fetchLegacyReconciliations()
        let sharedCandidates = candidates.filter {
            $0.workoutIdentifier == "shared-looking-id"
        }

        XCTAssertEqual(candidates.count, 6)
        XCTAssertEqual(workouts.count, 4)
        XCTAssertEqual(sharedCandidates.count, 4)
        XCTAssertEqual(
            Set(workouts.compactMap(\.profileLocalIdentifier)),
            ["profile-a", "profile-b"]
        )
        for profile in ["profile-a", "profile-b"] {
            let profileSharedCandidateIDs = Set(sharedCandidates.filter {
                $0.profileLocalIdentifier == profile
            }.map(\.candidateID))
            let imported = try XCTUnwrap(workouts.first {
                Set($0.candidateIDs) == profileSharedCandidateIDs
            })
            XCTAssertEqual(imported.identityStatus, .exact)
            XCTAssertEqual(imported.profileLocalIdentifier, profile)
        }
        XCTAssertEqual(reconciliations.count, 2)
        XCTAssertTrue(reconciliations.allSatisfy {
            $0.outcome == .matched && $0.identityKind == .workoutIdentifier
        })
    }

    func testOverlappingGlobalAndFallbackProfileHistoryReconcileExactWorkoutOnce() async throws {
        let trainingLogsDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: trainingLogsDirectory) }
        let suiteName = "LegacyTelemetryMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workoutA: [String: Any] = [
            "id": "overlap-workout-a",
            "date": 1_800_000_000,
            "durationSeconds": 600,
            "avgBpm": 132,
        ]
        let workoutB: [String: Any] = [
            "id": "profile-only-workout-b",
            "date": 1_800_001_000,
            "durationSeconds": 900,
            "avgBpm": 138,
        ]
        let globalHistory = try JSONSerialization.data(
            withJSONObject: [workoutA],
            options: [.sortedKeys]
        )
        let scopedHistory = try JSONSerialization.data(
            withJSONObject: [workoutA, workoutB],
            options: [.sortedKeys]
        )
        let scopedKey = "workout_history_v1_profile_\(profileID)"
        defaults.set(globalHistory, forKey: "workout_history_v1")
        defaults.set(scopedHistory, forKey: scopedKey)

        let request = LegacyTelemetryMigrationSourceDiscovery.makeRequest(
            userDefaults: defaults,
            trainingLogsDirectory: trainingLogsDirectory,
            knownProfileLocalIdentifiers: [profileID],
            deterministicLegacyFallbackProfileLocalIdentifier: profileID,
            maximumRecordsPerBatch: 1
        )
        let store = try TelemetryStoreFactory.make(.inMemory)
        let migrator = LegacyTelemetryMigrator(store: store)

        let firstReport = await migrator.run(request)
        let firstSources = try await store.fetchLegacyMigrationSources()
        let firstCandidates = try await store.fetchLegacyWorkoutCandidates()
        let firstWorkouts = try await store.fetchLegacyImportedWorkouts()
        let firstReconciliations = try await store.fetchLegacyReconciliations()

        XCTAssertEqual(firstReport.completion, .completed)
        XCTAssertEqual(firstReport.completedSourceCount, 2)
        XCTAssertEqual(firstSources.count, 2)
        XCTAssertTrue(firstSources.allSatisfy {
            $0.kind == .workoutHistory && $0.status == .completed
        })
        XCTAssertEqual(Set(firstSources.map(\.locator)), ["workout_history_v1", scopedKey])
        XCTAssertEqual(firstCandidates.count, 3)

        let workoutACandidateIDs = firstCandidates
            .filter { $0.workoutIdentifier == "overlap-workout-a" }
            .map(\.candidateID)
        let workoutBCandidate = try XCTUnwrap(firstCandidates.first {
            $0.workoutIdentifier == "profile-only-workout-b"
        })
        XCTAssertEqual(workoutACandidateIDs.count, 2)
        XCTAssertEqual(firstWorkouts.count, 2)
        let importedA = try XCTUnwrap(firstWorkouts.first {
            Set($0.candidateIDs) == Set(workoutACandidateIDs)
        })
        XCTAssertEqual(importedA.identityStatus, .exact)
        XCTAssertEqual(importedA.profileLocalIdentifier, profileID)
        XCTAssertNotNil(firstWorkouts.first {
            $0.candidateIDs == [workoutBCandidate.candidateID]
        })
        XCTAssertEqual(firstReconciliations.count, 1)
        XCTAssertEqual(firstReconciliations.first?.outcome, .matched)
        XCTAssertEqual(firstReconciliations.first?.identityKind, .workoutIdentifier)
        XCTAssertEqual(firstReconciliations.first?.identityValue, "overlap-workout-a")
        XCTAssertEqual(defaults.data(forKey: "workout_history_v1"), globalHistory)
        XCTAssertEqual(defaults.data(forKey: scopedKey), scopedHistory)

        let secondReport = await migrator.run(request)
        let secondSources = try await store.fetchLegacyMigrationSources()
        let secondCandidates = try await store.fetchLegacyWorkoutCandidates()
        let secondWorkouts = try await store.fetchLegacyImportedWorkouts()
        let secondReconciliations = try await store.fetchLegacyReconciliations()
        XCTAssertEqual(secondReport.completion, .completed)
        XCTAssertEqual(secondReport.skippedSourceCount, 2)
        XCTAssertEqual(secondSources, firstSources)
        XCTAssertEqual(secondCandidates, firstCandidates)
        XCTAssertEqual(secondWorkouts, firstWorkouts)
        XCTAssertEqual(secondReconciliations, firstReconciliations)
        XCTAssertEqual(defaults.data(forKey: "workout_history_v1"), globalHistory)
        XCTAssertEqual(defaults.data(forKey: scopedKey), scopedHistory)
    }

    func testMalformedHistoryFailureIsAuditedAndRepresentationsStayImmutable() async throws {
        let history = Data("{not-an-array}".utf8)
        let original = history
        let store = try TelemetryStoreFactory.make(.inMemory)
        let request = LegacyTelemetryMigrationRequest(
            jsonlSources: [],
            workoutHistorySources: [
                .init(
                    storageKey: "workout_history_v1",
                    representation: history,
                    exactProfileLocalIdentifier: profileID
                ),
            ],
            knownProfileLocalIdentifiers: [profileID]
        )

        let report = await LegacyTelemetryMigrator(store: store).run(request)
        let sources = try await store.fetchLegacyMigrationSources()
        let records = try await store.fetchLegacyImportedRecords()
        let candidates = try await store.fetchLegacyWorkoutCandidates()
        XCTAssertEqual(report.completion, .failed)
        XCTAssertEqual(report.failedSourceCount, 1)
        let source = try XCTUnwrap(sources.first)
        XCTAssertEqual(source.status, .failed)
        XCTAssertEqual(source.errorCode, "workout-history-source-failed")
        XCTAssertEqual(history, original)
        XCTAssertTrue(records.isEmpty)
        XCTAssertTrue(candidates.isEmpty)
    }

    func testFailureAfterCommittedHistoryBatchKeepsValidPrefixAndDoesNotReinsertIt() async throws {
        let history = Data("[{\"id\":\"committed-prefix\",\"durationSeconds\":10},".utf8)
        let original = history
        let store = try TelemetryStoreFactory.make(.inMemory)
        let request = LegacyTelemetryMigrationRequest(
            jsonlSources: [],
            workoutHistorySources: [
                .init(
                    storageKey: "workout_history_v1_profile_\(profileID)",
                    representation: history,
                    exactProfileLocalIdentifier: profileID
                ),
            ],
            knownProfileLocalIdentifiers: [profileID],
            maximumRecordsPerBatch: 1
        )

        let firstReport = await LegacyTelemetryMigrator(store: store).run(request)
        let firstSources = try await store.fetchLegacyMigrationSources()
        let firstRecords = try await store.fetchLegacyImportedRecords()
        let firstCandidates = try await store.fetchLegacyWorkoutCandidates()
        XCTAssertEqual(firstReport.completion, .failed)
        XCTAssertEqual(firstSources.first?.status, .failed)
        XCTAssertEqual(firstSources.first?.checkpointRecordIndex, 1)
        XCTAssertEqual(firstRecords.count, 1)
        XCTAssertEqual(firstCandidates.count, 1)
        XCTAssertEqual(history, original)

        let secondReport = await LegacyTelemetryMigrator(store: store).run(request)
        let secondSources = try await store.fetchLegacyMigrationSources()
        let secondRecords = try await store.fetchLegacyImportedRecords()
        let secondCandidates = try await store.fetchLegacyWorkoutCandidates()
        XCTAssertEqual(secondReport.completion, .failed)
        XCTAssertEqual(secondSources.first?.status, .failed)
        XCTAssertEqual(secondRecords, firstRecords)
        XCTAssertEqual(secondCandidates, firstCandidates)
        XCTAssertEqual(history, original)
    }

    func testSourceDiscoveryReadsExactStoredRepresentationsWithoutMutation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let jsonl = directory.appendingPathComponent("a.jsonl")
        let ignored = directory.appendingPathComponent("ignored.txt")
        let jsonlBytes = lines([object(["event": "session_start"])])
        try jsonlBytes.write(to: jsonl)
        try Data("ignored".utf8).write(to: ignored)
        let suiteName = "LegacyTelemetryMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profileHistory = Data("[]".utf8)
        let globalHistory = Data("[ { \"id\" : \"legacy\" } ]".utf8)
        defaults.set(profileHistory, forKey: "workout_history_v1_profile_profile-a")
        defaults.set(globalHistory, forKey: "workout_history_v1")

        let request = LegacyTelemetryMigrationSourceDiscovery.makeRequest(
            userDefaults: defaults,
            trainingLogsDirectory: directory,
            knownProfileLocalIdentifiers: ["PROFILE-A", "active-profile"],
            deterministicLegacyFallbackProfileLocalIdentifier: "PROFILE-A"
        )

        XCTAssertEqual(
            request.jsonlSources.map { $0.url.standardizedFileURL.path },
            [jsonl.standardizedFileURL.path]
        )
        XCTAssertEqual(request.jsonlSources.first?.deterministicFallbackProfileLocalIdentifier, profileID)
        XCTAssertEqual(request.workoutHistorySources.count, 2)
        XCTAssertEqual(
            request.workoutHistorySources.first {
                $0.storageKey == "workout_history_v1_profile_profile-a"
            }?.representation,
            profileHistory
        )
        XCTAssertEqual(
            request.workoutHistorySources.first { $0.storageKey == "workout_history_v1" }?
                .exactProfileLocalIdentifier,
            profileID
        )
        XCTAssertEqual(defaults.data(forKey: "workout_history_v1"), globalHistory)
        XCTAssertEqual(try Data(contentsOf: jsonl), jsonlBytes)
    }

    func testExistingSchemaV1StoreMigratesLightweightToV2WithoutLosingEvidence() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("TelemetryV2.store")
        let session = TelemetryPersistenceFixtures.session(seed: 34)

        var legacyContainer: ModelContainer? = try ModelContainer(
            for: Schema(versionedSchema: TelemetrySchemaV1.self),
            configurations: [
                ModelConfiguration(
                    "TelemetryV1MigrationFixture",
                    schema: Schema(versionedSchema: TelemetrySchemaV1.self),
                    url: storeURL,
                    cloudKitDatabase: .none
                ),
            ]
        )
        var legacyStore: TelemetryStore? = TelemetryStore(
            modelContainer: try XCTUnwrap(legacyContainer),
            onDiskStoreURL: storeURL
        )
        try await legacyStore?.insertSession(session)
        legacyStore = nil
        legacyContainer = nil

        let migrated = try TelemetryStoreFactory.make(.onDisk(storeURL))
        let migratedSessions = try await migrated.fetchSessions()
        let migrationSources = try await migrated.fetchLegacyMigrationSources()
        XCTAssertEqual(migratedSessions, [session])
        XCTAssertTrue(migrationSources.isEmpty)
    }

    func testBoundedReadersResumeAtCommittedOffsetsAcrossChunkAndElementBoundaries() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("chunked.jsonl")
        let firstRow = object(["event": "session_start", "session_id": "chunked"])
        let secondRow = object(["event": "session_end", "session_id": "chunked"])
        let bytes = lines([firstRow, secondRow])
        try bytes.write(to: url)

        let firstReader = try LegacyJSONLLineReader(
            url: url,
            startingAt: 0,
            nextRecordIndex: 0,
            chunkSize: 3,
            maximumLineBytes: 1_024
        )
        let first = try XCTUnwrap(firstReader.next())
        XCTAssertEqual(first.data, firstRow)
        XCTAssertEqual(first.recordIndex, 1)

        let resumedReader = try LegacyJSONLLineReader(
            url: url,
            startingAt: first.endOffset,
            nextRecordIndex: first.recordIndex,
            chunkSize: 2,
            maximumLineBytes: 1_024
        )
        let resumed = try XCTUnwrap(resumedReader.next())
        XCTAssertEqual(resumed.data, secondRow)
        XCTAssertEqual(resumed.recordIndex, 2)
        XCTAssertNil(try resumedReader.next())

        let history = try JSONSerialization.data(withJSONObject: [
            ["id": "first"],
            ["id": "second"],
        ], options: [.sortedKeys])
        var historyReader = try LegacyJSONArrayElementReader(
            data: history,
            startingAt: 0,
            nextRecordIndex: 0
        )
        let firstHistory = try XCTUnwrap(historyReader.next())
        var resumedHistoryReader = try LegacyJSONArrayElementReader(
            data: history,
            startingAt: firstHistory.endOffset,
            nextRecordIndex: firstHistory.recordIndex
        )
        let secondHistory = try XCTUnwrap(resumedHistoryReader.next())
        let secondObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(secondHistory.data))
                as? [String: String]
        )
        XCTAssertEqual(secondObject["id"], "second")
        XCTAssertEqual(secondHistory.recordIndex, 2)
        XCTAssertNil(try resumedHistoryReader.next())
    }

    private func request(jsonlURL: URL, history: Data) -> LegacyTelemetryMigrationRequest {
        LegacyTelemetryMigrationRequest(
            jsonlSources: [
                .init(url: jsonlURL, deterministicFallbackProfileLocalIdentifier: profileID),
            ],
            workoutHistorySources: [
                .init(
                    storageKey: "workout_history_v1_profile_\(profileID)",
                    representation: history,
                    exactProfileLocalIdentifier: profileID
                ),
            ],
            knownProfileLocalIdentifiers: [profileID],
            maximumRecordsPerBatch: 3
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "legacy-migration-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func object(_ value: [String: Any]) -> Data {
        // Test fixtures are deliberately serialized independently of production parsing.
        try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func lines(_ values: [Data]) -> Data {
        var result = Data()
        for value in values {
            result.append(value)
            result.append(0x0a)
        }
        return result
    }

    private func lines(_ values: [Any]) -> Data {
        lines(values.map { value in
            if let data = value as? Data { return data }
            return Data(String(describing: value).utf8)
        })
    }
}
