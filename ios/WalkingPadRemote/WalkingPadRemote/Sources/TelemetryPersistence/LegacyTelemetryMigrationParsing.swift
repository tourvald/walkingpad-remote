import CryptoKit
import CoreFoundation
import Foundation

enum LegacyMigrationParsingError: Error, Equatable {
    case unreadableSource
    case invalidWorkoutHistoryArray
    case sourceOffsetOutOfBounds
}

enum LegacyMigrationHashing {
    static func fileSHA256(_ url: URL, chunkSize: Int = 64 * 1_024) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    static func dataSHA256(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    static func deterministicIdentifier(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let parts = bytes.map { String(format: "%02x", $0) }
        return [
            parts[0...3].joined(),
            parts[4...5].joined(),
            parts[6...7].joined(),
            parts[8...9].joined(),
            parts[10...15].joined(),
        ].joined(separator: "-")
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

struct LegacySourceElement: Sendable {
    let data: Data?
    let startOffset: Int64
    let endOffset: Int64
    let recordIndex: Int64
    let structuralWarning: String?
}

final class LegacyJSONLLineReader {
    private let handle: FileHandle
    private let chunkSize: Int
    private let maximumLineBytes: Int
    private var buffer = Data()
    private var bufferStartOffset: Int64
    private var nextRecordIndex: Int64
    private var reachedEOF = false
    private var discardingOversizedLine = false

    init(
        url: URL,
        startingAt byteOffset: Int64,
        nextRecordIndex: Int64,
        chunkSize: Int = 64 * 1_024,
        maximumLineBytes: Int = 1 * 1_024 * 1_024
    ) throws {
        guard byteOffset >= 0 else {
            throw LegacyMigrationParsingError.sourceOffsetOutOfBounds
        }
        handle = try FileHandle(forReadingFrom: url)
        try handle.seek(toOffset: UInt64(byteOffset))
        bufferStartOffset = byteOffset
        self.nextRecordIndex = nextRecordIndex
        self.chunkSize = max(1, chunkSize)
        self.maximumLineBytes = max(1, maximumLineBytes)
    }

    deinit {
        try? handle.close()
    }

    func next() throws -> LegacySourceElement? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0a) {
                let consumedCount = buffer.distance(
                    from: buffer.startIndex,
                    to: buffer.index(after: newline)
                )
                let start = bufferStartOffset
                let end = start + Int64(consumedCount)
                let rawLine = Data(buffer[..<newline])
                buffer.removeFirst(consumedCount)
                bufferStartOffset = end
                nextRecordIndex += 1

                if discardingOversizedLine {
                    discardingOversizedLine = false
                    return LegacySourceElement(
                        data: nil,
                        startOffset: start,
                        endOffset: end,
                        recordIndex: nextRecordIndex,
                        structuralWarning: "line-too-large"
                    )
                }
                return element(
                    rawLine,
                    start: start,
                    end: end,
                    recordIndex: nextRecordIndex
                )
            }

            if reachedEOF {
                guard !buffer.isEmpty || discardingOversizedLine else { return nil }
                let start = bufferStartOffset
                let end = start + Int64(buffer.count)
                let rawLine = buffer
                buffer.removeAll(keepingCapacity: false)
                bufferStartOffset = end
                nextRecordIndex += 1
                if discardingOversizedLine {
                    discardingOversizedLine = false
                    return LegacySourceElement(
                        data: nil,
                        startOffset: start,
                        endOffset: end,
                        recordIndex: nextRecordIndex,
                        structuralWarning: "line-too-large"
                    )
                }
                return element(
                    rawLine,
                    start: start,
                    end: end,
                    recordIndex: nextRecordIndex
                )
            }

            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                reachedEOF = true
                continue
            }
            if discardingOversizedLine {
                if let newline = chunk.firstIndex(of: 0x0a) {
                    let suffixStart = chunk.index(after: newline)
                    bufferStartOffset += Int64(chunk.distance(
                        from: chunk.startIndex,
                        to: suffixStart
                    ))
                    buffer.append(contentsOf: chunk[suffixStart...])
                    nextRecordIndex += 1
                    discardingOversizedLine = false
                    return LegacySourceElement(
                        data: nil,
                        startOffset: bufferStartOffset,
                        endOffset: bufferStartOffset,
                        recordIndex: nextRecordIndex,
                        structuralWarning: "line-too-large"
                    )
                }
                bufferStartOffset += Int64(chunk.count)
                continue
            }
            buffer.append(chunk)
            if buffer.count > maximumLineBytes, buffer.firstIndex(of: 0x0a) == nil {
                bufferStartOffset += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                discardingOversizedLine = true
            }
        }
    }

    private func element(
        _ rawLine: Data,
        start: Int64,
        end: Int64,
        recordIndex: Int64
    ) -> LegacySourceElement {
        var line = rawLine
        if line.last == 0x0d {
            line.removeLast()
        }
        return LegacySourceElement(
            data: line.isEmpty ? nil : line,
            startOffset: start,
            endOffset: end,
            recordIndex: recordIndex,
            structuralWarning: nil
        )
    }
}

