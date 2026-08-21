import Darwin
import Foundation
import TelemetryDomain
@testable import TelemetryPersistence
import XCTest

private struct TelemetryGateRecoveryMarker: Codable {
    let sessionID: String
    let committedHeartRateCount: Int
    let committedIdentityHash: String
}

final class TelemetryGateRecoveryTests: XCTestCase {
    func testForcedProcessInterruptionPreservesCommittedPrefixAndMarksIncomplete() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "telemetry-gate-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("TelemetryV2.store")
        let markerURL = root.appendingPathComponent("committed-prefix.json")
        let committedCount = 256

        let worker = Process()
        worker.executableURL = try crashWorkerExecutableURL()
        worker.arguments = [
            "--store", storeURL.path,
            "--marker", markerURL.path,
            "--committed-heart-rate-count", String(committedCount),
        ]
        worker.standardOutput = FileHandle.nullDevice
        worker.standardError = FileHandle.nullDevice
        try worker.run()

        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: markerURL.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard FileManager.default.fileExists(atPath: markerURL.path) else {
            if worker.isRunning {
                kill(worker.processIdentifier, SIGKILL)
                worker.waitUntilExit()
            }
            XCTFail("Crash worker did not publish the committed-prefix marker.")
            return
        }
        let marker = try JSONDecoder().decode(
            TelemetryGateRecoveryMarker.self,
            from: Data(contentsOf: markerURL)
        )
        XCTAssertEqual(marker.committedHeartRateCount, committedCount)
        XCTAssertTrue(worker.isRunning)

        XCTAssertEqual(kill(worker.processIdentifier, SIGKILL), 0)
        worker.waitUntilExit()
        XCTAssertEqual(worker.terminationReason, .uncaughtSignal)
        XCTAssertEqual(worker.terminationStatus, SIGKILL)

        guard let rawSessionID = UUID(uuidString: marker.sessionID) else {
            XCTFail("Worker emitted an invalid session identifier.")
            return
        }
        let sessionID = SessionID(rawValue: rawSessionID)
        let reopened = try TelemetryStoreFactory.make(.onDisk(storeURL))
        let counts = try await reopened.counts()
        XCTAssertEqual(counts.sessions, 1)
        XCTAssertEqual(counts.sources, 1)
        XCTAssertEqual(counts.heartRateSamples, committedCount)
        let heartRate = try await reopened.fetchHeartRate(sessionID: sessionID)
        XCTAssertEqual(heartRate.count, committedCount)
        XCTAssertEqual(identityHash(heartRate), marker.committedIdentityHash)
        let beforeRecovery = try await reopened.fetchSessions()
        XCTAssertEqual(beforeRecovery.count, 1)
        XCTAssertEqual(beforeRecovery[0].lifecycleState, .running)
        XCTAssertFalse(beforeRecovery[0].recorderHealth.isComplete)
        XCTAssertNil(beforeRecovery[0].endedAt)

        try await reopened.gateMarkInterruptedSessionIncomplete(
            sessionID,
            reason: "forced-process-interruption"
        )
        let verifiedReopen = try TelemetryStoreFactory.make(.onDisk(storeURL))
        let recoveredSessions = try await verifiedReopen.fetchSessions()
        XCTAssertEqual(recoveredSessions.count, 1)
        XCTAssertEqual(recoveredSessions[0].lifecycleState, .incomplete)
        XCTAssertEqual(recoveredSessions[0].incompleteReason, "forced-process-interruption")
        XCTAssertFalse(recoveredSessions[0].recorderHealth.isComplete)
        XCTAssertNil(recoveredSessions[0].endedAt)
        let verifiedCounts = try await verifiedReopen.counts()
        XCTAssertEqual(verifiedCounts.heartRateSamples, committedCount)
        let verifiedHeartRate = try await verifiedReopen.fetchHeartRate(sessionID: sessionID)
        XCTAssertEqual(
            identityHash(verifiedHeartRate),
            marker.committedIdentityHash
        )

        let policy = try TelemetryStoreFilePolicy.applyRequiredAttributes(
            primaryStoreURL: storeURL
        )
        XCTAssertFalse(policy.protectedURLs.isEmpty)
        for url in policy.protectedURLs {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(
                attributes[.protectionKey] as? FileProtectionType,
                .completeUntilFirstUserAuthentication
            )
            XCTAssertEqual(
                try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
                true
            )
        }
    }

    private func crashWorkerExecutableURL() throws -> URL {
        let testProductsDirectory = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
        let colocatedWorker = testProductsDirectory
            .appendingPathComponent("TelemetryGateCrashWorker", isDirectory: false)
        if FileManager.default.isExecutableFile(atPath: colocatedWorker.path) {
            return colocatedWorker
        }

        let buildRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: buildRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        for case let url as URL in enumerator where url.lastPathComponent == "TelemetryGateCrashWorker" {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey])
            if values.isRegularFile == true, values.isExecutable == true {
                return url
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func identityHash(_ observations: [HeartRateObservation]) -> String {
        var hasher = TelemetryGateIdentityHasher()
        for observation in observations {
            hasher.update(observation.observationID.description)
        }
        return hasher.lowercaseHexDigest
    }
}
