import Dispatch
import Foundation
import TelemetryDomain
@testable import TelemetryRecorder
import XCTest

final class TelemetryRecorderBehaviorTests: XCTestCase {
    func testSessionHeaderPersistsAsynchronouslyWithoutCallerAwait() async {
        let persistence = InMemoryTelemetryRecorderPersistence()
        let scheduler = ManualTelemetryRecorderScheduler()
        let session = TelemetryRecorderFixtures.session()
        let recorder = TelemetryRecorder(
            sessionHeader: session,
            persistence: persistence,
            scheduler: scheduler
        )

        await persistence.waitForHeaders(1)
        let snapshot = await persistence.snapshot()
        XCTAssertEqual(snapshot.headers, [session])
        XCTAssertEqual(snapshot.batches.count, 0)
        _ = await recorder.cancel()
    }

    func testTerminalHeaderFailurePreventsBodyPersistenceAndMarksLoss() async {
        let persistence = InMemoryTelemetryRecorderPersistence(beginBehaviors: [.terminal])
        let scheduler = ManualTelemetryRecorderScheduler()
        let session = TelemetryRecorderFixtures.session()
        let recorder = TelemetryRecorder(
            sessionHeader: session,
            persistence: persistence,
            scheduler: scheduler
        )

        _ = recorder.ingress.yield(
            TelemetryRecorderFixtures.event(sessionID: session.sessionID, order: 1)
        )
        let result = await recorder.finish(
            endedAt: TelemetryRecorderFixtures.baseDate,
            endedElapsed: .zero
        )

        let snapshot = await persistence.snapshot()
        XCTAssertEqual(snapshot.beginCalls, 1)
        XCTAssertEqual(snapshot.batchCalls, 0)
        XCTAssertTrue(snapshot.batches.isEmpty)
        XCTAssertEqual(result.completeness, .failed)
        XCTAssertEqual(recorder.operationalState.lostCriticalCount, 1)
    }

    func testConcurrentProducersReceiveUniqueMonotonicSequencesAndPersistInOrder() async throws {
        let persistence = InMemoryTelemetryRecorderPersistence()
        let scheduler = ManualTelemetryRecorderScheduler()
        let session = TelemetryRecorderFixtures.session()
        let source = TelemetryRecorderFixtures.source()
        let recorder = TelemetryRecorder(
            sessionHeader: session,
            persistence: persistence,
            bufferPolicy: try XCTUnwrap(
                TelemetryBufferPolicy(
                    capacity: 2_000,
                    reservedCriticalCapacity: 100,
                    reservedNativeCapacity: 900
                )
            ),
            batchPolicy: try XCTUnwrap(
                TelemetryBatchPolicy(maximumRecordCount: 2_000, maximumInterval: .seconds(5))
            ),
            scheduler: scheduler
        )
        let receiptsLock = NSLock()
        var receipts: [TelemetryYieldReceipt] = []

        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            let receipt = recorder.ingress.yield(
                TelemetryRecorderFixtures.heartRate(
                    sessionID: session.sessionID,
                    source: source,
                    order: UInt64(index),
                    bpm: UInt16(100 + index % 40)
                )
            )
            receiptsLock.withLock {
                receipts.append(receipt)
            }
        }
        let result = await recorder.finish(
            endedAt: TelemetryRecorderFixtures.baseDate.addingTimeInterval(10),
            endedElapsed: ElapsedDuration(microseconds: 10_000_000)
        )

