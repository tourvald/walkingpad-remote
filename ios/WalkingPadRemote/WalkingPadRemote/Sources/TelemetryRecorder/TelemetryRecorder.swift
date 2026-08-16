import Foundation
import TelemetryDomain

public final class TelemetryIngress: @unchecked Sendable {
    private let core: TelemetryRecorderCore
    private let scheduler: any TelemetryRecorderScheduler

    fileprivate init(
        core: TelemetryRecorderCore,
        scheduler: any TelemetryRecorderScheduler
    ) {
        self.core = core
        self.scheduler = scheduler
    }

    @discardableResult
    public func yield(_ record: TelemetryPersistenceRecord) -> TelemetryYieldReceipt {
        core.yield(record, at: scheduler.now())
    }
}

public final class TelemetryRecorder: @unchecked Sendable {
    public let ingress: TelemetryIngress

    private let core: TelemetryRecorderCore
    private let scheduler: any TelemetryRecorderScheduler
    private let continuation: AsyncStream<Void>.Continuation
    private let consumerTask: Task<Void, Never>

    public init(
        sessionHeader: WorkoutSessionRecord,
        persistence: any TelemetryRecorderPersistence,
        bufferPolicy: TelemetryBufferPolicy = .initialDefault,
        batchPolicy: TelemetryBatchPolicy = .initialDefault,
        retryPolicy: TelemetryRetryPolicy = .initialDefault,
        scheduler: any TelemetryRecorderScheduler = ContinuousTelemetryRecorderScheduler()
    ) {
        var capturedContinuation: AsyncStream<Void>.Continuation?
        let stream = AsyncStream<Void>(
            Void.self,
            bufferingPolicy: .bufferingNewest(1)
        ) { streamContinuation in
            capturedContinuation = streamContinuation
        }
        guard let streamContinuation = capturedContinuation else {
            preconditionFailure("AsyncStream must synchronously provide its continuation.")
        }

        let core = TelemetryRecorderCore(
            sessionHeader: sessionHeader,
            bufferPolicy: bufferPolicy,
            batchPolicy: batchPolicy,
            retryPolicy: retryPolicy,
            continuation: streamContinuation
        )
        self.core = core
        self.scheduler = scheduler
        continuation = streamContinuation
        ingress = TelemetryIngress(core: core, scheduler: scheduler)
        consumerTask = Task.detached(priority: .utility) {
            await Self.consume(
                core: core,
                persistence: persistence,
                scheduler: scheduler,
                stream: stream,
                continuation: streamContinuation
            )
        }
    }

    deinit {
        core.requestCancellation(completion: nil)
        core.wake()
    }

    public var operationalState: TelemetryRecorderOperationalState {
        core.operationalState()
    }

    public func requestFlush(reason: TelemetryFlushReason) {
        core.requestFlush(reason: reason)
        core.wake()
    }

    public func flush(reason: TelemetryFlushReason) async -> TelemetryFlushResult {
        await withCheckedContinuation { continuation in
            if let immediate = core.requestFlush(reason: reason, completion: { result in
                continuation.resume(returning: result)
            }) {
                continuation.resume(returning: immediate)
            } else {
                core.wake()
            }
        }
    }

    public func finish(
        endedAt: Date,
        endedElapsed: ElapsedDuration
    ) async -> TelemetryFinishResult {
        await withCheckedContinuation { continuation in
            if let immediate = core.requestFinish(
                endedAt: endedAt,
                endedElapsed: endedElapsed,
                completion: { result in continuation.resume(returning: result) }
            ) {
                continuation.resume(returning: immediate)
            } else {
                core.wake()
            }
        }
    }

    public func fail(reason: String) async -> TelemetryFinishResult {
        await withCheckedContinuation { continuation in
            if let immediate = core.requestFailure(
                reason: reason,
                completion: { result in continuation.resume(returning: result) }
            ) {
                continuation.resume(returning: immediate)
            } else {
                core.wake()
            }
        }
    }

    @discardableResult
    public func requestFailure(reason: String) -> Bool {
        let accepted = core.requestFailure(reason: reason, completion: nil) == nil
        if accepted {
            core.wake()
        }
        return accepted
    }

    @discardableResult
    public func requestIncomplete(
        endedAt: Date,
        endedElapsed: ElapsedDuration,
        reason: String,
        lostCriticalRecordCount: UInt64,
        lostNativeRecordCount: UInt64
    ) -> Bool {
        let accepted = core.requestIncomplete(
            endedAt: endedAt,
            endedElapsed: endedElapsed,
            reason: reason,
            lostCriticalRecordCount: lostCriticalRecordCount,
            lostNativeRecordCount: lostNativeRecordCount
        ) == nil
        if accepted {
            core.wake()
        }
        return accepted
    }

