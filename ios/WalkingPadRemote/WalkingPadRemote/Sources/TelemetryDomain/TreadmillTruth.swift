import Foundation

public struct TreadmillConnectionEpoch: RawRepresentable, Codable, Hashable, Sendable,
    CustomStringConvertible
{
    public let rawValue: UUID

    public nonisolated init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue.uuidString.lowercased()
    }
}

public enum TreadmillProtocolKind: String, Codable, Hashable, Sendable {
    case walkingPad
    case ftms
    case fitShow
    case unknown
}

public enum TreadmillNativeSpeedResolution: String, Codable, Hashable, Sendable {
    case tenths
    case hundredths

    public var multiplier: Double {
        switch self {
        case .tenths:
            0.1
        case .hundredths:
            0.01
        }
    }
}

public enum TreadmillReportedSpeedUnit: String, Codable, Hashable, Sendable {
    case controllerUnit
    case kilometresPerHour
    case milesPerHour
}

public struct ReportedTreadmillNativeSpeed: Codable, Hashable, Sendable {
    public let rawValue: Int
    public let resolution: TreadmillNativeSpeedResolution
    public let unit: TreadmillReportedSpeedUnit

    public init(
        rawValue: Int,
        resolution: TreadmillNativeSpeedResolution,
        unit: TreadmillReportedSpeedUnit
    ) {
        self.rawValue = rawValue
        self.resolution = resolution
        self.unit = unit
    }

    public var scaledValue: Double {
        Double(rawValue) * resolution.multiplier
    }
}

public enum TreadmillPhysicalSpeedUnit: String, Codable, Hashable, Sendable {
    case kilometresPerHour
    case milesPerHour
}

public enum TreadmillUnitsTruth: Codable, Hashable, Sendable {
    case valid(
        unit: TreadmillPhysicalSpeedUnit,
        connectionEpoch: TreadmillConnectionEpoch,
        observedAt: Date
    )
    case notRead(connectionEpoch: TreadmillConnectionEpoch)
    case unknown(connectionEpoch: TreadmillConnectionEpoch)
    case invalidChecksum(connectionEpoch: TreadmillConnectionEpoch)
    case malformed(connectionEpoch: TreadmillConnectionEpoch)

    public var connectionEpoch: TreadmillConnectionEpoch {
        switch self {
        case let .valid(_, connectionEpoch, _),
             let .notRead(connectionEpoch),
             let .unknown(connectionEpoch),
             let .invalidChecksum(connectionEpoch),
             let .malformed(connectionEpoch):
            connectionEpoch
        }
    }
}

public enum TreadmillObservationQualityFlag: String, Codable, Hashable, Sendable,
    CaseIterable
{
    case missingMeasurementTime
    case missingSpeed
    case invalidChecksum
    case invalidNativeValue
    case unitsNotRead
    case unitsUnknown
    case unitsStale
    case unitsMalformed
    case unitsInvalidChecksum
    case unitsEpochMismatch
    case unsupportedProtocol
}

public struct TreadmillObservationQualityFlags: Codable, Hashable, Sendable,
    ExpressibleByArrayLiteral
{
    public private(set) var values: Set<TreadmillObservationQualityFlag>

    public init(_ values: Set<TreadmillObservationQualityFlag> = []) {
        self.values = values
    }

    public init(arrayLiteral elements: TreadmillObservationQualityFlag...) {
        self.init(Set(elements))
    }

    public func contains(_ flag: TreadmillObservationQualityFlag) -> Bool {
        values.contains(flag)
    }

    public mutating func insert(_ flag: TreadmillObservationQualityFlag) {
        values.insert(flag)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(Set(try container.decode([TreadmillObservationQualityFlag].self)))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values.sorted { $0.rawValue < $1.rawValue })
    }
}

public enum TreadmillObservationFreshness: String, Codable, Hashable, Sendable {
    case freshAtReceipt
    case unknown
}

public enum TreadmillObservedResponseAssociation: Codable, Hashable, Sendable {
    case unassociated
    case deterministicallyCorrelated(commandID: CommandID, attemptID: CommandAttemptID)

    public var commandID: CommandID? {
        switch self {
        case .unassociated:
            nil
        case let .deterministicallyCorrelated(commandID, _):
            commandID
        }
    }

