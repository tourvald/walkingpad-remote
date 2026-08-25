import Foundation
import XCTest
@testable import WalkingPadCoreLogic

final class TrainingTelemetryWriterTests: XCTestCase {
    func testLifecycleEvidenceIsMaterializedInRawCsv() {
        let payload: [String: Any] = [
            "event": "app_lifecycle",
            "app_state_previous": "inactive",
            "app_state": "background",
            "workout_lifecycle_stage": "cooldown",
            "workout_committed": true,
            "background_policy_action": "continueEventDriven",
            "background_policy_reason": "committed_workout_background_event_driven",
            "background_control_loop_permitted": true,
            "native_hr_provider_state": "collecting",
            "hr_last_factual_at": "2026-08-25T18:15:55.000Z",
            "hr_last_received_at": "2026-08-25T18:15:57.000Z",
            "hr_last_age_s": 3.5,
            "treadmill_connection_state": "connected",
            "treadmill_control_ready": true,
            "treadmill_protocol": "walkingPad",
        ]

        let headers = TrainingTelemetryWriter.trainingCsvHeaders
        let row = TrainingTelemetryWriter.csvRow(
            sourceFile: "lifecycle.jsonl",
            payload: payload
        )

        XCTAssertEqual(row.count, headers.count)
        XCTAssertEqual(row[headers.firstIndex(of: "app_state")!], "background")
        XCTAssertEqual(row[headers.firstIndex(of: "workout_lifecycle_stage")!], "cooldown")
        XCTAssertEqual(row[headers.firstIndex(of: "workout_committed")!], "true")
        XCTAssertEqual(
            row[headers.firstIndex(of: "background_policy_action")!],
            "continueEventDriven"
        )
        XCTAssertEqual(row[headers.firstIndex(of: "native_hr_provider_state")!], "collecting")
        XCTAssertEqual(row[headers.firstIndex(of: "hr_last_age_s")!], "3.5")
        XCTAssertEqual(row[headers.firstIndex(of: "treadmill_control_ready")!], "true")
    }

    func testStopTruthFieldsAreMaterializedInRawCsv() {
        let payload: [String: Any] = [
            "event": "stop_observation_finished",
            "stop_attempt_id": "attempt-6",
            "stop_attempt_at": "2026-08-13T10:00:00.000Z",
            "stop_attempt_source": "hr",
            "stop_command_sent_at": "2026-08-13T10:00:00.100Z",
            "stop_command_status": "sent",
            "stop_confirmed_ever": true,
            "stop_currently_confirmed": false,
            "stop_invalidation_reason": "subsequent_device_motion",
            "stop_peripheral_id": "peripheral-6",
            "stop_connection_epoch": "epoch-6",
            "stop_notification_stream_id": "stream-6",
            "stop_observation_sequence": 4,
            "stop_observation_count": 4,
            "stop_observation_at": "2026-08-13T10:00:01.000Z",
            "stop_observation_age_s": 0.1,
            "stop_device_speed_raw_tenths": 0,
            "stop_device_state": 2,
            "stop_fe01_checksum_valid": true,
            "stop_fresh": true,
            "stop_confirmation_predicate": "fresh_raw_speed_zero_and_accepted_non_running_state",
            "stop_confirmation_result": "confirmed",
            "stop_first_confirmed_at": "2026-08-13T10:00:01.000Z",
            "stop_first_confirmed_elapsed_s": 1.0,
            "stop_final_result": "confirmed",
            "stop_unconfirmed_reason": "",
            "stop_freshness_limit_s": 2.0,
            "stop_observation_window_s": 30.0,
            "stop_checkpoint_delay_s": 0.5
        ]

        let headers = TrainingTelemetryWriter.trainingCsvHeaders
        let row = TrainingTelemetryWriter.csvRow(sourceFile: "stop.jsonl", payload: payload)

        XCTAssertEqual(row.count, headers.count)
        XCTAssertEqual(row[headers.firstIndex(of: "stop_attempt_id")!], "attempt-6")
        XCTAssertEqual(row[headers.firstIndex(of: "stop_command_status")!], "sent")
        XCTAssertEqual(row[headers.firstIndex(of: "stop_confirmed_ever")!], "true")
        XCTAssertEqual(row[headers.firstIndex(of: "stop_currently_confirmed")!], "false")
        XCTAssertEqual(row[headers.firstIndex(of: "stop_invalidation_reason")!], "subsequent_device_motion")
        XCTAssertEqual(row[headers.firstIndex(of: "stop_device_speed_raw_tenths")!], "0")
        XCTAssertEqual(row[headers.firstIndex(of: "stop_device_state")!], "2")
        XCTAssertEqual(row[headers.firstIndex(of: "stop_confirmation_result")!], "confirmed")
        XCTAssertEqual(row[headers.firstIndex(of: "stop_final_result")!], "confirmed")
        XCTAssertEqual(row[headers.firstIndex(of: "stop_freshness_limit_s")!], "2")
        XCTAssertEqual(row[headers.firstIndex(of: "stop_observation_window_s")!], "30")
    }

