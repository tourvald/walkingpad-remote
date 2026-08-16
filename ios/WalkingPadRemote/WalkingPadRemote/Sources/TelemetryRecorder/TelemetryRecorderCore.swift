import Foundation
import TelemetryDomain

final class TelemetryRecorderCore: @unchecked Sendable {
    typealias FlushCompletion = @Sendable (TelemetryFlushResult) -> Void
    typealias FinishCompletion = @Sendable (TelemetryFinishResult) -> Void

    private enum Phase {
        case beginning
        case active
        case finishing(
            endedAt: Date,
            endedElapsed: ElapsedDuration,
            incompleteReason: String?
        )
        case finalizing(TelemetryRecorderCompleteness)
        case failing(reason: String)
        case cancelling
        case terminal(TelemetryRecorderCompleteness)
    }

    private enum TerminalTransitionExpectation {
        case finalizing(TelemetryRecorderCompleteness)
        case requested(TelemetryRecorderCompleteness, generation: UInt64)
    }

    private struct FlushWaiter {
        let targetSequence: UInt64?
        let completion: FlushCompletion
    }

    let sessionHeader: WorkoutSessionRecord
    let retryPolicy: TelemetryRetryPolicy

    private let lock = NSLock()
    private let batchPolicy: TelemetryBatchPolicy
    private let continuation: AsyncStream<Void>.Continuation
    private var buffer: BoundedTelemetryBuffer
    private var phase: Phase = .beginning
    private var headerIsPersisted = false
    private var nextSequence: UInt64? = 1
    private var lastAcceptedSequence: UInt64?
    private var forcedFlushThrough: UInt64?
    private var flushWaiters: [FlushWaiter] = []
    private var finishCompletions: [FinishCompletion] = []
    private var timerGeneration: UInt64 = 0
    private var armedTimer: TelemetryRecorderTimerToken?
    private var readyRetryTimer: TelemetryRecorderTimerToken?
    private var knownLoss = false
    private var terminalIntentGeneration: UInt64 = 0

    private var peakQueueDepth = 0
    private var coalescedFrameCount: UInt64 = 0
    private var droppedFrameCount: UInt64 = 0
    private var lostNativeCount: UInt64 = 0
    private var lostCriticalCount: UInt64 = 0
    private var writerFailureCount: UInt64 = 0
    private var retryCount: UInt64 = 0
    private var successfulFlushCount: UInt64 = 0
    private var lastCommittedSequence: UInt64?
    private var lastPersistedElapsed: ElapsedDuration?
    private var mostRecentFlushDuration: Duration?

    init(
        sessionHeader: WorkoutSessionRecord,
        bufferPolicy: TelemetryBufferPolicy,
        batchPolicy: TelemetryBatchPolicy,
        retryPolicy: TelemetryRetryPolicy,
        continuation: AsyncStream<Void>.Continuation
    ) {
        self.sessionHeader = sessionHeader
        self.batchPolicy = batchPolicy
        self.retryPolicy = retryPolicy
        self.continuation = continuation
        buffer = BoundedTelemetryBuffer(policy: bufferPolicy)
    }

    func wake() {
        continuation.yield()
    }

