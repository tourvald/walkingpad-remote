import Foundation

public enum SignalProviderKind: Codable, Hashable, Sendable {
    case unknown
    case healthKitSelected
    case watchMediated
    case phoneLocal
    case bluetooth
    case treadmillProtocol
    case other(String)
}

public struct ProviderSavingSource: Codable, Hashable, Sendable {
    public let bundleIdentifier: String?
    public let productType: String?
    public let softwareVersion: String?

    public init(
        bundleIdentifier: String? = nil,
        productType: String? = nil,
        softwareVersion: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.productType = productType
        self.softwareVersion = softwareVersion
    }
}

public struct KnownDeviceMetadata: Codable, Hashable, Sendable {
    public let manufacturer: String?
    public let model: String?
    public let hardwareVersion: String?

    public init(
        manufacturer: String? = nil,
        model: String? = nil,
        hardwareVersion: String? = nil
    ) {
        self.manufacturer = manufacturer
        self.model = model
        self.hardwareVersion = hardwareVersion
    }
}

public struct SignalSourceIdentity: Codable, Hashable, Sendable {
    public let id: SourceID
    public let providerKind: SignalProviderKind
    public let stableLocalKey: String
    public let savingSource: ProviderSavingSource?
    public let knownDevice: KnownDeviceMetadata?

    public init(
        id: SourceID,
        providerKind: SignalProviderKind,
        stableLocalKey: String,
        savingSource: ProviderSavingSource? = nil,
        knownDevice: KnownDeviceMetadata? = nil
    ) {
        self.id = id
        self.providerKind = providerKind
        self.stableLocalKey = stableLocalKey
        self.savingSource = savingSource
        self.knownDevice = knownDevice
    }
}

public enum EvidenceProvenance: String, Codable, Hashable, Sendable {
    case measuredByProvider
    case reportedByProvider
    case decodedDeviceReport
}

public enum QualityFlag: String, Codable, Hashable, Sendable, CaseIterable {
    case missingSource
    case missingMeasurementTime
    case duplicateProviderIdentity
    case duplicateProviderSequence
    case measurementOutOfArrivalOrder
    case invalidNativeValue
    case nativeValueOutOfDomain
    case staleAtUse
    case unknownFreshness
    case clockRegression
    case implausibleReceiveLatency
    case gapBeforeRecord
    case recorderLossBeforeRecord
    case estimatedProvenance
    case derivedProvenance
}

public struct QualityFlags: Codable, Hashable, Sendable, ExpressibleByArrayLiteral {
    public private(set) var values: Set<QualityFlag>

    public init(_ values: Set<QualityFlag> = []) {
        self.values = values
    }

    public init(arrayLiteral elements: QualityFlag...) {
        self.init(Set(elements))
    }

    public func contains(_ flag: QualityFlag) -> Bool {
        values.contains(flag)
    }

    public mutating func insert(_ flag: QualityFlag) {
        values.insert(flag)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(Set(try container.decode([QualityFlag].self)))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values.sorted { $0.rawValue < $1.rawValue })
    }
}

public enum FreshnessState: String, Codable, Hashable, Sendable {
    case fresh
    case stale
    case unknown
}

public struct EvidenceFreshness: Codable, Hashable, Sendable {
    public let state: FreshnessState
    public let evaluatedAt: RecordTimestamp
    public let age: ElapsedDuration?
    public let policyVersion: SafetyPolicyVersion?

    public init(
        state: FreshnessState,
        evaluatedAt: RecordTimestamp,
        age: ElapsedDuration?,
        policyVersion: SafetyPolicyVersion?
    ) {
        self.state = state
        self.evaluatedAt = evaluatedAt
        self.age = age
        self.policyVersion = policyVersion
    }
}
