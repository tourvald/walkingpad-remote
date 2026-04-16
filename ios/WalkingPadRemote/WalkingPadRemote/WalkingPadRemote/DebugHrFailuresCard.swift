import SwiftUI

struct DebugHrFailuresCard: View {
    struct Presentation {
        struct Metric: Identifiable {
            let id: String
            let title: String
            let value: String
            let tint: Color
        }

        struct ReportPreview: Identifiable {
            let id: UUID
            let title: String
            let subtitle: String
            let body: String
        }

        let subtitle: String
        let metrics: [Metric]
        let exportSubtitle: String
        let canExport: Bool
        let clearSubtitle: String
        let canClear: Bool
        let clearConfirmationMessage: String
        let reports: [ReportPreview]
        let emptyState: String?
        let footer: String?
    }

    let presentation: Presentation
    let onExport: () -> Void
    let onClear: () -> Void

    @State private var showClearConfirmation = false

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
            title: "HR Failures",
            subtitle: presentation.subtitle
        ) {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: metricColumns, spacing: 10) {
                    ForEach(presentation.metrics) { item in
                        DebugMetricTile(
                            title: item.title,
                            value: item.value,
                            tint: item.tint
                        )
                    }
                }

                LazyVGrid(columns: actionColumns, spacing: 10) {
                    Button(action: onExport) {
                        DebugActionTileLabel(
                            title: "Export HR Failures",
                            subtitle: presentation.exportSubtitle,
                            tint: .orange,
                            enabled: presentation.canExport
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!presentation.canExport)

                    Button {
                        showClearConfirmation = true
                    } label: {
                        DebugActionTileLabel(
                            title: "Clear HR Failures",
                            subtitle: presentation.clearSubtitle,
                            tint: .red,
                            enabled: presentation.canClear
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!presentation.canClear)
                }

                if let emptyState = presentation.emptyState, !emptyState.isEmpty {
                    Text(emptyState)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(presentation.reports) { report in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(report.title)
                                    .font(.footnote.weight(.semibold))
                                Text(report.subtitle)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(report.body)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.leading)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(8)
                            }
                            .padding(10)
                            .background(Color(.tertiarySystemFill))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }

                if let footer = presentation.footer, !footer.isEmpty {
                    Text(footer)
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                }
            }
        }
        .alert("Clear HR Failures?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                onClear()
            }
        } message: {
            Text(presentation.clearConfirmationMessage)
        }
    }
}
