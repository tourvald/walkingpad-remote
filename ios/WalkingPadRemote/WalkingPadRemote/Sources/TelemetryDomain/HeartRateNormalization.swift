import Foundation

public struct HeartRateCanonicalObservationID: RawRepresentable, Codable, Hashable, Sendable,
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

public struct HeartRateDeliveryID: RawRepresentable, Codable, Hashable, Sendable,
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

public enum HeartRateProviderKind: Codable, Hashable, Sendable {
    case legacyWatchWorkoutStream
    case healthKitSelected
    case mirroredWatchWorkout
    case phoneHealthKit
    case bluetooth
    case unknown
    case other(String)
}

public struct HeartRateProviderIdentity: Codable, Hashable, Sendable {
    public let kind: HeartRateProviderKind
    public let stableLocalKey: String

    public init(kind: HeartRateProviderKind, stableLocalKey: String) {
        self.kind = kind
        self.stableLocalKey = stableLocalKey
    }

    public var canScopeNativeSampleIdentity: Bool {
        !stableLocalKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct HeartRateProviderNativeSampleIdentity: Codable, Hashable, Sendable {
    public let identifier: String

    public init?(identifier: String) {
        guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        self.identifier = identifier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let identifier = try container.decode(String.self)
        guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "A provider-native HR identity must not be blank."
            )
        }
        self.identifier = identifier
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(identifier)
    }
}

public enum HeartRateNormalizationQualityFlag: String, Codable, Hashable, Sendable,
    CaseIterable
{
    case missingMeasurementTime
    case missingSourceObservationTime
    case malformedSourceObservationTime
    case missingProviderSequence
    case malformedProviderSequence
    case duplicateProviderIdentity
    case duplicateProviderSequence
    case providerSequenceOutOfOrder
    case sourceObservationOutOfArrivalOrder
    case repeatedValue
    case receivedLate
    case clockRegression
    case gapBefore
    case missingStableSourceIdentity
}

public enum HeartRateSourceClockRelationship: String, Codable, Hashable, Sendable {
    case independent
    case receiverComparable
}

public struct HeartRateNormalizationQualityFlags: Codable, Hashable, Sendable,
    ExpressibleByArrayLiteral
{
    public private(set) var values: Set<HeartRateNormalizationQualityFlag>

    public init(_ values: Set<HeartRateNormalizationQualityFlag> = []) {
        self.values = values
    }

    public init(arrayLiteral elements: HeartRateNormalizationQualityFlag...) {
        self.init(Set(elements))
    }

    public func contains(_ flag: HeartRateNormalizationQualityFlag) -> Bool {
        values.contains(flag)
    }

    public mutating func insert(_ flag: HeartRateNormalizationQualityFlag) {
        values.insert(flag)
    }

    public mutating func formUnion(_ other: HeartRateNormalizationQualityFlags) {
        values.formUnion(other.values)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(Set(try container.decode([HeartRateNormalizationQualityFlag].self)))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values.sorted { $0.rawValue < $1.rawValue })
    }
}

public enum HeartRateWatchPayloadKey {
    public static let sourceCallbackObservedAt = "hr_callback_observed_at"
    public static let providerSequence = "hr_sequence"
}

public struct DecodedWatchHeartRatePayload: Hashable, Sendable {
    public let beatsPerMinute: Int
    public let sourceCallbackObservedAt: Date?
    public let providerSequence: Int64?
    public let quality: HeartRateNormalizationQualityFlags

    public init(
        beatsPerMinute: Int,
        sourceCallbackObservedAt: Date?,
        providerSequence: Int64?,
        quality: HeartRateNormalizationQualityFlags
    ) {
        self.beatsPerMinute = beatsPerMinute
        self.sourceCallbackObservedAt = sourceCallbackObservedAt
        self.providerSequence = providerSequence
        self.quality = quality
    }
}

