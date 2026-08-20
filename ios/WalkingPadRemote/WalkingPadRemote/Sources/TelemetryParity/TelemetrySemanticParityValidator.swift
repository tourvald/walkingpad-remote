import Foundation

public struct TelemetryParityTolerance: Equatable, Sendable {
    public let timestampMilliseconds: Int64
    public let speedKilometresPerHour: Double
    public let aggregateSeconds: Int

    public init(
        timestampMilliseconds: Int64 = 1_000,
        speedKilometresPerHour: Double = 0.001,
        aggregateSeconds: Int = 1
    ) {
        self.timestampMilliseconds = timestampMilliseconds
        self.speedKilometresPerHour = speedKilometresPerHour
        self.aggregateSeconds = aggregateSeconds
    }
}

public enum TelemetrySemanticParityValidator {
    public static func validate(
        legacy: TelemetryParitySessionEvidence,
        telemetryV2: TelemetryParitySessionEvidence,
        tolerance: TelemetryParityTolerance = TelemetryParityTolerance()
    ) -> TelemetrySemanticParityReport {
        var findings = Dictionary(
            uniqueKeysWithValues: TelemetryParityCategory.allCases.map { ($0, [TelemetryParityFinding]()) }
        )

        func add(
            _ category: TelemetryParityCategory,
            _ code: String,
            _ classification: TelemetryParityFindingClass,
            _ impact: TelemetryParityStatus,
            _ detail: String
        ) {
            findings[category, default: []].append(
                TelemetryParityFinding(
                    code: code,
                    classification: classification,
                    impact: impact,
                    detail: detail
                )
            )
        }

        for limitation in legacy.limitations + telemetryV2.limitations {
            add(
                limitation.category,
                limitation.code,
                .sourceLegacyLimitation,
                .inconclusive,
                limitation.detail
            )
        }

        compareLifecycle(legacy, telemetryV2, tolerance: tolerance, add: add)
        compareHeartRate(legacy, telemetryV2, tolerance: tolerance, add: add)
        comparePhases(legacy, telemetryV2, tolerance: tolerance, add: add)
        compareConfiguration(legacy, telemetryV2, tolerance: tolerance, add: add)
        compareDecisions(legacy, telemetryV2, tolerance: tolerance, add: add)
        compareTreadmillFacts(legacy, telemetryV2, tolerance: tolerance, add: add)
        compareCommands(legacy, telemetryV2, add: add)
        compareAggregates(legacy, telemetryV2, tolerance: tolerance, add: add)
        compareStopEvidence(legacy, telemetryV2, add: add)
        inspectIntegrity(legacy, telemetryV2, add: add)
        inspectCausality(telemetryV2, add: add)

        add(
            .physicalDeviceTruth,
            "device-only-deferred-to-issue-37",
            .deviceOnlyUnverified,
            .inconclusive,
            "Hosted parity and replay do not verify physical treadmill behavior."
        )

        let results = TelemetryParityCategory.allCases.map { category in
            let categoryFindings = (findings[category] ?? []).sorted {
                if $0.impact != $1.impact {
                    return statusRank($0.impact) > statusRank($1.impact)
                }
                if $0.classification != $1.classification {
                    return $0.classification.rawValue < $1.classification.rawValue
                }
                return $0.code < $1.code
            }
            return TelemetryParityCategoryResult(
                category: category,
                status: categoryFindings.map(\.impact).max(by: {
                    statusRank($0) < statusRank($1)
                }) ?? .pass,
                findings: categoryFindings
            )
        }

        let automatedResults = results.filter { $0.category != .physicalDeviceTruth }
        let overallStatus = automatedResults.map(\.status).max(by: {
            statusRank($0) < statusRank($1)
        }) ?? .pass
        let causalOutcomes = telemetryV2.commandEvidence.filter { $0.outcomeKind != .sent }
        let coverage = TelemetryParityCausalCoverage(
            factualOutcomeCount: causalOutcomes.count,
            deterministicallyAssociatedCount: causalOutcomes.filter {
                $0.association == .deterministicallyCorrelated && causalClaimIsSupported($0)
            }.count,
            honestlyUnknownCount: causalOutcomes.filter {
                $0.association == .unknown
                    && $0.commandIdentifier == nil
                    && $0.attemptIdentifier == nil
            }.count,
            unsupportedClaimCount: causalOutcomes.filter { !causalClaimIsSupported($0) }.count
        )

        return TelemetrySemanticParityReport(
            legacySessionIdentifier: legacy.sessionIdentifier,
            telemetryV2SessionIdentifier: telemetryV2.sessionIdentifier,
            overallStatus: overallStatus,
            categories: results,
            causalCoverage: coverage
        )
    }

