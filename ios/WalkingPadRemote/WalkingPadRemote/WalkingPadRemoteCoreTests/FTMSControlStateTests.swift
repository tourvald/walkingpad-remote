import Foundation
import XCTest
@testable import WalkingPadCoreLogic

final class FTMSControlStateTests: XCTestCase {
    private let connection = TreadmillControlConnectionIdentity(peripheralID: UUID(), epoch: UUID())

    func testRequestMustCompleteBeforeStopAndAttSuccessCannotGrantControl() {
        var state = FTMSControlState()
        XCTAssertTrue(state.needsRequestControl)
        XCTAssertFalse(state.canSend(opcode: 0x08))
        state.sent(opcode: 0x00, connection: connection, at: .now)
        XCTAssertFalse(state.needsRequestControl)
        XCTAssertFalse(state.hasControl)
        XCTAssertFalse(state.canSend(opcode: 0x08))
        XCTAssertFalse(state.canSend(opcode: 0x00))
        XCTAssertEqual(state.receive(opcode: 0x00, resultCode: 0x01, connection: connection), true)
        XCTAssertTrue(state.hasControl)
        XCTAssertTrue(state.canSend(opcode: 0x08))
    }

    func testStopWaitsForSentProcedureButNeverRetainsQueuedSpeed() {
        var state = FTMSControlState()
        state.sent(opcode: 0x00, connection: connection, at: .now)
        _ = state.receive(opcode: 0x00, resultCode: 0x01, connection: connection)
        state.sent(opcode: 0x07, connection: connection, at: .now)
        var queue: [CommandQueueService.Command] = [.init(data: Data([0x02]), label: "SPEED")]
        CommandQueueService.replaceWithHighPriority(queue: &queue, command: .init(data: Data([0x08]), label: "STOP"))
        XCTAssertEqual(queue.map(\.label), ["STOP"])
        XCTAssertFalse(state.canSend(opcode: 0x08))
        XCTAssertNil(state.receive(opcode: 0x02, resultCode: 0x01, connection: connection))
        XCTAssertEqual(state.receive(opcode: 0x07, resultCode: 0x01, connection: connection), true)
        XCTAssertTrue(state.canSend(opcode: 0x08))
    }

    func testRejectedRequestAndTransportLossBlockMotionUntilReconnect() {
        for rejection in [UInt8(0x02), 0x03, 0x04, 0x05] {
            var state = FTMSControlState()
            state.sent(opcode: 0x00, connection: connection, at: .now)
            XCTAssertEqual(state.receive(opcode: 0x00, resultCode: rejection, connection: connection), false)
            assertBlocked(state)
        }
        var state = FTMSControlState()
        state.sent(opcode: 0x00, connection: connection, at: .now)
        state.invalidate()
        assertBlocked(state)
        XCTAssertNil(state.receive(opcode: 0x00, resultCode: 0x01, connection: connection))
        XCTAssertTrue(FTMSControlState().needsRequestControl)
    }

    func testRejectedProcedureRetainsGrantedControlAndAllowsStop() {
        for opcode: UInt8 in [0x02, 0x07, 0x08] {
            for rejection: UInt8 in [0x02, 0x03, 0x04] {
                var state = FTMSControlState()
                state.sent(opcode: 0x00, connection: connection, at: .now)
                XCTAssertEqual(state.receive(opcode: 0x00, resultCode: 0x01, connection: connection), true)
                state.sent(opcode: opcode, connection: connection, at: .now)
                XCTAssertEqual(state.receive(opcode: opcode, resultCode: rejection, connection: connection), false)
                XCTAssertTrue(state.hasControl)
                XCTAssertFalse(state.isBlocked)
                XCTAssertTrue(state.canSend(opcode: 0x08))
                XCTAssertFalse(state.needsRequestControl)
            }
        }
    }

    func testLostPermissionAndUnknownResultCannotRetainControl() {
        for rejection: UInt8 in [0x00, 0x05, 0xFF] {
            var state = FTMSControlState()
            state.sent(opcode: 0x00, connection: connection, at: .now)
            _ = state.receive(opcode: 0x00, resultCode: 0x01, connection: connection)
            state.sent(opcode: 0x02, connection: connection, at: .now)
            XCTAssertEqual(state.receive(opcode: 0x02, resultCode: rejection, connection: connection), false)
            assertBlocked(state)
        }
    }

    func testTimeoutIsMonotonicAndLateSuccessCannotGrantControl() {
        var state = FTMSControlState()
        let start = ContinuousClock.now
        state.sent(opcode: 0x00, connection: connection, at: start)
        XCTAssertFalse(state.hasTimedOut(at: start.advanced(by: .seconds(29))))
        XCTAssertTrue(state.hasTimedOut(at: start.advanced(by: .seconds(30))))
        state.invalidate()
        XCTAssertNil(state.receive(opcode: 0x00, resultCode: 0x01, connection: connection))
        assertBlocked(state)
    }

    func testLateSuccessExpiresWithoutWaitingForMaintenanceTick() {
        let start = ContinuousClock.now
        for opcode: UInt8 in [0x00, 0x08] {
            var state = FTMSControlState()
            state.sent(opcode: opcode, connection: connection, at: start)
            XCTAssertEqual(state.receive(opcode: opcode, resultCode: 0x01,
                connection: connection, at: start.advanced(by: .seconds(30))), false)
            assertBlocked(state)
        }
    }

    func testOldConnectionCannotGrantControlToNewRequest() {
        var state = FTMSControlState()
        let replacement = TreadmillControlConnectionIdentity(peripheralID: connection.peripheralID, epoch: UUID())
        state.sent(opcode: 0x00, connection: replacement, at: .now)
        XCTAssertNil(state.receive(opcode: 0x00, resultCode: 0x01, connection: connection))
        XCTAssertFalse(state.hasControl)
        XCTAssertEqual(state.receive(opcode: 0x00, resultCode: 0x01, connection: replacement), true)
    }

    func testMalformedMachineStatusCannotRevokeControl() {
        XCTAssertTrue(BLETransportCodec.ftmsControlPermissionWasLost(Data([0xFF])))
        for bytes: [UInt8] in [[], [0x01], [0xFF, 0x00], [0x80, 0x00, 0x01]] {
            XCTAssertFalse(BLETransportCodec.ftmsControlPermissionWasLost(Data(bytes)))
        }
    }

    private func assertBlocked(_ state: FTMSControlState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(state.isBlocked, file: file, line: line)
        XCTAssertFalse(state.needsRequestControl, file: file, line: line)
        for opcode: UInt8 in [0x00, 0x02, 0x07, 0x08] {
            XCTAssertFalse(state.canSend(opcode: opcode), file: file, line: line)
        }
    }
}
