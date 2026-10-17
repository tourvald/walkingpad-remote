import ActivityKit
import SwiftUI
import WidgetKit

@main
struct WorkoutLiveActivityBundle: WidgetBundle {
    var body: some Widget { WorkoutLiveActivityWidget() }
}

struct WorkoutLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "figure.run")
                Text(context.isStale ? "Откройте тренировку" : title(context.state.phase))
                Spacer()
                countdown(context, width: 96)
                    .font(.title2.weight(.semibold))
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "figure.run").foregroundStyle(.cyan)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdown(context, width: 96).font(.title2.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.isStale ? "Откройте тренировку" : title(context.state.phase))
                        .font(.caption)
                }
            } compactLeading: {
                Image(systemName: "figure.run").foregroundStyle(.cyan)
            } compactTrailing: {
                countdown(context).foregroundStyle(.cyan)
            } minimal: {
                Image(systemName: "timer").foregroundStyle(.cyan)
                    .accessibilityLabel(title(context.state.phase))
            }
        }
    }

    @ViewBuilder
    private func countdown(_ context: ActivityViewContext<WorkoutActivityAttributes>, width: CGFloat = 58) -> some View {
        if let deadline = context.state.deadline, !context.isStale {
            Text(timerInterval: Date(timeIntervalSince1970: 0)...deadline, countsDown: true, showsHours: false)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: width)
                .accessibilityLabel(title(context.state.phase))
                .accessibilityValue(Text(timerInterval: Date(timeIntervalSince1970: 0)...deadline, countsDown: true, showsHours: false))
        } else {
            Image(systemName: context.isStale ? "exclamationmark.circle" : "ellipsis")
                .accessibilityLabel(context.isStale ? "Откройте тренировку" : "Завершаем тренировку")
        }
    }

    private func title(_ phase: WorkoutActivityAttributes.ContentState.Phase) -> String {
        switch phase {
        case .main: return "До заминки"
        case .cooldown: return "До лимита заминки"
        case .finishing: return "Завершаем тренировку"
        }
    }
}
