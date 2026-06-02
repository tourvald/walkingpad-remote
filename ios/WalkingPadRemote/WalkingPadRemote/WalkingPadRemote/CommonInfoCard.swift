import SwiftUI

struct CommonInfoCard: View {
    @EnvironmentObject private var manager: BluetoothManager
    @State private var heartPulse = false
    @State private var showBeatsPerMeterInfo = false

    // Computed display strings for primary metrics
    private var hrValue: String {
        let bpm = manager.lastKnownHeartRateBPM
        return bpm > 0 ? "\(bpm)" : "—"
    }

    private var hrUnit: String {
        manager.lastKnownHeartRateBPM > 0 ? "bpm" : ""
    }

    private var hrDeltaText: String? {
        guard manager.heartRateBPM > 0 && manager.hrStreamingActive else { return nil }
        let delta = manager.heartRateBPM - manager.hrTargetBPM
        if delta == 0 { return "±0" }
        return delta > 0 ? "+\(delta)" : "\(delta)"
    }

    private var speedValue: String {
        String(format: "%.1f", manager.treadmillActualSpeedKmh)
    }

    private var timeText: String {
        String(format: "%d:%02d", max(0, manager.timeSec) / 60, max(0, manager.timeSec) % 60)
    }

    var body: some View {
        Card {
            let hasHR: Bool = manager.heartRateBPM > 0 && manager.hrStreamingActive
            let hrColor: Color = {
                guard manager.lastKnownHeartRateBPM > 0 else { return .secondary }
                guard hasHR else { return .secondary }
                let diff = manager.heartRateBPM - manager.hrTargetBPM
                if diff > 3 { return .red }
                if diff < -3 { return .orange }
                return .green
            }()
            let speedActive = manager.treadmillActualSpeedKmh > 0.05
            let columns = [
                GridItem(.flexible(), spacing: 12, alignment: .leading),
                GridItem(.flexible(), spacing: 12, alignment: .leading),
                GridItem(.flexible(), spacing: 12, alignment: .leading)
            ]
            let delta = manager.lastSpeedDeltaKmh
            let deltaSymbol = delta > 0.05 ? "arrow.up" : (delta < -0.05 ? "arrow.down" : "minus")
            let deltaText = abs(delta) < 0.05 ? "0.0" : String(format: "%+.1f", delta)
            let deltaColor: Color = delta > 0.05 ? .orange : (delta < -0.05 ? .red : .green)

            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: columns, spacing: 12) {
                    primaryMetric(systemImage: "heart.fill", title: "Пульс", value: hrValue, unit: "", color: hrColor, valueSize: 40, badgeText: nil, badgeColor: .secondary, iconColor: .red, pulseIcon: hasHR, iconSize: 16)
                        .frame(maxWidth: .infinity, alignment: .center)
                    primaryMetric(systemImage: "speedometer", title: "km/h", value: speedValue, unit: "", color: speedActive ? .primary : .secondary, valueSize: 40)
                        .frame(maxWidth: .infinity, alignment: .center)
                    speedDeltaMetric(symbol: deltaSymbol, value: deltaText, color: deltaColor)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                Divider()
                    .overlay(Color(.separator))

                LazyVGrid(columns: columns, spacing: 12) {
                    statMetric(systemImage: "stopwatch", title: "Время", value: timeText)
                    statMetric(systemImage: "ruler", title: "Дистанция", value: String(format: "%.2f", manager.distKm), unit: "km")
                    statMetric(systemImage: "figure.walk", title: "Шаги", value: "\(manager.stepsCount)")
                }

                Divider()
                    .overlay(Color(.separator))

                LazyVGrid(columns: columns, spacing: 12) {
                    avgMetric(systemImage: "heart.fill", title: "Средн. пульс", value: "\(manager.hrAverageBPM)", unit: "bpm", active: hasHR)
                    Button {
                        showBeatsPerMeterInfo = true
                    } label: {
                        avgMetric(
                            systemImage: "waveform.path.ecg",
                            title: "Удары/м",
                            value: manager.beatsPerMeter.map { String(format: "%.2f", $0) } ?? "—",
                            unit: "",
                            active: manager.beatsPerMeter != nil
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Что такое удары на метр")
                    .sheet(isPresented: $showBeatsPerMeterInfo) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Удары на метр")
                                .font(.headline)
                            Text("Метрика показывает, сколько ударов сердца приходится на каждый метр. Чем ниже — тем лучше (вы тратите меньше ударов на ту же дистанцию).")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                            Text("Расчёт: средний пульс и средняя скорость за сессию")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                            Divider()
                            Text("Подсказка")
                                .font(.subheadline.weight(.semibold))
                            Text("Поддерживайте стабильный темп и старайтесь держать пульс ближе к целевому — это помогает снижать показатель.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                    }
                    avgMetric(systemImage: "speedometer", title: "Средняя скорость", value: String(format: "%.1f", manager.avgSpeedKmh), unit: "km/h", active: manager.avgSpeedActive)
                }
            }
        }
    }

    @ViewBuilder
    private func primaryMetric(systemImage: String, title: String?, value: String, unit: String, color: Color, valueSize: CGFloat, badgeText: String? = nil, badgeColor: Color? = nil, iconColor: Color = .secondary, pulseIcon: Bool = false, iconSize: CGFloat = 12) -> some View {
        VStack(alignment: .center, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundColor(iconColor)
                    .scaleEffect(pulseIcon && heartPulse ? 1.15 : 1.0)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: heartPulse)
                if let title {
                    Text(title)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Text(value)
                .font(.system(size: valueSize, weight: .bold, design: .rounded))
                .fontWeight(.bold)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundColor(color)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.25), value: value)
                .animation(.easeInOut(duration: 0.25), value: color)
                .frame(maxWidth: .infinity, alignment: .center)
                .layoutPriority(2)
            HStack(spacing: 6) {
                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let badgeText, !badgeText.isEmpty {
                    Text(badgeText)
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 6)
                        .background((badgeColor ?? color).opacity(0.12))
                        .foregroundColor(badgeColor ?? color)
                        .clipShape(Capsule())
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.2), value: badgeText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .onAppear { heartPulse = true }
    }

    @ViewBuilder
    private func secondaryMetric(title: String, value: String, unit: String, active: Bool) -> some View {
        let valueColor: Color = active ? .primary : .secondary
        let weight: Font.Weight = active ? .semibold : .regular
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: 24, weight: weight, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(valueColor)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func chipMetric(systemImage: String, text: String, active: Bool) -> some View {
        let valueColor: Color = active ? .primary : .secondary
        return HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption2)
                .foregroundColor(valueColor.opacity(0.9))
            Text(text)
                .font(.caption)
                .monospacedDigit()
                .foregroundColor(valueColor)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(active ? Color.accentColor.opacity(0.12) : Color(.tertiarySystemFill))
        .overlay(
            Capsule().stroke(active ? Color.accentColor.opacity(0.35) : .clear, lineWidth: 1)
        )
        .clipShape(Capsule())
        .animation(.easeInOut(duration: 0.2), value: active)
    }

    private func speedDeltaMetric(symbol: String, value: String, color: Color) -> some View {
        VStack(alignment: .center, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("km/h")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundColor(color)
                Text(value)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .fontWeight(.bold)
                    .monospacedDigit()
                    .foregroundColor(color)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.25), value: value)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func statMetric(systemImage: String, title: String, value: String, unit: String? = nil) -> some View {
        VStack(alignment: .center, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(.title2, design: .rounded))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundColor(.primary)
                if let unit {
                    Text(unit)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func avgMetric(systemImage: String, title: String, value: String, unit: String, active: Bool) -> some View {
        let valueColor: Color = active ? .primary : .secondary
        let weight: Font.Weight = active ? .semibold : .regular
        return VStack(alignment: .center, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(.title3, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(valueColor)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .fontWeight(weight)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
