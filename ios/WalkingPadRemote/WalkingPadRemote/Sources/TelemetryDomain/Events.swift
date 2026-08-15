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

    public init(
        previous: SessionLifecycleState?,
        current: SessionLifecycleState,
        incompleteReason: String? = nil
    ) {
        self.previous = previous
        self.current = current
        self.incompleteReason = incompleteReason
    }
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
    public let detailCode: String?

    public init(
        kind: RecorderHealthKind,
        affectedRecordClass: String? = nil,
        count: UInt64? = nil,
        detailCode: String? = nil
    ) {
        self.kind = kind
        self.affectedRecordClass = affectedRecordClass
        self.count = count
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
        }
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

    public init(
        recordID: RecordID,
        sessionID: SessionID,
        timestamp: EventTimestamp,
        sourceID: SourceID? = nil,
        decisionID: DecisionID? = nil,
        commandID: CommandID? = nil,
        attemptID: CommandAttemptID? = nil,
        payload: EventPayloadEnvelope
    ) {
        self.recordID = recordID
        self.sessionID = sessionID
        self.kind = payload.payload.kind
        self.timestamp = timestamp
        self.sourceID = sourceID
        self.decisionID = decisionID
        self.commandID = commandID
        self.attemptID = attemptID
        self.payload = payload
    }
}
