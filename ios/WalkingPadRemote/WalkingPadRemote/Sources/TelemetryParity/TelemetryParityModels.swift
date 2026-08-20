import Foundation

public enum TelemetryParityStatus: String, Codable, CaseIterable, Sendable {
    case pass = "PASS"
    case fail = "FAIL"
    case inconclusive = "INCONCLUSIVE"
}

public enum TelemetryParityCategory: String, Codable, CaseIterable, Sendable {
    case lifecycle
    case heartRateObservations
    case phaseAndCooldown
    case configurationAndVersions
    case controlDecisions
    case treadmillFacts
    case commandLifecycle
    case timestampDerivedAggregates
    case stopAndSafety
    case recordIntegrity
    case causalAssociation
    case physicalDeviceTruth
}

public enum TelemetryParityFindingClass: String, Codable, Sendable {
    case sourceLegacyLimitation
    case v2RecorderOrDataLoss
    case protocolRuntimeCausalAmbiguity
    case actualSemanticMismatch
    case unsupportedCausalEdge
    case deviceOnlyUnverified
}

public struct TelemetryParityFinding: Codable, Equatable, Sendable {
    public let code: String
    public let classification: TelemetryParityFindingClass
    public let impact: TelemetryParityStatus
    public let detail: String

    public init(
        code: String,
        classification: TelemetryParityFindingClass,
        impact: TelemetryParityStatus,
        detail: String
    ) {
        self.code = code
        self.classification = classification
        self.impact = impact
        self.detail = detail
    }
}

public struct TelemetryParityCategoryResult: Codable, Equatable, Sendable {
    public let category: TelemetryParityCategory
    public let status: TelemetryParityStatus
    public let findings: [TelemetryParityFinding]

    public init(
        category: TelemetryParityCategory,
        status: TelemetryParityStatus,
        findings: [TelemetryParityFinding]
    ) {
        self.category = category
        self.status = status
        self.findings = findings
    }
}

public struct TelemetryParityCausalCoverage: Codable, Equatable, Sendable {
    public let factualOutcomeCount: Int
    public let deterministicallyAssociatedCount: Int
    public let honestlyUnknownCount: Int
    public let unsupportedClaimCount: Int

    public init(
        factualOutcomeCount: Int,
        deterministicallyAssociatedCount: Int,
        honestlyUnknownCount: Int,
        unsupportedClaimCount: Int
    ) {
        self.factualOutcomeCount = factualOutcomeCount
        self.deterministicallyAssociatedCount = deterministicallyAssociatedCount
        self.honestlyUnknownCount = honestlyUnknownCount
        self.unsupportedClaimCount = unsupportedClaimCount
    }
}

public struct TelemetrySemanticParityReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let legacySessionIdentifier: String?
    public let telemetryV2SessionIdentifier: String
    public let overallStatus: TelemetryParityStatus
    public let categories: [TelemetryParityCategoryResult]
    public let causalCoverage: TelemetryParityCausalCoverage

    public init(
        schemaVersion: Int = 1,
        legacySessionIdentifier: String?,
        telemetryV2SessionIdentifier: String,
        overallStatus: TelemetryParityStatus,
        categories: [TelemetryParityCategoryResult],
        causalCoverage: TelemetryParityCausalCoverage
    ) {
        self.schemaVersion = schemaVersion
        self.legacySessionIdentifier = legacySessionIdentifier
        self.telemetryV2SessionIdentifier = telemetryV2SessionIdentifier
        self.overallStatus = overallStatus
        self.categories = categories
        self.causalCoverage = causalCoverage
    }

    public func machineReadableJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public func humanReadableText() -> String {
        var lines = [
            "Telemetry V2 semantic parity: \(overallStatus.rawValue)",
            "legacy_session=\(legacySessionIdentifier ?? "unknown")",
            "v2_session=\(telemetryV2SessionIdentifier)",
        ]
        for result in categories {
            lines.append("[\(result.status.rawValue)] \(result.category.rawValue)")
            for finding in result.findings {
                lines.append(
                    "  - \(finding.classification.rawValue)/\(finding.code): \(finding.detail)"
                )
            }
        }
        lines.append(
            "causal_coverage factual=\(causalCoverage.factualOutcomeCount) " +
                "associated=\(causalCoverage.deterministicallyAssociatedCount) " +
                "unknown=\(causalCoverage.honestlyUnknownCount) " +
                "unsupported=\(causalCoverage.unsupportedClaimCount)"
        )
        return lines.joined(separator: "\n")
    }
}