struct LegacyJSONArrayElementReader {
    private let data: Data
    private var cursor: Int
    private var nextRecordIndex: Int64
    private var opened = false

    init(data: Data, startingAt byteOffset: Int64, nextRecordIndex: Int64) throws {
        guard byteOffset >= 0, byteOffset <= data.count else {
            throw LegacyMigrationParsingError.sourceOffsetOutOfBounds
        }
        self.data = data
        cursor = Int(byteOffset)
        self.nextRecordIndex = nextRecordIndex
        opened = byteOffset > 0
    }

    mutating func next() throws -> LegacySourceElement? {
        if !opened {
            skipWhitespace()
            guard cursor < data.count, data[cursor] == 0x5b else {
                throw LegacyMigrationParsingError.invalidWorkoutHistoryArray
            }
            cursor += 1
            opened = true
        }
        skipSeparators()
        guard cursor < data.count else {
            throw LegacyMigrationParsingError.invalidWorkoutHistoryArray
        }
        if data[cursor] == 0x5d {
            cursor += 1
            skipWhitespace()
            guard cursor == data.count else {
                throw LegacyMigrationParsingError.invalidWorkoutHistoryArray
            }
            return nil
        }

        let start = cursor
        var depth = 0
        var isInString = false
        var isEscaped = false
        while cursor < data.count {
            let byte = data[cursor]
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if byte == 0x5c {
                    isEscaped = true
                } else if byte == 0x22 {
                    isInString = false
                }
            } else {
                switch byte {
                case 0x22:
                    isInString = true
                case 0x7b, 0x5b:
                    depth += 1
                case 0x7d:
                    depth -= 1
                case 0x5d:
                    if depth == 0 {
                        return makeElement(start: start, end: cursor)
                    }
                    depth -= 1
                case 0x2c where depth == 0:
                    return makeElement(start: start, end: cursor)
                default:
                    break
                }
            }
            cursor += 1
        }
        return makeElement(start: start, end: cursor)
    }

    private mutating func makeElement(start: Int, end: Int) -> LegacySourceElement {
        let trimmed = data[start..<end].trimmingJSONWhitespace()
        let result = LegacySourceElement(
            data: trimmed.isEmpty ? nil : Data(trimmed),
            startOffset: Int64(start),
            endOffset: Int64(end),
            recordIndex: nextRecordIndex + 1,
            structuralWarning: nil
        )
        nextRecordIndex += 1
        return result
    }

    private mutating func skipWhitespace() {
        while cursor < data.count, data[cursor].isJSONWhitespace {
            cursor += 1
        }
    }

    private mutating func skipSeparators() {
        while cursor < data.count {
            if data[cursor].isJSONWhitespace || data[cursor] == 0x2c {
                cursor += 1
            } else {
                break
            }
        }
    }
}

private extension Data.SubSequence {
    func trimmingJSONWhitespace() -> Data.SubSequence {
        var lower = startIndex
        var upper = endIndex
        while lower < upper, self[lower].isJSONWhitespace {
            lower = index(after: lower)
        }
        while lower < upper {
            let previous = index(before: upper)
            guard self[previous].isJSONWhitespace else { break }
            upper = previous
        }
        return self[lower..<upper]
    }
}

private extension UInt8 {
    var isJSONWhitespace: Bool {
        self == 0x20 || self == 0x09 || self == 0x0a || self == 0x0d
    }
}

struct ParsedLegacyJSONLRecord {
    let canonicalPayloadDigest: String
    let draft: LegacyImportedRecordDraft
}

