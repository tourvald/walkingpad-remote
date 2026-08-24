import Foundation

struct TestRunHeartRateDiagnosticProviderAttempt: Equatable {
    let runID: UUID
    let generation: UInt64
    let providerIdentity: ObjectIdentifier
}

struct TestRunHeartRateDiagnosticProviderOwnership {
    private(set) var currentAttempt: TestRunHeartRateDiagnosticProviderAttempt?

    mutating func bind(_ attempt: TestRunHeartRateDiagnosticProviderAttempt) {
        currentAttempt = attempt
    }

    func accepts(
        _ attempt: TestRunHeartRateDiagnosticProviderAttempt,
        provider: AnyObject
    ) -> Bool {
        currentAttempt == attempt
            && attempt.providerIdentity == ObjectIdentifier(provider)
    }

    mutating func release(_ attempt: TestRunHeartRateDiagnosticProviderAttempt) -> Bool {
        guard currentAttempt == attempt else { return false }
        currentAttempt = nil
        return true
    }
}

struct TestRunHeartRateDiagnosticService {
    static let firstQualifyingSampleTimeoutSeconds: TimeInterval = 30

    enum TerminalReason: String, Equatable {
        case testRunCompleted = "test_run_completed"
        case userRequested = "user_requested"
        case appInactive = "app_inactive"
        case connectionInvalidated = "connection_invalidated"
        case providerFailure = "provider_failure"
        case timeout = "first_qualifying_sample_timeout"
    }

    enum Phase: String, Equatable {
        case idle
        case preparing
        case collecting
        case completed
        case cancelled
        case failed
        case unavailable
    }

    enum RejectionReason: String, CaseIterable, Hashable {
        case sourceIsNotNativeHealthKit = "source_not_native_healthkit"
        case invalidBPM = "invalid_bpm"
        case receivedBeforeCollection = "received_before_collection"
        case measuredBeforeCollection = "measured_before_collection"
        case stale = "stale"
    }

    struct Sample: Equatable {
        let qualificationObservation: NativeHeartRatePreflightEngine.Observation
        let sourceCallbackObservedAt: Date?
        let providerNativeIdentity: String?
    }

    struct Snapshot: Equatable {
        let runID: UUID?
        let phase: Phase
        let providerState: String
        let startedAt: Date?
        let collectionStartedAt: Date?
        let firstSampleReceivedAt: Date?
        let latestMeasuredAt: Date?
        let latestSourceCallbackObservedAt: Date?
        let latestReceivedAt: Date?
        let latestBPM: Int?
        let latestSource: String?
        let latestProviderNativeIdentity: String?
        let latestAgeSeconds: TimeInterval?
        let latestDisplayFresh: Bool
        let latestStartQualified: Bool
        let receivedSampleCount: Int
        let displayFreshSampleCount: Int
        let qualifyingSampleCount: Int
        let rejectedSampleCount: Int
        let rejectionCountsByReason: [RejectionReason: Int]
        let firstQualifyingSampleLatencySeconds: TimeInterval?
        let latestRejectionReason: RejectionReason?
        let terminalReason: TerminalReason?
        let detail: String?

        static let idle = Snapshot(
            runID: nil,
            phase: .idle,
            providerState: "idle",
            startedAt: nil,
            collectionStartedAt: nil,
            firstSampleReceivedAt: nil,
            latestMeasuredAt: nil,
            latestSourceCallbackObservedAt: nil,
            latestReceivedAt: nil,
            latestBPM: nil,
            latestSource: nil,
            latestProviderNativeIdentity: nil,
            latestAgeSeconds: nil,
            latestDisplayFresh: false,
            latestStartQualified: false,
            receivedSampleCount: 0,
            displayFreshSampleCount: 0,
            qualifyingSampleCount: 0,
            rejectedSampleCount: 0,
            rejectionCountsByReason: [:],
            firstQualifyingSampleLatencySeconds: nil,
            latestRejectionReason: nil,
            terminalReason: nil,
            detail: nil
        )
    }

