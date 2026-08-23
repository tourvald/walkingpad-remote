import Foundation
import XCTest
@testable import WalkingPadCoreLogic

final class TreadmillControlReadinessPolicyTests: XCTestCase {
    private let current = TreadmillControlConnectionIdentity(
        peripheralID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        epoch: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    )

    func testEachSupportedProtocolRequiresItsMatchingCurrentUsableTransportPair() {
        let cases: [(
            TreadmillControlProtocolKind,
            TreadmillControlTransportRole,
            TreadmillControlTransportRole
        )] = [
            (.walkingPad, .walkingPadTelemetry, .walkingPadCommand),
            (.ftms, .ftmsTelemetry, .ftmsCommand),
            (.fitShow, .fitShowTelemetry, .fitShowCommand),
        ]

        for (protocolKind, telemetryRole, commandRole) in cases {
            let snapshot = readySnapshot(
                protocolKind: protocolKind,
                telemetryRole: telemetryRole,
                commandRole: commandRole
            )

            XCTAssertTrue(
                TreadmillControlReadinessPolicy.isReady(snapshot),
                "Expected \(protocolKind) to be ready with its current usable transports"
            )
        }
    }

    func testMissingOrUnusableTransportFailsClosedForEverySupportedProtocol() {
        let cases: [(
            TreadmillControlProtocolKind,
            TreadmillControlTransportRole,
            TreadmillControlTransportRole
        )] = [
            (.walkingPad, .walkingPadTelemetry, .walkingPadCommand),
            (.ftms, .ftmsTelemetry, .ftmsCommand),
            (.fitShow, .fitShowTelemetry, .fitShowCommand),
        ]

        for (protocolKind, telemetryRole, commandRole) in cases {
            let ready = readySnapshot(
                protocolKind: protocolKind,
                telemetryRole: telemetryRole,
                commandRole: commandRole
            )
            XCTAssertFalse(TreadmillControlReadinessPolicy.isReady(replacingTelemetry(in: ready, with: nil)))
            XCTAssertFalse(TreadmillControlReadinessPolicy.isReady(replacingCommand(in: ready, with: nil)))
            XCTAssertFalse(TreadmillControlReadinessPolicy.isReady(replacingTelemetry(
                in: ready,
                with: evidence(role: telemetryRole, isUsable: false)
            )))
            XCTAssertFalse(TreadmillControlReadinessPolicy.isReady(replacingCommand(
                in: ready,
                with: evidence(role: commandRole, isUsable: false)
            )))
        }
    }

    func testProtocolTransportMismatchAndUnknownProtocolFailClosed() {
        XCTAssertFalse(TreadmillControlReadinessPolicy.isReady(readySnapshot(
            protocolKind: .walkingPad,
            telemetryRole: .ftmsTelemetry,
            commandRole: .ftmsCommand
        )))
        XCTAssertFalse(TreadmillControlReadinessPolicy.isReady(readySnapshot(
            protocolKind: .unknown,
            telemetryRole: .walkingPadTelemetry,
            commandRole: .walkingPadCommand
        )))
    }

    func testMissingLinkAndStalePeripheralOrEpochFailClosed() {
        let ready = readySnapshot(
            protocolKind: .walkingPad,
            telemetryRole: .walkingPadTelemetry,
            commandRole: .walkingPadCommand
        )
        XCTAssertFalse(TreadmillControlReadinessPolicy.isReady(
            TreadmillControlReadinessSnapshot(
                currentConnection: nil,
                protocolKind: ready.protocolKind,
                protocolConnection: ready.protocolConnection,
                telemetry: ready.telemetry,
                command: ready.command
            )
        ))

        let stalePeripheral = TreadmillControlConnectionIdentity(
            peripheralID: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            epoch: current.epoch
        )
        XCTAssertFalse(TreadmillControlReadinessPolicy.isReady(replacingTelemetry(
            in: ready,
            with: TreadmillControlTransportEvidence(
                role: .walkingPadTelemetry,
                connection: stalePeripheral,
                isUsable: true
            )
        )))
        XCTAssertFalse(TreadmillControlReadinessPolicy.isReady(replacingCommand(
            in: ready,
            with: TreadmillControlTransportEvidence(
                role: .walkingPadCommand,
                connection: stalePeripheral,
                isUsable: true
            )
        )))

        let staleEpoch = TreadmillControlConnectionIdentity(
            peripheralID: current.peripheralID,
            epoch: UUID(uuidString: "00000000-1111-2222-3333-444444444444")!
        )
        XCTAssertFalse(TreadmillControlReadinessPolicy.isReady(
            TreadmillControlReadinessSnapshot(
                currentConnection: current,
                protocolKind: ready.protocolKind,
                protocolConnection: staleEpoch,
                telemetry: ready.telemetry,
                command: ready.command
            )
        ))
    }

    func testCallbackContextMustMatchTheCurrentPeripheralAndEpoch() {
        XCTAssertTrue(TreadmillControlReadinessPolicy.isCurrentCallback(
            current,
            currentConnection: current
        ))

        let stalePeripheral = TreadmillControlConnectionIdentity(
            peripheralID: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            epoch: current.epoch
        )
        XCTAssertFalse(TreadmillControlReadinessPolicy.isCurrentCallback(
            stalePeripheral,
            currentConnection: current
        ))

        let staleEpoch = TreadmillControlConnectionIdentity(
            peripheralID: current.peripheralID,
            epoch: UUID(uuidString: "00000000-1111-2222-3333-444444444444")!
        )
        XCTAssertFalse(TreadmillControlReadinessPolicy.isCurrentCallback(
            staleEpoch,
            currentConnection: current
        ))
        XCTAssertFalse(TreadmillControlReadinessPolicy.isCurrentCallback(
            nil,
            currentConnection: current
        ))
    }

    private func readySnapshot(
        protocolKind: TreadmillControlProtocolKind,
        telemetryRole: TreadmillControlTransportRole,
        commandRole: TreadmillControlTransportRole
    ) -> TreadmillControlReadinessSnapshot {
        TreadmillControlReadinessSnapshot(
            currentConnection: current,
            protocolKind: protocolKind,
            protocolConnection: current,
            telemetry: evidence(role: telemetryRole),
            command: evidence(role: commandRole)
        )
    }

    private func evidence(
        role: TreadmillControlTransportRole,
        isUsable: Bool = true
    ) -> TreadmillControlTransportEvidence {
        TreadmillControlTransportEvidence(
            role: role,
            connection: current,
            isUsable: isUsable
        )
    }

    private func replacingTelemetry(
        in snapshot: TreadmillControlReadinessSnapshot,
        with telemetry: TreadmillControlTransportEvidence?
    ) -> TreadmillControlReadinessSnapshot {
        TreadmillControlReadinessSnapshot(
            currentConnection: snapshot.currentConnection,
            protocolKind: snapshot.protocolKind,
            protocolConnection: snapshot.protocolConnection,
            telemetry: telemetry,
            command: snapshot.command
        )
    }

    private func replacingCommand(
        in snapshot: TreadmillControlReadinessSnapshot,
        with command: TreadmillControlTransportEvidence?
    ) -> TreadmillControlReadinessSnapshot {
        TreadmillControlReadinessSnapshot(
            currentConnection: snapshot.currentConnection,
            protocolKind: snapshot.protocolKind,
            protocolConnection: snapshot.protocolConnection,
            telemetry: snapshot.telemetry,
            command: command
        )
    }
}
