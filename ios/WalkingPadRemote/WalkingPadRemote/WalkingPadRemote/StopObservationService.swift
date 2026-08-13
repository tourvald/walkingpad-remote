import Foundation

enum StopObservationPolicy {
    // Extracted read-only from safety/units-gate-with-queryparams
    // StopExperimentPlanService (commit 75ca9ed): maximum FE01 evidence age.
    static let freshnessInterval: TimeInterval = 2.0
    // Extracted read-only from stop-forensics commit 3ce7471: bounded snapshots
    // at 0.5/1.5/3/5/8/15/30 seconds, ending at 30 seconds.
    static let observationWindow: TimeInterval = 30.0
    static let checkpointDelays: [TimeInterval] = [0.5, 1.5, 3.0, 5.0, 8.0, 15.0, 30.0]
    static let maxStoredObservations = 256
    // Extracted read-only from safety/units-gate-with-queryparams
    // StopExperimentPlanService (commit 75ca9ed); do not expand without evidence.
    static let acceptedNonRunningStates: Set<Int> = [0, 2, 5, 7, 9]
}

struct StopObservationContext: Equatable {
    let peripheralID: UUID
    let connectionEpoch: UUID
    let notificationStreamID: UUID?
}

enum StopObservationResult: String, Equatable {
    case confirmed
    case moving
    case contradictory
    case stale
    case missingObservation = "missing_observation"
    case missingSpeed = "missing_speed"
    case missingState = "missing_state"
    case invalidChecksum = "invalid_checksum"
    case wrongContext = "wrong_context"
    case beforeAttempt = "before_attempt"
    case commandNotSent = "command_not_sent"
    case beforeCommand = "before_command"
}

enum StopObservationFinalResult: String, Equatable {
    case confirmed
    case unconfirmed
    case timeoutUnconfirmed = "timeout_unconfirmed"
}

struct StopDeviceObservation: Equatable {
    let sequence: Int
    let observedAt: Date
    let speedRawTenths: Int?
    let state: Int?
    let checksumValid: Bool
    let context: StopObservationContext
}

struct StopObservationEvaluation: Equatable {
    let result: StopObservationResult
    let reason: String
    let ageSeconds: TimeInterval?
    let isFresh: Bool
    let isConfirmed: Bool
}

struct StopObservationLifecycle {
    let attemptID: UUID
    let source: String
    let attemptedAt: Date
    let context: StopObservationContext

    private(set) var observations: [StopDeviceObservation] = []
    private(set) var commandSentAt: Date?
    private(set) var firstConfirmedAt: Date?
    private(set) var finalizedAt: Date?
    private(set) var finalResult: StopObservationFinalResult?
    private(set) var finalReason: String?
    private var nextSequence = 1

    init(
        attemptID: UUID,
        source: String,
        attemptedAt: Date,
        context: StopObservationContext
    ) {
        self.attemptID = attemptID
        self.source = source
        self.attemptedAt = attemptedAt
        self.context = context
    }

    var deadline: Date {
        attemptedAt.addingTimeInterval(StopObservationPolicy.observationWindow)
    }

    var commandStatus: String {
        if commandSentAt != nil {
            return "sent"
        }
        return finalResult == nil ? "queued" : "not_sent"
    }

    mutating func markCommandSent(at sentAt: Date) {
        commandSentAt = commandSentAt ?? sentAt
    }

    mutating func record(
        speedRawTenths: Int?,
        state: Int?,
        checksumValid: Bool,
        context observationContext: StopObservationContext,
        observedAt: Date,
        evaluatedAt: Date
    ) -> StopObservationEvaluation {
        let observation = StopDeviceObservation(
            sequence: nextSequence,
            observedAt: observedAt,
            speedRawTenths: speedRawTenths,
            state: state,
            checksumValid: checksumValid,
            context: observationContext
        )
        let evaluation = Self.evaluate(
            observation,
            attemptAt: attemptedAt,
            commandSentAt: commandSentAt,
            expectedContext: context,
            now: evaluatedAt
        )

        guard evaluation.result != .wrongContext,
              evaluation.result != .beforeAttempt,
              evaluation.result != .commandNotSent,
              evaluation.result != .beforeCommand,
              finalResult == nil else {
            return evaluation
        }

        nextSequence += 1
        if observations.count == StopObservationPolicy.maxStoredObservations {
            observations.removeFirst()
        }
        observations.append(observation)

        if evaluation.isConfirmed {
            firstConfirmedAt = firstConfirmedAt ?? observedAt
        }
        return evaluation
    }

