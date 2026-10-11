import XCTest
import TelemetryInstrumentation
import TelemetryRecorder
import TelemetryRuntime
@testable import WalkingPadCoreLogic
import TelemetryDomain
import TelemetryPersistence
import TelemetryAnalysis
@testable import TelemetrySoak

private struct TestControlCycleObservation: ControlCycleObservation {
    let observation: TelemetryV2PerformanceObservation

    func measureControlCycle(_ operation: () -> Void) {
        observation.measureControlCycle(operation)
    }
}

final class TelemetrySoakRunnerTests: XCTestCase {
    private let start = TelemetrySoakFixture.baseDate

    func testFractionalWriteSpacingKeepsStatusCoverageAndUnitsRefresh() {
        for cadence in [9, 10] {
            let result = runSchedule(cadence: cadence, dispatchDelay: 0.024, responseDelay: 0.1)
            print("STATUS_SCHEDULE cadence=\(cadence) status=\(result.status.count) units=\(result.units.count) durationCoverage=\(result.coverage) maxGap=\(result.maximumGap)")
            XCTAssertGreaterThanOrEqual(result.coverage, 0.90)
            XCTAssertGreaterThan(result.units.count, 60)
            XCTAssertLessThanOrEqual(result.status.count + result.units.count, 930)
            XCTAssertEqual(result.motion.count, 1859 / cadence + 1)
            for (index, actual) in result.motion.enumerated() {
                XCTAssertEqual(actual, Double(index * cadence) + 0.024, accuracy: 0.001)
            }
        }
    }

    func testPendingReadOnlyQueriesYieldToUnexpectedMotionWithoutExtraControlDelay() {
        // A status read is queued at 1s behind the 0.024s motion write.
        let bursts = [1.5]
        let baseline = runSchedule(cadence: 9, dispatchDelay: 0.024, responseDelay: 0.1,
            bursts: bursts, queriesEnabled: false)
        let candidate = runSchedule(cadence: 9, dispatchDelay: 0.024, responseDelay: 0.1, bursts: bursts)
        XCTAssertEqual(candidate.motion.count, baseline.motion.count)
        for (actual, expected) in zip(candidate.motion, baseline.motion) {
            XCTAssertEqual(actual, expected, accuracy: 0.000001)
        }
        let cancellations = candidate.records.filter { if case .commandCancelled = $0.1 { return true }; return false }
        XCTAssertEqual(cancellations.count, bursts.count)
        XCTAssertGreaterThanOrEqual(candidate.coverage, 0.90)
    }

    func testQueueCongestionAndDelayedRepliesDoNotFabricateCoverage() {
        let blocked = runSchedule(cadence: 9, dispatchDelay: 0.024, responseDelay: 0.1,
            bursts: stride(from: 1.5, to: 1860, by: 1.5).map { $0 })
        XCTAssertLessThan(blocked.coverage, 0.90)
        for delay in [0.0, 0.024, 0.065] {
            let result = runSchedule(cadence: 9, dispatchDelay: delay, responseDelay: 0.35)
            XCTAssertGreaterThanOrEqual(result.coverage, 0.90)
            XCTAssertGreaterThan(result.units.count, 60)
            XCTAssertLessThanOrEqual(result.status.count + result.units.count, 930)
        }
    }

