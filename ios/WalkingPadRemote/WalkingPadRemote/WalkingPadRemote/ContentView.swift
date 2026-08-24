import SwiftUI
import Combine
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

    #if DEBUG
    private var isTrainingPreviewLaunch: Bool {
        ProcessInfo.processInfo.arguments.contains {
            $0.hasPrefix("--training-hub-preview=")
                || $0.hasPrefix("--active-workout-preview=")
                || $0.hasPrefix("--training-result-preview=")
                || $0 == "--training-ui-pressure-baseline"
        }
    }
    #endif

    var body: some View {
        TabView(selection: rootTabSelection) {
            ControlSwipeView(manager: manager) {
                selectedRootTabRaw = RootTab.stats.rawValue
            }
                .equatable()
                .tabItem {
                    Label("Тренировка", systemImage: "figure.run.circle")
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
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--training-ui-pressure-baseline") {
                TrainingUIUpdatePressureHarness.run(manager: manager)
                return
            }
            guard !isTrainingPreviewLaunch else { return }
            #endif
            manager.start()
            updateNativeHeartRateLifecycle(scenePhase)
        }
        .onChange(of: scenePhase) { _, phase in
            #if DEBUG
            guard !isTrainingPreviewLaunch else { return }
            #endif
            if phase == .active {
                manager.pingWatch()
            } else {
                manager.treadmillTestRunAppBecameInactive()
            }
            updateNativeHeartRateLifecycle(phase)
#if STOP_TRUTH_EXPERIMENT_CAPABILITY
            if phase != .active {
                manager.stopTruthExperimentAppBecameInactive()
            }
#endif
        }
    }

    private func updateNativeHeartRateLifecycle(_ phase: ScenePhase) {
        switch phase {
        case .active:
            manager.nativeHeartRateAppBecameActive()
        case .inactive:
            manager.nativeHeartRateAppBecameInactive()
        case .background:
            manager.nativeHeartRateAppEnteredBackground()
        @unknown default:
            manager.nativeHeartRateAppEnteredBackground()
        }
    }
}

private struct TrainingHubPresentation {
    struct Readiness: Identifiable {
        let id: String
        let title: String
        let value: String
        let sourceLabel: String?
        let systemImage: String
        let tint: Color
        let isReady: Bool
    }

    struct Metric: Identifiable {
        let id: String
        let title: String
        let value: String
        let systemImage: String
    }

    struct TargetSegment: Identifiable {
        let id: Int
        let title: String
        let rangeText: String
        let lowerBound: Int
        let upperBound: Int
        let tint: Color
    }

    let modeTitle: String
    let modeSystemImage: String
    let targetTitle: String
    let targetValue: String
    let targetSegments: [TargetSegment]
    let selectedSegmentID: Int?
    let durationMinutes: Int?
    let metrics: [Metric]
    let readiness: [Readiness]
    let startEnabled: Bool
    let startBlocker: String?
    let isPreparing: Bool
    let isPreview: Bool

    let phaseTitle: String?
    let primaryValue: String?
    let primaryUnit: String?
    let statusTitle: String?
    let statusSystemImage: String?
    let statusTint: Color
    let liveMarkerBPM: Int?
    let targetThresholdBPM: Int?
    let showsExtendAction: Bool

    init(
        modeTitle: String,
        modeSystemImage: String,
        targetTitle: String,
        targetValue: String,
        targetSegments: [TargetSegment],
        selectedSegmentID: Int?,
        durationMinutes: Int? = nil,
        metrics: [Metric],
        readiness: [Readiness],
        startEnabled: Bool,
        startBlocker: String?,
        isPreparing: Bool,
        isPreview: Bool,
        phaseTitle: String? = nil,
        primaryValue: String? = nil,
        primaryUnit: String? = nil,
        statusTitle: String? = nil,
        statusSystemImage: String? = nil,
        statusTint: Color = .secondary,
        liveMarkerBPM: Int? = nil,
        targetThresholdBPM: Int? = nil,
        showsExtendAction: Bool = false
    ) {
        self.modeTitle = modeTitle
        self.modeSystemImage = modeSystemImage
        self.targetTitle = targetTitle
        self.targetValue = targetValue
        self.targetSegments = targetSegments
        self.selectedSegmentID = selectedSegmentID
        self.durationMinutes = durationMinutes
        self.metrics = metrics
        self.readiness = readiness
        self.startEnabled = startEnabled
        self.startBlocker = startBlocker
        self.isPreparing = isPreparing
        self.isPreview = isPreview
        self.phaseTitle = phaseTitle
        self.primaryValue = primaryValue
        self.primaryUnit = primaryUnit
        self.statusTitle = statusTitle
        self.statusSystemImage = statusSystemImage
        self.statusTint = statusTint
        self.liveMarkerBPM = liveMarkerBPM
        self.targetThresholdBPM = targetThresholdBPM
        self.showsExtendAction = showsExtendAction
    }
}

private struct TrainingDistanceReading {
    let peripheralID: UUID
    let connectionEpoch: UUID
    let counter10m: Int
}

private struct TrainingSessionPresentationAnchor {
    let nativeProjectionIDs: Set<String>?
    let distanceStart: TrainingDistanceReading?
}

private struct PendingTrainingResult {
    let nativeProjectionIDs: Set<String>?
    let projectionGenerationAtEnd: UInt
    let distanceKilometres: Double?
}

private struct ResolvedTrainingResult {
    let projection: WorkoutHistoryProjection
    let distanceKilometres: Double?
}

private func formattedWorkoutResultDuration(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let remainingSeconds = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
    }
    return String(format: "%d:%02d", minutes, remainingSeconds)
}

private func factualWorkoutResultValue(_ seconds: Double?) -> Double? {
    guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
    return seconds
}

private struct TrainingEndingStatus {
    let title: String
    let systemImage: String
    let tint: Color
}

private func trainingEndingStatus(from rawStatus: String) -> TrainingEndingStatus? {
    guard !rawStatus.isEmpty else { return nil }
    if rawStatus.contains("confirmed by device") {
        return TrainingEndingStatus(
            title: "Дорожка остановлена",
            systemImage: "checkmark.circle.fill",
            tint: .green
        )
    }
    if rawStatus.contains("confirming") {
        return TrainingEndingStatus(
            title: "Проверяем остановку дорожки",
            systemImage: "hourglass",
            tint: .orange
        )
    }
    if rawStatus.contains("not sent") {
        return TrainingEndingStatus(
            title: "Команда остановки не отправлена",
            systemImage: "exclamationmark.triangle.fill",
            tint: .red
        )
    }
    if rawStatus.contains("unconfirmed")
        || rawStatus.contains("confirmation unavailable")
    {
        return TrainingEndingStatus(
            title: "Остановка дорожки не подтверждена",
            systemImage: "exclamationmark.triangle.fill",
            tint: .red
        )
    }
    return nil
}

private func makeTrainingTargetSegments(
    zoneRanges: [ClosedRange<Int>]
) -> [TrainingHubPresentation.TargetSegment] {
    zoneRanges.enumerated().map { index, range in
        TrainingHubPresentation.TargetSegment(
            id: index,
            title: "Z\(index + 1)",
            rangeText: "\(range.lowerBound)–\(range.upperBound) bpm",
            lowerBound: range.lowerBound,
            upperBound: range.upperBound,
            tint: hrZoneColor(index + 1)
        )
    }
}

private func makeHRControlTrainingHubPresentation(
    treadmillConnected: Bool,
    hrFresh: Bool,
    currentHeartRateBPM: Int?,
    heartRateSourceLabel: String?,
    targetZoneIndex: Int,
    zoneRanges: [ClosedRange<Int>],
    durationMinutes: Int,
    startEnabled: Bool,
    runtimeBlockReason: String?,
    isPreparing: Bool = false,
    isPreview: Bool = false
) -> TrainingHubPresentation {
    let safeZoneIndex = max(0, min(zoneRanges.count - 1, targetZoneIndex))
    let targetRange = zoneRanges[safeZoneIndex]
    let heartRateReadiness =
        TrainingUIHeartRateReadinessPresentationPolicy.presentation(
            isFresh: hrFresh,
            currentHeartRateBPM: currentHeartRateBPM,
            sourceLabel: heartRateSourceLabel,
            isPreparing: isPreparing
        )
    let startBlocker: String? = {
        guard !startEnabled, !isPreparing else { return nil }
        if !treadmillConnected { return "Подключите дорожку" }
        guard let runtimeBlockReason, !runtimeBlockReason.isEmpty else {
            return "Тренировка пока недоступна"
        }
        let normalized = runtimeBlockReason.lowercased()
        if normalized.contains("час") || normalized.contains("apple watch") {
            return "Пульс пока не готов к старту"
        }
        return runtimeBlockReason
    }()

    return TrainingHubPresentation(
        modeTitle: "HR‑контроль",
        modeSystemImage: "heart.text.square.fill",
        targetTitle: "Зона \(safeZoneIndex + 1)",
        targetValue: "\(targetRange.lowerBound)–\(targetRange.upperBound) bpm",
        targetSegments: makeTrainingTargetSegments(zoneRanges: zoneRanges),
        selectedSegmentID: safeZoneIndex,
        durationMinutes: durationMinutes,
        metrics: [],
        readiness: [
            .init(
                id: "treadmill",
                title: "Дорожка",
                value: treadmillConnected ? "Готова" : "Нет",
                sourceLabel: nil,
                systemImage: "figure.walk.motion",
                tint: treadmillConnected ? .green : .orange,
                isReady: treadmillConnected
            ),
            .init(
                id: "heartRate",
                title: "Пульс",
                value: heartRateReadiness.value,
                sourceLabel: heartRateReadiness.sourceLabel,
                systemImage: "heart.fill",
                tint: heartRateReadiness.isReady ? .green : .orange,
                isReady: heartRateReadiness.isReady
            )
        ],
        startEnabled: startEnabled,
        startBlocker: startBlocker,
        isPreparing: isPreparing,
        isPreview: isPreview
    )
}

private func formattedTrainingElapsed(_ totalSeconds: Int) -> String {
    let safeSeconds = max(0, totalSeconds)
    let hours = safeSeconds / 3600
    let minutes = (safeSeconds % 3600) / 60
    let seconds = safeSeconds % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%02d:%02d", minutes, seconds)
}