    public var attemptID: CommandAttemptID? {
        switch self {
        case .unassociated:
            nil
        case let .deterministicallyCorrelated(_, attemptID):
            attemptID
        }
    }
}

/// An opaque capability supplied only by a decoder that has independently
/// proven a factual-response-to-attempt edge. Current production protocols
/// create none.
public struct TreadmillDeterministicResponseProof: Hashable, Sendable {
    private let evidenceKey: UUID

    init(evidenceKey: UUID) {
        self.evidenceKey = evidenceKey
    }
}

public struct TreadmillProviderObservation: Codable, Hashable, Sendable {
    public let protocolKind: TreadmillProtocolKind
    public let connectionEpoch: TreadmillConnectionEpoch
    public let nativeSpeed: ReportedTreadmillNativeSpeed?
    public let rawDeviceState: Int?
    public let deviceState: TreadmillDeviceState
    public let checksumValid: Bool?
    public let measuredAt: Date?
    public let receivedAt: Date

    public init(
        protocolKind: TreadmillProtocolKind,
        connectionEpoch: TreadmillConnectionEpoch,
        nativeSpeed: ReportedTreadmillNativeSpeed?,
        rawDeviceState: Int?,
        deviceState: TreadmillDeviceState,
        checksumValid: Bool?,
        measuredAt: Date?,
        receivedAt: Date
    ) {
        self.protocolKind = protocolKind
        self.connectionEpoch = connectionEpoch
        self.nativeSpeed = nativeSpeed
        self.rawDeviceState = rawDeviceState
        self.deviceState = deviceState
        self.checksumValid = checksumValid
        self.measuredAt = measuredAt
        self.receivedAt = receivedAt
    }

    public static func walkingPad(
        speedRawTenths: Int?,
        rawState: Int?,
        deviceState: TreadmillDeviceState,
        checksumValid: Bool,
        connectionEpoch: TreadmillConnectionEpoch,
        receivedAt: Date
    ) -> Self {
        Self(
            protocolKind: .walkingPad,
            connectionEpoch: connectionEpoch,
            nativeSpeed: speedRawTenths.map {
                ReportedTreadmillNativeSpeed(
                    rawValue: $0,
                    resolution: .tenths,
                    unit: .controllerUnit
                )
            },
            rawDeviceState: rawState,
            deviceState: deviceState,
            checksumValid: checksumValid,
            measuredAt: nil,
            receivedAt: receivedAt
        )
    }

    public static func ftms(
        speedRawHundredthsKmh: Int?,
        rawState: Int?,
        deviceState: TreadmillDeviceState,
        connectionEpoch: TreadmillConnectionEpoch,
        receivedAt: Date
    ) -> Self {
        Self(
            protocolKind: .ftms,
            connectionEpoch: connectionEpoch,
            nativeSpeed: speedRawHundredthsKmh.map {
                ReportedTreadmillNativeSpeed(
                    rawValue: $0,
                    resolution: .hundredths,
                    unit: .kilometresPerHour
                )
            },
            rawDeviceState: rawState,
            deviceState: deviceState,
            checksumValid: nil,
            measuredAt: nil,
            receivedAt: receivedAt
        )
    }

    public static func fitShow(
        speedRawTenthsKmh: Int?,
        rawState: Int?,
        deviceState: TreadmillDeviceState,
        checksumValid: Bool,
        connectionEpoch: TreadmillConnectionEpoch,
        receivedAt: Date
    ) -> Self {
        Self(
            protocolKind: .fitShow,
            connectionEpoch: connectionEpoch,
            nativeSpeed: speedRawTenthsKmh.map {
                ReportedTreadmillNativeSpeed(
                    rawValue: $0,
                    resolution: .tenths,
                    unit: .kilometresPerHour
                )
            },
            rawDeviceState: rawState,
            deviceState: deviceState,
            checksumValid: checksumValid,
            measuredAt: nil,
            receivedAt: receivedAt
        )
    }

    public static func unknown(
        connectionEpoch: TreadmillConnectionEpoch,
        receivedAt: Date
    ) -> Self {
        Self(
            protocolKind: .unknown,
            connectionEpoch: connectionEpoch,
            nativeSpeed: nil,
            rawDeviceState: nil,
            deviceState: .unknown,
            checksumValid: nil,
            measuredAt: nil,
            receivedAt: receivedAt
        )
    }
}

