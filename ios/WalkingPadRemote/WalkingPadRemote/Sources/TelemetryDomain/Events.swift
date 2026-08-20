import Foundation

public enum WorkoutMode: Codable, Hashable, Sendable {
    case heartRateControlled
    case manual
    case other(String)
}

public enum WorkoutPhase: Codable, Hashable, Sendable {
    case warmup
    case main
    case cooldown
    case finished
    case unknown
    case other(String)
}

public enum SessionLifecycleState: String, Codable, Hashable, Sendable {
    case created
    case running
    case paused
    case completed
    case incomplete
    case cancelled
}

public enum ObservationReference: Codable, Hashable, Sendable {
    case heartRate(ObservationID)
    case treadmill(ObservationID)
}

public enum ControlTarget: Codable, Hashable, Sendable {
    case none
    case heartRate(beatsPerMinute: UInt16)
    case desiredSpeed(DesiredSpeedKilometresPerHour)
    case stop
}

public enum ControlAction: Codable, Hashable, Sendable {
    case noCommand
    case enqueueSpeed(DesiredSpeedKilometresPerHour)
    case enqueueStop
}

public enum ControlDecisionReason: Codable, Hashable, Sendable {
    case withinTarget
    case belowTarget
    case aboveTarget
    case safetyGate(String)
    case manual
    case other(String)
}

public extension ControlDecisionReason {
    static let heartRateInertiaHold = Self.other("inertiaHold")
    static let heartRateSpeedLimit = Self.other("speedLimit")
}

public struct ControlDecision: Codable, Hashable, Sendable {
    public let decisionID: DecisionID
    public let observationsUsed: [ObservationReference]
    public let target: ControlTarget
    public let action: ControlAction
    public let reason: ControlDecisionReason
    public let versions: RuntimeVersionContext
    public let configurationSnapshotID: ConfigurationSnapshotID

    public init(
        decisionID: DecisionID,
        observationsUsed: [ObservationReference],
        target: ControlTarget,
        action: ControlAction,
        reason: ControlDecisionReason,
        versions: RuntimeVersionContext,
        configurationSnapshotID: ConfigurationSnapshotID
    ) {
        self.decisionID = decisionID
        self.observationsUsed = observationsUsed
        self.target = target
        self.action = action
        self.reason = reason
        self.versions = versions
        self.configurationSnapshotID = configurationSnapshotID
    }
}

public enum CommandKind: Codable, Hashable, Sendable {
    case setSpeed(CommandedSpeed)
    case stop
    case other(String)
}

public enum CommandCancellationReason: Codable, Hashable, Sendable {
    case superseded
    case sessionEnded
    case safetyGate(String)
    case other(String)
}

public enum CommandFailureReason: Codable, Hashable, Sendable {
    case transportUnavailable
    case encodingFailed
    case rejected
    case other(String)
}

public enum CommandLifecycle: Codable, Hashable, Sendable {
    case enqueued(kind: CommandKind)
    case sendAttempt(attemptID: CommandAttemptID, attemptNumber: UInt16)
    case acknowledged(attemptID: CommandAttemptID)
    case timedOut(attemptID: CommandAttemptID)
    case retryScheduled(
        previousAttemptID: CommandAttemptID,
        nextAttemptID: CommandAttemptID,
        nextAttemptNumber: UInt16
    )
    case cancelled(reason: CommandCancellationReason)
    case failed(attemptID: CommandAttemptID?, reason: CommandFailureReason)
}

public struct CommandLifecycleRecord: Codable, Hashable, Sendable {
    public let commandID: CommandID
    public let decisionID: DecisionID?
    public let lifecycle: CommandLifecycle

    public init(commandID: CommandID, decisionID: DecisionID?, lifecycle: CommandLifecycle) {
        self.commandID = commandID
        self.decisionID = decisionID
        self.lifecycle = lifecycle
    }
}

public struct SessionLifecycleEvent: Codable, Hashable, Sendable {
    public let previous: SessionLifecycleState?
    public let current: SessionLifecycleState
    public let incompleteReason: String?
    public let reason: String?

    public init(
        previous: SessionLifecycleState?,
        current: SessionLifecycleState,
        incompleteReason: String? = nil,
        reason: String? = nil
    ) {
        self.previous = previous
        self.current = current
        self.incompleteReason = incompleteReason
        self.reason = reason
    }
}

