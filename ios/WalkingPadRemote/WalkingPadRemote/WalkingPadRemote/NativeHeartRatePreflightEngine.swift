import Foundation

struct IPhoneHealthKitRuntimeFailureContext: Equatable {
    let providerGeneration: UInt64
    let attemptID: UUID?
}

struct DeferredNativeHealthKitLinkage: Codable, Equatable {
    let acquisitionStartedAt: Date
    let finishRequestedAt: Date
    let healthKitStoppedAt: Date?
    let profileID: UUID?
    let telemetrySessionID: UUID?
    let linksLegacyWorkout: Bool
    let legacyWorkoutID: UUID?
    let recoveryAppWorkoutID: UUID?
    let healthKitWorkoutID: UUID?

    func provingSavedWorkout(id: UUID) -> Self {
        Self(
            acquisitionStartedAt: acquisitionStartedAt,
            finishRequestedAt: finishRequestedAt,
            healthKitStoppedAt: healthKitStoppedAt,
            profileID: profileID,
            telemetrySessionID: telemetrySessionID,
            linksLegacyWorkout: linksLegacyWorkout,
            legacyWorkoutID: legacyWorkoutID,
            recoveryAppWorkoutID: recoveryAppWorkoutID,
            healthKitWorkoutID: id
        )
    }
}

enum DeferredNativeHealthKitLinkageQueue {
    static func retaining(
        _ linkage: DeferredNativeHealthKitLinkage,
        in pending: [DeferredNativeHealthKitLinkage]
    ) -> [DeferredNativeHealthKitLinkage]? {
        var updated = pending
        guard let recoveryAppWorkoutID = linkage.recoveryAppWorkoutID,
              let index = updated.firstIndex(where: {
                  $0.recoveryAppWorkoutID == recoveryAppWorkoutID
              }) else {
            if !updated.contains(linkage) {
                updated.append(linkage)
            }
            return updated
        }
        let existing = updated[index]
        if let existingWorkoutID = existing.healthKitWorkoutID {
            guard linkage.healthKitWorkoutID == nil
                    || linkage.healthKitWorkoutID == existingWorkoutID else {
                return nil
            }
            return updated
        }
        updated[index] = linkage
        return updated
    }

    static func provingSavedWorkout(
        id: UUID,
        replacing source: DeferredNativeHealthKitLinkage,
        in pending: [DeferredNativeHealthKitLinkage]
    ) -> [DeferredNativeHealthKitLinkage]? {
        guard let index = pending.firstIndex(of: source) else { return nil }
        if let existingWorkoutID = source.healthKitWorkoutID {
            return existingWorkoutID == id ? pending : nil
        }
        var updated = pending
        updated[index] = source.provingSavedWorkout(id: id)
        return updated
    }

    static func next(
        in pending: [DeferredNativeHealthKitLinkage],
        preferredRecoveryAppWorkoutID: UUID? = nil
    ) -> DeferredNativeHealthKitLinkage? {
        if let preferredRecoveryAppWorkoutID,
           let preferred = pending.last(where: {
               $0.recoveryAppWorkoutID == preferredRecoveryAppWorkoutID
           }) {
            return preferred
        }
        return pending.last(where: {
            $0.healthKitWorkoutID != nil
                && (!$0.linksLegacyWorkout || $0.legacyWorkoutID != nil)
        })
            ?? pending.last(where: { $0.healthKitWorkoutID != nil })
            ?? pending.last
    }
}

struct NativeWorkoutRecoveryRecord: Codable, Equatable {
    enum Phase: String, Codable, Equatable {
        case preflight
        case committed
        case stopping
        case finishing
    }

    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let appWorkoutID: UUID
    let phase: Phase
    let targetBPM: Int
    let durationMinutes: Int
    let plannedDurationSeconds: Int?
    let acquisitionStartedAt: Date
    let controlledWorkoutStartedAt: Date?
    let terminalRequestedAt: Date?
    let healthKitStopActivityAt: Date?
    let profileID: UUID?
    let legacySessionID: UUID?
    let telemetrySessionID: UUID?
    let legacyWorkoutID: UUID?

