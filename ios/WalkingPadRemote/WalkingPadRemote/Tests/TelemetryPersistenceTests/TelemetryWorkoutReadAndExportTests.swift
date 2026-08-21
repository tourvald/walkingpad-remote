import Foundation
import TelemetryAnalysis
import TelemetryDomain
@testable import TelemetryPersistence
import XCTest

final class TelemetryWorkoutReadAndExportTests: XCTestCase {
    func testFailedLegacyShadowSourceDoesNotBlockOrCorruptNativeV2Read() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let native = session(
            index: 99,
            profile: "profile-a",
            startedAt: Date(timeIntervalSince1970: 1_900_000_999)
        )
        try await store.insertSession(native)

        let report = await LegacyTelemetryMigrator(store: store).run(
            LegacyTelemetryMigrationRequest(
                jsonlSources: [],
                workoutHistorySources: [
                    LegacyWorkoutHistorySourceDescriptor(
                        storageKey: "workout_history_v1_profile_profile-a",
                        representation: Data("not-json".utf8),
                        exactProfileLocalIdentifier: "profile-a"
                    ),
                ],
                knownProfileLocalIdentifiers: ["profile-a"]
            )
        )
        XCTAssertEqual(report.completion, .failed)

        let page = try await store.fetchWorkoutHistoryPage(
            filter: WorkoutReadFilter(profileScope: .exact("profile-a")),
            after: nil,
            limit: 50
        )
        XCTAssertEqual(page.items.map(\.id), ["native:\(native.sessionID.description)"])
        XCTAssertEqual(page.items.first?.origin, .nativeV2)
    }

    func testProfileScopedKeysetPaginationIsStableForEqualTimestampsAndNewerInsert() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let sharedDate = Date(timeIntervalSince1970: 1_900_000_000)
        let sessions = [
            session(index: 2, profile: "profile-a", startedAt: sharedDate),
            session(index: 1, profile: "profile-a", startedAt: sharedDate),
            session(index: 3, profile: "profile-a", startedAt: sharedDate.addingTimeInterval(-60)),
            session(index: 4, profile: "profile-b", startedAt: sharedDate.addingTimeInterval(120)),
        ]
        for session in sessions {
            try await store.insertSession(session)
        }

        let filter = WorkoutReadFilter(profileScope: .exact("profile-a"))
        let first = try await store.fetchWorkoutHistoryPage(
            filter: filter,
            after: nil,
            limit: 1
        )
        XCTAssertEqual(first.items.count, 1)
        XCTAssertNotNil(first.nextCursor)

        let newer = session(
            index: 5,
            profile: "profile-a",
            startedAt: sharedDate.addingTimeInterval(300)
        )
        try await store.insertSession(newer)

        var observed = first.items
        var cursor = first.nextCursor
        while let current = cursor {
            let page = try await store.fetchWorkoutHistoryPage(
                filter: filter,
                after: current,
                limit: 1
            )
            observed.append(contentsOf: page.items)
            cursor = page.nextCursor
        }

        XCTAssertEqual(observed.count, 3)
        XCTAssertEqual(Set(observed.map(\.id)).count, 3)
        XCTAssertFalse(observed.contains { $0.id == "native:\(newer.sessionID.description)" })
        XCTAssertTrue(observed.allSatisfy { $0.id != "native:\(sessions[3].sessionID.description)" })
        XCTAssertEqual(
            Array(observed.prefix(2).map(\.id)),
            [sessions[1], sessions[0]].map { "native:\($0.sessionID.description)" }
        )
    }

    func testExactUUIDProfileScopeIncludesHistoricalCaseSpellingsOnly() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let profile = "A1000000-0000-0000-0000-000000000001"
        try await store.insertSession(
            session(index: 40, profile: profile, startedAt: Date(timeIntervalSince1970: 40))
        )
        try await store.insertSession(
            session(
                index: 41,
                profile: profile.lowercased(),
                startedAt: Date(timeIntervalSince1970: 41)
            )
        )
        try await store.insertSession(
            session(
                index: 42,
                profile: "B2000000-0000-0000-0000-000000000002",
                startedAt: Date(timeIntervalSince1970: 42)
            )
        )

        let page = try await store.fetchWorkoutHistoryPage(
            filter: WorkoutReadFilter(profileScope: .exact(profile)),
            after: nil,
            limit: 50
        )
        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(Set(page.items.map(\.id)).count, 2)
    }


    func testThousandsOfSessionsUseBoundedFetchesWithoutTimeSeriesHydration() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let configuration = self.configuration(targetHeartRate: 135)
        let total = 1_200
        for batchStart in stride(from: 0, to: total, by: 100) {
            let upper = min(total, batchStart + 100)
            let records: [TelemetryGateRecord] = (batchStart..<upper).map { index in
                .session(
                    session(
                        index: 10_000 + index,
                        profile: "scale-profile",
                        startedAt: Date(timeIntervalSince1970: 1_900_000_000 + Double(index)),
                        configuration: configuration
                    )
                )
            }
            try await store.insertGateBatch(records)
        }

        let filter = WorkoutReadFilter(profileScope: .exact("scale-profile"))
        var cursor: WorkoutHistoryCursor?
        var count = 0
        repeat {
            let page = try await store.fetchWorkoutHistoryPage(
                filter: filter,
                after: cursor,
                limit: 37
            )
            XCTAssertLessThanOrEqual(page.diagnostics.maximumStoreFetchLimit, 75)
            XCTAssertEqual(page.diagnostics.hydratedTimeSeriesRecordCount, 0)
            count += page.items.count
            cursor = page.nextCursor
        } while cursor != nil

        XCTAssertEqual(count, total)
    }

    func testStatisticsDateRangeStopsAtLowerBoundWithoutScanningWholeHistory() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let base = Date(timeIntervalSince1970: 1_900_000_000)
        for batchStart in stride(from: 0, to: 1_000, by: 100) {
            let records: [TelemetryGateRecord] = (batchStart..<(batchStart + 100)).map { index in
                .session(
                    session(
                        index: 20_000 + index,
                        profile: "range-profile",
                        startedAt: base.addingTimeInterval(Double(index))
                    )
                )
            }
            try await store.insertGateBatch(records)
        }

        let statistics = try await store.fetchWorkoutStatistics(
            filter: WorkoutReadFilter(
                profileScope: .exact("range-profile"),
                startedAtOrAfter: base.addingTimeInterval(990),
                startedBefore: base.addingTimeInterval(1_000)
            ),
            batchSize: 50
        )
        XCTAssertEqual(statistics.queryableWorkoutCount, 10)
        XCTAssertLessThanOrEqual(statistics.diagnostics.storeFetchCount, 24)
        XCTAssertLessThanOrEqual(statistics.diagnostics.maximumStoreFetchLimit, 101)
        XCTAssertEqual(statistics.diagnostics.hydratedTimeSeriesRecordCount, 0)
    }

    func testImportedIncompleteIdentityUncertainAndUnavailableMetricsRemainQueryable() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let now = Date(timeIntervalSince1970: 1_900_100_000)
        let definition = LegacyMigrationSourceDefinition(
            sourceID: "source-imported-uncertain",
            kind: .jsonl,
            contentHashDigest: String(repeating: "a", count: 64),
            locator: "immutable-source.jsonl",
            exactProfileLocalIdentifier: "profile-a"
        )
        _ = try await store.beginLegacyMigrationSource(
            definition,
            importerVersion: LegacyTelemetryMigrator.importerVersion,
            emptyAggregateStatePayload: Data("{}".utf8),
            now: now
        )
        let candidate = LegacyWorkoutCandidateDraft(
            candidateID: "candidate-uncertain",
            sourceItemIdentityKey: "source-item-uncertain",
            sourceID: definition.sourceID,
            origin: .jsonl,
            profileLocalIdentifier: "profile-a",
            workoutIdentifier: nil,
            healthKitWorkoutIdentifier: nil,
            stableLegacySessionIdentifier: nil,
            startedAt: now,
            endedAt: nil,
            identityUncertain: true,
            possibleDuplicate: true,
            summary: importedSummary(
                malformedRecordCount: 1,
                complete: false,
                warnings: ["truncated-tail", "missing-factual-speed"]
            )
        )
        _ = try await store.commitLegacyMigrationBatch(
            sourceID: definition.sourceID,
            records: [],
            candidates: [candidate],
            checkpointByteOffset: 100,
            checkpointRecordIndex: 1,
            parsedRecordCount: 1,
            malformedRecordCount: 1,
            warningCount: 2,
            aggregateStatePayload: Data("{}".utf8),
            completing: true,
            now: now
        )
        let reconciledCount = try await store.reconcileLegacyWorkoutCandidates()
        XCTAssertEqual(reconciledCount, 1)

        let page = try await store.fetchWorkoutHistoryPage(
            filter: WorkoutReadFilter(profileScope: .exact("profile-a")),
            after: nil,
            limit: 10
        )
        let item = try XCTUnwrap(page.items.first)
        XCTAssertEqual(item.origin, .importedLegacy)
        XCTAssertNil(item.durationSeconds)
        XCTAssertNil(item.averageHeartRate)
        XCTAssertNil(item.averageSpeed)
        XCTAssertEqual(item.quality.identityStatus, LegacyIdentityStatus.uncertain.rawValue)
        XCTAssertEqual(item.quality.lifecycleState, "imported-incomplete")
        XCTAssertTrue(item.quality.possibleDuplicate)
        XCTAssertFalse(item.quality.adaptationEligible)
        XCTAssertFalse(item.quality.includedInStatistics)
        XCTAssertTrue(item.quality.unavailableMetrics.contains("averageFactualSpeed") == false)
        XCTAssertTrue(item.quality.unavailableMetrics.contains("averageSpeed"))
        XCTAssertTrue(item.quality.warnings.contains("truncated-tail"))
    }

    func testUnusableNativeAnalysisDoesNotUpgradeMetricsOrAdaptationEligibility() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let storedSession = session(
            index: 70,
            profile: "profile-low-quality",
            startedAt: Date(timeIntervalSince1970: 1_900_100_070)
        )
        try await store.insertSession(storedSession)
        try await store.insertAnalysis(
            WorkoutAnalysisResult(
                analysisID: AnalysisID(rawValue: uuid(810_001)),
                recordID: RecordID(rawValue: uuid(810_002)),
                sessionID: storedSession.sessionID,
                analyzerVersion: AnalyzerVersion(rawValue: "low-quality-fixture"),
                evidenceHash: ContentHash(
                    algorithm: .sha256,
                    lowercaseHexDigest: String(repeating: "d", count: 64)
                ),
                generatedAt: Date(timeIntervalSince1970: 1_900_100_071),
                qualityGrade: .unusable,
                exclusions: [],
                keyMetrics: AnalysisKeyMetrics(
                    coveredDuration: ElapsedDuration(microseconds: 10_000_000),
                    averageHeartRate: 199,
                    maximumHeartRate: 220,
                    averageFactualSpeedKilometresPerHour: 19
                ),
                detailSchemaVersion: WorkoutAnalysisDetailV1.schemaVersion,
                versionedDetailPayload: Data("unusable-detail".utf8)
            )
        )

        let page = try await store.fetchWorkoutHistoryPage(
            filter: WorkoutReadFilter(profileScope: .exact("profile-low-quality")),
            after: nil,
            limit: 10
        )
        let item = try XCTUnwrap(page.items.first)
        XCTAssertEqual(item.quality.analysisGrade, AnalysisQualityGrade.unusable.rawValue)
        XCTAssertNil(item.averageHeartRate)
        XCTAssertNil(item.averageSpeed)
        XCTAssertNil(item.zoneSeconds)
        XCTAssertFalse(item.quality.adaptationEligible)
        XCTAssertTrue(item.quality.includedInStatistics)
    }

    func testExactImportedDuplicateEnrichesNativeHealthKitLinkageInHistoryAndExport() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let startedAt = Date(timeIntervalSince1970: 1_900_150_000)
        let native = session(index: 80, profile: "profile-historical", startedAt: startedAt)
        let healthKitIdentifier = uuid(880_001)
        try await store.insertSession(native)

        let sourceID = "source-historical-healthkit"
        try await importCandidates(
            [
                LegacyWorkoutCandidateDraft(
                    candidateID: "candidate-historical-healthkit",
                    sourceItemIdentityKey: "source-item-historical-healthkit",
                    sourceID: sourceID,
                    origin: .jsonl,
                    profileLocalIdentifier: "profile-historical",
                    workoutIdentifier: nil,
                    healthKitWorkoutIdentifier: healthKitIdentifier.uuidString.lowercased(),
                    stableLegacySessionIdentifier: native.sessionID.description,
                    startedAt: startedAt,
                    endedAt: startedAt.addingTimeInterval(600),
                    identityUncertain: false,
                    possibleDuplicate: false,
                    summary: importedSummary(
                        malformedRecordCount: 0,
                        complete: true,
                        warnings: []
                    )
                ),
            ],
            sourceID: sourceID,
            store: store,
            now: startedAt
        )

        let page = try await store.fetchWorkoutHistoryPage(
            filter: WorkoutReadFilter(profileScope: .exact("profile-historical")),
            after: nil,
            limit: 10
        )
        let item = try XCTUnwrap(page.items.first)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(item.origin, .nativeV2)
        XCTAssertEqual(item.healthKitWorkoutIdentifier, healthKitIdentifier)
        XCTAssertTrue(
            item.quality.provenance.contains("telemetry-v2-imported-exact-healthkit-linkage")
        )

        let artifact = try await store.exportWorkouts(
            WorkoutExportRequest(
                filter: WorkoutReadFilter(profileScope: .exact("profile-historical")),
                selection: .all,
                batchSize: 10
            )
        )
        defer { try? FileManager.default.removeItem(at: artifact.directoryURL) }
        let summary = try String(
            contentsOf: artifact.directoryURL.appendingPathComponent("session_summary_v1.jsonl"),
            encoding: .utf8
        )
        XCTAssertTrue(summary.lowercased().contains(healthKitIdentifier.uuidString.lowercased()))
        XCTAssertTrue(summary.contains("telemetry-v2-imported-exact-healthkit-linkage"))
    }

    func testConflictingExactImportedHealthKitEvidenceDoesNotEnrichNativeLinkage() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let startedAt = Date(timeIntervalSince1970: 1_900_160_000)
        let native = session(index: 81, profile: "profile-conflict", startedAt: startedAt)
        try await store.insertSession(native)

        let sourceID = "source-conflicting-healthkit"
        let candidates: [LegacyWorkoutCandidateDraft] = [
            LegacyWorkoutCandidateDraft(
                candidateID: "candidate-conflicting-healthkit-a",
                sourceItemIdentityKey: "source-item-conflicting-healthkit-a",
                sourceID: sourceID,
                origin: .jsonl,
                profileLocalIdentifier: "profile-conflict",
                workoutIdentifier: nil,
                healthKitWorkoutIdentifier: uuid(881_001).uuidString.lowercased(),
                stableLegacySessionIdentifier: native.sessionID.description,
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(600),
                identityUncertain: false,
                possibleDuplicate: false,
                summary: importedSummary(
                    malformedRecordCount: 0,
                    complete: true,
                    warnings: []
                )
            ),
            LegacyWorkoutCandidateDraft(
                candidateID: "candidate-conflicting-healthkit-b",
                sourceItemIdentityKey: "source-item-conflicting-healthkit-b",
                sourceID: sourceID,
                origin: .workoutHistory,
                profileLocalIdentifier: "profile-conflict",
                workoutIdentifier: nil,
                healthKitWorkoutIdentifier: uuid(881_002).uuidString.lowercased(),
                stableLegacySessionIdentifier: native.sessionID.description,
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(600),
                identityUncertain: false,
                possibleDuplicate: false,
                summary: importedSummary(
                    malformedRecordCount: 0,
                    complete: true,
                    warnings: []
                )
            ),
        ]
        try await importCandidates(
            candidates,
            sourceID: sourceID,
            store: store,
            now: startedAt
        )

        let page = try await store.fetchWorkoutHistoryPage(
            filter: WorkoutReadFilter(profileScope: .exact("profile-conflict")),
            after: nil,
            limit: 10
        )
        let item = try XCTUnwrap(page.items.first { $0.origin == .nativeV2 })
        XCTAssertNil(item.healthKitWorkoutIdentifier)
        XCTAssertTrue(item.quality.warnings.contains("conflicting-healthkit-workout-identifier"))
        XCTAssertTrue(
            item.quality.provenance.contains("telemetry-v2-imported-exact-healthkit-linkage")
        )
    }

    func testStatisticsExclusionAloneMarksPartialWithoutChangingSafeTotals() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let startedAt = Date(timeIntervalSince1970: 1_900_170_000)
        let sourceID = "source-statistics-exclusion"
        let safeSummary = LegacyWorkoutCandidateSummary(
            timestampDerivedDurationMicroseconds: 600_000_000,
            legacySummaryDurationSeconds: nil,
            targetBeatsPerMinute: 135,
            timestampDerivedAverageHeartRateBeatsPerMinute: 130,
            legacySummaryAverageHeartRateBeatsPerMinute: nil,
            legacyEstimatedAverageSpeedKilometresPerHour: 5.0,
            timestampDerivedZoneMicroseconds: [
                60_000_000, 120_000_000, 180_000_000, 120_000_000, 120_000_000,
            ],
            legacySummaryZoneSeconds: nil,
            heartRateCoveredMicroseconds: 600_000_000,
            heartRateUncoveredMicroseconds: 0,
            heartRateSampleCount: 600,
            missingTimestampCount: 0,
            malformedRecordCount: 0,
            ignoredStepFieldCount: 0,
            legacySessionEvidenceComplete: true,
            warnings: [],
            conflicts: []
        )
        try await importCandidates(
            [
                LegacyWorkoutCandidateDraft(
                    candidateID: "candidate-statistics-safe",
                    sourceItemIdentityKey: "source-item-statistics-safe",
                    sourceID: sourceID,
                    origin: .jsonl,
                    profileLocalIdentifier: "profile-statistics",
                    workoutIdentifier: "workout-statistics-safe",
                    healthKitWorkoutIdentifier: nil,
                    stableLegacySessionIdentifier: nil,
                    startedAt: startedAt,
                    endedAt: startedAt.addingTimeInterval(600),
                    identityUncertain: false,
                    possibleDuplicate: false,
                    summary: safeSummary
                ),
                LegacyWorkoutCandidateDraft(
                    candidateID: "candidate-statistics-uncertain",
                    sourceItemIdentityKey: "source-item-statistics-uncertain",
                    sourceID: sourceID,
                    origin: .jsonl,
                    profileLocalIdentifier: "profile-statistics",
                    workoutIdentifier: nil,
                    healthKitWorkoutIdentifier: nil,
                    stableLegacySessionIdentifier: nil,
                    startedAt: startedAt.addingTimeInterval(-900),
                    endedAt: nil,
                    identityUncertain: true,
                    possibleDuplicate: false,
                    summary: importedSummary(
                        malformedRecordCount: 0,
                        complete: true,
                        warnings: []
                    )
                ),
            ],
            sourceID: sourceID,
            store: store,
            now: startedAt
        )

        let statistics = try await store.fetchWorkoutStatistics(
            filter: WorkoutReadFilter(profileScope: .exact("profile-statistics")),
            batchSize: 10
        )
        XCTAssertEqual(statistics.queryableWorkoutCount, 2)
        XCTAssertEqual(statistics.includedWorkoutCount, 1)
        XCTAssertEqual(statistics.excludedWorkoutCount, 1)
        XCTAssertEqual(statistics.totalDurationSeconds, 600)
        XCTAssertEqual(statistics.zoneSeconds, [60, 120, 180, 120, 120])
        XCTAssertEqual(statistics.workoutsWithUnavailableDuration, 0)
        XCTAssertEqual(statistics.workoutsWithUnavailableZones, 0)
        XCTAssertEqual(statistics.exclusionReasonCounts, [.identity: 1])
        XCTAssertTrue(statistics.isPartial)
    }

    func testExportStreamsBatchesOmitsUnnecessaryIdentifiersAndManifestRoundTrips() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let session = session(
            index: 50,
            profile: "private-profile-id",
            startedAt: Date(timeIntervalSince1970: 1_900_200_000)
        )
        let source = TelemetryPersistenceFixtures.source(seed: 31, kind: .healthKitSelected)
        try await store.insertSession(session)
        try await store.insertSource(
            source,
            firstSeen: session.startedAt,
            lastSeen: session.startedAt.addingTimeInterval(120)
        )
        for index in 0..<101 {
            try await store.insertHeartRate(
                TelemetryPersistenceFixtures.heartRate(
                    seed: UInt8(index + 1),
                    session: session,
                    source: source,
                    arrivalOrder: UInt64(index),
                    bpm: UInt16(110 + (index % 20))
                )
            )
        }
        let healthKitID = UUID()
        try await store.associateHealthKitWorkout(
            sessionID: session.sessionID,
            workoutIdentifier: healthKitID
        )

        let artifact = try await store.exportWorkouts(
            WorkoutExportRequest(
                filter: WorkoutReadFilter(profileScope: .exact("private-profile-id")),
                selection: .all,
                batchSize: 17
            )
        )
        defer { try? FileManager.default.removeItem(at: artifact.directoryURL) }

        XCTAssertEqual(artifact.exportedWorkoutCount, 1)
        XCTAssertEqual(artifact.exportedRecordCount, 102)
        XCTAssertTrue(artifact.containsHealthData)
        XCTAssertEqual(Set(artifact.fileURLs.map(\.lastPathComponent)), Set([
            "raw_evidence_v1.jsonl",
            "normalized_evidence_v1.csv",
            "session_summary_v1.jsonl",
            "session_summary_v1.csv",
            "manifest.json",
        ]))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            WorkoutExportManifest.self,
            from: Data(contentsOf: artifact.directoryURL.appendingPathComponent("manifest.json"))
        )
        XCTAssertEqual(manifest.manifestVersion, WorkoutExportManifest.formatVersion)
        XCTAssertEqual(manifest.exportedRecordCount, 102)
        XCTAssertEqual(manifest.batchSize, 17)
        XCTAssertTrue(manifest.containsHealthData)
        XCTAssertTrue(manifest.omittedIdentifierKinds.contains("profile-id"))

        let raw = try String(
            contentsOf: artifact.directoryURL.appendingPathComponent("raw_evidence_v1.jsonl"),
            encoding: .utf8
        )
        XCTAssertEqual(raw.split(separator: "\n").count, 102)
        XCTAssertFalse(raw.contains("private-profile-id"))
        XCTAssertFalse(raw.contains("source-31"))
        XCTAssertFalse(raw.contains("test.source.31"))
        XCTAssertTrue(raw.contains("\"targetHeartRate\":135"))
        XCTAssertTrue(raw.contains(healthKitID.uuidString.lowercased()))
    }

    func testHealthKitWorkoutCannotBeAssociatedWithTwoV2Sessions() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let first = session(
            index: 60,
            profile: "profile-healthkit",
            startedAt: Date(timeIntervalSince1970: 1_900_250_000)
        )
        let second = session(
            index: 61,
            profile: "profile-healthkit",
            startedAt: Date(timeIntervalSince1970: 1_900_251_000)
        )
        try await store.insertSession(first)
        try await store.insertSession(second)
        let workoutIdentifier = UUID()
        try await store.associateHealthKitWorkout(
            sessionID: first.sessionID,
            workoutIdentifier: workoutIdentifier
        )

        do {
            try await store.associateHealthKitWorkout(
                sessionID: second.sessionID,
                workoutIdentifier: workoutIdentifier
            )
            XCTFail("One HealthKit workout UUID must not link to two V2 sessions")
        } catch let error as TelemetryStoreError {
            XCTAssertEqual(
                error,
                .conflictingStableIdentity(
                    "healthkit-workout:\(workoutIdentifier.uuidString.lowercased())"
                )
            )
        }
    }

    func testCancelledExportRemovesOnlyTemporaryArtifactAndPreservesStore() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        for index in 0..<100 {
            try await store.insertSession(
                session(
                    index: 20_000 + index,
                    profile: "profile-cancel",
                    startedAt: Date(timeIntervalSince1970: 1_900_300_000 + Double(index))
                )
            )
        }
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let before = try exportDirectories(in: temporaryDirectory)
        let task = Task {
            try await store.exportWorkouts(
                WorkoutExportRequest(
                    filter: WorkoutReadFilter(profileScope: .exact("profile-cancel")),
                    selection: .all,
                    batchSize: 1
                )
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled export unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        }
        let after = try exportDirectories(in: temporaryDirectory)
        XCTAssertEqual(after, before)
        let counts = try await store.counts()
        XCTAssertEqual(counts.sessions, 100)
    }

    func testExportProjectionErrorRemovesTemporaryArtifactAndPreservesEvidence() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let storedSession = session(
            index: 30_000,
            profile: "profile-export-error",
            startedAt: Date(timeIntervalSince1970: 1_900_400_000)
        )
        try await store.insertSession(storedSession)
        try await store.insertAnalysis(
            WorkoutAnalysisResult(
                analysisID: AnalysisID(rawValue: uuid(800_001)),
                recordID: RecordID(rawValue: uuid(800_002)),
                sessionID: storedSession.sessionID,
                analyzerVersion: AnalyzerVersion(rawValue: "malformed-fixture"),
                evidenceHash: ContentHash(
                    algorithm: .sha256,
                    lowercaseHexDigest: String(repeating: "c", count: 64)
                ),
                generatedAt: Date(timeIntervalSince1970: 1_900_400_001),
                qualityGrade: .high,
                exclusions: [],
                keyMetrics: AnalysisKeyMetrics(
                    coveredDuration: ElapsedDuration(microseconds: 600_000_000),
                    averageHeartRate: 130,
                    maximumHeartRate: 145,
                    averageFactualSpeedKilometresPerHour: 5.5
                ),
                detailSchemaVersion: WorkoutAnalysisDetailV1.schemaVersion,
                versionedDetailPayload: Data("not-json".utf8)
            )
        )

        let temporaryDirectory = FileManager.default.temporaryDirectory
        let before = try exportDirectories(in: temporaryDirectory)
        do {
            _ = try await store.exportWorkouts(
                WorkoutExportRequest(
                    filter: WorkoutReadFilter(
                        profileScope: .exact("profile-export-error")
                    ),
                    selection: .all,
                    batchSize: 10
                )
            )
            XCTFail("Malformed persisted analysis must fail explicitly")
        } catch {
            // Expected: the projection cannot decode persisted analysis detail.
        }
        let after = try exportDirectories(in: temporaryDirectory)
        XCTAssertEqual(after, before)
        let counts = try await store.counts()
        XCTAssertEqual(counts.sessions, 1)
        XCTAssertEqual(counts.analyses, 1)
    }

    private func session(
        index: Int,
        profile: String,
        startedAt: Date,
        configuration: ImmutableConfigurationSnapshot? = nil
    ) -> WorkoutSessionRecord {
        WorkoutSessionRecord(
            recordID: RecordID(rawValue: uuid(index * 2 + 1)),
            sessionID: SessionID(rawValue: uuid(index * 2 + 2)),
            profileLocalIdentifier: profile,
            lifecycleState: .completed,
            workoutMode: .heartRateControlled,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(600),
            endedElapsed: ElapsedDuration(microseconds: 600_000_000),
            incompleteReason: nil,
            appContext: AppRuntimeContext(
                appVersion: "1.2.3",
                buildNumber: "456",
                operatingSystemVersion: "iOS 26",
                deviceModel: "private-device-model"
            ),
            versions: RuntimeVersionContext(
                telemetrySchema: TelemetrySchemaVersion(rawValue: "1.0.0"),
                algorithm: AlgorithmVersion(rawValue: "algorithm-v1"),
                safetyPolicy: SafetyPolicyVersion(rawValue: "safety-v1"),
                workoutProtocol: WorkoutProtocolVersion(rawValue: "workout-v1")
            ),
            configuration: configuration ?? self.configuration(targetHeartRate: 135),
            healthKitWorkoutIdentifier: nil,
            treadmill: KnownTreadmillMetadata(
                stableLocalIdentifier: "private-treadmill-id",
                model: "private-treadmill-model",
                protocolName: "test"
            ),
            recorderHealth: RecorderHealthSummary(
                isComplete: true,
                lostCriticalRecordCount: 0,
                lostNativeRecordCount: 0,
                lastPersistedElapsed: ElapsedDuration(microseconds: 600_000_000)
            )
        )
    }

    private func configuration(targetHeartRate: Int) -> ImmutableConfigurationSnapshot {
        let payload = Data("{\"targetHeartRate\":\(targetHeartRate)}".utf8)
        return ImmutableConfigurationSnapshot(
            id: ConfigurationSnapshotID(rawValue: uuid(900_000 + targetHeartRate)),
            formatVersion: 1,
            format: .canonicalJSON,
            canonicalPayload: payload,
            contentHash: ContentHash(
                algorithm: .sha256,
                lowercaseHexDigest: String(repeating: "b", count: 64)
            )
        )
    }

    private func importedSummary(
        malformedRecordCount: Int,
        complete: Bool,
        warnings: [String]
    ) -> LegacyWorkoutCandidateSummary {
        LegacyWorkoutCandidateSummary(
            timestampDerivedDurationMicroseconds: nil,
            legacySummaryDurationSeconds: nil,
            targetBeatsPerMinute: nil,
            timestampDerivedAverageHeartRateBeatsPerMinute: nil,
            legacySummaryAverageHeartRateBeatsPerMinute: nil,
            legacyEstimatedAverageSpeedKilometresPerHour: nil,
            timestampDerivedZoneMicroseconds: nil,
            legacySummaryZoneSeconds: nil,
            heartRateCoveredMicroseconds: nil,
            heartRateUncoveredMicroseconds: nil,
            heartRateSampleCount: 0,
            missingTimestampCount: 1,
            malformedRecordCount: malformedRecordCount,
            ignoredStepFieldCount: 0,
            legacySessionEvidenceComplete: complete,
            warnings: warnings,
            conflicts: []
        )
    }

    private func importCandidates(
        _ candidates: [LegacyWorkoutCandidateDraft],
        sourceID: String,
        store: TelemetryStore,
        now: Date
    ) async throws {
        let definition = LegacyMigrationSourceDefinition(
            sourceID: sourceID,
            kind: .jsonl,
            contentHashDigest: String(repeating: "e", count: 64),
            locator: "\(sourceID).jsonl",
            exactProfileLocalIdentifier: candidates.first?.profileLocalIdentifier
        )
        _ = try await store.beginLegacyMigrationSource(
            definition,
            importerVersion: LegacyTelemetryMigrator.importerVersion,
            emptyAggregateStatePayload: Data("{}".utf8),
            now: now
        )
        _ = try await store.commitLegacyMigrationBatch(
            sourceID: sourceID,
            records: [],
            candidates: candidates,
            checkpointByteOffset: 100,
            checkpointRecordIndex: Int64(candidates.count),
            parsedRecordCount: Int64(candidates.count),
            malformedRecordCount: 0,
            warningCount: 0,
            aggregateStatePayload: Data("{}".utf8),
            completing: true,
            now: now
        )
        _ = try await store.reconcileLegacyWorkoutCandidates()
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", value))!
    }

    private func exportDirectories(in directory: URL) throws -> Set<String> {
        Set(
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent).filter { $0.hasPrefix("TelemetryV2Export_") }
        )
    }
}