    private typealias FindingSink = (
        TelemetryParityCategory,
        String,
        TelemetryParityFindingClass,
        TelemetryParityStatus,
        String
    ) -> Void

    private static func compareLifecycle(
        _ legacy: TelemetryParitySessionEvidence,
        _ v2: TelemetryParitySessionEvidence,
        tolerance: TelemetryParityTolerance,
        add: FindingSink
    ) {
        if let linked = v2.linkedLegacySessionIdentifier,
           linked.caseInsensitiveCompare(legacy.sessionIdentifier) != .orderedSame {
            add(
                .lifecycle,
                "cross-reference-mismatch",
                .actualSemanticMismatch,
                .fail,
                "V2 session is linked to \(linked), not legacy session \(legacy.sessionIdentifier)."
            )
        }
        compareRequiredDate(
            legacy.lifecycle.startedAt,
            v2.lifecycle.startedAt,
            field: "start",
            tolerance: tolerance,
            v2Completeness: v2.completeness,
            category: .lifecycle,
            add: add
        )
        compareRequiredDate(
            legacy.lifecycle.endedAt,
            v2.lifecycle.endedAt,
            field: "end",
            tolerance: tolerance,
            v2Completeness: v2.completeness,
            category: .lifecycle,
            add: add
        )
        compareOptional(
            legacy.lifecycle.endReason,
            v2.lifecycle.endReason,
            field: "end-reason",
            category: .lifecycle,
            v2Completeness: v2.completeness,
            add: add
        )
        compareOptionalInt64(
            legacy.lifecycle.durationMilliseconds,
            v2.lifecycle.durationMilliseconds,
            field: "duration",
            tolerance: tolerance.timestampMilliseconds,
            category: .lifecycle,
            v2Completeness: v2.completeness,
            add: add
        )
    }

    private static func compareHeartRate(
        _ legacy: TelemetryParitySessionEvidence,
        _ v2: TelemetryParitySessionEvidence,
        tolerance: TelemetryParityTolerance,
        add: FindingSink
    ) {
        guard legacy.heartRate.count == v2.heartRate.count else {
            addMissingOrExtra(
                category: .heartRateObservations,
                code: "heart-rate-count",
                legacyCount: legacy.heartRate.count,
                v2Count: v2.heartRate.count,
                v2Completeness: v2.completeness,
                add: add
            )
            return
        }
        for (index, pair) in zip(legacy.heartRate, v2.heartRate).enumerated() {
            let lhs = pair.0
            let rhs = pair.1
            if lhs.beatsPerMinute != rhs.beatsPerMinute
                || lhs.acceptedForControl != rhs.acceptedForControl
                || abs(lhs.elapsedMilliseconds - rhs.elapsedMilliseconds) > tolerance.timestampMilliseconds {
                add(
                    .heartRateObservations,
                    "heart-rate-semantic-mismatch-\(index)",
                    .actualSemanticMismatch,
                    .fail,
                    "HR observation \(index) differs in timestamp, BPM, or accepted-for-control state."
                )
            }
        }
        let v2Arrival = v2.heartRate.map(\.arrivalOrder)
        if !strictlyIncreasing(v2Arrival) {
            add(
                .heartRateObservations,
                "v2-arrival-order",
                .actualSemanticMismatch,
                .fail,
                "V2 HR arrival order is not strictly increasing."
            )
        }
    }

