import Foundation

public enum LegacyMigrationSourceKind: String, Codable, Hashable, Sendable {
    case jsonl
    case workoutHistory
}

public enum LegacyMigrationSourceStatus: String, Codable, Hashable, Sendable {
    case pending
    case inProgress
    case paused
    case completed
    case failed
}

public enum LegacyWorkoutCandidateOrigin: String, Codable, Hashable, Sendable {
    case jsonl
    case workoutHistory
}

public enum LegacyIdentityStatus: String, Codable, Hashable, Sendable {
    case exact
    case uncertain
    case conflict
}

public enum LegacyReconciliationOutcome: String, Codable, Hashable, Sendable {
    case matched
    case conflict
}

public enum LegacyReconciliationIdentityKind: String, Codable, Hashable, Sendable {
    case workoutIdentifier
    case healthKitWorkoutIdentifier
    case stableLegacySessionIdentifier
}

public enum LegacyImportedSpeedEvidence: Codable, Hashable, Sendable {
    case factualDeviceReported(kilometresPerHour: Double, source: String)
    case legacyEstimated(kilometresPerHour: Double, field: String)
    case legacyUnknown(value: Double, field: String, reason: String)
}

public enum LegacyCausalAssociation: String, Codable, Hashable, Sendable {
    case notApplicable
    case unknown
    case unsupportedSpecificClaim
}

public struct LegacyImportedRecordPayload: Codable, Hashable, Sendable {
    public let eventName: String
    public let heartRateBeatsPerMinute: Int?
    public let targetBeatsPerMinute: Int?
    public let targetZoneIndex: Int?
    public let speedEvidence: LegacyImportedSpeedEvidence?
    public let desiredSpeedKilometresPerHour: Double?
    public let legacySummaryDurationSeconds: Int?
    public let legacySummaryAverageHeartRateBeatsPerMinute: Int?
    public let ignoredStepFieldPresent: Bool
    public let causalAssociation: LegacyCausalAssociation
    public let warnings: [String]

    public init(
        eventName: String,
        heartRateBeatsPerMinute: Int?,
        targetBeatsPerMinute: Int?,
        targetZoneIndex: Int?,
        speedEvidence: LegacyImportedSpeedEvidence?,
        desiredSpeedKilometresPerHour: Double?,
        legacySummaryDurationSeconds: Int?,
        legacySummaryAverageHeartRateBeatsPerMinute: Int?,
        ignoredStepFieldPresent: Bool,
        causalAssociation: LegacyCausalAssociation,
        warnings: [String]
    ) {
        self.eventName = eventName
        self.heartRateBeatsPerMinute = heartRateBeatsPerMinute
        self.targetBeatsPerMinute = targetBeatsPerMinute
        self.targetZoneIndex = targetZoneIndex
        self.speedEvidence = speedEvidence
        self.desiredSpeedKilometresPerHour = desiredSpeedKilometresPerHour
        self.legacySummaryDurationSeconds = legacySummaryDurationSeconds
        self.legacySummaryAverageHeartRateBeatsPerMinute =
            legacySummaryAverageHeartRateBeatsPerMinute
        self.ignoredStepFieldPresent = ignoredStepFieldPresent
        self.causalAssociation = causalAssociation
        self.warnings = warnings
    }
}

public struct LegacySummaryConflict: Codable, Hashable, Sendable {
    public let field: String
    public let preferredProvenance: String?
    public let observedProvenances: [String]

    public init(
        field: String,
        preferredProvenance: String?,
        observedProvenances: [String]
    ) {
        self.field = field
        self.preferredProvenance = preferredProvenance
        self.observedProvenances = observedProvenances
    }
}

public struct LegacyWorkoutCandidateSummary: Codable, Hashable, Sendable {
    public let timestampDerivedDurationMicroseconds: Int64?
    public let legacySummaryDurationSeconds: Int?
    public let targetBeatsPerMinute: Int?
    public let timestampDerivedAverageHeartRateBeatsPerMinute: Double?
    public let legacySummaryAverageHeartRateBeatsPerMinute: Int?
    public let legacyEstimatedAverageSpeedKilometresPerHour: Double?
    public let timestampDerivedZoneMicroseconds: [Int64?]?
    public let legacySummaryZoneSeconds: [Int?]?
    public let heartRateCoveredMicroseconds: Int64?
    public let heartRateUncoveredMicroseconds: Int64?
    public let heartRateSampleCount: Int
    public let missingTimestampCount: Int
    public let malformedRecordCount: Int
    public let ignoredStepFieldCount: Int
    public let legacySessionEvidenceComplete: Bool?
    public let warnings: [String]
    public let conflicts: [LegacySummaryConflict]

