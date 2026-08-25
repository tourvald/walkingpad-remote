import Darwin
import Foundation
import TelemetryDomain
@testable import TelemetryPersistence
import TelemetryRuntime
import XCTest

private struct DiagnosticBundleBenchmarkResult: Codable {
    let workload: String
    let representedMinutes: Int
    let selection: String
    let exportedWorkoutCount: Int
    let exportedRecordCount: Int
    let exportGenerationSeconds: Double
    let packagingSeconds: Double
    let totalSeconds: Double
    let archiveBytes: UInt64
    let baselineResidentBytes: UInt64
    let peakResidentBytes: UInt64
    let peakResidentDeltaBytes: UInt64
    let maximumStreamingChunkBytes: Int
    let mainActorHeartbeatCount: Int
    let mainActorMaximumGapSeconds: Double
}

final class DiagnosticBundlePerformanceTests: XCTestCase {
    func testEmptyStoreProducesSupportOnlyBundle() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let export = try await store.exportWorkouts(
            WorkoutExportRequest(
                filter: WorkoutReadFilter(profileScope: .exact("profile-without-workouts")),
                selection: .latestCompleted(1)
            )
        )
        XCTAssertEqual(export.exportedWorkoutCount, 0)
        try FileManager.default.removeItem(at: export.directoryURL)
        let bundle = try await DiagnosticBundlePackager.createSupportOnly(
            supportSnapshot: benchmarkSupportSnapshot(),
            archiveName: "WalkingPad_Diagnostics.zip",
            workoutEvidenceStatus: "not_present",
            workoutEvidenceFailureCategory: "no_completed_workout"
        )
        defer { try? FileManager.default.removeItem(at: bundle.directoryURL) }