    private func runSchedule(cadence: Int, dispatchDelay: Double, responseDelay: Double,
                             bursts: [Double] = [], queriesEnabled: Bool = true)
        -> (status: [Double], units: [Double], motion: [Double], coverage: Double, maximumGap: Double, records: [(Double, TreadmillTelemetryEvidence)]) {
        var queue: [CommandQueueService.Command] = []
        var sidecar = TreadmillCommandTelemetrySidecar()
        let epoch = TreadmillConnectionEpoch(rawValue: UUID())
        var records: [(Double, TreadmillTelemetryEvidence)] = []
        var nextCommand: UInt64 = 0
        var fireAt: Double?
        var nextAllowed = 0.0
        var lastStatus: Date?
        var lastUnits = start
        var status: [Double] = []
        var units: [Double] = []
        var motion: [Double] = []
        var nextTick = 0
        var nextBurst = 0
        func enqueue(_ label: String, at now: Double) {
            nextCommand += 1
            let kind: CommandKind = label == "QUERY STATUS" ? .walkingPadStatusQuery
                : label == "QUERY PARAMS" ? .walkingPadControllerUnitsQuery : .other("synthetic-motion")
            let evidence = TreadmillCommandEnqueuedEvidence(commandID: .init(rawValue: TelemetrySoakFixture.deterministicUUID(kind: 20, counter: nextCommand)),
                decisionID: nil, kind: kind, protocolKind: .walkingPad, connectionEpoch: epoch,
                enqueuedAt: start.addingTimeInterval(now))
            _ = sidecar.enqueueRegular(label: label, evidence: evidence, isSpeedLabel: { $0.hasPrefix("SPEED") })
            if kind.isReadOnlyQuery(protocolKind: .walkingPad, decisionID: nil) { records.append((now, .commandEnqueued(evidence))) }
            _ = CommandQueueService.enqueueRegular(queue: &queue,
                command: .init(data: Data(), label: label), isSpeedLabel: { $0.hasPrefix("SPEED") })
            if fireAt == nil { fireAt = max(now, nextAllowed) + dispatchDelay }
        }
        while nextTick < 1860 || fireAt != nil || nextBurst < bursts.count {
            let tickTime = nextTick < 1860 ? Double(nextTick) : .infinity
            let burstTime = nextBurst < bursts.count ? bursts[nextBurst] : .infinity
            if burstTime < min(tickTime, fireAt ?? .infinity) {
                enqueue("SPEED burst", at: burstTime); nextBurst += 1
                continue
            }
            if let fire = fireAt, nextTick >= 1860 || fire < Double(nextTick) {
                let remainder = Int(fire) % cadence
                let lead = remainder == 0 ? cadence : cadence - remainder
                let discarded = CommandQueueService.discardReadOnlyQueries(queue: &queue,
                    motionWindowIsProtected: lead <= ControllerUnitsRefreshPolicy.requiredMotionLeadSeconds)
                if !discarded.isEmpty {
                    for entry in sidecar.removeQueued(where: CommandQueueService.isReadOnlyQueryLabel) {
                        records.append((fire, .commandCancelled(.init(commandID: entry.evidence.commandID,
                            decisionID: nil, connectionEpoch: epoch, occurredAt: start.addingTimeInterval(fire),
                            reason: .other("read_only_query_yielded_to_motion")))))
                    }
                }
                if discarded.contains(where: { $0.label == "QUERY PARAMS" }) { lastUnits = start.addingTimeInterval(-100) }
                if queue.isEmpty { fireAt = nil; continue }
                let command = queue.removeFirst()
                guard case let .matched(entry) = sidecar.dequeue(expectedLabel: command.label, currentEpoch: epoch) else {
                    XCTFail("Queue/sidecar order lost"); break
                }
                if entry.evidence.kind.isReadOnlyQuery(protocolKind: .walkingPad, decisionID: nil) {
                    let sentAt = start.addingTimeInterval(fire)
                    records.append((fire, .commandQueueDelay(.init(commandID: entry.evidence.commandID, decisionID: nil,
                        connectionEpoch: epoch, enqueuedAt: entry.evidence.enqueuedAt, sentAt: sentAt))))
                    records.append((fire, .sendAttempt(.init(commandID: entry.evidence.commandID, decisionID: nil,
                        attemptID: .init(), attemptNumber: 1, protocolKind: .walkingPad, connectionEpoch: epoch,
                        sentAt: sentAt, writeType: .withoutResponse))))
                }
                switch command.label {
                case "QUERY STATUS": lastStatus = start.addingTimeInterval(fire); status.append(fire + responseDelay)
                case "QUERY PARAMS": units.append(fire + responseDelay)
                default: motion.append(fire)
                }
                nextAllowed = fire + 2
                fireAt = queue.isEmpty ? nil : nextAllowed + dispatchDelay
                continue
            }
            let second = nextTick
            nextTick += 1
            let now = Double(second)
            let date = start.addingTimeInterval(now)
            let remainder = second % cadence
            if remainder == 0 { enqueue("SPEED scheduled", at: now) }
            let decision = WalkingPadStatusRefreshPolicy.activeWorkoutRefresh(
                isWorkoutOrCooldownActive: queriesEnabled && second < 1860, transportReady: true,
                motionQueueIdle: queue.isEmpty && fireAt == nil,
                secondsUntilNextScheduledMotion: remainder == 0 ? cadence : cadence - remainder,
                lastStatusQueryAt: lastStatus, lastControllerUnitsQueryAt: lastUnits,
                earliestWriteDelaySeconds: max(0, nextAllowed - now), now: date)
            switch decision.kind {
            case .status: enqueue("QUERY STATUS", at: now)
            case .controllerUnits: lastUnits = date; enqueue("QUERY PARAMS", at: now)
            case nil: break
            }
        }
        // Continuous freshness duration, not population or sampled frame count.
        var covered = 0.0
        for (index, received) in status.enumerated() where received < 1860 {
            let next = index + 1 < status.count ? status[index + 1] : 1860
            covered += max(0, min(1860, min(received + 5, next)) - received)
        }
        let gaps = zip(status, status.dropFirst()).map { $1 - $0 }
        return (status, units, motion, covered / 1860, gaps.max() ?? 0, records)
    }


