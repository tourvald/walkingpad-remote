import Foundation
import SwiftData

enum TelemetrySchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            TelemetryConfigurationSnapshotV1.self,
            TelemetryWorkoutSessionV1.self,
            TelemetrySignalSourceV1.self,
            TelemetryHeartRateSampleV1.self,
            TelemetryTreadmillSampleV1.self,
            TelemetryWorkoutEventV1.self,
            TelemetryWorkoutFrameV1.self,
            TelemetryWorkoutAnalysisV1.self,
        ]
    }
}

enum TelemetryMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [TelemetrySchemaV1.self]
    }

    public static var stages: [MigrationStage] {
        []
    }
}

@Model
final class TelemetryConfigurationSnapshotV1 {
    #Index<TelemetryConfigurationSnapshotV1>([\.contentHashDigest])

    @Attribute(.unique) public var snapshotID: String
    public var formatVersion: Int
    public var formatKey: String
    public var canonicalPayload: Data
    public var hashAlgorithmKey: String
    public var contentHashDigest: String

    public init(
        snapshotID: String,
        formatVersion: Int,
        formatKey: String,
        canonicalPayload: Data,
        hashAlgorithmKey: String,
        contentHashDigest: String
    ) {
        self.snapshotID = snapshotID
        self.formatVersion = formatVersion
        self.formatKey = formatKey
        self.canonicalPayload = canonicalPayload
        self.hashAlgorithmKey = hashAlgorithmKey
        self.contentHashDigest = contentHashDigest
    }
}

@Model
final class TelemetryWorkoutSessionV1 {
    #Index<TelemetryWorkoutSessionV1>([\.startedAt], [\.profileLocalIdentifier, \.startedAt])

    @Attribute(.unique) public var sessionID: String
    @Attribute(.unique) public var recordID: String
    public var profileLocalIdentifier: String
    public var lifecycleStateKey: String
    public var workoutModePayload: Data
    public var startedAt: Date
    public var endedAt: Date?
    public var endedElapsedMicroseconds: Int64?
    public var incompleteReason: String?
    public var appVersion: String
    public var buildNumber: String
    public var operatingSystemVersion: String
    public var deviceModel: String?
    public var telemetrySchemaVersion: String
    public var algorithmVersion: String
    public var safetyPolicyVersion: String
    public var workoutProtocolVersion: String
    public var healthKitWorkoutIdentifier: String?
    public var treadmillMetadataPayload: Data?
    public var recorderIsComplete: Bool
    public var lostCriticalRecordCount: Int64
    public var lostNativeRecordCount: Int64
    public var lastPersistedElapsedMicroseconds: Int64?
    public var configuration: TelemetryConfigurationSnapshotV1?

    @Relationship(deleteRule: .cascade, inverse: \TelemetryHeartRateSampleV1.session)
    public var heartRateSamples: [TelemetryHeartRateSampleV1] = []

    @Relationship(deleteRule: .cascade, inverse: \TelemetryTreadmillSampleV1.session)
    public var treadmillSamples: [TelemetryTreadmillSampleV1] = []

    @Relationship(deleteRule: .cascade, inverse: \TelemetryWorkoutEventV1.session)
    public var events: [TelemetryWorkoutEventV1] = []

    @Relationship(deleteRule: .cascade, inverse: \TelemetryWorkoutFrameV1.session)
    public var frames: [TelemetryWorkoutFrameV1] = []

    @Relationship(deleteRule: .cascade, inverse: \TelemetryWorkoutAnalysisV1.session)
    public var analyses: [TelemetryWorkoutAnalysisV1] = []

