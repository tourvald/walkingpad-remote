import SwiftUI
#if canImport(TelemetryRuntime)
import TelemetryRuntime
#endif
#if canImport(TelemetryDomain)
import TelemetryDomain
#endif
#if canImport(UIKit)
import UIKit
#endif

// Fallback definition to satisfy references in this file if the app doesn't define it elsewhere.
#if !canImport(HrFailureReportModule)
struct HrFailureReport: Identifiable {
    let id = UUID()
    let reason: String
    let start: Date
    let end: Date
    let lines: [String]
}
#endif

struct ContentView: View {
    @EnvironmentObject private var manager: BluetoothManager
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("content_selected_root_tab_v1") private var selectedRootTabRaw: Int = RootTab.control.rawValue

    private enum RootTab: Int {
        case control = 0
        case stats = 1
        case plank = 2
        case debug = 3
    }

    private var rootTabSelection: Binding<RootTab> {
        Binding(
            get: { RootTab(rawValue: selectedRootTabRaw) ?? .control },
            set: { newValue in selectedRootTabRaw = newValue.rawValue }
        )
    }

    var body: some View {
        TabView(selection: rootTabSelection) {
            ControlSwipeView()
                .environmentObject(manager)
                .tabItem {
                    Label("HR‑контроль", systemImage: "heart.circle")
                }
                .tag(RootTab.control)

            WorkoutStatsView()
                .environmentObject(manager)
                .tabItem {
                    Label("Статистика", systemImage: "chart.bar")
                }
                .tag(RootTab.stats)

            PlankTimerView()
                .tabItem {
                    Label("Планка", systemImage: "timer.circle")
                }
                .tag(RootTab.plank)

            DebugView()
                .environmentObject(manager)
                .tabItem {
                    Label("Отладка", systemImage: "ladybug")
                }
                .tag(RootTab.debug)
        }
        .onAppear { manager.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                manager.pingWatch()
            } else {
                manager.treadmillTestRunAppBecameInactive()
            }
#if STOP_TRUTH_EXPERIMENT_CAPABILITY
            if phase != .active {
                manager.stopTruthExperimentAppBecameInactive()
            }
#endif
        }
    }
}

private struct ControlSwipeView: View {
    @EnvironmentObject private var manager: BluetoothManager
    @State private var showDevicePicker = false
    @State private var showConnectError = false
    @State private var presentSuggestedPicker = false
    @State private var showInfoToast = false
    private let heroAccent: Color = .orange

    private var watchStatusLabel: String {
        if manager.hrStreamingActive {
            return "HR активен"
        }
        return manager.watchReachable ? "Часы онлайн" : "Часы офлайн"
    }

    private var connectionStatusLabel: String {
        manager.isConnected ? "Подключено" : "Не подключено"
    }

    private var connectionStatusColor: Color {
        manager.isConnected ? .green : .secondary
    }

    private var watchStatusColor: Color {
        manager.hrStreamingActive ? .green : (manager.watchReachable ? .orange : .secondary)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(.systemGroupedBackground), Color(.secondarySystemGroupedBackground)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                Circle()
                    .fill(heroAccent.opacity(0.16))
                    .frame(width: 260, height: 260)
                    .blur(radius: 40)
                    .offset(x: 135, y: -280)
                    .allowsHitTesting(false)

                Circle()
                    .fill(Color.teal.opacity(0.1))
                    .frame(width: 230, height: 230)
                    .blur(radius: 38)
                    .offset(x: -140, y: 220)
                    .allowsHitTesting(false)

                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            controlHeroMetric(
                                icon: "antenna.radiowaves.left.and.right",
                                title: "Дорожка",
                                value: connectionStatusLabel,
                                tint: connectionStatusColor,
                                action: {
                                    showDevicePicker = true
                                }
                            )
                            controlHeroMetric(
                                icon: "applewatch",
                                title: "Часы",
                                value: watchStatusLabel,
                                tint: watchStatusColor,
                                action: {
                                    manager.pingWatch()
                                }
                            )
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        heroAccent.opacity(0.2),
                                        Color(.secondarySystemGroupedBackground).opacity(0.95)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(heroAccent.opacity(0.3), lineWidth: 1)
                    )
                    .sheet(isPresented: $showDevicePicker) {
                        DevicePickerView()
                            .environmentObject(manager)
                    }
                    .onChange(of: manager.connectErrorMessage) { _, newValue in
                        if newValue != nil {
                            showConnectError = true
                        }
                    }
                    .alert("Проблема с подключением", isPresented: $showConnectError, presenting: manager.connectErrorMessage) { _ in
                        Button("Выбрать другую дорожку") { showDevicePicker = true }
                        Button("OK", role: .cancel) {}
                    } message: { msg in
                        Text(msg)
                    }
                    .onChange(of: manager.suggestDevicePicker) { _, newValue in
                        if newValue {
                            presentSuggestedPicker = true
                        }
                    }
                    .sheet(isPresented: $presentSuggestedPicker, onDismiss: {
                        manager.suggestDevicePicker = false
                    }) {
                        DevicePickerView()
                            .environmentObject(manager)
                    }
                    .onChange(of: manager.infoToastMessage) { _, newValue in
                        if newValue != nil {
                            showInfoToast = true
                        }
                    }
                    .alert("Информация", isPresented: $showInfoToast, presenting: manager.infoToastMessage) { _ in
                        Button("Открыть выбор") { showDevicePicker = true }
                        Button("OK", role: .cancel) {}
                    } message: { msg in
                        Text(msg)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                    CommonInfoCard()
                        .environmentObject(manager)
                        .padding(.horizontal, 12)

                    ScrollView {
                        HRControlPanel()
                            .environmentObject(manager)
                            .padding(.horizontal, 12)
                            .padding(.bottom)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
    }

    @ViewBuilder
    private func controlHeroMetric(
        icon: String,
        title: String,
        value: String,
        tint: Color,
        action: (() -> Void)? = nil
    ) -> some View {
        let content = HStack(alignment: .top, spacing: 8) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.16))
                    .frame(width: 24, height: 24)
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(.systemBackground).opacity(0.72), tint.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: tint.opacity(0.08), radius: 8, x: 0, y: 4)

        if let action {
            Button(action: action) {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }
}

private struct ManualView: View {
    @EnvironmentObject private var manager: BluetoothManager
    @State private var showDisconnectAlert = false
    let embedded: Bool

    private struct SpeedBounds {
        let min: Double
        let max: Double
        let increment: Double
    }

    private var speedBounds: SpeedBounds {
        let rawMin = manager.treadmillMinSpeedKmh
        let rawMax = manager.treadmillMaxSpeedKmh
        let rawInc = manager.treadmillSpeedIncrementKmh

        let minV = (rawMin.isFinite && rawMin > 0.0) ? rawMin : 0.5
        let maxV = (rawMax.isFinite && rawMax >= minV) ? rawMax : max(12.0, minV)
        let incV = (rawInc.isFinite && rawInc > 0.0) ? rawInc : 0.1

        // UI-friendly caps; do not assume high-end treadmill limits.
        let cappedMax = min(maxV, 25.0)
        let cappedInc = min(max(incV, 0.1), 1.0)
        return SpeedBounds(min: minV, max: cappedMax, increment: cappedInc)
    }

    private var currentSpeed: Double { max(0.0, min(speedBounds.max, manager.speedKmh)) }
    private var targetSpeed: Double { max(speedBounds.min, min(speedBounds.max, manager.desiredSpeedKmh)) }

    private var targetSpeedBinding: Binding<Double> {
        Binding(
            get: { targetSpeed },
            set: {
                let step = speedBounds.increment
                let snapped = ($0 / step).rounded() * step
                manager.setTargetSpeedFromSlider(max(speedBounds.min, min(speedBounds.max, snapped)))
            }
        )
    }

    init(embedded: Bool = false) {
        self.embedded = embedded
    }

