import Foundation
import SwiftData
import TelemetryDomain
@testable import TelemetryPersistence
import XCTest

final class TelemetrySchemaAndBoundaryTests: XCTestCase {
    func testVersionedSchemaMigrationPlanIndicesAndUniquenessAreRegistered() throws {
        XCTAssertEqual(TelemetrySchemaV1.versionIdentifier, Schema.Version(1, 0, 0))
        XCTAssertEqual(TelemetryMigrationPlan.schemas.count, 1)
        XCTAssertTrue(TelemetryMigrationPlan.schemas[0] == TelemetrySchemaV1.self)
        XCTAssertTrue(TelemetryMigrationPlan.stages.isEmpty)

        let schema = Schema(versionedSchema: TelemetrySchemaV1.self)
        XCTAssertEqual(schema.entities.count, 8)

        let sessions = try XCTUnwrap(schema.entitiesByName["TelemetryWorkoutSessionV1"])
        XCTAssertTrue(sessions.attributesByName["sessionID"]?.isUnique == true)
        XCTAssertTrue(sessions.indices.contains(["binary", "startedAt"]))
        XCTAssertTrue(
            sessions.indices.contains(["binary", "profileLocalIdentifier", "startedAt"])
        )

        let frames = try XCTUnwrap(schema.entitiesByName["TelemetryWorkoutFrameV1"])
        XCTAssertTrue(frames.attributesByName["canonicalIdentityKey"]?.isUnique == true)
        XCTAssertTrue(
            frames.indices.contains(["binary", "sessionID", "canonicalElapsedSecond"])
        )

        let events = try XCTUnwrap(schema.entitiesByName["TelemetryWorkoutEventV1"])
        XCTAssertTrue(
            events.indices.contains(["binary", "sessionID", "kindKey", "occurredElapsedMicroseconds"])
        )
        XCTAssertTrue(events.indices.contains(["binary", "decisionID"]))
        XCTAssertTrue(events.indices.contains(["binary", "commandID"]))
        XCTAssertTrue(events.indices.contains(["binary", "attemptID"]))

        let heartRate = try XCTUnwrap(schema.entitiesByName["TelemetryHeartRateSampleV1"])
        XCTAssertTrue(heartRate.indices.contains(["binary", "nativeSampleIdentityKey"]))

        let treadmill = try XCTUnwrap(schema.entitiesByName["TelemetryTreadmillSampleV1"])
        XCTAssertNotNil(treadmill.attributesByName["factualSpeedNormalizationRuleKey"])
    }

    func testInsertDuplicatePreflightsAreBoundedPredicates() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let storeURL = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("TelemetryPersistence")
            .appendingPathComponent("TelemetryStore.swift")
        let source = try String(contentsOf: storeURL, encoding: .utf8)