private func makeHRControlActivePresentation(
    treadmillConnected: Bool,
    hrFresh: Bool,
    currentHeartRateBPM: Int?,
    heartRateSourceLabel: String?,
    targetZoneIndex: Int,
    zoneRanges: [ClosedRange<Int>],
    factualSpeedKmh: Double?,
    elapsedSeconds: Int,
    isCooldown: Bool,
    cooldownTargetBPM: Int,
    canExtend: Bool,
    phaseTitleOverride: String? = nil,
    isPreview: Bool = false
) -> TrainingHubPresentation {
    let fallbackRange = 60...220
    let safeZoneIndex = zoneRanges.isEmpty
        ? 0
        : max(0, min(zoneRanges.count - 1, targetZoneIndex))
    let selectedRange = zoneRanges.indices.contains(safeZoneIndex)
        ? zoneRanges[safeZoneIndex]
        : fallbackRange
    let factualHeartRate = hrFresh ? currentHeartRateBPM : nil

    let status: (title: String, symbol: String, tint: Color) = {
        guard let factualHeartRate else {
            return ("Пульс недоступен", "waveform.path.ecg.slash", .orange)
        }
        if isCooldown {
            return factualHeartRate <= cooldownTargetBPM
                ? ("Цель достигнута", "checkmark.circle.fill", .green)
                : ("Выше цели", "arrow.up.circle.fill", .orange)
        }
        if factualHeartRate < selectedRange.lowerBound {
            return ("Ниже зоны", "arrow.down.circle.fill", .blue)
        }
        if factualHeartRate > selectedRange.upperBound {
            return ("Выше зоны", "arrow.up.circle.fill", .orange)
        }
        return ("В зоне", "checkmark.circle.fill", .green)
    }()

    return TrainingHubPresentation(
        modeTitle: "HR‑контроль",
        modeSystemImage: "heart.text.square.fill",
        targetTitle: isCooldown ? "Заминка" : "Зона \(safeZoneIndex + 1)",
        targetValue: isCooldown
            ? "≤ \(cooldownTargetBPM) bpm"
            : "\(selectedRange.lowerBound)–\(selectedRange.upperBound) bpm",
        targetSegments: makeTrainingTargetSegments(zoneRanges: zoneRanges),
        selectedSegmentID: isCooldown ? nil : safeZoneIndex,
        metrics: [
            .init(
                id: "speed",
                title: "Скорость",
                value: factualSpeedKmh.map { String(format: "%.1f км/ч", $0) } ?? "—",
                systemImage: "speedometer"
            ),
            .init(
                id: "elapsed",
                title: "Прошло",
                value: formattedTrainingElapsed(elapsedSeconds),
                systemImage: "stopwatch"
            )
        ],
        readiness: [
            .init(
                id: "treadmill",
                title: "Дорожка",
                value: treadmillConnected ? "Готова" : "Нет",
                sourceLabel: nil,
                systemImage: "figure.walk.motion",
                tint: treadmillConnected ? .green : .orange,
                isReady: treadmillConnected
            ),
            .init(
                id: "heartRate",
                title: "Пульс",
                value: factualHeartRate == nil ? "Нет" : "Доступен",
                sourceLabel: factualHeartRate == nil ? nil : heartRateSourceLabel,
                systemImage: "heart.fill",
                tint: factualHeartRate == nil ? .orange : .green,
                isReady: factualHeartRate != nil
            )
        ],
        startEnabled: false,
        startBlocker: nil,
        isPreparing: false,
        isPreview: isPreview,
        phaseTitle: phaseTitleOverride ?? (isCooldown ? "ЗАМИНКА" : "ТРЕНИРОВКА"),
        primaryValue: factualHeartRate.map(String.init) ?? "—",
        primaryUnit: factualHeartRate == nil ? nil : "bpm",
        statusTitle: status.title,
        statusSystemImage: status.symbol,
        statusTint: status.tint,
        liveMarkerBPM: factualHeartRate,
        targetThresholdBPM: isCooldown ? cooldownTargetBPM : nil,
        showsExtendAction: !isCooldown && canExtend
    )
}

private func makeProductionTrainingHubPresentation(
    manager: BluetoothManager
) -> TrainingHubPresentation {
    let heartRate = manager.trainingUIHeartRateSnapshot
    return makeHRControlTrainingHubPresentation(
        treadmillConnected: manager.isTreadmillControlReady,
        hrFresh: heartRate.isFresh,
        currentHeartRateBPM: heartRate.currentHeartRateBPM,
        heartRateSourceLabel: heartRate.sourceLabel,
        targetZoneIndex: hrZoneIndex(for: manager.hrTargetBPM, manager: manager),
        zoneRanges: hrZoneRanges(for: manager),
        durationMinutes: manager.hrDurationMinutes,
        startEnabled: manager.isHrControlStartAffordanceAvailable,
        runtimeBlockReason: manager.hrControlStartBlockReasonText,
        isPreparing: manager.isNativeHeartRatePreflightActive
    )
}

private func makeProductionActiveWorkoutPresentation(
    manager: BluetoothManager
) -> TrainingHubPresentation {
    let heartRate = manager.trainingUIHeartRateSnapshot
    let factualSpeedKmh: Double? = {
        guard manager.isConnected else { return nil }
        return manager.trainingUITreadmillSpeedKmh
    }()

    return makeHRControlActivePresentation(
        treadmillConnected: manager.isTreadmillControlReady,
        hrFresh: heartRate.isFresh,
        currentHeartRateBPM: heartRate.currentHeartRateBPM,
        heartRateSourceLabel: heartRate.sourceLabel,
        targetZoneIndex: hrZoneIndex(for: manager.hrTargetBPM, manager: manager),
        zoneRanges: hrZoneRanges(for: manager),
        factualSpeedKmh: factualSpeedKmh,
        elapsedSeconds: manager.presentedWorkoutElapsedSeconds,
        isCooldown: manager.isHrControlRunning && manager.hrRemainingSeconds <= 0,
        cooldownTargetBPM: manager.hrCooldownTargetBpm,
        canExtend: manager.canExtendHrSession,
        phaseTitleOverride: manager.presentedWorkoutPhaseTitle
    )
}

private extension TrainingUIObservationBoundary {
    convenience init(manager: BluetoothManager) {
        self.init(signals: [
            manager.$isConnected.map { _ in () }.eraseToAnyPublisher(),
            manager.$isTreadmillControlReady.map { _ in () }.eraseToAnyPublisher(),
            manager.$trainingUIHeartRateSnapshot.map { _ in () }.eraseToAnyPublisher(),
            manager.$trainingUITreadmillSpeedKmh.map { _ in () }.eraseToAnyPublisher(),
            manager.$hrTargetBPM.map { _ in () }.eraseToAnyPublisher(),
            manager.$hrZone1Max.map { _ in () }.eraseToAnyPublisher(),
            manager.$hrZone2Max.map { _ in () }.eraseToAnyPublisher(),
            manager.$hrZone3Max.map { _ in () }.eraseToAnyPublisher(),
            manager.$hrZone4Max.map { _ in () }.eraseToAnyPublisher(),
            manager.$hrDurationMinutes.map { _ in () }.eraseToAnyPublisher(),
            manager.$isHrControlStartAllowed.map { _ in () }.eraseToAnyPublisher(),
            manager.$hrControlStartBlockReasonText.map { _ in () }.eraseToAnyPublisher(),
            manager.$isNativeHeartRatePreflightActive.map { _ in () }.eraseToAnyPublisher(),
            manager.$isHrControlRunning.map { _ in () }.eraseToAnyPublisher(),
            manager.$hrRemainingSeconds.map { _ in () }.eraseToAnyPublisher(),
            manager.$hrCooldownTargetBpm.map { _ in () }.eraseToAnyPublisher(),
            manager.$timeSec.map { _ in () }.eraseToAnyPublisher(),
            manager.$isNativeWorkoutRecoveryActive.map { _ in () }.eraseToAnyPublisher(),
            manager.$nativeWorkoutRecoveryStatusText.map { _ in () }.eraseToAnyPublisher(),
            manager.$stopTruthStatusText.map { _ in () }.eraseToAnyPublisher(),
            manager.$telemetryV2ProjectionGeneration.map { _ in () }.eraseToAnyPublisher(),
            manager.$telemetryV2WorkoutHistoryState.map { _ in () }.eraseToAnyPublisher(),
            manager.$telemetryV2WorkoutHistory.map { _ in () }.eraseToAnyPublisher(),
            manager.$telemetryV2StatusText.map { _ in () }.eraseToAnyPublisher(),
            manager.$connectErrorMessage.map { _ in () }.eraseToAnyPublisher(),
            manager.$suggestDevicePicker.map { _ in () }.eraseToAnyPublisher(),
            manager.$infoToastMessage.map { _ in () }.eraseToAnyPublisher(),
        ])
    }
}

#if DEBUG
@MainActor
private enum TrainingUIUpdatePressureHarness {
    private typealias Event = (source: String, apply: (BluetoothManager) -> Void)
    private struct Measurement: Codable {
        let source: String
        var technicalEvents = 0
        var managerPublishedEvents = 0
        var trainingBoundaryPublishedEvents = 0
        var visibleSnapshotChanges = 0
        var potentialAvoidableManagerDrivenInvalidations = 0
        var potentialAvoidableTrainingBoundaryInvalidations = 0
        var rawManagerPublications = 0
        var rawTrainingBoundaryPublications = 0
        var synchronousMainThreadNanoseconds: UInt64 = 0
    }

    private struct Workload: Codable {
        let workload: String
        let measurements: [Measurement]
        let technicalEvents: Int
        let managerPublishedEvents: Int
        let trainingBoundaryPublishedEvents: Int
        let visibleSnapshotChanges: Int
        let potentialAvoidableManagerDrivenInvalidations: Int
        let potentialAvoidableTrainingBoundaryInvalidations: Int
        let rawManagerPublications: Int
        let rawTrainingBoundaryPublications: Int
        let eventToVisibleChangeRatio: Double?
        let boundaryEventToVisibleChangeRatio: Double?
        let synchronousMainThreadNanoseconds: UInt64
    }

    private struct Report: Codable {
        let schema: String
        let workloads: [Workload]
    }

    private static var didRun = false

