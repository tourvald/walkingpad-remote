import Foundation

enum WalkingPadStartTransaction {
    enum ObservedMotion: Equatable {
        case stopped
        case moving
        case unknown
    }

    struct FactualMotionObservation: Equatable {
        let motion: ObservedMotion
        let ageSeconds: TimeInterval
        let isCurrentConnectionEpoch: Bool

        var isFreshCurrent: Bool {
            isCurrentConnectionEpoch
                && ageSeconds >= 0
                && ageSeconds <= StopObservationPolicy.freshnessInterval
        }

        var isFreshCurrentStop: Bool {
            isFreshCurrent && motion == .stopped
        }
    }

    enum Command: Equatable {
        case modeManual
        case start
        case speed(Double)

        var label: String {
            switch self {
            case .modeManual:
                return "MODE MANUAL"
            case .start:
                return "START"
            case .speed(let targetSpeedKmh):
                return String(format: "SPEED %.1f km/h", targetSpeedKmh)
            }
        }
    }

    struct ScheduledCommand: Equatable {
        let command: Command
        let delay: TimeInterval
    }

    enum BlockReason: String, Equatable {
        case startTransactionInFlight = "start_transaction_in_flight"
        case ambiguousMotion = "ambiguous_motion"
    }

    enum Plan: Equatable {
        case commands([ScheduledCommand])
        case blocked(BlockReason)
    }

    static func plan(
        isStartTransactionInFlight: Bool,
        factualObservation: FactualMotionObservation?,
        targetSpeedKmh: Double
    ) -> Plan {
        guard !isStartTransactionInFlight else {
            return .blocked(.startTransactionInFlight)
        }
        guard factualObservation?.isFreshCurrent == true else {
            return .blocked(.ambiguousMotion)
        }
        if factualObservation?.motion == .moving {
            return .commands([
                ScheduledCommand(command: .speed(targetSpeedKmh), delay: 0.2),
            ])
        }
        if factualObservation?.isFreshCurrentStop == true {
            return .commands([
                ScheduledCommand(command: .modeManual, delay: 0),
                ScheduledCommand(command: .start, delay: 0.2),
                ScheduledCommand(command: .speed(targetSpeedKmh), delay: 0.45),
            ])
        }
        return .blocked(.ambiguousMotion)
    }
}