public enum WatchHeartRatePayloadDecoder {
    public static func decode(_ payload: [String: Any]) -> DecodedWatchHeartRatePayload? {
        guard let heartRate = payload["hr"] as? Double, heartRate.isFinite else {
            return nil
        }

        var quality: HeartRateNormalizationQualityFlags = []
        let sourceCallbackObservedAt: Date?
        if let value = payload[HeartRateWatchPayloadKey.sourceCallbackObservedAt] {
            if let seconds = finiteDouble(value) {
                sourceCallbackObservedAt = Date(timeIntervalSince1970: seconds)
            } else {
                sourceCallbackObservedAt = nil
                quality.insert(.malformedSourceObservationTime)
            }
        } else {
            sourceCallbackObservedAt = nil
            quality.insert(.missingSourceObservationTime)
        }

        let providerSequence: Int64?
        if let value = payload[HeartRateWatchPayloadKey.providerSequence] {
            if let sequence = exactInt64(value) {
                providerSequence = sequence
            } else {
                providerSequence = nil
                quality.insert(.malformedProviderSequence)
            }
        } else {
            providerSequence = nil
            quality.insert(.missingProviderSequence)
        }

        return DecodedWatchHeartRatePayload(
            beatsPerMinute: Int(heartRate.rounded()),
            sourceCallbackObservedAt: sourceCallbackObservedAt,
            providerSequence: providerSequence,
            quality: quality
        )
    }

    private static func finiteDouble(_ value: Any) -> Double? {
        guard !(value is Bool) else {
            return nil
        }
        if let value = value as? Double, value.isFinite {
            return value
        }
        if let value = value as? NSNumber {
            let double = value.doubleValue
            return double.isFinite ? double : nil
        }
        return nil
    }

    private static func exactInt64(_ value: Any) -> Int64? {
        guard !(value is Bool) else {
            return nil
        }
        if let value = value as? Int64 {
            return value
        }
        if let value = value as? Int {
            return Int64(exactly: value)
        }
        if let value = value as? NSNumber {
            let double = value.doubleValue
            guard double.isFinite,
                  double.rounded(.towardZero) == double,
                  double >= Double(Int64.min),
                  double < 9_223_372_036_854_775_808
            else {
                return nil
            }
            return Int64(double)
        }
        return nil
    }
}

public struct HeartRateProviderObservation: Codable, Hashable, Sendable {
    public let source: HeartRateProviderIdentity
    public let beatsPerMinute: Int
    public let providerSequence: Int64?
    public let providerNativeIdentity: HeartRateProviderNativeSampleIdentity?
    public let measuredAt: Date?
    public let sourceCallbackObservedAt: Date?
    public let sourceClockRelationship: HeartRateSourceClockRelationship
    public let receivedAt: Date
    public let metadataQuality: HeartRateNormalizationQualityFlags

    public init(
        source: HeartRateProviderIdentity,
        beatsPerMinute: Int,
        providerSequence: Int64?,
        providerNativeIdentity: HeartRateProviderNativeSampleIdentity?,
        measuredAt: Date?,
        sourceCallbackObservedAt: Date?,
        sourceClockRelationship: HeartRateSourceClockRelationship,
        receivedAt: Date,
        metadataQuality: HeartRateNormalizationQualityFlags
    ) {
        self.source = source
        self.beatsPerMinute = beatsPerMinute
        self.providerSequence = providerSequence
        self.providerNativeIdentity = providerNativeIdentity
        self.measuredAt = measuredAt
        self.sourceCallbackObservedAt = sourceCallbackObservedAt
        self.sourceClockRelationship = sourceClockRelationship
        self.receivedAt = receivedAt
        self.metadataQuality = metadataQuality
    }
}

public struct NormalizedHeartRateScientificObservation: Codable, Hashable, Sendable {
    public let canonicalObservationID: HeartRateCanonicalObservationID
    public let source: HeartRateProviderIdentity
    public let beatsPerMinute: Int
    public let providerSequence: Int64?
    public let providerNativeIdentity: HeartRateProviderNativeSampleIdentity?
    public let measuredAt: Date?
    public let sourceCallbackObservedAt: Date?
    public let sourceClockRelationship: HeartRateSourceClockRelationship
    public let receivedAt: Date
    public let recordedAt: Date
    public let quality: HeartRateNormalizationQualityFlags

