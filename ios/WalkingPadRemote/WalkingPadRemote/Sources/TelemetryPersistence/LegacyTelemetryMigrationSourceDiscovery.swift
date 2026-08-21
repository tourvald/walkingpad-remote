import Foundation
import TelemetryDomain

public enum LegacyTelemetryMigrationSourceDiscovery {
    public static func makeRequest(
        userDefaults: UserDefaults,
        trainingLogsDirectory: URL,
        knownProfileLocalIdentifiers: [String],
        deterministicLegacyFallbackProfileLocalIdentifier: String?,
        maximumRecordsPerBatch: Int = 64
    ) -> LegacyTelemetryMigrationRequest {
        let knownProfiles = Set(
            knownProfileLocalIdentifiers.map(normalizedIdentifier).filter { !$0.isEmpty }
        )
        let fallback = deterministicLegacyFallbackProfileLocalIdentifier
            .map(normalizedIdentifier)
            .flatMap { knownProfiles.contains($0) ? $0 : nil }

        let jsonlSources: [LegacyJSONLSourceDescriptor] = {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: trainingLogsDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return urls.filter { url in
                guard url.pathExtension.lowercased() == "jsonl" else { return false }
                return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile)
                    ?? false
            }.sorted { $0.standardizedFileURL.path < $1.standardizedFileURL.path }
                .map {
                    LegacyJSONLSourceDescriptor(
                        url: $0,
                        deterministicFallbackProfileLocalIdentifier: fallback
                    )
                }
        }()

        var historySources: [LegacyWorkoutHistorySourceDescriptor] = []
        for profile in knownProfiles.sorted() {
            let key = "workout_history_v1_profile_\(profile)"
            guard let representation = userDefaults.data(forKey: key) else { continue }
            historySources.append(
                LegacyWorkoutHistorySourceDescriptor(
                    storageKey: key,
                    representation: representation,
                    exactProfileLocalIdentifier: profile
                )
            )
        }
        if let representation = userDefaults.data(forKey: "workout_history_v1") {
            historySources.append(
                LegacyWorkoutHistorySourceDescriptor(
                    storageKey: "workout_history_v1",
                    representation: representation,
                    exactProfileLocalIdentifier: fallback
                )
            )
        }

        return LegacyTelemetryMigrationRequest(
            jsonlSources: jsonlSources,
            workoutHistorySources: historySources.sorted {
                $0.storageKey < $1.storageKey
            },
            knownProfileLocalIdentifiers: knownProfiles,
            maximumRecordsPerBatch: maximumRecordsPerBatch
        )
    }

    public static func defaultTrainingLogsDirectory() -> URL? {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("TrainingLogs", isDirectory: true)
    }

    private static func normalizedIdentifier(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
