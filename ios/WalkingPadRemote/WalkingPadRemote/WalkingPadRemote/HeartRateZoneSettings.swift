import Foundation

struct HeartRateZoneSettings: Codable, Equatable {
    enum Source: String, Codable, CaseIterable {
        case manual
        case appleHealth
    }

    // Ephemeral request ownership; never encoded with profile settings.
    struct AppleReadRequest: Equatable {
        let id = UUID()
        let profileID: UUID

        func canApply(current: Self?, activeProfileID: UUID?, settingsEditable: Bool, taskCancelled: Bool) -> Bool {
            self == current && profileID == activeProfileID && settingsEditable && !taskCancelled
        }
    }

    struct MaximumHeartRateDraft {
        private(set) var text = ""
        private(set) var profileID: UUID?
        private(set) var isEdited = false

        var value: Int? { Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        var isValid: Bool {
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || (value != nil && HeartRateZoneSettings.validMaximum(value))
        }

        mutating func synchronize(value: Int?, profileID: UUID?) {
            guard !isEdited || self.profileID != profileID else { return }
            self.profileID = profileID
            text = value.map(String.init) ?? ""
            isEdited = false
        }

        mutating func edit(_ text: String) {
            self.text = text
            isEdited = true
        }

        func canSave(activeProfileID: UUID?, settingsEditable: Bool) -> Bool {
            isEdited && profileID != nil && profileID == activeProfileID && settingsEditable && isValid
        }

        mutating func markSaved() { isEdited = false }
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
            // The existing training selector ends at 220 BPM (hrZoneRanges).
            // A higher zone-5 lower bound would be silently truncated there.
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
        copy.manualUpperBounds = manualUpperBounds
        return copy
    }
}
