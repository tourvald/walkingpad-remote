import Foundation

public enum LegacyTelemetryJSONLReaderError: Error, Equatable, Sendable {
    case unreadableUTF8
    case noParseableRecords
    case missingSessionIdentifier
}

public enum LegacyTelemetryJSONLReader {
    public static func read(from url: URL) throws -> TelemetryParitySessionEvidence {
        try read(data: Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    public static func read(data: Data) throws -> TelemetryParitySessionEvidence {
        guard let source = String(data: data, encoding: .utf8) else {
            throw LegacyTelemetryJSONLReaderError.unreadableUTF8
        }

        var payloads: [[String: Any]] = []
        var malformedRecordCount = 0
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(rawLine).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData),
                  let payload = object as? [String: Any] else {
                malformedRecordCount += 1
                continue
            }
            payloads.append(payload)
        }
        guard !payloads.isEmpty else {
            throw LegacyTelemetryJSONLReaderError.noParseableRecords
        }
        guard let sessionIdentifier = payloads.lazy.compactMap({ string($0["session_id"]) }).first,
              !sessionIdentifier.isEmpty else {
            throw LegacyTelemetryJSONLReaderError.missingSessionIdentifier
        }

        let datedPayloads = payloads.map { payload in
            (payload, date(payload["ts"]))
        }
        let sessionStartPayload = datedPayloads.first { string($0.0["event"]) == "session_start" }
        let sessionEndPayload = datedPayloads.last { string($0.0["event"]) == "session_end" }
        let startedAt = sessionStartPayload?.1 ?? datedPayloads.compactMap(\.1).first
        let endedAt = sessionEndPayload?.1
        let durationMilliseconds = durationMilliseconds(startedAt: startedAt, endedAt: endedAt)
        let elapsed: (Date?) -> Int64 = { eventDate in
            guard let startedAt, let eventDate else { return 0 }
            return max(0, Int64((eventDate.timeIntervalSince(startedAt) * 1_000).rounded()))
        }

        var arrivalOrder: UInt64 = 0
        var heartRate: [TelemetryParityHeartRateEvidence] = []
        var phases: [TelemetryParityPhaseEvidence] = []
        var decisions: [TelemetryParityDecisionEvidence] = []
        var treadmillFacts: [TelemetryParityTreadmillFact] = []
        var commandEvidence: [TelemetryParityCommandEvidence] = []
        var stopEvidence: [TelemetryParityStopEvidence] = []

        for (payload, eventDate) in datedPayloads {
            guard let event = string(payload["event"]) else { continue }
            let elapsedMilliseconds = elapsed(eventDate)
            switch event {
            case "session_start":
                phases.append(
                    TelemetryParityPhaseEvidence(
                        phase: "main",
                        elapsedMilliseconds: elapsedMilliseconds
                    )
                )
            case "session_end":
                phases.append(
                    TelemetryParityPhaseEvidence(
                        phase: "finished",
                        elapsedMilliseconds: elapsedMilliseconds
                    )
                )
            case "cooldown_start":
                phases.append(
                    TelemetryParityPhaseEvidence(
                        phase: "cooldown",
                        elapsedMilliseconds: elapsedMilliseconds
                    )
                )
            case "hr_sample":
                if let beatsPerMinute = integer(payload["hr_bpm"]), let eventDate {
                    arrivalOrder += 1
                    heartRate.append(
                        TelemetryParityHeartRateEvidence(
                            elapsedMilliseconds: elapsedMilliseconds,
                            receivedAt: eventDate,
                            beatsPerMinute: beatsPerMinute,
                            acceptedForControl: true,
                            arrivalOrder: arrivalOrder
                        )
                    )
                }
            case "hr_decision":
                decisions.append(
                    TelemetryParityDecisionEvidence(
                        source: "heartRateControl",
                        action: normalizedDecision(payload),
                        desiredSpeedKilometresPerHour: double(payload["speed_after_kmh"]),
                        elapsedMilliseconds: elapsedMilliseconds
                    )
                )
            case "notify_fe01":
                if let reportedSpeed = double(payload["speed_kmh"]) {
                    let unitsAreMetric = string(payload["controller_units"]) == "metric"
                        && bool(payload["controller_units_fresh"]) == true
                    treadmillFacts.append(
                        TelemetryParityTreadmillFact(
                            elapsedMilliseconds: elapsedMilliseconds,
                            nativeValue: reportedSpeed,
                            nativeUnit: "walkingpad_controller_tenths",
                            factualSpeedKilometresPerHour: unitsAreMetric ? reportedSpeed : nil,
                            deviceState: normalizedWalkingPadState(
                                speedKilometresPerHour: reportedSpeed,
                                rawState: integer(payload["state"])
                            )
                        )
                    )
                }
            case "notify_ftms_treadmill_data":
                if let reportedSpeed = double(payload["speed_kmh"]) {
                    treadmillFacts.append(
                        TelemetryParityTreadmillFact(
                            elapsedMilliseconds: elapsedMilliseconds,
                            nativeValue: reportedSpeed,
                            nativeUnit: "kilometres_per_hour",
                            factualSpeedKilometresPerHour: reportedSpeed,
                            deviceState: bool(payload["moving"]) == true ? "moving" : "stopped"
                        )
                    )
                }
            case "notify_fitshow_speed", "notify_fitshow_status":
                if let reportedSpeed = double(payload["speed_kmh"]) {
                    treadmillFacts.append(
                        TelemetryParityTreadmillFact(
                            elapsedMilliseconds: elapsedMilliseconds,
                            nativeValue: reportedSpeed,
                            nativeUnit: "kilometres_per_hour",
                            factualSpeedKilometresPerHour: reportedSpeed,
                            deviceState: string(payload["state"]) ?? "unknown"
                        )
                    )
                }
            case "command_write":
                commandEvidence.append(
                    TelemetryParityCommandEvidence(
                        outcomeKind: .sent,
                        semanticCommand: semanticCommand(label: string(payload["label"])),
                        elapsedMilliseconds: elapsedMilliseconds,
                        association: .unknown,
                        commandIdentifier: nil,
                        attemptIdentifier: nil
                    )
                )
            case "command_ack_timeout":
                commandEvidence.append(
                    unknownCommandOutcome(.timeout, elapsedMilliseconds: elapsedMilliseconds)
                )
            case "command_write_result":
                commandEvidence.append(
                    unknownCommandOutcome(.writeResult, elapsedMilliseconds: elapsedMilliseconds)
                )
            case "stop_observation_finished":
                if let conclusion = string(payload["stop_final_result"]), !conclusion.isEmpty {
                    stopEvidence.append(
                        TelemetryParityStopEvidence(
                            conclusion: normalizedStopConclusion(conclusion),
                            factualObservationIdentifier: nil,
                            elapsedMilliseconds: elapsedMilliseconds
                        )
                    )
                }
            default:
                break
            }
        }

        let timestamps = datedPayloads.compactMap(\.1)
        let outOfOrderCount = zip(timestamps, timestamps.dropFirst()).filter {
            pair in pair.0 > pair.1
        }.count
        var limitations = [
            TelemetryParitySourceLimitation(
                category: .commandLifecycle,
                code: "legacy-jsonl-ack-acceptance-not-explicit",
                detail: "Legacy JSONL notifications do not prove which signals the runtime accepted as ACK evidence."
            )
        ]
        if malformedRecordCount > 0 {
            limitations.append(
                TelemetryParitySourceLimitation(
                    category: .recordIntegrity,
                    code: "legacy-malformed-records",
                    detail: "Legacy JSONL contains \(malformedRecordCount) malformed record(s)."
                )
            )
        }
        let configuration = sessionStartPayload.map {
            legacyConfiguration($0.0, limitations: &limitations)
        }
        let completeness: TelemetryParityCompleteness = malformedRecordCount == 0
            && sessionEndPayload != nil ? .complete : .incomplete

        return TelemetryParitySessionEvidence(
            origin: .legacyJSONL,
            sessionIdentifier: sessionIdentifier,
            linkedLegacySessionIdentifier: sessionIdentifier,
            completeness: completeness,
            lifecycle: TelemetryParityLifecycleEvidence(
                startedAt: startedAt,
                endedAt: endedAt,
                endReason: sessionEndPayload.flatMap { string($0.0["reason"]) },
                durationMilliseconds: durationMilliseconds
            ),
            heartRate: heartRate,
            phases: phases,
            configuration: configuration,
            decisions: decisions,
            treadmillFacts: treadmillFacts,
            commandEvidence: commandEvidence,
            aggregates: nil,
            stopEvidence: stopEvidence,
            integrity: TelemetryParityIntegrityEvidence(
                outOfOrderRecordCount: outOfOrderCount
            ),
            limitations: limitations
        )
    }