    func testPacedRefreshRecorderAndAnalyzerWorkload() async throws {
        let workload = TelemetrySoakWorkload(simulatedMinutes: 31,
            heartRateCadenceMilliseconds: 1_000, treadmillCadenceMilliseconds: 1_000, burst: nil)
        let fixture = TelemetrySoakFixture(workload: workload)
        let candidate = runSchedule(cadence: 9, dispatchDelay: 0.024, responseDelay: 0.1)
        // Golden nine-second legacy trace, validated against the pre-fix policy/queue reproducer.
        let baseline = stride(from: 3, to: 1860, by: 9).flatMap { second in
            [second, second + 3].filter { $0 < 1860 }.map { Double($0) + 0.124 }
        }
        XCTAssertEqual(baseline.count, 413)
        let epoch = TreadmillConnectionEpoch(rawValue: UUID())
        var oldEvents: [(Double, TreadmillTelemetryEvidence)] = []
        for (index, received) in baseline.enumerated() {
            let sent = received - 0.1
            let evidence = TreadmillCommandEnqueuedEvidence(commandID: .init(rawValue: TelemetrySoakFixture.deterministicUUID(kind: 20, counter: UInt64(index + 1))),
                decisionID: nil, kind: .walkingPadStatusQuery, protocolKind: .walkingPad, connectionEpoch: epoch,
                enqueuedAt: start.addingTimeInterval(sent - 0.024))
            oldEvents.append((sent - 0.024, .commandEnqueued(evidence)))
            oldEvents.append((sent, .commandQueueDelay(.init(commandID: evidence.commandID, decisionID: nil,
                connectionEpoch: epoch, enqueuedAt: evidence.enqueuedAt, sentAt: start.addingTimeInterval(sent)))))
            oldEvents.append((sent, .sendAttempt(.init(commandID: evidence.commandID, decisionID: nil,
                attemptID: .init(), attemptNumber: 1, protocolKind: .walkingPad, connectionEpoch: epoch,
                sentAt: start.addingTimeInterval(sent), writeType: .withoutResponse))))
        }
        for scenario in ["baseline", "candidate", "silence"] {
            let replies = scenario == "baseline" ? baseline : candidate.status.enumerated().compactMap {
                scenario == "silence" && $0.offset.isMultiple(of: 3) ? nil : $0.element
            }
            let events = scenario == "baseline" ? oldEvents : candidate.records
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try TelemetryStoreFactory.make(.onDisk(directory.appendingPathComponent("refresh.store")))
            let recorder = TelemetryRecorder(sessionHeader: supportedHeader(fixture.sessionHeader), persistence: store)
            let clock = ContinuousClock()
            let began = clock.now
            var timeline: [(Double, TelemetryPersistenceRecord)] = replies.enumerated().map {
                ($0.element, fixture.treadmill(index: UInt64($0.offset + 1), elapsedMilliseconds: Int(($0.element * 1000).rounded())))
            }
            for (index, item) in events.enumerated() where item.0 < 1860 {
                let elapsed = ElapsedDuration(microseconds: Int64((item.0 * 1_000_000).rounded()))
                let date = start.addingTimeInterval(elapsed.seconds)
                timeline.append((item.0, .event(.init(recordID: .init(rawValue: TelemetrySoakFixture.deterministicUUID(kind: 30, counter: UInt64(index + 1))),
                    sessionID: fixture.sessionID,
                    timestamp: .init(occurredAt: date, recordedAt: date, occurredElapsed: elapsed, recordedElapsed: elapsed),
                    payload: .init(schemaVersion: 1, payload: .treadmillEvidence(item.1))))))
            }
            timeline.sort { $0.0 < $1.0 }
            for record in fixture.sourceRecords { _ = recorder.ingress.yield(record) }
            _ = recorder.ingress.yield(fixture.lifecycleEvent(elapsedSecond: 0, ending: false))
            var next = 0
            var latestTreadmill: TreadmillObservation?
            var stalePopulatedFrames = 0
            for second in 0..<1860 {
                // Field frame phase median was 0.848891s; use the same 0.85s phase in both traces.
                let materializedSeconds = Double(second) + 0.85
                while next < timeline.count && timeline[next].0 <= materializedSeconds {
                    if case let .treadmill(observation) = timeline[next].1 { latestTreadmill = observation }
                    _ = recorder.ingress.yield(timeline[next].1); next += 1
                }
                let hrRecord = fixture.heartRate(index: UInt64(second + 1), elapsedMilliseconds: second * 1000)
                _ = recorder.ingress.yield(hrRecord)
                guard case let .heartRate(hr) = hrRecord, case let .frame(template) = fixture.frame(elapsedSecond: second) else {
                    XCTFail("Invalid fixture records"); return
                }
                let frame = populatedFrame(template, heartRate: hr, treadmill: latestTreadmill,
                    materializedSeconds: materializedSeconds)
                if frame.treadmillEvidence?.freshness == .stale { stalePopulatedFrames += 1 }
                _ = recorder.ingress.yield(.frame(frame))
                if second.isMultiple(of: 5) { _ = await recorder.flush(reason: .explicit) }
            }
            while next < timeline.count { _ = recorder.ingress.yield(timeline[next].1); next += 1 }
            _ = recorder.ingress.yield(fixture.lifecycleEvent(elapsedSecond: 1860, ending: true))
            let terminal = start.addingTimeInterval(1860)
            let finish = await recorder.finish(endedAt: terminal, endedElapsed: .init(microseconds: 1_860_000_000))
            let analysisBegan = clock.now
            let outcome = try await store.analyzeTerminalWorkout(sessionID: fixture.sessionID, generatedAt: terminal)
            let analysisEnd = clock.now
            let result = try XCTUnwrap(outcome.analysis)
            let detail = try JSONDecoder().decode(WorkoutAnalysisDetailV1.self, from: result.versionedDetailPayload)
            let coverage = try XCTUnwrap(detail.quality.treadmillFactualCoverage.coverageRatio)
            XCTAssertEqual(finish.completeness, .complete)
            XCTAssertEqual(outcome.triggerResult, .inserted)
            XCTAssertEqual(result.analyzerVersion, WorkoutAnalyzerV1.analyzerVersion)
            if scenario == "candidate" {
                XCTAssertGreaterThanOrEqual(coverage, 0.90)
                XCTAssertNotNil(result.keyMetrics.averageFactualSpeedKilometresPerHour)
            } else {
                XCTAssertLessThan(coverage, 0.90)
                XCTAssertNil(result.keyMetrics.averageFactualSpeedKilometresPerHour)
            }
            if scenario == "silence" { XCTAssertGreaterThan(stalePopulatedFrames, 100) }
            if scenario == "baseline" { XCTAssertEqual(coverage, 0.8601010752688172, accuracy: 0.00001) }
            let history = try await store.fetchWorkoutHistoryPage(filter: .init(profileScope: .exact(fixture.sessionHeader.profileLocalIdentifier)), after: nil, limit: 10)
            XCTAssertEqual(history.items.first?.durationSeconds, 1860)
            XCTAssertEqual(history.items.first?.averageSpeed != nil, scenario == "candidate")
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            let bytes = try files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
            print("REFRESH_PIPELINE scenario=\(scenario) status=\(replies.count) queryEvents=\(events.count) coverage=\(coverage) stalePopulatedFrames=\(stalePopulatedFrames) persistedSequence=\(finish.lastCommittedRecorderSequence ?? 0) bytes=\(bytes) recorder=\(began.duration(to: analysisBegan)) analyzer=\(analysisBegan.duration(to: analysisEnd))")
        }
    }

