public enum PostWorkoutAnalysisTriggerResult: String, Codable, Hashable, Sendable {
    case inserted
    case existing
    case ineligible
    case failed
}

/// Optional persistence capability discovered by the runtime after recorder
/// finalization. Runtime callers must ignore the result: analysis is downstream
/// derived data and never a control, safety, or session-completion dependency.
public protocol TelemetryPostWorkoutAnalysisCapability: Sendable {
    func analyzeTerminalWorkout(
        sessionID: SessionID
    ) async -> PostWorkoutAnalysisTriggerResult

    func resumePendingWorkoutAnalyses() async -> [PostWorkoutAnalysisTriggerResult]
}