public enum HeartRateRuntimeEvidence: Codable, Hashable, Sendable {
    case delivery(HeartRateNormalizationResult)
    case sourceLifecycle(HeartRateSourceLifecycleEvidence)
    case controlUse(HeartRateControlUseEvidence)
}

public struct WorkoutPhaseTransition: Codable, Hashable, Sendable {
    public let previous: WorkoutPhase?
    public let current: WorkoutPhase

    public init(previous: WorkoutPhase?, current: WorkoutPhase) {
        self.previous = previous
        self.current = current
    }
}

public struct SourceTransition: Codable, Hashable, Sendable {
    public let previousSourceID: SourceID?
    public let currentSourceID: SourceID?
    public let reason: String

    public init(previousSourceID: SourceID?, currentSourceID: SourceID?, reason: String) {
        self.previousSourceID = previousSourceID
        self.currentSourceID = currentSourceID
        self.reason = reason
    }
}

public enum ConnectionState: String, Codable, Hashable, Sendable {
    case disconnected
    case connecting
    case connected
    case degraded
}

public struct ConnectionTransition: Codable, Hashable, Sendable {
    public let previous: ConnectionState
    public let current: ConnectionState
    public let reason: String?

    public init(previous: ConnectionState, current: ConnectionState, reason: String? = nil) {
        self.previous = previous
        self.current = current
        self.reason = reason
    }
}

public enum CooldownLifecycle: String, Codable, Hashable, Sendable {
    case started
    case targetChanged
    case completed
    case insufficient
    case cancelled
}

public struct CooldownEvent: Codable, Hashable, Sendable {
    public let lifecycle: CooldownLifecycle
    public let targetHeartRate: UInt16?

    public init(lifecycle: CooldownLifecycle, targetHeartRate: UInt16? = nil) {
        self.lifecycle = lifecycle
        self.targetHeartRate = targetHeartRate
    }
}

public struct ManualStopEvent: Codable, Hashable, Sendable {
    public let reason: String?

    public init(reason: String? = nil) {
        self.reason = reason
    }
}

public enum SafetyEventOutcome: String, Codable, Hashable, Sendable {
    case allowed
    case blocked
    case failedClosed
}

public struct SafetyEvent: Codable, Hashable, Sendable {
    public let policy: SafetyPolicyVersion
    public let gate: String
    public let outcome: SafetyEventOutcome
    public let evidence: [ObservationReference]

    public init(
        policy: SafetyPolicyVersion,
        gate: String,
        outcome: SafetyEventOutcome,
        evidence: [ObservationReference]
    ) {
        self.policy = policy
        self.gate = gate
        self.outcome = outcome
        self.evidence = evidence
    }
}

public enum StopEvidenceConclusion: Codable, Hashable, Sendable {
    case confirmedByFreshFactualObservation(ObservationID)
    case unconfirmed(reason: String)
    case contradictory(reason: String)
}

public struct StopEvidenceEvent: Codable, Hashable, Sendable {
    public let conclusion: StopEvidenceConclusion
    public let freshness: EvidenceFreshness?
    public let deviceState: TreadmillDeviceState?
    public let factualSpeed: FactualSpeedKilometresPerHour?

    public init(
        conclusion: StopEvidenceConclusion,
        freshness: EvidenceFreshness?,
        deviceState: TreadmillDeviceState?,
        factualSpeed: FactualSpeedKilometresPerHour?
    ) {
        self.conclusion = conclusion
        self.freshness = freshness
        self.deviceState = deviceState
        self.factualSpeed = factualSpeed
    }
}

public enum RecorderHealthKind: String, Codable, Hashable, Sendable {
    case pressure
    case loss
    case drain
    case persistence
    case recovery
}

public struct RecorderHealthEvent: Codable, Hashable, Sendable {
    public let kind: RecorderHealthKind
    public let affectedRecordClass: String?
    public let count: UInt64?
    public let firstAffectedElapsed: ElapsedDuration?
    public let lastAffectedElapsed: ElapsedDuration?
    public let detailCode: String?

