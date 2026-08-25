import Foundation

public enum WorkoutReadProfileScope: Codable, Hashable, Sendable {
    case exact(String)
    case unassigned
    case all
}

public struct WorkoutReadFilter: Codable, Hashable, Sendable {
    public let profileScope: WorkoutReadProfileScope
    public let startedAtOrAfter: Date?
    public let startedBefore: Date?

    public init(
        profileScope: WorkoutReadProfileScope,
        startedAtOrAfter: Date? = nil,
        startedBefore: Date? = nil
    ) {
        self.profileScope = profileScope
        self.startedAtOrAfter = startedAtOrAfter
        self.startedBefore = startedBefore
    }
}

public struct WorkoutHistoryCursor: Codable, Hashable, Sendable {
    public let startedAt: Date?
    public let stableTieBreaker: String

    public init(startedAt: Date?, stableTieBreaker: String) {
        self.startedAt = startedAt
        self.stableTieBreaker = stableTieBreaker
    }
}

public enum WorkoutProjectionOrigin: String, Codable, Hashable, Sendable {
    case nativeV2
    case importedLegacy
}

public enum WorkoutSpeedEvidenceKind: String, Codable, Hashable, Sendable {
    case factual
    case legacyEstimated
}

public struct WorkoutSpeedProjection: Codable, Hashable, Sendable {
    public let kilometresPerHour: Double
    public let evidenceKind: WorkoutSpeedEvidenceKind
    public let provenance: String

    public init(
        kilometresPerHour: Double,
        evidenceKind: WorkoutSpeedEvidenceKind,
        provenance: String
    ) {
        self.kilometresPerHour = kilometresPerHour
        self.evidenceKind = evidenceKind
        self.provenance = provenance
    }
}

public struct WorkoutFactualSpeedCoverageProjection: Codable, Hashable, Sendable {
    public let coveredSeconds: Double
    public let uncoveredSeconds: Double
    public let coverageRatio: Double?
    public let requiredRatio: Double

    public init(
        coveredSeconds: Double,
        uncoveredSeconds: Double,
        coverageRatio: Double?,
        requiredRatio: Double
    ) {
        self.coveredSeconds = coveredSeconds
        self.uncoveredSeconds = uncoveredSeconds
        self.coverageRatio = coverageRatio
        self.requiredRatio = requiredRatio
    }
}

public struct WorkoutProjectionQuality: Codable, Hashable, Sendable {
    public let lifecycleState: String
    public let recorderComplete: Bool?
    public let analysisGrade: String?
    public let identityStatus: String?
    public let possibleDuplicate: Bool
    public let adaptationEligible: Bool
    public let includedInStatistics: Bool
    public let provenance: [String]
    public let unavailableMetrics: [String]
    public let warnings: [String]

    public init(
        lifecycleState: String,
        recorderComplete: Bool?,
        analysisGrade: String?,
        identityStatus: String?,
        possibleDuplicate: Bool,
        adaptationEligible: Bool,
        includedInStatistics: Bool,
        provenance: [String],
        unavailableMetrics: [String],
        warnings: [String]
    ) {
        self.lifecycleState = lifecycleState
        self.recorderComplete = recorderComplete
        self.analysisGrade = analysisGrade
        self.identityStatus = identityStatus
        self.possibleDuplicate = possibleDuplicate
        self.adaptationEligible = adaptationEligible
        self.includedInStatistics = includedInStatistics
        self.provenance = provenance.sorted()
        self.unavailableMetrics = unavailableMetrics.sorted()
        self.warnings = warnings.sorted()
    }
}

