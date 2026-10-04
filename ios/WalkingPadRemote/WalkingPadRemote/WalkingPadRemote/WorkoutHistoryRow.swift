import Foundation
import SwiftUI
#if canImport(TelemetryDomain)
import TelemetryDomain
#endif

// Presentation rules use loaded projections only; they never query workout evidence.
enum WorkoutHistoryPresentation {
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
            candidate.isMeaningfulWorkout && candidate.origin == .nativeV2
                && candidate.quality.lifecycleState == "completed"
                && !candidate.quality.possibleDuplicate && candidate.targetHeartRate != nil
        }
        guard eligible(entry), let target = entry.targetHeartRate,
              let index = loaded.firstIndex(where: { $0.id == entry.id }),
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

struct WorkoutHistoryRow: View {
    let entry: WorkoutHistoryProjection
    let comparison: String?
    var showsDisclosure = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.startedAt.map(Self.dateFormatter.string(from:)) ?? "Дата неизвестна")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if showsDisclosure {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .accessibilityHidden(true)
                }
            }
            if let badge = WorkoutHistoryPresentation.badge(entry) {
                Text(badge)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { metrics }
            } else {
                HStack(alignment: .top, spacing: 8) { metrics }
            }
            if let target = entry.targetHeartRate {
                Text("Цель \(target) bpm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let zones = entry.zoneSeconds, zones.count == 5 {
                WorkoutHistoryZones(values: zones)
            }
            if let comparison {
                Text(comparison)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(showsDisclosure ? "Открыть подробности тренировки" : "")
    }

    @ViewBuilder private var metrics: some View {
        metric("Время", WorkoutHistoryPresentation.duration(entry.durationSeconds))
        metric("Ср. пульс", WorkoutHistoryPresentation.heartRate(entry.averageHeartRate))
        metric("Ср. скорость", WorkoutHistoryPresentation.speed(entry.averageSpeed))
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct WorkoutHistoryZones: View {
    let values: [Double?]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), alignment: .leading),
                            count: dynamicTypeSize.isAccessibilitySize ? 2 : 5)
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(0..<5) { index in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Z\(index + 1)").foregroundStyle(.secondary)
                    Text(WorkoutHistoryPresentation.duration(values[index])).monospacedDigit()
                }
                .font(.caption2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Зона \(index + 1)")
                .accessibilityValue(WorkoutHistoryPresentation.duration(values[index]))
            }
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct WorkoutHistoryDetail: View {
    let entry: WorkoutHistoryProjection
    let exportingWorkoutID: String?
    let onExportAnalysis: (WorkoutHistoryProjection) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    WorkoutHistoryRow(entry: entry, comparison: nil, showsDisclosure: false)
                    if let beats = WorkoutHistoryPresentation.value(entry.beatsPerMetre) {
                        Text("Удары/м: \(String(format: "%.2f", beats))")
                    }
                    Text(entry.origin == .importedLegacy
                         ? "Импортированная тренировка. Доступность метрик зависит от сохранённых данных."
                         : WorkoutHistoryPresentation.badge(entry) == nil
                            ? "Завершённая тренировка. Фактические метрики сохранены в Telemetry V2."
                            : "Часть данных недоступна или тренировка не завершена полностью.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    DisclosureGroup("Технические сведения") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Источник: \(entry.origin.rawValue)")
                            Text("Состояние: \(entry.quality.lifecycleState)")
                            Text("Анализ: \(entry.quality.analysisGrade ?? "—")")
                            Text("App/build: \(entry.appVersion ?? "—") / \(entry.buildNumber ?? "—")")
                            Text("Schema: \(entry.telemetrySchemaVersion ?? "—")")
                            Text("Algorithm: \(entry.algorithmVersion ?? "—")")
                            Text("Analyzer: \(entry.analyzerVersion ?? "—")")
                            Text("Identity: \(entry.quality.identityStatus ?? "—")")
                            Text("Возможный дубликат: \(entry.quality.possibleDuplicate ? "да" : "нет")")
                            Text(entry.quality.provenance.joined(separator: "\n"))
                            Text(entry.quality.warnings.joined(separator: "\n"))
                            Text("Недоступно: \(entry.quality.unavailableMetrics.joined(separator: ", "))")
                            if let identifier = entry.healthKitWorkoutIdentifier {
                                Text("HealthKit: \(identifier.uuidString.lowercased())")
                                if entry.quality.provenance.contains("telemetry-v2-imported-exact-healthkit-linkage") {
                                    Text("exact import linkage")
                                }
                            }
                            if let coverage = entry.factualSpeedCoverage {
                                Text("Покрытие скорости: \(WorkoutHistoryPresentation.duration(coverage.coveredSeconds)); пропуск: \(WorkoutHistoryPresentation.duration(coverage.uncoveredSeconds))")
                            }
                        }
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                    }
                    if entry.origin == .nativeV2 {
                        Button {
                            onExportAnalysis(entry)
                        } label: {
                            HStack {
                                if exportingWorkoutID == entry.id { ProgressView() }
                                Label("Экспорт данных тренировки", systemImage: "square.and.arrow.up")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(exportingWorkoutID != nil)
                        .accessibilityLabel("Экспорт данных тренировки")
                    }
                }
                .padding()
            }
            .navigationTitle("Тренировка")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}
