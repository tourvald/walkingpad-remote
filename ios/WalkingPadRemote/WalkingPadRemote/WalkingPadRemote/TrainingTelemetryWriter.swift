import Foundation

enum TrainingLogCsvExportScope: Equatable {
    case all
    case lastCompletedWorkouts(Int)

    var buttonTitle: String {
        switch self {
        case .all:
            return "Все логи"
        case .lastCompletedWorkouts(let count):
            return "Последние \(count) тренировки"
        }
    }

    var missingLogsMessage: String {
        switch self {
        case .all:
            return "Training logs not found yet. Start HR session first."
        case .lastCompletedWorkouts(let count):
            return "Completed training logs not found yet. Need at least \(count) saved workouts or fewer completed ones."
        }
    }

    var fileNameSuffix: String {
        switch self {
        case .all:
            return ""
        case .lastCompletedWorkouts(let count):
            return "_last\(count)"
        }
    }

    var logDescription: String {
        switch self {
        case .all:
            return "all"
        case .lastCompletedWorkouts(let count):
            return "last_\(count)_workouts"
        }
    }
}

enum TrainingTelemetryWriter {
    struct CleanupSummary: Equatable {
        let removedCount: Int
        let skippedCount: Int
        let reclaimedBytes: Int64
    }

    struct SessionLogSummary: Equatable {
        let fileURL: URL
        let startedAt: Date
        let containsSavedWorkout: Bool
        let profileID: String?
        let profileLabel: String?
        let fileSizeBytes: Int64
    }

    struct TrainingLogsInventory: Equatable {
        static let empty = TrainingLogsInventory(
            totalSessionFiles: 0,
            completedWorkoutFiles: 0,
            matchingProfileSessionFiles: 0,
            matchingProfileCompletedWorkoutFiles: 0,
            clearableSessionFiles: 0,
            totalBytes: 0,
            matchingProfileBytes: 0,
            clearableBytes: 0
        )

        let totalSessionFiles: Int
        let completedWorkoutFiles: Int
        let matchingProfileSessionFiles: Int
        let matchingProfileCompletedWorkoutFiles: Int
        let clearableSessionFiles: Int
        let totalBytes: Int64
        let matchingProfileBytes: Int64
        let clearableBytes: Int64
    }

    private struct SessionSummary {
        let values: [String]
    }

    private nonisolated(unsafe) static let iso8601WithFractionalSecondsFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated static let trainingCsvHeaders: [String] = [
        "source_file",
        "ts",
        "installation_id",
        "profile_id",
        "profile_label",
        "session_id",
        "event",
        "phase",
        "session_state",
        "is_hr_running",
        "hr_bpm",
        "hr_last_bpm",
        "target_bpm",
        "target_zone_index",
        "target_zone_lower_bpm",
        "target_zone_upper_bpm",
        "session_peak_bpm",
        "main_avg_bpm",
        "main_peak_bpm",
        "zone1_s",
        "zone2_s",
        "zone3_s",
        "zone4_s",
        "zone5_s",
        "zone4plus_s",
        "cooldown_start_hr_bpm",
        "cooldown_end_hr_bpm",
        "cooldown_peak_hr_bpm",
        "cooldown_target_bpm",
        "cooldown_planned_s",
        "cooldown_elapsed_s",
        "cooldown_target_hit_elapsed_s",
        "cooldown_hr_drop_bpm",
        "cooldown_hr_recovery_bpm_per_min",
        "cooldown_finish_reason",
        "cooldown_timeout_blocker",
        "cooldown_first_min_speed_elapsed_s",
        "cooldown_first_stable_elapsed_s",
        "cooldown_hr_below_target_s",
        "cooldown_min_speed_s",
        "cooldown_target_and_min_speed_s",
        "cooldown_target_and_min_speed_max_streak_s",
        "cooldown_stable_s",
        "cooldown_stable_required_s",
        "cooldown_observed_speed_kmh",
        "cooldown_controller_speed_kmh",
        "cooldown_hr_ok",
        "cooldown_min_speed_ok",
        "cooldown_stable_ok",
        "cooldown_stability_blocker",
        "speed_actual_kmh",
        "speed_target_kmh",
        "speed_device_target_kmh",
        "speed_reported_kmh",
        "speed_reported_app_kmh",
        "speed_delta_kmh",
        "decision",
        "reason",
        "diff_bpm",
        "diff_percent",
        "step_tag",
        "step_kmh",
        "label",
        "char_uuid",
        "write_type",
        "queue_size",
        "delay_s",
        "status",
        "error",
        "controller_units_action",
        "controller_units_motion_path",
        "controller_units_query_requested",
        "controller_units_query_trigger",
        "controller_units_query_age_s",
        "controller_units",
        "controller_units_status",
        "controller_units_checksum_ok",
        "controller_units_fresh",
        "controller_units_age_s",
        "controller_units_freshness_limit_s",
        "controller_units_gate_allowed",
        "controller_units_block_reason",
        "raw_json"
    ]

