import Combine
import Foundation
import HealthKit
import UserNotifications
import WatchConnectivity
import WatchKit

actor WorkoutSessionController {
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var started: Bool = false

    func start(healthStore: HKHealthStore,
               configuration: HKWorkoutConfiguration,
               sessionDelegate: HKWorkoutSessionDelegate,
               builderDelegate: HKLiveWorkoutBuilderDelegate) throws {
        let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
        let builder = session.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
        session.delegate = sessionDelegate
        builder.delegate = builderDelegate
        self.session = session
        self.builder = builder
        let startDate = Date()
        session.startActivity(with: startDate)
        builder.beginCollection(withStart: startDate) { _, _ in }
        started = true
    }

    func addStats(distanceDelta: Double?, stepsDelta: Int?) {
        guard started, let builder else { return }
        var samples: [HKSample] = []
        let now = Date()
        if let dm = distanceDelta, dm > 0,
           let distanceType = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) {
            let quantity = HKQuantity(unit: .meter(), doubleValue: dm)
            let sample = HKQuantitySample(type: distanceType, quantity: quantity, start: now.addingTimeInterval(-1), end: now)
            samples.append(sample)
        }
        if let steps = stepsDelta, steps > 0,
           let stepsType = HKQuantityType.quantityType(forIdentifier: .stepCount) {
            let quantity = HKQuantity(unit: .count(), doubleValue: Double(steps))
            let sample = HKQuantitySample(type: stepsType, quantity: quantity, start: now.addingTimeInterval(-1), end: now)
            samples.append(sample)
        }
        guard !samples.isEmpty else { return }
        builder.add(samples) { _, _ in }
    }

    func addEvent(_ value: String) {
        guard started, let builder else { return }
        let type: HKWorkoutEventType?
        switch value.lowercased() {
        case "pause": type = .pause
        case "resume": type = .resume
        default: type = nil
        }
        guard let type else { return }
        let now = Date()
        let interval = DateInterval(start: now, duration: 0)
        let event = HKWorkoutEvent(type: type, dateInterval: interval, metadata: nil)
        builder.addWorkoutEvents([event]) { _, _ in }
    }

    func endAndFinish() async -> HKWorkout? {
        guard started else { return nil }
        started = false
        let end = Date()
        let session = self.session
        let builder = self.builder
        self.session = nil
        self.builder = nil
        if let builder {
            return await withCheckedContinuation { continuation in
                builder.endCollection(withEnd: end) { _, _ in
                    session?.end()
                    builder.finishWorkout { workout, _ in
                        continuation.resume(returning: workout)
                    }
                }
            }
        }
        session?.end()
        return nil
    }

    func currentBuilder() -> HKLiveWorkoutBuilder? { builder }
}

final class WatchHeartRateManager: NSObject, ObservableObject {
    static let shared = WatchHeartRateManager()
    @Published var bpm: Int = 0
    @Published var isActive: Bool = false
    @Published var targetBpm: Int = 130

    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?
    private var workoutActive = false

    private var wcSession: WCSession?
    private var authorized = false
    private var notificationsAuthorized = false
    private let heartRatePayloadSequenceLock = NSLock()
    private var heartRatePayloadSequence: Int64 = 0

    private let workoutController = WorkoutSessionController()

    func activate() {
        if wcSession != nil { return }
        startWatchConnectivity()
        configureNotifications()
        requestAuthorization { [weak self] ok in
            self?.authorized = ok
        }
    }

    func start() {
        if workoutActive {
            sendStatus("hr_started")
            return
        }
        if !authorized {
            requestAuthorization { [weak self] ok in
                self?.authorized = ok
                if ok {
                    self?.startWorkout()
                } else {
                    self?.sendStatus("hr_stopped")
                }
            }
            return
        }
        startWorkout()
    }

