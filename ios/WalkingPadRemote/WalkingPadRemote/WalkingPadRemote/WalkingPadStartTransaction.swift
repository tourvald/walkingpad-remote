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

    static func plan(
        isStartTransactionInFlight: Bool,
        previousCommandedSpeedKmh: Double,
        factualObservation: FactualMotionObservation?,
        targetSpeedKmh: Double
    ) -> [ScheduledCommand] {
        guard !isStartTransactionInFlight else { return [] }
        if factualObservation?.isFreshCurrent == true,
           factualObservation?.motion == .moving {
            return [ScheduledCommand(command: .speed(targetSpeedKmh), delay: 0.2)]
        }
        let ownsStartPrerequisites = previousCommandedSpeedKmh <= 0.1
            || factualObservation?.isFreshCurrentStop == true
        if ownsStartPrerequisites {
            return [
                ScheduledCommand(command: .modeManual, delay: 0),
                ScheduledCommand(command: .start, delay: 0.2),
                ScheduledCommand(command: .speed(targetSpeedKmh), delay: 0.45),
            ]
        }
        return [ScheduledCommand(command: .speed(targetSpeedKmh), delay: 0.2)]
    }
}
