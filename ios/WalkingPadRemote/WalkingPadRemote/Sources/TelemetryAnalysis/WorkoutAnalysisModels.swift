import Foundation
import TelemetryDomain

public struct WorkoutAnalysisInput: Codable, Hashable, Sendable {
    public let session: WorkoutSessionRecord
    public let heartRate: [HeartRateObservation]
    public let treadmill: [TreadmillObservation]
    public let events: [WorkoutEvent]
    public let frames: [CanonicalFrame]

    public init(
        session: WorkoutSessionRecord,
        heartRate: [HeartRateObservation],
        treadmill: [TreadmillObservation],
        events: [WorkoutEvent],
        frames: [CanonicalFrame]
    ) {
        self.session = session
        self.heartRate = heartRate
        self.treadmill = treadmill
        self.events = events
        self.frames = frames
    }
}

public struct AnalyzerV1Policy: Codable, Hashable, Sendable {
    public static let acceptedInputSchemaMinimum = "1.0.0"
    public static let acceptedInputSchemaMaximum = "1.0.0"

    public static let `default` = AnalyzerV1Policy(
        heartRateFreshnessSeconds: 7,
        treadmillFreshnessSeconds: 5,
        settlingWindowSeconds: 30,
        stableSpeedMinimumSeconds: 30,
        stableSpeedToleranceKilometresPerHour: 0.1,
        informativeSpeedDeltaKilometresPerHour: 0.2,
        eventResponseWindowSeconds: 10,
        minimumWindowCoverageRatio: 0.5
    )

    public let heartRateFreshnessSeconds: Double
    public let treadmillFreshnessSeconds: Double
    public let settlingWindowSeconds: Double
    public let stableSpeedMinimumSeconds: Double
    public let stableSpeedToleranceKilometresPerHour: Double
    public let informativeSpeedDeltaKilometresPerHour: Double
    public let eventResponseWindowSeconds: Double
    public let minimumWindowCoverageRatio: Double

    public init(
        heartRateFreshnessSeconds: Double,
        treadmillFreshnessSeconds: Double,
        settlingWindowSeconds: Double,
        stableSpeedMinimumSeconds: Double,
        stableSpeedToleranceKilometresPerHour: Double,
        informativeSpeedDeltaKilometresPerHour: Double,
        eventResponseWindowSeconds: Double,
        minimumWindowCoverageRatio: Double
    ) {
        self.heartRateFreshnessSeconds = heartRateFreshnessSeconds
        self.treadmillFreshnessSeconds = treadmillFreshnessSeconds
        self.settlingWindowSeconds = settlingWindowSeconds
        self.stableSpeedMinimumSeconds = stableSpeedMinimumSeconds
        self.stableSpeedToleranceKilometresPerHour = stableSpeedToleranceKilometresPerHour
        self.informativeSpeedDeltaKilometresPerHour = informativeSpeedDeltaKilometresPerHour
        self.eventResponseWindowSeconds = eventResponseWindowSeconds
        self.minimumWindowCoverageRatio = minimumWindowCoverageRatio
    }
}

public enum AnalysisConfidence: String, Codable, Hashable, Sendable {
    case high
    case medium
    case low
    case unavailable
}

public struct AnalysisMetric<Value: Codable & Hashable & Sendable>: Codable, Hashable,
    Sendable
{
    public let value: Value?
    public let confidence: AnalysisConfidence
    public let unavailableReasons: [String]

    public init(
        value: Value?,
        confidence: AnalysisConfidence,
        unavailableReasons: [String] = []
    ) {
        self.value = value
        self.confidence = confidence
        self.unavailableReasons = unavailableReasons.sorted()
    }

    public static func unavailable(_ reasons: [String]) -> Self {
        Self(value: nil, confidence: .unavailable, unavailableReasons: reasons)
    }
}

public enum AnalysisQualityClass: String, Codable, Hashable, Sendable {
    case recorderEvidenceLoss
    case protocolRuntimeCausalAmbiguity
    case sourceCoverageUnavailable
    case malformedCorruptEvidence
}

public struct AnalysisQualityIssue: Codable, Hashable, Sendable {
    public let category: AnalysisQualityClass
    public let code: String
    public let count: UInt64
    public let detail: String?

    public init(
        category: AnalysisQualityClass,
        code: String,
        count: UInt64 = 1,
        detail: String? = nil
    ) {
        self.category = category
        self.code = code
        self.count = count
        self.detail = detail
    }
}

public struct DurationCoverage: Codable, Hashable, Sendable {
    public let coveredSeconds: Double
    public let uncoveredSeconds: Double
    public let coverageRatio: Double?

