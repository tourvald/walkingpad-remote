import Foundation
import SwiftData
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
        let hash = try await Task.detached(priority: .utility) {
            try WorkoutAnalyzerV1.evidenceHash(for: input, policy: policy)
        }.value
        if let existing = try analysisMatching(sessionID: sessionID, hash: hash) {
            return StoredWorkoutAnalysisOutcome(triggerResult: .existing, analysis: existing)
        }
        let analysis = try await Task.detached(priority: .utility) {
            try WorkoutAnalyzerV1.analyze(input, generatedAt: generatedAt, policy: policy)
        }.value
        // Another actor caller can insert the same result while calculation is suspended.
        let existing = try analysisMatching(sessionID: sessionID, hash: analysis.evidenceHash)
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
        let completed = SessionLifecycleState.completed.rawValue
        let incomplete = SessionLifecycleState.incomplete.rawValue
        let cancelled = SessionLifecycleState.cancelled.rawValue
        let descriptor = FetchDescriptor<TelemetryWorkoutSessionV1>(
            predicate: #Predicate {
                $0.lifecycleStateKey == completed || $0.lifecycleStateKey == incomplete
                    || $0.lifecycleStateKey == cancelled
            }, sortBy: [SortDescriptor(\TelemetryWorkoutSessionV1.sessionID)]
        )
        return try modelContext.fetch(descriptor).map {
            try Self.uuid($0.sessionID, as: SessionIDTag.self)
        }
    }

    private func terminalAnalysisInput(
        sessionID: SessionID
    ) throws -> WorkoutAnalysisInput? {
        let key = sessionID.description
        var descriptor = FetchDescriptor<TelemetryWorkoutSessionV1>(
            predicate: #Predicate { $0.sessionID == key }
        )
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else { return nil }
        let session = try Self.domainSession(model)
        guard Self.isAnalysisTerminal(session.lifecycleState) else { return nil }
        return WorkoutAnalysisInput(
            session: session,
            heartRate: try fetchHeartRate(sessionID: sessionID),
            treadmill: try fetchTreadmill(sessionID: sessionID),
            events: try fetchEvents(sessionID: sessionID),
            frames: try fetchFrames(sessionID: sessionID)
        )
    }

    private func analysisMatching(sessionID: SessionID, hash: ContentHash) throws -> WorkoutAnalysisResult? {
        let key = try Self.analysisIdentityKey(
            sessionID: sessionID, analyzerVersion: WorkoutAnalyzerV1.analyzerVersion, hash: hash
        )
        var descriptor = FetchDescriptor<TelemetryWorkoutAnalysisV1>(
            predicate: #Predicate { $0.analysisIdentityKey == key }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.map(Self.domainAnalysis)
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