    private static func comparePhases(
        _ legacy: TelemetryParitySessionEvidence,
        _ v2: TelemetryParitySessionEvidence,
        tolerance: TelemetryParityTolerance,
        add: FindingSink
    ) {
        guard legacy.phases.count == v2.phases.count else {
            addMissingOrExtra(
                category: .phaseAndCooldown,
                code: "phase-count",
                legacyCount: legacy.phases.count,
                v2Count: v2.phases.count,
                v2Completeness: v2.completeness,
                add: add
            )
            return
        }
        for (index, pair) in zip(legacy.phases, v2.phases).enumerated() {
            if pair.0.phase != pair.1.phase
                || abs(pair.0.elapsedMilliseconds - pair.1.elapsedMilliseconds) > tolerance.timestampMilliseconds {
                add(
                    .phaseAndCooldown,
                    "phase-mismatch-\(index)",
                    .actualSemanticMismatch,
                    .fail,
                    "Phase boundary \(index) differs semantically."
                )
            }
        }
    }

    private static func compareConfiguration(
        _ legacy: TelemetryParitySessionEvidence,
        _ v2: TelemetryParitySessionEvidence,
        tolerance: TelemetryParityTolerance,
        add: FindingSink
    ) {
        guard let lhs = legacy.configuration else {
            add(
                .configurationAndVersions,
                "legacy-configuration-unavailable",
                .sourceLegacyLimitation,
                .inconclusive,
                "Legacy source does not expose a configuration snapshot."
            )
            return
        }
        guard let rhs = v2.configuration else {
            add(
                .configurationAndVersions,
                "v2-configuration-missing",
                .v2RecorderOrDataLoss,
                v2.completeness == .complete ? .fail : .inconclusive,
                "V2 configuration snapshot is missing."
            )
            return
        }

        compareConfigurationValue(lhs.targetHeartRate, rhs.targetHeartRate, "target-heart-rate", add)
        compareConfigurationValue(lhs.durationSeconds, rhs.durationSeconds, "duration", add)
        compareConfigurationValue(
            lhs.decisionIntervalSeconds,
            rhs.decisionIntervalSeconds,
            "decision-interval",
            add
        )
        compareConfigurationValue(lhs.adaptiveStepEnabled, rhs.adaptiveStepEnabled, "adaptive-step", add)
        compareConfigurationDouble(
            lhs.maximumStepKilometresPerHour,
            rhs.maximumStepKilometresPerHour,
            "maximum-step",
            tolerance.speedKilometresPerHour,
            add
        )
        if lhs.heartRateZoneUpperBounds != rhs.heartRateZoneUpperBounds {
            add(
                .configurationAndVersions,
                "zone-bounds",
                .actualSemanticMismatch,
                .fail,
                "Heart-rate zone bounds differ."
            )
        }
        compareConfigurationValue(
            lhs.cooldownTargetHeartRate,
            rhs.cooldownTargetHeartRate,
            "cooldown-target",
            add
        )
        compareConfigurationDouble(
            lhs.cooldownMinimumSpeedKilometresPerHour,
            rhs.cooldownMinimumSpeedKilometresPerHour,
            "cooldown-minimum-speed",
            tolerance.speedKilometresPerHour,
            add
        )
        compareConfigurationValue(
            lhs.cooldownMaximumSeconds,
            rhs.cooldownMaximumSeconds,
            "cooldown-maximum-duration",
            add
        )
        compareVersion(lhs.telemetrySchemaVersion, rhs.telemetrySchemaVersion, "telemetry-schema", add)
        compareVersion(lhs.algorithmVersion, rhs.algorithmVersion, "algorithm", add)
        compareVersion(lhs.safetyPolicyVersion, rhs.safetyPolicyVersion, "safety-policy", add)
        compareVersion(lhs.workoutProtocolVersion, rhs.workoutProtocolVersion, "workout-protocol", add)
    }

