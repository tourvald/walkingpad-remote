enum TrainingUITreadmillPublicationPolicy {
    static func visibleSpeedKmh(
        appReportedSpeedKmh: Double,
        rawReportedSpeedKmh: Double
    ) -> Double? {
        if appReportedSpeedKmh > 0.05 {
            return appReportedSpeedKmh
        }
        if rawReportedSpeedKmh > 0.05 {
            return rawReportedSpeedKmh
        }
        return nil
    }

    static func shouldPublish(
        currentVisibleSpeedKmh: Double?,
        appReportedSpeedKmh: Double,
        rawReportedSpeedKmh: Double
    ) -> Bool {
        currentVisibleSpeedKmh != visibleSpeedKmh(
            appReportedSpeedKmh: appReportedSpeedKmh,
            rawReportedSpeedKmh: rawReportedSpeedKmh
        )
    }
}
