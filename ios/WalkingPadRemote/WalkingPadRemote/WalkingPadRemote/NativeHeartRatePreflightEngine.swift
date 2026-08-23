import Foundation

struct NativeHeartRateProviderLifecycle: Equatable {
    private(set) var generation: UInt64 = 0
    private(set) var attemptID: UUID?
    private(set) var cleanupGeneration: UInt64?

    var cleanupInFlight: Bool { cleanupGeneration != nil }

    mutating func bindAttempt(_ attemptID: UUID) {
        guard !cleanupInFlight else { return }
        self.attemptID = attemptID
    }

    mutating func beginProviderLifecycle() -> UInt64 {
        precondition(!cleanupInFlight)
        generation &+= 1
        return generation
    }

    func acceptsProviderCompletion(
        generation: UInt64,
        attemptID expectedAttemptID: UUID? = nil
    ) -> Bool {
        guard !cleanupInFlight, generation == self.generation else { return false }
        guard let expectedAttemptID else { return true }
        return attemptID == expectedAttemptID
    }

    func acceptsObservation(providerIsCollecting: Bool) -> Bool {
        !cleanupInFlight && attemptID != nil && providerIsCollecting
    }

    mutating func beginCleanup() -> UInt64 {
        generation &+= 1
        attemptID = nil
        cleanupGeneration = generation
        return generation
    }

    mutating func completeCleanup(
        generation: UInt64,
        providerIsIdle: Bool
    ) -> Bool {
        guard cleanupGeneration == generation, providerIsIdle else { return false }
        cleanupGeneration = nil
        return true
    }

    mutating func releaseCommittedProvider() {
        generation &+= 1
        attemptID = nil
        cleanupGeneration = nil
    }
}

struct NativeHeartRatePreflightEngine {
    static let timeoutSeconds: TimeInterval = 30

    enum RuntimePolicy {
        static func stopInProgress(
            hasObservationLifecycle: Bool,
            observationHasFinalResult: Bool,
            hasUnavailableAttempt: Bool
        ) -> Bool {
            (hasObservationLifecycle && !observationHasFinalResult)
                || hasUnavailableAttempt
        }

        static func hasConflictingWorkout(
            isHrControlRunning: Bool,
            treadmillTestRunIsActive: Bool,
            nativeWorkoutCommitted: Bool,
            nativeFlowOwnsController: Bool,
            nativeWorkoutFinishInFlight: Bool
        ) -> Bool {
            isHrControlRunning
                || treadmillTestRunIsActive
                || nativeWorkoutFinishInFlight
                || (nativeWorkoutCommitted && !nativeFlowOwnsController)
        }

        static func canWarmPrepare(
            isTrainingHubVisible: Bool,
            appActivity: AppActivity,
            isHrControlRunning: Bool,
            nativeWorkoutCommitted: Bool,
            nativeWorkoutFinishInFlight: Bool,
            providerIsIdle: Bool,
            providerIsSupported: Bool
        ) -> Bool {
            isTrainingHubVisible
                && appActivity == .active
                && !isHrControlRunning
                && !nativeWorkoutCommitted
                && !nativeWorkoutFinishInFlight
                && providerIsIdle
                && providerIsSupported
        }

        static func permitsProductionCommit(
            intent: Intent,
            now: Date,
            flowOwnsController: Bool,
            nativeWorkoutAlreadyCommitted: Bool,
            providerIsCollecting: Bool,
            observationIsQualifying: Bool,
            safety: SafetyFacts
        ) -> Bool {
            flowOwnsController
                && !nativeWorkoutAlreadyCommitted
                && providerIsCollecting
                && observationIsQualifying
                && now < intent.requestedAt.addingTimeInterval(timeoutSeconds)
                && safety.permitsCommit
        }
    }

    struct Intent: Equatable {
        let id: UUID
        let targetBPM: Int
        let durationMinutes: Int
        let requestedAt: Date
    }

    enum ObservationSource: Equatable {
        case nativeHealthKit
        case legacyWatch
    }

    struct Observation: Equatable {
        let source: ObservationSource
        let beatsPerMinute: Int
        let measuredAt: Date?
        let receivedAt: Date

        func isQualifying(
            collectionStartedAt: Date,
            now: Date,
            freshnessLimit: TimeInterval
        ) -> Bool {
            guard source == .nativeHealthKit,
                  beatsPerMinute > 0,
                  receivedAt >= collectionStartedAt else {
                return false
            }
            let factualDate = measuredAt ?? receivedAt
            return factualDate >= collectionStartedAt
                && now.timeIntervalSince(factualDate) <= freshnessLimit
        }
    }

    enum AppActivity: Equatable {
        case active
        case inactive
        case background
    }

    enum TelemetryAvailability: Equatable {
        case healthy
        case degraded
        case unavailable
    }

    struct SafetyFacts: Equatable {
        let appActivity: AppActivity
        let treadmillControlReady: Bool
        let transportValid: Bool
        let controllerUnitsAllowed: Bool
        let hasConflictingWorkout: Bool
        let stopInProgress: Bool
        let telemetryAvailability: TelemetryAvailability

        var permitsStartIntent: Bool {
            appActivity == .active
                && treadmillControlReady
                && transportValid
                && !hasConflictingWorkout
                && !stopInProgress
        }

        var permitsCommit: Bool {
            permitsStartIntent && controllerUnitsAllowed
        }
    }

    enum CancellationReason: String, Equatable {
        case user
        case timeout
        case treadmillControlLost
        case appBackgrounded
        case providerFailure
        case hubLeft
        case superseded
    }

    enum Effect: Equatable {
        case prepare
        case startCollection(intent: Intent, acquisitionStartedAt: Date)
        case commit(
            intent: Intent,
            observation: Observation,
            acquisitionStartedAt: Date
        )
        case discard(reason: CancellationReason)
    }

