import Foundation
import TelemetryDomain
import TelemetryPersistence

private struct WorkerArguments {
    let storeURL: URL
    let markerURL: URL
    let committedHeartRateCount: Int

    init(arguments: [String]) throws {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
                return nil
            }
            return arguments[index + 1]
        }

        guard let storePath = value(after: "--store"),
              let markerPath = value(after: "--marker"),
              let countText = value(after: "--committed-heart-rate-count"),
              let count = Int(countText),
              count > 0
        else {
            throw WorkerError.invalidArguments
        }

        storeURL = URL(fileURLWithPath: storePath)
        markerURL = URL(fileURLWithPath: markerPath)
        committedHeartRateCount = count
    }
}

private enum WorkerError: Error {
    case invalidArguments
}

private struct RecoveryMarker: Codable {
    let sessionID: String
    let committedHeartRateCount: Int
    let committedIdentityHash: String
}

private enum RecoveryFixture {
    static let seed: UInt64 = 0x26_39_40
    static let baseDate = Date(timeIntervalSince1970: 1_820_000_000)

    static let sessionID = SessionID(rawValue: uuid(kind: 1, counter: 1))
    static let source = SignalSourceIdentity(
        id: SourceID(rawValue: uuid(kind: 2, counter: 1)),
        providerKind: .healthKitSelected,
        stableLocalKey: "gate-recovery-hr",
        savingSource: ProviderSavingSource(bundleIdentifier: "gate.synthetic.hr"),
        knownDevice: nil
    )

    static var versions: RuntimeVersionContext {
        RuntimeVersionContext(
            telemetrySchema: TelemetrySchemaVersion(rawValue: "v1"),
            algorithm: AlgorithmVersion(rawValue: "gate-algorithm-v1"),
            safetyPolicy: SafetyPolicyVersion(rawValue: "gate-safety-v1"),
            workoutProtocol: WorkoutProtocolVersion(rawValue: "gate-workout-v1")
        )
    }

    static var session: WorkoutSessionRecord {
        WorkoutSessionRecord(
            recordID: RecordID(rawValue: uuid(kind: 3, counter: 1)),
            sessionID: sessionID,
            profileLocalIdentifier: "gate-recovery-profile",
            lifecycleState: .running,
            workoutMode: .heartRateControlled,
            startedAt: baseDate,
            endedAt: nil,
            endedElapsed: nil,
            incompleteReason: nil,
            appContext: AppRuntimeContext(
                appVersion: "gate",
                buildNumber: "26",
                operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString
            ),
            versions: versions,
            configuration: ImmutableConfigurationSnapshot(
                id: ConfigurationSnapshotID(rawValue: uuid(kind: 4, counter: 1)),
                formatVersion: 1,
                format: .canonicalJSON,
                canonicalPayload: Data(#"{"fixture":"recovery"}"#.utf8),
                contentHash: ContentHash(
                    algorithm: .sha256,
                    lowercaseHexDigest: String(repeating: "26", count: 32)
                )
            ),
            healthKitWorkoutIdentifier: nil,
            treadmill: nil,
            recorderHealth: RecorderHealthSummary(
                isComplete: false,
                lostCriticalRecordCount: 0,
                lostNativeRecordCount: 0,
                lastPersistedElapsed: nil
            )
        )
    }

    static func heartRate(index: Int) -> HeartRateObservation {
        let elapsed = Int64(index) * 1_000_000
        let measured = baseDate.addingTimeInterval(Double(index))
        return HeartRateObservation(
            recordID: RecordID(rawValue: uuid(kind: 5, counter: UInt64(index))),
            observationID: ObservationID(rawValue: uuid(kind: 6, counter: UInt64(index))),
            sessionID: sessionID,
            source: source,
            beatsPerMinute: UInt16(100 + index % 40),
            arrivalOrder: UInt64(index),
            providerSequence: Int64(index),
            providerSampleIdentity: ProviderNativeSampleIdentity(identifier: "recovery-\(index)"),
            timestamp: ObservationTimestamp(
                measuredAt: measured,
                receivedAt: measured.addingTimeInterval(0.02),
                recordedAt: measured.addingTimeInterval(0.03),
                measuredElapsed: ElapsedDuration(microseconds: elapsed),
                receivedElapsed: ElapsedDuration(microseconds: elapsed + 20_000),
                recordedElapsed: ElapsedDuration(microseconds: elapsed + 30_000)
            ),
            provenance: .reportedByProvider,
            freshness: EvidenceFreshness(
                state: .fresh,
                evaluatedAt: RecordTimestamp(
                    recordedAt: measured.addingTimeInterval(0.03),
                    elapsed: ElapsedDuration(microseconds: elapsed + 30_000)
                ),
                age: ElapsedDuration(microseconds: 30_000),
                policyVersion: versions.safetyPolicy
            ),
            quality: [],
            controlUse: .acceptedNotUsed
        )
    }

    static func committedIdentityHash(count: Int) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for index in 0..<count {
            for byte in heartRate(index: index).observationID.description.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
        }
        return String(format: "%016llx", hash)
    }

    private static func uuid(kind: UInt64, counter: UInt64) -> UUID {
        var high = seed ^ (kind &* 0x9e37_79b9_7f4a_7c15) ^ counter
        var low = high &+ 0x9e37_79b9_7f4a_7c15
        high = mix(high)
        low = mix(low)
        let bytes = withUnsafeBytes(of: high.bigEndian) { Array($0) }
            + withUnsafeBytes(of: low.bigEndian) { Array($0) }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func mix(_ value: UInt64) -> UInt64 {
        var mixed = value
        mixed = (mixed ^ (mixed >> 30)) &* 0xbf58_476d_1ce4_e5b9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94d0_49bb_1331_11eb
        return mixed ^ (mixed >> 31)
    }
}

@main
private enum TelemetryGateCrashWorker {
    static func main() async throws {
        let arguments = try WorkerArguments(arguments: CommandLine.arguments)
        let store = try TelemetryStoreFactory.make(.onDisk(arguments.storeURL))

        try await store.insertSession(RecoveryFixture.session)
        try await store.insertSource(
            RecoveryFixture.source,
            firstSeen: RecoveryFixture.baseDate,
            lastSeen: RecoveryFixture.baseDate.addingTimeInterval(
                Double(arguments.committedHeartRateCount)
            )
        )
        for index in 0..<arguments.committedHeartRateCount {
            try await store.insertHeartRate(RecoveryFixture.heartRate(index: index))
        }

        // Allocate a deterministic uncommitted tail before telling the supervisor to kill us.
        _ = RecoveryFixture.heartRate(index: arguments.committedHeartRateCount)
        let marker = RecoveryMarker(
            sessionID: RecoveryFixture.sessionID.description,
            committedHeartRateCount: arguments.committedHeartRateCount,
            committedIdentityHash: RecoveryFixture.committedIdentityHash(
                count: arguments.committedHeartRateCount
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(marker).write(to: arguments.markerURL, options: .atomic)

        // The supervisor uses SIGKILL during this interval. Reaching the tail insert is a failure.
        try await Task.sleep(nanoseconds: 30_000_000_000)
        try await store.insertHeartRate(
            RecoveryFixture.heartRate(index: arguments.committedHeartRateCount)
        )
        throw WorkerError.invalidArguments
    }
}
