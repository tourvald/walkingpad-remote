import Foundation

enum TreadmillNativeUnits: String, Codable, Equatable {
    case metric
    case imperial
    case unknown

    init(rawControllerUnit: Int) {
        switch rawControllerUnit {
        case 0:
            self = .metric
        case 1:
            self = .imperial
        default:
            self = .unknown
        }
    }
}

enum TreadmillUnitsSource: String, Equatable {
    case queryParams
    case notRead
    case parseFailed
}

enum TreadmillUnitsParseStatus: String, Equatable {
    case validChecksum
    case failedChecksum
    case notRead
    case parseFailed

    var isValidQueryParamsRead: Bool {
        self == .validChecksum
    }
}

enum PhysicalSpeedConfidence: String, Equatable {
    case confirmedMetric
    case confirmedImperial
    case unknown
}

struct TreadmillUnitsState: Equatable {
    static let notRead = TreadmillUnitsState(
        nativeUnits: .unknown,
        source: .notRead,
        parseStatus: .notRead,
        readAt: nil,
        rawParamsHex: nil,
        physicalSpeedConfidence: .unknown
    )

    let nativeUnits: TreadmillNativeUnits
    let source: TreadmillUnitsSource
    let parseStatus: TreadmillUnitsParseStatus
    let readAt: Date?
    let rawParamsHex: String?
    let physicalSpeedConfidence: PhysicalSpeedConfidence

    init(
        nativeUnits: TreadmillNativeUnits,
        source: TreadmillUnitsSource,
        parseStatus: TreadmillUnitsParseStatus,
        readAt: Date?,
        rawParamsHex: String?,
        physicalSpeedConfidence: PhysicalSpeedConfidence = .unknown
    ) {
        self.nativeUnits = nativeUnits
        self.source = source
        self.parseStatus = parseStatus
        self.readAt = readAt
        self.rawParamsHex = rawParamsHex
        self.physicalSpeedConfidence = physicalSpeedConfidence
    }

    func withPhysicalSpeedConfidence(_ confidence: PhysicalSpeedConfidence) -> TreadmillUnitsState {
        TreadmillUnitsState(
            nativeUnits: nativeUnits,
            source: source,
            parseStatus: parseStatus,
            readAt: readAt,
            rawParamsHex: rawParamsHex,
            physicalSpeedConfidence: confidence
        )
    }
}

enum TreadmillUnitsBlockReason: String, Equatable {
    case imperialUnits
    case brokenImperialUnits = "broken_imperial_units"
    case manualStopAcknowledgementRequired
    case unitsUnknown
    case paramsInvalid
}

enum TreadmillStopSafetyStatus: String, Equatable {
    case ready
    case brokenImperialUnits = "broken_imperial_units"
    case unitsUnknown = "units_unknown"
    case paramsInvalid = "params_invalid"
}

enum TreadmillUnitsSafetyPolicy {
    static func allowsHrControl(_ state: TreadmillUnitsState) -> Bool {
        allowsHrControl(state, manualStopAcknowledged: false)
    }

    static func allowsHrControl(
        _ state: TreadmillUnitsState,
        manualStopAcknowledged: Bool
    ) -> Bool {
        blockReason(for: state, manualStopAcknowledged: manualStopAcknowledged) == nil
    }

    static func allowsDebugTestRun(_ state: TreadmillUnitsState) -> Bool {
        allowsDebugTestRun(state, confirmedNoLoadDiagnostic: false)
    }

    static func allowsDebugTestRun(
        _ state: TreadmillUnitsState,
        confirmedNoLoadDiagnostic: Bool
    ) -> Bool {
        if requiresNoLoadDiagnosticConfirmation(for: state) {
            return confirmedNoLoadDiagnostic
        }
        return blockReason(for: state) == nil
    }

    static func requiresNoLoadDiagnosticConfirmation(for state: TreadmillUnitsState) -> Bool {
        false
    }

    static func blockReason(for state: TreadmillUnitsState) -> TreadmillUnitsBlockReason? {
        blockReason(for: state, manualStopAcknowledged: false)
    }

    static func blockReason(
        for state: TreadmillUnitsState,
        manualStopAcknowledged: Bool
    ) -> TreadmillUnitsBlockReason? {
        guard state.source == .queryParams, state.parseStatus.isValidQueryParamsRead else {
            return state.source == .queryParams ? .paramsInvalid : .unitsUnknown
        }

        switch state.nativeUnits {
        case .metric:
            return nil
        case .imperial:
            return .brokenImperialUnits
        case .unknown:
            return .unitsUnknown
        }
    }
}

enum ControllerUnitsRecovery {
    enum ReadbackResult: String, Equatable {
        case success
        case unchanged
        case failed
        case noResponse = "no_response"
        case parseFailed = "parse_failed"
    }

