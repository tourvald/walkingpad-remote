import SwiftUI

struct StatsRightAlignedBlock: View {
    @ObservedObject var manager: BluetoothManager

    private func timeText(_ seconds: Int) -> String {
        let m = max(0, seconds) / 60
        let s = max(0, seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func distText(_ km: Double) -> String {
        String(format: "%.2f", max(0.0, km))
    }

    private func stepsText(_ steps: Int) -> String {
        "\(max(0, steps))"
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            // Time row
            VStack(alignment: .trailing, spacing: 4) {
                Text(timeText(manager.timeSec))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Text("время")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            // Distance row
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Text(distText(manager.distKm))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Text("км")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text("дистанция")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            // Steps row
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Text(stepsText(manager.stepsCount))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Text("шаги")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text("количество")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 8)
    }
}

#Preview {
    let manager: BluetoothManager = {
        let manager = BluetoothManager()
        manager.timeSec = 75
        manager.distKm = 0.42
        manager.stepsCount = 356
        return manager
    }()

    StatsRightAlignedBlock(manager: manager)
        .padding()
        .background(Color.primary.opacity(0.06))
}