enum LegacyTelemetryMigrationParser {
    static func canonicalObjectDigest(_ data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data)
        guard JSONSerialization.isValidJSONObject(object) else {
            throw LegacyMigrationParsingError.unreadableSource
        }
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return LegacyMigrationHashing.dataSHA256(canonical)
    }

    static func parseJSONL(
        _ data: Data,
        sourceID: String,
        candidateID: String,
        element: LegacySourceElement,
        knownProfiles: Set<String>,
        deterministicFallbackProfile: String?
    ) throws -> ParsedLegacyJSONLRecord {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LegacyMigrationParsingError.unreadableSource
        }
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let digest = LegacyMigrationHashing.dataSHA256(canonical)
        let event = string(object, keys: ["event"]) ?? "unknown"
        let timestamp = jsonlDate(object["ts"] ?? object["timestamp"])
        let stableSession = stableIdentifier(object, keys: [
            "session_id", "legacy_session_id", "session_uuid",
        ])
        let workoutIdentifier = stableIdentifier(object, keys: ["workout_id"])
        let healthKitIdentifier = uuidIdentifier(object, keys: [
            "healthkit_workout_uuid", "healthkitWorkoutUUID", "healthkit_uuid",
            "workout_uuid",
        ])
        var warnings: [String] = []
        let explicitProfile = stableIdentifier(
            object,
            keys: ["profile_id", "profileId"]
        )?.lowercased()
        let profile: String?
        if let explicitProfile {
            if knownProfiles.contains(explicitProfile) {
                profile = explicitProfile
            } else {
                profile = nil
                warnings.append("unknown-explicit-profile")
            }
        } else if let deterministicFallbackProfile,
                  knownProfiles.contains(deterministicFallbackProfile) {
            profile = deterministicFallbackProfile
            warnings.append("deterministic-pre-profile-ownership-mapping")
        } else {
            profile = nil
            warnings.append("profile-ownership-unknown")
        }

        let heartRate: Int? = event == "hr_sample"
            ? positiveInteger(object, keys: ["hr_bpm", "bpm"], maximum: 300)
            : nil
        let target = positiveInteger(object, keys: ["target_bpm"], maximum: 300)
        let targetZone = nonNegativeInteger(object, keys: ["target_zone_index", "zone_index"])
        let speedEvidence = speedEvidence(object, event: event, warnings: &warnings)
        let desiredSpeed = nonNegativeDouble(
            object,
            keys: ["speed_after_kmh", "speed_target_kmh"]
        )
        let summaryDuration = (event == "workout_saved" || event == "session_end")
            ? positiveInteger(object, keys: ["workout_duration_s", "duration_s"])
            : nil
        let summaryAverageHeartRate = (event == "workout_saved" || event == "session_end")
            ? nonNegativeInteger(object, keys: ["avg_bpm", "main_avg_bpm"])
            : nil
        let ignoredSteps = object["steps"] != nil
        if ignoredSteps {
            warnings.append("legacy-steps-ignored")
        }
        let hasSpecificCausalClaim = stableIdentifier(object, keys: [
            "command_id", "commandID", "attempt_id", "attemptID",
        ]) != nil || bool(object, keys: ["deterministically_correlated"]) == true
        let isCommandEvidence = event.hasPrefix("command_")
            || event == "notify_ftms_control_point"
        let causalAssociation: LegacyCausalAssociation
        if hasSpecificCausalClaim {
            causalAssociation = .unsupportedSpecificClaim
            warnings.append("unsupported-specific-causal-claim")
        } else if isCommandEvidence {
            causalAssociation = .unknown
        } else {
            causalAssociation = .notApplicable
        }
        if timestamp == nil {
            warnings.append("missing-or-invalid-timestamp")
        }

        let sourceItemKey = "jsonl-item:\(sourceID):\(element.recordIndex):\(digest)"
        let importedRecordID = LegacyMigrationHashing.deterministicIdentifier(sourceItemKey)
        let identityUncertain = stableSession == nil
            && workoutIdentifier == nil
            && healthKitIdentifier == nil
        let payload = LegacyImportedRecordPayload(
            eventName: event,
            heartRateBeatsPerMinute: heartRate,
            targetBeatsPerMinute: target,
            targetZoneIndex: targetZone,
            speedEvidence: speedEvidence,
            desiredSpeedKilometresPerHour: desiredSpeed,
            legacySummaryDurationSeconds: summaryDuration,
            legacySummaryAverageHeartRateBeatsPerMinute: summaryAverageHeartRate,
            ignoredStepFieldPresent: ignoredSteps,
            causalAssociation: causalAssociation,
            warnings: warnings.sorted()
        )
        return ParsedLegacyJSONLRecord(
            canonicalPayloadDigest: digest,
            draft: LegacyImportedRecordDraft(
                importedRecordID: importedRecordID,
                sourceItemIdentityKey: sourceItemKey,
                sourceID: sourceID,
                candidateID: candidateID,
                sourceRecordIndex: element.recordIndex,
                sourceByteOffset: element.startOffset,
                eventKind: event,
                occurredAt: timestamp,
                profileLocalIdentifier: profile,
                workoutIdentifier: workoutIdentifier,
                healthKitWorkoutIdentifier: healthKitIdentifier,
                stableLegacySessionIdentifier: stableSession,
                provenanceKey: "legacyJSONL",
                payload: payload,
                identityUncertain: identityUncertain
            )
        )
    }

    static func parseWorkoutHistory(
        _ data: Data,
        sourceID: String,
        element: LegacySourceElement,
        occurrence: Int,
        exactProfile: String?
    ) throws -> (record: LegacyImportedRecordDraft, candidate: LegacyWorkoutCandidateDraft) {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LegacyMigrationParsingError.unreadableSource
        }
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let digest = LegacyMigrationHashing.dataSHA256(canonical)
        let workoutIdentifier = stableIdentifier(object, keys: ["id", "workout_id"])
        let healthKitIdentifier = uuidIdentifier(object, keys: [
            "healthkitWorkoutUUID", "healthkit_workout_uuid", "workout_uuid",
        ])
        let stableSession = stableIdentifier(object, keys: [
            "session_id", "legacy_session_id", "session_uuid",
        ])
        let sourceItemKey = "history-item:\(sourceID):\(digest):\(occurrence)"
        let candidateID = LegacyMigrationHashing.deterministicIdentifier(
            "history-candidate:\(sourceItemKey)"
        )
        let importedRecordID = LegacyMigrationHashing.deterministicIdentifier(
            "history-record:\(sourceItemKey)"
        )
        let endedAt = historyDate(object["date"] ?? object["ended_at"])
        let duration = positiveInteger(object, keys: ["durationSeconds", "duration_s"])
        let target = positiveInteger(object, keys: ["targetBpm", "target_bpm"], maximum: 300)
        let averageHeartRate = nonNegativeInteger(object, keys: ["avgBpm", "avg_bpm"])
        let averageSpeed = nonNegativeDouble(object, keys: ["avgSpeedKmh", "avg_speed_kmh"])
        let zones = optionalNonNegativeIntegerArray(
            object["zoneSeconds"] ?? object["zone_seconds"],
            expectedCount: 5
        )
        var warnings: [String] = ["legacy-summary-not-native-evidence"]
        if workoutIdentifier == nil, healthKitIdentifier == nil, stableSession == nil {
            warnings.append("stable-identity-missing")
        }
        if exactProfile == nil {
            warnings.append("profile-ownership-unknown")
        }
        let speedEvidence = averageSpeed.map {
            LegacyImportedSpeedEvidence.legacyEstimated(
                kilometresPerHour: $0,
                field: "avgSpeedKmh"
            )
        }
        let payload = LegacyImportedRecordPayload(
            eventName: "workout_history_summary",
            heartRateBeatsPerMinute: averageHeartRate,
            targetBeatsPerMinute: target,
            targetZoneIndex: nil,
            speedEvidence: speedEvidence,
            desiredSpeedKilometresPerHour: nil,
            legacySummaryDurationSeconds: duration,
            legacySummaryAverageHeartRateBeatsPerMinute: averageHeartRate,
            ignoredStepFieldPresent: false,
            causalAssociation: .notApplicable,
            warnings: warnings.sorted()
        )
        let identityUncertain = workoutIdentifier == nil
            && healthKitIdentifier == nil
            && stableSession == nil
        let summary = LegacyWorkoutCandidateSummary(
            timestampDerivedDurationMicroseconds: nil,
            legacySummaryDurationSeconds: duration,
            targetBeatsPerMinute: target,
            timestampDerivedAverageHeartRateBeatsPerMinute: nil,
            legacySummaryAverageHeartRateBeatsPerMinute: averageHeartRate,
            legacyEstimatedAverageSpeedKilometresPerHour: averageSpeed,
            timestampDerivedZoneMicroseconds: nil,
            legacySummaryZoneSeconds: zones,
            heartRateCoveredMicroseconds: nil,
            heartRateUncoveredMicroseconds: nil,
            heartRateSampleCount: 0,
            missingTimestampCount: endedAt == nil ? 1 : 0,
            malformedRecordCount: 0,
            ignoredStepFieldCount: 0,
            legacySessionEvidenceComplete: nil,
            warnings: warnings.sorted(),
            conflicts: []
        )
        return (
            LegacyImportedRecordDraft(
                importedRecordID: importedRecordID,
                sourceItemIdentityKey: sourceItemKey,
                sourceID: sourceID,
                candidateID: candidateID,
                sourceRecordIndex: element.recordIndex,
                sourceByteOffset: element.startOffset,
                eventKind: "workout_history_summary",
                occurredAt: endedAt,
                profileLocalIdentifier: exactProfile,
                workoutIdentifier: workoutIdentifier,
                healthKitWorkoutIdentifier: healthKitIdentifier,
                stableLegacySessionIdentifier: stableSession,
                provenanceKey: "workout_history_v1",
                payload: payload,
                identityUncertain: identityUncertain
            ),
            LegacyWorkoutCandidateDraft(
                candidateID: candidateID,
                sourceItemIdentityKey: sourceItemKey,
                sourceID: sourceID,
                origin: .workoutHistory,
                profileLocalIdentifier: exactProfile,
                workoutIdentifier: workoutIdentifier,
                healthKitWorkoutIdentifier: healthKitIdentifier,
                stableLegacySessionIdentifier: stableSession,
                startedAt: nil,
                endedAt: endedAt,
                identityUncertain: identityUncertain || exactProfile == nil,
                possibleDuplicate: identityUncertain,
                summary: summary
            )
        )
    }

    private static func speedEvidence(
        _ object: [String: Any],
        event: String,
        warnings: inout [String]
    ) -> LegacyImportedSpeedEvidence? {
        switch event {
        case "notify_ftms_treadmill_data":
            if let value = nonNegativeDouble(object, keys: ["speed_kmh"]) {
                return .factualDeviceReported(
                    kilometresPerHour: value,
                    source: "ftms-treadmill-data"
                )
            }
        case "notify_fitshow_speed", "notify_fitshow_status":
            if bool(object, keys: ["checksum_ok"]) == true,
               let value = nonNegativeDouble(object, keys: ["speed_kmh"]) {
                return .factualDeviceReported(
                    kilometresPerHour: value,
                    source: "fitshow-checksum-valid-report"
                )
            }
            if let value = nonNegativeDouble(object, keys: ["speed_kmh"]) {
                warnings.append("fitshow-speed-not-factual-without-valid-checksum")
                return .legacyUnknown(
                    value: value,
                    field: "speed_kmh",
                    reason: "checksum-not-proven-valid"
                )
            }
        case "notify_fe01":
            let unitsMetric = string(object, keys: ["controller_units"]) == "metric"
            let unitsFresh = bool(object, keys: ["controller_units_fresh"]) == true
            let checksumValid = bool(object, keys: ["checksum_ok"]) == true
            if unitsMetric, unitsFresh, checksumValid,
               let value = nonNegativeDouble(object, keys: ["speed_kmh"]) {
                return .factualDeviceReported(
                    kilometresPerHour: value,
                    source: "walkingpad-explicit-metric-fresh-checksum-valid-report"
                )
            }
            if let value = nonNegativeDouble(object, keys: ["speed_kmh"]) {
                warnings.append("walkingpad-speed-units-or-quality-unproven")
                return .legacyUnknown(
                    value: value,
                    field: "speed_kmh",
                    reason: "metric-units-and-quality-not-independently-proven"
                )
            }
        default:
            break
        }
        if event == "workout_saved",
           let value = nonNegativeDouble(object, keys: ["avg_speed_kmh"]) {
            warnings.append("legacy-summary-average-speed-kept-estimated")
            return .legacyEstimated(
                kilometresPerHour: value,
                field: "avg_speed_kmh"
            )
        }
        if let value = nonNegativeDouble(object, keys: ["speed_actual_kmh"]) {
            warnings.append("ambiguous-speed-actual-kept-estimated")
            return .legacyEstimated(
                kilometresPerHour: value,
                field: "speed_actual_kmh"
            )
        }
        return nil
    }

    private static func jsonlDate(_ value: Any?) -> Date? {
        if let seconds = double(value), seconds >= 0 {
            return Date(timeIntervalSince1970: seconds)
        }
        guard let raw = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    private static func historyDate(_ value: Any?) -> Date? {
        if let seconds = double(value), seconds >= 0 {
            return seconds > 1_200_000_000
                ? Date(timeIntervalSince1970: seconds)
                : Date(timeIntervalSinceReferenceDate: seconds)
        }
        return jsonlDate(value)
    }

    private static func stableIdentifier(
        _ object: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            guard let value = object[key] else { continue }
            let raw: String?
            if let string = value as? String {
                raw = string
            } else if let uuid = value as? UUID {
                raw = uuid.uuidString
            } else {
                raw = nil
            }
            if let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
               !trimmed.isEmpty {
                return UUID(uuidString: trimmed)?.uuidString.lowercased() ?? trimmed
            }
        }
        return nil
    }

    private static func uuidIdentifier(
        _ object: [String: Any],
        keys: [String]
    ) -> String? {
        guard let value = stableIdentifier(object, keys: keys),
              let uuid = UUID(uuidString: value) else { return nil }
        return uuid.uuidString.lowercased()
    }

    private static func string(_ object: [String: Any], keys: [String]) -> String? {
        keys.lazy.compactMap { object[$0] as? String }.first
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let result = number.doubleValue
            return result.isFinite ? result : nil
        }
        if let string = value as? String, let result = Double(string), result.isFinite {
            return result
        }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let numeric = double(value), numeric.rounded() == numeric,
              numeric >= Double(Int.min), numeric <= Double(Int.max) else { return nil }
        return Int(numeric)
    }

    private static func positiveInteger(
        _ object: [String: Any],
        keys: [String],
        maximum: Int = Int.max
    ) -> Int? {
        guard let value = keys.lazy.compactMap({ integer(object[$0]) }).first,
              value > 0, value <= maximum else { return nil }
        return value
    }

    private static func nonNegativeInteger(
        _ object: [String: Any],
        keys: [String]
    ) -> Int? {
        guard let value = keys.lazy.compactMap({ integer(object[$0]) }).first,
              value >= 0 else { return nil }
        return value
    }

    private static func nonNegativeDouble(
        _ object: [String: Any],
        keys: [String]
    ) -> Double? {
        guard let value = keys.lazy.compactMap({ double(object[$0]) }).first,
              value >= 0 else { return nil }
        return value
    }

    private static func bool(_ object: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = object[key] as? Bool { return value }
            if let value = object[key] as? NSNumber { return value.boolValue }
            if let value = object[key] as? String {
                if value == "true" { return true }
                if value == "false" { return false }
            }
        }
        return nil
    }

    private static func optionalNonNegativeIntegerArray(
        _ value: Any?,
        expectedCount: Int
    ) -> [Int?]? {
        guard let raw = value as? [Any] else { return nil }
        var result = raw.prefix(expectedCount).map { element -> Int? in
            guard let parsed = integer(element), parsed >= 0 else { return nil }
            return parsed
        }
        while result.count < expectedCount {
            result.append(nil)
        }
        return result
    }
}

