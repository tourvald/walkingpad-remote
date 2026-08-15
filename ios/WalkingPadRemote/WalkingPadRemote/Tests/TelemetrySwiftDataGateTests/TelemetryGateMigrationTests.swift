import Foundation
import SwiftData
import TelemetryDomain
@testable import TelemetryPersistence
import XCTest

@Model
private final class TelemetrySyntheticMigrationMarkerV2 {
    @Attribute(.unique) var key: String
    var createdAt: Date

    init(key: String, createdAt: Date) {
        self.key = key
        self.createdAt = createdAt
    }
}

private enum TelemetrySyntheticSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        TelemetrySchemaV1.models + [TelemetrySyntheticMigrationMarkerV2.self]
    }
}

private enum TelemetrySyntheticMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [TelemetrySchemaV1.self, TelemetrySyntheticSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(
                fromVersion: TelemetrySchemaV1.self,
                toVersion: TelemetrySyntheticSchemaV2.self
            ),
        ]
    }
}

private struct TelemetrySyntheticMigrationEvidence: Equatable {
    let counts: TelemetryStoreCounts
    let heartRateIdentityHash: String
    let markerCount: Int
}

final class TelemetryGateMigrationTests: XCTestCase {
    func testV1ToSyntheticV2MigrationRetainsEvidenceAcrossRepeatedReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "telemetry-gate-migration-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("TelemetryV2.store")
        let expected = try await createV1Fixture(at: storeURL)
        try assertDirectoryBackupBoundary(primaryStoreURL: storeURL, phase: "V1 fixture")

        let migrated = try migrateAndRead(at: storeURL, addMarker: true)
        XCTAssertEqual(migrated.counts, expected.counts)
        XCTAssertEqual(migrated.heartRateIdentityHash, expected.heartRateIdentityHash)
        XCTAssertEqual(migrated.markerCount, 1)
        try assertDirectoryBackupBoundary(primaryStoreURL: storeURL, phase: "migration")

        let repeatedReopen = try migrateAndRead(at: storeURL, addMarker: false)
        XCTAssertEqual(repeatedReopen, migrated)
        try assertDirectoryBackupBoundary(primaryStoreURL: storeURL, phase: "migration reopen")

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

    private func createV1Fixture(at storeURL: URL) async throws
        -> TelemetrySyntheticMigrationEvidence
    {
        let profile = TelemetryGateProfile(
            name: "migration-v1",
            sessionCount: 1,
            secondsPerSession: 60,
            frameGapStartSecond: 20,
            frameGapLengthSeconds: 5,
            heartRateIntervalSeconds: 5,
            treadmillIntervalSeconds: 15,
            eventsPerSession: 20,
            batchSize: 128,
            queryRepetitions: 1
        )
        let generator = TelemetryGateFixtureGenerator(profile: profile)
        let store = try TelemetryStoreFactory.make(.onDisk(storeURL))
        try await store.insertGateBatch(generator.sources.map(TelemetryGateRecord.source))
        try await store.insertSession(generator.session(index: 0))
        var records: [TelemetryGateRecord] = []
        for index in 0..<profile.heartRatePerSession {
            records.append(.heartRate(generator.heartRate(sessionIndex: 0, sampleIndex: index)))
        }
        for index in 0..<profile.treadmillPerSession {
            records.append(.treadmill(generator.treadmill(sessionIndex: 0, sampleIndex: index)))
        }
        records.append(contentsOf: generator.events(sessionIndex: 0).map(TelemetryGateRecord.event))
        for second in 0..<profile.secondsPerSession {
            if let frame = generator.frame(sessionIndex: 0, elapsedSecond: second) {
                records.append(.frame(frame))
            }
        }
        records.append(.analysis(generator.analysis(sessionIndex: 0)))
        try await store.insertGateBatch(records)
        let counts = try await store.counts()
        let heartRate = try await store.fetchHeartRate(
            sessionID: generator.causalProbe(sessionIndex: 0).sessionID
        )
        return TelemetrySyntheticMigrationEvidence(
            counts: counts,
            heartRateIdentityHash: identityHash(heartRate),
            markerCount: 0
        )
    }

    private func migrateAndRead(
        at storeURL: URL,
        addMarker: Bool
    ) throws -> TelemetrySyntheticMigrationEvidence {
        _ = try TelemetryStoreFilePolicy.prepareStoreDirectory(
            primaryStoreURL: storeURL
        )
        try assertDirectoryBackupBoundary(
            primaryStoreURL: storeURL,
            phase: "before migration open"
        )
        let schema = Schema(versionedSchema: TelemetrySyntheticSchemaV2.self)
        let configuration = ModelConfiguration(
            "TelemetryV2SyntheticMigration",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: schema,
            migrationPlan: TelemetrySyntheticMigrationPlan.self,
            configurations: [configuration]
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        if addMarker {
            try context.transaction {
                context.insert(
                    TelemetrySyntheticMigrationMarkerV2(
                        key: "synthetic-successor-v2",
                        createdAt: TelemetryGateFixtureGenerator.baseDate
                    )
                )
            }
        }
        try assertDirectoryBackupBoundary(
            primaryStoreURL: storeURL,
            phase: "after migration write"
        )
        _ = try TelemetryStoreFilePolicy.applyRequiredAttributes(
            primaryStoreURL: storeURL
        )
        let heartRateDescriptor = FetchDescriptor<TelemetryHeartRateSampleV1>(
            sortBy: [SortDescriptor(\TelemetryHeartRateSampleV1.arrivalOrder)]
        )
        let heartRateModels = try context.fetch(heartRateDescriptor)
        var hasher = TelemetryGateIdentityHasher()
        for model in heartRateModels {
            hasher.update(model.observationID)
        }
        return TelemetrySyntheticMigrationEvidence(
            counts: TelemetryStoreCounts(
                configurations: try context.fetchCount(
                    FetchDescriptor<TelemetryConfigurationSnapshotV1>()
                ),
                sessions: try context.fetchCount(FetchDescriptor<TelemetryWorkoutSessionV1>()),
                sources: try context.fetchCount(FetchDescriptor<TelemetrySignalSourceV1>()),
                heartRateSamples: heartRateModels.count,
                treadmillSamples: try context.fetchCount(
                    FetchDescriptor<TelemetryTreadmillSampleV1>()
                ),
                events: try context.fetchCount(FetchDescriptor<TelemetryWorkoutEventV1>()),
                frames: try context.fetchCount(FetchDescriptor<TelemetryWorkoutFrameV1>()),
                analyses: try context.fetchCount(FetchDescriptor<TelemetryWorkoutAnalysisV1>())
            ),
            heartRateIdentityHash: hasher.lowercaseHexDigest,
            markerCount: try context.fetchCount(
                FetchDescriptor<TelemetrySyntheticMigrationMarkerV2>()
            )
        )
    }

    private func identityHash(_ observations: [HeartRateObservation]) -> String {
        var hasher = TelemetryGateIdentityHasher()
        for observation in observations {
            hasher.update(observation.observationID.description)
        }
        return hasher.lowercaseHexDigest
    }

    private func assertDirectoryBackupBoundary(
        primaryStoreURL: URL,
        phase: String
    ) throws {
        XCTAssertEqual(
            try primaryStoreURL.deletingLastPathComponent()
                .resourceValues(forKeys: [.isExcludedFromBackupKey])
                .isExcludedFromBackup,
            true,
            phase
        )
    }
}