    func stop() {
        if !workoutActive {
            DispatchQueue.main.async { self.isActive = false }
            sendStatus("hr_stopped")
            return
        }
        workoutActive = false

        Task {
            let workout = await self.workoutController.endAndFinish()
            if let workout {
                self.sendWorkoutUUID(workout.uuid, endDate: workout.endDate)
            }
        }

        DispatchQueue.main.async { self.isActive = false }
        self.sendStatus("hr_stopped")
        WKInterfaceDevice.current().play(.stop)
        sendLocalNotification(title: "WalkingPadRemote", body: "Heart rate stopped")
    }

    private func handleSessionEnded(reason: String, error: Error? = nil) {
        guard workoutActive else { return }
        workoutActive = false
        Task {
            let workout = await self.workoutController.endAndFinish()
            if let workout {
                self.sendWorkoutUUID(workout.uuid, endDate: workout.endDate)
            }
        }
        DispatchQueue.main.async { self.isActive = false }
        sendStatus("hr_stopped")
        if let error {
            sendLocalNotification(title: "WalkingPadRemote", body: "Heart rate stopped (\(error.localizedDescription))")
        }
    }

    private func requestAuthorization(completion: @escaping (Bool) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(false)
            return
        }
        let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!
        let distanceType = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)!
        let stepsType = HKQuantityType.quantityType(forIdentifier: .stepCount)!
        let workoutType = HKObjectType.workoutType()
        healthStore.requestAuthorization(
            toShare: [workoutType, energyType, distanceType, stepsType],
            read: [hrType, energyType, distanceType, stepsType]
        ) { success, _ in
            completion(success)
        }
    }

    private func startWorkout() {
        let config = HKWorkoutConfiguration()
        config.activityType = .running
        config.locationType = .indoor
        resetHeartRatePayloadSequence()

        Task {
            do {
                try await startWorkoutViaController(config: config)
                self.workoutActive = true
                DispatchQueue.main.async { self.isActive = true }
                self.sendStatus("hr_started")
                WKInterfaceDevice.current().play(.start)
                self.sendLocalNotification(title: "WalkingPadRemote", body: "Heart rate started")
            } catch {
                self.workoutActive = false
                DispatchQueue.main.async { self.isActive = false }
                self.sendStatus("hr_stopped")
            }
        }
    }

    private func startWorkoutViaController(config: HKWorkoutConfiguration) async throws {
        try await workoutController.start(healthStore: healthStore,
                                          configuration: config,
                                          sessionDelegate: self,
                                          builderDelegate: self)
    }

    private func startWatchConnectivity() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        wcSession = session
    }

    private func canSendToPhone(_ session: WCSession) -> Bool {
        guard session.activationState == .activated else { return false }
        guard session.isCompanionAppInstalled else { return false }
        return true
    }

    private func sendHeartRate(_ value: Double, callbackObservedAt: Date) {
        guard let session = wcSession, canSendToPhone(session) else { return }
        let payload: [String: Any] = [
            "hr": value,
            "hr_callback_observed_at": callbackObservedAt.timeIntervalSince1970,
            "hr_sequence": nextHeartRatePayloadSequence()
        ]
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        } else {
            try? session.updateApplicationContext(payload)
        }
    }

    private func resetHeartRatePayloadSequence() {
        heartRatePayloadSequenceLock.lock()
        heartRatePayloadSequence = 0
        heartRatePayloadSequenceLock.unlock()
    }

    private func nextHeartRatePayloadSequence() -> Int64 {
        heartRatePayloadSequenceLock.lock()
        defer { heartRatePayloadSequenceLock.unlock() }
        if heartRatePayloadSequence < Int64.max {
            heartRatePayloadSequence += 1
        }
        return heartRatePayloadSequence
    }

    private func sendStatus(_ status: String) {
        guard let session = wcSession, canSendToPhone(session) else { return }
        let payload: [String: Any] = ["status": status]
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        } else {
            try? session.updateApplicationContext(payload)
        }
    }

    private func sendWorkoutUUID(_ uuid: UUID, endDate: Date) {
        guard let session = wcSession, canSendToPhone(session) else { return }
        let payload: [String: Any] = [
            "workout_uuid": uuid.uuidString,
            "workout_end": endDate.timeIntervalSince1970
        ]
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        } else {
            session.transferUserInfo(payload)
        }
    }

    private func configureNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self?.notificationsAuthorized = true
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    self?.notificationsAuthorized = granted
                }
            case .denied:
                self?.notificationsAuthorized = false
            @unknown default:
                self?.notificationsAuthorized = false
            }
        }
    }

    private func sendLocalNotification(title: String, body: String) {
        guard notificationsAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
    
    private func handleStats(_ stats: [String: Any]) {
        guard !stats.isEmpty else { return }
        let dm = stats["distanceMetersDelta"] as? Double
        let steps = stats["stepsDelta"] as? Int
        Task { await self.workoutController.addStats(distanceDelta: dm, stepsDelta: steps) }
    }
    
    private func handleWorkoutEvent(_ value: String) {
        Task { await self.workoutController.addEvent(value) }
    }

    private func handleTargetBpm(_ value: Int) {
        DispatchQueue.main.async { self.targetBpm = value }
    }

}

