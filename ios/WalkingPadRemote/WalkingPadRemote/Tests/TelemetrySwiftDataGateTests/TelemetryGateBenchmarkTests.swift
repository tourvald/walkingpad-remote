import Darwin
import Foundation
import TelemetryDomain
@testable import TelemetryPersistence
import XCTest

private struct GateLatencySummary: Codable, Equatable {
    let samples: Int
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let p99Milliseconds: Double
    let minimumMilliseconds: Double
    let maximumMilliseconds: Double

    static func calculate(_ values: [Double]) -> GateLatencySummary {
        precondition(!values.isEmpty)
        let sorted = values.sorted()
        return GateLatencySummary(
            samples: sorted.count,
            p50Milliseconds: percentile(sorted, percentile: 0.50),
            p95Milliseconds: percentile(sorted, percentile: 0.95),
            p99Milliseconds: percentile(sorted, percentile: 0.99),
            minimumMilliseconds: sorted[0],
            maximumMilliseconds: sorted[sorted.count - 1]
        )
    }

    private static func percentile(_ sorted: [Double], percentile: Double) -> Double {
        let rank = max(1, Int(ceil(percentile * Double(sorted.count))))
        return sorted[min(rank - 1, sorted.count - 1)]
    }
}

private struct GateStorageFile: Codable, Equatable {
    let name: String
    let bytes: UInt64
    let protection: String?
    let excludedFromBackup: Bool?
}

private struct GateStorageSnapshot: Codable, Equatable {
    let lifecycle: String
    let files: [GateStorageFile]

    var primaryBytes: UInt64 {
        files.first { !$0.name.contains("-wal") && !$0.name.contains("-shm") }?.bytes ?? 0
    }

    var walBytes: UInt64 {
        files.first { $0.name.contains("-wal") }?.bytes ?? 0
    }

    var shmBytes: UInt64 {
        files.first { $0.name.contains("-shm") }?.bytes ?? 0
    }

    var totalBytes: UInt64 {
        files.reduce(0) { $0 + $1.bytes }
    }
}

private struct GateMemorySummary: Codable, Equatable {
    let mechanism: String
    let generationEndpointPeakBytes: UInt64
    let persistenceEndpointPeakBytes: UInt64
    let queryEndpointPeakBytes: UInt64
    let exportEndpointPeakBytes: UInt64
    let processLifetimePeakBytes: UInt64
}

private struct GateQuerySummary: Codable, Equatable {
    let shape: String
    let returnedRecords: Int
    let latency: GateLatencySummary
}

private struct GateInsertScaleSummary: Codable, Equatable {
    let lowerBoundPersistedRecords: Int
    let upperBoundPersistedRecords: Int
    let transactionLatency: GateLatencySummary
}

private struct GateBenchmarkSummary: Codable, Equatable {
    let harnessVersion: String
    let profile: TelemetryGateProfile
    let deterministicSeed: UInt64
    let representedWorkoutHours: Double
    let expectedCounts: TelemetryGateExpectedCounts
    let actualCounts: TelemetryStoreCounts
    let deterministicIdentityHash: String
    let transactionCount: Int
    let full128RecordTransactionCount: Int
    let expectedNativeRedeliveryRejections: Int
    let unexpectedFailureCount: Int
    let totalDrainSeconds: Double
    let persistedRecordsPerSecond: Double
    let full128RecordTransactionLatency: GateLatencySummary
    let insertScaling: [GateInsertScaleSummary]
    let queries: [GateQuerySummary]
    let memory: GateMemorySummary
    let storageStages: [GateStorageSnapshot]
    let afterWriteStorage: GateStorageSnapshot
    let afterReopenStorage: GateStorageSnapshot
    let bytesPerWorkoutHourAfterWrite: Double
    let bytesPerWorkoutHourAfterReopen: Double
    let filePolicyHostPass: Bool
    let storeURL: String
    let operatingSystem: String
    let processorArchitecture: String
}

