import Foundation

enum TrainingRawLogExportScope: Equatable {
    case all
    case lastSessions(Int)

    var buttonTitle: String {
        switch self {
        case .all:
            return "Все raw логи"
        case .lastSessions(let count):
            return "Последние \(count) сессии"
        }
    }

    var missingLogsMessage: String {
        switch self {
        case .all:
            return "Training logs not found yet. Start HR session first."
        case .lastSessions(let count):
            return "Training logs not found yet. Need at least \(count) retained sessions or fewer available ones."
        }
    }

    var fileNameSuffix: String {
        switch self {
        case .all:
            return ""
        case .lastSessions(let count):
            return "_last\(count)"
        }
    }

    var logDescription: String {
        switch self {
        case .all:
            return "all_sessions"
        case .lastSessions(let count):
            return "last_\(count)_sessions"
        }
    }
}

enum TrainingSessionSummaryExportScope: Equatable {
    case allCompleted
    case lastCompletedWorkouts(Int)

    var buttonTitle: String {
        switch self {
        case .allCompleted:
            return "Все тренировки"
        case .lastCompletedWorkouts(let count):
            return "Последние \(count) тренировки"
        }
    }

    var missingLogsMessage: String {
        switch self {
        case .allCompleted:
            return "Completed training logs not found yet. Start and save an HR workout first."
        case .lastCompletedWorkouts(let count):
            return "Completed training logs not found yet. Need at least \(count) saved workouts or fewer completed ones."
        }
    }

    var fileNameSuffix: String {
        switch self {
        case .allCompleted:
            return ""
        case .lastCompletedWorkouts(let count):
            return "_last\(count)"
        }
    }

