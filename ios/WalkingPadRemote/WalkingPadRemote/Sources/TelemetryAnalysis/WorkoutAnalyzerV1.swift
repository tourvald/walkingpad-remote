import CryptoKit
import Foundation
import TelemetryDomain

public enum WorkoutAnalyzerError: Error, Equatable, Sendable {
    case evidenceSessionMismatch
    case unsupportedTelemetrySchema(String)
    case invalidSessionTime
    case encodingFailed
}

public enum WorkoutAnalyzerV1 {
    public static let analyzerVersion = AnalyzerVersion(rawValue: "workout-analyzer-v1")
    public static let metricDefinitionVersion = "timestamp-hold-metrics-v1"

    static func secondsDetail(_ seconds: Double) -> String {
        String(
            format: "%.3f seconds",
            locale: Locale(identifier: "en_US_POSIX"),
            arguments: [seconds]
        )
    }

    public static func evidenceHash(
        for input: WorkoutAnalysisInput,
        policy: AnalyzerV1Policy = .default
    ) throws -> ContentHash {
        try validateSessionOwnership(input)
        let projection = EvidenceHashProjection(
            session: input.session,
            heartRate: input.heartRate.sorted(by: heartRateEvidenceOrder),
            treadmill: input.treadmill.sorted(by: treadmillEvidenceOrder),
            events: input.events.sorted(by: eventEvidenceOrder),
            frames: input.frames.sorted(by: frameEvidenceOrder),
            analyzerVersion: analyzerVersion.rawValue,
            metricDefinitionVersion: metricDefinitionVersion,
            policy: policy
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(projection)
        } catch {
            throw WorkoutAnalyzerError.encodingFailed
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ContentHash(algorithm: .sha256, lowercaseHexDigest: digest)
    }

    public static func analyze(
        _ input: WorkoutAnalysisInput,
        generatedAt: Date,
        policy: AnalyzerV1Policy = .default
    ) throws -> WorkoutAnalysisResult {
        try validateSessionOwnership(input)
        let schema = input.session.versions.telemetrySchema.rawValue
        guard schema == AnalyzerV1Policy.acceptedInputSchemaMinimum else {
            throw WorkoutAnalyzerError.unsupportedTelemetrySchema(schema)
        }
        let sessionEnd = try resolvedSessionEnd(input)
        let hash = try evidenceHash(for: input, policy: policy)
        let configuration = AnalysisConfiguration.decode(input.session.configuration.canonicalPayload)
        let phaseTimeline = PhaseTimeline(events: input.events, sessionEnd: sessionEnd)
        let targetTimeline = TargetTimeline(
            events: input.events,
            configuration: configuration,
            sessionEnd: sessionEnd
        )
        let heartRate = HeartRateTimeline(
            observations: input.heartRate,
            sessionEnd: sessionEnd,
            phaseTimeline: phaseTimeline,
            targetTimeline: targetTimeline,
            sourceBoundaries: sourceTransitionBoundaries(input.events),
            freshnessSeconds: policy.heartRateFreshnessSeconds
        )
        let treadmill = TreadmillTimeline(
            observations: input.treadmill,
            sessionEnd: sessionEnd,
            phaseTimeline: phaseTimeline,
            connectionBoundaries: connectionTransitionBoundaries(input.events),
            freshnessSeconds: policy.treadmillFreshnessSeconds
        )
        let causal = CausalAnalysis(events: input.events)
        let quality = makeQuality(
            input: input,
            sessionEnd: sessionEnd,
            phases: phaseTimeline,
            heartRate: heartRate,
            treadmill: treadmill,
            causal: causal,
            configurationAvailable: configuration != nil
        )
        let control = makeControlMetrics(
            configuration: configuration,
            phases: phaseTimeline,
            targets: targetTimeline,
            heartRate: heartRate,
            treadmill: treadmill,
            causal: causal,
            events: input.events,
            policy: policy
        )
        let detail = WorkoutAnalysisDetailV1(
            metricDefinitionVersion: metricDefinitionVersion,
            acceptedInputSchemaRange: AnalysisSchemaRangeV1(
                minimum: AnalyzerV1Policy.acceptedInputSchemaMinimum,
                maximum: AnalyzerV1Policy.acceptedInputSchemaMaximum
            ),
            analyzerPolicy: policy,
            quality: quality,
            control: control
        )
        let detailPayload: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            detailPayload = try encoder.encode(detail)
        } catch {
            throw WorkoutAnalyzerError.encodingFailed
        }
        let exclusions = quality.issues.map {
            AnalysisExclusion(
                code: "\($0.category.rawValue).\($0.code)",
                detail: $0.detail
            )
        }.sorted { lhs, rhs in
            if lhs.code != rhs.code { return lhs.code < rhs.code }
            return (lhs.detail ?? "") < (rhs.detail ?? "")
        }
        let weightedHeartRate = heartRate.weightedAverage(in: nil)
        let weightedSpeed = treadmill.weightedAverage(in: nil)
        let identity = "\(input.session.sessionID.description)|\(analyzerVersion.rawValue)|\(hash.lowercaseHexDigest)"
        return WorkoutAnalysisResult(
            analysisID: AnalysisID(rawValue: deterministicUUID("analysis|\(identity)")),
            recordID: RecordID(rawValue: deterministicUUID("record|\(identity)")),
            sessionID: input.session.sessionID,
            analyzerVersion: analyzerVersion,
            evidenceHash: hash,
            generatedAt: generatedAt,
            qualityGrade: quality.sessionGrade,
            exclusions: exclusions,
            keyMetrics: AnalysisKeyMetrics(
                coveredDuration: ElapsedDuration(
                    microseconds: microseconds(heartRate.coveredSeconds(in: nil))
                ),
                averageHeartRate: weightedHeartRate,
                maximumHeartRate: heartRate.maximumHeartRate(in: nil),
                averageFactualSpeedKilometresPerHour: weightedSpeed
            ),
            detailSchemaVersion: WorkoutAnalysisDetailV1.schemaVersion,
            versionedDetailPayload: detailPayload
        )
    }
}

private extension WorkoutAnalyzerV1 {
    struct EvidenceHashProjection: Codable {
        let session: WorkoutSessionRecord
        let heartRate: [HeartRateObservation]
        let treadmill: [TreadmillObservation]
        let events: [WorkoutEvent]
        let frames: [CanonicalFrame]
        let analyzerVersion: String
        let metricDefinitionVersion: String
        let policy: AnalyzerV1Policy
    }

    struct AnalysisConfiguration: Decodable {
        let targetHeartRate: Double
        let heartRateZones: [Double]
        let cooldownTargetHeartRate: Double
        let cooldownMinimumSpeedKilometresPerHour: Double

        private enum CodingKeys: String, CodingKey {
            case targetHeartRate
            case heartRateZones
            case cooldownTargetHeartRate
            case cooldownMinimumSpeedKilometresPerHour
        }

        static func decode(_ data: Data) -> Self? {
            guard let value = try? JSONDecoder().decode(Self.self, from: data),
                  value.targetHeartRate.isFinite,
                  value.targetHeartRate > 0,
                  value.cooldownTargetHeartRate.isFinite,
                  value.cooldownTargetHeartRate > 0,
                  value.cooldownMinimumSpeedKilometresPerHour.isFinite,
                  value.cooldownMinimumSpeedKilometresPerHour >= 0,
                  value.heartRateZones.count >= 4 else {
                return nil
            }
            let zones = Array(value.heartRateZones.prefix(4))
            guard zones.allSatisfy({ $0.isFinite && $0 > 0 }),
                  zip(zones, zones.dropFirst()).allSatisfy({ $0 < $1 }) else {
                return nil
            }
            return value
        }
    }

    struct PhaseInterval: Hashable {
        let phase: WorkoutPhase
        let start: Double
        let end: Double
    }

    struct PhaseTimeline {
        let intervals: [PhaseInterval]

        init(events: [WorkoutEvent], sessionEnd: Double) {
            var changes: [(Double, WorkoutPhase, String)] = []
            for event in events {
                guard case let .workoutPhase(transition) = event.payload.payload else { continue }
                changes.append((
                    seconds(event.timestamp.occurredElapsed),
                    transition.current,
                    event.recordID.description
                ))
            }
            changes.sort {
                if $0.0 != $1.0 { return $0.0 < $1.0 }
                return $0.2 < $1.2
            }
            if changes.first?.0 ?? .infinity > 0 {
                changes.insert((0, .unknown, ""), at: 0)
            }
            var built: [PhaseInterval] = []
            for index in changes.indices {
                let start = min(sessionEnd, max(0, changes[index].0))
                let end = index + 1 < changes.count
                    ? min(sessionEnd, max(start, changes[index + 1].0))
                    : sessionEnd
                if end > start {
                    built.append(PhaseInterval(phase: changes[index].1, start: start, end: end))
                }
            }
            if built.isEmpty, sessionEnd > 0 {
                built = [PhaseInterval(phase: .unknown, start: 0, end: sessionEnd)]
            }
            intervals = built
        }

        func phase(at time: Double) -> WorkoutPhase {
            intervals.first { $0.start <= time && time < $0.end }?.phase ?? .unknown
        }

        func boundaries(in range: Range<Double>) -> [Double] {
            intervals.flatMap { [$0.start, $0.end] }.filter {
                range.lowerBound < $0 && $0 < range.upperBound
            }
        }

        func range(for phase: WorkoutPhase) -> Range<Double>? {
            let matching = intervals.filter { $0.phase == phase }
            guard let first = matching.first, let last = matching.last else { return nil }
            return first.start..<last.end
        }
    }

    struct TargetChange: Hashable {
        let time: Double
        let beatsPerMinute: Double
        let sourceRank: Int
        let recordKey: String
    }

    struct TargetTimeline {
        let changes: [TargetChange]
        let sessionEnd: Double