public struct WorkoutHistoryProjection: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let origin: WorkoutProjectionOrigin
    public let startedAt: Date?
    public let endedAt: Date?
    public let durationSeconds: Double?
    public let targetHeartRate: Int?
    public let averageHeartRate: Double?
    public let averageSpeed: WorkoutSpeedProjection?
    public let beatsPerMetre: Double?
    public let zoneSeconds: [Double?]?
    public let healthKitWorkoutIdentifier: UUID?
    public let telemetrySchemaVersion: String?
    public let appVersion: String?
    public let buildNumber: String?
    public let algorithmVersion: String?
    public let analyzerVersion: String?
    public let quality: WorkoutProjectionQuality
    public let factualSpeedCoverage: WorkoutFactualSpeedCoverageProjection?

    public init(
        id: String,
        origin: WorkoutProjectionOrigin,
        startedAt: Date?,
        endedAt: Date?,
        durationSeconds: Double?,
        targetHeartRate: Int?,
        averageHeartRate: Double?,
        averageSpeed: WorkoutSpeedProjection?,
        beatsPerMetre: Double?,
        zoneSeconds: [Double?]?,
        healthKitWorkoutIdentifier: UUID?,
        telemetrySchemaVersion: String?,
        appVersion: String?,
        buildNumber: String?,
        algorithmVersion: String?,
        analyzerVersion: String?,
        quality: WorkoutProjectionQuality,
        factualSpeedCoverage: WorkoutFactualSpeedCoverageProjection? = nil
    ) {
        self.id = id
        self.origin = origin
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.targetHeartRate = targetHeartRate
        self.averageHeartRate = averageHeartRate
        self.averageSpeed = averageSpeed
        self.beatsPerMetre = beatsPerMetre
        self.zoneSeconds = zoneSeconds
        self.healthKitWorkoutIdentifier = healthKitWorkoutIdentifier
        self.telemetrySchemaVersion = telemetrySchemaVersion
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.algorithmVersion = algorithmVersion
        self.analyzerVersion = analyzerVersion
        self.quality = quality
        self.factualSpeedCoverage = factualSpeedCoverage
    }
}

public struct WorkoutReadDiagnostics: Codable, Hashable, Sendable {
    public let storeFetchCount: Int
    public let maximumStoreFetchLimit: Int
    public let hydratedTimeSeriesRecordCount: Int
    public let exactNativeDuplicateCount: Int

    public init(
        storeFetchCount: Int,
        maximumStoreFetchLimit: Int,
        hydratedTimeSeriesRecordCount: Int,
        exactNativeDuplicateCount: Int
    ) {
        self.storeFetchCount = storeFetchCount
        self.maximumStoreFetchLimit = maximumStoreFetchLimit
        self.hydratedTimeSeriesRecordCount = hydratedTimeSeriesRecordCount
        self.exactNativeDuplicateCount = exactNativeDuplicateCount
    }
}

public struct WorkoutHistoryPage: Codable, Hashable, Sendable {
    public let items: [WorkoutHistoryProjection]
    public let nextCursor: WorkoutHistoryCursor?
    public let diagnostics: WorkoutReadDiagnostics

    public init(
        items: [WorkoutHistoryProjection],
        nextCursor: WorkoutHistoryCursor?,
        diagnostics: WorkoutReadDiagnostics
    ) {
        self.items = items
        self.nextCursor = nextCursor
        self.diagnostics = diagnostics
    }
}

public struct WorkoutStatisticsProjection: Codable, Hashable, Sendable {
    public let totalDurationSeconds: Double?
    public let averageBeatsPerMetre: Double?
    public let zoneSeconds: [Double?]
    public let queryableWorkoutCount: Int
    public let includedWorkoutCount: Int
    public let excludedWorkoutCount: Int
    public let exclusionReasonCounts: [WorkoutStatisticsExclusionReason: Int]
    public let workoutsWithUnavailableDuration: Int
    public let workoutsWithUnavailableZones: Int
    public let isPartial: Bool
    public let diagnostics: WorkoutReadDiagnostics

    public init(
        totalDurationSeconds: Double?,
        averageBeatsPerMetre: Double?,
        zoneSeconds: [Double?],
        queryableWorkoutCount: Int,
        includedWorkoutCount: Int,
        excludedWorkoutCount: Int,
        exclusionReasonCounts: [WorkoutStatisticsExclusionReason: Int],
        workoutsWithUnavailableDuration: Int,
        workoutsWithUnavailableZones: Int,
        isPartial: Bool,
        diagnostics: WorkoutReadDiagnostics
    ) {
        self.totalDurationSeconds = totalDurationSeconds
        self.averageBeatsPerMetre = averageBeatsPerMetre
        self.zoneSeconds = zoneSeconds
        self.queryableWorkoutCount = queryableWorkoutCount
        self.includedWorkoutCount = includedWorkoutCount
        self.excludedWorkoutCount = excludedWorkoutCount
        self.exclusionReasonCounts = exclusionReasonCounts
        self.workoutsWithUnavailableDuration = workoutsWithUnavailableDuration
        self.workoutsWithUnavailableZones = workoutsWithUnavailableZones
        self.isPartial = isPartial
        self.diagnostics = diagnostics
    }
}

