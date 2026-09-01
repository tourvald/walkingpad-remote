import Foundation
import TelemetryDomain
import XCTest
@testable import WalkingPadCoreLogic

final class WalkingPadStartTransactionTests: XCTestCase {
    private lazy var bluetoothManagerSource: String = {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("WalkingPadRemote/BluetoothManager.swift")
        return (try? String(contentsOf: sourceURL, encoding: .utf8)) ?? ""
    }()

    func testFirstStoppedStartOwnsFullPrerequisiteTransaction() {
        XCTAssertEqual(
            WalkingPadStartTransaction.plan(
                isStartTransactionInFlight: false,
                previousCommandedSpeedKmh: 0,
                factualObservation: nil,
                targetSpeedKmh: 3.0
            ),
            [
                .init(command: .modeManual, delay: 0),
                .init(command: .start, delay: 0.2),
                .init(command: .speed(3.0), delay: 0.45),
            ]
        )
    }

    func testOrdinaryStopThenSecondStartInSameConnectionOwnsPrerequisitesAgain() {
        let firstStart = WalkingPadStartTransaction.plan(
            isStartTransactionInFlight: false,
            previousCommandedSpeedKmh: 0,
            factualObservation: nil,
            targetSpeedKmh: 3.0
        )

        // An ordinary Stop does not need to mutate any start-transaction cache.
        let secondStart = WalkingPadStartTransaction.plan(
            isStartTransactionInFlight: false,
            previousCommandedSpeedKmh: 0,
            factualObservation: nil,
            targetSpeedKmh: 3.4
        )

        XCTAssertEqual(firstStart.map(\.command), [.modeManual, .start, .speed(3.0)])
        XCTAssertEqual(secondStart.map(\.command), [.modeManual, .start, .speed(3.4)])
    }

    func testSpeedAdjustmentWhileMovingDoesNotResendPrerequisites() {
        for previousCommandedSpeedKmh in [0.0, 3.0] {
            XCTAssertEqual(
                WalkingPadStartTransaction.plan(
                    isStartTransactionInFlight: false,
                    previousCommandedSpeedKmh: previousCommandedSpeedKmh,
                    factualObservation: .init(
                        motion: .moving,
                        ageSeconds: 0.5,
                        isCurrentConnectionEpoch: true
                    ),
                    targetSpeedKmh: 3.8
                ),
                [.init(command: .speed(3.8), delay: 0.2)]
            )
        }
    }

    func testDisconnectReconnectDoesNotChangeStoppedStartContract() {
        let beforeDisconnect = WalkingPadStartTransaction.plan(
            isStartTransactionInFlight: false,
            previousCommandedSpeedKmh: 0,
            factualObservation: nil,
            targetSpeedKmh: 3.0
        )
        let afterReconnect = WalkingPadStartTransaction.plan(
            isStartTransactionInFlight: false,
            previousCommandedSpeedKmh: 0,
            factualObservation: nil,
            targetSpeedKmh: 3.0
        )

        XCTAssertEqual(afterReconnect, beforeDisconnect)
        XCTAssertEqual(afterReconnect.map(\.command), [.modeManual, .start, .speed(3.0)])
    }

    func testHighPriorityStopPreemptsPartiallyQueuedSecondStartAndTelemetrySidecar() {
        let epoch = TreadmillConnectionEpoch(rawValue: UUID())
        let secondStart = WalkingPadStartTransaction.plan(
            isStartTransactionInFlight: false,
            previousCommandedSpeedKmh: 0,
            factualObservation: nil,
            targetSpeedKmh: 3.0
        )
        var queue: [CommandQueueService.Command] = []
        var sidecar = TreadmillCommandTelemetrySidecar()

        for scheduled in secondStart {
            let label = scheduled.command.label
            let command = CommandQueueService.Command(data: Data(), label: label)
            _ = CommandQueueService.enqueueRegular(
                queue: &queue,
                command: command,
                isSpeedLabel: isSpeedLabel
            )
            _ = sidecar.enqueueRegular(
                label: label,
                evidence: evidence(for: scheduled.command, epoch: epoch),
                isSpeedLabel: isSpeedLabel
            )
        }

        let stopEvidence = evidence(kind: .stop, epoch: epoch)
        CommandQueueService.replaceWithHighPriority(
            queue: &queue,
            command: .init(data: Data([0x00]), label: "STOP")
        )
        let superseded = sidecar.replaceWithHighPriority(
            label: "STOP",
            evidence: stopEvidence
        )

        XCTAssertEqual(queue.map(\.label), ["STOP"])
        XCTAssertEqual(sidecar.count, 1)
        XCTAssertEqual(superseded.map(\.kind), [
            .other("mode_manual"),
            .other("start"),
            .setSpeed(TreadmillCommandedSpeedRepresentation.walkingPad(rawControllerTenths: 30)),
        ])
        XCTAssertEqual(sidecar.dequeue(expectedLabel: "STOP", currentEpoch: epoch), .matched(stopEvidence))
    }

