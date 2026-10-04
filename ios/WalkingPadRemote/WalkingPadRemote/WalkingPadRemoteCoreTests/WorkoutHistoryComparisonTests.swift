import Foundation
import XCTest

final class WorkoutHistoryComparisonTests: XCTestCase {
    func testActualPresentationMatchesPreviousAlgorithmAndTraversesLinearly() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: package.appendingPathComponent("WalkingPadRemote/WorkoutHistoryRow.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "enum WorkoutHistoryPresentation {"))
        let end = try XCTUnwrap(source.range(of: "\nstruct WorkoutHistoryRow:", range: start.upperBound..<source.endIndex))
        let actual = String(source[start.lowerBound..<end.lowerBound]).replacingOccurrences(
            of: "for entry in loaded.reversed() {", with: "for entry in loaded.reversed() { linearVisits += 1"
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let main = directory.appendingPathComponent("main.swift")
        let executable = directory.appendingPathComponent("Comparison")
        // Keep the accepted predecessor implementation as an output-equivalence oracle.
        // Instrument only test-compiled source; production has no counters or cache.
        let program = #"""
import Foundation
var indexVisits = 0
var candidateVisits = 0
var linearVisits = 0
\#(actual)
enum PreviousPresentation {
    static func value(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    static func duration(_ seconds: Double?) -> String {
        guard let seconds = value(seconds) else { return "—" }
        let rounded = Int(seconds.rounded())
        return String(format: "%d:%02d", rounded / 60, rounded % 60)
    }

    static func heartRate(_ bpm: Double?) -> String {
        value(bpm).map { "\(Int($0.rounded())) bpm" } ?? "—"
    }

    static func speed(_ speed: WorkoutSpeedProjection?) -> String {
        guard let speed, let value = value(speed.kilometresPerHour) else { return "—" }
        return (speed.evidenceKind == .legacyEstimated ? "≈" : "")
            + String(format: "%.1f км/ч", value)
    }

    static func badge(_ entry: WorkoutHistoryProjection) -> String? {
        if entry.origin == .importedLegacy { return "Импортировано" }
        if entry.quality.lifecycleState != "completed"
            || entry.quality.recorderComplete == false
            || entry.quality.possibleDuplicate
            || value(entry.durationSeconds) == nil
            || value(entry.averageHeartRate) == nil
            || entry.averageSpeed.flatMap({ value($0.kilometresPerHour) }) == nil
            || entry.zoneSeconds?.count != 5
            || entry.zoneSeconds?.contains(where: { value($0) == nil }) == true {
            return "Неполные данные"
        }
        return nil
    }

    static func comparison(
        for entry: WorkoutHistoryProjection, loaded: [WorkoutHistoryProjection]
    ) -> String? {
        func eligible(_ candidate: WorkoutHistoryProjection) -> Bool {
            candidateVisits += 1
            return candidate.isMeaningfulWorkout && candidate.origin == .nativeV2
                && candidate.quality.lifecycleState == "completed"
                && !candidate.quality.possibleDuplicate && candidate.targetHeartRate != nil
        }
        guard eligible(entry), let target = entry.targetHeartRate,
              let index = loaded.firstIndex(where: { indexVisits += 1; return $0.id == entry.id }),
              let previous = loaded.dropFirst(index + 1).first(where: {
                  eligible($0) && $0.targetHeartRate == target
              }) else { return nil }
        var parts: [String] = []
        func sign(_ delta: Double) -> String { delta < 0 ? "−" : "+" }
        if let current = value(entry.durationSeconds), let older = value(previous.durationSeconds) {
            let delta = current - older
            parts.append("время \(sign(delta))\(duration(abs(delta)))")
        }
        if let current = value(entry.averageHeartRate), let older = value(previous.averageHeartRate) {
            let delta = current - older
            parts.append("пульс \(sign(delta))\(Int(abs(delta).rounded())) bpm")
        }
        if let current = entry.averageSpeed, let older = previous.averageSpeed,
           current.evidenceKind == .factual, older.evidenceKind == .factual,
           let currentValue = value(current.kilometresPerHour),
           let olderValue = value(older.kilometresPerHour) {
            let delta = currentValue - olderValue
            parts.append("скорость \(sign(delta))\(String(format: "%.1f", abs(delta))) км/ч")
        }
        guard !parts.isEmpty else { return nil }
        return "К предыдущей с целью \(target): " + parts.joined(separator: " · ")
    }
}

func makeProjection(
        analyzed: Bool,
        id: String = "current",
        zones: [Double?]? = nil,
        origin: WorkoutProjectionOrigin = .nativeV2,
        duration: Double? = 100,
        included: Bool = true,
        target: Int? = 125,
        lifecycle: String = "completed",
        duplicate: Bool = false,
        estimated: Bool = false
    ) -> WorkoutHistoryProjection {
        WorkoutHistoryProjection(
            id: id,
            origin: origin,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 200),
            durationSeconds: duration,
            targetHeartRate: target,
            averageHeartRate: analyzed ? 125 : nil,
            averageSpeed: analyzed ? WorkoutSpeedProjection(
                kilometresPerHour: 4.2, evidenceKind: estimated ? .legacyEstimated : .factual, provenance: "decoded-device"
            ) : nil,
            beatsPerMetre: nil,
            zoneSeconds: zones,
            healthKitWorkoutIdentifier: nil,
            telemetrySchemaVersion: "2", appVersion: "1", buildNumber: "1",
            algorithmVersion: "test", analyzerVersion: analyzed ? "test-analyzer" : nil,
            quality: WorkoutProjectionQuality(
                lifecycleState: lifecycle, recorderComplete: true,
                analysisGrade: analyzed ? "high" : nil, identityStatus: "exact",
                possibleDuplicate: duplicate, adaptationEligible: false, includedInStatistics: included,
                provenance: ["telemetry-v2-native"],
                unavailableMetrics: zones == nil ? ["zoneSeconds"] : [], warnings: []
            )
        )
    }


let representative = [
    makeProjection(analyzed: true, id: "current", duration: 120),
    makeProjection(analyzed: true, id: "other", target: 130),
    makeProjection(analyzed: true, id: "trivial", duration: 13),
    makeProjection(analyzed: true, id: "unknown", duration: nil),
    makeProjection(analyzed: true, id: "import", origin: .importedLegacy),
    makeProjection(analyzed: true, id: "excluded", included: false),
    makeProjection(analyzed: true, id: "duplicate", duplicate: true),
    makeProjection(analyzed: true, id: "unfinished", lifecycle: "interrupted"),
    makeProjection(analyzed: true, id: "no-target", target: nil),
    makeProjection(analyzed: true, id: "boundary", duration: 60),
    makeProjection(analyzed: true, id: "estimated", estimated: true),
    makeProjection(analyzed: false, id: "missing-metrics"),
    makeProjection(analyzed: true, id: "older-other", target: 130)
]
let mixed = (0..<300).map { index in
    makeProjection(analyzed: !index.isMultiple(of: 3), id: String(index),
        origin: index.isMultiple(of: 7) ? .importedLegacy : .nativeV2,
        duration: index.isMultiple(of: 11) ? nil : Double(index + 1),
        included: !index.isMultiple(of: 13), target: index.isMultiple(of: 17) ? nil : 100 + index % 5,
        lifecycle: index.isMultiple(of: 19) ? "interrupted" : "completed",
        duplicate: index.isMultiple(of: 23), estimated: index.isMultiple(of: 29))
}
for loaded in [[], Array(representative.prefix(1)), representative,
               representative.filter(\.isMeaningfulWorkout), Array(representative.reversed()), mixed] {
    let results = WorkoutHistoryPresentation.comparisons(for: loaded)
    for entry in loaded {
        precondition(results[entry.id] == PreviousPresentation.comparison(for: entry, loaded: loaded))
    }
}
let results = WorkoutHistoryPresentation.comparisons(for: representative)
precondition(results["current"] == "К предыдущей с целью 125: время +1:00 · пульс +0 bpm · скорость +0.0 км/ч")
precondition(results["boundary"]?.contains("скорость") == false)
precondition(results["estimated"]?.contains("пульс") == false)
precondition(results["trivial"] == nil && results["import"] == nil && results["excluded"] == nil)
for count in [1000, 2000] {
    let loaded = (0..<count).map { makeProjection(analyzed: false, id: String($0)) }
    indexVisits = 0; candidateVisits = 0; linearVisits = 0
    let baselineStart = Date()
    let expected = loaded.map { PreviousPresentation.comparison(for: $0, loaded: loaded) }
    let beforeSeconds = Date().timeIntervalSince(baselineStart)
    let linearStart = Date()
    let actual = WorkoutHistoryPresentation.comparisons(for: loaded)
    let afterSeconds = Date().timeIntervalSince(linearStart)
    precondition(loaded.enumerated().allSatisfy { actual[$0.element.id] == expected[$0.offset] })
    precondition(linearVisits == count)
    precondition(indexVisits + candidateVisits == count * (count + 1) / 2 + 2 * count - 1)
    print("rows=\(count) before_visits=\(indexVisits + candidateVisits) after_visits=\(linearVisits) before_s=\(beforeSeconds) after_s=\(afterSeconds)")
}
print("Equivalence and linear traversal verified")

"""#
        try program.write(to: main, atomically: true, encoding: .utf8)
        let domain = package.appendingPathComponent("Sources/TelemetryDomain")
        let sources = try FileManager.default.contentsOfDirectory(at: domain, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }.map(\.path)
        _ = try run("/usr/bin/xcrun", ["swiftc", "-O", "-package-name", "WalkingPadRemoteCoreLogic"] + sources + [main.path, "-o", executable.path])
        let result = try run(executable.path, [])
        XCTAssertTrue(result.contains("Equivalence and linear traversal verified"), result)
        print(result)
    }

    private func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let result = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, result)
        guard process.terminationStatus == 0 else { throw NSError(domain: "comparison-harness", code: Int(process.terminationStatus)) }
        return result
    }
}