        XCTAssertEqual(bundle.exportedWorkoutCount, 0)
        XCTAssertEqual(bundle.exportedRecordCount, 0)
        XCTAssertFalse(bundle.containsHealthData)
        let evidenceFiles = try FileManager.default.contentsOfDirectory(
            at: bundle.directoryURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension != "zip" }
        XCTAssertEqual(evidenceFiles.map(\.lastPathComponent), ["support_diagnostics_v1.json"])
        let support = try Data(contentsOf: bundle.directoryURL.appendingPathComponent(
            "support_diagnostics_v1.json"
        ))
        let supportText = String(decoding: support, as: UTF8.self)
        XCTAssertTrue(supportText.contains(#""workoutEvidenceStatus" : "not_present""#))
        XCTAssertTrue(supportText.contains(#""workoutEvidenceFailureCategory" : "no_completed_workout""#))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.archiveURL.path))
    }

    func testRepresentativeThirtyMinuteTwoHourAndAllScopeExports() async throws {
        let workloads: [(String, TelemetryGateProfile, WorkoutExportSelection, Int, Int)] = [
            (
                "30-minute-latest",
                profile(name: "30-minute", sessionCount: 1, secondsPerSession: 1_800),
                .latestCompleted(1),
                30,
                1
            ),
            (
                "120-minute-latest",
                profile(name: "120-minute", sessionCount: 1, secondsPerSession: 7_200),
                .latestCompleted(1),
                120,
                1
            ),
            (
                "all-active-profile",
                profile(name: "all-scope", sessionCount: 13, secondsPerSession: 1_800),
                .all,
                120,
                4
            ),
        ]

        for (name, profile, selection, representedMinutes, expectedWorkouts) in workloads {
            let result = try await runWorkload(
                name: name,
                profile: profile,
                selection: selection,
                representedMinutes: representedMinutes
            )
            XCTAssertEqual(result.exportedWorkoutCount, expectedWorkouts)
            XCTAssertGreaterThan(result.exportedRecordCount, 0)
            XCTAssertGreaterThan(result.archiveBytes, 0)
            XCTAssertLessThanOrEqual(result.maximumStreamingChunkBytes, 64 * 1024)
            XCTAssertGreaterThan(result.mainActorHeartbeatCount, 0)
            XCTAssertLessThan(result.mainActorMaximumGapSeconds, 1.0)
            let data = try JSONEncoder.sorted.encode(result)
            print("DIAGNOSTIC_BUNDLE_BENCHMARK \(String(decoding: data, as: UTF8.self))")
        }
    }

    private func runWorkload(
        name: String,
        profile: TelemetryGateProfile,
        selection: WorkoutExportSelection,
        representedMinutes: Int
    ) async throws -> DiagnosticBundleBenchmarkResult {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticBundleBenchmark_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let generator = TelemetryGateFixtureGenerator(profile: profile)
        let store = try await Task.detached {
            try TelemetryStoreFactory.make(.onDisk(root.appendingPathComponent("TelemetryV2.store")))
        }.value
        try await persistFixture(generator: generator, store: store)

        let baselineResidentBytes = currentResidentBytes()
        let memorySampler = Task.detached(priority: .utility) {
            var peak = currentResidentBytes()
            while !Task.isCancelled {
                peak = max(peak, currentResidentBytes())
                try? await Task.sleep(for: .milliseconds(2))
            }
            return peak
        }
        let heartbeat = await MainActor.run { BenchmarkMainActorHeartbeat() }
        let heartbeatTask = Task { @MainActor in
            await heartbeat.run()
        }
        defer {
            memorySampler.cancel()
            heartbeatTask.cancel()
        }

        let totalStarted = ContinuousClock.now
        let exportStarted = ContinuousClock.now
        let artifact = try await store.exportWorkouts(
            WorkoutExportRequest(
                filter: WorkoutReadFilter(profileScope: .exact("profile-0")),
                selection: selection,
                batchSize: 128
            )
        )
        defer { try? FileManager.default.removeItem(at: artifact.directoryURL) }
        let exportSeconds = exportStarted.duration(to: .now).seconds
        let bundle = try await DiagnosticBundlePackager.create(
            workoutArtifact: artifact,
            supportSnapshot: benchmarkSupportSnapshot(),
            archiveName: "WalkingPad_Diagnostics.zip"
        )
        let totalSeconds = totalStarted.duration(to: .now).seconds

        memorySampler.cancel()
        heartbeatTask.cancel()
        let peakResidentBytes = await memorySampler.value
        _ = await heartbeatTask.result
        let heartbeatSnapshot = await MainActor.run { heartbeat.snapshot }

        return DiagnosticBundleBenchmarkResult(
            workload: name,
            representedMinutes: representedMinutes,
            selection: selection.description,
            exportedWorkoutCount: bundle.exportedWorkoutCount,
            exportedRecordCount: bundle.exportedRecordCount,
            exportGenerationSeconds: exportSeconds,
            packagingSeconds: bundle.packagingDurationSeconds,
            totalSeconds: totalSeconds,
            archiveBytes: bundle.archiveBytes,
            baselineResidentBytes: baselineResidentBytes,
            peakResidentBytes: peakResidentBytes,
            peakResidentDeltaBytes: peakResidentBytes > baselineResidentBytes
                ? peakResidentBytes - baselineResidentBytes
                : 0,
            maximumStreamingChunkBytes: bundle.maximumChunkBytes,
            mainActorHeartbeatCount: heartbeatSnapshot.count,
            mainActorMaximumGapSeconds: heartbeatSnapshot.maximumGapSeconds
        )
    }

    private func persistFixture(
        generator: TelemetryGateFixtureGenerator,
        store: TelemetryStore
    ) async throws {
        var pending: [TelemetryGateRecord] = []
        pending.reserveCapacity(generator.profile.batchSize)

        func flush(force: Bool = false) async throws {
            guard !pending.isEmpty,
                  force || pending.count == generator.profile.batchSize else { return }
            let batch = pending
            pending.removeAll(keepingCapacity: true)
            try await store.insertGateBatch(batch)
        }

        func append(_ record: TelemetryGateRecord) async throws {
            pending.append(record)
            try await flush()
        }

        for source in generator.sources { try await append(.source(source)) }
        try await flush(force: true)
        for sessionIndex in 0..<generator.profile.sessionCount {
            try await append(.session(generator.session(index: sessionIndex)))
            try await flush(force: true)
        }
        for sessionIndex in 0..<generator.profile.sessionCount {
            for sampleIndex in 0..<generator.profile.heartRatePerSession {
                try await append(.heartRate(generator.heartRate(
                    sessionIndex: sessionIndex,
                    sampleIndex: sampleIndex
                )))
            }
        }
        try await flush(force: true)
        for sessionIndex in 0..<generator.profile.sessionCount {
            for sampleIndex in 0..<generator.profile.treadmillPerSession {
                try await append(.treadmill(generator.treadmill(
                    sessionIndex: sessionIndex,
                    sampleIndex: sampleIndex
                )))
            }
        }
        try await flush(force: true)
        for sessionIndex in 0..<generator.profile.sessionCount {
            for event in generator.events(sessionIndex: sessionIndex) {
                try await append(.event(event))
            }
        }
        try await flush(force: true)
        for sessionIndex in 0..<generator.profile.sessionCount {
            for second in 0..<generator.profile.secondsPerSession {
                if let frame = generator.frame(sessionIndex: sessionIndex, elapsedSecond: second) {
                    try await append(.frame(frame))
                }
            }
        }
        try await flush(force: true)
        for sessionIndex in 0..<generator.profile.sessionCount {
            try await append(.analysis(generator.analysis(sessionIndex: sessionIndex)))
        }
        try await flush(force: true)
    }

    private func profile(
        name: String,
        sessionCount: Int,
        secondsPerSession: Int
    ) -> TelemetryGateProfile {
        TelemetryGateProfile(
            name: name,
            sessionCount: sessionCount,
            secondsPerSession: secondsPerSession,
            frameGapStartSecond: secondsPerSession / 2,
            frameGapLengthSeconds: 20,
            heartRateIntervalSeconds: 5,
            treadmillIntervalSeconds: 15,
            eventsPerSession: 20,
            batchSize: 128,
            queryRepetitions: 1
        )
    }
}

@MainActor
private final class BenchmarkMainActorHeartbeat {
    struct Snapshot {
        let count: Int
        let maximumGapSeconds: Double
    }

    private var count = 0
    private var maximumGapSeconds: Double = 0

    var snapshot: Snapshot {
        Snapshot(count: count, maximumGapSeconds: maximumGapSeconds)
    }

    func run() async {
        var previous = ContinuousClock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
            let current = ContinuousClock.now
            maximumGapSeconds = max(
                maximumGapSeconds,
                previous.duration(to: current).seconds
            )
            previous = current
            count += 1
        }
    }
}

private func currentResidentBytes() -> UInt64 {
    var information = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &information) { pointer in
        pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
            task_info(
                mach_task_self_,
                task_flavor_t(MACH_TASK_BASIC_INFO),
                $0,
                &count
            )
        }
    }
    return result == KERN_SUCCESS ? UInt64(information.resident_size) : 0
}