    func testCsvRowIncludesNormalizedControllerUnitsEvidence() {
        let headers = TrainingTelemetryWriter.trainingCsvHeaders
        let payload: [String: Any] = [
            "controller_units_action": "hr_control_start",
            "controller_units_motion_path": "hr_control",
            "controller_units_query_requested": true,
            "controller_units_query_trigger": "connection_ready",
            "controller_units_query_age_s": 2.5,
            "controller_units": "imperial",
            "controller_units_status": "valid",
            "controller_units_checksum_ok": true,
            "controller_units_fresh": true,
            "controller_units_age_s": 2,
            "controller_units_freshness_limit_s": 30,
            "controller_units_gate_allowed": false,
            "controller_units_block_reason": "units_imperial"
        ]

        let row = TrainingTelemetryWriter.csvRow(sourceFile: "blocked.jsonl", payload: payload)

        XCTAssertEqual(row.count, headers.count)
        XCTAssertEqual(row[headers.firstIndex(of: "controller_units")!], "imperial")
        XCTAssertEqual(row[headers.firstIndex(of: "controller_units_status")!], "valid")
        XCTAssertEqual(row[headers.firstIndex(of: "controller_units_checksum_ok")!], "true")
        XCTAssertEqual(row[headers.firstIndex(of: "controller_units_fresh")!], "true")
        XCTAssertEqual(row[headers.firstIndex(of: "controller_units_gate_allowed")!], "false")
        XCTAssertEqual(row[headers.firstIndex(of: "controller_units_block_reason")!], "units_imperial")
    }

    func testCleanupExportedJsonlFilesRemovesJsonlFilesAndCountsBytes() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let first = tempDir.appendingPathComponent("first.jsonl")
        let second = tempDir.appendingPathComponent("second.jsonl")
        let note = tempDir.appendingPathComponent("note.txt")

        try "aaa".write(to: first, atomically: true, encoding: .utf8)
        try "bbbb".write(to: second, atomically: true, encoding: .utf8)
        try "keep".write(to: note, atomically: true, encoding: .utf8)

        let summary = TrainingTelemetryWriter.cleanupExportedJsonlFiles([first, second, note])

