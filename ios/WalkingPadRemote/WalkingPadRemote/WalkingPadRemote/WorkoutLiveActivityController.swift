import ActivityKit
import Combine
import OSLog
import TelemetryDomain

@MainActor
final class WorkoutLiveActivityController {
    private let logger = Logger(subsystem: "sw.WalkingPadRemote", category: "WorkoutLiveActivity")
    private var observation: AnyCancellable?
    private var desired: WorkoutLiveActivityState?
    private var foreground = false
    private var revision = 0
    private var task: Task<Void, Never>?
    private var suppressedSessionID: UUID?
    private var ownedActivity: Activity<WorkoutActivityAttributes>?

    func observe(_ manager: BluetoothManager, isForeground: Bool) {
        guard observation == nil else { return }
        foreground = isForeground
        observation = Publishers.CombineLatest4(
            manager.$isHrControlRunning, manager.$isNativeWorkoutRecoveryActive,
            manager.$hrRemainingSeconds, manager.$hrCooldownRemainingSeconds
        )
        // Published emits before assignment; read one coherent snapshot on the next main turn.
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak manager] _ in
            guard let self, let manager else { return }
            self.synchronize(Self.input(from: manager), isForeground: self.foreground)
        }
    }

    static func input(from manager: BluetoothManager) -> WorkoutLiveActivityInput {
        WorkoutLiveActivityInput(
            sessionID: manager.activeTelemetryV2SessionID?.rawValue,
            isRunning: manager.isHrControlRunning,
            isRecovering: manager.isNativeWorkoutRecoveryActive,
            mainRemainingSeconds: manager.hrRemainingSeconds,
            cooldownRemainingSeconds: manager.hrCooldownRemainingSeconds
        )
    }

    func synchronize(_ input: WorkoutLiveActivityInput, isForeground: Bool, now: Date = Date()) {
        let next = WorkoutLiveActivityState.resolve(input, previous: desired, now: now)
        guard next != desired || foreground != isForeground || revision == 0 else { return }
        if next?.sessionID != desired?.sessionID { suppressedSessionID = nil }
        desired = next
        foreground = isForeground
        revision += 1
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            var processedRevision = 0
            while processedRevision != self.revision {
                processedRevision = self.revision
                await self.reconcile()
            }
            self.task = nil
        }
    }

    private func reconcile() async {
        let state = desired
        var activities = Activity<WorkoutActivityAttributes>.activities
        if let ownedActivity, !activities.contains(where: { $0.id == ownedActivity.id }) {
            activities.append(ownedActivity)
        }
        for activity in activities where activity.attributes.sessionID != state?.sessionID {
            await activity.end(nil, dismissalPolicy: .immediate)
            if ownedActivity?.id == activity.id { ownedActivity = nil }
        }
        // Awaiting an old activity must not publish an obsolete session or phase.
        guard state == desired, let state else { return }
        guard suppressedSessionID != state.sessionID else { return }
        let phase: WorkoutActivityAttributes.ContentState.Phase
        switch state.phase {
        case .main: phase = .main
        case .cooldown: phase = .cooldown
        case .finishing: phase = .finishing
        }
        let contentState = WorkoutActivityAttributes.ContentState(phase: phase, deadline: state.deadline)
        let content = ActivityContent(state: contentState, staleDate: state.deadline)
        if let activity = activities.first(where: { $0.attributes.sessionID == state.sessionID }) {
            ownedActivity = activity
            guard activity.activityState == .active || activity.activityState == .stale else {
                suppressedSessionID = state.sessionID
                return
            }
            guard activity.content.state != contentState else { return }
            await activity.update(content)
        } else if foreground, ActivityAuthorizationInfo().areActivitiesEnabled {
            do {
                ownedActivity = try Activity.request(
                    attributes: WorkoutActivityAttributes(sessionID: state.sessionID),
                    content: content,
                    pushType: nil
                )
            } catch {
                // This optional presentation must never block or retry a workout operation.
                suppressedSessionID = state.sessionID
                logger.error("Live Activity request failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
