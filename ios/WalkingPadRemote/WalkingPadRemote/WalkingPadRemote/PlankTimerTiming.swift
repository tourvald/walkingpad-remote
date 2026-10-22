import Foundation

/// Continuous time includes device sleep and is independent of wall-clock edits.
enum PlankTimerTiming {
    static func elapsedSeconds(since start: ContinuousClock.Instant,
                               at now: ContinuousClock.Instant, limit: Int) -> Int {
        let seconds = start.duration(to: now).components.seconds
        return Int(min(Int64(max(0, limit)), max(0, seconds)))
    }
}