    private static func compareDecisions(
        _ legacy: TelemetryParitySessionEvidence,
        _ v2: TelemetryParitySessionEvidence,
        tolerance: TelemetryParityTolerance,
        add: FindingSink
    ) {
        let legacyHeartRateDecisions = legacy.decisions.filter {
            $0.domain == .heartRateControl
        }
        let v2HeartRateDecisions = v2.decisions.filter {
            $0.domain == .heartRateControl
        }

        let legacyActionOrder = legacyHeartRateDecisions.map(\.action)
        let v2ActionOrder = v2HeartRateDecisions.map(\.action)
        if legacyHeartRateDecisions.count == v2HeartRateDecisions.count,
           legacyActionOrder != v2ActionOrder {
            add(
                .controlDecisions,
                "heart-rate-control-decision-order",
                .actualSemanticMismatch,
                .fail,
                "Comparable HR-control decision action order differs."
            )
        }

        let actions = Set(legacyActionOrder + v2ActionOrder).sorted()
        for action in actions {
            let legacyActionDecisions = legacyHeartRateDecisions.filter { $0.action == action }
            let v2ActionDecisions = v2HeartRateDecisions.filter { $0.action == action }

            if legacyActionDecisions.count != v2ActionDecisions.count {
                addHeartRateDecisionCountDifference(
                    action: action,
                    legacyCount: legacyActionDecisions.count,
                    v2Count: v2ActionDecisions.count,
                    v2Completeness: v2.completeness,
                    add: add
                )
            }

            // Exact semantic action plus occurrence order is the identity rule.
            // Speed and timestamp are compared only after that deterministic pairing.
            for (index, pair) in zip(legacyActionDecisions, v2ActionDecisions).enumerated() {
                let speedMatches: Bool
                switch (pair.0.desiredSpeedKilometresPerHour, pair.1.desiredSpeedKilometresPerHour) {
                case (nil, nil): speedMatches = true
                case let (lhs?, rhs?):
                    speedMatches = abs(lhs - rhs) <= tolerance.speedKilometresPerHour
                default: speedMatches = false
                }
                if pair.0.source != pair.1.source
                    || !speedMatches
                    || abs(pair.0.elapsedMilliseconds - pair.1.elapsedMilliseconds) > tolerance.timestampMilliseconds {
                    add(
                        .controlDecisions,
                        "heart-rate-control-decision-mismatch-\(action)-\(index)",
                        .actualSemanticMismatch,
                        .fail,
                        "HR-control \(action) decision occurrence \(index) differs in source, speed target, or time."
                    )
                }
            }
        }
    }

    private static func addHeartRateDecisionCountDifference(
        action: String,
        legacyCount: Int,
        v2Count: Int,
        v2Completeness: TelemetryParityCompleteness,
        add: FindingSink
    ) {
        let v2IsMissingRequiredEvidence = v2Count < legacyCount
        let classification: TelemetryParityFindingClass
        let impact: TelemetryParityStatus
        if v2IsMissingRequiredEvidence, v2Completeness != .complete {
            classification = .v2RecorderOrDataLoss
            impact = .inconclusive
        } else {
            classification = .actualSemanticMismatch
            impact = .fail
        }
        add(
            .controlDecisions,
            "heart-rate-control-decision-count-\(action)",
            classification,
            impact,
            "Comparable HR-control \(action) count: legacy=\(legacyCount), V2=\(v2Count)."
        )
    }

    private static func compareTreadmillFacts(
        _ legacy: TelemetryParitySessionEvidence,
        _ v2: TelemetryParitySessionEvidence,
        tolerance: TelemetryParityTolerance,
        add: FindingSink
    ) {
        if legacy.treadmillFacts.isEmpty {
            add(
                .treadmillFacts,
                "legacy-factual-treadmill-evidence-unavailable",
                .sourceLegacyLimitation,
                .inconclusive,
                "Legacy source contains no explicit device-reported treadmill fact to compare."
            )
            return
        }
        guard legacy.treadmillFacts.count == v2.treadmillFacts.count else {
            addMissingOrExtra(
                category: .treadmillFacts,
                code: "treadmill-fact-count",
                legacyCount: legacy.treadmillFacts.count,
                v2Count: v2.treadmillFacts.count,
                v2Completeness: v2.completeness,
                add: add
            )
            return
        }
        for (index, pair) in zip(legacy.treadmillFacts, v2.treadmillFacts).enumerated() {
            let factualSpeedMatches: Bool
            switch (pair.0.factualSpeedKilometresPerHour, pair.1.factualSpeedKilometresPerHour) {
            case (nil, _): factualSpeedMatches = true
            case let (lhs?, rhs?):
                factualSpeedMatches = abs(lhs - rhs) <= tolerance.speedKilometresPerHour
            case (_, nil): factualSpeedMatches = false
            }
            let deviceStateMatches: Bool
            switch (pair.0.deviceState, pair.1.deviceState) {
            case (nil, _): deviceStateMatches = true
            case let (lhs?, rhs?): deviceStateMatches = lhs == rhs
            case (_, nil): deviceStateMatches = false
            }
            if pair.0.nativeUnit != pair.1.nativeUnit
                || abs(pair.0.nativeValue - pair.1.nativeValue) > tolerance.speedKilometresPerHour
                || !factualSpeedMatches
                || !deviceStateMatches
                || abs(pair.0.elapsedMilliseconds - pair.1.elapsedMilliseconds) > tolerance.timestampMilliseconds {
                add(
                    .treadmillFacts,
                    "treadmill-fact-mismatch-\(index)",
                    .actualSemanticMismatch,
                    .fail,
                    "Explicit treadmill fact \(index) differs; desired or modelled speed was not substituted."
                )
            }
        }
    }

