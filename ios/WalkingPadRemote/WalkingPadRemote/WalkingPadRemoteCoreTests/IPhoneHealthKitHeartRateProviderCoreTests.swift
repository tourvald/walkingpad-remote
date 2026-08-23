import Foundation
import TelemetryDomain
import XCTest
@testable import WalkingPadCoreLogic

@MainActor
final class IPhoneHealthKitHeartRateProviderCoreTests: XCTestCase {
    func testPrepareOwnsOneWorkoutWithoutStartingCollection() async throws {
        let (provider, driver) = makeProvider()

        try await provider.prepare(configuration: "walking")

        XCTAssertEqual(provider.state, .prepared)
        XCTAssertEqual(driver.calls, ["authorization", "create:walking", "prepare"])
        XCTAssertEqual(driver.beginCollectionCount, 0)
    }

    func testPreparedProviderStartsCollectionExactlyOnce() async throws {
        let (provider, driver) = makeProvider()
        try await provider.prepare(configuration: "walking")

        try await provider.start(at: Date(timeIntervalSince1970: 1_000))
        await XCTAssertThrowsErrorAsync(try await provider.start()) { error in
            XCTAssertEqual(
                error as? IPhoneHealthKitHeartRateProviderError,
                .invalidTransition(expected: .prepared, actual: .collecting)
            )
        }

        XCTAssertEqual(provider.state, .collecting)
        XCTAssertEqual(driver.startActivityCount, 1)
        XCTAssertEqual(driver.beginCollectionCount, 1)
    }

