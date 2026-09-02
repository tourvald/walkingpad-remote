import Foundation

enum WalkingPadStartTransaction {
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

    // Compose the existing Start branch only; readiness and safety stay with the caller.
    static func commands(
        shouldSendStart: Bool,
        targetSpeedKmh: Double
    ) -> [ScheduledCommand] {
        if shouldSendStart {
            return [
                ScheduledCommand(command: .modeManual, delay: 0),
                ScheduledCommand(command: .start, delay: 0.2),
                ScheduledCommand(command: .speed(targetSpeedKmh), delay: 0.45),
            ]
        }
        return [ScheduledCommand(command: .speed(targetSpeedKmh), delay: 0.2)]
    }
}