    func currentEvaluation(at now: Date) -> StopObservationEvaluation {
        guard let latest = observations.last else {
            return StopObservationEvaluation(
                result: .missingObservation,
                reason: "no_post_stop_observation",
                ageSeconds: nil,
                isFresh: false,
                isConfirmed: false
            )
        }
        return Self.evaluate(
            latest,
            attemptAt: attemptedAt,
            commandSentAt: commandSentAt,
            expectedContext: context,
            now: now
        )
    }

    mutating func finalizeTimeout(at now: Date) -> StopObservationEvaluation {
        let evaluation = currentEvaluation(at: now)
        finalizedAt = now
        if evaluation.isConfirmed {
            finalResult = .confirmed
            finalReason = "fresh_zero_and_non_running_state_at_window_end"
        } else {
            finalResult = .timeoutUnconfirmed
            finalReason = Self.timeoutReason(for: evaluation)
        }
        return evaluation
    }

    mutating func finalizeUnconfirmed(at now: Date, reason: String) -> StopObservationEvaluation {
        let evaluation = currentEvaluation(at: now)
        finalizedAt = now
        finalResult = .unconfirmed
        finalReason = reason
        return evaluation
    }

    static func evaluate(
        _ observation: StopDeviceObservation,
        attemptAt: Date,
        commandSentAt: Date? = nil,
        expectedContext: StopObservationContext,
        now: Date
    ) -> StopObservationEvaluation {
        guard observation.context == expectedContext else {
            return evaluation(.wrongContext, reason: "connection_or_notification_context_changed")
        }
        guard observation.observedAt >= attemptAt else {
            return evaluation(.beforeAttempt, reason: "observation_predates_attempt")
        }
        guard let commandSentAt else {
            return evaluation(.commandNotSent, reason: "initial_stop_command_not_sent")
        }
        guard observation.observedAt >= commandSentAt else {
            return evaluation(.beforeCommand, reason: "observation_predates_initial_stop_write")
        }

        let age = max(0, now.timeIntervalSince(observation.observedAt))
        guard age <= StopObservationPolicy.freshnessInterval else {
            return evaluation(.stale, reason: "observation_stale", age: age)
        }
        guard observation.checksumValid else {
            return evaluation(.invalidChecksum, reason: "checksum_invalid", age: age, fresh: true)
        }
        guard let speed = observation.speedRawTenths else {
            return evaluation(.missingSpeed, reason: "device_speed_missing", age: age, fresh: true)
        }
        guard let state = observation.state else {
            return evaluation(.missingState, reason: "device_state_missing", age: age, fresh: true)
        }

        let acceptedState = StopObservationPolicy.acceptedNonRunningStates.contains(state)
        if speed == 0, acceptedState {
            return evaluation(
                .confirmed,
                reason: "fresh_zero_and_non_running_state",
                age: age,
                fresh: true,
                confirmed: true
            )
        }
        if speed == 0 {
            return evaluation(.contradictory, reason: "zero_speed_with_running_or_unknown_state", age: age, fresh: true)
        }
        if acceptedState {
            return evaluation(.contradictory, reason: "nonzero_speed_with_non_running_state", age: age, fresh: true)
        }
        return evaluation(.moving, reason: "device_reports_nonzero_speed", age: age, fresh: true)
    }

    private static func timeoutReason(for evaluation: StopObservationEvaluation) -> String {
        switch evaluation.result {
        case .moving:
            return "moving_at_timeout"
        case .contradictory:
            return "contradictory_at_timeout"
        case .stale:
            return "stale_at_timeout"
        case .missingObservation:
            return "no_post_stop_observation"
        case .missingSpeed:
            return "missing_speed_at_timeout"
        case .missingState:
            return "missing_state_at_timeout"
        case .invalidChecksum:
            return "invalid_checksum_at_timeout"
        case .wrongContext:
            return "connection_context_changed"
        case .beforeAttempt:
            return "no_current_attempt_observation"
        case .commandNotSent:
            return "initial_stop_command_not_sent"
        case .beforeCommand:
            return "no_post_command_observation"
        case .confirmed:
            return ""
        }
    }

    private static func evaluation(
        _ result: StopObservationResult,
        reason: String,
        age: TimeInterval? = nil,
        fresh: Bool = false,
        confirmed: Bool = false
    ) -> StopObservationEvaluation {
        StopObservationEvaluation(
            result: result,
            reason: reason,
            ageSeconds: age,
            isFresh: fresh,
            isConfirmed: confirmed
        )
    }
}
