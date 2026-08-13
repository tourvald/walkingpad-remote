import Foundation

final class StopTruthExperimentController {
    typealias TransportInvocation = (
        Data,
        BLETransportCodec.StopTruthExperimentCommandRole,
        UUID,
        @escaping (Result<StopTruthExperimentTransportReceipt, Error>) -> Void
    ) -> Bool

    private final class ClosureTransport: StopTruthExperimentTransport {
        var invocation: TransportInvocation
        init(invocation: @escaping TransportInvocation) { self.invocation = invocation }

        func invoke(
            packet: Data,
            role: BLETransportCodec.StopTruthExperimentCommandRole,
            writeID: UUID,
            completion: @escaping (Result<StopTruthExperimentTransportReceipt, Error>) -> Void
        ) {
            _ = invocation(packet, role, writeID, completion)
        }
    }

    private let buildIdentity: StopTruthExperimentBuildIdentity
    private let clock: StopTruthExperimentClock
    private let context: StopTruthExperimentPlanService.Context
    private let timeoutPolicy: StopTruthExperimentSessionService.TimeoutPolicy
    private let evidenceSink: StopTruthExperimentEvidenceSink
    private let transport: ClosureTransport
    private let speedSnapshot: () -> (speedKmh: Double, deviceReportedSpeedKmh: Double)
    private let beforeHighPriorityStop: () -> Void
    private let onStateChange: (String) -> Void
    private let deviceMetadata: () -> [String: String]
    private let scheduleHandler: StopTruthExperimentExecutor.ScheduleHandler?
    private var session: StopTruthExperimentSessionService
    private var executor: StopTruthExperimentExecutor?
    private var run: StopTruthExperimentExecutor.Run?
    private var observationService: StopTruthExperimentObservationService?
    private var observationWindowWorkItem: DispatchWorkItem?
    private var postWindowWorkItem: DispatchWorkItem?
    private var repetitionTimeoutWorkItem: DispatchWorkItem?
    private var globalTimeoutWorkItem: DispatchWorkItem?
    private var baselineStartDeadlineWorkItem: DispatchWorkItem?
    private var movingBaselineDeadlineWorkItem: DispatchWorkItem?
    private var physicalStopDeadlineWorkItem: DispatchWorkItem?
    private var lastInvocationUptimeNanoseconds: UInt64?
    private var terminalSafetyCutoffRecorded = false
    private var hasRecordedTerminalSafety = false

    init(
        experimentID: UUID = UUID(),
        buildIdentity: StopTruthExperimentBuildIdentity,
        context: StopTruthExperimentPlanService.Context,
        timeoutPolicy: StopTruthExperimentSessionService.TimeoutPolicy,
        evidenceSink: StopTruthExperimentEvidenceSink,
        clock: StopTruthExperimentClock = StopTruthExperimentClock(),
        transportInvocation: @escaping TransportInvocation,
        speedSnapshot: @escaping () -> (speedKmh: Double, deviceReportedSpeedKmh: Double),
        beforeHighPriorityStop: @escaping () -> Void,
        deviceMetadata: @escaping () -> [String: String] = { [:] },
        scheduleHandler: StopTruthExperimentExecutor.ScheduleHandler? = nil,
        onStateChange: @escaping (String) -> Void
    ) {
        self.buildIdentity = buildIdentity
        self.clock = clock
        self.context = context
        self.timeoutPolicy = timeoutPolicy
        self.evidenceSink = evidenceSink
        self.speedSnapshot = speedSnapshot
        self.beforeHighPriorityStop = beforeHighPriorityStop
        self.deviceMetadata = deviceMetadata
        self.scheduleHandler = scheduleHandler
        self.onStateChange = onStateChange
        self.transport = ClosureTransport(invocation: transportInvocation)
        self.session = StopTruthExperimentSessionService(
            experimentID: experimentID,
            context: context,
            clockOriginID: clock.originID,
            timeoutPolicy: timeoutPolicy,
            buildIdentity: buildIdentity
        )
        self.transport.invocation = { [weak self] packet, role, writeID, completion in
            guard let self else {
                DispatchQueue.main.async {
                    completion(.failure(ControllerError.monotonicClockUnavailable))
                }
                return false
            }
            return self.transportInvoked(
                role: role,
                packet: packet,
                writeID: writeID,
                completion: completion,
                invocation: transportInvocation
            )
        }
    }

    var isActive: Bool {
        switch session.phase {
        case .disabled, .completed, .aborted, .failed:
            return false
        default:
            return true
        }
    }

