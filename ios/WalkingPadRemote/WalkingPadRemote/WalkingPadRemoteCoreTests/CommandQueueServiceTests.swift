import Foundation
import TelemetryDomain
import XCTest
@testable import WalkingPadCoreLogic

final class CommandQueueServiceTests: XCTestCase {
    func testTelemetrySidecarKeepsOriginalSessionAcrossCancellationAndSameEpochDequeue() {
        let epoch = TreadmillConnectionEpoch(rawValue: UUID())
        let oldSession = SessionID()
        let newSession = SessionID()
        let old = evidence(label: "STOP", epoch: epoch)
        let new = evidence(label: "START", epoch: epoch)
        var sidecar = TreadmillCommandTelemetrySidecar()
        _ = sidecar.enqueueRegular(label: "STOP", evidence: old, sessionID: oldSession, isSpeedLabel: isSpeed)
        let cancelled = sidecar.replaceWithHighPriority(label: "START", evidence: new, sessionID: newSession)
        XCTAssertEqual(cancelled, [.init(evidence: old, sessionID: oldSession)])
        XCTAssertEqual(sidecar.dequeue(expectedLabel: "START", currentEpoch: epoch),
            .matched(.init(evidence: new, sessionID: newSession)))
        _ = sidecar.enqueueRegular(label: "STOP retry", evidence: old, sessionID: oldSession, isSpeedLabel: isSpeed)
        XCTAssertEqual(sidecar.dequeue(expectedLabel: "STOP retry", currentEpoch: epoch),
            .matched(.init(evidence: old, sessionID: oldSession)))
    }

    func testLogicalRequestRetainsOriginalContextAndPublishesBeforeAnySendOnlyOnce() throws {
        let session = SessionID(), epoch = TreadmillConnectionEpoch(rawValue: UUID())
        let at = Date(timeIntervalSince1970: 100)
        let request = TreadmillCommandTelemetrySidecar.Request(sessionID: session,
            commandID: CommandID(), decisionID: DecisionID(), kind: .stop)
        let first = request.prepareEnqueue(protocolKind: .walkingPad, connectionEpoch: epoch, enqueuedAt: at)
        let original = try XCTUnwrap(first.publication)
        XCTAssertEqual(first.queued, original)
        var sidecar = TreadmillCommandTelemetrySidecar()
        _ = sidecar.replaceWithHighPriority(label: "STOP", evidence: original, sessionID: request.sessionID)
        XCTAssertEqual(sidecar.clear().first?.evidence, original) // Cancelled before a send counter exists.
        let retry = request.prepareEnqueue(protocolKind: .ftms,
            connectionEpoch: .init(rawValue: UUID()), enqueuedAt: at.addingTimeInterval(4))
        XCTAssertNil(retry.publication)
        XCTAssertEqual(retry.queued, original)
        XCTAssertEqual(request.sessionID, session)
        _ = sidecar.enqueueRegular(label: "STOP retry", evidence: try XCTUnwrap(retry.queued),
            sessionID: request.sessionID, isSpeedLabel: isSpeed)
        XCTAssertEqual(sidecar.dequeue(expectedLabel: "STOP retry", currentEpoch: epoch),
            .matched(.init(evidence: original, sessionID: session)))
        let duplicate = TreadmillCommandTelemetrySidecar.Request(sessionID: session,
            commandID: request.commandID, decisionID: request.decisionID, kind: .stop)
        XCTAssertNotNil(duplicate.prepareEnqueue(protocolKind: .walkingPad,
            connectionEpoch: epoch, enqueuedAt: at).publication)
    }

    func testUnknownFirstEnqueueCannotAcquireAReplacementConnectionContext() {
        let request = TreadmillCommandTelemetrySidecar.Request(sessionID: nil,
            commandID: CommandID(), decisionID: nil, kind: .stop)
        let first = request.prepareEnqueue(protocolKind: .unknown, connectionEpoch: nil, enqueuedAt: Date())
        XCTAssertNil(first.queued)
        XCTAssertNil(first.publication)
        let retry = request.prepareEnqueue(protocolKind: .walkingPad,
            connectionEpoch: .init(rawValue: UUID()), enqueuedAt: Date())
        XCTAssertNil(retry.queued)
        XCTAssertNil(retry.publication)
        XCTAssertNil(request.sessionID)
    }

    func testRequestMetadataLifetimeEndsWithExplicitRetryCallbacks() throws {
        var sidecar = TreadmillCommandTelemetrySidecar()
        var callback: (() -> Void)?
        weak var retained: TreadmillCommandTelemetrySidecar.Request?
        do {
            let request = TreadmillCommandTelemetrySidecar.Request(sessionID: SessionID(),
                commandID: CommandID(), decisionID: nil, kind: .stop)
            retained = request
            let first = request.prepareEnqueue(protocolKind: .walkingPad,
                connectionEpoch: .init(rawValue: UUID()), enqueuedAt: Date())
            _ = sidecar.enqueueRegular(label: "STOP", evidence: try XCTUnwrap(first.queued),
                sessionID: request.sessionID, isSpeedLabel: isSpeed)
            callback = { _ = request.prepareEnqueue(protocolKind: .unknown, connectionEpoch: nil, enqueuedAt: Date()) }
        }
        XCTAssertNotNil(retained)
        callback?()
        callback = nil
        XCTAssertNil(retained)
        XCTAssertEqual(sidecar.count, 1) // Queue metadata is a value, not a retained request owner.
    }

