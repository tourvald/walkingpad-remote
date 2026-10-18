import Foundation
import TelemetryDomain

enum IntervalWorkoutRuntime {
    struct Plan: Equatable {
        // Owner-approved temporary duration for V1 testing, not the full protocol.
        static let warmupSeconds = 300
        static let workSeconds = 240
        static let recoverySeconds = 180
        let maximumHeartRate: Int
        let cycles: Int

        init?(maximumHeartRate: Int?, cycles: Int) {
            guard let maximumHeartRate, (80...250).contains(maximumHeartRate),
                  (1...4).contains(cycles) else { return nil }
            self.maximumHeartRate = maximumHeartRate
            self.cycles = cycles
        }

        func bpm(_ fraction: Double) -> Int {
            Int((Double(maximumHeartRate) * fraction).rounded())
        }

        var workRange: ClosedRange<Int> {
            Int(ceil(Double(maximumHeartRate) * 0.85))...Int(floor(Double(maximumHeartRate) * 0.95))
        }
        var recoveryCeilingBPM: Int { Int(floor(Double(maximumHeartRate) * 0.70)) }
        var warmupRange: ClosedRange<Int> { bpm(0.60)...bpm(0.70) }
        var totalSeconds: Int {
            Self.warmupSeconds + cycles * Self.workSeconds + (cycles - 1) * Self.recoverySeconds
        }
    }

    enum Phase: String, Equatable { case warmup, work, recovery, cooldown }

    struct State: Equatable {
        let plan: Plan
        private(set) var phase: Phase = .warmup
        private(set) var cycle = 0
        private(set) var phaseStartedSeconds: Double = 0
        private(set) var elapsedSeconds: Double = 0
        private(set) var completedPlannedSeconds = 0
        private(set) var finishReason: String?
        private(set) var workElapsedSeconds: Double = 0
        private(set) var coveredWorkSeconds: Double = 0
        private(set) var inRangeSeconds: Double = 0
        private(set) var aboveRangeSeconds: Double = 0
        private var upperLimitObserved = false
        private var previousBPM: Int?
        private var previousValidUntil: Double = 0

        init(plan: Plan) { self.plan = plan }

        var telemetryPhase: WorkoutPhase {
            switch phase {
            case .warmup: .warmup
            case .work: .main
            case .recovery: .other("interval_recovery")
            case .cooldown: .cooldown
            }
        }
        var targetBPM: Int {
            phase == .recovery ? plan.recoveryCeilingBPM
                : plan.bpm(phase == .work ? 0.90 : (phase == .warmup ? 0.65 : 0.70))
        }
        var targetRange: ClosedRange<Int> {
            switch phase {
            case .work: plan.workRange
            case .recovery: 0...plan.recoveryCeilingBPM
            case .warmup, .cooldown: plan.warmupRange
            }
        }
        var durationSeconds: Int {
            switch phase {
            case .warmup: Plan.warmupSeconds
            case .work: Plan.workSeconds
            case .recovery: Plan.recoverySeconds
            case .cooldown: 0
            }
        }
        var remainingSeconds: Int {
            Int(ceil(max(0, Double(durationSeconds) - (elapsedSeconds - phaseStartedSeconds))))
        }
        var mainRemainingSeconds: Int {
            phase == .cooldown ? 0 : max(1, plan.totalSeconds - completedPlannedSeconds
                - Int(min(Double(durationSeconds), elapsedSeconds - phaseStartedSeconds)))
        }
        var progress: Double {
            phase == .cooldown ? 1 : min(1, Double(plan.totalSeconds - mainRemainingSeconds)
                / Double(plan.totalSeconds))
        }

        // Retain accepted excursions across callbacks; only tick may change phase.
        mutating func observeHeartRate(_ bpm: Int, sampleAgeSeconds: Double) -> Bool {
            guard !upperLimitObserved, phase != .cooldown,
                  sampleAgeSeconds.isFinite, (0...7).contains(sampleAgeSeconds),
                  Double(bpm) > Double(plan.maximumHeartRate) * 0.95 else { return false }
            upperLimitObserved = true
            return true
        }

        mutating func tick(elapsed: Double, heartRate: Int?, validForSeconds: Double) {
            guard elapsed.isFinite, elapsed >= elapsedSeconds, phase != .cooldown else { return }
            let phaseEnd = phaseStartedSeconds + Double(durationSeconds)
            if phase == .work {
                let end = min(elapsed, phaseEnd)
                workElapsedSeconds += max(0, end - elapsedSeconds)
                let covered = max(0, min(end, previousValidUntil) - elapsedSeconds)
                if let previousBPM {
                    coveredWorkSeconds += covered
                    if plan.workRange.contains(previousBPM) { inRangeSeconds += covered }
                    if Double(previousBPM) > Double(plan.maximumHeartRate) * 0.95 {
                        aboveRangeSeconds += covered
                    }
                }
            }
            elapsedSeconds = elapsed
            previousBPM = heartRate
            previousValidUntil = elapsed + (validForSeconds.isFinite ? max(0, validForSeconds) : 0)

            if let heartRate { _ = observeHeartRate(heartRate, sampleAgeSeconds: 0) }
            if upperLimitObserved {
                finish(reason: "above_95_percent")
                return
            }
            guard elapsed >= phaseEnd else { return }
            guard let heartRate else {
                finish(reason: "heart_rate_unavailable_at_transition")
                return
            }
            completedPlannedSeconds += durationSeconds
            phaseStartedSeconds = elapsed
            switch phase {
            case .warmup:
                cycle = 1
                phase = .work
            case .work:
                if cycle == plan.cycles { finish(reason: "cycles_completed") }
                else { phase = .recovery }
            case .recovery:
                if heartRate <= plan.recoveryCeilingBPM { cycle += 1; phase = .work }
                else { finish(reason: "recovery_target_not_reached") }
            case .cooldown: break
            }
        }

        mutating func finish(reason: String) {
            phase = .cooldown
            finishReason = reason
        }

        func evidence(reason: String? = nil) -> IntervalWorkoutContext {
            .init(maximumHeartRate: plan.maximumHeartRate, plannedCycles: plan.cycles,
                  cycle: cycle, phase: phase.rawValue, phaseRemainingSeconds: remainingSeconds,
                  workElapsedSeconds: workElapsedSeconds, coveredWorkSeconds: coveredWorkSeconds,
                  inRangeSeconds: inRangeSeconds, aboveRangeSeconds: aboveRangeSeconds,
                  finishReason: reason ?? finishReason)
        }
    }

    static func recoverySpeed(current: Double, minimum: Double, step: Double) -> Double {
        HRDomainService.cooldownNextTargetSpeedKmh(
            currentSentSpeedKmh: current, minSpeedKmh: min(current, minimum),
            reductionStepKmh: max(0.1, min(2, step))
        ) ?? current
    }
}
