import Foundation

struct WorkoutLiveActivityInput: Equatable {
    let sessionID: UUID?
    let isRunning: Bool
    let isRecovering: Bool
    let mainRemainingSeconds: Int
    let cooldownRemainingSeconds: Int
}

struct WorkoutLiveActivityState: Equatable {
    enum Phase: String, Codable {
        case main, cooldown, finishing
    }

    let sessionID: UUID
    let phase: Phase
    let deadline: Date?

    static func resolve(
        _ input: WorkoutLiveActivityInput,
        previous: Self?,
        now: Date
    ) -> Self? {
        guard input.isRunning, !input.isRecovering, let sessionID = input.sessionID else {
            return nil
        }
        let phase: Phase
        let remaining: Int
        if input.mainRemainingSeconds > 0 {
            phase = .main
            remaining = input.mainRemainingSeconds
        } else if input.cooldownRemainingSeconds > 0 {
            phase = .cooldown
            remaining = input.cooldownRemainingSeconds
        } else {
            phase = .finishing
            remaining = 0
        }
        let deadline = remaining > 0 ? now.addingTimeInterval(Double(remaining)) : nil
        if let previous, previous.sessionID == sessionID, previous.phase == phase {
            if let deadline, let previousDeadline = previous.deadline,
               abs(deadline.timeIntervalSince(previousDeadline)) <= 2 {
                // Ignore normal publication jitter; SwiftUI renders the countdown itself.
                return previous
            }
            if deadline == nil, previous.deadline == nil { return previous }
        }
        return Self(sessionID: sessionID, phase: phase, deadline: deadline)
    }
}