    static func run(manager: BluetoothManager) {
        guard !didRun else { return }
        didRun = true

        let idle = measure(
            workload: "idle_hub_duplicate_discovery",
            manager: manager,
            configure: { $0.prepareTrainingUIIdlePressureBaseline() },
            events: (0..<120).map { index -> Event in
                ("ble_discovery", { $0.applyTrainingUIDiscoveryPressureEvent(index) })
            }
        )
        let activeEvents = (1...60).flatMap { second -> [Event] in
            [
                ("heart_rate", { $0.applyTrainingUIHeartRatePressureEvent(second: second) }),
                ("treadmill_status", { $0.applyTrainingUITreadmillPressureEvent(second: second) }),
                ("timer", { $0.applyTrainingUITimerPressureEvent(second: second) }),
            ]
        }
        let active = measure(
            workload: "active_workout_60s",
            manager: manager,
            configure: { $0.prepareTrainingUIActivePressureBaseline() },
            events: activeEvents
        )
        let report = Report(
            schema: "training-ui-update-pressure-v3",
            workloads: [idle, active]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(report),
              let json = String(data: data, encoding: .utf8) else { return }
        print("TRAINING_UI_PRESSURE \(json)")
    }

    private static func measure(
        workload: String,
        manager: BluetoothManager,
        configure: (BluetoothManager) -> Void,
        events: [Event]
    ) -> Workload {
        configure(manager)
        let boundary = TrainingUIObservationBoundary(manager: manager)
        var publicationCount = 0
        var boundaryPublicationCount = 0
        let managerCancellable = manager.objectWillChange.sink {
            publicationCount += 1
        }
        let boundaryCancellable = boundary.objectWillChange.sink {
            boundaryPublicationCount += 1
        }
        var measurements: [String: Measurement] = [:]
        var snapshot = visibleSnapshot(manager: manager)

        for event in events {
            let publicationsBefore = publicationCount
            let boundaryPublicationsBefore = boundaryPublicationCount
            let startedAt = DispatchTime.now().uptimeNanoseconds
            event.apply(manager)
            let nextSnapshot = visibleSnapshot(manager: manager)
            let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt

            var measurement = measurements[event.source]
                ?? Measurement(source: event.source)
            let managerPublished = publicationCount > publicationsBefore
            let boundaryPublished = boundaryPublicationCount > boundaryPublicationsBefore
            let snapshotChanged = nextSnapshot != snapshot
            measurement.technicalEvents += 1
            measurement.rawManagerPublications += publicationCount - publicationsBefore
            measurement.rawTrainingBoundaryPublications +=
                boundaryPublicationCount - boundaryPublicationsBefore
            measurement.synchronousMainThreadNanoseconds += elapsed
            if managerPublished {
                measurement.managerPublishedEvents += 1
            }
            if boundaryPublished {
                measurement.trainingBoundaryPublishedEvents += 1
            }
            if snapshotChanged {
                measurement.visibleSnapshotChanges += 1
            }
            if managerPublished && !snapshotChanged {
                measurement.potentialAvoidableManagerDrivenInvalidations += 1
            }
            if boundaryPublished && !snapshotChanged {
                measurement.potentialAvoidableTrainingBoundaryInvalidations += 1
            }
            measurements[event.source] = measurement
            snapshot = nextSnapshot
        }
        withExtendedLifetime((managerCancellable, boundaryCancellable, boundary)) {}

        let ordered = measurements.values.sorted { $0.source < $1.source }
        let technicalEvents = ordered.reduce(0) { $0 + $1.technicalEvents }
        let managerPublishedEvents = ordered.reduce(0) { $0 + $1.managerPublishedEvents }
        let trainingBoundaryPublishedEvents = ordered.reduce(0) {
            $0 + $1.trainingBoundaryPublishedEvents
        }
        let visibleSnapshotChanges = ordered.reduce(0) { $0 + $1.visibleSnapshotChanges }
        return Workload(
            workload: workload,
            measurements: ordered,
            technicalEvents: technicalEvents,
            managerPublishedEvents: managerPublishedEvents,
            trainingBoundaryPublishedEvents: trainingBoundaryPublishedEvents,
            visibleSnapshotChanges: visibleSnapshotChanges,
            potentialAvoidableManagerDrivenInvalidations: ordered.reduce(0) {
                $0 + $1.potentialAvoidableManagerDrivenInvalidations
            },
            potentialAvoidableTrainingBoundaryInvalidations: ordered.reduce(0) {
                $0 + $1.potentialAvoidableTrainingBoundaryInvalidations
            },
            rawManagerPublications: ordered.reduce(0) { $0 + $1.rawManagerPublications },
            rawTrainingBoundaryPublications: ordered.reduce(0) {
                $0 + $1.rawTrainingBoundaryPublications
            },
            eventToVisibleChangeRatio: visibleSnapshotChanges > 0
                ? Double(managerPublishedEvents) / Double(visibleSnapshotChanges)
                : nil,
            boundaryEventToVisibleChangeRatio: visibleSnapshotChanges > 0
                ? Double(trainingBoundaryPublishedEvents) / Double(visibleSnapshotChanges)
                : nil,
            synchronousMainThreadNanoseconds: ordered.reduce(0) {
                $0 + $1.synchronousMainThreadNanoseconds
            }
        )
    }

    private static func visibleSnapshot(manager: BluetoothManager) -> [String] {
        let presentation = manager.shouldPresentActiveWorkout
            ? makeProductionActiveWorkoutPresentation(manager: manager)
            : makeProductionTrainingHubPresentation(manager: manager)
        return [
            presentation.modeTitle,
            presentation.targetTitle,
            presentation.targetValue,
            presentation.metrics.map { "\($0.id)=\($0.value)" }.joined(separator: "|"),
            presentation.readiness.map {
                "\($0.id)=\($0.value)|\($0.sourceLabel ?? "")|\($0.isReady)"
            }.joined(separator: ";"),
            String(presentation.startEnabled),
            presentation.startBlocker ?? "",
            String(presentation.isPreparing),
            presentation.phaseTitle ?? "",
            presentation.primaryValue ?? "",
            presentation.primaryUnit ?? "",
            presentation.statusTitle ?? "",
            presentation.liveMarkerBPM.map(String.init) ?? "",
            presentation.targetThresholdBPM.map(String.init) ?? "",
            String(presentation.showsExtendAction),
        ]
    }
}

private func trainingHubPreviewPresentation(named name: String) -> TrainingHubPresentation? {
    let ranges = [60...134, 135...146, 147...158, 159...170, 171...220]
    func hrControl(
        treadmillReady: Bool = true,
        hrReady: Bool = true,
        bpm: Int? = 138,
        source: String? = nil,
        durationMinutes: Int = 30,
        startEnabled: Bool = true,
        preparing: Bool = false
    ) -> TrainingHubPresentation {
        makeHRControlTrainingHubPresentation(
            treadmillConnected: treadmillReady,
            hrFresh: hrReady,
            currentHeartRateBPM: bpm,
            heartRateSourceLabel: source,
            targetZoneIndex: 2,
            zoneRanges: ranges,
            durationMinutes: durationMinutes,
            startEnabled: startEnabled,
            runtimeBlockReason: nil,
            isPreparing: preparing,
            isPreview: true
        )
    }

    switch name {
    case "ready-unknown-source":
        return hrControl()
    case "ready-known-source":
        return hrControl(source: "Apple Watch")
    case "treadmill-unavailable":
        return hrControl(treadmillReady: false, startEnabled: false)
    case "hr-unavailable":
        return hrControl(hrReady: false, bpm: nil, startEnabled: false)
    case "preparing":
        return hrControl(startEnabled: false, preparing: true)
    case "duration-20":
        return hrControl(durationMinutes: 20)
    case "duration-30":
        return hrControl(durationMinutes: 30)
    case "duration-45":
        return hrControl(durationMinutes: 45)
    case "duration-legacy-10":
        return hrControl(durationMinutes: 10)
    case "duration-legacy-60":
        return hrControl(durationMinutes: 60)
    case "intervals":
        return TrainingHubPresentation(
            modeTitle: "Интервалы",
            modeSystemImage: "repeat",
            targetTitle: "4 раунда",
            targetValue: "3:00 / 2:00",
            targetSegments: [],
            selectedSegmentID: nil,
            metrics: [
                .init(id: "work", title: "Работа", value: "3 мин", systemImage: "figure.run"),
                .init(id: "recovery", title: "Восстановление", value: "2 мин", systemImage: "figure.walk")
            ],
            readiness: hrControl(startEnabled: false).readiness,
            startEnabled: false,
            startBlocker: "Только предпросмотр",
            isPreparing: false,
            isPreview: true
        )
    case "weekly-zones":
        return TrainingHubPresentation(
            modeTitle: "Недельные зоны",
            modeSystemImage: "calendar",
            targetTitle: "Осталось за неделю",
            targetValue: "15 мин",
            targetSegments: [],
            selectedSegmentID: nil,
            metrics: [
                .init(id: "zone5", title: "Зона 5", value: "3 мин", systemImage: "heart.fill"),
                .init(id: "zone4", title: "Зона 4", value: "12 мин", systemImage: "heart.fill")
            ],
            readiness: hrControl(startEnabled: false).readiness,
            startEnabled: false,
            startBlocker: "Только предпросмотр",
            isPreparing: false,
            isPreview: true
        )
    default:
        return nil
    }
}

private func activeWorkoutPreviewPresentation(named name: String) -> TrainingHubPresentation? {
    let ranges = [60...134, 135...146, 147...158, 159...170, 171...220]
    let hrControl: (
        Bool,
        Bool,
        Int?,
        String?,
        Double?,
        Bool,
        Int
    ) -> TrainingHubPresentation = { treadmillReady, hrReady, bpm, source, speed, cooldown, cooldownTarget in
        return makeHRControlActivePresentation(
            treadmillConnected: treadmillReady,
            hrFresh: hrReady,
            currentHeartRateBPM: bpm,
            heartRateSourceLabel: source,
            targetZoneIndex: 2,
            zoneRanges: ranges,
            factualSpeedKmh: speed,
            elapsedSeconds: 18 * 60 + 42,
            isCooldown: cooldown,
            cooldownTargetBPM: cooldownTarget,
            canExtend: !cooldown,
            isPreview: true
        )
    }

    switch name {
    case "active-below":
        return hrControl(true, true, 140, nil, 4.4, false, 115)
    case "active-in-zone":
        return hrControl(true, true, 152, nil, 4.4, false, 115)
    case "active-above":
        return hrControl(true, true, 166, nil, 4.2, false, 115)
    case "active-known-source":
        return hrControl(true, true, 152, "HealthKit", 4.4, false, 115)
    case "active-no-hr":
        return hrControl(true, false, nil, nil, 3.8, false, 115)
    case "active-no-speed":
        return hrControl(true, true, 152, nil, nil, false, 115)
    case "active-disconnected":
        return hrControl(false, true, 152, nil, nil, false, 115)
    case "cooldown-above":
        return hrControl(true, true, 124, nil, 3.0, true, 115)
    case "cooldown-reached":
        return hrControl(true, true, 110, nil, 2.0, true, 115)
    case "active-intervals":
        return TrainingHubPresentation(
            modeTitle: "Интервалы",
            modeSystemImage: "repeat",
            targetTitle: "Работа 2/4",
            targetValue: "3:00",
            targetSegments: [],
            selectedSegmentID: nil,
            metrics: [
                .init(id: "speed", title: "Скорость", value: "5.0 км/ч", systemImage: "speedometer"),
                .init(id: "elapsed", title: "Прошло", value: "12:30", systemImage: "stopwatch")
            ],
            readiness: hrControl(true, true, 152, nil, 5.0, false, 115).readiness,
            startEnabled: false,
            startBlocker: nil,
            isPreparing: false,
            isPreview: true,
            phaseTitle: "РАБОТА 2/4",
            primaryValue: "02:14",
            primaryUnit: nil,
            statusTitle: "Работа",
            statusSystemImage: "figure.run",
            statusTint: .orange
        )
    case "active-weekly-zones":
        return TrainingHubPresentation(
            modeTitle: "Недельные зоны",
            modeSystemImage: "calendar",
            targetTitle: "Зона 5",
            targetValue: "осталось 3 мин",
            targetSegments: [],
            selectedSegmentID: nil,
            metrics: [
                .init(id: "speed", title: "Скорость", value: "4.8 км/ч", systemImage: "speedometer"),
                .init(id: "elapsed", title: "Прошло", value: "21:05", systemImage: "stopwatch")
            ],
            readiness: hrControl(true, true, 174, nil, 4.8, false, 115).readiness,
            startEnabled: false,
            startBlocker: nil,
            isPreparing: false,
            isPreview: true,
            phaseTitle: "ЗОНА 5",
            primaryValue: "3",
            primaryUnit: "мин",
            statusTitle: "Осталось за неделю",
            statusSystemImage: "calendar.badge.clock",
            statusTint: .red
        )
    default:
        return nil
    }
}

private enum TrainingResultPreview {
    case ending(String)
    case summary(ResolvedTrainingResult)
    case unavailable
}

private func trainingResultPreview(named name: String) -> TrainingResultPreview? {
    let completeProjection = WorkoutHistoryProjection(
        id: "native:00000000-0000-0000-0000-000000000059",
        origin: .nativeV2,
        startedAt: Date(timeIntervalSince1970: 1_787_400_000),
        endedAt: Date(timeIntervalSince1970: 1_787_401_845),
        durationSeconds: 1_845,
        targetHeartRate: 152,
        averageHeartRate: 146,
        averageSpeed: WorkoutSpeedProjection(
            kilometresPerHour: 4.7,
            evidenceKind: .factual,
            provenance: "telemetry-v2-analysis-factual"
        ),
        beatsPerMetre: nil,
        zoneSeconds: [75, 260, 930, 490, 90],
        healthKitWorkoutIdentifier: nil,
        telemetrySchemaVersion: "1.0.0",
        appVersion: "1.0",
        buildNumber: "1",
        algorithmVersion: "legacy-hr-control-2026-08",
        analyzerVersion: "workout-analyzer-v1",
        quality: WorkoutProjectionQuality(
            lifecycleState: "completed",
            recorderComplete: true,
            analysisGrade: "high",
            identityStatus: "exact",
            possibleDuplicate: false,
            adaptationEligible: true,
            includedInStatistics: true,
            provenance: ["telemetry-v2-native"],
            unavailableMetrics: ["beatsPerMetre"],
            warnings: []
        )
    )

    switch name {
    case "ending-confirming":
        return .ending("stop requested • confirming")
    case "ending-confirmed":
        return .ending("stop confirmed by device")
    case "summary-complete":
        return .summary(
            ResolvedTrainingResult(
                projection: completeProjection,
                distanceKilometres: 2.43
            )
        )
    case "summary-duration-fallback":
        return .summary(
            ResolvedTrainingResult(
                projection: completeProjection,
                distanceKilometres: nil
            )
        )
    case "summary-partial":
        return .summary(
            ResolvedTrainingResult(
                projection: WorkoutHistoryProjection(
                    id: "native:00000000-0000-0000-0000-000000000060",
                    origin: .nativeV2,
                    startedAt: completeProjection.startedAt,
                    endedAt: completeProjection.endedAt,
                    durationSeconds: completeProjection.durationSeconds,
                    targetHeartRate: completeProjection.targetHeartRate,
                    averageHeartRate: nil,
                    averageSpeed: nil,
                    beatsPerMetre: nil,
                    zoneSeconds: [75, nil, 930, nil, 90],
                    healthKitWorkoutIdentifier: nil,
                    telemetrySchemaVersion: completeProjection.telemetrySchemaVersion,
                    appVersion: completeProjection.appVersion,
                    buildNumber: completeProjection.buildNumber,
                    algorithmVersion: completeProjection.algorithmVersion,
                    analyzerVersion: completeProjection.analyzerVersion,
                    quality: WorkoutProjectionQuality(
                        lifecycleState: "completed",
                        recorderComplete: true,
                        analysisGrade: "partial",
                        identityStatus: "exact",
                        possibleDuplicate: false,
                        adaptationEligible: false,
                        includedInStatistics: true,
                        provenance: ["telemetry-v2-native"],
                        unavailableMetrics: [
                            "averageHeartRate", "averageFactualSpeed", "beatsPerMetre"
                        ],
                        warnings: []
                    )
                ),
                distanceKilometres: nil
            )
        )
    case "summary-unavailable":
        return .unavailable
    default:
        return nil
    }
}
#endif

private struct TrainingReadinessStrip: View {
    let items: [TrainingHubPresentation.Readiness]
    let treadmillInteractive: Bool
    let onTreadmillTap: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { readinessItems }
            VStack(spacing: 6) { readinessItems }
        }
    }

    @ViewBuilder
    private var readinessItems: some View {
        ForEach(items) { item in
            readinessItem(item)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func readinessItem(_ item: TrainingHubPresentation.Readiness) -> some View {
        let chip = readinessChip(item)
        if item.id == "treadmill", treadmillInteractive {
            Button(action: onTreadmillTap) { chip }
                .buttonStyle(.plain)
        } else {
            chip
        }
    }

    private func readinessChip(_ item: TrainingHubPresentation.Readiness) -> some View {
        HStack(spacing: 7) {
            Image(systemName: item.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(item.tint)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(item.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(item.value)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                if let sourceLabel = item.sourceLabel {
                    Text(sourceLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Image(systemName: item.isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(item.tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.thinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(item.tint.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [item.title, item.value, item.sourceLabel].compactMap { $0 }.joined(separator: ", ")
        )
        .accessibilityValue(item.isReady ? "Готово" : "Недоступно")
    }
}

private struct TrainingZoneScale: View {
    let segments: [TrainingHubPresentation.TargetSegment]
    let selectedSegmentID: Int?
    let liveMarkerBPM: Int?
    let targetThresholdBPM: Int?
    let interactive: Bool
    let onSegmentTap: (Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasMarkerLayer: Bool {
        liveMarkerBPM != nil || targetThresholdBPM != nil
    }

    private var aggregateAccessibilityValue: String {
        var parts: [String] = []
        if let selectedSegmentID,
           let selected = segments.first(where: { $0.id == selectedSegmentID }) {
            parts.append("Выбрана зона \(selected.id + 1), \(selected.rangeText)")
        }
        if let targetThresholdBPM {
            parts.append("Цель заминки не выше \(targetThresholdBPM) ударов в минуту")
        }
        if let liveMarkerBPM {
            parts.append("Текущий пульс \(liveMarkerBPM) ударов в минуту")
        }
        return parts.isEmpty ? "Данные недоступны" : parts.joined(separator: ". ")
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                HStack(spacing: 5) {
                    ForEach(segments) { segment in
                        let isSelected = segment.id == selectedSegmentID
                        if interactive {
                            Button {
                                onSegmentTap(segment.id)
                            } label: {
                                segmentContent(segment, isSelected: isSelected)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Выбирает целевой диапазон пульса")
                        } else {
                            segmentContent(segment, isSelected: isSelected)
                        }
                    }
                }
                .padding(.top, hasMarkerLayer ? 20 : 0)

                if let targetThresholdBPM {
                    Rectangle()
                        .fill(Color.primary.opacity(0.5))
                        .frame(width: 2, height: 30)
                        .position(
                            x: markerX(for: targetThresholdBPM, width: proxy.size.width),
                            y: 36
                        )
                        .accessibilityHidden(true)
                }

                if let liveMarkerBPM {
                    VStack(spacing: 0) {
                        Image(systemName: "triangle.fill")
                            .font(.caption2.weight(.bold))
                            .rotationEffect(.degrees(180))
                        Rectangle()
                            .frame(width: 2, height: 13)
                    }
                    .foregroundStyle(Color.primary)
                    .position(
                        x: markerX(for: liveMarkerBPM, width: proxy.size.width),
                        y: 12
                    )
                    .animation(
                        reduceMotion ? nil : .snappy(duration: 0.25),
                        value: liveMarkerBPM
                    )
                    .accessibilityHidden(true)
                }
            }
        }
        .frame(height: hasMarkerLayer ? 64 : 44)
        .accessibilityElement(children: interactive ? .contain : .ignore)
        .accessibilityLabel("Пульсовые зоны")
        .accessibilityValue(aggregateAccessibilityValue)
    }

    private func segmentContent(
        _ segment: TrainingHubPresentation.TargetSegment,
        isSelected: Bool
    ) -> some View {
        VStack(spacing: 5) {
            Text(segment.title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            Capsule(style: .continuous)
                .fill(segment.tint.opacity(isSelected ? 0.92 : 0.24))
                .frame(height: isSelected ? 16 : 10)
                .overlay {
                    if isSelected {
                        Capsule(style: .continuous)
                            .stroke(Color.primary.opacity(0.65), lineWidth: 2)
                    }
                }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Зона \(segment.id + 1), \(segment.rangeText)")
        .accessibilityValue(isSelected ? "Выбрана" : "Не выбрана")
        .accessibilityHidden(!interactive)
    }

    private func markerX(for bpm: Int, width: CGFloat) -> CGFloat {
        guard !segments.isEmpty else { return width / 2 }
        let position: Double
        if bpm <= segments[0].lowerBound {
            position = 0
        } else if bpm >= segments[segments.count - 1].upperBound {
            position = 1
        } else if let index = segments.firstIndex(where: {
            bpm >= $0.lowerBound && bpm <= $0.upperBound
        }) {
            let segment = segments[index]
            let span = max(1, segment.upperBound - segment.lowerBound)
            let fraction = Double(bpm - segment.lowerBound) / Double(span)
            position = (Double(index) + fraction) / Double(segments.count)
        } else {
            position = 0
        }
        let inset: CGFloat = 7
        return min(max(inset, width * position), max(inset, width - inset))
    }
}

private let trainingDurationPresets = [20, 25, 30, 35, 40, 45]

private struct TrainingDurationPresetSelector: View {
    let selectedMinutes: Int
    let interactive: Bool
    let onSelect: (Int) -> Void

    private var hasPresetSelection: Bool {
        trainingDurationPresets.contains(selectedMinutes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("ВРЕМЯ · МИН")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if !hasPresetSelection {
                    Text("Текущее: \(selectedMinutes) мин")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityLabel("Текущая длительность \(selectedMinutes) минут")
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    presetButtons
                }

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                    spacing: 6
                ) {
                    presetButtons
                }
            }
        }
    }

    @ViewBuilder
    private var presetButtons: some View {
        ForEach(trainingDurationPresets, id: \.self) { minutes in
            let isSelected = minutes == selectedMinutes
            Button {
                guard interactive else { return }
                onSelect(minutes)
            } label: {
                Text("\(minutes)")
                    .font(.subheadline.weight(isSelected ? .bold : .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
                    .background(
                        isSelected ? Color.accentColor : Color(.systemBackground).opacity(0.55),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(
                                isSelected ? Color.accentColor : Color.secondary.opacity(0.16),
                                lineWidth: isSelected ? 2 : 1
                            )
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(minutes) минут")
            .accessibilityValue(isSelected ? "Выбрано" : "Не выбрано")
            .accessibilityHidden(!interactive)
        }
    }
}

private struct TrainingHubView: View {
    let presentation: TrainingHubPresentation
    let onTreadmillTap: () -> Void
    let onZoneTap: (Int) -> Void
    let onDurationSelect: (Int) -> Void
    let onSettingsTap: () -> Void
    let onStart: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                TrainingReadinessStrip(
                    items: presentation.readiness,
                    treadmillInteractive: !presentation.isPreview && !presentation.isPreparing,
                    onTreadmillTap: onTreadmillTap
                )
                hero
                startArea
                    .padding(.top, 6)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 20)
        }
    }

    private var hero: some View {
        VStack(spacing: 18) {
            modeSelector

            VStack(spacing: 4) {
                Text(presentation.targetTitle)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .multilineTextAlignment(.center)
                Text(presentation.targetValue)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)

            if !presentation.targetSegments.isEmpty {
                targetScale
            }

            if let durationMinutes = presentation.durationMinutes {
                TrainingDurationPresetSelector(
                    selectedMinutes: durationMinutes,
                    interactive: !presentation.isPreview && !presentation.isPreparing,
                    onSelect: onDurationSelect
                )
            }

            if !presentation.metrics.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { metricItems }
                    VStack(spacing: 8) { metricItems }
                }
            }

            if !presentation.isPreview && !presentation.isPreparing {
                Button(action: onSettingsTap) {
                    HStack {
                        Label("Параметры", systemImage: "slider.horizontal.3")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Открывает параметры HR-контроля")
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.13), .clear, hrZoneColor((presentation.selectedSegmentID ?? 0) + 1).opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
        }
    }

    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("РЕЖИМ ТРЕНИРОВКИ")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            if presentation.isPreview {
                modeSelectorLabel
            } else {
                Menu {
                    Button(action: {}) {
                        Label("HR‑контроль", systemImage: "checkmark")
                    }
                    Button(action: {}) {
                        Label("Интервалы · Скоро", systemImage: "hourglass")
                    }
                    .disabled(true)
                } label: {
                    modeSelectorLabel
                }
                .accessibilityLabel("Режим тренировки, HR-контроль")
                .accessibilityHint("Интервальные тренировки появятся позже")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modeSelectorLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: presentation.modeSystemImage)
                .foregroundStyle(Color.accentColor)
            Text(presentation.modeTitle)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Spacer()
            if !presentation.isPreview {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.systemBackground).opacity(0.62), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var targetScale: some View {
        TrainingZoneScale(
            segments: presentation.targetSegments,
            selectedSegmentID: presentation.selectedSegmentID,
            liveMarkerBPM: nil,
            targetThresholdBPM: nil,
            interactive: !presentation.isPreview && !presentation.isPreparing,
            onSegmentTap: onZoneTap
        )
    }

    @ViewBuilder
    private var metricItems: some View {
        ForEach(presentation.metrics) { metric in
            let content = HStack(spacing: 8) {
                Image(systemName: metric.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(metric.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(metric.value)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(.systemBackground).opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            content
        }
    }

    private var startArea: some View {
        VStack(spacing: 7) {
            if let blocker = presentation.startBlocker {
                Label(blocker, systemImage: "exclamationmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if presentation.isPreparing {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Получаем пульс…")
                        .font(.headline)
                    Text("Дорожка запустится автоматически, когда появится пульс.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Отмена", role: .cancel, action: onCancel)
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Получаем пульс. Дорожка запустится автоматически, когда появится пульс.")
            } else {
                Button {
                    guard !presentation.isPreview else { return }
                    onStart()
                } label: {
                    Label("Начать тренировку", systemImage: "play.fill")
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!presentation.startEnabled)
                .accessibilityHint("Запускает HR-контроль с выбранной целевой зоной")
            }
        }
    }
}

private struct ActiveWorkoutShell: View {
    let presentation: TrainingHubPresentation
    let onExtend: () -> Void
    let onStop: () -> Void
    var stopEnabled = true

    @ScaledMetric(relativeTo: .largeTitle) private var primaryValueSize: CGFloat = 86
    @State private var showExtendConfirm = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                phaseRow
                TrainingReadinessStrip(
                    items: presentation.readiness,
                    treadmillInteractive: false,
                    onTreadmillTap: {}
                )
                liveHero
                secondaryMetrics
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            controls
        }
        .alert("Добавить 5 минут?", isPresented: $showExtendConfirm) {
            Button("Добавить") {
                guard !presentation.isPreview else { return }
                onExtend()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Тренировка будет продлена на 5 минут.")
        }
    }

    private var phaseRow: some View {
        HStack(spacing: 8) {
            Image(systemName: presentation.modeSystemImage)
                .foregroundStyle(Color.accentColor)
            Text(presentation.phaseTitle ?? presentation.modeTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var liveHero: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(presentation.primaryValue ?? "—")
                    .font(.system(size: primaryValueSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .contentTransition(.numericText())
                if let unit = presentation.primaryUnit {
                    Text(unit)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Текущий пульс")
            .accessibilityValue(
                [presentation.primaryValue, presentation.primaryUnit]
                    .compactMap { $0 }
                    .joined(separator: " ")
            )

            if !presentation.targetSegments.isEmpty {
                TrainingZoneScale(
                    segments: presentation.targetSegments,
                    selectedSegmentID: presentation.selectedSegmentID,
                    liveMarkerBPM: presentation.liveMarkerBPM,
                    targetThresholdBPM: presentation.targetThresholdBPM,
                    interactive: false,
                    onSegmentTap: { _ in }
                )
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    targetSummary
                    Spacer(minLength: 8)
                    relationStatus
                }
                VStack(spacing: 8) {
                    targetSummary
                    relationStatus
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(presentation.statusTint.opacity(0.22), lineWidth: 1)
        }
    }

    private var targetSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(presentation.targetTitle)
                .font(.subheadline.weight(.semibold))
            Text(presentation.targetValue)
                .font(.headline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Цель")
    }

    private var relationStatus: some View {
        Label(
            presentation.statusTitle ?? "Статус недоступен",
            systemImage: presentation.statusSystemImage ?? "questionmark.circle"
        )
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(presentation.statusTint)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(presentation.statusTint.opacity(0.12), in: Capsule(style: .continuous))
        .accessibilityLabel(presentation.statusTitle ?? "Статус недоступен")
    }

    private var secondaryMetrics: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { metricItems }
            VStack(spacing: 8) { metricItems }
        }
    }

    @ViewBuilder
    private var metricItems: some View {
        ForEach(presentation.metrics) { metric in
            HStack(spacing: 10) {
                Image(systemName: metric.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(metric.value)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .padding(.horizontal, 12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Group {
                if presentation.showsExtendAction {
                    Button("+5 мин") {
                        guard !presentation.isPreview else { return }
                        showExtendConfirm = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityLabel("Продлить тренировку на 5 минут")
                } else {
                    Color.clear
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 48)

            Button {
                guard !presentation.isPreview else { return }
                onStop()
            } label: {
                Label("Стоп", systemImage: "stop.fill")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.red)
            .disabled(!stopEnabled)
            .accessibilityLabel("Остановить HR-контроль")
            .accessibilityHint(
                stopEnabled
                    ? "Запускает существующий процесс остановки тренировки"
                    : "Доступно после восстановления управления дорожкой"
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }
}

private struct TrainingWorkoutEndingView: View {
    let stopStatusText: String

    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        VStack {
            Spacer(minLength: 24)
            VStack(spacing: 16) {
                Text("Завершаем тренировку…")
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($headingFocused)

                if let status = trainingEndingStatus(from: stopStatusText) {
                    Label(status.title, systemImage: status.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(status.tint)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(status.tint.opacity(0.12), in: Capsule(style: .continuous))
                        .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 16)
            Spacer(minLength: 24)
        }
        .onAppear { headingFocused = true }
    }
}

private struct TrainingWorkoutSummaryView: View {
    private struct SecondaryMetric: Identifiable {
        let id: String
        let title: String
        let value: String
        let systemImage: String
    }

    private struct ZoneResult: Identifiable {
        let id: Int
        let seconds: Double?
        let share: Double?
    }

    let result: ResolvedTrainingResult
    let onDone: () -> Void
    let onOpenStatistics: () -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var heroValueSize: CGFloat = 62
    @AccessibilityFocusState private var headingFocused: Bool

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var durationSeconds: Double? {
        factualWorkoutResultValue(result.projection.durationSeconds)
    }

    private var factualAverageSpeed: WorkoutSpeedProjection? {
        guard let speed = result.projection.averageSpeed,
              speed.evidenceKind == .factual,
              speed.kilometresPerHour.isFinite,
              speed.kilometresPerHour >= 0 else { return nil }
        return speed
    }

    private var averageHeartRate: Double? {
        factualWorkoutResultValue(result.projection.averageHeartRate)
    }

    private var normalizedZoneValues: [Double?]? {
        guard let values = result.projection.zoneSeconds, values.count == 5 else { return nil }
        return values.map(factualWorkoutResultValue)
    }

    private var zoneResults: [ZoneResult]? {
        guard let values = normalizedZoneValues else { return nil }
        let completeValues = values.compactMap { $0 }
        let total = completeValues.count == 5 ? completeValues.reduce(0, +) : 0
        return values.enumerated().map { index, seconds in
            ZoneResult(
                id: index,
                seconds: seconds,
                share: total > 0 ? seconds.map { $0 / total } : nil
            )
        }
    }

    private var isPartial: Bool {
        result.projection.quality.lifecycleState != "completed"
            || result.projection.quality.recorderComplete == false
            || durationSeconds == nil
            || averageHeartRate == nil
            || factualAverageSpeed == nil
            || normalizedZoneValues == nil
            || normalizedZoneValues?.contains(where: { $0 == nil }) == true
    }

    private var secondaryMetrics: [SecondaryMetric] {
        var metrics: [SecondaryMetric] = []
        if result.distanceKilometres != nil, let durationSeconds {
            metrics.append(
                SecondaryMetric(
                    id: "duration",
                    title: "Продолжительность",
                    value: formattedWorkoutResultDuration(durationSeconds),
                    systemImage: "stopwatch"
                )
            )
        }
        if let averageHeartRate {
            metrics.append(
                SecondaryMetric(
                    id: "averageHeartRate",
                    title: "Средний пульс",
                    value: "\(Int(averageHeartRate.rounded())) bpm",
                    systemImage: "heart.fill"
                )
            )
        }
        if let factualAverageSpeed {
            metrics.append(
                SecondaryMetric(
                    id: "averageSpeed",
                    title: "Средняя скорость",
                    value: String(format: "%.1f км/ч", factualAverageSpeed.kilometresPerHour),
                    systemImage: "speedometer"
                )
            )
        }
        return metrics
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 5) {
                    Text("Итог тренировки")
                        .font(.title2.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($headingFocused)
                    if let startedAt = result.projection.startedAt {
                        Text(Self.dateFormatter.string(from: startedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                hero

                if isPartial {
                    Label("Часть данных недоступна", systemImage: "info.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                }

                if !secondaryMetrics.isEmpty {
                    secondaryMetricsSection
                }

                zonesSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actions
        }
        .onAppear { headingFocused = true }
    }

    @ViewBuilder
    private var hero: some View {
        if let distance = result.distanceKilometres,
           distance.isFinite,
           distance >= 0 {
            heroCard(
                value: String(format: "%.2f км", locale: Locale.current, distance),
                label: "Дистанция"
            )
        } else if let durationSeconds {
            heroCard(
                value: formattedWorkoutResultDuration(durationSeconds),
                label: "Продолжительность"
            )
        }
    }

    private func heroCard(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: heroValueSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(label)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    private var secondaryMetricsSection: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { secondaryMetricItems }
            VStack(spacing: 8) { secondaryMetricItems }
        }
    }

    @ViewBuilder
    private var secondaryMetricItems: some View {
        ForEach(secondaryMetrics) { metric in
            HStack(spacing: 9) {
                Image(systemName: metric.systemImage)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(metric.value)
                        .font(.headline.weight(.semibold))
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .padding(.horizontal, 12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(metric.title)
            .accessibilityValue(metric.value)
        }
    }

    private var zonesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Пульсовые зоны")
                .font(.headline.weight(.semibold))

            if let zoneResults {
                ForEach(zoneResults) { zone in
                    zoneRow(zone)
                }
            } else {
                Text("Данные по пульсовым зонам недоступны")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Данные по пульсовым зонам недоступны")
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func zoneRow(_ zone: ZoneResult) -> some View {
        let title = "Z\(zone.id + 1)"
        let value = zone.seconds.map(formattedWorkoutResultDuration) ?? "Недоступно"
        return VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                    Spacer()
                    Text(value)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                    Text(value)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
            }

            if let share = zone.share {
                ProgressView(value: min(1, max(0, share)))
                    .tint(hrZoneColor(zone.id + 1))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Зона \(zone.id + 1)")
        .accessibilityValue(zone.seconds == nil ? "Недоступно" : value)
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button("Готово", action: onDone)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            Button("Открыть статистику", action: onOpenStatistics)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }
}

private struct TrainingWorkoutUnavailableView: View {
    let onDone: () -> Void
    let onOpenStatistics: () -> Void

    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        VStack {
            Spacer(minLength: 24)
            VStack(spacing: 10) {
                Text("Итог пока недоступен")
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($headingFocused)
                Text("Не удалось точно определить результат этой тренировки.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 16)
            Spacer(minLength: 24)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                Button("Готово", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                Button("Открыть статистику", action: onOpenStatistics)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(.ultraThinMaterial)
        }
        .onAppear { headingFocused = true }
    }
}

private struct ControlSwipeView: View, Equatable {
    let manager: BluetoothManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var trainingObservation: TrainingUIObservationBoundary
    @State private var showDevicePicker = false
    @State private var showConnectError = false
    @State private var presentSuggestedPicker = false
    @State private var showInfoToast = false
    @State private var showParameters = false
    @State private var sessionPresentationAnchor: TrainingSessionPresentationAnchor?
    @State private var pendingTrainingResult: PendingTrainingResult?
    @State private var resolvedTrainingResult: ResolvedTrainingResult?
    @State private var trainingResultUnavailable = false
    let onOpenStatistics: () -> Void
    private let heroAccent: Color = .orange

    init(manager: BluetoothManager, onOpenStatistics: @escaping () -> Void) {
        self.manager = manager
        self.onOpenStatistics = onOpenStatistics
        _trainingObservation = StateObject(
            wrappedValue: TrainingUIObservationBoundary(manager: manager)
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.manager === rhs.manager
    }

    private var productionTrainingHubPresentation: TrainingHubPresentation {
        makeProductionTrainingHubPresentation(manager: manager)
    }

    private var trainingHubPresentation: TrainingHubPresentation {
        #if DEBUG
        if let argument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix("--training-hub-preview=")
        }) {
            let name = String(argument.dropFirst("--training-hub-preview=".count))
            if let preview = trainingHubPreviewPresentation(named: name) {
                return preview
            }
        }
        #endif
        return productionTrainingHubPresentation
    }

    private var productionActiveWorkoutPresentation: TrainingHubPresentation {
        makeProductionActiveWorkoutPresentation(manager: manager)
    }

    private var activeWorkoutPresentation: TrainingHubPresentation? {
        #if DEBUG
        if let argument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix("--active-workout-preview=")
        }) {
            let name = String(argument.dropFirst("--active-workout-preview=".count))
            if let preview = activeWorkoutPreviewPresentation(named: name) {
                return preview
            }
        }
        #endif
        guard manager.shouldPresentActiveWorkout else { return nil }
        return productionActiveWorkoutPresentation
    }

    #if DEBUG
    private var resultPreview: TrainingResultPreview? {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix("--training-result-preview=")
        }) else { return nil }
        let name = String(argument.dropFirst("--training-result-preview=".count))
        return trainingResultPreview(named: name)
    }
    #endif

    private var flowTransitionID: String {
        #if DEBUG
        if let resultPreview {
            switch resultPreview {
            case .ending: return "preview-ending"
            case .summary: return "preview-summary"
            case .unavailable: return "preview-unavailable"
            }
        }
        #endif
        if resolvedTrainingResult != nil { return "summary" }
        if trainingResultUnavailable { return "summary-unavailable" }
        if pendingTrainingResult != nil { return "ending" }
        if activeWorkoutPresentation != nil { return "active" }
        return "hub"
    }

    private var usesCompactNavigationTitle: Bool {
        flowTransitionID != "hub"
    }

    @ViewBuilder
    private var trainingFlowContent: some View {
        #if DEBUG
        if let resultPreview {
            switch resultPreview {
            case .ending(let status):
                TrainingWorkoutEndingView(stopStatusText: status)
            case .summary(let result):
                TrainingWorkoutSummaryView(
                    result: result,
                    onDone: {},
                    onOpenStatistics: {}
                )
            case .unavailable:
                TrainingWorkoutUnavailableView(onDone: {}, onOpenStatistics: {})
            }
        } else {
            productionTrainingFlowContent
        }
        #else
        productionTrainingFlowContent
        #endif
    }

    @ViewBuilder
    private var productionTrainingFlowContent: some View {
        if let resolvedTrainingResult {
            TrainingWorkoutSummaryView(
                result: resolvedTrainingResult,
                onDone: clearTrainingResultPresentation,
                onOpenStatistics: openStatistics
            )
        } else if trainingResultUnavailable {
            TrainingWorkoutUnavailableView(
                onDone: clearTrainingResultPresentation,
                onOpenStatistics: openStatistics
            )
        } else if pendingTrainingResult != nil {
            TrainingWorkoutEndingView(stopStatusText: manager.stopTruthStatusText)
        } else if let activePresentation = activeWorkoutPresentation {
            ActiveWorkoutShell(
                presentation: activePresentation,
                onExtend: { manager.extendHrSession(minutes: 5) },
                onStop: { manager.stopHrControl() },
                stopEnabled: manager.canStopPresentedWorkout
            )
        } else {
            trainingHub
        }
    }

    private var trainingHub: some View {
        TrainingHubView(
            presentation: trainingHubPresentation,
            onTreadmillTap: { showDevicePicker = true },
            onZoneTap: { zoneIndex in
                let ranges = hrZoneRanges(for: manager)
                guard ranges.indices.contains(zoneIndex) else { return }
                manager.hrTargetBPM = hrZoneTargetBpm(
                    zone: zoneIndex + 1,
                    range: ranges[zoneIndex]
                )
            },
            onDurationSelect: { manager.hrDurationMinutes = $0 },
            onSettingsTap: { showParameters = true },
            onStart: { manager.startHrControl() },
            onCancel: { manager.cancelNativeHeartRatePreflight() }
        )
        .onAppear { manager.trainingHubDidAppear() }
        .onDisappear { manager.trainingHubDidDisappear() }
    }

    private func currentFactualDistanceReading() -> TrainingDistanceReading? {
        guard manager.isConnected,
              let peripheralID = manager.connectedPeripheralId,
              let connectionEpoch = manager.controllerUnitsTruth.connectionEpoch,
              manager.controllerUnitsTruth.status == .valid,
              manager.controllerUnitsTruth.units == .metric,
              manager.deviceReportedChecksumOk,
              !manager.deviceReportedRawHex.isEmpty,
              manager.deviceReportedDistance10m >= 0,
              Double(manager.lastNotifyAgeSeconds) <= StopObservationPolicy.freshnessInterval
        else {
            return nil
        }
        return TrainingDistanceReading(
            peripheralID: peripheralID,
            connectionEpoch: connectionEpoch,
            counter10m: manager.deviceReportedDistance10m
        )
    }

    private func factualSessionDistanceKilometres(
        from start: TrainingDistanceReading?,
        to end: TrainingDistanceReading?
    ) -> Double? {
        guard let start,
              let end,
              start.peripheralID == end.peripheralID,
              start.connectionEpoch == end.connectionEpoch,
              end.counter10m >= start.counter10m else {
            return nil
        }
        return Double(end.counter10m - start.counter10m) * 10.0 / 1_000.0
    }

    private func beginTrainingPresentationSession() {
        let nativeProjectionIDs: Set<String>? = manager.telemetryV2WorkoutHistoryState == .loaded
            ? Set(
                manager.telemetryV2WorkoutHistory
                    .filter { $0.origin == .nativeV2 }
                    .map(\.id)
            )
            : nil
        sessionPresentationAnchor = TrainingSessionPresentationAnchor(
            nativeProjectionIDs: nativeProjectionIDs,
            distanceStart: currentFactualDistanceReading()
        )
        pendingTrainingResult = nil
        resolvedTrainingResult = nil
        trainingResultUnavailable = false
    }

    private func finishTrainingPresentationSession() {
        guard let anchor = sessionPresentationAnchor else {
            showUnavailableTrainingResult()
            return
        }
        let distance = factualSessionDistanceKilometres(
            from: anchor.distanceStart,
            to: currentFactualDistanceReading()
        )
        pendingTrainingResult = PendingTrainingResult(
            nativeProjectionIDs: anchor.nativeProjectionIDs,
            projectionGenerationAtEnd: manager.telemetryV2ProjectionGeneration,
            distanceKilometres: distance
        )
        sessionPresentationAnchor = nil
        resolvedTrainingResult = nil
        trainingResultUnavailable = false
        resolveTrainingResultIfPossible()
    }

    private func resolveTrainingResultIfPossible() {
        guard let pendingTrainingResult else { return }
        guard let baselineIDs = pendingTrainingResult.nativeProjectionIDs else {
            showUnavailableTrainingResult()
            return
        }
        if case .failed = manager.telemetryV2WorkoutHistoryState {
            showUnavailableTrainingResult()
            return
        }
        guard manager.telemetryV2ProjectionGeneration
                > pendingTrainingResult.projectionGenerationAtEnd,
              manager.telemetryV2WorkoutHistoryState == .loaded else {
            return
        }
        let candidates = manager.telemetryV2WorkoutHistory.filter {
            $0.origin == .nativeV2 && !baselineIDs.contains($0.id)
        }
        guard candidates.count == 1, let projection = candidates.first else {
            showUnavailableTrainingResult()
            return
        }
        resolvedTrainingResult = ResolvedTrainingResult(
            projection: projection,
            distanceKilometres: pendingTrainingResult.distanceKilometres
        )
        self.pendingTrainingResult = nil
        trainingResultUnavailable = false
    }

    private func resolveTerminalTelemetryFailureIfNeeded(_ status: String) {
        guard pendingTrainingResult != nil else { return }
        if status.hasPrefix("unavailable")
            || status.contains("ended-before-recorder-ready")
            || status.contains("session-start-failed")
        {
            showUnavailableTrainingResult()
        }
    }

    private func showUnavailableTrainingResult() {
        pendingTrainingResult = nil
        resolvedTrainingResult = nil
        trainingResultUnavailable = true
    }

    private func clearTrainingResultPresentation() {
        sessionPresentationAnchor = nil
        pendingTrainingResult = nil
        resolvedTrainingResult = nil
        trainingResultUnavailable = false
    }

    private func openStatistics() {
        clearTrainingResultPresentation()
        onOpenStatistics()
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

                trainingFlowContent
                    .id(flowTransitionID)
                    .transition(.opacity)
            }
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.2),
                value: flowTransitionID
            )
            .navigationTitle("Тренировка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(usesCompactNavigationTitle ? .visible : .hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showParameters) {
                HRParametersFormView()
                    .environmentObject(manager)
            }
            .sheet(isPresented: $showDevicePicker) {
                DevicePickerView()
                    .environmentObject(manager)
            }
            .onChange(of: manager.isHrControlRunning) { wasRunning, isRunning in
                if isRunning {
                    beginTrainingPresentationSession()
                } else if wasRunning {
                    finishTrainingPresentationSession()
                }
            }
            .onChange(of: manager.telemetryV2ProjectionGeneration) { _, _ in
                resolveTrainingResultIfPossible()
            }
            .onChange(of: manager.telemetryV2WorkoutHistoryState) { _, _ in
                resolveTrainingResultIfPossible()
            }
            .onChange(of: manager.telemetryV2WorkoutHistory.map(\.id)) { _, _ in
                resolveTrainingResultIfPossible()
            }
            .onChange(of: manager.telemetryV2StatusText) { _, status in
                resolveTerminalTelemetryFailureIfNeeded(status)
            }
            .onChange(of: manager.connectErrorMessage) { _, newValue in
                if newValue != nil { showConnectError = true }
            }
            .alert("Проблема с подключением", isPresented: $showConnectError, presenting: manager.connectErrorMessage) { _ in
                Button("Выбрать другую дорожку") {
                    manager.consumeConnectErrorMessage()
                    showDevicePicker = true
                }
                Button("OK", role: .cancel) {
                    manager.consumeConnectErrorMessage()
                }
            } message: { msg in
                Text(msg)
            }
            .onChange(of: manager.suggestDevicePicker) { _, newValue in
                if newValue { presentSuggestedPicker = true }
            }
            .sheet(isPresented: $presentSuggestedPicker, onDismiss: {
                manager.suggestDevicePicker = false
            }) {
                DevicePickerView()
                    .environmentObject(manager)
            }
            .onChange(of: manager.infoToastMessage) { _, newValue in
                if newValue != nil { showInfoToast = true }
            }
            .alert("Информация", isPresented: $showInfoToast, presenting: manager.infoToastMessage) { _ in
                Button("Открыть выбор") { showDevicePicker = true }
                Button("OK", role: .cancel) {}
            } message: { msg in
                Text(msg)
            }
        }
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

                if let stats, stats.excludedWorkoutCount > 0 {
                    Text(
                        "Исключено из агрегатов: \(stats.excludedWorkoutCount) · "
                            + statisticsExclusionReasonText(stats.exclusionReasonCounts)
                            + ". Валидные суммы сохранены; исключённые тренировки не считаются нулями."
                    )
                    .font(.caption2)
                    .foregroundColor(.orange)
                }

                if let stats,
                   stats.workoutsWithUnavailableDuration > 0
                    || stats.workoutsWithUnavailableZones > 0 {
                    Text("Часть метрик недоступна; пропуски показаны как «—» и не заменены нулями.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func statisticsExclusionReasonText(
        _ counts: [WorkoutStatisticsExclusionReason: Int]
    ) -> String {
        counts.keys.sorted { $0.rawValue < $1.rawValue }.map { reason in
            let title: String
            switch reason {
            case .identity:
                title = "identity"
            case .possibleDuplicate:
                title = "duplicate"
            case .lifecycleOrQuality:
                title = "lifecycle/quality"
            }
            return "\(title): \(counts[reason, default: 0])"
        }.joined(separator: ", ")
    }

    private var zoneRanges: [String] {
        (0..<5).map { zoneRangeText(index: $0) }
    }

    @ViewBuilder
    private func zoneSummaryList(scope: StatsScope, zoneSeconds: [Double?]?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<5, id: \.self) { idx in
                let seconds = zoneSeconds.flatMap { idx < $0.count ? $0[idx] : nil }
                let monthPlan = idx < manager.zonePlanMinutes.count ? manager.zonePlanMinutes[idx] : 0
                let planSeconds = ZonePlanProgress.planSeconds(
                    monthlyPlanMinutes: monthPlan,
                    isWeekly: scope == .week
                )
                ZoneSummaryRow(
                    title: "Зона \(idx + 1)",
                    rangeText: zoneRangeText(index: idx),
                    actualSeconds: seconds,
                    planSeconds: planSeconds,
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
    let actualSeconds: Double?
    let planSeconds: Double
    let color: Color

    var body: some View {
        let progress = ZonePlanProgress.rawProgress(
            actualSeconds: actualSeconds,
            planSeconds: planSeconds
        )
        let achieved = ZonePlanProgress.isAchieved(
            actualSeconds: actualSeconds,
            planSeconds: planSeconds
        )
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
                Text("Факт \(ZonePlanProgress.durationText(seconds: actualSeconds))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("·")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if planSeconds > 0 {
                    Text("План \(ZonePlanProgress.durationText(seconds: planSeconds))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Text("План —")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            if let displayedProgress = ZonePlanProgress.displayedProgress(progress) {
                ProgressView(value: displayedProgress)
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
                                    Text(healthKitLinkageText(for: entry, identifier: healthKitID))
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

    private func healthKitLinkageText(
        for entry: WorkoutHistoryProjection,
        identifier: UUID
    ) -> String {
        let provenance = entry.quality.provenance.contains(
            "telemetry-v2-imported-exact-healthkit-linkage"
        ) ? " · exact import linkage" : " · native linkage"
        return "HealthKit: \(identifier.uuidString.lowercased())\(provenance)"
    }
}

private enum HrControlPreviewMode: String, CaseIterable, Identifiable {
    case workout = "Тренировка"
    case cooldown = "Заминка"

    var id: String { rawValue }
}

private struct DebugTreadmillFactualObservationRows: View {
    @ObservedObject var publisher: TreadmillFactualObservationPublisher
    let manager: BluetoothManager

    var body: some View {
        Group {
            Text(
                "Reported speed: \(String(format: "%.1f", manager.deviceReportedSpeedKmh))  "
                    + "AppSpeed: \(String(format: "%.1f", manager.deviceReportedAppSpeedKmh))"
            )
            Text(
                "State \(manager.deviceReportedState)  Mode \(manager.deviceReportedManualMode)  "
                    + "Button \(manager.deviceReportedButton)  Checksum \(manager.deviceReportedChecksumOk ? "ok" : "bad")"
            )
            Text(
                "Time \(manager.deviceReportedTimeSeconds)s  "
                    + "Dist \(manager.deviceReportedDistance10m * 10)m  Steps \(manager.deviceReportedSteps)"
            )
            if !manager.deviceReportedRawHex.isEmpty {
                Text("FE01 raw: \(manager.deviceReportedRawHex)")
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }
}

private struct DebugHeartRateFactualObservationRow: View {
    @ObservedObject var state: HeartRateFactualState

    var body: some View {
        Text(
            "HR \(state.heartRateBPM) (last \(state.lastKnownHeartRateBPM))"
        )
        .font(.caption)
        .foregroundColor(.secondary)
    }
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
        let controllerUnitsDiagnostic = manager.controllerUnitsDiagnosticSnapshot()
        let heartRateDiagnostic = manager.treadmillTestRunHeartRateDiagnosticSnapshot
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
            controllerUnitsDiagnosticStatusText: controllerUnitsDiagnosticStatusText(
                controllerUnitsDiagnostic
            ),
            controllerUnitsDiagnosticMetrics: controllerUnitsDiagnosticMetrics(
                controllerUnitsDiagnostic
            ),
            controllerUnitsDiagnosticDetailLines: controllerUnitsDiagnosticDetailLines(
                controllerUnitsDiagnostic
            ),
            controllerUnitsDiagnosticReport: controllerUnitsDiagnostic.reportText,
            heartRateDiagnosticStatusText: testRunHeartRateDiagnosticStatusText(
                heartRateDiagnostic
            ),
            heartRateDiagnosticMetrics: testRunHeartRateDiagnosticMetrics(
                heartRateDiagnostic
            ),
            heartRateDiagnosticDetailLines: testRunHeartRateDiagnosticDetailLines(
                heartRateDiagnostic
            ),
            heartRateDiagnosticReport: testRunHeartRateDiagnosticReport(
                heartRateDiagnostic
            ),
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

    private func controllerUnitsDiagnosticStatusText(
        _ snapshot: ControllerUnitsDiagnosticSnapshot
    ) -> String {
        let context = snapshot.isCurrentConnection ? "current connection" : "no current evidence"
        let gate = snapshot.gateAllowed ? "gate allowed" : "gate blocked"
        return "\(context) · \(gate)"
    }

    private func controllerUnitsDiagnosticMetrics(
        _ snapshot: ControllerUnitsDiagnosticSnapshot
    ) -> [DebugTrainingLogsCard.Presentation.Metric] {
        let age = snapshot.ageSeconds.map { String(format: "%.1f s", $0) } ?? "—"
        return [
            .init(
                id: "units_status",
                title: "Status",
                value: snapshot.status.rawValue,
                tint: snapshot.status == .valid ? .green : .orange
            ),
            .init(
                id: "units_value",
                title: "Units",
                value: snapshot.units.rawValue,
                tint: snapshot.units == .metric ? .green : .orange
            ),
            .init(id: "units_age", title: "Age", value: age, tint: .secondary),
            .init(
                id: "units_fresh",
                title: "Fresh",
                value: snapshot.isFresh ? "yes" : "no",
                tint: snapshot.isFresh ? .green : .orange
            ),
            .init(
                id: "units_gate",
                title: "Test Run gate",
                value: snapshot.gateAllowed ? "allowed" : "blocked",
                tint: snapshot.gateAllowed ? .green : .red
            ),
            .init(
                id: "units_bytes",
                title: "A6 bytes",
                value: snapshot.byteCount.map(String.init) ?? "—",
                tint: .blue
            ),
        ]
    }

    private func controllerUnitsDiagnosticDetailLines(
        _ snapshot: ControllerUnitsDiagnosticSnapshot
    ) -> [String] {
        [
            "observed_at: \(testRunHeartRateDiagnosticDate(snapshot.observedAt))",
            "block_reason: \(snapshot.blockReason?.rawValue ?? "none")",
            "current_connection_context: \(snapshot.isCurrentConnection)",
            "evidence_connection_epoch: \(snapshot.evidenceConnectionEpoch?.uuidString ?? "unavailable")",
            "current_connection_epoch: \(snapshot.currentConnectionEpoch?.uuidString ?? "unavailable")",
            "raw_hex: \(snapshot.rawHex ?? "unavailable")",
        ]
    }

    private func testRunHeartRateDiagnosticStatusText(
        _ snapshot: TestRunHeartRateDiagnosticService.Snapshot
    ) -> String {
        guard snapshot.runID != nil else {
            return "Запускается параллельно Test Run и не управляет дорожкой."
        }
        if let detail = snapshot.detail, !detail.isEmpty {
            return "\(snapshot.phase.rawValue) · \(detail)"
        }
        if let reason = snapshot.terminalReason {
            return "\(snapshot.phase.rawValue) · \(reason.rawValue)"
        }
        return "\(snapshot.phase.rawValue) · provider \(snapshot.providerState)"
    }

    private func testRunHeartRateDiagnosticMetrics(
        _ snapshot: TestRunHeartRateDiagnosticService.Snapshot
    ) -> [DebugTrainingLogsCard.Presentation.Metric] {
        guard snapshot.runID != nil else { return [] }
        let bpm = snapshot.latestBPM.map(String.init) ?? "—"
        let freshness = snapshot.latestDisplayFresh ? "fresh" : "not fresh"
        let qualification = snapshot.latestStartQualified ? "qualified" : "not qualified"
        return [
            .init(
                id: "hr_probe_provider",
                title: "Provider",
                value: snapshot.providerState,
                tint: .accentColor
            ),
            .init(id: "hr_probe_bpm", title: "HR", value: "\(bpm) bpm", tint: .red),
            .init(
                id: "hr_probe_fresh",
                title: "Display",
                value: freshness,
                tint: snapshot.latestDisplayFresh ? .green : .orange
            ),
            .init(
                id: "hr_probe_qualified",
                title: "Start gate",
                value: qualification,
                tint: snapshot.latestStartQualified ? .green : .orange
            ),
            .init(
                id: "hr_probe_counts",
                title: "Samples Q / R",
                value: "\(snapshot.qualifyingSampleCount) / \(snapshot.rejectedSampleCount)",
                tint: .blue
            ),
            .init(
                id: "hr_probe_fresh_total",
                title: "Fresh / total",
                value: "\(snapshot.displayFreshSampleCount) / \(snapshot.receivedSampleCount)",
                tint: .secondary
            ),
        ]
    }

    private func testRunHeartRateDiagnosticDetailLines(
        _ snapshot: TestRunHeartRateDiagnosticService.Snapshot
    ) -> [String] {
        guard snapshot.runID != nil else { return [] }
        let age = snapshot.latestAgeSeconds.map { String(format: "%.1f s", $0) } ?? "—"
        let qualifyingLatency = snapshot.firstQualifyingSampleLatencySeconds.map {
            String(format: "%.3f s", $0)
        } ?? "—"
        return [
            "started_at: \(testRunHeartRateDiagnosticDate(snapshot.startedAt))",
            "collection_started_at: \(testRunHeartRateDiagnosticDate(snapshot.collectionStartedAt))",
            "first_sample_received_at: \(testRunHeartRateDiagnosticDate(snapshot.firstSampleReceivedAt))",
            "first_qualifying_latency_from_acquisition: \(qualifyingLatency)",
            "latest_measured_at: \(testRunHeartRateDiagnosticDate(snapshot.latestMeasuredAt))",
            "latest_callback_observed_at: \(testRunHeartRateDiagnosticDate(snapshot.latestSourceCallbackObservedAt))",
            "latest_received_at: \(testRunHeartRateDiagnosticDate(snapshot.latestReceivedAt))",
            "latest_source: \(snapshot.latestSource ?? "—")",
            "latest_provider_native_identity: \(snapshot.latestProviderNativeIdentity ?? "unavailable")",
            "latest_age: \(age)",
            "latest_rejection: \(snapshot.latestRejectionReason?.rawValue ?? "—")",
            "rejections_by_reason: \(testRunHeartRateDiagnosticRejectionSummary(snapshot))",
        ]
    }

    private func testRunHeartRateDiagnosticReport(
        _ snapshot: TestRunHeartRateDiagnosticService.Snapshot
    ) -> String {
        let lines = [
            "WalkingPad Test Run HR diagnostic",
            "run_id: \(snapshot.runID?.uuidString ?? "—")",
            "phase: \(snapshot.phase.rawValue)",
            "provider_state: \(snapshot.providerState)",
            "terminal_reason: \(snapshot.terminalReason?.rawValue ?? "—")",
            "detail: \(snapshot.detail ?? "—")",
            "latest_bpm: \(snapshot.latestBPM.map(String.init) ?? "—")",
            "latest_display_fresh: \(snapshot.latestDisplayFresh)",
            "latest_start_qualified: \(snapshot.latestStartQualified)",
            "samples_received: \(snapshot.receivedSampleCount)",
            "samples_display_fresh: \(snapshot.displayFreshSampleCount)",
            "samples_qualifying: \(snapshot.qualifyingSampleCount)",
            "samples_rejected: \(snapshot.rejectedSampleCount)",
            "latest_rejection: \(snapshot.latestRejectionReason?.rawValue ?? "—")",
        ] + testRunHeartRateDiagnosticDetailLines(snapshot)
        return lines.joined(separator: "\n")
    }

    private func testRunHeartRateDiagnosticRejectionSummary(
        _ snapshot: TestRunHeartRateDiagnosticService.Snapshot
    ) -> String {
        TestRunHeartRateDiagnosticService.RejectionReason.allCases.map { reason in
            "\(reason.rawValue)=\(snapshot.rejectionCountsByReason[reason, default: 0])"
        }.joined(separator: ",")
    }

    private func testRunHeartRateDiagnosticDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        return ISO8601DateFormatter().string(from: date)
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

    private var hrControlPreviewPresentation: TrainingHubPresentation {
        let isCooldown = hrControlPreviewMode == .cooldown
        return makeHRControlActivePresentation(
            treadmillConnected: true,
            hrFresh: !previewNoHrSignal,
            currentHeartRateBPM: previewNoHrSignal ? nil : (isCooldown ? 124 : 152),
            heartRateSourceLabel: nil,
            targetZoneIndex: 2,
            zoneRanges: [60...134, 135...146, 147...158, 159...170, 171...220],
            factualSpeedKmh: isCooldown ? 3.0 : 4.4,
            elapsedSeconds: 18 * 60 + 42,
            isCooldown: isCooldown,
            cooldownTargetBPM: 115,
            canExtend: !isCooldown,
            isPreview: true
        )
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

                                ActiveWorkoutShell(
                                    presentation: hrControlPreviewPresentation,
                                    onExtend: {},
                                    onStop: {}
                                )
                                .frame(height: 690)
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
                            Text("Speed \(actualStr)  Target \(targetStr)  AppSet \(deviceStr)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            DebugHeartRateFactualObservationRow(
                                state: manager.heartRateFactualState
                            )
                            DebugTreadmillFactualObservationRows(
                                publisher: manager.treadmillFactualObservationPublisher,
                                manager: manager
                            )

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
