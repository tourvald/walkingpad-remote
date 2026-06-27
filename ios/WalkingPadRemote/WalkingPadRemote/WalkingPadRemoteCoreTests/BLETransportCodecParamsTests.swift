import Foundation
import XCTest
@testable import WalkingPadCoreLogic

final class BLETransportCodecParamsTests: XCTestCase {
    func testQueryParamsPacketBytes() {
        let packet = BLETransportCodec.buildWalkingPadQueryParamsPacket()

        XCTAssertEqual([UInt8](packet), [0xF7, 0xA6, 0x00, 0x00, 0x00, 0x00, 0x00, 0xA6, 0xFD])
    }

    func testParseParamsResponseKeepsRawValuesAndNormalizesUnits() {
        // F8 A6 goalType goal[3] regulate maxSpeed startSpeed startMode sensitivity display lock unit crc FD
        let bytes: [UInt8] = [
            0xF8, 0xA6,
            0x00,
            0x00, 0x00, 0x00,
            0x00,
            0x3C,
            0x14,
            0x01,
            0x03,
            0x7F,
            0x00,
            0x01,
            0x7A,
            0xFD
        ]

        let params = BLETransportCodec.parseWalkingPadParams(Data(bytes))

        XCTAssertNotNil(params)
        XCTAssertEqual(params?.maxSpeedRawTenths, 0x3C)
        XCTAssertEqual(params?.maxSpeedKmh, 6.0)
        XCTAssertEqual(params?.startSpeedRawTenths, 0x14)
        XCTAssertEqual(params?.startSpeedKmh, 2.0)
        XCTAssertEqual(params?.unit, 1)
        XCTAssertEqual(params?.nativeUnitsLabel, "imperial")
        XCTAssertEqual(params?.checksumOk, true)
        XCTAssertEqual(params?.rawHex, "F8 A6 00 00 00 00 00 3C 14 01 03 7F 00 01 7A FD")
    }

    func testParseParamsNormalizesMetricAndUnknownUnits() {
        var metricBytes: [UInt8] = [
            0xF8, 0xA6, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x3C, 0x14, 0x01, 0x03, 0x7F, 0x00, 0x00, 0x79, 0xFD
        ]
        XCTAssertEqual(BLETransportCodec.parseWalkingPadParams(Data(metricBytes))?.nativeUnitsLabel, "metric")

        metricBytes[13] = 0x02
        metricBytes[14] = 0x7B
        let unknownParams = BLETransportCodec.parseWalkingPadParams(Data(metricBytes))
        XCTAssertEqual(unknownParams?.unit, 2)
        XCTAssertEqual(unknownParams?.nativeUnitsLabel, "unknown")
    }

    func testParseParamsDetectsBadChecksumAndRejectsWrongShape() {
        let badChecksum = Data([
            0xF8, 0xA6, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x3C, 0x14, 0x01, 0x03, 0x7F, 0x00, 0x01, 0x00, 0xFD
        ])

        XCTAssertEqual(BLETransportCodec.parseWalkingPadParams(badChecksum)?.checksumOk, false)
        XCTAssertNil(BLETransportCodec.parseWalkingPadParams(Data([0xF8, 0xA2, 0x01, 0x00])))
        XCTAssertNil(BLETransportCodec.parseWalkingPadParams(Data([0xF8, 0xA6, 0x00, 0x00])))
    }
}
