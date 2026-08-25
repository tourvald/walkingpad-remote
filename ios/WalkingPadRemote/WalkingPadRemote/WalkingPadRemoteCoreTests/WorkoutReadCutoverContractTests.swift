import Foundation
import XCTest

final class WorkoutReadCutoverContractTests: XCTestCase {
    private lazy var managerSource = source("BluetoothManager.swift")
    private lazy var contentSource = source("ContentView.swift")
    private lazy var trainingLogsCardSource = source("DebugTrainingLogsCard.swift")

    func testNormalHistoryStatisticsAndExportUIUseOnlyTelemetryV2() {
        XCTAssertTrue(contentSource.contains("manager.telemetryV2WorkoutHistory"))
        XCTAssertTrue(contentSource.contains("manager.telemetryV2Statistics"))
        XCTAssertTrue(contentSource.contains("manager.prepareDiagnosticBundle"))
        XCTAssertTrue(managerSource.contains("prepareTelemetryV2Export"))
        XCTAssertFalse(contentSource.contains("manager.workoutHistory"))
        XCTAssertFalse(contentSource.contains("manager.prepareTrainingLogsCsvExport"))
        XCTAssertFalse(contentSource.contains("manager.prepareTrainingSessionSummaryCsvExport"))
        XCTAssertFalse(contentSource.contains("manager.clearTrainingLogsForActiveProfile"))
    }

    func testDebugSharesOneCancellableDiagnosticItemWithRecentDefault() {
        XCTAssertTrue(trainingLogsCardSource.contains("Поделиться диагностикой"))
        XCTAssertTrue(trainingLogsCardSource.contains(".lastCompletedWorkouts(1)"))
        XCTAssertTrue(trainingLogsCardSource.contains("presentation.diagnosticScopeOptions"))
        XCTAssertTrue(trainingLogsCardSource.contains("Отменить подготовку"))
        XCTAssertTrue(trainingLogsCardSource.contains("controllerUnitsDiagnosticReport"))
        XCTAssertTrue(trainingLogsCardSource.contains("heartRateDiagnosticReport"))
        XCTAssertFalse(trainingLogsCardSource.contains("Export Training CSV"))
        XCTAssertFalse(trainingLogsCardSource.contains("Export Session Summary"))
        XCTAssertFalse(trainingLogsCardSource.contains("onExportRaw"))
        XCTAssertFalse(trainingLogsCardSource.contains("onExportSessionSummary"))

        XCTAssertTrue(contentSource.contains("Все доступные тренировки"))
        XCTAssertTrue(contentSource.contains("Последние "))
        XCTAssertTrue(contentSource.contains("Данные о здоровье"))
        XCTAssertTrue(contentSource.contains("activityItems: [artifact.archiveURL]"))
        XCTAssertFalse(contentSource.contains("activityItems: artifact.fileURLs"))
        XCTAssertTrue(contentSource.contains("manager.finalizeDiagnosticBundle"))
        XCTAssertTrue(contentSource.contains("diagnosticBundleTask?.cancel()"))
        XCTAssertTrue(managerSource.contains("diagnosticSupportSnapshot"))
        XCTAssertTrue(managerSource.contains("DiagnosticBundlePackager.create"))
    }

    func testLegacyHistoryIsPrivateShadowEvidenceAndCannotGateStart() throws {
        XCTAssertTrue(
            managerSource.contains(
                "private var legacyShadowWorkoutHistory: [LegacyShadowWorkoutEntry] = []"
            )
        )
        XCTAssertTrue(managerSource.contains("Compatibility-only parity evidence through #37"))
        XCTAssertFalse(managerSource.contains("@Published var workoutHistory"))

        let startGate = try sourceSlice(
            from: "private func recomputeHrStartAllowed()",
            to: "private func startTelemetry()",
            in: managerSource
        )
        XCTAssertFalse(startGate.contains("telemetryV2WorkoutHistory"))
        XCTAssertFalse(startGate.contains("telemetryV2Statistics"))
        XCTAssertFalse(startGate.contains("legacyShadowWorkoutHistory"))
        XCTAssertFalse(startGate.contains("legacyShadowWriterStatusText"))
    }

    func testShadowWriteFailureIsDiagnosticOnlyAndDoesNotOwnV2SessionSuccess() throws {
        let shadowWrite = try sourceSlice(
            from: "private func saveLegacyShadowWorkoutHistory(",
            to: "private func removeStoredData(",
            in: managerSource
        )
        XCTAssertTrue(shadowWrite.contains("legacyShadowWriterStatusText"))
        XCTAssertTrue(shadowWrite.contains("appendLog("))
        XCTAssertFalse(shadowWrite.contains("throw"))
        XCTAssertFalse(shadowWrite.contains("telemetryV2Coordinator"))

        let workoutSave = try sourceSlice(
            from: "private func recordHrWorkoutIfNeeded(",
            to: "private func attachHealthkitWorkoutUUID(",
            in: managerSource
        )
        XCTAssertTrue(workoutSave.contains("saveLegacyShadowWorkoutHistory()"))
        XCTAssertFalse(workoutSave.contains("guard saveLegacyShadowWorkoutHistory"))
        XCTAssertFalse(workoutSave.contains("if saveLegacyShadowWorkoutHistory"))
    }

    func testLegacySourceEvidenceHasNoAutomaticOrExportCleanupCaller() throws {
        XCTAssertFalse(managerSource.contains("pruneTrainingLogs(in: "))

        let legacyFinalize = try sourceSlice(
            from: "func finalizeTrainingLogsCsvExport(",
            to: "private func hex(",
            in: managerSource
        )
        XCTAssertTrue(legacyFinalize.contains("source evidence preserved"))
        XCTAssertFalse(legacyFinalize.contains("cleanupExportedJsonlFiles"))
        XCTAssertFalse(legacyFinalize.contains("pruneTrainingLogs"))

        let legacyClear = try sourceSlice(
            from: "func clearTrainingLogsForActiveProfile()",
            to: "private func availableTrainingJsonlFiles(",
            in: managerSource
        )
        XCTAssertTrue(legacyClear.contains("source evidence preserved"))
        XCTAssertFalse(legacyClear.contains("cleanupExportedJsonlFiles"))
        XCTAssertFalse(legacyClear.contains("pruneTrainingLogs"))
    }

    func testStatisticsUIExposesExcludedWorkoutCompleteness() {
        XCTAssertTrue(contentSource.contains("stats.excludedWorkoutCount"))
        XCTAssertTrue(contentSource.contains("exclusionReasonCounts"))
        XCTAssertTrue(contentSource.contains("Исключено из агрегатов"))
    }

    func testHistoryUIExposesExactImportedHealthKitLinkageProvenance() {
        XCTAssertTrue(
            contentSource.contains("telemetry-v2-imported-exact-healthkit-linkage")
        )
        XCTAssertTrue(contentSource.contains("exact import linkage"))
    }

    private func source(_ fileName: String) -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("WalkingPadRemote", isDirectory: true)
        return try! String(
            contentsOf: appDirectory.appendingPathComponent(fileName),
            encoding: .utf8
        )
    }

    private func sourceSlice(
        from start: String,
        to end: String,
        in source: String
    ) throws -> String {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex)
        else {
            throw NSError(domain: "WorkoutReadCutoverContractTests", code: 1)
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }
}
