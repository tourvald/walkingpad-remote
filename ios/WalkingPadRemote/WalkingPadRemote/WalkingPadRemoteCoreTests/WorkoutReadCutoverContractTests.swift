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

    func testPostWorkoutProjectionChangeInvalidatesStatisticsAndRekeysQuery() throws {
        XCTAssertTrue(contentSource.contains(
            #".task(id: "\(manager.workoutStatisticsKey(for: interval))|\(manager.telemetryV2ProjectionGeneration)|\(statisticsRetryGeneration[scope, default: 0])")"#
        ))
        let invalidation = try sourceSlice(
            from: "private func telemetryV2ProjectionDidChange()",
            to: "private func activeWorkoutReadFilter(", in: managerSource
        )
        XCTAssertTrue(invalidation.contains("telemetryV2ProjectionGeneration &+= 1"))
        XCTAssertTrue(invalidation.contains("telemetryV2Statistics.removeAll()"))
        XCTAssertTrue(invalidation.contains("telemetryV2StatisticsState.removeAll()"))
        XCTAssertTrue(managerSource.contains("self?.telemetryV2ProjectionDidChange()"))
    }

    func testStatisticsUIExposesExcludedWorkoutCompleteness() {
        XCTAssertTrue(contentSource.contains("stats.excludedWorkoutCount"))
        XCTAssertTrue(contentSource.contains("exclusionReasonCounts"))
        XCTAssertTrue(contentSource.contains("Исключено из агрегатов"))
    }

    func testHistoryUIExposesExactImportedHealthKitLinkageProvenance() {
        XCTAssertTrue(
            source("WorkoutHistoryRow.swift").contains("telemetry-v2-imported-exact-healthkit-linkage")
        )
        XCTAssertTrue(source("WorkoutHistoryRow.swift").contains("exact import linkage"))
    }

    func testHistoryPrimaryCardIsGlanceableAndDetailsRetainDiagnostics() throws {
        let history = source("WorkoutHistoryRow.swift")
        let row = try sourceSlice(from: "struct WorkoutHistoryRow: View", to: "private struct WorkoutHistoryZones", in: history)
        for field in ["quality.provenance", "quality.warnings", "healthKitWorkoutIdentifier", "onExportAnalysis", "lifecycleState", "analysisGrade"] {
            XCTAssertFalse(row.contains(field), field)
        }
        XCTAssertTrue(row.contains("Ср. пульс"))
        XCTAssertTrue(row.contains("Ср. скорость"))
        XCTAssertTrue(row.contains("dynamicTypeSize.isAccessibilitySize"))
        XCTAssertTrue(row.contains(".accessibilityElement(children: .combine)"))
        XCTAssertTrue(row.contains(".foregroundStyle(.secondary)"))
        XCTAssertFalse(row.contains(".red"))
        XCTAssertFalse(row.contains(".green"))
        XCTAssertTrue(history.contains(".accessibilityLabel(\"Зона"))
        XCTAssertTrue(history.contains(".accessibilityValue("))
        XCTAssertTrue(history.contains("DisclosureGroup(\"Технические сведения\")"))
        XCTAssertTrue(history.contains("entry.quality.warnings"))
        XCTAssertTrue(history.contains("entry.analyzerVersion"))
        XCTAssertTrue(history.contains("entry.healthKitWorkoutIdentifier"))
        XCTAssertTrue(history.contains("entry.beatsPerMetre"))
        XCTAssertTrue(contentSource.contains(".sheet(item: $selectedWorkout)"))
    }

    func testHistoryBadgeReportsProvenanceAndEstimatedSpeedStaysExplicit() throws {
        let history = source("WorkoutHistoryRow.swift")
        let badge = try sourceSlice(from: "static func badge(", to: "static func comparison(", in: history)
        XCTAssertTrue(badge.contains("if entry.origin == .importedLegacy { return \"Импортировано\" }"))
        XCTAssertTrue(badge.contains("Неполные данные"))
        XCTAssertTrue(badge.contains("value(entry.averageHeartRate) == nil"))
        XCTAssertTrue(badge.contains("entry.zoneSeconds?.count != 5"))
        XCTAssertTrue(history.contains("speed.evidenceKind == .legacyEstimated ? \"≈\" : \"\""))
        XCTAssertTrue(history.contains("entry.quality.unavailableMetrics"))
    }

    func testHistoryPreservesLoadedOrderingPaginationAndFailure() {
        XCTAssertTrue(contentSource.contains("ForEach(entries)"))
        XCTAssertTrue(contentSource.contains("comparison(for: entry, loaded: entries)"))
        XCTAssertTrue(contentSource.contains("Button(\"Показать ещё\", action: onLoadMore)"))
        XCTAssertTrue(contentSource.contains("Следующая страница недоступна"))
        XCTAssertTrue(contentSource.contains("История Telemetry V2 недоступна"))
        XCTAssertTrue(contentSource.contains("String($0.includedWorkoutCount)"))
        XCTAssertTrue(contentSource.contains("zoneSeconds: stats?.zoneSeconds"))
        let presentation = source("WorkoutHistoryRow.swift")
        XCTAssertFalse(presentation.contains("fetchWorkout"))
        XCTAssertFalse(presentation.contains("TelemetryStore"))
        XCTAssertFalse(presentation.contains("BluetoothManager"))
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
