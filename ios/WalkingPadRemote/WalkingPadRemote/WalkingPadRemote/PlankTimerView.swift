import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AudioToolbox)
import AudioToolbox
#endif

struct PlankTimerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var timerValueSize: CGFloat = 58
    private let minBaseDurationSeconds: Int = 5
    private let maxDurationSeconds: Int = 1800
    private let holdToMeasureDuration: Double = 3.0
    private let holdToCancelDuration: Double = 1.2
    private let tapMaxDuration: Double = 0.35

    private enum HoldAction: Equatable {
        case startMeasurement
        case cancelCurrentSet
    }

    @AppStorage("plank_base_duration_seconds_v1") private var baseDurationSeconds: Int = 60
    @AppStorage("plank_increase_step_seconds_v1") private var increaseStepSeconds: Int = 5
    @AppStorage("plank_increase_every_count_v1") private var increaseEveryCount: Int = 3
    @AppStorage("plank_completed_sets_count_v1") private var completedSetsCount: Int = 0
    @AppStorage("plank_estimated_weekly_sets_v1") private var estimatedWeeklySets: Int = 7

    @State private var activeSetTotalSeconds: Int = 60
    @State private var remainingSeconds: Int = 60
    @State private var isRunning = false
    @State private var isMeasuring = false
    @State private var measurementElapsedSeconds = 0
    @State private var lastMeasuredBaselineSeconds: Int?
    @State private var holdProgress: Double = 0.0
    @State private var holdAction: HoldAction?
    @State private var isCirclePressed = false
    @State private var holdDidTriggerAction = false
    @State private var holdTriggerToken: UUID?
    @State private var pressStartedAt: Date?
    @State private var showMeasurementStartConfirmation = false
    @State private var showCompletionBanner = false
    @State private var ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var safeBaseDurationSeconds: Int {
        min(maxDurationSeconds, max(minBaseDurationSeconds, baseDurationSeconds))
    }

    private var safeIncreaseStepSeconds: Int {
        min(120, max(1, increaseStepSeconds))
    }

    private var safeIncreaseEveryCount: Int {
        min(200, max(1, increaseEveryCount))
    }

    private var safeEstimatedWeeklySets: Int {
        min(200, max(1, estimatedWeeklySets))
    }

    private var displayedSeconds: Int {
        isMeasuring ? measurementElapsedSeconds : remainingSeconds
    }

    private var nextSetTotalSeconds: Int {
        durationSeconds(forCompletedSets: completedSetsCount)
    }

    private var projectedSetsPerYear: Int {
        safeEstimatedWeeklySets * 52
    }

    private var projectedDurationInYearSeconds: Int {
        durationSeconds(forCompletedSets: completedSetsCount + projectedSetsPerYear)
    }

    private var projectedDurationText: String {
        String(
            format: "%d:%02d",
            projectedDurationInYearSeconds / 60,
            projectedDurationInYearSeconds % 60
        )
    }

    private var increaseStepBinding: Binding<Int> {
        Binding(
            get: { safeIncreaseStepSeconds },
            set: { newValue in
                increaseStepSeconds = min(120, max(1, newValue))
                syncIdleTimerToCurrentProgram()
            }
        )
    }

    private var increaseEveryBinding: Binding<Int> {
        Binding(
            get: { safeIncreaseEveryCount },
            set: { newValue in
                increaseEveryCount = min(200, max(1, newValue))
                syncIdleTimerToCurrentProgram()
            }
        )
    }

    private var estimatedWeeklySetsBinding: Binding<Int> {
        Binding(
            get: { safeEstimatedWeeklySets },
            set: { newValue in
                estimatedWeeklySets = min(200, max(1, newValue))
            }
        )
    }

    private var progress: Double {
        if isMeasuring {
            return min(1.0, max(0.0, Double(measurementElapsedSeconds) / Double(maxDurationSeconds)))
        }
        guard activeSetTotalSeconds > 0 else { return 0.0 }
        let elapsed = activeSetTotalSeconds - remainingSeconds
        return min(1.0, max(0.0, Double(elapsed) / Double(activeSetTotalSeconds)))
    }

    private var circleProgress: Double {
        if holdAction != nil {
            return holdProgress
        }
        return progress
    }

    private var circleProgressColors: [Color] {
        switch holdAction {
        case .startMeasurement:
            return [Color.orange.opacity(0.6), Color.orange]
        case .cancelCurrentSet:
            return [Color.red.opacity(0.6), Color.red]
        case .none:
            return [FocusStyle.accent, FocusStyle.accent]
        }
    }

    private var timeText: String {
        String(format: "%d:%02d", max(0, displayedSeconds) / 60, max(0, displayedSeconds) % 60)
    }

    private var durationCaption: String {
        if isMeasuring {
            return "Замер: секундомер"
        }
        if isRunning {
            return "Подход: \(activeSetTotalSeconds) сек"
        }
        if remainingSeconds == 0 {
            return "Следующий: \(nextSetTotalSeconds) сек"
        }
        return "Текущий: \(activeSetTotalSeconds) сек"
    }

    private var statusText: String {
        if let holdAction {
            let secondsLeft = max(0, Int(ceil((1.0 - holdProgress) * holdDuration(for: holdAction))))
            switch holdAction {
            case .startMeasurement:
                return "Удерживай круг ещё \(secondsLeft) сек, чтобы включить замер"
            case .cancelCurrentSet:
                return "Удерживай ещё \(secondsLeft) сек для остановки"
            }
        }
        if isMeasuring {
            return "Идёт замер. Тап по кругу завершит замер"
        }
        if let measured = lastMeasuredBaselineSeconds {
            return "База обновлена: \(measured) сек. Нажми круг, чтобы начать"
        }
        if isRunning {
            let cancelSeconds = max(1, Int(ceil(holdToCancelDuration)))
            return "Идёт планка. Удерживай круг \(cancelSeconds) сек для остановки без зачёта"
        }
        if remainingSeconds == 0 {
            return "Готово. Нажми круг для повтора"
        }
        let measureSeconds = max(1, Int(ceil(holdToMeasureDuration)))
        return "Нажми круг, чтобы начать. Удерживай \(measureSeconds) сек для замера"
    }

    private var modeLabel: String {
        if holdAction != nil {
            return "Удержание"
        }
        if isMeasuring {
            return "Замер"
        }
        if isRunning {
            return "Подход"
        }
        if remainingSeconds == 0 {
            return "Готово"
        }
        return "Таймер"
    }

    private var modeIcon: String {
        if holdAction != nil {
            return "hand.tap.fill"
        }
        if isMeasuring {
            return "stopwatch.fill"
        }
        if isRunning {
            return "figure.strengthtraining.traditional"
        }
        if remainingSeconds == 0 {
            return "checkmark.circle.fill"
        }
        return "timer"
    }

    private var stateAccentColor: Color {
        switch holdAction {
        case .startMeasurement:
            return .orange
        case .cancelCurrentSet:
            return .red
        case .none:
            if isMeasuring {
                return .blue
            }
            if isRunning {
                return .green
            }
            if remainingSeconds == 0 {
                return .mint
            }
            return .accentColor
        }
    }

    private var setsUntilNextIncrease: Int {
        let remainder = completedSetsCount % safeIncreaseEveryCount
        if remainder == 0 {
            return safeIncreaseEveryCount
        }
        return safeIncreaseEveryCount - remainder
    }

    private var progressionToNextIncrease: Double {
        guard safeIncreaseEveryCount > 0 else { return 0.0 }
        let remainder = completedSetsCount % safeIncreaseEveryCount
        return min(1.0, max(0.0, Double(remainder) / Double(safeIncreaseEveryCount)))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FocusStyle.background.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 14) {
                            Label(modeLabel, systemImage: modeIcon)
                                .font(.headline)
                                .foregroundStyle(FocusStyle.accent)

                            let metricsLayout = dynamicTypeSize.isAccessibilitySize
                                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                                : AnyLayout(HStackLayout(spacing: 10))
                            metricsLayout {
                                heroMetric(
                                    icon: "bolt.circle.fill",
                                    title: "База",
                                    value: "\(safeBaseDurationSeconds) сек"
                                )
                                heroMetric(
                                    icon: "repeat.circle.fill",
                                    title: "Следующий",
                                    value: "\(nextSetTotalSeconds) сек"
                                )
                                heroMetric(
                                    icon: "flag.checkered.circle.fill",
                                    title: "До +\(safeIncreaseStepSeconds) сек",
                                    value: "\(setsUntilNextIncrease)"
                                )
                            }
                        }
                        .padding(20)
                        .background(FocusStyle.surface, in: RoundedRectangle(cornerRadius: FocusStyle.cornerRadius, style: .continuous))

                        VStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(FocusStyle.surface)

                                Circle()
                                    .stroke(Color(.tertiarySystemFill), lineWidth: 14)

                                Circle()
                                    .trim(from: 0, to: circleProgress)
                                    .stroke(
                                        LinearGradient(
                                            colors: circleProgressColors,
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        style: StrokeStyle(lineWidth: 14, lineCap: .round)
                                    )
                                    .rotationEffect(.degrees(-90))
                                    .opacity((isRunning || isMeasuring || holdAction != nil) ? 1.0 : 0.55)

                                VStack(spacing: 6) {
                                    Text(timeText)
                                        .font(dynamicTypeSize.isAccessibilitySize
                                            ? .system(.largeTitle, design: .rounded, weight: .bold)
                                            : .system(size: timerValueSize, weight: .bold, design: .rounded))
                                        .monospacedDigit()
                                        .minimumScaleFactor(0.65)
                                        .foregroundColor(.primary)
                                    if !dynamicTypeSize.isAccessibilitySize {
                                        Text(durationCaption)
                                            .font(.caption.weight(.medium))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.horizontal, 12)
                            }
                            .aspectRatio(1, contentMode: .fit)
                            .frame(maxWidth: 340)
                            .contentShape(Circle())
                            .accessibilityLabel("Таймер планки")
                            .accessibilityValue("\(timeText), \(durationCaption)")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { handleCircleTap() }
                            .accessibilityActions {
                                if !isRunning && !isMeasuring {
                                    Button("Начать замер") { showMeasurementStartConfirmation = true }
                                }
                                if isRunning {
                                    Button("Сбросить") { resetTimer() }
                                }
                            }
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { _ in
                                        handleCirclePressChanged(isPressing: true)
                                    }
                                    .onEnded { _ in
                                        handleCirclePressChanged(isPressing: false)
                                    }
                            )

                            if dynamicTypeSize.isAccessibilitySize {
                                Text(durationCaption)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Text(statusText)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)

                            if showCompletionBanner {
                                Label("Подход завершён", systemImage: "checkmark.circle.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(Color.green.opacity(0.12))
                                    )
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .stroke(Color.green.opacity(0.35), lineWidth: 1)
                                    )
                                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                            }
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: FocusStyle.cornerRadius, style: .continuous)
                                .fill(FocusStyle.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: FocusStyle.cornerRadius, style: .continuous)
                                .stroke(Color(.separator).opacity(0.2), lineWidth: 1)
                        )

                        VStack(spacing: 12) {
                            let progressionLayout = dynamicTypeSize.isAccessibilitySize
                                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
                            progressionLayout {
                                Label("Прогрессия", systemImage: "chart.line.uptrend.xyaxis")
                                    .font(.headline)
                                    .labelStyle(.titleOnly)
                                    .fixedSize(horizontal: false, vertical: true)
                                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                                Text("\(completedSetsCount) \(plankWord(for: completedSetsCount))")
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(stateAccentColor)
                            }

                            ProgressView(value: progressionToNextIncrease)
                                .tint(stateAccentColor)
                            Text("До следующего увеличения осталось \(setsUntilNextIncrease) \(plankWord(for: setsUntilNextIncrease)).")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Stepper(value: increaseStepBinding, in: 1...120) {
                                progressionLayout {
                                    Text("Добавлять секунд")
                                        .font(.subheadline)
                                    if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                                    Text("+\(safeIncreaseStepSeconds) сек")
                                        .font(.subheadline.weight(.semibold))
                                        .monospacedDigit()
                                }
                            }

                            Stepper(value: increaseEveryBinding, in: 1...200) {
                                progressionLayout {
                                    Text("Повышать каждые")
                                        .font(.subheadline)
                                    if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                                    Text("\(safeIncreaseEveryCount) \(plankWord(for: safeIncreaseEveryCount))")
                                        .font(.subheadline.weight(.semibold))
                                        .monospacedDigit()
                                }
                            }

                            Stepper(value: estimatedWeeklySetsBinding, in: 1...200) {
                                progressionLayout {
                                    Text("Планок в неделю")
                                        .font(.subheadline)
                                    if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                                    Text("\(safeEstimatedWeeklySets) / нед")
                                        .font(.subheadline.weight(.semibold))
                                        .monospacedDigit()
                                }
                            }

                            Divider()

                            progressionLayout {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Прогноз через год")
                                        .font(.subheadline)
                                    Text("~\(projectedSetsPerYear) подходов в год")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                                Text("\(projectedDurationText)")
                                    .font(.title3.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundColor(.primary)
                            }
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: FocusStyle.cornerRadius, style: .continuous)
                                .fill(Color(.secondarySystemGroupedBackground))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: FocusStyle.cornerRadius, style: .continuous)
                                .stroke(Color(.tertiarySystemFill), lineWidth: 1)
                        )
                        .disabled(isRunning || isMeasuring)
                        .opacity((isRunning || isMeasuring) ? 0.6 : 1.0)

                        if isRunning {
                            Button {
                                resetTimer()
                            } label: {
                                Label("Сбросить", systemImage: "arrow.counterclockwise.circle.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                            }
                            .buttonStyle(FocusActionStyle(destructive: true))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Планка")
            .navigationBarTitleDisplayMode(.large)
        }
        .onReceive(ticker) { _ in
            tick()
        }
        .onAppear {
            if baseDurationSeconds != safeBaseDurationSeconds {
                baseDurationSeconds = safeBaseDurationSeconds
            }
            syncIdleTimerToCurrentProgram(forceReset: true)
        }
        .onChange(of: baseDurationSeconds) { _, _ in
            syncIdleTimerToCurrentProgram()
        }
        .onChange(of: completedSetsCount) { _, _ in
            syncIdleTimerToCurrentProgram()
        }
        .onChange(of: increaseStepSeconds) { _, _ in
            syncIdleTimerToCurrentProgram()
        }
        .onChange(of: increaseEveryCount) { _, _ in
            syncIdleTimerToCurrentProgram()
        }
        .onChange(of: showMeasurementStartConfirmation) { _, isPresented in
            if isPresented {
                playMeasurementPromptFeedback()
            }
        }
        .alert(
            "Начать замер планки?",
            isPresented: $showMeasurementStartConfirmation,
        ) {
            Button("Начать замер") {
                startMeasurement()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("После старта коснитесь круга, когда закончите замер.")
        }
    }

    private func heroMetric(icon: String, title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(stateAccentColor)
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.systemBackground).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(stateAccentColor.opacity(0.18), lineWidth: 1)
        )
    }

    private func handleCircleTap() {
        if isMeasuring {
            finishMeasurement()
            return
        }

        startIfNeeded()
    }

    private func handleCirclePressChanged(isPressing: Bool) {
        if isPressing {
            beginCirclePressIfNeeded()
            return
        }
        endCirclePress()
    }

    private func beginCirclePressIfNeeded() {
        guard !isCirclePressed else { return }
        isCirclePressed = true
        pressStartedAt = Date()
        holdDidTriggerAction = false

        guard !isMeasuring else { return }

        let action: HoldAction = isRunning ? .cancelCurrentSet : .startMeasurement
        startHoldProgress(for: action)
        scheduleHoldTrigger(for: action)
    }

    private func endCirclePress() {
        guard isCirclePressed else { return }
        isCirclePressed = false
        holdTriggerToken = nil

        let pressDuration = Date().timeIntervalSince(pressStartedAt ?? Date())
        pressStartedAt = nil
        let didTriggerAction = holdDidTriggerAction
        holdDidTriggerAction = false

        resetHoldProgress()

        if isMeasuring {
            handleCircleTap()
            return
        }

        guard !didTriggerAction else { return }
        if pressDuration <= tapMaxDuration {
            handleCircleTap()
        }
    }

    private func scheduleHoldTrigger(for action: HoldAction) {
        let token = UUID()
        holdTriggerToken = token
        let duration = holdDuration(for: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard holdTriggerToken == token else { return }
            guard isCirclePressed else { return }
            guard holdAction == action else { return }
            holdDidTriggerAction = true
            triggerLongPressAction()
        }
    }

    private func triggerLongPressAction() {
        guard !isMeasuring else { return }
        guard let holdAction else { return }
        resetHoldProgress()
        switch holdAction {
        case .startMeasurement:
            showMeasurementStartConfirmation = true
        case .cancelCurrentSet:
            cancelCurrentSetFromLongPress()
        }
    }

    private func startHoldProgress(for action: HoldAction) {
        if holdAction == action { return }
        holdAction = action
        holdProgress = 0.0
        withAnimation(.linear(duration: holdDuration(for: action))) {
            holdProgress = 1.0
        }
    }

    private func holdDuration(for action: HoldAction) -> Double {
        switch action {
        case .startMeasurement:
            return holdToMeasureDuration
        case .cancelCurrentSet:
            return holdToCancelDuration
        }
    }

    private func resetHoldProgress() {
        holdAction = nil
        withAnimation(.easeOut(duration: 0.2)) {
            holdProgress = 0.0
        }
    }

    private func startIfNeeded() {
        guard !isRunning else { return }
        guard !isMeasuring else { return }
        resetHoldProgress()
        lastMeasuredBaselineSeconds = nil
        let targetSeconds = nextSetTotalSeconds
        if remainingSeconds == 0 || activeSetTotalSeconds != targetSeconds {
            activeSetTotalSeconds = targetSeconds
            remainingSeconds = targetSeconds
        }
        isRunning = true
    }

    private func tick() {
        if isMeasuring {
            measurementElapsedSeconds = min(maxDurationSeconds, measurementElapsedSeconds + 1)
            return
        }
        guard isRunning else { return }
        guard remainingSeconds > 0 else {
            finish()
            return
        }

        remainingSeconds -= 1
        if remainingSeconds == 0 {
            finish()
        }
    }

    private func finish() {
        guard isRunning else { return }
        isRunning = false
        completedSetsCount += 1
        showCompletionBannerTemporarily()
        playCompletionSignal()
    }

    private func resetTimer() {
        isRunning = false
        lastMeasuredBaselineSeconds = nil
        activeSetTotalSeconds = nextSetTotalSeconds
        remainingSeconds = activeSetTotalSeconds
    }

    private func cancelCurrentSetFromLongPress() {
        guard isRunning else { return }
        resetTimer()
        playCancellationFeedback()
    }

    private func syncIdleTimerToCurrentProgram(forceReset: Bool = false) {
        guard !isRunning else { return }
        guard !isMeasuring else { return }
        let targetSeconds = nextSetTotalSeconds
        if forceReset || remainingSeconds > 0 {
            activeSetTotalSeconds = targetSeconds
            remainingSeconds = targetSeconds
        }
    }

    private func startMeasurement() {
        guard !isRunning else { return }
        guard !isMeasuring else { return }
        resetHoldProgress()
        measurementElapsedSeconds = 0
        isMeasuring = true
        lastMeasuredBaselineSeconds = nil
    }

    private func finishMeasurement() {
        guard isMeasuring else { return }
        isMeasuring = false

        let measured = min(maxDurationSeconds, max(minBaseDurationSeconds, measurementElapsedSeconds))
        baseDurationSeconds = measured
        completedSetsCount = 0
        activeSetTotalSeconds = measured
        remainingSeconds = measured
        lastMeasuredBaselineSeconds = measured

        playMeasurementSavedFeedback()
    }

    private func durationSeconds(forCompletedSets completedSets: Int) -> Int {
        let progressionLevel = max(0, completedSets) / safeIncreaseEveryCount
        let rawSeconds = safeBaseDurationSeconds + (progressionLevel * safeIncreaseStepSeconds)
        return min(maxDurationSeconds, max(safeBaseDurationSeconds, rawSeconds))
    }

    private func plankWord(for count: Int) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        if mod10 == 1 && mod100 != 11 {
            return "планку"
        }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) {
            return "планки"
        }
        return "планок"
    }

    private func playCompletionSignal() {
        #if canImport(AudioToolbox)
        // Completion pattern: tone + vibration fallback + confirmation tone.
        AudioServicesPlaySystemSound(1104)
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            AudioServicesPlaySystemSound(1113)
        }
        #endif
        #if canImport(UIKit)
        // Two-step haptic: success pulse + confirmation tap.
        let success = UINotificationFeedbackGenerator()
        success.prepare()
        success.notificationOccurred(.success)

        let impact = UIImpactFeedbackGenerator(style: .heavy)
        impact.prepare()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            impact.impactOccurred(intensity: 1.0)
        }
        #endif
    }

    private func showCompletionBannerTemporarily() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9)) {
            showCompletionBanner = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeOut(duration: 0.2)) {
                showCompletionBanner = false
            }
        }
    }

    private func playMeasurementSavedFeedback() {
        #if canImport(UIKit)
        let feedback = UINotificationFeedbackGenerator()
        feedback.prepare()
        feedback.notificationOccurred(.success)
        #endif
    }

    private func playMeasurementPromptFeedback() {
        #if canImport(AudioToolbox)
        // Fallback vibration for devices/settings where UIFeedback generators feel too subtle.
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        #endif
        #if canImport(UIKit)
        let notification = UINotificationFeedbackGenerator()
        notification.prepare()
        notification.notificationOccurred(.warning)

        let impact = UIImpactFeedbackGenerator(style: .rigid)
        impact.prepare()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            impact.impactOccurred(intensity: 1.0)
        }
        #endif
    }

    private func playCancellationFeedback() {
        #if canImport(UIKit)
        let feedback = UINotificationFeedbackGenerator()
        feedback.prepare()
        feedback.notificationOccurred(.warning)
        #endif
    }
}