    struct Command: Equatable {
        let targetUnits: TreadmillNativeUnits
        let packet: Data
        let label: String

        var packetHex: String {
            hex(packet)
        }
    }

    static let confirmationText = """
    This writes a persistent controller preference.
    Metric mode is required because imperial mode breaks stop on this treadmill.
    Use only if you understand this changes controller units.
    """

    static func productionCommand(to units: TreadmillNativeUnits) -> Command? {
        guard units == .metric,
              let packet = BLETransportCodec.buildWalkingPadUnitPreferencePacket(nativeUnits: .metric)
        else {
            return nil
        }
        return Command(
            targetUnits: .metric,
            packet: packet,
            label: "UNITS RECOVERY METRIC"
        )
    }

    static func stopSafetyStatus(for state: TreadmillUnitsState) -> TreadmillStopSafetyStatus {
        guard state.source == .queryParams, state.parseStatus.isValidQueryParamsRead else {
            return state.source == .queryParams ? .paramsInvalid : .unitsUnknown
        }

        switch state.nativeUnits {
        case .metric:
            return .ready
        case .imperial:
            return .brokenImperialUnits
        case .unknown:
            return .unitsUnknown
        }
    }

    static func shouldOfferManualRecovery(for state: TreadmillUnitsState) -> Bool {
        stopSafetyStatus(for: state) == .brokenImperialUnits
    }

    static func shouldAutoSwitchOnConnect(for state: TreadmillUnitsState) -> Bool {
        false
    }

    static func readbackResult(
        before: TreadmillUnitsState,
        after: TreadmillUnitsState?
    ) -> ReadbackResult {
        guard let after else { return .noResponse }
        guard after.source == .queryParams, after.parseStatus == .validChecksum else {
            return .parseFailed
        }
        if before.nativeUnits == .metric, after.nativeUnits == .metric {
            return .unchanged
        }
        return after.nativeUnits == .metric ? .success : .failed
    }

    static func startedFields(
        before: TreadmillUnitsState,
        connectedPeripheralID: UUID?,
        connectedPeripheralName: String
    ) -> [String: Any] {
        [
            "unit_before": before.nativeUnits.rawValue,
            "raw_params_hex": before.rawParamsHex ?? "",
            "checksum_ok": before.parseStatus == .validChecksum,
            "stop_safety_before": stopSafetyStatus(for: before).rawValue,
            "connected_peripheral_id": connectedPeripheralID?.uuidString ?? "",
            "connected_peripheral_name": connectedPeripheralName,
            "owner_approved_required": true
        ]
    }

    static func commandSentFields(command: Command) -> [String: Any] {
        [
            "packet_hex": command.packetHex,
            "target_units": command.targetUnits.rawValue,
            "command_family": "A6",
            "key": 8,
            "value": 0
        ]
    }

    static func readbackFields(
        before: TreadmillUnitsState,
        after: TreadmillUnitsState?,
        result: ReadbackResult
    ) -> [String: Any] {
        [
            "raw_params_hex": after?.rawParamsHex ?? "",
            "unit_before": before.nativeUnits.rawValue,
            "unit_after": after?.nativeUnits.rawValue ?? TreadmillNativeUnits.unknown.rawValue,
            "checksum_ok": after?.parseStatus == .validChecksum,
            "result": result.rawValue,
            "stop_safety_before": stopSafetyStatus(for: before).rawValue,
            "stop_safety_after": after.map { stopSafetyStatus(for: $0).rawValue } ?? TreadmillStopSafetyStatus.unitsUnknown.rawValue
        ]
    }