    private static func legacyConfiguration(
        _ payload: [String: Any],
        limitations: inout [TelemetryParitySourceLimitation]
    ) -> TelemetryParityConfigurationEvidence {
        let telemetrySchemaVersion = string(payload["telemetry_schema_version"])
        let algorithmVersion = string(payload["algorithm_version"])
        let safetyPolicyVersion = string(payload["safety_policy_version"])
        let workoutProtocolVersion = string(payload["workout_protocol_version"])
        if telemetrySchemaVersion == nil || algorithmVersion == nil
            || safetyPolicyVersion == nil || workoutProtocolVersion == nil {
            limitations.append(
                TelemetryParitySourceLimitation(
                    category: .configurationAndVersions,
                    code: "legacy-runtime-versions-not-recorded",
                    detail: "Legacy JSONL does not expose the complete V2 runtime-version snapshot."
                )
            )
        }
        return TelemetryParityConfigurationEvidence(
            targetHeartRate: integer(payload["target_bpm"]),
            durationSeconds: integer(payload["duration_min"]).map { $0 * 60 },
            decisionIntervalSeconds: integer(payload["decision_interval_s"]),
            adaptiveStepEnabled: bool(payload["adaptive_step_enabled"]),
            maximumStepKilometresPerHour: double(payload["max_step_kmh"]),
            heartRateZoneUpperBounds: integerArray(payload["zone_bounds"]),
            cooldownTargetHeartRate: integer(payload["cooldown_target_bpm"]),
            cooldownMinimumSpeedKilometresPerHour: double(payload["cooldown_min_speed_kmh"]),
            cooldownMaximumSeconds: integer(payload["cooldown_max_minutes"]).map { $0 * 60 },
            telemetrySchemaVersion: telemetrySchemaVersion,
            algorithmVersion: algorithmVersion,
            safetyPolicyVersion: safetyPolicyVersion,
            workoutProtocolVersion: workoutProtocolVersion
        )
    }

