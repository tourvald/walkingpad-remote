import XCTest
import TelemetryInstrumentation
import TelemetryRecorder
import TelemetryRuntime
@testable import WalkingPadCoreLogic
import TelemetryDomain
import TelemetryPersistence
@testable import TelemetrySoak

private struct TestControlCycleObservation: ControlCycleObservation {
    let observation: TelemetryV2PerformanceObservation

    func measureControlCycle(_ operation: () -> Void) {
        observation.measureControlCycle(operation)
    }
}

final class TelemetrySoakRunnerTests: XCTestCase {
    func testRepresentativeTerminalStagesBeforeAndAfterStopOwnerCompletion() async throws {
        let workload = TelemetrySoakWorkload(simulatedMinutes: 31,
            heartRateCadenceMilliseconds: 1_000, treadmillCadenceMilliseconds: 1_000, burst: nil)
        for early in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try TelemetryStoreFactory.make(.onDisk(directory.appendingPathComponent("terminal.store")))
            let fixture = TelemetrySoakFixture(workload: workload)
            let base = fixture.sessionHeader
            let header = WorkoutSessionRecord(recordID: base.recordID, sessionID: base.sessionID,
                profileLocalIdentifier: base.profileLocalIdentifier, lifecycleState: base.lifecycleState,
                workoutMode: base.workoutMode, startedAt: base.startedAt, endedAt: nil, endedElapsed: nil,
                incompleteReason: nil, appContext: base.appContext,
                versions: RuntimeVersionContext(telemetrySchema: .init(rawValue: "1.0.0"),
                    algorithm: base.versions.algorithm, safetyPolicy: base.versions.safetyPolicy,
                    workoutProtocol: base.versions.workoutProtocol), configuration: base.configuration,
                healthKitWorkoutIdentifier: nil, treadmill: base.treadmill, recorderHealth: base.recorderHealth)
            let recorder = TelemetryRecorder(sessionHeader: header, persistence: store)
            for record in fixture.sourceRecords { _ = recorder.ingress.yield(record) }
            _ = recorder.ingress.yield(fixture.lifecycleEvent(elapsedSecond: 0, ending: false))
            for second in 0..<1860 {
                _ = recorder.ingress.yield(fixture.heartRate(index: UInt64(second + 1), elapsedMilliseconds: second * 1_000))
                _ = recorder.ingress.yield(fixture.treadmill(index: UInt64(second + 1), elapsedMilliseconds: second * 1_000))
                _ = recorder.ingress.yield(fixture.frame(elapsedSecond: second))
                if second.isMultiple(of: 5) { _ = await recorder.flush(reason: .explicit) }
            }
            _ = recorder.ingress.yield(fixture.lifecycleEvent(elapsedSecond: 1860, ending: true))
            let terminal = TelemetrySoakFixture.baseDate.addingTimeInterval(1860)
            let context = StopObservationContext(peripheralID: UUID(), connectionEpoch: UUID(), notificationStreamID: UUID())
            var owner = StopObservationLifecycle(attemptID: UUID(), source: "synthetic-terminal",
                attemptedAt: terminal, context: context, scheduledStopEffects: 2)
            owner.markCommandSent(at: terminal)
            owner.markMotionWrite(at: terminal.addingTimeInterval(2))
            owner.completeScheduledStopEffect()
            owner.completeScheduledStopEffect()
            let observedAt = terminal.addingTimeInterval(4.2)
            _ = owner.record(speedRawTenths: 0, state: 0, checksumValid: true,
                context: context, observedAt: observedAt, evaluatedAt: observedAt)
            let closeAt = early ? observedAt : owner.deadline
            if early { XCTAssertTrue(owner.finalizeCompletedStopIfReady(at: closeAt, queueIdle: true)) }
            else { _ = owner.finalizeTimeout(at: closeAt) }
            let clock = ContinuousClock()
            let finishStart = clock.now
            let finish = await recorder.finish(endedAt: terminal,
                endedElapsed: ElapsedDuration(microseconds: 1_860_000_000))
            let analysisStart = clock.now
            let analysis = try await store.analyzeTerminalWorkout(sessionID: fixture.sessionID, generatedAt: closeAt)
            let projectionStart = clock.now
            let history = try await store.fetchWorkoutHistoryPage(filter: .init(profileScope: .exact(fixture.sessionHeader.profileLocalIdentifier)), after: nil, limit: 10)
            let projectionEnd = clock.now
            XCTAssertEqual(finish.completeness, .complete)
            XCTAssertEqual(analysis.triggerResult, .inserted)
            XCTAssertEqual(history.items.count, 1)
            XCTAssertEqual(history.items.first?.endedAt, terminal)
            XCTAssertEqual(history.items.first?.durationSeconds, 1860)
            XCTAssertEqual(owner.deadline, terminal.addingTimeInterval(30))
            print("TERMINAL_STAGES early=\(early) simulated_tail_s=\(closeAt.timeIntervalSince(terminal)) recorder_finish=\(finishStart.duration(to: analysisStart)) analyzer=\(analysisStart.duration(to: projectionStart)) projection=\(projectionStart.duration(to: projectionEnd))")
        }
    }

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

    func testControlChecksumHasStableShortWorkloadVector() {
        let checksum = DeterministicControlReplay.checksum(
            durationSeconds: TelemetrySoakWorkload.shortCI.simulatedMinutes * 60,
            observation: TestControlCycleObservation(
                observation: TelemetryV2PerformanceObservation(
                    instrumentation: TelemetryPerformanceInstrumentation(enabled: false)
                )
            )
        )

        // The harness reflects the full cooldown output, including diagnostic telemetry.
        // The additive factual-speed properties change this vector without changing control effects.
        XCTAssertEqual(checksum, "c04d272e8a312b32")
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
