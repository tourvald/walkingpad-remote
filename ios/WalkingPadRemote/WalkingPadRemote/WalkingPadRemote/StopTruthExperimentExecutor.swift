import Foundation

struct StopTruthExperimentTransportReceipt: Equatable {
    let characteristicUUID: String
    let writeType: String
}

protocol StopTruthExperimentTransport: AnyObject {
    /// Must return immediately and invoke completion asynchronously. The
    /// executor calls this while holding its abort/write linearization lock.
    func invoke(
        packet: Data,
        role: BLETransportCodec.StopTruthExperimentCommandRole,
        writeID: UUID,
        completion: @escaping (Result<StopTruthExperimentTransportReceipt, Error>) -> Void
    )
}

final class StopTruthExperimentExecutor {
    typealias ScheduleHandler = (TimeInterval, DispatchWorkItem) -> Void
    struct Run: Equatable {
        let token: UUID
        let experimentID: UUID
        let repetition: Int
        let expectedRoles: [BLETransportCodec.StopTruthExperimentCommandRole]
        let allowsConditionalStopRetry: Bool

        init(
            token: UUID,
            experimentID: UUID,
            repetition: Int,
            expectedRoles: [BLETransportCodec.StopTruthExperimentCommandRole],
            allowsConditionalStopRetry: Bool = false
        ) {
            self.token = token
            self.experimentID = experimentID
            self.repetition = repetition
            self.expectedRoles = expectedRoles
            self.allowsConditionalStopRetry = allowsConditionalStopRetry
        }
    }

    enum State: Equatable {
        case idle
        case active(Run)
        case invoking(Run, writeID: UUID)
        case abortPending(Run, writeID: UUID)
        case aborted(Run)
        case failed(Run, reason: String)
        case completed(Run)
    }

    enum EnqueueResult: Equatable {
        case accepted(writeID: UUID)
        case rejected(reason: String)
    }

    private let lock = NSLock()
    private let transport: StopTruthExperimentTransport
    private let clock: StopTruthExperimentClock
    private weak var evidenceSink: StopTruthExperimentEvidenceSink?
    private let scheduleHandler: ScheduleHandler?
    private let onFailure: ((String) -> Void)?
    private(set) var state: State = .idle
    private var nextRoleIndex = 0
    private var invocationSequence = 0
    private var barrierSequence: Int?
    private var conditionalStopRetryInvoked = false
    private var delayedActions: [UUID: DispatchWorkItem] = [:]

    init(
        transport: StopTruthExperimentTransport,
        clock: StopTruthExperimentClock,
        evidenceSink: StopTruthExperimentEvidenceSink,
        scheduleHandler: ScheduleHandler? = nil,
        onFailure: ((String) -> Void)? = nil
    ) {
        self.transport = transport
        self.clock = clock
        self.evidenceSink = evidenceSink
        self.scheduleHandler = scheduleHandler
        self.onFailure = onFailure
    }

