import Foundation

public enum ControlUseState: String, Codable, Hashable, Sendable {
    case rejected
    case acceptedNotUsed
    case acceptedAndUsed

    public var acceptedForControl: Bool {
        self != .rejected
    }

    public var usedForControl: Bool {
        self == .acceptedAndUsed
    }
}

public struct HeartRateObservation: Codable, Hashable, Sendable {
    public let recordID: RecordID
    public let observationID: ObservationID
    public let sessionID: SessionID
    public let source: SignalSourceIdentity
    public let beatsPerMinute: UInt16
    public let arrivalOrder: UInt64
    public let providerSequence: Int64?
    public let providerSampleIdentifier: String?
    public let timestamp: ObservationTimestamp
    public let provenance: EvidenceProvenance
    public let freshness: EvidenceFreshness
    public let quality: QualityFlags
    public let controlUse: ControlUseState

    public init(
        recordID: RecordID,
        observationID: ObservationID,
        sessionID: SessionID,
        source: SignalSourceIdentity,
        beatsPerMinute: UInt16,
        arrivalOrder: UInt64,
        providerSequence: Int64?,
        providerSampleIdentifier: String?,
        timestamp: ObservationTimestamp,
        provenance: EvidenceProvenance,
        freshness: EvidenceFreshness,
        quality: QualityFlags,
        controlUse: ControlUseState
    ) {
        self.recordID = recordID
        self.observationID = observationID
        self.sessionID = sessionID
        self.source = source
        self.beatsPerMinute = beatsPerMinute
        self.arrivalOrder = arrivalOrder
        self.providerSequence = providerSequence
        self.providerSampleIdentifier = providerSampleIdentifier
        self.timestamp = timestamp
        self.provenance = provenance
        self.freshness = freshness
        self.quality = quality
        self.controlUse = controlUse
    }
}

public enum TreadmillNativeSpeedUnit: Codable, Hashable, Sendable {
    case kilometresPerHour
    case milesPerHour
    case controllerNative(code: String?)
    case unknown
}

public struct NativeTreadmillSpeed: Codable, Hashable, Sendable {
    public let value: Double
    public let unit: TreadmillNativeSpeedUnit

    public init(value: Double, unit: TreadmillNativeSpeedUnit) {
        self.value = value
        self.unit = unit
    }
}

public enum FactualSpeedNormalizationRule: String, Codable, Hashable, Sendable {
    case nativeToKilometresPerHourV1
}

public struct FactualSpeedKilometresPerHour: Codable, Hashable, Sendable {
    public let value: Double
    public let provenance: EvidenceProvenance
    public let normalizationRule: FactualSpeedNormalizationRule

    private init(
        value: Double,
        provenance: EvidenceProvenance,
        normalizationRule: FactualSpeedNormalizationRule
    ) {
        self.value = value
        self.provenance = provenance
        self.normalizationRule = normalizationRule
    }

    private enum CodingKeys: String, CodingKey {
        case value
        case provenance
        case normalizationRule
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(Double.self, forKey: .value)
        guard value.isFinite, value >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .value,
                in: container,
                debugDescription: "Factual treadmill speed must be finite and non-negative."
            )
        }

        self.init(
            value: value,
            provenance: try container.decode(EvidenceProvenance.self, forKey: .provenance),
            normalizationRule: try container.decode(
                FactualSpeedNormalizationRule.self,
                forKey: .normalizationRule
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
        try container.encode(provenance, forKey: .provenance)
        try container.encode(normalizationRule, forKey: .normalizationRule)
    }

    public static func normalized(
        from native: NativeTreadmillSpeed,
        provenance: EvidenceProvenance,
        normalizationRule: FactualSpeedNormalizationRule = .nativeToKilometresPerHourV1
    ) -> Self? {
        guard native.value.isFinite, native.value >= 0 else {
            return nil
        }

        switch normalizationRule {
        case .nativeToKilometresPerHourV1:
            switch native.unit {
            case .kilometresPerHour:
                return Self(
                    value: native.value,
                    provenance: provenance,
                    normalizationRule: normalizationRule
                )
            case .milesPerHour:
                return Self(
                    value: native.value * 1.609_344,
                    provenance: provenance,
                    normalizationRule: normalizationRule
                )
            case .controllerNative, .unknown:
                return nil
            }
        }
    }
}