    private func populatedFrame(_ template: CanonicalFrame, heartRate hr: HeartRateObservation,
                                treadmill: TreadmillObservation?, materializedSeconds: Double) -> CanonicalFrame {
        let elapsed = ElapsedDuration(microseconds: Int64((materializedSeconds * 1_000_000).rounded()))
        let hrAge = ElapsedDuration(microseconds: elapsed.microseconds - hr.timestamp.effectiveElapsed.microseconds)
        let speed = treadmill.map { observation in
            let age = ElapsedDuration(microseconds: elapsed.microseconds - observation.timestamp.effectiveElapsed.microseconds)
            return TreadmillFrameEvidence(observationID: observation.observationID, recordID: observation.recordID,
                sourceID: observation.source.id, nativeSpeed: observation.nativeSpeed, factualSpeed: observation.factualSpeed,
                deviceState: observation.deviceState, measuredAt: observation.timestamp.measuredAt,
                receivedAt: observation.timestamp.receivedAt, evidenceElapsed: observation.timestamp.effectiveElapsed,
                ageAtMaterialization: age, freshness: age.seconds <= 5 ? .fresh : .stale, provenance: observation.provenance)
        }
        return CanonicalFrame(frameID: template.frameID, recordID: template.recordID, sessionID: template.sessionID,
            canonicalElapsedSecond: template.canonicalElapsedSecond,
            materializedAt: .init(recordedAt: start.addingTimeInterval(elapsed.seconds), elapsed: elapsed),
            heartRateEvidence: .init(observationID: hr.observationID, recordID: hr.recordID, sourceID: hr.source.id,
                beatsPerMinute: hr.beatsPerMinute, measuredAt: hr.timestamp.measuredAt, receivedAt: hr.timestamp.receivedAt,
                evidenceElapsed: hr.timestamp.effectiveElapsed, ageAtMaterialization: hrAge,
                freshness: hrAge.seconds <= 7 ? .fresh : .stale, provenance: hr.provenance), treadmillEvidence: speed)
    }

    private func supportedHeader(_ base: WorkoutSessionRecord) -> WorkoutSessionRecord {
        WorkoutSessionRecord(recordID: base.recordID, sessionID: base.sessionID,
            profileLocalIdentifier: base.profileLocalIdentifier, lifecycleState: base.lifecycleState,
            workoutMode: base.workoutMode, startedAt: base.startedAt, endedAt: nil, endedElapsed: nil,
            incompleteReason: nil, appContext: base.appContext,
            versions: RuntimeVersionContext(telemetrySchema: .init(rawValue: "1.0.0"),
                algorithm: base.versions.algorithm, safetyPolicy: base.versions.safetyPolicy,
                workoutProtocol: base.versions.workoutProtocol), configuration: base.configuration,
            healthKitWorkoutIdentifier: nil, treadmill: base.treadmill, recorderHealth: base.recorderHealth)
    }

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
            let header = supportedHeader(base)
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
