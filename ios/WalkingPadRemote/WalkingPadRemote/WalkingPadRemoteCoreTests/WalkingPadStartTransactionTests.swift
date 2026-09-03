import Foundation
import TelemetryDomain
import XCTest
@testable import WalkingPadCoreLogic

final class WalkingPadStartTransactionTests: XCTestCase {
    private lazy var bluetoothManagerSource: String = {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try! String(
            contentsOf: directory.deletingLastPathComponent()
                .appendingPathComponent("WalkingPadRemote/BluetoothManager.swift"),
            encoding: .utf8
        )
    }()

    func testAcceptedStartComposesFullSequenceWithoutAnyObservationPrerequisite() {
        XCTAssertEqual(WalkingPadStartTransaction.commands(
            shouldSendStart: true, targetSpeedKmh: 3.0
        ), [
            .init(command: .modeManual, delay: 0),
            .init(command: .start, delay: 0.2),
            .init(command: .speed(3.0), delay: 0.45),
        ])
    }

    func testAlreadyMovingAdjustmentIsSpeedOnlyAtOriginalDelay() {
        XCTAssertEqual(WalkingPadStartTransaction.commands(
            shouldSendStart: false, targetSpeedKmh: 3.8
        ), [.init(command: .speed(3.8), delay: 0.2)])
    }

    func testOrdinaryStopThenSecondWorkoutOnSameConnectionResendsMode() {
        let epoch = TreadmillConnectionEpoch(rawValue: UUID())
        var queue: [CommandQueueService.Command] = []
        var sidecar = TreadmillCommandTelemetrySidecar()
        for speed in [3.0, 3.4] {
            let commands = WalkingPadStartTransaction.commands(shouldSendStart: true, targetSpeedKmh: speed)
            enqueue(commands, epoch: epoch, queue: &queue, sidecar: &sidecar)
            XCTAssertEqual(queue.map(\.label), [
                "MODE MANUAL", "START", String(format: "SPEED %.1f km/h", speed),
            ])
            XCTAssertEqual(commands.map(\.delay), [0, 0.2, 0.45])
            for command in queue {
                guard case .matched(let current) = sidecar.dequeue(
                    expectedLabel: command.label, currentEpoch: epoch
                ) else { return XCTFail("Expected current-connection command evidence") }
                XCTAssertEqual(current.connectionEpoch, epoch)
            }
            _ = CommandQueueService.clear(queue: &queue)
            CommandQueueService.replaceWithHighPriority(
                queue: &queue, command: .init(data: Data(), label: "STOP")
            )
            _ = sidecar.replaceWithHighPriority(label: "STOP", evidence: evidence(kind: .stop, epoch: epoch))
            XCTAssertEqual(queue.map(\.label), ["STOP"])
            _ = CommandQueueService.clear(queue: &queue)
            _ = sidecar.clear()
            // Normal workout end does not reset a mode/start cache: none exists.
        }
    }

    func testHighPriorityStopPreemptsEveryQueuedPrefixOfSecondStart() {
        let epoch = TreadmillConnectionEpoch(rawValue: UUID())
        let first = WalkingPadStartTransaction.commands(shouldSendStart: true, targetSpeedKmh: 3.0)
        let second = WalkingPadStartTransaction.commands(shouldSendStart: true, targetSpeedKmh: 3.4)
        XCTAssertEqual(first.map(\.command).prefix(2), second.map(\.command).prefix(2))
        for count in 1...second.count {
            var queue: [CommandQueueService.Command] = []
            var sidecar = TreadmillCommandTelemetrySidecar()
            enqueue(Array(second.prefix(count)), epoch: epoch, queue: &queue, sidecar: &sidecar)
            CommandQueueService.replaceWithHighPriority(
                queue: &queue, command: .init(data: Data(), label: "STOP")
            )
            let stop = evidence(kind: .stop, epoch: epoch)
            let cancelled = sidecar.replaceWithHighPriority(label: "STOP", evidence: stop)
            XCTAssertEqual(cancelled.map(\.kind), second.prefix(count).map { kind(for: $0.command) })
            XCTAssertEqual(queue.map(\.label), ["STOP"])
            XCTAssertEqual(sidecar.dequeue(expectedLabel: "STOP", currentEpoch: epoch), .matched(stop))
            XCTAssertEqual(sidecar.count, 0)
        }
    }

