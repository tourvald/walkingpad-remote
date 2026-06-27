import Foundation

enum TreadmillPhysicalSemantics: String, Codable, Equatable {
    case confirmedImperial
    case confirmedMetric
    case unknown

    var confidence: PhysicalSpeedConfidence {
        switch self {
        case .confirmedImperial:
            return .confirmedImperial
        case .confirmedMetric:
            return .confirmedMetric
        case .unknown:
            return .unknown
        }
    }
}

enum TreadmillPhysicalSemanticsSource: String, Codable, Equatable {
    case operatorVisualConfirmation = "operator_visual_confirmation"
}

struct TreadmillPhysicalSemanticsFingerprint: Codable, Equatable {
    let peripheralId: UUID
    let peripheralName: String
    let protocolName: String
    let controllerParamsRawHex: String
    let controllerUnitPref: TreadmillNativeUnits
    let controllerParamsChecksumOk: Bool

    func isCompatible(with other: TreadmillPhysicalSemanticsFingerprint) -> Bool {
        peripheralId == other.peripheralId
            && protocolName == other.protocolName
            && controllerParamsChecksumOk
            && other.controllerParamsChecksumOk
            && controllerUnitPref == .imperial
            && other.controllerUnitPref == .imperial
            && controllerParamsRawHex == other.controllerParamsRawHex
    }
}

struct TreadmillPhysicalSemanticsConfirmation: Codable, Equatable {
    let fingerprint: TreadmillPhysicalSemanticsFingerprint
    let semantics: TreadmillPhysicalSemantics
    let source: TreadmillPhysicalSemanticsSource
    let confirmedAt: Date
    let diagnosticSessionId: String
    let diagnosticProfile: String
    let rawTenths: Int
    let nativeCommand: Double
}

final class TreadmillPhysicalSemanticsConfirmationStore {
    private let defaults: UserDefaults
    private let storeKey = "treadmill_physical_semantics_confirmations_v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func confirmation(for peripheralId: UUID) -> TreadmillPhysicalSemanticsConfirmation? {
        load()[peripheralId.uuidString]
    }

    func save(_ confirmation: TreadmillPhysicalSemanticsConfirmation) {
        var confirmations = load()
        confirmations[confirmation.fingerprint.peripheralId.uuidString] = confirmation
        save(confirmations)
    }

    func clear(peripheralId: UUID) {
        var confirmations = load()
        confirmations.removeValue(forKey: peripheralId.uuidString)
        save(confirmations)
    }

    private func load() -> [String: TreadmillPhysicalSemanticsConfirmation] {
        guard let data = defaults.data(forKey: storeKey),
              let confirmations = try? JSONDecoder().decode([String: TreadmillPhysicalSemanticsConfirmation].self, from: data) else {
            return [:]
        }
        return confirmations
    }

    private func save(_ confirmations: [String: TreadmillPhysicalSemanticsConfirmation]) {
        if let data = try? JSONEncoder().encode(confirmations) {
            defaults.set(data, forKey: storeKey)
        }
    }
}

enum TreadmillPhysicalSemanticsConfirmationResolver {
    static func resolvedUnitsState(
        _ state: TreadmillUnitsState,
        confirmation: TreadmillPhysicalSemanticsConfirmation?,
        currentFingerprint: TreadmillPhysicalSemanticsFingerprint?
    ) -> TreadmillUnitsState {
        guard state.source == .queryParams,
              state.parseStatus.isValidQueryParamsRead,
              state.nativeUnits == .imperial,
              let confirmation,
              let currentFingerprint,
              confirmation.fingerprint.isCompatible(with: currentFingerprint) else {
            return state.withPhysicalSpeedConfidence(.unknown)
        }

        return state.withPhysicalSpeedConfidence(confirmation.semantics.confidence)
    }
}
