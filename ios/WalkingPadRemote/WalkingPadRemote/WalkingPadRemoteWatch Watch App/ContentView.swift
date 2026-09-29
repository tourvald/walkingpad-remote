import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject private var hr: WatchHeartRateManager

    var body: some View {
        let hasHr = hr.bpm > 0 && hr.isActive
        let hrColor: Color = {
            guard hasHr else { return .secondary }
            let diff = hr.bpm - hr.targetBpm
            if diff > 3 { return .red }
            if diff < -3 { return .orange }
            return .green
        }()

        ScrollView {
        VStack(spacing: 12) {
            Text("Пульс")
                .font(.headline)
            Text(hasHr ? "\(hr.bpm) bpm" : "—")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .monospacedDigit()
                .accessibilityLabel("Пульс")
                .accessibilityValue(hasHr ? "\(hr.bpm) ударов в минуту" : "Недоступен")
                .foregroundColor(hrColor)
            if hr.isActive {
                Text("Трансляция пульса")
                    .font(.caption)
                    .foregroundColor(.green)
            } else {
                Text("Нажмите «Начать»")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Button(hr.isActive ? "Завершить" : "Начать") {
                if hr.isActive {
                    hr.stop()
                } else {
                    hr.start()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(hr.isActive ? .red : .orange)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .padding()
        }
    }
}
