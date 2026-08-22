import Foundation

enum ZonePlanProgress {
    static func planSeconds(monthlyPlanMinutes: Int, isWeekly: Bool) -> Double {
        let monthlySeconds = Double(max(0, monthlyPlanMinutes)) * 60.0
        return isWeekly ? monthlySeconds / 4.0 : monthlySeconds
    }

    static func rawProgress(actualSeconds: Double?, planSeconds: Double) -> Double? {
        guard let actualSeconds,
              actualSeconds.isFinite,
              actualSeconds >= 0,
              planSeconds.isFinite,
              planSeconds > 0 else {
            return nil
        }
        return actualSeconds / planSeconds
    }

    static func displayedProgress(_ rawProgress: Double?) -> Double? {
        rawProgress.map { min(1.0, max(0.0, $0)) }
    }

    static func isAchieved(actualSeconds: Double?, planSeconds: Double) -> Bool {
        guard let actualSeconds,
              actualSeconds.isFinite,
              actualSeconds >= 0,
              planSeconds.isFinite,
              planSeconds > 0 else {
            return false
        }
        return actualSeconds >= planSeconds
    }

    static func durationText(seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let totalSeconds = Int(seconds.rounded(.down))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainingSeconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}
