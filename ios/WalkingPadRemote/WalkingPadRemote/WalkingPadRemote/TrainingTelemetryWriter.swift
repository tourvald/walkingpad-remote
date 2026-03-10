import Foundation

enum TrainingTelemetryWriter {
    struct CleanupSummary: Equatable {
        let removedCount: Int
        let skippedCount: Int
        let reclaimedBytes: Int64
    }

    static func makeDirectoryURL(
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

    static func pruneJsonlFiles(in directory: URL, maxFiles: Int) {
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

    static func cleanupExportedJsonlFiles(
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

    static func csvString(_ value: Any?) -> String {
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

    static func zoneSeconds(from payload: [String: Any]) -> [Int] {
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

    static func csvEscape(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        if escaped.contains(",") || escaped.contains("\n") || escaped.contains("\"") {
            return "\"\(escaped)\""
        }
        return escaped
    }

    static func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return text
    }
}
