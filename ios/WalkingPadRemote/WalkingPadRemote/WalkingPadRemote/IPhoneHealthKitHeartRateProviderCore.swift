import Foundation
import TelemetryDomain

protocol IPhoneHealthKitWorkoutLifecycleDriving: AnyObject {
    associatedtype Configuration
    associatedtype Workout

    func requestAuthorization() async throws
    func createWorkout(configuration: Configuration) throws
    func prepare() async throws
    func startActivity(at date: Date)
    func beginCollection(at date: Date) async throws
    func stopActivity(at date: Date)
    func waitForStoppedTransition() async throws -> Date
    func endCollection(at date: Date) async throws
    func finishWorkout() async throws -> Workout?
    func discardWorkout()
    func endSession()
    func reset()
}

enum IPhoneHealthKitHeartRateProviderState: String, Equatable {
    case idle
    case authorizing
    case preparing
    case prepared
    case starting
    case collecting
    case resetting
    case finishing
}

enum IPhoneHealthKitHeartRateProviderError: Error, Equatable {
    case invalidTransition(
        expected: IPhoneHealthKitHeartRateProviderState,
        actual: IPhoneHealthKitHeartRateProviderState
    )
    case operationCancelled
    case finishedWorkoutUnavailable
}

struct IPhoneHealthKitHeartRateSample: Equatable {
    let beatsPerMinute: Int
    let measurementInterval: DateInterval?
    let callbackObservedAt: Date
    let receivedAt: Date
}

@MainActor
final class IPhoneHealthKitHeartRateProviderCore<Driver: IPhoneHealthKitWorkoutLifecycleDriving> {
    typealias ObservationHandler = (HeartRateProviderObservation) -> Void

    private let driver: Driver
    private let source: HeartRateProviderIdentity
    private var generation: UInt64 = 0
    private var ownsWorkout = false
    private var activityStarted = false
    private var collectionStarted = false

    private(set) var state: IPhoneHealthKitHeartRateProviderState = .idle
    var onObservation: ObservationHandler?

    init(
        driver: Driver,
        source: HeartRateProviderIdentity = HeartRateProviderIdentity(
            kind: .healthKitSelected,
            stableLocalKey: "iphone-healthkit-selected"
        )
    ) {
        self.driver = driver
        self.source = source
    }

    func prepare(configuration: Driver.Configuration) async throws {
        guard state == .idle else {
            throw IPhoneHealthKitHeartRateProviderError.invalidTransition(
                expected: .idle,
                actual: state
            )
        }

        generation &+= 1
        let operationGeneration = generation
        state = .authorizing

        do {
            try await driver.requestAuthorization()
            try requireCurrent(operationGeneration, state: .authorizing)

            try driver.createWorkout(configuration: configuration)
            ownsWorkout = true
            state = .preparing
            try await driver.prepare()
            try requireCurrent(operationGeneration, state: .preparing)
            state = .prepared
        } catch {
            if operationGeneration == generation {
                await discardOwnedWorkout()
            }
            throw error
        }
    }

    func start(at date: Date = Date()) async throws {
        guard state == .prepared else {
            throw IPhoneHealthKitHeartRateProviderError.invalidTransition(
                expected: .prepared,
                actual: state
            )
        }

        let operationGeneration = generation
        state = .starting
        activityStarted = true
        driver.startActivity(at: date)

        do {
            try await driver.beginCollection(at: date)
            try requireCurrent(operationGeneration, state: .starting)
            collectionStarted = true
            state = .collecting
        } catch {
            if operationGeneration == generation {
                await discardOwnedWorkout()
            }
            throw error
        }
    }

    func receive(_ sample: IPhoneHealthKitHeartRateSample) {
        guard state == .collecting else { return }

        onObservation?(HeartRateProviderObservation(
            source: source,
            beatsPerMinute: sample.beatsPerMinute,
            providerSequence: nil,
            providerNativeIdentity: nil,
            measuredAt: sample.measurementInterval?.end,
            sourceCallbackObservedAt: sample.callbackObservedAt,
            sourceClockRelationship: .receiverComparable,
            receivedAt: sample.receivedAt,
            metadataQuality: []
        ))
    }

    func discard(at date: Date) async {
        guard state != .idle else { return }
        generation &+= 1
        await discardOwnedWorkout(at: date)
    }

    func finish(at date: Date) async throws -> Driver.Workout {
        guard state == .collecting else {
            throw IPhoneHealthKitHeartRateProviderError.invalidTransition(
                expected: .collecting,
                actual: state
            )
        }

        let operationGeneration = generation
        state = .finishing
        driver.stopActivity(at: date)

        do {
            let stoppedAt = try await driver.waitForStoppedTransition()
            try requireCurrent(operationGeneration, state: .finishing)
            activityStarted = false
            try await driver.endCollection(at: stoppedAt)
            try requireCurrent(operationGeneration, state: .finishing)
            collectionStarted = false
            guard let workout = try await driver.finishWorkout() else {
                throw IPhoneHealthKitHeartRateProviderError.finishedWorkoutUnavailable
            }
            try requireCurrent(operationGeneration, state: .finishing)
            driver.endSession()
            resetOwnership()
            return workout
        } catch {
            if operationGeneration == generation {
                await discardOwnedWorkout(at: date)
            }
            throw error
        }
    }

    func resetAfterFailure(at date: Date = Date()) async {
        guard state != .idle else { return }
        generation &+= 1
        await discardOwnedWorkout(at: date)
    }

    private func requireCurrent(
        _ operationGeneration: UInt64,
        state expectedState: IPhoneHealthKitHeartRateProviderState
    ) throws {
        guard operationGeneration == generation, state == expectedState else {
            throw IPhoneHealthKitHeartRateProviderError.operationCancelled
        }
    }

    private func discardOwnedWorkout(at date: Date = Date()) async {
        state = .resetting
        if activityStarted {
            driver.stopActivity(at: date)
            activityStarted = false
        }
        if collectionStarted {
            try? await driver.endCollection(at: date)
            collectionStarted = false
        }
        if ownsWorkout {
            driver.discardWorkout()
            driver.endSession()
        }
        resetOwnership()
    }

    private func resetOwnership() {
        driver.reset()
        ownsWorkout = false
        activityStarted = false
        collectionStarted = false
        state = .idle
    }
}