    public init(
        sessionID: String,
        recordID: String,
        profileLocalIdentifier: String,
        lifecycleStateKey: String,
        workoutModePayload: Data,
        startedAt: Date,
        endedAt: Date?,
        endedElapsedMicroseconds: Int64?,
        incompleteReason: String?,
        appVersion: String,
        buildNumber: String,
        operatingSystemVersion: String,
        deviceModel: String?,
        telemetrySchemaVersion: String,
        algorithmVersion: String,
        safetyPolicyVersion: String,
        workoutProtocolVersion: String,
        healthKitWorkoutIdentifier: String?,
        treadmillMetadataPayload: Data?,
        recorderIsComplete: Bool,
        lostCriticalRecordCount: Int64,
        lostNativeRecordCount: Int64,
        lastPersistedElapsedMicroseconds: Int64?,
        configuration: TelemetryConfigurationSnapshotV1
    ) {
        self.sessionID = sessionID
        self.recordID = recordID
        self.profileLocalIdentifier = profileLocalIdentifier
        self.lifecycleStateKey = lifecycleStateKey
        self.workoutModePayload = workoutModePayload
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.endedElapsedMicroseconds = endedElapsedMicroseconds
        self.incompleteReason = incompleteReason
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.operatingSystemVersion = operatingSystemVersion
        self.deviceModel = deviceModel
        self.telemetrySchemaVersion = telemetrySchemaVersion
        self.algorithmVersion = algorithmVersion
        self.safetyPolicyVersion = safetyPolicyVersion
        self.workoutProtocolVersion = workoutProtocolVersion
        self.healthKitWorkoutIdentifier = healthKitWorkoutIdentifier
        self.treadmillMetadataPayload = treadmillMetadataPayload
        self.recorderIsComplete = recorderIsComplete
        self.lostCriticalRecordCount = lostCriticalRecordCount
        self.lostNativeRecordCount = lostNativeRecordCount
        self.lastPersistedElapsedMicroseconds = lastPersistedElapsedMicroseconds
        self.configuration = configuration
    }
}

@Model
final class TelemetrySignalSourceV1 {
    #Index<TelemetrySignalSourceV1>([\.providerKindKey, \.stableLocalKey], [\.lastSeen])

    @Attribute(.unique) public var sourceID: String
    @Attribute(.unique) public var stableIdentityKey: String
    public var providerKindKey: String
    public var providerKindPayload: Data
    public var stableLocalKey: String
    public var savingSourcePayload: Data?
    public var knownDevicePayload: Data?
    public var firstSeen: Date
    public var lastSeen: Date

    public init(
        sourceID: String,
        stableIdentityKey: String,
        providerKindKey: String,
        providerKindPayload: Data,
        stableLocalKey: String,
        savingSourcePayload: Data?,
        knownDevicePayload: Data?,
        firstSeen: Date,
        lastSeen: Date
    ) {
        self.sourceID = sourceID
        self.stableIdentityKey = stableIdentityKey
        self.providerKindKey = providerKindKey
        self.providerKindPayload = providerKindPayload
        self.stableLocalKey = stableLocalKey
        self.savingSourcePayload = savingSourcePayload
        self.knownDevicePayload = knownDevicePayload
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

@Model
final class TelemetryHeartRateSampleV1 {
    #Index<TelemetryHeartRateSampleV1>(
        [\.sessionID, \.receivedElapsedMicroseconds],
        [\.sourceID, \.arrivalOrder]
    )

    @Attribute(.unique) public var observationID: String
    @Attribute(.unique) public var recordID: String
    public var sessionID: String
    public var sourceID: String
    public var beatsPerMinute: Int
    public var arrivalOrder: Int64
    public var providerSequence: Int64?
    public var providerSampleIdentifier: String?
    public var measuredAt: Date?
    public var receivedAt: Date
    public var recordedAt: Date
    public var measuredElapsedMicroseconds: Int64?
    public var receivedElapsedMicroseconds: Int64
    public var recordedElapsedMicroseconds: Int64
    public var provenanceKey: String
    public var freshnessPayload: Data
    public var qualityPayload: Data
    public var controlUseKey: String
    public var session: TelemetryWorkoutSessionV1?
    public var source: TelemetrySignalSourceV1?

    public init(
        observationID: String,
        recordID: String,
        sessionID: String,
        sourceID: String,
        beatsPerMinute: Int,
        arrivalOrder: Int64,
        providerSequence: Int64?,
        providerSampleIdentifier: String?,
        measuredAt: Date?,
        receivedAt: Date,
        recordedAt: Date,
        measuredElapsedMicroseconds: Int64?,
        receivedElapsedMicroseconds: Int64,
        recordedElapsedMicroseconds: Int64,
        provenanceKey: String,
        freshnessPayload: Data,
        qualityPayload: Data,
        controlUseKey: String,
        session: TelemetryWorkoutSessionV1,
        source: TelemetrySignalSourceV1
    ) {
        self.observationID = observationID
        self.recordID = recordID
        self.sessionID = sessionID
        self.sourceID = sourceID
        self.beatsPerMinute = beatsPerMinute
        self.arrivalOrder = arrivalOrder
        self.providerSequence = providerSequence
        self.providerSampleIdentifier = providerSampleIdentifier
        self.measuredAt = measuredAt
        self.receivedAt = receivedAt
        self.recordedAt = recordedAt
        self.measuredElapsedMicroseconds = measuredElapsedMicroseconds
        self.receivedElapsedMicroseconds = receivedElapsedMicroseconds
        self.recordedElapsedMicroseconds = recordedElapsedMicroseconds
        self.provenanceKey = provenanceKey
        self.freshnessPayload = freshnessPayload
        self.qualityPayload = qualityPayload
        self.controlUseKey = controlUseKey
        self.session = session
        self.source = source
    }
}

@Model
final class TelemetryTreadmillSampleV1 {
    #Index<TelemetryTreadmillSampleV1>(
        [\.sessionID, \.receivedElapsedMicroseconds],
        [\.sourceID, \.arrivalOrder]
    )