    public init(
        timestampDerivedDurationMicroseconds: Int64?,
        legacySummaryDurationSeconds: Int?,
        targetBeatsPerMinute: Int?,
        timestampDerivedAverageHeartRateBeatsPerMinute: Double?,
        legacySummaryAverageHeartRateBeatsPerMinute: Int?,
        legacyEstimatedAverageSpeedKilometresPerHour: Double?,
        timestampDerivedZoneMicroseconds: [Int64?]?,
        legacySummaryZoneSeconds: [Int?]?,
        heartRateCoveredMicroseconds: Int64?,
        heartRateUncoveredMicroseconds: Int64?,
        heartRateSampleCount: Int,
        missingTimestampCount: Int,
        malformedRecordCount: Int,
        ignoredStepFieldCount: Int,
        legacySessionEvidenceComplete: Bool?,
        warnings: [String],
        conflicts: [LegacySummaryConflict]
    ) {
        self.timestampDerivedDurationMicroseconds = timestampDerivedDurationMicroseconds
        self.legacySummaryDurationSeconds = legacySummaryDurationSeconds
        self.targetBeatsPerMinute = targetBeatsPerMinute
        self.timestampDerivedAverageHeartRateBeatsPerMinute =
            timestampDerivedAverageHeartRateBeatsPerMinute
        self.legacySummaryAverageHeartRateBeatsPerMinute =
            legacySummaryAverageHeartRateBeatsPerMinute
        self.legacyEstimatedAverageSpeedKilometresPerHour =
            legacyEstimatedAverageSpeedKilometresPerHour
        self.timestampDerivedZoneMicroseconds = timestampDerivedZoneMicroseconds
        self.legacySummaryZoneSeconds = legacySummaryZoneSeconds
        self.heartRateCoveredMicroseconds = heartRateCoveredMicroseconds
        self.heartRateUncoveredMicroseconds = heartRateUncoveredMicroseconds
        self.heartRateSampleCount = heartRateSampleCount
        self.missingTimestampCount = missingTimestampCount
        self.malformedRecordCount = malformedRecordCount
        self.ignoredStepFieldCount = ignoredStepFieldCount
        self.legacySessionEvidenceComplete = legacySessionEvidenceComplete
        self.warnings = warnings
        self.conflicts = conflicts
    }
}

public struct LegacySourcedValue<Value>: Codable, Hashable, Sendable
where Value: Codable & Hashable & Sendable {
    public let value: Value
    public let provenance: String

    public init(value: Value, provenance: String) {
        self.value = value
        self.provenance = provenance
    }
}

public struct LegacyResolvedValue<Value>: Codable, Hashable, Sendable
where Value: Codable & Hashable & Sendable {
    public let selected: LegacySourcedValue<Value>?
    public let alternatives: [LegacySourcedValue<Value>]
    public let conflict: Bool

    public init(
        selected: LegacySourcedValue<Value>?,
        alternatives: [LegacySourcedValue<Value>],
        conflict: Bool
    ) {
        self.selected = selected
        self.alternatives = alternatives
        self.conflict = conflict
    }
}

public struct LegacyResolvedWorkoutSummary: Codable, Hashable, Sendable {
    public let durationMicroseconds: LegacyResolvedValue<Int64>
    public let targetBeatsPerMinute: LegacyResolvedValue<Int>
    public let averageHeartRateBeatsPerMinute: LegacyResolvedValue<Double>
    public let estimatedAverageSpeedKilometresPerHour: LegacyResolvedValue<Double>
    public let zoneMicroseconds: LegacyResolvedValue<[Int64?]>
    public let warnings: [String]
    public let conflicts: [LegacySummaryConflict]

    public init(
        durationMicroseconds: LegacyResolvedValue<Int64>,
        targetBeatsPerMinute: LegacyResolvedValue<Int>,
        averageHeartRateBeatsPerMinute: LegacyResolvedValue<Double>,
        estimatedAverageSpeedKilometresPerHour: LegacyResolvedValue<Double>,
        zoneMicroseconds: LegacyResolvedValue<[Int64?]>,
        warnings: [String],
        conflicts: [LegacySummaryConflict]
    ) {
        self.durationMicroseconds = durationMicroseconds
        self.targetBeatsPerMinute = targetBeatsPerMinute
        self.averageHeartRateBeatsPerMinute = averageHeartRateBeatsPerMinute
        self.estimatedAverageSpeedKilometresPerHour =
            estimatedAverageSpeedKilometresPerHour
        self.zoneMicroseconds = zoneMicroseconds
        self.warnings = warnings
        self.conflicts = conflicts
    }
}

