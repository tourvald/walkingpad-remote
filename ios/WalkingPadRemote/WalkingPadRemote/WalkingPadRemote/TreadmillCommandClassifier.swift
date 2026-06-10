import Foundation

/// Classifies an outbound BLE command — by its human-readable label — into a
/// stable `source` taxonomy for forensic telemetry.
///
/// This is **diagnostics only**: the result is written to the training log so we
/// can reconstruct *who* asked for each write (the user vs. an automatic loop)
/// when auditing treadmill-controller behaviour. It never influences control
/// flow, gating, or what bytes are sent.
///
/// Pure and side-effect free so it can be unit-tested in isolation.
enum TreadmillCommandClassifier {
    enum Source: String {
        case userManual = "user_manual"
        case hrAlgorithm = "hr_algorithm"
        case cooldown = "cooldown"
        case testRun = "test_run"
        case start = "start"
        case stop = "stop"
        case stopAssist = "stop_assist"
        case protocolControl = "protocol_control"
        case statusQuery = "status_query"
        case other = "other"
    }

    /// Maps a command label (as passed to `writeCommand`) to its originating source.
    ///
    /// Order matters: the most specific markers are checked first so that, e.g.,
    /// `"SPEED 3.0 km/h (HR)"` classifies as `.hrAlgorithm` rather than `.userManual`,
    /// and `"STOP retry"` / `"MODE STANDBY"` classify as `.stopAssist` rather than
    /// `.stop` / `.start`.
    static func source(forLabel label: String) -> Source {
        let l = label.lowercased()

        // Stop-assist retries and the standby that follows a stop come first:
        // they must not be mistaken for a user stop or a start.
        if l.contains("retry") || l.contains("standby") { return .stopAssist }

        // Automatic speed sources tag themselves with a parenthesised suffix.
        if l.contains("(hr)") { return .hrAlgorithm }
        if l.contains("(cooldown)") { return .cooldown }
        if l.contains("(test)") { return .testRun }

        // Protocol housekeeping / read-only queries.
        if l.contains("request control") { return .protocolControl }
        if l.contains("status") { return .statusQuery }

        // Plain stop (user button or session end).
        if l.hasPrefix("stop") { return .stop }

        // Start sequence: manual-mode switch, start_belt, FTMS/FitShow start/resume.
        if l.contains("start") || l.contains("resume") || l.contains("mode manual") { return .start }

        // Anything beginning with SPEED that wasn't tagged above is a manual change.
        if l.hasPrefix("speed") { return .userManual }

        return .other
    }
}