    private static func compareCommands(
        _ legacy: TelemetryParitySessionEvidence,
        _ v2: TelemetryParitySessionEvidence,
        add: FindingSink
    ) {
        let legacySent = legacy.commandEvidence.filter { $0.outcomeKind == .sent }.map(\.semanticCommand)
        let v2Sent = v2.commandEvidence.filter { $0.outcomeKind == .sent }.map(\.semanticCommand)
        if legacySent != v2Sent {
            let isMissingV2Evidence = v2Sent.count < legacySent.count
            add(
                .commandLifecycle,
                "sent-command-sequence",
                isMissingV2Evidence ? .v2RecorderOrDataLoss : .actualSemanticMismatch,
                isMissingV2Evidence && v2.completeness != .complete ? .inconclusive : .fail,
                "Comparable sent-command sequence differs."
            )
        }

        for kind in [
            TelemetryParityCommandOutcomeKind.acknowledgement,
            .timeout,
            .writeResult,
            .observedResponse,
        ] {
            let sourceCannotCompareAssociation = legacy.limitations.contains {
                $0.category == .commandLifecycle
                    && $0.code == "legacy-jsonl-ack-acceptance-not-explicit"
            }
            if sourceCannotCompareAssociation
                && (kind == .acknowledgement || kind == .observedResponse) {
                continue
            }
            let legacyCount = legacy.commandEvidence.filter { $0.outcomeKind == kind }.count
            let v2Count = v2.commandEvidence.filter { $0.outcomeKind == kind }.count
            if legacyCount != v2Count {
                addMissingOrExtra(
                    category: .commandLifecycle,
                    code: "\(kind.rawValue)-count",
                    legacyCount: legacyCount,
                    v2Count: v2Count,
                    v2Completeness: v2.completeness,
                    add: add
                )
            }
        }
    }

    private static func compareAggregates(
        _ legacy: TelemetryParitySessionEvidence,
        _ v2: TelemetryParitySessionEvidence,
        tolerance: TelemetryParityTolerance,
        add: FindingSink
    ) {
        guard let lhs = derivedAggregates(legacy) ?? legacy.aggregates,
              let rhs = derivedAggregates(v2) ?? v2.aggregates else {
            add(
                .timestampDerivedAggregates,
                "aggregate-inputs-unavailable",
                .sourceLegacyLimitation,
                .inconclusive,
                "Timestamped HR, phase, or zone inputs are insufficient for deterministic aggregate comparison."
            )
            return
        }
        if lhs.zoneSeconds.count != rhs.zoneSeconds.count
            || zip(lhs.zoneSeconds, rhs.zoneSeconds).contains(where: {
                abs($0.0 - $0.1) > tolerance.aggregateSeconds
            }) {
            add(
                .timestampDerivedAggregates,
                "zone-duration-mismatch",
                .actualSemanticMismatch,
                .fail,
                "Timestamp-derived zone durations differ beyond \(tolerance.aggregateSeconds)s tolerance."
            )
        }
        switch (lhs.cooldownCoveredSeconds, rhs.cooldownCoveredSeconds) {
        case (nil, nil): break
        case let (legacySeconds?, v2Seconds?) where
            abs(legacySeconds - v2Seconds) <= tolerance.aggregateSeconds:
            break
        default:
            add(
                .timestampDerivedAggregates,
                "cooldown-duration-mismatch",
                .actualSemanticMismatch,
                .fail,
                "Timestamp-derived cooldown coverage differs beyond tolerance."
            )
        }
    }