public enum WorkoutStatisticsExclusionReason: String, Codable, Hashable, Sendable {
    case identity
    case possibleDuplicate
    case lifecycleOrQuality
}

public enum WorkoutExportSelection: Codable, Hashable, Sendable {
    case all
    case latestCompleted(Int)
}

public struct WorkoutExportRequest: Codable, Hashable, Sendable {
    public let filter: WorkoutReadFilter
    public let selection: WorkoutExportSelection
    public let batchSize: Int

    public init(
        filter: WorkoutReadFilter,
        selection: WorkoutExportSelection,
        batchSize: Int = 128
    ) {
        self.filter = filter
        self.selection = selection
        self.batchSize = batchSize
    }
}

public struct WorkoutExportArtifact: Codable, Hashable, Sendable {
    public let directoryURL: URL
    public let fileURLs: [URL]
    public let exportedWorkoutCount: Int
    public let exportedRecordCount: Int
    public let containsHealthData: Bool

    public init(
        directoryURL: URL,
        fileURLs: [URL],
        exportedWorkoutCount: Int,
        exportedRecordCount: Int,
        containsHealthData: Bool
    ) {
        self.directoryURL = directoryURL
        self.fileURLs = fileURLs
        self.exportedWorkoutCount = exportedWorkoutCount
        self.exportedRecordCount = exportedRecordCount
        self.containsHealthData = containsHealthData
    }
}

public struct WorkoutExportManifestQuality: Codable, Hashable, Sendable {
    public let lifecycleCounts: [String: Int]
    public let analysisGradeCounts: [String: Int]
    public let identityStatusCounts: [String: Int]
    public let workoutCountWithUnavailableMetrics: Int
    public let possibleDuplicateCount: Int

    public init(
        lifecycleCounts: [String: Int],
        analysisGradeCounts: [String: Int],
        identityStatusCounts: [String: Int],
        workoutCountWithUnavailableMetrics: Int,
        possibleDuplicateCount: Int
    ) {
        self.lifecycleCounts = lifecycleCounts
        self.analysisGradeCounts = analysisGradeCounts
        self.identityStatusCounts = identityStatusCounts
        self.workoutCountWithUnavailableMetrics = workoutCountWithUnavailableMetrics
        self.possibleDuplicateCount = possibleDuplicateCount
    }
}

public struct WorkoutExportManifest: Codable, Hashable, Sendable {
    public static let formatVersion = "workout-export-manifest-v1"
    public static let sessionSummaryVersion = "workout-session-summary-v2"

    public let manifestVersion: String
    public let sessionSummaryVersion: String
    public let generatedAt: Date
    public let storageSchemaVersion: String
    public let telemetrySchemaVersions: [String]
    public let appVersions: [String]
    public let buildNumbers: [String]
    public let algorithmVersions: [String]
    public let analyzerVersions: [String]
    public let exportedWorkoutCount: Int
    public let exportedRecordCount: Int
    public let batchSize: Int
    public let containsHealthData: Bool
    public let healthDataNotice: String
    public let omittedIdentifierKinds: [String]
    public let files: [String]
    public let quality: WorkoutExportManifestQuality

    public init(
        generatedAt: Date,
        storageSchemaVersion: String,
        telemetrySchemaVersions: [String],
        appVersions: [String],
        buildNumbers: [String],
        algorithmVersions: [String],
        analyzerVersions: [String],
        exportedWorkoutCount: Int,
        exportedRecordCount: Int,
        batchSize: Int,
        containsHealthData: Bool,
        healthDataNotice: String,
        omittedIdentifierKinds: [String],
        files: [String],
        quality: WorkoutExportManifestQuality
    ) {
        manifestVersion = Self.formatVersion
        sessionSummaryVersion = Self.sessionSummaryVersion
        self.generatedAt = generatedAt
        self.storageSchemaVersion = storageSchemaVersion
        self.telemetrySchemaVersions = telemetrySchemaVersions.sorted()
        self.appVersions = appVersions.sorted()
        self.buildNumbers = buildNumbers.sorted()
        self.algorithmVersions = algorithmVersions.sorted()
        self.analyzerVersions = analyzerVersions.sorted()
        self.exportedWorkoutCount = exportedWorkoutCount
        self.exportedRecordCount = exportedRecordCount
        self.batchSize = batchSize
        self.containsHealthData = containsHealthData
        self.healthDataNotice = healthDataNotice
        self.omittedIdentifierKinds = omittedIdentifierKinds.sorted()
        self.files = files.sorted()
        self.quality = quality
    }
}