    private static func normalizedDecision(_ payload: [String: Any]) -> String {
        switch string(payload["decision"]) {
        case "set": "setSpeed"
        case "hold": "hold"
        case "inertia_hold": "inertiaHold"
        case "limit": "speedLimit"
        case let value?: value
        case nil: "unknown"
        }
    }

    private static func semanticCommand(label: String?) -> String {
        let lower = (label ?? "").lowercased()
        if lower.contains("stop") || lower.contains("standby") { return "stop" }
        if lower.contains("speed") { return "setSpeed" }
        if lower.contains("start") || lower.contains("resume") { return "start" }
        if lower.contains("request") || lower.contains("query") { return "maintenance" }
        return "other"
    }

    private static func unknownCommandOutcome(
        _ kind: TelemetryParityCommandOutcomeKind,
        elapsedMilliseconds: Int64
    ) -> TelemetryParityCommandEvidence {
        TelemetryParityCommandEvidence(
            outcomeKind: kind,
            semanticCommand: nil,
            elapsedMilliseconds: elapsedMilliseconds,
            association: .unknown,
            commandIdentifier: nil,
            attemptIdentifier: nil
        )
    }

    private static func normalizedWalkingPadState(
        speedKilometresPerHour: Double,
        rawState: Int?
    ) -> String {
        if speedKilometresPerHour > 0 { return "moving" }
        if [0, 2, 5, 7, 9].contains(rawState) { return "stopped" }
        return "unknown"
    }

    private static func normalizedStopConclusion(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("confirmed") && !lower.contains("unconfirmed") { return "confirmed" }
        if lower.contains("contradict") { return "contradictory" }
        return "unconfirmed"
    }

    private static func durationMilliseconds(startedAt: Date?, endedAt: Date?) -> Int64? {
        guard let startedAt, let endedAt else { return nil }
        return max(0, Int64((endedAt.timeIntervalSince(startedAt) * 1_000).rounded()))
    }

    private static func date(_ value: Any?) -> Date? {
        guard let value = string(value) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: value) { return parsed }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            if value == "true" { return true }
            if value == "false" { return false }
        }
        return nil
    }

    private static func integerArray(_ value: Any?) -> [Int] {
        (value as? [Any] ?? []).compactMap(integer)
    }
}
