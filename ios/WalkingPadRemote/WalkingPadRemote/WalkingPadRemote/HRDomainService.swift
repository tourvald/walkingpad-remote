import Foundation

enum HRDomainService {
    struct AdaptiveStepSelection {
        let level: Int
        let stepKmh: Double
    }

    struct CooldownSpeedSnapshot: Equatable {
        let observedSpeedKmh: Double
        let controllerSpeedKmh: Double
        let factualSpeedKmh: Double?
    }

    struct CooldownPlan {
        let totalSeconds: Int
    }

    struct AdaptiveThresholdPercents: Equatable {
        let deadband: Double
        let downLevel2Start: Double
        let downLevel3Start: Double
        let downLevel4Start: Double
        let upLevel2Start: Double
        let upLevel3Start: Double
        let upLevel4Start: Double
    }

    static func quantizeSpeedStep(_ value: Double) -> Double {
        max(0.1, (value * 10.0).rounded() / 10.0)
    }

    static func diffPercent(absDiff: Int, targetBpm: Int) -> Double {
        let safeTarget = max(1, targetBpm)
        return (Double(absDiff) / Double(safeTarget)) * 100.0
    }

    static func diffBpm(forPercent percent: Double, targetBpm: Int) -> Int {
        let safeTarget = max(1, targetBpm)
        return max(1, Int(round((Double(safeTarget) * percent) / 100.0)))
    }

    static func deadbandBpm(targetBpm: Int, thresholds: AdaptiveThresholdPercents) -> Int {
        diffBpm(forPercent: thresholds.deadband, targetBpm: targetBpm)
    }

    static func stepFromDiff(
        diffPercent: Double,
        isIncreasingSpeed: Bool,
        thresholds: AdaptiveThresholdPercents
    ) -> AdaptiveStepSelection {
        let level: Int
        if isIncreasingSpeed {
            if diffPercent >= thresholds.upLevel4Start {
                level = 4
            } else if diffPercent >= thresholds.upLevel3Start {
                level = 3
            } else if diffPercent >= thresholds.upLevel2Start {
                level = 2
            } else {
                level = 1
            }
        } else {
            if diffPercent >= thresholds.downLevel4Start {
                level = 4
            } else if diffPercent >= thresholds.downLevel3Start {
                level = 3
            } else if diffPercent >= thresholds.downLevel2Start {
                level = 2
            } else {
                level = 1
            }
        }

        return AdaptiveStepSelection(level: level, stepKmh: stepForLevel(level))
    }

    static func stepForLevel(_ level: Int) -> Double {
        let normalized = max(1, min(4, level))
        return Double(normalized) * 0.1
    }

    static func cooldownPlan(
        baseMinutes: Int,
        startBpm: Int,
        targetBpm: Int
    ) -> CooldownPlan {
        let baseSeconds = max(60, baseMinutes * 60)
        let excessBpm = max(0, startBpm - targetBpm)

        let extraSeconds: Int
        switch excessBpm {
        case ..<15:
            extraSeconds = 0
        case ..<30:
            extraSeconds = 60
        case ..<45:
            extraSeconds = 120
        default:
            extraSeconds = 180
        }

        return CooldownPlan(totalSeconds: baseSeconds + extraSeconds)
    }

    static func cooldownSpeedSnapshot(
        desiredSpeedKmh: Double,
        deviceTargetSpeedKmh: Double,
        appReportedSpeedKmh: Double,
        rawReportedSpeedKmh: Double,
        currentActualSpeedKmh: Double
    ) -> CooldownSpeedSnapshot {
        let controllerSpeedKmh = max(0, max(desiredSpeedKmh, deviceTargetSpeedKmh))

        let factualSpeedKmh: Double?
        if rawReportedSpeedKmh > 0.05 {
            factualSpeedKmh = rawReportedSpeedKmh
        } else if currentActualSpeedKmh > 0.05 {
            factualSpeedKmh = currentActualSpeedKmh
        } else if appReportedSpeedKmh > 0.05 {
            factualSpeedKmh = appReportedSpeedKmh
        } else {
            factualSpeedKmh = nil
        }

        return CooldownSpeedSnapshot(
            observedSpeedKmh: factualSpeedKmh ?? controllerSpeedKmh,
            controllerSpeedKmh: controllerSpeedKmh,
            factualSpeedKmh: factualSpeedKmh
        )
    }

    static func cooldownReductionStepKmh(
        baseStepKmh: Double,
        currentBpm: Int,
        targetBpm: Int,
        startBpm: Int,
        elapsedSeconds: Int,
        totalSeconds: Int
    ) -> Double {
        let safeBaseStep = max(0.1, baseStepKmh)
        let currentExcessBpm = max(0, currentBpm - targetBpm)
        let startExcessBpm = max(0, startBpm - targetBpm)
        let progress = totalSeconds > 0 ? min(1.0, max(0.0, Double(elapsedSeconds) / Double(totalSeconds))) : 1.0

        var factor = 1.0
        if currentExcessBpm >= 20 {
            factor += 0.5
        } else if currentExcessBpm >= 10 {
            factor += 0.25
        }

        if progress < 0.25 {
            if startExcessBpm >= 45 {
                factor += 0.5
            } else if startExcessBpm >= 30 {
                factor += 0.25
            }
        } else if progress < 0.5, startExcessBpm >= 45 {
            factor += 0.25
        }

        let scaledStep = min(1.0, safeBaseStep * factor)
        return quantizeSpeedStep(scaledStep)
    }

    static func cooldownNextTargetSpeedKmh(
        currentSentSpeedKmh: Double,
        minSpeedKmh: Double,
        reductionStepKmh: Double
    ) -> Double? {
        let rawTarget = currentSentSpeedKmh - reductionStepKmh
        let target = max(minSpeedKmh, rawTarget)
        return abs(target - currentSentSpeedKmh) >= 0.01 ? target : nil
    }

    // MARK: - HR trend estimation

    /// One exponential-moving-average smoothing step for a raw HR sample.
    /// First sample (no previous EMA) returns the raw value unchanged.
    static func emaSmooth(previousEma: Double?, raw: Double, alpha: Double) -> Double {
        guard let ema = previousEma else { return raw }
        return ema + alpha * (raw - ema)
    }

    /// Least-squares HR slope (bpm/second) over recent smoothed samples, clamped to ±clampMax.
    /// Returns nil when there are too few samples or the observed window is too short to trust.
    /// `time` may use any consistent base (e.g. seconds since 1970); only differences matter.
    static func trendSlopeBpmPerSecond(
        samples: [(time: TimeInterval, value: Double)],
        minSamples: Int,
        minWindowSeconds: Double,
        clampMaxBpmPerSecond: Double
    ) -> Double? {
        guard samples.count >= minSamples,
              let first = samples.first,
              let last = samples.last else { return nil }
        let span = last.time - first.time
        guard span >= minWindowSeconds else { return nil }
        let t0 = first.time
        var sumT = 0.0
        var sumY = 0.0
        var sumTT = 0.0
        var sumTY = 0.0
        for sample in samples {
            let t = sample.time - t0
            sumT += t
            sumY += sample.value
            sumTT += t * t
            sumTY += t * sample.value
        }
        let n = Double(samples.count)
        let denom = (n * sumTT) - (sumT * sumT)
        guard denom > 0.0001 else { return nil }
        let slope = (n * sumTY - sumT * sumY) / denom
        return max(-clampMaxBpmPerSecond, min(clampMaxBpmPerSecond, slope))
    }
}
