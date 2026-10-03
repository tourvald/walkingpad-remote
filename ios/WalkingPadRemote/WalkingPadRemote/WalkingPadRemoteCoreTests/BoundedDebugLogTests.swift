import XCTest
@testable import WalkingPadCoreLogic

final class BoundedDebugLogTests: XCTestCase {
    func testLineAndByteRetentionKeepsNewestCompleteEntries() {
        var lineLimited = BoundedDebugLogBuffer(
            policy: DebugLogRetentionPolicy(maxLines: 3, maxUTF8Bytes: 100)
        )
        for index in 0..<10 {
            lineLimited.append("line-\(index)")
        }

        let lineSnapshot = lineLimited.snapshot()
        XCTAssertEqual(lineSnapshot.text, "line-7\nline-8\nline-9")
        XCTAssertEqual(lineSnapshot.lineCount, 3)
        XCTAssertLessThanOrEqual(lineSnapshot.retainedUTF8Bytes, 100)

        var byteLimited = BoundedDebugLogBuffer(
            policy: DebugLogRetentionPolicy(maxLines: 10, maxUTF8Bytes: 14)
        )
        byteLimited.append("aaaaa")
        byteLimited.append("bbbbb")
        byteLimited.append("ccccc")

        let byteSnapshot = byteLimited.snapshot()
        XCTAssertEqual(byteSnapshot.text, "bbbbb\nccccc")
        XCTAssertEqual(byteSnapshot.lineCount, 2)
        XCTAssertEqual(byteSnapshot.retainedUTF8Bytes, 12)
    }

    func testOversizedUnicodeLineIsValidAndStrictlyBounded() {
        let policy = DebugLogRetentionPolicy(maxLines: 4, maxUTF8Bytes: 12)
        var buffer = BoundedDebugLogBuffer(policy: policy)

        buffer.append(String(repeating: "🙂", count: 20))

        let snapshot = buffer.snapshot()
        XCTAssertEqual(snapshot.text, "🙂🙂")
        XCTAssertEqual(snapshot.lineCount, 1)
        XCTAssertLessThanOrEqual(snapshot.retainedUTF8Bytes, policy.maxUTF8Bytes)
        XCTAssertNotNil(snapshot.text.data(using: .utf8))
    }

    func testEmbeddedNewlinesParticipateInLineRetentionPolicy() {
        var buffer = BoundedDebugLogBuffer(
            policy: DebugLogRetentionPolicy(maxLines: 3, maxUTF8Bytes: 100)
        )

        buffer.append("first\nsecond\nthird\nfourth")

        let snapshot = buffer.snapshot()
        XCTAssertEqual(snapshot.text, "second\nthird\nfourth")
        XCTAssertEqual(snapshot.lineCount, 3)
        XCTAssertEqual(buffer.diagnostics.appendCount, 1)
    }

    func testSustainedAppendDoesNotAssembleRetainedTextUntilSnapshot() {
        let policy = DebugLogRetentionPolicy.production
        var buffer = BoundedDebugLogBuffer(policy: policy)
        let payload = String(repeating: "x", count: 96)

        for index in 0..<100_000 {
            buffer.append("event=\(index) payload=\(payload)")
        }

        XCTAssertEqual(buffer.diagnostics.appendCount, 100_000)
        XCTAssertEqual(buffer.diagnostics.snapshotAssemblyCount, 0)
        XCTAssertLessThanOrEqual(buffer.lineCount, policy.maxLines)
        XCTAssertLessThanOrEqual(buffer.retainedUTF8Bytes, policy.maxUTF8Bytes)
        XCTAssertGreaterThan(
            buffer.retainedUTF8Bytes,
            policy.maxUTF8Bytes - 150
        )

        let snapshot = buffer.snapshot()
        XCTAssertEqual(buffer.diagnostics.snapshotAssemblyCount, 1)
        XCTAssertEqual(snapshot.lineCount, buffer.lineCount)
        XCTAssertTrue(snapshot.text.hasSuffix("event=99999 payload=\(payload)"))
    }

    func testSnapshotAndClearAreDeterministic() {
        var buffer = BoundedDebugLogBuffer(
            policy: DebugLogRetentionPolicy(maxLines: 5, maxUTF8Bytes: 100)
        )
        buffer.append("first")
        buffer.append("second")

        let first = buffer.snapshot()
        let second = buffer.snapshot()
        XCTAssertEqual(first.text, second.text)
        XCTAssertEqual(first.revision, second.revision)

        buffer.clear()
        let cleared = buffer.snapshot()
        XCTAssertEqual(cleared.text, "")
        XCTAssertEqual(cleared.lineCount, 0)
        XCTAssertEqual(cleared.retainedUTF8Bytes, 0)
        XCTAssertGreaterThan(cleared.revision, second.revision)
    }

    func testStoreSnapshotIncludesAllPreviouslyEnqueuedAppends() {
        let store = DebugLogStore(
            policy: DebugLogRetentionPolicy(maxLines: 5, maxUTF8Bytes: 100)
        )
        for index in 0..<20 {
            store.append("event-\(index)")
        }

        let snapshotExpectation = expectation(description: "snapshot")
        store.snapshot(after: nil) { snapshot in
            XCTAssertEqual(
                snapshot?.text,
                "event-15\nevent-16\nevent-17\nevent-18\nevent-19"
            )
            XCTAssertEqual(snapshot?.lineCount, 5)
            snapshotExpectation.fulfill()
        }

        wait(for: [snapshotExpectation], timeout: 1)
    }
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
        XCTAssertFalse(manager.contains("@Published var loggingEnabled"))
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
