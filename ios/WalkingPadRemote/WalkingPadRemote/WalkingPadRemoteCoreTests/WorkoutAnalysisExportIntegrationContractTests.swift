import Foundation
import XCTest

final class WorkoutAnalysisExportIntegrationContractTests: XCTestCase {
    func testHistoryExposesOnlyNativeWorkoutAnalysisAction() throws {
        let content = try source("WalkingPadRemote/ContentView.swift")
        XCTAssertTrue(content.contains("if entry.origin == .nativeV2"))
        XCTAssertTrue(content.contains("Text(\"Экспорт данных тренировки\")"))
        XCTAssertTrue(content.contains("onExportAnalysis(entry)"))
        XCTAssertTrue(content.contains(".controlSize(.large)"))
        XCTAssertTrue(content.contains(".disabled(exportingWorkoutID != nil)"))
        XCTAssertTrue(content.contains("Исходные данные не будут изменены или удалены."))
    }

    func testUIRoutesTypedExactProfileRequestWithoutDiagnosticExport() throws {
        let manager = try source("WalkingPadRemote/BluetoothManager.swift")
        let method = try slice(
            manager,
            from: "func prepareWorkoutAnalysisExport(",
            through: "func finalizeWorkoutAnalysisExport("
        )
        XCTAssertTrue(method.contains("entry.origin == .nativeV2"))
        XCTAssertTrue(method.contains("WorkoutAnalysisExportRequest("))
        XCTAssertTrue(method.contains("exactProfileLocalIdentifier: profileID.uuidString"))
        XCTAssertTrue(method.contains("telemetryV2Coordinator.exportWorkoutAnalysis"))
        XCTAssertFalse(method.contains("prepareDiagnosticBundle"))
        XCTAssertFalse(method.contains("prepareTelemetryV2Export"))
    }

    func testExportPathIsReadOnlyAndDoesNotRunAnalyzerOrDiagnosticReduction() throws {
        let coordinator = try source("Sources/TelemetryRuntime/TelemetryV2RuntimeCoordinator.swift")
        let coordinatorMethod = try slice(
            coordinator,
            from: "public func exportWorkoutAnalysis(",
            through: "public func associateHealthKitWorkout("
        )
        XCTAssertTrue(coordinatorMethod.contains("workoutReadCapability()"))
        XCTAssertFalse(coordinatorMethod.contains("prepareStoreAndRecover"))
        XCTAssertFalse(coordinatorMethod.contains("resumePendingWorkoutAnalyses"))

        let exporter = try source(
            "Sources/TelemetryPersistence/TelemetryWorkoutAnalysisExportStore.swift"
        )
        XCTAssertFalse(exporter.contains("WorkoutAnalyzerV1"))
        XCTAssertFalse(exporter.contains("exportWorkouts("))
        XCTAssertFalse(exporter.contains("modelContext.delete"))
        XCTAssertFalse(exporter.contains("removeItem(at: session"))
        XCTAssertTrue(exporter.contains("selectedKinds.contains($0.kindKey)"))
    }

    private func source(_ relativePath: String) throws -> String {
        let packageDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageDirectory.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func slice(
        _ source: String,
        from startMarker: String,
        through endMarker: String
    ) throws -> Substring {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
        let end = try XCTUnwrap(
            source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound
        )
        return source[start..<end]
    }
}