    public init(
        canonicalObservationID: HeartRateCanonicalObservationID,
        source: HeartRateProviderIdentity,
        beatsPerMinute: Int,
        providerSequence: Int64?,
        providerNativeIdentity: HeartRateProviderNativeSampleIdentity?,
        measuredAt: Date?,
        sourceCallbackObservedAt: Date?,
        sourceClockRelationship: HeartRateSourceClockRelationship,
        receivedAt: Date,
        recordedAt: Date,
        quality: HeartRateNormalizationQualityFlags
    ) {
        self.canonicalObservationID = canonicalObservationID
        self.source = source
        self.beatsPerMinute = beatsPerMinute
        self.providerSequence = providerSequence
        self.providerNativeIdentity = providerNativeIdentity
        self.measuredAt = measuredAt
        self.sourceCallbackObservedAt = sourceCallbackObservedAt
        self.sourceClockRelationship = sourceClockRelationship
        self.receivedAt = receivedAt
        self.recordedAt = recordedAt
        self.quality = quality
    }
}

public enum HeartRateControlUseAtDelivery: String, Codable, Hashable, Sendable {
    case notYetObserved
}

public struct HeartRateCausalReference: Codable, Hashable, Sendable {
    public let deliveryID: HeartRateDeliveryID
    public let canonicalObservationID: HeartRateCanonicalObservationID

    public init(
        deliveryID: HeartRateDeliveryID,
        canonicalObservationID: HeartRateCanonicalObservationID
    ) {
        self.deliveryID = deliveryID
        self.canonicalObservationID = canonicalObservationID
    }
}

public struct HeartRateDeliveryEvidence: Codable, Hashable, Sendable {
    public let deliveryID: HeartRateDeliveryID
    public let canonicalObservationID: HeartRateCanonicalObservationID
    public let source: HeartRateProviderIdentity
    public let beatsPerMinute: Int
    public let arrivalOrder: UInt64
    public let providerSequence: Int64?
    public let sourceCallbackObservedAt: Date?
    public let sourceClockRelationship: HeartRateSourceClockRelationship
    public let receivedAt: Date
    public let recordedAt: Date
    public let quality: HeartRateNormalizationQualityFlags
    public let acceptedIntoLegacyControllerState: Bool
    public let controlUseAtDelivery: HeartRateControlUseAtDelivery

    public init(
        deliveryID: HeartRateDeliveryID,
        canonicalObservationID: HeartRateCanonicalObservationID,
        source: HeartRateProviderIdentity,
        beatsPerMinute: Int,
        arrivalOrder: UInt64,
        providerSequence: Int64?,
        sourceCallbackObservedAt: Date?,
        sourceClockRelationship: HeartRateSourceClockRelationship,
        receivedAt: Date,
        recordedAt: Date,
        quality: HeartRateNormalizationQualityFlags,
        acceptedIntoLegacyControllerState: Bool,
        controlUseAtDelivery: HeartRateControlUseAtDelivery
    ) {
        self.deliveryID = deliveryID
        self.canonicalObservationID = canonicalObservationID
        self.source = source
        self.beatsPerMinute = beatsPerMinute
        self.arrivalOrder = arrivalOrder
        self.providerSequence = providerSequence
        self.sourceCallbackObservedAt = sourceCallbackObservedAt
        self.sourceClockRelationship = sourceClockRelationship
        self.receivedAt = receivedAt
        self.recordedAt = recordedAt
        self.quality = quality
        self.acceptedIntoLegacyControllerState = acceptedIntoLegacyControllerState
        self.controlUseAtDelivery = controlUseAtDelivery
    }

    public var causalReference: HeartRateCausalReference {
        HeartRateCausalReference(
            deliveryID: deliveryID,
            canonicalObservationID: canonicalObservationID
        )
    }
}

public struct HeartRateNormalizationResult: Codable, Hashable, Sendable {
    public let canonicalObservation: NormalizedHeartRateScientificObservation?
    public let delivery: HeartRateDeliveryEvidence

    public init(
        canonicalObservation: NormalizedHeartRateScientificObservation?,
        delivery: HeartRateDeliveryEvidence
    ) {
        self.canonicalObservation = canonicalObservation
        self.delivery = delivery
    }
}

public struct HeartRateCanonicalBinding: Codable, Hashable, Sendable {
    public let source: HeartRateProviderIdentity
    public let providerNativeIdentity: HeartRateProviderNativeSampleIdentity
    public let canonicalObservationID: HeartRateCanonicalObservationID

