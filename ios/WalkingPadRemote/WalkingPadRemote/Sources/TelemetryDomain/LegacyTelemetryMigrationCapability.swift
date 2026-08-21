import Foundation

public struct LegacyJSONLSourceDescriptor: Hashable, Sendable {
    public let url: URL
    public let deterministicFallbackProfileLocalIdentifier: String?

    public init(
        url: URL,
        deterministicFallbackProfileLocalIdentifier: String?
    ) {
        self.url = url
        self.deterministicFallbackProfileLocalIdentifier =
            deterministicFallbackProfileLocalIdentifier
    }
}

public struct LegacyWorkoutHistorySourceDescriptor: Hashable, Sendable {
    public let storageKey: String
    public let representation: Data
    public let exactProfileLocalIdentifier: String?

    public init(
        storageKey: String,
        representation: Data,
        exactProfileLocalIdentifier: String?
    ) {
        self.storageKey = storageKey
        self.representation = representation
        self.exactProfileLocalIdentifier = exactProfileLocalIdentifier
    }
}

public struct LegacyTelemetryMigrationRequest: Sendable {
    public let jsonlSources: [LegacyJSONLSourceDescriptor]
    public let workoutHistorySources: [LegacyWorkoutHistorySourceDescriptor]
    public let knownProfileLocalIdentifiers: Set<String>
    public let maximumRecordsPerBatch: Int

    public init(
        jsonlSources: [LegacyJSONLSourceDescriptor],
        workoutHistorySources: [LegacyWorkoutHistorySourceDescriptor],
        knownProfileLocalIdentifiers: Set<String>,
        maximumRecordsPerBatch: Int = 64
    ) {
        self.jsonlSources = jsonlSources
        self.workoutHistorySources = workoutHistorySources
        self.knownProfileLocalIdentifiers = knownProfileLocalIdentifiers
        self.maximumRecordsPerBatch = maximumRecordsPerBatch
    }
}

public enum LegacyTelemetryMigrationCompletion: String, Codable, Hashable, Sendable {
    case completed
    case partial
    case failed
}

public struct LegacyTelemetryMigrationReport: Codable, Hashable, Sendable {
    public let completion: LegacyTelemetryMigrationCompletion
    public let completedSourceCount: Int
    public let skippedSourceCount: Int
    public let failedSourceCount: Int
    public let importedRecordCount: Int
    public let importedWorkoutCount: Int

    public init(
        completion: LegacyTelemetryMigrationCompletion,
        completedSourceCount: Int,
        skippedSourceCount: Int,
        failedSourceCount: Int,
        importedRecordCount: Int,
        importedWorkoutCount: Int
    ) {
        self.completion = completion
        self.completedSourceCount = completedSourceCount
        self.skippedSourceCount = skippedSourceCount
        self.failedSourceCount = failedSourceCount
        self.importedRecordCount = importedRecordCount
        self.importedWorkoutCount = importedWorkoutCount
    }
}

/// Optional persistence capability used only for historical/background work.
/// Runtime callers must ignore the result: migration completeness never owns
/// application startup, workout startup, control, Stop, or safety policy.
public protocol LegacyTelemetryMigrationCapability: Sendable {
    func migrateLegacyTelemetry(
        _ request: LegacyTelemetryMigrationRequest
    ) async -> LegacyTelemetryMigrationReport
}
