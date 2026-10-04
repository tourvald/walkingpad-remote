import XCTest
@testable import WalkingPadCoreLogic

final class BoundedDebugLogTests: XCTestCase {
    func testDebugSurfaceHasNoLegacySnapshotOrPublicationLifecycle() throws {
        let view = try source("ContentView.swift")
        let manager = try source("BluetoothManager.swift")
        for removed in ["Runtime Snapshot", "Copy Logs", "Button(\"Clear\")", "Toggle(\"Logging\"",
                        "Logging is OFF", "manager.debugLog", "copyLogs(",
                        "DebugTreadmillFactualObservationRows", "DebugHeartRateFactualObservationRow"] {
            XCTAssertFalse(view.contains(removed), removed)
        }
        for removed in ["startDebugLogPresentation", "stopDebugLogPresentation", "makeDebugLogSnapshot",
                        "clearDebugLog", "refreshDebugLogSnapshot", "debugLogPresentationTimer",
                        "debugLogPublicationState", "@Published private(set) var debugLog"] {
            XCTAssertFalse(manager.contains(removed), removed)
            XCTAssertFalse(view.contains(removed), removed)
        }
        for removed in ["loggingEnabled", "appendLog(", "logUiAction(", "DebugLogStore", "debugLogStore"] {
            XCTAssertFalse(manager.contains(removed), removed)
        }
    }

    func testDiagnosticShareAndTypedSupportRemainIndependentOfLegacyLogging() throws {
        let view = try source("ContentView.swift")
        let manager = try source("BluetoothManager.swift")
        let card = try source("DebugTrainingLogsCard.swift")
        for preserved in ["DebugTrainingLogsCard(", "DebugHrFailuresCard(", "manager.startTreadmillTestRun()",
                          "manager.stopTreadmillTestRun()", "prepareAndPresentDiagnosticBundle(",
                          "manager.refreshWorkoutHistoryFromV2(reset: true)", "diagnosticBundleTask?.cancel()"] {
            XCTAssertTrue(view.contains(preserved), preserved)
        }
        XCTAssertTrue(card.contains("Поделиться диагностикой"))
        let start = try XCTUnwrap(manager.range(of: "    func prepareDiagnosticBundle("))
        let end = try XCTUnwrap(manager.range(of: "    private func diagnosticWorkoutExportFailureCategory", range: start.upperBound..<manager.endIndex))
        let bundle = String(manager[start.lowerBound..<end.lowerBound])
        for preserved in ["diagnosticSupportSnapshot()", "prepareTelemetryV2Export(scope: scope)",
                          "DiagnosticBundlePackager.create(", "DiagnosticBundlePackager.createSupportOnly("] {
            XCTAssertTrue(bundle.contains(preserved), preserved)
        }
        for forbidden in ["loggingEnabled", "debugLog", "DebugLogStore", "prepareTrainingCsv", "legacy"] {
            XCTAssertFalse(bundle.contains(forbidden), forbidden)
        }
        for preserved in ["return DiagnosticSupportSnapshot(", "runtime: .init(",
                          "nativeHeartRatePreflight: .init(", "controllerUnits: .init(",
                          "treadmill: .init(", "writerHealth: .init(", "lostCriticalCount: writer.lostCriticalCount"] {
            XCTAssertTrue(manager.contains(preserved), preserved)
        }
    }

    private func source(_ name: String) throws -> String {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: directory.appendingPathComponent("WalkingPadRemote/\(name)"), encoding: .utf8)
    }

}