    var status: String {
        let phase = String(describing: session.phase)
        guard session.physicalCutoffRequired else { return phase }
        return "\(phase) • physical power cutoff required; no resume/reconnect"
    }
    var experimentID: UUID { session.experimentID }

    func start() -> Bool {
        guard case .preflight(repetition: 1) = session.phase,
              buildIdentity.isEnabled,
              startExecutor(repetition: 1) else {
            publishState()
            return false
        }
        var fields: [String: String] = [
            "expected_git_sha": buildIdentity.expectedGitSHA ?? "",
            "actual_git_sha": buildIdentity.actualGitSHA ?? "",
            "bundle_id": buildIdentity.bundleIdentifier ?? "",
            "bundle_version": buildIdentity.version ?? "",
            "bundle_build": buildIdentity.build ?? "",
            "planned_repetitions": String(StopTruthExperimentPlanService.plannedRepetitions),
            "reconnect_count": "0",
            "peripheral_id": context.peripheralID.uuidString,
            "connection_epoch": context.connectionEpoch.uuidString,
            "notification_stream_id": context.notificationStreamID.uuidString
        ]
        fields.merge(deviceMetadata(), uniquingKeysWith: { current, _ in current })
        record(.experimentStarted, repetition: 1, fields: fields)
        scheduleGlobalTimeout()
        scheduleRepetitionTimeout(repetition: 1)
        guard enqueue(.queryParams) else {
            fail("query_params_enqueue_failed")
            return false
        }
        publishState()
        return true
    }

    func recordA6Bounds(
        params: BLETransportCodec.WalkingPadParams,
        context incomingContext: StopTruthExperimentPlanService.Context,
        receivedUptimeNanoseconds: UInt64,
        receivedWallDate: Date
    ) {
        guard isActive,
              incomingContext == context,
              let timestamp = clock.timestamp(
                uptimeNanoseconds: receivedUptimeNanoseconds,
                wallDate: receivedWallDate
              ) else { return }
        let evidence = StopTruthExperimentPlanService.A6BoundsEvidence(
            context: incomingContext,
            observedAt: timestamp,
            checksumValid: params.checksumOk,
            startSpeedRawTenths: params.startSpeedRawTenths,
            maxSpeedRawTenths: params.maxSpeedRawTenths
        )
        session.recordA6Bounds(evidence)
        record(.a6Bounds, timestamp: timestamp, fields: [
            "raw_packet_hex": params.rawHex,
            "checksum_valid": String(params.checksumOk),
            "start_speed_raw_tenths": String(params.startSpeedRawTenths),
            "max_speed_raw_tenths": String(params.maxSpeedRawTenths)
        ])
        publishState()
    }

    func recordMalformedA6(
        rawHex: String,
        context incomingContext: StopTruthExperimentPlanService.Context,
        receivedUptimeNanoseconds: UInt64,
        receivedWallDate: Date
    ) {
        guard isActive,
              incomingContext == context,
              let timestamp = clock.timestamp(
                uptimeNanoseconds: receivedUptimeNanoseconds,
                wallDate: receivedWallDate
              ) else { return }
        session.recordA6Bounds(.init(
            context: incomingContext,
            observedAt: timestamp,
            checksumValid: false,
            startSpeedRawTenths: 0,
            maxSpeedRawTenths: 0
        ))
        record(.a6Bounds, timestamp: timestamp, fields: [
            "raw_packet_hex": rawHex,
            "checksum_valid": "false",
            "parse_result": "malformed_a6"
        ])
        publishState()
    }

