import Foundation
import TelemetryDomain

public struct TelemetrySourceRecord: Hashable, Sendable {
    public let identity: SignalSourceIdentity
    public let firstSeen: Date
    public let lastSeen: Date

    public init(identity: SignalSourceIdentity, firstSeen: Date, lastSeen: Date) {
        self.identity = identity
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

public enum TelemetryPersistenceRecord: Hashable, Sendable {
    case source(TelemetrySourceRecord)
    case heartRate(HeartRateObservation)
    case treadmill(TreadmillObservation)
    case event(WorkoutEvent)
    case frame(CanonicalFrame)
}

public struct SequencedTelemetryRecord: Hashable, Sendable {
    public let recorderSequence: UInt64
    public let record: TelemetryPersistenceRecord

    public init(recorderSequence: UInt64, record: TelemetryPersistenceRecord) {
        self.recorderSequence = recorderSequence
        self.record = record
    }
}

public enum TelemetryRecordClass: String, Hashable, Sendable {
    case critical
    case native
    case bulkFrame
}

public enum TelemetryYieldDisposition: String, Hashable, Sendable {
    case enqueued
    case coalescedFrame
    case droppedFrame
    case lostNative
    case lostCritical
    case rejectedAfterFinish
    case rejectedTerminal
    case sequenceExhausted
}

public struct TelemetryYieldReceipt: Hashable, Sendable {
    public let recorderSequence: UInt64?
    public let disposition: TelemetryYieldDisposition

    public init(recorderSequence: UInt64?, disposition: TelemetryYieldDisposition) {
        self.recorderSequence = recorderSequence
        self.disposition = disposition
    }
}

public struct TelemetryBufferPolicy: Hashable, Sendable {
    public static let initialDefault = TelemetryBufferPolicy(
        capacity: 2_048,
        reservedCriticalCapacity: 256,
        reservedNativeCapacity: 512
    )!

    public let capacity: Int
    public let reservedCriticalCapacity: Int
    public let reservedNativeCapacity: Int

    public init?(
        capacity: Int,
        reservedCriticalCapacity: Int,
        reservedNativeCapacity: Int
    ) {
        guard capacity > 0,
              reservedCriticalCapacity >= 0,
              reservedNativeCapacity >= 0,
              reservedCriticalCapacity + reservedNativeCapacity < capacity
        else {
            return nil
        }
        self.capacity = capacity
        self.reservedCriticalCapacity = reservedCriticalCapacity
        self.reservedNativeCapacity = reservedNativeCapacity
    }

    public var nonCriticalCapacity: Int {
        capacity - reservedCriticalCapacity
    }

    public var bulkFrameCapacity: Int {
        capacity - reservedCriticalCapacity - reservedNativeCapacity
    }
}

public struct TelemetryBatchPolicy: Hashable, Sendable {
    public static let initialDefault = TelemetryBatchPolicy(
        maximumRecordCount: 128,
        maximumInterval: .seconds(5)
    )!

    public let maximumRecordCount: Int
    public let maximumInterval: Duration

    public init?(maximumRecordCount: Int, maximumInterval: Duration) {
        guard maximumRecordCount > 0, maximumInterval > .zero else {
            return nil
        }
        self.maximumRecordCount = maximumRecordCount
        self.maximumInterval = maximumInterval
    }
}

public struct TelemetryRetryPolicy: Hashable, Sendable {
    public static let initialDefault = TelemetryRetryPolicy(
        maximumPrecommitRetries: 1,
        delay: .milliseconds(250)
    )!

    public let maximumPrecommitRetries: Int
    public let delay: Duration

    public init?(maximumPrecommitRetries: Int, delay: Duration) {
        guard maximumPrecommitRetries >= 0, delay >= .zero else {
            return nil
        }
        self.maximumPrecommitRetries = maximumPrecommitRetries
        self.delay = delay
    }
}

public enum TelemetryPersistenceOperationError: Error, Equatable, Sendable {
    case retryableBeforeCommit(code: String)
    case terminal(code: String)
    case commitOutcomeUnknown(code: String)
}

public struct TelemetrySessionFinalization: Hashable, Sendable {
    public let sessionID: SessionID
    public let lifecycleState: SessionLifecycleState
    public let endedAt: Date?
    public let endedElapsed: ElapsedDuration?
    public let incompleteReason: String?
    public let recorderHealth: RecorderHealthSummary

    public init(
        sessionID: SessionID,
        lifecycleState: SessionLifecycleState,
        endedAt: Date?,
        endedElapsed: ElapsedDuration?,
        incompleteReason: String?,
        recorderHealth: RecorderHealthSummary
    ) {
        self.sessionID = sessionID
        self.lifecycleState = lifecycleState
        self.endedAt = endedAt
        self.endedElapsed = endedElapsed
        self.incompleteReason = incompleteReason
        self.recorderHealth = recorderHealth
    }
}

public protocol TelemetryRecorderPersistence: Sendable {
    func beginSession(_ header: WorkoutSessionRecord) async throws
    func persistBatch(_ records: [SequencedTelemetryRecord]) async throws
    func finalizeSession(_ finalization: TelemetrySessionFinalization) async throws
    func unfinishedSessions() async throws -> [WorkoutSessionRecord]
}

public protocol TelemetryRecorderScheduler: AnyObject, Sendable {
    func now() -> Duration
    func schedule(after delay: Duration, operation: @escaping @Sendable () -> Void)
    func cancelScheduledOperation()
}

public enum TelemetryFlushReason: String, Hashable, Sendable {
    case explicit
    case applicationBackground
    case applicationLifecycle
    case sessionFinish
}

public enum TelemetryRecorderCompleteness: String, Hashable, Sendable {
    case complete
    case incomplete
    case failed
    case cancelled
}

public enum TelemetryRecorderLifecycleState: String, Hashable, Sendable {
    case beginning
    case active
    case finishing
    case failing
    case cancelling
    case complete
    case incomplete
    case failed
    case cancelled
}

public struct TelemetryRecorderOperationalState: Equatable, Sendable {
    public let queueDepth: Int
    public let peakQueueDepth: Int
    public let coalescedFrameCount: UInt64
    public let droppedFrameCount: UInt64
    public let lostNativeCount: UInt64
    public let lostCriticalCount: UInt64
    public let writerFailureCount: UInt64
    public let retryCount: UInt64
    public let successfulFlushCount: UInt64
    public let lastCommittedRecorderSequence: UInt64?
    public let mostRecentFlushDuration: Duration?
    public let lifecycleState: TelemetryRecorderLifecycleState
    public let completeness: TelemetryRecorderCompleteness

    public init(
        queueDepth: Int,
        peakQueueDepth: Int,
        coalescedFrameCount: UInt64,
        droppedFrameCount: UInt64,
        lostNativeCount: UInt64,
        lostCriticalCount: UInt64,
        writerFailureCount: UInt64,
        retryCount: UInt64,
        successfulFlushCount: UInt64,
        lastCommittedRecorderSequence: UInt64?,
        mostRecentFlushDuration: Duration?,
        lifecycleState: TelemetryRecorderLifecycleState,
        completeness: TelemetryRecorderCompleteness
    ) {
        self.queueDepth = queueDepth
        self.peakQueueDepth = peakQueueDepth
        self.coalescedFrameCount = coalescedFrameCount
        self.droppedFrameCount = droppedFrameCount
        self.lostNativeCount = lostNativeCount
        self.lostCriticalCount = lostCriticalCount
        self.writerFailureCount = writerFailureCount
        self.retryCount = retryCount
        self.successfulFlushCount = successfulFlushCount
        self.lastCommittedRecorderSequence = lastCommittedRecorderSequence
        self.mostRecentFlushDuration = mostRecentFlushDuration
        self.lifecycleState = lifecycleState
        self.completeness = completeness
    }
}

public struct TelemetryFlushResult: Equatable, Sendable {
    public let lastCommittedRecorderSequence: UInt64?
    public let completeness: TelemetryRecorderCompleteness

    public init(
        lastCommittedRecorderSequence: UInt64?,
        completeness: TelemetryRecorderCompleteness
    ) {
        self.lastCommittedRecorderSequence = lastCommittedRecorderSequence
        self.completeness = completeness
    }
}

public struct TelemetryFinishResult: Equatable, Sendable {
    public let completeness: TelemetryRecorderCompleteness
    public let lastCommittedRecorderSequence: UInt64?

    public init(
        completeness: TelemetryRecorderCompleteness,
        lastCommittedRecorderSequence: UInt64?
    ) {
        self.completeness = completeness
        self.lastCommittedRecorderSequence = lastCommittedRecorderSequence
    }
}

extension TelemetryPersistenceRecord {
    var recordClass: TelemetryRecordClass {
        switch self {
        case .source, .event:
            .critical
        case .heartRate, .treadmill:
            .native
        case .frame:
            .bulkFrame
        }
    }

    var persistedElapsed: ElapsedDuration? {
        switch self {
        case .source:
            nil
        case let .heartRate(observation):
            observation.timestamp.recordedElapsed
        case let .treadmill(observation):
            observation.timestamp.recordedElapsed
        case let .event(event):
            event.timestamp.recordedElapsed
        case let .frame(frame):
            frame.materializedAt.elapsed
        }
    }
}

struct CanonicalFrameIdentity: Hashable, Sendable {
    let sessionID: SessionID
    let elapsedSecond: Int64

    init(_ frame: CanonicalFrame) {
        sessionID = frame.sessionID
        elapsedSecond = frame.canonicalElapsedSecond
    }
}