    nonisolated static let trainingSessionSummaryHeaders: [String] = [
        "source_file",
        "installation_id",
        "profile_id",
        "profile_label",
        "session_id",
        "started_at",
        "ended_at",
        "session_duration_s",
        "session_end_reason",
        "raw_events_count",
        "distance_km",
        "workout_duration_s",
        "avg_speed_kmh",
        "main_target_bpm",
        "cooldown_target_bpm",
        "session_peak_bpm",
        "main_avg_bpm",
        "main_peak_bpm",
        "main_samples",
        "main_below_target_minus_10_s",
        "main_within_plusminus_10_s",
        "main_above_target_plus_10_s",
        "zone1_s",
        "zone2_s",
        "zone3_s",
        "zone4_s",
        "zone5_s",
        "zone4plus_s",
        "cooldown_start_hr_bpm",
        "cooldown_end_hr_bpm",
        "cooldown_peak_hr_bpm",
        "cooldown_final_excess_bpm",
        "cooldown_planned_s",
        "cooldown_elapsed_s",
        "cooldown_target_hit_elapsed_s",
        "cooldown_hr_drop_bpm",
        "cooldown_hr_recovery_bpm_per_min",
        "cooldown_last30s_slope_bpm_per_min",
        "cooldown_last60s_slope_bpm_per_min",
        "cooldown_finish_reason",
        "cooldown_timeout_blocker",
        "cooldown_first_min_speed_elapsed_s",
        "cooldown_first_stable_elapsed_s",
        "cooldown_hr_below_target_s",
        "cooldown_min_speed_s",
        "cooldown_target_and_min_speed_s",
        "cooldown_target_and_min_speed_max_streak_s",
        "cooldown_insufficient"
    ]