    func recordFE01(
        rawHex: String,
        status: BLETransportCodec.WalkingPadStatus,
        context incomingContext: StopTruthExperimentPlanService.Context,
        receivedUptimeNanoseconds: UInt64,
        receivedWallDate: Date
    ) {
        guard isActive,
              let timestamp = clock.timestamp(
                uptimeNanoseconds: receivedUptimeNanoseconds,
                wallDate: receivedWallDate
              ) else { return }
        let observation = StopTruthExperimentPlanService.FE01Observation(
            context: incomingContext,
            receivedAt: timestamp,
            rawHex: rawHex,
            checksumValid: status.checksumOk,
            speedRawTenths: Int(status.speedRawTenths),
            state: status.beltState
        )
        session.recordFE01(observation)
        record(.fe01Raw, timestamp: timestamp, fields: [
            "raw_packet_hex": rawHex,
            "checksum_valid": String(status.checksumOk),
            "speed_raw_tenths": String(status.speedRawTenths),
            "state": String(status.beltState),
            "peripheral_id": incomingContext.peripheralID.uuidString,
            "connection_epoch": incomingContext.connectionEpoch.uuidString,
            "notification_stream_id": incomingContext.notificationStreamID.uuidString
        ])
        guard incomingContext == context else {
            fail("connection_or_notification_context_changed")
            return
        }
        refreshMovingBaselineQualification(nowUptimeNanoseconds: timestamp.monotonicUptimeNanoseconds)
        if var observationService {
            guard !observationService.isFrozen else {
                publishState()
                return
            }
            let evaluation = observationService.record(
                observation,
                nowUptimeNanoseconds: timestamp.monotonicUptimeNanoseconds
            )
            self.observationService = observationService
            recordStopObservation(evaluation, service: observationService, observation: observation)
        }
        publishState()
    }

    func recordInvalidFE01(
        rawHex: String,
        context incomingContext: StopTruthExperimentPlanService.Context,
        reason: String,
        receivedUptimeNanoseconds: UInt64,
        receivedWallDate: Date
    ) {
        guard isActive,
              let timestamp = clock.timestamp(
                uptimeNanoseconds: receivedUptimeNanoseconds,
                wallDate: receivedWallDate
              ) else { return }
        let observation = StopTruthExperimentPlanService.FE01Observation(
            context: incomingContext,
            receivedAt: timestamp,
            rawHex: rawHex,
            checksumValid: false,
            speedRawTenths: nil,
            state: nil
        )
        session.recordFE01(observation)
        record(.fe01Raw, timestamp: timestamp, fields: [
            "raw_packet_hex": rawHex,
            "checksum_valid": "false",
            "parse_result": reason,
            "peripheral_id": incomingContext.peripheralID.uuidString,
            "connection_epoch": incomingContext.connectionEpoch.uuidString,
            "notification_stream_id": incomingContext.notificationStreamID.uuidString
        ])
        guard incomingContext == context else {
            fail("connection_or_notification_context_changed")
            return
        }
        if var observationService {
            guard !observationService.isFrozen else {
                publishState()
                return
            }
            let evaluation = observationService.record(
                observation,
                nowUptimeNanoseconds: timestamp.monotonicUptimeNanoseconds
            )
            self.observationService = observationService
            recordStopObservation(evaluation, service: observationService, observation: observation)
        }
        publishState()
    }

    func prepareMotion() -> Bool {
        guard let now = clock.now(),
              session.acceptStationaryBaseline(clock: clock, nowUptimeNanoseconds: now.monotonicUptimeNanoseconds),
              StopTruthExperimentPlanService.raw5IsAllowed(
                by: session.a6BoundsEvidence,
                currentContext: context,
                clock: clock,
                nowUptimeNanoseconds: now.monotonicUptimeNanoseconds,
                maximumAgeSeconds: StopTruthExperimentPlanService.a6FreshnessIntervalSeconds
              ),
              session.beginMovingBaseline(),
              let run else {
            publishState()
            return false
        }
        let baseDelay = remainingWriteInterval(nowUptimeNanoseconds: now.monotonicUptimeNanoseconds)
        var delay = baseDelay
        if run.repetition == 1 {
            guard schedule(.modeManual, after: delay) else { return false }
            delay += 2.0
        }
        guard schedule(.baselineStart, after: delay, shouldEnqueue: { [weak self] in
            guard let self, self.raw5GateIsCurrent() else {
                self?.fail("a6_gate_invalid_before_baseline_start")
                return false
            }
            return true
        }) else { return false }
        delay += 2.0
        guard schedule(.speedRaw5, after: delay, shouldEnqueue: { [weak self] in
            guard let self, self.raw5GateIsCurrent() else {
                self?.fail("a6_gate_invalid_before_raw5")
                return false
            }
            return true
        }) else { return false }
        publishState()
        return true
    }