    var logDescription: String {
        switch self {
        case .allCompleted:
            return "all_completed"
        case .lastCompletedWorkouts(let count):
            return "last_\(count)_completed_workouts"
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
        enum Outcome: String, Equatable {
            case saved
            case failed
            case aborted
            case unknown
        }

        let fileURL: URL
        let startedAt: Date
        let endedAt: Date?
        let sessionID: String?
        let outcome: Outcome
        let sessionEndReason: String?
        let containsSavedWorkout: Bool
        let containsFailedWorkout: Bool
        let hrFailureReason: String?
        let profileID: String?
        let profileLabel: String?
        let fileSizeBytes: Int64
    }

    struct HrFailureLogReport: Equatable {
        let sourceFile: String
        let sessionID: String
        let reason: String
        let start: Date
        let end: Date
        let lines: [String]
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
        "hr_source_mode",
        "hr_bpm",
        "heart_rate_bpm",
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
        "speed_model_kmh",
        "speed_target_kmh",
        "speed_device_target_kmh",
        "speed_reported_kmh",
        "speed_reported_app_kmh",
        "speed_source",
        "speed_has_fresh_report",
        "speed_report_age_s",
        "speed_raw_tenths",
        "app_speed_raw_tenths",
        "speed_unit_pref",
        "command_units",
        "display_units",
        "physical_speed_confidence",
        "physical_semantics",
        "physical_semantics_source",
        "physical_semantics_confirmed_at",
        "physical_semantics_diagnostic_session_id",
        "physical_semantics_raw_tenths",
        "units_source",
        "controller_params_raw_hex",
        "controller_params_checksum_ok",
        "command_raw_tenths",
        "projection_will_send",
        "projection_noop",
        "capped_physical_speed_kmh",
        "capped_noop",
        "command_native_units",
        "command_native_speed",
        "physical_speed_kmh_estimate",
        "native_speed_mph",
        "command_native_speed_mph",
        "requested_physical_delta_kmh",
        "command_physical_delta_kmh_estimate",
        "imperial_hr_control_enabled",
        "manual_stop_acknowledged",
        "reported_native_units",
        "reported_native_speed",
        "distance_raw",
        "distance_raw_units_unknown",
        "distance_unit_pref",
        "distance_native_interpreted_optional",
        "diagnostic_no_load_confirmed",
        "diagnostic_profile",
        "external_distance_m",
        "physical_measured_distance_m",
        "physical_discriminator_expected_kmh_distance_m",
        "physical_discriminator_expected_mph_distance_m",
        "observer_mode",
        "experiment_id",
        "variant",
        "baseline_speed_raw_tenths",
        "baseline_state",
        "freshness_s",
        "confirmed_stop",
        "outcome",
        "writes_count",
        "blocked_writes_count",
        "notifications_count",
        "stop_experiment_phase",
        "stop_experiment_elapsed_s",
        "stop_experiment_duration_s",
        "stop_experiment_command_label",
        "stop_experiment_command_packet_hex",
        "stop_experiment_setup_speed_raw_tenths",
        "stop_experiment_max_speed_raw_tenths",
        "stop_confirmed",
        "stop_confirmed_ever",
        "stop_assist_command",
        "stop_assist_sent",
        "stop_source",
        "stop_report_age_s",
        "stop_reported_speed_kmh",
        "stop_reported_app_speed_kmh",
        "stop_reported_state",
        "stop_has_fresh_report",
        "stop_attempt_id",
        "stop_attempt_started_at",
        "stop_command_sequence",
        "stop_command_label",
        "stop_command_packet_hex",
        "stop_command_source",
        "stop_write_type",
        "stop_queue_size_before",
        "stop_queue_size_after",
        "stop_snapshot_phase",
        "stop_response_age_s",
        "stop_raw_fe01_hex",
        "stop_parsed_state",
        "stop_speed_raw_tenths",
        "stop_app_speed_raw_tenths",
        "stop_native_units",
        "stop_native_speed",
        "stop_physical_speed_kmh_estimate",
        "stop_mode",
        "stop_button",
        "stop_freshness",
        "stop_fe01_before_state",
        "stop_fe01_before_speed_raw_tenths",
        "stop_fe01_before_app_speed_raw_tenths",
        "stop_fe01_before_raw_hex",
        "stop_fe01_before_age_s",
        "stop_fe01_after_state",
        "stop_fe01_after_speed_raw_tenths",
        "stop_fe01_after_app_speed_raw_tenths",
        "stop_fe01_after_raw_hex",
        "stop_fe01_after_age_s",
        "speed_delta_kmh",
        "decision",
        "hr_decision",
        "reason",
        "post_session_observation_s",
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
        "test_run_active",
        "test_phase",
        "test_elapsed_s",
        "test_remaining_s",
        "test_progress",
        "test_target_speed_kmh",
        "test_duration_s",
        "test_peak_speed_kmh",
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
        scope: TrainingRawLogExportScope
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
        case .lastSessions(let limit):
            guard limit > 0 else { return [] }
            return summaries
                .sorted { $0.startedAt < $1.startedAt }
                .suffix(limit)
                .map(\.fileURL)
        }
    }

    nonisolated static func selectCompletedJsonlFilesForExport(
        _ files: [URL],
        scope: TrainingSessionSummaryExportScope
    ) -> [URL] {
        let completed = files
            .compactMap(summarizeJsonlFile)
            .filter(\.containsSavedWorkout)
            .sorted { $0.startedAt < $1.startedAt }

        switch scope {
        case .allCompleted:
            return completed.map(\.fileURL)
        case .lastCompletedWorkouts(let limit):
            guard limit > 0 else { return [] }
            return completed.suffix(limit).map(\.fileURL)
        }
    }