    func testHeartRateCallbackEmitsOneTruthfulProviderObservation() async throws {
        let (provider, _) = makeProvider()
        try await provider.prepare(configuration: "walking")
        try await provider.start()
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 2_000),
            duration: 2.5
        )
        let callbackObservedAt = Date(timeIntervalSince1970: 2_003)
        let receivedAt = Date(timeIntervalSince1970: 2_003.1)
        var observations: [HeartRateProviderObservation] = []
        provider.onObservation = { observations.append($0) }

        provider.receive(IPhoneHealthKitHeartRateSample(
            beatsPerMinute: 142,
            measurementInterval: interval,
            callbackObservedAt: callbackObservedAt,
            receivedAt: receivedAt
        ))

        let observation = try XCTUnwrap(observations.only)
        XCTAssertEqual(observation.source.kind, .healthKitSelected)
        XCTAssertEqual(observation.source.stableLocalKey, "iphone-healthkit-selected")
        XCTAssertEqual(observation.beatsPerMinute, 142)
        XCTAssertEqual(observation.measuredAt, interval.end)
        XCTAssertEqual(observation.sourceCallbackObservedAt, callbackObservedAt)
        XCTAssertEqual(observation.receivedAt, receivedAt)
        XCTAssertNil(observation.providerSequence)
        XCTAssertNil(observation.providerNativeIdentity)
    }

    func testMissingMeasurementIntervalRemainsMissingThroughNormalization() async throws {
        let (provider, _) = makeProvider()
        try await provider.prepare(configuration: "walking")
        try await provider.start()
        let callbackObservedAt = Date(timeIntervalSince1970: 3_000)
        var observations: [HeartRateProviderObservation] = []
        provider.onObservation = { observations.append($0) }

        provider.receive(IPhoneHealthKitHeartRateSample(
            beatsPerMinute: 118,
            measurementInterval: nil,
            callbackObservedAt: callbackObservedAt,
            receivedAt: callbackObservedAt
        ))

        let providerObservation = try XCTUnwrap(observations.only)
        XCTAssertNil(providerObservation.measuredAt)
        var normalizer = HeartRateObservationNormalizer()
        let result = normalizer.normalize(
            providerObservation,
            canonicalObservationID: HeartRateCanonicalObservationID(),
            deliveryID: HeartRateDeliveryID(),
            recordedAt: callbackObservedAt
        )
        XCTAssertNil(result.canonicalObservation?.measuredAt)
        XCTAssertTrue(result.delivery.quality.contains(.missingMeasurementTime))
    }

    func testDiscardStopsCollectionAndNeverFinishesWorkout() async throws {
        let (provider, driver) = makeProvider()
        try await provider.prepare(configuration: "walking")
        try await provider.start()
        driver.calls.removeAll()

        await provider.discard(at: Date(timeIntervalSince1970: 4_000))

        XCTAssertEqual(provider.state, .idle)
        XCTAssertEqual(
            driver.calls,
            ["stopActivity", "endCollection", "discard", "endSession", "reset"]
        )
        XCTAssertEqual(driver.finishCount, 0)
    }

    func testCommittedFinishWaitsForStoppedTransitionAndUsesItsDate() async throws {
        let (provider, driver) = makeProvider()
        try await provider.prepare(configuration: "walking")
        try await provider.start()
        driver.calls.removeAll()
        driver.suspendStoppedTransition = true
        let stoppedAt = Date(timeIntervalSince1970: 5_001)

        let finish = Task {
            try await provider.finish(at: Date(timeIntervalSince1970: 5_000))
        }
        await driver.waitUntilStoppedTransitionIsPending()

        XCTAssertEqual(driver.calls, ["stopActivity"])

        driver.sendStoppedTransition(at: stoppedAt)
        let outcome = try await finish.value

        XCTAssertEqual(outcome, .saved(workout: driver.workoutID))
        XCTAssertEqual(provider.state, .idle)
        XCTAssertEqual(
            driver.calls,
            [
                "stopActivity",
                "stoppedTransition",
                "endCollection",
                "finish",
                "endSession",
                "reset",
            ]
        )
        XCTAssertEqual(driver.endCollectionDates, [stoppedAt])
        XCTAssertEqual(driver.stopActivityCount, 1)
        XCTAssertEqual(driver.endCollectionCount, 1)
        XCTAssertEqual(driver.finishCount, 1)
    }

    func testRapidHubWarmDuringCommittedFinishLeavesProviderUntouched() async throws {
        let (provider, driver) = makeProvider()
        try await provider.prepare(configuration: "walking")
        try await provider.start()
        driver.calls.removeAll()
        driver.suspendStoppedTransition = true

        let finish = Task {
            try await provider.finish(at: Date(timeIntervalSince1970: 5_010))
        }
        await driver.waitUntilStoppedTransitionIsPending()

        let shouldWarm = NativeHeartRatePreflightEngine.RuntimePolicy.canWarmPrepare(
            isTrainingHubVisible: true,
            appActivity: .active,
            isHrControlRunning: false,
            nativeWorkoutCommitted: true,
            nativeWorkoutFinishInFlight: true,
            providerIsIdle: provider.state == .idle,
            providerIsSupported: true
        )
        if shouldWarm {
            try await provider.prepare(configuration: "unexpected-warm")
        }

        XCTAssertFalse(shouldWarm)
        XCTAssertEqual(provider.state, .finishing)
        XCTAssertEqual(driver.calls, ["stopActivity"])
        XCTAssertEqual(driver.discardCount, 0)
        XCTAssertEqual(driver.finishCount, 0)
        XCTAssertEqual(driver.resetCount, 0)

        driver.sendStoppedTransition(at: Date(timeIntervalSince1970: 5_011))
        _ = try await finish.value

        XCTAssertEqual(provider.state, .idle)
        XCTAssertEqual(driver.finishCount, 1)
        XCTAssertEqual(driver.discardCount, 0)
        XCTAssertEqual(driver.resetCount, 1)
        XCTAssertEqual(driver.createdConfigurations, ["walking"])
    }

    func testUnavailableFinishedWorkoutEndsSessionWithoutDiscardOrRetry() async throws {
        let (provider, driver) = makeProvider()
        try await provider.prepare(configuration: "walking")
        try await provider.start()
        driver.finishedWorkout = nil
        driver.calls.removeAll()

        let outcome = try await provider.finish(at: Date(timeIntervalSince1970: 5_100))

        XCTAssertEqual(outcome, .savedWorkoutUnavailable)
        XCTAssertEqual(provider.state, .idle)
        XCTAssertEqual(
            driver.calls,
            [
                "stopActivity",
                "stoppedTransition",
                "endCollection",
                "finish",
                "endSession",
                "reset",
            ]
        )
        XCTAssertEqual(driver.finishCount, 1)
        XCTAssertEqual(driver.discardCount, 0)
        XCTAssertEqual(driver.endSessionCount, 1)
        XCTAssertEqual(driver.resetCount, 1)
    }

    func testFinishErrorFailsAndDiscardsOwnedWorkout() async throws {
        let (provider, driver) = makeProvider()
        try await provider.prepare(configuration: "walking")
        try await provider.start()
        driver.finishWorkoutError = TestError.expected
        driver.calls.removeAll()

        await XCTAssertThrowsErrorAsync(
            try await provider.finish(at: Date(timeIntervalSince1970: 5_200))
        ) { error in
            XCTAssertEqual(error as? TestError, .expected)
        }

        XCTAssertEqual(provider.state, .idle)
        XCTAssertEqual(
            driver.calls,
            [
                "stopActivity",
                "stoppedTransition",
                "endCollection",
                "finish",
                "discard",
                "endSession",
                "reset",
            ]
        )
        XCTAssertEqual(driver.finishCount, 1)
        XCTAssertEqual(driver.discardCount, 1)
        XCTAssertEqual(driver.endSessionCount, 1)
        XCTAssertEqual(driver.resetCount, 1)
    }

    func testFailureResetsOwnershipBeforeNextAttempt() async throws {
        let (provider, driver) = makeProvider()
        driver.beginCollectionError = TestError.expected
        try await provider.prepare(configuration: "first")

        await XCTAssertThrowsErrorAsync(try await provider.start()) { error in
            XCTAssertEqual(error as? TestError, .expected)
        }

        XCTAssertEqual(provider.state, .idle)
        XCTAssertEqual(driver.discardCount, 1)
        XCTAssertEqual(driver.resetCount, 1)

        driver.beginCollectionError = nil
        try await provider.prepare(configuration: "second")
        try await provider.start()

        XCTAssertEqual(provider.state, .collecting)
        XCTAssertEqual(driver.createdConfigurations, ["first", "second"])
        XCTAssertEqual(driver.beginCollectionCount, 2)
    }

    func testDiscardWhilePreparingCancelsPendingOperationAndAllowsFreshAttempt() async throws {
        let (provider, driver) = makeProvider()
        driver.suspendPrepare = true
        let firstAttempt = Task {
            try await provider.prepare(configuration: "first")
        }
        await driver.waitUntilPrepareIsPending()

        await provider.discard(at: Date(timeIntervalSince1970: 6_000))
        await XCTAssertThrowsErrorAsync(try await firstAttempt.value) { error in
            XCTAssertEqual(
                error as? IPhoneHealthKitHeartRateProviderError,
                .operationCancelled
            )
        }

        driver.suspendPrepare = false
        try await provider.prepare(configuration: "second")

        XCTAssertEqual(provider.state, .prepared)
        XCTAssertEqual(driver.createdConfigurations, ["first", "second"])
        XCTAssertEqual(driver.discardCount, 1)
        XCTAssertEqual(driver.resetCount, 1)
    }

    func testFoundationHasNoProductionControllerOrWatchDependency() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let packageDirectory = testsDirectory.deletingLastPathComponent()
        let manager = try String(
            contentsOf: packageDirectory.appendingPathComponent("WalkingPadRemote/BluetoothManager.swift"),
            encoding: .utf8
        )
        let provider = try String(
            contentsOf: packageDirectory.appendingPathComponent(
                "WalkingPadRemote/IPhoneHealthKitLiveHeartRateProvider.swift"
            ),
            encoding: .utf8
        )
        let watch = try String(
            contentsOf: packageDirectory.appendingPathComponent(
                "WalkingPadRemoteWatch Watch App/WatchHeartRateManager.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(manager.contains("IPhoneHealthKitLiveHeartRateProvider"))
        for forbidden in [
            "sendTreadmill", "WCSession", "watchReachable", "start_hr", "CoreBluetooth",
        ] {
            XCTAssertFalse(provider.contains(forbidden), forbidden)
        }
        XCTAssertTrue(watch.contains("final class WatchHeartRateManager"))
    }

    private func makeProvider() -> (
        IPhoneHealthKitHeartRateProviderCore<FakeHealthKitWorkoutDriver>,
        FakeHealthKitWorkoutDriver
    ) {
        let driver = FakeHealthKitWorkoutDriver()
        return (IPhoneHealthKitHeartRateProviderCore(driver: driver), driver)
    }
}

