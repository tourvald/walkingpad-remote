import Foundation
import XCTest
@testable import WalkingPadCoreLogic

final class BLETransportCodecParamsTests: XCTestCase {
    func testQueryParamsPacketIsExactReadOnlyKeyZeroRequest() {
        let packet = BLETransportCodec.buildWalkingPadQueryParamsPacket()

        XCTAssertEqual([UInt8](packet), [0xF7, 0xA6, 0x00, 0x00, 0x00, 0x00, 0x00, 0xA6, 0xFD])
        XCTAssertEqual(packet[2], 0, "A6 key zero is the read-only query form")
    }

    func testParsesValidMetricResponse() {
        let params = BLETransportCodec.parseWalkingPadParams(frame(unit: 0))

        XCTAssertEqual(params?.rawControllerUnit, 0)
        XCTAssertEqual(params?.checksumOk, true)
        XCTAssertEqual(params?.maxSpeedRawTenths, 0x3C)
        XCTAssertEqual(params?.startSpeedRawTenths, 0x14)
    }

    func testParsesValidImperialResponse() {
        let params = BLETransportCodec.parseWalkingPadParams(frame(unit: 1))

        XCTAssertEqual(params?.rawControllerUnit, 1)
        XCTAssertEqual(params?.checksumOk, true)
    }

    func testKeepsUnknownUnitAsRawEvidence() {
        let params = BLETransportCodec.parseWalkingPadParams(frame(unit: 2))

        XCTAssertEqual(params?.rawControllerUnit, 2)
        XCTAssertEqual(params?.checksumOk, true)
    }

    func testReportsChecksumFailureWithoutAcceptingItAsValid() {
        var bytes = [UInt8](frame(unit: 0))
        bytes[14] ^= 0x01

        let params = BLETransportCodec.parseWalkingPadParams(Data(bytes))

        XCTAssertEqual(params?.checksumOk, false)
    }

    func testRejectsMalformedFramesAndMissingTerminator() {
        XCTAssertNil(BLETransportCodec.parseWalkingPadParams(Data([0xF8, 0xA6])))
        XCTAssertNil(BLETransportCodec.parseWalkingPadParams(Data([0xF8, 0xA2] + Array(repeating: 0, count: 14))))

        var missingTerminator = [UInt8](frame(unit: 0))
        missingTerminator[15] = 0x00
        XCTAssertNil(BLETransportCodec.parseWalkingPadParams(Data(missingTerminator)))

        var extraByte = [UInt8](frame(unit: 0))
        extraByte.append(0x00)
        XCTAssertNil(BLETransportCodec.parseWalkingPadParams(Data(extraByte)))
    }

    func testParsesWalkingPadStatusRawEvidenceWithoutChangingUnits() {
        let status = BLETransportCodec.parseWalkingPadStatus(statusFrame(state: 2, speedRawTenths: 7))

        XCTAssertEqual(status?.beltState, 2)
        XCTAssertEqual(status?.speedRawTenths, 7)
        XCTAssertEqual(status?.speedKmh, 0.7)
        XCTAssertEqual(status?.appSpeedRawTenths, 8)
        XCTAssertEqual(status?.manualMode, 1)
        XCTAssertEqual(status?.timeSeconds, 2)
        XCTAssertEqual(status?.distance10m, 3)
        XCTAssertEqual(status?.steps, 4)
        XCTAssertEqual(status?.lastButton, 9)
        XCTAssertEqual(status?.checksumOk, true)
    }

    func testWalkingPadStatusReportsChecksumFailureAndRejectsMalformedFrame() {
        var invalidChecksum = [UInt8](statusFrame(state: 0, speedRawTenths: 0))
        invalidChecksum[18] ^= 0x01

        XCTAssertEqual(BLETransportCodec.parseWalkingPadStatus(Data(invalidChecksum))?.checksumOk, false)
        XCTAssertNil(BLETransportCodec.parseWalkingPadStatus(Data([0xF8, 0xA2])))
        XCTAssertNil(BLETransportCodec.parseWalkingPadStatus(Data([0xF8, 0xA6] + Array(repeating: 0, count: 18))))
    }

    private func frame(unit: UInt8) -> Data {
        var bytes: [UInt8] = [
            0xF8, 0xA6, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x3C, 0x14, 0x01, 0x03, 0x7F, 0x00, unit, 0x00, 0xFD
        ]
        bytes[14] = UInt8(bytes[1..<14].reduce(UInt16(0)) { ($0 + UInt16($1)) & 0xFF })
        return Data(bytes)
    }

    private func statusFrame(state: UInt8, speedRawTenths: UInt8) -> Data {
        var bytes: [UInt8] = [
            0xF8, 0xA2, state, speedRawTenths, 0x01,
            0x00, 0x00, 0x02,
            0x00, 0x00, 0x03,
            0x00, 0x00, 0x04,
            0x08, 0x00, 0x09, 0x00, 0x00, 0xFD
        ]
        bytes[18] = UInt8(bytes[1..<18].reduce(UInt16(0)) { ($0 + UInt16($1)) & 0xFF })
        return Data(bytes)
    }
}