    @Attribute(.unique) public var observationID: String
    @Attribute(.unique) public var recordID: String
    public var sessionID: String
    public var sourceID: String
    public var nativeValue: Double
    public var nativeUnitKey: String
    public var nativeUnitPayload: Data
    public var factualKilometresPerHour: Double?
    public var deviceStateKey: String
    public var arrivalOrder: Int64
    public var measuredAt: Date?
    public var receivedAt: Date
    public var recordedAt: Date
    public var measuredElapsedMicroseconds: Int64?
    public var receivedElapsedMicroseconds: Int64
    public var recordedElapsedMicroseconds: Int64
    public var provenanceKey: String
    public var freshnessPayload: Data
    public var qualityPayload: Data
    public var session: TelemetryWorkoutSessionV1?
    public var source: TelemetrySignalSourceV1?

    public init(
        observationID: String,
        recordID: String,
        sessionID: String,
        sourceID: String,
        nativeValue: Double,
        nativeUnitKey: String,
        nativeUnitPayload: Data,
        factualKilometresPerHour: Double?,
        deviceStateKey: String,
        arrivalOrder: Int64,
        measuredAt: Date?,
        receivedAt: Date,
        recordedAt: Date,
        measuredElapsedMicroseconds: Int64?,
        receivedElapsedMicroseconds: Int64,
        recordedElapsedMicroseconds: Int64,
        provenanceKey: String,
        freshnessPayload: Data,
        qualityPayload: Data,
        session: TelemetryWorkoutSessionV1,
        source: TelemetrySignalSourceV1
    ) {
        self.observationID = observationID
        self.recordID = recordID
        self.sessionID = sessionID
        self.sourceID = sourceID
        self.nativeValue = nativeValue
        self.nativeUnitKey = nativeUnitKey
        self.nativeUnitPayload = nativeUnitPayload
        self.factualKilometresPerHour = factualKilometresPerHour
        self.deviceStateKey = deviceStateKey
        self.arrivalOrder = arrivalOrder
        self.measuredAt = measuredAt
        self.receivedAt = receivedAt
        self.recordedAt = recordedAt
        self.measuredElapsedMicroseconds = measuredElapsedMicroseconds
        self.receivedElapsedMicroseconds = receivedElapsedMicroseconds
        self.recordedElapsedMicroseconds = recordedElapsedMicroseconds
        self.provenanceKey = provenanceKey
        self.freshnessPayload = freshnessPayload
        self.qualityPayload = qualityPayload
        self.session = session
        self.source = source
    }
}

@Model
final class TelemetryWorkoutEventV1 {
    #Index<TelemetryWorkoutEventV1>([\.sessionID, \.kindKey, \.occurredElapsedMicroseconds])

    @Attribute(.unique) public var recordID: String
    public var sessionID: String
    public var kindKey: String
    public var occurredAt: Date
    public var recordedAt: Date
    public var occurredElapsedMicroseconds: Int64
    public var recordedElapsedMicroseconds: Int64
    public var sourceID: String?
    public var decisionID: String?
    public var commandID: String?
    public var attemptID: String?
    public var payloadSchemaVersion: Int
    public var payload: Data
    public var session: TelemetryWorkoutSessionV1?
    public var source: TelemetrySignalSourceV1?

    public init(
        recordID: String,
        sessionID: String,
        kindKey: String,
        occurredAt: Date,
        recordedAt: Date,
        occurredElapsedMicroseconds: Int64,
        recordedElapsedMicroseconds: Int64,
        sourceID: String?,
        decisionID: String?,
        commandID: String?,
        attemptID: String?,
        payloadSchemaVersion: Int,
        payload: Data,
        session: TelemetryWorkoutSessionV1,
        source: TelemetrySignalSourceV1?
    ) {
        self.recordID = recordID
        self.sessionID = sessionID
        self.kindKey = kindKey
        self.occurredAt = occurredAt
        self.recordedAt = recordedAt
        self.occurredElapsedMicroseconds = occurredElapsedMicroseconds
        self.recordedElapsedMicroseconds = recordedElapsedMicroseconds
        self.sourceID = sourceID
        self.decisionID = decisionID
        self.commandID = commandID
        self.attemptID = attemptID
        self.payloadSchemaVersion = payloadSchemaVersion
        self.payload = payload
        self.session = session
        self.source = source
    }
}

