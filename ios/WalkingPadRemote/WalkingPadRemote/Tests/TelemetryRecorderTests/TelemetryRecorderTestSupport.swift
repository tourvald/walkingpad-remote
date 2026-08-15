import Foundation
import TelemetryDomain
@testable import TelemetryRecorder

final class ManualTelemetryRecorderScheduler: TelemetryRecorderScheduler,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var current: Duration = .zero
    private var deadline: Duration?
    private var operation: (@Sendable () -> Void)?
    private var scheduleWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var maximumOutstandingOperationCount = 0

    func now() -> Duration {
        lock.withLock { current }
    }

    func schedule(after delay: Duration, operation: @escaping @Sendable () -> Void) {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            deadline = current + max(delay, .zero)
            self.operation = operation
            maximumOutstandingOperationCount = max(maximumOutstandingOperationCount, 1)
            defer { scheduleWaiters.removeAll(keepingCapacity: false) }
            return scheduleWaiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func cancelScheduledOperation() {
        lock.withLock {
            deadline = nil
            operation = nil
        }
    }

    func advance(by duration: Duration) {
        let ready: (@Sendable () -> Void)? = lock.withLock {
            current += max(duration, .zero)
            guard let deadline, deadline <= current else {
                return nil
            }
            defer {
                self.deadline = nil
                operation = nil
            }
            return operation
        }
        ready?()
    }

    var hasScheduledOperation: Bool {
        lock.withLock { operation != nil }
    }

    func waitUntilScheduled() async {
        if hasScheduledOperation {
            return
        }
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                if operation != nil {
                    return true
                }
                scheduleWaiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }
}

