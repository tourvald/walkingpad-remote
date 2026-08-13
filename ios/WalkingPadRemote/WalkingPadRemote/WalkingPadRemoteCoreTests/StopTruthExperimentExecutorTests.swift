import Foundation
import XCTest
@testable import WalkingPadCoreLogic

final class StopTruthExperimentExecutorTests: XCTestCase {
    func testWrongRoleOrderFailsBeforeTransportInvocation() {
        let harness = makeHarness(roles: [.queryParams, .modeManual])
        let result = harness.executor.enqueue(role: .modeManual, token: harness.run.token)
        XCTAssertEqual(result, .rejected(reason: "whitelist_order_or_packet_mismatch"))
        XCTAssertEqual(harness.transport.invocations.count, 0)
        XCTAssertEqual(harness.executor.snapshot(), .failed(harness.run, reason: "whitelist_order_or_packet_mismatch"))
    }

    func testAbortBeforeInvocationProducesZeroInvocationAndRejectsEnqueue() {
        let harness = makeHarness(roles: [.queryParams])
        harness.executor.abort(token: harness.run.token)
        XCTAssertEqual(harness.executor.enqueue(role: .queryParams, token: harness.run.token), .rejected(reason: "inactive_or_aborted"))
        XCTAssertEqual(harness.transport.invocations.count, 0)
        XCTAssertEqual(harness.executor.snapshot(), .aborted(harness.run))
    }

    func testInvocationLinearizedBeforeAbortIsOnlyOverlappingInvocation() {
        let harness = makeHarness(roles: [.queryParams, .modeManual])
        guard case .accepted = harness.executor.enqueue(role: .queryParams, token: harness.run.token) else {
            return XCTFail("query should be accepted")
        }
        XCTAssertEqual(harness.transport.invocations.count, 1)
        harness.executor.abort(token: harness.run.token)
        XCTAssertEqual(harness.executor.snapshot(), .abortPending(harness.run, writeID: harness.transport.invocations[0].writeID))
        harness.transport.completeFirst(.success(.init(characteristicUUID: "FE02", writeType: "without_response")))
        XCTAssertEqual(harness.executor.snapshot(), .aborted(harness.run))
        XCTAssertEqual(harness.executor.enqueue(role: .modeManual, token: harness.run.token), .rejected(reason: "inactive_or_aborted"))
        XCTAssertEqual(harness.transport.invocations.count, 1)
        XCTAssertTrue(harness.sink.records.contains(where: {
            $0.event == .transportResult && $0.fields["overlapped_abort_barrier"] == "true"
        }))
    }

    func testAbortInvalidatesDelayedActionsAndNoCallbackBypassesExecutor() {
        let scheduler = FakeScheduler()
        let harness = makeHarness(
            roles: [.productionStopRecovery, .conditionalStopRetry],
            scheduler: scheduler
        )
        XCTAssertNotNil(harness.executor.schedule(
            role: .productionStopRecovery, token: harness.run.token, after: 2.0
        ))
        XCTAssertNotNil(harness.executor.schedule(
            role: .conditionalStopRetry, token: harness.run.token, after: 4.0
        ))
        harness.executor.abort(token: harness.run.token)
        scheduler.fireAll()
        XCTAssertEqual(harness.transport.invocations.count, 0)
        XCTAssertEqual(harness.executor.snapshot(), .aborted(harness.run))
    }

    func testAbortIsStickyAndFinishRequiresExactCount() {
        let harness = makeHarness(roles: [.queryParams])
        XCTAssertFalse(harness.executor.finish(token: harness.run.token))
        _ = harness.executor.enqueue(role: .queryParams, token: harness.run.token)
        harness.transport.completeFirst(.success(.init(characteristicUUID: "FE02", writeType: "without_response")))
        XCTAssertTrue(harness.executor.finish(token: harness.run.token))
        harness.executor.abort(token: harness.run.token)
        XCTAssertEqual(harness.executor.snapshot(), .completed(harness.run))
    }

    func testEvidenceContainsWriteAndBarrierOrdering() {
        let harness = makeHarness(roles: [.initialStop])
        _ = harness.executor.enqueue(role: .initialStop, token: harness.run.token)
        harness.executor.abort(token: harness.run.token, note: "operator")
        harness.transport.completeFirst(.failure(TestError.failed))
        let invoke = harness.sink.records.first(where: { $0.event == .transportInvoked })
        let barrier = harness.sink.records.first(where: { $0.event == .abortBarrier })
        XCTAssertEqual(invoke?.fields["invocation_sequence"], "1")
        XCTAssertEqual(barrier?.fields["abort_barrier_sequence"], "2")
        XCTAssertEqual(barrier?.fields["operator_recovery"], "physical_power_cutoff_after_motion_capable_write")
    }

    private func makeHarness(
        roles: [BLETransportCodec.StopTruthExperimentCommandRole],
        scheduler: FakeScheduler? = nil
    ) -> Harness {
        let transport = FakeTransport()
        let sink = StopTruthExperimentMemoryEvidenceSink()
        var uptime: UInt64 = 1_000
        let clock = StopTruthExperimentClock(uptimeProvider: { uptime += 1; return uptime }, wallProvider: Date.init)
        let executor = StopTruthExperimentExecutor(
            transport: transport,
            clock: clock,
            evidenceSink: sink,
            scheduleHandler: scheduler.map { scheduler in
                { delay, item in scheduler.schedule(delay: delay, item: item) }
            }
        )
        let run = StopTruthExperimentExecutor.Run(token: UUID(), experimentID: UUID(), repetition: 1, expectedRoles: roles)
        XCTAssertTrue(executor.start(run: run))
        return Harness(executor: executor, transport: transport, sink: sink, run: run)
    }
}

private struct Harness {
    let executor: StopTruthExperimentExecutor
    let transport: FakeTransport
    let sink: StopTruthExperimentMemoryEvidenceSink
    let run: StopTruthExperimentExecutor.Run
}

private final class FakeTransport: StopTruthExperimentTransport {
    struct Invocation {
        let packet: Data
        let role: BLETransportCodec.StopTruthExperimentCommandRole
        let writeID: UUID
        let completion: (Result<StopTruthExperimentTransportReceipt, Error>) -> Void
    }
    private(set) var invocations: [Invocation] = []

    func invoke(
        packet: Data,
        role: BLETransportCodec.StopTruthExperimentCommandRole,
        writeID: UUID,
        completion: @escaping (Result<StopTruthExperimentTransportReceipt, Error>) -> Void
    ) {
        invocations.append(.init(packet: packet, role: role, writeID: writeID, completion: completion))
    }

    func completeFirst(_ result: Result<StopTruthExperimentTransportReceipt, Error>) {
        invocations.first?.completion(result)
    }
}

private enum TestError: Error { case failed }

private final class FakeScheduler {
    private(set) var items: [(delay: TimeInterval, item: DispatchWorkItem)] = []
    func schedule(delay: TimeInterval, item: DispatchWorkItem) {
        items.append((delay, item))
    }
    func fireAll() {
        let pending = items
        items.removeAll()
        pending.forEach { $0.item.perform() }
    }
}