public struct TreadmillObservationEvidence: Codable, Hashable, Sendable {
    public let observationID: ObservationID
    public let protocolKind: TreadmillProtocolKind
    public let connectionEpoch: TreadmillConnectionEpoch
    public let nativeSpeed: ReportedTreadmillNativeSpeed?
    public let factualSpeed: FactualSpeedKilometresPerHour?
    public let rawDeviceState: Int?
    public let deviceState: TreadmillDeviceState
    public let measuredAt: Date?
    public let receivedAt: Date
    public let recordedAt: Date
    public let arrivalOrder: UInt64
    public let freshness: TreadmillObservationFreshness
    public let quality: TreadmillObservationQualityFlags
    public let provenance: EvidenceProvenance
    public let responseAssociation: TreadmillObservedResponseAssociation

    public var commandID: CommandID? {
        responseAssociation.commandID
    }

    public var attemptID: CommandAttemptID? {
        responseAssociation.attemptID
    }

    public static func deterministicallyAssociated(
        _ observation: Self,
        sendAttempt: TreadmillCommandSendAttemptEvidence,
        proof: TreadmillDeterministicResponseProof
    ) -> Self? {
        _ = proof
        guard observation.protocolKind == sendAttempt.protocolKind,
              observation.connectionEpoch == sendAttempt.connectionEpoch else {
            return nil
        }
        return Self(
            observationID: observation.observationID,
            protocolKind: observation.protocolKind,
            connectionEpoch: observation.connectionEpoch,
            nativeSpeed: observation.nativeSpeed,
            factualSpeed: observation.factualSpeed,
            rawDeviceState: observation.rawDeviceState,
            deviceState: observation.deviceState,
            measuredAt: observation.measuredAt,
            receivedAt: observation.receivedAt,
            recordedAt: observation.recordedAt,
            arrivalOrder: observation.arrivalOrder,
            freshness: observation.freshness,
            quality: observation.quality,
            provenance: observation.provenance,
            responseAssociation: .deterministicallyCorrelated(
                commandID: sendAttempt.commandID,
                attemptID: sendAttempt.attemptID
            )
        )
    }
}

public struct TreadmillObservationNormalizer: Sendable {
    public static let defaultControllerUnitsFreshnessInterval: TimeInterval = 30

    private var nextArrivalOrder: UInt64 = 1
    private let controllerUnitsFreshnessInterval: TimeInterval

    public init(
        controllerUnitsFreshnessInterval: TimeInterval = Self.defaultControllerUnitsFreshnessInterval
    ) {
        self.controllerUnitsFreshnessInterval = controllerUnitsFreshnessInterval
    }

    public mutating func normalize(
        _ observation: TreadmillProviderObservation,
        unitsTruth: TreadmillUnitsTruth?,
        observationID: ObservationID,
        recordedAt: Date
    ) -> TreadmillObservationEvidence {
        var quality: TreadmillObservationQualityFlags = []
        if observation.measuredAt == nil {
            quality.insert(.missingMeasurementTime)
        }
        if observation.nativeSpeed == nil {
            quality.insert(.missingSpeed)
        }
        if observation.checksumValid == false {
            quality.insert(.invalidChecksum)
        }
        if observation.protocolKind == .unknown {
            quality.insert(.unsupportedProtocol)
        }

        let factualSpeed = normalizedFactualSpeed(
            for: observation,
            unitsTruth: unitsTruth,
            quality: &quality
        )
        let arrivalOrder = nextArrivalOrder
        if nextArrivalOrder < UInt64.max {
            nextArrivalOrder += 1
        }

        return TreadmillObservationEvidence(
            observationID: observationID,
            protocolKind: observation.protocolKind,
            connectionEpoch: observation.connectionEpoch,
            nativeSpeed: observation.nativeSpeed,
            factualSpeed: factualSpeed,
            rawDeviceState: observation.rawDeviceState,
            deviceState: observation.deviceState,
            measuredAt: observation.measuredAt,
            receivedAt: observation.receivedAt,
            recordedAt: recordedAt,
            arrivalOrder: arrivalOrder,
            freshness: observation.protocolKind == .unknown ? .unknown : .freshAtReceipt,
            quality: quality,
            provenance: .decodedDeviceReport,
            responseAssociation: .unassociated
        )
    }

