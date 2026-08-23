import Foundation
import HealthKit
import TelemetryDomain

@available(iOS 26.0, *)
@MainActor
final class IPhoneHealthKitLiveHeartRateProvider {
    typealias ObservationHandler = (HeartRateProviderObservation) -> Void

    private let driver: HealthKitLiveWorkoutDriver
    private let core: IPhoneHealthKitHeartRateProviderCore<HealthKitLiveWorkoutDriver>

    var onObservation: ObservationHandler? {
        get { core.onObservation }
        set { core.onObservation = newValue }
    }

    var state: IPhoneHealthKitHeartRateProviderState {
        core.state
    }

    init(healthStore: HKHealthStore = HKHealthStore()) {
        let driver = HealthKitLiveWorkoutDriver(healthStore: healthStore)
        self.driver = driver
        core = IPhoneHealthKitHeartRateProviderCore(driver: driver)

        driver.onHeartRateSample = { [weak core] sample in
            Task { @MainActor in
                core?.receive(sample)
            }
        }
        driver.onRuntimeFailure = { [weak core] in
            Task { @MainActor in
                await core?.resetAfterFailure()
            }
        }
    }

    func prepare(configuration: HKWorkoutConfiguration) async throws {
        try await core.prepare(configuration: configuration)
    }

    func start(at date: Date = Date()) async throws {
        try await core.start(at: date)
    }

    func discard(at date: Date = Date()) async {
        await core.discard(at: date)
    }

    func finish(
        at date: Date = Date()
    ) async throws -> IPhoneHealthKitWorkoutFinishOutcome<HKWorkout> {
        try await core.finish(at: date)
    }
}

@available(iOS 26.0, *)
private final class HealthKitLiveWorkoutDriver: NSObject, IPhoneHealthKitWorkoutLifecycleDriving {
    typealias Configuration = HKWorkoutConfiguration
    typealias Workout = HKWorkout

    var onHeartRateSample: ((IPhoneHealthKitHeartRateSample) -> Void)?
    var onRuntimeFailure: (() -> Void)?

    private let healthStore: HKHealthStore
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var prepareContinuation: CheckedContinuation<Void, Error>?
    private var beginCollectionContinuation: CheckedContinuation<Void, Error>?
    private var stoppedTransitionContinuation: CheckedContinuation<Date, Error>?
    private var stoppedAt: Date?
    private var endCollectionContinuation: CheckedContinuation<Void, Error>?
    private var finishContinuation: CheckedContinuation<HKWorkout?, Error>?

