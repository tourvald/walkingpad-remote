import Foundation

/// Pure, side-effect-free heart-rate speed decision.
///
/// This is the per-interval "brain" of HR control extracted out of `BluetoothManager`'s
/// 1-second timer tick (the block that decided hold / inertia-hold / set / limit). It is a
/// behavior-preserving extraction: given the same inputs it returns exactly the speed/decision
/// the inline manager code produced. Keeping it pure makes it unit-testable and replayable
/// against recorded `hr_sample` / `hr_decision` telemetry, and lets background/event-driven
/// callers reuse the identical decision without touching the orchestrator.
///
/// The manager remains responsible for all side effects (telemetry, UI strings, sending the
/// BLE speed command, mutating published state). It only builds `Input`, calls `decide`, and
/// executes the returned `Decision`.
enum HRControlDecisionEngine {
    struct Config: Equatable {
        /// Target heart rate the session is steering toward.
        let targetBpm: Int
        /// When false, every non-hold step uses `fixedStepKmh` (FIXED mode, level 4).
        let adaptiveStepEnabled: Bool
        /// Raw user step for FIXED mode; clamped to `[0.1, 2.0]` like the manager.
        let fixedStepKmh: Double
        /// Percent thresholds that map HR deviation to an adaptive step level (L1...L4).
        let thresholds: HRDomainService.AdaptiveThresholdPercents
        /// Look-ahead horizon: `predicted = hr + trend * predictSeconds`.
        let predictSeconds: Double
        /// Inertia margin: while speeding up, hold if the prediction is within this many bpm of target.
        let predictMarginBpm: Int
        /// Running speed bounds used to clamp the next target (and to detect the `limit` case).
        let speedBounds: TreadmillSpeedBoundsService.Bounds
    }

    struct Input: Equatable {
        /// Latest accepted heart-rate sample (bpm).
        let currentHeartRateBpm: Int
        /// HR slope in bpm/second (least-squares over the trend window), or nil if not enough data.
        let trendBpmPerSecond: Double?
        /// Speed the decision is measured against: the device target when known, else the clamped desired speed.
        let currentTargetSpeedKmh: Double
    }

    enum Kind: String, Equatable {
        /// HR within the deadband — no change.
        case hold
        /// Speeding-up path gated by an upward trend/prediction near target — no change.
        case inertiaHold
        /// New target speed applied.
        case set
        /// A change was wanted but the clamp pinned us at a speed bound — no change.
        case limit
    }

    struct Decision: Equatable {
        let kind: Kind
        let nextSpeedKmh: Double
        let currentTargetSpeedKmh: Double
        let diffBpm: Int
        let absDiffPercent: Double
        let deadbandBpm: Int
        let predictedBpm: Int?
        let effectiveBpm: Int
        let trendBpmPerSecond: Double?
        let stepKmh: Double
        let stepLevel: Int
        /// "UP" | "DOWN" | "HOLD" (sign of the HR deviation).
        let directionLabel: String
        /// "L0"..."L4" in adaptive mode, "FIXED" otherwise. "L0" marks a deadband hold.
        let modeLabel: String

        /// Diagnostic tag used in logs/UI, e.g. "DOWN-L3" / "UP-FIXED" / "HOLD-L0".
        var stepTag: String { "\(directionLabel)-\(modeLabel)" }
        /// Signed speed change this decision produces (0 for hold/inertia/limit).
        var speedDeltaKmh: Double { nextSpeedKmh - currentTargetSpeedKmh }
        /// True only when an actual BLE speed command must be sent.
        var changesSpeed: Bool { kind == .set }
    }

    static func decide(config: Config, input: Input) -> Decision {
        let hr = input.currentHeartRateBpm

        // Forward prediction: only ever pushes the effective HR *up*, so downward trends never
        // accelerate a speed reduction (conservative, matches the manager).
        let predictedValue: Double? = input.trendBpmPerSecond.map { Double(hr) + $0 * config.predictSeconds }
        let predictedBpm: Int? = predictedValue.map { Int($0.rounded()) }
        let effectiveBpm = max(hr, predictedBpm ?? hr)

        let diff = effectiveBpm - config.targetBpm
        let absDiff = abs(diff)
        let absDiffPercent = HRDomainService.diffPercent(absDiff: absDiff, targetBpm: config.targetBpm)
        let deadbandBpm = HRDomainService.deadbandBpm(targetBpm: config.targetBpm, thresholds: config.thresholds)

        let direction: Double = diff > 0 ? -1.0 : 1.0
        let directionLabel = diff > 0 ? "DOWN" : (diff < 0 ? "UP" : "HOLD")
        let isIncreasingSpeed = direction > 0

        let fixedStep = max(0.1, min(2.0, config.fixedStepKmh))
        let stepSelection: HRDomainService.AdaptiveStepSelection = {
            if config.adaptiveStepEnabled {
                return HRDomainService.stepFromDiff(
                    diffPercent: absDiffPercent,
                    isIncreasingSpeed: isIncreasingSpeed,
                    thresholds: config.thresholds
                )
            }
            return HRDomainService.AdaptiveStepSelection(level: 4, stepKmh: HRDomainService.quantizeSpeedStep(fixedStep))
        }()
        let step = HRDomainService.quantizeSpeedStep(stepSelection.stepKmh)
        let modeLabel = config.adaptiveStepEnabled ? "L\(stepSelection.level)" : "FIXED"
        let currentTarget = input.currentTargetSpeedKmh

        func decision(_ kind: Kind, nextSpeed: Double, mode: String) -> Decision {
            Decision(
                kind: kind,
                nextSpeedKmh: nextSpeed,
                currentTargetSpeedKmh: currentTarget,
                diffBpm: diff,
                absDiffPercent: absDiffPercent,
                deadbandBpm: deadbandBpm,
                predictedBpm: predictedBpm,
                effectiveBpm: effectiveBpm,
                trendBpmPerSecond: input.trendBpmPerSecond,
                stepKmh: step,
                stepLevel: stepSelection.level,
                directionLabel: directionLabel,
                modeLabel: mode
            )
        }

        // 1) Deadband: HR close enough to target — hold.
        if absDiff <= deadbandBpm {
            let holdMode = config.adaptiveStepEnabled ? "L0" : "FIXED"
            return decision(.hold, nextSpeed: currentTarget, mode: holdMode)
        }

        // 2) Inertia: while speeding up, if HR is trending toward target, hold instead of overshooting.
        if direction > 0, let trend = input.trendBpmPerSecond, trend > 0, let predictedValue {
            let threshold = Double(config.targetBpm - config.predictMarginBpm)
            if predictedValue >= threshold {
                return decision(.inertiaHold, nextSpeed: currentTarget, mode: modeLabel)
            }
        }

        // 3) Apply the step, clamped to bounds. If the clamp pins us, it's a limit (no change).
        let nextSpeed = TreadmillSpeedBoundsService.clampRunningSpeed(currentTarget + direction * step, bounds: config.speedBounds)
        let kind: Kind = (nextSpeed != currentTarget) ? .set : .limit
        return decision(kind, nextSpeed: nextSpeed, mode: modeLabel)
    }
}
