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

    static func isStopConfirmed(sample: Sample) -> Bool {
        sample.parseOK
            && sample.checksumOK
            && sample.speedRawTenths == 0
            && stoppedStates.contains(sample.state)
    }
}
