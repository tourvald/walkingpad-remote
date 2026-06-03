import Foundation
import XCTest
@testable import WalkingPadCoreLogic

final class TrainingTelemetryWriterTests: XCTestCase {
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
            "speed_model_kmh": 4.1,
            "speed_target_kmh": 3.5,
            "speed_device_target_kmh": 3.5,
            "speed_reported_kmh": 3.9,
            "speed_reported_app_kmh": 3.5,
            "speed_source": "device_reported",
            "speed_has_fresh_report": true,
            "speed_report_age_s": 1,
            "stop_confirmed": false,
            "stop_confirmed_ever": true,
            "stop_assist_command": "MODE STANDBY",
            "stop_assist_sent": true,
            "stop_source": "device_reported_stale",
            "stop_report_age_s": 12,
            "stop_reported_speed_kmh": 0.3,
            "stop_reported_app_speed_kmh": 0.8,
            "stop_reported_state": 1,
            "stop_has_fresh_report": false,
            "test_run_active": true,
            "test_phase": "ramp_up",
            "test_elapsed_s": 45,
            "test_remaining_s": 135,
            "test_progress": 0.25,
            "test_target_speed_kmh": 5.0,
            "test_duration_s": 180,
            "test_peak_speed_kmh": 8.0,
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
        XCTAssertEqual(row[headers.firstIndex(of: "speed_actual_kmh")!], "3.5")
        XCTAssertEqual(row[headers.firstIndex(of: "speed_model_kmh")!], "4.1")
        XCTAssertEqual(row[headers.firstIndex(of: "speed_source")!], "device_reported")
        XCTAssertEqual(row[headers.firstIndex(of: "speed_has_fresh_report")!], "true")
        XCTAssertEqual(row[headers.firstIndex(of: "speed_report_age_s")!], "1")
        XCTAssertEqual(row[headers.firstIndex(of: "stop_confirmed")!], "false")
        XCTAssertEqual(row[headers.firstIndex(of: "stop_confirmed_ever")!], "true")
        XCTAssertEqual(row[headers.firstIndex(of: "stop_assist_command")!], "MODE STANDBY")
        XCTAssertEqual(row[headers.firstIndex(of: "stop_assist_sent")!], "true")
        XCTAssertEqual(row[headers.firstIndex(of: "stop_source")!], "device_reported_stale")
        XCTAssertEqual(row[headers.firstIndex(of: "stop_report_age_s")!], "12")
        XCTAssertEqual(row[headers.firstIndex(of: "stop_reported_speed_kmh")!], "0.3")
        XCTAssertEqual(row[headers.firstIndex(of: "stop_reported_app_speed_kmh")!], "0.8")
        XCTAssertEqual(row[headers.firstIndex(of: "stop_reported_state")!], "1")
        XCTAssertEqual(row[headers.firstIndex(of: "stop_has_fresh_report")!], "false")
        XCTAssertEqual(row[headers.firstIndex(of: "test_run_active")!], "true")
        XCTAssertEqual(row[headers.firstIndex(of: "test_phase")!], "ramp_up")
        XCTAssertEqual(row[headers.firstIndex(of: "test_elapsed_s")!], "45")
        XCTAssertEqual(row[headers.firstIndex(of: "test_remaining_s")!], "135")
        XCTAssertEqual(row[headers.firstIndex(of: "test_progress")!], "0.25")
        XCTAssertEqual(row[headers.firstIndex(of: "test_target_speed_kmh")!], "5")
        XCTAssertEqual(row[headers.firstIndex(of: "test_duration_s")!], "180")
        XCTAssertEqual(row[headers.firstIndex(of: "test_peak_speed_kmh")!], "8")
        XCTAssertEqual(row[headers.firstIndex(of: "zone1_s")!], "10")
        XCTAssertTrue(row.last?.contains("\"cooldown_finish_reason\":\"timeout\"") == true)
    }

    func testSelectJsonlFilesForExportKeepsLatestSessionsIncludingFailedAndIncomplete() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        func makeFile(name: String, start: String, events: [[String: Any]]) throws -> URL {
            let url = tempDir.appendingPathComponent(name)
            var lines: [String] = [TrainingTelemetryWriter.jsonString([
                "ts": start,
                "event": "session_start",
                "session_id": name
            ])]
            for event in events {
                lines.append(TrainingTelemetryWriter.jsonString(event))
            }
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        let file1 = try makeFile(name: "session1.jsonl", start: "2026-03-15T10:00:00.000Z", events: [
            ["ts": "2026-03-15T10:30:00.000Z", "event": "workout_saved"]
        ])
        let file2 = try makeFile(name: "session2.jsonl", start: "2026-03-16T10:00:00.000Z", events: [])
        let file3 = try makeFile(name: "session3.jsonl", start: "2026-03-17T10:00:00.000Z", events: [
            ["ts": "2026-03-17T10:10:00.000Z", "event": "hr_control_failed", "reason": "no_hr_signal"],
            ["ts": "2026-03-17T10:10:01.000Z", "event": "session_end", "reason": "hr_no_signal"]
        ])
        let file4 = try makeFile(name: "session4.jsonl", start: "2026-03-18T10:00:00.000Z", events: [
            ["ts": "2026-03-18T10:25:00.000Z", "event": "workout_saved"]
        ])
        let file5 = try makeFile(name: "session5.jsonl", start: "2026-03-19T10:00:00.000Z", events: [])

        let selected = TrainingTelemetryWriter.selectJsonlFilesForExport(
            [file3, file2, file5, file1, file4],
            scope: .lastSessions(3)
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

        let inventory = TrainingTelemetryWriter.trainingLogsInventory(
            [legacy, profileA1, profileA2, profileB],
            matchingProfileID: "profile-a",
            legacyFallbackProfileID: "profile-a"
        )

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
            scope: .allCompleted
        )

        XCTAssertEqual(selected, [complete1, complete2])
    }

    func testSummarizeJsonlFileMarksFailedOutcomeAndHrReason() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("failed-session.jsonl")
        let lines = [
            TrainingTelemetryWriter.jsonString([
                "ts": "2026-04-21T07:00:00.000Z",
                "event": "session_start",
                "session_id": "session-failed",
                "profile_id": "profile-1",
                "profile_label": "Dima"
            ]),
            TrainingTelemetryWriter.jsonString([
                "ts": "2026-04-21T07:10:00.000Z",
                "event": "hr_control_failed",
                "reason": "no_hr_signal"
            ]),
            TrainingTelemetryWriter.jsonString([
                "ts": "2026-04-21T07:10:01.000Z",
                "event": "session_end",
                "reason": "hr_no_signal"
            ]),
            TrainingTelemetryWriter.jsonString([
                "ts": "2026-04-21T07:10:02.000Z",
                "event": "workout_not_saved",
                "reason": "failed"
            ])
        ]
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

        let summary = TrainingTelemetryWriter.summarizeJsonlFile(url)

        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.sessionID, "session-failed")
        XCTAssertEqual(summary?.outcome, .failed)
        XCTAssertEqual(summary?.sessionEndReason, "hr_no_signal")
        XCTAssertEqual(summary?.hrFailureReason, "no_hr_signal")
        XCTAssertEqual(summary?.containsSavedWorkout, false)
        XCTAssertEqual(summary?.containsFailedWorkout, true)
        XCTAssertEqual(summary?.profileID, "profile-1")
    }

    func testHrFailureLogReportsExtractDiagnosticWindowFromRawJsonl() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("failed-session.jsonl")
        let lines = [
            TrainingTelemetryWriter.jsonString([
                "ts": "2026-04-21T07:00:00.000Z",
                "event": "session_start",
                "session_id": "session-failed"
            ]),
            TrainingTelemetryWriter.jsonString([
                "ts": "2026-04-21T07:08:00.000Z",
                "event": "hr_sample",
                "session_state": "main",
                "hr_bpm": 169
            ]),
            TrainingTelemetryWriter.jsonString([
                "ts": "2026-04-21T07:08:05.000Z",
                "event": "command_write",
                "label": "CMD hold speed"
            ]),
            TrainingTelemetryWriter.jsonString([
                "ts": "2026-04-21T07:08:10.000Z",
                "event": "hr_stream_state",
                "active": false,
                "last_age_s": 8
            ]),
            TrainingTelemetryWriter.jsonString([
                "ts": "2026-04-21T07:08:15.000Z",
                "event": "speed_target_changed",
                "speed_target_kmh": 4.2,
                "reason": "hold_no_hr"
            ]),
            TrainingTelemetryWriter.jsonString([
                "ts": "2026-04-21T07:09:00.000Z",
                "event": "hr_control_failed",
                "reason": "no_hr_signal",
                "missing_s": 60
            ]),
            TrainingTelemetryWriter.jsonString([
                "ts": "2026-04-21T07:09:01.000Z",
                "event": "session_end",
                "reason": "hr_no_signal"
            ])
        ]
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

        let reports = TrainingTelemetryWriter.hrFailureLogReports(from: [url])

        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.sessionID, "session-failed")
        XCTAssertEqual(reports.first?.reason, "Нет данных пульса")
        XCTAssertEqual(reports.first?.start, TrainingTelemetryWriter.iso8601Date("2026-04-21T07:08:10.000Z"))
        XCTAssertEqual(reports.first?.end, TrainingTelemetryWriter.iso8601Date("2026-04-21T07:09:01.000Z"))
        XCTAssertTrue(reports.first?.lines.contains(where: { $0.contains("hr_control_failed") }) == true)
        XCTAssertTrue(reports.first?.lines.contains(where: { $0.contains("session_end") }) == true)
        XCTAssertTrue(reports.first?.lines.contains(where: { $0.contains("command_write") }) == true)
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
                "ts": "2026-03-19T10:25:00.750Z",
                "event": "session_finished",
                "reason": "cooldown_timeout",
                "post_session_observation_s": 30
            ],
            [
                "ts": "2026-03-19T10:25:32.000Z",
                "event": "session_end",
                "reason": "cooldown_timeout",
                "post_session_observation_s": 30
            ]
        ]

        let row = TrainingTelemetryWriter.sessionSummaryRow(sourceFile: "session-42.jsonl", payloads: payloads)

        XCTAssertNotNil(row)
        XCTAssertEqual(row?.count, headers.count)
        XCTAssertEqual(row?[headers.firstIndex(of: "installation_id")!], "install-1")
        XCTAssertEqual(row?[headers.firstIndex(of: "profile_id")!], "profile-1")
        XCTAssertEqual(row?[headers.firstIndex(of: "profile_label")!], "Dima")
        XCTAssertEqual(row?[headers.firstIndex(of: "session_id")!], "session-42")
        XCTAssertEqual(row?[headers.firstIndex(of: "session_duration_s")!], "1500")
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