    private func isSpeed(_ label: String) -> Bool {
        label.lowercased().hasPrefix("speed")
    }

    func testEnqueueRegularCoalescesOlderSpeedCommands() {
        var queue: [CommandQueueService.Command] = [
            .init(data: Data([0x01]), label: "SPEED 3.0"),
            .init(data: Data([0x02]), label: "PING"),
            .init(data: Data([0x03]), label: "SPEED 3.2")
        ]

        let result = CommandQueueService.enqueueRegular(
            queue: &queue,
            command: .init(data: Data([0x04]), label: "SPEED 4.0"),
            isSpeedLabel: isSpeed
        )

        XCTAssertEqual(result.coalescedSpeedCount, 2)
        XCTAssertEqual(queue.map(\.label), ["PING", "SPEED 4.0"])
    }

    func testEnqueueRegularKeepsNonSpeedCommands() {
        var queue: [CommandQueueService.Command] = [
            .init(data: Data([0x01]), label: "PING")
        ]

        let result = CommandQueueService.enqueueRegular(
            queue: &queue,
            command: .init(data: Data([0x02]), label: "STATUS"),
            isSpeedLabel: isSpeed
        )

        XCTAssertEqual(result.coalescedSpeedCount, 0)
        XCTAssertEqual(queue.map(\.label), ["PING", "STATUS"])
    }