    public init(coveredSeconds: Double, uncoveredSeconds: Double) {
        self.coveredSeconds = coveredSeconds
        self.uncoveredSeconds = uncoveredSeconds
        let total = coveredSeconds + uncoveredSeconds
        coverageRatio = total > 0 ? coveredSeconds / total : nil
    }
}

public struct ScalarDistribution: Codable, Hashable, Sendable {
    public let count: Int
    public let minimum: Double
    public let maximum: Double
    public let mean: Double
    public let median: Double
    public let percentile95: Double
    public let standardDeviation: Double

    public init(
        count: Int,
        minimum: Double,
        maximum: Double,
        mean: Double,
        median: Double,
        percentile95: Double,
        standardDeviation: Double
    ) {
        self.count = count
        self.minimum = minimum
        self.maximum = maximum
        self.mean = mean
        self.median = median
        self.percentile95 = percentile95
        self.standardDeviation = standardDeviation
    }
}

public struct CausalAssociationCoverage: Codable, Hashable, Sendable {
    public let eligibleEdgeCount: Int
    public let provenEdgeCount: Int
    public let unknownAssociationCount: Int
    public let coverageRatio: Double?
    public let latencySeconds: AnalysisMetric<ScalarDistribution>

    public init(
        eligibleEdgeCount: Int,
        provenEdgeCount: Int,
        unknownAssociationCount: Int,
        latencySeconds: AnalysisMetric<ScalarDistribution>
    ) {
        self.eligibleEdgeCount = eligibleEdgeCount
        self.provenEdgeCount = provenEdgeCount
        self.unknownAssociationCount = unknownAssociationCount
        coverageRatio = eligibleEdgeCount > 0
            ? Double(provenEdgeCount) / Double(eligibleEdgeCount)
            : nil
        self.latencySeconds = latencySeconds
    }
}

public struct PhaseQualitySummary: Codable, Hashable, Sendable {
    public let phase: String
    public let durationSeconds: Double
    public let heartRateCoverage: DurationCoverage
    public let treadmillCoverage: DurationCoverage
    public let grade: AnalysisQualityGrade
    public let exclusionCodes: [String]

    public init(
        phase: String,
        durationSeconds: Double,
        heartRateCoverage: DurationCoverage,
        treadmillCoverage: DurationCoverage,
        grade: AnalysisQualityGrade,
        exclusionCodes: [String]
    ) {
        self.phase = phase
        self.durationSeconds = durationSeconds
        self.heartRateCoverage = heartRateCoverage
        self.treadmillCoverage = treadmillCoverage
        self.grade = grade
        self.exclusionCodes = exclusionCodes.sorted()
    }
}

public struct WorkoutDataQualityV1: Codable, Hashable, Sendable {
    public let sessionDurationSeconds: Double?
    public let heartRateCoverage: DurationCoverage
    public let heartRateGapCount: Int
    public let maximumHeartRateGapSeconds: Double?
    public let heartRateCadenceSeconds: AnalysisMetric<ScalarDistribution>
    public let receiveLatencySeconds: AnalysisMetric<ScalarDistribution>
    public let receiveTimeFallbackCount: Int
    public let duplicateEvidenceCount: Int
    public let outOfOrderEvidenceCount: Int
    public let sourceSwitchCount: Int
    public let treadmillFactualCoverage: DurationCoverage
    public let commandAcknowledgement: CausalAssociationCoverage
    public let commandFactualResponse: CausalAssociationCoverage
    public let incompleteSession: Bool
    public let recorderLoss: Bool
    public let issues: [AnalysisQualityIssue]
    public let sessionGrade: AnalysisQualityGrade
    public let phases: [PhaseQualitySummary]
}

public struct ZoneDurationV1: Codable, Hashable, Sendable {
    public let zone: Int
    public let seconds: Double
}

public struct HeartRateErrorMetricsV1: Codable, Hashable, Sendable {
    public let coveredSeconds: Double
    public let meanAbsoluteErrorBeatsPerMinute: Double
    public let rootMeanSquareErrorBeatsPerMinute: Double
    public let integralAbsoluteErrorBeatSeconds: Double
}

public struct DirectionalDeviationMetricsV1: Codable, Hashable, Sendable {
    public let durationSeconds: Double
    public let maximumMagnitudeBeatsPerMinute: Double
    public let meanMagnitudeBeatsPerMinute: Double
    public let integralMagnitudeBeatSeconds: Double
}

public struct StableSpeedHeartRateDriftV1: Codable, Hashable, Sendable {
    public let qualifyingWindowCount: Int
    public let coveredSeconds: Double
    public let slopeBeatsPerMinutePerMinute: Double
    public let coefficientOfDetermination: Double?
}

