import SwiftUI

struct DebugTrainingLogsCard: View {
    struct Presentation {
        struct Metric: Identifiable {
            let id: String
            let title: String
            let value: String
            let tint: Color
        }

        struct DiagnosticScopeOption: Identifiable {
            let id: String
            let title: String
            let scope: TrainingLogCsvExportScope
        }

        let testRunActive: Bool
        let testRunStatusText: String
        let canStartTestRun: Bool
        let controllerUnitsDiagnosticStatusText: String
        let controllerUnitsDiagnosticMetrics: [Metric]
        let controllerUnitsDiagnosticDetailLines: [String]
        let controllerUnitsDiagnosticReport: String
        let heartRateDiagnosticStatusText: String
        let heartRateDiagnosticMetrics: [Metric]
        let heartRateDiagnosticDetailLines: [String]
        let heartRateDiagnosticReport: String
        let subtitle: String
        let profileMetrics: [Metric]
        let deviceMetrics: [Metric]
        let writerHealthMetrics: [Metric]
        let writerHealthDetailLines: [String]
        let diagnosticScopeOptions: [DiagnosticScopeOption]
        let diagnosticShareSubtitle: String
        let canShareDiagnostics: Bool
        let clearSubtitle: String
        let canClear: Bool
        let clearConfirmationMessage: String
        let detailLines: [String]
        let footer: String?
    }

    let presentation: Presentation
    let onToggleTestRun: () -> Void
    let onShareDiagnostics: (TrainingLogCsvExportScope) -> Void

    private let metricColumns = [
        GridItem(.flexible(), spacing: 10),
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

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Controller units diagnostic")
                            .font(.caption.weight(.medium))
                            .foregroundColor(.secondary)
                        Spacer()
                        ShareLink(item: presentation.controllerUnitsDiagnosticReport) {
                            Label("Report", systemImage: "square.and.arrow.up")
                                .font(.caption.weight(.semibold))
                        }
                    }

                    Text(presentation.controllerUnitsDiagnosticStatusText)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    metricsSection(
                        title: "A6 controller params",
                        items: presentation.controllerUnitsDiagnosticMetrics
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(
                            Array(presentation.controllerUnitsDiagnosticDetailLines.enumerated()),
                            id: \.offset
                        ) { _, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .textSelection(.enabled)
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

                Menu {
                    ForEach(presentation.diagnosticScopeOptions) { option in
                        Button(option.title) {
                            onShareDiagnostics(option.scope)
                        }
                    }
                } label: {
                    DebugActionTileLabel(
                        title: "Поделиться диагностикой",
                        subtitle: presentation.diagnosticShareSubtitle,
                        tint: .accentColor,
                        enabled: presentation.canShareDiagnostics
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(!presentation.canShareDiagnostics)
                .accessibilityLabel("Поделиться диагностикой")
                .accessibilityHint("Выберите объём тренировок для диагностического пакета")

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