    nonisolated static func hrFailureLogReports(from files: [URL]) -> [HrFailureLogReport] {
        files
            .compactMap(hrFailureLogReport(from:))
            .sorted { $0.end > $1.end }
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
        let payloads = sortedPayloads(loadJsonlPayloads(from: file))
        guard !payloads.isEmpty else {
            return nil
        }

        let fallbackDate = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        let startedAt = payloadTimestamp(payloads.first) ?? fallbackDate
        let endedAt = payloadTimestamp(payloads.last)
        let sessionID = sessionIdentifier(sourceFile: file.lastPathComponent, payloads: payloads)

        let containsSavedWorkout = payloads.contains { payloadEvent($0) == "workout_saved" }
        let sessionEndReason = payloads.reversed().compactMap { payload -> String? in
            guard payloadEvent(payload) == "session_end" else { return nil }
            return stringValue(payload["reason"])
        }.first
        let hrFailureReason = payloads.reversed().compactMap(hrFailureReason(from:)).first
        let containsFailedWorkout = payloads.contains(where: isFailedWorkoutPayload)

        let outcome: SessionLogSummary.Outcome = {
            if containsSavedWorkout {
                return .saved
            }
            if containsFailedWorkout {
                return .failed
            }
            if sessionEndReason != nil {
                return .aborted
            }
            return .unknown
        }()

        let profileID = payloads.compactMap { payload -> String? in
            guard let value = stringValue(payload["profile_id"]), !value.isEmpty else { return nil }
            return value
        }.first
        let profileLabel = payloads.compactMap { payload -> String? in
            guard let value = stringValue(payload["profile_label"]), !value.isEmpty else { return nil }
            return value
        }.first

        return SessionLogSummary(
            fileURL: file,
            startedAt: startedAt,
            endedAt: endedAt,
            sessionID: sessionID,
            outcome: outcome,
            sessionEndReason: sessionEndReason,
            containsSavedWorkout: containsSavedWorkout,
            containsFailedWorkout: containsFailedWorkout,
            hrFailureReason: hrFailureReason,
            profileID: profileID,
            profileLabel: profileLabel,
            fileSizeBytes: fileSizeBytes(for: file)
        )
    }

