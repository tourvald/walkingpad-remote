import Foundation
import TelemetryDomain
import XCTest
@testable import TelemetryRuntime

final class DiagnosticZipArchiveTests: XCTestCase {
    func testArchiveContainsEveryDiagnosticArtifactAndPreservesSources() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let payloads = [
            "manifest.json": #"{"manifestVersion":"workout-export-manifest-v1"}"#,
            "raw_evidence_v1.jsonl": #"{"recordType":"heart_rate"}"#,
            "normalized_evidence_v1.csv": "record_type,heart_rate_bpm\nheart_rate,132\n",
            "session_summary_v2.jsonl": #"{"recordType":"workout_summary"}"#,
            "session_summary_v2.csv": "summary_version,warnings\nworkout-session-summary-v2,partial\n",
        ]
        let sourceURLs = try payloads.sorted(by: { $0.key < $1.key }).map { name, payload in
            let url = root.appendingPathComponent(name)
            try Data(payload.utf8).write(to: url)
            return url
        }

        let archiveURL = try DiagnosticZipArchive.create(
            directoryURL: root,
            fileURLs: sourceURLs,
            archiveName: "WalkingPad_Diagnostics.zip"
        )

        XCTAssertEqual(archiveURL.pathExtension, "zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
        for sourceURL in sourceURLs {
            XCTAssertEqual(
                try String(contentsOf: sourceURL, encoding: .utf8),
                payloads[sourceURL.lastPathComponent]
            )
        }

        let listedFiles = try runUnzip(["-Z1", archiveURL.path])
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(Set(listedFiles), Set(payloads.keys))
        for (name, payload) in payloads {
            XCTAssertEqual(try runUnzip(["-p", archiveURL.path, name]), payload)
        }
    }

