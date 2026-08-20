import Foundation
import TelemetryAnalysis
import TelemetryDomain

public struct StoredWorkoutAnalysisOutcome: Hashable, Sendable {
    public let triggerResult: PostWorkoutAnalysisTriggerResult
    public let analysis: WorkoutAnalysisResult?

    public init(
        triggerResult: PostWorkoutAnalysisTriggerResult,
        analysis: WorkoutAnalysisResult?
    ) {
        self.triggerResult = triggerResult
        self.analysis = analysis
    }
}

public extension TelemetryStore {
    func analyzeTerminalWorkout(
        sessionID: SessionID,
        generatedAt: Date,
        policy: AnalyzerV1Policy = .default
    ) async throws -> StoredWorkoutAnalysisOutcome {
        guard let input = try terminalAnalysisInput(sessionID: sessionID) else {
            return StoredWorkoutAnalysisOutcome(triggerResult: .ineligible, analysis: nil)
        }
        let analysis = try await Task.detached(priority: .utility) {
            try WorkoutAnalyzerV1.analyze(input, generatedAt: generatedAt, policy: policy)
        }.value
        let existing = try fetchAnalyses(
            sessionID: sessionID,
            analyzerVersion: WorkoutAnalyzerV1.analyzerVersion
        ).first { $0.evidenceHash == analysis.evidenceHash }
        if let existing {
            guard existing.logicalResult == analysis.logicalResult else {
                throw TelemetryStoreError.conflictingAnalysis(
                    "\(sessionID.description)|\(analysis.evidenceHash.lowercaseHexDigest)"
                )
            }
            return StoredWorkoutAnalysisOutcome(triggerResult: .existing, analysis: existing)
        }
        try insertAnalysis(analysis)
        return StoredWorkoutAnalysisOutcome(triggerResult: .inserted, analysis: analysis)
    }

    func pendingTerminalAnalysisSessionIDs() throws -> [SessionID] {
        try fetchSessions().filter { session in
            Self.isAnalysisTerminal(session.lifecycleState)
        }.map(\.sessionID)
    }

    private func terminalAnalysisInput(
        sessionID: SessionID
    ) throws -> WorkoutAnalysisInput? {
        guard let session = try fetchSessions().first(where: {
            $0.sessionID == sessionID
        }), Self.isAnalysisTerminal(session.lifecycleState) else {
            return nil
        }
        return WorkoutAnalysisInput(
            session: session,
            heartRate: try fetchHeartRate(sessionID: sessionID),
            treadmill: try fetchTreadmill(sessionID: sessionID),
            events: try fetchEvents(sessionID: sessionID),
            frames: try fetchFrames(sessionID: sessionID)
        )
    }

    private static func isAnalysisTerminal(_ state: SessionLifecycleState) -> Bool {
        switch state {
        case .completed, .incomplete, .cancelled:
            true
        case .created, .running, .paused:
            false
        }
    }
}

extension TelemetryStore: TelemetryPostWorkoutAnalysisCapability {
    public func analyzeTerminalWorkout(
        sessionID: SessionID
    ) async -> PostWorkoutAnalysisTriggerResult {
        do {
            return try await analyzeTerminalWorkout(
                sessionID: sessionID,
                generatedAt: Date()
            ).triggerResult
        } catch {
            return .failed
        }
    }

    public func resumePendingWorkoutAnalyses() async -> [PostWorkoutAnalysisTriggerResult] {
        do {
            let sessionIDs = try pendingTerminalAnalysisSessionIDs()
            var results: [PostWorkoutAnalysisTriggerResult] = []
            for sessionID in sessionIDs {
                results.append(await analyzeTerminalWorkout(sessionID: sessionID))
            }
            return results
        } catch {
            return [.failed]
        }
    }
}