    private enum Phase: Equatable {
        case idle
        case warming
        case prepared
        case preparing(Intent)
        case starting(Intent, acquisitionStartedAt: Date)
        case waiting(
            Intent,
            acquisitionStartedAt: Date,
            observation: Observation?
        )
    }

    private var phase: Phase = .idle

    var isWarmPrepared: Bool { phase == .prepared }

    var hasStartIntent: Bool {
        switch phase {
        case .preparing, .starting, .waiting:
            true
        case .idle, .warming, .prepared:
            false
        }
    }

    var ownsUncommittedWorkout: Bool { phase != .idle }

    var pendingObservation: Observation? {
        guard case .waiting(_, _, let observation) = phase else { return nil }
        return observation
    }

    mutating func requestWarmPreparation() -> [Effect] {
        guard phase == .idle else { return [] }
        phase = .warming
        return [.prepare]
    }

    mutating func requestStart(intent: Intent, safety: SafetyFacts) -> [Effect] {
        guard safety.permitsStartIntent else { return [] }
        switch phase {
        case .idle:
            phase = .preparing(intent)
            return [.prepare]
        case .warming:
            phase = .preparing(intent)
            return []
        case .prepared:
            let acquisitionStartedAt = intent.requestedAt
            phase = .starting(intent, acquisitionStartedAt: acquisitionStartedAt)
            return [.startCollection(
                intent: intent,
                acquisitionStartedAt: acquisitionStartedAt
            )]
        case .preparing, .starting, .waiting:
            return []
        }
    }

    mutating func providerPrepared(at date: Date) -> [Effect] {
        switch phase {
        case .warming:
            phase = .prepared
            return []
        case .preparing(let intent):
            guard !deadlineReached(for: intent, now: date) else {
                return cancel(reason: .timeout)
            }
            phase = .starting(intent, acquisitionStartedAt: date)
            return [.startCollection(intent: intent, acquisitionStartedAt: date)]
        case .idle, .prepared, .starting, .waiting:
            return []
        }
    }

    mutating func collectionStarted(
        intentID: UUID,
        acquisitionStartedAt: Date,
        now: Date
    ) -> [Effect] {
        guard case .starting(let intent, let expectedStart) = phase,
              intent.id == intentID,
              expectedStart == acquisitionStartedAt else {
            return []
        }
        guard !deadlineReached(for: intent, now: now) else {
            return cancel(reason: .timeout)
        }
        phase = .waiting(
            intent,
            acquisitionStartedAt: acquisitionStartedAt,
            observation: nil
        )
        return []
    }

    mutating func receive(
        _ observation: Observation,
        safety: SafetyFacts,
        now: Date,
        freshnessLimit: TimeInterval
    ) -> [Effect] {
        guard let intent = currentIntent else { return [] }
        guard !deadlineReached(for: intent, now: now) else {
            return cancel(reason: .timeout)
        }
        guard case .waiting(let intent, let acquisitionStartedAt, _) = phase,
              observation.isQualifying(
                collectionStartedAt: acquisitionStartedAt,
                now: now,
                freshnessLimit: freshnessLimit
              ) else {
            return []
        }
        phase = .waiting(
            intent,
            acquisitionStartedAt: acquisitionStartedAt,
            observation: observation
        )
        return commitIfAllowed(safety: safety, now: now, freshnessLimit: freshnessLimit)
    }

    mutating func safetyChanged(
        _ safety: SafetyFacts,
        now: Date,
        freshnessLimit: TimeInterval
    ) -> [Effect] {
        guard ownsUncommittedWorkout else { return [] }
        if let intent = currentIntent, deadlineReached(for: intent, now: now) {
            return cancel(reason: .timeout)
        }
        if safety.appActivity == .background {
            return cancel(reason: .appBackgrounded)
        }
        if !safety.treadmillControlReady || !safety.transportValid {
            return cancel(reason: .treadmillControlLost)
        }
        if safety.hasConflictingWorkout || safety.stopInProgress {
            return cancel(reason: .superseded)
        }
        return commitIfAllowed(safety: safety, now: now, freshnessLimit: freshnessLimit)
    }

    mutating func tick(now: Date) -> [Effect] {
        guard let intent = currentIntent,
              deadlineReached(for: intent, now: now) else {
            return []
        }
        return cancel(reason: .timeout)
    }

    mutating func cancel(reason: CancellationReason) -> [Effect] {
        guard phase != .idle else { return [] }
        phase = .idle
        return [.discard(reason: reason)]
    }

    private var currentIntent: Intent? {
        switch phase {
        case .preparing(let intent),
             .starting(let intent, _),
             .waiting(let intent, _, _):
            intent
        case .idle, .warming, .prepared:
            nil
        }
    }

    private mutating func commitIfAllowed(
        safety: SafetyFacts,
        now: Date,
        freshnessLimit: TimeInterval
    ) -> [Effect] {
        guard case .waiting(
                let intent,
                let acquisitionStartedAt,
                let observation?
              ) = phase else {
            return []
        }
        guard !deadlineReached(for: intent, now: now) else {
            return cancel(reason: .timeout)
        }
        guard safety.permitsCommit,
              observation.isQualifying(
                collectionStartedAt: acquisitionStartedAt,
                now: now,
                freshnessLimit: freshnessLimit
              ) else {
            return []
        }
        phase = .idle
        return [.commit(
            intent: intent,
            observation: observation,
            acquisitionStartedAt: acquisitionStartedAt
        )]
    }

    private func deadlineReached(for intent: Intent, now: Date) -> Bool {
        now >= intent.requestedAt.addingTimeInterval(Self.timeoutSeconds)
    }
}