private final class FakeHealthKitWorkoutDriver: IPhoneHealthKitWorkoutLifecycleDriving {
    typealias Configuration = String
    typealias Workout = UUID

    let workoutID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    var finishedWorkout: UUID?
    var calls: [String] = []
    var createdConfigurations: [String] = []
    var beginCollectionError: Error?
    var finishWorkoutError: Error?
    var suspendPrepare = false
    var suspendStoppedTransition = false
    var startActivityCount = 0
    var beginCollectionCount = 0
    var stopActivityCount = 0
    var endCollectionCount = 0
    var finishCount = 0
    var discardCount = 0
    var endSessionCount = 0
    var resetCount = 0
    var endCollectionDates: [Date] = []
    private var prepareContinuation: CheckedContinuation<Void, Error>?
    private var stoppedTransitionContinuation: CheckedContinuation<Date, Error>?

    init() {
        finishedWorkout = workoutID
    }

    func requestAuthorization() async throws {
        calls.append("authorization")
    }

    func createWorkout(configuration: String) throws {
        calls.append("create:\(configuration)")
        createdConfigurations.append(configuration)
    }

    func prepare() async throws {
        calls.append("prepare")
        guard suspendPrepare else { return }
        try await withCheckedThrowingContinuation { continuation in
            prepareContinuation = continuation
        }
    }

