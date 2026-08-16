import Foundation
import TelemetryDomain
import TelemetryInstrumentation
import TelemetryPersistence
import TelemetryRecorder
import TelemetryRuntime
import WalkingPadCoreLogic
#if canImport(Darwin)
import Darwin
#endif

public enum TelemetrySoakError: Error, Equatable {
    case persistedCountsDoNotMatchStore
    case noTransactions
}

public enum TelemetrySoakRunner {
    public static func run(
        workload: TelemetrySoakWorkload,
        recorderConfiguration: TelemetrySoakRecorderConfiguration = .provisionalDefault,
        instrumentationEnabled: Bool = true
    ) async throws -> TelemetrySoakReport {
        let instrumentation = TelemetryPerformanceInstrumentation(
            enabled: instrumentationEnabled
        )
        let soakInterval = instrumentation.beginIntegratedSoak(
            simulatedMinutes: workload.simulatedMinutes
        )
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("telemetry-soak-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let storeURL = temporaryDirectory.appendingPathComponent("TelemetryV2.store")
        let store = try TelemetryStoreFactory.make(.onDisk(storeURL))
        let persistence = MeasuringSoakPersistence(store: store)
        let fixture = TelemetrySoakFixture(workload: workload)
        let recorder = TelemetryRecorder(
            sessionHeader: fixture.sessionHeader,
            persistence: persistence,
            bufferPolicy: recorderConfiguration.bufferPolicy,
            batchPolicy: recorderConfiguration.batchPolicy,
            retryPolicy: recorderConfiguration.retryPolicy,
            instrumentation: instrumentation
        )

        let wallClock = ContinuousClock()
        let wallStart = wallClock.now
        let controlOutputChecksum = DeterministicControlReplay.checksum(
            durationSeconds: workload.simulatedMinutes * 60,
            observation: SoakControlCycleObservation(
                observation: TelemetryV2PerformanceObservation(
                    instrumentation: instrumentation
                )
            )
        )
        var produced = TelemetrySoakClassCounts()
        var heartRateIndex: UInt64 = 0
        var treadmillIndex: UInt64 = 0
        var memorySamples: [TelemetrySoakMemorySample] = []
        appendMemorySample(minute: 0, to: &memorySamples)

        func yield(_ record: TelemetryPersistenceRecord) {
            switch record {
            case .source, .event:
                produced.critical &+= 1
            case .heartRate, .treadmill:
                produced.native &+= 1
            case .frame:
                produced.bulkFrame &+= 1
            }
            _ = recorder.ingress.yield(record)
        }

        for record in fixture.sourceRecords {
            yield(record)
        }
        yield(fixture.lifecycleEvent(elapsedSecond: 0, ending: false))

        let durationMilliseconds = workload.simulatedMinutes * 60 * 1_000
        let stepMilliseconds = greatestCommonDivisor(
            greatestCommonDivisor(
                workload.heartRateCadenceMilliseconds,
                workload.treadmillCadenceMilliseconds
            ),
            1_000
        )
        var elapsedMilliseconds = 0
        while elapsedMilliseconds < durationMilliseconds {
            if elapsedMilliseconds % workload.heartRateCadenceMilliseconds == 0 {
                heartRateIndex &+= 1
                yield(
                    fixture.heartRate(
                        index: heartRateIndex,
                        elapsedMilliseconds: elapsedMilliseconds
                    )
                )
            }
            if elapsedMilliseconds % workload.treadmillCadenceMilliseconds == 0 {
                treadmillIndex &+= 1
                yield(
                    fixture.treadmill(
                        index: treadmillIndex,
                        elapsedMilliseconds: elapsedMilliseconds
                    )
                )
            }
            if elapsedMilliseconds % 1_000 == 0 {
                let elapsedSecond = elapsedMilliseconds / 1_000
                yield(fixture.frame(elapsedSecond: elapsedSecond))
            }

            if let burst = workload.burst,
               elapsedMilliseconds > 0,
               elapsedMilliseconds % (burst.everySeconds * 1_000) == 0
            {
                for burstIndex in 0..<burst.nativeRecordCount {
                    if burstIndex.isMultiple(of: 2) {
                        heartRateIndex &+= 1
                        yield(
                            fixture.heartRate(
                                index: heartRateIndex,
                                elapsedMilliseconds: elapsedMilliseconds
                            )
                        )
                    } else {
                        treadmillIndex &+= 1
                        yield(
                            fixture.treadmill(
                                index: treadmillIndex,
                                elapsedMilliseconds: elapsedMilliseconds
                            )
                        )
                    }
                }
            }

            let elapsedSecond = elapsedMilliseconds / 1_000
            if elapsedMilliseconds > 0,
               elapsedMilliseconds % (workload.flushEverySeconds * 1_000) == 0
            {
                _ = await recorder.flush(reason: .explicit)
            }
            if elapsedMilliseconds > 0,
               elapsedMilliseconds % 60_000 == 0
            {
                appendMemorySample(minute: elapsedSecond / 60, to: &memorySamples)
            }
            elapsedMilliseconds += stepMilliseconds
        }

        let endSecond = workload.simulatedMinutes * 60
        yield(fixture.lifecycleEvent(elapsedSecond: endSecond, ending: true))
        let finish = await recorder.finish(
            endedAt: TelemetrySoakFixture.baseDate.addingTimeInterval(Double(endSecond)),
            endedElapsed: ElapsedDuration(
                microseconds: Int64(endSecond) * 1_000_000
            )
        )
        appendMemorySample(minute: workload.simulatedMinutes, to: &memorySamples)

        let wallDuration = wallStart.duration(to: wallClock.now)
        let wallNanoseconds = durationNanoseconds(wallDuration)
        let persistenceSummary = await persistence.summary()
        let storeCounts = try await store.counts()
        guard persistenceSummary.persisted.critical
                == UInt64(storeCounts.sources + storeCounts.events),
              persistenceSummary.persisted.native
                == UInt64(storeCounts.heartRateSamples + storeCounts.treadmillSamples),
              persistenceSummary.persisted.bulkFrame == UInt64(storeCounts.frames)
        else {
            instrumentation.endIntegratedSoak(soakInterval, result: .failed)
            throw TelemetrySoakError.persistedCountsDoNotMatchStore
        }
        guard !persistenceSummary.transactionNanoseconds.isEmpty else {
            instrumentation.endIntegratedSoak(soakInterval, result: .failed)
            throw TelemetrySoakError.noTransactions
        }

        let operationalState = recorder.operationalState
        let report = TelemetrySoakReport(
            workload: workload,
            recorderConfiguration: recorderConfiguration,
            instrumentationEnabled: instrumentationEnabled,
            produced: produced,
            persisted: persistenceSummary.persisted,
            coalescedFrames: operationalState.coalescedFrameCount,
            droppedFrames: operationalState.droppedFrameCount,
            lostNative: operationalState.lostNativeCount,
            lostCritical: operationalState.lostCriticalCount,
            finalQueueDepth: operationalState.queueDepth,
            queueHighWaterMark: operationalState.peakQueueDepth,
            transactionCount: UInt64(persistenceSummary.transactionNanoseconds.count),
            transactionLatency: latencyDistribution(
                persistenceSummary.transactionNanoseconds
            ),
            throughputRecordsPerSecond: wallNanoseconds == 0
                ? 0
                : Double(persistenceSummary.persisted.total)
                    / (Double(wallNanoseconds) / 1_000_000_000),
            memorySamples: memorySamples,
            finalStoreBytes: try allocatedStoreBytes(in: temporaryDirectory),
            completeness: finish.completeness.rawValue,
            controlOutputChecksum: controlOutputChecksum,
            wallDurationNanoseconds: wallNanoseconds
        )
        instrumentation.endIntegratedSoak(
            soakInterval,
            result: finish.completeness.instrumentationResult
        )
        return report
    }

    public static func compare(
        workload: TelemetrySoakWorkload,
        baseline: TelemetrySoakRecorderConfiguration = .provisionalDefault,
        candidate: TelemetrySoakRecorderConfiguration,
        instrumentationEnabled: Bool = true
    ) async throws -> TelemetrySoakComparison {
        let baselineReport = try await run(
            workload: workload,
            recorderConfiguration: baseline,
            instrumentationEnabled: instrumentationEnabled
        )
        let candidateReport = try await run(
            workload: workload,
            recorderConfiguration: candidate,
            instrumentationEnabled: instrumentationEnabled
        )
        return TelemetrySoakComparison(
            baseline: baselineReport,
            candidate: candidateReport
        )
    }
}

private struct SoakControlCycleObservation: ControlCycleObservation {
    let observation: TelemetryV2PerformanceObservation

