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
    case unitsUnknown
    case paramsInvalid
}

enum TreadmillUnitsSafetyPolicy {
    static func allowsHrControl(_ state: TreadmillUnitsState) -> Bool {
        blockReason(for: state) == nil
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
        state.source == .queryParams
            && state.parseStatus.isValidQueryParamsRead
            && state.nativeUnits == .imperial
    }

    static func blockReason(for state: TreadmillUnitsState) -> TreadmillUnitsBlockReason? {
        guard state.source == .queryParams, state.parseStatus.isValidQueryParamsRead else {
            return state.source == .queryParams ? .paramsInvalid : .unitsUnknown
        }

        switch state.nativeUnits {
        case .metric:
            return nil
        case .imperial:
            return .imperialUnits
        case .unknown:
            return .unitsUnknown
        }
    }
}
