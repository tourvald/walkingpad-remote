import Foundation

public struct VersionValue<Tag>: RawRepresentable, Codable, Hashable, Sendable,
    CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue
    }
}
public enum TelemetrySchemaVersionTag: Sendable {}
public enum AlgorithmVersionTag: Sendable {}
public enum SafetyPolicyVersionTag: Sendable {}
public enum WorkoutProtocolVersionTag: Sendable {}
public enum AnalyzerVersionTag: Sendable {}

public typealias TelemetrySchemaVersion = VersionValue<TelemetrySchemaVersionTag>
public typealias AlgorithmVersion = VersionValue<AlgorithmVersionTag>
public typealias SafetyPolicyVersion = VersionValue<SafetyPolicyVersionTag>
public typealias WorkoutProtocolVersion = VersionValue<WorkoutProtocolVersionTag>
public typealias AnalyzerVersion = VersionValue<AnalyzerVersionTag>

public struct RuntimeVersionContext: Codable, Hashable, Sendable {
    public let telemetrySchema: TelemetrySchemaVersion
    public let algorithm: AlgorithmVersion
    public let safetyPolicy: SafetyPolicyVersion
    public let workoutProtocol: WorkoutProtocolVersion

    public init(
        telemetrySchema: TelemetrySchemaVersion,
        algorithm: AlgorithmVersion,
        safetyPolicy: SafetyPolicyVersion,
        workoutProtocol: WorkoutProtocolVersion
    ) {
        self.telemetrySchema = telemetrySchema
        self.algorithm = algorithm
        self.safetyPolicy = safetyPolicy
        self.workoutProtocol = workoutProtocol
    }
}

public struct AppRuntimeContext: Codable, Hashable, Sendable {
    public let appVersion: String
    public let buildNumber: String
    public let operatingSystemVersion: String
    public let deviceModel: String?

    public init(
        appVersion: String,
        buildNumber: String,
        operatingSystemVersion: String,
        deviceModel: String? = nil
    ) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.operatingSystemVersion = operatingSystemVersion
        self.deviceModel = deviceModel
    }
}

public enum ConfigurationPayloadFormat: String, Codable, Hashable, Sendable {
    case canonicalJSON
}

public enum ContentHashAlgorithm: String, Codable, Hashable, Sendable {
    case sha256
}

public struct ContentHash: Codable, Hashable, Sendable {
    public let algorithm: ContentHashAlgorithm
    public let lowercaseHexDigest: String

    public init(algorithm: ContentHashAlgorithm, lowercaseHexDigest: String) {
        self.algorithm = algorithm
        self.lowercaseHexDigest = lowercaseHexDigest
    }
}

public struct ImmutableConfigurationSnapshot: Codable, Hashable, Sendable {
    public let id: ConfigurationSnapshotID
    public let formatVersion: UInt16
    public let format: ConfigurationPayloadFormat
    public let canonicalPayload: Data
    public let contentHash: ContentHash

    public init(
        id: ConfigurationSnapshotID,
        formatVersion: UInt16,
        format: ConfigurationPayloadFormat,
        canonicalPayload: Data,
        contentHash: ContentHash
    ) {
        self.id = id
        self.formatVersion = formatVersion
        self.format = format
        self.canonicalPayload = canonicalPayload
        self.contentHash = contentHash
    }
}
