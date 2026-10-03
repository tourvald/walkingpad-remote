// Run with the actual WorkoutHistoryRow.swift and the built TelemetryDomain objects.
// Pure fixture assertions and SwiftUI ImageRenderer previews; no app/runtime/device access.
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import SwiftUI
import TelemetryDomain

func fixture(
    _ id: String, target: Int? = 145, origin: WorkoutProjectionOrigin = .nativeV2,
    duration: Double? = 1800, hr: Double? = 145, speed: Double? = 5.8,
    estimated: Bool = false, duplicate: Bool = false, completed: Bool = true,
    offsetDays: Double = 0, zones: [Double?]? = [60, 240, 1200, 300, 0]
) -> WorkoutHistoryProjection {
    WorkoutHistoryProjection(
        id: id, origin: origin, startedAt: Date(timeIntervalSince1970: 1_790_000_000 - offsetDays * 86_400), endedAt: nil,
        durationSeconds: duration, targetHeartRate: target, averageHeartRate: hr,
        averageSpeed: speed.map { WorkoutSpeedProjection(kilometresPerHour: $0,
            evidenceKind: estimated ? .legacyEstimated : .factual, provenance: "fixture") },
        beatsPerMetre: 28, zoneSeconds: zones,
        healthKitWorkoutIdentifier: nil, telemetrySchemaVersion: "1.0.0", appVersion: "1.0",
        buildNumber: "100", algorithmVersion: "fixture", analyzerVersion: "fixture",
        quality: WorkoutProjectionQuality(lifecycleState: completed ? "completed" : "incomplete",
            recorderComplete: completed, analysisGrade: "high", identityStatus: nil,
            possibleDuplicate: duplicate, adaptationEligible: false, includedInStatistics: completed,
            provenance: ["fixture-provenance"], unavailableMetrics: [], warnings: ["fixture-warning"])
    )
}

@main struct HistoryPreview {
    @MainActor static func main() throws {
        let recent = fixture("recent", duration: 1930, hr: 142, speed: 6)
        let previous = fixture("previous", offsetDays: 1)
        let expected = "К предыдущей с целью 145: время +2:10 · пульс −3 bpm · скорость +0.2 км/ч"
        assert(WorkoutHistoryPresentation.comparison(for: recent, loaded: [recent, previous]) == expected)
        assert(WorkoutHistoryPresentation.comparison(for: recent, loaded: [recent]) == nil)
        assert(WorkoutHistoryPresentation.comparison(for: recent, loaded: [recent, fixture("other", target: 130)]) == nil)
        assert(WorkoutHistoryPresentation.comparison(for: recent, loaded: [recent, fixture("import", origin: .importedLegacy)]) == nil)
        assert(WorkoutHistoryPresentation.comparison(for: fixture("dup", duplicate: true), loaded: [fixture("dup", duplicate: true), previous]) == nil)
        assert(WorkoutHistoryPresentation.comparison(for: recent, loaded: [recent, fixture("unfinished", completed: false)]) == nil)
        assert(WorkoutHistoryPresentation.comparison(for: recent, loaded: [recent, fixture("estimated", estimated: true)])?.contains("скорость") == false)
        let missing = fixture("missing", duration: nil, hr: nil, speed: nil)
        assert(WorkoutHistoryPresentation.comparison(for: missing, loaded: [missing, previous]) == nil)
        assert(WorkoutHistoryPresentation.duration(nil) == "—")
        assert(WorkoutHistoryPresentation.heartRate(nil) == "—")
        assert(WorkoutHistoryPresentation.speed(nil) == "—")
        assert(WorkoutHistoryPresentation.speed(fixture("estimated", estimated: true).averageSpeed).hasPrefix("≈"))
        assert(WorkoutHistoryPresentation.badge(recent) == nil)
        assert(WorkoutHistoryPresentation.badge(missing) == "Неполные данные")
        assert(WorkoutHistoryPresentation.badge(fixture("import", origin: .importedLegacy, speed: nil)) == "Импортировано")
        let imported = fixture("imported", target: nil, origin: .importedLegacy, estimated: true, offsetDays: 5)
        assert(WorkoutHistoryPresentation.comparison(for: recent, loaded: [recent, imported, previous]) == expected)
        print("16 deterministic presentation assertions passed")
        let directory = CommandLine.arguments.dropFirst().first ?? "/tmp/issue-142-previews"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let entries = [recent, previous, fixture("older", duration: 1690, hr: 147, speed: 5.6, offsetDays: 2, zones: [60, 240, 1090, 300, 0]),
                       fixture("partial", speed: nil, offsetDays: 3), fixture("mixed", target: 130, offsetDays: 4), imported]
        for (name, visible, large) in [
            ("history-light", entries, false),
            ("history-dark-accessibility", entries, true),
            ("large-card", Array(entries.prefix(1)), true),
        ] {
            let view = VStack(alignment: .leading, spacing: 12) {
                Text("История тренировок").font(.headline)
                ForEach(visible) { entry in
                    WorkoutHistoryRow(entry: entry,
                        comparison: WorkoutHistoryPresentation.comparison(for: entry, loaded: entries))
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding(16)
            .frame(width: 390)
            .background(large ? Color.black : Color.white)
            .environment(\.colorScheme, large ? .dark : .light)
            .environment(\.dynamicTypeSize, large ? .accessibility3 : .large)
            .environment(\.locale, Locale(identifier: "ru_RU"))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            var bitmap: CGImage?
            renderer.render(rasterizationScale: 2) { size, draw in
                guard let context = CGContext(data: nil, width: Int(size.width * 2),
                    height: Int(size.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                context.scaleBy(x: 2, y: 2)
                draw(context)
                bitmap = context.makeImage()
            }
            guard let image = bitmap else {
                throw NSError(domain: "HistoryPreview", code: 1)
            }
            #if canImport(UIKit)
            let png = UIImage(cgImage: image).pngData()!
            #else
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            #endif
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
            try png.write(to: url)
            print(url.path)
        }
    }
}
