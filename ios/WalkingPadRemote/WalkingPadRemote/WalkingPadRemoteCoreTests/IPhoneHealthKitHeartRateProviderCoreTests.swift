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

    func testCommittedFinishUsesStopEndCollectionFinishExactlyOnce() async throws {
        let (provider, driver) = makeProvider()
        try await provider.prepare(configuration: "walking")
        try await provider.start()
        driver.calls.removeAll()

        let workoutID = try await provider.finish(at: Date(timeIntervalSince1970: 5_000))

        XCTAssertEqual(workoutID, driver.workoutID)
        XCTAssertEqual(provider.state, .idle)
        XCTAssertEqual(
            driver.calls,
            ["stopActivity", "endCollection", "finish", "endSession", "reset"]
        )
        XCTAssertEqual(driver.stopActivityCount, 1)
        XCTAssertEqual(driver.endCollectionCount, 1)
        XCTAssertEqual(driver.finishCount, 1)
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

        XCTAssertFalse(manager.contains("IPhoneHealthKitLiveHeartRateProvider"))
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
    var calls: [String] = []
    var createdConfigurations: [String] = []
    var beginCollectionError: Error?
    var suspendPrepare = false
    var startActivityCount = 0
    var beginCollectionCount = 0
    var stopActivityCount = 0
    var endCollectionCount = 0
    var finishCount = 0
    var discardCount = 0
    var resetCount = 0
    private var prepareContinuation: CheckedContinuation<Void, Error>?

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

    func endCollection(at date: Date) async throws {
        calls.append("endCollection")
        endCollectionCount += 1
    }

    func finishWorkout() async throws -> UUID {
        calls.append("finish")
        finishCount += 1
        return workoutID
    }

    func discardWorkout() {
        calls.append("discard")
        discardCount += 1
    }

    func endSession() {
        calls.append("endSession")
    }

    func reset() {
        calls.append("reset")
        resetCount += 1
        prepareContinuation?.resume(
            throwing: IPhoneHealthKitHeartRateProviderError.operationCancelled
        )
        prepareContinuation = nil
    }

    func waitUntilPrepareIsPending() async {
        while prepareContinuation == nil {
            await Task.yield()
        }
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
