import SwiftUI
import HealthKit
import HealthKitUI
import UIKit

@available(iOS 26.0, *)
final class WalkingPadRemoteSceneDelegate: UIResponder, UIWindowSceneDelegate {}

@available(iOS 26.0, *)
@MainActor
final class WalkingPadRemoteAppDelegate: NSObject, UIApplicationDelegate {
    typealias RecoveryHandler = (HKWorkoutSession?, Error?) -> Void

    var recoveryAvailabilityHandler: ((Bool) -> Void)? {
        didSet { deliverPendingRecoveryAvailabilityIfPossible() }
    }
    var recoveryRequestHandler: (() -> Void)? {
        didSet { deliverPendingRecoveryRequestIfPossible() }
    }
    var recoveryHandler: RecoveryHandler? {
        didSet { deliverPendingRecoveryIfPossible() }
    }

    private let healthStore = HKHealthStore()
    private var recoveryRequestGate = ActiveWorkoutRecoveryRequestGate()
    private var pendingRecoveryAvailability: Bool?
    private var recoveryRequestPendingDelivery = false
    private var pendingRecoveryResult: (HKWorkoutSession?, Error?)?

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        deliverRecoveryAvailability(options.shouldHandleActiveWorkoutRecovery)
        if recoveryRequestGate.shouldRequestRecovery(
            sceneSessionID: connectingSceneSession.persistentIdentifier,
            recoveryRequested: options.shouldHandleActiveWorkoutRecovery
        ) {
            deliverRecoveryRequest()
            healthStore.recoverActiveWorkoutSession { [weak self] session, error in
                DispatchQueue.main.async {
                    self?.deliverRecovery(session: session, error: error)
                }
            }
        }

        let configuration = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = WalkingPadRemoteSceneDelegate.self
        return configuration
    }

    private func deliverRecoveryAvailability(_ recoveryRequested: Bool) {
        guard let recoveryAvailabilityHandler else {
            pendingRecoveryAvailability = pendingRecoveryAvailability == true
                || recoveryRequested
            return
        }
        recoveryAvailabilityHandler(recoveryRequested)
    }

    private func deliverPendingRecoveryAvailabilityIfPossible() {
        guard let recoveryAvailabilityHandler,
              let pendingRecoveryAvailability else { return }
        self.pendingRecoveryAvailability = nil
        recoveryAvailabilityHandler(pendingRecoveryAvailability)
    }

    private func deliverRecoveryRequest() {
        guard let recoveryRequestHandler else {
            recoveryRequestPendingDelivery = true
            return
        }
        recoveryRequestHandler()
    }

    private func deliverPendingRecoveryRequestIfPossible() {
        guard recoveryRequestPendingDelivery, let recoveryRequestHandler else { return }
        recoveryRequestPendingDelivery = false
        recoveryRequestHandler()
    }

    private func deliverRecovery(session: HKWorkoutSession?, error: Error?) {
        guard let recoveryHandler else {
            pendingRecoveryResult = (session, error)
            return
        }
        recoveryHandler(session, error)
    }

    private func deliverPendingRecoveryIfPossible() {
        guard let recoveryHandler, let pendingRecoveryResult else { return }
        self.pendingRecoveryResult = nil
        recoveryHandler(pendingRecoveryResult.0, pendingRecoveryResult.1)
    }
}

@main
struct WalkingPadRemoteApp: App {
    @UIApplicationDelegateAdaptor(WalkingPadRemoteAppDelegate.self)
    private var appDelegate
    @StateObject private var manager: BluetoothManager

    init() {
        let manager = BluetoothManager()
        _manager = StateObject(wrappedValue: manager)
        appDelegate.recoveryAvailabilityHandler = { [weak manager] recoveryRequested in
            manager?.handleActiveWorkoutRecoveryAvailability(
                recoveryRequested: recoveryRequested
            )
        }
        appDelegate.recoveryRequestHandler = { [weak manager] in
            manager?.handleActiveWorkoutRecoveryRequest()
        }
        appDelegate.recoveryHandler = { [weak manager] session, error in
            manager?.handleActiveWorkoutRecovery(session: session, error: error)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
        }
    }
}