    public func cancel() async -> TelemetryFinishResult {
        await withCheckedContinuation { continuation in
            if let immediate = core.requestCancellation(
                completion: { result in continuation.resume(returning: result) }
            ) {
                continuation.resume(returning: immediate)
            } else {
                core.wake()
            }
        }
    }

    @discardableResult
    public func requestCancellation() -> Bool {
        let accepted = core.requestCancellation(completion: nil) == nil
        if accepted {
            core.wake()
        }
        return accepted
    }

    public static func recoverUnfinishedSessions(
        using persistence: any TelemetryRecorderPersistence,
        reason: String = "recorder-recovered-unfinished-session"
    ) async throws -> [WorkoutSessionRecord] {
        let unfinished = try await persistence.unfinishedSessions()
        for session in unfinished {
            let finalization = TelemetrySessionFinalization(
                sessionID: session.sessionID,
                lifecycleState: .incomplete,
                endedAt: nil,
                endedElapsed: nil,
                incompleteReason: reason,
                recorderHealth: RecorderHealthSummary(
                    isComplete: false,
                    lostCriticalRecordCount: session.recorderHealth.lostCriticalRecordCount,
                    lostNativeRecordCount: session.recorderHealth.lostNativeRecordCount,
                    lastPersistedElapsed: session.recorderHealth.lastPersistedElapsed
                )
            )
            try await persistence.finalizeSession(finalization)
        }
        return unfinished
    }
}

private extension TelemetryRecorder {
    enum PersistenceAttemptResult {
        case success
        case aborted
        case failure(Error)
    }

    static func consume(
        core: TelemetryRecorderCore,
        persistence: any TelemetryRecorderPersistence,
        scheduler: any TelemetryRecorderScheduler,
        stream: AsyncStream<Void>,
        continuation: AsyncStream<Void>.Continuation
    ) async {
        var iterator = stream.makeAsyncIterator()

        let beginIntentGeneration = core.terminalIntentGenerationSnapshot()
        let beginResult = await attemptPersistence(
            core: core,
            scheduler: scheduler,
            iterator: &iterator
        ) {
            try await persistence.beginSession(core.sessionHeader)
        }
        switch beginResult {
        case .success:
            core.headerPersisted()
            core.resumeSatisfiedFlushes()
        case .aborted:
            await terminateRequestedRecorder(
                core: core,
                persistence: persistence
            )
            continuation.finish()
            return
        case let .failure(error):
            core.persistenceBecameTerminalIfIntentUnchanged(
                error: error,
                uncertainRecords: [],
                expectedGeneration: beginIntentGeneration
            )
            await terminateRequestedRecorder(
                core: core,
                persistence: persistence
            )
            continuation.finish()
            return
        }

        while true {
            switch core.nextConsumerAction(now: scheduler.now()) {
            case let .persist(batch, intentGeneration):
                cancelTimer(core: core, scheduler: scheduler)
                let startedAt = scheduler.now()
                let result = await attemptPersistence(
                    core: core,
                    scheduler: scheduler,
                    iterator: &iterator
                ) {
                    try await persistence.persistBatch(batch)
                }
                switch result {
                case .success:
                    core.batchCommitted(
                        batch,
                        duration: nonnegativeDuration(from: startedAt, to: scheduler.now())
                    )
                    core.resumeSatisfiedFlushes()
                case .aborted:
                    core.restoreUncertainBatchForAccounting(batch)
                case let .failure(error):
                    core.persistenceBecameTerminalIfIntentUnchanged(
                        error: error,
                        uncertainRecords: batch,
                        expectedGeneration: intentGeneration
                    )
                    await terminateRequestedRecorder(
                        core: core,
                        persistence: persistence
                    )
                    continuation.finish()
                    return
                }

            case let .scheduleFlush(after):
                armTimer(
                    core: core,
                    scheduler: scheduler,
                    purpose: .flush,
                    delay: after
                )

            case .terminateRequested:
                cancelTimer(core: core, scheduler: scheduler)
                await terminateRequestedRecorder(
                    core: core,
                    persistence: persistence
                )
                continuation.finish()
                return

            case let .finalize(
                finalization,
                intendedCompleteness,
                intentGeneration
            ):
                cancelTimer(core: core, scheduler: scheduler)
                let result = await attemptPersistence(
                    core: core,
                    scheduler: scheduler,
                    iterator: &iterator
                ) {
                    try await persistence.finalizeSession(finalization)
                }
                switch result {
                case .success:
                    if !core.completeFinalizationIfUnchanged(intendedCompleteness) {
                        await terminateRequestedRecorder(
                            core: core,
                            persistence: persistence
                        )
                    }
                case .aborted:
                    await terminateRequestedRecorder(
                        core: core,
                        persistence: persistence
                    )
                case let .failure(error):
                    core.persistenceBecameTerminalIfIntentUnchanged(
                        error: error,
                        uncertainRecords: [],
                        expectedGeneration: intentGeneration
                    )
                    await terminateRequestedRecorder(
                        core: core,
                        persistence: persistence
                    )
                }
                continuation.finish()
                return

            case .wait:
                guard await iterator.next() != nil else {
                    core.requestCancellation(completion: nil)
                    continue
                }
            }
        }
    }

