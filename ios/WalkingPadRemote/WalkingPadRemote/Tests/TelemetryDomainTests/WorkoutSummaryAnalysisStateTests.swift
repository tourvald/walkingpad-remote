import Foundation
import TelemetryDomain
import XCTest

final class WorkoutSummaryAnalysisStateTests: XCTestCase {
    func testEarlyCompletedProjectionIsProcessingEvenBeforeInvalidationReadCatchesUp() {
        let projection = makeProjection(analyzed: false)
        XCTAssertEqual(projection.summaryAnalysisState(terminalResult: nil), .processing)
        XCTAssertEqual(projection.summaryAnalysisState(terminalResult: .inserted), .processing)
    }

    func testSameIDProjectionRefreshExposesFactualMetricsWhileResultRemainsOpen() {
        let pending = makeProjection(analyzed: false)
        let final = makeProjection(analyzed: true, zones: [287, 62, 69, 738, 5])
        XCTAssertEqual(pending.id, final.id)
        XCTAssertEqual(pending.summaryAnalysisState(terminalResult: nil), .processing)
        XCTAssertEqual(final.summaryAnalysisState(terminalResult: .inserted), .ready)
        XCTAssertEqual(final.zoneSeconds, [287, 62, 69, 738, 5])
        XCTAssertEqual(final.averageHeartRate, 125)
        XCTAssertEqual(final.averageSpeed?.evidenceKind, .factual)
    }

    func testGenuinelyUnavailableMetricRemainsUnavailableAfterAnalysis() {
        let final = makeProjection(analyzed: true)
        XCTAssertEqual(final.summaryAnalysisState(terminalResult: .existing), .ready)
        XCTAssertNil(final.zoneSeconds)
        XCTAssertTrue(final.quality.unavailableMetrics.contains("zoneSeconds"))
    }

    func testAnalysisFailureAndIneligibleAreExplicitAndCannotBecomeEmptySuccess() {
        for result in [PostWorkoutAnalysisTriggerResult.failed, .ineligible] {
            XCTAssertEqual(makeProjection(analyzed: false).summaryAnalysisState(terminalResult: result), .failed)
            XCTAssertEqual(makeProjection(analyzed: true).summaryAnalysisState(terminalResult: result), .failed)
        }
    }

    func testReopenUsesPersistedFinalAnalysisWithoutRuntimeOutcomeOrLegacyFallback() {
        let final = makeProjection(analyzed: true, zones: [1, 2, 3, 4, 5])
        for _ in 0..<3 {
            XCTAssertEqual(final.summaryAnalysisState(terminalResult: nil), .ready)
        }
        XCTAssertEqual(makeProjection(analyzed: true, origin: .importedLegacy)
            .summaryAnalysisState(terminalResult: nil), .failed)
    }

    private func makeProjection(
        analyzed: Bool,
        zones: [Double?]? = nil,
        origin: WorkoutProjectionOrigin = .nativeV2
    ) -> WorkoutHistoryProjection {
        WorkoutHistoryProjection(
            id: "native:00000000-0000-0000-0000-000000000001",
            origin: origin,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 200),
            durationSeconds: 100,
            targetHeartRate: 125,
            averageHeartRate: analyzed ? 125 : nil,
            averageSpeed: analyzed ? WorkoutSpeedProjection(
                kilometresPerHour: 4.2, evidenceKind: .factual, provenance: "decoded-device"
            ) : nil,
            beatsPerMetre: nil,
            zoneSeconds: zones,
            healthKitWorkoutIdentifier: nil,
            telemetrySchemaVersion: "2", appVersion: "1", buildNumber: "1",
            algorithmVersion: "test", analyzerVersion: analyzed ? "test-analyzer" : nil,
            quality: WorkoutProjectionQuality(
                lifecycleState: "completed", recorderComplete: true,
                analysisGrade: analyzed ? "high" : nil, identityStatus: "exact",
                possibleDuplicate: false, adaptationEligible: false, includedInStatistics: true,
                provenance: ["telemetry-v2-native"],
                unavailableMetrics: zones == nil ? ["zoneSeconds"] : [], warnings: []
            )
        )
    }
}
