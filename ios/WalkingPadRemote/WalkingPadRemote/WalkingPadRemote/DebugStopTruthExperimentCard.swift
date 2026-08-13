import SwiftUI

#if STOP_TRUTH_EXPERIMENT_CAPABILITY
struct DebugStopTruthExperimentCard: View {
    struct Presentation {
        let capabilityAvailable: Bool
        let active: Bool
        let status: String
        let artifactPath: String
    }

    let presentation: Presentation
    let onStart: () -> Void
    let onPrepareMotion: () -> Void
    let onInitialStop: () -> Void
    let onMovingMarker: () -> Void
    let onStoppedMarker: () -> Void
    let onAbortMarker: () -> Void
    let onNextRepetition: () -> Void

    var body: some View {
        DebugSectionCard(
            title: "Issue #11 Stop-truth runner",
            subtitle: "Fixed typed experiment tooling • no generic packet input"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text(presentation.status)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)

                Button("Start fixed runner") { onStart() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!presentation.capabilityAvailable || presentation.active)

                HStack {
                    Button("Prepare raw-5 motion") { onPrepareMotion() }
                    Button("Send initial Stop") { onInitialStop() }
                }
                .buttonStyle(.bordered)
                .disabled(!presentation.active)

                HStack {
                    Button("MOVING") { onMovingMarker() }
                    Button("STOPPED") { onStoppedMarker() }
                    Button("ABORT", role: .destructive) { onAbortMarker() }
                }
                .buttonStyle(.bordered)
                .disabled(!presentation.active)

                Button("Complete recovery pause / next repetition") {
                    onNextRepetition()
                }
                .buttonStyle(.bordered)
                .disabled(!presentation.active)

                Text("MOVING / STOPPED / ABORT markers record evidence only and never send BLE commands.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("After ABORT following any motion-capable write: use the physical power cutoff. No software recovery command is sent.")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.red)
                if !presentation.artifactPath.isEmpty {
                    Text("Private evidence: \(presentation.artifactPath)")
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
#endif
