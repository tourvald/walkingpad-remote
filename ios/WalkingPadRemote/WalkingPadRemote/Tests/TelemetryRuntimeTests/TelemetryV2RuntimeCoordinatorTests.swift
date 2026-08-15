import CryptoKit
import Dispatch
import Foundation
import TelemetryDomain
import TelemetryRecorder
@testable import TelemetryRuntime
import XCTest

final class TelemetryV2RuntimeCoordinatorTests: XCTestCase {
    func testStoreConstructionAndImmediateStopNeverBlockOrResurrectSession() async throws {
        let persistence = RuntimePersistence()
        let factoryGate = DispatchSemaphore(value: 0)
        let factoryEntered = DispatchSemaphore(value: 0)
        let coordinator = TelemetryV2RuntimeCoordinator {
            factoryEntered.signal()
            factoryGate.wait()
            return persistence
        }

        let startBegan = ContinuousClock.now
        coordinator.beginSession(Self.descriptor())
        let startDuration = startBegan.duration(to: .now)
        XCTAssertLessThan(startDuration, .milliseconds(50))
        XCTAssertEqual(factoryEntered.wait(timeout: .now() + 1), .success)

        let stopBegan = ContinuousClock.now
        coordinator.endSession(reason: "immediate-stop")
        let stopDuration = stopBegan.duration(to: .now)
        XCTAssertLessThan(stopDuration, .milliseconds(50))

        factoryGate.signal()
        try await eventually { await persistence.unfinishedCallCount == 1 }
        let snapshot = await persistence.snapshot()
        XCTAssertEqual(snapshot.beginCallCount, 0)
        XCTAssertTrue(snapshot.headers.isEmpty)
        XCTAssertTrue(snapshot.finalizations.isEmpty)
        XCTAssertEqual(coordinator.status, .incomplete("ended-before-recorder-ready"))
    }

    func testDelayedHeaderAndFinalizationNeverBlockProductLifecycle() async throws {
        let persistence = RuntimePersistence(suspendBegin: true, suspendFinalize: true)
        let coordinator = TelemetryV2RuntimeCoordinator { persistence }
        coordinator.beginSession(Self.descriptor())
        try await eventually { await persistence.beginCallCount == 1 }
        try await eventually {
            if case .active = coordinator.status { return true }
            return false
        }

        let stopBegan = ContinuousClock.now
        coordinator.endSession(reason: "manual-stop")
        XCTAssertLessThan(stopBegan.duration(to: .now), .milliseconds(50))

        await persistence.resumeBegin()
        try await eventually { await persistence.finalizeCallCount == 1 }
        XCTAssertEqual(coordinator.status, .finishing)
        await persistence.resumeFinalize()
        try await eventually { await persistence.finalizations.count == 1 }
        try await eventually { coordinator.status == .idle }
    }