    static func finishedFields(
        before: TreadmillUnitsState,
        after: TreadmillUnitsState?,
        result: ReadbackResult,
        error: String?
    ) -> [String: Any] {
        [
            "unit_before": before.nativeUnits.rawValue,
            "unit_after": after?.nativeUnits.rawValue ?? TreadmillNativeUnits.unknown.rawValue,
            "result": result.rawValue,
            "error": error ?? "",
            "stop_safety_before": stopSafetyStatus(for: before).rawValue,
            "stop_safety_after": after.map { stopSafetyStatus(for: $0).rawValue } ?? TreadmillStopSafetyStatus.unitsUnknown.rawValue
        ]
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

enum UnitsControllerPreferencesDiagnostics {
    enum Action: String, CaseIterable, Equatable {
        case readControllerUnits = "read_controller_units"
        case setMetric = "set_metric"
        case setImperial = "set_imperial"
        case readBackVerify = "readback_verify"
        case clearState = "clear_state"

        var requiresConfirmation: Bool {
            switch self {
            case .setMetric, .setImperial:
                return true
            case .readControllerUnits, .readBackVerify, .clearState:
                return false
            }
        }
    }

    enum ReadbackResult: String, Equatable {
        case changed
        case unchanged
        case parseFailed = "parse_failed"
        case noResponse = "no_response"
    }

    struct Command: Equatable {
        let action: Action
        let packet: Data
        let label: String
        let commandFamily: String
        let key: Int?
        let value: Int?
        let dangerousDebug: Bool
        let testControllerRequired: Bool

        var packetHex: String {
            UnitsControllerPreferencesDiagnostics.hex(packet)
        }
    }

    static let dangerousConfirmationText = "This may write a persistent controller preference.\nUse only with the test controller installed.\nDo not use on a production controller."

    static func command(for action: Action) -> Command? {
        switch action {
        case .readControllerUnits:
            return queryCommand(action: action, label: "UNITS DEBUG READ PARAMS")
        case .setMetric:
            guard let packet = BLETransportCodec.buildWalkingPadUnitPreferencePacket(nativeUnits: .metric) else {
                return nil
            }
            return Command(
                action: action,
                packet: packet,
                label: "UNITS DEBUG METRIC",
                commandFamily: "A6",
                key: 8,
                value: 0,
                dangerousDebug: true,
                testControllerRequired: true
            )
        case .setImperial:
            guard let packet = BLETransportCodec.buildWalkingPadUnitPreferencePacket(nativeUnits: .imperial) else {
                return nil
            }
            return Command(
                action: action,
                packet: packet,
                label: "UNITS DEBUG IMPERIAL",
                commandFamily: "A6",
                key: 8,
                value: 1,
                dangerousDebug: true,
                testControllerRequired: true
            )
        case .readBackVerify:
            return queryCommand(action: action, label: "UNITS DEBUG READBACK")
        case .clearState:
            return nil
        }
    }

    static func isWhitelistedPacket(_ packet: Data) -> Bool {
        packet == BLETransportCodec.buildWalkingPadQueryParamsPacket()
            || packet == BLETransportCodec.buildWalkingPadUnitPreferencePacket(nativeUnits: .metric)
            || packet == BLETransportCodec.buildWalkingPadUnitPreferencePacket(nativeUnits: .imperial)
    }

    static func readbackResult(
        before: TreadmillUnitsState,
        after: TreadmillUnitsState?
    ) -> ReadbackResult {
        guard let after else { return .noResponse }
        guard after.source == .queryParams, after.parseStatus == .validChecksum else {
            return .parseFailed
        }
        return before.nativeUnits == after.nativeUnits ? .unchanged : .changed
    }

    static func actionStartedFields(
        action: Action,
        controllerState: String,
        currentUnitsState: TreadmillUnitsState,
        connectedPeripheralID: UUID?,
        connectedPeripheralName: String
    ) -> [String: Any] {
        [
            "action": action.rawValue,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "controller_state": controllerState,
            "current_units_state": currentUnitsState.nativeUnits.rawValue,
            "current_units_parse_status": currentUnitsState.parseStatus.rawValue,
            "last_query_params_raw_hex": currentUnitsState.rawParamsHex ?? "",
            "connected_peripheral_id": connectedPeripheralID?.uuidString ?? "",
            "connected_peripheral_name": connectedPeripheralName
        ]
    }

    static func commandSentFields(
        action: Action,
        command: Command,
        purpose: String
    ) -> [String: Any] {
        [
            "action": action.rawValue,
            "purpose": purpose,
            "packet_hex": command.packetHex,
            "command_family": command.commandFamily,
            "key": command.key ?? "",
            "value": command.value ?? "",
            "dangerous_debug": command.dangerousDebug,
            "test_controller_required": command.testControllerRequired
        ]
    }

    static func readbackFields(
        before: TreadmillUnitsState,
        after: TreadmillUnitsState?,
        result: ReadbackResult
    ) -> [String: Any] {
        [
            "raw_params_hex": after?.rawParamsHex ?? "",
            "unit_before": before.nativeUnits.rawValue,
            "unit_after": after?.nativeUnits.rawValue ?? TreadmillNativeUnits.unknown.rawValue,
            "checksum_ok": after?.parseStatus == .validChecksum,
            "changed": result == .changed,
            "result": result.rawValue
        ]
    }

    static func actionFinishedFields(
        action: Action,
        result: ReadbackResult,
        error: String?
    ) -> [String: Any] {
        [
            "action": action.rawValue,
            "result": result.rawValue,
            "error": error ?? ""
        ]
    }

    private static func queryCommand(action: Action, label: String) -> Command {
        Command(
            action: action,
            packet: BLETransportCodec.buildWalkingPadQueryParamsPacket(),
            label: label,
            commandFamily: "A6",
            key: nil,
            value: nil,
            dangerousDebug: false,
            testControllerRequired: false
        )
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