    func recordMarker(
        _ marker: StopTruthExperimentSessionService.Marker,
        note: String = "operator_tap",
        operatorHadVisibility: Bool = true
    ) {
        guard let timestamp = clock.now() else {
            fail("marker_monotonic_clock_unavailable")
            return
        }
        if marker == .abort {
            guard session.recordMarker(
                marker,
                timestamp: timestamp,
                note: note,
                operatorHadVisibility: operatorHadVisibility
            ) else { return }
            recordPhysicalMarker(session.markers.last)
            finalizeTerminalState(note: note)
            return
        }
        guard session.recordMarker(
            marker,
            timestamp: timestamp,
            note: note,
            operatorHadVisibility: operatorHadVisibility
        ) else {
            if !isActive { finalizeTerminalState(note: session.terminalReason ?? "marker_rejected_terminal") }
            return
        }
        recordPhysicalMarker(session.markers.last)
        if marker == .moving, let now = clock.now() {
            refreshMovingBaselineQualification(nowUptimeNanoseconds: now.monotonicUptimeNanoseconds)
        } else if marker == .stopped, session.hasFirstPhysicalStopForCurrentRepetition() {
            physicalStopDeadlineWorkItem?.cancel()
        }
        publishState()
    }

    func beginStop() -> Bool {
        guard let now = clock.now(),
              session.acceptMovingBaseline(clock: clock, nowUptimeNanoseconds: now.monotonicUptimeNanoseconds),
              session.canAttemptInitialStop(nowUptimeNanoseconds: now.monotonicUptimeNanoseconds) else {
            if case .movingReady = session.phase {
                fail("initial_stop_attempt_after_motion_deadline")
            }
            publishState()
            return false
        }
        cancelMovingBaselineDeadlines()
        guard session.beginStopObservation() else { return false }
        beforeHighPriorityStop()
        guard enqueue(.initialStop) else {
            fail("initial_stop_enqueue_failed")
            return false
        }
        publishState()
        return true
    }

    func beginNextRepetition() -> Bool {
        guard let now = clock.now(),
              session.beginNextRepetition(
                clock: clock,
                nowUptimeNanoseconds: now.monotonicUptimeNanoseconds,
                executorQuiescent: executor?.isQuiescent() == true
              ) else { return false }
        if case .completed = session.phase {
            cancelAllDelayedWork()
            publishState()
            return true
        }
        guard case .preflight(let repetition) = session.phase,
              startExecutor(repetition: repetition) else {
            fail("next_repetition_executor_start_failed")
            return false
        }
        scheduleRepetitionTimeout(repetition: repetition)
        publishState()
        return true
    }

    func connectionContextInvalidated() {
        session.recordReconnect()
        finalizeTerminalState(note: "connection_context_invalidated")
    }

    private func startExecutor(repetition: Int) -> Bool {
        let first = repetition == 1
        var roles = StopTruthExperimentPlanService.fixedRoles(firstRepetition: first, retryRequired: false)
        let conditionalIndex = roles.firstIndex(of: .conditionalStopRetry)
        if let conditionalIndex { roles.remove(at: conditionalIndex) }
        let run = StopTruthExperimentExecutor.Run(
            token: UUID(),
            experimentID: session.experimentID,
            repetition: repetition,
            expectedRoles: roles,
            allowsConditionalStopRetry: true
        )
        let executor = StopTruthExperimentExecutor(
            transport: transport,
            clock: clock,
            evidenceSink: evidenceSink,
            scheduleHandler: scheduleHandler,
            onFailure: { [weak self] reason in
                self?.fail("executor_\(reason)")
            }
        )
        guard executor.start(run: run) else { return false }
        self.run = run
        self.executor = executor
        return true
    }

    private func enqueue(_ role: BLETransportCodec.StopTruthExperimentCommandRole) -> Bool {
        guard let executor, let run else { return false }
        if case .accepted = executor.enqueue(role: role, token: run.token) { return true }
        return false
    }

    private func schedule(
        _ role: BLETransportCodec.StopTruthExperimentCommandRole,
        after delay: TimeInterval,
        shouldEnqueue: @escaping () -> Bool = { true }
    ) -> Bool {
        guard let executor, let run else { return false }
        return executor.schedule(
            role: role,
            token: run.token,
            after: delay,
            shouldEnqueue: shouldEnqueue
        ) != nil
    }