    private func normalizedFactualSpeed(
        for observation: TreadmillProviderObservation,
        unitsTruth: TreadmillUnitsTruth?,
        quality: inout TreadmillObservationQualityFlags
    ) -> FactualSpeedKilometresPerHour? {
        guard observation.checksumValid != false,
              let nativeSpeed = observation.nativeSpeed,
              nativeSpeed.rawValue >= 0 else {
            if observation.nativeSpeed?.rawValue ?? 0 < 0 {
                quality.insert(.invalidNativeValue)
            }
            return nil
        }

        switch observation.protocolKind {
        case .ftms, .fitShow:
            return FactualSpeedKilometresPerHour.normalized(
                from: NativeTreadmillSpeed(
                    value: nativeSpeed.scaledValue,
                    unit: nativeSpeed.unit == .milesPerHour
                        ? .milesPerHour
                        : .kilometresPerHour
                ),
                provenance: .decodedDeviceReport
            )

        case .walkingPad:
            guard let unitsTruth else {
                quality.insert(.unitsUnknown)
                return nil
            }
            guard unitsTruth.connectionEpoch == observation.connectionEpoch else {
                quality.insert(.unitsEpochMismatch)
                return nil
            }
            switch unitsTruth {
            case let .valid(unit, _, observedAt):
                let age = observation.receivedAt.timeIntervalSince(observedAt)
                guard age >= 0, age <= controllerUnitsFreshnessInterval else {
                    quality.insert(.unitsStale)
                    return nil
                }
                let nativeUnit: TreadmillNativeSpeedUnit = unit == .milesPerHour
                    ? .milesPerHour
                    : .kilometresPerHour
                return FactualSpeedKilometresPerHour.normalized(
                    from: NativeTreadmillSpeed(
                        value: nativeSpeed.scaledValue,
                        unit: nativeUnit
                    ),
                    provenance: .decodedDeviceReport
                )
            case .notRead:
                quality.insert(.unitsNotRead)
                return nil
            case .unknown:
                quality.insert(.unitsUnknown)
                return nil
            case .invalidChecksum:
                quality.insert(.unitsInvalidChecksum)
                return nil
            case .malformed:
                quality.insert(.unitsMalformed)
                return nil
            }

        case .unknown:
            return nil
        }
    }
}

public struct ControllerReportedTargetSpeed: Codable, Hashable, Sendable {
    public let nativeValue: Double
    public let nativeUnit: TreadmillNativeSpeedUnit

    public init(nativeValue: Double, nativeUnit: TreadmillNativeSpeedUnit) {
        self.nativeValue = nativeValue
        self.nativeUnit = nativeUnit
    }
}

public struct TreadmillSpeedSemanticsSnapshot: Codable, Hashable, Sendable {
    public let desired: DesiredSpeedKilometresPerHour?
    public let commanded: CommandedSpeed?
    public let controllerReportedTarget: ControllerReportedTargetSpeed?
    public let expectedEstimate: EstimatedSpeedKilometresPerHour?
    public let modeledEstimate: EstimatedSpeedKilometresPerHour?

    public init(
        desired: DesiredSpeedKilometresPerHour?,
        commanded: CommandedSpeed?,
        controllerReportedTarget: ControllerReportedTargetSpeed?,
        expectedEstimate: EstimatedSpeedKilometresPerHour?,
        modeledEstimate: EstimatedSpeedKilometresPerHour?
    ) {
        self.desired = desired
        self.commanded = commanded
        self.controllerReportedTarget = controllerReportedTarget
        self.expectedEstimate = expectedEstimate
        self.modeledEstimate = modeledEstimate
    }
}

public enum TreadmillCommandedSpeedRepresentation {
    public static func walkingPad(rawControllerTenths: Int) -> CommandedSpeed {
        CommandedSpeed(
            nativeValue: Double(rawControllerTenths),
            nativeUnit: .controllerNative(code: "walkingpad_controller_tenths")
        )
    }

    public static func ftms(rawHundredthsKmh: UInt16) -> CommandedSpeed {
        CommandedSpeed(
            nativeValue: Double(rawHundredthsKmh),
            nativeUnit: .controllerNative(code: "ftms_hundredths_kmh")
        )
    }

    public static func fitShow(rawTenthsKmh: UInt8) -> CommandedSpeed {
        CommandedSpeed(
            nativeValue: Double(rawTenthsKmh),
            nativeUnit: .controllerNative(code: "fitshow_tenths_kmh")
        )
    }

}