private func benchmarkSupportSnapshot() -> DiagnosticSupportSnapshot {
    DiagnosticSupportSnapshot(
        capturedAt: Date(timeIntervalSince1970: 1_000),
        runtime: .init(
            appVersion: "benchmark",
            buildNumber: "1",
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            telemetrySchemaVersion: "1.0.0",
            algorithmVersion: "benchmark-v1",
            safetyPolicyVersion: "benchmark-safety-v1",
            workoutProtocolVersion: "benchmark-workout-v1"
        ),
        nativeHeartRatePreflight: .init(
            phase: "idle",
            requestedAt: nil,
            providerPreparedAt: nil,
            collectionStartedAt: nil,
            firstNativeCallbackMeasuredAt: nil,
            firstNativeCallbackReceivedAt: nil,
            firstQualifyingLatencySeconds: nil,
            terminalAt: nil,
            terminalReason: nil,
            gateBlockReason: nil,
            providerState: "idle",
            providerCleanupInFlight: false,
            providerGeneration: 0,
            providerHasBoundAttempt: false,
            nativeWorkoutCommitted: false
        ),
        controllerUnits: .init(
            status: "not_read",
            physicalUnits: "unknown",
            observedAt: nil,
            ageSeconds: nil,
            isFresh: false,
            gateAllowed: false,
            blockReason: "units_not_read",
            evidenceConnectionEpoch: nil,
            currentConnectionEpoch: nil,
            isCurrentConnection: false,
            byteCount: nil,
            rawA6Hex: nil
        ),
        treadmill: .init(
            protocolName: "Unknown",
            isConnected: false,
            isControlReady: false,
            hasCurrentConnectionContext: false,
            protocolMatchesCurrentConnection: false,
            connectionEpoch: nil
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

private extension WorkoutExportSelection {
    var description: String {
        switch self {
        case .all: "all"
        case .latestCompleted(let count): "latest-completed-\(count)"
        }
    }
}

private extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