    func start(run: Run) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .idle = state,
              (1...StopTruthExperimentPlanService.plannedRepetitions).contains(run.repetition),
              !run.expectedRoles.isEmpty else {
            return false
        }
        nextRoleIndex = 0
        invocationSequence = 0
        barrierSequence = nil
        conditionalStopRetryInvoked = false
        state = .active(run)
        return true
    }

    func enqueue(
        role: BLETransportCodec.StopTruthExperimentCommandRole,
        token: UUID
    ) -> EnqueueResult {
        let packet = BLETransportCodec.buildStopTruthExperimentPacket(role: role)
        let writeID = UUID()
        lock.lock()
        guard case .active(let run) = state,
              run.token == token else {
            let run = currentRunLocked()
            recordLocked(.rejectedAfterAbort, run: run, fields: ["phase": "enqueue", "role": role.rawValue])
            lock.unlock()
            return .rejected(reason: "inactive_or_aborted")
        }
        let isNextRequiredRole = nextRoleIndex < run.expectedRoles.count
            && run.expectedRoles[nextRoleIndex] == role
        let isAllowedConditionalRetry = role == .conditionalStopRetry
            && run.allowsConditionalStopRetry
            && nextRoleIndex == run.expectedRoles.count
            && !conditionalStopRetryInvoked
        guard (isNextRequiredRole || isAllowedConditionalRetry),
              BLETransportCodec.validateStopTruthExperimentPacket(packet, role: role) else {
            let reason = "whitelist_order_or_packet_mismatch"
            state = .failed(run, reason: reason)
            lock.unlock()
            onFailure?(reason)
            return .rejected(reason: reason)
        }
        if isNextRequiredRole {
            nextRoleIndex += 1
        } else {
            conditionalStopRetryInvoked = true
        }
        recordLocked(.commandEnqueued, run: run, fields: [
            "role": role.rawValue,
            "packet_hex": packet.map { String(format: "%02X", $0) }.joined(separator: " "),
            "write_id": writeID.uuidString,
            "whitelist_index": String(nextRoleIndex)
        ])
        lock.unlock()
        invoke(packet: packet, role: role, writeID: writeID, token: token)
        return .accepted(writeID: writeID)
    }

    func schedule(
        role: BLETransportCodec.StopTruthExperimentCommandRole,
        token: UUID,
        after delay: TimeInterval,
        queue: DispatchQueue = .main,
        maximumLateness: TimeInterval = 0.25,
        shouldEnqueue: @escaping () -> Bool = { true }
    ) -> UUID? {
        lock.lock()
        guard case .active(let run) = state, run.token == token else {
            lock.unlock()
            return nil
        }
        guard let scheduledAt = clock.now() else {
            let reason = "monotonic_clock_unavailable"
            state = .failed(run, reason: reason)
            lock.unlock()
            onFailure?(reason)
            return nil
        }
        let actionID = UUID()
        let item = DispatchWorkItem { [weak self] in
            self?.runDelayed(
                actionID: actionID,
                role: role,
                token: token,
                scheduledAt: scheduledAt,
                nominalDelay: delay,
                maximumLateness: maximumLateness,
                shouldEnqueue: shouldEnqueue
            )
        }
        delayedActions[actionID] = item
        lock.unlock()
        if let scheduleHandler {
            scheduleHandler(delay, item)
        } else {
            queue.asyncAfter(deadline: .now() + delay, execute: item)
        }
        return actionID
    }

    func abort(token: UUID, note: String = "") {
        lock.lock()
        guard let run = currentRunLocked(), run.token == token else {
            lock.unlock()
            return
        }
        delayedActions.values.forEach { $0.cancel() }
        delayedActions.removeAll()
        barrierSequence = invocationSequence + 1
        switch state {
        case .active:
            state = .aborted(run)
        case .invoking(_, let writeID):
            state = .abortPending(run, writeID: writeID)
        case .abortPending, .aborted, .failed, .completed, .idle:
            lock.unlock()
            return
        }
        recordLocked(.abortBarrier, run: run, fields: [
            "abort_barrier_sequence": String(barrierSequence ?? -1),
            "note": note,
            "operator_recovery": "physical_power_cutoff_after_motion_capable_write"
        ])
        lock.unlock()
    }

    func finish(token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .active(let run) = state,
              run.token == token,
              nextRoleIndex == run.expectedRoles.count,
              delayedActions.isEmpty else {
            return false
        }
        state = .completed(run)
        return true
    }

    func snapshot() -> State {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func isQuiescent() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard delayedActions.isEmpty else { return false }
        if case .completed = state { return true }
        return false
    }

    private func runDelayed(
        actionID: UUID,
        role: BLETransportCodec.StopTruthExperimentCommandRole,
        token: UUID,
        scheduledAt: StopTruthExperimentTimestamp,
        nominalDelay: TimeInterval,
        maximumLateness: TimeInterval,
        shouldEnqueue: () -> Bool
    ) {
        lock.lock()
        guard delayedActions.removeValue(forKey: actionID) != nil,
              case .active(let run) = state,
              run.token == token else {
            lock.unlock()
            return
        }
        guard let firedAt = clock.now(),
              firedAt.originID == scheduledAt.originID,
              firedAt.monotonicUptimeNanoseconds >= scheduledAt.monotonicUptimeNanoseconds else {
            state = .failed(run, reason: "monotonic_clock_discontinuity")
            recordLocked(.timingInvalid, run: run, fields: ["reason": "monotonic_clock_discontinuity"])
            lock.unlock()
            onFailure?("monotonic_clock_discontinuity")
            return
        }
        let actualDelay = Double(
            firedAt.monotonicUptimeNanoseconds - scheduledAt.monotonicUptimeNanoseconds
        ) / 1_000_000_000
        guard actualDelay <= nominalDelay + maximumLateness else {
            state = .failed(run, reason: "critical_timing_discontinuity")
            recordLocked(.timingInvalid, run: run, fields: [
                "reason": "critical_timing_discontinuity",
                "nominal_delay_s": String(nominalDelay),
                "actual_delay_s": String(actualDelay)
            ])
            lock.unlock()
            onFailure?("critical_timing_discontinuity")
            return
        }
        lock.unlock()
        guard shouldEnqueue() else { return }
        _ = enqueue(role: role, token: token)
    }

    private func invoke(
        packet: Data,
        role: BLETransportCodec.StopTruthExperimentCommandRole,
        writeID: UUID,
        token: UUID
    ) {
        lock.lock()
        guard case .active(let run) = state,
              run.token == token else {
            recordLocked(.rejectedAfterAbort, run: currentRunLocked(), fields: [
                "phase": "transport_invocation",
                "write_id": writeID.uuidString,
                "role": role.rawValue
            ])
            lock.unlock()
            return
        }
        invocationSequence += 1
        let sequence = invocationSequence
        state = .invoking(run, writeID: writeID)
        recordLocked(.transportInvoked, run: run, fields: [
            "write_id": writeID.uuidString,
            "invocation_sequence": String(sequence),
            "role": role.rawValue,
            "priority": role == .initialStop ? "high" : "regular",
            "overlapped_abort_barrier": "false"
        ])
        transport.invoke(packet: packet, role: role, writeID: writeID) { [weak self] result in
            self?.completeInvocation(run: run, writeID: writeID, sequence: sequence, result: result)
        }
        lock.unlock()
    }

    private func completeInvocation(
        run: Run,
        writeID: UUID,
        sequence: Int,
        result: Result<StopTruthExperimentTransportReceipt, Error>
    ) {
        lock.lock()
        let overlapped: Bool
        switch state {
        case .invoking(let currentRun, let currentWriteID)
            where currentRun == run && currentWriteID == writeID:
            overlapped = false
            state = result.isSuccess ? .active(run) : .failed(run, reason: "transport_invocation_failed")
        case .abortPending(let currentRun, let currentWriteID)
            where currentRun == run && currentWriteID == writeID:
            overlapped = true
            state = .aborted(run)
        default:
            lock.unlock()
            return
        }
        var resultFields: [String: String] = [
            "write_id": writeID.uuidString,
            "invocation_sequence": String(sequence),
            "result": result.isSuccess ? "success" : "failure",
            "overlapped_abort_barrier": String(overlapped),
            "abort_barrier_sequence": barrierSequence.map(String.init) ?? ""
        ]
        if case .success(let receipt) = result {
            resultFields["characteristic_uuid"] = receipt.characteristicUUID
            resultFields["write_type"] = receipt.writeType
        }
        recordLocked(.transportResult, run: run, fields: resultFields)
        lock.unlock()
        if !result.isSuccess, !overlapped {
            onFailure?("transport_invocation_failed")
        }
    }

    private func currentRunLocked() -> Run? {
        switch state {
        case .active(let run), .invoking(let run, _), .abortPending(let run, _),
             .aborted(let run), .failed(let run, _), .completed(let run):
            return run
        case .idle:
            return nil
        }
    }

    private func recordLocked(
        _ event: StopTruthExperimentEvidenceEvent,
        run: Run?,
        fields: [String: String]
    ) {
        guard let run, let timestamp = clock.now() else { return }
        var fields = fields
        fields["run_state"] = stateLabelLocked()
        evidenceSink?.append(StopTruthExperimentEvidenceRecord(
            event: event,
            experimentID: run.experimentID,
            caseID: StopTruthExperimentPlanService.caseID,
            repetition: run.repetition,
            timestamp: timestamp,
            fields: fields
        ))
    }

    private func stateLabelLocked() -> String {
        switch state {
        case .idle: return "idle"
        case .active: return "active"
        case .invoking: return "invoking"
        case .abortPending: return "abort_pending"
        case .aborted: return "aborted"
        case .failed: return "failed"
        case .completed: return "completed"
        }
    }
}

private extension Result where Success == StopTruthExperimentTransportReceipt {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
