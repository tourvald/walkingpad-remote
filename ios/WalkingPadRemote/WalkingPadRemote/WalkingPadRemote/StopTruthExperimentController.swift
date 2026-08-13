import Foundation

final class StopTruthExperimentController {
    typealias TransportInvocation = (
        Data,
        BLETransportCodec.StopTruthExperimentCommandRole,
        UUID,
        @escaping (Result<StopTruthExperimentTransportReceipt, Error>) -> Void
    ) -> Void

    private final class ClosureTransport: StopTruthExperimentTransport {
        var invocation: TransportInvocation
        init(invocation: @escaping TransportInvocation) { self.invocation = invocation }

        func invoke(
            packet: Data,
            role: BLETransportCodec.StopTruthExperimentCommandRole,
            writeID: UUID,
            completion: @escaping (Result<StopTruthExperimentTransportReceipt, Error>) -> Void
        ) {
            invocation(packet, role, writeID, completion)
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
    private var session: StopTruthExperimentSessionService
    private var executor: StopTruthExperimentExecutor?
    private var run: StopTruthExperimentExecutor.Run?
    private var observationService: StopTruthExperimentObservationService?
    private var observationWindowWorkItem: DispatchWorkItem?
    private var postWindowWorkItem: DispatchWorkItem?
    private var repetitionTimeoutWorkItem: DispatchWorkItem?
    private var globalTimeoutWorkItem: DispatchWorkItem?
    private var lastInvocationUptimeNanoseconds: UInt64?

    init(
        experimentID: UUID = UUID(),
        buildIdentity: StopTruthExperimentBuildIdentity,
        context: StopTruthExperimentPlanService.Context,
        timeoutPolicy: StopTruthExperimentSessionService.TimeoutPolicy,
        evidenceSink: StopTruthExperimentEvidenceSink,
        transportInvocation: @escaping TransportInvocation,
        speedSnapshot: @escaping () -> (speedKmh: Double, deviceReportedSpeedKmh: Double),
        beforeHighPriorityStop: @escaping () -> Void,
        deviceMetadata: @escaping () -> [String: String] = { [:] },
        onStateChange: @escaping (String) -> Void
    ) {
        self.buildIdentity = buildIdentity
        self.clock = StopTruthExperimentClock()
        self.context = context
        self.timeoutPolicy = timeoutPolicy
        self.evidenceSink = evidenceSink
        self.speedSnapshot = speedSnapshot
        self.beforeHighPriorityStop = beforeHighPriorityStop
        self.deviceMetadata = deviceMetadata
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
                return
            }
            self.transportInvoked(
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

    var status: String { String(describing: session.phase) }
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
        context incomingContext: StopTruthExperimentPlanService.Context
    ) {
        guard isActive, incomingContext == context, let timestamp = clock.now() else { return }
        let evidence = StopTruthExperimentPlanService.A6BoundsEvidence(
            context: incomingContext,
            observedAt: timestamp,
            checksumValid: params.checksumOk,
            startSpeedRawTenths: params.startSpeedRawTenths,
            maxSpeedRawTenths: params.maxSpeedRawTenths
        )
        session.recordA6Bounds(evidence)
        record(.a6Bounds, fields: [
            "raw_packet_hex": params.rawHex,
            "checksum_valid": String(params.checksumOk),
            "start_speed_raw_tenths": String(params.startSpeedRawTenths),
            "max_speed_raw_tenths": String(params.maxSpeedRawTenths)
        ])
        publishState()
    }

    func recordMalformedA6(
        rawHex: String,
        context incomingContext: StopTruthExperimentPlanService.Context
    ) {
        guard isActive, incomingContext == context, let timestamp = clock.now() else { return }
        session.recordA6Bounds(.init(
            context: incomingContext,
            observedAt: timestamp,
            checksumValid: false,
            startSpeedRawTenths: 0,
            maxSpeedRawTenths: 0
        ))
        record(.a6Bounds, fields: [
            "raw_packet_hex": rawHex,
            "checksum_valid": "false",
            "parse_result": "malformed_a6"
        ])
        publishState()
    }

    func recordFE01(
        rawHex: String,
        status: BLETransportCodec.WalkingPadStatus,
        context incomingContext: StopTruthExperimentPlanService.Context
    ) {
        guard isActive, let timestamp = clock.now() else { return }
        let observation = StopTruthExperimentPlanService.FE01Observation(
            context: incomingContext,
            receivedAt: timestamp,
            rawHex: rawHex,
            checksumValid: status.checksumOk,
            speedRawTenths: Int(status.speedRawTenths),
            state: status.beltState
        )
        session.recordFE01(observation)
        record(.fe01Raw, fields: [
            "raw_packet_hex": rawHex,
            "checksum_valid": String(status.checksumOk),
            "speed_raw_tenths": String(status.speedRawTenths),
            "state": String(status.beltState),
            "peripheral_id": incomingContext.peripheralID.uuidString,
            "connection_epoch": incomingContext.connectionEpoch.uuidString,
            "notification_stream_id": incomingContext.notificationStreamID.uuidString
        ])
        if var observationService {
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
        reason: String
    ) {
        guard isActive, let timestamp = clock.now() else { return }
        let observation = StopTruthExperimentPlanService.FE01Observation(
            context: incomingContext,
            receivedAt: timestamp,
            rawHex: rawHex,
            checksumValid: false,
            speedRawTenths: nil,
            state: nil
        )
        session.recordFE01(observation)
        record(.fe01Raw, fields: [
            "raw_packet_hex": rawHex,
            "checksum_valid": "false",
            "parse_result": reason,
            "peripheral_id": incomingContext.peripheralID.uuidString,
            "connection_epoch": incomingContext.connectionEpoch.uuidString,
            "notification_stream_id": incomingContext.notificationStreamID.uuidString
        ])
        if var observationService {
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
                maximumAgeSeconds: timeoutPolicy.globalSeconds
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
            executor?.abort(token: run?.token ?? UUID(), note: note)
            cancelAllDelayedWork()
        }
        guard session.recordMarker(
            marker,
            timestamp: timestamp,
            note: note,
            operatorHadVisibility: operatorHadVisibility
        ) else { return }
        record(.physicalMarker, fields: [
            "marker": marker.rawValue,
            "note": note,
            "operator_had_visibility": String(operatorHadVisibility),
            "sends_ble_command": "false"
        ])
        publishState()
    }

    func beginStop() -> Bool {
        guard let now = clock.now(),
              session.acceptMovingBaseline(clock: clock, nowUptimeNanoseconds: now.monotonicUptimeNanoseconds),
              session.beginStopObservation() else {
            publishState()
            return false
        }
        beforeHighPriorityStop()
        guard enqueue(.initialStop) else {
            fail("initial_stop_enqueue_failed")
            return false
        }
        publishState()
        return true
    }

    func beginNextRepetition() -> Bool {
        guard session.beginNextRepetition() else { return false }
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
        executor?.abort(token: run?.token ?? UUID(), note: "connection_context_invalidated")
        cancelAllDelayedWork()
        publishState()
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
            evidenceSink: evidenceSink
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

    private func transportInvoked(
        role: BLETransportCodec.StopTruthExperimentCommandRole,
        packet: Data,
        writeID: UUID,
        completion: @escaping (Result<StopTruthExperimentTransportReceipt, Error>) -> Void,
        invocation: TransportInvocation
    ) {
        guard let timestamp = clock.now() else {
            DispatchQueue.main.async { [weak self] in
                completion(.failure(ControllerError.monotonicClockUnavailable))
                self?.fail("monotonic_clock_unavailable")
            }
            return
        }
        if let last = lastInvocationUptimeNanoseconds,
           timestamp.monotonicUptimeNanoseconds < last + 2_000_000_000 {
            DispatchQueue.main.async { [weak self] in
                completion(.failure(ControllerError.minimumWriteIntervalViolation))
                self?.fail("minimum_write_interval_violation")
            }
            return
        }
        lastInvocationUptimeNanoseconds = timestamp.monotonicUptimeNanoseconds
        if role == .initialStop {
            observationService = StopTruthExperimentObservationService(
                context: context,
                stopInvokedAt: timestamp
            )
        }
        invocation(packet, role, writeID) { [weak self] result in
            completion(result)
            if case .success = result, role == .initialStop {
                guard self?.isActive == true else { return }
                self?.scheduleProductionStopActions()
                self?.scheduleObservationWindow(stopInvokedAt: timestamp)
            } else if case .failure = result {
                self?.fail("transport_invocation_failed")
            }
        }
    }

    private func scheduleProductionStopActions() {
        guard let executor, let run else { return }
        _ = executor.schedule(
            role: .productionStopRecovery,
            token: run.token,
            after: StopTruthExperimentPlanService.recoveryToggleDelaySeconds
        )
        _ = executor.schedule(
            role: .conditionalStopRetry,
            token: run.token,
            after: StopTruthExperimentPlanService.conditionalRetryDelaySeconds,
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
        )
    }

    private func scheduleObservationWindow(stopInvokedAt: StopTruthExperimentTimestamp) {
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
            _ = self.session.finishObservationWindow()
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
            _ = self.session.finishPostWindowFreshness()
            self.record(.postWindowFreshness, fields: self.stopFields(evaluation, service: service))
            if let executor = self.executor, let run = self.run, !executor.finish(token: run.token) {
                self.fail("experiment_command_count_incomplete")
                return
            }
            self.repetitionTimeoutWorkItem?.cancel()
            self.publishState()
        }
        observationWindowWorkItem = window
        postWindowWorkItem = post
        DispatchQueue.main.asyncAfter(deadline: .now() + 30.0, execute: window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 32.1, execute: post)
    }

    private func scheduleGlobalTimeout() {
        let item = DispatchWorkItem { [weak self] in self?.fail("global_timeout") }
        globalTimeoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutPolicy.globalSeconds, execute: item)
    }

    private func scheduleRepetitionTimeout(repetition: Int) {
        repetitionTimeoutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.fail("repetition_\(repetition)_timeout") }
        repetitionTimeoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutPolicy.perRepetitionSeconds, execute: item)
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
            maximumAgeSeconds: timeoutPolicy.globalSeconds
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
        record(.stopObservation, fields: fields)
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
        fields: [String: String]
    ) {
        guard let timestamp = clock.now() else { return }
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
        executor?.abort(token: run?.token ?? UUID(), note: reason)
        cancelAllDelayedWork()
        session.fail(reason)
        publishState()
    }

    private func cancelAllDelayedWork() {
        observationWindowWorkItem?.cancel()
        postWindowWorkItem?.cancel()
        repetitionTimeoutWorkItem?.cancel()
        globalTimeoutWorkItem?.cancel()
    }

    private func publishState() { onStateChange(status) }

    enum ControllerError: Error {
        case monotonicClockUnavailable
        case minimumWriteIntervalViolation
    }
}