actor InMemoryTelemetryRecorderPersistence: TelemetryRecorderPersistence {
    enum Behavior: Sendable {
        case success
        case retryableBeforeCommit
        case terminal
        case ambiguousAfterCommit
    }

    private(set) var headers: [WorkoutSessionRecord] = []
    private(set) var batches: [[SequencedTelemetryRecord]] = []
    private(set) var finalizations: [TelemetrySessionFinalization] = []
    private(set) var batchCallCount = 0
    private(set) var beginCallCount = 0
    private(set) var finalizeCallCount = 0
    private var batchBehaviors: [Behavior]
    private var beginBehaviors: [Behavior]
    private var finalizeBehaviors: [Behavior]
    private var unfinished: [WorkoutSessionRecord]
    private var suspendsNextFinalization: Bool
    private var suspendedFinalization: CheckedContinuation<Void, Never>?
    private var headerWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var batchWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var finalizationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var batchCallWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var finalizeCallWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(
        batchBehaviors: [Behavior] = [],
        beginBehaviors: [Behavior] = [],
        finalizeBehaviors: [Behavior] = [],
        unfinished: [WorkoutSessionRecord] = [],
        suspendNextFinalization: Bool = false
    ) {
        self.batchBehaviors = batchBehaviors
        self.beginBehaviors = beginBehaviors
        self.finalizeBehaviors = finalizeBehaviors
        self.unfinished = unfinished
        suspendsNextFinalization = suspendNextFinalization
    }

    func beginSession(_ header: WorkoutSessionRecord) async throws {
        beginCallCount += 1
        let behavior = nextBehavior(&beginBehaviors)
        switch behavior {
        case .success:
            headers.append(header)
            resumeHeaderWaiters()
        case .retryableBeforeCommit:
            throw TelemetryPersistenceOperationError.retryableBeforeCommit(code: "fake-begin")
        case .terminal:
            throw TelemetryPersistenceOperationError.terminal(code: "fake-begin")
        case .ambiguousAfterCommit:
            headers.append(header)
            resumeHeaderWaiters()
            throw TelemetryPersistenceOperationError.commitOutcomeUnknown(code: "fake-begin")
        }
    }

    func persistBatch(_ records: [SequencedTelemetryRecord]) async throws {
        batchCallCount += 1
        resumeBatchCallWaiters()
        let behavior = nextBehavior(&batchBehaviors)
        switch behavior {
        case .success:
            batches.append(records)
            resumeBatchWaiters()
        case .retryableBeforeCommit:
            throw TelemetryPersistenceOperationError.retryableBeforeCommit(code: "fake-batch")
        case .terminal:
            throw TelemetryPersistenceOperationError.terminal(code: "fake-batch")
        case .ambiguousAfterCommit:
            batches.append(records)
            resumeBatchWaiters()
            throw TelemetryPersistenceOperationError.commitOutcomeUnknown(code: "fake-batch")
        }
    }

    func finalizeSession(_ finalization: TelemetrySessionFinalization) async throws {
        finalizeCallCount += 1
        resumeFinalizeCallWaiters()
        let behavior = nextBehavior(&finalizeBehaviors)
        if suspendsNextFinalization {
            suspendsNextFinalization = false
            await withCheckedContinuation { continuation in
                suspendedFinalization = continuation
            }
        }
        switch behavior {
        case .success:
            finalizations.append(finalization)
            resumeFinalizationWaiters()
        case .retryableBeforeCommit:
            throw TelemetryPersistenceOperationError.retryableBeforeCommit(code: "fake-finalize")
        case .terminal:
            throw TelemetryPersistenceOperationError.terminal(code: "fake-finalize")
        case .ambiguousAfterCommit:
            finalizations.append(finalization)
            resumeFinalizationWaiters()
            throw TelemetryPersistenceOperationError.commitOutcomeUnknown(code: "fake-finalize")
        }
    }

    func unfinishedSessions() async throws -> [WorkoutSessionRecord] {
        unfinished
    }

    func waitForHeaders(_ count: Int) async {
        guard headers.count < count else {
            return
        }
        await withCheckedContinuation { continuation in
            headerWaiters.append((count, continuation))
        }
    }

    func waitForBatches(_ count: Int) async {
        guard batches.count < count else {
            return
        }
        await withCheckedContinuation { continuation in
            batchWaiters.append((count, continuation))
        }
    }

    func waitForBatchCalls(_ count: Int) async {
        guard batchCallCount < count else {
            return
        }
        await withCheckedContinuation { continuation in
            batchCallWaiters.append((count, continuation))
        }
    }

    func waitForFinalizations(_ count: Int) async {
        guard finalizations.count < count else {
            return
        }
        await withCheckedContinuation { continuation in
            finalizationWaiters.append((count, continuation))
        }
    }

    func waitForFinalizeCalls(_ count: Int) async {
        guard finalizeCallCount < count else {
            return
        }
        await withCheckedContinuation { continuation in
            finalizeCallWaiters.append((count, continuation))
        }
    }

    func resumeSuspendedFinalization() {
        guard let continuation = suspendedFinalization else {
            preconditionFailure("A finalization must be suspended before it can resume.")
        }
        suspendedFinalization = nil
        continuation.resume()
    }

    func suspendNextFinalization() {
        precondition(!suspendsNextFinalization)
        suspendsNextFinalization = true
    }

    func snapshot() -> (
        headers: [WorkoutSessionRecord],
        batches: [[SequencedTelemetryRecord]],
        finalizations: [TelemetrySessionFinalization],
        batchCalls: Int,
        beginCalls: Int,
        finalizeCalls: Int
    ) {
        (headers, batches, finalizations, batchCallCount, beginCallCount, finalizeCallCount)
    }

    private func nextBehavior(_ behaviors: inout [Behavior]) -> Behavior {
        behaviors.isEmpty ? .success : behaviors.removeFirst()
    }

    private func resumeHeaderWaiters() {
        resume(waiters: &headerWaiters, currentCount: headers.count)
    }

    private func resumeBatchWaiters() {
        resume(waiters: &batchWaiters, currentCount: batches.count)
    }

    private func resumeBatchCallWaiters() {
        resume(waiters: &batchCallWaiters, currentCount: batchCallCount)
    }

    private func resumeFinalizationWaiters() {
        resume(waiters: &finalizationWaiters, currentCount: finalizations.count)
    }

    private func resumeFinalizeCallWaiters() {
        resume(waiters: &finalizeCallWaiters, currentCount: finalizeCallCount)
    }

    private func resume(
        waiters: inout [(Int, CheckedContinuation<Void, Never>)],
        currentCount: Int
    ) {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if currentCount >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }
}

enum TelemetryRecorderFixtures {
    static let baseDate = Date(timeIntervalSince1970: 1_820_000_000)

    static func session() -> WorkoutSessionRecord {
        WorkoutSessionRecord(
            recordID: RecordID(),
            sessionID: SessionID(),
            profileLocalIdentifier: "recorder-test-profile",
            lifecycleState: .running,
            workoutMode: .heartRateControlled,
            startedAt: baseDate,
            endedAt: nil,
            endedElapsed: nil,
            incompleteReason: nil,
            appContext: AppRuntimeContext(
                appVersion: "1.0",
                buildNumber: "1",
                operatingSystemVersion: "test"
            ),
            versions: RuntimeVersionContext(
                telemetrySchema: TelemetrySchemaVersion(rawValue: "1.0.0"),
                algorithm: AlgorithmVersion(rawValue: "test-algorithm"),
                safetyPolicy: SafetyPolicyVersion(rawValue: "test-safety"),
                workoutProtocol: WorkoutProtocolVersion(rawValue: "test-workout")
            ),
            configuration: ImmutableConfigurationSnapshot(
                id: ConfigurationSnapshotID(),
                formatVersion: 1,
                format: .canonicalJSON,
                canonicalPayload: Data("{}".utf8),
                contentHash: ContentHash(
                    algorithm: .sha256,
                    lowercaseHexDigest: String(repeating: "0", count: 64)
                )
            ),
            healthKitWorkoutIdentifier: nil,
            treadmill: nil,
            recorderHealth: RecorderHealthSummary(
                isComplete: false,
                lostCriticalRecordCount: 0,
                lostNativeRecordCount: 0,
                lastPersistedElapsed: nil
            )
        )
    }

