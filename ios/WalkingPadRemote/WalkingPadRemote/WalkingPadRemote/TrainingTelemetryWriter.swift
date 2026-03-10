import Foundation

enum TrainingTelemetryWriter {
    struct CleanupSummary: Equatable {
        let removedCount: Int
        let skippedCount: Int
        let reclaimedBytes: Int64
    }

    nonisolated static let trainingCsvHeaders: [String] = [
        "source_file",
        "ts",
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
        "raw_json"
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

    nonisolated static func csvRow(sourceFile: String, payload: [String: Any]) -> [String] {
        let zoneSeconds = zoneSeconds(from: payload)

        return [
            sourceFile,
            csvString(payload["ts"]),
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
            jsonString(payload)
        ]
    }
}
