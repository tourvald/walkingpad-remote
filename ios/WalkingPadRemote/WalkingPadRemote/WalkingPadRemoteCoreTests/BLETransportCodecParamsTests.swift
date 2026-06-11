import Foundation
import XCTest
@testable import WalkingPadCoreLogic

final class BLETransportCodecParamsTests: XCTestCase {
    func testQueryParamsPacketBytes() {
        let packet = BLETransportCodec.buildWalkingPadQueryParamsPacket()
        XCTAssertEqual([UInt8](packet), [0xF7, 0xA6, 0x00, 0x00, 0x00, 0x00, 0x00, 0xA6, 0xFD])
    }

    func testParseParamsResponse() {
        // F8 A6 goalType goal[3] regulate maxSpeed startSpeed startMode sensitivity display lock unit crc FD
        let bytes: [UInt8] = [
            0xF8, 0xA6,
            0x00,             // goalType
            0x00, 0x00, 0x00, // goal
            0x00,             // regulate
            0x3C,             // maxSpeed raw 60 -> 6.0 km/h
            0x14,             // startSpeed raw 20 -> 2.0 km/h
            0x01,             // startMode
            0x03,             // sensitivity (3 = low)
            0x7F,             // display bits
            0x00,             // child lock
            0x01,             // unit (1 = imperial)
            0x7A,             // checksum = sum(bytes[1..13]) & 0xFF
            0xFD
        ]
        let params = BLETransportCodec.parseWalkingPadParams(Data(bytes))
        XCTAssertNotNil(params)
        XCTAssertEqual(params?.goalType, 0)
        XCTAssertEqual(params?.goal, 0)
        XCTAssertEqual(params?.regulate, 0)
        XCTAssertEqual(params?.maxSpeedKmh, 6.0)
        XCTAssertEqual(params?.startSpeedKmh, 2.0)
        XCTAssertEqual(params?.startMode, 1)
        XCTAssertEqual(params?.sensitivity, 3)
        XCTAssertEqual(params?.displayBits, 0x7F)
        XCTAssertEqual(params?.childLock, 0)
        XCTAssertEqual(params?.unit, 1)
        XCTAssertEqual(params?.checksumOk, true)
    }

    func testParseParamsDetectsBadChecksum() {
        var bytes: [UInt8] = [
            0xF8, 0xA6, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x3C, 0x14, 0x01, 0x03, 0x7F, 0x00, 0x01,
            0x00, 0xFD
        ]
        bytes[14] = 0x11 // wrong checksum
        let params = BLETransportCodec.parseWalkingPadParams(Data(bytes))
        XCTAssertNotNil(params)
        XCTAssertEqual(params?.checksumOk, false)
    }

    func testParseParamsRejectsWrongTypeOrShortFrame() {
        XCTAssertNil(BLETransportCodec.parseWalkingPadParams(Data([0xF8, 0xA2, 0x01, 0x00])))
        XCTAssertNil(BLETransportCodec.parseWalkingPadParams(Data([0xF8, 0xA6, 0x00, 0x00])))
        XCTAssertNil(BLETransportCodec.parseWalkingPadParams(Data()))
    }
}