    static func preflight(
        appWorkoutID: UUID,
        targetBPM: Int,
        durationMinutes: Int,
        acquisitionStartedAt: Date,
        profileID: UUID?
    ) -> Self {
        Self(
            schemaVersion: currentSchemaVersion,
            appWorkoutID: appWorkoutID,
            phase: .preflight,
            targetBPM: targetBPM,
            durationMinutes: durationMinutes,
            plannedDurationSeconds: durationMinutes * 60,
            acquisitionStartedAt: acquisitionStartedAt,
            controlledWorkoutStartedAt: nil,
            terminalRequestedAt: nil,
            healthKitStopActivityAt: nil,
            profileID: profileID,
            legacySessionID: nil,
            telemetrySessionID: nil,
            legacyWorkoutID: nil
        )
    }

    func committed(
        controlledWorkoutStartedAt: Date,
        profileID: UUID,
        legacySessionID: UUID,
        telemetrySessionID: UUID
    ) -> Self {
        Self(
            schemaVersion: schemaVersion,
            appWorkoutID: appWorkoutID,
            phase: .committed,
            targetBPM: targetBPM,
            durationMinutes: durationMinutes,
            plannedDurationSeconds: plannedDurationSeconds,
            acquisitionStartedAt: acquisitionStartedAt,
            controlledWorkoutStartedAt: controlledWorkoutStartedAt,
            terminalRequestedAt: nil,
            healthKitStopActivityAt: nil,
            profileID: profileID,
            legacySessionID: legacySessionID,
            telemetrySessionID: telemetrySessionID,
            legacyWorkoutID: nil
        )
    }

    func finishing(requestedAt: Date) -> Self {
        Self(
            schemaVersion: schemaVersion,
            appWorkoutID: appWorkoutID,
            phase: .finishing,
            targetBPM: targetBPM,
            durationMinutes: durationMinutes,
            plannedDurationSeconds: plannedDurationSeconds,
            acquisitionStartedAt: acquisitionStartedAt,
            controlledWorkoutStartedAt: controlledWorkoutStartedAt,
            terminalRequestedAt: requestedAt,
            healthKitStopActivityAt: healthKitStopActivityAt,
            profileID: profileID,
            legacySessionID: legacySessionID,
            telemetrySessionID: telemetrySessionID,
            legacyWorkoutID: legacyWorkoutID
        )
    }

    func stopping(requestedAt: Date) -> Self {
        Self(
            schemaVersion: schemaVersion,
            appWorkoutID: appWorkoutID,
            phase: .stopping,
            targetBPM: targetBPM,
            durationMinutes: durationMinutes,
            plannedDurationSeconds: plannedDurationSeconds,
            acquisitionStartedAt: acquisitionStartedAt,
            controlledWorkoutStartedAt: controlledWorkoutStartedAt,
            terminalRequestedAt: requestedAt,
            healthKitStopActivityAt: nil,
            profileID: profileID,
            legacySessionID: legacySessionID,
            telemetrySessionID: telemetrySessionID,
            legacyWorkoutID: legacyWorkoutID
        )
    }

    func planningDuration(seconds: Int) -> Self {
        Self(
            schemaVersion: schemaVersion,
            appWorkoutID: appWorkoutID,
            phase: phase,
            targetBPM: targetBPM,
            durationMinutes: max(1, (seconds + 59) / 60),
            plannedDurationSeconds: seconds,
            acquisitionStartedAt: acquisitionStartedAt,
            controlledWorkoutStartedAt: controlledWorkoutStartedAt,
            terminalRequestedAt: terminalRequestedAt,
            healthKitStopActivityAt: healthKitStopActivityAt,
            profileID: profileID,
            legacySessionID: legacySessionID,
            telemetrySessionID: telemetrySessionID,
            legacyWorkoutID: legacyWorkoutID
        )
    }

    func linkingLegacyWorkout(id: UUID) -> Self {
        Self(
            schemaVersion: schemaVersion,
            appWorkoutID: appWorkoutID,
            phase: phase,
            targetBPM: targetBPM,
            durationMinutes: durationMinutes,
            plannedDurationSeconds: plannedDurationSeconds,
            acquisitionStartedAt: acquisitionStartedAt,
            controlledWorkoutStartedAt: controlledWorkoutStartedAt,
            terminalRequestedAt: terminalRequestedAt,
            healthKitStopActivityAt: healthKitStopActivityAt,
            profileID: profileID,
            legacySessionID: legacySessionID,
            telemetrySessionID: telemetrySessionID,
            legacyWorkoutID: id
        )
    }

