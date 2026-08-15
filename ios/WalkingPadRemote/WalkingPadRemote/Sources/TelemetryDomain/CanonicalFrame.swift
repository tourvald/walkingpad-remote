import Foundation

public enum CanonicalGapKind: String, Codable, Hashable, Sendable {
    case noObservation
    case runtimeSuspensionOrStall
    case recorderOutageOrLoss
    case unknown
}

public struct CanonicalGapBoundary: Codable, Hashable, Sendable {
    public let missingSinceElapsedSecond: Int64
    public let kind: CanonicalGapKind

    public init(missingSinceElapsedSecond: Int64, kind: CanonicalGapKind) {
        self.missingSinceElapsedSecond = missingSinceElapsedSecond
        self.kind = kind
    }
}

public struct HeartRateFrameEvidence: Codable, Hashable, Sendable {
    public let observationID: ObservationID
    public let recordID: RecordID
    public let sourceID: SourceID
    public let beatsPerMinute: UInt16
    public let measuredAt: Date?
    public let receivedAt: Date
    public let evidenceElapsed: ElapsedDuration
    public let ageAtMaterialization: ElapsedDuration
    public let freshness: FreshnessState
    public let provenance: EvidenceProvenance

    public init(
        observationID: ObservationID,
        recordID: RecordID,
        sourceID: SourceID,
        beatsPerMinute: UInt16,
        measuredAt: Date?,
        receivedAt: Date,
        evidenceElapsed: ElapsedDuration,
        ageAtMaterialization: ElapsedDuration,
        freshness: FreshnessState,
        provenance: EvidenceProvenance
    ) {
        self.observationID = observationID
        self.recordID = recordID
        self.sourceID = sourceID
        self.beatsPerMinute = beatsPerMinute
        self.measuredAt = measuredAt
        self.receivedAt = receivedAt
        self.evidenceElapsed = evidenceElapsed
        self.ageAtMaterialization = ageAtMaterialization
        self.freshness = freshness
        self.provenance = provenance
    }
}

public struct TreadmillFrameEvidence: Codable, Hashable, Sendable {
    public let observationID: ObservationID
    public let recordID: RecordID
    public let sourceID: SourceID
    public let nativeSpeed: NativeTreadmillSpeed
    public let factualSpeed: FactualSpeedKilometresPerHour?
    public let deviceState: TreadmillDeviceState
    public let measuredAt: Date?
    public let receivedAt: Date
    public let evidenceElapsed: ElapsedDuration
    public let ageAtMaterialization: ElapsedDuration
    public let freshness: FreshnessState
    public let provenance: EvidenceProvenance

    public init(
        observationID: ObservationID,
        recordID: RecordID,
        sourceID: SourceID,
        nativeSpeed: NativeTreadmillSpeed,
        factualSpeed: FactualSpeedKilometresPerHour?,
        deviceState: TreadmillDeviceState,
        measuredAt: Date?,
        receivedAt: Date,
        evidenceElapsed: ElapsedDuration,
        ageAtMaterialization: ElapsedDuration,
        freshness: FreshnessState,
        provenance: EvidenceProvenance
    ) {
        self.observationID = observationID
        self.recordID = recordID
        self.sourceID = sourceID
        self.nativeSpeed = nativeSpeed
        self.factualSpeed = factualSpeed
        self.deviceState = deviceState
        self.measuredAt = measuredAt
        self.receivedAt = receivedAt
        self.evidenceElapsed = evidenceElapsed
        self.ageAtMaterialization = ageAtMaterialization
        self.freshness = freshness
        self.provenance = provenance
    }
}

public struct CanonicalFrame: Codable, Hashable, Sendable {
    public let frameID: FrameID
    public let recordID: RecordID
    public let sessionID: SessionID
    public let canonicalElapsedSecond: Int64
    public let materializedAt: RecordTimestamp
    public let heartRateEvidence: HeartRateFrameEvidence?
    public let treadmillEvidence: TreadmillFrameEvidence?
    public let precedingGap: CanonicalGapBoundary?

    public init(
        frameID: FrameID,
        recordID: RecordID,
        sessionID: SessionID,
        canonicalElapsedSecond: Int64,
        materializedAt: RecordTimestamp,
        heartRateEvidence: HeartRateFrameEvidence?,
        treadmillEvidence: TreadmillFrameEvidence?,
        precedingGap: CanonicalGapBoundary? = nil
    ) {
        self.frameID = frameID
        self.recordID = recordID
        self.sessionID = sessionID
        self.canonicalElapsedSecond = canonicalElapsedSecond
        self.materializedAt = materializedAt
        self.heartRateEvidence = heartRateEvidence
        self.treadmillEvidence = treadmillEvidence
        self.precedingGap = precedingGap
    }
}