public struct EventAlignedHeartRateResponseV1: Codable, Hashable, Sendable {
    public let provenFactualResponseEventCount: Int
    public let responseBeatsPerMinute: ScalarDistribution
    public let standardError: Double?
    public let causalInterpretation: String
}

public struct CooldownAnalysisV1: Codable, Hashable, Sendable {
    public let durationSeconds: Double?
    public let heartRateCoverage: DurationCoverage
    public let startHeartRate: AnalysisMetric<Double>
    public let endHeartRate: AnalysisMetric<Double>
    public let peakHeartRate: AnalysisMetric<Double>
    public let targetHeartRate: AnalysisMetric<Double>
    public let targetHitElapsedSeconds: AnalysisMetric<Double>
    public let heartRateBelowTargetSeconds: AnalysisMetric<Double>
    public let minimumFactualSpeedSeconds: AnalysisMetric<Double>
    public let targetAndMinimumSpeedSeconds: AnalysisMetric<Double>
    public let targetAndMinimumSpeedMaximumStreakSeconds: AnalysisMetric<Double>
    public let finishReason: AnalysisMetric<String>
    public let timeoutBlocker: AnalysisMetric<String>
    public let hrr10: AnalysisMetric<Double>
    public let hrr30: AnalysisMetric<Double>
    public let hrr60: AnalysisMetric<Double>
    public let hrr120: AnalysisMetric<Double>
    public let recoverySlopeBeatsPerMinutePerMinute: AnalysisMetric<Double>
    public let recoveryFitRSquared: AnalysisMetric<Double>
}

public struct IntervalMetricFrameworkV1: Codable, Hashable, Sendable {
    public let schemaVersion: UInt16
    public let intervalEngineImplemented: Bool
    public let intervalResults: [String]

    public init() {
        schemaVersion = 1
        intervalEngineImplemented = false
        intervalResults = []
    }
}

public struct WorkoutControlMetricsV1: Codable, Hashable, Sendable {
    public let zoneDurations: [ZoneDurationV1]
    public let targetRangeDurationSeconds: AnalysisMetric<Double>
    public let targetRangeCoverageRatio: AnalysisMetric<Double>
    public let heartRateError: AnalysisMetric<HeartRateErrorMetricsV1>
    public let overshoot: AnalysisMetric<DirectionalDeviationMetricsV1>
    public let undershoot: AnalysisMetric<DirectionalDeviationMetricsV1>
    public let timeToTargetSeconds: AnalysisMetric<Double>
    public let settlingTimeSeconds: AnalysisMetric<Double>
    public let commandCount: Int
    public let speedDeltaKilometresPerHour: AnalysisMetric<ScalarDistribution>
    public let stableSpeedHeartRateDrift: AnalysisMetric<StableSpeedHeartRateDriftV1>
    public let eventAlignedHeartRateResponse: AnalysisMetric<EventAlignedHeartRateResponseV1>
    public let retryAttemptLatencySeconds: AnalysisMetric<ScalarDistribution>
    public let cooldown: CooldownAnalysisV1
    public let futureIntervals: IntervalMetricFrameworkV1
}

public struct AnalysisSchemaRangeV1: Codable, Hashable, Sendable {
    public let minimum: String
    public let maximum: String
}

public struct WorkoutAnalysisDetailV1: Codable, Hashable, Sendable {
    public static let schemaVersion: UInt16 = 1

    public let metricDefinitionVersion: String
    public let acceptedInputSchemaRange: AnalysisSchemaRangeV1
    public let analyzerPolicy: AnalyzerV1Policy
    public let quality: WorkoutDataQualityV1
    public let control: WorkoutControlMetricsV1
}

public struct WorkoutAnalysisLogicalResult: Hashable, Sendable {
    public let sessionID: SessionID
    public let analyzerVersion: AnalyzerVersion
    public let evidenceHash: ContentHash
    public let qualityGrade: AnalysisQualityGrade
    public let exclusions: [AnalysisExclusion]
    public let keyMetrics: AnalysisKeyMetrics
    public let detailSchemaVersion: UInt16
    public let versionedDetailPayload: Data
}

public extension WorkoutAnalysisResult {
    var logicalResult: WorkoutAnalysisLogicalResult {
        WorkoutAnalysisLogicalResult(
            sessionID: sessionID,
            analyzerVersion: analyzerVersion,
            evidenceHash: evidenceHash,
            qualityGrade: qualityGrade,
            exclusions: exclusions,
            keyMetrics: keyMetrics,
            detailSchemaVersion: detailSchemaVersion,
            versionedDetailPayload: versionedDetailPayload
        )
    }
}