    func testObservedFramesAreUniqueAllowGapsAndNeverBackfill() async throws {
        let persistence = RuntimePersistence()
        let clock = ManualRuntimeClock(date: Date(timeIntervalSince1970: 10_000))
        let legacyID = UUID(uuidString: "10000000-0000-0000-0000-000000000030")!
        let coordinator = TelemetryV2RuntimeCoordinator(
            persistenceFactory: { persistence },
            runtimeClock: clock
        )
        let descriptor = Self.descriptor(
            legacySessionID: legacyID,
            startedAt: clock.nowDate()
        )
        coordinator.beginSession(descriptor)
        try await eventually { await persistence.headers.count == 1 }
        try await eventually {
            if case .active = coordinator.status { return true }
            return false
        }

        XCTAssertEqual(coordinator.observeCurrentElapsedSecond(), .enqueued)
        XCTAssertEqual(coordinator.observeCurrentElapsedSecond(), .coalescedFrame)
        clock.advance(by: .seconds(3))
        XCTAssertEqual(coordinator.observeCurrentElapsedSecond(), .enqueued)
        coordinator.endSession(reason: "complete")
        try await eventually { await persistence.finalizations.count == 1 }

        let snapshot = await persistence.snapshot()
        let header = try XCTUnwrap(snapshot.headers.first)
        XCTAssertEqual(header.sessionID.rawValue, legacyID)
        XCTAssertEqual(header.profileLocalIdentifier, descriptor.configuration.profileLocalIdentifier)
        XCTAssertEqual(header.workoutMode, descriptor.configuration.workoutMode)
        XCTAssertEqual(header.appContext, descriptor.appContext)
        XCTAssertEqual(header.versions, descriptor.versions)
        XCTAssertEqual(
            header.treadmill?.protocolName,
            descriptor.configuration.treadmill.protocolName
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                TelemetryV2ConfigurationInput.self,
                from: header.configuration.canonicalPayload
            ),
            descriptor.configuration
        )
        XCTAssertEqual(
            header.configuration.contentHash.lowercaseHexDigest,
            SHA256.hash(data: header.configuration.canonicalPayload)
                .map { String(format: "%02x", $0) }
                .joined()
        )
        let frames = snapshot.records.compactMap { record -> CanonicalFrame? in
            guard case let .frame(frame) = record else { return nil }
            return frame
        }
        XCTAssertEqual(frames.map(\.canonicalElapsedSecond), [0, 3])
        XCTAssertNil(frames[0].precedingGap)
        XCTAssertEqual(frames[1].precedingGap?.missingSinceElapsedSecond, 1)
        XCTAssertEqual(frames[1].precedingGap?.kind, .runtimeSuspensionOrStall)
        XCTAssertNil(frames[0].heartRateEvidence)
        XCTAssertNil(frames[0].treadmillEvidence)
        XCTAssertNil(frames[1].heartRateEvidence)
        XCTAssertNil(frames[1].treadmillEvidence)
    }

    func testSessionPhaseCooldownManualStopAndConnectionEventsPersistInOrder() async throws {
        let persistence = RuntimePersistence()
        let clock = ManualRuntimeClock(date: Date(timeIntervalSince1970: 15_000))
        let coordinator = TelemetryV2RuntimeCoordinator(
            persistenceFactory: { persistence },
            runtimeClock: clock
        )
        coordinator.beginSession(Self.descriptor(startedAt: clock.nowDate()))
        try await eventually {
            if case .active = coordinator.status { return true }
            return false
        }

        clock.advance(by: .seconds(1))
        XCTAssertEqual(
            coordinator.observeWorkoutPhase(.cooldown, occurredAt: clock.nowDate()),
            .enqueued
        )
        XCTAssertEqual(
            coordinator.observeEvent(
                .cooldown(CooldownEvent(lifecycle: .started, targetHeartRate: 100)),
                occurredAt: clock.nowDate()
            ),
            .enqueued
        )
        XCTAssertEqual(
            coordinator.observeEvent(
                .connectionTransition(
                    ConnectionTransition(
                        previous: .connected,
                        current: .disconnected,
                        reason: "disconnect_user"
                    )
                ),
                occurredAt: clock.nowDate()
            ),
            .enqueued
        )
        coordinator.endSession(reason: "manual_stop")
        try await eventually { await persistence.finalizations.count == 1 }

        let events = await persistence.snapshot().records.compactMap { record -> WorkoutEvent? in
            guard case let .event(event) = record else { return nil }
            return event
        }
        XCTAssertEqual(
            events.map(\.kind),
            [
                .sessionLifecycle,
                .workoutPhase,
                .workoutPhase,
                .cooldown,
                .connectionTransition,
                .manualStop,
                .workoutPhase,
                .sessionLifecycle,
            ]
        )
        let phases = events.compactMap { event -> WorkoutPhaseTransition? in
            guard case let .workoutPhase(transition) = event.payload.payload else { return nil }
            return transition
        }
        XCTAssertEqual(phases.map(\.current), [.main, .cooldown, .finished])
    }

    func testPendingUnknownCausalityReplaysWithoutInventingIdentifiers() async throws {
        let persistence = RuntimePersistence()
        let factoryGate = DispatchSemaphore(value: 0)
        let coordinator = TelemetryV2RuntimeCoordinator {
            factoryGate.wait()
            return persistence
        }
        let epoch = TreadmillConnectionEpoch(rawValue: UUID())
        let date = Date(timeIntervalSince1970: 20_000)
        let evidence: [TreadmillTelemetryEvidence] = [
            .acknowledgement(
                .unresolved(
                    protocolKind: .walkingPad,
                    connectionEpoch: epoch,
                    receivedAt: date,
                    recordedAt: date
                )
            ),
            .commandTimeout(
                LegacyCommandTimeoutObservation(
                    protocolKind: .walkingPad,
                    connectionEpoch: epoch,
                    occurredAt: date
                )
            ),
            .writeResult(
                LegacyWriteResultObservation(
                    protocolKind: .walkingPad,
                    connectionEpoch: epoch,
                    occurredAt: date,
                    status: .succeeded
                )
            ),
        ]
        coordinator.beginSession(Self.descriptor())
        for item in evidence {
            XCTAssertEqual(coordinator.observeTreadmillEvidence(item), .accepted)
        }
        factoryGate.signal()
        try await eventually { await persistence.headers.count == 1 }
        try await eventually {
            if case .active = coordinator.status { return true }
            return false
        }
        coordinator.endSession(reason: "complete")
        try await eventually { await persistence.finalizations.count == 1 }

        let stored = await persistence.snapshot().records.compactMap { record -> WorkoutEvent? in
            guard case let .event(event) = record,
                  event.kind == .treadmillEvidence else { return nil }
            return event
        }
        XCTAssertEqual(stored.count, 3)
        for event in stored {
            XCTAssertNil(event.decisionID)
            XCTAssertNil(event.commandID)
            XCTAssertNil(event.attemptID)
            let encoded = try JSONEncoder().encode(event)
            let replayed = try JSONDecoder().decode(WorkoutEvent.self, from: encoded)
            XCTAssertNil(replayed.decisionID)
            XCTAssertNil(replayed.commandID)
            XCTAssertNil(replayed.attemptID)
        }
    }

    func testPendingEvidenceOverflowDurablyFailsOnlyTelemetrySession() async throws {
        let persistence = RuntimePersistence()
        let factoryGate = DispatchSemaphore(value: 0)
        let coordinator = TelemetryV2RuntimeCoordinator {
            factoryGate.wait()
            return persistence
        }
        let evidence = TreadmillTelemetryEvidence.unassociatedWrite(
            UnassociatedLegacyWriteObservation(
                protocolKind: .walkingPad,
                connectionEpoch: TreadmillConnectionEpoch(rawValue: UUID()),
                sentAt: Date(),
                writeType: .withoutResponse
            )
        )

        coordinator.beginSession(Self.descriptor())
        for _ in 0..<256 {
            XCTAssertEqual(coordinator.observeTreadmillEvidence(evidence), .accepted)
        }
        XCTAssertEqual(coordinator.observeTreadmillEvidence(evidence), .degraded)

        factoryGate.signal()
        try await eventually { await persistence.finalizations.count == 1 }
        let snapshot = await persistence.snapshot()
        let finalization = try XCTUnwrap(snapshot.finalizations.first)
        XCTAssertEqual(finalization.lifecycleState, .incomplete)
        XCTAssertEqual(finalization.incompleteReason, "pre-recorder-staging-overflow")
        XCTAssertFalse(finalization.recorderHealth.isComplete)
        if case .incomplete("pre-recorder-staging-overflow") = coordinator.status {
            // The telemetry failure is visible and does not require product-path coordination.
        } else {
            XCTFail("Expected durable telemetry-only incomplete status")
        }
    }

    func testStoreAndFinalizationFailuresRemainTelemetryOnly() async throws {
        enum FactoryFailure: Error { case unavailable }
        let failedFactoryCoordinator = TelemetryV2RuntimeCoordinator {
            throw FactoryFailure.unavailable
        }
        let began = ContinuousClock.now
        failedFactoryCoordinator.beginSession(Self.descriptor())
        XCTAssertLessThan(began.duration(to: .now), .milliseconds(50))
        try await eventually {
            if case .unavailable = failedFactoryCoordinator.status { return true }
            return false
        }
        XCTAssertEqual(
            failedFactoryCoordinator.observeTreadmillEvidence(
                .unassociatedWrite(
                    UnassociatedLegacyWriteObservation(
                        protocolKind: .walkingPad,
                        connectionEpoch: TreadmillConnectionEpoch(rawValue: UUID()),
                        sentAt: Date(),
                        writeType: .withoutResponse
                    )
                )
            ),
            .unavailable
        )

        let persistence = RuntimePersistence(finalizeFailure: true)
        let finalizeFailureCoordinator = TelemetryV2RuntimeCoordinator { persistence }
        finalizeFailureCoordinator.beginSession(Self.descriptor())
        try await eventually { await persistence.headers.count == 1 }
        try await eventually {
            if case .active = finalizeFailureCoordinator.status { return true }
            return false
        }
        let ended = ContinuousClock.now
        finalizeFailureCoordinator.endSession(reason: "manual-stop")
        XCTAssertLessThan(ended.duration(to: .now), .milliseconds(50))
        try await eventually {
            if case .incomplete = finalizeFailureCoordinator.status { return true }
            return false
        }
    }

    private static func descriptor(
        legacySessionID: UUID? = UUID(uuidString: "10000000-0000-0000-0000-000000000030"),
        startedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> TelemetryV2SessionDescriptor {
        TelemetryV2SessionDescriptor(
            sessionID: TelemetryV2SessionDescriptor.sessionID(
                deterministicallyLinkedTo: legacySessionID
            ),
            deterministicLegacySessionID: legacySessionID,
            startedAt: startedAt,
            appContext: AppRuntimeContext(
                appVersion: "test",
                buildNumber: "30",
                operatingSystemVersion: "test",
                deviceModel: "test"
            ),
            configuration: TelemetryV2ConfigurationInput(
                profileLocalIdentifier: "profile-30",
                workoutMode: .heartRateControlled,
                targetHeartRate: 120,
                durationMinutes: 30,
                decisionIntervalSeconds: 10,
                adaptiveStepEnabled: true,
                maximumStepKilometresPerHour: 0.4,
                heartRateZones: [100, 120, 140, 160],
                cooldownTargetHeartRate: 100,
                cooldownMinimumSpeedKilometresPerHour: 1,
                cooldownMaximumMinutes: 5,
                heartRateProviderKind: "legacyWatchWorkoutStream",
                heartRateProviderStableLocalKey: "watch-session",
                treadmill: TelemetryV2TreadmillContext(
                    stableLocalIdentifier: "treadmill-30",
                    model: "test",
                    protocolName: "walkingPad",
                    protocolVersion: nil,
                    minimumSpeedKilometresPerHour: 0.5,
                    maximumSpeedKilometresPerHour: 6,
                    speedIncrementKilometresPerHour: 0.1
                )
            ),
            versions: RuntimeVersionContext(
                telemetrySchema: TelemetrySchemaVersion(rawValue: "1"),
                algorithm: AlgorithmVersion(rawValue: "legacy"),
                safetyPolicy: SafetyPolicyVersion(rawValue: "test"),
                workoutProtocol: WorkoutProtocolVersion(rawValue: "test")
            ),
            heartRateFreshnessLimitSeconds: 5,
            treadmillFreshnessLimitSeconds: 30
        )
    }
}