struct LegacyJSONLAggregateState: Codable, Hashable, Sendable {
    private static let maximumDistinctValues = 8
    private static let freshnessMicroseconds: Int64 = 7_000_000

    var sessionIdentifiers: [String] = []
    var workoutIdentifiers: [String] = []
    var healthKitIdentifiers: [String] = []
    var profileIdentifiers: [String] = []
    var firstTimestamp: Date?
    var lastTimestamp: Date?
    var sessionStartedAt: Date?
    var sessionEndedAt: Date?
    var targetValues: [Int] = []
    var averageHeartRateValues: [Int] = []
    var durationSummaryValues: [Int] = []
    var averageSpeedValues: [Double] = []
    var zoneMicroseconds: [Int64] = Array(repeating: 0, count: 5)
    var heartRateCoveredMicroseconds: Int64 = 0
    var heartRateUncoveredMicroseconds: Int64 = 0
    var heartRateWeightedBeatMicroseconds: Int64 = 0
    var heartRateSampleCount: Int = 0
    var missingTimestampCount: Int = 0
    var malformedRecordCount: Int = 0
    var ignoredStepFieldCount: Int = 0
    var sawWorkoutSaved = false
    var warnings: [String] = []
    var permitsDeterministicPreProfileFallback = true
    var lastHeartRateTimestamp: Date?
    var lastHeartRateBeatsPerMinute: Int?
    var lastHeartRateZoneIndex: Int?
    var gapBeforeNextHeartRate = false