@Model
final class TelemetryWorkoutFrameV1 {
    #Index<TelemetryWorkoutFrameV1>([\.sessionID, \.canonicalElapsedSecond])

    @Attribute(.unique) public var frameID: String
    @Attribute(.unique) public var recordID: String
    @Attribute(.unique) public var canonicalIdentityKey: String
    public var sessionID: String
    public var canonicalElapsedSecond: Int64
    public var materializedAt: Date
    public var materializedElapsedMicroseconds: Int64
    public var heartRateEvidencePayload: Data?
    public var treadmillEvidencePayload: Data?
    public var precedingGapPayload: Data?
    public var session: TelemetryWorkoutSessionV1?

    public init(
        frameID: String,
        recordID: String,
        canonicalIdentityKey: String,
        sessionID: String,
        canonicalElapsedSecond: Int64,
        materializedAt: Date,
        materializedElapsedMicroseconds: Int64,
        heartRateEvidencePayload: Data?,
        treadmillEvidencePayload: Data?,
        precedingGapPayload: Data?,
        session: TelemetryWorkoutSessionV1
    ) {
        self.frameID = frameID
        self.recordID = recordID
        self.canonicalIdentityKey = canonicalIdentityKey
        self.sessionID = sessionID
        self.canonicalElapsedSecond = canonicalElapsedSecond
        self.materializedAt = materializedAt
        self.materializedElapsedMicroseconds = materializedElapsedMicroseconds
        self.heartRateEvidencePayload = heartRateEvidencePayload
        self.treadmillEvidencePayload = treadmillEvidencePayload
        self.precedingGapPayload = precedingGapPayload
        self.session = session
    }
}

@Model
final class TelemetryWorkoutAnalysisV1 {
    #Index<TelemetryWorkoutAnalysisV1>([\.sessionID, \.analyzerVersion, \.generatedAt])

    @Attribute(.unique) public var analysisID: String
    @Attribute(.unique) public var recordID: String
    @Attribute(.unique) public var analysisIdentityKey: String
    public var sessionID: String
    public var analyzerVersion: String
    public var evidenceHashAlgorithm: String
    public var evidenceHashDigest: String
    public var generatedAt: Date
    public var qualityGradeKey: String
    public var exclusionsPayload: Data
    public var coveredDurationMicroseconds: Int64
    public var averageHeartRate: Double?
    public var maximumHeartRate: Int?
    public var averageFactualSpeedKilometresPerHour: Double?
    public var detailSchemaVersion: Int
    public var detailPayload: Data
    public var session: TelemetryWorkoutSessionV1?

    public init(
        analysisID: String,
        recordID: String,
        analysisIdentityKey: String,
        sessionID: String,
        analyzerVersion: String,
        evidenceHashAlgorithm: String,
        evidenceHashDigest: String,
        generatedAt: Date,
        qualityGradeKey: String,
        exclusionsPayload: Data,
        coveredDurationMicroseconds: Int64,
        averageHeartRate: Double?,
        maximumHeartRate: Int?,
        averageFactualSpeedKilometresPerHour: Double?,
        detailSchemaVersion: Int,
        detailPayload: Data,
        session: TelemetryWorkoutSessionV1
    ) {
        self.analysisID = analysisID
        self.recordID = recordID
        self.analysisIdentityKey = analysisIdentityKey
        self.sessionID = sessionID
        self.analyzerVersion = analyzerVersion
        self.evidenceHashAlgorithm = evidenceHashAlgorithm
        self.evidenceHashDigest = evidenceHashDigest
        self.generatedAt = generatedAt
        self.qualityGradeKey = qualityGradeKey
        self.exclusionsPayload = exclusionsPayload
        self.coveredDurationMicroseconds = coveredDurationMicroseconds
        self.averageHeartRate = averageHeartRate
        self.maximumHeartRate = maximumHeartRate
        self.averageFactualSpeedKilometresPerHour = averageFactualSpeedKilometresPerHour
        self.detailSchemaVersion = detailSchemaVersion
        self.detailPayload = detailPayload
        self.session = session
    }
}