    static func attemptPersistence(
        core: TelemetryRecorderCore,
        scheduler: any TelemetryRecorderScheduler,
        iterator: inout AsyncStream<Void>.Iterator,
        operation: @escaping @Sendable () async throws -> Void
    ) async -> PersistenceAttemptResult {
        var retryCount = 0
        while true {
            if core.persistenceShouldAbort() {
                return .aborted
            }
            do {
                try await operation()
                return .success
            } catch {
                core.writerAttemptFailed()
                guard case .retryableBeforeCommit = error as? TelemetryPersistenceOperationError,
                      retryCount < core.retryPolicy.maximumPrecommitRetries,
                      !core.persistenceShouldAbort()
                else {
                    return .failure(error)
                }

                retryCount += 1
                core.retryScheduled()
                cancelTimer(core: core, scheduler: scheduler)
                let token = armTimer(
                    core: core,
                    scheduler: scheduler,
                    purpose: .retry,
                    delay: core.retryPolicy.delay
                )
                while !core.takeRetryTimerIfReady(token: token) {
                    if core.persistenceShouldAbort() {
                        cancelTimer(core: core, scheduler: scheduler)
                        return .aborted
                    }
                    guard await iterator.next() != nil else {
                        return .aborted
                    }
                }
            }
        }
    }

    @discardableResult
    static func armTimer(
        core: TelemetryRecorderCore,
        scheduler: any TelemetryRecorderScheduler,
        purpose: TelemetryRecorderTimerPurpose,
        delay: Duration
    ) -> TelemetryRecorderTimerToken {
        let token = core.armTimer(purpose: purpose)
        scheduler.schedule(after: max(delay, .zero)) { [weak core] in
            core?.timerFired(token)
        }
        return token
    }

    static func cancelTimer(
        core: TelemetryRecorderCore,
        scheduler: any TelemetryRecorderScheduler
    ) {
        if core.cancelTimer() {
            scheduler.cancelScheduledOperation()
        }
    }

    static func terminateRequestedRecorder(
        core: TelemetryRecorderCore,
        persistence: any TelemetryRecorderPersistence
    ) async {
        while true {
            let (finalization, intendedCompleteness, generation) = core
                .prepareRequestedTermination()
            do {
                try await persistence.finalizeSession(finalization)
            } catch {
                core.writerAttemptFailed()
                guard let failureGeneration = core
                    .persistenceBecameTerminalIfIntentUnchanged(
                        error: error,
                        uncertainRecords: [],
                        expectedGeneration: generation
                    ) else {
                    continue
                }
                if core.completeRequestedTerminationIfUnchanged(
                    .failed,
                    generation: failureGeneration
                ) {
                    return
                }
                continue
            }
            if core.completeRequestedTerminationIfUnchanged(
                intendedCompleteness,
                generation: generation
            ) {
                return
            }
        }
    }

    static func nonnegativeDuration(from start: Duration, to end: Duration) -> Duration {
        max(end - start, .zero)
    }
}

enum TelemetryRecorderTimerPurpose: Sendable {
    case flush
    case retry
}

struct TelemetryRecorderTimerToken: Equatable, Sendable {
    let generation: UInt64
    let purpose: TelemetryRecorderTimerPurpose
}

enum TelemetryRecorderConsumerAction: Sendable {
    case persist([SequencedTelemetryRecord], intentGeneration: UInt64)
    case scheduleFlush(Duration)
    case terminateRequested
    case finalize(
        TelemetrySessionFinalization,
        TelemetryRecorderCompleteness,
        intentGeneration: UInt64
    )
    case wait
}
