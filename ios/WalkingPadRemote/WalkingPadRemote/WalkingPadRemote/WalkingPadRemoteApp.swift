import SwiftUI

@main
struct WalkingPadRemoteApp: App {
    @StateObject private var manager = BluetoothManager()
    @State private var didRunLaunchMaintenance = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
                .task {
                    runLaunchMaintenanceIfNeeded()
                }
        }
    }

    private func runLaunchMaintenanceIfNeeded() {
        guard !didRunLaunchMaintenance else { return }
        didRunLaunchMaintenance = true

        if TrainingLogMaintenanceLaunchAction.shouldClearTrainingLogs() {
            manager.clearTrainingLogsForActiveProfile()
        }
    }
}
