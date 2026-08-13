import Foundation

struct StopTruthExperimentSessionService {
    struct TimeoutPolicy: Equatable {
        let perRepetitionSeconds: TimeInterval
        let globalSeconds: TimeInterval

        init(perRepetitionSeconds: TimeInterval, globalSeconds: TimeInterval) {
            self.perRepetitionSeconds = perRepetitionSeconds
            self.globalSeconds = globalSeconds
        }

        var isValid: Bool {
            perRepetitionSeconds >= StopTruthExperimentPlanService.observationWindowSeconds
                + StopTruthExperimentPlanService.postWindowFreshnessDelaySeconds
                && globalSeconds >= perRepetitionSeconds * Double(StopTruthExperimentPlanService.plannedRepetitions)
        }
    }

    enum Marker: String, Codable {
        case moving = "MOVING"
        case stopped = "STOPPED"
        case abort = "ABORT"
    }

    struct MarkerEvidence: Equatable {
        let marker: Marker
        let repetition: Int
        let timestamp: StopTruthExperimentTimestamp
        let note: String
        let operatorHadVisibility: Bool
    }

    struct MotionInvocationEvidence: Equatable {
        let repetition: Int
        let timestamp: StopTruthExperimentTimestamp
    }

    enum Phase: Equatable {
        case disabled(reason: String)
        case preflight(repetition: Int)
        case stationaryReady(repetition: Int)
        case establishingMovingBaseline(repetition: Int)
        case movingReady(repetition: Int)
        case observingStop(repetition: Int)
        case postWindowFreshness(repetition: Int)
        case recoveryPause(completedRepetitions: Int)
        case completed
        case aborted
        case failed(reason: String)
    }

    let experimentID: UUID
    let context: StopTruthExperimentPlanService.Context
    let clockOriginID: UUID
    let timeoutPolicy: TimeoutPolicy
    private(set) var phase: Phase
    private(set) var reconnectCount = 0
    private(set) var markers: [MarkerEvidence] = []
    private(set) var a6BoundsEvidence: StopTruthExperimentPlanService.A6BoundsEvidence?
    private(set) var fe01Observations: [StopTruthExperimentPlanService.FE01Observation] = []
    private(set) var raw5Invocation: MotionInvocationEvidence?

    init(
        experimentID: UUID = UUID(),
        context: StopTruthExperimentPlanService.Context,
        clockOriginID: UUID,
        timeoutPolicy: TimeoutPolicy,
        buildIdentity: StopTruthExperimentBuildIdentity
    ) {
        self.experimentID = experimentID
        self.context = context
        self.clockOriginID = clockOriginID
        self.timeoutPolicy = timeoutPolicy
        if !buildIdentity.isEnabled {
            phase = .disabled(reason: "exact_build_identity_not_enabled")
        } else if !timeoutPolicy.isValid {
            phase = .disabled(reason: "invalid_timeout_policy")
        } else {
            phase = .preflight(repetition: 1)
        }
    }

    mutating func recordA6Bounds(_ evidence: StopTruthExperimentPlanService.A6BoundsEvidence) {
        guard evidence.context == context, evidence.observedAt.originID == clockOriginID else {
            fail("a6_context_or_clock_mismatch")
            return
        }
        a6BoundsEvidence = evidence
    }

    mutating func recordFE01(_ observation: StopTruthExperimentPlanService.FE01Observation) {
        guard observation.receivedAt.originID == clockOriginID else {
            fail("fe01_clock_origin_mismatch")
            return
        }
        if fe01Observations.count == StopObservationPolicy.maxStoredObservations {
            fe01Observations.removeFirst()
        }
        fe01Observations.append(observation)
    }

    mutating func acceptStationaryBaseline(clock: StopTruthExperimentClock, nowUptimeNanoseconds: UInt64) -> Bool {
        guard case .preflight(let repetition) = phase,
              reconnectCount == StopTruthExperimentPlanService.allowedReconnectCount,
              StopTruthExperimentPlanService.baselineSatisfied(
                observations: fe01Observations,
                kind: .stationary,
                currentContext: context,
                clock: clock,
                nowUptimeNanoseconds: nowUptimeNanoseconds
              ) else {
            return false
        }
        phase = .stationaryReady(repetition: repetition)
        return true
    }

    mutating func beginMovingBaseline() -> Bool {
        guard case .stationaryReady(let repetition) = phase else { return false }
        phase = .establishingMovingBaseline(repetition: repetition)
        return true
    }

