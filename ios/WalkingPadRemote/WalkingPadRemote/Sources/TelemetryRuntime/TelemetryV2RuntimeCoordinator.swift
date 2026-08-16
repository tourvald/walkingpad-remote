import CryptoKit
import Dispatch
import Foundation
#if canImport(TelemetryDomain)
import TelemetryDomain
#endif
#if canImport(TelemetryRecorder)
import TelemetryRecorder
#endif
public enum TelemetryV2RuntimeStatus: Equatable, Sendable {
    case idle
    case preparing
    case starting
    case active(TelemetryRecorderCompleteness)
    case finishing
    case unavailable(String)
    case incomplete(String)
}

public enum TelemetryV2WriterLifecycle: String, Equatable, Sendable {
    case idle
    case preparing
    case starting
    case active
    case finishing
    case unavailable
    case incomplete
}

public enum TelemetryV2WriterRecorderLifecycle: String, Equatable, Sendable {
    case beginning
    case active
    case finishing
    case failing
    case cancelling
    case complete
    case incomplete
    case failed
    case cancelled
}

public enum TelemetryV2WriterCompleteness: String, Equatable, Sendable {
    case complete
    case incomplete
    case failed
    case cancelled
}

public struct TelemetryV2WriterHealthSnapshot: Equatable, Sendable {
    public let runtimeLifecycle: TelemetryV2WriterLifecycle
    public let recorderLifecycle: TelemetryV2WriterRecorderLifecycle?
    public let completeness: TelemetryV2WriterCompleteness?
    public let queueDepth: Int
    public let peakQueueDepth: Int
    public let coalescedFrameCount: UInt64
    public let droppedFrameCount: UInt64
    public let lostNativeCount: UInt64
    public let lostCriticalCount: UInt64
    public let writerFailureCount: UInt64
    public let retryCount: UInt64
    public let successfulFlushCount: UInt64
    public let lastCommittedRecorderSequence: UInt64?
    public let mostRecentFlushDuration: Duration?

    public static let idle = TelemetryV2WriterHealthSnapshot(
        runtimeStatus: .idle,
        operationalState: nil
    )

    init(
        runtimeStatus: TelemetryV2RuntimeStatus,
        operationalState: TelemetryRecorderOperationalState?
    ) {
        switch runtimeStatus {
        case .idle:
            runtimeLifecycle = .idle
        case .preparing:
            runtimeLifecycle = .preparing
        case .starting:
            runtimeLifecycle = .starting
        case .active:
            runtimeLifecycle = .active
        case .finishing:
            runtimeLifecycle = .finishing
        case .unavailable:
            runtimeLifecycle = .unavailable
        case .incomplete:
            runtimeLifecycle = .incomplete
        }
        switch operationalState?.lifecycleState {
        case .beginning: recorderLifecycle = .beginning
        case .active: recorderLifecycle = .active
        case .finishing: recorderLifecycle = .finishing
        case .failing: recorderLifecycle = .failing
        case .cancelling: recorderLifecycle = .cancelling
        case .complete: recorderLifecycle = .complete
        case .incomplete: recorderLifecycle = .incomplete
        case .failed: recorderLifecycle = .failed
        case .cancelled: recorderLifecycle = .cancelled
        case nil: recorderLifecycle = nil
        }
        if let operationalState {
            switch operationalState.completeness {
            case .complete: completeness = .complete
            case .incomplete: completeness = .incomplete
            case .failed: completeness = .failed
            case .cancelled: completeness = .cancelled
            }
        } else if case let .active(runtimeCompleteness) = runtimeStatus {
            switch runtimeCompleteness {
            case .complete: completeness = .complete
            case .incomplete: completeness = .incomplete
            case .failed: completeness = .failed
            case .cancelled: completeness = .cancelled
            }
        } else {
            completeness = nil
        }
        queueDepth = operationalState?.queueDepth ?? 0
        peakQueueDepth = operationalState?.peakQueueDepth ?? 0
        coalescedFrameCount = operationalState?.coalescedFrameCount ?? 0
        droppedFrameCount = operationalState?.droppedFrameCount ?? 0
        lostNativeCount = operationalState?.lostNativeCount ?? 0
        lostCriticalCount = operationalState?.lostCriticalCount ?? 0
        writerFailureCount = operationalState?.writerFailureCount ?? 0
        retryCount = operationalState?.retryCount ?? 0
        successfulFlushCount = operationalState?.successfulFlushCount ?? 0
        lastCommittedRecorderSequence = operationalState?.lastCommittedRecorderSequence
        mostRecentFlushDuration = operationalState?.mostRecentFlushDuration
    }
}

public protocol TelemetryV2RuntimeClock: AnyObject, Sendable {
    func nowDate() -> Date
    func now() -> Duration
}

public final class ContinuousTelemetryV2RuntimeClock: TelemetryV2RuntimeClock,
    @unchecked Sendable
{
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    public init() {
        origin = clock.now
    }

    public func nowDate() -> Date {
        Date()
    }

    public func now() -> Duration {
        origin.duration(to: clock.now)
    }
}

public struct TelemetryV2TreadmillContext: Codable, Equatable, Sendable {
    public let stableLocalIdentifier: String?
    public let model: String?
    public let protocolName: String
    public let protocolVersion: String?
    public let minimumSpeedKilometresPerHour: Double
    public let maximumSpeedKilometresPerHour: Double
    public let speedIncrementKilometresPerHour: Double

    public init(
        stableLocalIdentifier: String?,
        model: String?,
        protocolName: String,
        protocolVersion: String?,
        minimumSpeedKilometresPerHour: Double,
        maximumSpeedKilometresPerHour: Double,
        speedIncrementKilometresPerHour: Double
    ) {
        self.stableLocalIdentifier = stableLocalIdentifier
        self.model = model
        self.protocolName = protocolName
        self.protocolVersion = protocolVersion
        self.minimumSpeedKilometresPerHour = minimumSpeedKilometresPerHour
        self.maximumSpeedKilometresPerHour = maximumSpeedKilometresPerHour
        self.speedIncrementKilometresPerHour = speedIncrementKilometresPerHour
    }
}

public struct TelemetryV2ConfigurationInput: Codable, Equatable, Sendable {
    public let profileLocalIdentifier: String
    public let workoutMode: WorkoutMode
    public let targetHeartRate: Int
    public let durationMinutes: Int
    public let decisionIntervalSeconds: Int
    public let adaptiveStepEnabled: Bool
    public let maximumStepKilometresPerHour: Double
    public let heartRateZones: [Int]
    public let cooldownTargetHeartRate: Int
    public let cooldownMinimumSpeedKilometresPerHour: Double
    public let cooldownMaximumMinutes: Int
    public let heartRateProviderKind: String
    public let heartRateProviderStableLocalKey: String
    public let treadmill: TelemetryV2TreadmillContext

