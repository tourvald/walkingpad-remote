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
                + StopTruthExperimentPlanService.minimumRecoveryPauseSeconds
                && globalSeconds >= perRepetitionSeconds * Double(StopTruthExperimentPlanService.plannedRepetitions)
        }
    }

    enum Marker: String, Codable {
        case moving = "MOVING"
        case stopped = "STOPPED"
        case abort = "ABORT"
    }

    enum MarkerRole: String, Codable {
        case movingBaseline = "moving_baseline"
        case firstPhysicalStop = "first_physical_stop"
        case recoveryStationaryConfirmation = "recovery_stationary_confirmation"
        case operatorAbort = "operator_abort"
    }

    struct MarkerEvidence: Equatable {
        let marker: Marker
        let role: MarkerRole
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
    private(set) var baselineStartInvocation: MotionInvocationEvidence?
    private(set) var raw5Invocation: MotionInvocationEvidence?
    private(set) var initialStopInvocation: MotionInvocationEvidence?
    private(set) var movingBaselineQualifiedAtUptimeNanoseconds: UInt64?
    private(set) var cumulativeMotionDurationSeconds: TimeInterval = 0
    private(set) var physicalCutoffRequired = false
    private(set) var terminalReason: String?
    private(set) var motionCapableInvocationOccurred = false
    private(set) var positiveSafeRecoveryEstablished = false
    private var recoveryPauseStartedAt: StopTruthExperimentTimestamp?
    private var executorQuiescentForRecovery = false
    private var renewedMotionAfterStop = false

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

    mutating func recordMotionCapableInvocation(
        role: BLETransportCodec.StopTruthExperimentCommandRole,
        timestamp: StopTruthExperimentTimestamp
    ) {
        guard role == .baselineStart || role == .speedRaw5 || role == .productionStopRecovery else {
            return
        }
        motionCapableInvocationOccurred = true
        positiveSafeRecoveryEstablished = false
        if isTerminal {
            physicalCutoffRequired = true
            return
        }
        guard timestamp.originID == clockOriginID, let repetition = currentRepetition else {
            fail("motion_invocation_context_or_clock_mismatch")
            return
        }
        if role == .baselineStart, baselineStartInvocation == nil {
            baselineStartInvocation = .init(repetition: repetition, timestamp: timestamp)
        }
    }

    mutating func recordRaw5Invocation(timestamp: StopTruthExperimentTimestamp) {
        guard case .establishingMovingBaseline(let repetition) = phase,
              timestamp.originID == clockOriginID else {
            fail("raw5_invocation_phase_or_clock_mismatch")
            return
        }
        if raw5Invocation == nil {
            raw5Invocation = MotionInvocationEvidence(repetition: repetition, timestamp: timestamp)
        }
    }

    mutating func refreshMovingBaselineQualification(
        clock: StopTruthExperimentClock,
        nowUptimeNanoseconds: UInt64
    ) -> Bool {
        if movingBaselineQualifiedAtUptimeNanoseconds != nil { return true }
        guard case .establishingMovingBaseline(let repetition) = phase,
              let baselineStartInvocation,
              baselineStartInvocation.repetition == repetition,
              let raw5Invocation,
              raw5Invocation.repetition == repetition,
              let movingMarker = authoritativeMarker(role: .movingBaseline, repetition: repetition),
              movingMarker.operatorHadVisibility,
              movingMarker.timestamp.monotonicUptimeNanoseconds >= raw5Invocation.timestamp.monotonicUptimeNanoseconds,
              within(
                nowUptimeNanoseconds,
                deadlineAfter: baselineStartInvocation.timestamp,
                seconds: StopTruthExperimentPlanService.movingBaselineDeadlineAfterBaselineStartSeconds
              ),
              within(
                nowUptimeNanoseconds,
                deadlineAfter: raw5Invocation.timestamp,
                seconds: StopTruthExperimentPlanService.movingBaselineDeadlineAfterRaw5Seconds
              ),
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
        movingBaselineQualifiedAtUptimeNanoseconds = nowUptimeNanoseconds
        return true
    }

    mutating func acceptMovingBaseline(clock: StopTruthExperimentClock, nowUptimeNanoseconds: UInt64) -> Bool {
        guard refreshMovingBaselineQualification(clock: clock, nowUptimeNanoseconds: nowUptimeNanoseconds),
              case .establishingMovingBaseline(let repetition) = phase else {
            return false
        }
        phase = .movingReady(repetition: repetition)
        return true
    }

    func canAttemptInitialStop(nowUptimeNanoseconds: UInt64) -> Bool {
        guard case .movingReady(let repetition) = phase,
              let moving = authoritativeMarker(role: .movingBaseline, repetition: repetition) else {
            return false
        }
        return stopTimingIsWithinBound(
            stopUptimeNanoseconds: nowUptimeNanoseconds,
            movingUptimeNanoseconds: moving.timestamp.monotonicUptimeNanoseconds
        )
    }

    func canInvokeInitialStop(nowUptimeNanoseconds: UInt64) -> Bool {
        guard case .observingStop(let repetition) = phase,
              let moving = authoritativeMarker(role: .movingBaseline, repetition: repetition) else {
            return false
        }
        return stopTimingIsWithinBound(
            stopUptimeNanoseconds: nowUptimeNanoseconds,
            movingUptimeNanoseconds: moving.timestamp.monotonicUptimeNanoseconds
        )
    }

    mutating func beginStopObservation() -> Bool {
        guard case .movingReady(let repetition) = phase else { return false }
        phase = .observingStop(repetition: repetition)
        return true
    }

    mutating func recordInitialStopInvocation(timestamp: StopTruthExperimentTimestamp) -> Bool {
        guard case .observingStop(let repetition) = phase,
              timestamp.originID == clockOriginID,
              let moving = authoritativeMarker(role: .movingBaseline, repetition: repetition),
              stopTimingIsWithinBound(
                stopUptimeNanoseconds: timestamp.monotonicUptimeNanoseconds,
                movingUptimeNanoseconds: moving.timestamp.monotonicUptimeNanoseconds
              ) else {
            return false
        }
        if initialStopInvocation == nil {
            initialStopInvocation = .init(repetition: repetition, timestamp: timestamp)
        }
        return true
    }

    mutating func finishObservationWindow() -> Bool {
        guard case .observingStop(let repetition) = phase,
              authoritativeMarker(role: .firstPhysicalStop, repetition: repetition) != nil else {
            return false
        }
        phase = .postWindowFreshness(repetition: repetition)
        return true
    }

    mutating func finishPostWindowFreshness(
        timestamp: StopTruthExperimentTimestamp,
        executorQuiescent: Bool
    ) -> Bool {
        guard case .postWindowFreshness(let repetition) = phase,
              timestamp.originID == clockOriginID,
              executorQuiescent else {
            return false
        }
        recoveryPauseStartedAt = timestamp
        executorQuiescentForRecovery = true
        phase = .recoveryPause(completedRepetitions: repetition)
        return true
    }

    mutating func beginNextRepetition(
        clock: StopTruthExperimentClock,
        nowUptimeNanoseconds: UInt64,
        executorQuiescent: Bool
    ) -> Bool {
        guard case .recoveryPause(let completed) = phase,
              let recoveryPauseStartedAt,
              let pauseAge = clock.ageSeconds(
                since: recoveryPauseStartedAt,
                nowUptimeNanoseconds: nowUptimeNanoseconds
              ),
              pauseAge >= StopTruthExperimentPlanService.minimumRecoveryPauseSeconds,
              executorQuiescent,
              executorQuiescentForRecovery,
              !renewedMotionAfterStop,
              authoritativeMarker(role: .firstPhysicalStop, repetition: completed) != nil,
              let recoveryMarker = authoritativeMarker(
                role: .recoveryStationaryConfirmation,
                repetition: completed
              ),
              let latestStationaryObservation = fe01Observations.last,
              recoveryMarker.timestamp.monotonicUptimeNanoseconds
                >= latestStationaryObservation.receivedAt.monotonicUptimeNanoseconds,
              StopTruthExperimentPlanService.baselineSatisfied(
                observations: fe01Observations,
                kind: .stationary,
                currentContext: context,
                clock: clock,
                nowUptimeNanoseconds: nowUptimeNanoseconds
              ) else {
            return false
        }
        positiveSafeRecoveryEstablished = true
        if completed == StopTruthExperimentPlanService.plannedRepetitions {
            phase = .completed
            return true
        }
        guard completed < StopTruthExperimentPlanService.plannedRepetitions else {
            fail("repetition_bound_exceeded")
            return false
        }
        resetForNextRepetition()
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
        switch marker {
        case .moving:
            if initialStopInvocation != nil {
                renewedMotionAfterStop = true
                fail("renewed_moving_after_initial_stop")
                return false
            }
            guard case .establishingMovingBaseline = phase,
                  operatorHadVisibility,
                  authoritativeMarker(role: .movingBaseline, repetition: repetition) == nil,
                  let raw5Invocation,
                  raw5Invocation.repetition == repetition,
                  timestamp.monotonicUptimeNanoseconds >= raw5Invocation.timestamp.monotonicUptimeNanoseconds else {
                return false
            }
            markers.append(.init(
                marker: marker,
                role: .movingBaseline,
                repetition: repetition,
                timestamp: timestamp,
                note: note,
                operatorHadVisibility: operatorHadVisibility
            ))
            return true
        case .stopped:
            return recordStoppedMarker(
                repetition: repetition,
                timestamp: timestamp,
                note: note,
                operatorHadVisibility: operatorHadVisibility
            )
        case .abort:
            markers.append(.init(
                marker: marker,
                role: .operatorAbort,
                repetition: repetition,
                timestamp: timestamp,
                note: note,
                operatorHadVisibility: operatorHadVisibility
            ))
            abort(note)
            return true
        }
    }

    mutating func recordReconnect() {
        reconnectCount += 1
        fail("reconnect_forbidden")
    }

    mutating func abort(_ reason: String) {
        guard !isTerminal else { return }
        terminalReason = reason
        applyTerminalCutoffPolicy()
        phase = .aborted
    }

    mutating func fail(_ reason: String) {
        guard !isTerminal else { return }
        terminalReason = reason
        applyTerminalCutoffPolicy()
        phase = .failed(reason: reason)
    }

    func hasFirstPhysicalStopForCurrentRepetition() -> Bool {
        guard let repetition = currentRepetition else { return false }
        return authoritativeMarker(role: .firstPhysicalStop, repetition: repetition) != nil
    }

    private mutating func recordStoppedMarker(
        repetition: Int,
        timestamp: StopTruthExperimentTimestamp,
        note: String,
        operatorHadVisibility: Bool
    ) -> Bool {
        if case .recoveryPause = phase {
            guard operatorHadVisibility,
                  authoritativeMarker(role: .recoveryStationaryConfirmation, repetition: repetition) == nil,
                  let recoveryPauseStartedAt,
                  timestamp.monotonicUptimeNanoseconds >= recoveryPauseStartedAt.monotonicUptimeNanoseconds else {
                return false
            }
            markers.append(.init(
                marker: .stopped,
                role: .recoveryStationaryConfirmation,
                repetition: repetition,
                timestamp: timestamp,
                note: note,
                operatorHadVisibility: operatorHadVisibility
            ))
            return true
        }
        guard case .observingStop = phase,
              operatorHadVisibility,
              authoritativeMarker(role: .firstPhysicalStop, repetition: repetition) == nil,
              let initialStopInvocation,
              initialStopInvocation.repetition == repetition,
              timestamp.monotonicUptimeNanoseconds >= initialStopInvocation.timestamp.monotonicUptimeNanoseconds,
              let moving = authoritativeMarker(role: .movingBaseline, repetition: repetition) else {
            return false
        }
        guard within(
            timestamp.monotonicUptimeNanoseconds,
            deadlineAfter: initialStopInvocation.timestamp,
            seconds: StopTruthExperimentPlanService.physicalStoppedDeadlineAfterInitialStopSeconds
        ) else {
            fail("physical_stopped_marker_deadline_exceeded")
            return false
        }
        let duration = Double(
            timestamp.monotonicUptimeNanoseconds - moving.timestamp.monotonicUptimeNanoseconds
        ) / 1_000_000_000
            + StopTruthExperimentPlanService.movingEvidenceLeadSeconds
            - StopTruthExperimentPlanService.stoppedEvidenceLeadSeconds
        guard duration <= StopTruthExperimentPlanService.maximumMotionDurationPerRepetitionSeconds,
              cumulativeMotionDurationSeconds + duration
                <= StopTruthExperimentPlanService.maximumCumulativeMotionDurationSeconds else {
            fail("motion_duration_bound_exceeded")
            return false
        }
        cumulativeMotionDurationSeconds += duration
        markers.append(.init(
            marker: .stopped,
            role: .firstPhysicalStop,
            repetition: repetition,
            timestamp: timestamp,
            note: note,
            operatorHadVisibility: operatorHadVisibility
        ))
        return true
    }

    private func stopTimingIsWithinBound(
        stopUptimeNanoseconds: UInt64,
        movingUptimeNanoseconds: UInt64
    ) -> Bool {
        guard stopUptimeNanoseconds >= movingUptimeNanoseconds else { return false }
        let elapsedAfterMoving = Double(stopUptimeNanoseconds - movingUptimeNanoseconds) / 1_000_000_000
        return elapsedAfterMoving + StopTruthExperimentPlanService.movingEvidenceLeadSeconds
            <= StopTruthExperimentPlanService.initialStopDeadlineAfterMovingEvidenceSeconds
    }

    private func within(
        _ uptimeNanoseconds: UInt64,
        deadlineAfter timestamp: StopTruthExperimentTimestamp,
        seconds: TimeInterval
    ) -> Bool {
        guard timestamp.originID == clockOriginID,
              uptimeNanoseconds >= timestamp.monotonicUptimeNanoseconds else {
            return false
        }
        return Double(uptimeNanoseconds - timestamp.monotonicUptimeNanoseconds) / 1_000_000_000 <= seconds
    }

    private func authoritativeMarker(role: MarkerRole, repetition: Int) -> MarkerEvidence? {
        markers.first(where: { $0.role == role && $0.repetition == repetition })
    }

    private mutating func applyTerminalCutoffPolicy() {
        if motionCapableInvocationOccurred && !positiveSafeRecoveryEstablished {
            physicalCutoffRequired = true
        }
    }

    private mutating func resetForNextRepetition() {
        fe01Observations.removeAll()
        baselineStartInvocation = nil
        raw5Invocation = nil
        initialStopInvocation = nil
        movingBaselineQualifiedAtUptimeNanoseconds = nil
        recoveryPauseStartedAt = nil
        executorQuiescentForRecovery = false
        renewedMotionAfterStop = false
    }

    private var isTerminal: Bool {
        switch phase {
        case .disabled, .completed, .aborted, .failed: return true
        default: return false
        }
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