public enum TreadmillControlDecisionSource: String, Codable, Hashable, Sendable {
    case manual
    case heartRateControl
    case cooldown
    case start
    case stop
    case protocolMaintenance
    case unknown
}

public enum TreadmillControlDecisionIntent: Codable, Hashable, Sendable {
    case startAtDesiredSpeed(DesiredSpeedKilometresPerHour)
    case setDesiredSpeed(DesiredSpeedKilometresPerHour)
    case stop
    case hold
    case requestControl
    case queryControllerUnits
    case other(String)
}

public struct TreadmillControlDecisionEvidence: Codable, Hashable, Sendable {
    public let decisionID: DecisionID
    public let source: TreadmillControlDecisionSource
    public let intent: TreadmillControlDecisionIntent
    public let heartRateInputs: [HeartRateCausalReference]
    public let occurredAt: Date
    public let connectionEpoch: TreadmillConnectionEpoch

    public init(
        decisionID: DecisionID,
        source: TreadmillControlDecisionSource,
        intent: TreadmillControlDecisionIntent,
        heartRateInputs: [HeartRateCausalReference],
        occurredAt: Date,
        connectionEpoch: TreadmillConnectionEpoch
    ) {
        self.decisionID = decisionID
        self.source = source
        self.intent = intent
        self.heartRateInputs = source == .heartRateControl ? heartRateInputs : []
        self.occurredAt = occurredAt
        self.connectionEpoch = connectionEpoch
    }
}

public enum TreadmillCommandWriteType: String, Codable, Hashable, Sendable {
    case withResponse
    case withoutResponse
}

public struct TreadmillCommandEnqueuedEvidence: Codable, Hashable, Sendable {
    public let commandID: CommandID
    public let decisionID: DecisionID?
    public let kind: CommandKind
    public let protocolKind: TreadmillProtocolKind
    public let connectionEpoch: TreadmillConnectionEpoch
    public let enqueuedAt: Date

    public init(
        commandID: CommandID,
        decisionID: DecisionID?,
        kind: CommandKind,
        protocolKind: TreadmillProtocolKind,
        connectionEpoch: TreadmillConnectionEpoch,
        enqueuedAt: Date
    ) {
        self.commandID = commandID
        self.decisionID = decisionID
        self.kind = kind
        self.protocolKind = protocolKind
        self.connectionEpoch = connectionEpoch
        self.enqueuedAt = enqueuedAt
    }
}

public struct TreadmillCommandSendAttemptEvidence: Codable, Hashable, Sendable {
    public let commandID: CommandID
    public let decisionID: DecisionID?
    public let attemptID: CommandAttemptID
    public let attemptNumber: UInt16
    public let protocolKind: TreadmillProtocolKind
    public let connectionEpoch: TreadmillConnectionEpoch
    public let sentAt: Date
    public let writeType: TreadmillCommandWriteType

    public init(
        commandID: CommandID,
        decisionID: DecisionID?,
        attemptID: CommandAttemptID,
        attemptNumber: UInt16,
        protocolKind: TreadmillProtocolKind,
        connectionEpoch: TreadmillConnectionEpoch,
        sentAt: Date,
        writeType: TreadmillCommandWriteType
    ) {
        self.commandID = commandID
        self.decisionID = decisionID
        self.attemptID = attemptID
        self.attemptNumber = attemptNumber
        self.protocolKind = protocolKind
        self.connectionEpoch = connectionEpoch
        self.sentAt = sentAt
        self.writeType = writeType
    }
}

public struct UnassociatedLegacyWriteObservation: Codable, Hashable, Sendable {
    public let protocolKind: TreadmillProtocolKind
    public let connectionEpoch: TreadmillConnectionEpoch
    public let sentAt: Date
    public let writeType: TreadmillCommandWriteType

    public init(
        protocolKind: TreadmillProtocolKind,
        connectionEpoch: TreadmillConnectionEpoch,
        sentAt: Date,
        writeType: TreadmillCommandWriteType
    ) {
        self.protocolKind = protocolKind
        self.connectionEpoch = connectionEpoch
        self.sentAt = sentAt
        self.writeType = writeType
    }
}