    public init(
        profileLocalIdentifier: String,
        workoutMode: WorkoutMode,
        targetHeartRate: Int,
        durationMinutes: Int,
        decisionIntervalSeconds: Int,
        adaptiveStepEnabled: Bool,
        maximumStepKilometresPerHour: Double,
        heartRateZones: [Int],
        cooldownTargetHeartRate: Int,
        cooldownMinimumSpeedKilometresPerHour: Double,
        cooldownMaximumMinutes: Int,
        heartRateProviderKind: String,
        heartRateProviderStableLocalKey: String,
        treadmill: TelemetryV2TreadmillContext
    ) {
        self.profileLocalIdentifier = profileLocalIdentifier
        self.workoutMode = workoutMode
        self.targetHeartRate = targetHeartRate
        self.durationMinutes = durationMinutes
        self.decisionIntervalSeconds = decisionIntervalSeconds
        self.adaptiveStepEnabled = adaptiveStepEnabled
        self.maximumStepKilometresPerHour = maximumStepKilometresPerHour
        self.heartRateZones = heartRateZones
        self.cooldownTargetHeartRate = cooldownTargetHeartRate
        self.cooldownMinimumSpeedKilometresPerHour = cooldownMinimumSpeedKilometresPerHour
        self.cooldownMaximumMinutes = cooldownMaximumMinutes
        self.heartRateProviderKind = heartRateProviderKind
        self.heartRateProviderStableLocalKey = heartRateProviderStableLocalKey
        self.treadmill = treadmill
    }
}

public struct TelemetryV2SessionDescriptor: Sendable {
    public let sessionID: SessionID
    public let deterministicLegacySessionID: UUID?
    public let startedAt: Date
    public let appContext: AppRuntimeContext
    public let configuration: TelemetryV2ConfigurationInput
    public let versions: RuntimeVersionContext
    public let heartRateFreshnessLimitSeconds: TimeInterval
    public let treadmillFreshnessLimitSeconds: TimeInterval

    public init(
        sessionID: SessionID,
        deterministicLegacySessionID: UUID?,
        startedAt: Date,
        appContext: AppRuntimeContext,
        configuration: TelemetryV2ConfigurationInput,
        versions: RuntimeVersionContext,
        heartRateFreshnessLimitSeconds: TimeInterval,
        treadmillFreshnessLimitSeconds: TimeInterval
    ) {
        precondition(
            deterministicLegacySessionID == nil
                || deterministicLegacySessionID == sessionID.rawValue,
            "A legacy session may be linked only by exact identity."
        )
        self.sessionID = sessionID
        self.deterministicLegacySessionID = deterministicLegacySessionID
        self.startedAt = startedAt
        self.appContext = appContext
        self.configuration = configuration
        self.versions = versions
        self.heartRateFreshnessLimitSeconds = heartRateFreshnessLimitSeconds
        self.treadmillFreshnessLimitSeconds = treadmillFreshnessLimitSeconds
    }

    public static func sessionID(deterministicallyLinkedTo legacySessionID: UUID?) -> SessionID {
        SessionID(rawValue: legacySessionID ?? UUID())
    }

    fileprivate func header() throws -> WorkoutSessionRecord {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(configuration)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let snapshot = ImmutableConfigurationSnapshot(
            id: ConfigurationSnapshotID(
                rawValue: Self.deterministicUUID(key: "configuration:\(digest)")
            ),
            formatVersion: 1,
            format: .canonicalJSON,
            canonicalPayload: payload,
            contentHash: ContentHash(algorithm: .sha256, lowercaseHexDigest: digest)
        )
        return WorkoutSessionRecord(
            recordID: RecordID(),
            sessionID: sessionID,
            profileLocalIdentifier: configuration.profileLocalIdentifier,
            lifecycleState: .running,
            workoutMode: configuration.workoutMode,
            startedAt: startedAt,
            endedAt: nil,
            endedElapsed: nil,
            incompleteReason: nil,
            appContext: appContext,
            versions: versions,
            configuration: snapshot,
            healthKitWorkoutIdentifier: nil,
            treadmill: KnownTreadmillMetadata(
                stableLocalIdentifier: configuration.treadmill.stableLocalIdentifier,
                model: configuration.treadmill.model,
                protocolName: configuration.treadmill.protocolName,
                protocolVersion: configuration.treadmill.protocolVersion
            ),
            recorderHealth: RecorderHealthSummary(
                isComplete: false,
                lostCriticalRecordCount: 0,
                lostNativeRecordCount: 0,
                lastPersistedElapsed: nil
            )
        )
    }

    fileprivate static func deterministicUUID(key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }
        return UUID(
            uuidString: [
                hex[0...3].joined(),
                hex[4...5].joined(),
                hex[6...7].joined(),
                hex[8...9].joined(),
                hex[10...15].joined(),
            ].joined(separator: "-")
        )!
    }
}

