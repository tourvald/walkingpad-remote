import Foundation
import TelemetryDomain
import TelemetryRecorder

struct TelemetrySoakFixture: Sendable {
    static let baseDate = Date(timeIntervalSince1970: 1_820_200_000)

    let workload: TelemetrySoakWorkload

    let sessionID = SessionID(rawValue: deterministicUUID(kind: 1, counter: 1))
    let heartRateSource = SignalSourceIdentity(
        id: SourceID(rawValue: deterministicUUID(kind: 2, counter: 1)),
        providerKind: .other("synthetic-soak"),
        stableLocalKey: "synthetic-soak-heart-rate"
    )
    let treadmillSource = SignalSourceIdentity(
        id: SourceID(rawValue: deterministicUUID(kind: 2, counter: 2)),
        providerKind: .treadmillProtocol,
        stableLocalKey: "synthetic-soak-treadmill"
    )

    var sessionHeader: WorkoutSessionRecord {
        WorkoutSessionRecord(
            recordID: RecordID(rawValue: Self.deterministicUUID(kind: 3, counter: 1)),
            sessionID: sessionID,
            profileLocalIdentifier: "synthetic-soak-profile",
            lifecycleState: .running,
            workoutMode: .heartRateControlled,
            startedAt: Self.baseDate,
            endedAt: nil,
            endedElapsed: nil,
            incompleteReason: nil,
            appContext: AppRuntimeContext(
                appVersion: "soak",
                buildNumber: "31",
                operatingSystemVersion: "hosted",
                deviceModel: "non-hardware-simulation"
            ),
            versions: RuntimeVersionContext(
                telemetrySchema: TelemetrySchemaVersion(rawValue: "v1"),
                algorithm: AlgorithmVersion(rawValue: "soak-control-v1"),
                safetyPolicy: SafetyPolicyVersion(rawValue: "soak-safety-v1"),
                workoutProtocol: WorkoutProtocolVersion(rawValue: "soak-workout-v1")
            ),
            configuration: ImmutableConfigurationSnapshot(
                id: ConfigurationSnapshotID(
                    rawValue: Self.deterministicUUID(kind: 4, counter: 1)
                ),
                formatVersion: 1,
                format: .canonicalJSON,
                canonicalPayload: Data(#"{"fixture":"telemetry-soak","version":1}"#.utf8),
                contentHash: ContentHash(
                    algorithm: .sha256,
                    lowercaseHexDigest: String(repeating: "3", count: 64)
                )
            ),
            healthKitWorkoutIdentifier: nil,
            treadmill: KnownTreadmillMetadata(
                stableLocalIdentifier: nil,
                model: nil,
                protocolName: "synthetic",
                protocolVersion: "1"
            ),
            recorderHealth: RecorderHealthSummary(
                isComplete: false,
                lostCriticalRecordCount: 0,
                lostNativeRecordCount: 0,
                lastPersistedElapsed: nil
            )
        )
    }

    var sourceRecords: [TelemetryPersistenceRecord] {
        [heartRateSource, treadmillSource].map {
            .source(
                TelemetrySourceRecord(
                    identity: $0,
                    firstSeen: Self.baseDate,
                    lastSeen: Self.baseDate.addingTimeInterval(
                        Double(workload.simulatedMinutes * 60)
                    )
                )
            )
        }
    }

    func heartRate(index: UInt64, elapsedMilliseconds: Int) -> TelemetryPersistenceRecord {
        let elapsed = ElapsedDuration(milliseconds: Int64(elapsedMilliseconds))!
        let timestamp = observationTimestamp(elapsed: elapsed)
        return .heartRate(
            HeartRateObservation(
                recordID: RecordID(rawValue: Self.deterministicUUID(kind: 5, counter: index)),
                observationID: ObservationID(
                    rawValue: Self.deterministicUUID(kind: 6, counter: index)
                ),
                sessionID: sessionID,
                source: heartRateSource,
                beatsPerMinute: UInt16(100 + index % 50),
                arrivalOrder: index,
                providerSequence: Int64(index),
                providerSampleIdentity: ProviderNativeSampleIdentity(
                    identifier: "synthetic-hr-\(index)"
                ),
                timestamp: timestamp,
                provenance: .reportedByProvider,
                freshness: freshness(elapsed: elapsed),
                quality: [],
                controlUse: index % 5 == 0 ? .acceptedAndUsed : .acceptedNotUsed
            )
        )
    }

    func treadmill(index: UInt64, elapsedMilliseconds: Int) -> TelemetryPersistenceRecord {
        let elapsed = ElapsedDuration(milliseconds: Int64(elapsedMilliseconds))!
        let timestamp = observationTimestamp(elapsed: elapsed)
        return .treadmill(
            TreadmillObservation(
                recordID: RecordID(rawValue: Self.deterministicUUID(kind: 7, counter: index)),
                observationID: ObservationID(
                    rawValue: Self.deterministicUUID(kind: 8, counter: index)
                ),
                sessionID: sessionID,
                source: treadmillSource,
                nativeSpeed: NativeTreadmillSpeed(
                    value: 3.0 + Double(index % 20) / 10,
                    unit: .kilometresPerHour
                ),
                deviceState: .moving,
                arrivalOrder: index,
                timestamp: timestamp,
                provenance: .decodedDeviceReport,
                freshness: freshness(elapsed: elapsed),
                quality: []
            )
        )
    }

    func frame(elapsedSecond: Int) -> TelemetryPersistenceRecord {
        let elapsed = ElapsedDuration(microseconds: Int64(elapsedSecond) * 1_000_000)
        return .frame(
            CanonicalFrame(
                frameID: FrameID(
                    rawValue: Self.deterministicUUID(
                        kind: 9,
                        counter: UInt64(elapsedSecond + 1)
                    )
                ),
                recordID: RecordID(
                    rawValue: Self.deterministicUUID(
                        kind: 10,
                        counter: UInt64(elapsedSecond + 1)
                    )
                ),
                sessionID: sessionID,
                canonicalElapsedSecond: Int64(elapsedSecond),
                materializedAt: RecordTimestamp(
                    recordedAt: Self.baseDate.addingTimeInterval(Double(elapsedSecond)),
                    elapsed: elapsed
                ),
                heartRateEvidence: nil,
                treadmillEvidence: nil
            )
        )
    }

    func lifecycleEvent(elapsedSecond: Int, ending: Bool) -> TelemetryPersistenceRecord {
        let elapsed = ElapsedDuration(microseconds: Int64(elapsedSecond) * 1_000_000)
        let date = Self.baseDate.addingTimeInterval(Double(elapsedSecond))
        return .event(
            WorkoutEvent(
                recordID: RecordID(
                    rawValue: Self.deterministicUUID(
                        kind: 11,
                        counter: ending ? 2 : 1
                    )
                ),
                sessionID: sessionID,
                timestamp: EventTimestamp(
                    occurredAt: date,
                    recordedAt: date,
                    occurredElapsed: elapsed,
                    recordedElapsed: elapsed
                ),
                payload: EventPayloadEnvelope(
                    schemaVersion: 1,
                    payload: .sessionLifecycle(
                        SessionLifecycleEvent(
                            previous: ending ? .running : .created,
                            current: ending ? .completed : .running
                        )
                    )
                )
            )
        )
    }

    private func observationTimestamp(elapsed: ElapsedDuration) -> ObservationTimestamp {
        let date = Self.baseDate.addingTimeInterval(elapsed.seconds)
        return ObservationTimestamp(
            measuredAt: date,
            receivedAt: date,
            recordedAt: date,
            measuredElapsed: elapsed,
            receivedElapsed: elapsed,
            recordedElapsed: elapsed
        )
    }

    private func freshness(elapsed: ElapsedDuration) -> EvidenceFreshness {
        EvidenceFreshness(
            state: .fresh,
            evaluatedAt: RecordTimestamp(
                recordedAt: Self.baseDate.addingTimeInterval(elapsed.seconds),
                elapsed: elapsed
            ),
            age: .zero,
            policyVersion: SafetyPolicyVersion(rawValue: "soak-safety-v1")
        )
    }

    static func deterministicUUID(kind: UInt16, counter: UInt64) -> UUID {
        let value = String(format: "%04x-%012llx", kind, counter)
        return UUID(uuidString: "00000000-0000-8000-\(value)")!
    }
}