public struct TreadmillCommandQueueDelayEvidence: Codable, Hashable, Sendable {
    public let commandID: CommandID
    public let decisionID: DecisionID?
    public let connectionEpoch: TreadmillConnectionEpoch
    public let enqueuedAt: Date
    public let sentAt: Date

    public init(
        commandID: CommandID,
        decisionID: DecisionID?,
        connectionEpoch: TreadmillConnectionEpoch,
        enqueuedAt: Date,
        sentAt: Date
    ) {
        self.commandID = commandID
        self.decisionID = decisionID
        self.connectionEpoch = connectionEpoch
        self.enqueuedAt = enqueuedAt
        self.sentAt = sentAt
    }

    public var delay: TimeInterval {
        max(0, sentAt.timeIntervalSince(enqueuedAt))
    }
}

public enum LegacyAcknowledgementAssociation: Codable, Hashable, Sendable {
    case unresolvedByLegacyRuntime
    case deterministicallyCorrelated(commandID: CommandID, attemptID: CommandAttemptID)
}

/// An opaque capability supplied only by a decoder that has independently
/// proven an ACK-to-attempt edge. Current production protocols create none.
public struct TreadmillDeterministicAcknowledgementProof: Hashable, Sendable {
    private let evidenceKey: UUID

    init(evidenceKey: UUID) {
        self.evidenceKey = evidenceKey
    }
}

public struct LegacyAcknowledgementObservation: Codable, Hashable, Sendable {
    public let protocolKind: TreadmillProtocolKind
    public let connectionEpoch: TreadmillConnectionEpoch
    public let receivedAt: Date
    public let recordedAt: Date
    public let association: LegacyAcknowledgementAssociation

    public var commandID: CommandID? {
        switch association {
        case .unresolvedByLegacyRuntime:
            nil
        case let .deterministicallyCorrelated(commandID, _):
            commandID
        }
    }

    public var attemptID: CommandAttemptID? {
        switch association {
        case .unresolvedByLegacyRuntime:
            nil
        case let .deterministicallyCorrelated(_, attemptID):
            attemptID
        }
    }

    public static func unresolved(
        protocolKind: TreadmillProtocolKind,
        connectionEpoch: TreadmillConnectionEpoch,
        receivedAt: Date,
        recordedAt: Date
    ) -> Self {
        Self(
            protocolKind: protocolKind,
            connectionEpoch: connectionEpoch,
            receivedAt: receivedAt,
            recordedAt: recordedAt,
            association: .unresolvedByLegacyRuntime
        )
    }

    public static func deterministicallyAssociated(
        protocolKind: TreadmillProtocolKind,
        connectionEpoch: TreadmillConnectionEpoch,
        receivedAt: Date,
        recordedAt: Date,
        sendAttempt: TreadmillCommandSendAttemptEvidence,
        proof: TreadmillDeterministicAcknowledgementProof
    ) -> Self? {
        _ = proof
        guard sendAttempt.connectionEpoch == connectionEpoch else {
            return nil
        }
        return Self(
            protocolKind: protocolKind,
            connectionEpoch: connectionEpoch,
            receivedAt: receivedAt,
            recordedAt: recordedAt,
            association: .deterministicallyCorrelated(
                commandID: sendAttempt.commandID,
                attemptID: sendAttempt.attemptID
            )
        )
    }
}

public struct LegacyCommandTimeoutObservation: Codable, Hashable, Sendable {
    public let protocolKind: TreadmillProtocolKind
    public let connectionEpoch: TreadmillConnectionEpoch
    public let occurredAt: Date
    public let association: LegacyAcknowledgementAssociation

    public init(
        protocolKind: TreadmillProtocolKind,
        connectionEpoch: TreadmillConnectionEpoch,
        occurredAt: Date
    ) {
        self.protocolKind = protocolKind
        self.connectionEpoch = connectionEpoch
        self.occurredAt = occurredAt
        self.association = .unresolvedByLegacyRuntime
    }

    public var commandID: CommandID? { nil }

    public var attemptID: CommandAttemptID? { nil }

