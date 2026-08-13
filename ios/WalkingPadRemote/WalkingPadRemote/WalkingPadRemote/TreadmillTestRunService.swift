import Foundation

struct TreadmillTestRunService {
    enum Action: Equatable {
        case start(speedKmh: Double)
        case setSpeed(speedKmh: Double)
        case stop
    }

    enum Stage: Int, CaseIterable, Equatable {
        case startAtOne
        case increaseToTwo
        case increaseToThree
        case decreaseToTwo
        case firstStop
        case restartAtOnePointFive
        case finalStop

        var action: Action {
            switch self {
            case .startAtOne:
                return .start(speedKmh: 1.0)
            case .increaseToTwo:
                return .setSpeed(speedKmh: 2.0)
            case .increaseToThree:
                return .setSpeed(speedKmh: 3.0)
            case .decreaseToTwo:
                return .setSpeed(speedKmh: 2.0)
            case .firstStop, .finalStop:
                return .stop
            case .restartAtOnePointFive:
                return .start(speedKmh: 1.5)
            }
        }

        var holdDuration: TimeInterval? {
            switch self {
            case .startAtOne, .increaseToTwo, .increaseToThree, .decreaseToTwo, .firstStop:
                return 15
            case .restartAtOnePointFive:
                return 10
            case .finalStop:
                return nil
            }
        }

        var statusText: String {
            switch self {
            case .startAtOne:
                return "START → 1.0 km/h"
            case .increaseToTwo:
                return "SPEED → 2.0 km/h"
            case .increaseToThree:
                return "SPEED → 3.0 km/h"
            case .decreaseToTwo:
                return "SPEED → 2.0 km/h"
            case .firstStop:
                return "STOP отправлен"
            case .restartAtOnePointFive:
                return "START → 1.5 km/h"
            case .finalStop:
                return "TEST COMPLETE · STOP отправлен"
            }
        }
    }

    enum CancellationReason: String, Equatable {
        case userRequested = "user_requested"
        case appInactive = "app_inactive"
        case connectionInvalidated = "connection_invalidated"
    }

    enum State: Equatable {
        case idle
        case running(runID: UUID, stage: Stage)
        case cancelled(reason: CancellationReason, stopRequested: Bool)
        case completed
    }

    struct Transition: Equatable {
        let actions: [Action]
        let state: State
    }

    private(set) var state: State = .idle
    private var nextStageDeadline: TimeInterval?

    var isActive: Bool {
        if case .running = state {
            return true
        }
        return false
    }

    var activeRunID: UUID? {
        guard case .running(let runID, _) = state else { return nil }
        return runID
    }

    var statusText: String {
        switch state {
        case .idle:
            return "READY"
        case .running(_, let stage):
            return stage.statusText
        case .cancelled(let reason, let stopRequested):
            let stopText = stopRequested ? " · STOP отправлен" : ""
            return "TEST CANCELLED · \(reason.rawValue)\(stopText)"
        case .completed:
            return Stage.finalStop.statusText
        }
    }

    mutating func start(at now: TimeInterval, runID: UUID = UUID()) -> Transition? {
        guard !isActive else { return nil }
        let firstStage = Stage.startAtOne
        state = .running(runID: runID, stage: firstStage)
        nextStageDeadline = now + (firstStage.holdDuration ?? 0)
        return Transition(actions: [firstStage.action], state: state)
    }

    mutating func advance(at now: TimeInterval, expectedRunID: UUID) -> Transition? {
        guard case .running(let runID, let currentStage) = state,
              runID == expectedRunID,
              let deadline = nextStageDeadline,
              now >= deadline,
              let nextStage = Stage(rawValue: currentStage.rawValue + 1) else {
            return nil
        }

        if nextStage == .finalStop {
            state = .completed
            nextStageDeadline = nil
        } else {
            state = .running(runID: runID, stage: nextStage)
            nextStageDeadline = now + (nextStage.holdDuration ?? 0)
        }
        return Transition(actions: [nextStage.action], state: state)
    }

    mutating func cancel(
        reason: CancellationReason,
        requestProductionStop: Bool
    ) -> Transition? {
        guard isActive else { return nil }
        state = .cancelled(reason: reason, stopRequested: requestProductionStop)
        nextStageDeadline = nil
        return Transition(
            actions: requestProductionStop ? [.stop] : [],
            state: state
        )
    }
}