    mutating func recordMalformed(_ code: String) {
        malformedRecordCount += 1
        Self.appendDistinct(code, to: &warnings)
        gapBeforeNextHeartRate = true
    }

    mutating func observe(_ record: LegacyImportedRecordDraft) {
        Self.appendDistinct(record.stableLegacySessionIdentifier, to: &sessionIdentifiers)
        if record.eventKind == "workout_saved" {
            Self.appendDistinct(record.workoutIdentifier, to: &workoutIdentifiers)
        }
        Self.appendDistinct(record.healthKitWorkoutIdentifier, to: &healthKitIdentifiers)
        Self.appendDistinct(record.profileLocalIdentifier, to: &profileIdentifiers)
        for warning in record.payload.warnings {
            Self.appendDistinct(warning, to: &warnings)
        }
        if record.payload.warnings.contains("unknown-explicit-profile") {
            permitsDeterministicPreProfileFallback = false
        }
        if record.payload.ignoredStepFieldPresent {
            ignoredStepFieldCount += 1
        }
        if record.eventKind == "workout_saved" {
            sawWorkoutSaved = true
        }
        guard let occurredAt = record.occurredAt else {
            missingTimestampCount += 1
            if record.payload.heartRateBeatsPerMinute != nil {
                gapBeforeNextHeartRate = true
            }
            observeSummaryValues(record)
            return
        }
        firstTimestamp = minDate(firstTimestamp, occurredAt)
        lastTimestamp = maxDate(lastTimestamp, occurredAt)
        if record.eventKind == "session_start" {
            sessionStartedAt = minDate(sessionStartedAt, occurredAt)
        }
        if record.eventKind == "session_end" {
            integrateFinalHeartRate(until: occurredAt)
            sessionEndedAt = maxDate(sessionEndedAt, occurredAt)
        }
        if record.eventKind == "hr_sample",
           let beatsPerMinute = record.payload.heartRateBeatsPerMinute {
            observeHeartRate(
                at: occurredAt,
                beatsPerMinute: beatsPerMinute,
                zoneIndex: record.payload.targetZoneIndex
            )
        }
        observeSummaryValues(record)
    }

