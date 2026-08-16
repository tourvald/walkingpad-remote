import OSLog

public enum TelemetryInstrumentationResult: String, Codable, Sendable {
    case success
    case incomplete
    case failed
    case cancelled
}

/// Privacy-safe performance diagnostics for Telemetry V2.
///
/// Signpost names and categories are static. The API accepts only aggregate
/// counts, coarse results, and durations; it has no surface for workout values
/// or identifiers.
public struct TelemetryPerformanceInstrumentation: Sendable {
    public struct ControlInterval: Sendable {
        fileprivate let state: OSSignpostIntervalState
    }

    public struct PersistenceInterval: Sendable {
        fileprivate let state: OSSignpostIntervalState
    }

    public struct LifecycleInterval: Sendable {
        fileprivate let state: OSSignpostIntervalState
    }

    public struct SoakInterval: Sendable {
        fileprivate let state: OSSignpostIntervalState
    }

    public static let system = TelemetryPerformanceInstrumentation(enabled: true)
    public static let disabled = TelemetryPerformanceInstrumentation(enabled: false)

    private static let subsystem = "com.tourvald.walkingpad.telemetry-v2"

    private let controlSignposter: OSSignposter
    private let ingressSignposter: OSSignposter
    private let persistenceSignposter: OSSignposter
    private let lifecycleSignposter: OSSignposter
    private let analysisSignposter: OSSignposter
    private let soakSignposter: OSSignposter

    public init(enabled: Bool) {
        if enabled {
            controlSignposter = OSSignposter(
                subsystem: Self.subsystem,
                category: "ControlObservation"
            )
            ingressSignposter = OSSignposter(
                subsystem: Self.subsystem,
                category: "RecorderIngress"
            )
            persistenceSignposter = OSSignposter(
                subsystem: Self.subsystem,
                category: "Persistence"
            )
            lifecycleSignposter = OSSignposter(
                subsystem: Self.subsystem,
                category: "SessionLifecycle"
            )
            analysisSignposter = OSSignposter(
                subsystem: Self.subsystem,
                category: "PostWorkoutAnalysis"
            )
            soakSignposter = OSSignposter(
                subsystem: Self.subsystem,
                category: "IntegratedSoak"
            )
        } else {
            controlSignposter = .disabled
            ingressSignposter = .disabled
            persistenceSignposter = .disabled
            lifecycleSignposter = .disabled
            analysisSignposter = .disabled
            soakSignposter = .disabled
        }
    }

    public func measureControlCycle<T>(_ operation: () throws -> T) rethrows -> T {
        try controlSignposter.withIntervalSignpost(
            "ControlCycleComputation",
            id: controlSignposter.makeSignpostID(),
            around: operation
        )
    }

    public func beginControlCycle() -> ControlInterval {
        ControlInterval(
            state: controlSignposter.beginInterval(
                "ControlCycleComputation",
                id: controlSignposter.makeSignpostID()
            )
        )
    }

    public func endControlCycle(_ interval: ControlInterval) {
        controlSignposter.endInterval("ControlCycleComputation", interval.state)
    }

    public func measureIngress<T>(_ operation: () throws -> T) rethrows -> T {
        try ingressSignposter.withIntervalSignpost(
            "TelemetryIngressEnqueue",
            id: ingressSignposter.makeSignpostID(),
            around: operation
        )
    }

    public func beginPersistenceBatch(recordCount: Int) -> PersistenceInterval {
        PersistenceInterval(
            state: persistenceSignposter.beginInterval(
                "PersistenceBatchTransaction",
                id: persistenceSignposter.makeSignpostID(),
                "record_count=\(recordCount, privacy: .public)"
            )
        )
    }

    public func endPersistenceBatch(
        _ interval: PersistenceInterval,
        result: TelemetryInstrumentationResult
    ) {
        persistenceSignposter.endInterval(
            "PersistenceBatchTransaction",
            interval.state,
            "result=\(result.rawValue, privacy: .public)"
        )
    }

    public func beginSessionLifecycle() -> LifecycleInterval {
        LifecycleInterval(
            state: lifecycleSignposter.beginInterval(
                "SessionFinishOrRecovery",
                id: lifecycleSignposter.makeSignpostID()
            )
        )
    }

    public func endSessionLifecycle(
        _ interval: LifecycleInterval,
        result: TelemetryInstrumentationResult
    ) {
        lifecycleSignposter.endInterval(
            "SessionFinishOrRecovery",
            interval.state,
            "result=\(result.rawValue, privacy: .public)"
        )
    }

    /// Reserved observation point for Issue #33. It does not run analysis.
    public func emitPostWorkoutAnalysisPlaceholder(
        result: TelemetryInstrumentationResult
    ) {
        analysisSignposter.emitEvent(
            "PostWorkoutAnalysisPlaceholder",
            id: analysisSignposter.makeSignpostID(),
            "result=\(result.rawValue, privacy: .public)"
        )
    }

    public func beginIntegratedSoak(simulatedMinutes: Int) -> SoakInterval {
        SoakInterval(
            state: soakSignposter.beginInterval(
                "IntegratedSimulatedSoak",
                id: soakSignposter.makeSignpostID(),
                "simulated_minutes=\(simulatedMinutes, privacy: .public)"
            )
        )
    }

    public func endIntegratedSoak(
        _ interval: SoakInterval,
        result: TelemetryInstrumentationResult
    ) {
        soakSignposter.endInterval(
            "IntegratedSimulatedSoak",
            interval.state,
            "result=\(result.rawValue, privacy: .public)"
        )
    }
}
