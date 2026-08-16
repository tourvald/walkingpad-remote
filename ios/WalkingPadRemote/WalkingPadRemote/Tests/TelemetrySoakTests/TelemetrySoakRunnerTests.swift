import XCTest
import TelemetryInstrumentation
import TelemetryRecorder
import TelemetryRuntime
import WalkingPadCoreLogic
@testable import TelemetrySoak

private struct TestControlCycleObservation: ControlCycleObservation {
    let observation: TelemetryV2PerformanceObservation

    func measureControlCycle(_ operation: () -> Void) {
        observation.measureControlCycle(operation)
    }
}

final class TelemetrySoakRunnerTests: XCTestCase {
    func testProvisionalConfigurationMatchesRecorderDefaults() {
        let configuration = TelemetrySoakRecorderConfiguration.provisionalDefault

        XCTAssertEqual(configuration.bufferCapacity, TelemetryBufferPolicy.initialDefault.capacity)
        XCTAssertEqual(
            configuration.criticalReserve,
            TelemetryBufferPolicy.initialDefault.reservedCriticalCapacity
        )
        XCTAssertEqual(
            configuration.nativeReserveFromBulk,
            TelemetryBufferPolicy.initialDefault.reservedNativeCapacity
        )
        XCTAssertEqual(
            configuration.batchRecordCount,
            TelemetryBatchPolicy.initialDefault.maximumRecordCount
        )
        XCTAssertEqual(
            Duration.milliseconds(configuration.batchIntervalMilliseconds),
            TelemetryBatchPolicy.initialDefault.maximumInterval
        )
        XCTAssertEqual(
            configuration.maximumPrecommitRetries,
            TelemetryRetryPolicy.initialDefault.maximumPrecommitRetries
        )
        XCTAssertEqual(
            Duration.milliseconds(configuration.retryDelayMilliseconds),
            TelemetryRetryPolicy.initialDefault.delay
        )
    }

    func testShortDeterministicSoakPreservesEvidenceAndCompletes() async throws {
        let report = try await TelemetrySoakRunner.run(
            workload: .shortCI,
            instrumentationEnabled: true
        )

        XCTAssertEqual(report.completeness, "complete")
        XCTAssertEqual(report.produced, report.persisted)
        XCTAssertEqual(report.lostCritical, 0)
        XCTAssertEqual(report.lostNative, 0)
        XCTAssertEqual(report.droppedFrames, 0)
        XCTAssertEqual(report.finalQueueDepth, 0)
        XCTAssertGreaterThan(report.transactionCount, 0)
        XCTAssertGreaterThan(report.transactionLatency.p95Nanoseconds, 0)
        XCTAssertGreaterThan(report.throughputRecordsPerSecond, 0)
        XCTAssertGreaterThan(report.finalStoreBytes, 0)
        XCTAssertEqual(
            report.controlOutputChecksum,
            DeterministicControlReplay.checksum(
                durationSeconds: TelemetrySoakWorkload.shortCI.simulatedMinutes * 60,
                observation: TestControlCycleObservation(
                    observation: TelemetryV2PerformanceObservation(
                        instrumentation: TelemetryPerformanceInstrumentation(enabled: true)
                    )
                )
            )
        )
    }

    func testInstrumentationOnAndOffHaveIdenticalControlOutput() async throws {
        let enabled = try await TelemetrySoakRunner.run(
            workload: .shortCI,
            instrumentationEnabled: true
        )
        let disabled = try await TelemetrySoakRunner.run(
            workload: .shortCI,
            instrumentationEnabled: false
        )

        XCTAssertEqual(enabled.controlOutputChecksum, disabled.controlOutputChecksum)
        XCTAssertEqual(enabled.produced, disabled.produced)
        XCTAssertEqual(enabled.persisted, disabled.persisted)
        XCTAssertEqual(enabled.lostCritical, disabled.lostCritical)
        XCTAssertEqual(enabled.lostNative, disabled.lostNative)
    }

    func testSameWorkloadComparisonCapturesFullEvidenceSet() async throws {
        let baseline = TelemetrySoakRecorderConfiguration.provisionalDefault
        let candidate = TelemetrySoakRecorderConfiguration(
            name: "candidate-batch-256",
            bufferCapacity: baseline.bufferCapacity,
            criticalReserve: baseline.criticalReserve,
            nativeReserveFromBulk: baseline.nativeReserveFromBulk,
            batchRecordCount: 256,
            batchIntervalMilliseconds: baseline.batchIntervalMilliseconds,
            maximumPrecommitRetries: baseline.maximumPrecommitRetries,
            retryDelayMilliseconds: baseline.retryDelayMilliseconds
        )
        let comparison = try await TelemetrySoakRunner.compare(
            workload: .shortCI,
            candidate: candidate
        )

        XCTAssertTrue(comparison.controlOutputChecksumsMatch)
        XCTAssertTrue(comparison.candidatePreservesCriticalAndNativeEvidence)
        XCTAssertEqual(comparison.baseline.workload, comparison.candidate.workload)
        XCTAssertEqual(comparison.baseline.produced, comparison.candidate.produced)
    }
}