public enum TelemetryParityEvidenceOrigin: String, Codable, Sendable {
    case legacyJSONL
    case telemetryV2
}

public enum TelemetryParityCompleteness: String, Codable, Sendable {
    case complete
    case incomplete
    case unknown
}

public struct TelemetryParityLifecycleEvidence: Codable, Equatable, Sendable {
    public let startedAt: Date?
    public let endedAt: Date?
    public let endReason: String?
    public let durationMilliseconds: Int64?

    public init(
        startedAt: Date?,
        endedAt: Date?,
        endReason: String?,
        durationMilliseconds: Int64?
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.endReason = endReason
        self.durationMilliseconds = durationMilliseconds
    }
}

public struct TelemetryParityHeartRateEvidence: Codable, Equatable, Sendable {
    public let elapsedMilliseconds: Int64
    public let receivedAt: Date
    public let beatsPerMinute: Int
    public let acceptedForControl: Bool
    public let arrivalOrder: UInt64

    public init(
        elapsedMilliseconds: Int64,
        receivedAt: Date,
        beatsPerMinute: Int,
        acceptedForControl: Bool,
        arrivalOrder: UInt64
    ) {
        self.elapsedMilliseconds = elapsedMilliseconds
        self.receivedAt = receivedAt
        self.beatsPerMinute = beatsPerMinute
        self.acceptedForControl = acceptedForControl
        self.arrivalOrder = arrivalOrder
    }
}

public struct TelemetryParityPhaseEvidence: Codable, Equatable, Sendable {
    public let phase: String
    public let elapsedMilliseconds: Int64