    @ViewBuilder
    private var controlCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Control")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Target speed")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(String(format: "%.1f km/h", targetSpeed))
                            .font(.caption.weight(.semibold))
                    }

                    Slider(value: targetSpeedBinding, in: speedBounds.min...speedBounds.max)

                    HStack {
                        Text(String(format: "%.1f", speedBounds.min))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(String(format: "%.1f", speedBounds.max))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        manager.manualGo(targetSpeed: max(speedBounds.min, targetSpeed))
                    } label: {
                        Label("GO", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!manager.isConnected)
                    .opacity(manager.isConnected ? 1.0 : 0.5)

                    Button("Stop") {
                        manager.manualStop()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!manager.isConnected)
                    .opacity(manager.isConnected ? 1.0 : 0.5)
                }

                HStack(spacing: 12) {
                    Button("− Speed") {
                        manager.adjustSpeed(delta: -speedBounds.increment)
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)

                    Button("+ Speed") {
                        manager.adjustSpeed(delta: speedBounds.increment)
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large)

                Text(String(format: "Actual %.1f  ·  Target %.1f  ·  AppSet %.1f", currentSpeed, targetSpeed, manager.deviceTargetSpeedKmh))
                    .font(.caption)
                    .foregroundColor(.secondary)

                if manager.loggingEnabled && !manager.lastCommandLine.isEmpty {
                    Text(manager.lastCommandLine)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    var body: some View {
        Group {
            if embedded {
                controlCard
            } else {
                NavigationStack {
                    ScrollView {
                        VStack(spacing: 16) {
                            StatusPillsRow(showDisconnectAlert: $showDisconnectAlert)
                                .environmentObject(manager)

                            CommonInfoCard()
                                .environmentObject(manager)

                            controlCard
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .navigationTitle("Пульт")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
    }
}

private struct HrWatchIssue: Identifiable {
    let id: String
    let title: String
    let message: String
    let color: Color

    init(title: String, message: String, color: Color) {
        self.id = "\(title)|\(message)"
        self.title = title
        self.message = message
        self.color = color
    }
}

private func hrZoneColor(_ zone: Int) -> Color {
    switch zone {
    case 1: return .blue
    case 2: return .green
    case 3: return .yellow
    case 4: return .orange
    default: return .red
    }
}

private func hrZoneRanges(for manager: BluetoothManager) -> [ClosedRange<Int>] {
    let upper1 = max(60, min(220, manager.hrZone1Max))
    let lower2 = min(220, upper1 + 1)
    let upper2 = max(lower2, min(220, manager.hrZone2Max))
    let lower3 = min(220, upper2 + 1)
    let upper3 = max(lower3, min(220, manager.hrZone3Max))
    let lower4 = min(220, upper3 + 1)
    let upper4 = max(lower4, min(220, manager.hrZone4Max))
    let lower5 = min(220, upper4 + 1)

    return [
        60...upper1,
        lower2...upper2,
        lower3...upper3,
        lower4...upper4,
        lower5...220
    ]
}

private func hrZoneMidpoint(_ range: ClosedRange<Int>) -> Int {
    range.lowerBound + ((range.upperBound - range.lowerBound) / 2)
}

private func hrZoneTargetBpm(zone: Int, range: ClosedRange<Int>) -> Int {
    // Zone 5 uses the lower boundary as a fixed target.
    if zone == 5 {
        return range.lowerBound
    }
    return hrZoneMidpoint(range)
}

private func hrZoneIndex(for bpm: Int, manager: BluetoothManager) -> Int {
    let ranges = hrZoneRanges(for: manager)
    for (index, range) in ranges.enumerated() where range.contains(bpm) {
        return index
    }
    return max(0, min(4, ranges.count - 1))
}

private func hrWatchIssue(for manager: BluetoothManager) -> HrWatchIssue? {
    if !manager.watchPaired {
        return HrWatchIssue(
            title: "Часы не сопряжены",
            message: "Apple Watch не сопряжены с этим iPhone. Сопрягите часы в приложении Watch.",
            color: .red
        )
    }

    if !manager.watchAppInstalled {
        return HrWatchIssue(
            title: "Нет приложения на часах",
            message: "Установите приложение WalkingPadRemote на Apple Watch и откройте его.",
            color: .red
        )
    }

    if manager.watchReachable && !manager.hrStreamingActive {
        return HrWatchIssue(
            title: "Нет пульса с часов",
            message: "Часы подключены, но пульс не поступает. Запустите экран часов и дождитесь данных HR.",
            color: .orange
        )
    }

    if !manager.watchReachable {
        return HrWatchIssue(
            title: "Часы недоступны",
            message: "Сейчас нет активного канала с Apple Watch. Откройте приложение на часах и держите его на экране.",
            color: .orange
        )
    }

    return nil
}

private struct HrAdaptiveUiThresholds {
    let deadbandPercent: Double
    let downLevel2StartPercent: Double
    let downLevel3StartPercent: Double
    let downLevel4StartPercent: Double
    let upLevel2StartPercent: Double
    let upLevel3StartPercent: Double
    let upLevel4StartPercent: Double
}

private struct HrAdaptiveUiSelection {
    let level: Int
    let stepKmh: Double
}

private struct HrAdaptiveDecisionPreview {
    let label: String
    let details: String
    let color: Color
}

private struct HrAdaptiveRangeRow: Identifiable {
    let id: String
    let title: String
    let hrRangeText: String
    let diffText: String
    let stepTag: String
    let deltaText: String
    let tint: Color
}

private func hrAdaptiveClampStep(_ value: Double) -> Double {
    max(0.1, min(2.0, value))
}

private func hrAdaptiveQuantizePercent(_ value: Double) -> Double {
    (value * 2.0).rounded() / 2.0
}

private func hrAdaptiveNormalizedThresholds(
    deadbandPercent: Double,
    downLevel2StartPercent: Double,
    downLevel3StartPercent: Double,
    downLevel4StartPercent: Double,
    upLevel2StartPercent: Double,
    upLevel3StartPercent: Double,
    upLevel4StartPercent: Double
) -> HrAdaptiveUiThresholds {
    let deadband = hrAdaptiveQuantizePercent(max(1.0, min(15.0, deadbandPercent)))
    let downL2 = hrAdaptiveQuantizePercent(max(deadband + 0.5, min(30.0, downLevel2StartPercent)))
    let downL3 = hrAdaptiveQuantizePercent(max(downL2 + 0.5, min(40.0, downLevel3StartPercent)))
    let downL4 = hrAdaptiveQuantizePercent(max(downL3 + 0.5, min(60.0, downLevel4StartPercent)))
    let upL2 = hrAdaptiveQuantizePercent(max(deadband + 0.5, min(40.0, upLevel2StartPercent)))
    let upL3 = hrAdaptiveQuantizePercent(max(upL2 + 0.5, min(60.0, upLevel3StartPercent)))
    let upL4 = hrAdaptiveQuantizePercent(max(upL3 + 0.5, min(80.0, upLevel4StartPercent)))
    return HrAdaptiveUiThresholds(
        deadbandPercent: deadband,
        downLevel2StartPercent: downL2,
        downLevel3StartPercent: downL3,
        downLevel4StartPercent: downL4,
        upLevel2StartPercent: upL2,
        upLevel3StartPercent: upL3,
        upLevel4StartPercent: upL4
    )
}

private func hrAdaptiveThresholds(for manager: BluetoothManager) -> HrAdaptiveUiThresholds {
    hrAdaptiveNormalizedThresholds(
        deadbandPercent: manager.hrAdaptiveDeadbandPercent,
        downLevel2StartPercent: manager.hrAdaptiveDownLevel2StartPercent,
        downLevel3StartPercent: manager.hrAdaptiveDownLevel3StartPercent,
        downLevel4StartPercent: manager.hrAdaptiveDownLevel4StartPercent,
        upLevel2StartPercent: manager.hrAdaptiveUpLevel2StartPercent,
        upLevel3StartPercent: manager.hrAdaptiveUpLevel3StartPercent,
        upLevel4StartPercent: manager.hrAdaptiveUpLevel4StartPercent
    )
}

private func hrAdaptiveQuantizeStep(_ value: Double) -> Double {
    max(0.1, (value * 10.0).rounded() / 10.0)
}

private func hrAdaptiveStepForLevel(_ level: Int) -> Double {
    let normalized = max(1, min(4, level))
    return Double(normalized) * 0.1
}

private func hrAdaptiveDiffPercent(absDiff: Int, targetBpm: Int) -> Double {
    let safeTarget = max(1, targetBpm)
    return (Double(absDiff) / Double(safeTarget)) * 100.0
}

private func hrAdaptiveDiffBpm(forPercent percent: Double, targetBpm: Int) -> Int {
    let safeTarget = max(1, targetBpm)
    return max(1, Int(round((Double(safeTarget) * percent) / 100.0)))
}

private func hrAdaptiveSelection(
    diffPercent: Double,
    isIncreasingSpeed: Bool,
    thresholds: HrAdaptiveUiThresholds
) -> HrAdaptiveUiSelection {
    let adjustedLevel: Int
    if isIncreasingSpeed {
        if diffPercent >= thresholds.upLevel4StartPercent {
            adjustedLevel = 4
        } else if diffPercent >= thresholds.upLevel3StartPercent {
            adjustedLevel = 3
        } else if diffPercent >= thresholds.upLevel2StartPercent {
            adjustedLevel = 2
        } else {
            adjustedLevel = 1
        }
    } else {
        if diffPercent >= thresholds.downLevel4StartPercent {
            adjustedLevel = 4
        } else if diffPercent >= thresholds.downLevel3StartPercent {
            adjustedLevel = 3
        } else if diffPercent >= thresholds.downLevel2StartPercent {
            adjustedLevel = 2
        } else {
            adjustedLevel = 1
        }
    }
    return HrAdaptiveUiSelection(level: adjustedLevel, stepKmh: hrAdaptiveStepForLevel(adjustedLevel))
}

private func hrAdaptiveDiffText(
    targetBpm: Int,
    minPercent: Double,
    maxPercent: Double?,
    signedDirection: Int
) -> String {
    let minAbs = hrAdaptiveDiffBpm(forPercent: minPercent, targetBpm: targetBpm)
    let percentText: String
    if let maxPercent {
        let maxAbs = hrAdaptiveDiffBpm(forPercent: maxPercent, targetBpm: targetBpm)
        let low = min(minAbs, maxAbs)
        let high = max(minAbs, maxAbs)
        if signedDirection < 0 {
            percentText = String(format: "%.1f...%.1f%%", -maxPercent, -minPercent)
        } else {
            percentText = String(format: "+%.1f...+%.1f%%", minPercent, maxPercent)
        }
        return String(format: "%d...%d bpm (%@)", low, high, percentText)
    }
    if signedDirection < 0 {
        percentText = String(format: "≤ %.1f%%", -minPercent)
    } else {
        percentText = String(format: "≥ +%.1f%%", minPercent)
    }
    return String(format: "≥ %d bpm (%@)", minAbs, percentText)
}

private func hrAdaptiveHoldDiffText(targetBpm: Int, thresholds: HrAdaptiveUiThresholds) -> String {
    let deadbandBpm = hrAdaptiveDiffBpm(forPercent: thresholds.deadbandPercent, targetBpm: targetBpm)
    return String(format: "±%d bpm (±%.1f%%)", deadbandBpm, thresholds.deadbandPercent)
}

private func hrAdaptiveHrRangeBelowText(targetBpm: Int, minAbsDiff: Int, maxAbsDiff: Int?) -> String {
    if let maxAbsDiff {
        let low = max(0, targetBpm - maxAbsDiff)
        let high = max(0, targetBpm - minAbsDiff)
        return "\(low)...\(high) bpm"
    }
    let upper = max(0, targetBpm - minAbsDiff)
    return "≤ \(upper) bpm"
}

private func hrAdaptiveHrRangeAboveText(targetBpm: Int, minAbsDiff: Int, maxAbsDiff: Int?) -> String {
    if let maxAbsDiff {
        return "\(targetBpm + minAbsDiff)...\(targetBpm + maxAbsDiff) bpm"
    }
    return "≥ \(targetBpm + minAbsDiff) bpm"
}

private func hrAdaptiveHoldRangeText(targetBpm: Int, thresholds: HrAdaptiveUiThresholds) -> String {
    let deadbandBpm = hrAdaptiveDiffBpm(forPercent: thresholds.deadbandPercent, targetBpm: targetBpm)
    return "\(max(0, targetBpm - deadbandBpm))...\(targetBpm + deadbandBpm) bpm"
}

private func hrAdaptiveDeltaText(stepKmh: Double, direction: Int) -> String {
    let signed = direction >= 0 ? stepKmh : -stepKmh
    return String(format: "%+.1f км/ч", signed)
}

private func hrAdaptiveRows(
    targetBpm: Int,
    fixedStepKmh: Double,
    adaptiveEnabled: Bool,
    thresholds: HrAdaptiveUiThresholds
) -> [HrAdaptiveRangeRow] {
    let fixedBaseStep = hrAdaptiveClampStep(fixedStepKmh)
    let deadbandBpm = hrAdaptiveDiffBpm(forPercent: thresholds.deadbandPercent, targetBpm: targetBpm)
    let minActionDiffBpm = deadbandBpm + 1

    let downL2StartBpm = max(minActionDiffBpm, hrAdaptiveDiffBpm(forPercent: thresholds.downLevel2StartPercent, targetBpm: targetBpm))
    let downL3StartBpm = max(downL2StartBpm + 1, hrAdaptiveDiffBpm(forPercent: thresholds.downLevel3StartPercent, targetBpm: targetBpm))
    let downL4StartBpm = max(downL3StartBpm + 1, hrAdaptiveDiffBpm(forPercent: thresholds.downLevel4StartPercent, targetBpm: targetBpm))
    let upL2StartBpm = max(minActionDiffBpm, hrAdaptiveDiffBpm(forPercent: thresholds.upLevel2StartPercent, targetBpm: targetBpm))
    let upL3StartBpm = max(upL2StartBpm + 1, hrAdaptiveDiffBpm(forPercent: thresholds.upLevel3StartPercent, targetBpm: targetBpm))
    let upL4StartBpm = max(upL3StartBpm + 1, hrAdaptiveDiffBpm(forPercent: thresholds.upLevel4StartPercent, targetBpm: targetBpm))

    if !adaptiveEnabled {
        let fixed = hrAdaptiveQuantizeStep(fixedBaseStep)
        return [
            HrAdaptiveRangeRow(
                id: "hold-fixed",
                title: "Удержание",
                hrRangeText: hrAdaptiveHoldRangeText(targetBpm: targetBpm, thresholds: thresholds),
                diffText: hrAdaptiveHoldDiffText(targetBpm: targetBpm, thresholds: thresholds),
                stepTag: "HOLD-FIXED",
                deltaText: String(format: "%+.1f км/ч", 0.0),
                tint: .secondary
            ),
            HrAdaptiveRangeRow(
                id: "up-fixed",
                title: "HR ниже цели",
                hrRangeText: hrAdaptiveHrRangeBelowText(targetBpm: targetBpm, minAbsDiff: minActionDiffBpm, maxAbsDiff: nil),
                diffText: hrAdaptiveDiffText(targetBpm: targetBpm, minPercent: thresholds.deadbandPercent, maxPercent: nil, signedDirection: -1),
                stepTag: "UP-FIXED",
                deltaText: hrAdaptiveDeltaText(stepKmh: fixed, direction: 1),
                tint: .green
            ),
            HrAdaptiveRangeRow(
                id: "down-fixed",
                title: "HR выше цели",
                hrRangeText: hrAdaptiveHrRangeAboveText(targetBpm: targetBpm, minAbsDiff: minActionDiffBpm, maxAbsDiff: nil),
                diffText: hrAdaptiveDiffText(targetBpm: targetBpm, minPercent: thresholds.deadbandPercent, maxPercent: nil, signedDirection: 1),
                stepTag: "DOWN-FIXED",
                deltaText: hrAdaptiveDeltaText(stepKmh: fixed, direction: -1),
                tint: .orange
            )
        ]
    }

    let upL1 = hrAdaptiveStepForLevel(1)
    let upL2 = hrAdaptiveStepForLevel(2)
    let upL3 = hrAdaptiveStepForLevel(3)
    let upL4 = hrAdaptiveStepForLevel(4)
    let downL1 = hrAdaptiveStepForLevel(1)
    let downL2 = hrAdaptiveStepForLevel(2)
    let downL3 = hrAdaptiveStepForLevel(3)
    let downL4 = hrAdaptiveStepForLevel(4)

    return [
        HrAdaptiveRangeRow(
            id: "hold",
            title: "Удержание",
            hrRangeText: hrAdaptiveHoldRangeText(targetBpm: targetBpm, thresholds: thresholds),
            diffText: hrAdaptiveHoldDiffText(targetBpm: targetBpm, thresholds: thresholds),
            stepTag: "HOLD-L0",
            deltaText: String(format: "%+.1f км/ч", 0.0),
            tint: .secondary
        ),
        HrAdaptiveRangeRow(
            id: "up-l1",
            title: "HR ниже цели (мягко)",
            hrRangeText: hrAdaptiveHrRangeBelowText(targetBpm: targetBpm, minAbsDiff: minActionDiffBpm, maxAbsDiff: max(minActionDiffBpm, upL2StartBpm - 1)),
            diffText: hrAdaptiveDiffText(targetBpm: targetBpm, minPercent: thresholds.deadbandPercent, maxPercent: thresholds.upLevel2StartPercent, signedDirection: -1),
            stepTag: "UP-L1",
            deltaText: hrAdaptiveDeltaText(stepKmh: upL1, direction: 1),
            tint: .green
        ),
        HrAdaptiveRangeRow(
            id: "up-l2",
            title: "HR ниже цели",
            hrRangeText: hrAdaptiveHrRangeBelowText(targetBpm: targetBpm, minAbsDiff: upL2StartBpm, maxAbsDiff: max(upL2StartBpm, upL3StartBpm - 1)),
            diffText: hrAdaptiveDiffText(targetBpm: targetBpm, minPercent: thresholds.upLevel2StartPercent, maxPercent: thresholds.upLevel3StartPercent, signedDirection: -1),
            stepTag: "UP-L2",
            deltaText: hrAdaptiveDeltaText(stepKmh: upL2, direction: 1),
            tint: .green
        ),
        HrAdaptiveRangeRow(
            id: "up-l3",
            title: "HR ниже цели (агрессивнее)",
            hrRangeText: hrAdaptiveHrRangeBelowText(targetBpm: targetBpm, minAbsDiff: upL3StartBpm, maxAbsDiff: max(upL3StartBpm, upL4StartBpm - 1)),
            diffText: hrAdaptiveDiffText(targetBpm: targetBpm, minPercent: thresholds.upLevel3StartPercent, maxPercent: thresholds.upLevel4StartPercent, signedDirection: -1),
            stepTag: "UP-L3",
            deltaText: hrAdaptiveDeltaText(stepKmh: upL3, direction: 1),
            tint: .green
        ),
        HrAdaptiveRangeRow(
            id: "up-l4",
            title: "HR ниже цели (максимум)",
            hrRangeText: hrAdaptiveHrRangeBelowText(targetBpm: targetBpm, minAbsDiff: upL4StartBpm, maxAbsDiff: nil),
            diffText: hrAdaptiveDiffText(targetBpm: targetBpm, minPercent: thresholds.upLevel4StartPercent, maxPercent: nil, signedDirection: -1),
            stepTag: "UP-L4",
            deltaText: hrAdaptiveDeltaText(stepKmh: upL4, direction: 1),
            tint: .green
        ),
        HrAdaptiveRangeRow(
            id: "down-l1",
            title: "HR выше цели (мягко)",
            hrRangeText: hrAdaptiveHrRangeAboveText(targetBpm: targetBpm, minAbsDiff: minActionDiffBpm, maxAbsDiff: max(minActionDiffBpm, downL2StartBpm - 1)),
            diffText: hrAdaptiveDiffText(targetBpm: targetBpm, minPercent: thresholds.deadbandPercent, maxPercent: thresholds.downLevel2StartPercent, signedDirection: 1),
            stepTag: "DOWN-L1",
            deltaText: hrAdaptiveDeltaText(stepKmh: downL1, direction: -1),
            tint: .orange
        ),
        HrAdaptiveRangeRow(
            id: "down-l2",
            title: "HR выше цели",
            hrRangeText: hrAdaptiveHrRangeAboveText(targetBpm: targetBpm, minAbsDiff: downL2StartBpm, maxAbsDiff: max(downL2StartBpm, downL3StartBpm - 1)),
            diffText: hrAdaptiveDiffText(targetBpm: targetBpm, minPercent: thresholds.downLevel2StartPercent, maxPercent: thresholds.downLevel3StartPercent, signedDirection: 1),
            stepTag: "DOWN-L2",
            deltaText: hrAdaptiveDeltaText(stepKmh: downL2, direction: -1),
            tint: .orange
        ),
        HrAdaptiveRangeRow(
            id: "down-l3",
            title: "HR выше цели (агрессивнее)",
            hrRangeText: hrAdaptiveHrRangeAboveText(targetBpm: targetBpm, minAbsDiff: downL3StartBpm, maxAbsDiff: max(downL3StartBpm, downL4StartBpm - 1)),
            diffText: hrAdaptiveDiffText(targetBpm: targetBpm, minPercent: thresholds.downLevel3StartPercent, maxPercent: thresholds.downLevel4StartPercent, signedDirection: 1),
            stepTag: "DOWN-L3",
            deltaText: hrAdaptiveDeltaText(stepKmh: downL3, direction: -1),
            tint: .orange
        ),
        HrAdaptiveRangeRow(
            id: "down-l4",
            title: "HR выше цели (максимум)",
            hrRangeText: hrAdaptiveHrRangeAboveText(targetBpm: targetBpm, minAbsDiff: downL4StartBpm, maxAbsDiff: nil),
            diffText: hrAdaptiveDiffText(targetBpm: targetBpm, minPercent: thresholds.downLevel4StartPercent, maxPercent: nil, signedDirection: 1),
            stepTag: "DOWN-L4",
            deltaText: hrAdaptiveDeltaText(stepKmh: downL4, direction: -1),
            tint: .orange
        )
    ]
}

private func hrAdaptiveDecisionPreview(
    currentBpm: Int,
    targetBpm: Int,
    fixedStepKmh: Double,
    adaptiveEnabled: Bool,
    thresholds: HrAdaptiveUiThresholds
) -> HrAdaptiveDecisionPreview {
    let diff = currentBpm - targetBpm
    let absDiff = abs(diff)
    let diffPercent = hrAdaptiveDiffPercent(absDiff: absDiff, targetBpm: targetBpm)
    let fixedBaseStep = hrAdaptiveClampStep(fixedStepKmh)
    let deadbandBpm = hrAdaptiveDiffBpm(forPercent: thresholds.deadbandPercent, targetBpm: targetBpm)

    if absDiff <= deadbandBpm {
        return HrAdaptiveDecisionPreview(
            label: "HOLD",
            details: "Δ \(diff) bpm (в пределах deadband \(hrAdaptiveHoldDiffText(targetBpm: targetBpm, thresholds: thresholds))) -> скорость без изменений",
            color: .secondary
        )
    }

    if !adaptiveEnabled {
        let fixedStep = hrAdaptiveQuantizeStep(fixedBaseStep)
        let isDown = diff > 0
        let delta = isDown ? -fixedStep : fixedStep
        return HrAdaptiveDecisionPreview(
            label: isDown ? "DOWN-FIXED" : "UP-FIXED",
            details: String(format: "Δ %d bpm -> шаг %+.1f км/ч", diff, delta),
            color: isDown ? .orange : .green
        )
    }

    let isIncreasingSpeed = diff < 0
    let selection = hrAdaptiveSelection(
        diffPercent: diffPercent,
        isIncreasingSpeed: isIncreasingSpeed,
        thresholds: thresholds
    )
    let directionLabel = diff > 0 ? "DOWN" : "UP"
    let delta = diff > 0 ? -selection.stepKmh : selection.stepKmh
    return HrAdaptiveDecisionPreview(
        label: "\(directionLabel)-L\(selection.level)",
        details: String(format: "Δ %d bpm -> шаг %+.1f км/ч", diff, delta),
        color: diff > 0 ? .orange : .green
    )
}

private struct HRControlPanel: View {
    @EnvironmentObject private var manager: BluetoothManager
    private let debugPreview: HRControlPanelPreviewState?
    @State private var showExportButton = false
    @State private var hrFailureBaselineCount = 0
    @State private var showExtendConfirm = false
    @State private var selectedWatchIssue: HrWatchIssue?

    init(debugPreview: HRControlPanelPreviewState? = nil) {
        self.debugPreview = debugPreview
    }

    var body: some View {
        let isPreviewMode = (debugPreview != nil)
        let isHrControlRunning = debugPreview?.isHrControlRunning ?? manager.isHrControlRunning
        let hrNextDecisionSeconds = debugPreview?.hrNextDecisionSeconds ?? manager.hrNextDecisionSeconds
        let hrPredictorStatusLine = debugPreview?.hrPredictorStatusLine ?? manager.hrPredictorStatusLine
        let hrDecisionDetails = debugPreview?.hrDecisionDetails ?? manager.hrDecisionDetails
        let hrRemainingSeconds = debugPreview?.hrRemainingSeconds ?? manager.hrRemainingSeconds
        let hrCooldownRemainingSeconds = debugPreview?.hrCooldownRemainingSeconds ?? manager.hrCooldownRemainingSeconds
        let hrProgress = debugPreview?.hrProgress ?? manager.hrProgress
        let hrCooldownProgress = debugPreview?.hrCooldownProgress ?? manager.hrCooldownProgress
        let hrStreamingActive = debugPreview?.hrStreamingActive ?? manager.hrStreamingActive
        let hrStatusLine = debugPreview?.hrStatusLine ?? manager.hrStatusLine
        let canExtendHrSession = debugPreview?.canExtendHrSession ?? manager.canExtendHrSession
        let hrSessionMaxMinutes = debugPreview?.hrSessionMaxMinutes ?? manager.hrSessionMaxMinutes
        let canStartHrControl = manager.isHrControlStartAffordanceAvailable
        let headerTint: Color = isHrControlRunning ? .accentColor : (hrStreamingActive ? .green : .orange)
        let hrStartSubtitle: String = {
            if isPreviewMode {
                return "Preview mode: команды на дорожку отключены"
            }
            if let blockReason = manager.hrControlStartBlockReasonText {
                return blockReason
            }
            if canStartHrControl {
                return "Автоподстройка скорости по пульсу и зоне"
            }
            return manager.hrControlStartBlockReasonText ?? "Проверьте дорожку и Apple Watch"
        }()

        Card {
            let watchIssue = hrWatchIssue(for: manager)
            VStack(alignment: .leading, spacing: 14) {
                if !isHrControlRunning {
                    VStack(alignment: .leading, spacing: 10) {
                        HRControlHeaderRow(watchIssue: watchIssue) { issue in
                            selectedWatchIssue = issue
                        }
                        HStack(spacing: 8) {
                            hrInfoChip(title: "Цель", value: "\(manager.hrTargetBPM) bpm", tint: .red)
                            hrInfoChip(
                                title: "Шаг",
                                value: manager.hrAdaptiveStepEnabled
                                    ? "Адаптивный"
                                    : String(format: "%.1f км/ч", manager.hrSpeedStepKmh),
                                tint: .blue
                            )
                            hrInfoChip(title: "Заминка", value: "\(manager.hrCooldownTargetBpm) bpm", tint: .mint)
                        }
                    }
                    .alert(item: $selectedWatchIssue) { issue in
                        Alert(
                            title: Text(issue.title),
                            message: Text(issue.message),
                            dismissButton: .cancel(Text("OK"))
                        )
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [headerTint.opacity(0.2), Color(.secondarySystemGroupedBackground)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(headerTint.opacity(0.25), lineWidth: 1)
                    )
                }

                if isHrControlRunning {
                    runningStatusSection(
                        isPreviewMode: isPreviewMode,
                        hrNextDecisionSeconds: hrNextDecisionSeconds,
                        hrPredictorStatusLine: hrPredictorStatusLine,
                        hrDecisionDetails: hrDecisionDetails,
                        hrRemainingSeconds: hrRemainingSeconds,
                        hrCooldownRemainingSeconds: hrCooldownRemainingSeconds,
                        hrProgress: hrProgress,
                        hrCooldownProgress: hrCooldownProgress,
                        canExtendHrSession: canExtendHrSession,
                        hrSessionMaxMinutes: hrSessionMaxMinutes
                    )
                }

                if !isHrControlRunning && showExportButton && !manager.hrFailureReports.isEmpty {
                    Button("Экспорт логов HR ошибок") {
                        #if canImport(UIKit)
                        exportHrFailures(reports: manager.hrFailureReports)
                        #endif
                        showExportButton = false
                    }
                    .buttonStyle(.borderedProminent)
                }

                if !isHrControlRunning {
                    VStack(alignment: .leading, spacing: 10) {
                        let ranges = hrZoneRanges(for: manager)
                        let selectedZone = hrZoneIndex(for: manager.hrTargetBPM, manager: manager) + 1
                        let zoneColumns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

                        Text("Целевая зона")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        LazyVGrid(columns: zoneColumns, spacing: 8) {
                            ForEach(1...5, id: \.self) { zone in
                                let range = ranges[zone - 1]
                                let target = hrZoneTargetBpm(zone: zone, range: range)
                                let isSelected = zone == selectedZone
                                let zoneColorValue = hrZoneColor(zone)
                                Button {
                                    manager.hrTargetBPM = target
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Зона \(zone)")
                                            .font(.caption.weight(.semibold))
                                        Text("\(range.lowerBound)–\(range.upperBound)")
                                            .font(.caption2)
                                            .monospacedDigit()
                                    }
                                    .foregroundColor(isSelected ? .white : .primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(
                                                LinearGradient(
                                                    colors: [
                                                        zoneColorValue.opacity(isSelected ? 0.95 : 0.12),
                                                        zoneColorValue.opacity(isSelected ? 0.75 : 0.08)
                                                    ],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(
                                                isSelected ? Color.white.opacity(0.9) : zoneColorValue.opacity(0.35),
                                                lineWidth: isSelected ? 2 : 1
                                            )
                                    )
                                    .overlay(alignment: .topTrailing) {
                                        if isSelected {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundColor(.white)
                                                .padding(6)
                                        }
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .scaleEffect(isSelected ? 1.03 : 1.0)
                                    .shadow(color: zoneColorValue.opacity(isSelected ? 0.35 : 0), radius: isSelected ? 8 : 0, x: 0, y: 4)
                                }
                                .buttonStyle(.plain)
                            }
                            HRDurationMenuTile(minutes: Binding(
                                get: { manager.hrDurationMinutes },
                                set: { manager.hrDurationMinutes = max(1, min(120, $0)) }
                            ))
                        }

                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color(.tertiarySystemFill), lineWidth: 1)
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        NavigationLink {
                            HRParametersFormView()
                                .environmentObject(manager)
                        } label: {
                            HStack(spacing: 8) {
                                Text("Параметры")
                                    .font(.subheadline)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                            }
                        }

                        Text("Ограничения заминки: ≥\(String(format: "%.1f", manager.hrCooldownMinSpeed)) км/ч, до \(manager.hrCooldownMaxMinutes) мин")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color(.tertiarySystemFill), lineWidth: 1)
                    )
                }

                if isHrControlRunning && !hrStreamingActive {
                    Label("Нет сигнала пульса", systemImage: "waveform.path.ecg")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.orange.opacity(0.14))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                        )
                }

                if !isHrControlRunning {
                    PrimaryActionButton(
                        title: isPreviewMode ? "HR‑контроль (preview)" : "Запустить HR‑контроль",
                        subtitle: hrStartSubtitle,
                        systemImage: "heart.circle.fill",
                        enabled: !isPreviewMode && canStartHrControl,
                        tint: .accentColor,
                        accessibilityLabel: "Запустить HR-контроль",
                        accessibilityHint: "Запускает автоматическую тренировку с контролем по пульсу"
                    ) {
                        if !isPreviewMode {
                            manager.startHrControl()
                        }
                    }
                }

                if !hrStatusLine.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.secondary)
                        Text(hrStatusLine)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                }
            }
        }
        .onChange(of: manager.isHrControlRunning) { _, newValue in
            guard !isPreviewMode else { return }
            if newValue {
                hrFailureBaselineCount = manager.hrFailureReports.count
                showExportButton = false
            } else {
                let newCount = manager.hrFailureReports.count
                if newCount > hrFailureBaselineCount {
                    showExportButton = true
                }
            }
        }
    }

    private func hrInfoChip(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.systemBackground).opacity(0.68))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(tint.opacity(0.24), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func progressBar(value: Double, height: CGFloat = 6) -> some View {
        let clamped = min(1.0, max(0.0, value))
        ProgressView(value: clamped)
            .progressViewStyle(.linear)
            .tint(.accentColor)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .clipShape(Capsule(style: .continuous))
    }

    @ViewBuilder
    private func runningMetaChip(title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .monospacedDigit()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.16))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(tint.opacity(0.34), lineWidth: 1)
            )
    }

    @ViewBuilder
    private func runningStatusSection(
        isPreviewMode: Bool,
        hrNextDecisionSeconds: Int,
        hrPredictorStatusLine: String,
        hrDecisionDetails: String,
        hrRemainingSeconds: Int,
        hrCooldownRemainingSeconds: Int,
        hrProgress: Double,
        hrCooldownProgress: Double,
        canExtendHrSession: Bool,
        hrSessionMaxMinutes: Int
    ) -> some View {
        let isMainSession = hrRemainingSeconds > 0
        let stageTitle = isMainSession ? "Тренировка" : "Заминка"
        let stageSymbol = isMainSession ? "figure.run" : "wind"
        let stageTint: Color = isMainSession ? .accentColor : .mint
        let remainingSeconds = isMainSession ? hrRemainingSeconds : hrCooldownRemainingSeconds
        let stageProgress = min(1.0, max(0.0, isMainSession ? hrProgress : hrCooldownProgress))
        let stageProgressPercent = Int((stageProgress * 100).rounded())
        let decisionText = hrDecisionDetails.isEmpty ? "Ожидание следующего решения" : hrDecisionDetails

        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Прогресс сессии")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(stageProgressPercent)%")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                progressBar(value: stageProgress, height: 10)
            }

            HStack(spacing: 8) {
                runningMetaChip(title: stageTitle.uppercased(), systemImage: stageSymbol, tint: stageTint)
                if hrNextDecisionSeconds > 0 {
                    runningMetaChip(
                        title: "След. решение через \(hrNextDecisionSeconds)с",
                        systemImage: "timer",
                        tint: stageTint
                    )
                }
            }

            if !hrPredictorStatusLine.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(stageTint)
                    Text(hrPredictorStatusLine)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineSpacing(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(.systemBackground).opacity(0.66))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(stageTint.opacity(0.2), lineWidth: 1)
                )
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Осталось")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(formattedDuration(remainingSeconds))
                        .font(.system(size: 42, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(isMainSession ? "до заминки" : "до завершения")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.systemBackground).opacity(0.72))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(stageTint.opacity(0.16), lineWidth: 1)
                )
                if isMainSession {
                    VStack(alignment: .trailing, spacing: 6) {
                        ExtendTimeButton(enabled: canExtendHrSession && !isPreviewMode) {
                            showExtendConfirm = true
                        }
                        .disabled(!canExtendHrSession || isPreviewMode)

                        ActionTileButton(
                            title: "Стоп",
                            subtitle: "Остановить",
                            enabled: !isPreviewMode,
                            tint: .red,
                            accessibilityLabel: "Остановить HR-контроль",
                            accessibilityHint: "Завершает текущую сессию HR-контроля"
                        ) {
                            if !isPreviewMode {
                                manager.stopHrControl()
                            }
                        }

                        if !canExtendHrSession {
                            Text("Лимит \(hrSessionMaxMinutes) мин")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("Решение алгоритма", systemImage: "brain.head.profile")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(stageTint)
                Text(decisionText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [stageTint.opacity(0.12), Color(.secondarySystemGroupedBackground)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(stageTint.opacity(0.2), lineWidth: 1)
            )

            if !isMainSession {
                ActionTileButton(
                    title: "Стоп",
                    subtitle: "Остановить",
                    enabled: !isPreviewMode,
                    tint: .red,
                    fullWidth: true,
                    accessibilityLabel: "Остановить HR-контроль",
                    accessibilityHint: "Завершает текущую сессию HR-контроля"
                ) {
                    if !isPreviewMode {
                        manager.stopHrControl()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            stageTint.opacity(0.16),
                            Color(.secondarySystemGroupedBackground),
                            Color(.secondarySystemGroupedBackground)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(stageTint.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: stageTint.opacity(0.1), radius: 12, x: 0, y: 6)
        .alert("Добавить 5 минут?", isPresented: $showExtendConfirm) {
            Button("Добавить") {
                if !isPreviewMode {
                    manager.extendHrSession(minutes: 5)
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Тренировка будет продлена на 5 минут.")
        }
    }

    private func formattedDuration(_ totalSeconds: Int) -> String {
        let safeSeconds = max(0, totalSeconds)
        let hours = safeSeconds / 3600
        let minutes = (safeSeconds % 3600) / 60
        let seconds = safeSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

}

private struct HRControlHeaderRow: View {
    let watchIssue: HrWatchIssue?
    let onWatchIssueTap: (HrWatchIssue) -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "heart.text.square.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text("HR‑контроль")
                    .font(.headline)
            }
            Spacer()
            if let watchIssue {
                Button {
                    onWatchIssueTap(watchIssue)
                } label: {
                    ZStack {
                        Circle()
                            .fill(watchIssue.color.opacity(0.2))
                            .frame(width: 30, height: 30)
                        Image(systemName: "applewatch")
                            .imageScale(.medium)
                            .foregroundColor(watchIssue.color)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Проблема подключения часов")
            }
        }
    }
}

private struct HRDurationMenuTile: View {
    @Binding var minutes: Int
    @State private var showDurationSheet = false

    var body: some View {
        Button {
            showDurationSheet = true
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Время")
                        .font(.caption.weight(.semibold))
                    Text("\(minutes) мин")
                        .font(.caption2)
                        .monospacedDigit()
                }
                Spacer(minLength: 4)
                Image(systemName: "clock.fill")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.16), Color.accentColor.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showDurationSheet) {
            HRDurationWheelSheet(minutes: $minutes)
        }
    }
}

private struct HRDurationWheelSheet: View {
    @Binding var minutes: Int
    @Environment(\.dismiss) private var dismiss
    @State private var draftMinutes: Int

    init(minutes: Binding<Int>) {
        _minutes = minutes
        _draftMinutes = State(initialValue: minutes.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("\(draftMinutes) мин")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()

                Picker("Длительность", selection: $draftMinutes) {
                    ForEach(1...120, id: \.self) { minute in
                        Text("\(minute) мин").tag(minute)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxHeight: 220)
                .clipped()

                HStack(spacing: 16) {
                    Button("- 5 мин") {
                        draftMinutes = max(1, draftMinutes - 5)
                    }
                    .buttonStyle(.bordered)

                    Button("+ 5 мин") {
                        draftMinutes = min(120, draftMinutes + 5)
                    }
                    .buttonStyle(.bordered)
                }

                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Длительность")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") {
                        minutes = draftMinutes
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

private struct HRParametersFormView: View {
    @EnvironmentObject private var manager: BluetoothManager
    @State private var showAdaptiveStepInfo = false
    @State private var previewHrBpm: Double = 130
    @State private var showCreateProfileAlert = false
    @State private var showRenameProfileAlert = false
    @State private var showDeleteProfileAlert = false
    @State private var newProfileName = ""
    @State private var renamedProfileName = ""

    var body: some View {
        Form {
            Section(
                header: Text("Профиль"),
                footer: Text("Профиль разделяет целевой пульс, длительность, заминку, кардио‑зоны, историю тренировок и training export. CSV и session summary теперь выгружаются только по активному профилю, а для объединения логов с разных телефонов дополнительно пишется installation_id.")
            ) {
                Picker("Активный профиль", selection: Binding(
                    get: { manager.activeUserProfileID },
                    set: { newValue in
                        guard let newValue else { return }
                        manager.selectUserProfile(id: newValue)
                    }
                )) {
                    ForEach(manager.userProfiles) { profile in
                        Text(profile.label).tag(Optional(profile.id))
                    }
                }
                .disabled(manager.isHrControlRunning)

                Button("Новый профиль") {
                    newProfileName = ""
                    showCreateProfileAlert = true
                }
                .disabled(manager.isHrControlRunning)

                Button("Переименовать текущий") {
                    renamedProfileName = manager.activeUserProfileLabel
                    showRenameProfileAlert = true
                }
                .disabled(manager.isHrControlRunning || manager.activeUserProfileID == nil)

                Button("Удалить текущий", role: .destructive) {
                    showDeleteProfileAlert = true
                }
                .disabled(manager.isHrControlRunning || manager.userProfiles.count <= 1)

                if manager.isHrControlRunning {
                    Text("Во время активной тренировки переключение и редактирование профиля заблокировано.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section(header: Text("Параметры")) {
                Toggle(isOn: Binding(
                    get: { manager.hrAdaptiveStepEnabled },
                    set: { manager.hrAdaptiveStepEnabled = $0 }
                )) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Адаптивный шаг")
                            Text(manager.hrAdaptiveStepEnabled
                                 ? "Уровни L1..L4 фиксированы: 0.1/0.2/0.3/0.4 км/ч"
                                 : "Фиксированный шаг скорости")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button {
                            showAdaptiveStepInfo = true
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 4)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Что такое адаптивный шаг")
                    }
                }
                .toggleStyle(.switch)
                .alert("Адаптивный шаг", isPresented: $showAdaptiveStepInfo) {
                    Button("Ок", role: .cancel) {}
                } message: {
                    Text("При включении используются фиксированные уровни: L1=0.1, L2=0.2, L3=0.3, L4=0.4 км/ч. Диапазоны переключения задаются в процентах от целевого пульса в секции ниже. В пределах deadband скорость удерживается.")
                }

                Stepper(value: Binding(
                    get: { manager.hrDecisionIntervalSeconds },
                    set: { manager.hrDecisionIntervalSeconds = max(1, min(60, $0)) }
                ), in: 1...60, step: 1) {
                    Text("Интервал решения: \(manager.hrDecisionIntervalSeconds) сек")
                        .monospacedDigit()
                }

                Stepper(value: Binding(
                    get: { manager.hrSpeedStepKmh },
                    set: {
                        let v = max(0.1, min(2.0, $0))
                        manager.hrSpeedStepKmh = (v * 10).rounded() / 10.0
                    }
                ), in: 0.1...2.0, step: 0.1) {
                    let title = manager.hrAdaptiveStepEnabled ? "Шаг FIXED/заминки: " : "Шаг скорости: "
                    Text(String(format: "%@%.1f км/ч", title, manager.hrSpeedStepKmh))
                        .monospacedDigit()
                }
            }

            Section(
                header: Text("Пороги адаптивного шага (%)"),
                footer: Text("Настройки применяются как процент отклонения от целевого пульса. Например, если для DOWN-L3 стоит 10%, то при превышении цели на 10% дорожка перейдет к более агрессивному снижению скорости.")
            ) {
                let downL1Delta = -hrAdaptiveStepForLevel(1)
                let downL2Delta = -hrAdaptiveStepForLevel(2)
                let downL3Delta = -hrAdaptiveStepForLevel(3)
                let upL1Delta = hrAdaptiveStepForLevel(1)
                let upL2Delta = hrAdaptiveStepForLevel(2)
                let upL3Delta = hrAdaptiveStepForLevel(3)

                let deadbandInt = Int(manager.hrAdaptiveDeadbandPercent.rounded(.down))
                let holdRangeText = String(format: "в диапазоне -%d%%...+%d%% -> %+.1f км/ч", deadbandInt, deadbandInt, 0.0)

                let downL1Start = deadbandInt + 1
                let downL1End = max(downL1Start, Int(manager.hrAdaptiveDownLevel2StartPercent.rounded(.up)) - 1)
                let downL2Start = Int(manager.hrAdaptiveDownLevel2StartPercent.rounded(.up))
                let downL2End = max(downL2Start, Int(manager.hrAdaptiveDownLevel3StartPercent.rounded(.up)) - 1)
                let downL3Start = Int(manager.hrAdaptiveDownLevel3StartPercent.rounded(.up))
                let downL3End = max(downL3Start, Int(manager.hrAdaptiveDownLevel4StartPercent.rounded(.up)) - 1)
                let downL4Start = Int(manager.hrAdaptiveDownLevel4StartPercent.rounded(.up))

                let upL1Start = -(deadbandInt + 1)
                let upL1End = min(upL1Start, -(Int(manager.hrAdaptiveUpLevel2StartPercent.rounded(.up)) - 1))
                let upL2Start = -Int(manager.hrAdaptiveUpLevel2StartPercent.rounded(.up))
                let upL2End = min(upL2Start, -(Int(manager.hrAdaptiveUpLevel3StartPercent.rounded(.up)) - 1))
                let upL3Start = -Int(manager.hrAdaptiveUpLevel3StartPercent.rounded(.up))
                let upL3End = min(upL3Start, -(Int(manager.hrAdaptiveUpLevel4StartPercent.rounded(.up)) - 1))
                let upL4Start = -Int(manager.hrAdaptiveUpLevel4StartPercent.rounded(.up))

                Stepper(value: Binding(
                    get: { manager.hrAdaptiveDeadbandPercent },
                    set: { setAdaptiveDeadbandPercent($0) }
                ), in: 1.0...15.0, step: 0.5) {
                    Text(String(format: "Deadband (HOLD): ±%.1f%%", manager.hrAdaptiveDeadbandPercent))
                        .monospacedDigit()
                }
                Text(holdRangeText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()

                Text(String(format: "DOWN-L1: +%d%%...+%d%% -> %+.1f км/ч", downL1Start, downL1End, downL1Delta))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()

                Stepper(value: Binding(
                    get: { manager.hrAdaptiveDownLevel2StartPercent },
                    set: { setAdaptiveDownLevel2StartPercent($0) }
                ), in: (manager.hrAdaptiveDeadbandPercent + 0.5)...30.0, step: 0.5) {
                    Text(String(format: "DOWN-L2: +%d%%...+%d%% -> %+.1f км/ч", downL2Start, downL2End, downL2Delta))
                        .monospacedDigit()
                }

                Stepper(value: Binding(
                    get: { manager.hrAdaptiveDownLevel3StartPercent },
                    set: { setAdaptiveDownLevel3StartPercent($0) }
                ), in: (manager.hrAdaptiveDownLevel2StartPercent + 0.5)...40.0, step: 0.5) {
                    Text(String(format: "DOWN-L3: +%d%%...+%d%% -> %+.1f км/ч", downL3Start, downL3End, downL3Delta))
                        .monospacedDigit()
                }

                Stepper(value: Binding(
                    get: { manager.hrAdaptiveDownLevel4StartPercent },
                    set: { setAdaptiveDownLevel4StartPercent($0) }
                ), in: (manager.hrAdaptiveDownLevel3StartPercent + 0.5)...60.0, step: 0.5) {
                    Text(String(format: "DOWN-L4: >= +%d%% -> %+.1f км/ч", downL4Start, -hrAdaptiveStepForLevel(4)))
                        .monospacedDigit()
                }

                Text(String(format: "UP-L1: %d%%...%d%% -> %+.1f км/ч", upL1Start, upL1End, upL1Delta))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()

                Stepper(value: Binding(
                    get: { manager.hrAdaptiveUpLevel2StartPercent },
                    set: { setAdaptiveUpLevel2StartPercent($0) }
                ), in: (manager.hrAdaptiveDeadbandPercent + 0.5)...40.0, step: 0.5) {
                    Text(String(format: "UP-L2: %d%%...%d%% -> %+.1f км/ч", upL2Start, upL2End, upL2Delta))
                        .monospacedDigit()
                }

                Stepper(value: Binding(
                    get: { manager.hrAdaptiveUpLevel3StartPercent },
                    set: { setAdaptiveUpLevel3StartPercent($0) }
                ), in: (manager.hrAdaptiveUpLevel2StartPercent + 0.5)...60.0, step: 0.5) {
                    Text(String(format: "UP-L3: %d%%...%d%% -> %+.1f км/ч", upL3Start, upL3End, upL3Delta))
                        .monospacedDigit()
                }

                Stepper(value: Binding(
                    get: { manager.hrAdaptiveUpLevel4StartPercent },
                    set: { setAdaptiveUpLevel4StartPercent($0) }
                ), in: (manager.hrAdaptiveUpLevel3StartPercent + 0.5)...80.0, step: 0.5) {
                    Text(String(format: "UP-L4: <= %d%% -> %+.1f км/ч", upL4Start, hrAdaptiveStepForLevel(4)))
                        .monospacedDigit()
                }
            }

            Section(
                header: Text("Наглядный шаг"),
                footer: Text("Таблица ниже считается от текущих параметров (цель + шаг). Во время реальной тренировки ускорение может дополнительно блокироваться логикой инерции по тренду/прогнозу пульса.")
            ) {
                let sampleBpm = max(60, min(220, Int(previewHrBpm.rounded())))
                let adaptiveThresholds = hrAdaptiveThresholds(for: manager)
                let preview = hrAdaptiveDecisionPreview(
                    currentBpm: sampleBpm,
                    targetBpm: manager.hrTargetBPM,
                    fixedStepKmh: manager.hrSpeedStepKmh,
                    adaptiveEnabled: manager.hrAdaptiveStepEnabled,
                    thresholds: adaptiveThresholds
                )

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Пример HR")
                        Spacer()
                        Text("\(sampleBpm) bpm")
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                    Slider(value: Binding(
                        get: { previewHrBpm },
                        set: { previewHrBpm = max(60, min(220, $0)) }
                    ), in: 60...220, step: 1)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(preview.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(preview.color)
                    Text(preview.details)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                ForEach(hrAdaptiveRows(
                    targetBpm: manager.hrTargetBPM,
                    fixedStepKmh: manager.hrSpeedStepKmh,
                    adaptiveEnabled: manager.hrAdaptiveStepEnabled,
                    thresholds: adaptiveThresholds
                )) { row in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.title)
                                .font(.subheadline.weight(.semibold))
                            Text("HR: \(row.hrRangeText)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Δ: \(row.diffText)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(row.stepTag)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(row.tint)
                            Text(row.deltaText)
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundColor(row.tint)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section(header: Text("Целевой пульс")) {
                Stepper(value: Binding(
                    get: { manager.hrTargetBPM },
                    set: { manager.hrTargetBPM = max(60, min(220, $0)) }
                ), in: 60...220, step: 5) {
                    Text("Целевой пульс: \(manager.hrTargetBPM) bpm")
                        .monospacedDigit()
                }
                Picker("Быстрый выбор", selection: Binding(
                    get: { manager.hrTargetBPM },
                    set: { manager.hrTargetBPM = $0 }
                )) {
                    ForEach([110, 120, 130, 135, 140], id: \.self) { t in
                        Text("\(t)").tag(t)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section(header: Text("Длительность")) {
                Stepper(value: Binding(
                    get: { manager.hrDurationMinutes },
                    set: { manager.hrDurationMinutes = max(1, min(120, $0)) }
                ), in: 1...120, step: 1) {
                    Text("Длительность: \(manager.hrDurationMinutes) мин")
                        .monospacedDigit()
                }
                Picker("Быстрый выбор", selection: Binding(
                    get: { manager.hrDurationMinutes },
                    set: { manager.hrDurationMinutes = $0 }
                )) {
                    ForEach([5, 10, 15, 20, 30], id: \.self) { m in
                        Text("\(m)").tag(m)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section(
                header: Text("Заминка"),
                footer: Text("Во время заминки скорость только снижается. Завершение — когда скорость ≤ минимума и пульс ≤ цели 20 сек подряд, либо по таймауту времени заминки.")
            ) {
                Stepper(value: Binding(
                    get: { manager.hrCooldownTargetBpm },
                    set: { manager.hrCooldownTargetBpm = max(80, min(140, $0)) }
                ), in: 80...140, step: 5) {
                    Text("Целевой пульс: \(manager.hrCooldownTargetBpm) bpm")
                        .monospacedDigit()
                }
                Stepper(value: Binding(
                    get: { manager.hrCooldownMinSpeed },
                    set: {
                        let v = max(2.0, min(6.0, $0))
                        manager.hrCooldownMinSpeed = (v * 10).rounded() / 10.0
                    }
                ), in: 2.0...6.0, step: 0.1) {
                    Text(String(format: "Минимальная скорость: %.1f км/ч", manager.hrCooldownMinSpeed))
                        .monospacedDigit()
                }
                Stepper(value: Binding(
                    get: { manager.hrCooldownMaxMinutes },
                    set: { manager.hrCooldownMaxMinutes = max(1, min(30, $0)) }
                ), in: 1...30, step: 1) {
                    Text("Время заминки: \(manager.hrCooldownMaxMinutes) мин")
                        .monospacedDigit()
                }
            }

            Section(
                header: Text("Кардио‑зоны"),
                footer: Text("Границы задаются верхней границей зоны. Зона 5 начинается выше границы зоны 4.")
            ) {
                Stepper(value: Binding(
                    get: { manager.hrZone1Max },
                    set: { manager.hrZone1Max = max(80, min(200, $0)) }
                ), in: 80...200, step: 1) {
                    Text("Зона 1: ≤ \(manager.hrZone1Max) bpm")
                        .monospacedDigit()
                }

                Stepper(value: Binding(
                    get: { manager.hrZone2Max },
                    set: { manager.hrZone2Max = max(81, min(210, $0)) }
                ), in: 81...210, step: 1) {
                    Text("Зона 2: ≤ \(manager.hrZone2Max) bpm")
                        .monospacedDigit()
                }

                Stepper(value: Binding(
                    get: { manager.hrZone3Max },
                    set: { manager.hrZone3Max = max(82, min(220, $0)) }
                ), in: 82...220, step: 1) {
                    Text("Зона 3: ≤ \(manager.hrZone3Max) bpm")
                        .monospacedDigit()
                }

                Stepper(value: Binding(
                    get: { manager.hrZone4Max },
                    set: { manager.hrZone4Max = max(83, min(230, $0)) }
                ), in: 83...230, step: 1) {
                    Text("Зона 4: ≤ \(manager.hrZone4Max) bpm")
                        .monospacedDigit()
                }

                Text("Зона 5: ≥ \(manager.hrZone4Max + 1) bpm")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section(
                header: Text("Тренд пульса"),
                footer: Text("Меньше окно и больше α — тренд живее. Больше окно и ниже лимит — спокойнее.")
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Окно тренда")
                        Spacer()
                        Text("\(Int(manager.hrTrendWindowSeconds)) сек")
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                    Slider(value: Binding(
                        get: { manager.hrTrendWindowSeconds },
                        set: { manager.hrTrendWindowSeconds = max(15, min(30, $0)) }
                    ), in: 15...30, step: 1)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Сглаживание (α)")
                        Spacer()
                        Text(String(format: "%.2f", manager.hrTrendEmaAlpha))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                    Slider(value: Binding(
                        get: { manager.hrTrendEmaAlpha },
                        set: { manager.hrTrendEmaAlpha = max(0.2, min(0.4, $0)) }
                    ), in: 0.2...0.4, step: 0.05)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Лимит тренда")
                        Spacer()
                        let bpmPerMin = Int(round(manager.hrTrendSlopeMaxBpmPerSecond * 60.0))
                        Text("±\(bpmPerMin) bpm/мин")
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                    Slider(value: Binding(
                        get: { manager.hrTrendSlopeMaxBpmPerSecond * 60.0 },
                        set: { manager.hrTrendSlopeMaxBpmPerSecond = max(0.3, min(1.0, $0 / 60.0)) }
                    ), in: 18...60, step: 2)
                }
            }
        }
        .navigationTitle("Параметры")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            previewHrBpm = Double(manager.hrTargetBPM)
        }
        .onChange(of: manager.activeUserProfileID) { _, _ in
            previewHrBpm = Double(manager.hrTargetBPM)
        }
        .alert("Новый профиль", isPresented: $showCreateProfileAlert) {
            TextField("Имя профиля", text: $newProfileName)
            Button("Отмена", role: .cancel) {}
            Button("Создать") {
                manager.createUserProfile(named: newProfileName)
            }
        } message: {
            Text("Новый профиль создаётся как копия текущих настроек, но с пустой историей тренировок.")
        }
        .alert("Переименовать профиль", isPresented: $showRenameProfileAlert) {
            TextField("Имя профиля", text: $renamedProfileName)
            Button("Отмена", role: .cancel) {}
            Button("Сохранить") {
                manager.renameActiveUserProfile(to: renamedProfileName)
            }
        } message: {
            Text("Новое имя попадёт и в будущие тренировочные логи.")
        }
        .alert("Удалить профиль?", isPresented: $showDeleteProfileAlert) {
            Button("Отмена", role: .cancel) {}
            Button("Удалить", role: .destructive) {
                manager.deleteActiveUserProfile()
            }
        } message: {
            Text("Будут удалены локальные настройки и история текущего профиля. Уже записанные raw-логи на диске останутся как архив.")
        }
    }

    private func quantizedPercent(_ value: Double) -> Double {
        (value * 2.0).rounded() / 2.0
    }

    private func clampAdaptivePercent(_ value: Double, min lowerBound: Double, max upperBound: Double) -> Double {
        let lower = quantizedPercent(lowerBound)
        let upper = max(lower, quantizedPercent(upperBound))
        let clamped = max(lower, min(upper, value))
        return quantizedPercent(clamped)
    }

    private func setAdaptiveDeadbandPercent(_ value: Double) {
        let deadband = clampAdaptivePercent(value, min: 1.0, max: 15.0)
        manager.hrAdaptiveDeadbandPercent = deadband

        let downL2 = clampAdaptivePercent(manager.hrAdaptiveDownLevel2StartPercent, min: deadband + 0.5, max: 30.0)
        manager.hrAdaptiveDownLevel2StartPercent = downL2

        let downL3 = clampAdaptivePercent(manager.hrAdaptiveDownLevel3StartPercent, min: downL2 + 0.5, max: 40.0)
        manager.hrAdaptiveDownLevel3StartPercent = downL3
        manager.hrAdaptiveDownLevel4StartPercent = clampAdaptivePercent(manager.hrAdaptiveDownLevel4StartPercent, min: downL3 + 0.5, max: 60.0)

        let upL2 = clampAdaptivePercent(manager.hrAdaptiveUpLevel2StartPercent, min: deadband + 0.5, max: 40.0)
        manager.hrAdaptiveUpLevel2StartPercent = upL2
        let upL3 = clampAdaptivePercent(manager.hrAdaptiveUpLevel3StartPercent, min: upL2 + 0.5, max: 60.0)
        manager.hrAdaptiveUpLevel3StartPercent = upL3
        manager.hrAdaptiveUpLevel4StartPercent = clampAdaptivePercent(manager.hrAdaptiveUpLevel4StartPercent, min: upL3 + 0.5, max: 80.0)
    }

    private func setAdaptiveDownLevel2StartPercent(_ value: Double) {
        let downL2 = clampAdaptivePercent(value, min: manager.hrAdaptiveDeadbandPercent + 0.5, max: 30.0)
        manager.hrAdaptiveDownLevel2StartPercent = downL2
        let downL3 = clampAdaptivePercent(manager.hrAdaptiveDownLevel3StartPercent, min: downL2 + 0.5, max: 40.0)
        manager.hrAdaptiveDownLevel3StartPercent = downL3
        manager.hrAdaptiveDownLevel4StartPercent = clampAdaptivePercent(manager.hrAdaptiveDownLevel4StartPercent, min: downL3 + 0.5, max: 60.0)
    }

    private func setAdaptiveDownLevel3StartPercent(_ value: Double) {
        let downL3 = clampAdaptivePercent(value, min: manager.hrAdaptiveDownLevel2StartPercent + 0.5, max: 40.0)
        manager.hrAdaptiveDownLevel3StartPercent = downL3
        manager.hrAdaptiveDownLevel4StartPercent = clampAdaptivePercent(manager.hrAdaptiveDownLevel4StartPercent, min: downL3 + 0.5, max: 60.0)
    }

    private func setAdaptiveDownLevel4StartPercent(_ value: Double) {
        manager.hrAdaptiveDownLevel4StartPercent = clampAdaptivePercent(value, min: manager.hrAdaptiveDownLevel3StartPercent + 0.5, max: 60.0)
    }

    private func setAdaptiveUpLevel2StartPercent(_ value: Double) {
        let upL2 = clampAdaptivePercent(value, min: manager.hrAdaptiveDeadbandPercent + 0.5, max: 40.0)
        manager.hrAdaptiveUpLevel2StartPercent = upL2
        let upL3 = clampAdaptivePercent(manager.hrAdaptiveUpLevel3StartPercent, min: upL2 + 0.5, max: 60.0)
        manager.hrAdaptiveUpLevel3StartPercent = upL3
        manager.hrAdaptiveUpLevel4StartPercent = clampAdaptivePercent(manager.hrAdaptiveUpLevel4StartPercent, min: upL3 + 0.5, max: 80.0)
    }

    private func setAdaptiveUpLevel3StartPercent(_ value: Double) {
        let upL3 = clampAdaptivePercent(value, min: manager.hrAdaptiveUpLevel2StartPercent + 0.5, max: 60.0)
        manager.hrAdaptiveUpLevel3StartPercent = upL3
        manager.hrAdaptiveUpLevel4StartPercent = clampAdaptivePercent(manager.hrAdaptiveUpLevel4StartPercent, min: upL3 + 0.5, max: 80.0)
    }

    private func setAdaptiveUpLevel4StartPercent(_ value: Double) {
        manager.hrAdaptiveUpLevel4StartPercent = clampAdaptivePercent(value, min: manager.hrAdaptiveUpLevel3StartPercent + 0.5, max: 80.0)
    }
}

private struct WorkoutStatsView: View {
    @EnvironmentObject private var manager: BluetoothManager

    private enum StatsScope: String, CaseIterable, Hashable {
        case week
        case month

        var title: String {
            switch self {
            case .week: return "Неделя"
            case .month: return "Месяц"
            }
        }
    }

    private struct StatsPageHeightPreferenceKey: PreferenceKey {
        static var defaultValue: [StatsScope: CGFloat] = [:]

        static func reduce(value: inout [StatsScope: CGFloat], nextValue: () -> [StatsScope: CGFloat]) {
            value.merge(nextValue(), uniquingKeysWith: { _, new in new })
        }
    }

    @State private var scope: StatsScope = .week
    @State private var weekOffset: Int = 0
    @State private var monthOffset: Int = 0
    @State private var showPlanSheet: Bool = false
    @State private var pageHeights: [StatsScope: CGFloat] = [:]

    private var scopeSelection: Binding<StatsScope> {
        Binding(
            get: { scope },
            set: { newValue in
                withAnimation(.easeInOut(duration: 0.25)) {
                    scope = newValue
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    periodPicker
                        .padding(.horizontal)
                        .padding(.top, 8)

                    TabView(selection: scopeSelection) {
                        statsSummaryPage(for: .week)
                            .tag(StatsScope.week)
                        statsSummaryPage(for: .month)
                            .tag(StatsScope.month)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(height: currentPageHeight)
                    .onPreferenceChange(StatsPageHeightPreferenceKey.self) { values in
                        pageHeights.merge(values, uniquingKeysWith: { _, new in new })
                    }

                    WorkoutHistoryCard(
                        entries: manager.telemetryV2WorkoutHistory,
                        readState: manager.telemetryV2WorkoutHistoryState,
                        hasMore: manager.telemetryV2WorkoutHistoryHasMore,
                        onRetry: { manager.refreshWorkoutHistoryFromV2(reset: true) },
                        onLoadMore: { manager.loadNextWorkoutHistoryPageFromV2() }
                    )
                    .padding(.horizontal)
                    .padding(.bottom)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("План") { showPlanSheet = true }
                }
            }
            .sheet(isPresented: $showPlanSheet) {
                ZonePlanSheet(planMinutes: $manager.zonePlanMinutes, ranges: zoneRanges)
            }
        }
    }

    private var currentPageHeight: CGFloat {
        max(320, pageHeights[scope] ?? pageHeights.values.max() ?? 1)
    }

    private var calendar: Calendar {
        var cal = Calendar(identifier: .iso8601)
        cal.locale = Locale.current
        return cal
    }

    private func offset(for scope: StatsScope) -> Int {
        switch scope {
        case .week: return weekOffset
        case .month: return monthOffset
        }
    }

    private func canGoForward(for scope: StatsScope) -> Bool {
        offset(for: scope) < 0
    }

    private func currentInterval(for scope: StatsScope) -> DateInterval {
        interval(for: scope, offset: offset(for: scope))
    }

    private var periodPicker: some View {
        Picker("Период", selection: scopeSelection) {
            ForEach(StatsScope.allCases, id: \.self) { item in
                Text(item.title).tag(item)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private func statsSummaryPage(for scope: StatsScope) -> some View {
        let interval = currentInterval(for: scope)
        VStack(spacing: 16) {
            periodHeader(for: scope)
            statsCard(scope: scope, title: scope.title, interval: interval)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: StatsPageHeightPreferenceKey.self,
                    value: [scope: proxy.size.height]
                )
            }
        )
        .task(id: "\(manager.workoutStatisticsKey(for: interval))|\(manager.telemetryV2ProjectionGeneration)") {
            manager.refreshWorkoutStatisticsFromV2(for: interval)
        }
    }

    private func periodHeader(for scope: StatsScope) -> some View {
        HStack {
            Button {
                shiftPeriod(by: -1, for: scope)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)

            Spacer()

            Text(rangeTitle(for: currentInterval(for: scope), scope: scope))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()

            Spacer()

            Button {
                shiftPeriod(by: 1, for: scope)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(!canGoForward(for: scope))
            .opacity(canGoForward(for: scope) ? 1.0 : 0.35)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func statsCard(scope: StatsScope, title: String, interval: DateInterval) -> some View {
        let key = manager.workoutStatisticsKey(for: interval)
        let stats = manager.telemetryV2Statistics[key]
        let state = manager.telemetryV2StatisticsState[key] ?? .idle
        let totalTime = formatTotalTime(stats?.totalDurationSeconds)
        let beatsValue = stats?.averageBeatsPerMetre.map { String(format: "%.2f", $0) } ?? "—"

        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)

                HStack(spacing: 16) {
                    StatTile(title: "Время", value: totalTime, unit: "")
                    StatTile(title: "Удары/м", value: beatsValue, unit: "")
                }

                if case .loading = state, stats == nil {
                    ProgressView("Чтение Telemetry V2…")
                        .font(.caption)
                }
                if case let .failed(message) = state {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Telemetry V2 недоступна: \(message)")
                            .font(.caption)
                            .foregroundColor(.red)
                        if stats != nil {
                            Text("Ниже показан последний успешный V2 snapshot; обновление не выполнено.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Button("Повторить") {
                            manager.refreshWorkoutStatisticsFromV2(for: interval)
                        }
                        .buttonStyle(.bordered)
                    }
                }

                zoneSummaryList(scope: scope, zoneSeconds: stats?.zoneSeconds)

                if stats?.isPartial == true {
                    Text("Часть метрик недоступна; пропуски показаны как «—» и не заменены нулями.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var zoneRanges: [String] {
        (0..<5).map { zoneRangeText(index: $0) }
    }

    @ViewBuilder
    private func zoneSummaryList(scope: StatsScope, zoneSeconds: [Double?]?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<5, id: \.self) { idx in
                let seconds = zoneSeconds.flatMap { idx < $0.count ? $0[idx] : nil }
                let actualMinutes = seconds.map { Int($0 / 60.0) }
                let monthPlan = idx < manager.zonePlanMinutes.count ? manager.zonePlanMinutes[idx] : 0
                let planMinutes = scope == .week ? Int(round(Double(monthPlan) / 4.0)) : monthPlan
                let progress = actualMinutes.map {
                    planMinutes > 0 ? min(1.0, Double($0) / Double(planMinutes)) : 0
                }
                ZoneSummaryRow(
                    title: "Зона \(idx + 1)",
                    rangeText: zoneRangeText(index: idx),
                    actualMinutes: actualMinutes,
                    planMinutes: planMinutes,
                    progress: progress,
                    color: zoneColor(index: idx)
                )
            }
        }
        .padding(.top, 2)
    }

    private func formatTotalTime(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours)ч \(minutes)м"
        }
        return "\(minutes)м"
    }

    private func interval(for scope: StatsScope, offset: Int) -> DateInterval {
        let now = Date()
        switch scope {
        case .week:
            let base = calendar.date(byAdding: .weekOfYear, value: offset, to: now) ?? now
            return calendar.dateInterval(of: .weekOfYear, for: base) ?? DateInterval(start: now, duration: 0)
        case .month:
            let base = calendar.date(byAdding: .month, value: offset, to: now) ?? now
            return calendar.dateInterval(of: .month, for: base) ?? DateInterval(start: now, duration: 0)
        }
    }

    private func shiftPeriod(by delta: Int, for scope: StatsScope) {
        switch scope {
        case .week:
            weekOffset += delta
        case .month:
            monthOffset += delta
        }
    }

    private func rangeTitle(for interval: DateInterval, scope: StatsScope) -> String {
        let start = interval.start
        let end = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end

        switch scope {
        case .month:
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.dateFormat = "LLLL yyyy"
            return formatter.string(from: start).capitalized
        case .week:
            let sameMonth = calendar.isDate(start, equalTo: end, toGranularity: .month)
            let sameYear = calendar.isDate(start, equalTo: end, toGranularity: .year)

            if sameMonth {
                let dayFormatter = DateFormatter()
                dayFormatter.locale = Locale.current
                dayFormatter.dateFormat = "d"
                let monthFormatter = DateFormatter()
                monthFormatter.locale = Locale.current
                monthFormatter.dateFormat = "MMM"
                return "\(dayFormatter.string(from: start))–\(dayFormatter.string(from: end)) \(monthFormatter.string(from: start))"
            }

            if sameYear {
                let formatter = DateFormatter()
                formatter.locale = Locale.current
                formatter.dateFormat = "d MMM"
                return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
            }

            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.dateFormat = "d MMM yyyy"
            return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
        }
    }

    private func zoneRangeText(index: Int) -> String {
        let z1 = manager.hrZone1Max
        let z2 = manager.hrZone2Max
        let z3 = manager.hrZone3Max
        let z4 = manager.hrZone4Max
        switch index {
        case 0: return "≤\(z1)"
        case 1: return "\(z1 + 1)–\(z2)"
        case 2: return "\(z2 + 1)–\(z3)"
        case 3: return "\(z3 + 1)–\(z4)"
        default: return "≥\(z4 + 1)"
        }
    }

    private func zoneColor(index: Int) -> Color {
        switch index {
        case 0: return Color.blue
        case 1: return Color.green
        case 2: return Color.yellow
        case 3: return Color.orange
        default: return Color.red
        }
    }

}

private struct ZoneSummaryRow: View {
    let title: String
    let rangeText: String
    let actualMinutes: Int?
    let planMinutes: Int
    let progress: Double?
    let color: Color

    var body: some View {
        let achieved = planMinutes > 0 && (actualMinutes ?? -1) >= planMinutes
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(achieved ? color : color)
                Text(rangeText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                if achieved {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundColor(color)
                }
            }
            HStack(spacing: 6) {
                Text(actualMinutes.map { "Факт \($0) мин" } ?? "Факт —")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("·")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if planMinutes > 0 {
                    Text("План \(planMinutes) мин")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Text("План —")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            if planMinutes > 0, let progress {
                ProgressView(value: min(1.0, max(0.0, progress)))
                    .progressViewStyle(.linear)
                    .tint(color)
            }
        }
    }
}

private struct ZonePlanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var planMinutes: [Int]
    let ranges: [String]

    var body: some View {
        NavigationStack {
            List {
                ForEach(0..<5, id: \.self) { idx in
                    let title = "Зона \(idx + 1)"
                    let range = idx < ranges.count ? ranges[idx] : ""
                    ZonePlanRow(
                        title: title,
                        rangeText: range,
                        value: binding(for: idx),
                        step: 5
                    )
                }
                Section(footer: Text("Недельный план считается автоматически: месяц / 4").font(.footnote)) {
                    EmptyView()
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("План по зонам")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    private func binding(for index: Int) -> Binding<Int> {
        Binding(
            get: {
                guard planMinutes.indices.contains(index) else { return 0 }
                return planMinutes[index]
            },
            set: { newValue in
                guard planMinutes.indices.contains(index) else { return }
                planMinutes[index] = max(0, min(2000, newValue))
            }
        )
    }
}

private struct ZonePlanRow: View {
    let title: String
    let rangeText: String
    @Binding var value: Int
    let step: Int

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(rangeText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text("\(value) мин/мес")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                Stepper("", value: $value, in: 0...2000, step: step)
                    .labelsHidden()
            }
        }
        .padding(.vertical, 4)
    }
}

private struct WorkoutHistoryCard: View {
    let entries: [WorkoutHistoryProjection]
    let readState: BluetoothManager.WorkoutReadState
    let hasMore: Bool
    let onRetry: () -> Void
    let onLoadMore: () -> Void

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("История тренировок")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if case .loading = readState, entries.isEmpty {
                    ProgressView("Чтение Telemetry V2…")
                        .font(.caption)
                } else if case let .failed(message) = readState, entries.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("История Telemetry V2 недоступна: \(message)")
                            .font(.caption2)
                            .foregroundColor(.red)
                        Button("Повторить", action: onRetry)
                            .buttonStyle(.bordered)
                    }
                } else if entries.isEmpty {
                    Text("Пока нет данных")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(entries) { entry in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.startedAt.map(Self.dateFormatter.string(from:)) ?? "Дата неизвестна")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundColor(.primary)
                                Text("Время: \(formatDuration(entry.durationSeconds))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(provenanceText(for: entry))
                                    .font(.caption2.weight(.medium))
                                    .foregroundColor(entry.origin == .nativeV2 ? .blue : .orange)
                                if !entry.quality.warnings.isEmpty {
                                    Text(entry.quality.warnings.joined(separator: "; "))
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                }
                                if let healthKitID = entry.healthKitWorkoutIdentifier {
                                    Text("HealthKit: \(healthKitID.uuidString.lowercased())")
                                        .font(.caption2.monospaced())
                                        .foregroundColor(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("Удары/м: \(entry.beatsPerMetre.map { String(format: "%.2f", $0) } ?? "—")")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text("Цель: \(entry.targetHeartRate.map(String.init) ?? "—")")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text("Ср. скорость: \(averageSpeedText(for: entry))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text("Ср. пульс: \(averageBpmText(for: entry))")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundColor(entry.averageHeartRate == nil ? .secondary : .red)
                            }
                        }
                        if entry.id != entries.last?.id {
                            Divider()
                        }
                    }

                    if hasMore {
                        Button("Показать ещё", action: onLoadMore)
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                    }

                    if case let .failed(message) = readState {
                        Text("Следующая страница недоступна: \(message)")
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                }
            }
        }
    }

    private func formatDuration(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        let value = max(0, Int(seconds))
        let minutes = value / 60
        let secs = value % 60
        return String(format: "%d:%02d", minutes, secs)
    }

    private func averageBpmText(for entry: WorkoutHistoryProjection) -> String {
        guard let average = entry.averageHeartRate else { return "—" }
        return "\(Int(average.rounded())) bpm"
    }

    private func averageSpeedText(for entry: WorkoutHistoryProjection) -> String {
        guard let speed = entry.averageSpeed else { return "—" }
        let prefix = speed.evidenceKind == .legacyEstimated ? "≈" : ""
        return prefix + String(format: "%.1f км/ч", speed.kilometresPerHour)
    }

    private func provenanceText(for entry: WorkoutHistoryProjection) -> String {
        let origin = entry.origin == .nativeV2 ? "V2 native" : "Legacy import"
        let lifecycle = entry.quality.lifecycleState
        let grade = entry.quality.analysisGrade.map { " · \($0)" } ?? ""
        return "\(origin) · \(lifecycle)\(grade)"
    }
}

private enum HrControlPreviewMode: String, CaseIterable, Identifiable {
    case workout = "Тренировка"
    case cooldown = "Заминка"

    var id: String { rawValue }
}

private struct HRControlPanelPreviewState {
    let isHrControlRunning: Bool
    let hrNextDecisionSeconds: Int
    let hrPredictorStatusLine: String
    let hrDecisionDetails: String
    let hrRemainingSeconds: Int
    let hrCooldownRemainingSeconds: Int
    let hrProgress: Double
    let hrCooldownProgress: Double
    let hrStreamingActive: Bool
    let hrStatusLine: String
    let canExtendHrSession: Bool
    let hrSessionMaxMinutes: Int
}

private struct DebugView: View {
    @EnvironmentObject private var manager: BluetoothManager
    @State private var showHrControlPreview = false
    @State private var hrControlPreviewMode: HrControlPreviewMode = .workout
    @State private var previewNoHrSignal = false

    private var trainingLogScopeOptions: [TrainingLogCsvExportScope] {
        [.all, .lastCompletedWorkouts(3), .lastCompletedWorkouts(5)]
    }

    private func formattedByteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func trainingLogsMenuItemTitle(
        scope: TrainingLogCsvExportScope,
        sessionSummaryOnly: Bool
    ) -> String {
        switch scope {
        case .all:
            return sessionSummaryOnly ? "Все V2 summary" : "Все V2 evidence"
        case .lastCompletedWorkouts(let limit):
            return "Последние \(limit) завершённых"
        }
    }

    private var telemetryV2WriterHealthMetrics: [DebugTrainingLogsCard.Presentation.Metric] {
        let snapshot = manager.telemetryV2WriterHealthSnapshot
        let lifecycle = [
            snapshot.runtimeLifecycle.rawValue,
            snapshot.recorderLifecycle?.rawValue,
            snapshot.completeness?.rawValue,
        ].compactMap { $0 }.joined(separator: " / ")

        return [
            .init(id: "v2_lifecycle", title: "State", value: lifecycle, tint: .accentColor),
            .init(id: "v2_queue", title: "Queue / peak", value: "\(snapshot.queueDepth) / \(snapshot.peakQueueDepth)", tint: .blue),
            .init(id: "v2_frames", title: "Frame C / D", value: "\(snapshot.coalescedFrameCount) / \(snapshot.droppedFrameCount)", tint: .secondary),
            .init(id: "v2_loss", title: "Loss N / C", value: "\(snapshot.lostNativeCount) / \(snapshot.lostCriticalCount)", tint: .orange),
            .init(id: "v2_writer", title: "Fail / retry", value: "\(snapshot.writerFailureCount) / \(snapshot.retryCount)", tint: .red),
            .init(id: "v2_flush", title: "Flush / seq", value: "\(snapshot.successfulFlushCount) / \(snapshot.lastCommittedRecorderSequence.map(String.init) ?? "—")", tint: .green),
        ]
    }

    private var telemetryV2WriterHealthDetailLines: [String] {
        let duration = manager.telemetryV2WriterHealthSnapshot.mostRecentFlushDuration
        guard let duration else {
            return [
                "Latest flush: —",
                "Legacy shadow parity writer: \(manager.legacyShadowWriterStatusText)",
            ]
        }
        let components = duration.components
        let milliseconds = (Double(components.seconds) * 1_000)
            + (Double(components.attoseconds) / 1_000_000_000_000_000)
        return [
            "Latest flush: \(String(format: "%.1f", milliseconds)) ms",
            "Legacy shadow parity writer: \(manager.legacyShadowWriterStatusText)",
        ]
    }

    private var trainingLogsCardPresentation: DebugTrainingLogsCard.Presentation {
        let entries = manager.telemetryV2WorkoutHistory
        let readReady = manager.telemetryV2WorkoutHistoryState == .loaded
        let readStatusText: String = {
            switch manager.telemetryV2WorkoutHistoryState {
            case .idle: return "V2 read: idle"
            case .loading: return "V2 read: loading"
            case .loaded: return "V2 read: ready"
            case let .failed(message): return "V2 read failed: \(message)"
            }
        }()
        let completedCount = entries.filter {
            $0.quality.lifecycleState == "completed" || $0.quality.lifecycleState == "imported"
        }.count
        let unavailableCount = entries.filter { !$0.quality.unavailableMetrics.isEmpty }.count
        let possibleDuplicateCount = entries.filter(\.quality.possibleDuplicate).count
        let detailLines = [
            "Export формируется потоково из Telemetry V2 и включает manifest, raw JSONL, normalized CSV и session summary.",
            "Legacy JSONL и UserDefaults shadow history не читаются, не очищаются и не удаляются.",
            "Поля HealthKit linkage и version context сохраняются; device/profile identifiers исключены.",
            readStatusText,
        ]

        let rawExportOptions = trainingLogScopeOptions.map { scope in
            DebugTrainingLogsCard.Presentation.ExportOption(
                id: "raw_\(scope.logDescription)",
                title: trainingLogsMenuItemTitle(scope: scope, sessionSummaryOnly: false),
                scope: scope
            )
        }
        let summaryExportOptions = trainingLogScopeOptions.map { scope in
            DebugTrainingLogsCard.Presentation.ExportOption(
                id: "summary_\(scope.logDescription)",
                title: trainingLogsMenuItemTitle(scope: scope, sessionSummaryOnly: true),
                scope: scope
            )
        }

        return DebugTrainingLogsCard.Presentation(
            testRunActive: manager.treadmillTestRunIsActive,
            testRunStatusText: manager.treadmillTestRunDisplayText,
            canStartTestRun: manager.canStartTreadmillTestRun,
            subtitle: "Telemetry V2 · активный профиль: \(manager.activeUserProfileLabel)",
            profileMetrics: [
                .init(id: "profile_loaded", title: "Загружено", value: "\(entries.count)", tint: .accentColor),
                .init(id: "profile_completed", title: "Заверш.", value: "\(completedCount)", tint: .blue),
                .init(id: "profile_quality", title: "Missing / dup", value: "\(unavailableCount) / \(possibleDuplicateCount)", tint: .orange)
            ],
            deviceMetrics: [],
            writerHealthMetrics: telemetryV2WriterHealthMetrics,
            writerHealthDetailLines: telemetryV2WriterHealthDetailLines,
            rawExportOptions: rawExportOptions,
            rawExportSubtitle: readReady ? "Raw + normalized + manifest" : "V2 read unavailable",
            canExportRaw: readReady,
            sessionSummaryOptions: summaryExportOptions,
            sessionSummarySubtitle: readReady
                ? "V2 summary + quality fields"
                : "V2 read unavailable",
            canExportSessionSummary: readReady,
            clearSubtitle: "Source evidence is immutable in this cutover.",
            canClear: false,
            clearConfirmationMessage: "",
            detailLines: detailLines,
            footer: completedCount < 3
                ? "Для анализа лучше накопить хотя бы 3 завершённые тренировки."
                : nil
        )
    }

    private var hrFailuresCardPresentation: DebugHrFailuresCard.Presentation {
        let reports = manager.hrFailureReports
        let latestFailureDate = reports.map(\.end).max()
        let reportPreviews = reports.prefix(3).map { report in
            DebugHrFailuresCard.Presentation.ReportPreview(
                id: report.id,
                title: report.reason,
                subtitle: "\(report.start.formatted(date: .abbreviated, time: .shortened)) → \(report.end.formatted(date: .abbreviated, time: .shortened))",
                body: report.lines.isEmpty
                    ? "Подробных строк нет."
                    : report.lines.prefix(8).joined(separator: "\n")
            )
        }

        return DebugHrFailuresCard.Presentation(
            subtitle: "Сохранённые инциденты потери или сбоя пульса",
            metrics: [
                .init(id: "reports_total", title: "Отчётов", value: "\(reports.count)", tint: .orange),
                .init(id: "reports_visible", title: "Показано", value: "\(reportPreviews.count)", tint: .blue),
                .init(
                    id: "reports_latest",
                    title: "Последний",
                    value: latestFailureDate.map { $0.formatted(date: .omitted, time: .shortened) } ?? "—",
                    tint: .red
                )
            ],
            exportSubtitle: reports.isEmpty ? "Нет данных" : "\(reports.count) отчётов",
            canExport: !reports.isEmpty,
            clearSubtitle: reports.isEmpty ? "Список уже пуст" : "Удалить \(reports.count) отчётов",
            canClear: !reports.isEmpty,
            clearConfirmationMessage: "Будут удалены все сохранённые HR failure reports в Debug. Structured training logs и история тренировок не изменятся.",
            reports: Array(reportPreviews),
            emptyState: reports.isEmpty ? "Ошибок пульса пока нет." : nil,
            footer: reports.count > reportPreviews.count
                ? "Показаны последние \(reportPreviews.count) отчёта из \(reports.count). Полный набор уйдёт в export."
                : "HR failure export сохраняет полный набор инцидентов."
        )
    }

    private var hrControlPreviewState: HRControlPanelPreviewState {
        switch hrControlPreviewMode {
        case .workout:
            return HRControlPanelPreviewState(
                isHrControlRunning: true,
                hrNextDecisionSeconds: 7,
                hrPredictorStatusLine: "HR 132 / цель 140 · тренд +1.8 bpm/мин · прогноз 135",
                hrDecisionDetails: "HR 132 / цель 140 (Δ -8) · шаг UP-L2 0.2 км/ч · скорость 4.4 → +0.2 км/ч",
                hrRemainingSeconds: 8 * 60,
                hrCooldownRemainingSeconds: 0,
                hrProgress: 0.62,
                hrCooldownProgress: 0,
                hrStreamingActive: !previewNoHrSignal,
                hrStatusLine: previewNoHrSignal ? "HR‑контроль: нет сигнала" : "HR‑контроль: увеличиваем скорость",
                canExtendHrSession: true,
                hrSessionMaxMinutes: manager.hrSessionMaxMinutes
            )
        case .cooldown:
            return HRControlPanelPreviewState(
                isHrControlRunning: true,
                hrNextDecisionSeconds: 0,
                hrPredictorStatusLine: "HR 119 / цель 100 · тренд -2.5 bpm/мин · прогноз 116",
                hrDecisionDetails: "Заминка: HR 119 / цель 100 · скорость 3.7 · стаб 11/20с",
                hrRemainingSeconds: 0,
                hrCooldownRemainingSeconds: 2 * 60,
                hrProgress: 1.0,
                hrCooldownProgress: 0.58,
                hrStreamingActive: !previewNoHrSignal,
                hrStatusLine: "Заминка",
                canExtendHrSession: false,
                hrSessionMaxMinutes: manager.hrSessionMaxMinutes
            )
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 4) {
                        Text(manager.connectionStateText)
                            .font(.headline)
                        Text(manager.deviceName)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Предпросмотр HR‑карточки (running)", isOn: $showHrControlPreview)
                                .toggleStyle(.switch)
                            if showHrControlPreview {
                                Picker("Режим", selection: $hrControlPreviewMode) {
                                    ForEach(HrControlPreviewMode.allCases) { mode in
                                        Text(mode.rawValue).tag(mode)
                                    }
                                }
                                .pickerStyle(.segmented)

                                Toggle("Симулировать отсутствие сигнала пульса", isOn: $previewNoHrSignal)
                                    .toggleStyle(.switch)

                                HRControlPanel(debugPreview: hrControlPreviewState)
                                    .environmentObject(manager)
                            }
                        }
                    }

                    DebugSectionCard(
                        title: "Runtime Snapshot",
                        subtitle: manager.loggingEnabled
                            ? "Logging ON · локальные runtime и BLE метрики"
                            : "Logging OFF · локальные runtime и BLE метрики"
                    ) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Button("Copy Logs") {
                                    copyLogs(
                                        lastCmd: manager.lastCommandLine,
                                        hrStatus: manager.hrStatusLine,
                                        log: manager.debugLog
                                    )
                                }
                                .buttonStyle(.bordered)

                                Button("Clear") {
                                    manager.debugLog = ""
                                    manager.lastCommandLine = ""
                                    manager.hrStatusLine = ""
                                }
                                .buttonStyle(.bordered)

                                Toggle("Logging", isOn: Binding(
                                    get: { manager.loggingEnabled },
                                    set: { manager.loggingEnabled = $0 }
                                ))
                                .toggleStyle(.switch)

                                Spacer()
                            }

                            if !manager.loggingEnabled {
                                Text("Logging is OFF — turn it on to record new events")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            if !manager.lastCommandLine.isEmpty {
                                Text("Last cmd: \(manager.lastCommandLine)")
                                    .font(.caption)
                            }

                            if !manager.treadmillStatusText.isEmpty {
                                Text("Treadmill: \(manager.treadmillStatusText)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if manager.lastNotifyAgeSeconds > 0 {
                                Text("Last notify: \(manager.lastNotifyAgeSeconds)s ago")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if !manager.lastCommandAckStatusText.isEmpty {
                                Text("Cmd ack: \(manager.lastCommandAckStatusText)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if manager.lastCommandTimeoutsCount > 0 {
                                Text("Cmd timeouts: \(manager.lastCommandTimeoutsCount)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            if !manager.hrStatusLine.isEmpty {
                                Text(manager.hrStatusLine)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            let actualStr = String(format: "%.1f", manager.speedKmh)
                            let targetStr = String(format: "%.1f", manager.desiredSpeedKmh)
                            let deviceStr = String(format: "%.1f", manager.deviceTargetSpeedKmh)
                            Text("Speed \(actualStr)  Target \(targetStr)  AppSet \(deviceStr)  HR \(manager.heartRateBPM) (last \(manager.lastKnownHeartRateBPM))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Reported speed: \(String(format: "%.1f", manager.deviceReportedSpeedKmh))  AppSpeed: \(String(format: "%.1f", manager.deviceReportedAppSpeedKmh))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("State \(manager.deviceReportedState)  Mode \(manager.deviceReportedManualMode)  Button \(manager.deviceReportedButton)  Checksum \(manager.deviceReportedChecksumOk ? "ok" : "bad")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Time \(manager.deviceReportedTimeSeconds)s  Dist \(manager.deviceReportedDistance10m * 10)m  Steps \(manager.deviceReportedSteps)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if !manager.deviceReportedRawHex.isEmpty {
                                Text("FE01 raw: \(manager.deviceReportedRawHex)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            let wcState = "WCSession: paired=\(manager.watchPaired ? "yes" : "no") installed=\(manager.watchAppInstalled ? "yes" : "no") reachable=\(manager.watchReachable ? "yes" : "no")"
                            Text(wcState)
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if !manager.debugLog.isEmpty {
                                ScrollView {
                                    Text(manager.debugLog)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.leading)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(height: 280)
                                .padding(.top, 4)
                            } else {
                                Text("No logs yet")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    DebugTrainingLogsCard(
                        presentation: trainingLogsCardPresentation,
                        onToggleTestRun: {
                            if manager.treadmillTestRunIsActive {
                                manager.stopTreadmillTestRun()
                            } else {
                                manager.startTreadmillTestRun()
                            }
                        },
                        onExportRaw: { scope in
                            exportTrainingHistoryCsv(manager: manager, scope: scope)
                        },
                        onExportSessionSummary: { scope in
                            exportTrainingSessionSummaryCsv(manager: manager, scope: scope)
                        }
                    )

                    DebugHrFailuresCard(
                        presentation: hrFailuresCardPresentation,
                        onExport: {
                            exportHrFailures(reports: manager.hrFailureReports)
                        },
                        onClear: {
                            manager.clearHrFailureReports()
                        }
                    )
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Отладка")
            .onAppear {
                manager.refreshWorkoutHistoryFromV2(reset: true)
            }
        }
    }
}

// MARK: - Small UI helpers

#if canImport(UIKit)
private func copyLogs(lastCmd: String, hrStatus: String, log: String) {
    var parts: [String] = []
    if !lastCmd.isEmpty { parts.append("Last cmd: \(lastCmd)") }
    if !hrStatus.isEmpty { parts.append(hrStatus) }
    if !log.isEmpty { parts.append(log) }

    let text = parts.joined(separator: "\n")
    UIPasteboard.general.string = text
}

private func exportTrainingHistoryCsv(
    manager: BluetoothManager,
    scope: TrainingLogCsvExportScope
) {
    presentTelemetryV2ExportWarning(manager: manager, scope: scope)
}

private func exportTrainingSessionSummaryCsv(
    manager: BluetoothManager,
    scope: TrainingLogCsvExportScope
) {
    presentTelemetryV2ExportWarning(manager: manager, scope: scope)
}

private func presentTelemetryV2ExportWarning(
    manager: BluetoothManager,
    scope: TrainingLogCsvExportScope
) {
    guard let root = activeRootViewController() else { return }
    let alert = UIAlertController(
        title: "Health Data Export",
        message: "The export contains heart-rate and workout health data. Share it only with a trusted recipient. Source evidence will not be deleted.",
        preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Continue", style: .default) { _ in
        Task { @MainActor in
            do {
                let artifact = try await manager.prepareTelemetryV2Export(scope: scope)
                let activity = UIActivityViewController(
                    activityItems: artifact.fileURLs,
                    applicationActivities: nil
                )
                activity.completionWithItemsHandler = { _, completed, _, _ in
                    Task { @MainActor in
                        manager.finalizeTelemetryV2Export(artifact, completed: completed)
                    }
                }
                activeRootViewController()?.present(activity, animated: true)
            } catch {
                let failure = UIAlertController(
                    title: "Telemetry V2 Export Failed",
                    message: error.localizedDescription,
                    preferredStyle: .alert
                )
                failure.addAction(UIAlertAction(title: "OK", style: .default))
                activeRootViewController()?.present(failure, animated: true)
            }
        }
    })
    root.present(alert, animated: true)
}

private func activeRootViewController() -> UIViewController? {
    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
        return nil
    }
    var controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController
        ?? scene.windows.first?.rootViewController
    while let presented = controller?.presentedViewController {
        controller = presented
    }
    return controller
}

// Overload to accept manager's nested type and forward to the existing exporter
private func exportHrFailures(reports: [BluetoothManager.HrFailureReport]) {
    let mapped: [HrFailureReport] = reports.map { r in
        HrFailureReport(
            reason: r.reason,
            start: r.start,
            end: r.end,
            lines: r.lines
        )
    }
    exportHrFailures(reports: mapped)
}

private func exportHrFailures(reports: [HrFailureReport]) {
    guard !reports.isEmpty else { return }
    var parts: [String] = []
    parts.append("HR Failure Reports: \(reports.count)")
    let headerFormatter = DateFormatter()
    headerFormatter.dateStyle = .short
    headerFormatter.timeStyle = .short
    for (idx, r) in reports.enumerated() {
        parts.append("")
        parts.append("=== Report \(idx + 1) ===")
        parts.append("Reason: \(r.reason)")
        parts.append("Start: \(headerFormatter.string(from: r.start))")
        parts.append("End: \(headerFormatter.string(from: r.end))")
        if !r.lines.isEmpty {
            parts.append("Lines:")
            parts.append(contentsOf: r.lines)
        }
    }
    let text = parts.joined(separator: "\n")

    let tsFormatter = DateFormatter()
    tsFormatter.dateFormat = "yyyyMMdd_HHmmss"
    let ts = tsFormatter.string(from: Date())
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("HR_Failures_\(ts).txt")

    let present: (UIActivityViewController) -> Void = { vc in
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            root.present(vc, animated: true)
        }
    }

    do {
        try text.write(to: url, atomically: true, encoding: .utf8)
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        present(vc)
    } catch {
        let vc = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        present(vc)
    }
}
#endif

private struct StatsRightAlignedRow: View {
    @ObservedObject var manager: BluetoothManager
    var body: some View {
        HStack(spacing: 20) {
            statChip(systemImage: "stopwatch", text: timeText, active: timeActive)
                .accessibilityLabel("Время движения: \(timeText)")
            statChip(systemImage: "ruler", text: String(format: "%.2f km", manager.distKm), active: distActive)
            statChip(systemImage: "figure.walk", text: "\(manager.stepsCount)", active: stepsActive)
            Spacer()
        }
    }

    private var timeActive: Bool { manager.timeSec > 0 }
    private var distActive: Bool { manager.distKm > 0.001 }
    private var stepsActive: Bool { manager.stepsCount > 0 }
    private var timeText: String {
        String(format: "%d:%02d", max(0, manager.timeSec) / 60, max(0, manager.timeSec) % 60)
    }

    @ViewBuilder
    private func statChip(systemImage: String, text: String, active: Bool) -> some View {
        let valueColor: Color = active ? .primary : .secondary
        HStack(spacing: 6) {
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
}
