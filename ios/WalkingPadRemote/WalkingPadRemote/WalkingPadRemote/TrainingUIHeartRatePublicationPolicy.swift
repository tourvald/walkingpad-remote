struct TrainingUIHeartRateSnapshot: Equatable {
    let isFresh: Bool
    let currentHeartRateBPM: Int?
    let sourceLabel: String?
}

enum TrainingUIHeartRatePublicationPolicy {
    static func snapshot(
        isNativeHeartRateCurrent: Bool,
        isHeartRateStreamActive: Bool,
        heartRateBPM: Int
    ) -> TrainingUIHeartRateSnapshot {
        let isFresh = isNativeHeartRateCurrent && isHeartRateStreamActive
        let currentHeartRateBPM = isFresh && heartRateBPM > 0
            ? heartRateBPM
            : nil
        return TrainingUIHeartRateSnapshot(
            isFresh: isFresh,
            currentHeartRateBPM: currentHeartRateBPM,
            sourceLabel: currentHeartRateBPM == nil ? nil : "HealthKit"
        )
    }
}
