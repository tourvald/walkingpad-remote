import Foundation

enum HRDomainService {
    // Motion output after the existing native-HR preflight has committed, not admission.
    static func initialMotionTargetSpeedKmh(
        deviceTargetSpeedKmh: Double,
        speedKmh: Double,
        desiredSpeedKmh: Double
    ) -> Double? {
        if deviceTargetSpeedKmh <= 0.1 && speedKmh <= 0.2 {
            return 3.0
        } else if deviceTargetSpeedKmh <= 0.1 {
            return desiredSpeedKmh
        }
        return nil
    }

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

    struct AdaptiveThresholdPercents {
        let deadband: Double
        let downLevel2Start: Double
        let downLevel3Start: Double
        let downLevel4Start: Double
        let upLevel2Start: Double
        let upLevel3Start: Double
        let upLevel4Start: Double
    }

    static func heartRateStartAffordanceAvailable(
        treadmillConnected: Bool,
        currentHeartRateVisible: Bool
    ) -> Bool {
        treadmillConnected && currentHeartRateVisible
    }

    static func heartRateRuntimePrerequisitesAllowStart(
        treadmillConnected: Bool,
        watchReachable: Bool,
        currentHeartRateVisible: Bool
    ) -> Bool {
        treadmillConnected && watchReachable && currentHeartRateVisible
    }

    static func applyHeartRateDelivery(
        _ beatsPerMinute: Int,
        now: () -> Date,
        updateCurrent: (Int) -> Void,
        updateLastKnown: (Int) -> Void,
        updateLastReceivedAt: (Date) -> Void,
        recordPredictorInput: (Int) -> Void
    ) {
        updateCurrent(beatsPerMinute)
        updateLastKnown(beatsPerMinute)
        updateLastReceivedAt(now())
        recordPredictorInput(beatsPerMinute)
    }

    static func heartRateStreamIsActive(
        beatsPerMinute: Int,
        hasLastReceivedAt: Bool,
        ageSeconds: Int,
        staleThresholdSeconds: Int
    ) -> Bool {
        beatsPerMinute > 0 && hasLastReceivedAt && ageSeconds <= staleThresholdSeconds
    }

    static func isWithinInitialHeartRateGrace(
        startedAt: Date?,
        now: Date,
        graceSeconds: Int
    ) -> Bool {
        guard let startedAt else { return false }
        return now.timeIntervalSince(startedAt) < TimeInterval(graceSeconds)
    }

    static func missingHeartRateSignalSeconds(
        lastReceivedAt: Date?,
        now: Date,
        noDataMaximumSeconds: Int
    ) -> Int {
        guard let lastReceivedAt else { return noDataMaximumSeconds }
        return max(0, Int(now.timeIntervalSince(lastReceivedAt)))
    }

    static func shouldStopForMissingHeartRateSignal(
        missingSeconds: Int,
        noDataMaximumSeconds: Int
    ) -> Bool {
        missingSeconds >= noDataMaximumSeconds
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
        if appReportedSpeedKmh > 0.05 {
            factualSpeedKmh = appReportedSpeedKmh
        } else if rawReportedSpeedKmh > 0.05 {
            factualSpeedKmh = rawReportedSpeedKmh
        } else if currentActualSpeedKmh > 0.05 {
            factualSpeedKmh = currentActualSpeedKmh
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
}