    func recordingHealthKitStopActivity(at date: Date) -> Self {
        Self(
            schemaVersion: schemaVersion,
            appWorkoutID: appWorkoutID,
            phase: phase,
            targetBPM: targetBPM,
            durationMinutes: durationMinutes,
            plannedDurationSeconds: plannedDurationSeconds,
            acquisitionStartedAt: acquisitionStartedAt,
            controlledWorkoutStartedAt: controlledWorkoutStartedAt,
            terminalRequestedAt: terminalRequestedAt,
            healthKitStopActivityAt: date,
            profileID: profileID,
            legacySessionID: legacySessionID,
            telemetrySessionID: telemetrySessionID,
            legacyWorkoutID: legacyWorkoutID
        )
    }

    var effectivePlannedDurationSeconds: Int {
        plannedDurationSeconds ?? durationMinutes * 60
    }

    var isStructurallyValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              (40...240).contains(targetBPM),
              (1...120).contains(durationMinutes),
              (60...(120 * 60)).contains(effectivePlannedDurationSeconds) else {
            return false
        }
        switch phase {
        case .preflight:
            return controlledWorkoutStartedAt == nil
                && terminalRequestedAt == nil
                && healthKitStopActivityAt == nil
                && legacySessionID == nil
                && telemetrySessionID == nil
                && legacyWorkoutID == nil
        case .committed, .stopping, .finishing:
            guard let controlledWorkoutStartedAt,
                  let legacySessionID,
                  let telemetrySessionID,
                  profileID != nil else {
                return false
            }
            let preflightLatency = controlledWorkoutStartedAt.timeIntervalSince(
                acquisitionStartedAt
            )
            let terminalIsValid: Bool
            switch phase {
            case .preflight:
                terminalIsValid = false
            case .committed:
                terminalIsValid = terminalRequestedAt == nil
                    && healthKitStopActivityAt == nil
            case .stopping:
                terminalIsValid = (terminalRequestedAt.map {
                    $0 >= controlledWorkoutStartedAt
                } ?? false) && healthKitStopActivityAt == nil
            case .finishing:
                guard let terminalRequestedAt else {
                    terminalIsValid = false
                    break
                }
                terminalIsValid = terminalRequestedAt >= controlledWorkoutStartedAt
                    && (healthKitStopActivityAt.map {
                        $0 >= terminalRequestedAt
                    } ?? true)
            }
            return preflightLatency >= 0
                && preflightLatency <= NativeHeartRatePreflightEngine.timeoutSeconds
                && terminalIsValid
                && telemetrySessionID == legacySessionID
        }
    }
}

enum NativeWorkoutRecoveryLoadResult: Equatable {
    case missing
    case invalid
    case record(NativeWorkoutRecoveryRecord)
}

struct NativeWorkoutRecoveryStore {
    let fileURL: URL

    static func applicationSupport(
        bundleIdentifier: String,
        fileManager: FileManager = .default
    ) throws -> Self {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return Self(fileURL: root
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("native_workout_recovery_v1.json"))
    }

    func load(fileManager: FileManager = .default) -> NativeWorkoutRecoveryLoadResult {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .missing }
        guard let data = try? Data(contentsOf: fileURL),
              let record = try? JSONDecoder().decode(
                NativeWorkoutRecoveryRecord.self,
                from: data
              ),
              record.isStructurallyValid else {
            return .invalid
        }
        return .record(record)
    }

    func save(
        _ record: NativeWorkoutRecoveryRecord,
        fileManager: FileManager = .default
    ) throws {
        guard record.isStructurallyValid else {
            throw NativeWorkoutRecoveryStoreError.invalidRecord
        }
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(record)
        try data.write(to: fileURL, options: .atomic)
    }

    func clear(fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }
}

enum NativeWorkoutRecoveryStoreError: Error, Equatable {
    case invalidRecord
}

enum NativeWorkoutRecoveryResolution: Equatable {
    case discard
    case restore(NativeWorkoutRecoveryRecord)
    case finish(NativeWorkoutRecoveryRecord)
}

enum NativeWorkoutNoActiveRecoveryResolution: Equatable {
    case retainFailClosed
    case discardPreflight(NativeWorkoutRecoveryRecord)
    case reconcileFinished(NativeWorkoutRecoveryRecord)
}

enum NativeWorkoutRecoveryPolicy {
    static let sessionStartTolerance: TimeInterval = 5

    static func resolve(
        loadResult: NativeWorkoutRecoveryLoadResult,
        recoveredSessionStartedAt: Date?,
        recoveredCollectionStarted: Bool,
        configurationIsIndoorWalking: Bool
    ) -> NativeWorkoutRecoveryResolution {
        guard case .record(let record) = loadResult,
              record.phase == .committed
                || record.phase == .stopping
                || record.phase == .finishing,
              record.isStructurallyValid,
              recoveredCollectionStarted,
              configurationIsIndoorWalking,
              let recoveredSessionStartedAt,
              abs(recoveredSessionStartedAt.timeIntervalSince(
                record.acquisitionStartedAt
              )) <= sessionStartTolerance else {
            return .discard
        }
        return record.phase == .finishing ? .finish(record) : .restore(record)
    }