public struct DesiredSpeedKilometresPerHour: Codable, Hashable, Sendable {
    public let value: Double

    public init(value: Double) {
        self.value = value
    }
}

public struct CommandedSpeed: Codable, Hashable, Sendable {
    public let nativeValue: Double
    public let nativeUnit: TreadmillNativeSpeedUnit

    public init(nativeValue: Double, nativeUnit: TreadmillNativeSpeedUnit) {
        self.nativeValue = nativeValue
        self.nativeUnit = nativeUnit
    }
}

public struct EstimatedSpeedKilometresPerHour: Codable, Hashable, Sendable {
    public let value: Double
    public let method: String
    public let version: String

    public init(value: Double, method: String, version: String) {
        self.value = value
        self.method = method
        self.version = version
    }
}

public enum TreadmillDeviceState: String, Codable, Hashable, Sendable {
    case unknown
    case stopped
    case moving
    case paused
    case disconnected
    case fault
}

public struct TreadmillObservation: Codable, Hashable, Sendable {
    public let recordID: RecordID
    public let observationID: ObservationID
    public let sessionID: SessionID
    public let source: SignalSourceIdentity
    public let nativeSpeed: NativeTreadmillSpeed
    public let factualSpeed: FactualSpeedKilometresPerHour?
    public let deviceState: TreadmillDeviceState
    public let arrivalOrder: UInt64
    public let timestamp: ObservationTimestamp
    public let provenance: EvidenceProvenance
    public let freshness: EvidenceFreshness
    public let quality: QualityFlags

    private struct CodingRepresentation: Codable {
        let recordID: RecordID
        let observationID: ObservationID
        let sessionID: SessionID
        let source: SignalSourceIdentity
        let nativeSpeed: NativeTreadmillSpeed
        let factualSpeed: FactualSpeedKilometresPerHour?
        let deviceState: TreadmillDeviceState
        let arrivalOrder: UInt64
        let timestamp: ObservationTimestamp
        let provenance: EvidenceProvenance
        let freshness: EvidenceFreshness
        let quality: QualityFlags
    }

    public init(
        recordID: RecordID,
        observationID: ObservationID,
        sessionID: SessionID,
        source: SignalSourceIdentity,
        nativeSpeed: NativeTreadmillSpeed,
        deviceState: TreadmillDeviceState,
        arrivalOrder: UInt64,
        timestamp: ObservationTimestamp,
        provenance: EvidenceProvenance,
        freshness: EvidenceFreshness,
        quality: QualityFlags,
        normalizationRule: FactualSpeedNormalizationRule = .nativeToKilometresPerHourV1
    ) {
        self.recordID = recordID
        self.observationID = observationID
        self.sessionID = sessionID
        self.source = source
        self.nativeSpeed = nativeSpeed
        self.factualSpeed = FactualSpeedKilometresPerHour.normalized(
            from: nativeSpeed,
            provenance: provenance,
            normalizationRule: normalizationRule
        )
        self.deviceState = deviceState
        self.arrivalOrder = arrivalOrder
        self.timestamp = timestamp
        self.provenance = provenance
        self.freshness = freshness
        self.quality = quality
    }

    public init(from decoder: Decoder) throws {
        let decoded = try CodingRepresentation(from: decoder)
        self.init(
            recordID: decoded.recordID,
            observationID: decoded.observationID,
            sessionID: decoded.sessionID,
            source: decoded.source,
            nativeSpeed: decoded.nativeSpeed,
            deviceState: decoded.deviceState,
            arrivalOrder: decoded.arrivalOrder,
            timestamp: decoded.timestamp,
            provenance: decoded.provenance,
            freshness: decoded.freshness,
            quality: decoded.quality,
            normalizationRule: decoded.factualSpeed?.normalizationRule
                ?? .nativeToKilometresPerHourV1
        )
        guard factualSpeed == decoded.factualSpeed else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Factual treadmill speed contradicts native evidence."
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        try CodingRepresentation(
            recordID: recordID,
            observationID: observationID,
            sessionID: sessionID,
            source: source,
            nativeSpeed: nativeSpeed,
            factualSpeed: factualSpeed,
            deviceState: deviceState,
            arrivalOrder: arrivalOrder,
            timestamp: timestamp,
            provenance: provenance,
            freshness: freshness,
            quality: quality
        ).encode(to: encoder)
    }
}
