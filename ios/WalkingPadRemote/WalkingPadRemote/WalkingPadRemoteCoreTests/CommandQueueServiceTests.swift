import Foundation
import TelemetryDomain
import XCTest
@testable import WalkingPadCoreLogic

final class CommandQueueServiceTests: XCTestCase {
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
        XCTAssertEqual(superseded.map(\.commandID), [first.commandID])
        XCTAssertEqual(legacyQueue.map(\.label), ["PING", "SPEED 4.0"])
        XCTAssertEqual(sidecar.count, legacyQueue.count)
        XCTAssertEqual(sidecar.dequeue(expectedLabel: "PING", currentEpoch: epoch), .matched(second))
        XCTAssertEqual(
            sidecar.dequeue(expectedLabel: "SPEED 4.0", currentEpoch: epoch),
            .matched(third)
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
            .staleEpoch(first)
        )

        let second = evidence(label: "STATUS", epoch: newEpoch)
        _ = sidecar.enqueueRegular(label: "STATUS", evidence: second, isSpeedLabel: isSpeed)
        XCTAssertEqual(
            sidecar.dequeue(expectedLabel: "DIFFERENT", currentEpoch: newEpoch),
            .correlationLost([second])
        )
        XCTAssertEqual(sidecar.count, 0)
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
