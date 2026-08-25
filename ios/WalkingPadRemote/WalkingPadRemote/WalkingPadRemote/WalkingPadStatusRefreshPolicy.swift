import Foundation

enum WalkingPadReadOnlyRefreshKind: Equatable {
    case status
    case controllerUnits
}

struct WalkingPadReadOnlyRefreshDecision: Equatable {
    let kind: WalkingPadReadOnlyRefreshKind?

    var shouldRequest: Bool { kind != nil }
}

/// Coordinates read-only WalkingPad polling without occupying a motion command window.
enum WalkingPadStatusRefreshPolicy {
    static let preferredStatusQueryInterval: TimeInterval = 3
    static let maximumStatusQueryInterval: TimeInterval = 5

    static func activeWorkoutRefresh(
        isWorkoutOrCooldownActive: Bool,
        transportReady: Bool,
        motionQueueIdle: Bool,
        secondsUntilNextScheduledMotion: Int,
        lastStatusQueryAt: Date?,
        lastControllerUnitsQueryAt: Date?,
        now: Date
    ) -> WalkingPadReadOnlyRefreshDecision {
        guard isWorkoutOrCooldownActive,
              transportReady,
              motionQueueIdle,
              secondsUntilNextScheduledMotion
                > ControllerUnitsRefreshPolicy.requiredMotionLeadSeconds else {
            return WalkingPadReadOnlyRefreshDecision(kind: nil)
        }

        let statusAge = lastStatusQueryAt.map { now.timeIntervalSince($0) }
        let unitsAge = lastControllerUnitsQueryAt.map { now.timeIntervalSince($0) }
        let statusIsDue = statusAge.map { $0 >= preferredStatusQueryInterval } ?? true
        let statusMustRunNow = statusAge.map { $0 >= maximumStatusQueryInterval } ?? true
        let unitsAreDue = unitsAge.map {
            $0 >= ControllerUnitsRefreshPolicy.activeWorkoutQueryInterval
        } ?? true
        let lastSafePreMotionTick = secondsUntilNextScheduledMotion
            == ControllerUnitsRefreshPolicy.requiredMotionLeadSeconds + 1

        // Pull a due status query into the final safe pre-motion tick. This prevents
        // the two-second WalkingPad write spacing from opening a >5 s evidence gap.
        if lastSafePreMotionTick,
           statusAge.map({ $0 >= preferredStatusQueryInterval - 1 }) ?? true {
            return WalkingPadReadOnlyRefreshDecision(kind: .status)
        }
        if statusMustRunNow {
            return WalkingPadReadOnlyRefreshDecision(kind: .status)
        }
        if unitsAreDue {
            return WalkingPadReadOnlyRefreshDecision(kind: .controllerUnits)
        }
        if statusIsDue {
            // At lead=4, waiting one tick aligns the query with the final safe slot.
            if secondsUntilNextScheduledMotion
                == ControllerUnitsRefreshPolicy.requiredMotionLeadSeconds + 2 {
                return WalkingPadReadOnlyRefreshDecision(kind: nil)
            }
            return WalkingPadReadOnlyRefreshDecision(kind: .status)
        }
        return WalkingPadReadOnlyRefreshDecision(kind: nil)
    }
}