    func candidate(
        sourceID: String,
        candidateID: String,
        deterministicFallbackProfile: String?
    ) -> LegacyWorkoutCandidateDraft {
        let stableSession = single(sessionIdentifiers)
        let workout = single(workoutIdentifiers)
        let healthKit = single(healthKitIdentifiers)
        let exactProfile = permitsDeterministicPreProfileFallback
            ? (single(profileIdentifiers) ?? deterministicFallbackProfile)
            : nil
        let startedAt = sessionStartedAt ?? firstTimestamp
        let endedAt = sessionEndedAt ?? lastTimestamp
        let durationMicroseconds: Int64? = {
            guard let startedAt, let endedAt, endedAt >= startedAt else { return nil }
            return Int64((endedAt.timeIntervalSince(startedAt) * 1_000_000).rounded())
        }()
        let timestampDerivedAverageHeartRate: Double? = heartRateCoveredMicroseconds > 0
            ? Double(heartRateWeightedBeatMicroseconds)
                / Double(heartRateCoveredMicroseconds)
            : nil
        var finalWarnings = warnings
        if sessionStartedAt == nil, startedAt != nil {
            if !finalWarnings.contains("duration-started-at-first-timestamp") {
                finalWarnings.append("duration-started-at-first-timestamp")
            }
        }
        if sessionEndedAt == nil, endedAt != nil {
            if !finalWarnings.contains("duration-ended-at-last-timestamp") {
                finalWarnings.append("duration-ended-at-last-timestamp")
            }
        }
        if sessionStartedAt == nil {
            finalWarnings.append("legacy-session-start-missing")
        }
        if sessionEndedAt == nil {
            finalWarnings.append("legacy-session-end-missing")
        }
        if !sawWorkoutSaved {
            finalWarnings.append("legacy-workout-saved-missing")
        }
        if malformedRecordCount > 0 {
            finalWarnings.append("legacy-records-malformed")
        }
        if missingTimestampCount > 0 {
            finalWarnings.append("legacy-timestamps-missing")
        }
        if sessionIdentifiers.count > 1 {
            if !finalWarnings.contains("conflicting-stable-session-identifiers") {
                finalWarnings.append("conflicting-stable-session-identifiers")
            }
        }
        if workoutIdentifiers.count > 1 {
            if !finalWarnings.contains("conflicting-workout-identifiers") {
                finalWarnings.append("conflicting-workout-identifiers")
            }
        }
        if healthKitIdentifiers.count > 1 {
            if !finalWarnings.contains("conflicting-healthkit-identifiers") {
                finalWarnings.append("conflicting-healthkit-identifiers")
            }
        }
        if profileIdentifiers.count > 1 {
            if !finalWarnings.contains("conflicting-profile-identifiers") {
                finalWarnings.append("conflicting-profile-identifiers")
            }
        }
        let summary = LegacyWorkoutCandidateSummary(
            timestampDerivedDurationMicroseconds: durationMicroseconds,
            legacySummaryDurationSeconds: single(durationSummaryValues),
            targetBeatsPerMinute: single(targetValues),
            timestampDerivedAverageHeartRateBeatsPerMinute:
                timestampDerivedAverageHeartRate,
            legacySummaryAverageHeartRateBeatsPerMinute:
                single(averageHeartRateValues),
            legacyEstimatedAverageSpeedKilometresPerHour: single(averageSpeedValues),
            timestampDerivedZoneMicroseconds: zoneMicroseconds.map(Optional.some),
            legacySummaryZoneSeconds: nil,
            heartRateCoveredMicroseconds: heartRateSampleCount > 0
                ? heartRateCoveredMicroseconds : nil,
            heartRateUncoveredMicroseconds: heartRateSampleCount > 0
                ? heartRateUncoveredMicroseconds : nil,
            heartRateSampleCount: heartRateSampleCount,
            missingTimestampCount: missingTimestampCount,
            malformedRecordCount: malformedRecordCount,
            ignoredStepFieldCount: ignoredStepFieldCount,
            legacySessionEvidenceComplete: sessionStartedAt != nil
                && sessionEndedAt != nil
                && sawWorkoutSaved
                && malformedRecordCount == 0
                && missingTimestampCount == 0,
            warnings: finalWarnings.sorted(),
            conflicts: summaryConflicts()
        )
        let stableIdentityExists = workout != nil || healthKit != nil || stableSession != nil
        let identityConflict = sessionIdentifiers.count > 1
            || workoutIdentifiers.count > 1
            || healthKitIdentifiers.count > 1
            || profileIdentifiers.count > 1
        return LegacyWorkoutCandidateDraft(
            candidateID: candidateID,
            sourceItemIdentityKey: "jsonl-candidate:\(sourceID)",
            sourceID: sourceID,
            origin: .jsonl,
            profileLocalIdentifier: identityConflict ? nil : exactProfile,
            workoutIdentifier: identityConflict ? nil : workout,
            healthKitWorkoutIdentifier: identityConflict ? nil : healthKit,
            stableLegacySessionIdentifier: identityConflict ? nil : stableSession,
            startedAt: startedAt,
            endedAt: endedAt,
            identityUncertain: identityConflict || !stableIdentityExists || exactProfile == nil,
            possibleDuplicate: !stableIdentityExists,
            summary: summary
        )
    }