    func testCommandLabelsAndTelemetryKindsRemainExact() {
        let epoch = TreadmillConnectionEpoch(rawValue: UUID())
        let plan = WalkingPadStartTransaction.plan(
            isStartTransactionInFlight: false,
            previousCommandedSpeedKmh: 0,
            factualObservation: nil,
            targetSpeedKmh: 3.0
        )

        XCTAssertEqual(plan.map { $0.command.label }, [
            "MODE MANUAL",
            "START",
            "SPEED 3.0 km/h",
        ])
        XCTAssertEqual(plan.map { evidence(for: $0.command, epoch: epoch).kind }, [
            .other("mode_manual"),
            .other("start"),
            .setSpeed(TreadmillCommandedSpeedRepresentation.walkingPad(rawControllerTenths: 30)),
        ])
    }

    func testProductionIntegrationUsesStatelessPlanAndExactTelemetryMapping() throws {
        let body = try functionBody("func startWithSpeed(_ kmh: Double)")

        XCTAssertFalse(bluetoothManagerSource.contains("manualModeSet"))
        assertOrdered(
            [
                "WalkingPadStartTransaction.plan(",
                "isStartTransactionInFlight: isWalkingPadStartTransactionInFlight",
                "previousCommandedSpeedKmh: old",
                "factualObservation: currentWalkingPadFactualMotionObservation()",
                "case .modeManual:",
                "buildCmdPacket(cmd: 0x02, value: 0x01)",
                "label: scheduled.command.label",
                "kind: .other(\"mode_manual\")",
                "case .start:",
                "buildCmdPacket(cmd: 0x04, value: 0x01)",
                "kind: .other(\"start\")",
                "case .speed(let targetSpeedKmh):",
                "buildWalkingPadSetSpeedPacket(kmh: targetSpeedKmh)",
                "kind: treadmillSetSpeedCommandKind(targetSpeedKmh)",
            ],
            in: body
        )
        XCTAssertTrue(body.contains("after: scheduled.delay"))
    }

    func testProductionStopRaceInvalidatesDelayedStartCommands() throws {
        let startBody = try functionBody("func startWithSpeed(_ kmh: Double)")
        let scheduleBody = try functionBody("private func scheduleWrite(")
        let enqueueBody = try functionBody("private func enqueueCommand(")

        XCTAssertTrue(startBody.contains("case .start:"))
        XCTAssertTrue(startBody.contains("case .speed(let targetSpeedKmh):"))
        XCTAssertGreaterThanOrEqual(
            startBody.components(separatedBy: "after: scheduled.delay").count - 1,
            2
        )
        assertOrdered(
            [
                "let epoch = commandQueueEpoch",
                "guard self.commandQueueEpoch == epoch else { return }",
                "self.writeCommand(",
            ],
            in: scheduleBody
        )
        assertOrdered(
            [
                "if highPriority",
                "resetCommandQueue(",
                "CommandQueueService.replaceWithHighPriority",
                "processCommandQueue()",
            ],
            in: enqueueBody
        )
    }

    func testProductionTransactionOwnershipIsBoundedByStopResetAndFactualMoving() throws {
        let startBody = try functionBody("func startWithSpeed(_ kmh: Double)")
        let resetBody = try functionBody("private func resetCommandQueue(")
        let observationBody = try functionBody("private func observeTreadmillProviderObservation(")

        assertOrdered(
            [
                "WalkingPadStartTransaction.plan(",
                "guard walkingPadTransaction?.isEmpty != true",
                "resetCommandQueue(reason: \"startWithSpeed\")",
                "walkingPadStartTransactionConnectionEpoch = treadmillTelemetryConnectionEpoch",
                "for scheduled in transaction",
            ],
            in: startBody
        )
        assertOrdered(
            [
                "CommandQueueService.clear(queue: &commandQueue)",
                "walkingPadStartTransactionConnectionEpoch = nil",
                "commandQueueEpoch += 1",
            ],
            in: resetBody
        )
        assertOrdered(
            [
                "latestTreadmillObservationEvidence = evidence",
                "evidence.protocolKind == .walkingPad",
                "let factualSpeedKmh = evidence.factualSpeed?.value",
                "evidence.deviceState == .moving || factualSpeedKmh > 0.1",
                "walkingPadStartTransactionConnectionEpoch = nil",
                "observeTreadmillTelemetry(.observation(evidence))",
            ],
            in: observationBody
        )
    }

