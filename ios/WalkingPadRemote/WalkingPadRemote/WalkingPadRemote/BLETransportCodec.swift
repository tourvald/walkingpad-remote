import Foundation

enum BLETransportCodec {
    struct FtmsTreadmillData {
        let instantaneousSpeedKmh: Double
        let isMoving: Bool
    }

    struct FtmsSupportedSpeedRange {
        let minSpeedKmh: Double
        let maxSpeedKmh: Double
        let minIncrementKmh: Double
    }

    struct FtmsControlPointResponse {
        let requestedOpcode: UInt8
        let resultCode: UInt8
    }

    struct FitShowFrame {
        let cmd: UInt8
        let subcmd: UInt8?
        let payload: Data
        let checksumOk: Bool
        let rawHex: String
    }

    struct WalkingPadParams {
        let maxSpeedRawTenths: UInt8
        let startSpeedRawTenths: UInt8
        let rawControllerUnit: UInt8
        let checksumOk: Bool
        let rawHex: String
    }

    /// Read-only controller parameters query. A zero key requests state and does
    /// not mutate any A6 preference.
    static func buildWalkingPadQueryParamsPacket() -> Data {
        Data([0xF7, 0xA6, 0x00, 0x00, 0x00, 0x00, 0x00, 0xA6, 0xFD])
    }

    static func parseWalkingPadParams(_ data: Data) -> WalkingPadParams? {
        guard data.count == 16,
              data[0] == 0xF8,
              data[1] == 0xA6,
              data[15] == 0xFD else {
            return nil
        }

        let checksumIndex = data.count - 2
        let expectedChecksum = data[checksumIndex]
        let computedChecksum = data[1..<checksumIndex].reduce(UInt16(0)) {
            ($0 + UInt16($1)) & 0xFF
        }

        return WalkingPadParams(
            maxSpeedRawTenths: data[7],
            startSpeedRawTenths: data[8],
            rawControllerUnit: data[13],
            checksumOk: UInt8(computedChecksum) == expectedChecksum,
            rawHex: hexString(data)
        )
    }

    static func buildFtmsRequestControlPacket() -> Data {
        Data([0x00])
    }

    static func buildFtmsStartOrResumePacket() -> Data {
        Data([0x07])
    }

    static func buildFtmsStopPacket() -> Data {
        Data([0x08, 0x01])
    }

    static func buildFtmsSetSpeedPacket(kmh: Double) -> Data {
        let raw = UInt16(max(0, min(65_535, (kmh * 100.0).rounded())))
        let lo = UInt8(raw & 0xFF)
        let hi = UInt8((raw >> 8) & 0xFF)
        return Data([0x02, lo, hi])
    }

    static func buildFitShowStartOrResumePacket() -> Data {
        buildFitShowFrame(cmd: 0x53, subcmd: 0x01, payload: Data([0x00]))
    }

    static func buildFitShowStopPacket() -> Data {
        buildFitShowFrame(cmd: 0x53, subcmd: 0x03, payload: Data())
    }

    static func buildFitShowSetSpeedPacket(kmh: Double, incline: UInt8) -> Data {
        let speedTenths = UInt8(max(0, min(250, Int((kmh * 10.0).rounded()))))
        return buildFitShowFrame(cmd: 0x53, subcmd: 0x02, payload: Data([speedTenths, incline]))
    }

    static func buildFitShowFrame(cmd: UInt8, subcmd: UInt8?, payload: Data) -> Data {
        var body: [UInt8] = [cmd]
        if let subcmd {
            body.append(subcmd)
        }
        body.append(contentsOf: payload)

        var checksum: UInt8 = 0
        for byte in body {
            checksum ^= byte
        }

        var out: [UInt8] = [0x02]
        out.append(contentsOf: body)
        out.append(checksum)
        out.append(0x03)
        return Data(out)
    }

    static func parseFtmsTreadmillData(_ data: Data) -> FtmsTreadmillData? {
        guard data.count >= 4 else { return nil }
        guard let rawSpeed = readUInt16LE(data, at: 2) else { return nil }
        let kmh = Double(rawSpeed) / 100.0
        return FtmsTreadmillData(instantaneousSpeedKmh: kmh, isMoving: kmh > 0.2)
    }

    static func parseFtmsSupportedSpeedRange(_ data: Data) -> FtmsSupportedSpeedRange? {
        guard data.count >= 6 else { return nil }
        guard let rawMin = readUInt16LE(data, at: 0),
              let rawMax = readUInt16LE(data, at: 2),
              let rawInc = readUInt16LE(data, at: 4) else {
            return nil
        }

        let minKmh = Double(rawMin) / 100.0
        let maxKmh = Double(rawMax) / 100.0
        let incKmh = Double(rawInc) / 100.0
        guard maxKmh >= minKmh, maxKmh > 0 else { return nil }

        return FtmsSupportedSpeedRange(
            minSpeedKmh: minKmh,
            maxSpeedKmh: maxKmh,
            minIncrementKmh: incKmh
        )
    }

    static func parseFtmsControlPointResponse(_ data: Data) -> FtmsControlPointResponse? {
        guard data.count >= 3, data[0] == 0x80 else { return nil }
        return FtmsControlPointResponse(requestedOpcode: data[1], resultCode: data[2])
    }

    static func parseFitShowFrame(_ data: Data) -> FitShowFrame? {
        guard data.count >= 4 else { return nil }
        guard data.first == 0x02, data.last == 0x03 else { return nil }

        let checksum = data[data.count - 2]
        let body = data[1..<(data.count - 2)]

        var computed: UInt8 = 0
        for byte in body {
            computed ^= byte
        }
        let checksumOk = computed == checksum

        let cmd = data[1]
        if cmd == 0x51 {
            let payload = data.count > 4 ? Data(data[2..<(data.count - 2)]) : Data()
            return FitShowFrame(
                cmd: cmd,
                subcmd: nil,
                payload: payload,
                checksumOk: checksumOk,
                rawHex: hexString(data)
            )
        }

        guard data.count >= 5 else { return nil }
        let subcmd = data[2]
        let payload = data.count > 5 ? Data(data[3..<(data.count - 2)]) : Data()
        return FitShowFrame(
            cmd: cmd,
            subcmd: subcmd,
            payload: payload,
            checksumOk: checksumOk,
            rawHex: hexString(data)
        )
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 1 < data.count else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
