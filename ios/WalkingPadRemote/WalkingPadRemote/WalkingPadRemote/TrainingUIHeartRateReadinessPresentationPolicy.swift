struct TrainingUIHeartRateReadinessPresentation: Equatable {
    let value: String
    let sourceLabel: String?
    let isReady: Bool
}

enum TrainingUIHeartRateReadinessPresentationPolicy {
    /// Maps display freshness to the Training chip without authorizing workout start.
    static func presentation(
        isFresh: Bool,
        currentHeartRateBPM: Int?,
        sourceLabel: String?,
        isPreparing: Bool
    ) -> TrainingUIHeartRateReadinessPresentation {
        if isPreparing {
            return TrainingUIHeartRateReadinessPresentation(
                value: "Ожидание",
                sourceLabel: nil,
                isReady: false
            )
        }

        guard isFresh else {
            return TrainingUIHeartRateReadinessPresentation(
                value: "При старте",
                sourceLabel: nil,
                isReady: false
            )
        }

        return TrainingUIHeartRateReadinessPresentation(
            value: currentHeartRateBPM.map { "\($0) bpm" } ?? "Доступен",
            sourceLabel: sourceLabel,
            isReady: true
        )
    }
}