        XCTAssertFalse(source.contains("requireAbsent"))
        XCTAssertFalse(source.contains("modelContext.fetch(FetchDescriptor<Model>())"))
        XCTAssertTrue(source.contains("private func rejectDuplicate<Model: PersistentModel>"))
        XCTAssertTrue(source.contains("descriptor.fetchLimit = 1"))
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "try rejectDuplicate(").count - 1,
            15,
            "Every insert identity must use the bounded duplicate preflight."
        )
    }

    func testStoreBoundaryDisablesAutosaveAndProductionWiringIsSingleCoordinatorFactory() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let autosaveEnabled = await store.isAutosaveEnabled()
        XCTAssertFalse(autosaveEnabled)

        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let productionSourceRoot = packageRoot.appendingPathComponent("WalkingPadRemote")
        let sourceURLs = try FileManager.default.contentsOfDirectory(
            at: productionSourceRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }

        for url in sourceURLs {
            let source = try String(contentsOf: url, encoding: .utf8)
            if url.lastPathComponent == "BluetoothManager.swift" {
                XCTAssertEqual(
                    source.components(separatedBy: "TelemetryStoreFactory.make").count - 1,
                    1
                )
                XCTAssertTrue(source.contains("import TelemetryPersistence"))
                XCTAssertTrue(source.contains("TelemetryV2RuntimeCoordinator("))
            } else {
                XCTAssertFalse(
                    source.contains("TelemetryStoreFactory"),
                    "Unexpected V2 store wiring in \(url.lastPathComponent)"
                )
                XCTAssertFalse(
                    source.contains("TelemetryPersistence"),
                    "Unexpected V2 import in \(url.lastPathComponent)"
                )
            }
        }
    }

    func testFrameSchemaDoesNotRepeatConfigurationSnapshot() throws {
        let schema = Schema(versionedSchema: TelemetrySchemaV1.self)
        let frames = try XCTUnwrap(schema.entitiesByName["TelemetryWorkoutFrameV1"])
        XCTAssertNil(frames.attributesByName["configurationSnapshot"])
        XCTAssertNil(frames.relationshipsByName["configuration"])
    }

    func testApplicationSupportLocationAndSidecarDiscoveryAreExplicit() throws {
        let url = try TelemetryStoreLocation.applicationSupportStoreURL(appIdentifier: "test.telemetry")
        XCTAssertEqual(url.lastPathComponent, "TelemetryV2.store")
        XCTAssertTrue(url.path.contains("Application Support/test.telemetry/TelemetryV2"))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("telemetry-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let primary = directory.appendingPathComponent("TelemetryV2.store")
        let wal = directory.appendingPathComponent("TelemetryV2.store-wal")
        let unrelated = directory.appendingPathComponent("other.store")
        try Data().write(to: primary)
        try Data().write(to: wal)
        try Data().write(to: unrelated)

        let discovered = try TelemetryStoreFilePolicy.discoveredStoreFiles(primaryStoreURL: primary)
        XCTAssertEqual(discovered.map(\.lastPathComponent), ["TelemetryV2.store", "TelemetryV2.store-wal"])

        let result = try TelemetryStoreFilePolicy.applyRequiredAttributes(primaryStoreURL: primary)
        XCTAssertEqual(result.protectedURLs, discovered)
        XCTAssertTrue(result.deviceVerificationRequired)
        let resourceValues = try primary.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(resourceValues.isExcludedFromBackup, true)
    }

    func testDirectoryBackupBoundarySurvivesChildResetAndRecreation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("telemetry-directory-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("TelemetryV2", isDirectory: true)
        let primary = directory.appendingPathComponent("TelemetryV2.store")
        let wal = directory.appendingPathComponent("TelemetryV2.store-wal")

        let preparedDirectory = try TelemetryStoreFilePolicy.prepareStoreDirectory(
            primaryStoreURL: primary
        )
        XCTAssertEqual(preparedDirectory, directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: primary.path))
        XCTAssertEqual(
            try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
                .isExcludedFromBackup,
            true
        )

        try Data().write(to: primary)
        try Data().write(to: wal)
        for url in [primary, wal] {
            var values = URLResourceValues()
            values.isExcludedFromBackup = false
            var mutableURL = url
            try mutableURL.setResourceValues(values)
        }
        XCTAssertEqual(
            try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
                .isExcludedFromBackup,
            true
        )

        try FileManager.default.removeItem(at: wal)
        try Data().write(to: wal)
        var resetValues = URLResourceValues()
        resetValues.isExcludedFromBackup = false
        var mutableWAL = wal
        try mutableWAL.setResourceValues(resetValues)
        XCTAssertEqual(
            try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
                .isExcludedFromBackup,
            true
        )

        let result = try TelemetryStoreFilePolicy.applyRequiredAttributes(
            primaryStoreURL: primary
        )
        XCTAssertEqual(
            result.protectedURLs.map(\.lastPathComponent),
            [primary.lastPathComponent, wal.lastPathComponent]
        )
        for url in result.protectedURLs {
            XCTAssertEqual(
                try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
                    .isExcludedFromBackup,
                true
            )
            XCTAssertEqual(
                try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey]
                    as? FileProtectionType,
                .completeUntilFirstUserAuthentication
            )
        }
    }
}