    func yield(
        _ record: TelemetryPersistenceRecord,
        at enqueueTime: Duration
    ) -> TelemetryYieldReceipt {
        var shouldWake = false
        let receipt = lock.withLock { () -> TelemetryYieldReceipt in
            switch phase {
            case .beginning, .active:
                break
            case .finishing:
                guard let sequence = allocateSequence() else {
                    accountLoss(for: record.recordClass)
                    return TelemetryYieldReceipt(
                        recorderSequence: nil,
                        disposition: .sequenceExhausted
                    )
                }
                accountLoss(for: record.recordClass)
                shouldWake = true
                return TelemetryYieldReceipt(
                    recorderSequence: sequence,
                    disposition: .rejectedAfterFinish
                )
            case .finalizing:
                return TelemetryYieldReceipt(
                    recorderSequence: nil,
                    disposition: .rejectedTerminal
                )
            case .failing, .cancelling:
                guard let sequence = allocateSequence() else {
                    accountLoss(for: record.recordClass)
                    return TelemetryYieldReceipt(
                        recorderSequence: nil,
                        disposition: .sequenceExhausted
                    )
                }
                accountLoss(for: record.recordClass)
                shouldWake = true
                return TelemetryYieldReceipt(
                    recorderSequence: sequence,
                    disposition: .rejectedTerminal
                )
            case let .terminal(completeness):
                guard completeness != .complete else {
                    return TelemetryYieldReceipt(
                        recorderSequence: nil,
                        disposition: .rejectedTerminal
                    )
                }
                guard let sequence = allocateSequence() else {
                    accountLoss(for: record.recordClass)
                    return TelemetryYieldReceipt(
                        recorderSequence: nil,
                        disposition: .sequenceExhausted
                    )
                }
                accountLoss(for: record.recordClass)
                return TelemetryYieldReceipt(
                    recorderSequence: sequence,
                    disposition: .rejectedTerminal
                )
            }

            guard let sequence = allocateSequence() else {
                accountLoss(for: record.recordClass)
                shouldWake = true
                return TelemetryYieldReceipt(
                    recorderSequence: nil,
                    disposition: .sequenceExhausted
                )
            }

            let wasEmpty = buffer.isEmpty
            let result = buffer.enqueue(
                SequencedTelemetryRecord(recorderSequence: sequence, record: record),
                at: enqueueTime
            )
            if result.evictedBulkFrame {
                increment(&droppedFrameCount)
                knownLoss = true
            }
            switch result.disposition {
            case .enqueued:
                lastAcceptedSequence = sequence
            case .coalescedFrame:
                increment(&coalescedFrameCount)
                lastAcceptedSequence = sequence
            case .droppedFrame:
                increment(&droppedFrameCount)
                knownLoss = true
            case .lostNative:
                increment(&lostNativeCount)
                knownLoss = true
            case .lostCritical:
                increment(&lostCriticalCount)
                knownLoss = true
            case .rejectedAfterFinish, .rejectedTerminal, .sequenceExhausted:
                preconditionFailure("The active buffer cannot return a lifecycle disposition.")
            }
            peakQueueDepth = max(peakQueueDepth, buffer.count)
            shouldWake = wasEmpty || buffer.count == batchPolicy.maximumRecordCount
            return TelemetryYieldReceipt(
                recorderSequence: sequence,
                disposition: result.disposition
            )
        }
        if shouldWake {
            wake()
        }
        return receipt
    }

    func requestFlush(reason _: TelemetryFlushReason) {
        lock.withLock {
            forcedFlushThrough = laterSequence(forcedFlushThrough, lastAcceptedSequence)
        }
    }

    func requestFlush(
        reason _: TelemetryFlushReason,
        completion: @escaping FlushCompletion
    ) -> TelemetryFlushResult? {
        lock.withLock {
            if case let .terminal(completeness) = phase {
                return TelemetryFlushResult(
                    lastCommittedRecorderSequence: lastCommittedSequence,
                    completeness: completeness
                )
            }
            let target = lastAcceptedSequence
            if headerIsPersisted,
               (target == nil || sequence(lastCommittedSequence, satisfies: target))
            {
                return TelemetryFlushResult(
                    lastCommittedRecorderSequence: lastCommittedSequence,
                    completeness: currentCompleteness
                )
            }
            forcedFlushThrough = laterSequence(forcedFlushThrough, target)
            flushWaiters.append(FlushWaiter(targetSequence: target, completion: completion))
            return nil
        }
    }

    func requestFinish(
        endedAt: Date,
        endedElapsed: ElapsedDuration,
        completion: @escaping FinishCompletion
    ) -> TelemetryFinishResult? {
        lock.withLock {
            if case let .terminal(completeness) = phase {
                return TelemetryFinishResult(
                    completeness: completeness,
                    lastCommittedRecorderSequence: lastCommittedSequence
                )
            }
            finishCompletions.append(completion)
            switch phase {
            case .beginning, .active:
                phase = .finishing(
                    endedAt: endedAt,
                    endedElapsed: endedElapsed,
                    incompleteReason: nil
                )
                forcedFlushThrough = laterSequence(forcedFlushThrough, lastAcceptedSequence)
            case .finishing, .finalizing, .failing, .cancelling, .terminal:
                break
            }
            return nil
        }
    }

