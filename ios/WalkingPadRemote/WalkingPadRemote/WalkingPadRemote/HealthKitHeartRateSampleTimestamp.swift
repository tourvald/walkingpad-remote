import Foundation

enum HealthKitHeartRateSampleTimestamp {
    static func resolve(from mostRecentSampleInterval: DateInterval?) -> Date? {
        mostRecentSampleInterval?.end
    }
}