    func testArchiveRejectsEvidenceOutsideExportDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside_\(UUID().uuidString).json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        XCTAssertThrowsError(
            try DiagnosticZipArchive.create(
                directoryURL: root,
                fileURLs: [outside],
                archiveName: "WalkingPad_Diagnostics.zip"
            )
        ) { error in
            guard case DiagnosticZipArchive.ArchiveError.invalidSource = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("WalkingPad_Diagnostics.zip").path
            )
        )
    }

    func testCancellationRemovesPartialArchiveAndPreservesSources() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("raw_evidence_v1.jsonl")
        let payload = Data(repeating: 0x61, count: 512 * 1024)
        try payload.write(to: source)
        var cancellationChecks = 0

        XCTAssertThrowsError(try DiagnosticZipArchive.createWithMetrics(
            directoryURL: root,
            fileURLs: [source],
            archiveName: "WalkingPad_Diagnostics.zip",
            cancellationCheck: {
                cancellationChecks += 1
                if cancellationChecks == 12 { throw CancellationError() }
            }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertGreaterThanOrEqual(cancellationChecks, 12)
        XCTAssertEqual(try Data(contentsOf: source), payload)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("WalkingPad_Diagnostics.zip").path
        ))
    }

    func testArchiveMetricsProveBoundedStreamingChunks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("raw_evidence_v1.jsonl")
        try Data(repeating: 0x62, count: 180_000).write(to: source)

        let result = try DiagnosticZipArchive.createWithMetrics(
            directoryURL: root,
            fileURLs: [source],
            archiveName: "WalkingPad_Diagnostics.zip"
        )

        XCTAssertGreaterThan(result.outputBytes, 180_000)
        XCTAssertEqual(result.maximumChunkBytes, 64 * 1024)
    }

    func testSupportOnlyBundleContainsBoundedSupportArtifact() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let names = [
            "raw_evidence_v1.jsonl",
            "normalized_evidence_v1.csv",
            "session_summary_v2.jsonl",
            "session_summary_v2.csv",
            "manifest.json",
        ]
        let files = try names.map { name in
            let url = root.appendingPathComponent(name)
            try Data().write(to: url)
            return url
        }
        let workoutArtifact = WorkoutExportArtifact(
            directoryURL: root,
            fileURLs: files,
            exportedWorkoutCount: 0,
            exportedRecordCount: 0,
            containsHealthData: false
        )

        let bundle = try await DiagnosticBundlePackager.create(
            workoutArtifact: workoutArtifact,
            supportSnapshot: makeSupportSnapshot(),
            archiveName: "WalkingPad_Diagnostics.zip"
        )

        XCTAssertEqual(bundle.exportedWorkoutCount, 0)
        XCTAssertEqual(bundle.exportedRecordCount, 0)
        XCTAssertFalse(bundle.containsHealthData)
        XCTAssertLessThanOrEqual(bundle.maximumChunkBytes, 64 * 1024)
        let listedFiles = try runUnzip(["-Z1", bundle.archiveURL.path])
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(Set(listedFiles), Set(names + ["support_diagnostics_v1.json"]))

        let support = try runUnzip([
            "-p", bundle.archiveURL.path, "support_diagnostics_v1.json",
        ])
        XCTAssertTrue(support.contains("walkingpad-support-diagnostics-v1"))
        XCTAssertTrue(support.contains("controller_units_blocked"))
        XCTAssertTrue(support.contains("rawA6Hex"))
        XCTAssertFalse(support.contains("profileID"))
        XCTAssertFalse(support.contains("peripheralID"))
    }

    func testUnavailableWorkoutEvidenceProducesExplicitSupportOnlyArchive() async throws {
        let bundle = try await DiagnosticBundlePackager.createSupportOnly(
            supportSnapshot: makeSupportSnapshot(),
            archiveName: "WalkingPad_Diagnostics.zip",
            workoutEvidenceFailureCategory: "unavailable"
        )
        defer { try? FileManager.default.removeItem(at: bundle.directoryURL) }

        XCTAssertEqual(bundle.exportedWorkoutCount, 0)
        XCTAssertFalse(bundle.containsHealthData)
        let listedFiles = try runUnzip(["-Z1", bundle.archiveURL.path])
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(listedFiles, ["support_diagnostics_v1.json"])
        let support = try runUnzip([
            "-p", bundle.archiveURL.path, "support_diagnostics_v1.json",
        ])
        XCTAssertTrue(support.contains(#""workoutEvidenceStatus" : "unavailable""#))
        XCTAssertTrue(support.contains(#""workoutEvidenceFailureCategory" : "unavailable""#))
    }

    func testPackagerCancellationReachesDetachedWorkerAndLeavesNoArchive() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("raw_evidence_v1.jsonl")
        try Data(repeating: 0x63, count: 4 * 1024 * 1024).write(to: source)
        let artifact = WorkoutExportArtifact(
            directoryURL: root,
            fileURLs: [source],
            exportedWorkoutCount: 1,
            exportedRecordCount: 1,
            containsHealthData: true
        )

        let task = Task {
            try await DiagnosticBundlePackager.create(
                workoutArtifact: artifact,
                supportSnapshot: makeSupportSnapshot(),
                archiveName: "WalkingPad_Diagnostics.zip"
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled packaging must not complete")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("WalkingPad_Diagnostics.zip").path
        ))
    }

    private func makeSupportSnapshot() -> DiagnosticSupportSnapshot {
        DiagnosticSupportSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_000),
            runtime: .init(
                appVersion: "1.0",
                buildNumber: "1",
                operatingSystemVersion: "test-os",
                telemetrySchemaVersion: "1.0.0",
                algorithmVersion: "algorithm-v1",
                safetyPolicyVersion: "safety-v1",
                workoutProtocolVersion: "workout-v1"
            ),
            nativeHeartRatePreflight: .init(
                phase: "terminal",
                requestedAt: Date(timeIntervalSince1970: 900),
                providerPreparedAt: Date(timeIntervalSince1970: 901),
                collectionStartedAt: Date(timeIntervalSince1970: 902),
                firstNativeCallbackMeasuredAt: nil,
                firstNativeCallbackReceivedAt: nil,
                firstQualifyingLatencySeconds: nil,
                terminalAt: Date(timeIntervalSince1970: 930),
                terminalReason: "timeout",
                gateBlockReason: "controller_units_blocked",
                providerState: "idle",
                providerCleanupInFlight: false,
                providerGeneration: 3,
                providerHasBoundAttempt: false,
                nativeWorkoutCommitted: false
            ),
            controllerUnits: .init(
                status: "valid",
                physicalUnits: "metric",
                observedAt: Date(timeIntervalSince1970: 999),
                ageSeconds: 1,
                isFresh: true,
                gateAllowed: true,
                blockReason: nil,
                evidenceConnectionEpoch: "ephemeral-evidence-epoch",
                currentConnectionEpoch: "ephemeral-current-epoch",
                isCurrentConnection: true,
                byteCount: 6,
                rawA6Hex: "f8a6000000ae"
            ),
            treadmill: .init(
                protocolName: "WalkingPad",
                isConnected: true,
                isControlReady: true,
                hasCurrentConnectionContext: true,
                protocolMatchesCurrentConnection: true,
                connectionEpoch: "ephemeral-current-epoch"
            ),
            writerHealth: .init(
                workoutReadState: "loaded",
                runtimeLifecycle: "idle",
                recorderLifecycle: nil,
                completeness: nil,
                queueDepth: 0,
                peakQueueDepth: 0,
                coalescedFrameCount: 0,
                droppedFrameCount: 0,
                lostNativeCount: 0,
                lostCriticalCount: 0,
                writerFailureCount: 0,
                retryCount: 0,
                successfulFlushCount: 0,
                lastCommittedRecorderSequence: nil
            )
        )
    }

    private func runUnzip(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                decoding: error.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            throw NSError(
                domain: "DiagnosticZipArchiveTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        return String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
    }
}
