import Dispatch
import Foundation
import TelemetryDomain
import TelemetryRecorder
@testable import TelemetryRuntime
import XCTest

final class StoreReadinessTests: XCTestCase {
    func testPreparedCapabilitiesAreImmediateAndPreparationIsIdempotent() async throws {
        let persistence = ReadinessPersistence()
        let deadlines = ReadinessCounter()
        let factories = ReadinessCounter()
        let coordinator = TelemetryV2RuntimeCoordinator(
            persistenceFactory: { factories.increment(); return persistence },
            installationDidPublishForTesting: { _ in },
            storeReadinessTimeout: { deadlines.increment(); try await Task.sleep(for: .seconds(3600)) }
        )
        try await read(coordinator)
        let before = deadlines.value
        for _ in 0..<5 {
            coordinator.prepareStoreAndRecover()
            try await read(coordinator)
            try await coordinator.associateHealthKitWorkout(sessionID: SessionID(), workoutIdentifier: UUID())
        }
        XCTAssertEqual(factories.value, 1)
        XCTAssertEqual(deadlines.value, before)
        XCTAssertEqual(coordinator.storeReadinessWaiterCount, 0)
        XCTAssertEqual(coordinator.status, .idle)
    }

    func testDelayedPreparationResumesAllReadAndLinkageWaitersOnce() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let persistence = ReadinessPersistence()
        let registered = expectation(description: "Five one-shot deadlines registered")
        registered.expectedFulfillmentCount = 5
        let coordinator = TelemetryV2RuntimeCoordinator(
            persistenceFactory: { gate.wait(); return persistence },
            installationDidPublishForTesting: { _ in },
            storeReadinessTimeout: { registered.fulfill(); try await Task.sleep(for: .seconds(3600)) }
        )
        let tasks = requests(coordinator, count: 5)
        await fulfillment(of: [registered], timeout: 5)
        XCTAssertEqual(coordinator.storeReadinessWaiterCount, 5)
        gate.signal()
        for task in tasks { try await task.value }
        let counts = await persistence.counts()
        XCTAssertEqual(counts.reads, 3)
        XCTAssertEqual(counts.links, 2)
        XCTAssertEqual(coordinator.storeReadinessWaiterCount, 0)
        XCTAssertEqual(coordinator.status, .idle)
    }

    func testPreparationFailureFailsAllConcurrentWaiters() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let registered = expectation(description: "Waiters registered before factory fails")
        registered.expectedFulfillmentCount = 4
        let coordinator = TelemetryV2RuntimeCoordinator(
            persistenceFactory: { gate.wait(); throw ReadinessFailure.factory },
            installationDidPublishForTesting: { _ in },
            storeReadinessTimeout: { registered.fulfill(); try await Task.sleep(for: .seconds(3600)) }
        )
        let tasks = requests(coordinator, count: 4)
        await fulfillment(of: [registered], timeout: 5)
        gate.signal()
        for task in tasks {
            do { try await task.value; XCTFail("Unavailable store must fail closed") }
            catch let error as TelemetryWorkoutReadError {
                guard case let .unavailable(reason) = error else { return XCTFail("Wrong failure") }
                XCTAssertTrue(reason.hasPrefix("store-or-recovery-failed:"))
            }
        }
        XCTAssertEqual(coordinator.storeReadinessWaiterCount, 0)
        guard case .unavailable = coordinator.status else { return XCTFail("Missing unavailable status") }
    }

    func testCancellationRemovesOnlyItsWaiterAndOtherCallerStillSucceeds() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let persistence = ReadinessPersistence()
        let registered = expectation(description: "Two waiters registered")
        registered.expectedFulfillmentCount = 2
        let coordinator = TelemetryV2RuntimeCoordinator(
            persistenceFactory: { gate.wait(); return persistence },
            installationDidPublishForTesting: { _ in },
            storeReadinessTimeout: { registered.fulfill(); try await Task.sleep(for: .seconds(3600)) }
        )
        let tasks = requests(coordinator, count: 2)
        await fulfillment(of: [registered], timeout: 5)
        tasks[0].cancel()
        do { try await tasks[0].value; XCTFail("Cancellation must propagate") }
        catch is CancellationError { }
        XCTAssertEqual(coordinator.storeReadinessWaiterCount, 1)
        gate.signal()
        try await tasks[1].value
        let counts = await persistence.counts()
        XCTAssertEqual(counts.reads, 0)
        XCTAssertEqual(counts.links, 1)
        XCTAssertEqual(coordinator.storeReadinessWaiterCount, 0)
    }

    func testDeadlineExpiryIsBoundedAndDoesNotChangePreparationOrRecovery() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let deadlines = ReadinessCounter()
        let coordinator = TelemetryV2RuntimeCoordinator(
            persistenceFactory: { gate.wait(); return ReadinessPersistence() },
            installationDidPublishForTesting: { _ in },
            storeReadinessTimeout: {
                deadlines.increment()
                if deadlines.value > 2 { try await Task.sleep(for: .seconds(3600)) }
            }
        )
        for task in requests(coordinator, count: 2) {
            do { try await task.value; XCTFail("Unresolved readiness must expire") }
            catch let error as TelemetryWorkoutReadError {
                XCTAssertEqual(error, .unavailable("telemetry-v2-store-prepare-timeout"))
            }
        }
        XCTAssertEqual(coordinator.storeReadinessWaiterCount, 0)
        XCTAssertEqual(coordinator.status, .preparing)
        gate.signal()
        try await read(coordinator)
        XCTAssertEqual(coordinator.status, .idle)
    }

    func testAlreadyCancelledCallerNeverInstallsWaiterOrReads() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let persistence = ReadinessPersistence()
        let coordinator = TelemetryV2RuntimeCoordinator { gate.wait(); return persistence }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await self.read(coordinator)
        }
        do { try await task.value; XCTFail("Already cancelled operation must fail") }
        catch is CancellationError { }
        XCTAssertEqual(coordinator.storeReadinessWaiterCount, 0)
        let counts = await persistence.counts()
        XCTAssertEqual(counts.reads, 0)
    }

    func testDefaultFiveSecondDeadlineCannotSucceedWithoutInstalledCapabilities() async throws {
        let coordinator = TelemetryV2RuntimeCoordinator { RecorderOnlyReadinessPersistence() }
        let clock = ContinuousClock()
        let start = clock.now
        for task in requests(coordinator, count: 2) {
            do { try await task.value; XCTFail("Prepared store without capability is not readiness") }
            catch let error as TelemetryWorkoutReadError {
                XCTAssertEqual(error, .unavailable("telemetry-v2-store-prepare-timeout"))
            }
        }
        XCTAssertGreaterThanOrEqual(start.duration(to: clock.now), .seconds(5))
        XCTAssertEqual(coordinator.storeReadinessWaiterCount, 0)
        XCTAssertEqual(coordinator.status, .idle)
    }

    private func requests(_ coordinator: TelemetryV2RuntimeCoordinator, count: Int) -> [Task<Void, Error>] {
        (0..<count).map { index in Task {
            if index.isMultiple(of: 2) { try await self.read(coordinator) }
            else { try await coordinator.associateHealthKitWorkout(sessionID: SessionID(), workoutIdentifier: UUID()) }
        } }
    }

    private func read(_ coordinator: TelemetryV2RuntimeCoordinator) async throws {
        let page = try await coordinator.fetchWorkoutHistoryPage(
            filter: WorkoutReadFilter(profileScope: .exact("readiness-test")), after: nil, limit: 1
        )
        XCTAssertTrue(page.items.isEmpty)
    }
}