        init(
            events: [WorkoutEvent],
            configuration: AnalysisConfiguration?,
            sessionEnd: Double
        ) {
            var values: [TargetChange] = []
            if let configuration {
                values.append(TargetChange(
                    time: 0,
                    beatsPerMinute: configuration.targetHeartRate,
                    sourceRank: 0,
                    recordKey: "configuration"
                ))
            }
            for event in events {
                switch event.payload.payload {
                case let .controlDecision(decision):
                    guard case let .heartRate(beatsPerMinute) = decision.target else { continue }
                    values.append(TargetChange(
                        time: seconds(event.timestamp.occurredElapsed),
                        beatsPerMinute: Double(beatsPerMinute),
                        sourceRank: 1,
                        recordKey: event.recordID.description
                    ))
                case let .cooldown(cooldown):
                    guard let target = cooldown.targetHeartRate else { continue }
                    values.append(TargetChange(
                        time: seconds(event.timestamp.occurredElapsed),
                        beatsPerMinute: Double(target),
                        sourceRank: 2,
                        recordKey: event.recordID.description
                    ))
                default:
                    continue
                }
            }
            values.sort {
                if $0.time != $1.time { return $0.time < $1.time }
                if $0.sourceRank != $1.sourceRank { return $0.sourceRank < $1.sourceRank }
                return $0.recordKey < $1.recordKey
            }
            changes = values
            self.sessionEnd = sessionEnd
        }

        func target(at time: Double) -> Double? {
            changes.last { $0.time <= time }?.beatsPerMinute
        }

        func boundaries(in range: Range<Double>) -> [Double] {
            changes.map(\.time).filter { range.lowerBound < $0 && $0 < range.upperBound }
        }
    }

    struct HeartRateSegment: Hashable {
        let start: Double
        let end: Double
        let beatsPerMinute: Double
        let sourceID: SourceID
        let phase: WorkoutPhase
        let target: Double?
        let usedReceiveTimeFallback: Bool

        var duration: Double { max(0, end - start) }
    }

    struct HeartRateTimeline {
        let segments: [HeartRateSegment]
        let effectiveTimesInArrivalOrder: [Double]
        let observationsInArrivalOrder: [HeartRateObservation]
        let sessionEnd: Double

        init(
            observations: [HeartRateObservation],
            sessionEnd: Double,
            phaseTimeline: PhaseTimeline,
            targetTimeline: TargetTimeline,
            sourceBoundaries: [Double],
            freshnessSeconds: Double
        ) {
            self.sessionEnd = sessionEnd
            observationsInArrivalOrder = observations.sorted {
                if $0.arrivalOrder != $1.arrivalOrder { return $0.arrivalOrder < $1.arrivalOrder }
                return $0.recordID.description < $1.recordID.description
            }
            effectiveTimesInArrivalOrder = observationsInArrivalOrder.map {
                seconds($0.timestamp.effectiveElapsed)
            }
            let ordered = observations.sorted(by: heartRateEvidenceOrder)
            var built: [HeartRateSegment] = []
            for index in ordered.indices {
                let observation = ordered[index]
                let start = max(0, min(sessionEnd, seconds(observation.timestamp.effectiveElapsed)))
                let nextTime = index + 1 < ordered.count
                    ? max(start, seconds(ordered[index + 1].timestamp.effectiveElapsed))
                    : sessionEnd
                let sourceEnd = sourceBoundaries.first {
                    start < $0 && $0 < nextTime
                } ?? sessionEnd
                let end = min(sessionEnd, nextTime, sourceEnd, start + freshnessSeconds)
                guard end > start, isUsableHeartRate(observation) else { continue }
                let original = start..<end
                let boundaries = Set(
                    phaseTimeline.boundaries(in: original)
                        + targetTimeline.boundaries(in: original)
                ).sorted()
                let points = [start] + boundaries + [end]
                for pair in zip(points, points.dropFirst()) where pair.1 > pair.0 {
                    built.append(HeartRateSegment(
                        start: pair.0,
                        end: pair.1,
                        beatsPerMinute: Double(observation.beatsPerMinute),
                        sourceID: observation.source.id,
                        phase: phaseTimeline.phase(at: pair.0),
                        target: targetTimeline.target(at: pair.0),
                        usedReceiveTimeFallback: observation.timestamp.measuredElapsed == nil
                    ))
                }
            }
            segments = built.sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.end != $1.end { return $0.end < $1.end }
                return $0.sourceID.description < $1.sourceID.description
            }
        }

        func coveredSeconds(in range: Range<Double>?) -> Double {
            clippedSegments(in: range).reduce(0) { $0 + $1.duration }
        }

        func weightedAverage(in range: Range<Double>?) -> Double? {
            let clipped = clippedSegments(in: range)
            let duration = clipped.reduce(0) { $0 + $1.duration }
            guard duration > 0 else { return nil }
            return clipped.reduce(0) { $0 + $1.beatsPerMinute * $1.duration } / duration
        }

        func maximumHeartRate(in range: Range<Double>?) -> UInt16? {
            clippedSegments(in: range).map(\.beatsPerMinute).max().flatMap {
                UInt16(exactly: Int($0.rounded()))
            }
        }

        func value(at time: Double) -> HeartRateSegment? {
            segments.last { $0.start <= time && time < $0.end }
        }

        func clippedSegments(in range: Range<Double>?) -> [HeartRateSegment] {
            guard let range else { return segments }
            return segments.compactMap { segment in
                let start = max(segment.start, range.lowerBound)
                let end = min(segment.end, range.upperBound)
                guard end > start else { return nil }
                return HeartRateSegment(
                    start: start,
                    end: end,
                    beatsPerMinute: segment.beatsPerMinute,
                    sourceID: segment.sourceID,
                    phase: segment.phase,
                    target: segment.target,
                    usedReceiveTimeFallback: segment.usedReceiveTimeFallback
                )
            }
        }