    public init(
        source: HeartRateProviderIdentity,
        providerNativeIdentity: HeartRateProviderNativeSampleIdentity,
        canonicalObservationID: HeartRateCanonicalObservationID
    ) {
        self.source = source
        self.providerNativeIdentity = providerNativeIdentity
        self.canonicalObservationID = canonicalObservationID
    }
}

public struct HeartRateObservationNormalizer: Sendable {
    private struct NativeIdentityKey: Hashable, Sendable {
        let source: HeartRateProviderIdentity
        let providerNativeIdentity: HeartRateProviderNativeSampleIdentity
    }

    private struct SourceState: Sendable {
        var lastProviderSequence: Int64?
        var lastSourceObservationTime: Date?
        var lastBeatsPerMinute: Int?
        var hasStarted = false
        var isStarted = false
        var hasObservedStale = false
        var hasObservedExplicitStop = false
    }

    private let receiveDelayThreshold: TimeInterval
    private var canonicalByNativeIdentity: [NativeIdentityKey: HeartRateCanonicalObservationID]
    private var sourceStates: [HeartRateProviderIdentity: SourceState] = [:]
    private var nextArrivalOrder: UInt64 = 1

    public init(
        receiveDelayThreshold: TimeInterval = 3,
        restoredCanonicalBindings: [HeartRateCanonicalBinding] = []
    ) {
        self.receiveDelayThreshold = max(0, receiveDelayThreshold)
        canonicalByNativeIdentity = [:]
        canonicalByNativeIdentity.reserveCapacity(restoredCanonicalBindings.count)
        for binding in restoredCanonicalBindings {
            guard binding.source.canScopeNativeSampleIdentity else { continue }
            let key = NativeIdentityKey(
                source: binding.source,
                providerNativeIdentity: binding.providerNativeIdentity
            )
            if canonicalByNativeIdentity[key] == nil {
                canonicalByNativeIdentity[key] = binding.canonicalObservationID
            }
        }
    }