    func testFreshFactualStopOverridesStaleCommandedMovingState() {
        let plan = WalkingPadStartTransaction.plan(
            isStartTransactionInFlight: false,
            previousCommandedSpeedKmh: 3.0,
            factualObservation: .init(
                motion: .stopped,
                ageSeconds: 0.5,
                isCurrentConnectionEpoch: true
            ),
            targetSpeedKmh: 3.2
        )

        XCTAssertEqual(plan.map(\.command), [.modeManual, .start, .speed(3.2)])
    }

    func testStaleOrWrongEpochStopDoesNotCreateDuplicateMotionCommands() {
        for observation in [
            WalkingPadStartTransaction.FactualMotionObservation(
                motion: .stopped,
                ageSeconds: StopObservationPolicy.freshnessInterval + 0.01,
                isCurrentConnectionEpoch: true
            ),
            WalkingPadStartTransaction.FactualMotionObservation(
                motion: .stopped,
                ageSeconds: 0.5,
                isCurrentConnectionEpoch: false
            ),
        ] {
            XCTAssertEqual(
                WalkingPadStartTransaction.plan(
                    isStartTransactionInFlight: false,
                    previousCommandedSpeedKmh: 3.0,
                    factualObservation: observation,
                    targetSpeedKmh: 3.4
                ),
                [.init(command: .speed(3.4), delay: 0.2)]
            )
        }
    }

    func testRepeatedStartWhileTransactionIsInFlightEmitsNoDuplicateCommands() {
        let plan = WalkingPadStartTransaction.plan(
            isStartTransactionInFlight: true,
            previousCommandedSpeedKmh: 3.0,
            factualObservation: .init(
                motion: .stopped,
                ageSeconds: 0.5,
                isCurrentConnectionEpoch: true
            ),
            targetSpeedKmh: 3.4
        )

        XCTAssertTrue(plan.isEmpty)
    }

    private func evidence(
        for command: WalkingPadStartTransaction.Command,
        epoch: TreadmillConnectionEpoch
    ) -> TreadmillCommandEnqueuedEvidence {
        switch command {
        case .modeManual:
            return evidence(kind: .other("mode_manual"), epoch: epoch)
        case .start:
            return evidence(kind: .other("start"), epoch: epoch)
        case .speed(let targetSpeedKmh):
            return evidence(
                kind: .setSpeed(
                    TreadmillCommandedSpeedRepresentation.walkingPad(
                        rawControllerTenths: Int((targetSpeedKmh * 10).rounded())
                    )
                ),
                epoch: epoch
            )
        }
    }

    private func evidence(
        kind: CommandKind,
        epoch: TreadmillConnectionEpoch
    ) -> TreadmillCommandEnqueuedEvidence {
        TreadmillCommandEnqueuedEvidence(
            commandID: CommandID(),
            decisionID: nil,
            kind: kind,
            protocolKind: .walkingPad,
            connectionEpoch: epoch,
            enqueuedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func isSpeedLabel(_ label: String) -> Bool {
        label.lowercased().hasPrefix("speed")
    }

    private func functionBody(_ signature: String) throws -> String {
        guard let signatureRange = bluetoothManagerSource.range(of: signature),
              let openingBrace = bluetoothManagerSource[signatureRange.upperBound...]
                .firstIndex(of: "{") else {
            throw NSError(domain: "WalkingPadStartTransactionTests", code: 1)
        }
        var depth = 0
        var index = openingBrace
        while index < bluetoothManagerSource.endIndex {
            switch bluetoothManagerSource[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(bluetoothManagerSource[openingBrace...index])
                }
            default: break
            }
            index = bluetoothManagerSource.index(after: index)
        }
        throw NSError(domain: "WalkingPadStartTransactionTests", code: 2)
    }

    private func assertOrdered(
        _ fragments: [String],
        in text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var searchStart = text.startIndex
        for fragment in fragments {
            guard let range = text.range(of: fragment, range: searchStart..<text.endIndex) else {
                XCTFail("Missing or out-of-order fragment: \(fragment)", file: file, line: line)
                return
            }
            searchStart = range.upperBound
        }
    }
}