    private var runID: UUID?
    private var phase: Phase = .idle
    private var providerState = "idle"
    private var startedAt: Date?
    private var collectionStartedAt: Date?
    private var firstSampleReceivedAt: Date?
    private var latestSample: Sample?
    private var latestStartQualified = false
    private var receivedSampleCount = 0
    private var displayFreshSampleCount = 0
    private var qualifyingSampleCount = 0
    private var rejectedSampleCount = 0
    private var rejectionCountsByReason: [RejectionReason: Int] = [:]
    private var firstQualifyingSampleLatencySeconds: TimeInterval?
    private var latestRejectionReason: RejectionReason?
    private var terminalReason: TerminalReason?
    private var detail: String?

    var isActive: Bool {
        phase == .preparing || phase == .collecting
    }

    mutating func start(runID: UUID, at date: Date) {
        self.runID = runID
        phase = .preparing
        providerState = "authorizing_or_preparing"
        startedAt = date
        collectionStartedAt = nil
        firstSampleReceivedAt = nil
        latestSample = nil
        latestStartQualified = false
        receivedSampleCount = 0
        displayFreshSampleCount = 0
        qualifyingSampleCount = 0
        rejectedSampleCount = 0
        rejectionCountsByReason = [:]
        firstQualifyingSampleLatencySeconds = nil
        latestRejectionReason = nil
        terminalReason = nil
        detail = nil
    }

    mutating func markUnavailable(runID: UUID, at date: Date, detail: String) {
        start(runID: runID, at: date)
        phase = .unavailable
        providerState = "unavailable"
        self.detail = detail
    }

    mutating func updateProviderState(_ state: String, expectedRunID: UUID) {
        guard runID == expectedRunID, isActive else { return }
        providerState = state
    }

    mutating func collectionStarted(expectedRunID: UUID, at date: Date) {
        guard runID == expectedRunID, phase == .preparing else { return }
        phase = .collecting
        providerState = "collecting"
        collectionStartedAt = date
    }

    mutating func receive(
        _ sample: Sample,
        expectedRunID: UUID,
        now: Date,
        freshnessLimit: TimeInterval
    ) {
        guard runID == expectedRunID,
              phase == .collecting,
              let collectionStartedAt else { return }

        let observation = sample.qualificationObservation
        receivedSampleCount += 1
        if firstSampleReceivedAt == nil {
            firstSampleReceivedAt = observation.receivedAt
        }
        latestSample = sample
        if isDisplayFresh(
            observation,
            now: now,
            freshnessLimit: freshnessLimit
        ) {
            displayFreshSampleCount += 1
        }
        let qualifies = observation.isQualifying(
            collectionStartedAt: collectionStartedAt,
            now: now,
            freshnessLimit: freshnessLimit
        )
        latestStartQualified = qualifies
        if qualifies {
            qualifyingSampleCount += 1
            if firstQualifyingSampleLatencySeconds == nil {
                firstQualifyingSampleLatencySeconds = max(
                    0,
                    observation.receivedAt.timeIntervalSince(collectionStartedAt)
                )
            }
            latestRejectionReason = nil
        } else {
            rejectedSampleCount += 1
            let reason = rejectionReason(
                for: observation,
                collectionStartedAt: collectionStartedAt,
                now: now,
                freshnessLimit: freshnessLimit
            )
            rejectionCountsByReason[reason, default: 0] += 1
            latestRejectionReason = reason
        }
    }

    mutating func timeoutIfNeeded(expectedRunID: UUID, now: Date) -> Bool {
        guard runID == expectedRunID,
              isActive,
              qualifyingSampleCount == 0,
              let startedAt,
              now.timeIntervalSince(startedAt) >= Self.firstQualifyingSampleTimeoutSeconds else {
            return false
        }
        finish(
            expectedRunID: expectedRunID,
            reason: .timeout,
            detail: "No qualifying native HealthKit sample within 30 seconds"
        )
        return true
    }