    private enum CodingKeys: String, CodingKey {
        case protocolKind
        case connectionEpoch
        case occurredAt
        case association
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let association = try container.decode(
            LegacyAcknowledgementAssociation.self,
            forKey: .association
        )
        guard association == .unresolvedByLegacyRuntime else {
            throw DecodingError.dataCorruptedError(
                forKey: .association,
                in: container,
                debugDescription: "Legacy timeout association must remain unresolved"
            )
        }
        self.protocolKind = try container.decode(
            TreadmillProtocolKind.self,
            forKey: .protocolKind
        )
        self.connectionEpoch = try container.decode(
            TreadmillConnectionEpoch.self,
            forKey: .connectionEpoch
        )
        self.occurredAt = try container.decode(Date.self, forKey: .occurredAt)
        self.association = association
    }
}

public enum TreadmillWriteResultStatus: String, Codable, Hashable, Sendable {
    case succeeded
    case failed
}

public struct LegacyWriteResultObservation: Codable, Hashable, Sendable {
    public let protocolKind: TreadmillProtocolKind
    public let connectionEpoch: TreadmillConnectionEpoch
    public let occurredAt: Date
    public let status: TreadmillWriteResultStatus
    public let association: LegacyAcknowledgementAssociation

    public init(
        protocolKind: TreadmillProtocolKind,
        connectionEpoch: TreadmillConnectionEpoch,
        occurredAt: Date,
        status: TreadmillWriteResultStatus
    ) {
        self.protocolKind = protocolKind
        self.connectionEpoch = connectionEpoch
        self.occurredAt = occurredAt
        self.status = status
        self.association = .unresolvedByLegacyRuntime
    }

    public var commandID: CommandID? { nil }

    public var attemptID: CommandAttemptID? { nil }

    private enum CodingKeys: String, CodingKey {
        case protocolKind
        case connectionEpoch
        case occurredAt
        case status
        case association
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let association = try container.decode(
            LegacyAcknowledgementAssociation.self,
            forKey: .association
        )
        guard association == .unresolvedByLegacyRuntime else {
            throw DecodingError.dataCorruptedError(
                forKey: .association,
                in: container,
                debugDescription: "Legacy write-result association must remain unresolved"
            )
        }
        self.protocolKind = try container.decode(
            TreadmillProtocolKind.self,
            forKey: .protocolKind
        )
        self.connectionEpoch = try container.decode(
            TreadmillConnectionEpoch.self,
            forKey: .connectionEpoch
        )
        self.occurredAt = try container.decode(Date.self, forKey: .occurredAt)
        self.status = try container.decode(
            TreadmillWriteResultStatus.self,
            forKey: .status
        )
        self.association = association
    }
}

public struct TreadmillCommandFailureObservation: Codable, Hashable, Sendable {
    public let commandID: CommandID?
    public let decisionID: DecisionID?
    public let attemptID: CommandAttemptID?
    public let connectionEpoch: TreadmillConnectionEpoch?
    public let occurredAt: Date
    public let reason: CommandFailureReason

    public init(
        commandID: CommandID?,
        decisionID: DecisionID?,
        attemptID: CommandAttemptID?,
        connectionEpoch: TreadmillConnectionEpoch?,
        occurredAt: Date,
        reason: CommandFailureReason
    ) {
        self.commandID = commandID
        self.decisionID = decisionID
        self.attemptID = attemptID
        self.connectionEpoch = connectionEpoch
        self.occurredAt = occurredAt
        self.reason = reason
    }
}

public struct TreadmillCommandCancellationObservation: Codable, Hashable, Sendable {
    public let commandID: CommandID
    public let decisionID: DecisionID?
    public let connectionEpoch: TreadmillConnectionEpoch
    public let occurredAt: Date
    public let reason: CommandCancellationReason

    public init(
        commandID: CommandID,
        decisionID: DecisionID?,
        connectionEpoch: TreadmillConnectionEpoch,
        occurredAt: Date,
        reason: CommandCancellationReason
    ) {
        self.commandID = commandID
        self.decisionID = decisionID
        self.connectionEpoch = connectionEpoch
        self.occurredAt = occurredAt
        self.reason = reason
    }
}

public struct TreadmillUnitsTruthEvidence: Codable, Hashable, Sendable {
    public let truth: TreadmillUnitsTruth
    public let observedAt: Date

    public init(truth: TreadmillUnitsTruth, observedAt: Date) {
        self.truth = truth
        self.observedAt = observedAt
    }
}

