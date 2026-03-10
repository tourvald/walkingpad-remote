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
}
