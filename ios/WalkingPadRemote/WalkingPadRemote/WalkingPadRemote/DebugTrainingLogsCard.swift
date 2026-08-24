import SwiftUI

struct DebugTrainingLogsCard: View {
    struct Presentation {
        struct Metric: Identifiable {
            let id: String
            let title: String
            let value: String
            let tint: Color
        }

        struct ExportOption: Identifiable {
            let id: String
            let title: String
            let scope: TrainingLogCsvExportScope
        }

        let testRunActive: Bool
        let testRunStatusText: String
        let canStartTestRun: Bool
        let heartRateDiagnosticStatusText: String
        let heartRateDiagnosticMetrics: [Metric]
        let heartRateDiagnosticDetailLines: [String]
        let heartRateDiagnosticReport: String
        let subtitle: String
        let profileMetrics: [Metric]
        let deviceMetrics: [Metric]
        let writerHealthMetrics: [Metric]
        let writerHealthDetailLines: [String]
        let rawExportOptions: [ExportOption]
        let rawExportSubtitle: String
        let canExportRaw: Bool
        let sessionSummaryOptions: [ExportOption]
        let sessionSummarySubtitle: String
        let canExportSessionSummary: Bool
        let clearSubtitle: String
        let canClear: Bool
        let clearConfirmationMessage: String
        let detailLines: [String]
        let footer: String?
    }

    let presentation: Presentation
    let onToggleTestRun: () -> Void
    let onExportRaw: (TrainingLogCsvExportScope) -> Void
    let onExportSessionSummary: (TrainingLogCsvExportScope) -> Void

    private let metricColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    private let actionColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        DebugSectionCard(
            title: "Training Logs",
            subtitle: presentation.subtitle
        ) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Test Run")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)

                    Button(action: onToggleTestRun) {
                        DebugActionTileLabel(
                            title: presentation.testRunActive
                                ? "Остановить Test Run"
                                : "Запустить Test Run",
                            subtitle: presentation.testRunStatusText,
                            tint: presentation.testRunActive ? .red : .accentColor,
                            enabled: presentation.testRunActive || presentation.canStartTestRun
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!presentation.testRunActive && !presentation.canStartTestRun)
                }

                if !presentation.heartRateDiagnosticMetrics.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("HR diagnostic probe")
                                .font(.caption.weight(.medium))
                                .foregroundColor(.secondary)
                            Spacer()
                            ShareLink(item: presentation.heartRateDiagnosticReport) {
                                Label("Report", systemImage: "square.and.arrow.up")
                                    .font(.caption.weight(.semibold))
                            }
                        }

                        Text(presentation.heartRateDiagnosticStatusText)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        metricsSection(
                            title: "Native HealthKit",
                            items: presentation.heartRateDiagnosticMetrics
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(
                                Array(presentation.heartRateDiagnosticDetailLines.enumerated()),
                                id: \.offset
                            ) { _, line in
                                Text(line)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .textSelection(.enabled)
                    }
                }

                metricsSection(title: "Активный профиль", items: presentation.profileMetrics)
                if !presentation.deviceMetrics.isEmpty {
                    metricsSection(title: "Всё устройство", items: presentation.deviceMetrics)
                }
                metricsSection(
                    title: "Telemetry V2 Writer",
                    items: presentation.writerHealthMetrics
                )

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(
                        Array(presentation.writerHealthDetailLines.enumerated()),
                        id: \.offset
                    ) { _, line in
                        Text(line)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                LazyVGrid(columns: actionColumns, spacing: 10) {
                    Menu {
                        ForEach(presentation.rawExportOptions) { option in
                            Button(option.title) {
                                onExportRaw(option.scope)
                            }
                        }
                    } label: {
                        DebugActionTileLabel(
                            title: "Export Training CSV",
                            subtitle: presentation.rawExportSubtitle,
                            tint: .accentColor,
                            enabled: presentation.canExportRaw
                        )
                    }
                    .disabled(!presentation.canExportRaw)

                    Menu {
                        ForEach(presentation.sessionSummaryOptions) { option in
                            Button(option.title) {
                                onExportSessionSummary(option.scope)
                            }
                        }
                    } label: {
                        DebugActionTileLabel(
                            title: "Export Session Summary",
                            subtitle: presentation.sessionSummarySubtitle,
                            tint: Color.blue,
                            enabled: presentation.canExportSessionSummary
                        )
                    }
                    .disabled(!presentation.canExportSessionSummary)
                }

                Text(presentation.clearSubtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(presentation.detailLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if let footer = presentation.footer, !footer.isEmpty {
                    Text(footer)
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func metricsSection(title: String, items: [Presentation.Metric]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)

            LazyVGrid(columns: metricColumns, spacing: 10) {
                ForEach(items) { item in
                    DebugMetricTile(
                        title: item.title,
                        value: item.value,
                        tint: item.tint
                    )
                }
            }
        }
    }
}