    public init(
        kind: RecorderHealthKind,
        affectedRecordClass: String? = nil,
        count: UInt64? = nil,
        firstAffectedElapsed: ElapsedDuration? = nil,
        lastAffectedElapsed: ElapsedDuration? = nil,
        detailCode: String? = nil
    ) {
        self.kind = kind
        self.affectedRecordClass = affectedRecordClass
        self.count = count
        self.firstAffectedElapsed = firstAffectedElapsed
        self.lastAffectedElapsed = lastAffectedElapsed
        self.detailCode = detailCode
    }
}

public enum WorkoutEventPayload: Codable, Hashable, Sendable {
    case sessionLifecycle(SessionLifecycleEvent)
    case workoutPhase(WorkoutPhaseTransition)
    case sourceTransition(SourceTransition)
    case connectionTransition(ConnectionTransition)
    case controlDecision(ControlDecision)
    case commandLifecycle(CommandLifecycleRecord)
    case cooldown(CooldownEvent)
    case manualStop(ManualStopEvent)
    case safety(SafetyEvent)
    case stopEvidence(StopEvidenceEvent)
    case recorderHealth(RecorderHealthEvent)
    case heartRateEvidence(HeartRateRuntimeEvidence)
    case treadmillEvidence(TreadmillTelemetryEvidence)

    public var kind: WorkoutEventKind {
        switch self {
        case .sessionLifecycle: .sessionLifecycle
        case .workoutPhase: .workoutPhase
        case .sourceTransition: .sourceTransition
        case .connectionTransition: .connectionTransition
        case .controlDecision: .controlDecision
        case .commandLifecycle: .commandLifecycle
        case .cooldown: .cooldown
        case .manualStop: .manualStop
        case .safety: .safety
        case .stopEvidence: .stopEvidence
        case .recorderHealth: .recorderHealth
        case .heartRateEvidence: .heartRateEvidence
        case .treadmillEvidence: .treadmillEvidence
        }
    }

    public var causalIDs: WorkoutEventCausalIDs {
        switch self {
        case let .controlDecision(decision):
            WorkoutEventCausalIDs(
                decisionID: decision.decisionID,
                commandID: nil,
                attemptID: nil
            )
        case let .commandLifecycle(record):
            WorkoutEventCausalIDs(
                decisionID: record.decisionID,
                commandID: record.commandID,
                attemptID: record.lifecycle.primaryAttemptID
            )
        case let .treadmillEvidence(evidence):
            evidence.causalIDs
        default:
            WorkoutEventCausalIDs(decisionID: nil, commandID: nil, attemptID: nil)
        }
    }
}

private extension CommandLifecycle {
    var primaryAttemptID: CommandAttemptID? {
        switch self {
        case .enqueued, .cancelled:
            nil
        case let .sendAttempt(attemptID, _),
             let .acknowledged(attemptID),
             let .timedOut(attemptID):
            attemptID
        case let .retryScheduled(_, nextAttemptID, _):
            nextAttemptID
        case let .failed(attemptID, _):
            attemptID
        }
    }
}

public struct WorkoutEventCausalIDs: Codable, Hashable, Sendable {
    public let decisionID: DecisionID?
    public let commandID: CommandID?
    public let attemptID: CommandAttemptID?

    public init(
        decisionID: DecisionID?,
        commandID: CommandID?,
        attemptID: CommandAttemptID?
    ) {
        self.decisionID = decisionID
        self.commandID = commandID
        self.attemptID = attemptID
    }
}

public enum WorkoutEventKind: String, Codable, Hashable, Sendable {
    case sessionLifecycle
    case workoutPhase
    case sourceTransition
    case connectionTransition
    case controlDecision
    case commandLifecycle
    case cooldown
    case manualStop
    case safety
    case stopEvidence
    case recorderHealth
    case heartRateEvidence
    case treadmillEvidence
}

