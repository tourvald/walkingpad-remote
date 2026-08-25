import Foundation

enum WorkoutLifecycleAppState: String, Codable, Equatable {
    case active
    case inactive
    case background
}

enum WorkoutLifecycleStage: String, Codable, Equatable {
    case idle
    case preflight
    case main
    case cooldown
    case stopping
    case recovery
}

enum WorkoutBackgroundPolicyAction: String, Codable, Equatable {
    case foreground
    case awaitingSystemTransition
    case continueEventDriven
    case blockUncommitted
    case recoveryOnly
    case terminalOnly
    case noActiveWorkout
}

struct WorkoutLifecyclePolicyInput: Equatable {
    let appState: WorkoutLifecycleAppState
    let stage: WorkoutLifecycleStage
    let hasCommittedWorkout: Bool
}

struct WorkoutLifecyclePolicyDecision: Equatable {
    let action: WorkoutBackgroundPolicyAction
    let permitsControlLoop: Bool
    let reason: String
}

enum WorkoutLifecyclePolicy {
    static func evaluate(
        _ input: WorkoutLifecyclePolicyInput
    ) -> WorkoutLifecyclePolicyDecision {
        switch input.stage {
        case .stopping:
            return WorkoutLifecyclePolicyDecision(
                action: .terminalOnly,
                permitsControlLoop: false,
                reason: "terminal_transition_only"
            )
        case .recovery:
            return WorkoutLifecyclePolicyDecision(
                action: .recoveryOnly,
                permitsControlLoop: false,
                reason: "recovery_never_authorizes_motion"
            )
        case .preflight where input.appState != .active:
            return WorkoutLifecyclePolicyDecision(
                action: .blockUncommitted,
                permitsControlLoop: false,
                reason: "uncommitted_workout_requires_foreground"
            )
        case .idle:
            return WorkoutLifecyclePolicyDecision(
                action: .noActiveWorkout,
                permitsControlLoop: false,
                reason: "no_committed_workout"
            )
        default:
            break
        }

        guard input.hasCommittedWorkout,
              input.stage == .main || input.stage == .cooldown else {
            return WorkoutLifecyclePolicyDecision(
                action: input.appState == .active ? .foreground : .blockUncommitted,
                permitsControlLoop: false,
                reason: "control_requires_committed_workout"
            )
        }

        switch input.appState {
        case .active:
            return WorkoutLifecyclePolicyDecision(
                action: .foreground,
                permitsControlLoop: true,
                reason: "committed_workout_foreground"
            )
        case .inactive:
            return WorkoutLifecyclePolicyDecision(
                action: .awaitingSystemTransition,
                permitsControlLoop: true,
                reason: "committed_workout_transitioning"
            )
        case .background:
            return WorkoutLifecyclePolicyDecision(
                action: .continueEventDriven,
                permitsControlLoop: true,
                reason: "committed_workout_background_event_driven"
            )
        }
    }
}