        XCTAssertEqual(summary.removedCount, 2)
        XCTAssertEqual(summary.skippedCount, 1)
        XCTAssertGreaterThanOrEqual(summary.reclaimedBytes, 7)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path))
    }

    func testCleanupExportedJsonlFilesKeepsProtectedActiveFile() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let active = tempDir.appendingPathComponent("active.jsonl")
        let archived = tempDir.appendingPathComponent("archived.jsonl")

        try "active".write(to: active, atomically: true, encoding: .utf8)
        try "archived".write(to: archived, atomically: true, encoding: .utf8)

        let summary = TrainingTelemetryWriter.cleanupExportedJsonlFiles(
            [active, archived],
            keeping: [active]
        )

        XCTAssertEqual(summary.removedCount, 1)
        XCTAssertEqual(summary.skippedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archived.path))
    }

    func testCsvRowIncludesDetailedCooldownAnalysisColumns() {
        let headers = TrainingTelemetryWriter.trainingCsvHeaders
        let payload: [String: Any] = [
            "ts": "2026-03-10T12:00:00Z",
            "installation_id": "install-1",
            "profile_id": "profile-1",
            "profile_label": "Dima",
            "session_id": "session-1",
            "event": "cooldown_analysis",
            "phase": "cooldown",
            "session_state": "cooldown",
            "is_hr_running": true,
            "hr_bpm": 111,
            "target_bpm": 110,
            "zone_seconds": [10, 20, 30, 40, 50],
            "zone4plus_seconds": 90,
            "cooldown_target_bpm": 110,
            "cooldown_finish_reason": "timeout",
            "cooldown_timeout_blocker": "hr_above_target",
            "cooldown_first_min_speed_elapsed_s": 105,
            "cooldown_first_stable_elapsed_s": 182,
            "cooldown_hr_below_target_s": 57,
            "cooldown_min_speed_s": 164,
            "cooldown_target_and_min_speed_s": 57,
            "cooldown_target_and_min_speed_max_streak_s": 15,
            "stable_s": 15,
            "stable_required_s": 20,
            "cooldown_observed_speed_kmh": 3.5,
            "cooldown_controller_speed_kmh": 4.7,
            "cooldown_hr_ok": false,
            "cooldown_min_speed_ok": true,
            "cooldown_stable_ok": false,
            "cooldown_stability_blocker": "hr_above_target",
            "speed_actual_kmh": 3.5,
            "speed_target_kmh": 3.5,
            "speed_device_target_kmh": 3.5,
            "speed_reported_kmh": 3.9,
            "speed_reported_app_kmh": 3.5,
            "raw_note": "kept in raw json"
        ]

        let row = TrainingTelemetryWriter.csvRow(sourceFile: "sample.jsonl", payload: payload)

        XCTAssertEqual(row.count, headers.count)
        XCTAssertEqual(row[headers.firstIndex(of: "installation_id")!], "install-1")
        XCTAssertEqual(row[headers.firstIndex(of: "profile_id")!], "profile-1")
        XCTAssertEqual(row[headers.firstIndex(of: "profile_label")!], "Dima")
        XCTAssertEqual(row[headers.firstIndex(of: "cooldown_target_bpm")!], "110")
        XCTAssertEqual(row[headers.firstIndex(of: "cooldown_finish_reason")!], "timeout")
        XCTAssertEqual(row[headers.firstIndex(of: "cooldown_timeout_blocker")!], "hr_above_target")
        XCTAssertEqual(row[headers.firstIndex(of: "cooldown_first_min_speed_elapsed_s")!], "105")
        XCTAssertEqual(row[headers.firstIndex(of: "cooldown_target_and_min_speed_s")!], "57")
        XCTAssertEqual(row[headers.firstIndex(of: "cooldown_target_and_min_speed_max_streak_s")!], "15")
        XCTAssertEqual(row[headers.firstIndex(of: "cooldown_observed_speed_kmh")!], "3.5")
        XCTAssertEqual(row[headers.firstIndex(of: "cooldown_controller_speed_kmh")!], "4.7")
        XCTAssertEqual(row[headers.firstIndex(of: "cooldown_hr_ok")!], "false")
        XCTAssertEqual(row[headers.firstIndex(of: "cooldown_min_speed_ok")!], "true")
        XCTAssertEqual(row[headers.firstIndex(of: "cooldown_stability_blocker")!], "hr_above_target")
        XCTAssertEqual(row[headers.firstIndex(of: "zone1_s")!], "10")
        XCTAssertTrue(row.last?.contains("\"cooldown_finish_reason\":\"timeout\"") == true)
    }

    func testSelectJsonlFilesForExportKeepsOnlyLatestCompletedWorkouts() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        func makeFile(name: String, start: String, hasWorkoutSaved: Bool) throws -> URL {
            let url = tempDir.appendingPathComponent(name)
            var lines: [String] = [
                #"{"ts":"\#(start)","event":"session_start","session_id":"\#(name)"}"#
            ]
            if hasWorkoutSaved {
                lines.append(#"{"ts":"\#(start)","event":"workout_saved","session_id":"\#(name)"}"#)
            }
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        let file1 = try makeFile(name: "session1.jsonl", start: "2026-03-15T10:00:00.000Z", hasWorkoutSaved: true)
        let file2 = try makeFile(name: "session2.jsonl", start: "2026-03-16T10:00:00.000Z", hasWorkoutSaved: false)
        let file3 = try makeFile(name: "session3.jsonl", start: "2026-03-17T10:00:00.000Z", hasWorkoutSaved: true)
        let file4 = try makeFile(name: "session4.jsonl", start: "2026-03-18T10:00:00.000Z", hasWorkoutSaved: true)
        let file5 = try makeFile(name: "session5.jsonl", start: "2026-03-19T10:00:00.000Z", hasWorkoutSaved: true)

        let selected = TrainingTelemetryWriter.selectJsonlFilesForExport(
            [file3, file2, file5, file1, file4],
            scope: .lastCompletedWorkouts(3)
        )

        XCTAssertEqual(selected, [file3, file4, file5])
    }

    func testFilterJsonlFilesKeepsOnlyMatchingProfileAndLegacyDefault() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        func makeFile(name: String, start: String, profileID: String?) throws -> URL {
            let url = tempDir.appendingPathComponent(name)
            var payload = #"{"ts":"\#(start)","event":"session_start","session_id":"\#(name)"}"#
            if let profileID {
                payload = #"{"ts":"\#(start)","event":"session_start","session_id":"\#(name)","profile_id":"\#(profileID)"}"#
            }
            try payload.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        let legacy = try makeFile(name: "legacy.jsonl", start: "2026-03-15T10:00:00.000Z", profileID: nil)
        let profileA = try makeFile(name: "profile-a.jsonl", start: "2026-03-16T10:00:00.000Z", profileID: "profile-a")
        let profileB = try makeFile(name: "profile-b.jsonl", start: "2026-03-17T10:00:00.000Z", profileID: "profile-b")

        let filtered = TrainingTelemetryWriter.filterJsonlFiles(
            [legacy, profileA, profileB],
            matchingProfileID: "profile-a",
            legacyFallbackProfileID: "profile-a"
        )

        XCTAssertEqual(filtered, [legacy, profileA])
    }

    func testTrainingLogsInventoryCountsProfileAndBytes() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        func makeFile(
            name: String,
            start: String,
            profileID: String?,
            hasWorkoutSaved: Bool
        ) throws -> URL {
            let url = tempDir.appendingPathComponent(name)
            var sessionStart: [String: Any] = [
                "ts": start,
                "event": "session_start",
                "session_id": name
            ]
            if let profileID {
                sessionStart["profile_id"] = profileID
            }

            var lines: [String] = [TrainingTelemetryWriter.jsonString(sessionStart)]
            if hasWorkoutSaved {
                lines.append(TrainingTelemetryWriter.jsonString([
                    "ts": start,
                    "event": "workout_saved",
                    "session_id": name
                ]))
            }
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        let legacy = try makeFile(name: "legacy.jsonl", start: "2026-03-15T10:00:00.000Z", profileID: nil, hasWorkoutSaved: false)
        let profileA1 = try makeFile(name: "profile-a-1.jsonl", start: "2026-03-16T10:00:00.000Z", profileID: "profile-a", hasWorkoutSaved: true)
        let profileA2 = try makeFile(name: "profile-a-2.jsonl", start: "2026-03-17T10:00:00.000Z", profileID: "profile-a", hasWorkoutSaved: false)
        let profileB = try makeFile(name: "profile-b.jsonl", start: "2026-03-18T10:00:00.000Z", profileID: "profile-b", hasWorkoutSaved: true)

        let snapshot = TrainingTelemetryWriter.trainingLogsInventorySnapshot(
            [legacy, profileA1, profileA2, profileB],
            matchingProfileID: "profile-a",
            legacyFallbackProfileID: "profile-a"
        )
        let inventory = snapshot.inventory

        let expectedTotalBytes = [legacy, profileA1, profileA2, profileB].reduce(Int64(0)) { partial, file in
            partial + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let expectedMatchingBytes = [legacy, profileA1, profileA2].reduce(Int64(0)) { partial, file in
            partial + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }

        XCTAssertEqual(inventory.totalSessionFiles, 4)
        XCTAssertEqual(inventory.completedWorkoutFiles, 2)
        XCTAssertEqual(inventory.matchingProfileSessionFiles, 3)
        XCTAssertEqual(inventory.matchingProfileCompletedWorkoutFiles, 1)
        XCTAssertEqual(inventory.clearableSessionFiles, 3)
        XCTAssertEqual(inventory.totalBytes, expectedTotalBytes)
        XCTAssertEqual(inventory.matchingProfileBytes, expectedMatchingBytes)
        XCTAssertEqual(inventory.clearableBytes, expectedMatchingBytes)
        XCTAssertEqual(snapshot.latestMatchingProfileFile, profileA2)
    }

    func testSelectJsonlFilesForClearRespectsProfileAndProtection() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        func makeFile(
            name: String,
            start: String,
            profileID: String?,
            hasWorkoutSaved: Bool
        ) throws -> URL {
            let url = tempDir.appendingPathComponent(name)
            var sessionStart: [String: Any] = [
                "ts": start,
                "event": "session_start",
                "session_id": name
            ]
            if let profileID {
                sessionStart["profile_id"] = profileID
            }

            var lines: [String] = [TrainingTelemetryWriter.jsonString(sessionStart)]
            if hasWorkoutSaved {
                lines.append(TrainingTelemetryWriter.jsonString([
                    "ts": start,
                    "event": "workout_saved",
                    "session_id": name
                ]))
            }
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        let legacy = try makeFile(name: "legacy.jsonl", start: "2026-03-15T10:00:00.000Z", profileID: nil, hasWorkoutSaved: false)
        let profileA = try makeFile(name: "profile-a.jsonl", start: "2026-03-16T10:00:00.000Z", profileID: "profile-a", hasWorkoutSaved: true)
        let profileB = try makeFile(name: "profile-b.jsonl", start: "2026-03-17T10:00:00.000Z", profileID: "profile-b", hasWorkoutSaved: true)

        let selected = TrainingTelemetryWriter.selectJsonlFilesForClear(
            [legacy, profileA, profileB],
            matchingProfileID: "profile-a",
            legacyFallbackProfileID: "profile-a",
            keeping: [profileA.standardizedFileURL]
        )

        XCTAssertEqual(selected, [legacy])
    }

    func testTrainingLogsInventoryCountsClearableBytesWithoutProtectedActiveFile() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        func makeFile(name: String, start: String, profileID: String?) throws -> URL {
            let url = tempDir.appendingPathComponent(name)
            var sessionStart: [String: Any] = [
                "ts": start,
                "event": "session_start",
                "session_id": name
            ]
            if let profileID {
                sessionStart["profile_id"] = profileID
            }

            try TrainingTelemetryWriter.jsonString(sessionStart).write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        let active = try makeFile(name: "active.jsonl", start: "2026-03-15T10:00:00.000Z", profileID: "profile-a")
        let archived = try makeFile(name: "archived.jsonl", start: "2026-03-16T10:00:00.000Z", profileID: "profile-a")

        let inventory = TrainingTelemetryWriter.trainingLogsInventory(
            [active, archived],
            matchingProfileID: "profile-a",
            keeping: [active.standardizedFileURL]
        )

        let archivedBytes = Int64((try? archived.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)

        XCTAssertEqual(inventory.matchingProfileSessionFiles, 2)
        XCTAssertEqual(inventory.clearableSessionFiles, 1)
        XCTAssertEqual(inventory.clearableBytes, archivedBytes)
    }

    func testSelectCompletedJsonlFilesForExportAllSkipsIncompleteSessions() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        func makeFile(name: String, start: String, hasWorkoutSaved: Bool) throws -> URL {
            let url = tempDir.appendingPathComponent(name)
            var lines: [String] = [
                #"{"ts":"\#(start)","event":"session_start","session_id":"\#(name)"}"#
            ]
            if hasWorkoutSaved {
                lines.append(#"{"ts":"\#(start)","event":"workout_saved","session_id":"\#(name)"}"#)
            }
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        let complete1 = try makeFile(name: "complete1.jsonl", start: "2026-03-15T10:00:00.000Z", hasWorkoutSaved: true)
        let incomplete = try makeFile(name: "incomplete.jsonl", start: "2026-03-16T10:00:00.000Z", hasWorkoutSaved: false)
        let complete2 = try makeFile(name: "complete2.jsonl", start: "2026-03-17T10:00:00.000Z", hasWorkoutSaved: true)

        let selected = TrainingTelemetryWriter.selectCompletedJsonlFilesForExport(
            [incomplete, complete2, complete1],
            scope: .all
        )

        XCTAssertEqual(selected, [complete1, complete2])
    }

    func testSessionSummaryRowIncludesDerivedCooldownAndMainMetrics() {
        let headers = TrainingTelemetryWriter.trainingSessionSummaryHeaders
        let payloads: [[String: Any]] = [
            [
                "ts": "2026-03-19T10:00:00.000Z",
                "event": "session_start",
                "installation_id": "install-1",
                "profile_id": "profile-1",
                "profile_label": "Dima",
                "session_id": "session-42",
                "target_bpm": 140,
                "cooldown_target_bpm": 110
            ],
            [
                "ts": "2026-03-19T10:00:05.000Z",
                "event": "hr_sample",
                "session_state": "main",
                "hr_bpm": 125
            ],
            [
                "ts": "2026-03-19T10:00:10.000Z",
                "event": "hr_sample",
                "session_state": "main",
                "hr_bpm": 138
            ],
            [
                "ts": "2026-03-19T10:00:15.000Z",
                "event": "hr_sample",
                "session_state": "main",
                "hr_bpm": 151
            ],
            [
                "ts": "2026-03-19T10:20:00.000Z",
                "event": "cooldown_state",
                "phase": "cooldown",
                "session_state": "cooldown",
                "hr_bpm": 120,
                "cooldown_target_bpm": 110
            ],
            [
                "ts": "2026-03-19T10:20:01.000Z",
                "event": "cooldown_state",
                "phase": "cooldown",
                "session_state": "cooldown",
                "hr_bpm": 118,
                "cooldown_target_bpm": 110
            ],
            [
                "ts": "2026-03-19T10:20:02.000Z",
                "event": "cooldown_state",
                "phase": "cooldown",
                "session_state": "cooldown",
                "hr_bpm": 116,
                "cooldown_target_bpm": 110
            ],
            [
                "ts": "2026-03-19T10:25:00.000Z",
                "event": "cooldown_complete",
                "cooldown_start_hr_bpm": 130,
                "cooldown_end_hr_bpm": 116,
                "cooldown_peak_hr_bpm": 132,
                "cooldown_target_bpm": 110,
                "cooldown_planned_s": 300,
                "cooldown_elapsed_s": 300,
                "cooldown_target_hit_elapsed_s": -1,
                "cooldown_hr_drop_bpm": 14,
                "cooldown_hr_recovery_bpm_per_min": 2.8,
                "cooldown_finish_reason": "timeout",
                "cooldown_timeout_blocker": "hr_above_target",
                "cooldown_first_min_speed_elapsed_s": 100,
                "cooldown_first_stable_elapsed_s": -1,
                "cooldown_hr_below_target_s": 0,
                "cooldown_min_speed_s": 180,
                "cooldown_target_and_min_speed_s": 0,
                "cooldown_target_and_min_speed_max_streak_s": 0,
                "session_peak_bpm": 151,
                "main_avg_bpm": 138,
                "main_peak_bpm": 151,
                "zone_seconds": [1, 2, 3, 4, 5],
                "zone4plus_seconds": 9,
                "distance_km": 2.5,
                "duration_s": 1500
            ],
            [
                "ts": "2026-03-19T10:25:00.500Z",
                "event": "cooldown_insufficient"
            ],
            [
                "ts": "2026-03-19T10:25:01.000Z",
                "event": "workout_saved"
            ],
            [
                "ts": "2026-03-19T10:25:02.000Z",
                "event": "session_end",
                "reason": "cooldown_timeout"
            ]
        ]

        let row = TrainingTelemetryWriter.sessionSummaryRow(sourceFile: "session-42.jsonl", payloads: payloads)

        XCTAssertNotNil(row)
        XCTAssertEqual(row?.count, headers.count)
        XCTAssertEqual(row?[headers.firstIndex(of: "installation_id")!], "install-1")
        XCTAssertEqual(row?[headers.firstIndex(of: "profile_id")!], "profile-1")
        XCTAssertEqual(row?[headers.firstIndex(of: "profile_label")!], "Dima")
        XCTAssertEqual(row?[headers.firstIndex(of: "session_id")!], "session-42")
        XCTAssertEqual(row?[headers.firstIndex(of: "main_target_bpm")!], "140")
        XCTAssertEqual(row?[headers.firstIndex(of: "cooldown_target_bpm")!], "110")
        XCTAssertEqual(row?[headers.firstIndex(of: "main_samples")!], "3")
        XCTAssertEqual(row?[headers.firstIndex(of: "main_below_target_minus_10_s")!], "1")
        XCTAssertEqual(row?[headers.firstIndex(of: "main_within_plusminus_10_s")!], "1")
        XCTAssertEqual(row?[headers.firstIndex(of: "main_above_target_plus_10_s")!], "1")
        XCTAssertEqual(row?[headers.firstIndex(of: "cooldown_final_excess_bpm")!], "6")
        XCTAssertEqual(row?[headers.firstIndex(of: "cooldown_finish_reason")!], "timeout")
        XCTAssertEqual(row?[headers.firstIndex(of: "cooldown_timeout_blocker")!], "hr_above_target")
        XCTAssertEqual(row?[headers.firstIndex(of: "cooldown_insufficient")!], "true")
        XCTAssertEqual(row?[headers.firstIndex(of: "avg_speed_kmh")!], "6")
    }
}