    static func resolveWithoutActiveRecoveryRequest(
        loadResult: NativeWorkoutRecoveryLoadResult
    ) -> NativeWorkoutNoActiveRecoveryResolution {
        guard case .record(let record) = loadResult,
              record.isStructurallyValid else {
            return .retainFailClosed
        }
        if record.phase == .preflight {
            return .discardPreflight(record)
        }
        guard record.phase == .finishing,
              record.healthKitStopActivityAt != nil else {
            return .retainFailClosed
        }
        return .reconcileFinished(record)
    }
}

enum NativeWorkoutSavedProofPolicy {
    static func matches(
        record: NativeWorkoutRecoveryRecord,
        workoutStartedAt: Date,
        workoutEndedAt: Date,
        isWalking: Bool,
        sourceMatchesApp: Bool
    ) -> Bool {
        guard record.phase == .finishing,
              record.isStructurallyValid,
              let stoppedAt = record.healthKitStopActivityAt,
              isWalking,
              sourceMatchesApp else {
            return false
        }
        return abs(workoutStartedAt.timeIntervalSince(record.acquisitionStartedAt)) <= 5
            && abs(workoutEndedAt.timeIntervalSince(stoppedAt)) <= 15
    }

    static func uniqueMatch<Candidate>(
        in candidates: [Candidate],
        matching matches: (Candidate) -> Bool
    ) -> Candidate? {
        var uniqueMatch: Candidate?
        for candidate in candidates where matches(candidate) {
            guard uniqueMatch == nil else { return nil }
            uniqueMatch = candidate
        }
        return uniqueMatch
    }
}

enum NativeWorkoutLegacyLinkPolicy {
    static func canLink(
        existingWorkoutUUID: String?,
        expectedWorkoutUUID: UUID
    ) -> Bool {
        existingWorkoutUUID == nil
            || existingWorkoutUUID == expectedWorkoutUUID.uuidString
    }
}

enum NativeWorkoutRequiredLinkagePolicy {
    static func complete(
        legacyRequired: Bool,
        persistLegacy: () -> Bool,
        telemetryRequired: Bool,
        persistTelemetry: () async -> Bool
    ) async -> Bool {
        if legacyRequired, !persistLegacy() { return false }
        if telemetryRequired, !(await persistTelemetry()) { return false }
        return true
    }
}

struct ActiveWorkoutRecoveryRequestGate {
    private var requestedSceneSessionIDs: Set<String> = []