    func testReconnectDropsOldQueueAndNewConnectionStillGetsFullStart() {
        let oldEpoch = TreadmillConnectionEpoch(rawValue: UUID())
        let newEpoch = TreadmillConnectionEpoch(rawValue: UUID())
        let commands = WalkingPadStartTransaction.commands(shouldSendStart: true, targetSpeedKmh: 3.0)
        var queue: [CommandQueueService.Command] = []
        var sidecar = TreadmillCommandTelemetrySidecar()
        enqueue(commands, epoch: oldEpoch, queue: &queue, sidecar: &sidecar)
        XCTAssertEqual(CommandQueueService.clear(queue: &queue), 3)
        XCTAssertEqual(sidecar.clear().map(\.connectionEpoch), Array(repeating: oldEpoch, count: 3))
        enqueue(commands, epoch: newEpoch, queue: &queue, sidecar: &sidecar)
        XCTAssertEqual(queue.map(\.label), ["MODE MANUAL", "START", "SPEED 3.0 km/h"])
        for command in queue {
            guard case .matched(let current) = sidecar.dequeue(
                expectedLabel: command.label, currentEpoch: newEpoch
            ) else { return XCTFail("Expected new-connection evidence") }
            XCTAssertEqual(current.connectionEpoch, newEpoch)
        }
    }

    func testCommandLabelsAndTelemetryKindsRemainExact() {
        let commands = WalkingPadStartTransaction.commands(shouldSendStart: true, targetSpeedKmh: 3.0)
        XCTAssertEqual(commands.map { $0.command.label }, ["MODE MANUAL", "START", "SPEED 3.0 km/h"])
        XCTAssertEqual(commands.map { kind(for: $0.command) }, [
            .other("mode_manual"), .other("start"),
            .setSpeed(TreadmillCommandedSpeedRepresentation.walkingPad(rawControllerTenths: 30)),
        ])
    }

    func testHrMotionOutputsMatchAllPre129BranchesAndThresholds() {
        let cases: [(target: Double, speed: Double, desired: Double, expected: Double?)] = [
            (0, 0, 4.2, 3), (0.1, 0.2, 4.2, 3),
            (0, 0.21, 4.2, 4.2), (0.1, 2.5, 3.4, 3.4),
            (0.11, 0, 4.2, nil), (3, 0, 4.2, nil), (3, 2.5, 4.2, nil),
        ]
        for input in cases {
            let target = HRDomainService.initialMotionTargetSpeedKmh(
                deviceTargetSpeedKmh: input.target,
                speedKmh: input.speed,
                desiredSpeedKmh: input.desired
            )
            XCTAssertEqual(target, input.expected)
            let commands = target.map {
                WalkingPadStartTransaction.commands(
                    shouldSendStart: input.speed <= 0.2 && input.target <= 0.1,
                    targetSpeedKmh: $0
                )
            } ?? []
            if input.target > 0.1 {
                XCTAssertTrue(commands.isEmpty, "Active target must not cause extra HR motion output")
            } else if input.speed > 0.2 {
                XCTAssertEqual(commands, [.init(command: .speed(input.desired), delay: 0.2)])
            } else {
                XCTAssertEqual(commands.map(\.command), [.modeManual, .start, .speed(3)])
            }
        }
    }

    // The iOS adapter is excluded from SwiftPM. Supplement behavioral rule/queue
    // tests above with wiring checks, including the absence of another admission gate.
    func testProductionStartHasNoObservationGateOrCrossWorkoutCache() throws {
        let start = try functionBody("func startWithSpeed(_ kmh: Double)")
        let commit = try functionBody("private func commitExistingHrControl(preflightLatencySeconds: TimeInterval)")
        for removed in ["manualModeSet", "currentWalkingPadFactualMotionObservation",
                        "walkingPadStartTransactionConnectionEpoch", "hrStartAdmission",
                        "rollbackCommittedHrControlBeforeMotion", "motion_admission_failed"] {
            XCTAssertFalse(bluetoothManagerSource.contains(removed), removed)
        }
        for body in [start, commit] {
            XCTAssertFalse(body.contains("latestTreadmillObservationEvidence"))
            XCTAssertFalse(body.contains("Дождитесь актуального статуса дорожки"))
        }
        assertOrdered([
            "guard !blocksNonStopTreadmillMotion", "guard isTreadmillControlReady",
            "resetCommandQueue(reason: \"startWithSpeed\")", "clampRunningSpeedKmh(kmh)",
            "let old = deviceTargetSpeedKmh", "deviceTargetSpeedKmh = v",
            "let shouldSendStart = speedKmh <= 0.2 && old <= 0.1",
            "WalkingPadStartTransaction.commands(", "shouldSendStart: shouldSendStart",
        ], in: start)
        assertOrdered([
            "nativeHeartRateSafetyFacts().permitsCommit", "unitsDecision.allowed",
            "isHrControlRunning = true", "persistQualifyingNativeHeartRateBeforeMotion()",
            "HRDomainService.initialMotionTargetSpeedKmh(",
            "deviceTargetSpeedKmh: deviceTargetSpeedKmh", "speedKmh: speedKmh",
            "desiredSpeedKmh: desiredSpeedKmh", "hrControlStartedBelt = true",
            "startWithSpeed(motionTargetSpeedKmh)",
        ], in: commit)
        XCTAssertTrue(try functionBody("private func observeCurrentStopTruth(")
            .contains("latestTreadmillObservationEvidence"))
    }