private enum ReadinessFailure: Error { case factory }

private struct RecorderOnlyReadinessPersistence: TelemetryRecorderPersistence {
    func beginSession(_ header: WorkoutSessionRecord) async throws { }
    func persistBatch(_ records: [SequencedTelemetryRecord]) async throws { }
    func finalizeSession(_ finalization: TelemetrySessionFinalization) async throws { }
    func unfinishedSessions() async throws -> [WorkoutSessionRecord] { [] }
}

private final class ReadinessCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

private actor ReadinessPersistence: TelemetryRecorderPersistence, TelemetryWorkoutReadCapability,
    TelemetryHealthKitWorkoutLinkageCapability
{
    private var reads = 0
    private var links = 0
    func counts() -> (reads: Int, links: Int) { (reads, links) }
    func beginSession(_ header: WorkoutSessionRecord) async throws { }
    func persistBatch(_ records: [SequencedTelemetryRecord]) async throws { }
    func finalizeSession(_ finalization: TelemetrySessionFinalization) async throws { }
    func unfinishedSessions() async throws -> [WorkoutSessionRecord] { [] }
    func fetchWorkoutHistoryPage(filter: WorkoutReadFilter, after cursor: WorkoutHistoryCursor?, limit: Int) async throws -> WorkoutHistoryPage {
        reads += 1
        return WorkoutHistoryPage(items: [], nextCursor: nil,
            diagnostics: WorkoutReadDiagnostics(storeFetchCount: 0, maximumStoreFetchLimit: 0, hydratedTimeSeriesRecordCount: 0, exactNativeDuplicateCount: 0))
    }
    func fetchWorkoutStatistics(filter: WorkoutReadFilter, batchSize: Int) async throws -> WorkoutStatisticsProjection { throw ReadinessFailure.factory }
    func exportWorkouts(_ request: WorkoutExportRequest) async throws -> WorkoutExportArtifact { throw ReadinessFailure.factory }
    func exportWorkoutAnalysis(_ request: WorkoutAnalysisExportRequest) async throws -> WorkoutAnalysisExportArtifact { throw ReadinessFailure.factory }
    func associateHealthKitWorkout(sessionID: SessionID, workoutIdentifier: UUID) async throws { links += 1 }
}
