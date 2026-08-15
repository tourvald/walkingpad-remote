import Foundation
@testable import TelemetryPersistence
import XCTest

final class TelemetryGateBoundaryTests: XCTestCase {
    func testFullProfileCannotSilentlyDowngradeBelowRequiredScale() {
        let profile = TelemetryGateProfile.full
        let expected = TelemetryGateFixtureGenerator(profile: profile).expectedCounts
        XCTAssertEqual(profile.representedWorkoutHours, 1_000)
        XCTAssertEqual(profile.sessionCount, 1_000)
        XCTAssertEqual(profile.secondsPerSession, 3_600)
        XCTAssertEqual(profile.batchSize, 128)
        XCTAssertGreaterThanOrEqual(expected.totalPersistedRecords, 4_000_000)
        XCTAssertGreaterThanOrEqual(expected.frames, 3_000_000)
        XCTAssertGreaterThan(expected.expectedNativeRedeliveryRejections, 0)
        XCTAssertGreaterThan(expected.identityAbsentDuplicatePairs, 0)
    }

    func testGateHarnessRemainsInternalAndOutsideApplicationTargets() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let storeSource = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/TelemetryPersistence/TelemetryStore.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(storeSource.contains("func insertGateBatch"))
        XCTAssertFalse(storeSource.contains("public func insertGateBatch"))
        XCTAssertTrue(storeSource.contains("package func gateStageUncommittedHeartRate"))
        XCTAssertFalse(storeSource.contains("public func gateStageUncommittedHeartRate"))

        let project = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "WalkingPadRemote.xcodeproj/project.pbxproj"
            ),
            encoding: .utf8
        )
        XCTAssertFalse(project.contains("TelemetryGateCrashWorker"))
        XCTAssertFalse(project.contains("TelemetrySwiftDataGateTests"))

        let runtimeDirectory = packageRoot.appendingPathComponent("WalkingPadRemote")
        let enumerator = FileManager.default.enumerator(
            at: runtimeDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        var runtimeSources = ""
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else {
                continue
            }
            runtimeSources += try String(contentsOf: url, encoding: .utf8)
        }
        XCTAssertFalse(runtimeSources.contains("TelemetryGateCrashWorker"))
        XCTAssertFalse(runtimeSources.contains("insertGateBatch"))
        XCTAssertFalse(runtimeSources.contains("gateStageUncommittedHeartRate"))
        XCTAssertFalse(runtimeSources.contains("TelemetryStoreFactory.make"))
    }
}
