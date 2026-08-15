import Foundation

public struct RecorderHealthSummary: Codable, Hashable, Sendable {
    public let isComplete: Bool
    public let lostCriticalRecordCount: UInt64
    public let lostNativeRecordCount: UInt64
    public let lastPersistedElapsed: ElapsedDuration?

    public init(
        isComplete: Bool,
        lostCriticalRecordCount: UInt64,
        lostNativeRecordCount: UInt64,
        lastPersistedElapsed: ElapsedDuration?
    ) {
        self.isComplete = isComplete
        self.lostCriticalRecordCount = lostCriticalRecordCount
        self.lostNativeRecordCount = lostNativeRecordCount
        self.lastPersistedElapsed = lastPersistedElapsed
    }
}
public struct KnownTreadmillMetadata: Codable, Hashable, Sendable {
    public let stableLocalIdentifier: String?
    public let model: String?
    public let protocolName: String?
    public let protocolVersion: String?

    public init(
        stableLocalIdentifier: String? = nil,
        model: String? = nil,
        protocolName: String? = nil,
        protocolVersion: String? = nil
    ) {
        self.stableLocalIdentifier = stableLocalIdentifier
        self.model = model
        self.protocolName = protocolName
        self.protocolVersion = protocolVersion
    }
}

public struct WorkoutSessionRecord: Codable, Hashable, Sendable {
    public let recordID: RecordID
    public let sessionID: SessionID
    public let profileLocalIdentifier: String
    public let lifecycleState: SessionLifecycleState
    public let workoutMode: WorkoutMode
    public let startedAt: Date
    public let endedAt: Date?
    public let endedElapsed: ElapsedDuration?
    public let incompleteReason: String?
    public let appContext: AppRuntimeContext
    public let versions: RuntimeVersionContext
    public let configuration: ImmutableConfigurationSnapshot
    public let healthKitWorkoutIdentifier: UUID?
    public let treadmill: KnownTreadmillMetadata?
    public let recorderHealth: RecorderHealthSummary

    public init(
        recordID: RecordID,
        sessionID: SessionID,
        profileLocalIdentifier: String,
        lifecycleState: SessionLifecycleState,
        workoutMode: WorkoutMode,
        startedAt: Date,
        endedAt: Date?,
        endedElapsed: ElapsedDuration?,
        incompleteReason: String?,
        appContext: AppRuntimeContext,
        versions: RuntimeVersionContext,
        configuration: ImmutableConfigurationSnapshot,
        healthKitWorkoutIdentifier: UUID?,
        treadmill: KnownTreadmillMetadata?,
        recorderHealth: RecorderHealthSummary
    ) {
        self.recordID = recordID
        self.sessionID = sessionID
        self.profileLocalIdentifier = profileLocalIdentifier
        self.lifecycleState = lifecycleState
        self.workoutMode = workoutMode
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.endedElapsed = endedElapsed
        self.incompleteReason = incompleteReason
        self.appContext = appContext
        self.versions = versions
        self.configuration = configuration
        self.healthKitWorkoutIdentifier = healthKitWorkoutIdentifier
        self.treadmill = treadmill
        self.recorderHealth = recorderHealth
    }
}

public enum AnalysisQualityGrade: String, Codable, Hashable, Sendable {
    case high
    case medium
    case low
    case unusable
}

public struct AnalysisExclusion: Codable, Hashable, Sendable {
    public let code: String
    public let detail: String?

    public init(code: String, detail: String? = nil) {
        self.code = code
        self.detail = detail
    }
}

public struct AnalysisKeyMetrics: Codable, Hashable, Sendable {
    public let coveredDuration: ElapsedDuration
    public let averageHeartRate: Double?
    public let maximumHeartRate: UInt16?
    public let averageFactualSpeedKilometresPerHour: Double?

    public init(
        coveredDuration: ElapsedDuration,
        averageHeartRate: Double?,
        maximumHeartRate: UInt16?,
        averageFactualSpeedKilometresPerHour: Double?
    ) {
        self.coveredDuration = coveredDuration
        self.averageHeartRate = averageHeartRate
        self.maximumHeartRate = maximumHeartRate
        self.averageFactualSpeedKilometresPerHour = averageFactualSpeedKilometresPerHour
    }
}

public struct WorkoutAnalysisResult: Codable, Hashable, Sendable {
    public let analysisID: AnalysisID
    public let recordID: RecordID
    public let sessionID: SessionID
    public let analyzerVersion: AnalyzerVersion
    public let evidenceHash: ContentHash
    public let generatedAt: Date
    public let qualityGrade: AnalysisQualityGrade
    public let exclusions: [AnalysisExclusion]
    public let keyMetrics: AnalysisKeyMetrics
    public let detailSchemaVersion: UInt16
    public let versionedDetailPayload: Data

    public init(
        analysisID: AnalysisID,
        recordID: RecordID,
        sessionID: SessionID,
        analyzerVersion: AnalyzerVersion,
        evidenceHash: ContentHash,
        generatedAt: Date,
        qualityGrade: AnalysisQualityGrade,
        exclusions: [AnalysisExclusion],
        keyMetrics: AnalysisKeyMetrics,
        detailSchemaVersion: UInt16,
        versionedDetailPayload: Data
    ) {
        self.analysisID = analysisID
        self.recordID = recordID
        self.sessionID = sessionID
        self.analyzerVersion = analyzerVersion
        self.evidenceHash = evidenceHash
        self.generatedAt = generatedAt
        self.qualityGrade = qualityGrade
        self.exclusions = exclusions
        self.keyMetrics = keyMetrics
        self.detailSchemaVersion = detailSchemaVersion
        self.versionedDetailPayload = versionedDetailPayload
    }
}