    @discardableResult
    private func transportInvoked(
        role: BLETransportCodec.StopTruthExperimentCommandRole,
        packet: Data,
        writeID: UUID,
        completion: @escaping (Result<StopTruthExperimentTransportReceipt, Error>) -> Void,
        invocation: TransportInvocation
    ) -> Bool {
        guard let timestamp = clock.now() else {
            DispatchQueue.main.async { [weak self] in
                completion(.failure(ControllerError.monotonicClockUnavailable))
                self?.fail("monotonic_clock_unavailable")
            }
            return false
        }
        if let last = lastInvocationUptimeNanoseconds,
           timestamp.monotonicUptimeNanoseconds < last + 2_000_000_000 {
            DispatchQueue.main.async { [weak self] in
                completion(.failure(ControllerError.minimumWriteIntervalViolation))
                self?.fail("minimum_write_interval_violation")
            }
            return false
        }
        if role == .initialStop,
           !session.canInvokeInitialStop(nowUptimeNanoseconds: timestamp.monotonicUptimeNanoseconds) {
            DispatchQueue.main.async { [weak self] in
                completion(.failure(ControllerError.initialStopDeadlineExceeded))
                self?.fail("initial_stop_actual_invocation_after_motion_deadline")
            }
            return false
        }
        lastInvocationUptimeNanoseconds = timestamp.monotonicUptimeNanoseconds
        let actuallyInvoked = invocation(packet, role, writeID) { [weak self] result in
            completion(result)
            if case .failure = result {
                self?.fail("transport_invocation_failed")
            } else {
                self?.handleSuccessfulReceipt(role: role, timestamp: timestamp)
            }
        }
        guard actuallyInvoked else {
            DispatchQueue.main.async { [weak self] in
                completion(.failure(ControllerError.transportRejectedBeforeInvocation))
                self?.fail("transport_rejected_before_actual_invocation")
            }
            return false
        }
        handleActualInvocation(role: role, timestamp: timestamp)
        return true
    }

    private func scheduleProductionStopActions(
        stopInvokedAt: StopTruthExperimentTimestamp
    ) -> Bool {
        guard let executor, let run else { return false }
        guard let recoveryDelay = remainingDeadlineDelay(
            since: stopInvokedAt,
            limit: StopTruthExperimentPlanService.recoveryToggleDelaySeconds
        ), let retryDelay = remainingDeadlineDelay(
            since: stopInvokedAt,
            limit: StopTruthExperimentPlanService.conditionalRetryDelaySeconds
        ) else { return false }
        guard executor.schedule(
            role: .productionStopRecovery,
            token: run.token,
            after: recoveryDelay
        ) != nil else { return false }
        guard executor.schedule(
            role: .conditionalStopRetry,
            token: run.token,
            after: retryDelay,
            shouldEnqueue: { [weak self] in
                guard let self else { return false }
                let snapshot = self.speedSnapshot()
                let required = StopTruthExperimentPlanService.productionRetryRequired(
                    speedKmh: snapshot.speedKmh,
                    deviceReportedSpeedKmh: snapshot.deviceReportedSpeedKmh
                )
                self.record(.conditionalRetryEvaluation, fields: [
                    "speed_kmh": String(snapshot.speedKmh),
                    "device_reported_speed_kmh": String(snapshot.deviceReportedSpeedKmh),
                    "threshold_kmh": "0.2",
                    "retry_required": String(required)
                ])
                return required
            }
        ) != nil else { return false }
        return true
    }

    private func handleSuccessfulReceipt(
        role: BLETransportCodec.StopTruthExperimentCommandRole,
        timestamp: StopTruthExperimentTimestamp
    ) {
        guard isActive else {
            finalizeTerminalState(note: session.terminalReason ?? "receipt_after_terminal")
            return
        }
        if role == .initialStop,
           !scheduleProductionStopActions(stopInvokedAt: timestamp) {
            fail("production_stop_actions_schedule_failed")
            return
        }
        publishState()
    }

    private func handleActualInvocation(
        role: BLETransportCodec.StopTruthExperimentCommandRole,
        timestamp: StopTruthExperimentTimestamp
    ) {
        if role == .baselineStart || role == .speedRaw5 || role == .productionStopRecovery {
            session.recordMotionCapableInvocation(role: role, timestamp: timestamp)
            recordTerminalSafetyIfNeeded(reason: session.terminalReason ?? "motion_capable_invocation")
        }
        guard isActive else {
            finalizeTerminalState(note: session.terminalReason ?? "invocation_completed_after_terminal")
            return
        }
        switch role {
        case .baselineStart:
            scheduleMovingBaselineDeadline(
                invocationTimestamp: timestamp,
                limit: StopTruthExperimentPlanService.movingBaselineDeadlineAfterBaselineStartSeconds,
                reason: "moving_baseline_missing_after_baseline_start_deadline",
                storage: &baselineStartDeadlineWorkItem
            )
        case .speedRaw5:
            session.recordRaw5Invocation(timestamp: timestamp)
            scheduleMovingBaselineDeadline(
                invocationTimestamp: timestamp,
                limit: StopTruthExperimentPlanService.movingBaselineDeadlineAfterRaw5Seconds,
                reason: "moving_baseline_missing_after_raw5_deadline",
                storage: &movingBaselineDeadlineWorkItem
            )
        case .initialStop:
            guard session.recordInitialStopInvocation(timestamp: timestamp) else {
                return
            }
            observationService = StopTruthExperimentObservationService(
                context: context,
                stopInvokedAt: timestamp
            )
            guard schedulePhysicalStopDeadline(stopInvokedAt: timestamp) else { return }
            guard scheduleObservationWindow(stopInvokedAt: timestamp) else { return }
        default:
            break
        }
        publishState()
    }

