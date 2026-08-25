import Foundation
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