    func requestIncomplete(
        endedAt: Date,
        endedElapsed: ElapsedDuration,
        reason: String,
        lostCriticalRecordCount: UInt64,
        lostNativeRecordCount: UInt64
    ) -> TelemetryFinishResult? {
        lock.withLock {
            if case let .terminal(completeness) = phase {
                return TelemetryFinishResult(
                    completeness: completeness,
                    lastCommittedRecorderSequence: lastCommittedSequence
                )
            }
            add(lostCriticalRecordCount, to: &lostCriticalCount)
            add(lostNativeRecordCount, to: &lostNativeCount)
            knownLoss = true
            switch phase {
            case .beginning, .active:
                phase = .finishing(
                    endedAt: endedAt,
                    endedElapsed: endedElapsed,
                    incompleteReason: reason
                )
                forcedFlushThrough = laterSequence(forcedFlushThrough, lastAcceptedSequence)
            case let .finishing(existingEndedAt, existingEndedElapsed, existingReason):
                phase = .finishing(
                    endedAt: existingEndedAt,
                    endedElapsed: existingEndedElapsed,
                    incompleteReason: existingReason ?? reason
                )
            case .finalizing, .failing, .cancelling, .terminal:
                break
            }
            return nil
        }
    }

    func requestFailure(
        reason: String,
        completion: FinishCompletion?
    ) -> TelemetryFinishResult? {
        lock.withLock {
            if case let .terminal(completeness) = phase {
                return TelemetryFinishResult(
                    completeness: completeness,
                    lastCommittedRecorderSequence: lastCommittedSequence
                )
            }
            if let completion {
                finishCompletions.append(completion)
            }
            switch phase {
            case .finalizing:
                phase = .failing(reason: reason)
            case .failing, .cancelling:
                phase = .failing(reason: reason)
            case .beginning, .active, .finishing:
                phase = .failing(reason: reason)
            case .terminal:
                break
            }
            terminalIntentGeneration &+= 1
            return nil
        }
    }

    @discardableResult
    func requestCancellation(
        completion: FinishCompletion?
    ) -> TelemetryFinishResult? {
        lock.withLock {
            if case let .terminal(completeness) = phase {
                return TelemetryFinishResult(
                    completeness: completeness,
                    lastCommittedRecorderSequence: lastCommittedSequence
                )
            }
            if let completion {
                finishCompletions.append(completion)
            }
            switch phase {
            case .finalizing:
                phase = .cancelling
            case .beginning, .active, .finishing, .failing, .cancelling:
                phase = .cancelling
            case .terminal:
                break
            }
            terminalIntentGeneration &+= 1
            return nil
        }
    }

    func headerPersisted() {
        lock.withLock {
            headerIsPersisted = true
            if case .beginning = phase {
                phase = .active
            }
        }
    }

    func nextConsumerAction(now: Duration) -> TelemetryRecorderConsumerAction {
        lock.withLock {
            switch phase {
            case .failing, .cancelling:
                return .terminateRequested
            case let .finishing(endedAt, endedElapsed, incompleteReason):
                if !buffer.isEmpty {
                    return .persist(
                        buffer.drain(maximumCount: batchPolicy.maximumRecordCount),
                        intentGeneration: terminalIntentGeneration
                    )
                }
                let completeness: TelemetryRecorderCompleteness = knownLoss
                    ? .incomplete
                    : .complete
                phase = .finalizing(completeness)
                return .finalize(
                    finalization(
                        completeness: completeness,
                        endedAt: endedAt,
                        endedElapsed: endedElapsed,
                        reason: knownLoss ? (incompleteReason ?? "recorder-loss") : nil
                    ),
                    completeness,
                    intentGeneration: terminalIntentGeneration
                )
            case .beginning:
                return .wait
            case .finalizing:
                return .wait
            case .active:
                break
            case .terminal:
                return .wait
            }

            let forced = forcedFlushThrough.map {
                !sequence(lastCommittedSequence, satisfies: $0)
            } ?? false
            if buffer.count >= batchPolicy.maximumRecordCount || forced {
                guard !buffer.isEmpty else {
                    forcedFlushThrough = nil
                    return .wait
                }
                return .persist(
                    buffer.drain(maximumCount: batchPolicy.maximumRecordCount),
                    intentGeneration: terminalIntentGeneration
                )
            }

            guard let oldest = buffer.oldestEnqueueTime else {
                return .wait
            }
            guard armedTimer == nil else {
                return .wait
            }
            let age = max(now - oldest, .zero)
            return .scheduleFlush(max(batchPolicy.maximumInterval - age, .zero))
        }
    }