    mutating func shouldRequestRecovery(
        sceneSessionID: String,
        recoveryRequested: Bool
    ) -> Bool {
        guard recoveryRequested else { return false }
        return requestedSceneSessionIDs.insert(sceneSessionID).inserted
    }
}

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

    struct DiagnosticSnapshot: Equatable {
        var phase: String
        var requestedAt: Date?
        var providerPreparedAt: Date?
        var collectionStartedAt: Date?
        var firstNativeCallbackMeasuredAt: Date?
        var firstNativeCallbackReceivedAt: Date?
        var firstQualifyingLatencySeconds: TimeInterval?
        var terminalAt: Date?
        var terminalReason: String?
        var gateBlockReason: String?

        static let idle = DiagnosticSnapshot(
            phase: "idle",
            requestedAt: nil,
            providerPreparedAt: nil,
            collectionStartedAt: nil,
            firstNativeCallbackMeasuredAt: nil,
            firstNativeCallbackReceivedAt: nil,
            firstQualifyingLatencySeconds: nil,
            terminalAt: nil,
            terminalReason: nil,
            gateBlockReason: nil
        )
    }

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
    private var latestProviderPreparedAt: Date?
    private(set) var diagnosticSnapshot: DiagnosticSnapshot = .idle

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
        guard safety.permitsStartIntent else {
            diagnosticSnapshot = DiagnosticSnapshot(
                phase: "blocked",
                requestedAt: intent.requestedAt,
                providerPreparedAt: latestProviderPreparedAt,
                collectionStartedAt: nil,
                firstNativeCallbackMeasuredAt: nil,
                firstNativeCallbackReceivedAt: nil,
                firstQualifyingLatencySeconds: nil,
                terminalAt: intent.requestedAt,
                terminalReason: "start_blocked",
                gateBlockReason: Self.startBlockReason(safety)
            )
            return []
        }
        diagnosticSnapshot = DiagnosticSnapshot(
            phase: "requested",
            requestedAt: intent.requestedAt,
            providerPreparedAt: latestProviderPreparedAt,
            collectionStartedAt: nil,
            firstNativeCallbackMeasuredAt: nil,
            firstNativeCallbackReceivedAt: nil,
            firstQualifyingLatencySeconds: nil,
            terminalAt: nil,
            terminalReason: nil,
            gateBlockReason: nil
        )
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
        latestProviderPreparedAt = date
        switch phase {
        case .warming:
            phase = .prepared
            return []
        case .preparing(let intent):
            if diagnosticSnapshot.requestedAt == intent.requestedAt {
                diagnosticSnapshot.phase = "provider_prepared"
                diagnosticSnapshot.providerPreparedAt = date
            }
            guard !deadlineReached(for: intent, now: date) else {
                return cancel(reason: .timeout, now: date)
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
            return cancel(reason: .timeout, now: now)
        }
        phase = .waiting(
            intent,
            acquisitionStartedAt: acquisitionStartedAt,
            observation: nil
        )
        diagnosticSnapshot.phase = "collecting"
        diagnosticSnapshot.collectionStartedAt = acquisitionStartedAt
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
            return cancel(reason: .timeout, now: now)
        }
        if observation.source == .nativeHealthKit,
           diagnosticSnapshot.firstNativeCallbackReceivedAt == nil {
            diagnosticSnapshot.firstNativeCallbackMeasuredAt = observation.measuredAt
            diagnosticSnapshot.firstNativeCallbackReceivedAt = observation.receivedAt
        }
        guard case .waiting(let intent, let acquisitionStartedAt, _) = phase,
              observation.isQualifying(
                collectionStartedAt: acquisitionStartedAt,
                now: now,
                freshnessLimit: freshnessLimit
              ) else {
            return []
        }
        diagnosticSnapshot.phase = "qualifying_hr_received"
        diagnosticSnapshot.firstQualifyingLatencySeconds = max(
            0,
            observation.receivedAt.timeIntervalSince(acquisitionStartedAt)
        )
        diagnosticSnapshot.gateBlockReason = safety.controllerUnitsAllowed
            ? nil
            : "controller_units_blocked"
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
            return cancel(reason: .timeout, now: now)
        }
        if safety.appActivity == .background {
            return cancel(reason: .appBackgrounded, now: now)
        }
        if !safety.treadmillControlReady || !safety.transportValid {
            return cancel(reason: .treadmillControlLost, now: now)
        }
        if safety.hasConflictingWorkout || safety.stopInProgress {
            return cancel(reason: .superseded, now: now)
        }
        return commitIfAllowed(safety: safety, now: now, freshnessLimit: freshnessLimit)
    }

    mutating func tick(now: Date) -> [Effect] {
        guard let intent = currentIntent,
              deadlineReached(for: intent, now: now) else {
            return []
        }
        return cancel(reason: .timeout, now: now)
    }

    mutating func cancel(reason: CancellationReason, now: Date = Date()) -> [Effect] {
        guard phase != .idle else { return [] }
        phase = .idle
        diagnosticSnapshot.phase = "terminal"
        diagnosticSnapshot.terminalAt = now
        diagnosticSnapshot.terminalReason = reason.rawValue
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
            return cancel(reason: .timeout, now: now)
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
        diagnosticSnapshot.phase = "committed"
        diagnosticSnapshot.terminalAt = now
        diagnosticSnapshot.terminalReason = "committed"
        diagnosticSnapshot.gateBlockReason = nil
        return [.commit(
            intent: intent,
            observation: observation,
            acquisitionStartedAt: acquisitionStartedAt
        )]
    }

    private func deadlineReached(for intent: Intent, now: Date) -> Bool {
        now >= intent.requestedAt.addingTimeInterval(Self.timeoutSeconds)
    }

    private static func startBlockReason(_ safety: SafetyFacts) -> String {
        if safety.appActivity != .active { return "app_not_active" }
        if !safety.treadmillControlReady { return "treadmill_not_ready" }
        if !safety.transportValid { return "transport_invalid" }
        if safety.hasConflictingWorkout { return "conflicting_workout" }
        if safety.stopInProgress { return "stop_in_progress" }
        return "unknown"
    }
}
