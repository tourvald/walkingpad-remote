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
            "session_id": "session-1",
            "event": "cooldown_analysis",
            "phase": "cooldown",
            "session_state": "cooldown",
            "is_hr_running": true,
            "hr_bpm": 111,
            "target_bpm": 110,
            "zone_seconds": [10, 20, 30, 40, 50],
            "zone4plus_seconds": 90,
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
        XCTAssertEqual(row[headers.firstIndex(of: "cooldown_finish_reason")!], "timeout")
        XCTAssertEqual(row[headers.firstIndex(of: "cooldown_timeout_blocker")!], "hr_above_target")
        XCTAssertEqual(row[headers.firstIndex(of: "cooldown_first_min_speed_elapsed_s")!], "105")
        XCTAssertEqual(row[headers.firstIndex(of: "cooldown_target_and_min_speed_s")!], "57")
        XCTAssertEqual(row[headers.firstIndex(of: "cooldown_target_and_min_speed_max_streak_s")!], "15")
        XCTAssertEqual(row[headers.firstIndex(of: "cooldown_observed_speed_kmh")!], "3.5")
        XCTAssertEqual(row[headers.firstIndex(of: "cooldown_hr_ok")!], "false")
        XCTAssertEqual(row[headers.firstIndex(of: "cooldown_min_speed_ok")!], "true")
        XCTAssertEqual(row[headers.firstIndex(of: "cooldown_stability_blocker")!], "hr_above_target")
        XCTAssertEqual(row[headers.firstIndex(of: "zone1_s")!], "10")
        XCTAssertTrue(row.last?.contains("\"cooldown_finish_reason\":\"timeout\"") == true)
    }
}