    func startActivity(at date: Date) {
        calls.append("startActivity")
        startActivityCount += 1
    }

    func beginCollection(at date: Date) async throws {
        calls.append("beginCollection")
        beginCollectionCount += 1
        if let beginCollectionError {
            throw beginCollectionError
        }
    }

    func stopActivity(at date: Date) {
        calls.append("stopActivity")
        stopActivityCount += 1
    }

    func waitForStoppedTransition() async throws -> Date {
        guard suspendStoppedTransition else {
            calls.append("stoppedTransition")
            return Date(timeIntervalSince1970: 4_999)
        }
        return try await withCheckedThrowingContinuation { continuation in
            stoppedTransitionContinuation = continuation
        }
    }

    func endCollection(at date: Date) async throws {
        calls.append("endCollection")
        endCollectionCount += 1
        endCollectionDates.append(date)
    }

    func finishWorkout() async throws -> UUID? {
        calls.append("finish")
        finishCount += 1
        if let finishWorkoutError {
            throw finishWorkoutError
        }
        return finishedWorkout
    }

    func discardWorkout() {
        calls.append("discard")
        discardCount += 1
    }

    func endSession() {
        calls.append("endSession")
        endSessionCount += 1
    }

    func reset() {
        calls.append("reset")
        resetCount += 1
        prepareContinuation?.resume(
            throwing: IPhoneHealthKitHeartRateProviderError.operationCancelled
        )
        prepareContinuation = nil
        stoppedTransitionContinuation?.resume(
            throwing: IPhoneHealthKitHeartRateProviderError.operationCancelled
        )
        stoppedTransitionContinuation = nil
    }

    func waitUntilPrepareIsPending() async {
        while prepareContinuation == nil {
            await Task.yield()
        }
    }

    func waitUntilStoppedTransitionIsPending() async {
        while stoppedTransitionContinuation == nil {
            await Task.yield()
        }
    }

    func sendStoppedTransition(at date: Date) {
        calls.append("stoppedTransition")
        let continuation = stoppedTransitionContinuation
        stoppedTransitionContinuation = nil
        continuation?.resume(returning: date)
    }
}

private enum TestError: Error, Equatable {
    case expected
}

private extension Array {
    var only: Element? {
        count == 1 ? self[0] : nil
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