    init(healthStore: HKHealthStore) {
        self.healthStore = healthStore
    }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable(),
              let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)
        else {
            throw HealthKitLiveWorkoutDriverError.healthDataUnavailable
        }

        let typesToShare: Set<HKSampleType> = [HKObjectType.workoutType()]
        let typesToRead: Set<HKObjectType> = [heartRateType]
        let status = try await healthStore.statusForAuthorizationRequest(
            toShare: typesToShare,
            read: typesToRead
        )

        guard status != .unnecessary else { return }
        try await healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead)
    }

    func createWorkout(configuration: HKWorkoutConfiguration) throws {
        guard session == nil, builder == nil else {
            throw HealthKitLiveWorkoutDriverError.workoutAlreadyOwned
        }

        let session = try HKWorkoutSession(
            healthStore: healthStore,
            configuration: configuration
        )
        let builder = session.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(
            healthStore: healthStore,
            workoutConfiguration: configuration
        )
        session.delegate = self
        builder.delegate = self
        self.session = session
        self.builder = builder
    }

    func prepare() async throws {
        guard let session else {
            throw HealthKitLiveWorkoutDriverError.missingWorkout
        }
        try await withCheckedThrowingContinuation { continuation in
            prepareContinuation = continuation
            session.prepare()
        }
    }

    func startActivity(at date: Date) {
        session?.startActivity(with: date)
    }

    func beginCollection(at date: Date) async throws {
        guard let builder else {
            throw HealthKitLiveWorkoutDriverError.missingWorkout
        }
        try await withCheckedThrowingContinuation { continuation in
            beginCollectionContinuation = continuation
            builder.beginCollection(withStart: date) { [weak self] success, error in
                DispatchQueue.main.async {
                    self?.completeVoidOperation(
                        keyPath: \.beginCollectionContinuation,
                        success: success,
                        error: error
                    )
                }
            }
        }
    }

    func stopActivity(at date: Date) {
        session?.stopActivity(with: date)
    }

    func waitForStoppedTransition() async throws -> Date {
        if let stoppedAt {
            self.stoppedAt = nil
            return stoppedAt
        }
        return try await withCheckedThrowingContinuation { continuation in
            stoppedTransitionContinuation = continuation
        }
    }

    func endCollection(at date: Date) async throws {
        guard let builder else {
            throw HealthKitLiveWorkoutDriverError.missingWorkout
        }
        try await withCheckedThrowingContinuation { continuation in
            endCollectionContinuation = continuation
            builder.endCollection(withEnd: date) { [weak self] success, error in
                DispatchQueue.main.async {
                    self?.completeVoidOperation(
                        keyPath: \.endCollectionContinuation,
                        success: success,
                        error: error
                    )
                }
            }
        }
    }

    func finishWorkout() async throws -> HKWorkout? {
        guard let builder else {
            throw HealthKitLiveWorkoutDriverError.missingWorkout
        }
        return try await withCheckedThrowingContinuation { [weak self] continuation in
            guard let self else {
                continuation.resume(
                    throwing: HealthKitLiveWorkoutDriverError.operationCancelled
                )
                return
            }
            self.finishContinuation = continuation
            builder.finishWorkout { [weak self] workout, error in
                DispatchQueue.main.async { [weak self] in
                    guard let self, let continuation = self.finishContinuation else { return }
                    self.finishContinuation = nil
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: workout)
                    }
                }
            }
        }
    }

    func discardWorkout() {
        builder?.discardWorkout()
    }

    func endSession() {
        session?.end()
    }

    func reset() {
        let cancellation = HealthKitLiveWorkoutDriverError.operationCancelled
        prepareContinuation?.resume(throwing: cancellation)
        beginCollectionContinuation?.resume(throwing: cancellation)
        stoppedTransitionContinuation?.resume(throwing: cancellation)
        endCollectionContinuation?.resume(throwing: cancellation)
        finishContinuation?.resume(throwing: cancellation)
        prepareContinuation = nil
        beginCollectionContinuation = nil
        stoppedTransitionContinuation = nil
        stoppedAt = nil
        endCollectionContinuation = nil
        finishContinuation = nil
        session = nil
        builder = nil
    }

    private func completeVoidOperation(
        keyPath: ReferenceWritableKeyPath<
            HealthKitLiveWorkoutDriver,
            CheckedContinuation<Void, Error>?
        >,
        success: Bool,
        error: Error?
    ) {
        guard let continuation = self[keyPath: keyPath] else { return }
        self[keyPath: keyPath] = nil
        if success {
            continuation.resume()
        } else {
            continuation.resume(
                throwing: error ?? HealthKitLiveWorkoutDriverError.operationFailed
            )
        }
    }
}

@available(iOS 26.0, *)
extension HealthKitLiveWorkoutDriver: HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self, workoutSession === self.session else { return }
            switch toState {
            case .prepared:
                let continuation = self.prepareContinuation
                self.prepareContinuation = nil
                continuation?.resume()
            case .stopped:
                if let continuation = self.stoppedTransitionContinuation {
                    self.stoppedTransitionContinuation = nil
                    continuation.resume(returning: date)
                } else {
                    self.stoppedAt = date
                }
            default:
                break
            }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, workoutSession === self.session else { return }
            let continuation = self.prepareContinuation
            self.prepareContinuation = nil
            continuation?.resume(throwing: error)
            let stoppedContinuation = self.stoppedTransitionContinuation
            self.stoppedTransitionContinuation = nil
            stoppedContinuation?.resume(throwing: error)
            self.onRuntimeFailure?()
        }
    }

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        guard workoutBuilder === builder,
              let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate),
              collectedTypes.contains(heartRateType),
              let statistics = workoutBuilder.statistics(for: heartRateType),
              let quantity = statistics.mostRecentQuantity()
        else {
            return
        }

        let beatsPerMinute = quantity.doubleValue(
            for: HKUnit.count().unitDivided(by: .minute())
        )
        guard beatsPerMinute.isFinite, beatsPerMinute > 0 else { return }

        let callbackObservedAt = Date()
        let sample = IPhoneHealthKitHeartRateSample(
            beatsPerMinute: Int(beatsPerMinute.rounded()),
            measurementInterval: statistics.mostRecentQuantityDateInterval(),
            callbackObservedAt: callbackObservedAt,
            receivedAt: Date()
        )
        DispatchQueue.main.async { [weak self] in
            self?.onHeartRateSample?(sample)
        }
    }
}

@available(iOS 26.0, *)
private enum HealthKitLiveWorkoutDriverError: LocalizedError {
    case healthDataUnavailable
    case missingWorkout
    case operationCancelled
    case operationFailed
    case workoutAlreadyOwned

    var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            "HealthKit data is unavailable on this device."
        case .missingWorkout:
            "The HealthKit workout lifecycle is not initialized."
        case .operationCancelled:
            "The HealthKit workout lifecycle operation was cancelled."
        case .operationFailed:
            "The HealthKit workout lifecycle operation failed."
        case .workoutAlreadyOwned:
            "The HealthKit provider already owns a workout lifecycle."
        }
    }
}