private extension TreadmillTelemetryEvidence {
    var causalIDs: WorkoutEventCausalIDs {
        switch self {
        case let .observation(evidence):
            return WorkoutEventCausalIDs(
                decisionID: nil,
                commandID: evidence.commandID,
                attemptID: evidence.attemptID
            )
        case .unitsTruth, .unassociatedWrite:
            return WorkoutEventCausalIDs(decisionID: nil, commandID: nil, attemptID: nil)
        case let .decision(evidence):
            return WorkoutEventCausalIDs(
                decisionID: evidence.decisionID,
                commandID: nil,
                attemptID: nil
            )
        case let .commandEnqueued(evidence):
            return WorkoutEventCausalIDs(
                decisionID: evidence.decisionID,
                commandID: evidence.commandID,
                attemptID: nil
            )
        case let .commandQueueDelay(evidence):
            return WorkoutEventCausalIDs(
                decisionID: evidence.decisionID,
                commandID: evidence.commandID,
                attemptID: nil
            )
        case let .sendAttempt(evidence):
            return WorkoutEventCausalIDs(
                decisionID: evidence.decisionID,
                commandID: evidence.commandID,
                attemptID: evidence.attemptID
            )
        case let .acknowledgement(evidence):
            return WorkoutEventCausalIDs(
                decisionID: nil,
                commandID: evidence.commandID,
                attemptID: evidence.attemptID
            )
        case let .writeResult(evidence):
            return WorkoutEventCausalIDs(
                decisionID: nil,
                commandID: evidence.commandID,
                attemptID: evidence.attemptID
            )
        case let .commandTimeout(evidence):
            return WorkoutEventCausalIDs(
                decisionID: nil,
                commandID: evidence.commandID,
                attemptID: evidence.attemptID
            )
        case let .commandFailed(evidence):
            return WorkoutEventCausalIDs(
                decisionID: evidence.decisionID,
                commandID: evidence.commandID,
                attemptID: evidence.attemptID
            )
        case let .commandCancelled(evidence):
            return WorkoutEventCausalIDs(
                decisionID: evidence.decisionID,
                commandID: evidence.commandID,
                attemptID: nil
            )
        case let .stopEvidence(evidence):
            return WorkoutEventCausalIDs(
                decisionID: evidence.decisionID,
                commandID: evidence.commandID,
                attemptID: nil
            )
        }
    }
}

public struct EventPayloadEnvelope: Codable, Hashable, Sendable {
    public let schemaVersion: UInt16
    public let payload: WorkoutEventPayload

    public init(schemaVersion: UInt16, payload: WorkoutEventPayload) {
        self.schemaVersion = schemaVersion
        self.payload = payload
    }
}

public struct WorkoutEvent: Codable, Hashable, Sendable {
    public let recordID: RecordID
    public let sessionID: SessionID
    public let kind: WorkoutEventKind
    public let timestamp: EventTimestamp
    public let sourceID: SourceID?
    public let decisionID: DecisionID?
    public let commandID: CommandID?
    public let attemptID: CommandAttemptID?
    public let payload: EventPayloadEnvelope

    private struct CodingRepresentation: Codable {
        let recordID: RecordID
        let sessionID: SessionID
        let kind: WorkoutEventKind
        let timestamp: EventTimestamp
        let sourceID: SourceID?
        let decisionID: DecisionID?
        let commandID: CommandID?
        let attemptID: CommandAttemptID?
        let payload: EventPayloadEnvelope
    }

    public init(
        recordID: RecordID,
        sessionID: SessionID,
        timestamp: EventTimestamp,
        sourceID: SourceID? = nil,
        payload: EventPayloadEnvelope
    ) {
        let causalIDs = payload.payload.causalIDs
        self.recordID = recordID
        self.sessionID = sessionID
        self.kind = payload.payload.kind
        self.timestamp = timestamp
        self.sourceID = sourceID
        self.decisionID = causalIDs.decisionID
        self.commandID = causalIDs.commandID
        self.attemptID = causalIDs.attemptID
        self.payload = payload
    }

    public init(from decoder: Decoder) throws {
        let representation = try CodingRepresentation(from: decoder)
        self.init(
            recordID: representation.recordID,
            sessionID: representation.sessionID,
            timestamp: representation.timestamp,
            sourceID: representation.sourceID,
            payload: representation.payload
        )
        guard representation.kind == kind,
              representation.decisionID == decisionID,
              representation.commandID == commandID,
              representation.attemptID == attemptID
        else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Workout event envelope contradicts its typed payload."
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        try CodingRepresentation(
            recordID: recordID,
            sessionID: sessionID,
            kind: kind,
            timestamp: timestamp,
            sourceID: sourceID,
            decisionID: decisionID,
            commandID: commandID,
            attemptID: attemptID,
            payload: payload
        ).encode(to: encoder)
    }
}