    func batchCommitted(_ batch: [SequencedTelemetryRecord], duration: Duration) {
        lock.withLock {
            guard let finalSequence = batch.last?.recorderSequence else {
                return
            }
            lastCommittedSequence = finalSequence
            for record in batch {
                guard let elapsed = record.record.persistedElapsed else {
                    continue
                }
                if let existing = lastPersistedElapsed {
                    lastPersistedElapsed = max(existing, elapsed)
                } else {
                    lastPersistedElapsed = elapsed
                }
            }
            increment(&successfulFlushCount)
            mostRecentFlushDuration = duration
            if let target = forcedFlushThrough,
               sequence(lastCommittedSequence, satisfies: target)
            {
                forcedFlushThrough = nil
            }
        }
    }

    func writerAttemptFailed() {
        lock.withLock {
            increment(&writerFailureCount)
        }
    }

    func retryScheduled() {
        lock.withLock {
            increment(&retryCount)
        }
    }

    func persistenceShouldAbort() -> Bool {
        lock.withLock {
            switch phase {
            case .failing, .cancelling, .terminal:
                true
            case .beginning, .active, .finishing, .finalizing:
                false
            }
        }
    }

    func terminalIntentGenerationSnapshot() -> UInt64 {
        lock.withLock { terminalIntentGeneration }
    }

    @discardableResult
    func persistenceBecameTerminalIfIntentUnchanged(
        error: Error,
        uncertainRecords: [SequencedTelemetryRecord],
        expectedGeneration: UInt64
    ) -> UInt64? {
        lock.withLock {
            accountUncertain(uncertainRecords)
            accountDiscarded(buffer.discardAll())
            knownLoss = true
            guard terminalIntentGeneration == expectedGeneration else {
                return nil
            }
            phase = .failing(reason: persistenceFailureReason(error))
            terminalIntentGeneration &+= 1
            return terminalIntentGeneration
        }
    }

    func restoreUncertainBatchForAccounting(_ batch: [SequencedTelemetryRecord]) {
        lock.withLock {
            accountUncertain(batch)
            knownLoss = true
        }
    }

    func prepareRequestedTermination() -> (
        TelemetrySessionFinalization,
        TelemetryRecorderCompleteness,
        UInt64
    ) {
        lock.withLock {
            accountDiscarded(buffer.discardAll())
            switch phase {
            case let .failing(reason):
                return (
                    finalization(
                        completeness: .failed,
                        endedAt: nil,
                        endedElapsed: nil,
                        reason: reason
                    ),
                    .failed,
                    terminalIntentGeneration
                )
            case .cancelling:
                return (
                    finalization(
                        completeness: .cancelled,
                        endedAt: nil,
                        endedElapsed: nil,
                        reason: "recorder-cancelled"
                    ),
                    .cancelled,
                    terminalIntentGeneration
                )
            case .beginning, .active, .finishing, .finalizing, .terminal:
                return (
                    finalization(
                        completeness: .failed,
                        endedAt: nil,
                        endedElapsed: nil,
                        reason: "recorder-terminated"
                    ),
                    .failed,
                    terminalIntentGeneration
                )
            }
        }
    }

    func completeFinalizationIfUnchanged(
        _ intendedCompleteness: TelemetryRecorderCompleteness
    ) -> Bool {
        transitionToTerminal(
            intendedCompleteness,
            expectation: .finalizing(intendedCompleteness)
        )
    }