    public mutating func normalize(
        _ observation: HeartRateProviderObservation,
        canonicalObservationID candidateCanonicalObservationID: HeartRateCanonicalObservationID,
        deliveryID: HeartRateDeliveryID,
        recordedAt: Date
    ) -> HeartRateNormalizationResult {
        var state = sourceStates[observation.source] ?? SourceState()
        var quality = observation.metadataQuality
        if observation.measuredAt == nil {
            quality.insert(.missingMeasurementTime)
        }
        if observation.sourceCallbackObservedAt == nil,
           !quality.contains(.malformedSourceObservationTime)
        {
            quality.insert(.missingSourceObservationTime)
        }
        if observation.providerSequence == nil,
           !quality.contains(.malformedProviderSequence)
        {
            quality.insert(.missingProviderSequence)
        }

        if let sequence = observation.providerSequence,
           let previous = state.lastProviderSequence
        {
            if sequence == previous {
                quality.insert(.duplicateProviderSequence)
            } else if sequence < previous {
                quality.insert(.providerSequenceOutOfOrder)
            } else if previous < Int64.max, sequence > previous + 1 {
                quality.insert(.gapBefore)
            }
        }
        if let sequence = observation.providerSequence,
           state.lastProviderSequence.map({ sequence > $0 }) ?? true
        {
            state.lastProviderSequence = sequence
        }

        if let sourceObservedAt = observation.sourceCallbackObservedAt {
            if let previous = state.lastSourceObservationTime,
               sourceObservedAt < previous
            {
                quality.insert(.sourceObservationOutOfArrivalOrder)
            }
            if state.lastSourceObservationTime.map({ sourceObservedAt > $0 }) ?? true {
                state.lastSourceObservationTime = sourceObservedAt
            }
            if observation.sourceClockRelationship == .receiverComparable {
                let delay = observation.receivedAt.timeIntervalSince(sourceObservedAt)
                if delay < 0 {
                    quality.insert(.clockRegression)
                } else if delay > receiveDelayThreshold {
                    quality.insert(.receivedLate)
                }
            }
        }

        if state.lastBeatsPerMinute == observation.beatsPerMinute {
            quality.insert(.repeatedValue)
        }
        state.lastBeatsPerMinute = observation.beatsPerMinute
        sourceStates[observation.source] = state

        let canonicalObservationID: HeartRateCanonicalObservationID
        let isCanonicalRedelivery: Bool
        if let providerNativeIdentity = observation.providerNativeIdentity,
           observation.source.canScopeNativeSampleIdentity
        {
            let key = NativeIdentityKey(
                source: observation.source,
                providerNativeIdentity: providerNativeIdentity
            )
            if let existing = canonicalByNativeIdentity[key] {
                canonicalObservationID = existing
                isCanonicalRedelivery = true
                quality.insert(.duplicateProviderIdentity)
            } else {
                canonicalObservationID = candidateCanonicalObservationID
                isCanonicalRedelivery = false
                canonicalByNativeIdentity[key] = candidateCanonicalObservationID
            }
        } else {
            if observation.providerNativeIdentity != nil {
                quality.insert(.missingStableSourceIdentity)
            }
            canonicalObservationID = candidateCanonicalObservationID
            isCanonicalRedelivery = false
        }

        let arrivalOrder = nextArrivalOrder
        if nextArrivalOrder < UInt64.max {
            nextArrivalOrder += 1
        }
        let canonicalObservation = isCanonicalRedelivery ? nil :
            NormalizedHeartRateScientificObservation(
                canonicalObservationID: canonicalObservationID,
                source: observation.source,
                beatsPerMinute: observation.beatsPerMinute,
                providerSequence: observation.providerSequence,
                providerNativeIdentity: observation.providerNativeIdentity,
                measuredAt: observation.measuredAt,
                sourceCallbackObservedAt: observation.sourceCallbackObservedAt,
                sourceClockRelationship: observation.sourceClockRelationship,
                receivedAt: observation.receivedAt,
                recordedAt: recordedAt,
                quality: quality
            )
        let delivery = HeartRateDeliveryEvidence(
            deliveryID: deliveryID,
            canonicalObservationID: canonicalObservationID,
            source: observation.source,
            beatsPerMinute: observation.beatsPerMinute,
            arrivalOrder: arrivalOrder,
            providerSequence: observation.providerSequence,
            sourceCallbackObservedAt: observation.sourceCallbackObservedAt,
            sourceClockRelationship: observation.sourceClockRelationship,
            receivedAt: observation.receivedAt,
            recordedAt: recordedAt,
            quality: quality,
            acceptedIntoLegacyControllerState: true,
            controlUseAtDelivery: .notYetObserved
        )
        return HeartRateNormalizationResult(
            canonicalObservation: canonicalObservation,
            delivery: delivery
        )
    }

    public mutating func observeLifecycle(
        _ transition: HeartRateSourceLifecycleInput,
        source: HeartRateProviderIdentity,
        occurredAt: Date
    ) -> HeartRateSourceLifecycleEvidence? {
        var state = sourceStates[source] ?? SourceState()
        let kind: HeartRateSourceLifecycleKind?
        switch transition {
        case .available:
            kind = .available
        case .unavailable:
            kind = .unavailable
        case .started:
            kind = state.hasStarted && !state.isStarted ? .restarted : .started
            state.hasStarted = true
            state.isStarted = true
            state.hasObservedStale = false
            state.hasObservedExplicitStop = false
            state.lastProviderSequence = nil
            state.lastSourceObservationTime = nil
            state.lastBeatsPerMinute = nil
        case .stopped:
            kind = .stopped
            state.isStarted = false
            state.hasObservedStale = false
            state.hasObservedExplicitStop = true
        case .stale:
            if state.hasObservedExplicitStop || state.hasObservedStale {
                kind = nil
            } else {
                kind = .stale
                state.hasObservedStale = true
            }
        case .recovered:
            if state.hasObservedStale && !state.hasObservedExplicitStop {
                kind = .recovered
                state.hasObservedStale = false
            } else {
                kind = nil
            }
        }
        sourceStates[source] = state
        guard let kind else { return nil }
        return HeartRateSourceLifecycleEvidence(
            source: source,
            kind: kind,
            occurredAt: occurredAt
        )
    }
}

public enum HeartRateSourceLifecycleInput: String, Codable, Hashable, Sendable {
    case available
    case unavailable
    case started
    case stopped
    case stale
    case recovered
}

