import Foundation

enum BLETransportCodec {
    enum StopTruthExperimentCommandRole: String, CaseIterable, Codable {
        case queryParams = "query_params"
        case modeManual = "mode_manual"
        case baselineStart = "baseline_start"
        case speedRaw5 = "speed_raw_5"
        case initialStop = "initial_stop"
        case productionStopRecovery = "production_stop_recovery"
        case conditionalStopRetry = "conditional_stop_retry"
    }

    struct FtmsTreadmillData {
        let instantaneousSpeedRawHundredthsKmh: UInt16
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

    struct WalkingPadStatus {
        let beltState: Int
        let speedRawTenths: UInt8
        let manualMode: Int
        let timeSeconds: Int
        let distance10m: Int
        let steps: Int
        let appSpeedRawTenths: UInt8
        let lastButton: Int
        let checksumOk: Bool

        var speedKmh: Double { Double(speedRawTenths) / 10.0 }
        var appSpeedKmh: Double { Double(appSpeedRawTenths) / 10.0 }
    }

    /// Read-only controller parameters query. A zero key requests state and does
    /// not mutate any A6 preference.
    static func buildWalkingPadQueryParamsPacket() -> Data {
        Data([0xF7, 0xA6, 0x00, 0x00, 0x00, 0x00, 0x00, 0xA6, 0xFD])
    }

    static func buildStopTruthExperimentPacket(
        role: StopTruthExperimentCommandRole
    ) -> Data {
        switch role {
        case .queryParams:
            return buildWalkingPadQueryParamsPacket()
        case .modeManual:
            return buildWalkingPadCommandPacket(command: 0x02, value: 0x01)
        case .baselineStart, .productionStopRecovery:
            return buildWalkingPadCommandPacket(command: 0x04, value: 0x01)
        case .speedRaw5:
            return buildWalkingPadCommandPacket(command: 0x01, value: 0x05)
        case .initialStop, .conditionalStopRetry:
            return buildWalkingPadCommandPacket(command: 0x01, value: 0x00)
        }
    }

    static func validateStopTruthExperimentPacket(
        _ packet: Data,
        role: StopTruthExperimentCommandRole
    ) -> Bool {
        packet == buildStopTruthExperimentPacket(role: role)
    }

    private static func buildWalkingPadCommandPacket(command: UInt8, value: UInt8) -> Data {
        var bytes: [UInt8] = [0xF7, 0xA2, command, value, 0xFF, 0xFD]
        let checksum = (UInt16(0xA2) + UInt16(command) + UInt16(value)) & 0xFF
        bytes[4] = UInt8(checksum)
        return Data(bytes)
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

    static func parseWalkingPadStatus(_ data: Data) -> WalkingPadStatus? {
        guard data.count >= 20, data[0] == 0xF8, data[1] == 0xA2 else {
            return nil
        }

        return WalkingPadStatus(
            beltState: Int(data[2]),
            speedRawTenths: data[3],
            manualMode: Int(data[4]),
            timeSeconds: decode3ByteBE(data, start: 5),
            distance10m: decode3ByteBE(data, start: 8),
            steps: decode3ByteBE(data, start: 11),
            appSpeedRawTenths: data[14],
            lastButton: Int(data[16]),
            checksumOk: verifyWalkingPadChecksum(data)
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
        return FtmsTreadmillData(
            instantaneousSpeedRawHundredthsKmh: rawSpeed,
            instantaneousSpeedKmh: kmh,
            isMoving: kmh > 0.2
        )
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

    private static func decode3ByteBE(_ data: Data, start: Int) -> Int {
        guard data.count >= start + 3 else { return 0 }
        return (Int(data[start]) << 16) + (Int(data[start + 1]) << 8) + Int(data[start + 2])
    }

    private static func verifyWalkingPadChecksum(_ data: Data) -> Bool {
        guard data.count >= 3 else { return false }
        let checksumIndex = data.count - 2
        let expected = data[checksumIndex]
        let computed = data[1..<checksumIndex].reduce(UInt16(0)) {
            ($0 + UInt16($1)) & 0xFF
        }
        return UInt8(computed) == expected
    }

    private static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