public struct TreadmillStopTruthEvidence: Codable, Hashable, Sendable {
    public let stopAttemptID: UUID
    public let decisionID: DecisionID?
    public let commandID: CommandID?
    public let observationID: ObservationID?
    public let connectionEpoch: TreadmillConnectionEpoch
    public let protocolKind: TreadmillProtocolKind
    public let conclusion: StopEvidenceConclusion
    public let rawSpeedTenths: Int?
    public let rawDeviceState: Int?
    public let checksumValid: Bool?
    public let observationReceivedAt: Date?
    public let evaluatedAt: Date

    public init(
        stopAttemptID: UUID,
        decisionID: DecisionID?,
        commandID: CommandID?,
        observationID: ObservationID?,
        connectionEpoch: TreadmillConnectionEpoch,
        protocolKind: TreadmillProtocolKind,
        conclusion: StopEvidenceConclusion,
        rawSpeedTenths: Int?,
        rawDeviceState: Int?,
        checksumValid: Bool?,
        observationReceivedAt: Date?,
        evaluatedAt: Date
    ) {
        self.stopAttemptID = stopAttemptID
        self.decisionID = decisionID
        self.commandID = commandID
        self.observationID = observationID
        self.connectionEpoch = connectionEpoch
        self.protocolKind = protocolKind
        self.conclusion = conclusion
        self.rawSpeedTenths = rawSpeedTenths
        self.rawDeviceState = rawDeviceState
        self.checksumValid = checksumValid
        self.observationReceivedAt = observationReceivedAt
        self.evaluatedAt = evaluatedAt
    }
}

public enum TreadmillAttemptEvidenceState: String, Codable, Hashable, Sendable {
    case sent
    case acknowledged
    case timedOut
    case failed
    case cancelled
}

public struct TreadmillCommandEvidenceLedger: Sendable {
    private struct Entry: Sendable {
        let sendAttempt: TreadmillCommandSendAttemptEvidence
        var state: TreadmillAttemptEvidenceState
    }

    private var entries: [CommandAttemptID: Entry] = [:]

    public init() {}

    public var attemptCount: Int {
        entries.count
    }

    public mutating func recordSendAttempt(_ sendAttempt: TreadmillCommandSendAttemptEvidence) {
        entries[sendAttempt.attemptID] = Entry(sendAttempt: sendAttempt, state: .sent)
    }

    public mutating func observeAcknowledgement(_ acknowledgement: LegacyAcknowledgementObservation) {
        guard case let .deterministicallyCorrelated(commandID, attemptID) = acknowledgement.association,
              var entry = entries[attemptID],
              entry.sendAttempt.commandID == commandID,
              entry.sendAttempt.connectionEpoch == acknowledgement.connectionEpoch else {
            return
        }
        entry.state = .acknowledged
        entries[attemptID] = entry
    }

    public func state(for attemptID: CommandAttemptID) -> TreadmillAttemptEvidenceState? {
        entries[attemptID]?.state
    }
}

public enum TreadmillTelemetrySinkDisposition: String, Codable, Hashable, Sendable,
    CaseIterable
{
    case accepted
    case degraded
    case rejected
    case unavailable
}

public enum TreadmillTelemetryEvidence: Codable, Hashable, Sendable {
    case observation(TreadmillObservationEvidence)
    case unitsTruth(TreadmillUnitsTruthEvidence)
    case decision(TreadmillControlDecisionEvidence)
    case commandEnqueued(TreadmillCommandEnqueuedEvidence)
    case commandQueueDelay(TreadmillCommandQueueDelayEvidence)
    case sendAttempt(TreadmillCommandSendAttemptEvidence)
    case unassociatedWrite(UnassociatedLegacyWriteObservation)
    case acknowledgement(LegacyAcknowledgementObservation)
    case writeResult(LegacyWriteResultObservation)
    case commandTimeout(LegacyCommandTimeoutObservation)
    case commandFailed(TreadmillCommandFailureObservation)
    case commandCancelled(TreadmillCommandCancellationObservation)
    case stopEvidence(TreadmillStopTruthEvidence)
}

public protocol TreadmillTelemetrySink: AnyObject {
    func observeTreadmillEvidence(
        _ evidence: TreadmillTelemetryEvidence
    ) -> TreadmillTelemetrySinkDisposition
}

public enum TreadmillObservationalTee {
    public static func afterLegacyAction(
        _ legacyAction: () -> Void,
        observe: (() -> TreadmillTelemetrySinkDisposition)?
    ) {
        legacyAction()
        _ = observe?()
    }
}