    mutating func finish(
        expectedRunID: UUID,
        reason: TerminalReason,
        detail: String? = nil
    ) {
        guard runID == expectedRunID, isActive else { return }
        terminalReason = reason
        self.detail = detail
        providerState = "discarding"
        switch reason {
        case .testRunCompleted:
            phase = .completed
        case .providerFailure, .timeout:
            phase = .failed
        case .userRequested, .appInactive, .connectionInvalidated:
            phase = .cancelled
        }
    }

    mutating func providerDiscarded(expectedRunID: UUID) {
        guard runID == expectedRunID, !isActive else { return }
        providerState = "idle_discarded"
    }

    func snapshot(now: Date, freshnessLimit: TimeInterval) -> Snapshot {
        let latestObservation = latestSample?.qualificationObservation
        let factualDate = latestObservation.map { $0.measuredAt ?? $0.receivedAt }
        let age = factualDate.map { max(0, now.timeIntervalSince($0)) }
        let displayFresh = latestObservation.map {
            isDisplayFresh($0, now: now, freshnessLimit: freshnessLimit)
        } ?? false
        return Snapshot(
            runID: runID,
            phase: phase,
            providerState: providerState,
            startedAt: startedAt,
            collectionStartedAt: collectionStartedAt,
            firstSampleReceivedAt: firstSampleReceivedAt,
            latestMeasuredAt: latestObservation?.measuredAt,
            latestSourceCallbackObservedAt: latestSample?.sourceCallbackObservedAt,
            latestReceivedAt: latestObservation?.receivedAt,
            latestBPM: latestObservation?.beatsPerMinute,
            latestSource: latestObservation.map { observation in
                switch observation.source {
                case .nativeHealthKit: return "native_healthkit"
                case .legacyWatch: return "legacy_watch"
                }
            },
            latestProviderNativeIdentity: latestSample?.providerNativeIdentity,
            latestAgeSeconds: age,
            latestDisplayFresh: displayFresh,
            latestStartQualified: latestStartQualified,
            receivedSampleCount: receivedSampleCount,
            displayFreshSampleCount: displayFreshSampleCount,
            qualifyingSampleCount: qualifyingSampleCount,
            rejectedSampleCount: rejectedSampleCount,
            rejectionCountsByReason: rejectionCountsByReason,
            firstQualifyingSampleLatencySeconds: firstQualifyingSampleLatencySeconds,
            latestRejectionReason: latestRejectionReason,
            terminalReason: terminalReason,
            detail: detail
        )
    }

    private func isDisplayFresh(
        _ observation: NativeHeartRatePreflightEngine.Observation,
        now: Date,
        freshnessLimit: TimeInterval
    ) -> Bool {
        let factualDate = observation.measuredAt ?? observation.receivedAt
        let ageSeconds = max(0, Int(now.timeIntervalSince(factualDate)))
        return HRDomainService.heartRateStreamIsActive(
            beatsPerMinute: observation.beatsPerMinute,
            hasLastReceivedAt: true,
            ageSeconds: ageSeconds,
            staleThresholdSeconds: Int(freshnessLimit)
        )
    }

    private func rejectionReason(
        for observation: NativeHeartRatePreflightEngine.Observation,
        collectionStartedAt: Date,
        now: Date,
        freshnessLimit: TimeInterval
    ) -> RejectionReason {
        guard observation.source == .nativeHealthKit else {
            return .sourceIsNotNativeHealthKit
        }
        guard observation.beatsPerMinute > 0 else { return .invalidBPM }
        guard observation.receivedAt >= collectionStartedAt else {
            return .receivedBeforeCollection
        }
        let factualDate = observation.measuredAt ?? observation.receivedAt
        guard factualDate >= collectionStartedAt else {
            return .measuredBeforeCollection
        }
        if now.timeIntervalSince(factualDate) > freshnessLimit {
            return .stale
        }
        return .stale
    }
}
