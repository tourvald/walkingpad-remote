import Foundation

enum ControllerUnits: String, Equatable {
    case metric
    case imperial
    case unknown

    init(rawControllerUnit: UInt8) {
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

enum ControllerUnitsTruthStatus: String, Equatable {
    case notRead = "not_read"
    case valid
    case invalidChecksum = "invalid_checksum"
    case malformed
}

struct ControllerUnitsTruth: Equatable {
    static let disconnected = ControllerUnitsTruth(
        connectionEpoch: nil,
        units: .unknown,
        status: .notRead,
        observedAt: nil,
        rawHex: nil
    )

    let connectionEpoch: UUID?
    let units: ControllerUnits
    let status: ControllerUnitsTruthStatus
    let observedAt: Date?
    let rawHex: String?

    func age(at now: Date) -> TimeInterval? {
        observedAt.map { max(0, now.timeIntervalSince($0)) }
    }
}

struct ControllerUnitsTruthTracker {
    private(set) var state: ControllerUnitsTruth = .disconnected

    mutating func beginConnection(epoch: UUID) {
        state = ControllerUnitsTruth(
            connectionEpoch: epoch,
            units: .unknown,
            status: .notRead,
            observedAt: nil,
            rawHex: nil
        )
    }

    mutating func disconnect() {
        state = .disconnected
    }

    mutating func record(
        _ params: BLETransportCodec.WalkingPadParams,
        for connectionEpoch: UUID,
        at date: Date
    ) {
        guard state.connectionEpoch == connectionEpoch else { return }
        state = ControllerUnitsTruth(
            connectionEpoch: connectionEpoch,
            units: ControllerUnits(rawControllerUnit: params.rawControllerUnit),
            status: params.checksumOk ? .valid : .invalidChecksum,
            observedAt: date,
            rawHex: params.rawHex
        )
    }

    mutating func recordMalformed(rawHex: String, for connectionEpoch: UUID, at date: Date) {
        guard state.connectionEpoch == connectionEpoch else { return }
        state = ControllerUnitsTruth(
            connectionEpoch: connectionEpoch,
            units: .unknown,
            status: .malformed,
            observedAt: date,
            rawHex: rawHex
        )
    }
}

enum ControllerUnitsBlockReason: String, Equatable {
    case notRead = "units_not_read"
    case stale = "units_stale"
    case invalidChecksum = "units_invalid_checksum"
    case malformed = "units_malformed"
    case unknown = "units_unknown"
    case imperial = "units_imperial"

    var userMessage: String {
        switch self {
        case .notRead:
            return "Единицы контроллера ещё не подтверждены"
        case .stale:
            return "Данные о единицах контроллера устарели"
        case .invalidChecksum:
            return "Ответ контроллера об единицах не прошёл проверку"
        case .malformed:
            return "Ответ контроллера об единицах имеет неверный формат"
        case .unknown:
            return "Контроллер сообщил неизвестные единицы"
        case .imperial:
            return "Контроллер использует имперские единицы; автоматический запуск заблокирован"
        }
    }
}

struct ControllerUnitsGateDecision: Equatable {
    let path: ControllerAutomatedMotionPath
    let allowed: Bool
    let blockReason: ControllerUnitsBlockReason?
    let ageSeconds: TimeInterval?
}

struct ControllerUnitsDiagnosticSnapshot: Equatable {
    let status: ControllerUnitsTruthStatus
    let units: ControllerUnits
    let observedAt: Date?
    let ageSeconds: TimeInterval?
    let isFresh: Bool
    let gateAllowed: Bool
    let blockReason: ControllerUnitsBlockReason?
    let evidenceConnectionEpoch: UUID?
    let currentConnectionEpoch: UUID?
    let isCurrentConnection: Bool
    let rawHex: String?
    let byteCount: Int?

    static func capture(
        truth: ControllerUnitsTruth,
        currentConnectionEpoch: UUID?,
        now: Date,
        requiresFreshMetricTruth: Bool
    ) -> ControllerUnitsDiagnosticSnapshot {
        let decision = ControllerUnitsSafetyPolicy.evaluate(
            path: .testRun,
            state: truth,
            currentConnectionEpoch: currentConnectionEpoch,
            now: now,
            requiresFreshMetricTruth: requiresFreshMetricTruth
        )
        let isCurrentConnection = currentConnectionEpoch != nil
            && truth.connectionEpoch == currentConnectionEpoch
        let currentRawHex = isCurrentConnection ? truth.rawHex : nil
        let currentObservedAt = isCurrentConnection ? truth.observedAt : nil
        let age = isCurrentConnection ? truth.age(at: now) : nil
        let isFresh = isCurrentConnection
            && truth.status == .valid
            && (age.map { $0 <= ControllerUnitsSafetyPolicy.freshnessInterval } ?? false)
        return ControllerUnitsDiagnosticSnapshot(
            status: isCurrentConnection ? truth.status : .notRead,
            units: isCurrentConnection ? truth.units : .unknown,
            observedAt: currentObservedAt,
            ageSeconds: age,
            isFresh: isFresh,
            gateAllowed: decision.allowed,
            blockReason: decision.blockReason,
            evidenceConnectionEpoch: truth.connectionEpoch,
            currentConnectionEpoch: currentConnectionEpoch,
            isCurrentConnection: isCurrentConnection,
            rawHex: currentRawHex,
            byteCount: currentRawHex.flatMap(byteCount),
        )
    }

    var reportText: String {
        let formatter = ISO8601DateFormatter()
        let observed = observedAt.map(formatter.string(from:)) ?? "unavailable"
        let age = ageSeconds.map { String(format: "%.3f", $0) } ?? "unavailable"
        return [
            "WalkingPad controller units diagnostic",
            "status: \(status.rawValue)",
            "units: \(units.rawValue)",
            "observed_at: \(observed)",
            "age_s: \(age)",
            "freshness_limit_s: \(Int(ControllerUnitsSafetyPolicy.freshnessInterval))",
            "fresh: \(isFresh)",
            "test_run_gate_allowed: \(gateAllowed)",
            "block_reason: \(blockReason?.rawValue ?? "none")",
            "evidence_connection_epoch: \(evidenceConnectionEpoch?.uuidString ?? "unavailable")",
            "current_connection_epoch: \(currentConnectionEpoch?.uuidString ?? "unavailable")",
            "current_connection_context: \(isCurrentConnection)",
            "byte_count: \(byteCount.map(String.init) ?? "unavailable")",
            "raw_hex: \(rawHex ?? "unavailable")",
        ].joined(separator: "\n")
    }

    private static func byteCount(_ rawHex: String) -> Int? {
        let tokens = rawHex.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty,
              tokens.allSatisfy({ token in
                  token.count == 2 && token.allSatisfy(\.isHexDigit)
              }) else {
            return nil
        }
        return tokens.count
    }
}

enum ControllerUnitsRefreshTrigger: String, Equatable {
    case connectionReady = "connection_ready"
    case gateBlockedAuto = "gate_blocked_auto"
}

struct ControllerUnitsRefreshDecision: Equatable {
    let trigger: ControllerUnitsRefreshTrigger?

    var shouldRequest: Bool { trigger != nil }
}

enum ControllerUnitsRefreshPolicy {
    static let minimumQueryInterval: TimeInterval = 5

    static func initialQuery(
        transportReady: Bool,
        lastQueryAt: Date?,
        now: Date
    ) -> ControllerUnitsRefreshDecision {
        guard transportReady, throttleAllowsQuery(lastQueryAt: lastQueryAt, now: now) else {
            return ControllerUnitsRefreshDecision(trigger: nil)
        }
        return ControllerUnitsRefreshDecision(trigger: .connectionReady)
    }

    static func blockedStartRefresh(
        existingGatesAllowStart: Bool,
        isHrControlRunning: Bool,
        transportReady: Bool,
        unitsDecision: ControllerUnitsGateDecision,
        lastQueryAt: Date?,
        now: Date
    ) -> ControllerUnitsRefreshDecision {
        guard existingGatesAllowStart,
              !isHrControlRunning,
              transportReady,
              (unitsDecision.blockReason == .notRead || unitsDecision.blockReason == .stale),
              throttleAllowsQuery(lastQueryAt: lastQueryAt, now: now) else {
            return ControllerUnitsRefreshDecision(trigger: nil)
        }
        return ControllerUnitsRefreshDecision(trigger: .gateBlockedAuto)
    }

    static func throttleAllowsQuery(lastQueryAt: Date?, now: Date) -> Bool {
        guard let lastQueryAt else { return true }
        return now.timeIntervalSince(lastQueryAt) >= minimumQueryInterval
    }
}

struct ControllerUnitsResponseContext: Equatable {
    let peripheralID: UUID
    let connectionEpoch: UUID
    let notifyCharacteristicID: ObjectIdentifier

    func matches(
        currentPeripheralID: UUID?,
        currentConnectionEpoch: UUID?,
        currentNotifyCharacteristicID: ObjectIdentifier?
    ) -> Bool {
        peripheralID == currentPeripheralID
            && connectionEpoch == currentConnectionEpoch
            && notifyCharacteristicID == currentNotifyCharacteristicID
    }
}

enum ControllerAutomatedMotionPath: String, CaseIterable {
    case hrControl = "hr_control"
    case testRun = "test_run"
}

enum ControllerUnitsSafetyPolicy {
    static let freshnessInterval: TimeInterval = 30

    static func evaluate(
        path: ControllerAutomatedMotionPath,
        state: ControllerUnitsTruth,
        currentConnectionEpoch: UUID?,
        now: Date,
        requiresFreshMetricTruth: Bool
    ) -> ControllerUnitsGateDecision {
        guard requiresFreshMetricTruth else {
            return ControllerUnitsGateDecision(path: path, allowed: true, blockReason: nil, ageSeconds: state.age(at: now))
        }

        guard let currentConnectionEpoch,
              state.connectionEpoch == currentConnectionEpoch else {
            return ControllerUnitsGateDecision(path: path, allowed: false, blockReason: .notRead, ageSeconds: nil)
        }

        let age = state.age(at: now)
        switch state.status {
        case .notRead:
            return ControllerUnitsGateDecision(path: path, allowed: false, blockReason: .notRead, ageSeconds: age)
        case .invalidChecksum:
            return ControllerUnitsGateDecision(path: path, allowed: false, blockReason: .invalidChecksum, ageSeconds: age)
        case .malformed:
            return ControllerUnitsGateDecision(path: path, allowed: false, blockReason: .malformed, ageSeconds: age)
        case .valid:
            break
        }

        guard let age, age <= freshnessInterval else {
            return ControllerUnitsGateDecision(path: path, allowed: false, blockReason: .stale, ageSeconds: age)
        }

        switch state.units {
        case .metric:
            return ControllerUnitsGateDecision(path: path, allowed: true, blockReason: nil, ageSeconds: age)
        case .imperial:
            return ControllerUnitsGateDecision(path: path, allowed: false, blockReason: .imperial, ageSeconds: age)
        case .unknown:
            return ControllerUnitsGateDecision(path: path, allowed: false, blockReason: .unknown, ageSeconds: age)
        }
    }

    static func allowsStart(
        path: ControllerAutomatedMotionPath,
        existingGatesAllowStart: Bool,
        state: ControllerUnitsTruth,
        currentConnectionEpoch: UUID?,
        now: Date,
        requiresFreshMetricTruth: Bool
    ) -> Bool {
        existingGatesAllowStart && evaluate(
            path: path,
            state: state,
            currentConnectionEpoch: currentConnectionEpoch,
            now: now,
            requiresFreshMetricTruth: requiresFreshMetricTruth
        ).allowed
    }
}