    private mutating func observeHeartRate(
        at timestamp: Date,
        beatsPerMinute: Int,
        zoneIndex: Int?
    ) {
        heartRateSampleCount += 1
        if let previous = lastHeartRateTimestamp {
            let delta = Int64((timestamp.timeIntervalSince(previous) * 1_000_000).rounded())
            if delta < 0 {
                Self.appendDistinct("heart-rate-timestamp-out-of-order", to: &warnings)
                gapBeforeNextHeartRate = true
                return
            } else if gapBeforeNextHeartRate {
                heartRateUncoveredMicroseconds = saturatedAdd(
                    heartRateUncoveredMicroseconds,
                    delta
                )
            } else {
                let covered = min(delta, Self.freshnessMicroseconds)
                heartRateCoveredMicroseconds = saturatedAdd(
                    heartRateCoveredMicroseconds,
                    covered
                )
                if let previousBeatsPerMinute = lastHeartRateBeatsPerMinute {
                    heartRateWeightedBeatMicroseconds = saturatedAdd(
                        heartRateWeightedBeatMicroseconds,
                        saturatedMultiply(Int64(previousBeatsPerMinute), covered)
                    )
                }
                if let previousZone = lastHeartRateZoneIndex,
                   (1...5).contains(previousZone) {
                    zoneMicroseconds[previousZone - 1] = saturatedAdd(
                        zoneMicroseconds[previousZone - 1],
                        covered
                    )
                }
                heartRateUncoveredMicroseconds = saturatedAdd(
                    heartRateUncoveredMicroseconds,
                    max(0, delta - covered)
                )
            }
        }
        lastHeartRateTimestamp = timestamp
        lastHeartRateBeatsPerMinute = beatsPerMinute
        lastHeartRateZoneIndex = zoneIndex
        gapBeforeNextHeartRate = false
    }