    mutating func recordRaw5Invocation(timestamp: StopTruthExperimentTimestamp) {
        guard case .establishingMovingBaseline(let repetition) = phase,
              timestamp.originID == clockOriginID else {
            fail("raw5_invocation_phase_or_clock_mismatch")
            return
        }
        raw5Invocation = MotionInvocationEvidence(repetition: repetition, timestamp: timestamp)
    }

    mutating func acceptMovingBaseline(clock: StopTruthExperimentClock, nowUptimeNanoseconds: UInt64) -> Bool {
        guard case .establishingMovingBaseline(let repetition) = phase,
              let raw5Invocation,
              raw5Invocation.repetition == repetition,
              let movingMarker = markers.last(where: {
                $0.marker == .moving && $0.repetition == repetition
              }),
              movingMarker.operatorHadVisibility,
              movingMarker.timestamp.monotonicUptimeNanoseconds
                >= raw5Invocation.timestamp.monotonicUptimeNanoseconds,
              StopTruthExperimentPlanService.raw5IsAllowed(
                by: a6BoundsEvidence,
                currentContext: context,
                clock: clock,
                nowUptimeNanoseconds: nowUptimeNanoseconds,
                maximumAgeSeconds: StopTruthExperimentPlanService.a6FreshnessIntervalSeconds
              ),
              StopTruthExperimentPlanService.baselineSatisfied(
                observations: fe01Observations,
                kind: .movingRaw5(movingMarkerRecorded: true),
                currentContext: context,
                clock: clock,
                nowUptimeNanoseconds: nowUptimeNanoseconds
              ) else {
            return false
        }
        phase = .movingReady(repetition: repetition)
        return true
    }

    mutating func beginStopObservation() -> Bool {
        guard case .movingReady(let repetition) = phase else { return false }
        phase = .observingStop(repetition: repetition)
        return true
    }

    mutating func finishObservationWindow() -> Bool {
        guard case .observingStop(let repetition) = phase else { return false }
        phase = .postWindowFreshness(repetition: repetition)
        return true
    }

    mutating func finishPostWindowFreshness() -> Bool {
        guard case .postWindowFreshness(let repetition) = phase else { return false }
        phase = .recoveryPause(completedRepetitions: repetition)
        return true
    }

    mutating func beginNextRepetition() -> Bool {
        guard case .recoveryPause(let completed) = phase else { return false }
        if completed == StopTruthExperimentPlanService.plannedRepetitions {
            phase = .completed
            return true
        }
        guard completed < StopTruthExperimentPlanService.plannedRepetitions else {
            fail("repetition_bound_exceeded")
            return false
        }
        fe01Observations.removeAll()
        raw5Invocation = nil
        phase = .preflight(repetition: completed + 1)
        return true
    }

    mutating func recordMarker(
        _ marker: Marker,
        timestamp: StopTruthExperimentTimestamp,
        note: String,
        operatorHadVisibility: Bool
    ) -> Bool {
        guard timestamp.originID == clockOriginID else {
            fail("marker_clock_origin_mismatch")
            return false
        }
        guard let repetition = currentRepetition else { return false }
        if marker == .moving {
            guard case .establishingMovingBaseline = phase,
                  let raw5Invocation,
                  raw5Invocation.repetition == repetition,
                  timestamp.monotonicUptimeNanoseconds
                    >= raw5Invocation.timestamp.monotonicUptimeNanoseconds else {
                return false
            }
        }
        let evidence = MarkerEvidence(
            marker: marker,
            repetition: repetition,
            timestamp: timestamp,
            note: note,
            operatorHadVisibility: operatorHadVisibility
        )
        markers.append(evidence)
        if marker == .abort { phase = .aborted }
        return true
    }

    mutating func recordReconnect() {
        reconnectCount += 1
        fail("reconnect_forbidden")
    }

    mutating func fail(_ reason: String) {
        guard phase != .aborted, phase != .completed else { return }
        phase = .failed(reason: reason)
    }

    private var currentRepetition: Int? {
        switch phase {
        case .preflight(let repetition), .stationaryReady(let repetition),
             .establishingMovingBaseline(let repetition), .movingReady(let repetition),
             .observingStop(let repetition), .postWindowFreshness(let repetition):
            return repetition
        case .recoveryPause(let completedRepetitions):
            return completedRepetitions
        case .disabled, .completed, .aborted, .failed:
            return nil
        }
    }
}
