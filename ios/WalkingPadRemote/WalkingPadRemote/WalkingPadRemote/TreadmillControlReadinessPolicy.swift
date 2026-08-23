import Foundation

enum TreadmillControlProtocolKind: Equatable {
    case walkingPad
    case ftms
    case fitShow
    case unknown
}

enum TreadmillControlTransportRole: Equatable {
    case walkingPadTelemetry
    case walkingPadCommand
    case ftmsTelemetry
    case ftmsCommand
    case fitShowTelemetry
    case fitShowCommand
}

struct TreadmillControlConnectionIdentity: Equatable {
    let peripheralID: UUID
    let epoch: UUID
}

struct TreadmillControlTransportEvidence: Equatable {
    let role: TreadmillControlTransportRole
    let connection: TreadmillControlConnectionIdentity
    let isUsable: Bool
}

struct TreadmillControlReadinessSnapshot: Equatable {
    let currentConnection: TreadmillControlConnectionIdentity?
    let protocolKind: TreadmillControlProtocolKind
    let protocolConnection: TreadmillControlConnectionIdentity?
    let telemetry: TreadmillControlTransportEvidence?
    let command: TreadmillControlTransportEvidence?
}

enum TreadmillControlReadinessPolicy {
    static func isCurrentCallback(
        _ callbackConnection: TreadmillControlConnectionIdentity?,
        currentConnection: TreadmillControlConnectionIdentity?
    ) -> Bool {
        guard let currentConnection else { return false }
        return callbackConnection == currentConnection
    }

    static func isReady(_ snapshot: TreadmillControlReadinessSnapshot) -> Bool {
        guard let currentConnection = snapshot.currentConnection,
              snapshot.protocolConnection == currentConnection,
              let telemetry = snapshot.telemetry,
              telemetry.connection == currentConnection,
              telemetry.isUsable,
              let command = snapshot.command,
              command.connection == currentConnection,
              command.isUsable else {
            return false
        }

        switch snapshot.protocolKind {
        case .walkingPad:
            return telemetry.role == .walkingPadTelemetry
                && command.role == .walkingPadCommand
        case .ftms:
            return telemetry.role == .ftmsTelemetry
                && command.role == .ftmsCommand
        case .fitShow:
            return telemetry.role == .fitShowTelemetry
                && command.role == .fitShowCommand
        case .unknown:
            return false
        }
    }
}
