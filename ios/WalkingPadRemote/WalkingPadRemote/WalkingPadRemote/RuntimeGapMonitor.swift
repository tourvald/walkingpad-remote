import Foundation

/// Detects stalls in the app's periodic runtime loop (the 1-second HR-session tick).
///
/// While an HR session is active the tick fires once per second. When iOS suspends the app —
/// e.g. the user switches to another app mid-session — the timer stops firing, so the first tick
/// after resume is late by the time spent away. This type turns that lateness into a reportable
/// `Gap`.
///
/// It is intentionally **observational only**: it never changes treadmill behavior. The caller
/// logs the gap to telemetry so background stalls are visible in exported training logs. Keeping
/// it pure (a single function of its inputs) makes it unit-testable and free of side effects.
enum RuntimeGapMonitor {
    struct Gap: Equatable {
        /// Wall-clock seconds during which the runtime loop did not tick.
        let seconds: Double
        /// Expected tick cadence, carried through for context in logs.
        let expectedIntervalSeconds: Double
    }

    /// Returns a `Gap` when `now` is at least `minReportableSeconds` after `lastTickAt`.
    ///
    /// Returns `nil` for the first tick of a session (`lastTickAt == nil`), when the clock did not
    /// advance past the threshold (normal cadence), or when `now` precedes `lastTickAt` (clock moved
    /// backward) — only a genuine forward stall is reported.
    static func evaluate(
        lastTickAt: Date?,
        now: Date,
        expectedIntervalSeconds: Double,
        minReportableSeconds: Double
    ) -> Gap? {
        guard let lastTickAt else { return nil }
        let elapsed = now.timeIntervalSince(lastTickAt)
        guard elapsed >= minReportableSeconds else { return nil }
        return Gap(seconds: elapsed, expectedIntervalSeconds: expectedIntervalSeconds)
    }
}