public final class TelemetryV2RuntimeCoordinator: HeartRateTelemetrySink,
    TreadmillTelemetrySink, @unchecked Sendable
{
    public typealias PersistenceFactory = @Sendable () throws -> any TelemetryRecorderPersistence
    public typealias StatusHandler = @Sendable (TelemetryV2RuntimeStatus) -> Void
    public typealias WriterHealthHandler = @Sendable (TelemetryV2WriterHealthSnapshot) -> Void

    fileprivate enum PendingEvidence: Sendable {
        case heartRate(HeartRateNormalizationResult)
        case sourceLifecycle(HeartRateSourceLifecycleEvidence)
        case controlUse(HeartRateControlUseEvidence)
        case treadmill(TreadmillTelemetryEvidence)
        case event(WorkoutEventPayload, Date)
        case workoutPhase(WorkoutPhase, Date)

        var lostRecordCounts: (critical: UInt64, native: UInt64) {
            switch self {
            case let .heartRate(result):
                (1, result.canonicalObservation == nil ? 0 : 1)
            case let .treadmill(evidence):
                if case let .observation(observation) = evidence,
                   observation.nativeSpeed != nil
                {
                    (1, 1)
                } else {
                    (1, 0)
                }
            case .sourceLifecycle, .controlUse, .event, .workoutPhase:
                (1, 0)
            }
        }

        func sourceID(for descriptor: TelemetryV2SessionDescriptor) -> SourceID? {
            let stableKey: String?
            switch self {
            case let .heartRate(result):
                stableKey = "hr:\(result.delivery.source.stableLocalKey)"
            case let .sourceLifecycle(evidence):
                stableKey = "hr:\(evidence.source.stableLocalKey)"
            case .controlUse:
                stableKey = "hr:\(descriptor.configuration.heartRateProviderStableLocalKey)"
            case let .treadmill(evidence):
                guard let stableDevice = descriptor.configuration.treadmill.stableLocalIdentifier,
                      !stableDevice.isEmpty else { return nil }
                stableKey = "treadmill:\(stableDevice):\(evidence.protocolKind.rawValue)"
            case .event, .workoutPhase:
                stableKey = nil
            }
            return stableKey.map {
                SourceID(
                    rawValue: TelemetryV2SessionDescriptor.deterministicUUID(key: $0)
                )
            }
        }
    }

    fileprivate struct PendingLossSummary: Sendable {
        var lostCriticalRecordCount: UInt64 = 0
        var lostNativeRecordCount: UInt64 = 0
        var droppedFrameCount: UInt64 = 0
        var firstCriticalAffectedElapsed: ElapsedDuration?
        var lastCriticalAffectedElapsed: ElapsedDuration?
        var firstNativeAffectedElapsed: ElapsedDuration?
        var lastNativeAffectedElapsed: ElapsedDuration?
        var firstBulkFrameAffectedElapsed: ElapsedDuration?
        var lastBulkFrameAffectedElapsed: ElapsedDuration?

        var hasLoss: Bool {
            lostCriticalRecordCount > 0
                || lostNativeRecordCount > 0
                || droppedFrameCount > 0
        }

        mutating func recordDroppedFrame(at elapsed: ElapsedDuration) {
            droppedFrameCount = Self.saturatedSum(droppedFrameCount, 1)
            firstBulkFrameAffectedElapsed = firstBulkFrameAffectedElapsed ?? elapsed
            lastBulkFrameAffectedElapsed = elapsed
        }

        mutating func record(
            _ evidence: PendingEvidence,
            at elapsed: ElapsedDuration,
            losesSourceRecord: Bool
        ) {
            let counts = evidence.lostRecordCounts
            lostCriticalRecordCount = Self.saturatedSum(
                lostCriticalRecordCount,
                Self.saturatedSum(counts.critical, losesSourceRecord ? 1 : 0)
            )
            lostNativeRecordCount = Self.saturatedSum(
                lostNativeRecordCount,
                counts.native
            )
            if counts.critical > 0 {
                firstCriticalAffectedElapsed = firstCriticalAffectedElapsed ?? elapsed
                lastCriticalAffectedElapsed = elapsed
            }
            if counts.native > 0 {
                firstNativeAffectedElapsed = firstNativeAffectedElapsed ?? elapsed
                lastNativeAffectedElapsed = elapsed
            }
        }

        private static func saturatedSum(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
            let result = lhs.addingReportingOverflow(rhs)
            return result.overflow ? UInt64.max : result.partialValue
        }
    }

    private struct PendingSession {
        let generation: UInt64
        let descriptor: TelemetryV2SessionDescriptor
        let startedMonotonic: Duration
        var isStarting: Bool
        var evidence: [PendingEvidence]
        var lossSummary: PendingLossSummary
        var lastObservedFrameSecond: Int64?
        var seenSourceIDs: Set<SourceID>
    }

    private struct ActiveSession {
        let generation: UInt64
        let session: TelemetryV2ActiveSession
    }

    private static let pendingEvidenceCapacity = 256
    private let lock = NSLock()
    private let persistenceFactory: PersistenceFactory
    private let statusHandler: StatusHandler?
    private let writerHealthHandler: WriterHealthHandler?
    private let runtimeClock: any TelemetryV2RuntimeClock
    private let installationDidPublishForTesting: (@Sendable (SessionID) -> Void)?
    private var persistence: (any TelemetryRecorderPersistence)?
    private var preparationStarted = false
    private var preparationFailed = false
    private var generation: UInt64 = 0
    private var pendingSession: PendingSession?
    private var activeSession: ActiveSession?
    private var storedStatus: TelemetryV2RuntimeStatus = .idle
    private var storedOperationalState: TelemetryRecorderOperationalState?
    private var storedWriterHealthSnapshot: TelemetryV2WriterHealthSnapshot = .idle

    public convenience init(
        persistenceFactory: @escaping PersistenceFactory,
        runtimeClock: any TelemetryV2RuntimeClock = ContinuousTelemetryV2RuntimeClock(),
        statusHandler: StatusHandler? = nil,
        writerHealthHandler: WriterHealthHandler? = nil
    ) {
        self.init(
            persistenceFactory: persistenceFactory,
            runtimeClock: runtimeClock,
            statusHandler: statusHandler,
            writerHealthHandler: writerHealthHandler,
            installationDidPublishForTesting: nil
        )
    }

    init(
        persistenceFactory: @escaping PersistenceFactory,
        runtimeClock: any TelemetryV2RuntimeClock = ContinuousTelemetryV2RuntimeClock(),
        statusHandler: StatusHandler? = nil,
        writerHealthHandler: WriterHealthHandler? = nil,
        installationDidPublishForTesting: @escaping @Sendable (SessionID) -> Void
    ) {
        self.persistenceFactory = persistenceFactory
        self.runtimeClock = runtimeClock
        self.statusHandler = statusHandler
        self.writerHealthHandler = writerHealthHandler
        self.installationDidPublishForTesting = installationDidPublishForTesting
    }

    private init(
        persistenceFactory: @escaping PersistenceFactory,
        runtimeClock: any TelemetryV2RuntimeClock,
        statusHandler: StatusHandler?,
        writerHealthHandler: WriterHealthHandler?,
        installationDidPublishForTesting: (@Sendable (SessionID) -> Void)?
    ) {
        self.persistenceFactory = persistenceFactory
        self.runtimeClock = runtimeClock
        self.statusHandler = statusHandler
        self.writerHealthHandler = writerHealthHandler
        self.installationDidPublishForTesting = installationDidPublishForTesting
    }

    public var status: TelemetryV2RuntimeStatus {
        withLock { storedStatus }
    }

    public var writerHealthSnapshot: TelemetryV2WriterHealthSnapshot {
        withLock { storedWriterHealthSnapshot }
    }

    public func prepareStoreAndRecover() {
        let shouldStart: Bool = withLock {
            guard !preparationStarted else { return false }
            preparationStarted = true
            setStatusLocked(.preparing)
            return true
        }
        guard shouldStart else { return }

        let factory = persistenceFactory
        Task.detached(priority: .utility) { [weak self] in
            do {
                let persistence = try factory()
                _ = try await TelemetryRecorder.recoverUnfinishedSessions(using: persistence)
                self?.storePrepared(persistence)
            } catch {
                self?.storePreparationFailed(error)
            }
        }
    }

    public func beginSession(_ descriptor: TelemetryV2SessionDescriptor) {
        let state: (TelemetryV2ActiveSession?, Bool) = withLock {
            generation &+= 1
            let previous = activeSession?.session
            activeSession = nil
            storedOperationalState = nil
            guard !preparationFailed else {
                pendingSession = nil
                setStatusLocked(.unavailable("store-unavailable"))
                return (previous, false)
            }
            pendingSession = PendingSession(
                generation: generation,
                descriptor: descriptor,
                startedMonotonic: runtimeClock.now(),
                isStarting: false,
                evidence: [],
                lossSummary: PendingLossSummary(),
                lastObservedFrameSecond: nil,
                seenSourceIDs: []
            )
            setStatusLocked(.starting)
            return (previous, true)
        }
        state.0?.requestCancellation()
        guard state.1 else { return }
        prepareStoreAndRecover()
        launchPendingSessionIfPossible()
    }

    public func endSession(reason: String) {
        let ending: (TelemetryV2ActiveSession?, UInt64, Bool) = withLock {
            guard pendingSession != nil || activeSession != nil else {
                return (nil, generation, false)
            }
            generation &+= 1
            pendingSession = nil
            let session = activeSession?.session
            activeSession = nil
            setStatusLocked(session == nil ? .incomplete("ended-before-recorder-ready") : .finishing)
            return (session, generation, true)
        }
        guard ending.2 else { return }
        guard let session = ending.0 else { return }
        session.emitSessionEnd(reason: reason)
        Task.detached(priority: .utility) { [weak self] in
            let result = await session.finish()
            self?.sessionFinished(
                result,
                operationalState: session.operationalState,
                generation: ending.1
            )
        }
    }

    @discardableResult
    public func observeCurrentElapsedSecond() -> TelemetryYieldDisposition? {
        guard let session = currentActiveSession() else {
            return recordPendingFrameDrop()
        }
        let disposition = session.observeCurrentElapsedSecond()
        refreshStatus(from: session)
        return disposition
    }

    public func observeHeartRate(
        _ result: HeartRateNormalizationResult
    ) -> HeartRateTelemetrySinkDisposition {
        guard let session = currentActiveSession() else {
            guard let disposition = bufferDisposition(.heartRate(result)) else {
                return .unavailable
            }
            return Self.heartRateDisposition(disposition)
        }
        let disposition = session.observeHeartRate(result)
        refreshStatus(from: session)
        return Self.heartRateDisposition(disposition)
    }

    public func observeSourceLifecycle(
        _ evidence: HeartRateSourceLifecycleEvidence
    ) -> HeartRateTelemetrySinkDisposition {
        guard let session = currentActiveSession() else {
            guard let disposition = bufferDisposition(.sourceLifecycle(evidence)) else {
                return .unavailable
            }
            return Self.heartRateDisposition(disposition)
        }
        let disposition = session.observeHeartRateRuntime(.sourceLifecycle(evidence))
        refreshStatus(from: session)
        return Self.heartRateDisposition(disposition)
    }

    public func observeControlUse(
        _ evidence: HeartRateControlUseEvidence
    ) -> HeartRateTelemetrySinkDisposition {
        guard let session = currentActiveSession() else {
            guard let disposition = bufferDisposition(.controlUse(evidence)) else {
                return .unavailable
            }
            return Self.heartRateDisposition(disposition)
        }
        let disposition = session.observeHeartRateRuntime(.controlUse(evidence))
        refreshStatus(from: session)
        return Self.heartRateDisposition(disposition)
    }

    public func observeTreadmillEvidence(
        _ evidence: TreadmillTelemetryEvidence
    ) -> TreadmillTelemetrySinkDisposition {
        guard let session = currentActiveSession() else {
            guard let disposition = bufferDisposition(.treadmill(evidence)) else {
                return .unavailable
            }
            return Self.treadmillDisposition(disposition)
        }
        let disposition = session.observeTreadmill(evidence)
        refreshStatus(from: session)
        return Self.treadmillDisposition(disposition)
    }

    @discardableResult
    public func observeEvent(
        _ payload: WorkoutEventPayload,
        occurredAt: Date
    ) -> TelemetryYieldDisposition? {
        guard let session = currentActiveSession() else {
            return bufferDisposition(.event(payload, occurredAt))
        }
        let disposition = session.observeEvent(payload, occurredAt: occurredAt)
        refreshStatus(from: session)
        return disposition
    }

    @discardableResult
    public func observeWorkoutPhase(
        _ phase: WorkoutPhase,
        occurredAt: Date
    ) -> TelemetryYieldDisposition? {
        guard let session = currentActiveSession() else {
            return bufferDisposition(.workoutPhase(phase, occurredAt))
        }
        let disposition = session.observeWorkoutPhase(phase, occurredAt: occurredAt)
        refreshStatus(from: session)
        return disposition
    }

    private func storePrepared(_ persistence: any TelemetryRecorderPersistence) {
        withLock {
            self.persistence = persistence
            if pendingSession == nil, activeSession == nil, storedStatus == .preparing {
                setStatusLocked(.idle)
            }
        }
        launchPendingSessionIfPossible()
    }

    private func storePreparationFailed(_ error: Error) {
        withLock {
            preparationFailed = true
            pendingSession = nil
            storedOperationalState = nil
            setStatusLocked(.unavailable("store-or-recovery-failed:\(Self.errorCode(error))"))
        }
    }

    private func launchPendingSessionIfPossible() {
        let work: (PendingSession, any TelemetryRecorderPersistence)? = withLock {
            guard var pendingSession,
                  !pendingSession.isStarting,
                  let persistence else { return nil }
            pendingSession.isStarting = true
            self.pendingSession = pendingSession
            return (pendingSession, persistence)
        }
        guard let work else { return }
        Task.detached(priority: .utility) { [weak self] in
            do {
                let header = try work.0.descriptor.header()
                let recorder = TelemetryRecorder(
                    sessionHeader: header,
                    persistence: work.1
                )
                let session = TelemetryV2ActiveSession(
                    descriptor: work.0.descriptor,
                    recorder: recorder,
                    runtimeClock: self?.runtimeClock ?? ContinuousTelemetryV2RuntimeClock(),
                    startedMonotonic: work.0.startedMonotonic
                )
                self?.install(session, generation: work.0.generation)
            } catch {
                self?.sessionStartFailed(error, generation: work.0.generation)
            }
        }
    }

    private func install(_ session: TelemetryV2ActiveSession, generation: UInt64) {
        session.activate()
        while true {
            let next: ([PendingEvidence], PendingLossSummary)? = withLock {
                guard self.generation == generation,
                      var pending = pendingSession,
                      pending.generation == generation else { return nil }
                if pending.evidence.isEmpty {
                    pendingSession = nil
                    activeSession = ActiveSession(generation: generation, session: session)
                    setStatusLocked(
                        !pending.lossSummary.hasLoss
                            ? .active(.complete)
                            : .incomplete("pre-recorder-staging-overflow")
                    )
                    return ([], pending.lossSummary)
                }
                let evidence = pending.evidence
                pending.evidence.removeAll(keepingCapacity: true)
                pendingSession = pending
                return (evidence, pending.lossSummary)
            }
            guard let next else {
                session.requestCancellation()
                return
            }
            if next.0.isEmpty {
                installationDidPublishForTesting?(session.sessionID)
                session.completeInstallation(stagingLoss: next.1)
                refreshStatus(from: session)
                return
            }
            for evidence in next.0 {
                session.replay(evidence)
            }
        }
    }

    private func sessionStartFailed(_ error: Error, generation: UInt64) {
        withLock {
            guard self.generation == generation else { return }
            pendingSession = nil
            storedOperationalState = nil
            setStatusLocked(.unavailable("session-start-failed:\(Self.errorCode(error))"))
        }
    }

    private func sessionFinished(
        _ result: TelemetryFinishResult,
        operationalState: TelemetryRecorderOperationalState,
        generation: UInt64
    ) {
        withLock {
            guard self.generation == generation else { return }
            storedOperationalState = operationalState
            switch result.completeness {
            case .complete:
                setStatusLocked(.idle)
            case .incomplete, .failed, .cancelled:
                setStatusLocked(.incomplete(result.completeness.rawValue))
            }
        }
    }

    private func currentActiveSession() -> TelemetryV2ActiveSession? {
        withLock {
            guard activeSession?.generation == generation else { return nil }
            return activeSession?.session
        }
    }

    var activeSessionIDForTesting: SessionID? {
        withLock {
            guard activeSession?.generation == generation else { return nil }
            return activeSession?.session.sessionID
        }
    }

    private func bufferDisposition(
        _ evidence: PendingEvidence
    ) -> TelemetryYieldDisposition? {
        withLock {
            guard var pending = pendingSession else { return nil }
            guard pending.evidence.count < Self.pendingEvidenceCapacity else {
                let sourceID = evidence.sourceID(for: pending.descriptor)
                let losesSourceRecord = sourceID.map {
                    pending.seenSourceIDs.insert($0).inserted
                } ?? false
                pending.lossSummary.record(
                    evidence,
                    at: Self.elapsedDuration(runtimeClock.now() - pending.startedMonotonic),
                    losesSourceRecord: losesSourceRecord
                )
                pendingSession = pending
                setStatusLocked(.incomplete("pre-recorder-staging-overflow"))
                return evidence.lostRecordCounts.critical > 0 ? .lostCritical : .lostNative
            }
            pending.evidence.append(evidence)
            if let sourceID = evidence.sourceID(for: pending.descriptor) {
                pending.seenSourceIDs.insert(sourceID)
            }
            pendingSession = pending
            return .enqueued
        }
    }

    private func recordPendingFrameDrop() -> TelemetryYieldDisposition? {
        withLock {
            guard var pending = pendingSession else { return nil }
            let elapsed = Self.elapsedDuration(runtimeClock.now() - pending.startedMonotonic)
            let currentSecond = max(0, elapsed.microseconds / 1_000_000)
            guard pending.lastObservedFrameSecond != currentSecond else {
                return .coalescedFrame
            }
            pending.lastObservedFrameSecond = currentSecond
            pending.lossSummary.recordDroppedFrame(at: elapsed)
            pendingSession = pending
            setStatusLocked(.incomplete("pre-recorder-staging-overflow"))
            return .droppedFrame
        }
    }

    private func refreshStatus(from session: TelemetryV2ActiveSession) {
        let operationalState = session.operationalState
        withLock {
            guard activeSession?.generation == generation,
                  activeSession?.session === session else { return }
            storedOperationalState = operationalState
            if session.hasStagingLoss {
                setStatusLocked(.incomplete("pre-recorder-staging-overflow"))
                return
            }
            switch operationalState.lifecycleState {
            case .failed, .cancelled, .incomplete:
                setStatusLocked(.incomplete(operationalState.lifecycleState.rawValue))
            default:
                setStatusLocked(.active(operationalState.completeness))
            }
        }
    }

    private func setStatusLocked(_ status: TelemetryV2RuntimeStatus) {
        let statusChanged = storedStatus != status
        storedStatus = status
        let writerHealthSnapshot = TelemetryV2WriterHealthSnapshot(
            runtimeStatus: status,
            operationalState: storedOperationalState
        )
        if writerHealthSnapshot != storedWriterHealthSnapshot {
            storedWriterHealthSnapshot = writerHealthSnapshot
            if let writerHealthHandler {
                DispatchQueue.main.async {
                    writerHealthHandler(writerHealthSnapshot)
                }
            }
        }
        if statusChanged, let statusHandler {
            DispatchQueue.main.async {
                statusHandler(status)
            }
        }
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }

    private static func heartRateDisposition(
        _ disposition: TelemetryYieldDisposition
    ) -> HeartRateTelemetrySinkDisposition {
        switch disposition {
        case .enqueued, .coalescedFrame: .accepted
        case .droppedFrame, .lostNative, .lostCritical: .degraded
        case .rejectedAfterFinish, .rejectedTerminal, .sequenceExhausted: .rejected
        }
    }

    private static func treadmillDisposition(
        _ disposition: TelemetryYieldDisposition
    ) -> TreadmillTelemetrySinkDisposition {
        switch disposition {
        case .enqueued, .coalescedFrame: .accepted
        case .droppedFrame, .lostNative, .lostCritical: .degraded
        case .rejectedAfterFinish, .rejectedTerminal, .sequenceExhausted: .rejected
        }
    }

    private static func errorCode(_ error: Error) -> String {
        String(describing: type(of: error))
    }

    private static func elapsedDuration(_ duration: Duration) -> ElapsedDuration {
        let components = duration.components
        let seconds = components.seconds.multipliedReportingOverflow(by: 1_000_000)
        guard !seconds.overflow else { return ElapsedDuration(microseconds: Int64.max) }
        let fractional = components.attoseconds / 1_000_000_000_000
        let total = seconds.partialValue.addingReportingOverflow(fractional)
        return ElapsedDuration(
            microseconds: total.overflow ? Int64.max : max(0, total.partialValue)
        )
    }
}

