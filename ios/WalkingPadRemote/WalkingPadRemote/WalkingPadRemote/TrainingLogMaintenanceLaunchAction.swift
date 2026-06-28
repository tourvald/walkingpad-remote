import Foundation

enum TrainingLogMaintenanceLaunchAction {
    static let clearTrainingLogsArgument = "--clear-training-logs-on-launch"

    static func shouldClearTrainingLogs(arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains(clearTrainingLogsArgument)
    }
}