    func testProductionCommandMappingAndDelayedStopEpochPreemptionStayIntact() throws {
        let start = try functionBody("func startWithSpeed(_ kmh: Double)")
        assertOrdered([
            "case .modeManual:", "buildCmdPacket(cmd: 0x02, value: 0x01)",
            "label: scheduled.command.label", "requiresControlReadiness: true",
            "kind: .other(\"mode_manual\")", "case .start:",
            "buildCmdPacket(cmd: 0x04, value: 0x01)", "after: scheduled.delay",
            "requiresControlReadiness: true", "kind: .other(\"start\")",
            "case .speed(let targetSpeedKmh):", "buildWalkingPadSetSpeedPacket(kmh: targetSpeedKmh)",
            "after: scheduled.delay", "requiresControlReadiness: true",
            "kind: treadmillSetSpeedCommandKind(targetSpeedKmh)",
        ], in: start)
        assertOrdered([
            "let epoch = commandQueueEpoch", "guard self.commandQueueEpoch == epoch else { return }",
            "self.writeCommand(",
        ], in: try functionBody("private func scheduleWrite("))
        assertOrdered([
            "if highPriority", "resetCommandQueue(",
            "CommandQueueService.replaceWithHighPriority", "processCommandQueue()",
        ], in: try functionBody("private func enqueueCommand("))
        assertOrdered([
            "CommandQueueService.clear(queue: &commandQueue)", "commandQueueEpoch += 1",
        ], in: try functionBody("private func resetCommandQueue("))
    }

    private func enqueue(
        _ commands: [WalkingPadStartTransaction.ScheduledCommand],
        epoch: TreadmillConnectionEpoch,
        queue: inout [CommandQueueService.Command],
        sidecar: inout TreadmillCommandTelemetrySidecar
    ) {
        for scheduled in commands {
            let label = scheduled.command.label
            _ = CommandQueueService.enqueueRegular(
                queue: &queue, command: .init(data: Data(), label: label), isSpeedLabel: isSpeedLabel
            )
            _ = sidecar.enqueueRegular(
                label: label, evidence: evidence(kind: kind(for: scheduled.command), epoch: epoch),
                isSpeedLabel: isSpeedLabel
            )
        }
    }

    private func kind(for command: WalkingPadStartTransaction.Command) -> CommandKind {
        switch command {
        case .modeManual: .other("mode_manual")
        case .start: .other("start")
        case .speed(let speed):
            .setSpeed(TreadmillCommandedSpeedRepresentation.walkingPad(
                rawControllerTenths: Int((speed * 10).rounded())
            ))
        }
    }

    private func evidence(kind: CommandKind, epoch: TreadmillConnectionEpoch) -> TreadmillCommandEnqueuedEvidence {
        .init(commandID: CommandID(), decisionID: nil, kind: kind, protocolKind: .walkingPad,
              connectionEpoch: epoch, enqueuedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func isSpeedLabel(_ label: String) -> Bool { label.lowercased().hasPrefix("speed") }

    private func functionBody(_ signature: String) throws -> String {
        guard let signatureRange = bluetoothManagerSource.range(of: signature),
              let openingBrace = bluetoothManagerSource[signatureRange.upperBound...].firstIndex(of: "{") else {
            throw NSError(domain: "WalkingPadStartTransactionTests", code: 1)
        }
        var depth = 0
        var index = openingBrace
        while index < bluetoothManagerSource.endIndex {
            switch bluetoothManagerSource[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(bluetoothManagerSource[openingBrace...index]) }
            default: break
            }
            index = bluetoothManagerSource.index(after: index)
        }
        throw NSError(domain: "WalkingPadStartTransactionTests", code: 2)
    }

    private func assertOrdered(
        _ fragments: [String], in text: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        var cursor = text.startIndex
        for fragment in fragments {
            guard let range = text.range(of: fragment, range: cursor..<text.endIndex) else {
                return XCTFail("Missing or out-of-order fragment: \(fragment)", file: file, line: line)
            }
            cursor = range.upperBound
        }
    }
}