    private static func compareStopEvidence(
        _ legacy: TelemetryParitySessionEvidence,
        _ v2: TelemetryParitySessionEvidence,
        add: FindingSink
    ) {
        guard !legacy.stopEvidence.isEmpty else {
            add(
                .stopAndSafety,
                "legacy-stop-truth-unavailable",
                .sourceLegacyLimitation,
                .inconclusive,
                "Legacy source does not establish factual stop truth."
            )
            return
        }
        guard legacy.stopEvidence.count == v2.stopEvidence.count else {
            addMissingOrExtra(
                category: .stopAndSafety,
                code: "stop-evidence-count",
                legacyCount: legacy.stopEvidence.count,
                v2Count: v2.stopEvidence.count,
                v2Completeness: v2.completeness,
                add: add
            )
            return
        }
        for (index, pair) in zip(legacy.stopEvidence, v2.stopEvidence).enumerated()
        where pair.0.conclusion != pair.1.conclusion {
            add(
                .stopAndSafety,
                "stop-conclusion-mismatch-\(index)",
                .actualSemanticMismatch,
                .fail,
                "Stop conclusion \(index) differs."
            )
        }
    }

    private static func inspectIntegrity(
        _ legacy: TelemetryParitySessionEvidence,
        _ v2: TelemetryParitySessionEvidence,
        add: FindingSink
    ) {
        if legacy.completeness != .complete {
            add(
                .recordIntegrity,
                "legacy-session-incomplete",
                .sourceLegacyLimitation,
                .inconclusive,
                "Legacy source is incomplete or its completion is unknown."
            )
        }
        if legacy.integrity.duplicateRecordIdentifierCount > 0
            || legacy.integrity.outOfOrderRecordCount > 0
            || legacy.integrity.duplicateCanonicalSecondCount > 0
            || legacy.integrity.unexplainedFrameGapCount > 0 {
            add(
                .recordIntegrity,
                "legacy-record-order-or-integrity-limitation",
                .sourceLegacyLimitation,
                .inconclusive,
                "Legacy source contains duplicate or out-of-order evidence that limits comparison."
            )
        }
        if v2.completeness != .complete {
            add(
                .recordIntegrity,
                "v2-session-incomplete",
                .v2RecorderOrDataLoss,
                .inconclusive,
                "V2 session is not represented complete."
            )
        }
        if v2.integrity.lostCriticalRecordCount > 0 || v2.integrity.lostNativeRecordCount > 0 {
            add(
                .recordIntegrity,
                "v2-native-or-critical-loss",
                .v2RecorderOrDataLoss,
                .fail,
                "V2 reports lost critical=\(v2.integrity.lostCriticalRecordCount), native=\(v2.integrity.lostNativeRecordCount)."
            )
        }
        if v2.integrity.duplicateRecordIdentifierCount > 0
            || v2.integrity.outOfOrderRecordCount > 0
            || v2.integrity.duplicateCanonicalSecondCount > 0
            || v2.integrity.unexplainedFrameGapCount > 0 {
            add(
                .recordIntegrity,
                "v2-record-order-or-frame-integrity",
                .actualSemanticMismatch,
                .fail,
                "V2 contains duplicate IDs, out-of-order records, duplicate frame seconds, or unexplained frame gaps."
            )
        }
    }

    private static func inspectCausality(
        _ v2: TelemetryParitySessionEvidence,
        add: FindingSink
    ) {
        let outcomes = v2.commandEvidence.filter { $0.outcomeKind != .sent }
        for (index, outcome) in outcomes.enumerated() {
            if !causalClaimIsSupported(outcome) {
                add(
                    .causalAssociation,
                    "unsupported-causal-edge-\(index)",
                    .unsupportedCausalEdge,
                    .fail,
                    "\(outcome.outcomeKind.rawValue) claims command/attempt ownership without independently sufficient evidence."
                )
            } else if outcome.association == .unknown {
                add(
                    .causalAssociation,
                    "honest-unknown-association-\(index)",
                    .protocolRuntimeCausalAmbiguity,
                    .pass,
                    "\(outcome.outcomeKind.rawValue) remains factual with nil command and attempt IDs."
                )
            }
        }
    }