    public init(phase: String, elapsedMilliseconds: Int64) {
        self.phase = phase
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

public struct TelemetryParityConfigurationEvidence: Codable, Equatable, Sendable {
    public let targetHeartRate: Int?
    public let durationSeconds: Int?
    public let decisionIntervalSeconds: Int?
    public let adaptiveStepEnabled: Bool?
    public let maximumStepKilometresPerHour: Double?
    public let heartRateZoneUpperBounds: [Int]
    public let cooldownTargetHeartRate: Int?
    public let cooldownMinimumSpeedKilometresPerHour: Double?
    public let cooldownMaximumSeconds: Int?
    public let telemetrySchemaVersion: String?
    public let algorithmVersion: String?
    public let safetyPolicyVersion: String?
    public let workoutProtocolVersion: String?

    public init(
        targetHeartRate: Int?,
        durationSeconds: Int?,
        decisionIntervalSeconds: Int?,
        adaptiveStepEnabled: Bool?,
        maximumStepKilometresPerHour: Double?,
        heartRateZoneUpperBounds: [Int],
        cooldownTargetHeartRate: Int?,
        cooldownMinimumSpeedKilometresPerHour: Double?,
        cooldownMaximumSeconds: Int?,
        telemetrySchemaVersion: String?,
        algorithmVersion: String?,
        safetyPolicyVersion: String?,
        workoutProtocolVersion: String?
    ) {
        self.targetHeartRate = targetHeartRate
        self.durationSeconds = durationSeconds
        self.decisionIntervalSeconds = decisionIntervalSeconds
        self.adaptiveStepEnabled = adaptiveStepEnabled
        self.maximumStepKilometresPerHour = maximumStepKilometresPerHour
        self.heartRateZoneUpperBounds = heartRateZoneUpperBounds
        self.cooldownTargetHeartRate = cooldownTargetHeartRate
        self.cooldownMinimumSpeedKilometresPerHour = cooldownMinimumSpeedKilometresPerHour
        self.cooldownMaximumSeconds = cooldownMaximumSeconds
        self.telemetrySchemaVersion = telemetrySchemaVersion
        self.algorithmVersion = algorithmVersion
        self.safetyPolicyVersion = safetyPolicyVersion
        self.workoutProtocolVersion = workoutProtocolVersion
    }
}

public enum TelemetryParityDecisionDomain: String, Codable, Sendable {
    case heartRateControl
    case outsideHeartRateControl
    case unclassified
}

public struct TelemetryParityDecisionEvidence: Codable, Equatable, Sendable {
    public let domain: TelemetryParityDecisionDomain
    public let source: String
    public let action: String
    public let desiredSpeedKilometresPerHour: Double?
    public let elapsedMilliseconds: Int64

    public init(
        domain: TelemetryParityDecisionDomain,
        source: String,
        action: String,
        desiredSpeedKilometresPerHour: Double?,
        elapsedMilliseconds: Int64
    ) {
        self.domain = domain
        self.source = source
        self.action = action
        self.desiredSpeedKilometresPerHour = desiredSpeedKilometresPerHour
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

public struct TelemetryParityTreadmillFact: Codable, Equatable, Sendable {
    public let elapsedMilliseconds: Int64
    public let nativeValue: Double
    public let nativeUnit: String
    public let factualSpeedKilometresPerHour: Double?
    public let deviceState: String?

    public init(
        elapsedMilliseconds: Int64,
        nativeValue: Double,
        nativeUnit: String,
        factualSpeedKilometresPerHour: Double?,
        deviceState: String?
    ) {
        self.elapsedMilliseconds = elapsedMilliseconds
        self.nativeValue = nativeValue
        self.nativeUnit = nativeUnit
        self.factualSpeedKilometresPerHour = factualSpeedKilometresPerHour
        self.deviceState = deviceState
    }
}

public enum TelemetryParityCommandOutcomeKind: String, Codable, Hashable, Sendable {
    case sent
    case acknowledgement
    case timeout
    case writeResult
    case observedResponse
}

public enum TelemetryParityCausalAssociation: String, Codable, Sendable {
    case unknown
    case deterministicallyCorrelated
}

public struct TelemetryParityCommandEvidence: Codable, Equatable, Sendable {
    public let outcomeKind: TelemetryParityCommandOutcomeKind
    public let semanticCommand: String?
    public let elapsedMilliseconds: Int64
    public let association: TelemetryParityCausalAssociation
    public let commandIdentifier: String?
    public let attemptIdentifier: String?

    public init(
        outcomeKind: TelemetryParityCommandOutcomeKind,
        semanticCommand: String?,
        elapsedMilliseconds: Int64,
        association: TelemetryParityCausalAssociation,
        commandIdentifier: String?,
        attemptIdentifier: String?
    ) {
        self.outcomeKind = outcomeKind
        self.semanticCommand = semanticCommand
        self.elapsedMilliseconds = elapsedMilliseconds
        self.association = association
        self.commandIdentifier = commandIdentifier
        self.attemptIdentifier = attemptIdentifier
    }
}

public struct TelemetryParityAggregateEvidence: Codable, Equatable, Sendable {
    public let zoneSeconds: [Int]
    public let cooldownCoveredSeconds: Int?

    public init(zoneSeconds: [Int], cooldownCoveredSeconds: Int?) {
        self.zoneSeconds = zoneSeconds
        self.cooldownCoveredSeconds = cooldownCoveredSeconds
    }
}

public struct TelemetryParityStopEvidence: Codable, Equatable, Sendable {
    public let conclusion: String
    public let factualObservationIdentifier: String?
    public let elapsedMilliseconds: Int64

    public init(
        conclusion: String,
        factualObservationIdentifier: String?,
        elapsedMilliseconds: Int64
    ) {
        self.conclusion = conclusion
        self.factualObservationIdentifier = factualObservationIdentifier
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

public struct TelemetryParityIntegrityEvidence: Codable, Equatable, Sendable {
    public let duplicateRecordIdentifierCount: Int
    public let outOfOrderRecordCount: Int
    public let duplicateCanonicalSecondCount: Int
    public let unexplainedFrameGapCount: Int
    public let lostCriticalRecordCount: UInt64
    public let lostNativeRecordCount: UInt64

    public init(
        duplicateRecordIdentifierCount: Int = 0,
        outOfOrderRecordCount: Int = 0,
        duplicateCanonicalSecondCount: Int = 0,
        unexplainedFrameGapCount: Int = 0,
        lostCriticalRecordCount: UInt64 = 0,
        lostNativeRecordCount: UInt64 = 0
    ) {
        self.duplicateRecordIdentifierCount = duplicateRecordIdentifierCount
        self.outOfOrderRecordCount = outOfOrderRecordCount
        self.duplicateCanonicalSecondCount = duplicateCanonicalSecondCount
        self.unexplainedFrameGapCount = unexplainedFrameGapCount
        self.lostCriticalRecordCount = lostCriticalRecordCount
        self.lostNativeRecordCount = lostNativeRecordCount
    }
}

public struct TelemetryParitySourceLimitation: Codable, Equatable, Sendable {
    public let category: TelemetryParityCategory
    public let code: String
    public let detail: String

    public init(category: TelemetryParityCategory, code: String, detail: String) {
        self.category = category
        self.code = code
        self.detail = detail
    }
}

public struct TelemetryParitySessionEvidence: Codable, Equatable, Sendable {
    public let origin: TelemetryParityEvidenceOrigin
    public let sessionIdentifier: String
    public let linkedLegacySessionIdentifier: String?
    public let completeness: TelemetryParityCompleteness
    public let lifecycle: TelemetryParityLifecycleEvidence
    public let heartRate: [TelemetryParityHeartRateEvidence]
    public let phases: [TelemetryParityPhaseEvidence]
    public let configuration: TelemetryParityConfigurationEvidence?
    public let decisions: [TelemetryParityDecisionEvidence]
    public let treadmillFacts: [TelemetryParityTreadmillFact]
    public let commandEvidence: [TelemetryParityCommandEvidence]
    public let aggregates: TelemetryParityAggregateEvidence?
    public let stopEvidence: [TelemetryParityStopEvidence]
    public let integrity: TelemetryParityIntegrityEvidence
    public let limitations: [TelemetryParitySourceLimitation]

    public init(
        origin: TelemetryParityEvidenceOrigin,
        sessionIdentifier: String,
        linkedLegacySessionIdentifier: String?,
        completeness: TelemetryParityCompleteness,
        lifecycle: TelemetryParityLifecycleEvidence,
        heartRate: [TelemetryParityHeartRateEvidence] = [],
        phases: [TelemetryParityPhaseEvidence] = [],
        configuration: TelemetryParityConfigurationEvidence? = nil,
        decisions: [TelemetryParityDecisionEvidence] = [],
        treadmillFacts: [TelemetryParityTreadmillFact] = [],
        commandEvidence: [TelemetryParityCommandEvidence] = [],
        aggregates: TelemetryParityAggregateEvidence? = nil,
        stopEvidence: [TelemetryParityStopEvidence] = [],
        integrity: TelemetryParityIntegrityEvidence = TelemetryParityIntegrityEvidence(),
        limitations: [TelemetryParitySourceLimitation] = []
    ) {
        self.origin = origin
        self.sessionIdentifier = sessionIdentifier
        self.linkedLegacySessionIdentifier = linkedLegacySessionIdentifier
        self.completeness = completeness
        self.lifecycle = lifecycle
        self.heartRate = heartRate
        self.phases = phases
        self.configuration = configuration
        self.decisions = decisions
        self.treadmillFacts = treadmillFacts
        self.commandEvidence = commandEvidence
        self.aggregates = aggregates
        self.stopEvidence = stopEvidence
        self.integrity = integrity
        self.limitations = limitations
    }
}