    func completeRequestedTerminationIfUnchanged(
        _ intendedCompleteness: TelemetryRecorderCompleteness,
        generation: UInt64
    ) -> Bool {
        transitionToTerminal(
            intendedCompleteness,
            expectation: .requested(intendedCompleteness, generation: generation)
        )
    }
    private func transitionToTerminal(
        _ completeness: TelemetryRecorderCompleteness,
        expectation: TerminalTransitionExpectation
    ) -> Bool {
        let flushes: [FlushWaiter]
        let finishes: [FinishCompletion]
        let flushResult: TelemetryFlushResult
        let finishResult: TelemetryFinishResult
        let transition = lock.withLock { () -> (
            [FlushWaiter],
            [FinishCompletion],
            TelemetryFlushResult,
            TelemetryFinishResult
        )? in
            switch expectation {
            case let .finalizing(expectedCompleteness):
                guard case let .finalizing(currentCompleteness) = phase,
                      currentCompleteness == expectedCompleteness
                else {
                    return nil
                }
            case let .requested(expectedCompleteness, expectedGeneration):
                guard terminalIntentGeneration == expectedGeneration else {
                    return nil
                }
                switch (expectedCompleteness, phase) {
                case (.failed, .failing), (.cancelled, .cancelling):
                    break
                case (.complete, _), (.incomplete, _), (.failed, _), (.cancelled, _):
                    return nil
                }
            }
            if case .terminal = phase {
                return nil
            }
            phase = .terminal(completeness)
            let flushes = flushWaiters
            let finishes = finishCompletions
            flushWaiters.removeAll(keepingCapacity: false)
            finishCompletions.removeAll(keepingCapacity: false)
            return (
                flushes,
                finishes,
                TelemetryFlushResult(
                    lastCommittedRecorderSequence: lastCommittedSequence,
                    completeness: completeness
                ),
                TelemetryFinishResult(
                    completeness: completeness,
                    lastCommittedRecorderSequence: lastCommittedSequence
                )
            )
        }
        guard let transition else {
            return false
        }
        (flushes, finishes, flushResult, finishResult) = transition
        for waiter in flushes {
            waiter.completion(flushResult)
        }
        for completion in finishes {
            completion(finishResult)
        }
        return true
    }

    func resumeSatisfiedFlushes() {
        let (waiters, result): ([FlushWaiter], TelemetryFlushResult) = lock.withLock {
            var satisfied: [FlushWaiter] = []
            var remaining: [FlushWaiter] = []
            for waiter in flushWaiters {
                if headerIsPersisted,
                   (waiter.targetSequence == nil
                       || sequence(lastCommittedSequence, satisfies: waiter.targetSequence))
                {
                    satisfied.append(waiter)
                } else {
                    remaining.append(waiter)
                }
            }
            flushWaiters = remaining
            return (
                satisfied,
                TelemetryFlushResult(
                    lastCommittedRecorderSequence: lastCommittedSequence,
                    completeness: currentCompleteness
                )
            )
        }
        for waiter in waiters {
            waiter.completion(result)
        }
    }

    func operationalState() -> TelemetryRecorderOperationalState {
        lock.withLock {
            TelemetryRecorderOperationalState(
                queueDepth: buffer.count,
                peakQueueDepth: peakQueueDepth,
                coalescedFrameCount: coalescedFrameCount,
                droppedFrameCount: droppedFrameCount,
                lostNativeCount: lostNativeCount,
                lostCriticalCount: lostCriticalCount,
                writerFailureCount: writerFailureCount,
                retryCount: retryCount,
                successfulFlushCount: successfulFlushCount,
                lastCommittedRecorderSequence: lastCommittedSequence,
                mostRecentFlushDuration: mostRecentFlushDuration,
                lifecycleState: lifecycleState,
                completeness: currentCompleteness
            )
        }
    }

    func armTimer(purpose: TelemetryRecorderTimerPurpose) -> TelemetryRecorderTimerToken {
        lock.withLock {
            timerGeneration &+= 1
            let token = TelemetryRecorderTimerToken(
                generation: timerGeneration,
                purpose: purpose
            )
            armedTimer = token
            readyRetryTimer = nil
            return token
        }
    }

    func cancelTimer() -> Bool {
        lock.withLock {
            let hadTimer = armedTimer != nil
            if hadTimer {
                timerGeneration &+= 1
            }
            armedTimer = nil
            readyRetryTimer = nil
            return hadTimer
        }
    }

    func timerFired(_ token: TelemetryRecorderTimerToken) {
        let shouldWake = lock.withLock { () -> Bool in
            guard armedTimer == token else {
                return false
            }
            armedTimer = nil
            switch token.purpose {
            case .flush:
                forcedFlushThrough = laterSequence(
                    forcedFlushThrough,
                    lastAcceptedSequence
                )
            case .retry:
                readyRetryTimer = token
            }
            return true
        }
        if shouldWake {
            wake()
        }
    }