    private nonisolated static func hrFailureLogReport(from file: URL) -> HrFailureLogReport? {
        let payloads = sortedPayloads(loadJsonlPayloads(from: file))
        guard !payloads.isEmpty else { return nil }

        let failureIndex = payloads.indices.reversed().first(where: {
            payloadEvent(payloads[$0]) == "hr_control_failed" && hrFailureReason(from: payloads[$0]) != nil
        }) ?? payloads.indices.reversed().first(where: {
            payloadEvent(payloads[$0]) == "session_end" && hrFailureReason(from: payloads[$0]) != nil
        })
        let failureCode = failureIndex.flatMap { hrFailureReason(from: payloads[$0]) }

        guard let failureIndex, let failureCode else { return nil }

        let failurePayload = payloads[failureIndex]
        let sessionEndIndex = (failureIndex..<payloads.count).first(where: { payloadEvent(payloads[$0]) == "session_end" })
        let fallbackDate = payloadTimestamp(failurePayload) ?? .distantPast
        let start = hrFailureStartDate(
            failureCode: failureCode,
            payloads: payloads,
            failureIndex: failureIndex,
            fallbackDate: fallbackDate
        )
        let end = sessionEndIndex.flatMap { payloadTimestamp(payloads[$0]) } ?? fallbackDate

        return HrFailureLogReport(
            sourceFile: file.lastPathComponent,
            sessionID: sessionIdentifier(sourceFile: file.lastPathComponent, payloads: payloads),
            reason: hrFailureDisplayReason(failureCode),
            start: start,
            end: end,
            lines: diagnosticLines(
                payloads: payloads,
                failureIndex: failureIndex,
                sessionEndIndex: sessionEndIndex
            )
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

        let sessionStartPayload = sortedPayloads.first(where: { stringValue($0["event"]) == "session_start" })
        let sessionFinishedPayload = sortedPayloads.last(where: { stringValue($0["event"]) == "session_finished" })
        let sessionEndPayload = sortedPayloads.last(where: { stringValue($0["event"]) == "session_end" })
        let logicalEndPayload = sessionFinishedPayload ?? sessionEndPayload ?? sortedPayloads.last

        let startedAt = iso8601Date(stringValue(sessionStartPayload?["ts"]) ?? stringValue(sortedPayloads.first?["ts"]) ?? "")
        let endedAt = iso8601Date(stringValue(logicalEndPayload?["ts"]) ?? "")
        let sessionDurationSeconds = max(0, Int((endedAt ?? .distantPast).timeIntervalSince(startedAt ?? .distantPast)))

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
        let sessionEndReason = stringValue(logicalEndPayload?["reason"]) ?? ""

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

    private nonisolated static func sortedPayloads(_ payloads: [[String: Any]]) -> [[String: Any]] {
        payloads.sorted {
            let left = payloadTimestamp($0) ?? .distantPast
            let right = payloadTimestamp($1) ?? .distantPast
            return left < right
        }
    }

    private nonisolated static func payloadTimestamp(_ payload: [String: Any]?) -> Date? {
        guard let payload, let timestamp = stringValue(payload["ts"]) else { return nil }
        return iso8601Date(timestamp)
    }

    private nonisolated static func payloadEvent(_ payload: [String: Any]) -> String {
        stringValue(payload["event"]) ?? ""
    }

    private nonisolated static func sessionIdentifier(sourceFile: String, payloads: [[String: Any]]) -> String {
        for payload in payloads {
            if let value = stringValue(payload["session_id"]), !value.isEmpty {
                return value
            }
        }
        return sourceFile
    }

    private nonisolated static func normalizedHrFailureReason(_ value: String?) -> String? {
        guard let rawValue = value else {
            return nil
        }

        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else {
            return nil
        }

        switch value {
        case "no_hr_signal", "hr_no_signal":
            return "no_hr_signal"
        case "no_connection", "hr_no_connection":
            return "no_connection"
        default:
            return nil
        }
    }

    private nonisolated static func hrFailureDisplayReason(_ code: String) -> String {
        switch code {
        case "no_hr_signal":
            return "Нет данных пульса"
        case "no_connection":
            return "Нет подключения к дорожке"
        default:
            return code
        }
    }

    private nonisolated static func hrFailureReason(from payload: [String: Any]) -> String? {
        let event = payloadEvent(payload)
        switch event {
        case "hr_control_failed", "session_end":
            return normalizedHrFailureReason(stringValue(payload["reason"]))
        default:
            return nil
        }
    }

    private nonisolated static func isFailedWorkoutPayload(_ payload: [String: Any]) -> Bool {
        let event = payloadEvent(payload)
        if event == "workout_not_saved" {
            return stringValue(payload["reason"]) == "failed"
        }
        return hrFailureReason(from: payload) != nil
    }

    private nonisolated static func hrFailureStartDate(
        failureCode: String,
        payloads: [[String: Any]],
        failureIndex: Int,
        fallbackDate: Date
    ) -> Date {
        if failureCode == "no_hr_signal" {
            for index in stride(from: failureIndex, through: 0, by: -1) {
                let payload = payloads[index]
                if payloadEvent(payload) == "hr_stream_state",
                   let active = payload["active"] as? Bool,
                   !active,
                   let timestamp = payloadTimestamp(payload) {
                    return timestamp
                }
            }

            for index in stride(from: failureIndex, through: 0, by: -1) {
                let payload = payloads[index]
                if payloadEvent(payload) == "hr_sample",
                   let timestamp = payloadTimestamp(payload) {
                    return timestamp
                }
            }
        }

        return fallbackDate
    }

    private nonisolated static func diagnosticLines(
        payloads: [[String: Any]],
        failureIndex: Int,
        sessionEndIndex: Int?
    ) -> [String] {
        var selectedIndices = Array(payloads[..<failureIndex]
            .indices
            .filter { isRelevantFailureDiagnosticEvent(payloadEvent(payloads[$0])) }
            .suffix(4))

        selectedIndices.append(failureIndex)
        if let sessionEndIndex, sessionEndIndex != failureIndex {
            selectedIndices.append(sessionEndIndex)
        }

        return selectedIndices.map { formatDiagnosticLine(payloads[$0]) }
    }

    private nonisolated static func isRelevantFailureDiagnosticEvent(_ event: String) -> Bool {
        switch event {
        case "hr_stream_state", "hr_sample", "command_write", "speed_target_changed":
            return true
        default:
            return false
        }
    }

    private nonisolated static func formatDiagnosticLine(_ payload: [String: Any]) -> String {
        let timestamp = stringValue(payload["ts"]) ?? "unknown_ts"
        let event = payloadEvent(payload)
        var fields: [String] = []

        let keys = [
            "reason",
            "post_session_observation_s",
            "session_state",
            "hr_bpm",
            "hr_last_bpm",
            "last_age_s",
            "missing_s",
            "elapsed_s",
            "speed_target_kmh",
            "speed_actual_kmh",
            "speed_model_kmh",
            "speed_device_target_kmh",
            "speed_reported_kmh",
            "speed_source",
            "speed_report_age_s",
            "label",
            "status"
        ]

        for key in keys {
            guard let value = payload[key] else { continue }
            let string = csvString(value)
            guard !string.isEmpty else { continue }
            fields.append("\(key)=\(string)")
        }

        return "[\(timestamp)] \(event)\(fields.isEmpty ? "" : " · " + fields.joined(separator: " · "))"
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
            csvString(payload["hr_source_mode"]),
            csvString(payload["hr_bpm"]),
            csvString(payload["heart_rate_bpm"] ?? payload["hr_bpm"]),
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
            csvString(payload["speed_model_kmh"]),
            csvString(payload["speed_target_kmh"]),
            csvString(payload["speed_device_target_kmh"]),
            csvString(payload["speed_reported_kmh"]),
            csvString(payload["speed_reported_app_kmh"]),
            csvString(payload["speed_source"]),
            csvString(payload["speed_has_fresh_report"]),
            csvString(payload["speed_report_age_s"]),
            csvString(payload["speed_raw_tenths"]),
            csvString(payload["app_speed_raw_tenths"]),
            csvString(payload["speed_unit_pref"]),
            csvString(payload["command_units"]),
            csvString(payload["display_units"]),
            csvString(payload["physical_speed_confidence"]),
            csvString(payload["physical_semantics"]),
            csvString(payload["physical_semantics_source"]),
            csvString(payload["physical_semantics_confirmed_at"]),
            csvString(payload["physical_semantics_diagnostic_session_id"]),
            csvString(payload["physical_semantics_raw_tenths"]),
            csvString(payload["units_source"]),
            csvString(payload["controller_params_raw_hex"]),
            csvString(payload["controller_params_checksum_ok"]),
            csvString(payload["command_raw_tenths"]),
            csvString(payload["projection_will_send"]),
            csvString(payload["projection_noop"]),
            csvString(payload["capped_physical_speed_kmh"]),
            csvString(payload["capped_noop"]),
            csvString(payload["command_native_units"]),
            csvString(payload["command_native_speed"]),
            csvString(payload["physical_speed_kmh_estimate"]),
            csvString(payload["native_speed_mph"]),
            csvString(payload["command_native_speed_mph"]),
            csvString(payload["requested_physical_delta_kmh"]),
            csvString(payload["command_physical_delta_kmh_estimate"]),
            csvString(payload["imperial_hr_control_enabled"]),
            csvString(payload["manual_stop_acknowledged"]),
            csvString(payload["reported_native_units"]),
            csvString(payload["reported_native_speed"]),
            csvString(payload["distance_raw"]),
            csvString(payload["distance_raw_units_unknown"]),
            csvString(payload["distance_unit_pref"]),
            csvString(payload["distance_native_interpreted_optional"]),
            csvString(payload["diagnostic_no_load_confirmed"]),
            csvString(payload["diagnostic_profile"]),
            csvString(payload["external_distance_m"]),
            csvString(payload["physical_measured_distance_m"]),
            csvString(payload["physical_discriminator_expected_kmh_distance_m"]),
            csvString(payload["physical_discriminator_expected_mph_distance_m"]),
            csvString(payload["observer_mode"]),
            csvString(payload["experiment_id"]),
            csvString(payload["variant"]),
            csvString(payload["baseline_speed_raw_tenths"]),
            csvString(payload["baseline_state"]),
            csvString(payload["freshness_s"]),
            csvString(payload["confirmed_stop"]),
            csvString(payload["outcome"]),
            csvString(payload["writes_count"]),
            csvString(payload["blocked_writes_count"]),
            csvString(payload["notifications_count"]),
            csvString(payload["stop_experiment_phase"]),
            csvString(payload["stop_experiment_elapsed_s"]),
            csvString(payload["stop_experiment_duration_s"]),
            csvString(payload["stop_experiment_command_label"]),
            csvString(payload["stop_experiment_command_packet_hex"]),
            csvString(payload["stop_experiment_setup_speed_raw_tenths"]),
            csvString(payload["stop_experiment_max_speed_raw_tenths"]),
            csvString(payload["stop_confirmed"]),
            csvString(payload["stop_confirmed_ever"]),
            csvString(payload["stop_assist_command"]),
            csvString(payload["stop_assist_sent"]),
            csvString(payload["stop_source"]),
            csvString(payload["stop_report_age_s"]),
            csvString(payload["stop_reported_speed_kmh"]),
            csvString(payload["stop_reported_app_speed_kmh"]),
            csvString(payload["stop_reported_state"]),
            csvString(payload["stop_has_fresh_report"]),
            csvString(payload["stop_attempt_id"]),
            csvString(payload["stop_attempt_started_at"]),
            csvString(payload["stop_command_sequence"]),
            csvString(payload["stop_command_label"]),
            csvString(payload["stop_command_packet_hex"]),
            csvString(payload["stop_command_source"]),
            csvString(payload["stop_write_type"]),
            csvString(payload["stop_queue_size_before"]),
            csvString(payload["stop_queue_size_after"]),
            csvString(payload["stop_snapshot_phase"]),
            csvString(payload["stop_response_age_s"]),
            csvString(payload["stop_raw_fe01_hex"]),
            csvString(payload["stop_parsed_state"]),
            csvString(payload["stop_speed_raw_tenths"]),
            csvString(payload["stop_app_speed_raw_tenths"]),
            csvString(payload["stop_native_units"]),
            csvString(payload["stop_native_speed"]),
            csvString(payload["stop_physical_speed_kmh_estimate"]),
            csvString(payload["stop_mode"]),
            csvString(payload["stop_button"]),
            csvString(payload["stop_freshness"]),
            csvString(payload["stop_fe01_before_state"]),
            csvString(payload["stop_fe01_before_speed_raw_tenths"]),
            csvString(payload["stop_fe01_before_app_speed_raw_tenths"]),
            csvString(payload["stop_fe01_before_raw_hex"]),
            csvString(payload["stop_fe01_before_age_s"]),
            csvString(payload["stop_fe01_after_state"]),
            csvString(payload["stop_fe01_after_speed_raw_tenths"]),
            csvString(payload["stop_fe01_after_app_speed_raw_tenths"]),
            csvString(payload["stop_fe01_after_raw_hex"]),
            csvString(payload["stop_fe01_after_age_s"]),
            csvString(payload["speed_delta_kmh"]),
            csvString(payload["decision"]),
            csvString(payload["hr_decision"] ?? payload["decision"]),
            csvString(payload["reason"]),
            csvString(payload["post_session_observation_s"]),
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
            csvString(payload["test_run_active"]),
            csvString(payload["test_phase"]),
            csvString(payload["test_elapsed_s"]),
            csvString(payload["test_remaining_s"]),
            csvString(payload["test_progress"]),
            csvString(payload["test_target_speed_kmh"]),
            csvString(payload["test_duration_s"]),
            csvString(payload["test_peak_speed_kmh"]),
            jsonString(payload)
        ]
    }
}
