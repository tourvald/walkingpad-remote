import Foundation

struct HeartRateZoneSettings: Codable, Equatable {
    enum Source: String, Codable, CaseIterable {
        case manual
        case appleHealth
    }

    struct AppleSnapshot: Codable, Equatable {
        let thresholds: [Double]
        let origin: String
        let configuration: String
        let fetchedAt: Date

        // Shared thresholds start the next zone. Keep every integer BPM below it
        // in the preceding zone, including when HealthKit supplies fractional BPM.
        var upperBounds: [Int]? {
            guard thresholds.count == 4,
                  thresholds.allSatisfy({ $0.isFinite && $0 >= 80 && $0 <= 220 }) else { return nil }
            let bounds = thresholds.map { Int(ceil($0)) - 1 }
            guard HeartRateZoneSettings.validBounds(bounds), bounds[3] < 220,
                  zip(thresholds, thresholds.dropFirst()).allSatisfy({ $0 < $1 }) else { return nil }
            return bounds
        }
    }

    var source: Source = .manual
    var manualUpperBounds = [134, 146, 158, 170]
    var appleSnapshot: AppleSnapshot?
    var maximumHeartRate: Int?

    static func validBounds(_ bounds: [Int]) -> Bool {
        guard bounds.count == 4 else { return false }
        return zip(bounds, [80...200, 81...210, 82...220, 83...230]).allSatisfy { $1.contains($0) }
            && zip(bounds, bounds.dropFirst()).allSatisfy { $0 < $1 }
    }

    static func validMaximum(_ value: Int?) -> Bool {
        value.map { (80...250).contains($0) } ?? true
    }

    static func restored(_ saved: Self?, legacyBounds: [Int]) -> Self {
        guard var saved, validBounds(saved.manualUpperBounds), validMaximum(saved.maximumHeartRate) else {
            var settings = Self()
            settings.manualUpperBounds = legacyBounds
            return settings
        }
        if saved.source == .appleHealth && saved.appleSnapshot?.upperBounds == nil {
            saved.source = .manual
        }
        return saved
    }

    var effectiveUpperBounds: [Int] {
        source == .appleHealth ? (appleSnapshot?.upperBounds ?? manualUpperBounds) : manualUpperBounds
    }

    func copiedForNewProfile() -> Self {
        var copy = Self()
        copy.manualUpperBounds = effectiveUpperBounds
        return copy
    }
}
