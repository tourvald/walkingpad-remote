import Foundation

public struct TelemetryIdentifier<Tag>: RawRepresentable, Codable, Hashable, Sendable,
    CustomStringConvertible
{
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }

    public var description: String {
        rawValue.uuidString.lowercased()
    }
}

public enum SessionIDTag: Sendable {}
public enum RecordIDTag: Sendable {}
public enum SourceIDTag: Sendable {}
public enum ObservationIDTag: Sendable {}
public enum DecisionIDTag: Sendable {}
public enum CommandIDTag: Sendable {}
public enum CommandAttemptIDTag: Sendable {}
public enum FrameIDTag: Sendable {}
public enum AnalysisIDTag: Sendable {}
public enum ConfigurationSnapshotIDTag: Sendable {}

public typealias SessionID = TelemetryIdentifier<SessionIDTag>
public typealias RecordID = TelemetryIdentifier<RecordIDTag>
public typealias SourceID = TelemetryIdentifier<SourceIDTag>
public typealias ObservationID = TelemetryIdentifier<ObservationIDTag>
public typealias DecisionID = TelemetryIdentifier<DecisionIDTag>
public typealias CommandID = TelemetryIdentifier<CommandIDTag>
public typealias CommandAttemptID = TelemetryIdentifier<CommandAttemptIDTag>
public typealias FrameID = TelemetryIdentifier<FrameIDTag>
public typealias AnalysisID = TelemetryIdentifier<AnalysisIDTag>
public typealias ConfigurationSnapshotID = TelemetryIdentifier<ConfigurationSnapshotIDTag>