final class TelemetryGateBenchmarkTests: XCTestCase {
    func testFastCIProfile() async throws {
        let first = try await runProfile(.fast, preserveStore: false)
        XCTAssertEqual(first.actualCounts, first.expectedCounts.storeCounts)
        XCTAssertEqual(first.representedWorkoutHours, 2.0 / 3.0, accuracy: 0.000_001)
        XCTAssertGreaterThan(first.full128RecordTransactionCount, 0)
        XCTAssertEqual(first.unexpectedFailureCount, 0)
        XCTAssertTrue(first.filePolicyHostPass)

        let second = try await runProfile(.fast, preserveStore: false)
        XCTAssertEqual(first.expectedCounts, second.expectedCounts)
        XCTAssertEqual(first.deterministicIdentityHash, second.deterministicIdentityHash)
    }

    func testConfiguredFullProfile() async throws {
        guard ProcessInfo.processInfo.environment["TELEMETRY_GATE_PROFILE"] == "full" else {
            throw XCTSkip("Set TELEMETRY_GATE_PROFILE=full to run the required 1000-hour profile.")
        }
        let summary = try await runProfile(.full, preserveStore: true)
        XCTAssertEqual(summary.representedWorkoutHours, 1_000, accuracy: 0.000_001)
        XCTAssertGreaterThanOrEqual(summary.actualCounts.frames, 3_000_000)
        XCTAssertGreaterThanOrEqual(summary.expectedCounts.totalPersistedRecords, 4_000_000)
        XCTAssertEqual(summary.actualCounts, summary.expectedCounts.storeCounts)
        XCTAssertEqual(summary.unexpectedFailureCount, 0)
        XCTAssertTrue(summary.filePolicyHostPass)
    }

