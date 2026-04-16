import Foundation

enum HRSettingsDefaults {
    static let defaultCooldownTargetBpm = 115

    static func resolvedCooldownTargetBpm(savedValue: Int?) -> Int {
        guard let savedValue else {
            return defaultCooldownTargetBpm
        }

        return max(80, min(140, savedValue))
    }
}