    func takeRetryTimerIfReady(token: TelemetryRecorderTimerToken) -> Bool {
        lock.withLock {
            guard readyRetryTimer == token else {
                return false
            }
            readyRetryTimer = nil
            return true
        }
    }
}

private extension TelemetryRecorderCore {
    var currentCompleteness: TelemetryRecorderCompleteness {
        switch phase {
        case let .terminal(completeness):
            completeness
        case .failing:
            .failed
        case .cancelling:
            .cancelled
        case .beginning, .active, .finishing, .finalizing:
            .incomplete
        }
    }

    var lifecycleState: TelemetryRecorderLifecycleState {
        switch phase {
        case .beginning: .beginning
        case .active: .active
        case .finishing, .finalizing: .finishing
        case .failing: .failing
        case .cancelling: .cancelling
        case let .terminal(completeness):
            switch completeness {
            case .complete: .complete
            case .incomplete: .incomplete
            case .failed: .failed
            case .cancelled: .cancelled
            }
        }
    }

    func allocateSequence() -> UInt64? {
        guard let current = nextSequence else {
            return nil
        }
        if current == UInt64.max {
            nextSequence = nil
        } else {
            nextSequence = current + 1
        }
        return current
    }

    func accountLoss(for recordClass: TelemetryRecordClass) {
        knownLoss = true
        switch recordClass {
        case .critical:
            increment(&lostCriticalCount)
        case .native:
            increment(&lostNativeCount)
        case .bulkFrame:
            increment(&droppedFrameCount)
        }
    }

    func accountUncertain(_ records: [SequencedTelemetryRecord]) {
        for record in records {
            accountLoss(for: record.record.recordClass)
        }
    }

    func accountDiscarded(_ discarded: TelemetryDiscardCounts) {
        if discarded.total > 0 {
            knownLoss = true
        }
        add(discarded.critical, to: &lostCriticalCount)
        add(discarded.native, to: &lostNativeCount)
        add(discarded.bulkFrame, to: &droppedFrameCount)
    }

    func finalization(
        completeness: TelemetryRecorderCompleteness,
        endedAt: Date?,
        endedElapsed: ElapsedDuration?,
        reason: String?
    ) -> TelemetrySessionFinalization {
        let lifecycle: SessionLifecycleState = switch completeness {
        case .complete:
            .completed
        case .cancelled:
            .cancelled
        case .incomplete, .failed:
            .incomplete
        }
        return TelemetrySessionFinalization(
            sessionID: sessionHeader.sessionID,
            lifecycleState: lifecycle,
            endedAt: endedAt,
            endedElapsed: endedElapsed,
            incompleteReason: reason,
            recorderHealth: RecorderHealthSummary(
                isComplete: completeness == .complete,
                lostCriticalRecordCount: lostCriticalCount,
                lostNativeRecordCount: lostNativeCount,
                lastPersistedElapsed: lastPersistedElapsed
            )
        )
    }

    func persistenceFailureReason(_ error: Error) -> String {
        switch error as? TelemetryPersistenceOperationError {
        case let .retryableBeforeCommit(code),
             let .terminal(code),
             let .commitOutcomeUnknown(code):
            "persistence-\(code)"
        case nil:
            "persistence-unknown-failure"
        }
    }

    func sequence(_ committed: UInt64?, satisfies target: UInt64?) -> Bool {
        guard let target else {
            return true
        }
        guard let committed else {
            return false
        }
        return committed >= target
    }

    func laterSequence(_ lhs: UInt64?, _ rhs: UInt64?) -> UInt64? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): max(lhs, rhs)
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
    }

    func increment(_ value: inout UInt64) {
        if value < UInt64.max {
            value += 1
        }
    }

    func add(_ amount: Int, to value: inout UInt64) {
        guard amount > 0 else {
            return
        }
        let converted = UInt64(amount)
        let (sum, overflow) = value.addingReportingOverflow(converted)
        value = overflow ? UInt64.max : sum
    }

    func add(_ amount: UInt64, to value: inout UInt64) {
        let (sum, overflow) = value.addingReportingOverflow(amount)
        value = overflow ? UInt64.max : sum
    }
}
