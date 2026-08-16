import Foundation
import TelemetryInstrumentation
import TelemetryRecorder

public struct TelemetrySoakBurst: Codable, Equatable, Sendable {
    public let everySeconds: Int
    public let nativeRecordCount: Int

    public init(everySeconds: Int, nativeRecordCount: Int) {
        precondition(everySeconds > 0)
        precondition((0...512).contains(nativeRecordCount))
        self.everySeconds = everySeconds
        self.nativeRecordCount = nativeRecordCount
    }
}

public struct TelemetrySoakWorkload: Codable, Equatable, Sendable {
    public static let shortCI = TelemetrySoakWorkload(
        simulatedMinutes: 2,
        heartRateCadenceMilliseconds: 1_000,
        treadmillCadenceMilliseconds: 1_000,
        burst: TelemetrySoakBurst(everySeconds: 30, nativeRecordCount: 32),
        flushEverySeconds: 5
    )

    public let simulatedMinutes: Int
    public let heartRateCadenceMilliseconds: Int
    public let treadmillCadenceMilliseconds: Int
    public let burst: TelemetrySoakBurst?
    public let flushEverySeconds: Int

    public init(
        simulatedMinutes: Int,
        heartRateCadenceMilliseconds: Int,
        treadmillCadenceMilliseconds: Int,
        burst: TelemetrySoakBurst?,
        flushEverySeconds: Int = 5
    ) {
        precondition((1...120).contains(simulatedMinutes))
        precondition(heartRateCadenceMilliseconds > 0)
        precondition(treadmillCadenceMilliseconds > 0)
        precondition(flushEverySeconds > 0)
        self.simulatedMinutes = simulatedMinutes
        self.heartRateCadenceMilliseconds = heartRateCadenceMilliseconds
        self.treadmillCadenceMilliseconds = treadmillCadenceMilliseconds
        self.burst = burst
        self.flushEverySeconds = flushEverySeconds
    }
}

public struct TelemetrySoakRecorderConfiguration: Codable, Equatable, Sendable {
    public static let provisionalDefault = TelemetrySoakRecorderConfiguration(
        name: "provisional-default",
        bufferCapacity: 2_048,
        criticalReserve: 256,
        nativeReserveFromBulk: 512,
        batchRecordCount: 128,
        batchIntervalMilliseconds: 5_000,
        maximumPrecommitRetries: 1,
        retryDelayMilliseconds: 250
    )

    public let name: String
    public let bufferCapacity: Int
    public let criticalReserve: Int
    public let nativeReserveFromBulk: Int
    public let batchRecordCount: Int
    public let batchIntervalMilliseconds: Int
    public let maximumPrecommitRetries: Int
    public let retryDelayMilliseconds: Int

    public init(
        name: String,
        bufferCapacity: Int,
        criticalReserve: Int,
        nativeReserveFromBulk: Int,
        batchRecordCount: Int,
        batchIntervalMilliseconds: Int,
        maximumPrecommitRetries: Int,
        retryDelayMilliseconds: Int
    ) {
        precondition(!name.isEmpty)
        precondition(bufferCapacity > 0)
        precondition(criticalReserve >= 0)
        precondition(nativeReserveFromBulk >= 0)
        precondition(criticalReserve + nativeReserveFromBulk < bufferCapacity)
        precondition(batchRecordCount > 0)
        precondition(batchIntervalMilliseconds > 0)
        precondition(maximumPrecommitRetries >= 0)
        precondition(retryDelayMilliseconds >= 0)
        self.name = name
        self.bufferCapacity = bufferCapacity
        self.criticalReserve = criticalReserve
        self.nativeReserveFromBulk = nativeReserveFromBulk
        self.batchRecordCount = batchRecordCount
        self.batchIntervalMilliseconds = batchIntervalMilliseconds
        self.maximumPrecommitRetries = maximumPrecommitRetries
        self.retryDelayMilliseconds = retryDelayMilliseconds
    }

    var bufferPolicy: TelemetryBufferPolicy {
        TelemetryBufferPolicy(
            capacity: bufferCapacity,
            reservedCriticalCapacity: criticalReserve,
            reservedNativeCapacity: nativeReserveFromBulk
        )!
    }

    var batchPolicy: TelemetryBatchPolicy {
        TelemetryBatchPolicy(
            maximumRecordCount: batchRecordCount,
            maximumInterval: .milliseconds(batchIntervalMilliseconds)
        )!
    }

    var retryPolicy: TelemetryRetryPolicy {
        TelemetryRetryPolicy(
            maximumPrecommitRetries: maximumPrecommitRetries,
            delay: .milliseconds(retryDelayMilliseconds)
        )!
    }
}

public struct TelemetrySoakClassCounts: Codable, Equatable, Sendable {
    public var critical: UInt64
    public var native: UInt64
    public var bulkFrame: UInt64

    public init(critical: UInt64 = 0, native: UInt64 = 0, bulkFrame: UInt64 = 0) {
        self.critical = critical
        self.native = native
        self.bulkFrame = bulkFrame
    }

    public var total: UInt64 { critical + native + bulkFrame }
}

public struct TelemetrySoakLatencyDistribution: Codable, Equatable, Sendable {
    public let minimumNanoseconds: UInt64
    public let p50Nanoseconds: UInt64
    public let p95Nanoseconds: UInt64
    public let maximumNanoseconds: UInt64
}

public struct TelemetrySoakMemorySample: Codable, Equatable, Sendable {
    public let simulatedMinute: Int
    public let residentBytes: UInt64
}

public struct TelemetrySoakReport: Codable, Equatable, Sendable {
    public let workload: TelemetrySoakWorkload
    public let recorderConfiguration: TelemetrySoakRecorderConfiguration
    public let instrumentationEnabled: Bool
    public let produced: TelemetrySoakClassCounts
    public let persisted: TelemetrySoakClassCounts
    public let coalescedFrames: UInt64
    public let droppedFrames: UInt64
    public let lostNative: UInt64
    public let lostCritical: UInt64
    public let finalQueueDepth: Int
    public let queueHighWaterMark: Int
    public let transactionCount: UInt64
    public let transactionLatency: TelemetrySoakLatencyDistribution
    public let throughputRecordsPerSecond: Double
    public let memorySamples: [TelemetrySoakMemorySample]
    public let finalStoreBytes: UInt64
    public let completeness: String
    public let controlOutputChecksum: String
    public let wallDurationNanoseconds: UInt64
}

public struct TelemetrySoakComparison: Codable, Equatable, Sendable {
    public let baseline: TelemetrySoakReport
    public let candidate: TelemetrySoakReport

    public var controlOutputChecksumsMatch: Bool {
        baseline.controlOutputChecksum == candidate.controlOutputChecksum
    }

    public var candidatePreservesCriticalAndNativeEvidence: Bool {
        candidate.lostCritical == 0
            && candidate.lostNative == 0
            && candidate.persisted.critical == baseline.persisted.critical
            && candidate.persisted.native == baseline.persisted.native
    }
}