    private static func causalClaimIsSupported(
        _ outcome: TelemetryParityCommandEvidence
    ) -> Bool {
        switch outcome.association {
        case .unknown:
            return outcome.commandIdentifier == nil
                && outcome.attemptIdentifier == nil
        case .deterministicallyCorrelated:
            // The accepted runtime persists no independently verifiable proof
            // token. A typed claim or matching IDs alone are not proof.
            return false
        }
    }

    private static func derivedAggregates(
        _ evidence: TelemetryParitySessionEvidence,
        freshnessMilliseconds: Int64 = 5_000
    ) -> TelemetryParityAggregateEvidence? {
        guard let configuration = evidence.configuration,
              !configuration.heartRateZoneUpperBounds.isEmpty,
              !evidence.heartRate.isEmpty else { return nil }
        let ordered = evidence.heartRate.sorted {
            if $0.elapsedMilliseconds != $1.elapsedMilliseconds {
                return $0.elapsedMilliseconds < $1.elapsedMilliseconds
            }
            return $0.arrivalOrder < $1.arrivalOrder
        }
        var zoneMilliseconds = Array(
            repeating: Int64(0),
            count: configuration.heartRateZoneUpperBounds.count + 1
        )
        for index in ordered.indices {
            let current = ordered[index]
            let nextElapsed = index + 1 < ordered.count
                ? ordered[index + 1].elapsedMilliseconds
                : (evidence.lifecycle.durationMilliseconds ?? current.elapsedMilliseconds)
            let interval = max(
                0,
                min(nextElapsed - current.elapsedMilliseconds, freshnessMilliseconds)
            )
            let zone = configuration.heartRateZoneUpperBounds.firstIndex {
                current.beatsPerMinute <= $0
            } ?? configuration.heartRateZoneUpperBounds.count
            zoneMilliseconds[zone] += interval
        }

        let cooldownStart = evidence.phases.first { $0.phase == "cooldown" }?.elapsedMilliseconds
        let finished = evidence.phases.first { $0.phase == "finished" }?.elapsedMilliseconds
            ?? evidence.lifecycle.durationMilliseconds
        let cooldownSeconds: Int?
        if let cooldownStart, let finished, finished >= cooldownStart {
            cooldownSeconds = Int(((Double(finished - cooldownStart) / 1_000.0).rounded()))
        } else {
            cooldownSeconds = nil
        }
        return TelemetryParityAggregateEvidence(
            zoneSeconds: zoneMilliseconds.map {
                Int((Double($0) / 1_000.0).rounded())
            },
            cooldownCoveredSeconds: cooldownSeconds
        )
    }

    private static func compareRequiredDate(
        _ legacy: Date?,
        _ v2: Date?,
        field: String,
        tolerance: TelemetryParityTolerance,
        v2Completeness: TelemetryParityCompleteness,
        category: TelemetryParityCategory,
        add: FindingSink
    ) {
        switch (legacy, v2) {
        case let (lhs?, rhs?):
            if abs(lhs.timeIntervalSince(rhs) * 1_000) > Double(tolerance.timestampMilliseconds) {
                add(
                    category,
                    "\(field)-timestamp-mismatch",
                    .actualSemanticMismatch,
                    .fail,
                    "Comparable \(field) timestamps differ beyond tolerance."
                )
            }
        case (nil, _):
            add(
                category,
                "legacy-\(field)-missing",
                .sourceLegacyLimitation,
                .inconclusive,
                "Legacy \(field) timestamp is unavailable."
            )
        case (_, nil):
            add(
                category,
                "v2-\(field)-missing",
                .v2RecorderOrDataLoss,
                v2Completeness == .complete ? .fail : .inconclusive,
                "V2 \(field) timestamp is unavailable."
            )
        }
    }

    private static func compareOptional<T: Equatable>(
        _ legacy: T?,
        _ v2: T?,
        field: String,
        category: TelemetryParityCategory,
        v2Completeness: TelemetryParityCompleteness,
        add: FindingSink
    ) {
        switch (legacy, v2) {
        case let (lhs?, rhs?) where lhs != rhs:
            add(category, "\(field)-mismatch", .actualSemanticMismatch, .fail, "\(field) differs.")
        case (nil, _):
            add(category, "legacy-\(field)-missing", .sourceLegacyLimitation, .inconclusive, "Legacy \(field) is unavailable.")
        case (_, nil):
            add(category, "v2-\(field)-missing", .v2RecorderOrDataLoss, v2Completeness == .complete ? .fail : .inconclusive, "V2 \(field) is unavailable.")
        default:
            break
        }
    }