public struct LegacyMigrationSourceSnapshot: Codable, Hashable, Sendable {
    public let sourceID: String
    public let kind: LegacyMigrationSourceKind
    public let contentHashDigest: String
    public let importerVersion: String
    public let locator: String
    public let exactProfileLocalIdentifier: String?
    public let status: LegacyMigrationSourceStatus
    public let checkpointByteOffset: Int64
    public let checkpointRecordIndex: Int64
    public let parsedRecordCount: Int64
    public let malformedRecordCount: Int64
    public let warningCount: Int64
    public let errorCode: String?
    public let errorDetail: String?
}

public struct LegacyImportedRecordSnapshot: Codable, Hashable, Sendable {
    public let importedRecordID: String
    public let sourceID: String
    public let candidateID: String
    public let sourceRecordIndex: Int64
    public let eventKind: String
    public let occurredAt: Date?
    public let profileLocalIdentifier: String?
    public let workoutIdentifier: String?
    public let healthKitWorkoutIdentifier: String?
    public let stableLegacySessionIdentifier: String?
    public let payload: LegacyImportedRecordPayload
    public let identityUncertain: Bool
    public let adaptationQualityEligible: Bool
}

public struct LegacyWorkoutCandidateSnapshot: Codable, Hashable, Sendable {
    public let candidateID: String
    public let sourceID: String
    public let origin: LegacyWorkoutCandidateOrigin
    public let profileLocalIdentifier: String?
    public let workoutIdentifier: String?
    public let healthKitWorkoutIdentifier: String?
    public let stableLegacySessionIdentifier: String?
    public let startedAt: Date?
    public let endedAt: Date?
    public let identityUncertain: Bool
    public let possibleDuplicate: Bool
    public let summary: LegacyWorkoutCandidateSummary
}

public struct LegacyImportedWorkoutSnapshot: Codable, Hashable, Sendable {
    public let importedWorkoutID: String
    public let canonicalIdentityKey: String
    public let profileLocalIdentifier: String?
    public let startedAt: Date?
    public let endedAt: Date?
    public let identityStatus: LegacyIdentityStatus
    public let possibleDuplicate: Bool
    public let adaptationQualityEligible: Bool
    public let candidateIDs: [String]
    public let resolvedSummary: LegacyResolvedWorkoutSummary
}

public struct LegacyReconciliationSnapshot: Codable, Hashable, Sendable {
    public let reconciliationID: String
    public let leftCandidateID: String
    public let rightCandidateID: String
    public let outcome: LegacyReconciliationOutcome
    public let identityKind: LegacyReconciliationIdentityKind?
    public let identityValue: String?
    public let importedWorkoutID: String?
    public let detailCodes: [String]
}

struct LegacyMigrationSourceDefinition: Sendable {
    let sourceID: String
    let kind: LegacyMigrationSourceKind
    let contentHashDigest: String
    let locator: String
    let exactProfileLocalIdentifier: String?
}

struct LegacyImportedRecordDraft: Sendable {
    let importedRecordID: String
    let sourceItemIdentityKey: String
    let sourceID: String
    let candidateID: String
    let sourceRecordIndex: Int64
    let sourceByteOffset: Int64
    let eventKind: String
    let occurredAt: Date?
    let profileLocalIdentifier: String?
    let workoutIdentifier: String?
    let healthKitWorkoutIdentifier: String?
    let stableLegacySessionIdentifier: String?
    let provenanceKey: String
    let payload: LegacyImportedRecordPayload
    let identityUncertain: Bool
}

struct LegacyWorkoutCandidateDraft: Sendable {
    let candidateID: String
    let sourceItemIdentityKey: String
    let sourceID: String
    let origin: LegacyWorkoutCandidateOrigin
    let profileLocalIdentifier: String?
    let workoutIdentifier: String?
    let healthKitWorkoutIdentifier: String?
    let stableLegacySessionIdentifier: String?
    let startedAt: Date?
    let endedAt: Date?
    let identityUncertain: Bool
    let possibleDuplicate: Bool
    let summary: LegacyWorkoutCandidateSummary
}
