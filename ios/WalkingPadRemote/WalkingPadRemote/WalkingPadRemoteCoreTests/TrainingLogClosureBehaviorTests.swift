#if os(macOS)
import Foundation
import XCTest

final class TrainingLogClosureBehaviorTests: XCTestCase {
    func testProductionCloseDoesNotWaitAndPreservesTerminalOwnership() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: package.appendingPathComponent("WalkingPadRemote/BluetoothManager.swift"), encoding: .utf8)
        let methods = try [
            "private func makeTrainingLogPayload(",
            "private func writeTrainingLogLocked(",
            "private func logTrainingEvent(",
            "private func stopTrainingStructuredLog(",
            "private func startTrainingStructuredLog(",
            "private func scheduleTrainingLogsInventoryRefresh("
        ].map { try declaration($0, in: source) }
        let program = Self.fixture + "\n" + methods.joined(separator: "\n") + "\n}\n" + Self.driver
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let swift = directory.appendingPathComponent("Closure.swift")
        let binary = directory.appendingPathComponent("closure")
        try program.write(to: swift, atomically: true, encoding: .utf8)
        try run("/usr/bin/xcrun", ["swiftc", "-swift-version", "5", swift.path, "-o", binary.path])
        try run(binary.path, [])
    }

    private func declaration(_ signature: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: signature))
        let opening = try XCTUnwrap(source[start.lowerBound...].firstIndex(of: "{"))
        var depth = 1
        var cursor = source.index(after: opening)
        while depth > 0, cursor < source.endIndex {
            if source[cursor] == "{" { depth += 1 }
            if source[cursor] == "}" { depth -= 1 }
            cursor = source.index(after: cursor)
        }
        XCTAssertEqual(depth, 0)
        return String(source[start.lowerBound..<cursor]).replacingOccurrences(of: "private func", with: "func")
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        print(text)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ProductionClosureHarness", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: text])
        }
    }

    private static let fixture = #"""
    import Foundation

    struct Profile { var id: UUID }
    struct RecoveryRecord { var legacySessionID: UUID }
    struct Cooldown {
        var startBpm = 120, endBpm = 110, peakBpm = 130, totalSeconds = 300
        var elapsedSeconds = 240, targetHitElapsedSeconds = 200, hrDropBpm = 10
        var recoveryBpmPerMinute = 3, firstMinSpeedElapsedSeconds = 50
        var firstStableElapsedSeconds = 220, belowTargetSeconds = 20, minSpeedSeconds = 30
        var targetAndMinSpeedSeconds = 15, maxStableStreakSeconds = 10
        var finishReason = "stable", timeoutBlocker = ""
    }
    final class Manager {
        let trainingLogQueue = DispatchQueue(label: "test.legacy.writer")
        let trainingLogIsoFormatter: ISO8601DateFormatter = {
            let value = ISO8601DateFormatter()
            value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return value
        }()
        let trainingLogTimestampFormatter = DateFormatter()
        var logDirectory: URL?
        var lastTrainingLogPath = ""
        var activeNativeWorkoutRecoveryRecord: RecoveryRecord?
        var hrDurationMinutes = 30, hrDecisionIntervalSeconds = 5
        var hrAdaptiveStepEnabled = true, hrSpeedStepKmh = 0.1, hrCooldownMinSpeed = 1.0
        var hrZone1Max = 120, hrZone2Max = 130, hrZone3Max = 140, hrZone4Max = 150
        func trainingLogsDirectoryURL() -> URL? { logDirectory }
        func controllerUnitsTelemetryFields(action: String) -> [String: Any] { ["units_action": action] }
        var trainingLogFileHandle: FileHandle?
        var trainingLogFileURL: URL?
        var trainingLogSessionId: String?
        var inventoryRefreshes = 0
        var installationID = "test-installation"
        var activeUserProfile: Profile? = Profile(id: UUID())
        var activeUserProfileLabel = "Original profile"
        var phase = "ended"
        var cooldownRuntimeState: Cooldown? = Cooldown()
        var isHrControlRunning = false
        var heartRateBPM = 110, lastKnownHeartRateBPM = 110, hrTargetBPM = 140
        var hrSessionPeakBPM = 160, hrMainPeakBPM = 150, hrCooldownTargetBpm = 115
        var speedKmh = 0.0, desiredSpeedKmh = 0.0, deviceTargetSpeedKmh = 0.0
        var deviceReportedSpeedKmh = 0.0, deviceReportedAppSpeedKmh = 0.0, lastSpeedDeltaKmh = 0.0
        var distKm = 2.0, timeSec = 900, stepsCount = 1000
        var treadmillStatusText = "stopped"
        var hrRemainingSeconds = 0, hrCooldownRemainingSeconds = 0, hrAverageBPM = 130
        func currentTargetZoneSnapshot() -> (index: Int, lower: Int, upper: Int) { (2, 130, 145) }
        func currentTrainingPhase() -> String { phase }
        func currentSessionState() -> String { "ended" }
        func mainPhaseAverageBPMSnapshot() -> Int { 140 }
        func zoneSecondsSnapshot() -> [String: Int] { ["Z1": 60] }
        func zone4PlusSecondsSnapshot() -> Int { 10 }
        func refreshTrainingLogsInventory() { inventoryRefreshes += 1 }

        // Reproduce the unchanged serial initialization boundary used by startTrainingStructuredLog.
        func open(_ file: URL, session: String) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try! FileHandle(forWritingTo: file)
            trainingLogQueue.sync {
                trainingLogFileHandle = handle
                trainingLogFileURL = file
                trainingLogSessionId = session
            }
        }
    """#

    private static let driver = #"""
    func rows(_ file: URL) -> [[String: Any]] {
        let data = try! Data(contentsOf: file)
        return data.split(separator: 10).map { try! JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
    }
    func check(_ condition: Bool, _ message: String) {
        guard condition else { print("FAIL: \(message)"); fflush(stdout); exit(1) }
    }
    func drainMain() { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = Manager()
    manager.logDirectory = directory
    let old = directory.appendingPathComponent("old.jsonl")
    let fresh = directory.appendingPathComponent("fresh.jsonl")
    manager.open(old, session: "old-session")
    let oldProfile = manager.activeUserProfile!.id.uuidString
    let held = DispatchSemaphore(value: 0)
    let entered = DispatchSemaphore(value: 0)
    manager.trainingLogQueue.async { entered.signal(); held.wait() }
    entered.wait()
    let release = DispatchTime.now() + .milliseconds(300)
    DispatchQueue.global().asyncAfter(deadline: release) { held.signal() }
    manager.logTrainingEvent("before_close", fields: ["sequence": 1])
    let start = DispatchTime.now().uptimeNanoseconds
    manager.stopTrainingStructuredLog(reason: "confirmed")
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    print("CLOSE_RETURN_MS=\(elapsed)"); fflush(stdout)
    check(elapsed < 100, "main-thread Stop closure waited for 300 ms writer backlog")
    check(manager.inventoryRefreshes == 0, "inventory refreshed before actual close")

    // Mutate every critical terminal identity/context while persistence remains held.
    manager.activeUserProfile = Profile(id: UUID())
    manager.activeUserProfileLabel = "Next profile"
    manager.phase = "main"
    manager.distKm = 99
    manager.timeSec = 9999
    manager.cooldownRuntimeState = nil
    manager.stopTrainingStructuredLog(reason: "duplicate")
    manager.trainingLogQueue.sync {}
    drainMain()
    let original = rows(old)
    check(original.compactMap { $0["event"] as? String } == ["before_close", "session_end"], "order or duplicate terminal record")
    check(original[0]["profile_id"] as? String == oldProfile && original[0]["phase"] as? String == "ended", "queued earlier event inherited later runtime context")
    let end = original.last!
    check(end["session_id"] as? String == "old-session", "terminal session identity")
    check(end["profile_id"] as? String == oldProfile, "terminal profile identity")
    check(end["profile_label"] as? String == "Original profile", "terminal profile label")
    check(end["phase"] as? String == "ended", "terminal phase")
    check(end["distance_km"] as? Double == 2 && end["duration_s"] as? Int == 900, "terminal metrics mutated")
    check(end["cooldown_elapsed_s"] as? Int == 240, "terminal cooldown mutated")
    let written = manager.trainingLogIsoFormatter.date(from: end["ts"] as! String)!
    check(written.timeIntervalSinceNow > -2, "writer timestamp missing")
    check(manager.trainingLogFileHandle == nil && manager.trainingLogFileURL == nil && manager.trainingLogSessionId == nil, "close did not clear writer state")
    check(manager.inventoryRefreshes >= 1, "post-close inventory callback missing")

    // A queued old close and a replacement start keep the existing FIFO writer boundary.
    manager.open(fresh, session: "fresh-session")
    manager.logTrainingEvent("session_start", fields: [:])
    let nextSession = UUID()
    check(manager.startTrainingStructuredLog(trigger: "test", sessionID: nextSession) == nextSession, "actual start lost identity")
    manager.trainingLogQueue.sync {}
    let next = manager.trainingLogFileURL!
    check(manager.trainingLogSessionId == nextSession.uuidString && manager.trainingLogFileHandle != nil, "old close closed replacement log")
    check(rows(next).count == 1 && rows(next)[0]["session_id"] as? String == nextSession.uuidString, "new log cannot accept events")
    check(rows(fresh).map { $0["event"] as! String } == ["session_start", "session_end"], "replacement start ordering")
    manager.logTrainingEvent("override", fields: ["session_id": "explicit", "ts": "explicit-time"])
    manager.trainingLogQueue.sync {}
    check(rows(next).last?["session_id"] as? String == "explicit" && rows(next).last?["ts"] as? String == "explicit-time", "existing explicit field overrides changed")
    manager.stopTrainingStructuredLog(reason: "manual_stop")
    manager.trainingLogQueue.sync {}
    let count = rows(next).count
    drainMain()
    let refreshes = manager.inventoryRefreshes
    manager.stopTrainingStructuredLog(reason: "already_closed")
    manager.trainingLogQueue.sync {}
    drainMain()
    check(rows(next).count == count, "close without handle appended data")
    check(manager.inventoryRefreshes == refreshes + 1, "no-handle inventory behavior changed")

    let failed = directory.appendingPathComponent("failed-start.jsonl")
    manager.open(failed, session: "before-failed-start")
    manager.logDirectory = nil
    let failedSession = UUID()
    check(manager.startTrainingStructuredLog(trigger: "test", sessionID: failedSession) == failedSession, "existing start-failure return contract changed")
    manager.trainingLogQueue.sync {}
    check(manager.trainingLogFileHandle == nil && rows(failed).count == 1, "failed replacement start stranded old log")

    // Existing invalid-payload behavior: skip serialization but still close safely.
    let invalid = directory.appendingPathComponent("invalid.jsonl")
    manager.open(invalid, session: "invalid-session")
    manager.distKm = Double.nan
    manager.stopTrainingStructuredLog(reason: "invalid_metric")
    manager.trainingLogQueue.sync {}
    check(rows(invalid).isEmpty && manager.trainingLogFileHandle == nil, "invalid payload did not preserve close behavior")
    print("ORDER_OWNERSHIP_RESTART_DUPLICATE_NO_HANDLE_INVALID=PASS")
    """#
}
#endif