    private static func compareOptionalInt64(
        _ legacy: Int64?,
        _ v2: Int64?,
        field: String,
        tolerance: Int64,
        category: TelemetryParityCategory,
        v2Completeness: TelemetryParityCompleteness,
        add: FindingSink
    ) {
        switch (legacy, v2) {
        case let (lhs?, rhs?) where abs(lhs - rhs) > tolerance:
            add(category, "\(field)-mismatch", .actualSemanticMismatch, .fail, "\(field) differs beyond tolerance.")
        case (nil, _):
            add(category, "legacy-\(field)-missing", .sourceLegacyLimitation, .inconclusive, "Legacy \(field) is unavailable.")
        case (_, nil):
            add(category, "v2-\(field)-missing", .v2RecorderOrDataLoss, v2Completeness == .complete ? .fail : .inconclusive, "V2 \(field) is unavailable.")
        default:
            break
        }
    }

    private static func addMissingOrExtra(
        category: TelemetryParityCategory,
        code: String,
        legacyCount: Int,
        v2Count: Int,
        v2Completeness: TelemetryParityCompleteness,
        add: FindingSink
    ) {
        let v2IsMissingEvidence = v2Count < legacyCount
        let classification: TelemetryParityFindingClass = v2IsMissingEvidence
            ? .v2RecorderOrDataLoss
            : .actualSemanticMismatch
        let impact: TelemetryParityStatus = v2IsMissingEvidence && v2Completeness != .complete
            ? .inconclusive
            : .fail
        add(
            category,
            code,
            classification,
            impact,
            "Legacy count=\(legacyCount), V2 count=\(v2Count)."
        )
    }

    private static func compareConfigurationValue<T: Equatable>(
        _ lhs: T?,
        _ rhs: T?,
        _ field: String,
        _ add: FindingSink
    ) {
        switch (lhs, rhs) {
        case let (lhs?, rhs?) where lhs != rhs:
            add(.configurationAndVersions, field, .actualSemanticMismatch, .fail, "Configuration field \(field) differs.")
        case (nil, _):
            add(.configurationAndVersions, "legacy-\(field)-missing", .sourceLegacyLimitation, .inconclusive, "Legacy configuration field \(field) is unavailable.")
        case (_, nil):
            add(.configurationAndVersions, "v2-\(field)-missing", .v2RecorderOrDataLoss, .fail, "V2 configuration field \(field) is unavailable.")
        default:
            break
        }
    }

    private static func compareConfigurationDouble(
        _ lhs: Double?,
        _ rhs: Double?,
        _ field: String,
        _ tolerance: Double,
        _ add: FindingSink
    ) {
        switch (lhs, rhs) {
        case let (lhs?, rhs?) where abs(lhs - rhs) > tolerance:
            add(.configurationAndVersions, field, .actualSemanticMismatch, .fail, "Configuration field \(field) differs.")
        case (nil, _):
            add(.configurationAndVersions, "legacy-\(field)-missing", .sourceLegacyLimitation, .inconclusive, "Legacy configuration field \(field) is unavailable.")
        case (_, nil):
            add(.configurationAndVersions, "v2-\(field)-missing", .v2RecorderOrDataLoss, .fail, "V2 configuration field \(field) is unavailable.")
        default:
            break
        }
    }

    private static func compareVersion(
        _ lhs: String?,
        _ rhs: String?,
        _ field: String,
        _ add: FindingSink
    ) {
        compareConfigurationValue(lhs, rhs, field, add)
    }

    private static func strictlyIncreasing<T: Comparable>(_ values: [T]) -> Bool {
        zip(values, values.dropFirst()).allSatisfy(<)
    }

    private static func statusRank(_ status: TelemetryParityStatus) -> Int {
        switch status {
        case .pass: 0
        case .inconclusive: 1
        case .fail: 2
        }
    }
}