private final class TelemetryV2ActiveSession: @unchecked Sendable {
    private enum InstallationState {
        case installing
        case installed
        case invalidated
    }

    private let descriptor: TelemetryV2SessionDescriptor
    private let recorder: TelemetryRecorder
    private let runtimeClock: any TelemetryV2RuntimeClock
    private let startedMonotonic: Duration
    private let lock = NSLock()
    private var emittedSourceIDs: Set<SourceID> = []
    private var latestHeartRate: HeartRateObservation?
    private var latestTreadmill: TreadmillObservation?
    private var lastObservedFrameSecond: Int64?
    private var firstMissingFrameSecond: Int64?
    private var currentWorkoutPhase: WorkoutPhase?
    private var ending = false
    private var stagingLossSummary = TelemetryV2RuntimeCoordinator.PendingLossSummary()
    private var installationState = InstallationState.installing
    private var installationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        descriptor: TelemetryV2SessionDescriptor,
        recorder: TelemetryRecorder,
        runtimeClock: any TelemetryV2RuntimeClock,
        startedMonotonic: Duration
    ) {
        self.descriptor = descriptor
        self.recorder = recorder
        self.runtimeClock = runtimeClock
        self.startedMonotonic = startedMonotonic
    }

    var operationalState: TelemetryRecorderOperationalState {
        recorder.operationalState
    }

    var sessionID: SessionID {
        descriptor.sessionID
    }

    var hasStagingLoss: Bool {
        withLock { stagingLossSummary.hasLoss }
    }

    func activate() {
        _ = yieldEvent(
            .sessionLifecycle(
                SessionLifecycleEvent(previous: nil, current: .running, reason: "authorized-start")
            ),
            occurredAt: descriptor.startedAt,
            sourceID: nil
        )
        _ = observeWorkoutPhase(.main, occurredAt: descriptor.startedAt)
    }

    func replay(_ evidence: TelemetryV2RuntimeCoordinator.PendingEvidence) {
        switch evidence {
        case let .heartRate(result):
            _ = observeHeartRate(result)
        case let .sourceLifecycle(sourceLifecycle):
            _ = observeHeartRateRuntime(.sourceLifecycle(sourceLifecycle))
        case let .controlUse(controlUse):
            _ = observeHeartRateRuntime(.controlUse(controlUse))
        case let .treadmill(treadmill):
            _ = observeTreadmill(treadmill)
        case let .event(payload, occurredAt):
            _ = observeEvent(payload, occurredAt: occurredAt)
        case let .workoutPhase(phase, occurredAt):
            _ = observeWorkoutPhase(phase, occurredAt: occurredAt)
        }
    }

    func completeInstallation(
        stagingLoss summary: TelemetryV2RuntimeCoordinator.PendingLossSummary
    ) {
        let canComplete: Bool = withLock {
            if case .installing = installationState { return true }
            return false
        }
        guard canComplete else { return }
        if summary.hasLoss {
            emitStagingLoss(summary)
        }
        let waiters: [CheckedContinuation<Void, Never>] = withLock {
            guard case .installing = installationState else { return [] }
            installationState = .installed
            let waiters = installationWaiters
            installationWaiters.removeAll(keepingCapacity: false)
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    private func emitStagingLoss(
        _ summary: TelemetryV2RuntimeCoordinator.PendingLossSummary
    ) {
        withLock { stagingLossSummary = summary }
        let occurredAt = runtimeClock.nowDate()
        if summary.lostCriticalRecordCount > 0 {
            _ = yieldEvent(
                .recorderHealth(
                    RecorderHealthEvent(
                        kind: .loss,
                        affectedRecordClass: "critical",
                        count: summary.lostCriticalRecordCount,
                        firstAffectedElapsed: summary.firstCriticalAffectedElapsed,
                        lastAffectedElapsed: summary.lastCriticalAffectedElapsed,
                        detailCode: "pre-recorder-staging-overflow"
                    )
                ),
                occurredAt: occurredAt,
                sourceID: nil
            )
        }
        if summary.lostNativeRecordCount > 0 {
            _ = yieldEvent(
                .recorderHealth(
                    RecorderHealthEvent(
                        kind: .loss,
                        affectedRecordClass: "native",
                        count: summary.lostNativeRecordCount,
                        firstAffectedElapsed: summary.firstNativeAffectedElapsed,
                        lastAffectedElapsed: summary.lastNativeAffectedElapsed,
                        detailCode: "pre-recorder-staging-overflow"
                    )
                ),
                occurredAt: occurredAt,
                sourceID: nil
            )
        }
        if summary.droppedFrameCount > 0 {
            _ = yieldEvent(
                .recorderHealth(
                    RecorderHealthEvent(
                        kind: .loss,
                        affectedRecordClass: "bulkFrame",
                        count: summary.droppedFrameCount,
                        firstAffectedElapsed: summary.firstBulkFrameAffectedElapsed,
                        lastAffectedElapsed: summary.lastBulkFrameAffectedElapsed,
                        detailCode: "pre-recorder-staging-overflow"
                    )
                ),
                occurredAt: occurredAt,
                sourceID: nil
            )
        }
        _ = recorder.requestIncomplete(
            endedAt: occurredAt,
            endedElapsed: elapsed(),
            reason: "pre-recorder-staging-overflow",
            lostCriticalRecordCount: summary.lostCriticalRecordCount,
            lostNativeRecordCount: summary.lostNativeRecordCount,
            droppedFrameCount: summary.droppedFrameCount
        )
    }

    func requestCancellation() {
        let waiters: [CheckedContinuation<Void, Never>] = withLock {
            installationState = .invalidated
            let waiters = installationWaiters
            installationWaiters.removeAll(keepingCapacity: false)
            return waiters
        }
        _ = recorder.requestCancellation()
        waiters.forEach { $0.resume() }
    }

    func emitSessionEnd(reason: String) {
        let shouldEmit: Bool = withLock {
            guard !ending else { return false }
            ending = true
            return true
        }
        guard shouldEmit else { return }
        if reason == "manual_stop" {
            _ = observeEvent(
                .manualStop(ManualStopEvent(reason: reason)),
                occurredAt: runtimeClock.nowDate()
            )
        }
        _ = observeWorkoutPhase(.finished, occurredAt: runtimeClock.nowDate())
        _ = yieldEvent(
            .sessionLifecycle(
                SessionLifecycleEvent(previous: .running, current: .completed, reason: reason)
            ),
            occurredAt: runtimeClock.nowDate(),
            sourceID: nil
        )
    }

    func finish() async -> TelemetryFinishResult {
        // Product stop schedules this work detached. Only the recorder task waits so
        // staging loss/incomplete intent wins before persistence can finalize.
        await waitForInstallationResolution()
        return await recorder.finish(
            endedAt: runtimeClock.nowDate(),
            endedElapsed: elapsed()
        )
    }

    private func waitForInstallationResolution() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately: Bool = withLock {
                switch installationState {
                case .installing:
                    installationWaiters.append(continuation)
                    return false
                case .installed, .invalidated:
                    return true
                }
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func observeHeartRate(_ result: HeartRateNormalizationResult) -> TelemetryYieldDisposition {
        let exactEvent = observeHeartRateRuntime(.delivery(result))
        guard let scientific = result.canonicalObservation,
              scientific.beatsPerMinute >= 0,
              scientific.beatsPerMinute <= Int(UInt16.max) else {
            return exactEvent
        }

        let source = heartRateSource(scientific.source)
        emitSourceIfNeeded(source, observedAt: scientific.recordedAt)
        let measuredElapsed = scientific.measuredAt.map(elapsed(at:))
        let receivedElapsed = elapsed(at: scientific.receivedAt)
        let recordedElapsed = elapsed(at: scientific.recordedAt)
        let quality = heartRateQuality(scientific.quality)
        let observation = HeartRateObservation(
            recordID: RecordID(),
            observationID: ObservationID(rawValue: scientific.canonicalObservationID.rawValue),
            sessionID: descriptor.sessionID,
            source: source,
            beatsPerMinute: UInt16(scientific.beatsPerMinute),
            arrivalOrder: result.delivery.arrivalOrder,
            providerSequence: scientific.providerSequence,
            providerSampleIdentity: scientific.providerNativeIdentity.flatMap {
                ProviderNativeSampleIdentity(identifier: $0.identifier)
            },
            timestamp: ObservationTimestamp(
                measuredAt: scientific.measuredAt,
                receivedAt: scientific.receivedAt,
                recordedAt: scientific.recordedAt,
                measuredElapsed: measuredElapsed,
                receivedElapsed: receivedElapsed,
                recordedElapsed: recordedElapsed
            ),
            provenance: scientific.measuredAt == nil ? .reportedByProvider : .measuredByProvider,
            freshness: EvidenceFreshness(
                state: .fresh,
                evaluatedAt: RecordTimestamp(
                    recordedAt: scientific.recordedAt,
                    elapsed: recordedElapsed
                ),
                age: .zero,
                policyVersion: descriptor.versions.safetyPolicy
            ),
            quality: quality,
            controlUse: result.delivery.acceptedIntoLegacyControllerState
                ? .acceptedNotUsed
                : .rejected
        )
        let receipt = recorder.ingress.yield(.heartRate(observation))
        if receipt.disposition == .enqueued {
            withLock { latestHeartRate = observation }
        }
        return Self.moreSevere(exactEvent, receipt.disposition)
    }

    func observeHeartRateRuntime(
        _ evidence: HeartRateRuntimeEvidence
    ) -> TelemetryYieldDisposition {
        let occurredAt: Date
        let source: HeartRateProviderIdentity
        switch evidence {
        case let .delivery(result):
            occurredAt = result.delivery.recordedAt
            source = result.delivery.source
        case let .sourceLifecycle(lifecycle):
            occurredAt = lifecycle.occurredAt
            source = lifecycle.source
        case let .controlUse(controlUse):
            occurredAt = controlUse.occurredAt
            source = HeartRateProviderIdentity(
                kind: .legacyWatchWorkoutStream,
                stableLocalKey: descriptor.configuration.heartRateProviderStableLocalKey
            )
        }
        let sourceIdentity = heartRateSource(source)
        emitSourceIfNeeded(sourceIdentity, observedAt: occurredAt)
        return yieldEvent(
            .heartRateEvidence(evidence),
            occurredAt: occurredAt,
            sourceID: sourceIdentity.id
        )
    }

    func observeTreadmill(
        _ evidence: TreadmillTelemetryEvidence
    ) -> TelemetryYieldDisposition {
        let source = treadmillSource(for: evidence)
        if let source {
            emitSourceIfNeeded(source, observedAt: evidence.occurredAt)
        }
        let eventDisposition = yieldEvent(
            .treadmillEvidence(evidence),
            occurredAt: evidence.occurredAt,
            sourceID: source?.id
        )
        guard case let .observation(observed) = evidence,
              let native = observed.nativeSpeed,
              let source else {
            return eventDisposition
        }
        let measuredElapsed = observed.measuredAt.map(elapsed(at:))
        let receivedElapsed = elapsed(at: observed.receivedAt)
        let recordedElapsed = elapsed(at: observed.recordedAt)
        guard let observation = TreadmillObservation(
            recordID: RecordID(),
            sessionID: descriptor.sessionID,
            source: source,
            observedEvidence: observed,
            nativeUnit: Self.nativeUnit(native, protocolKind: observed.protocolKind),
            timestamp: ObservationTimestamp(
                measuredAt: observed.measuredAt,
                receivedAt: observed.receivedAt,
                recordedAt: observed.recordedAt,
                measuredElapsed: measuredElapsed,
                receivedElapsed: receivedElapsed,
                recordedElapsed: recordedElapsed
            ),
            freshness: EvidenceFreshness(
                state: observed.freshness == .freshAtReceipt ? .fresh : .unknown,
                evaluatedAt: RecordTimestamp(
                    recordedAt: observed.recordedAt,
                    elapsed: recordedElapsed
                ),
                age: .zero,
                policyVersion: descriptor.versions.safetyPolicy
            ),
            quality: treadmillQuality(observed.quality)
        ) else { return eventDisposition }
        let receipt = recorder.ingress.yield(.treadmill(observation))
        if receipt.disposition == .enqueued {
            withLock { latestTreadmill = observation }
        }
        return Self.moreSevere(eventDisposition, receipt.disposition)
    }

    func observeEvent(
        _ payload: WorkoutEventPayload,
        occurredAt: Date
    ) -> TelemetryYieldDisposition {
        yieldEvent(payload, occurredAt: occurredAt, sourceID: nil)
    }

    func observeWorkoutPhase(
        _ phase: WorkoutPhase,
        occurredAt: Date
    ) -> TelemetryYieldDisposition {
        let previous: WorkoutPhase? = withLock {
            let previous = currentWorkoutPhase
            if previous != phase {
                currentWorkoutPhase = phase
            }
            return previous
        }
        guard previous != phase else { return .coalescedFrame }
        return yieldEvent(
            .workoutPhase(WorkoutPhaseTransition(previous: previous, current: phase)),
            occurredAt: occurredAt,
            sourceID: nil
        )
    }

    func observeCurrentElapsedSecond() -> TelemetryYieldDisposition {
        let now = runtimeClock.nowDate()
        let currentElapsed = elapsed()
        let currentSecond = max(0, currentElapsed.microseconds / 1_000_000)
        let frame: CanonicalFrame? = withLock {
            guard !ending,
                  lastObservedFrameSecond != currentSecond else { return nil }
            let gap: CanonicalGapBoundary?
            if let firstMissingFrameSecond {
                gap = CanonicalGapBoundary(
                    missingSinceElapsedSecond: firstMissingFrameSecond,
                    kind: .recorderOutageOrLoss
                )
            } else if let lastObservedFrameSecond,
                      currentSecond > lastObservedFrameSecond + 1 {
                gap = CanonicalGapBoundary(
                    missingSinceElapsedSecond: lastObservedFrameSecond + 1,
                    kind: .runtimeSuspensionOrStall
                )
            } else if lastObservedFrameSecond == nil, currentSecond > 0 {
                gap = CanonicalGapBoundary(
                    missingSinceElapsedSecond: 0,
                    kind: .recorderOutageOrLoss
                )
            } else {
                gap = nil
            }
            lastObservedFrameSecond = currentSecond
            return CanonicalFrame(
                frameID: FrameID(),
                recordID: RecordID(),
                sessionID: descriptor.sessionID,
                canonicalElapsedSecond: currentSecond,
                materializedAt: RecordTimestamp(recordedAt: now, elapsed: currentElapsed),
                heartRateEvidence: latestHeartRate.map {
                    heartRateFrame($0, materializedAt: now, elapsed: currentElapsed)
                },
                treadmillEvidence: latestTreadmill.map {
                    treadmillFrame($0, materializedAt: now, elapsed: currentElapsed)
                },
                precedingGap: gap
            )
        }
        guard let frame else { return .coalescedFrame }
        let disposition = recorder.ingress.yield(.frame(frame)).disposition
        withLock {
            if disposition == .enqueued || disposition == .coalescedFrame {
                firstMissingFrameSecond = nil
            } else if firstMissingFrameSecond == nil {
                firstMissingFrameSecond = currentSecond
            }
        }
        return disposition
    }

    private func yieldEvent(
        _ payload: WorkoutEventPayload,
        occurredAt: Date,
        sourceID: SourceID?
    ) -> TelemetryYieldDisposition {
        let currentElapsed = elapsed()
        let event = WorkoutEvent(
            recordID: RecordID(),
            sessionID: descriptor.sessionID,
            timestamp: EventTimestamp(
                occurredAt: occurredAt,
                recordedAt: runtimeClock.nowDate(),
                occurredElapsed: elapsed(at: occurredAt),
                recordedElapsed: currentElapsed
            ),
            sourceID: sourceID,
            payload: EventPayloadEnvelope(schemaVersion: 1, payload: payload)
        )
        return recorder.ingress.yield(.event(event)).disposition
    }

    private func emitSourceIfNeeded(_ source: SignalSourceIdentity, observedAt: Date) {
        let shouldEmit: Bool = withLock {
            emittedSourceIDs.insert(source.id).inserted
        }
        guard shouldEmit else { return }
        _ = recorder.ingress.yield(
            .source(TelemetrySourceRecord(identity: source, firstSeen: observedAt, lastSeen: observedAt))
        )
    }

    private func heartRateSource(_ source: HeartRateProviderIdentity) -> SignalSourceIdentity {
        let stableKey = "hr:\(source.stableLocalKey)"
        return SignalSourceIdentity(
            id: SourceID(rawValue: TelemetryV2SessionDescriptor.deterministicUUID(key: stableKey)),
            providerKind: Self.providerKind(source.kind),
            stableLocalKey: stableKey
        )
    }

    private func treadmillSource(
        for evidence: TreadmillTelemetryEvidence
    ) -> SignalSourceIdentity? {
        guard let stableDevice = descriptor.configuration.treadmill.stableLocalIdentifier,
              !stableDevice.isEmpty else { return nil }
        let protocolKind = evidence.protocolKind.rawValue
        let stableKey = "treadmill:\(stableDevice):\(protocolKind)"
        return SignalSourceIdentity(
            id: SourceID(rawValue: TelemetryV2SessionDescriptor.deterministicUUID(key: stableKey)),
            providerKind: .treadmillProtocol,
            stableLocalKey: stableKey,
            knownDevice: KnownDeviceMetadata(
                manufacturer: nil,
                model: descriptor.configuration.treadmill.model,
                hardwareVersion: nil
            )
        )
    }

    private func heartRateFrame(
        _ observation: HeartRateObservation,
        materializedAt: Date,
        elapsed: ElapsedDuration
    ) -> HeartRateFrameEvidence {
        let age = Self.nonnegativeAge(from: observation.timestamp.recordedElapsed, to: elapsed)
        return HeartRateFrameEvidence(
            observationID: observation.observationID,
            recordID: observation.recordID,
            sourceID: observation.source.id,
            beatsPerMinute: observation.beatsPerMinute,
            measuredAt: observation.timestamp.measuredAt,
            receivedAt: observation.timestamp.receivedAt,
            evidenceElapsed: observation.timestamp.recordedElapsed,
            ageAtMaterialization: age,
            freshness: age.seconds <= descriptor.heartRateFreshnessLimitSeconds ? .fresh : .stale,
            provenance: observation.provenance
        )
    }

    private func treadmillFrame(
        _ observation: TreadmillObservation,
        materializedAt: Date,
        elapsed: ElapsedDuration
    ) -> TreadmillFrameEvidence {
        let age = Self.nonnegativeAge(from: observation.timestamp.recordedElapsed, to: elapsed)
        return TreadmillFrameEvidence(
            observationID: observation.observationID,
            recordID: observation.recordID,
            sourceID: observation.source.id,
            nativeSpeed: observation.nativeSpeed,
            factualSpeed: observation.factualSpeed,
            deviceState: observation.deviceState,
            measuredAt: observation.timestamp.measuredAt,
            receivedAt: observation.timestamp.receivedAt,
            evidenceElapsed: observation.timestamp.recordedElapsed,
            ageAtMaterialization: age,
            freshness: age.seconds <= descriptor.treadmillFreshnessLimitSeconds ? .fresh : .stale,
            provenance: observation.provenance
        )
    }

    private func elapsed() -> ElapsedDuration {
        Self.elapsedDuration(runtimeClock.now() - startedMonotonic)
    }

    private func elapsed(at date: Date) -> ElapsedDuration {
        let microseconds = date.timeIntervalSince(descriptor.startedAt) * 1_000_000
        guard microseconds.isFinite else { return .zero }
        return ElapsedDuration(
            microseconds: Int64(max(0, min(microseconds, Double(Int64.max))))
        )
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }

    private static func elapsedDuration(_ duration: Duration) -> ElapsedDuration {
        let components = duration.components
        let seconds = components.seconds.multipliedReportingOverflow(by: 1_000_000)
        guard !seconds.overflow else {
            return ElapsedDuration(microseconds: Int64.max)
        }
        let fractional = components.attoseconds / 1_000_000_000_000
        let total = seconds.partialValue.addingReportingOverflow(fractional)
        return ElapsedDuration(microseconds: total.overflow ? Int64.max : max(0, total.partialValue))
    }

    private static func nonnegativeAge(
        from evidence: ElapsedDuration,
        to current: ElapsedDuration
    ) -> ElapsedDuration {
        ElapsedDuration(microseconds: max(0, current.microseconds - evidence.microseconds))
    }

    private static func providerKind(_ kind: HeartRateProviderKind) -> SignalProviderKind {
        switch kind {
        case .legacyWatchWorkoutStream, .mirroredWatchWorkout: .watchMediated
        case .healthKitSelected: .healthKitSelected
        case .phoneHealthKit: .phoneLocal
        case .bluetooth: .bluetooth
        case .unknown: .unknown
        case let .other(value): .other(value)
        }
    }

    private static func nativeUnit(
        _ speed: ReportedTreadmillNativeSpeed,
        protocolKind: TreadmillProtocolKind
    ) -> TreadmillNativeSpeedUnit {
        switch speed.unit {
        case .kilometresPerHour: .kilometresPerHour
        case .milesPerHour: .milesPerHour
        case .controllerUnit:
            .controllerNative(code: "\(protocolKind.rawValue)-\(speed.resolution.rawValue)")
        }
    }

    private static func moreSevere(
        _ lhs: TelemetryYieldDisposition,
        _ rhs: TelemetryYieldDisposition
    ) -> TelemetryYieldDisposition {
        let order: [TelemetryYieldDisposition] = [
            .enqueued, .coalescedFrame, .droppedFrame, .lostNative, .lostCritical,
            .rejectedAfterFinish, .rejectedTerminal, .sequenceExhausted,
        ]
        return (order.firstIndex(of: lhs) ?? 0) >= (order.firstIndex(of: rhs) ?? 0)
            ? lhs
            : rhs
    }

    private func heartRateQuality(
        _ quality: HeartRateNormalizationQualityFlags
    ) -> QualityFlags {
        var mapped: QualityFlags = []
        if quality.contains(.missingMeasurementTime) { mapped.insert(.missingMeasurementTime) }
        if quality.contains(.duplicateProviderIdentity) { mapped.insert(.duplicateProviderIdentity) }
        if quality.contains(.duplicateProviderSequence) { mapped.insert(.duplicateProviderSequence) }
        if quality.contains(.providerSequenceOutOfOrder)
            || quality.contains(.sourceObservationOutOfArrivalOrder)
        {
            mapped.insert(.measurementOutOfArrivalOrder)
        }
        return mapped
    }

    private func treadmillQuality(_ quality: TreadmillObservationQualityFlags) -> QualityFlags {
        var mapped: QualityFlags = []
        if quality.contains(.missingMeasurementTime) { mapped.insert(.missingMeasurementTime) }
        if quality.contains(.missingSpeed) { mapped.insert(.unknownFreshness) }
        if quality.contains(.invalidNativeValue) || quality.contains(.invalidChecksum) {
            mapped.insert(.invalidNativeValue)
        }
        if quality.contains(.unitsNotRead) || quality.contains(.unitsUnknown)
            || quality.contains(.unitsStale) || quality.contains(.unitsMalformed)
            || quality.contains(.unitsInvalidChecksum) || quality.contains(.unitsEpochMismatch)
        {
            mapped.insert(.unknownFreshness)
        }
        return mapped
    }
}

private extension TreadmillTelemetryEvidence {
    var occurredAt: Date {
        switch self {
        case let .observation(evidence): evidence.recordedAt
        case let .unitsTruth(evidence): evidence.observedAt
        case let .decision(evidence): evidence.occurredAt
        case let .commandEnqueued(evidence): evidence.enqueuedAt
        case let .commandQueueDelay(evidence): evidence.sentAt
        case let .sendAttempt(evidence): evidence.sentAt
        case let .unassociatedWrite(evidence): evidence.sentAt
        case let .acknowledgement(evidence): evidence.recordedAt
        case let .writeResult(evidence): evidence.occurredAt
        case let .commandTimeout(evidence): evidence.occurredAt
        case let .commandFailed(evidence): evidence.occurredAt
        case let .commandCancelled(evidence): evidence.occurredAt
        case let .stopEvidence(evidence): evidence.evaluatedAt
        }
    }

    var protocolKind: TreadmillProtocolKind {
        switch self {
        case let .observation(evidence): return evidence.protocolKind
        case let .unitsTruth(evidence):
            switch evidence.truth {
            case .valid, .notRead, .unknown, .invalidChecksum, .malformed:
                return .walkingPad
            }
        case let .decision(evidence):
            _ = evidence
            return .unknown
        case let .commandEnqueued(evidence): return evidence.protocolKind
        case .commandQueueDelay: return .unknown
        case let .sendAttempt(evidence): return evidence.protocolKind
        case let .unassociatedWrite(evidence): return evidence.protocolKind
        case let .acknowledgement(evidence): return evidence.protocolKind
        case let .writeResult(evidence): return evidence.protocolKind
        case let .commandTimeout(evidence): return evidence.protocolKind
        case .commandFailed, .commandCancelled: return .unknown
        case let .stopEvidence(evidence): return evidence.protocolKind
        }
    }
}