extension WatchHeartRateManager: HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState, date: Date) {
        if toState == .ended || toState == .stopped {
            handleSessionEnded(reason: "ended")
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        handleSessionEnded(reason: "error", error: error)
    }

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let callbackObservedAt = Date()
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate),
              collectedTypes.contains(hrType),
              let stats = workoutBuilder.statistics(for: hrType),
              let quantity = stats.mostRecentQuantity() else {
            return
        }
        let value = quantity.doubleValue(for: HKUnit.count().unitDivided(by: HKUnit.minute()))
        DispatchQueue.main.async { self.bpm = Int(value.rounded()) }
        sendHeartRate(value, callbackObservedAt: callbackObservedAt)
    }
}

extension WatchHeartRateManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    private func handleCommand(_ cmd: String) {
        if cmd == "start_hr" {
            start()
        } else if cmd == "stop_hr" {
            stop()
        } else if cmd == "ping" {
            sendStatus("watch_ok")
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let evt = message["workout_event"] as? String { handleWorkoutEvent(evt); return }
        if let stats = message["stats"] as? [String: Any] {
            handleStats(stats)
            return
        }
        if let target = message["target_bpm"] as? Int {
            handleTargetBpm(target)
            return
        }
        if let cmd = message["cmd"] as? String {
            handleCommand(cmd)
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        if let evt = message["workout_event"] as? String { handleWorkoutEvent(evt); replyHandler(["status": "ok"]); return }
        if let stats = message["stats"] as? [String: Any] {
            handleStats(stats)
            replyHandler(["status": "ok"])
            return
        }
        if let target = message["target_bpm"] as? Int {
            handleTargetBpm(target)
            replyHandler(["status": "ok"])
            return
        }
        if let cmd = message["cmd"] as? String {
            handleCommand(cmd)
        }
        replyHandler(["status": "ok"])
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if let evt = applicationContext["workout_event"] as? String { handleWorkoutEvent(evt); return }
        if let stats = applicationContext["stats"] as? [String: Any] {
            handleStats(stats)
            return
        }
        if let target = applicationContext["target_bpm"] as? Int {
            handleTargetBpm(target)
            return
        }
        if let cmd = applicationContext["cmd"] as? String {
            handleCommand(cmd)
        }
    }
    
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        if let evt = userInfo["workout_event"] as? String { handleWorkoutEvent(evt); return }
        if let stats = userInfo["stats"] as? [String: Any] {
            handleStats(stats)
            return
        }
        if let target = userInfo["target_bpm"] as? Int {
            handleTargetBpm(target)
            return
        }
        if let cmd = userInfo["cmd"] as? String {
            handleCommand(cmd)
        }
    }
}