    private func refreshMovingBaselineQualification(nowUptimeNanoseconds: UInt64) {
        guard session.refreshMovingBaselineQualification(
            clock: clock,
            nowUptimeNanoseconds: nowUptimeNanoseconds
        ) else { return }
        cancelMovingBaselineDeadlines()
    }

    private func scheduleMovingBaselineDeadline(
        invocationTimestamp: StopTruthExperimentTimestamp,
        limit: TimeInterval,
        reason: String,
        storage: inout DispatchWorkItem?
    ) {
        storage?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let now = self.clock.now() else {
                self?.fail("moving_baseline_deadline_clock_unavailable")
                return
            }
            guard !self.session.refreshMovingBaselineQualification(
                clock: self.clock,
                nowUptimeNanoseconds: now.monotonicUptimeNanoseconds
            ) else {
                self.cancelMovingBaselineDeadlines()
                return
            }
            self.fail(reason)
        }
        storage = item
        guard let delay = remainingDeadlineDelay(since: invocationTimestamp, limit: limit) else {
            fail("moving_baseline_deadline_clock_discontinuity")
            return
        }
        scheduleWorkItem(after: delay, item: item)
    }

    private func schedulePhysicalStopDeadline(stopInvokedAt: StopTruthExperimentTimestamp) -> Bool {
        physicalStopDeadlineWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.session.hasFirstPhysicalStopForCurrentRepetition() else { return }
            self.fail("physical_stopped_marker_deadline_exceeded")
        }
        physicalStopDeadlineWorkItem = item
        guard let delay = remainingDeadlineDelay(
            since: stopInvokedAt,
            limit: StopTruthExperimentPlanService.physicalStoppedDeadlineAfterInitialStopSeconds
                + StopTruthExperimentPlanService.inclusiveDeadlineEpsilonSeconds
        ) else {
            fail("physical_stop_deadline_clock_discontinuity")
            return false
        }
        scheduleWorkItem(after: delay, item: item)
        return true
    }

    private func scheduleWorkItem(after delay: TimeInterval, item: DispatchWorkItem) {
        if let scheduleHandler {
            scheduleHandler(delay, item)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    private func remainingDeadlineDelay(
        since timestamp: StopTruthExperimentTimestamp,
        limit: TimeInterval
    ) -> TimeInterval? {
        guard let now = clock.now(),
              now.originID == timestamp.originID,
              now.monotonicUptimeNanoseconds >= timestamp.monotonicUptimeNanoseconds else {
            return nil
        }
        let elapsed = Double(
            now.monotonicUptimeNanoseconds - timestamp.monotonicUptimeNanoseconds
        ) / 1_000_000_000
        guard elapsed <= limit else { return nil }
        return limit - elapsed
    }

    private func cancelMovingBaselineDeadlines() {
        baselineStartDeadlineWorkItem?.cancel()
        movingBaselineDeadlineWorkItem?.cancel()
    }

    private func scheduleObservationWindow(stopInvokedAt: StopTruthExperimentTimestamp) -> Bool {
        observationWindowWorkItem?.cancel()
        postWindowWorkItem?.cancel()
        let window = DispatchWorkItem { [weak self] in
            guard let self, let now = self.clock.now(), var service = self.observationService else { return }
            let expected = stopInvokedAt.monotonicUptimeNanoseconds + 30_000_000_000
            guard now.monotonicUptimeNanoseconds >= expected,
                  now.monotonicUptimeNanoseconds <= expected + 250_000_000 else {
                self.fail("observation_window_timing_discontinuity")
                return
            }
            let evaluation = service.finalizeWindow(nowUptimeNanoseconds: now.monotonicUptimeNanoseconds)
            self.observationService = service
            guard self.session.finishObservationWindow() else {
                self.fail("observation_window_missing_physical_stop")
                return
            }
            self.record(.stopFinalResult, fields: self.stopFields(evaluation, service: service))
            self.publishState()
        }
        let post = DispatchWorkItem { [weak self] in
            guard let self, let now = self.clock.now(), var service = self.observationService else { return }
            let expected = stopInvokedAt.monotonicUptimeNanoseconds + 32_100_000_000
            guard now.monotonicUptimeNanoseconds >= expected,
                  now.monotonicUptimeNanoseconds <= expected + 250_000_000 else {
                self.fail("post_window_timing_discontinuity")
                return
            }
            let evaluation = service.recordPostWindowFreshness(nowUptimeNanoseconds: now.monotonicUptimeNanoseconds)
            self.observationService = service
            self.record(.postWindowFreshness, fields: self.stopFields(evaluation, service: service))
            if let executor = self.executor, let run = self.run, !executor.finish(token: run.token) {
                self.fail("experiment_command_count_incomplete")
                return
            }
            guard self.session.finishPostWindowFreshness(
                timestamp: now,
                executorQuiescent: self.executor?.isQuiescent() == true
            ) else {
                self.fail("recovery_entry_not_quiescent")
                return
            }
            self.repetitionTimeoutWorkItem?.cancel()
            self.publishState()
        }
        observationWindowWorkItem = window
        postWindowWorkItem = post
        guard let windowDelay = remainingDeadlineDelay(
            since: stopInvokedAt,
            limit: StopTruthExperimentPlanService.observationWindowSeconds
        ), let postDelay = remainingDeadlineDelay(
            since: stopInvokedAt,
            limit: StopTruthExperimentPlanService.observationWindowSeconds
                + StopTruthExperimentPlanService.postWindowFreshnessDelaySeconds
        ) else {
            fail("observation_schedule_clock_discontinuity")
            return false
        }
        scheduleWorkItem(after: windowDelay, item: window)
        scheduleWorkItem(after: postDelay, item: post)
        return true
    }

    private func scheduleGlobalTimeout() {
        let item = DispatchWorkItem { [weak self] in self?.fail("global_timeout") }
        globalTimeoutWorkItem = item
        scheduleWorkItem(after: timeoutPolicy.globalSeconds, item: item)
    }

    private func scheduleRepetitionTimeout(repetition: Int) {
        repetitionTimeoutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.fail("repetition_\(repetition)_timeout") }
        repetitionTimeoutWorkItem = item
        scheduleWorkItem(after: timeoutPolicy.perRepetitionSeconds, item: item)
    }

    private func remainingWriteInterval(nowUptimeNanoseconds: UInt64) -> TimeInterval {
        guard let lastInvocationUptimeNanoseconds else { return 0 }
        let allowed = lastInvocationUptimeNanoseconds + 2_000_000_000
        guard allowed > nowUptimeNanoseconds else { return 0 }
        return Double(allowed - nowUptimeNanoseconds) / 1_000_000_000
    }

    private func raw5GateIsCurrent() -> Bool {
        guard let now = clock.now() else { return false }
        return StopTruthExperimentPlanService.raw5IsAllowed(
            by: session.a6BoundsEvidence,
            currentContext: context,
            clock: clock,
            nowUptimeNanoseconds: now.monotonicUptimeNanoseconds,
            maximumAgeSeconds: StopTruthExperimentPlanService.a6FreshnessIntervalSeconds
        )
    }

    private func recordStopObservation(
        _ evaluation: StopTruthExperimentStopEvaluation,
        service: StopTruthExperimentObservationService,
        observation: StopTruthExperimentPlanService.FE01Observation
    ) {
        var fields = stopFields(evaluation, service: service)
        fields["raw_packet_hex"] = observation.rawHex
        fields["observation_sequence"] = String(service.observations.count)
        record(.stopObservation, timestamp: observation.receivedAt, fields: fields)
    }

    private func recordPhysicalMarker(_ marker: StopTruthExperimentSessionService.MarkerEvidence?) {
        guard let marker else { return }
        var fields = [
            "marker": marker.marker.rawValue,
            "marker_role": marker.role.rawValue,
            "note": marker.note,
            "operator_had_visibility": String(marker.operatorHadVisibility),
            "sends_ble_command": "false"
        ]
        if marker.role == .movingBaseline {
            fields["authoritative_moving_uptime_ns"] = String(marker.timestamp.monotonicUptimeNanoseconds)
            if marker.timestamp.monotonicUptimeNanoseconds >= 1_500_000_000 {
                fields["motion_evidence_start_uptime_ns"] = String(
                    marker.timestamp.monotonicUptimeNanoseconds - 1_500_000_000
                )
            }
        } else if marker.role == .firstPhysicalStop {
            fields["first_physical_stopped_uptime_ns"] = String(marker.timestamp.monotonicUptimeNanoseconds)
            if marker.timestamp.monotonicUptimeNanoseconds >= 500_000_000 {
                fields["motion_evidence_stop_uptime_ns"] = String(
                    marker.timestamp.monotonicUptimeNanoseconds - 500_000_000
                )
            }
            fields["cumulative_motion_duration_s"] = String(session.cumulativeMotionDurationSeconds)
            fields["initial_stop_uptime_ns"] = session.initialStopInvocation.map {
                String($0.timestamp.monotonicUptimeNanoseconds)
            } ?? ""
        }
        record(.physicalMarker, timestamp: marker.timestamp, fields: fields)
    }

    private func stopFields(
        _ evaluation: StopTruthExperimentStopEvaluation,
        service: StopTruthExperimentObservationService
    ) -> [String: String] {
        [
            "evaluation_result": evaluation.result.rawValue,
            "evaluation_reason": evaluation.reason,
            "fresh": String(evaluation.isFresh),
            "currently_confirmed": String(evaluation.isCurrentlyConfirmed),
            "confirmed_ever": String(service.firstConfirmedAt != nil),
            "first_confirmed_at": service.firstConfirmedAt.map(ISO8601DateFormatter().string(from:)) ?? "",
            "stop_first_confirmed_monotonic_uptime_ns": service.stopFirstConfirmedMonotonicUptimeNanoseconds.map(String.init) ?? ""
        ]
    }

    private func record(
        _ event: StopTruthExperimentEvidenceEvent,
        repetition: Int? = nil,
        timestamp providedTimestamp: StopTruthExperimentTimestamp? = nil,
        fields: [String: String]
    ) {
        guard let timestamp = providedTimestamp ?? clock.now(),
              timestamp.originID == clock.originID else { return }
        evidenceSink.append(StopTruthExperimentEvidenceRecord(
            event: event,
            experimentID: session.experimentID,
            caseID: StopTruthExperimentPlanService.caseID,
            repetition: repetition ?? run?.repetition ?? 0,
            timestamp: timestamp,
            fields: fields
        ))
    }

    private func fail(_ reason: String) {
        session.fail(reason)
        finalizeTerminalState(note: reason)
    }

    private func finalizeTerminalState(note: String) {
        executor?.abort(token: run?.token ?? UUID(), note: note)
        cancelAllDelayedWork()
        recordTerminalSafetyIfNeeded(reason: note)
        publishState()
    }

    private func recordTerminalSafetyIfNeeded(reason: String) {
        guard session.physicalCutoffRequired || session.terminalReason != nil else { return }
        guard !hasRecordedTerminalSafety
                || session.physicalCutoffRequired != terminalSafetyCutoffRecorded else { return }
        record(.terminalSafety, fields: [
            "terminal_reason": session.terminalReason ?? reason,
            "motion_capable_invocation_occurred": String(session.motionCapableInvocationOccurred),
            "positive_safe_recovery_established": String(session.positiveSafeRecoveryEstablished),
            "physical_cutoff_required": String(session.physicalCutoffRequired),
            "operator_instruction": session.physicalCutoffRequired
                ? "use_physical_power_cutoff_no_resume_reconnect_or_next_repetition"
                : "no_physical_cutoff_required_before_motion"
        ])
        hasRecordedTerminalSafety = true
        terminalSafetyCutoffRecorded = session.physicalCutoffRequired
    }

    private func cancelAllDelayedWork() {
        observationWindowWorkItem?.cancel()
        postWindowWorkItem?.cancel()
        repetitionTimeoutWorkItem?.cancel()
        globalTimeoutWorkItem?.cancel()
        baselineStartDeadlineWorkItem?.cancel()
        movingBaselineDeadlineWorkItem?.cancel()
        physicalStopDeadlineWorkItem?.cancel()
    }

    private func publishState() { onStateChange(status) }

    enum ControllerError: Error {
        case monotonicClockUnavailable
        case minimumWriteIntervalViolation
        case initialStopDeadlineExceeded
        case transportRejectedBeforeInvocation
    }
}
