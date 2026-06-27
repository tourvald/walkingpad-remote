import SwiftUI

struct DebugTrainingLogsCard: View {
    struct Presentation {
        struct Metric: Identifiable {
            let id: String
            let title: String
            let value: String
            let tint: Color
        }

        struct RawExportOption: Identifiable {
            let id: String
            let title: String
            let scope: TrainingRawLogExportScope
        }

        struct SessionSummaryExportOption: Identifiable {
            let id: String
            let title: String
            let scope: TrainingSessionSummaryExportScope
        }

        let subtitle: String
        let profileMetrics: [Metric]
        let deviceMetrics: [Metric]
        let rawExportOptions: [RawExportOption]
        let rawExportSubtitle: String
        let canExportRaw: Bool
        let sessionSummaryOptions: [SessionSummaryExportOption]
        let sessionSummarySubtitle: String
        let canExportSessionSummary: Bool
        let testRunSubtitle: String
        let testRunStatus: String
        let testRunProgress: Double
        let isTestRunActive: Bool
        let canStartTestRun: Bool
        let requiresNoLoadConfirmation: Bool
        let noLoadConfirmationMessage: String
        let physicalConfirmationSummary: String
        let physicalConfirmationStatus: String
        let canConfirmPhysicalSemantics: Bool
        let canClearPhysicalSemantics: Bool
        let clearSubtitle: String
        let canClear: Bool
        let clearConfirmationMessage: String
        let detailLines: [String]
        let footer: String?
    }

    let presentation: Presentation
    let onExportRaw: (TrainingRawLogExportScope) -> Void
    let onExportSessionSummary: (TrainingSessionSummaryExportScope) -> Void
    let onStartTestRun: (_ confirmedNoLoadDiagnostic: Bool) -> Void
    let onStopTestRun: () -> Void
    let onConfirmPhysicalSemantics: (TreadmillPhysicalSemantics) -> Void
    let onClearPhysicalSemantics: () -> Void
    let onClear: () -> Void

    @State private var showClearConfirmation = false
    @State private var showNoLoadConfirmation = false

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
                metricsSection(title: "Активный профиль", items: presentation.profileMetrics)
                metricsSection(title: "Всё устройство", items: presentation.deviceMetrics)
                testRunSection()
                physicalSemanticsSection()

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

                Button {
                    showClearConfirmation = true
                } label: {
                    DebugActionTileLabel(
                        title: "Clear Training Logs",
                        subtitle: presentation.clearSubtitle,
                        tint: .red,
                        enabled: presentation.canClear
                    )
                }
                .buttonStyle(.plain)
                .disabled(!presentation.canClear)

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
        .alert("Clear Training Logs?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                onClear()
            }
        } message: {
            Text(presentation.clearConfirmationMessage)
        }
        .alert("No-load diagnostic?", isPresented: $showNoLoadConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Start Diagnostic", role: .destructive) {
                onStartTestRun(true)
            }
        } message: {
            Text(presentation.noLoadConfirmationMessage)
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

    private func testRunSection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Тест дорожки")
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)

            if presentation.isTestRunActive {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(presentation.testRunStatus)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.primary)
                        Spacer()
                        Text("\(Int((presentation.testRunProgress * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }

                    ProgressView(value: max(0, min(1, presentation.testRunProgress)))
                        .tint(.orange)
                }
            }

            Button {
                if presentation.isTestRunActive {
                    onStopTestRun()
                } else if presentation.requiresNoLoadConfirmation {
                    showNoLoadConfirmation = true
                } else {
                    onStartTestRun(false)
                }
            } label: {
                DebugActionTileLabel(
                    title: presentation.isTestRunActive ? "Stop Test Run" : "Start Test Run",
                    subtitle: presentation.isTestRunActive
                        ? "Остановить тест и отправить STOP"
                        : presentation.testRunSubtitle,
                    tint: presentation.isTestRunActive ? .red : .orange,
                    enabled: presentation.isTestRunActive || presentation.canStartTestRun
                )
            }
            .buttonStyle(.plain)
            .disabled(!presentation.isTestRunActive && !presentation.canStartTestRun)
        }
    }

    @ViewBuilder
    private func physicalSemanticsSection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Physical semantics")
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)

            Text(presentation.physicalConfirmationStatus)
                .font(.caption)
                .foregroundColor(.secondary)

            if !presentation.physicalConfirmationSummary.isEmpty {
                Text(presentation.physicalConfirmationSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }

            if presentation.canConfirmPhysicalSemantics {
                LazyVGrid(columns: actionColumns, spacing: 10) {
                    Button {
                        onConfirmPhysicalSemantics(.confirmedImperial)
                    } label: {
                        DebugActionTileLabel(
                            title: "Looks like 3.0 mph",
                            subtitle: "operator visual confirmation",
                            tint: .orange,
                            enabled: true
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        onConfirmPhysicalSemantics(.confirmedMetric)
                    } label: {
                        DebugActionTileLabel(
                            title: "Looks like 3.0 km/h",
                            subtitle: "operator visual confirmation",
                            tint: .blue,
                            enabled: true
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        onConfirmPhysicalSemantics(.unknown)
                    } label: {
                        DebugActionTileLabel(
                            title: "Unsure",
                            subtitle: "keep physical semantics unknown",
                            tint: .secondary,
                            enabled: true
                        )
                    }
                    .buttonStyle(.plain)

                    if presentation.canClearPhysicalSemantics {
                        Button {
                            onClearPhysicalSemantics()
                        } label: {
                            DebugActionTileLabel(
                                title: "Clear physical confirmation",
                                subtitle: "for this treadmill",
                                tint: .red,
                                enabled: true
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if presentation.canClearPhysicalSemantics {
                Button {
                    onClearPhysicalSemantics()
                } label: {
                    DebugActionTileLabel(
                        title: "Clear physical confirmation",
                        subtitle: "for this treadmill",
                        tint: .red,
                        enabled: true
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
