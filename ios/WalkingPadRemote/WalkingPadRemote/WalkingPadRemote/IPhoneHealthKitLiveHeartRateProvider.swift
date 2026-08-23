import Foundation
import HealthKit
import TelemetryDomain

@available(iOS 26.0, *)
@MainActor
final class IPhoneHealthKitLiveHeartRateProvider {
    typealias ObservationHandler = (HeartRateProviderObservation) -> Void
    typealias FailureHandler = (IPhoneHealthKitRuntimeFailureContext) -> Void

    private let driver: HealthKitLiveWorkoutDriver
    private let core: IPhoneHealthKitHeartRateProviderCore<HealthKitLiveWorkoutDriver>
    private var runtimeFailureContext: IPhoneHealthKitRuntimeFailureContext?

    var onObservation: ObservationHandler? {
        get { core.onObservation }
        set { core.onObservation = newValue }
    }

    var onFailure: FailureHandler?

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
        driver.onRuntimeFailure = { [weak self, weak core] context in
            Task { @MainActor in
                guard let self else { return }
                guard self.runtimeFailureContext == context else {
                    self.onFailure?(context)
                    return
                }
                await core?.resetAfterFailure()
                guard self.runtimeFailureContext == context else {
                    self.onFailure?(context)
                    return
                }
                self.runtimeFailureContext = nil
                self.onFailure?(context)
            }
        }
    }

    static var isSupported: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func canPrepareWithoutAuthorizationPrompt() async -> Bool {
        await driver.canPrepareWithoutAuthorizationPrompt()
    }

    func prepare(
        configuration: HKWorkoutConfiguration,
        failureContext: IPhoneHealthKitRuntimeFailureContext
    ) async throws {
        runtimeFailureContext = failureContext
        driver.setNextRuntimeFailureContext(failureContext)
        do {
            try await core.prepare(configuration: configuration)
        } catch {
            if runtimeFailureContext == failureContext {
                runtimeFailureContext = nil
            }
            throw error
        }
    }

    func bindRuntimeFailureContext(_ context: IPhoneHealthKitRuntimeFailureContext) {
        runtimeFailureContext = context
        driver.updateCurrentRuntimeFailureContext(context)
    }

    func start(at date: Date = Date()) async throws {
        try await core.start(at: date)
    }

    func discard(at date: Date = Date()) async {
        let discardedContext = runtimeFailureContext
        await core.discard(at: date)
        if runtimeFailureContext == discardedContext {
            runtimeFailureContext = nil
        }
    }

    func finish(
        at date: Date = Date()
    ) async throws -> IPhoneHealthKitWorkoutFinishOutcome<HKWorkout> {
        let finishedContext = runtimeFailureContext
        defer {
            if runtimeFailureContext == finishedContext {
                runtimeFailureContext = nil
            }
        }
        return try await core.finish(at: date)
    }
}

@available(iOS 26.0, *)
private final class HealthKitLiveWorkoutDriver: NSObject, IPhoneHealthKitWorkoutLifecycleDriving {
    typealias Configuration = HKWorkoutConfiguration
    typealias Workout = HKWorkout

    var onHeartRateSample: ((IPhoneHealthKitHeartRateSample) -> Void)?
    var onRuntimeFailure: ((IPhoneHealthKitRuntimeFailureContext) -> Void)?

    private let healthStore: HKHealthStore
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var prepareContinuation: CheckedContinuation<Void, Error>?
    private var beginCollectionContinuation: CheckedContinuation<Void, Error>?
    private var stoppedTransitionContinuation: CheckedContinuation<Date, Error>?
    private var stoppedAt: Date?
    private var endCollectionContinuation: CheckedContinuation<Void, Error>?
    private var finishContinuation: CheckedContinuation<HKWorkout?, Error>?
    private var nextRuntimeFailureContext: IPhoneHealthKitRuntimeFailureContext?
    private var runtimeFailureContexts: [ObjectIdentifier: IPhoneHealthKitRuntimeFailureContext] = [:]
    private var runtimeFailureContextOrder: [ObjectIdentifier] = []

    init(healthStore: HKHealthStore) {
        self.healthStore = healthStore
    }

    func setNextRuntimeFailureContext(_ context: IPhoneHealthKitRuntimeFailureContext) {
        nextRuntimeFailureContext = context
    }

    func updateCurrentRuntimeFailureContext(_ context: IPhoneHealthKitRuntimeFailureContext) {
        guard let session else { return }
        retainRuntimeFailureContext(context, for: session)
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

        if status != .unnecessary {
            try await healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead)
        }
        guard healthStore.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
            throw HealthKitLiveWorkoutDriverError.authorizationNotGranted
        }
    }

    func canPrepareWithoutAuthorizationPrompt() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable(),
              let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate),
              healthStore.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
            return false
        }
        let status = try? await healthStore.statusForAuthorizationRequest(
            toShare: [HKObjectType.workoutType()],
            read: [heartRateType]
        )
        return status == .unnecessary
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
        let dataSource = HKLiveWorkoutDataSource(
            healthStore: healthStore,
            workoutConfiguration: configuration
        )
        if let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate) {
            for quantityType in dataSource.typesToCollect where quantityType != heartRateType {
                dataSource.disableCollection(for: quantityType)
            }
            dataSource.enableCollection(for: heartRateType, predicate: nil)
        }
        builder.dataSource = dataSource
        session.delegate = self
        builder.delegate = self
        self.session = session
        self.builder = builder
        if let nextRuntimeFailureContext {
            retainRuntimeFailureContext(nextRuntimeFailureContext, for: session)
            self.nextRuntimeFailureContext = nil
        }
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

    private func retainRuntimeFailureContext(
        _ context: IPhoneHealthKitRuntimeFailureContext,
        for session: HKWorkoutSession
    ) {
        let identifier = ObjectIdentifier(session)
        runtimeFailureContexts[identifier] = context
        runtimeFailureContextOrder.removeAll { $0 == identifier }
        runtimeFailureContextOrder.append(identifier)
        while runtimeFailureContextOrder.count > 8 {
            let expiredIdentifier = runtimeFailureContextOrder.removeFirst()
            runtimeFailureContexts.removeValue(forKey: expiredIdentifier)
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
            guard let self else { return }
            let identifier = ObjectIdentifier(workoutSession)
            guard let failureContext = self.runtimeFailureContexts.removeValue(
                forKey: identifier
            ) else { return }
            self.runtimeFailureContextOrder.removeAll { $0 == identifier }
            if workoutSession === self.session {
                let continuation = self.prepareContinuation
                self.prepareContinuation = nil
                continuation?.resume(throwing: error)
                let stoppedContinuation = self.stoppedTransitionContinuation
                self.stoppedTransitionContinuation = nil
                stoppedContinuation?.resume(throwing: error)
            }
            self.onRuntimeFailure?(failureContext)
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
    case authorizationNotGranted
    case healthDataUnavailable
    case missingWorkout
    case operationCancelled
    case operationFailed
    case workoutAlreadyOwned

    var errorDescription: String? {
        switch self {
        case .authorizationNotGranted:
            "HealthKit workout access was not granted."
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