    private func runProfile(
        _ profile: TelemetryGateProfile,
        preserveStore: Bool
    ) async throws -> GateBenchmarkSummary {
        let generator = TelemetryGateFixtureGenerator(profile: profile)
        let expected = generator.expectedCounts
        let runRoot = try benchmarkRunRoot(profile: profile, preserveStore: preserveStore)
        let storeURL = runRoot.appendingPathComponent("TelemetryV2.store")
        let store = try await Task.detached {
            try TelemetryStoreFactory.make(.onDisk(storeURL))
        }.value
        let autosaveEnabled = await store.isAutosaveEnabled()
        let runsOnMainThread = await store.gateRunsOnMainThread()
        XCTAssertFalse(autosaveEnabled)
        XCTAssertFalse(runsOnMainThread)

        var pending: [TelemetryGateRecord] = []
        pending.reserveCapacity(profile.batchSize)
        var transactionLatencies: [(recordsBefore: Int, batchSize: Int, milliseconds: Double)] = []
        var full128Latencies: [Double] = []
        var persistedRecordCount = 0
        var transactionCount = 0
        var unexpectedFailures = 0
        var identityHasher = TelemetryGateIdentityHasher()
        var generationPeak = GateMemoryProbe.currentPhysicalFootprintBytes()
        var persistencePeak = generationPeak

        func recordIdentity(_ record: TelemetryGateRecord) -> String {
            switch record {
            case let .session(value): value.recordID.description
            case let .source(value): value.identity.id.description
            case let .heartRate(value): value.recordID.description
            case let .treadmill(value): value.recordID.description
            case let .event(value): value.recordID.description
            case let .frame(value): value.recordID.description
            case let .analysis(value): value.recordID.description
            }
        }

        func persistPending(force: Bool = false) async throws {
            guard !pending.isEmpty, force || pending.count == profile.batchSize else {
                return
            }
            generationPeak = max(
                generationPeak,
                GateMemoryProbe.currentPhysicalFootprintBytes()
            )
            let batch = pending
            pending.removeAll(keepingCapacity: true)
            let started = DispatchTime.now().uptimeNanoseconds
            do {
                try await store.insertGateBatch(batch)
            } catch {
                unexpectedFailures += 1
                throw error
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            transactionLatencies.append(
                (recordsBefore: persistedRecordCount, batchSize: batch.count, milliseconds: elapsed)
            )
            if batch.count == 128 {
                full128Latencies.append(elapsed)
            }
            persistedRecordCount += batch.count
            transactionCount += 1
            persistencePeak = max(
                persistencePeak,
                GateMemoryProbe.currentPhysicalFootprintBytes()
            )
        }

        func append(_ record: TelemetryGateRecord) async throws {
            identityHasher.update(recordIdentity(record))
            pending.append(record)
            try await persistPending()
        }

        let drainStarted = DispatchTime.now().uptimeNanoseconds
        for source in generator.sources {
            try await append(.source(source))
        }
        try await persistPending(force: true)

        for sessionIndex in 0..<profile.sessionCount {
            try await append(.session(generator.session(index: sessionIndex)))
            // Save the configuration owner before another session reuses it. This keeps the
            // benchmark on the Foundation's existing configuration lookup semantics.
            try await persistPending(force: true)
        }
        var storageStages = [
            try storageSnapshot(primaryStoreURL: storeURL, lifecycle: "schema-sources-sessions"),
        ]

        for sessionIndex in 0..<profile.sessionCount {
            for sampleIndex in 0..<profile.heartRatePerSession {
                try await append(
                    .heartRate(
                        generator.heartRate(
                            sessionIndex: sessionIndex,
                            sampleIndex: sampleIndex
                        )
                    )
                )
            }
        }
        try await persistPending(force: true)

        var nativeRedeliveryRejections = 0
        for sessionIndex in 0..<profile.sessionCount {
            for sampleIndex in generator.redeliverySampleIndices() {
                do {
                    try await store.insertHeartRate(
                        generator.heartRate(
                            sessionIndex: sessionIndex,
                            sampleIndex: sampleIndex,
                            redelivery: true
                        )
                    )
                    XCTFail("Stable provider-native redelivery unexpectedly persisted.")
                } catch TelemetryStoreError.duplicateStableIdentity {
                    nativeRedeliveryRejections += 1
                } catch {
                    unexpectedFailures += 1
                    throw error
                }
            }
        }
        storageStages.append(
            try storageSnapshot(primaryStoreURL: storeURL, lifecycle: "after-native-heart-rate")
        )

        for sessionIndex in 0..<profile.sessionCount {
            for sampleIndex in 0..<profile.treadmillPerSession {
                try await append(
                    .treadmill(
                        generator.treadmill(
                            sessionIndex: sessionIndex,
                            sampleIndex: sampleIndex
                        )
                    )
                )
            }
        }
        try await persistPending(force: true)
        storageStages.append(
            try storageSnapshot(primaryStoreURL: storeURL, lifecycle: "after-treadmill")
        )

        for sessionIndex in 0..<profile.sessionCount {
            for event in generator.events(sessionIndex: sessionIndex) {
                try await append(.event(event))
            }
        }
        try await persistPending(force: true)
        storageStages.append(
            try storageSnapshot(primaryStoreURL: storeURL, lifecycle: "after-events")
        )

        for sessionIndex in 0..<profile.sessionCount {
            for second in 0..<profile.secondsPerSession {
                if let frame = generator.frame(sessionIndex: sessionIndex, elapsedSecond: second) {
                    try await append(.frame(frame))
                }
            }
        }
        try await persistPending(force: true)
        storageStages.append(
            try storageSnapshot(primaryStoreURL: storeURL, lifecycle: "after-canonical-frames")
        )

        for sessionIndex in 0..<profile.sessionCount {
            try await append(.analysis(generator.analysis(sessionIndex: sessionIndex)))
        }
        try await persistPending(force: true)
        storageStages.append(
            try storageSnapshot(primaryStoreURL: storeURL, lifecycle: "after-analyses")
        )
        let drainSeconds = Double(DispatchTime.now().uptimeNanoseconds - drainStarted)
            / 1_000_000_000

        let actualCounts = try await store.counts()
        XCTAssertEqual(actualCounts, expected.storeCounts)
        XCTAssertEqual(nativeRedeliveryRejections, expected.expectedNativeRedeliveryRejections)
        try await validateSemantics(store: store, generator: generator)

        let afterWrite = try storageSnapshot(
            primaryStoreURL: storeURL,
            lifecycle: "after-write"
        )
        let queryResult = try await benchmarkQueries(store: store, generator: generator)
        let afterReopenStore = try await Task.detached {
            try TelemetryStoreFactory.make(.onDisk(storeURL))
        }.value
        let afterReopenCounts = try await afterReopenStore.counts()
        XCTAssertEqual(afterReopenCounts, expected.storeCounts)
        let afterReopen = try storageSnapshot(
            primaryStoreURL: storeURL,
            lifecycle: "after-reopen"
        )

        let scaleSummaries = insertScaleSummaries(
            transactionLatencies,
            totalRecords: expected.totalPersistedRecords
        )
        let filePolicyHostPass = (afterWrite.files + afterReopen.files).allSatisfy {
            $0.protection == FileProtectionType.completeUntilFirstUserAuthentication.rawValue
                && $0.excludedFromBackup == true
        }
        XCTAssertTrue(filePolicyHostPass)
        XCTAssertFalse(full128Latencies.isEmpty)

        let summary = GateBenchmarkSummary(
            harnessVersion: "swiftdata-gate-v1",
            profile: profile,
            deterministicSeed: generator.seed,
            representedWorkoutHours: profile.representedWorkoutHours,
            expectedCounts: expected,
            actualCounts: actualCounts,
            deterministicIdentityHash: identityHasher.lowercaseHexDigest,
            transactionCount: transactionCount,
            full128RecordTransactionCount: full128Latencies.count,
            expectedNativeRedeliveryRejections: nativeRedeliveryRejections,
            unexpectedFailureCount: unexpectedFailures,
            totalDrainSeconds: drainSeconds,
            persistedRecordsPerSecond: Double(expected.totalPersistedRecords) / drainSeconds,
            full128RecordTransactionLatency: GateLatencySummary.calculate(full128Latencies),
            insertScaling: scaleSummaries,
            queries: queryResult.summaries,
            memory: GateMemorySummary(
                mechanism: "getrusage RUSAGE_SELF ru_maxrss process high-water sampled at batch/query endpoints",
                generationEndpointPeakBytes: generationPeak,
                persistenceEndpointPeakBytes: persistencePeak,
                queryEndpointPeakBytes: queryResult.queryPeakBytes,
                exportEndpointPeakBytes: queryResult.exportPeakBytes,
                processLifetimePeakBytes: GateMemoryProbe.lifetimePeakPhysicalFootprintBytes()
            ),
            storageStages: storageStages,
            afterWriteStorage: afterWrite,
            afterReopenStorage: afterReopen,
            bytesPerWorkoutHourAfterWrite: Double(afterWrite.totalBytes)
                / profile.representedWorkoutHours,
            bytesPerWorkoutHourAfterReopen: Double(afterReopen.totalBytes)
                / profile.representedWorkoutHours,
            filePolicyHostPass: filePolicyHostPass,
            storeURL: storeURL.path,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            processorArchitecture: machineArchitecture()
        )
        try writeSummaryIfRequested(summary)
        if !preserveStore {
            try? FileManager.default.removeItem(at: runRoot)
        }
        return summary
    }

    private func validateSemantics(
        store: TelemetryStore,
        generator: TelemetryGateFixtureGenerator
    ) async throws {
        let sessionIndex = generator.profile.sessionCount - 1
        let probe = generator.causalProbe(sessionIndex: sessionIndex)
        let heartRate = try await store.fetchHeartRate(sessionID: probe.sessionID)
        let treadmill = try await store.fetchTreadmill(sessionID: probe.sessionID)
        let frames = try await store.fetchFrames(sessionID: probe.sessionID)
        let events = try await store.fetchEvents(sessionID: probe.sessionID)
        let analyses = try await store.fetchAnalyses(sessionID: probe.sessionID)
        XCTAssertEqual(heartRate.count, generator.profile.heartRatePerSession)
        XCTAssertEqual(treadmill.count, generator.profile.treadmillPerSession)
        XCTAssertEqual(frames.count, generator.profile.framesPerSession)
        XCTAssertEqual(events.count, generator.profile.eventsPerSession)
        XCTAssertEqual(analyses.count, 1)

        let frameSeconds = Set(frames.map(\.canonicalElapsedSecond))
        for second in generator.profile.frameGapStartSecond..<(
            generator.profile.frameGapStartSecond + generator.profile.frameGapLengthSeconds
        ) {
            XCTAssertFalse(frameSeconds.contains(Int64(second)))
        }
        let postGapSecond = Int64(
            generator.profile.frameGapStartSecond + generator.profile.frameGapLengthSeconds
        )
        XCTAssertEqual(
            frames.first { $0.canonicalElapsedSecond == postGapSecond }?.precedingGap,
            CanonicalGapBoundary(
                missingSinceElapsedSecond: Int64(generator.profile.frameGapStartSecond),
                kind: .runtimeSuspensionOrStall
            )
        )
        XCTAssertTrue(frames.allSatisfy { $0.heartRateEvidence != nil && $0.treadmillEvidence != nil })

        let firstDuplicatePair = 21...22
        let pair = heartRate.filter { firstDuplicatePair.contains(Int($0.arrivalOrder)) }
        XCTAssertEqual(pair.count, 2)
        XCTAssertEqual(Set(pair.map(\.beatsPerMinute)).count, 1)
        XCTAssertEqual(Set(pair.compactMap(\.providerSequence)).count, 1)
        XCTAssertTrue(pair.allSatisfy { $0.providerSampleIdentity == nil })
        let decisionEvents = try await store.gateFetchEvents(decisionID: probe.decisionID)
        let commandEvents = try await store.gateFetchEvents(commandID: probe.commandID)
        let attemptEvents = try await store.gateFetchEvents(attemptID: probe.attemptID)
        XCTAssertEqual(decisionEvents.count, 4)
        XCTAssertEqual(commandEvents.count, 3)
        XCTAssertEqual(attemptEvents.count, 2)
        XCTAssertTrue(events.allSatisfy {
            $0.payload.payload.causalIDs
                == WorkoutEventCausalIDs(
                    decisionID: $0.decisionID,
                    commandID: $0.commandID,
                    attemptID: $0.attemptID
                )
        })
        XCTAssertTrue(treadmill.allSatisfy {
            $0.factualSpeed?.provenance == .decodedDeviceReport
        })
    }

    private func benchmarkQueries(
        store: TelemetryStore,
        generator: TelemetryGateFixtureGenerator
    ) async throws -> (summaries: [GateQuerySummary], queryPeakBytes: UInt64, exportPeakBytes: UInt64) {
        let sessionIndex = generator.profile.sessionCount - 1
        let probe = generator.causalProbe(sessionIndex: sessionIndex)
        var summaries: [GateQuerySummary] = []
        var queryPeak = GateMemoryProbe.currentPhysicalFootprintBytes()
        var exportPeak: UInt64 = 0

        func measure(
            shape: String,
            operation: () async throws -> Int
        ) async throws {
            _ = try await operation()
            var values: [Double] = []
            var count = 0
            for _ in 0..<generator.profile.queryRepetitions {
                let started = DispatchTime.now().uptimeNanoseconds
                count = try await operation()
                values.append(
                    Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                )
                queryPeak = max(queryPeak, GateMemoryProbe.currentPhysicalFootprintBytes())
            }
            summaries.append(
                GateQuerySummary(
                    shape: shape,
                    returnedRecords: count,
                    latency: GateLatencySummary.calculate(values)
                )
            )
        }

        try await measure(shape: "recent workout history by profile") {
            try await store.gateFetchRecentSessions(
                profileLocalIdentifier: probe.profileLocalIdentifier,
                limit: 20
            ).count
        }
        try await measure(shape: "single-session HR time series by arrival order") {
            try await store.fetchHeartRate(sessionID: probe.sessionID).count
        }
        try await measure(shape: "single-session treadmill time series by arrival order") {
            try await store.fetchTreadmill(sessionID: probe.sessionID).count
        }
        try await measure(shape: "canonical frames for chart and replay") {
            try await store.fetchFrames(sessionID: probe.sessionID).count
        }
        try await measure(shape: "all events for a session") {
            try await store.fetchEvents(sessionID: probe.sessionID).count
        }
        try await measure(shape: "events filtered by event kind") {
            try await store.fetchEvents(
                sessionID: probe.sessionID,
                kind: .commandLifecycle
            ).count
        }
        try await measure(shape: "causal event lookup by decision ID") {
            try await store.gateFetchEvents(decisionID: probe.decisionID).count
        }
        try await measure(shape: "causal event lookup by command ID") {
            try await store.gateFetchEvents(commandID: probe.commandID).count
        }
        try await measure(shape: "causal event lookup by attempt ID") {
            try await store.gateFetchEvents(attemptID: probe.attemptID).count
        }
        try await measure(shape: "analyses by session and analyzer version") {
            try await store.fetchAnalyses(
                sessionID: probe.sessionID,
                analyzerVersion: AnalyzerVersion(rawValue: "gate-analyzer-v1")
            ).count
        }
        try await measure(shape: "last N comparable sessions by profile and decoded mode") {
            try await store.gateFetchComparableSessions(
                profileLocalIdentifier: probe.profileLocalIdentifier,
                workoutMode: probe.workoutMode,
                limit: 10
            ).count
        }

        let exportStarted = DispatchTime.now().uptimeNanoseconds
        let traversal = try await store.gateTraverseSession(probe.sessionID)
        exportPeak = GateMemoryProbe.currentPhysicalFootprintBytes()
        summaries.append(
            GateQuerySummary(
                shape: "export-style complete session evidence traversal",
                returnedRecords: traversal.total,
                latency: GateLatencySummary.calculate([
                    Double(DispatchTime.now().uptimeNanoseconds - exportStarted) / 1_000_000,
                ])
            )
        )
        return (summaries, queryPeak, exportPeak)
    }

    private func insertScaleSummaries(
        _ samples: [(recordsBefore: Int, batchSize: Int, milliseconds: Double)],
        totalRecords: Int
    ) -> [GateInsertScaleSummary] {
        let bounds = [0, totalRecords / 10, totalRecords / 4, totalRecords / 2, totalRecords]
        return zip(bounds, bounds.dropFirst()).compactMap { lower, upper in
            let latencies = samples.filter {
                $0.batchSize == 128 && $0.recordsBefore >= lower && $0.recordsBefore < upper
            }.map(\.milliseconds)
            guard !latencies.isEmpty else {
                return nil
            }
            return GateInsertScaleSummary(
                lowerBoundPersistedRecords: lower,
                upperBoundPersistedRecords: upper,
                transactionLatency: GateLatencySummary.calculate(latencies)
            )
        }
    }

    private func storageSnapshot(
        primaryStoreURL: URL,
        lifecycle: String
    ) throws -> GateStorageSnapshot {
        let files = try TelemetryStoreFilePolicy.discoveredStoreFiles(
            primaryStoreURL: primaryStoreURL
        )
        let values = try files.map { url in
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let resourceValues = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
            return GateStorageFile(
                name: url.lastPathComponent,
                bytes: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                protection: (attributes[.protectionKey] as? FileProtectionType)?.rawValue,
                excludedFromBackup: resourceValues.isExcludedFromBackup
            )
        }
        return GateStorageSnapshot(lifecycle: lifecycle, files: values)
    }

    private func benchmarkRunRoot(
        profile: TelemetryGateProfile,
        preserveStore: Bool
    ) throws -> URL {
        if preserveStore,
           let requested = ProcessInfo.processInfo.environment["TELEMETRY_GATE_STORE_DIRECTORY"]
        {
            let url = URL(fileURLWithPath: requested, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "telemetry-swiftdata-gate-\(profile.name)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSummaryIfRequested(_ summary: GateBenchmarkSummary) throws {
        guard let outputPath = ProcessInfo.processInfo.environment["TELEMETRY_GATE_OUTPUT"] else {
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(summary).write(
            to: URL(fileURLWithPath: outputPath),
            options: .atomic
        )
    }

    private func machineArchitecture() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}

private enum GateMemoryProbe {
    static func currentPhysicalFootprintBytes() -> UInt64 {
        highWaterResidentBytes()
    }

    static func lifetimePeakPhysicalFootprintBytes() -> UInt64 {
        highWaterResidentBytes()
    }

    private static func highWaterResidentBytes() -> UInt64 {
        var usage = rusage()
        let result = getrusage(RUSAGE_SELF, &usage)
        return result == 0 ? UInt64(max(0, usage.ru_maxrss)) : 0
    }
}