public enum HeartRateSourceLifecycleKind: String, Codable, Hashable, Sendable {
    case available
    case unavailable
    case started
    case restarted
    case stopped
    case stale
    case recovered
}

public struct HeartRateSourceLifecycleEvidence: Codable, Hashable, Sendable {
    public let source: HeartRateProviderIdentity
    public let kind: HeartRateSourceLifecycleKind
    public let occurredAt: Date

    public init(
        source: HeartRateProviderIdentity,
        kind: HeartRateSourceLifecycleKind,
        occurredAt: Date
    ) {
        self.source = source
        self.kind = kind
        self.occurredAt = occurredAt
    }
}

public enum HeartRateControlUseKind: String, Codable, Hashable, Sendable {
    case speedDecision
}

public struct HeartRateControlUseEvidence: Codable, Hashable, Sendable {
    public let kind: HeartRateControlUseKind
    public let inputs: [HeartRateCausalReference]
    public let occurredAt: Date

    public init(
        kind: HeartRateControlUseKind,
        inputs: [HeartRateCausalReference],
        occurredAt: Date
    ) {
        self.kind = kind
        self.inputs = inputs
        self.occurredAt = occurredAt
    }
}

public enum HeartRateTelemetrySinkDisposition: String, Codable, Hashable, Sendable,
    CaseIterable
{
    case accepted
    case degraded
    case rejected
    case unavailable
}

public protocol HeartRateTelemetrySink: AnyObject {
    func observeHeartRate(
        _ result: HeartRateNormalizationResult
    ) -> HeartRateTelemetrySinkDisposition
    func observeSourceLifecycle(
        _ evidence: HeartRateSourceLifecycleEvidence
    ) -> HeartRateTelemetrySinkDisposition
    func observeControlUse(
        _ evidence: HeartRateControlUseEvidence
    ) -> HeartRateTelemetrySinkDisposition
}

public enum HeartRateObservationalTee {
    @discardableResult
    public static func deliver(
        _ beatsPerMinute: Int,
        toLegacyController: (Int) -> Void,
        observe: (() -> HeartRateTelemetrySinkDisposition)?
    ) -> HeartRateTelemetrySinkDisposition {
        toLegacyController(beatsPerMinute)
        return observe?() ?? .unavailable
    }
}

public enum HeartRateLegacyControlSemantics {
    public static func applyDelivery(
        _ beatsPerMinute: Int,
        now: () -> Date,
        updateCurrent: (Int) -> Void,
        updateLastKnown: (Int) -> Void,
        updateLastReceivedAt: (Date) -> Void,
        recordPredictorInput: (Int) -> Void
    ) {
        updateCurrent(beatsPerMinute)
        updateLastKnown(beatsPerMinute)
        updateLastReceivedAt(now())
        recordPredictorInput(beatsPerMinute)
    }

    public static func streamIsActive(
        beatsPerMinute: Int,
        hasLastReceivedAt: Bool,
        ageSeconds: Int,
        staleThresholdSeconds: Int
    ) -> Bool {
        beatsPerMinute > 0 && hasLastReceivedAt && ageSeconds <= staleThresholdSeconds
    }

    public static func isWithinInitialGrace(
        startedAt: Date?,
        now: Date,
        graceSeconds: Int
    ) -> Bool {
        guard let startedAt else { return false }
        return now.timeIntervalSince(startedAt) < TimeInterval(graceSeconds)
    }

    public static func missingSignalSeconds(
        lastReceivedAt: Date?,
        now: Date,
        noDataMaximumSeconds: Int
    ) -> Int {
        guard let lastReceivedAt else { return noDataMaximumSeconds }
        return max(0, Int(now.timeIntervalSince(lastReceivedAt)))
    }

    public static func shouldStopForMissingSignal(
        missingSeconds: Int,
        noDataMaximumSeconds: Int
    ) -> Bool {
        missingSeconds >= noDataMaximumSeconds
    }
}

public enum HeartRateControlStartEligibility {
    public static func existingPrerequisitesAllowStart(
        treadmillConnected: Bool,
        watchReachable: Bool,
        currentHeartRateVisible: Bool
    ) -> Bool {
        treadmillConnected && watchReachable && currentHeartRateVisible
    }
}
