import Foundation
import XCTest

final class LegacyTelemetryRetirementTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent("WalkingPadRemote/\(name)"), encoding: .utf8)
    }

    func testProductionHasNoLegacyWriterOrDestructiveSourceMaintenance() throws {
        let manager = try source("BluetoothManager.swift")
        for retired in ["logTrainingEvent(", "TrainingTelemetryWriter", "trainingLogFileHandle",
                        "saveLegacyShadowWorkoutHistory", "prefix(50)", "Int.random(in:",
                        "prepareTrainingLogsCsvExport", "clearTrainingLogsForActiveProfile"] {
            XCTAssertFalse(manager.contains(retired), "Retired production path: \(retired)")
        }
        XCTAssertTrue(manager.contains("telemetryV2Coordinator.observeCurrentElapsedSecond()"))
        XCTAssertTrue(manager.contains("LegacyTelemetryMigrationSourceDiscovery"))
        XCTAssertTrue(manager.contains("scheduleLegacyMigrationInBackground"))
    }

    func testDebugUsesOnlyV2Evidence() throws {
        let content = try source("ContentView.swift")
        XCTAssertFalse(content.contains("legacyShadowWriterStatusText"))
        XCTAssertFalse(content.contains("manager.refreshTrainingLogsInventory()"))
        XCTAssertTrue(content.contains("manager.prepareDiagnosticBundle"))
        XCTAssertTrue(content.contains("manager.telemetryV2WriterHealthSnapshot"))
    }
}
