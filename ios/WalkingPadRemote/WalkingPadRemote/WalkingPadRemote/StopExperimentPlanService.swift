import Foundation

enum StopExperimentPlanService {
    static let baselineFreshnessSeconds: TimeInterval = 2.0
    static let maxBaselineSpeedRawTenths = 40
    static let accelerationMarginRawTenths = 2
    static let stoppedStates: Set<Int> = [0, 2, 5, 7, 9]

    enum Variant: String, CaseIterable {
        case speedZeroOnly = "speed-zero-only"
        case toggleOnly = "toggle-only"
    }

    struct Plan: Equatable {
        let variant: Variant
        let label: String
        let packet: [UInt8]

        var packetHex: String {
            packet.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
    }

    struct Command: Equatable {
        let label: String
        let packet: [UInt8]

        var packetHex: String {
            packet.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
    }

    struct UnifiedABPlan: Equatable {
        let variant: String
        let durationSeconds: Int
        let setupSpeedRawTenths: Int
        let setupCommands: [Command]
        let stopCommands: [Command]

        var allCommands: [Command] {
            setupCommands + stopCommands
        }
    }

    struct Sample: Equatable {
        let parseOK: Bool
        let checksumOK: Bool
        let state: Int
        let speedRawTenths: Int
        let ageSeconds: TimeInterval
    }

    enum BaselineError: String, Equatable {
        case invalidFE01 = "invalid_fe01"
        case staleBaseline = "stale_baseline"
        case stoppedBaseline = "stopped_baseline"
        case highSpeedBaseline = "high_speed_baseline"
    }

    enum Outcome: String, Equatable {
        case stopConfirmed = "STOP_CONFIRMED"
        case deceleratedButNotZero = "DECELERATED_BUT_NOT_ZERO"
        case stateStillRunning = "STATE_STILL_RUNNING"
        case commandCausedAcceleration = "COMMAND_CAUSED_ACCELERATION"
        case noFreshFE01 = "NO_FRESH_FE01"
    }

    enum UnifiedSecondAttemptReadiness: String, Equatable {
        case ready
        case stopAlreadyConfirmed
        case unsafeBaseline
        case acceleratedBaseline
    }

    static func plan(for variant: Variant) -> Plan {
        switch variant {
        case .speedZeroOnly:
            Plan(
                variant: variant,
                label: "SPEED ZERO ONLY",
                packet: [0xF7, 0xA2, 0x01, 0x00, 0xA3, 0xFD]
            )
        case .toggleOnly:
            Plan(
                variant: variant,
                label: "START/STOP TOGGLE ONLY",
                packet: [0xF7, 0xA2, 0x04, 0x01, 0xA7, 0xFD]
            )
        }
    }

    static func unifiedABPlan() -> UnifiedABPlan {
        UnifiedABPlan(
            variant: "unified-a-b",
            durationSeconds: 10,
            setupSpeedRawTenths: 8,
            setupCommands: [
                Command(label: "MODE MANUAL", packet: [0xF7, 0xA2, 0x02, 0x01, 0xA5, 0xFD]),
                Command(label: "START", packet: [0xF7, 0xA2, 0x04, 0x01, 0xA7, 0xFD]),
                Command(label: "SPEED raw=8", packet: [0xF7, 0xA2, 0x01, 0x08, 0xAB, 0xFD])
            ],
            stopCommands: [
                Command(label: "A SPEED ZERO ONLY", packet: [0xF7, 0xA2, 0x01, 0x00, 0xA3, 0xFD]),
                Command(label: "B START/STOP TOGGLE ONLY", packet: [0xF7, 0xA2, 0x04, 0x01, 0xA7, 0xFD])
            ]
        )
    }

    static func baselineError(sample: Sample) -> BaselineError? {
        guard sample.parseOK, sample.checksumOK else { return .invalidFE01 }
        guard sample.ageSeconds <= baselineFreshnessSeconds else { return .staleBaseline }
        guard sample.speedRawTenths > 0 else { return .stoppedBaseline }
        guard sample.speedRawTenths <= maxBaselineSpeedRawTenths else { return .highSpeedBaseline }
        return nil
    }

    static func classifyOutcome(
        baselineSpeedRawTenths: Int,
        latest: Sample?,
        maxAfterCommandSpeedRawTenths: Int?
    ) -> Outcome {
        guard let latest, latest.ageSeconds <= baselineFreshnessSeconds else {
            return .noFreshFE01
        }

        if let maxAfterCommandSpeedRawTenths,
           maxAfterCommandSpeedRawTenths > baselineSpeedRawTenths + accelerationMarginRawTenths {
            return .commandCausedAcceleration
        }

        if isStopConfirmed(sample: latest) {
            return .stopConfirmed
        }

        if latest.speedRawTenths > 0, latest.speedRawTenths < baselineSpeedRawTenths {
            return .deceleratedButNotZero
        }

        return .stateStillRunning
    }

    static func unifiedSecondAttemptReadiness(
        baselineSpeedRawTenths: Int,
        latest: Sample
    ) -> UnifiedSecondAttemptReadiness {
        if isStopConfirmed(sample: latest) {
            return .stopAlreadyConfirmed
        }

        if let error = baselineError(sample: latest) {
            return error == .stoppedBaseline ? .stopAlreadyConfirmed : .unsafeBaseline
        }

        if latest.speedRawTenths > baselineSpeedRawTenths + accelerationMarginRawTenths {
            return .acceleratedBaseline
        }

        return .ready
    }

    static func isStopConfirmed(sample: Sample) -> Bool {
        sample.parseOK
            && sample.checksumOK
            && sample.speedRawTenths == 0
            && stoppedStates.contains(sample.state)
    }
}