    private mutating func integrateFinalHeartRate(until timestamp: Date) {
        guard let previous = lastHeartRateTimestamp else { return }
        let delta = Int64((timestamp.timeIntervalSince(previous) * 1_000_000).rounded())
        guard delta >= 0 else { return }
        if gapBeforeNextHeartRate {
            heartRateUncoveredMicroseconds = saturatedAdd(
                heartRateUncoveredMicroseconds,
                delta
            )
        } else {
            let covered = min(delta, Self.freshnessMicroseconds)
            heartRateCoveredMicroseconds = saturatedAdd(
                heartRateCoveredMicroseconds,
                covered
            )
            if let beatsPerMinute = lastHeartRateBeatsPerMinute {
                heartRateWeightedBeatMicroseconds = saturatedAdd(
                    heartRateWeightedBeatMicroseconds,
                    saturatedMultiply(Int64(beatsPerMinute), covered)
                )
            }
            if let zone = lastHeartRateZoneIndex, (1...5).contains(zone) {
                zoneMicroseconds[zone - 1] = saturatedAdd(
                    zoneMicroseconds[zone - 1],
                    covered
                )
            }
            heartRateUncoveredMicroseconds = saturatedAdd(
                heartRateUncoveredMicroseconds,
                max(0, delta - covered)
            )
        }
        lastHeartRateTimestamp = nil
        lastHeartRateBeatsPerMinute = nil
        lastHeartRateZoneIndex = nil
    }

    private mutating func observeSummaryValues(_ record: LegacyImportedRecordDraft) {
        guard record.eventKind == "session_start"
            || record.eventKind == "workout_saved"
            || record.eventKind == "session_end" else {
            return
        }
        if let target = record.payload.targetBeatsPerMinute {
            Self.appendDistinct(target, to: &targetValues)
        }
        if let duration = record.payload.legacySummaryDurationSeconds {
            Self.appendDistinct(duration, to: &durationSummaryValues)
        }
        if let average = record.payload.legacySummaryAverageHeartRateBeatsPerMinute {
            Self.appendDistinct(average, to: &averageHeartRateValues)
        }
        if case let .legacyEstimated(speed, field)? = record.payload.speedEvidence,
           field == "speed_actual_kmh" || field == "avg_speed_kmh" {
            Self.appendDistinct(speed, to: &averageSpeedValues)
        }
    }

    private func summaryConflicts() -> [LegacySummaryConflict] {
        var result: [LegacySummaryConflict] = []
        if targetValues.count > 1 {
            result.append(
                LegacySummaryConflict(
                    field: "target_bpm",
                    preferredProvenance: "legacy-jsonl-timestamped-event",
                    observedProvenances: targetValues.map { "legacy-jsonl:\($0)" }
                )
            )
        }
        if averageHeartRateValues.count > 1 {
            result.append(
                LegacySummaryConflict(
                    field: "average_hr_bpm",
                    preferredProvenance: "legacy-jsonl-timestamped-event",
                    observedProvenances: averageHeartRateValues.map { "legacy-jsonl:\($0)" }
                )
            )
        }
        return result
    }

    private func single<T>(_ values: [T]) -> T? {
        values.count == 1 ? values[0] : nil
    }

    private func minDate(_ lhs: Date?, _ rhs: Date) -> Date {
        lhs.map { min($0, rhs) } ?? rhs
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date) -> Date {
        lhs.map { max($0, rhs) } ?? rhs
    }

    private static func appendDistinct<T: Equatable>(_ value: T?, to values: inout [T]) {
        guard let value else { return }
        appendDistinct(value, to: &values)
    }

    private static func appendDistinct<T: Equatable>(_ value: T, to values: inout [T]) {
        guard !values.contains(value), values.count < Self.maximumDistinctValues else { return }
        values.append(value)
    }

    private func saturatedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int64.max : result.partialValue
    }

    private func saturatedMultiply(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        return result.overflow ? Int64.max : result.partialValue
    }
}
