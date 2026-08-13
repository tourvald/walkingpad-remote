import Foundation

struct StopTruthExperimentStopEvaluation: Equatable {
    let result: StopObservationResult
    let reason: String
    let ageSeconds: TimeInterval?
    let isFresh: Bool
    let isCurrentlyConfirmed: Bool
}

struct StopTruthExperimentObservationService {
    private(set) var observations: [StopTruthExperimentPlanService.FE01Observation] = []
    private(set) var firstConfirmedAt: Date?
    private(set) var stopFirstConfirmedMonotonicUptimeNanoseconds: UInt64?
    private(set) var finalWindowEvaluation: StopTruthExperimentStopEvaluation?
    private(set) var postWindowFreshnessEvaluation: StopTruthExperimentStopEvaluation?

    let context: StopTruthExperimentPlanService.Context
    let stopInvokedAt: StopTruthExperimentTimestamp
    private let clockOriginID: UUID

    init(
        context: StopTruthExperimentPlanService.Context,
        stopInvokedAt: StopTruthExperimentTimestamp
    ) {
        self.context = context
        self.stopInvokedAt = stopInvokedAt
        self.clockOriginID = stopInvokedAt.originID
    }

    mutating func record(
        _ observation: StopTruthExperimentPlanService.FE01Observation,
        nowUptimeNanoseconds: UInt64
    ) -> StopTruthExperimentStopEvaluation {
        let evaluation = evaluate(observation, nowUptimeNanoseconds: nowUptimeNanoseconds)
        if observations.count == StopObservationPolicy.maxStoredObservations {
            observations.removeFirst()
        }
        observations.append(observation)
        if evaluation.isCurrentlyConfirmed, firstConfirmedAt == nil {
            firstConfirmedAt = observation.receivedAt.wallDate
            stopFirstConfirmedMonotonicUptimeNanoseconds = observation.receivedAt.monotonicUptimeNanoseconds
        }
        return evaluation
    }

    func currentEvaluation(nowUptimeNanoseconds: UInt64) -> StopTruthExperimentStopEvaluation {
        guard let observation = observations.last else {
            return result(.missingObservation, "no_post_stop_observation")
        }
        return evaluate(observation, nowUptimeNanoseconds: nowUptimeNanoseconds)
    }

    mutating func finalizeWindow(nowUptimeNanoseconds: UInt64) -> StopTruthExperimentStopEvaluation {
        let evaluation = currentEvaluation(nowUptimeNanoseconds: nowUptimeNanoseconds)
        finalWindowEvaluation = evaluation
        return evaluation
    }

    mutating func recordPostWindowFreshness(nowUptimeNanoseconds: UInt64) -> StopTruthExperimentStopEvaluation {
        let evaluation = currentEvaluation(nowUptimeNanoseconds: nowUptimeNanoseconds)
        postWindowFreshnessEvaluation = evaluation
        return evaluation
    }

    private func evaluate(
        _ observation: StopTruthExperimentPlanService.FE01Observation,
        nowUptimeNanoseconds: UInt64
    ) -> StopTruthExperimentStopEvaluation {
        guard observation.context == context else {
            return result(.wrongContext, "connection_or_notification_context_changed")
        }
        guard observation.receivedAt.originID == clockOriginID,
              stopInvokedAt.originID == clockOriginID else {
            return result(.stale, "monotonic_origin_mismatch")
        }
        guard observation.receivedAt.monotonicUptimeNanoseconds >= stopInvokedAt.monotonicUptimeNanoseconds else {
            return result(.beforeCommand, "observation_predates_initial_stop_write")
        }
        guard nowUptimeNanoseconds >= observation.receivedAt.monotonicUptimeNanoseconds else {
            return result(.stale, "impossible_negative_monotonic_age")
        }
        let age = Double(nowUptimeNanoseconds - observation.receivedAt.monotonicUptimeNanoseconds) / 1_000_000_000
        guard age <= StopObservationPolicy.freshnessInterval else {
            return result(.stale, "observation_stale", age: age)
        }
        guard observation.checksumValid else {
            return result(.invalidChecksum, "checksum_invalid", age: age, fresh: true)
        }
        guard let speed = observation.speedRawTenths else {
            return result(.missingSpeed, "device_speed_missing", age: age, fresh: true)
        }
        guard let state = observation.state else {
            return result(.missingState, "device_state_missing", age: age, fresh: true)
        }
        let accepted = StopObservationPolicy.acceptedNonRunningStates.contains(state)
        if speed == 0, accepted {
            return result(.confirmed, "fresh_zero_and_non_running_state", age: age, fresh: true, confirmed: true)
        }
        if speed == 0 || accepted {
            return result(.contradictory, "speed_state_contradiction", age: age, fresh: true)
        }
        return result(.moving, "device_reports_nonzero_speed", age: age, fresh: true)
    }

    private func result(
        _ value: StopObservationResult,
        _ reason: String,
        age: TimeInterval? = nil,
        fresh: Bool = false,
        confirmed: Bool = false
    ) -> StopTruthExperimentStopEvaluation {
        StopTruthExperimentStopEvaluation(
            result: value,
            reason: reason,
            ageSeconds: age,
            isFresh: fresh,
            isCurrentlyConfirmed: confirmed
        )
    }
}