public struct WorkoutAnalysisExportRequest: Codable, Hashable, Sendable {
    public let sessionID: SessionID
    public let exactProfileLocalIdentifier: String
    public let batchSize: Int

    public init(
        sessionID: SessionID,
        exactProfileLocalIdentifier: String,
        batchSize: Int = 128
    ) {
        self.sessionID = sessionID
        self.exactProfileLocalIdentifier = exactProfileLocalIdentifier
        self.batchSize = batchSize
    }
}

public struct WorkoutAnalysisExportDiagnostics: Codable, Hashable, Sendable {
    public let frameRowCount: Int
    public let eventRowCount: Int
    public let metadataRowCount: Int
    public let fileByteCount: Int64
    public let storeFetchCount: Int
    public let maximumStoreFetchLimit: Int
    public let maximumBufferedTimelineRows: Int

    public init(
        frameRowCount: Int,
        eventRowCount: Int,
        metadataRowCount: Int,
        fileByteCount: Int64,
        storeFetchCount: Int,
        maximumStoreFetchLimit: Int,
        maximumBufferedTimelineRows: Int
    ) {
        self.frameRowCount = frameRowCount
        self.eventRowCount = eventRowCount
        self.metadataRowCount = metadataRowCount
        self.fileByteCount = fileByteCount
        self.storeFetchCount = storeFetchCount
        self.maximumStoreFetchLimit = maximumStoreFetchLimit
        self.maximumBufferedTimelineRows = maximumBufferedTimelineRows
    }
}

public struct WorkoutAnalysisExportArtifact: Codable, Hashable, Sendable {
    public static let schemaVersion = "workout-analysis-timeline-v1"

    public let fileURL: URL
    public let diagnostics: WorkoutAnalysisExportDiagnostics
    public let containsHealthData: Bool

    public init(
        fileURL: URL,
        diagnostics: WorkoutAnalysisExportDiagnostics,
        containsHealthData: Bool
    ) {
        self.fileURL = fileURL
        self.diagnostics = diagnostics
        self.containsHealthData = containsHealthData
    }
}

public enum TelemetryWorkoutReadError: Error, Codable, Equatable, Sendable {
    case unavailable(String)
    case invalidPageSize
    case corruptProjection(String)
    case exportFailed(String)
}

extension TelemetryWorkoutReadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unavailable(reason):
            return "Telemetry V2 is unavailable (\(reason))."
        case .invalidPageSize:
            return "Telemetry V2 rejected the requested page size."
        case let .corruptProjection(reason):
            return "Telemetry V2 projection is corrupt (\(reason))."
        case let .exportFailed(reason):
            return "Telemetry V2 export failed (\(reason))."
        }
    }
}

public protocol TelemetryWorkoutReadCapability: Sendable {
    func fetchWorkoutHistoryPage(
        filter: WorkoutReadFilter,
        after cursor: WorkoutHistoryCursor?,
        limit: Int
    ) async throws -> WorkoutHistoryPage

    func fetchWorkoutStatistics(
        filter: WorkoutReadFilter,
        batchSize: Int
    ) async throws -> WorkoutStatisticsProjection

    func exportWorkouts(_ request: WorkoutExportRequest) async throws -> WorkoutExportArtifact

    func exportWorkoutAnalysis(
        _ request: WorkoutAnalysisExportRequest
    ) async throws -> WorkoutAnalysisExportArtifact
}

public protocol TelemetryHealthKitWorkoutLinkageCapability: Sendable {
    func associateHealthKitWorkout(
        sessionID: SessionID,
        workoutIdentifier: UUID
    ) async throws
}
