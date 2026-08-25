import Foundation

struct TrainingUIHeartRateReadinessPresentation: Equatable {
    let value: String
    let sourceLabel: String?
    let isReady: Bool
}

struct TrainingUIHeartRateActivePresentation: Equatable {
    let currentHeartRateBPM: Int?
    let sourceLabel: String?
    let isReady: Bool
    let isHeld: Bool
}

struct TrainingUIHeartRateAcceptedPresentation: Equatable {
    let heartRateBPM: Int
    let acceptedAt: Date
    let sourceLabel: String?
}

enum TrainingUIHeartRatePresentationHoldPolicy {
    static let holdDurationSeconds: TimeInterval = 10

    /// Keeps recent accepted HR visible without changing factual freshness or timestamps.
    static func presentation(
        factualSnapshot: TrainingUIHeartRateSnapshot,
        lastAcceptedPresentation: TrainingUIHeartRateAcceptedPresentation?,
        now: Date
    ) -> TrainingUIHeartRateActivePresentation {
        if factualSnapshot.isFresh,
           let currentHeartRateBPM = factualSnapshot.currentHeartRateBPM {
            return TrainingUIHeartRateActivePresentation(
                currentHeartRateBPM: currentHeartRateBPM,
                sourceLabel: factualSnapshot.sourceLabel,
                isReady: true,
                isHeld: false
            )
        }

        guard let lastAcceptedPresentation else {
            return unavailablePresentation
        }
        let ageSeconds = now.timeIntervalSince(lastAcceptedPresentation.acceptedAt)
        guard ageSeconds >= 0, ageSeconds < holdDurationSeconds else {
            return unavailablePresentation
        }

        return TrainingUIHeartRateActivePresentation(
            currentHeartRateBPM: lastAcceptedPresentation.heartRateBPM,
            sourceLabel: lastAcceptedPresentation.sourceLabel,
            isReady: true,
            isHeld: true
        )
    }

    private static let unavailablePresentation = TrainingUIHeartRateActivePresentation(
        currentHeartRateBPM: nil,
        sourceLabel: nil,
        isReady: false,
        isHeld: false
    )
}

enum TrainingUIHeartRateReadinessPresentationPolicy {
    /// Maps display freshness to the Training chip without authorizing workout start.
    static func presentation(
        isFresh: Bool,
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
            value: readyValue(sourceLabel: sourceLabel),
            sourceLabel: nil,
            isReady: true
        )
    }

    static func readyValue(sourceLabel: String?) -> String {
        guard let sourceLabel,
              !sourceLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Готов"
        }
        return sourceLabel
    }
}