private final class ManualRuntimeClock: TelemetryV2RuntimeClock, @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    private var elapsed: Duration = .zero

    init(date: Date) {
        self.date = date
    }

    func nowDate() -> Date {
        lock.withLock { date }
    }

    func now() -> Duration {
        lock.withLock { elapsed }
    }

    func advance(by duration: Duration) {
        lock.withLock {
            elapsed += duration
            date = date.addingTimeInterval(duration.seconds)
        }
    }
}

private actor RuntimePersistence: TelemetryRecorderPersistence {
    struct Snapshot: Sendable {
        let headers: [WorkoutSessionRecord]
        let records: [TelemetryPersistenceRecord]
        let finalizations: [TelemetrySessionFinalization]
        let beginCallCount: Int
    }

    private(set) var headers: [WorkoutSessionRecord] = []
    private(set) var records: [TelemetryPersistenceRecord] = []
    private(set) var finalizations: [TelemetrySessionFinalization] = []
    private(set) var beginCallCount = 0
    private(set) var finalizeCallCount = 0
    private(set) var unfinishedCallCount = 0
    private let suspendBegin: Bool
    private let suspendFinalize: Bool
    private let finalizeFailure: Bool
    private var beginContinuation: CheckedContinuation<Void, Never>?
    private var finalizeContinuation: CheckedContinuation<Void, Never>?

    init(
        suspendBegin: Bool = false,
        suspendFinalize: Bool = false,
        finalizeFailure: Bool = false
    ) {
        self.suspendBegin = suspendBegin
        self.suspendFinalize = suspendFinalize
        self.finalizeFailure = finalizeFailure
    }

    func beginSession(_ header: WorkoutSessionRecord) async throws {
        beginCallCount += 1
        if suspendBegin {
            await withCheckedContinuation { beginContinuation = $0 }
        }
        headers.append(header)
    }

    func persistBatch(_ records: [SequencedTelemetryRecord]) async throws {
        self.records.append(contentsOf: records.map(\.record))
    }

    func finalizeSession(_ finalization: TelemetrySessionFinalization) async throws {
        finalizeCallCount += 1
        if suspendFinalize {
            await withCheckedContinuation { finalizeContinuation = $0 }
        }
        if finalizeFailure {
            throw TelemetryPersistenceOperationError.terminal(code: "test-finalize")
        }
        finalizations.append(finalization)
    }

    func unfinishedSessions() async throws -> [WorkoutSessionRecord] {
        unfinishedCallCount += 1
        return []
    }

    func resumeBegin() {
        beginContinuation?.resume()
        beginContinuation = nil
    }

    func resumeFinalize() {
        finalizeContinuation?.resume()
        finalizeContinuation = nil
    }

    func snapshot() -> Snapshot {
        Snapshot(
            headers: headers,
            records: records,
            finalizations: finalizations,
            beginCallCount: beginCallCount
        )
    }
}

private enum EventuallyFailure: Error {
    case timedOut
}

private func eventually(
    attempts: Int = 10_000,
    _ predicate: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0..<attempts {
        if await predicate() { return }
        await Task.yield()
    }
    throw EventuallyFailure.timedOut
}

private extension Duration {
    var seconds: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