    func measureControlCycle(_ operation: () -> Void) {
        observation.measureControlCycle(operation)
    }
}

private actor MeasuringSoakPersistence: TelemetryRecorderPersistence {
    struct Summary: Sendable {
        let persisted: TelemetrySoakClassCounts
        let transactionNanoseconds: [UInt64]
    }

    private let store: TelemetryStore
    private let clock = ContinuousClock()
    private var persisted = TelemetrySoakClassCounts()
    private var transactionNanoseconds: [UInt64] = []

    init(store: TelemetryStore) {
        self.store = store
    }

    func beginSession(_ header: WorkoutSessionRecord) async throws {
        try await store.beginSession(header)
    }

    func persistBatch(_ records: [SequencedTelemetryRecord]) async throws {
        let start = clock.now
        try await store.persistBatch(records)
        transactionNanoseconds.append(durationNanoseconds(start.duration(to: clock.now)))
        for record in records {
            switch record.record {
            case .source, .event:
                persisted.critical &+= 1
            case .heartRate, .treadmill:
                persisted.native &+= 1
            case .frame:
                persisted.bulkFrame &+= 1
            }
        }
    }

    func finalizeSession(_ finalization: TelemetrySessionFinalization) async throws {
        try await store.finalizeSession(finalization)
    }

    func unfinishedSessions() async throws -> [WorkoutSessionRecord] {
        try await store.unfinishedSessions()
    }

    func summary() -> Summary {
        Summary(
            persisted: persisted,
            transactionNanoseconds: transactionNanoseconds
        )
    }
}

private func greatestCommonDivisor(_ lhs: Int, _ rhs: Int) -> Int {
    var first = lhs
    var second = rhs
    while second != 0 {
        (first, second) = (second, first % second)
    }
    return max(first, 1)
}

private func durationNanoseconds(_ duration: Duration) -> UInt64 {
    let components = duration.components
    guard components.seconds >= 0 else { return 0 }
    let seconds = UInt64(components.seconds)
    let attoseconds = max(components.attoseconds, 0)
    return seconds &* 1_000_000_000 + UInt64(attoseconds / 1_000_000_000)
}

private func latencyDistribution(
    _ measurements: [UInt64]
) -> TelemetrySoakLatencyDistribution {
    let sorted = measurements.sorted()
    func percentile(_ fraction: Double) -> UInt64 {
        let index = Int((Double(sorted.count - 1) * fraction).rounded(.up))
        return sorted[index]
    }
    return TelemetrySoakLatencyDistribution(
        minimumNanoseconds: sorted[0],
        p50Nanoseconds: percentile(0.50),
        p95Nanoseconds: percentile(0.95),
        maximumNanoseconds: sorted[sorted.count - 1]
    )
}

private func allocatedStoreBytes(in directory: URL) throws -> UInt64 {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileAllocatedSizeKey]
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
    ) else {
        return 0
    }
    var total: UInt64 = 0
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: keys)
        if values.isRegularFile == true, let size = values.fileAllocatedSize {
            total &+= UInt64(size)
        }
    }
    return total
}

private func appendMemorySample(
    minute: Int,
    to samples: inout [TelemetrySoakMemorySample]
) {
    guard let residentBytes = residentMemoryBytes() else { return }
    samples.append(
        TelemetrySoakMemorySample(
            simulatedMinute: minute,
            residentBytes: residentBytes
        )
    )
}

private func residentMemoryBytes() -> UInt64? {
    #if canImport(Darwin)
    var information = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &information) { pointer in
        pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
            task_info(
                mach_task_self_,
                task_flavor_t(MACH_TASK_BASIC_INFO),
                $0,
                &count
            )
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    return UInt64(information.resident_size)
    #else
    return nil
    #endif
}

private extension TelemetryRecorderCompleteness {
    var instrumentationResult: TelemetryInstrumentationResult {
        switch self {
        case .complete: .success
        case .incomplete: .incomplete
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }
}
