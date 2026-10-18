import Foundation

struct HRSettingsDTO: Codable {
    let targetBpm: Int
    let durationMinutes: Int
    let adaptiveStepEnabled: Bool
    let decisionIntervalSeconds: Int
    let speedStepKmh: Double
    let adaptiveDeadbandPercent: Double?
    let adaptiveDownLevel2StartPercent: Double?
    let adaptiveDownLevel3StartPercent: Double?
    let adaptiveDownLevel4StartPercent: Double?
    let adaptiveUpLevel2StartPercent: Double?
    let adaptiveUpLevel3StartPercent: Double?
    let adaptiveUpLevel4StartPercent: Double?
    let trendWindowSeconds: Double?
    let trendEmaAlpha: Double?
    let trendSlopeMaxBpmPerSecond: Double?
    var zone1Max: Int?
    var zone2Max: Int?
    var zone3Max: Int?
    var zone4Max: Int?
    let cooldownTargetBpm: Int?
    let cooldownMinSpeed: Double?
    let cooldownMaxMinutes: Int?
    var heartRateZones: HeartRateZoneSettings?

    func copiedForNewProfile() -> Self {
        guard let settings = heartRateZones else { return self }
        var copy = self
        let zones = settings.copiedForNewProfile()
        copy.heartRateZones = zones
        // Keep legacy readers consistent with the isolated nested settings.
        copy.zone1Max = zones.manualUpperBounds[0]
        copy.zone2Max = zones.manualUpperBounds[1]
        copy.zone3Max = zones.manualUpperBounds[2]
        copy.zone4Max = zones.manualUpperBounds[3]
        return copy
    }
}