        let assigned = receipts.compactMap(\.recorderSequence).sorted()
        XCTAssertEqual(assigned, Array(1...1_000).map(UInt64.init))
        XCTAssertEqual(Set(assigned).count, 1_000)
        let persisted = await persistence.snapshot().batches.flatMap { $0 }
        XCTAssertEqual(persisted.map(\.recorderSequence), assigned)
        XCTAssertEqual(result.completeness, .complete)
    }

    func testCountTriggeredFlushPreservesProviderFields() async throws {
        let persistence = InMemoryTelemetryRecorderPersistence()
        let scheduler = ManualTelemetryRecorderScheduler()
        let session = TelemetryRecorderFixtures.session()
        let source = TelemetryRecorderFixtures.source()
        let recorder = TelemetryRecorder(
            sessionHeader: session,
            persistence: persistence,
            batchPolicy: try XCTUnwrap(
                TelemetryBatchPolicy(maximumRecordCount: 2, maximumInterval: .seconds(5))
            ),
            scheduler: scheduler
        )
        let first = TelemetryRecorderFixtures.heartRate(
            sessionID: session.sessionID,
            source: source,
            order: 9,
            bpm: 123
        )
        let second = TelemetryRecorderFixtures.treadmill(
            sessionID: session.sessionID,
            source: source,
            order: 4
        )

        _ = recorder.ingress.yield(first)
        _ = recorder.ingress.yield(second)
        await persistence.waitForBatches(1)

        let persistedSnapshot = await persistence.snapshot()
        let batch = try XCTUnwrap(persistedSnapshot.batches.first)
        XCTAssertEqual(batch.map(\.record), [first, second])
        XCTAssertEqual(batch.map(\.recorderSequence), [1, 2])
        _ = await recorder.cancel()
    }

    func testTimeTriggeredFlushUsesManualClockWithoutWallSleep() async throws {
        let persistence = InMemoryTelemetryRecorderPersistence()
        let scheduler = ManualTelemetryRecorderScheduler()
        let session = TelemetryRecorderFixtures.session()
        let recorder = TelemetryRecorder(
            sessionHeader: session,
            persistence: persistence,
            batchPolicy: try XCTUnwrap(
                TelemetryBatchPolicy(maximumRecordCount: 10, maximumInterval: .seconds(5))
            ),
            scheduler: scheduler
        )

        _ = recorder.ingress.yield(TelemetryRecorderFixtures.event(sessionID: session.sessionID, order: 1))
        await scheduler.waitUntilScheduled()
        scheduler.advance(by: .seconds(4))
        let beforeDeadline = await persistence.snapshot()
        XCTAssertTrue(beforeDeadline.batches.isEmpty)
        scheduler.advance(by: .seconds(1))
        await persistence.waitForBatches(1)

        let afterDeadline = await persistence.snapshot()
        XCTAssertEqual(afterDeadline.batches.first?.count, 1)
        _ = await recorder.cancel()
    }

    func testLifecycleFlushAndFinishDrainQueuedEvidence() async throws {
        let persistence = InMemoryTelemetryRecorderPersistence()
        let scheduler = ManualTelemetryRecorderScheduler()
        let session = TelemetryRecorderFixtures.session()
        let recorder = TelemetryRecorder(
            sessionHeader: session,
            persistence: persistence,
            batchPolicy: try XCTUnwrap(
                TelemetryBatchPolicy(maximumRecordCount: 10, maximumInterval: .seconds(5))
            ),
            scheduler: scheduler
        )

        _ = recorder.ingress.yield(TelemetryRecorderFixtures.event(sessionID: session.sessionID, order: 1))
        let flush = await recorder.flush(reason: .applicationBackground)
        XCTAssertEqual(flush.lastCommittedRecorderSequence, 1)
        _ = recorder.ingress.yield(TelemetryRecorderFixtures.event(sessionID: session.sessionID, order: 2))
        let finish = await recorder.finish(
            endedAt: TelemetryRecorderFixtures.baseDate.addingTimeInterval(2),
            endedElapsed: ElapsedDuration(microseconds: 2_000_000)
        )

        let snapshot = await persistence.snapshot()
        XCTAssertEqual(snapshot.batches.flatMap { $0 }.map(\.recorderSequence), [1, 2])
        XCTAssertEqual(snapshot.finalizations.last?.lifecycleState, .completed)
        XCTAssertEqual(finish.completeness, .complete)
        XCTAssertEqual(recorder.operationalState.successfulFlushCount, 2)
    }

    func testRetryablePrecommitFailureRetriesOnceAfterInjectedDelay() async throws {
        let persistence = InMemoryTelemetryRecorderPersistence(
            batchBehaviors: [.retryableBeforeCommit, .success]
        )
        let scheduler = ManualTelemetryRecorderScheduler()
        let session = TelemetryRecorderFixtures.session()
        let recorder = TelemetryRecorder(
            sessionHeader: session,
            persistence: persistence,
            batchPolicy: try XCTUnwrap(
                TelemetryBatchPolicy(maximumRecordCount: 1, maximumInterval: .seconds(5))
            ),
            retryPolicy: try XCTUnwrap(
                TelemetryRetryPolicy(maximumPrecommitRetries: 1, delay: .milliseconds(250))
            ),
            scheduler: scheduler
        )

        _ = recorder.ingress.yield(TelemetryRecorderFixtures.event(sessionID: session.sessionID, order: 1))
        await persistence.waitForBatchCalls(1)
        await scheduler.waitUntilScheduled()
        scheduler.advance(by: .milliseconds(250))
        await persistence.waitForBatches(1)
        let finish = await recorder.finish(
            endedAt: TelemetryRecorderFixtures.baseDate,
            endedElapsed: .zero
        )

        let snapshot = await persistence.snapshot()
        XCTAssertEqual(snapshot.batchCalls, 2)
        XCTAssertEqual(recorder.operationalState.retryCount, 1)
        XCTAssertEqual(recorder.operationalState.writerFailureCount, 1)
        XCTAssertEqual(finish.completeness, .complete)
    }

    func testRetryExhaustionBecomesFailedAndIncomplete() async throws {
        let persistence = InMemoryTelemetryRecorderPersistence(
            batchBehaviors: [.retryableBeforeCommit, .retryableBeforeCommit]
        )
        let scheduler = ManualTelemetryRecorderScheduler()
        let session = TelemetryRecorderFixtures.session()
        let recorder = TelemetryRecorder(
            sessionHeader: session,
            persistence: persistence,
            batchPolicy: try XCTUnwrap(
                TelemetryBatchPolicy(maximumRecordCount: 1, maximumInterval: .seconds(5))
            ),
            retryPolicy: try XCTUnwrap(
                TelemetryRetryPolicy(maximumPrecommitRetries: 1, delay: .milliseconds(1))
            ),
            scheduler: scheduler
        )

        _ = recorder.ingress.yield(TelemetryRecorderFixtures.event(sessionID: session.sessionID, order: 1))
        await persistence.waitForBatchCalls(1)
        await scheduler.waitUntilScheduled()
        scheduler.advance(by: .milliseconds(1))
        await persistence.waitForFinalizations(1)
        let result = await recorder.finish(
            endedAt: TelemetryRecorderFixtures.baseDate,
            endedElapsed: .zero
        )

        let snapshot = await persistence.snapshot()
        XCTAssertEqual(snapshot.batchCalls, 2)
        XCTAssertEqual(snapshot.finalizations.last?.lifecycleState, .incomplete)
        XCTAssertEqual(result.completeness, .failed)
        XCTAssertEqual(recorder.operationalState.lostCriticalCount, 1)
    }

    func testExplicitFailureAccountsQueuedTailWithoutPersistingIt() async {
        let persistence = InMemoryTelemetryRecorderPersistence()
        let scheduler = ManualTelemetryRecorderScheduler()
        let session = TelemetryRecorderFixtures.session()
        let recorder = TelemetryRecorder(
            sessionHeader: session,
            persistence: persistence,
            scheduler: scheduler
        )
        await persistence.waitForHeaders(1)

        _ = recorder.ingress.yield(
            TelemetryRecorderFixtures.event(sessionID: session.sessionID, order: 1)
        )
        let result = await recorder.fail(reason: "test-explicit-failure")

        let snapshot = await persistence.snapshot()
        XCTAssertTrue(snapshot.batches.isEmpty)
        XCTAssertEqual(snapshot.finalizations.last?.lifecycleState, .incomplete)
        XCTAssertEqual(snapshot.finalizations.last?.incompleteReason, "test-explicit-failure")
        XCTAssertEqual(result.completeness, .failed)
        XCTAssertEqual(recorder.operationalState.lostCriticalCount, 1)
    }

    func testAmbiguousCommitOutcomeIsNeverRetried() async throws {
        let persistence = InMemoryTelemetryRecorderPersistence(
            batchBehaviors: [.ambiguousAfterCommit, .success]
        )
        let scheduler = ManualTelemetryRecorderScheduler()
        let session = TelemetryRecorderFixtures.session()
        let recorder = TelemetryRecorder(
            sessionHeader: session,
            persistence: persistence,
            batchPolicy: try XCTUnwrap(
                TelemetryBatchPolicy(maximumRecordCount: 1, maximumInterval: .seconds(5))
            ),
            retryPolicy: try XCTUnwrap(
                TelemetryRetryPolicy(maximumPrecommitRetries: 3, delay: .milliseconds(1))
            ),
            scheduler: scheduler
        )

        _ = recorder.ingress.yield(TelemetryRecorderFixtures.event(sessionID: session.sessionID, order: 1))
        await persistence.waitForBatches(1)
        await persistence.waitForFinalizations(1)

        let snapshot = await persistence.snapshot()
        XCTAssertEqual(snapshot.batchCalls, 1)
        XCTAssertEqual(recorder.operationalState.retryCount, 0)
        XCTAssertEqual(recorder.operationalState.lifecycleState, .failed)
    }

    func testCancellationAccountsTailAndASecondRecorderCanRestartDeterministically() async throws {
        let persistence = InMemoryTelemetryRecorderPersistence()
        let scheduler = ManualTelemetryRecorderScheduler()
        let firstSession = TelemetryRecorderFixtures.session()
        let first = TelemetryRecorder(
            sessionHeader: firstSession,
            persistence: persistence,
            batchPolicy: try XCTUnwrap(
                TelemetryBatchPolicy(maximumRecordCount: 10, maximumInterval: .seconds(5))
            ),
            scheduler: scheduler
        )
        await persistence.waitForHeaders(1)
        _ = first.ingress.yield(TelemetryRecorderFixtures.event(sessionID: firstSession.sessionID, order: 1))
        let cancelled = await first.cancel()

        XCTAssertEqual(cancelled.completeness, .cancelled)
        let cancelledSnapshot = await persistence.snapshot()
        XCTAssertEqual(cancelledSnapshot.finalizations.last?.lifecycleState, .cancelled)
        XCTAssertEqual(first.operationalState.lostCriticalCount, 1)
        XCTAssertEqual(
            first.ingress.yield(TelemetryRecorderFixtures.event(sessionID: firstSession.sessionID, order: 2))
                .disposition,
            .rejectedTerminal
        )

        let secondSession = TelemetryRecorderFixtures.session()
        let second = TelemetryRecorder(
            sessionHeader: secondSession,
            persistence: persistence,
            batchPolicy: try XCTUnwrap(
                TelemetryBatchPolicy(maximumRecordCount: 1, maximumInterval: .seconds(5))
            ),
            scheduler: ManualTelemetryRecorderScheduler()
        )
        _ = second.ingress.yield(TelemetryRecorderFixtures.event(sessionID: secondSession.sessionID, order: 1))
        let finished = await second.finish(
            endedAt: TelemetryRecorderFixtures.baseDate,
            endedElapsed: .zero
        )
        XCTAssertEqual(finished.completeness, .complete)
        XCTAssertEqual(finished.lastCommittedRecorderSequence, 1)
    }

    func testAmbiguousCompletionFinalizationDowngradesStoredStateToIncomplete() async {
        let persistence = InMemoryTelemetryRecorderPersistence(
            finalizeBehaviors: [.ambiguousAfterCommit, .success]
        )
        let scheduler = ManualTelemetryRecorderScheduler()
        let session = TelemetryRecorderFixtures.session()
        let recorder = TelemetryRecorder(
            sessionHeader: session,
            persistence: persistence,
            scheduler: scheduler
        )
        await persistence.waitForHeaders(1)

        let result = await recorder.finish(
            endedAt: TelemetryRecorderFixtures.baseDate,
            endedElapsed: .zero
        )

        let snapshot = await persistence.snapshot()
        XCTAssertEqual(snapshot.finalizeCalls, 2)
        XCTAssertEqual(snapshot.finalizations.map(\.lifecycleState), [.completed, .incomplete])
        XCTAssertEqual(
            snapshot.finalizations.last?.incompleteReason,
            "recorder-persistence-failure"
        )
        XCTAssertEqual(result.completeness, .failed)
        XCTAssertEqual(recorder.operationalState.writerFailureCount, 1)
    }

    func testUnfinishedSessionRecoveryMarksIncompleteWithoutFabricatedCompletion() async throws {
        let unfinished = TelemetryRecorderFixtures.session()
        let persistence = InMemoryTelemetryRecorderPersistence(unfinished: [unfinished])

        let discovered = try await TelemetryRecorder.recoverUnfinishedSessions(
            using: persistence
        )

        let recoverySnapshot = await persistence.snapshot()
        let finalization = try XCTUnwrap(recoverySnapshot.finalizations.last)
        XCTAssertEqual(discovered, [unfinished])
        XCTAssertEqual(finalization.lifecycleState, .incomplete)
        XCTAssertNil(finalization.endedAt)
        XCTAssertNil(finalization.endedElapsed)
        XCTAssertFalse(finalization.recorderHealth.isComplete)
    }

    func testHighVolumeConcurrentStreamStaysBoundedAndUsesOneTimer() async throws {
        let persistence = InMemoryTelemetryRecorderPersistence()
        let scheduler = ManualTelemetryRecorderScheduler()
        let session = TelemetryRecorderFixtures.session()
        let source = TelemetryRecorderFixtures.source()
        let capacity = 256
        let recorder = TelemetryRecorder(
            sessionHeader: session,
            persistence: persistence,
            bufferPolicy: try XCTUnwrap(
                TelemetryBufferPolicy(
                    capacity: capacity,
                    reservedCriticalCapacity: 32,
                    reservedNativeCapacity: 64
                )
            ),
            batchPolicy: try XCTUnwrap(
                TelemetryBatchPolicy(maximumRecordCount: 64, maximumInterval: .seconds(5))
            ),
            scheduler: scheduler
        )

        DispatchQueue.concurrentPerform(iterations: 10_000) { index in
            if index.isMultiple(of: 10) {
                _ = recorder.ingress.yield(
                    TelemetryRecorderFixtures.event(
                        sessionID: session.sessionID,
                        order: UInt64(index)
                    )
                )
            } else if index.isMultiple(of: 3) {
                _ = recorder.ingress.yield(
                    TelemetryRecorderFixtures.frame(
                        sessionID: session.sessionID,
                        second: Int64(index % 500)
                    )
                )
            } else {
                _ = recorder.ingress.yield(
                    TelemetryRecorderFixtures.heartRate(
                        sessionID: session.sessionID,
                        source: source,
                        order: UInt64(index),
                        bpm: UInt16(90 + index % 80)
                    )
                )
            }
        }
        let finish = await recorder.finish(
            endedAt: TelemetryRecorderFixtures.baseDate.addingTimeInterval(100),
            endedElapsed: ElapsedDuration(microseconds: 100_000_000)
        )

        let state = recorder.operationalState
        let persisted = await persistence.snapshot().batches.flatMap { $0 }
        XCTAssertLessThanOrEqual(state.peakQueueDepth, capacity)
        XCTAssertEqual(persisted.map(\.recorderSequence), persisted.map(\.recorderSequence).sorted())
        XCTAssertEqual(Set(persisted.map(\.recorderSequence)).count, persisted.count)
        XCTAssertLessThanOrEqual(scheduler.maximumOutstandingOperationCount, 1)
        XCTAssertGreaterThan(state.successfulFlushCount, 0)
        XCTAssertTrue(finish.completeness == .complete || finish.completeness == .incomplete)
    }

    func testOperationalCountersExposeOnlyPrivacySafeStateFields() {
        let state = TelemetryRecorderOperationalState(
            queueDepth: 1,
            peakQueueDepth: 2,
            coalescedFrameCount: 3,
            droppedFrameCount: 4,
            lostNativeCount: 5,
            lostCriticalCount: 6,
            writerFailureCount: 7,
            retryCount: 8,
            successfulFlushCount: 9,
            lastCommittedRecorderSequence: 10,
            mostRecentFlushDuration: .milliseconds(11),
            lifecycleState: .active,
            completeness: .incomplete
        )

        let labels = Set(Mirror(reflecting: state).children.compactMap(\.label))
        XCTAssertEqual(
            labels,
            [
                "queueDepth", "peakQueueDepth", "coalescedFrameCount",
                "droppedFrameCount", "lostNativeCount", "lostCriticalCount",
                "writerFailureCount", "retryCount", "successfulFlushCount",
                "lastCommittedRecorderSequence", "mostRecentFlushDuration",
                "lifecycleState", "completeness",
            ]
        )
        XCTAssertFalse(labels.contains("beatsPerMinute"))
        XCTAssertFalse(labels.contains("sourceID"))
        XCTAssertFalse(labels.contains("rawPayload"))
    }
}
