import Foundation
import Combine
import HealthKit

final class IPhoneHealthKitHeartRateManager: NSObject, ObservableObject {
    struct HeartRateSample {
        let bpm: Int
        let sampledAt: Date
    }

    var onHeartRateSample: ((HeartRateSample) -> Void)?
    var onStatus: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    var onCollectionStarted: ((Date) -> Void)?
    var onWorkoutFinished: ((UUID, Date?) -> Void)?

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var isActive = false
    private var startRequestID: UUID?

    func start() {
        if isActive || startRequestID != nil {
            onStatus?("iPhone HealthKit: HR already active or starting")
            return
        }

        let requestID = UUID()
        startRequestID = requestID
        onStatus?("iPhone HealthKit: requesting authorization")
        requestAuthorization { [weak self] granted, failureMessage in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.startRequestID == requestID else { return }
                guard granted else {
                    self.startRequestID = nil
                    self.fail(failureMessage ?? "iPhone HealthKit: authorization denied")
                    return
                }
                self.startWorkout(requestID: requestID)
            }
        }
    }

    func stop() {
        let wasStarting = startRequestID != nil
        startRequestID = nil
        guard wasStarting || isActive || session != nil || builder != nil else { return }
        isActive = false
        if wasStarting {
            abortWorkoutStart()
            onStatus?("iPhone HealthKit: HR stopped")
            return
        }
        finishWorkout()
    }

    private func requestAuthorization(completion: @escaping (Bool, String?) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(false, "iPhone HealthKit: Health data is unavailable")
            return
        }

        let workoutType = HKObjectType.workoutType()
        let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!
        let distanceType = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)!
        let stepsType = HKQuantityType.quantityType(forIdentifier: .stepCount)!

        healthStore.requestAuthorization(
            toShare: [workoutType, energyType, distanceType, stepsType],
            read: [hrType, energyType, distanceType, stepsType]
        ) { success, error in
            if let error {
                completion(false, "iPhone HealthKit: authorization failed: \(error.localizedDescription)")
            } else if success {
                completion(true, nil)
            } else {
                completion(false, "iPhone HealthKit: authorization denied")
            }
        }
    }

    private func startWorkout(requestID: UUID) {
        guard startRequestID == requestID else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .walking
        configuration.locationType = .indoor

        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder

            let startDate = Date()
            session.startActivity(with: startDate)
            builder.beginCollection(withStart: startDate) { [weak self] success, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard self.startRequestID == requestID else {
                        self.abortWorkoutStart()
                        return
                    }
                    guard success, error == nil else {
                        self.startRequestID = nil
                        self.abortWorkoutStart()
                        let details = error?.localizedDescription ?? "unknown error"
                        self.fail("iPhone HealthKit: collection error: \(details)")
                        return
                    }

                    self.startRequestID = nil
                    self.isActive = true
                    self.onStatus?("iPhone HealthKit: HR started")
                    self.onCollectionStarted?(Date())
                }
            }
        } catch {
            startRequestID = nil
            isActive = false
            session = nil
            builder = nil
            fail("iPhone HealthKit: start failed: \(error.localizedDescription)")
        }
    }

    private func finishWorkout() {
        startRequestID = nil
        let endDate = Date()
        let session = self.session
        let builder = self.builder
        self.session = nil
        self.builder = nil

        guard let builder else {
            session?.end()
            onStatus?("iPhone HealthKit: HR stopped")
            return
        }

        builder.endCollection(withEnd: endDate) { [weak self] _, _ in
            session?.end()
            builder.finishWorkout { workout, error in
                DispatchQueue.main.async {
                    if let workout {
                        self?.onWorkoutFinished?(workout.uuid, workout.endDate)
                    }
                    if let error {
                        self?.onStatus?("iPhone HealthKit: workout finish error: \(error.localizedDescription)")
                    } else {
                        self?.onStatus?("iPhone HealthKit: HR stopped")
                    }
                }
            }
        }
    }

    private func abortWorkoutStart() {
        let session = self.session
        let builder = self.builder
        self.session = nil
        self.builder = nil
        isActive = false
        builder?.discardWorkout()
        session?.end()
    }

    private func fail(_ message: String) {
        onStatus?(message)
        onFailure?(message)
    }
}

extension IPhoneHealthKitHeartRateManager: HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        if (toState == .ended || toState == .stopped), isActive {
            DispatchQueue.main.async { [weak self] in
                self?.isActive = false
                self?.finishWorkout()
            }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.startRequestID = nil
            self?.isActive = false
            self?.fail("iPhone HealthKit: HR failed: \(error.localizedDescription)")
            self?.finishWorkout()
        }
    }

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate),
              collectedTypes.contains(hrType),
              let statistics = workoutBuilder.statistics(for: hrType),
              let quantity = statistics.mostRecentQuantity(),
              let sampledAt = HealthKitHeartRateSampleTimestamp.resolve(
                  from: statistics.mostRecentQuantityDateInterval()
              ) else {
            return
        }

        let bpm = Int(quantity.doubleValue(for: HKUnit.count().unitDivided(by: HKUnit.minute())).rounded())
        let sample = HeartRateSample(bpm: bpm, sampledAt: sampledAt)
        DispatchQueue.main.async { [weak self] in
            self?.onHeartRateSample?(sample)
        }
    }
}