    func testReplaceWithHighPriorityDropsPendingCommands() {
        var queue: [CommandQueueService.Command] = [
            .init(data: Data([0x01]), label: "SPEED 3.0"),
            .init(data: Data([0x02]), label: "PING")
        ]

        CommandQueueService.replaceWithHighPriority(
            queue: &queue,
            command: .init(data: Data([0xFF]), label: "STOP")
        )

        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.first?.label, "STOP")
    }

    func testClearReturnsDroppedCount() {
        var queue: [CommandQueueService.Command] = [
            .init(data: Data([0x01]), label: "A"),
            .init(data: Data([0x02]), label: "B"),
            .init(data: Data([0x03]), label: "C")
        ]

        let dropped = CommandQueueService.clear(queue: &queue)
        XCTAssertEqual(dropped, 3)
        XCTAssertTrue(queue.isEmpty)
    }

    func testTelemetrySidecarMirrorsCoalescingWithoutChangingCommandEquality() {
        let epoch = TreadmillConnectionEpoch(rawValue: UUID())
        let sharedBytes = Data([0xF7, 0xA2, 0x01, 0x20])
        let legacyA = CommandQueueService.Command(data: sharedBytes, label: "SPEED 3.2")
        let legacyB = CommandQueueService.Command(data: sharedBytes, label: "SPEED 3.2")
        XCTAssertEqual(legacyA, legacyB)

        var legacyQueue: [CommandQueueService.Command] = []
        var sidecar = TreadmillCommandTelemetrySidecar()
        let first = evidence(label: "SPEED 3.2", epoch: epoch)
        let second = evidence(label: "PING", epoch: epoch)
        let third = evidence(label: "SPEED 4.0", epoch: epoch)

        _ = CommandQueueService.enqueueRegular(
            queue: &legacyQueue,
            command: legacyA,
            isSpeedLabel: isSpeed
        )
        XCTAssertTrue(
            sidecar.enqueueRegular(label: "SPEED 3.2", evidence: first, isSpeedLabel: isSpeed)
                .isEmpty
        )
        _ = CommandQueueService.enqueueRegular(
            queue: &legacyQueue,
            command: .init(data: Data([0x01]), label: "PING"),
            isSpeedLabel: isSpeed
        )
        _ = sidecar.enqueueRegular(label: "PING", evidence: second, isSpeedLabel: isSpeed)
        let result = CommandQueueService.enqueueRegular(
            queue: &legacyQueue,
            command: .init(data: Data([0x02]), label: "SPEED 4.0"),
            isSpeedLabel: isSpeed
        )
        let superseded = sidecar.enqueueRegular(
            label: "SPEED 4.0",
            evidence: third,
            isSpeedLabel: isSpeed
        )

        XCTAssertEqual(result.coalescedSpeedCount, 1)
        XCTAssertEqual(superseded.map(\.evidence.commandID), [first.commandID])
        XCTAssertEqual(legacyQueue.map(\.label), ["PING", "SPEED 4.0"])
        XCTAssertEqual(sidecar.count, legacyQueue.count)
        XCTAssertEqual(sidecar.dequeue(expectedLabel: "PING", currentEpoch: epoch), .matched(.init(evidence: second, sessionID: nil)))
        XCTAssertEqual(
            sidecar.dequeue(expectedLabel: "SPEED 4.0", currentEpoch: epoch),
            .matched(.init(evidence: third, sessionID: nil))
        )
    }

    func testTelemetrySidecarFailsCorrelationClosedAcrossEpochOrOrderMismatch() {
        let oldEpoch = TreadmillConnectionEpoch(rawValue: UUID())
        let newEpoch = TreadmillConnectionEpoch(rawValue: UUID())
        let first = evidence(label: "PING", epoch: oldEpoch)
        var sidecar = TreadmillCommandTelemetrySidecar()
        _ = sidecar.enqueueRegular(label: "PING", evidence: first, isSpeedLabel: isSpeed)

        XCTAssertEqual(
            sidecar.dequeue(expectedLabel: "PING", currentEpoch: newEpoch),
            .staleEpoch(.init(evidence: first, sessionID: nil))
        )

        let second = evidence(label: "STATUS", epoch: newEpoch)
        _ = sidecar.enqueueRegular(label: "STATUS", evidence: second, isSpeedLabel: isSpeed)
        XCTAssertEqual(
            sidecar.dequeue(expectedLabel: "DIFFERENT", currentEpoch: newEpoch),
            .correlationLost([.init(evidence: second, sessionID: nil)])
        )
        XCTAssertEqual(sidecar.count, 0)
    }

    func testReadOnlyQueriesYieldWithoutChangingMotionBytesOrderOrSessionOwnership() {
        let epoch = TreadmillConnectionEpoch(rawValue: UUID())
        let session = SessionID()
        let labels = ["QUERY STATUS", "SPEED 4.0", "QUERY PARAMS", "START", "QUERY STATUS extra", "STOP retry"]
        var queue: [CommandQueueService.Command] = []
        var sidecar = TreadmillCommandTelemetrySidecar()
        for (index, label) in labels.enumerated() {
            queue.append(.init(data: Data([UInt8(index)]), label: label))
            _ = sidecar.enqueueRegular(label: label, evidence: evidence(label: label, epoch: epoch),
                sessionID: session, isSpeedLabel: isSpeed)
        }
        let originalMotion = queue.filter { !CommandQueueService.isReadOnlyQueryLabel($0.label) }
        let discarded = CommandQueueService.discardReadOnlyQueries(queue: &queue, motionWindowIsProtected: false)
        let cancelled = sidecar.removeQueued(where: CommandQueueService.isReadOnlyQueryLabel)
        XCTAssertEqual(discarded.map(\.label), ["QUERY STATUS", "QUERY PARAMS"])
        XCTAssertEqual(queue, originalMotion)
        XCTAssertEqual(cancelled.count, 2)
        XCTAssertTrue(cancelled.allSatisfy { $0.sessionID == session })
        for command in queue {
            guard case let .matched(entry) = sidecar.dequeue(expectedLabel: command.label, currentEpoch: epoch) else {
                XCTFail("Correlation lost after read-only preemption"); return
            }
            XCTAssertEqual(entry.sessionID, session)
        }
    }

    func testLateReadOnlyCallbackYieldsAtProtectedWindowButIdleQueryIsRetained() {
        for protected in [false, true] {
            let query = CommandQueueService.Command(data: Data([0xA2]), label: "QUERY STATUS")
            var queue = [query]
            let discarded = CommandQueueService.discardReadOnlyQueries(queue: &queue, motionWindowIsProtected: protected)
            XCTAssertEqual(discarded, protected ? [query] : [])
            XCTAssertEqual(queue, protected ? [] : [query])
        }
    }

    func testQueriesAdmittedWhileWaitingForHeartRateYieldToSpeedAndStop() {
        let query = CommandQueueService.Command(data: Data([0xA2]), label: "QUERY STATUS")
        let units = CommandQueueService.Command(data: Data([0xA7]), label: "QUERY PARAMS")
        let speed = CommandQueueService.Command(data: Data([0x01]), label: "SPEED 4.0")
        let stop = CommandQueueService.Command(data: Data([0xFF]), label: "STOP")
        var queue = [query, units]
        XCTAssertTrue(CommandQueueService.discardReadOnlyQueries(queue: &queue,
            motionWindowIsProtected: false).isEmpty)
        _ = CommandQueueService.enqueueRegular(queue: &queue, command: speed, isSpeedLabel: isSpeed)
        XCTAssertEqual(CommandQueueService.discardReadOnlyQueries(queue: &queue,
            motionWindowIsProtected: false), [query, units])
        XCTAssertEqual(queue, [speed])
        _ = CommandQueueService.enqueueRegular(queue: &queue, command: query, isSpeedLabel: isSpeed)
        CommandQueueService.replaceWithHighPriority(queue: &queue, command: stop)
        XCTAssertEqual(queue, [stop])
    }

    private func evidence(
        label: String,
        epoch: TreadmillConnectionEpoch
    ) -> TreadmillCommandEnqueuedEvidence {
        TreadmillCommandEnqueuedEvidence(
            commandID: CommandID(),
            decisionID: nil,
            kind: .other(label),
            protocolKind: .walkingPad,
            connectionEpoch: epoch,
            enqueuedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
