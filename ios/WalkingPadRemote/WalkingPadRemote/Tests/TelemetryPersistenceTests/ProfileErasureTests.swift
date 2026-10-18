import Foundation
import SwiftData
import TelemetryDomain
@testable import TelemetryPersistence
import XCTest

final class ProfileErasureTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testDiskErasurePreservesBAndRejectsStaleSessionAfterReopenAndRetry() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("test.store")
        let a = TelemetryPersistenceFixtures.session(seed: 1, profile: "profile-a")
        let b = TelemetryPersistenceFixtures.session(seed: 2, profile: "profile-b")
        var store: TelemetryStore? = try TelemetryStoreFactory.make(.onDisk(url))
        try await store!.insertSession(a)
        try await store!.insertSession(b)
        try await store!.eraseProfile("profile-a", legacyFallback: nil, logsDirectory: nil, temporaryDirectory: root)
        store = nil
        let reopened = try TelemetryStoreFactory.make(.onDisk(url))
        let retained = try await reopened.fetchSessions()
        XCTAssertEqual(retained, [b])
        let counts = try await reopened.counts()
        XCTAssertEqual(counts.configurations, 1)
        do { try await reopened.insertSession(a); XCTFail("Erased UUID resurrected") }
        catch { XCTAssertEqual(error as? ProfileErasureError, .erasedProfile) }
        try await reopened.eraseProfile("profile-a", legacyFallback: nil, logsDirectory: nil, temporaryDirectory: root)
        let again = try await reopened.fetchSessions()
        XCTAssertEqual(again, [b])
    }

    func testLegacyReplayCannotResurrectErasedProfileAndPreservesOtherHistory() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent("TrainingLogs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let aFile = logs.appendingPathComponent("a.jsonl")
        let bFile = logs.appendingPathComponent("b.jsonl")
        let a = Data("{\"event\":\"session_start\",\"session_id\":\"a\",\"profile_id\":\"profile-a\",\"ts\":1800000000}\n".utf8)
        let b = Data("{\"event\":\"session_start\",\"session_id\":\"b\",\"profileId\":\"profile-b\",\"ts\":1800000001}\n".utf8)
        try a.write(to: aFile); try b.write(to: bFile)
        let defaults = UserDefaults(suiteName: "ProfileErasure-\(UUID().uuidString)")!
        let request = LegacyTelemetryMigrationSourceDiscovery.makeRequest(userDefaults: defaults,
            trainingLogsDirectory: logs, knownProfileLocalIdentifiers: ["profile-a", "profile-b"],
            deterministicLegacyFallbackProfileLocalIdentifier: "profile-a")
        let storeURL = root.appendingPathComponent("legacy.store")
        let store = try TelemetryStoreFactory.make(.onDisk(storeURL))
        _ = await LegacyTelemetryMigrator(store: store).run(request)
        let before = try await store.fetchLegacyImportedRecords().filter { $0.profileLocalIdentifier == "profile-b" }
        let bSources = try await store.fetchLegacyMigrationSources().filter { $0.locator == bFile.path }
        try await store.eraseProfile("profile-a", legacyFallback: "profile-a", logsDirectory: logs, temporaryDirectory: root)
        let bSourcesAfter = try await store.fetchLegacyMigrationSources().filter { $0.locator == bFile.path }
        XCTAssertEqual(bSourcesAfter, bSources)
        XCTAssertFalse(FileManager.default.fileExists(atPath: aFile.path))
        XCTAssertEqual(try Data(contentsOf: bFile), b)
        // Replay an already captured stale request, including a restored source file.
        try a.write(to: aFile)
        let reopened = try TelemetryStoreFactory.make(.onDisk(storeURL))
        _ = await LegacyTelemetryMigrator(store: reopened).run(request)
        let after = try await reopened.fetchLegacyImportedRecords()
        XCTAssertEqual(after.filter { $0.profileLocalIdentifier == "profile-b" }, before)
        XCTAssertFalse(after.contains { $0.profileLocalIdentifier == "profile-a" })
        let candidates = try await store.fetchLegacyWorkoutCandidates()
        XCTAssertFalse(candidates.contains { $0.profileLocalIdentifier == "profile-a" })
        let sources = try await store.fetchLegacyMigrationSources()
        XCTAssertFalse(sources.contains { $0.locator == aFile.path })
    }

    func testMixedAndCorruptSourcesFailWithoutPurgingAnyProfile() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("mixed.jsonl")
        let mixed = Data("{\"profile_id\":\"profile-a\"}\n{\"profile_id\":\"profile-b\"}\n".utf8)
        let store = try TelemetryStoreFactory.make(.inMemory)
        let session = TelemetryPersistenceFixtures.session(seed: 1)
        try await store.insertSession(session)
        for data in [mixed, Data("{corrupt".utf8), Data("{}\n".utf8), Data("{\"profile_id\":\"profile-a\",\"profileId\":\"profile-b\"}\n".utf8)] {
            try data.write(to: file)
            do { try await store.eraseProfile("profile-a", legacyFallback: nil, logsDirectory: logs, temporaryDirectory: root); XCTFail("Unknown ownership accepted") }
            catch {}
            XCTAssertEqual(try Data(contentsOf: file), data)
            let retained = try await store.fetchSessions()
            XCTAssertEqual(retained, [session])
        }
    }

    func testPendingJournalSurvivesReopenAndAllowsRetryAfterDatabaseBoundaryFailure() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("test.store")
        let session = TelemetryPersistenceFixtures.session(seed: 1)
        var store: TelemetryStore? = try TelemetryStoreFactory.make(.onDisk(url))
        try await store!.insertSession(session)
        // Inject an ordinary storage failure at the durable marker/purge boundary.
        do {
            try await store!.eraseProfile("profile-a", legacyFallback: nil, logsDirectory: nil,
                temporaryDirectory: root, afterJournalForTesting: { throw CocoaError(.fileWriteNoPermission) })
            XCTFail("Failure must propagate")
        } catch {}
        store = nil
        let reopened = try TelemetryStoreFactory.make(.onDisk(url))
        do { try await reopened.insertSession(TelemetryPersistenceFixtures.session(seed: 3)); XCTFail("Pending erasure permits new data") } catch {}
        try await reopened.eraseProfile("profile-a", legacyFallback: nil, logsDirectory: nil, temporaryDirectory: root)
        let retained = try await reopened.fetchSessions()
        XCTAssertTrue(retained.isEmpty)
    }

    func testOwnedTemporaryExportErasedOtherExportPreservedAndAmbiguityFails() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TelemetryStoreFactory.make(.inMemory)
        for (name, owners) in [("a", Set(["profile-a"])), ("b", Set(["profile-b"]))] {
            let folder = root.appendingPathComponent("TelemetryV2Export_\(name)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try ProfileErasureFiles.mark(folder, profiles: owners)
            try Data("private-fixture".utf8).write(to: folder.appendingPathComponent("data"))
        }
        try await store.eraseProfile("profile-a", legacyFallback: nil, logsDirectory: nil, temporaryDirectory: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("TelemetryV2Export_a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("TelemetryV2Export_b/data").path))
        let ambiguous = root.appendingPathComponent("WorkoutAnalysisExport_unknown")
        try FileManager.default.createDirectory(at: ambiguous, withIntermediateDirectories: true)
        do { try await store.eraseProfile("profile-b", legacyFallback: nil, logsDirectory: nil, temporaryDirectory: root); XCTFail("Unknown export ownership accepted") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: ambiguous.path))
    }

    func testRunningSessionBlocksErasureWithoutCommittingMarker() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TelemetryStoreFactory.make(.inMemory)
        let session = TelemetryPersistenceFixtures.session(seed: 1, lifecycleState: .running)
        try await store.insertSession(session)
        do { try await store.eraseProfile("profile-a", legacyFallback: nil, logsDirectory: nil, temporaryDirectory: root); XCTFail("Active session erased") }
        catch { XCTAssertEqual(error as? ProfileErasureError, .busy) }
        let retained = try await store.fetchSessions()
        XCTAssertEqual(retained, [session])
        let erased = try await store.erasedProfileIdentifiers()
        XCTAssertTrue(erased.isEmpty)
    }

    func testLateAnalysisAndLinkageCannotRestoreErasedWorkout() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TelemetryStoreFactory.make(.inMemory)
        let session = TelemetryPersistenceFixtures.session(seed: 1)
        try await store.insertSession(session)
        try await store.eraseProfile("profile-a", legacyFallback: nil, logsDirectory: nil, temporaryDirectory: root)
        let outcome = try await store.analyzeTerminalWorkout(sessionID: session.sessionID, generatedAt: Date())
        XCTAssertEqual(outcome.triggerResult, .ineligible)
        do { try await store.associateHealthKitWorkout(sessionID: session.sessionID, workoutIdentifier: UUID()); XCTFail("Erased workout relinked") } catch {}
        let retained = try await store.fetchSessions()
        XCTAssertTrue(retained.isEmpty)
    }

    func testLegacyFallbackDeletesOnlyOriginalProfileAndCorruptJournalFailsClosed() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("pre-profile.jsonl")
        try Data("{\"event\":\"session_start\"}\n".utf8).write(to: file)
        let storeURL = root.appendingPathComponent("test.store")
        let store = try TelemetryStoreFactory.make(.onDisk(storeURL))
        try await store.eraseProfile("profile-b", legacyFallback: "profile-a", logsDirectory: logs, temporaryDirectory: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try await store.eraseProfile("profile-a", legacyFallback: "profile-a", logsDirectory: logs, temporaryDirectory: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try Data("corrupt".utf8).write(to: storeURL.appendingPathExtension("erased-profiles.json"))
        do { try await store.insertSession(TelemetryPersistenceFixtures.session(seed: 3)); XCTFail("Corrupt journal allowed insertion") } catch {}
    }

    func testConcurrentAnalysisExportBlocksErasureUntilItsOwnershipEnds() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TelemetryStoreFactory.make(.inMemory)
        let session = TelemetryPersistenceFixtures.session(seed: 1)
        try await store.insertSession(session)
        let export = try await store.exportWorkoutAnalysis(
            .init(sessionID: session.sessionID, exactProfileLocalIdentifier: "profile-a"),
            temporaryFileCreatedForTesting: {
                do {
                    try await store.eraseProfile("profile-a", legacyFallback: nil, logsDirectory: nil, temporaryDirectory: root)
                    XCTFail("Export ownership ignored")
                } catch { XCTAssertEqual(error as? ProfileErasureError, .busy) }
            }
        )
        defer { try? FileManager.default.removeItem(at: export.fileURL.deletingLastPathComponent()) }
        let owned = root.appendingPathComponent(export.fileURL.deletingLastPathComponent().lastPathComponent)
        try FileManager.default.moveItem(at: export.fileURL.deletingLastPathComponent(), to: owned)
        try await store.eraseProfile("profile-a", legacyFallback: nil, logsDirectory: nil, temporaryDirectory: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
    }

    func testCascadeErasesSamplesAndUnsharedSourcesWhilePreservingSharedSource() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TelemetryStoreFactory.make(.inMemory)
        let a = TelemetryPersistenceFixtures.session(seed: 1)
        let b = TelemetryPersistenceFixtures.session(seed: 2, profile: "profile-b")
        let shared = TelemetryPersistenceFixtures.source(seed: 10)
        let exclusive = TelemetryPersistenceFixtures.source(seed: 11)
        try await store.insertSession(a); try await store.insertSession(b)
        for source in [shared, exclusive] { try await store.insertSource(source, firstSeen: a.startedAt, lastSeen: a.startedAt) }
        let retainedSample = TelemetryPersistenceFixtures.heartRate(seed: 2, session: b, source: shared, arrivalOrder: 1, bpm: 120)
        try await store.insertHeartRate(TelemetryPersistenceFixtures.heartRate(seed: 1, session: a, source: shared, arrivalOrder: 1, bpm: 130))
        try await store.insertHeartRate(TelemetryPersistenceFixtures.heartRate(seed: 3, session: a, source: exclusive, arrivalOrder: 2, bpm: 140))
        try await store.insertHeartRate(retainedSample)
        try await store.eraseProfile("profile-a", legacyFallback: nil, logsDirectory: nil, temporaryDirectory: root)
        let sources = try await store.fetchSources()
        XCTAssertEqual(sources.map(\.identity), [shared])
        let samples = try await store.fetchHeartRate(sessionID: b.sessionID)
        XCTAssertEqual(samples, [retainedSample])
        let counts = try await store.counts()
        XCTAssertEqual(counts.heartRateSamples, 1)
    }

    func testLegacySettingsReopenCannotRebindErasedFallbackAndPreservesB() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ProfileErasure-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("private-a".utf8), forKey: "hr_settings_v1")
        defaults.set(Data("zone-a".utf8), forKey: "zone_plan_v1")
        defaults.set(Data("private-b".utf8), forKey: "hr_settings_v1_profile_profile-b")
        defaults.set("shared", forKey: "known_peripherals_v1")
        let url = root.appendingPathComponent("test.store")
        var store: TelemetryStore? = try TelemetryStoreFactory.make(.onDisk(url))
        do {
            try await store!.eraseProfile("profile-a", legacyFallback: nil, logsDirectory: nil,
                temporaryDirectory: root, afterJournalForTesting: { throw CocoaError(.fileWriteUnknown) })
            XCTFail("Injected interruption ignored")
        } catch {}
        store = nil
        defaults.set(Data("corrupt-profile-list".utf8), forKey: "user_profiles_state_v1")
        let reopened = try TelemetryStoreFactory.make(.onDisk(url))
        let erased = try await reopened.erasedProfileIdentifiers()
        XCTAssertFalse(ProfileErasureSettings.migrateLegacySettings(userDefaults: defaults,
            profileID: "replacement", legacyFallback: "profile-a", erasedProfiles: erased))
        XCTAssertFalse(ProfileErasureSettings.migrateLegacySettings(userDefaults: defaults,
            profileID: "profile-a", legacyFallback: "profile-a", erasedProfiles: erased))
        XCTAssertNil(defaults.data(forKey: "hr_settings_v1_profile_replacement"))
        XCTAssertNil(defaults.data(forKey: "zone_plan_v1_profile_replacement"))
        ProfileErasureSettings.removeProfileSettings(userDefaults: defaults, profileID: "profile-a", legacyFallback: "profile-a")
        XCTAssertNil(defaults.data(forKey: "hr_settings_v1"))
        XCTAssertNil(defaults.data(forKey: "zone_plan_v1"))
        XCTAssertEqual(defaults.data(forKey: "hr_settings_v1_profile_profile-b"), Data("private-b".utf8))
        XCTAssertEqual(defaults.string(forKey: "known_peripherals_v1"), "shared")
    }

    func testFirstLegacySettingsMigrationCopiesOnlyItsConfirmedOwnerAndKeepsExistingValues() {
        let suite = "ProfileErasure-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("legacy".utf8), forKey: "hr_settings_v1")
        defaults.set(Data("current-zones".utf8), forKey: "zone_plan_v1_profile_profile-a")
        defaults.set(Data("legacy-zones".utf8), forKey: "zone_plan_v1")
        XCTAssertTrue(ProfileErasureSettings.migrateLegacySettings(userDefaults: defaults,
            profileID: "profile-a", legacyFallback: "profile-a", erasedProfiles: []))
        XCTAssertEqual(defaults.data(forKey: "hr_settings_v1_profile_profile-a"), Data("legacy".utf8))
        XCTAssertEqual(defaults.data(forKey: "zone_plan_v1_profile_profile-a"), Data("current-zones".utf8))
        XCTAssertFalse(ProfileErasureSettings.migrateLegacySettings(userDefaults: defaults,
            profileID: "profile-b", legacyFallback: "profile-a", erasedProfiles: []))
        XCTAssertNil(defaults.data(forKey: "hr_settings_v1_profile_profile-b"))
    }

    func testStartupNormalizingLoaderCannotOverwriteLegacySettingsBeforeMigration() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ProfileErasure-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = Data(#"{"targetBpm":152,"cooldownTargetBpm":120,"zone1Max":135}"#.utf8)
        defaults.set(legacy, forKey: "hr_settings_v1")
        let store = try TelemetryStoreFactory.make(.onDisk(root.appendingPathComponent("test.store")))
        let erased = try await store.erasedProfileIdentifiers()
        var loaded: Data?
        ProfileErasureSettings.loadAfterLegacyMigration(userDefaults: defaults, profileID: "profile-a",
            legacyFallback: "profile-a", erasedProfiles: erased, load: {
                let scoped = "hr_settings_v1_profile_profile-a"
                // The app's normalization callback persists whichever value was loaded.
                loaded = defaults.data(forKey: scoped) ?? Data("defaults".utf8)
                defaults.set(loaded, forKey: scoped)
            })
        XCTAssertEqual(loaded, legacy)
        XCTAssertEqual(defaults.data(forKey: "hr_settings_v1_profile_profile-a"), legacy)
    }

    func testNewExportAfterDeletionContainsOnlyRetainedProfile() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TelemetryStoreFactory.make(.inMemory)
        try await store.insertSession(TelemetryPersistenceFixtures.session(seed: 1, profile: "profile-a"))
        try await store.insertSession(TelemetryPersistenceFixtures.session(seed: 2, profile: "profile-b"))
        try await store.eraseProfile("profile-a", legacyFallback: nil, logsDirectory: nil, temporaryDirectory: root)
        do { _ = try await store.exportWorkouts(.init(filter: .init(profileScope: .exact("profile-a")), selection: .all)); XCTFail("Erased profile exported") } catch {}
        let export = try await store.exportWorkouts(.init(filter: .init(profileScope: .exact("profile-b")), selection: .all))
        defer { try? FileManager.default.removeItem(at: export.directoryURL) }
        XCTAssertEqual(export.exportedWorkoutCount, 1)
    }
}
