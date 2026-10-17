enum WorkoutDiagnosticExportScope: Equatable {
    case all
    case lastCompletedWorkouts(Int)

    var logDescription: String {
        switch self {
        case .all:
            return "all"
        case .lastCompletedWorkouts(let count):
            return "last_\(count)_workouts"
        }
    }
}

