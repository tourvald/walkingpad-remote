import Foundation

enum TreadmillNativeUnits: String, Equatable {
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

struct TreadmillUnitsState: Equatable {
    static let notRead = TreadmillUnitsState(
        nativeUnits: .unknown,
        source: .notRead,
        parseStatus: .notRead,
        readAt: nil,
        rawParamsHex: nil
    )

    let nativeUnits: TreadmillNativeUnits
    let source: TreadmillUnitsSource
    let parseStatus: TreadmillUnitsParseStatus
    let readAt: Date?
    let rawParamsHex: String?
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
        blockReason(for: state) == nil
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