        var mergedCoverageRanges: [Range<Double>] {
            mergeRanges(segments.map { $0.start..<$0.end })
        }
    }

    struct SpeedSegment: Hashable {
        let start: Double
        let end: Double
        let speed: Double
        let phase: WorkoutPhase
        var duration: Double { max(0, end - start) }
    }

    struct TreadmillTimeline {
        let segments: [SpeedSegment]
        let sessionEnd: Double

        init(
            observations: [TreadmillObservation],
            sessionEnd: Double,
            phaseTimeline: PhaseTimeline,
            connectionBoundaries: [Double],
            freshnessSeconds: Double
        ) {
            self.sessionEnd = sessionEnd
            let ordered = observations.sorted(by: treadmillEvidenceOrder)
            var built: [SpeedSegment] = []
            for index in ordered.indices {
                let observation = ordered[index]
                let start = max(0, min(sessionEnd, seconds(observation.timestamp.effectiveElapsed)))
                let nextTime = index + 1 < ordered.count
                    ? max(start, seconds(ordered[index + 1].timestamp.effectiveElapsed))
                    : sessionEnd
                let connectionEnd = connectionBoundaries.first {
                    start < $0 && $0 < nextTime
                } ?? sessionEnd
                let end = min(sessionEnd, nextTime, connectionEnd, start + freshnessSeconds)
                guard end > start,
                      isUsableTreadmill(observation),
                      let factual = observation.factualSpeed else { continue }
                let original = start..<end
                let boundaries = phaseTimeline.boundaries(in: original)
                let points = [start] + boundaries + [end]
                for pair in zip(points, points.dropFirst()) where pair.1 > pair.0 {
                    built.append(SpeedSegment(
                        start: pair.0,
                        end: pair.1,
                        speed: factual.value,
                        phase: phaseTimeline.phase(at: pair.0)
                    ))
                }
            }
            segments = built.sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.end != $1.end { return $0.end < $1.end }
                return $0.speed < $1.speed
            }
        }

        func coveredSeconds(in range: Range<Double>?) -> Double {
            clippedSegments(in: range).reduce(0) { $0 + $1.duration }
        }

        func weightedAverage(in range: Range<Double>?) -> Double? {
            let clipped = clippedSegments(in: range)
            let duration = clipped.reduce(0) { $0 + $1.duration }
            guard duration > 0 else { return nil }
            return clipped.reduce(0) { $0 + $1.speed * $1.duration } / duration
        }

        func clippedSegments(in range: Range<Double>?) -> [SpeedSegment] {
            guard let range else { return segments }
            return segments.compactMap { segment in
                let start = max(segment.start, range.lowerBound)
                let end = min(segment.end, range.upperBound)
                guard end > start else { return nil }
                return SpeedSegment(
                    start: start,
                    end: end,
                    speed: segment.speed,
                    phase: segment.phase
                )
            }
        }
    }

    struct SendAttempt: Hashable {
        let commandID: CommandID
        let decisionID: DecisionID?
        let attemptID: CommandAttemptID
        let attemptNumber: UInt16
        let time: Double
        let protocolKind: TreadmillProtocolKind
        let connectionEpoch: TreadmillConnectionEpoch
    }

    struct ProvenEdge: Hashable {
        let commandID: CommandID
        let attemptID: CommandAttemptID
        let time: Double
        let protocolKind: TreadmillProtocolKind
        let connectionEpoch: TreadmillConnectionEpoch
    }

    struct ProvenEdgeIdentity: Hashable {
        let commandID: CommandID
        let attemptID: CommandAttemptID
    }

    struct ScopedCommandIdentity: Hashable {
        let commandID: CommandID
        let protocolKind: TreadmillProtocolKind
        let connectionEpoch: TreadmillConnectionEpoch
    }

    struct DesiredDecision: Hashable {
        let decisionID: DecisionID
        let time: Double
        let speed: Double
        let connectionEpoch: TreadmillConnectionEpoch
    }

    struct ScopedDecisionIdentity: Hashable {
        let decisionID: DecisionID
        let protocolKind: TreadmillProtocolKind
        let connectionEpoch: TreadmillConnectionEpoch
    }

    struct DecisionSeriesScope: Hashable {
        let protocolKind: TreadmillProtocolKind
        let connectionEpoch: TreadmillConnectionEpoch
    }

    struct ScopedDesiredDecision: Hashable {
        let identity: ScopedDecisionIdentity
        let time: Double
        let speed: Double
    }

    struct CausalAnalysis {
        let commandIDs: Set<ScopedCommandIdentity>
        let sendsByAttempt: [CommandAttemptID: SendAttempt]
        let provenAcknowledgements: [ProvenEdge]
        let provenFactualResponses: [ProvenEdge]
        let unknownAcknowledgementCount: Int
        let unknownFactualResponseCount: Int
        let invalidCausalEdgeCount: Int
        let desiredDecisions: [ScopedDesiredDecision]
        let commandDecisionIDs: [ScopedCommandIdentity: DecisionID]

        init(events: [WorkoutEvent]) {
            var commands: Set<ScopedCommandIdentity> = []
            var sends: [CommandAttemptID: SendAttempt] = [:]
            var acknowledgements: [ProvenEdge] = []
            var responses: [ProvenEdge] = []
            var invalidAttemptIDs: Set<CommandAttemptID> = []
            var duplicateSendRecordCount = 0
            var unsupportedGenericCausalRecordCount = 0
            var unknownAcknowledgements = 0
            var unknownResponses = 0
            var decisionEpochs: [DecisionID: TreadmillConnectionEpoch] = [:]
            var decisions: [DecisionID: DesiredDecision] = [:]
            var invalidDecisionIDs: Set<DecisionID> = []
            var duplicateDecisionRecordCount = 0
            var commandToDecision: [ScopedCommandIdentity: DecisionID] = [:]
            var invalidCommandDecisionScopes: Set<ScopedCommandIdentity> = []
            var duplicateCommandLinkRecordCount = 0

            func recordSend(_ send: SendAttempt) {
                if sends[send.attemptID] != nil {
                    invalidAttemptIDs.insert(send.attemptID)
                    duplicateSendRecordCount += 1
                } else {
                    sends[send.attemptID] = send
                }
            }

            for event in events.sorted(by: eventEvidenceOrder) {
                let time = seconds(event.timestamp.occurredElapsed)
                switch event.payload.payload {
                case .commandLifecycle:
                    unsupportedGenericCausalRecordCount += 1
                case let .treadmillEvidence(evidence):
                    switch evidence {
                    case let .decision(decision):
                        if decisionEpochs[decision.decisionID] != nil {
                            invalidDecisionIDs.insert(decision.decisionID)
                            duplicateDecisionRecordCount += 1
                        } else {
                            decisionEpochs[decision.decisionID] = decision.connectionEpoch
                        }
                        let speed: Double?
                        switch decision.intent {
                        case let .startAtDesiredSpeed(value), let .setDesiredSpeed(value):
                            speed = value.value
                        case .stop, .hold, .requestControl, .queryControllerUnits, .other:
                            speed = nil
                        }
                        if let speed, decisions[decision.decisionID] == nil {
                            decisions[decision.decisionID] = DesiredDecision(
                                decisionID: decision.decisionID,
                                time: time,
                                speed: speed,
                                connectionEpoch: decision.connectionEpoch
                            )
                        }
                    case let .commandEnqueued(command):
                        let identity = ScopedCommandIdentity(
                            commandID: command.commandID,
                            protocolKind: command.protocolKind,
                            connectionEpoch: command.connectionEpoch
                        )
                        commands.insert(identity)
                        if let decisionID = command.decisionID {
                            if commandToDecision[identity] != nil {
                                invalidCommandDecisionScopes.insert(identity)
                                duplicateCommandLinkRecordCount += 1
                            } else {
                                commandToDecision[identity] = decisionID
                            }
                        }
                    case let .sendAttempt(attempt):
                        recordSend(SendAttempt(
                            commandID: attempt.commandID,
                            decisionID: attempt.decisionID,
                            attemptID: attempt.attemptID,
                            attemptNumber: attempt.attemptNumber,
                            time: time,
                            protocolKind: attempt.protocolKind,
                            connectionEpoch: attempt.connectionEpoch
                        ))
                    case let .acknowledgement(acknowledgement):
                        switch acknowledgement.association {
                        case .unresolvedByLegacyRuntime:
                            unknownAcknowledgements += 1
                        case let .deterministicallyCorrelated(commandID, attemptID):
                            acknowledgements.append(ProvenEdge(
                                commandID: commandID,
                                attemptID: attemptID,
                                time: time,
                                protocolKind: acknowledgement.protocolKind,
                                connectionEpoch: acknowledgement.connectionEpoch
                            ))
                        }
                    case let .observation(observation):
                        guard observation.factualSpeed != nil else { break }
                        switch observation.responseAssociation {
                        case .unassociated:
                            unknownResponses += 1
                        case let .deterministicallyCorrelated(commandID, attemptID):
                            responses.append(ProvenEdge(
                                commandID: commandID,
                                attemptID: attemptID,
                                time: time,
                                protocolKind: observation.protocolKind,
                                connectionEpoch: observation.connectionEpoch
                            ))
                        }
                    case .unitsTruth, .commandQueueDelay, .unassociatedWrite,
                         .writeResult, .commandTimeout, .commandFailed, .commandCancelled,
                         .stopEvidence:
                        break
                    }
                default:
                    break
                }
            }
            let sortedAcknowledgements = acknowledgements.sorted(by: edgeOrder)
            let sortedResponses = responses.sorted(by: edgeOrder)
            let validCommandDecisionIDs = commandToDecision.filter { identity, decisionID in
                !invalidCommandDecisionScopes.contains(identity)
                    && !invalidDecisionIDs.contains(decisionID)
                    && decisionEpochs[decisionID] == identity.connectionEpoch
            }
            let invalidCommandDecisionLinkCount = duplicateCommandLinkRecordCount
                + commandToDecision.filter { identity, decisionID in
                    invalidCommandDecisionScopes.contains(identity)
                        || invalidDecisionIDs.contains(decisionID)
                        || decisionEpochs[decisionID] != identity.connectionEpoch
                }.count
            var mismatchedSendDecisionCount = 0
            for send in sends.values {
                let identity = ScopedCommandIdentity(
                    commandID: send.commandID,
                    protocolKind: send.protocolKind,
                    connectionEpoch: send.connectionEpoch
                )
                guard let enqueuedDecisionID = validCommandDecisionIDs[identity] else {
                    continue
                }
                if send.decisionID != enqueuedDecisionID {
                    invalidAttemptIDs.insert(send.attemptID)
                    mismatchedSendDecisionCount += 1
                }
            }
            commandIDs = commands
            sendsByAttempt = sends.filter { !invalidAttemptIDs.contains($0.key) }
            let duplicateAcknowledgementKeys = duplicateEdgeIdentities(sortedAcknowledgements)
            let duplicateResponseKeys = duplicateEdgeIdentities(sortedResponses)
            let isValidEdge: (ProvenEdge, Set<ProvenEdgeIdentity>) -> Bool = {
                edge, duplicateKeys in
                let identity = ProvenEdgeIdentity(
                    commandID: edge.commandID,
                    attemptID: edge.attemptID
                )
                guard !invalidAttemptIDs.contains(edge.attemptID),
                      !duplicateKeys.contains(identity) else { return false }
                guard let send = sends[edge.attemptID] else { return false }
                guard send.commandID == edge.commandID,
                      edge.time >= send.time else { return false }
                return send.protocolKind == edge.protocolKind
                    && send.connectionEpoch == edge.connectionEpoch
            }
            provenAcknowledgements = sortedAcknowledgements.filter {
                isValidEdge($0, duplicateAcknowledgementKeys)
            }
            provenFactualResponses = sortedResponses.filter {
                isValidEdge($0, duplicateResponseKeys)
            }
            unknownAcknowledgementCount = unknownAcknowledgements
            unknownFactualResponseCount = unknownResponses
            invalidCausalEdgeCount = unsupportedGenericCausalRecordCount
                + duplicateSendRecordCount
                + duplicateDecisionRecordCount
                + mismatchedSendDecisionCount
                + invalidCommandDecisionLinkCount
                + sortedAcknowledgements.filter {
                    !isValidEdge($0, duplicateAcknowledgementKeys)
                }.count
                + sortedResponses.filter {
                    !isValidEdge($0, duplicateResponseKeys)
                }.count
            desiredDecisions = Array(Dictionary(
                validCommandDecisionIDs.compactMap { identity, decisionID -> (
                    ScopedDecisionIdentity,
                    ScopedDesiredDecision
                )? in
                    guard let decision = decisions[decisionID],
                          !invalidDecisionIDs.contains(decisionID) else { return nil }
                    let scopedIdentity = ScopedDecisionIdentity(
                        decisionID: decisionID,
                        protocolKind: identity.protocolKind,
                        connectionEpoch: identity.connectionEpoch
                    )
                    return (
                        scopedIdentity,
                        ScopedDesiredDecision(
                            identity: scopedIdentity,
                            time: decision.time,
                            speed: decision.speed
                        )
                    )
                },
                uniquingKeysWith: { first, _ in first }
            ).values).sorted(by: scopedDecisionOrder)
            commandDecisionIDs = validCommandDecisionIDs
        }

        var acknowledgementCoverage: CausalAssociationCoverage {
            coverage(edges: provenAcknowledgements, unknownCount: unknownAcknowledgementCount)
        }

        var factualResponseCoverage: CausalAssociationCoverage {
            coverage(edges: provenFactualResponses, unknownCount: unknownFactualResponseCount)
        }

        var retryLatencies: [Double] {
            Dictionary(grouping: sendsByAttempt.values) { send in
                ScopedCommandIdentity(
                    commandID: send.commandID,
                    protocolKind: send.protocolKind,
                    connectionEpoch: send.connectionEpoch
                )
            }.values.flatMap { attempts in
                let ordered = attempts.sorted {
                    if $0.attemptNumber != $1.attemptNumber {
                        return $0.attemptNumber < $1.attemptNumber
                    }
                    return $0.time < $1.time
                }
                return zip(ordered, ordered.dropFirst()).compactMap { pair -> Double? in
                    let (previous, next) = pair
                    guard next.attemptNumber > previous.attemptNumber,
                          next.time >= previous.time else { return nil }
                    return next.time - previous.time
                }
            }
        }

        var speedDeltas: [Double] {
            scopedDecisionSeries.flatMap { decisions in
                zip(decisions, decisions.dropFirst()).map { $1.speed - $0.speed }
            }
        }

        func informativeCommandIDs(minimumDelta: Double) -> Set<ScopedCommandIdentity> {
            var informativeDecisions: Set<ScopedDecisionIdentity> = []
            for decisions in scopedDecisionSeries {
                for pair in zip(decisions, decisions.dropFirst())
                    where abs(pair.1.speed - pair.0.speed) >= minimumDelta
                {
                    informativeDecisions.insert(pair.1.identity)
                }
            }
            return Set(commandDecisionIDs.compactMap { identity, decisionID in
                let scopedDecision = ScopedDecisionIdentity(
                    decisionID: decisionID,
                    protocolKind: identity.protocolKind,
                    connectionEpoch: identity.connectionEpoch
                )
                return informativeDecisions.contains(scopedDecision) ? identity : nil
            })
        }

        private var scopedDecisionSeries: [[ScopedDesiredDecision]] {
            Dictionary(grouping: desiredDecisions) { decision in
                DecisionSeriesScope(
                    protocolKind: decision.identity.protocolKind,
                    connectionEpoch: decision.identity.connectionEpoch
                )
            }.values.map { $0.sorted(by: scopedDecisionOrder) }
        }

        private func coverage(
            edges: [ProvenEdge],
            unknownCount: Int
        ) -> CausalAssociationCoverage {
            let valid = edges.compactMap { edge -> Double? in
                guard let send = sendsByAttempt[edge.attemptID],
                      send.commandID == edge.commandID,
                      edge.time >= send.time else { return nil }
                return edge.time - send.time
            }
            let latency = metricDistribution(
                valid,
                noEvidenceReason: sendsByAttempt.isEmpty
                    ? "no-command-attempt-evidence"
                    : "no-proven-causal-edge"
            )
            return CausalAssociationCoverage(
                eligibleEdgeCount: sendsByAttempt.count,
                provenEdgeCount: valid.count,
                unknownAssociationCount: unknownCount,
                latencySeconds: latency
            )
        }
    }

    static func makeQuality(
        input: WorkoutAnalysisInput,
        sessionEnd: Double,
        phases: PhaseTimeline,
        heartRate: HeartRateTimeline,
        treadmill: TreadmillTimeline,
        causal: CausalAnalysis,
        configurationAvailable: Bool
    ) -> WorkoutDataQualityV1 {
        let heartRateCovered = heartRate.coveredSeconds(in: nil)
        let treadmillCovered = treadmill.coveredSeconds(in: nil)
        let hrCoverage = DurationCoverage(
            coveredSeconds: heartRateCovered,
            uncoveredSeconds: max(0, sessionEnd - heartRateCovered)
        )
        let treadmillCoverage = DurationCoverage(
            coveredSeconds: treadmillCovered,
            uncoveredSeconds: max(0, sessionEnd - treadmillCovered)
        )
        let gaps = uncoveredRanges(
            covered: heartRate.mergedCoverageRanges,
            within: 0..<sessionEnd
        )
        let cadenceValues = zip(
            heartRate.effectiveTimesInArrivalOrder,
            heartRate.effectiveTimesInArrivalOrder.dropFirst()
        ).compactMap { previous, next in next >= previous ? next - previous : nil }
        let latencyValues = input.heartRate.compactMap { observation -> Double? in
            guard let measured = observation.timestamp.measuredElapsed else { return nil }
            let latency = seconds(observation.timestamp.receivedElapsed) - seconds(measured)
            return latency >= 0 ? latency : nil
        }
        let duplicateCount = input.heartRate.filter {
            $0.quality.contains(.duplicateProviderIdentity)
                || $0.quality.contains(.duplicateProviderSequence)
        }.count
        let outOfOrderCount = input.heartRate.reduce(0) {
            $0 + ($1.quality.contains(.measurementOutOfArrivalOrder) ? 1 : 0)
        } + zip(
            heartRate.effectiveTimesInArrivalOrder,
            heartRate.effectiveTimesInArrivalOrder.dropFirst()
        ).filter { $1 < $0 }.count
        let observedSourceSwitches = zip(
            heartRate.observationsInArrivalOrder,
            heartRate.observationsInArrivalOrder.dropFirst()
        ).filter { $0.source.id != $1.source.id }.count
        let typedSourceSwitches = input.events.filter { event in
            guard case let .sourceTransition(transition) = event.payload.payload else {
                return false
            }
            return transition.previousSourceID != transition.currentSourceID
        }.count
        let sourceSwitches = typedSourceSwitches > 0
            ? typedSourceSwitches
            : observedSourceSwitches
        let recorderLoss = !input.session.recorderHealth.isComplete
            || input.session.recorderHealth.lostCriticalRecordCount > 0
            || input.session.recorderHealth.lostNativeRecordCount > 0
            || input.events.contains { event in
                if case let .recorderHealth(health) = event.payload.payload {
                    return health.kind == .loss && (health.count ?? 0) > 0
                }
                return false
            }
        let incomplete = input.session.lifecycleState != .completed
            || input.session.incompleteReason != nil
        let malformedNativeCount = input.heartRate.reduce(0) { count, observation in
            count + (hasMalformedQuality(observation.quality) ? 1 : 0)
        } + input.treadmill.reduce(0) { count, observation in
            count + (hasMalformedQuality(observation.quality) ? 1 : 0)
        }
        let malformedCount = malformedNativeCount + causal.invalidCausalEdgeCount
        let hasMalformedEvidence = malformedCount > 0 || !configurationAvailable
        var issues: [AnalysisQualityIssue] = []
        if recorderLoss {
            issues.append(AnalysisQualityIssue(
                category: .recorderEvidenceLoss,
                code: "recorder-loss",
                count: max(
                    1,
                    saturatedUInt64(
                        input.session.recorderHealth.lostCriticalRecordCount,
                        input.session.recorderHealth.lostNativeRecordCount
                    )
                )
            ))
        }
        if causal.unknownAcknowledgementCount > 0 {
            issues.append(AnalysisQualityIssue(
                category: .protocolRuntimeCausalAmbiguity,
                code: "unknown-command-ack-association",
                count: UInt64(causal.unknownAcknowledgementCount)
            ))
        }
        if causal.unknownFactualResponseCount > 0 {
            issues.append(AnalysisQualityIssue(
                category: .protocolRuntimeCausalAmbiguity,
                code: "unknown-command-factual-response-association",
                count: UInt64(causal.unknownFactualResponseCount)
            ))
        }
        if hrCoverage.uncoveredSeconds > 0 {
            issues.append(AnalysisQualityIssue(
                category: .sourceCoverageUnavailable,
                code: "heart-rate-uncovered-time",
                count: UInt64(gaps.count),
                detail: secondsDetail(hrCoverage.uncoveredSeconds)
            ))
        }
        if treadmillCoverage.uncoveredSeconds > 0 {
            issues.append(AnalysisQualityIssue(
                category: .sourceCoverageUnavailable,
                code: "factual-treadmill-uncovered-time",
                detail: secondsDetail(treadmillCoverage.uncoveredSeconds)
            ))
        }
        if !configurationAvailable {
            issues.append(AnalysisQualityIssue(
                category: .malformedCorruptEvidence,
                code: "configuration-payload-unavailable"
            ))
        }
        if malformedCount > 0 {
            issues.append(AnalysisQualityIssue(
                category: .malformedCorruptEvidence,
                code: "malformed-or-invalid-native-evidence",
                count: UInt64(malformedCount)
            ))
        }
        if incomplete {
            issues.append(AnalysisQualityIssue(
                category: .sourceCoverageUnavailable,
                code: "incomplete-session",
                detail: input.session.incompleteReason
            ))
        }
        let grade = qualityGrade(
            coverage: hrCoverage.coverageRatio,
            incomplete: incomplete,
            recorderLoss: recorderLoss,
            malformed: hasMalformedEvidence,
            hasCausalAmbiguity: causal.unknownAcknowledgementCount > 0
                || causal.unknownFactualResponseCount > 0
        )
        let phaseQuality = phases.intervals
            .filter { $0.phase != .finished }
            .map { interval -> PhaseQualitySummary in
                let range = interval.start..<interval.end
                let duration = interval.end - interval.start
                let hr = heartRate.coveredSeconds(in: range)
                let speed = treadmill.coveredSeconds(in: range)
                let coverage = DurationCoverage(
                    coveredSeconds: hr,
                    uncoveredSeconds: max(0, duration - hr)
                )
                let speedCoverage = DurationCoverage(
                    coveredSeconds: speed,
                    uncoveredSeconds: max(0, duration - speed)
                )
                let phaseGrade = qualityGrade(
                    coverage: coverage.coverageRatio,
                    incomplete: false,
                    recorderLoss: recorderLoss,
                    malformed: hasMalformedEvidence,
                    hasCausalAmbiguity: false
                )
                var codes: [String] = []
                if coverage.uncoveredSeconds > 0 { codes.append("heart-rate-uncovered-time") }
                if speedCoverage.uncoveredSeconds > 0 { codes.append("factual-treadmill-uncovered-time") }
                if recorderLoss { codes.append("recorder-loss") }
                if !configurationAvailable { codes.append("configuration-payload-unavailable") }
                if malformedCount > 0 {
                    codes.append("malformed-or-invalid-native-evidence")
                }
                return PhaseQualitySummary(
                    phase: phaseKey(interval.phase),
                    durationSeconds: duration,
                    heartRateCoverage: coverage,
                    treadmillCoverage: speedCoverage,
                    grade: phaseGrade,
                    exclusionCodes: codes
                )
            }
        return WorkoutDataQualityV1(
            sessionDurationSeconds: sessionEnd,
            heartRateCoverage: hrCoverage,
            heartRateGapCount: gaps.count,
            maximumHeartRateGapSeconds: gaps.map { $0.upperBound - $0.lowerBound }.max(),
            heartRateCadenceSeconds: metricDistribution(
                cadenceValues,
                noEvidenceReason: "insufficient-heart-rate-cadence-evidence"
            ),
            receiveLatencySeconds: metricDistribution(
                latencyValues,
                noEvidenceReason: "measurement-time-not-comparable-or-unavailable"
            ),
            receiveTimeFallbackCount: input.heartRate.filter {
                $0.timestamp.measuredElapsed == nil
            }.count,
            duplicateEvidenceCount: duplicateCount,
            outOfOrderEvidenceCount: outOfOrderCount,
            sourceSwitchCount: sourceSwitches,
            treadmillFactualCoverage: treadmillCoverage,
            commandAcknowledgement: causal.acknowledgementCoverage,
            commandFactualResponse: causal.factualResponseCoverage,
            incompleteSession: incomplete,
            recorderLoss: recorderLoss,
            issues: issues.sorted(by: qualityIssueOrder),
            sessionGrade: grade,
            phases: phaseQuality
        )
    }

    static func makeControlMetrics(
        configuration: AnalysisConfiguration?,
        phases: PhaseTimeline,
        targets: TargetTimeline,
        heartRate: HeartRateTimeline,
        treadmill: TreadmillTimeline,
        causal: CausalAnalysis,
        events: [WorkoutEvent],
        policy: AnalyzerV1Policy
    ) -> WorkoutControlMetricsV1 {
        let mainRange = phases.range(for: .main)
        let mainSegments = heartRate.clippedSegments(in: mainRange)
        let zoneDurations: [ZoneDurationV1]
        if let configuration, !mainSegments.isEmpty {
            var zoneSeconds = Array(repeating: 0.0, count: 5)
            for segment in mainSegments {
                let zone = zoneIndex(
                    beatsPerMinute: segment.beatsPerMinute,
                    upperBounds: configuration.heartRateZones
                )
                zoneSeconds[zone] += segment.duration
            }
            zoneDurations = zoneSeconds.enumerated().map {
                ZoneDurationV1(zone: $0.offset + 1, seconds: $0.element)
            }
        } else {
            zoneDurations = []
        }
        let targetSegments = configuration.map { configuration in
            mainSegments.compactMap { segment -> (
                segment: HeartRateSegment,
                target: Double,
                range: ClosedRange<Double>
            )? in
                guard let target = segment.target else { return nil }
                return (
                    segment,
                    target,
                    targetRange(target: target, upperBounds: configuration.heartRateZones)
                )
            }
        } ?? []
        let targetCovered = targetSegments.reduce(0) { $0 + $1.segment.duration }
        let inTarget = targetSegments.reduce(0) { partial, item in
            partial + (item.range.contains(item.segment.beatsPerMinute)
                ? item.segment.duration
                : 0)
        }
        let targetDuration: AnalysisMetric<Double> = targetCovered > 0
            ? AnalysisMetric(value: inTarget, confidence: .high)
            : .unavailable(["target-or-heart-rate-coverage-unavailable"])
        let targetRatio: AnalysisMetric<Double> = targetCovered > 0
            ? AnalysisMetric(value: inTarget / targetCovered, confidence: .high)
            : .unavailable(["target-or-heart-rate-coverage-unavailable"])

        let absoluteIntegral = targetSegments.reduce(0) {
            $0 + abs($1.segment.beatsPerMinute - $1.target) * $1.segment.duration
        }
        let squaredIntegral = targetSegments.reduce(0) {
            let error = $1.segment.beatsPerMinute - $1.target
            return $0 + error * error * $1.segment.duration
        }
        let errorMetric: AnalysisMetric<HeartRateErrorMetricsV1> = targetCovered > 0
            ? AnalysisMetric(
                value: HeartRateErrorMetricsV1(
                    coveredSeconds: targetCovered,
                    meanAbsoluteErrorBeatsPerMinute: absoluteIntegral / targetCovered,
                    rootMeanSquareErrorBeatsPerMinute: sqrt(squaredIntegral / targetCovered),
                    integralAbsoluteErrorBeatSeconds: absoluteIntegral
                ),
                confidence: .high
            )
            : .unavailable(["target-or-heart-rate-coverage-unavailable"])
        let overshoot = directionalDeviation(targetSegments, direction: .above)
        let undershoot = directionalDeviation(targetSegments, direction: .below)
        let timeToTarget = firstTargetEntry(
            segments: targetSegments,
            mainStart: mainRange?.lowerBound
        )
        let settlingTime = settlingTime(
            segments: targetSegments,
            mainStart: mainRange?.lowerBound,
            requiredSeconds: policy.settlingWindowSeconds
        )
        let speedDelta = metricDistribution(
            causal.speedDeltas,
            noEvidenceReason: "insufficient-command-domain-speed-decisions"
        )
        let drift = stableSpeedDrift(
            heartRate: heartRate,
            treadmill: treadmill,
            mainRange: mainRange,
            policy: policy
        )
        let eventResponse = eventAlignedResponse(
            heartRate: heartRate,
            causal: causal,
            policy: policy
        )
        let retryLatency = metricDistribution(
            causal.retryLatencies,
            noEvidenceReason: "no-proven-retry-attempt-identity"
        )
        let cooldown = cooldownMetrics(
            configuration: configuration,
            phases: phases,
            targets: targets,
            heartRate: heartRate,
            treadmill: treadmill,
            events: events
        )
        return WorkoutControlMetricsV1(
            zoneDurations: zoneDurations,
            targetRangeDurationSeconds: targetDuration,
            targetRangeCoverageRatio: targetRatio,
            heartRateError: errorMetric,
            overshoot: overshoot,
            undershoot: undershoot,
            timeToTargetSeconds: timeToTarget,
            settlingTimeSeconds: settlingTime,
            commandCount: causal.commandIDs.count,
            speedDeltaKilometresPerHour: speedDelta,
            stableSpeedHeartRateDrift: drift,
            eventAlignedHeartRateResponse: eventResponse,
            retryAttemptLatencySeconds: retryLatency,
            cooldown: cooldown,
            futureIntervals: IntervalMetricFrameworkV1()
        )
    }

    enum DeviationDirection {
        case above
        case below
    }

    static func directionalDeviation(
        _ segments: [(
            segment: HeartRateSegment,
            target: Double,
            range: ClosedRange<Double>
        )],
        direction: DeviationDirection
    ) -> AnalysisMetric<DirectionalDeviationMetricsV1> {
        guard !segments.isEmpty else {
            return .unavailable(["target-or-heart-rate-coverage-unavailable"])
        }
        let values: [(magnitude: Double, duration: Double)] = segments.compactMap { item in
            let magnitude: Double
            switch direction {
            case .above: magnitude = item.segment.beatsPerMinute - item.target
            case .below: magnitude = item.target - item.segment.beatsPerMinute
            }
            return magnitude > 0 ? (magnitude, item.segment.duration) : nil
        }
        let duration = values.reduce(0) { $0 + $1.duration }
        guard duration > 0 else {
            return AnalysisMetric(
                value: DirectionalDeviationMetricsV1(
                    durationSeconds: 0,
                    maximumMagnitudeBeatsPerMinute: 0,
                    meanMagnitudeBeatsPerMinute: 0,
                    integralMagnitudeBeatSeconds: 0
                ),
                confidence: .high
            )
        }
        let integral = values.reduce(0) { $0 + $1.magnitude * $1.duration }
        return AnalysisMetric(
            value: DirectionalDeviationMetricsV1(
                durationSeconds: duration,
                maximumMagnitudeBeatsPerMinute: values.map(\.magnitude).max() ?? 0,
                meanMagnitudeBeatsPerMinute: integral / duration,
                integralMagnitudeBeatSeconds: integral
            ),
            confidence: .high
        )
    }

    static func firstTargetEntry(
        segments: [(
            segment: HeartRateSegment,
            target: Double,
            range: ClosedRange<Double>
        )],
        mainStart: Double?
    ) -> AnalysisMetric<Double> {
        guard let mainStart else { return .unavailable(["main-phase-unavailable"]) }
        guard let first = segments.first(where: {
            $0.range.contains($0.segment.beatsPerMinute)
        }) else {
            return .unavailable(["target-range-not-observed"])
        }
        return AnalysisMetric(value: max(0, first.segment.start - mainStart), confidence: .high)
    }

    static func settlingTime(
        segments: [(
            segment: HeartRateSegment,
            target: Double,
            range: ClosedRange<Double>
        )],
        mainStart: Double?,
        requiredSeconds: Double
    ) -> AnalysisMetric<Double> {
        guard let mainStart else { return .unavailable(["main-phase-unavailable"]) }
        var streakStart: Double?
        var streakEnd: Double?
        for item in segments {
            let inRange = item.range.contains(item.segment.beatsPerMinute)
            if inRange, streakEnd == nil || approximatelyEqual(streakEnd!, item.segment.start) {
                streakStart = streakStart ?? item.segment.start
                streakEnd = item.segment.end
            } else if inRange {
                streakStart = item.segment.start
                streakEnd = item.segment.end
            } else {
                streakStart = nil
                streakEnd = nil
            }
            if let streakStart, let streakEnd, streakEnd - streakStart >= requiredSeconds {
                return AnalysisMetric(value: max(0, streakStart - mainStart), confidence: .high)
            }
        }
        return .unavailable(["continuous-target-settling-window-not-observed"])
    }

    static func stableSpeedDrift(
        heartRate: HeartRateTimeline,
        treadmill: TreadmillTimeline,
        mainRange: Range<Double>?,
        policy: AnalyzerV1Policy
    ) -> AnalysisMetric<StableSpeedHeartRateDriftV1> {
        guard let mainRange else { return .unavailable(["main-phase-unavailable"]) }
        let intersections = intersect(
            heartRate: heartRate.clippedSegments(in: mainRange),
            treadmill: treadmill.clippedSegments(in: mainRange)
        )
        var groups: [[WeightedHeartRatePoint]] = []
        var current: [WeightedHeartRatePoint] = []
        var referenceSpeed: Double?
        var previousEnd: Double?
        for item in intersections {
            let continuous = previousEnd.map { approximatelyEqual($0, item.start) } ?? true
            let stable = referenceSpeed.map {
                abs($0 - item.speed) <= policy.stableSpeedToleranceKilometresPerHour
            } ?? true
            if !continuous || !stable {
                if !current.isEmpty { groups.append(current) }
                current = []
                referenceSpeed = item.speed
            }
            referenceSpeed = referenceSpeed ?? item.speed
            current.append(WeightedHeartRatePoint(
                time: (item.start + item.end) / 2,
                beatsPerMinute: item.beatsPerMinute,
                weight: item.end - item.start
            ))
            previousEnd = item.end
        }
        if !current.isEmpty { groups.append(current) }
        let qualifying = groups.filter {
            $0.reduce(0) { $0 + $1.weight } >= policy.stableSpeedMinimumSeconds
        }
        let windowRegressions = qualifying.compactMap { points -> (
            coveredSeconds: Double,
            regression: WeightedRegression
        )? in
            let covered = points.reduce(0) { $0 + $1.weight }
            guard let regression = weightedRegression(points) else { return nil }
            return (covered, regression)
        }
        let covered = windowRegressions.reduce(0) { $0 + $1.coveredSeconds }
        guard !windowRegressions.isEmpty, covered > 0 else {
            return .unavailable(["insufficient-stable-factual-speed-heart-rate-coverage"])
        }
        let slope = windowRegressions.reduce(0) {
            $0 + ($1.regression.slopePerSecond * $1.coveredSeconds)
        } / covered
        let rSquaredValues = windowRegressions.compactMap { item in
            item.regression.rSquared.map { ($0, item.coveredSeconds) }
        }
        let rSquaredWeight = rSquaredValues.reduce(0) { $0 + $1.1 }
        let rSquared = rSquaredWeight > 0
            ? rSquaredValues.reduce(0) { $0 + ($1.0 * $1.1) } / rSquaredWeight
            : nil
        return AnalysisMetric(
            value: StableSpeedHeartRateDriftV1(
                qualifyingWindowCount: windowRegressions.count,
                coveredSeconds: covered,
                slopeBeatsPerMinutePerMinute: slope * 60,
                coefficientOfDetermination: rSquared
            ),
            confidence: windowRegressions.count > 1 ? .high : .medium
        )
    }

    static func eventAlignedResponse(
        heartRate: HeartRateTimeline,
        causal: CausalAnalysis,
        policy: AnalyzerV1Policy
    ) -> AnalysisMetric<EventAlignedHeartRateResponseV1> {
        let informative = causal.informativeCommandIDs(
            minimumDelta: policy.informativeSpeedDeltaKilometresPerHour
        )
        var responses: [Double] = []
        for edge in causal.provenFactualResponses {
            let identity = ScopedCommandIdentity(
                commandID: edge.commandID,
                protocolKind: edge.protocolKind,
                connectionEpoch: edge.connectionEpoch
            )
            guard informative.contains(identity) else { continue }
            let before = (edge.time - policy.eventResponseWindowSeconds)..<edge.time
            let after = edge.time..<(edge.time + policy.eventResponseWindowSeconds)
            let beforeCoverage = heartRate.coveredSeconds(in: before)
            let afterCoverage = heartRate.coveredSeconds(in: after)
            let required = policy.eventResponseWindowSeconds * policy.minimumWindowCoverageRatio
            guard beforeCoverage >= required,
                  afterCoverage >= required,
                  let beforeAverage = heartRate.weightedAverage(in: before),
                  let afterAverage = heartRate.weightedAverage(in: after) else { continue }
            responses.append(afterAverage - beforeAverage)
        }
        guard let distribution = distribution(responses) else {
            return .unavailable([
                informative.isEmpty
                    ? "no-informative-command-domain-speed-change"
                    : "no-proven-factual-response-with-covered-heart-rate-windows",
            ])
        }
        let standardError = responses.count > 1
            ? distribution.standardDeviation / sqrt(Double(responses.count))
            : nil
        return AnalysisMetric(
            value: EventAlignedHeartRateResponseV1(
                provenFactualResponseEventCount: responses.count,
                responseBeatsPerMinute: distribution,
                standardError: standardError,
                causalInterpretation: "descriptive-after-proven-factual-response-not-causal-effect"
            ),
            confidence: responses.count >= 3 ? .medium : .low
        )
    }

    static func cooldownMetrics(
        configuration: AnalysisConfiguration?,
        phases: PhaseTimeline,
        targets: TargetTimeline,
        heartRate: HeartRateTimeline,
        treadmill: TreadmillTimeline,
        events: [WorkoutEvent]
    ) -> CooldownAnalysisV1 {
        guard let range = phases.range(for: .cooldown) else {
            let unavailableDouble = AnalysisMetric<Double>.unavailable(["cooldown-phase-unavailable"])
            return CooldownAnalysisV1(
                durationSeconds: nil,
                heartRateCoverage: DurationCoverage(coveredSeconds: 0, uncoveredSeconds: 0),
                startHeartRate: unavailableDouble,
                endHeartRate: unavailableDouble,
                peakHeartRate: unavailableDouble,
                targetHeartRate: unavailableDouble,
                targetHitElapsedSeconds: unavailableDouble,
                heartRateBelowTargetSeconds: unavailableDouble,
                minimumFactualSpeedSeconds: unavailableDouble,
                targetAndMinimumSpeedSeconds: unavailableDouble,
                targetAndMinimumSpeedMaximumStreakSeconds: unavailableDouble,
                finishReason: .unavailable(["cooldown-phase-unavailable"]),
                timeoutBlocker: .unavailable(["not-persisted-as-typed-evidence"]),
                hrr10: unavailableDouble,
                hrr30: unavailableDouble,
                hrr60: unavailableDouble,
                hrr120: unavailableDouble,
                recoverySlopeBeatsPerMinutePerMinute: unavailableDouble,
                recoveryFitRSquared: unavailableDouble
            )
        }
        let duration = range.upperBound - range.lowerBound
        let hrSegments = heartRate.clippedSegments(in: range)
        let speedSegments = treadmill.clippedSegments(in: range)
        let covered = hrSegments.reduce(0) { $0 + $1.duration }
        let coverage = DurationCoverage(
            coveredSeconds: covered,
            uncoveredSeconds: max(0, duration - covered)
        )
        let start = heartRate.value(at: range.lowerBound)
        let end = heartRate.value(at: max(range.lowerBound, range.upperBound - 0.000_001))
        let startMetric = pointMetric(start, unavailableReason: "cooldown-start-heart-rate-uncovered")
        let endMetric = pointMetric(end, unavailableReason: "cooldown-end-heart-rate-uncovered")
        let peakMetric: AnalysisMetric<Double> = hrSegments.map(\.beatsPerMinute).max().map {
            AnalysisMetric(value: $0, confidence: .high)
        } ?? .unavailable(["cooldown-heart-rate-uncovered"])
        let targetValue = targets.target(at: range.lowerBound)
            ?? configuration?.cooldownTargetHeartRate
        let targetMetric: AnalysisMetric<Double> = targetValue.map {
            AnalysisMetric(value: $0, confidence: .high)
        } ?? .unavailable(["cooldown-target-unavailable"])
        let targetHit: AnalysisMetric<Double>
        let belowTarget: AnalysisMetric<Double>
        if let targetValue {
            let below = hrSegments.filter { $0.beatsPerMinute <= targetValue }
            targetHit = below.first.map {
                AnalysisMetric(value: max(0, $0.start - range.lowerBound), confidence: .high)
            } ?? .unavailable(["cooldown-target-not-observed"])
            belowTarget = covered > 0
                ? AnalysisMetric(
                    value: below.reduce(0) { $0 + $1.duration },
                    confidence: .high
                )
                : .unavailable(["cooldown-heart-rate-uncovered"])
        } else {
            targetHit = .unavailable(["cooldown-target-unavailable"])
            belowTarget = .unavailable(["cooldown-target-unavailable"])
        }
        let minimumSpeed = configuration?.cooldownMinimumSpeedKilometresPerHour
        let minimumSpeedIntervals = minimumSpeed.map { minimum in
            speedSegments.filter { $0.speed <= minimum + 0.000_001 }
        } ?? []
        let minimumSpeedMetric: AnalysisMetric<Double> = minimumSpeed == nil
            ? .unavailable(["cooldown-minimum-speed-configuration-unavailable"])
            : speedSegments.isEmpty
                ? .unavailable(["cooldown-factual-speed-uncovered"])
                : AnalysisMetric(
                    value: minimumSpeedIntervals.reduce(0) { $0 + $1.duration },
                    confidence: .high
                )
        let overlapRanges: [Range<Double>]
        if let targetValue, minimumSpeed != nil {
            let belowRanges = hrSegments.filter {
                $0.beatsPerMinute <= targetValue
            }.map { $0.start..<$0.end }
            let speedRanges = minimumSpeedIntervals.map { $0.start..<$0.end }
            overlapRanges = intersectRanges(belowRanges, speedRanges)
        } else {
            overlapRanges = []
        }
        let jointCoverage = intersectRanges(
            hrSegments.map { $0.start..<$0.end },
            speedSegments.map { $0.start..<$0.end }
        ).reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        let overlapMetric: AnalysisMetric<Double> = targetValue != nil
            && minimumSpeed != nil
            && jointCoverage > 0
            ? AnalysisMetric(
                value: overlapRanges.reduce(0) { $0 + $1.upperBound - $1.lowerBound },
                confidence: .high
            )
            : .unavailable([
                targetValue == nil || minimumSpeed == nil
                    ? "cooldown-target-or-minimum-speed-unavailable"
                    : "cooldown-joint-heart-rate-speed-coverage-unavailable",
            ])
        let overlapStreak: AnalysisMetric<Double> = targetValue != nil
            && minimumSpeed != nil
            && jointCoverage > 0
            ? AnalysisMetric(
                value: overlapRanges.map { $0.upperBound - $0.lowerBound }.max() ?? 0,
                confidence: .high
            )
            : .unavailable([
                targetValue == nil || minimumSpeed == nil
                    ? "cooldown-target-or-minimum-speed-unavailable"
                    : "cooldown-joint-heart-rate-speed-coverage-unavailable",
            ])
        let finishReason = events.compactMap {
            event -> (time: Double, recordID: String, lifecycle: String)? in
            let time = seconds(event.timestamp.occurredElapsed)
            guard case let .cooldown(cooldown) = event.payload.payload,
                  time >= range.lowerBound,
                  time <= range.upperBound else { return nil }
            return (
                time,
                event.recordID.description,
                cooldown.lifecycle.rawValue
            )
        }.sorted { lhs, rhs in
            if lhs.time != rhs.time { return lhs.time < rhs.time }
            return lhs.recordID < rhs.recordID
        }.last?.lifecycle
        let finishMetric: AnalysisMetric<String> = finishReason.map {
            AnalysisMetric(value: $0, confidence: .high)
        } ?? .unavailable(["cooldown-finish-event-unavailable"])
        let hrr = { (offset: Double) -> AnalysisMetric<Double> in
            guard range.lowerBound + offset <= range.upperBound else {
                return .unavailable(["cooldown-ended-before-hrr-window"])
            }
            guard let baseline = start,
                  let point = heartRate.value(at: range.lowerBound + offset) else {
                return .unavailable(["required-hrr-timestamp-coverage-unavailable"])
            }
            let confidence: AnalysisConfidence = baseline.usedReceiveTimeFallback
                || point.usedReceiveTimeFallback ? .medium : .high
            return AnalysisMetric(
                value: baseline.beatsPerMinute - point.beatsPerMinute,
                confidence: confidence
            )
        }
        let recoveryPoints = hrSegments.map {
            WeightedHeartRatePoint(
                time: ($0.start + $0.end) / 2,
                beatsPerMinute: $0.beatsPerMinute,
                weight: $0.duration
            )
        }
        let regression = covered >= 30 ? weightedRegression(recoveryPoints) : nil
        return CooldownAnalysisV1(
            durationSeconds: duration,
            heartRateCoverage: coverage,
            startHeartRate: startMetric,
            endHeartRate: endMetric,
            peakHeartRate: peakMetric,
            targetHeartRate: targetMetric,
            targetHitElapsedSeconds: targetHit,
            heartRateBelowTargetSeconds: belowTarget,
            minimumFactualSpeedSeconds: minimumSpeedMetric,
            targetAndMinimumSpeedSeconds: overlapMetric,
            targetAndMinimumSpeedMaximumStreakSeconds: overlapStreak,
            finishReason: finishMetric,
            timeoutBlocker: .unavailable(["not-persisted-as-typed-evidence"]),
            hrr10: hrr(10),
            hrr30: hrr(30),
            hrr60: hrr(60),
            hrr120: hrr(120),
            recoverySlopeBeatsPerMinutePerMinute: regression.map {
                AnalysisMetric(value: $0.slopePerSecond * 60, confidence: .medium)
            } ?? .unavailable(["insufficient-cooldown-timestamp-coverage-for-fit"]),
            recoveryFitRSquared: regression?.rSquared.map {
                AnalysisMetric(value: $0, confidence: .medium)
            } ?? .unavailable(["insufficient-cooldown-timestamp-coverage-for-fit"])
        )
    }

    struct WeightedHeartRatePoint {
        let time: Double
        let beatsPerMinute: Double
        let weight: Double
    }

    struct WeightedRegression {
        let slopePerSecond: Double
        let rSquared: Double?
    }

    struct HeartRateSpeedIntersection {
        let start: Double
        let end: Double
        let beatsPerMinute: Double
        let speed: Double
    }

    static func validateSessionOwnership(_ input: WorkoutAnalysisInput) throws {
        let sessionID = input.session.sessionID
        guard input.heartRate.allSatisfy({ $0.sessionID == sessionID }),
              input.treadmill.allSatisfy({ $0.sessionID == sessionID }),
              input.events.allSatisfy({ $0.sessionID == sessionID }),
              input.frames.allSatisfy({ $0.sessionID == sessionID }) else {
            throw WorkoutAnalyzerError.evidenceSessionMismatch
        }
    }

    static func resolvedSessionEnd(_ input: WorkoutAnalysisInput) throws -> Double {
        if let ended = input.session.endedElapsed {
            let terminalEnd = seconds(ended)
            guard terminalEnd.isFinite, terminalEnd > 0 else {
                throw WorkoutAnalyzerError.invalidSessionTime
            }
            return terminalEnd
        }
        var candidates: [Double] = []
        if let persisted = input.session.recorderHealth.lastPersistedElapsed {
            candidates.append(seconds(persisted))
        }
        candidates.append(contentsOf: input.heartRate.flatMap {
            [seconds($0.timestamp.receivedElapsed), seconds($0.timestamp.recordedElapsed)]
        })
        candidates.append(contentsOf: input.treadmill.flatMap {
            [seconds($0.timestamp.receivedElapsed), seconds($0.timestamp.recordedElapsed)]
        })
        candidates.append(contentsOf: input.events.map { seconds($0.timestamp.occurredElapsed) })
        candidates.append(contentsOf: input.frames.map { seconds($0.materializedAt.elapsed) })
        guard let end = candidates.filter({ $0.isFinite && $0 >= 0 }).max(), end > 0 else {
            throw WorkoutAnalyzerError.invalidSessionTime
        }
        return end
    }

    static func heartRateEvidenceOrder(
        _ lhs: HeartRateObservation,
        _ rhs: HeartRateObservation
    ) -> Bool {
        let lhsTime = lhs.timestamp.effectiveElapsed.microseconds
        let rhsTime = rhs.timestamp.effectiveElapsed.microseconds
        if lhsTime != rhsTime { return lhsTime < rhsTime }
        if lhs.arrivalOrder != rhs.arrivalOrder { return lhs.arrivalOrder < rhs.arrivalOrder }
        return lhs.recordID.description < rhs.recordID.description
    }

    static func treadmillEvidenceOrder(
        _ lhs: TreadmillObservation,
        _ rhs: TreadmillObservation
    ) -> Bool {
        let lhsTime = lhs.timestamp.effectiveElapsed.microseconds
        let rhsTime = rhs.timestamp.effectiveElapsed.microseconds
        if lhsTime != rhsTime { return lhsTime < rhsTime }
        if lhs.arrivalOrder != rhs.arrivalOrder { return lhs.arrivalOrder < rhs.arrivalOrder }
        return lhs.recordID.description < rhs.recordID.description
    }

    static func eventEvidenceOrder(_ lhs: WorkoutEvent, _ rhs: WorkoutEvent) -> Bool {
        let lhsTime = lhs.timestamp.occurredElapsed.microseconds
        let rhsTime = rhs.timestamp.occurredElapsed.microseconds
        if lhsTime != rhsTime { return lhsTime < rhsTime }
        return lhs.recordID.description < rhs.recordID.description
    }

    static func frameEvidenceOrder(_ lhs: CanonicalFrame, _ rhs: CanonicalFrame) -> Bool {
        if lhs.canonicalElapsedSecond != rhs.canonicalElapsedSecond {
            return lhs.canonicalElapsedSecond < rhs.canonicalElapsedSecond
        }
        return lhs.recordID.description < rhs.recordID.description
    }

    static func sourceTransitionBoundaries(_ events: [WorkoutEvent]) -> [Double] {
        events.compactMap { event in
            guard case .sourceTransition = event.payload.payload else { return nil }
            return seconds(event.timestamp.occurredElapsed)
        }.filter { $0.isFinite && $0 >= 0 }.sorted()
    }

    static func connectionTransitionBoundaries(_ events: [WorkoutEvent]) -> [Double] {
        events.compactMap { event in
            guard case .connectionTransition = event.payload.payload else { return nil }
            return seconds(event.timestamp.occurredElapsed)
        }.filter { $0.isFinite && $0 >= 0 }.sorted()
    }

    static func edgeOrder(_ lhs: ProvenEdge, _ rhs: ProvenEdge) -> Bool {
        if lhs.time != rhs.time { return lhs.time < rhs.time }
        if lhs.commandID != rhs.commandID {
            return lhs.commandID.description < rhs.commandID.description
        }
        return lhs.attemptID.description < rhs.attemptID.description
    }

    static func scopedDecisionOrder(
        _ lhs: ScopedDesiredDecision,
        _ rhs: ScopedDesiredDecision
    ) -> Bool {
        if lhs.time != rhs.time { return lhs.time < rhs.time }
        return lhs.identity.decisionID.description < rhs.identity.decisionID.description
    }

    static func duplicateEdgeIdentities(
        _ edges: [ProvenEdge]
    ) -> Set<ProvenEdgeIdentity> {
        Set(Dictionary(grouping: edges) { edge in
            ProvenEdgeIdentity(commandID: edge.commandID, attemptID: edge.attemptID)
        }.compactMap { identity, matches in
            matches.count > 1 ? identity : nil
        })
    }

    static func isUsableHeartRate(_ observation: HeartRateObservation) -> Bool {
        observation.freshness.state == .fresh
            && !observation.quality.contains(.invalidNativeValue)
            && !observation.quality.contains(.nativeValueOutOfDomain)
            && !observation.quality.contains(.staleAtUse)
            && !observation.quality.contains(.unknownFreshness)
            && !observation.quality.contains(.clockRegression)
    }

    static func isUsableTreadmill(_ observation: TreadmillObservation) -> Bool {
        observation.freshness.state == .fresh
            && !observation.quality.contains(.invalidNativeValue)
            && !observation.quality.contains(.nativeValueOutOfDomain)
            && !observation.quality.contains(.staleAtUse)
            && !observation.quality.contains(.unknownFreshness)
            && !observation.quality.contains(.clockRegression)
    }

    static func hasMalformedQuality(_ quality: QualityFlags) -> Bool {
        quality.contains(.invalidNativeValue)
            || quality.contains(.nativeValueOutOfDomain)
            || quality.contains(.clockRegression)
    }

    static func mergeRanges(_ ranges: [Range<Double>]) -> [Range<Double>] {
        let sorted = ranges.filter { $0.upperBound > $0.lowerBound }.sorted {
            if $0.lowerBound != $1.lowerBound { return $0.lowerBound < $1.lowerBound }
            return $0.upperBound < $1.upperBound
        }
        var merged: [Range<Double>] = []
        for range in sorted {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }
            if range.lowerBound <= last.upperBound + 0.000_001 {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    static func uncoveredRanges(
        covered: [Range<Double>],
        within bounds: Range<Double>
    ) -> [Range<Double>] {
        guard bounds.upperBound > bounds.lowerBound else { return [] }
        var cursor = bounds.lowerBound
        var uncovered: [Range<Double>] = []
        for range in mergeRanges(covered) {
            let start = max(bounds.lowerBound, range.lowerBound)
            let end = min(bounds.upperBound, range.upperBound)
            guard end > bounds.lowerBound, start < bounds.upperBound else { continue }
            if start > cursor { uncovered.append(cursor..<start) }
            cursor = max(cursor, end)
        }
        if cursor < bounds.upperBound { uncovered.append(cursor..<bounds.upperBound) }
        return uncovered
    }

    static func intersectRanges(
        _ lhs: [Range<Double>],
        _ rhs: [Range<Double>]
    ) -> [Range<Double>] {
        var intersections: [Range<Double>] = []
        for left in lhs {
            for right in rhs {
                let start = max(left.lowerBound, right.lowerBound)
                let end = min(left.upperBound, right.upperBound)
                if end > start { intersections.append(start..<end) }
            }
        }
        return mergeRanges(intersections)
    }

    static func intersect(
        heartRate: [HeartRateSegment],
        treadmill: [SpeedSegment]
    ) -> [HeartRateSpeedIntersection] {
        var output: [HeartRateSpeedIntersection] = []
        var hrIndex = 0
        var speedIndex = 0
        while hrIndex < heartRate.count, speedIndex < treadmill.count {
            let hr = heartRate[hrIndex]
            let speed = treadmill[speedIndex]
            let start = max(hr.start, speed.start)
            let end = min(hr.end, speed.end)
            if end > start {
                output.append(HeartRateSpeedIntersection(
                    start: start,
                    end: end,
                    beatsPerMinute: hr.beatsPerMinute,
                    speed: speed.speed
                ))
            }
            if hr.end <= speed.end { hrIndex += 1 }
            if speed.end <= hr.end { speedIndex += 1 }
        }
        return output
    }

    static func weightedRegression(
        _ points: [WeightedHeartRatePoint]
    ) -> WeightedRegression? {
        let valid = points.filter {
            $0.weight > 0 && $0.time.isFinite && $0.beatsPerMinute.isFinite
        }
        let totalWeight = valid.reduce(0) { $0 + $1.weight }
        guard valid.count >= 2, totalWeight > 0 else { return nil }
        let meanTime = valid.reduce(0) { $0 + $1.time * $1.weight } / totalWeight
        let meanHR = valid.reduce(0) { $0 + $1.beatsPerMinute * $1.weight } / totalWeight
        let covariance = valid.reduce(0) {
            $0 + $1.weight * ($1.time - meanTime) * ($1.beatsPerMinute - meanHR)
        }
        let timeVariance = valid.reduce(0) {
            $0 + $1.weight * pow($1.time - meanTime, 2)
        }
        guard timeVariance > 0 else { return nil }
        let slope = covariance / timeVariance
        let intercept = meanHR - slope * meanTime
        let total = valid.reduce(0) {
            $0 + $1.weight * pow($1.beatsPerMinute - meanHR, 2)
        }
        let residual = valid.reduce(0) {
            let predicted = intercept + slope * $1.time
            return $0 + $1.weight * pow($1.beatsPerMinute - predicted, 2)
        }
        let rSquared = total > 0 ? max(0, min(1, 1 - residual / total)) : nil
        return WeightedRegression(slopePerSecond: slope, rSquared: rSquared)
    }

    static func distribution(_ values: [Double]) -> ScalarDistribution? {
        let sorted = values.filter(\.isFinite).sorted()
        guard let minimum = sorted.first, let maximum = sorted.last else { return nil }
        let count = sorted.count
        let mean = sorted.reduce(0, +) / Double(count)
        let variance = sorted.reduce(0) { $0 + pow($1 - mean, 2) } / Double(count)
        func percentile(_ fraction: Double) -> Double {
            guard count > 1 else { return sorted[0] }
            let position = fraction * Double(count - 1)
            let lower = Int(floor(position))
            let upper = Int(ceil(position))
            if lower == upper { return sorted[lower] }
            let weight = position - Double(lower)
            return sorted[lower] * (1 - weight) + sorted[upper] * weight
        }
        return ScalarDistribution(
            count: count,
            minimum: minimum,
            maximum: maximum,
            mean: mean,
            median: percentile(0.5),
            percentile95: percentile(0.95),
            standardDeviation: sqrt(variance)
        )
    }

    static func metricDistribution(
        _ values: [Double],
        noEvidenceReason: String
    ) -> AnalysisMetric<ScalarDistribution> {
        guard let value = distribution(values) else {
            return .unavailable([noEvidenceReason])
        }
        return AnalysisMetric(value: value, confidence: values.count >= 3 ? .high : .low)
    }

    static func pointMetric(
        _ segment: HeartRateSegment?,
        unavailableReason: String
    ) -> AnalysisMetric<Double> {
        guard let segment else { return .unavailable([unavailableReason]) }
        return AnalysisMetric(
            value: segment.beatsPerMinute,
            confidence: segment.usedReceiveTimeFallback ? .medium : .high
        )
    }

    static func qualityGrade(
        coverage: Double?,
        incomplete: Bool,
        recorderLoss: Bool,
        malformed: Bool,
        hasCausalAmbiguity: Bool
    ) -> AnalysisQualityGrade {
        guard let coverage, coverage > 0 else { return .unusable }
        if malformed || recorderLoss || incomplete || coverage < 0.5 { return .low }
        if coverage < 0.9 || hasCausalAmbiguity { return .medium }
        return .high
    }

    static func zoneIndex(beatsPerMinute: Double, upperBounds: [Double]) -> Int {
        for (index, bound) in upperBounds.prefix(4).enumerated()
            where beatsPerMinute <= bound
        {
            return index
        }
        return 4
    }

    static func targetRange(
        target: Double,
        upperBounds: [Double]
    ) -> ClosedRange<Double> {
        let bounds = upperBounds.prefix(4).sorted()
        for (index, upper) in bounds.enumerated() where target <= upper {
            let lower = index == 0 ? 0 : bounds[index - 1]
            return lower...upper
        }
        return (bounds.last ?? max(0, target - 3))...Double(UInt16.max)
    }

    static func phaseKey(_ phase: WorkoutPhase) -> String {
        switch phase {
        case .warmup: "warmup"
        case .main: "main"
        case .cooldown: "cooldown"
        case .finished: "finished"
        case .unknown: "unknown"
        case let .other(value): "other:\(value)"
        }
    }

    static func qualityIssueOrder(
        _ lhs: AnalysisQualityIssue,
        _ rhs: AnalysisQualityIssue
    ) -> Bool {
        if lhs.category.rawValue != rhs.category.rawValue {
            return lhs.category.rawValue < rhs.category.rawValue
        }
        return lhs.code < rhs.code
    }

    static func seconds(_ duration: ElapsedDuration) -> Double {
        duration.seconds
    }

    static func microseconds(_ seconds: Double) -> Int64 {
        guard seconds.isFinite else { return 0 }
        let scaled = max(0, seconds) * 1_000_000
        return Int64(min(scaled.rounded(), Double(Int64.max)))
    }

    static func saturatedUInt64(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? UInt64.max : result.partialValue
    }

    static func approximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) <= 0.000_001
    }

    static func deterministicUUID(_ key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }
        return UUID(uuidString: [
            hex[0...3].joined(),
            hex[4...5].joined(),
            hex[6...7].joined(),
            hex[8...9].joined(),
            hex[10...15].joined(),
        ].joined(separator: "-"))!
    }
}