    nonisolated static func makeDirectoryURL(
        directoryName: String,
        onError: (String) -> Void
    ) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let dir = base.appendingPathComponent(directoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            onError("Training log dir error: \(error.localizedDescription)")
            return nil
        }
    }

    nonisolated static func pruneJsonlFiles(in directory: URL, maxFiles: Int) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let jsonlFiles = files.filter { $0.pathExtension.lowercased() == "jsonl" }
        guard jsonlFiles.count > maxFiles else { return }

        let sorted = jsonlFiles.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return left < right
        }

        for file in sorted.prefix(max(0, sorted.count - maxFiles)) {
            try? fileManager.removeItem(at: file)
        }
    }

    nonisolated static func cleanupExportedJsonlFiles(
        _ files: [URL],
        keeping protectedFiles: Set<URL> = []
    ) -> CleanupSummary {
        let fileManager = FileManager.default
        let protectedPaths = Set(protectedFiles.map { $0.standardizedFileURL.path })

        var removedCount = 0
        var skippedCount = 0
        var reclaimedBytes: Int64 = 0

        for file in files {
            let normalized = file.standardizedFileURL
            guard normalized.pathExtension.lowercased() == "jsonl" else {
                skippedCount += 1
                continue
            }
            guard !protectedPaths.contains(normalized.path) else {
                skippedCount += 1
                continue
            }
            guard fileManager.fileExists(atPath: normalized.path) else {
                skippedCount += 1
                continue
            }

            let size = Int64((try? normalized.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            do {
                try fileManager.removeItem(at: normalized)
                removedCount += 1
                reclaimedBytes += max(0, size)
            } catch {
                skippedCount += 1
            }
        }

        return CleanupSummary(
            removedCount: removedCount,
            skippedCount: skippedCount,
            reclaimedBytes: reclaimedBytes
        )
    }

    nonisolated static func selectJsonlFilesForExport(
        _ files: [URL],
        scope: TrainingLogCsvExportScope
    ) -> [URL] {
        let summaries = files.compactMap(summarizeJsonlFile)

        switch scope {
        case .all:
            if !summaries.isEmpty {
                return summaries
                    .sorted { $0.startedAt < $1.startedAt }
                    .map(\.fileURL)
            }
            return files.sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return left < right
            }
        case .lastCompletedWorkouts(let limit):
            guard limit > 0 else { return [] }
            return summaries
                .filter(\.containsSavedWorkout)
                .sorted { $0.startedAt < $1.startedAt }
                .suffix(limit)
                .map(\.fileURL)
        }
    }

    nonisolated static func selectCompletedJsonlFilesForExport(
        _ files: [URL],
        scope: TrainingLogCsvExportScope
    ) -> [URL] {
        let completed = files
            .compactMap(summarizeJsonlFile)
            .filter(\.containsSavedWorkout)
            .sorted { $0.startedAt < $1.startedAt }

        switch scope {
        case .all:
            return completed.map(\.fileURL)
        case .lastCompletedWorkouts(let limit):
            guard limit > 0 else { return [] }
            return completed.suffix(limit).map(\.fileURL)
        }
    }

    nonisolated static func selectJsonlFilesForClear(
        _ files: [URL],
        matchingProfileID profileID: String?,
        legacyFallbackProfileID: String? = nil,
        keeping protectedFiles: Set<URL> = []
    ) -> [URL] {
        let filtered = filterJsonlFiles(
            files,
            matchingProfileID: profileID,
            legacyFallbackProfileID: legacyFallbackProfileID
        )
        let protectedPaths = Set(protectedFiles.map { $0.standardizedFileURL.path })

        return filtered.filter { file in
            !protectedPaths.contains(file.standardizedFileURL.path)
        }
    }

    nonisolated static func filterJsonlFiles(
        _ files: [URL],
        matchingProfileID profileID: String?,
        legacyFallbackProfileID: String? = nil
    ) -> [URL] {
        guard let profileID, !profileID.isEmpty else {
            return files
        }

        return files.filter { file in
            guard let summary = summarizeJsonlFile(file) else {
                return false
            }

            if let fileProfileID = summary.profileID, !fileProfileID.isEmpty {
                return fileProfileID == profileID
            }

            return legacyFallbackProfileID == profileID
        }
    }

    nonisolated static func trainingLogsInventory(
        _ files: [URL],
        matchingProfileID profileID: String?,
        legacyFallbackProfileID: String? = nil,
        keeping protectedFiles: Set<URL> = []
    ) -> TrainingLogsInventory {
        let summaries = files.compactMap(summarizeJsonlFile)
        let profileFiltered = summaries.filter { summary in
            guard let profileID, !profileID.isEmpty else {
                return true
            }

            if let fileProfileID = summary.profileID, !fileProfileID.isEmpty {
                return fileProfileID == profileID
            }

            return legacyFallbackProfileID == profileID
        }
        let clearable = selectJsonlFilesForClear(
            files,
            matchingProfileID: profileID,
            legacyFallbackProfileID: legacyFallbackProfileID,
            keeping: protectedFiles
        )
        let clearablePaths = Set(clearable.map { $0.standardizedFileURL.path })
        let clearableBytes = profileFiltered.reduce(Int64(0)) { partial, summary in
            guard clearablePaths.contains(summary.fileURL.standardizedFileURL.path) else {
                return partial
            }
            return partial + summary.fileSizeBytes
        }

        return TrainingLogsInventory(
            totalSessionFiles: summaries.count,
            completedWorkoutFiles: summaries.filter(\.containsSavedWorkout).count,
            matchingProfileSessionFiles: profileFiltered.count,
            matchingProfileCompletedWorkoutFiles: profileFiltered.filter(\.containsSavedWorkout).count,
            clearableSessionFiles: clearable.count,
            totalBytes: summaries.reduce(0) { $0 + $1.fileSizeBytes },
            matchingProfileBytes: profileFiltered.reduce(0) { $0 + $1.fileSizeBytes },
            clearableBytes: clearableBytes
        )
    }

    nonisolated static func csvString(_ value: Any?) -> String {
        guard let value else { return "" }
        if let stringValue = value as? String { return stringValue }

        if let numberValue = value as? NSNumber {
            if CFGetTypeID(numberValue) == CFBooleanGetTypeID() {
                return numberValue.boolValue ? "true" : "false"
            }
            return numberValue.stringValue
        }

        if let boolValue = value as? Bool { return boolValue ? "true" : "false" }
        if let arrayValue = value as? [Any] { return jsonString(arrayValue) }
        if let dictValue = value as? [String: Any] { return jsonString(dictValue) }
        return String(describing: value)
    }

    private nonisolated static func fileSizeBytes(for file: URL) -> Int64 {
        Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    nonisolated static func zoneSeconds(from payload: [String: Any]) -> [Int] {
        guard let raw = payload["zone_seconds"] else { return [0, 0, 0, 0, 0] }

        let values: [Int]
        if let ints = raw as? [Int] {
            values = ints
        } else if let numbers = raw as? [NSNumber] {
            values = numbers.map(\.intValue)
        } else if let anyArray = raw as? [Any] {
            values = anyArray.map {
                if let intValue = $0 as? Int { return intValue }
                if let numberValue = $0 as? NSNumber { return numberValue.intValue }
                if let stringValue = $0 as? String, let parsed = Int(stringValue) { return parsed }
                return 0
            }
        } else {
            values = []
        }

        var out = Array(values.prefix(5))
        while out.count < 5 {
            out.append(0)
        }
        return out
    }

    nonisolated static func csvEscape(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        if escaped.contains(",") || escaped.contains("\n") || escaped.contains("\"") {
            return "\"\(escaped)\""
        }
        return escaped
    }

    nonisolated static func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return text
    }

    nonisolated static func loadJsonlPayloads(from file: URL) -> [[String: Any]] {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else {
            return []
        }

        var payloads: [[String: Any]] = []
        payloads.reserveCapacity(256)

        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let payload = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
                continue
            }
            payloads.append(payload)
        }

        return payloads
    }

    nonisolated static func summarizeJsonlFile(_ file: URL) -> SessionLogSummary? {
        let payloads = loadJsonlPayloads(from: file)
        guard !payloads.isEmpty else {
            return nil
        }

        var startedAt: Date? = nil
        var containsSavedWorkout = false
        var profileID: String? = nil
        var profileLabel: String? = nil
        let fileSizeBytes = fileSizeBytes(for: file)

        for payload in payloads {
            if let event = payload["event"] as? String, event == "workout_saved" {
                containsSavedWorkout = true
            }

            if profileID == nil,
               let value = stringValue(payload["profile_id"]),
               !value.isEmpty {
                profileID = value
            }

            if profileLabel == nil,
               let value = stringValue(payload["profile_label"]),
               !value.isEmpty {
                profileLabel = value
            }

            if startedAt == nil,
               let timestamp = payload["ts"] as? String,
               let date = iso8601Date(timestamp) {
                startedAt = date
            }
        }

        let fallbackDate = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        return SessionLogSummary(
            fileURL: file,
            startedAt: startedAt ?? fallbackDate,
            containsSavedWorkout: containsSavedWorkout,
            profileID: profileID,
            profileLabel: profileLabel,
            fileSizeBytes: fileSizeBytes
        )
    }

    nonisolated static func iso8601Date(_ value: String) -> Date? {
        iso8601WithFractionalSecondsFormatter.date(from: value) ?? iso8601Formatter.date(from: value)
    }

    nonisolated static func sessionSummaryRow(sourceFile: String, payloads: [[String: Any]]) -> [String]? {
        guard let summary = buildSessionSummary(sourceFile: sourceFile, payloads: payloads) else {
            return nil
        }
        return summary.values
    }

    private nonisolated static func buildSessionSummary(
        sourceFile: String,
        payloads: [[String: Any]]
    ) -> SessionSummary? {
        guard !payloads.isEmpty else { return nil }

        let sortedPayloads = payloads.sorted {
            let left = iso8601Date(stringValue($0["ts"]) ?? "") ?? .distantPast
            let right = iso8601Date(stringValue($1["ts"]) ?? "") ?? .distantPast
            return left < right
        }

        guard sortedPayloads.contains(where: { stringValue($0["event"]) == "workout_saved" }) else {
            return nil
        }

        let startedAt = iso8601Date(stringValue(sortedPayloads.first?["ts"]) ?? "")
        let endedAt = iso8601Date(stringValue(sortedPayloads.last?["ts"]) ?? "")
        let sessionDurationSeconds = max(0, Int((endedAt ?? .distantPast).timeIntervalSince(startedAt ?? .distantPast)))

        let sessionStartPayload = sortedPayloads.first(where: { stringValue($0["event"]) == "session_start" })
        let sessionEndPayload = sortedPayloads.last(where: { stringValue($0["event"]) == "session_end" })

        let sessionID = stringValue(sessionStartPayload?["session_id"])
            ?? stringValue(sortedPayloads.first?["session_id"])
            ?? sourceFile
        let installationID = stringValue(sessionStartPayload?["installation_id"])
            ?? stringValue(sortedPayloads.first?["installation_id"])
            ?? stringValue(sortedPayloads.last?["installation_id"])
            ?? ""
        let profileID = stringValue(sessionStartPayload?["profile_id"])
            ?? stringValue(sortedPayloads.first?["profile_id"])
            ?? stringValue(sortedPayloads.last?["profile_id"])
            ?? ""
        let profileLabel = stringValue(sessionStartPayload?["profile_label"])
            ?? stringValue(sortedPayloads.first?["profile_label"])
            ?? stringValue(sortedPayloads.last?["profile_label"])
            ?? ""
        let sessionEndReason = stringValue(sessionEndPayload?["reason"]) ?? ""

        let zonePayload = sortedPayloads.last(where: { $0["zone_seconds"] != nil }) ?? sortedPayloads.last
        let zones = zoneSeconds(from: zonePayload ?? [:])

        let distanceKm = lastDoubleValue(forKey: "distance_km", in: sortedPayloads)
        let workoutDurationSeconds = lastIntValue(forKey: "duration_s", in: sortedPayloads)
        let averageSpeedKmh: Double? = {
            guard let distanceKm, let workoutDurationSeconds, workoutDurationSeconds > 0 else { return nil }
            return distanceKm / (Double(workoutDurationSeconds) / 3600.0)
        }()

        let mainTargetBpm = intValue(sessionStartPayload?["target_bpm"])
            ?? lastIntValue(forKey: "target_bpm", in: sortedPayloads)
        let cooldownTargetBpm = lastCooldownTargetBpm(in: sortedPayloads)

        let mainSamples = sortedPayloads.compactMap { payload -> Double? in
            guard stringValue(payload["event"]) == "hr_sample",
                  stringValue(payload["session_state"]) == "main" else {
                return nil
            }
            return doubleValue(payload["hr_bpm"])
        }

        let mainBelowTargetMinus10Seconds: Int
        let mainWithinPlusMinus10Seconds: Int
        let mainAboveTargetPlus10Seconds: Int
        if let mainTargetBpm {
            mainBelowTargetMinus10Seconds = mainSamples.filter { $0 <= Double(mainTargetBpm - 10) }.count
            mainWithinPlusMinus10Seconds = mainSamples.filter {
                $0 > Double(mainTargetBpm - 10) && $0 < Double(mainTargetBpm + 10)
            }.count
            mainAboveTargetPlus10Seconds = mainSamples.filter { $0 >= Double(mainTargetBpm + 10) }.count
        } else {
            mainBelowTargetMinus10Seconds = 0
            mainWithinPlusMinus10Seconds = 0
            mainAboveTargetPlus10Seconds = 0
        }

        let cooldownStates = sortedPayloads.filter { stringValue($0["event"]) == "cooldown_state" }
        let cooldownHrSamples = cooldownStates.compactMap { doubleValue($0["hr_bpm"]) }
        let cooldownLast30Slope = slopePerMinute(values: Array(cooldownHrSamples.suffix(30)))
        let cooldownLast60Slope = slopePerMinute(values: Array(cooldownHrSamples.suffix(60)))

        let cooldownEndHr = lastIntValue(forKey: "cooldown_end_hr_bpm", in: sortedPayloads)
        let cooldownFinalExcessBpm: Int? = {
            guard let cooldownEndHr, let cooldownTargetBpm else { return nil }
            return cooldownEndHr - cooldownTargetBpm
        }()
        let cooldownInsufficient = sortedPayloads.contains { stringValue($0["event"]) == "cooldown_insufficient" }

        let values: [String] = [
            sourceFile,
            installationID,
            profileID,
            profileLabel,
            sessionID,
            startedAt.map(iso8601WithFractionalSecondsFormatter.string(from:)) ?? "",
            endedAt.map(iso8601WithFractionalSecondsFormatter.string(from:)) ?? "",
            String(sessionDurationSeconds),
            sessionEndReason,
            String(sortedPayloads.count),
            csvString(distanceKm),
            csvString(workoutDurationSeconds),
            csvString(averageSpeedKmh),
            csvString(mainTargetBpm),
            csvString(cooldownTargetBpm),
            csvString(lastIntValue(forKey: "session_peak_bpm", in: sortedPayloads)),
            csvString(lastIntValue(forKey: "main_avg_bpm", in: sortedPayloads)),
            csvString(lastIntValue(forKey: "main_peak_bpm", in: sortedPayloads)),
            String(mainSamples.count),
            String(mainBelowTargetMinus10Seconds),
            String(mainWithinPlusMinus10Seconds),
            String(mainAboveTargetPlus10Seconds),
            String(zones[0]),
            String(zones[1]),
            String(zones[2]),
            String(zones[3]),
            String(zones[4]),
            csvString(lastIntValue(forKey: "zone4plus_seconds", in: sortedPayloads)),
            csvString(lastIntValue(forKey: "cooldown_start_hr_bpm", in: sortedPayloads)),
            csvString(cooldownEndHr),
            csvString(lastIntValue(forKey: "cooldown_peak_hr_bpm", in: sortedPayloads)),
            csvString(cooldownFinalExcessBpm),
            csvString(lastIntValue(forKey: "cooldown_planned_s", in: sortedPayloads)),
            csvString(lastIntValue(forKey: "cooldown_elapsed_s", in: sortedPayloads)),
            csvString(lastIntValue(forKey: "cooldown_target_hit_elapsed_s", in: sortedPayloads)),
            csvString(lastIntValue(forKey: "cooldown_hr_drop_bpm", in: sortedPayloads)),
            csvString(lastDoubleValue(forKey: "cooldown_hr_recovery_bpm_per_min", in: sortedPayloads)),
            csvString(cooldownLast30Slope),
            csvString(cooldownLast60Slope),
            csvString(lastMeaningfulValue(forKey: "cooldown_finish_reason", in: sortedPayloads)),
            csvString(lastMeaningfulValue(forKey: "cooldown_timeout_blocker", in: sortedPayloads)),
            csvString(lastIntValue(forKey: "cooldown_first_min_speed_elapsed_s", in: sortedPayloads)),
            csvString(lastIntValue(forKey: "cooldown_first_stable_elapsed_s", in: sortedPayloads)),
            csvString(lastIntValue(forKey: "cooldown_hr_below_target_s", in: sortedPayloads)),
            csvString(lastIntValue(forKey: "cooldown_min_speed_s", in: sortedPayloads)),
            csvString(lastIntValue(forKey: "cooldown_target_and_min_speed_s", in: sortedPayloads)),
            csvString(lastIntValue(forKey: "cooldown_target_and_min_speed_max_streak_s", in: sortedPayloads)),
            cooldownInsufficient ? "true" : "false"
        ]

        return SessionSummary(values: values)
    }

    private nonisolated static func isCooldownPayload(_ payload: [String: Any]) -> Bool {
        if let event = stringValue(payload["event"]), event.hasPrefix("cooldown_") {
            return true
        }
        return stringValue(payload["phase"]) == "cooldown" || stringValue(payload["session_state"]) == "cooldown"
    }

    private nonisolated static func lastCooldownTargetBpm(in payloads: [[String: Any]]) -> Int? {
        if let explicitTarget = lastIntValue(forKey: "cooldown_target_bpm", in: payloads) {
            return explicitTarget
        }

        for payload in payloads.reversed() {
            guard isCooldownPayload(payload),
                  let targetBpm = intValue(payload["target_bpm"]) else {
                continue
            }
            return targetBpm
        }

        return nil
    }

    private nonisolated static func lastMeaningfulValue(
        forKey key: String,
        in payloads: [[String: Any]]
    ) -> Any? {
        for payload in payloads.reversed() {
            guard let value = payload[key] else { continue }
            if let string = value as? String, string.isEmpty {
                continue
            }
            return value
        }
        return nil
    }

    private nonisolated static func lastIntValue(forKey key: String, in payloads: [[String: Any]]) -> Int? {
        payloads.reversed().compactMap { intValue($0[key]) }.first
    }

    private nonisolated static func lastDoubleValue(forKey key: String, in payloads: [[String: Any]]) -> Double? {
        payloads.reversed().compactMap { doubleValue($0[key]) }.first
    }

    private nonisolated static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String {
            if let int = Int(string) { return int }
            if let double = Double(string) { return Int(double) }
        }
        return nil
    }

    private nonisolated static func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let float = value as? Float { return Double(float) }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private nonisolated static func stringValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return String(describing: value)
    }

    private nonisolated static func slopePerMinute(values: [Double]) -> Double? {
        guard values.count >= 2 else { return nil }
        let count = Double(values.count)
        let xMean = (count - 1.0) / 2.0
        let yMean = values.reduce(0, +) / count

        var numerator = 0.0
        var denominator = 0.0

        for (index, value) in values.enumerated() {
            let x = Double(index) - xMean
            let y = value - yMean
            numerator += x * y
            denominator += x * x
        }

        guard denominator > 0 else { return nil }
        return (numerator / denominator) * 60.0
    }

    nonisolated static func csvRow(sourceFile: String, payload: [String: Any]) -> [String] {
        let zoneSeconds = zoneSeconds(from: payload)

        return [
            sourceFile,
            csvString(payload["ts"]),
            csvString(payload["installation_id"]),
            csvString(payload["profile_id"]),
            csvString(payload["profile_label"]),
            csvString(payload["session_id"]),
            csvString(payload["event"]),
            csvString(payload["phase"]),
            csvString(payload["session_state"]),
            csvString(payload["is_hr_running"]),
            csvString(payload["hr_bpm"]),
            csvString(payload["hr_last_bpm"]),
            csvString(payload["target_bpm"]),
            csvString(payload["target_zone_index"]),
            csvString(payload["target_zone_lower_bpm"]),
            csvString(payload["target_zone_upper_bpm"]),
            csvString(payload["session_peak_bpm"]),
            csvString(payload["main_avg_bpm"]),
            csvString(payload["main_peak_bpm"]),
            String(zoneSeconds[0]),
            String(zoneSeconds[1]),
            String(zoneSeconds[2]),
            String(zoneSeconds[3]),
            String(zoneSeconds[4]),
            csvString(payload["zone4plus_seconds"]),
            csvString(payload["cooldown_start_hr_bpm"]),
            csvString(payload["cooldown_end_hr_bpm"]),
            csvString(payload["cooldown_peak_hr_bpm"]),
            csvString(payload["cooldown_target_bpm"]),
            csvString(payload["cooldown_planned_s"]),
            csvString(payload["cooldown_elapsed_s"]),
            csvString(payload["cooldown_target_hit_elapsed_s"]),
            csvString(payload["cooldown_hr_drop_bpm"]),
            csvString(payload["cooldown_hr_recovery_bpm_per_min"]),
            csvString(payload["cooldown_finish_reason"]),
            csvString(payload["cooldown_timeout_blocker"]),
            csvString(payload["cooldown_first_min_speed_elapsed_s"]),
            csvString(payload["cooldown_first_stable_elapsed_s"]),
            csvString(payload["cooldown_hr_below_target_s"]),
            csvString(payload["cooldown_min_speed_s"]),
            csvString(payload["cooldown_target_and_min_speed_s"]),
            csvString(payload["cooldown_target_and_min_speed_max_streak_s"]),
            csvString(payload["stable_s"]),
            csvString(payload["stable_required_s"]),
            csvString(payload["cooldown_observed_speed_kmh"]),
            csvString(payload["cooldown_controller_speed_kmh"]),
            csvString(payload["cooldown_hr_ok"]),
            csvString(payload["cooldown_min_speed_ok"]),
            csvString(payload["cooldown_stable_ok"]),
            csvString(payload["cooldown_stability_blocker"]),
            csvString(payload["speed_actual_kmh"]),
            csvString(payload["speed_target_kmh"]),
            csvString(payload["speed_device_target_kmh"]),
            csvString(payload["speed_reported_kmh"]),
            csvString(payload["speed_reported_app_kmh"]),
            csvString(payload["speed_delta_kmh"]),
            csvString(payload["decision"]),
            csvString(payload["reason"]),
            csvString(payload["diff_bpm"]),
            csvString(payload["diff_percent"]),
            csvString(payload["step_tag"]),
            csvString(payload["step_kmh"]),
            csvString(payload["label"]),
            csvString(payload["char_uuid"]),
            csvString(payload["write_type"]),
            csvString(payload["queue_size"]),
            csvString(payload["delay_s"]),
            csvString(payload["status"]),
            csvString(payload["error"]),
            csvString(payload["controller_units_action"]),
            csvString(payload["controller_units_motion_path"]),
            csvString(payload["controller_units_query_requested"]),
            csvString(payload["controller_units_query_trigger"]),
            csvString(payload["controller_units_query_age_s"]),
            csvString(payload["controller_units"]),
            csvString(payload["controller_units_status"]),
            csvString(payload["controller_units_checksum_ok"]),
            csvString(payload["controller_units_fresh"]),
            csvString(payload["controller_units_age_s"]),
            csvString(payload["controller_units_freshness_limit_s"]),
            csvString(payload["controller_units_gate_allowed"]),
            csvString(payload["controller_units_block_reason"]),
            jsonString(payload)
        ]
    }
}