    static func source() -> SignalSourceIdentity {
        SignalSourceIdentity(
            id: SourceID(),
            providerKind: .healthKitSelected,
            stableLocalKey: UUID().uuidString
        )
    }

    static func sourceRecord(_ source: SignalSourceIdentity? = nil) -> TelemetryPersistenceRecord {
        .source(
            TelemetrySourceRecord(
                identity: source ?? self.source(),
                firstSeen: baseDate,
                lastSeen: baseDate
            )
        )
    }

    static func heartRate(
        sessionID: SessionID,
        source: SignalSourceIdentity,
        order: UInt64,
        bpm: UInt16 = 120
    ) -> TelemetryPersistenceRecord {
        let elapsed = ElapsedDuration(microseconds: Int64(order) * 1_000)
        return .heartRate(
            HeartRateObservation(
                recordID: RecordID(),
                observationID: ObservationID(),
                sessionID: sessionID,
                source: source,
                beatsPerMinute: bpm,
                arrivalOrder: order,
                providerSequence: Int64(order),
                providerSampleIdentity: nil,
                timestamp: ObservationTimestamp(
                    measuredAt: baseDate,
                    receivedAt: baseDate,
                    recordedAt: baseDate,
                    measuredElapsed: elapsed,
                    receivedElapsed: elapsed,
                    recordedElapsed: elapsed
                ),
                provenance: .measuredByProvider,
                freshness: EvidenceFreshness(
                    state: .fresh,
                    evaluatedAt: RecordTimestamp(recordedAt: baseDate, elapsed: elapsed),
                    age: .zero,
                    policyVersion: SafetyPolicyVersion(rawValue: "test-safety")
                ),
                quality: [],
                controlUse: .acceptedNotUsed
            )
        )
    }

    static func treadmill(
        sessionID: SessionID,
        source: SignalSourceIdentity,
        order: UInt64
    ) -> TelemetryPersistenceRecord {
        let elapsed = ElapsedDuration(microseconds: Int64(order) * 1_000)
        return .treadmill(
            TreadmillObservation(
                recordID: RecordID(),
                observationID: ObservationID(),
                sessionID: sessionID,
                source: source,
                nativeSpeed: NativeTreadmillSpeed(value: 5, unit: .kilometresPerHour),
                deviceState: .moving,
                arrivalOrder: order,
                timestamp: ObservationTimestamp(
                    measuredAt: baseDate,
                    receivedAt: baseDate,
                    recordedAt: baseDate,
                    measuredElapsed: elapsed,
                    receivedElapsed: elapsed,
                    recordedElapsed: elapsed
                ),
                provenance: .decodedDeviceReport,
                freshness: EvidenceFreshness(
                    state: .fresh,
                    evaluatedAt: RecordTimestamp(recordedAt: baseDate, elapsed: elapsed),
                    age: .zero,
                    policyVersion: SafetyPolicyVersion(rawValue: "test-safety")
                ),
                quality: []
            )
        )
    }

    static func event(sessionID: SessionID, order: UInt64) -> TelemetryPersistenceRecord {
        let elapsed = ElapsedDuration(microseconds: Int64(order) * 1_000)
        return .event(
            WorkoutEvent(
                recordID: RecordID(),
                sessionID: sessionID,
                timestamp: EventTimestamp(
                    occurredAt: baseDate,
                    recordedAt: baseDate,
                    occurredElapsed: elapsed,
                    recordedElapsed: elapsed
                ),
                payload: EventPayloadEnvelope(
                    schemaVersion: 1,
                    payload: .recorderHealth(
                        RecorderHealthEvent(kind: .drain, count: order)
                    )
                )
            )
        )
    }

    static func frame(sessionID: SessionID, second: Int64) -> TelemetryPersistenceRecord {
        .frame(
            CanonicalFrame(
                frameID: FrameID(),
                recordID: RecordID(),
                sessionID: sessionID,
                canonicalElapsedSecond: second,
                materializedAt: RecordTimestamp(
                    recordedAt: baseDate,
                    elapsed: ElapsedDuration(microseconds: second * 1_000_000)
                ),
                heartRateEvidence: nil,
                treadmillEvidence: nil
            )
        )
    }
}
