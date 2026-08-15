import Foundation
import TelemetryDomain

enum TelemetryPersistenceFixtures {
    static let baseDate = Date(timeIntervalSince1970: 1_810_000_000)

    static func configuration(seed: UInt8 = 1) -> ImmutableConfigurationSnapshot {
        ImmutableConfigurationSnapshot(
            id: ConfigurationSnapshotID(rawValue: uuid(seed)),
            formatVersion: 1,
            format: .canonicalJSON,
            canonicalPayload: Data("{\"seed\":\(seed)}".utf8),
            contentHash: ContentHash(
                algorithm: .sha256,
                lowercaseHexDigest: String(repeating: String(format: "%02x", seed), count: 32)
            )
        )
    }

    static func versions() -> RuntimeVersionContext {
        RuntimeVersionContext(
            telemetrySchema: TelemetrySchemaVersion(rawValue: "2.0"),
            algorithm: AlgorithmVersion(rawValue: "algorithm-v1"),
            safetyPolicy: SafetyPolicyVersion(rawValue: "safety-v1"),
            workoutProtocol: WorkoutProtocolVersion(rawValue: "workout-v1")
        )
    }

    static func session(
        seed: UInt8,
        profile: String = "profile-a",
        configuration: ImmutableConfigurationSnapshot? = nil,
        startedOffset: TimeInterval = 0
    ) -> WorkoutSessionRecord {
        WorkoutSessionRecord(
            recordID: RecordID(rawValue: uuid(seed &+ 40)),
            sessionID: SessionID(rawValue: uuid(seed)),
            profileLocalIdentifier: profile,
            lifecycleState: .completed,
            workoutMode: .heartRateControlled,
            startedAt: baseDate.addingTimeInterval(startedOffset),
            endedAt: baseDate.addingTimeInterval(startedOffset + 600),
            endedElapsed: ElapsedDuration(microseconds: 600_000_000),
            incompleteReason: nil,
            appContext: AppRuntimeContext(
                appVersion: "1.0",
                buildNumber: "100",
                operatingSystemVersion: "iOS 26.0"
            ),
            versions: versions(),
            configuration: configuration ?? self.configuration(seed: seed),
            healthKitWorkoutIdentifier: nil,
            treadmill: KnownTreadmillMetadata(model: "test-model", protocolName: "test-protocol"),
            recorderHealth: RecorderHealthSummary(
                isComplete: true,
                lostCriticalRecordCount: 0,
                lostNativeRecordCount: 0,
                lastPersistedElapsed: ElapsedDuration(microseconds: 600_000_000)
            )
        )
    }

    static func source(seed: UInt8, kind: SignalProviderKind = .healthKitSelected) -> SignalSourceIdentity {
        SignalSourceIdentity(
            id: SourceID(rawValue: uuid(seed &+ 10)),
            providerKind: kind,
            stableLocalKey: "source-\(seed)",
            savingSource: kind == .unknown ? nil : ProviderSavingSource(bundleIdentifier: "test.source.\(seed)"),
            knownDevice: nil
        )
    }

    static func timestamp(elapsedMicroseconds: Int64) -> ObservationTimestamp {
        ObservationTimestamp(
            measuredAt: baseDate.addingTimeInterval(Double(elapsedMicroseconds) / 1_000_000),
            receivedAt: baseDate.addingTimeInterval(Double(elapsedMicroseconds + 20_000) / 1_000_000),
            recordedAt: baseDate.addingTimeInterval(Double(elapsedMicroseconds + 30_000) / 1_000_000),
            measuredElapsed: ElapsedDuration(microseconds: elapsedMicroseconds),
            receivedElapsed: ElapsedDuration(microseconds: elapsedMicroseconds + 20_000),
            recordedElapsed: ElapsedDuration(microseconds: elapsedMicroseconds + 30_000)
        )
    }

    static func freshness(elapsedMicroseconds: Int64) -> EvidenceFreshness {
        EvidenceFreshness(
            state: .fresh,
            evaluatedAt: RecordTimestamp(
                recordedAt: baseDate.addingTimeInterval(Double(elapsedMicroseconds + 30_000) / 1_000_000),
                elapsed: ElapsedDuration(microseconds: elapsedMicroseconds + 30_000)
            ),
            age: ElapsedDuration(microseconds: 30_000),
            policyVersion: versions().safetyPolicy
        )
    }

    static func heartRate(
        seed: UInt8,
        session: WorkoutSessionRecord,
        source: SignalSourceIdentity,
        arrivalOrder: UInt64,
        bpm: UInt16,
        providerSampleIdentity: ProviderNativeSampleIdentity? = nil,
        timestamp: ObservationTimestamp? = nil
    ) -> HeartRateObservation {
        let elapsed = Int64(arrivalOrder) * 1_000_000
        return HeartRateObservation(
            recordID: RecordID(rawValue: uuid(seed &+ 80)),
            observationID: ObservationID(rawValue: uuid(seed &+ 60)),
            sessionID: session.sessionID,
            source: source,
            beatsPerMinute: bpm,
            arrivalOrder: arrivalOrder,
            providerSequence: Int64(arrivalOrder),
            providerSampleIdentity: providerSampleIdentity,
            timestamp: timestamp ?? self.timestamp(elapsedMicroseconds: elapsed),
            provenance: .reportedByProvider,
            freshness: freshness(elapsedMicroseconds: elapsed),
            quality: arrivalOrder == 1 ? [.measurementOutOfArrivalOrder] : [],
            controlUse: arrivalOrder == 1 ? .acceptedAndUsed : .acceptedNotUsed
        )
    }

    static func treadmill(
        seed: UInt8,
        session: WorkoutSessionRecord,
        source: SignalSourceIdentity,
        arrivalOrder: UInt64,
        unit: TreadmillNativeSpeedUnit
    ) -> TreadmillObservation {
        let elapsed = Int64(arrivalOrder) * 1_000_000
        return TreadmillObservation(
            recordID: RecordID(rawValue: uuid(seed &+ 100)),
            observationID: ObservationID(rawValue: uuid(seed &+ 90)),
            sessionID: session.sessionID,
            source: source,
            nativeSpeed: NativeTreadmillSpeed(value: 5.5, unit: unit),
            deviceState: .moving,
            arrivalOrder: arrivalOrder,
            timestamp: timestamp(elapsedMicroseconds: elapsed),
            provenance: .decodedDeviceReport,
            freshness: freshness(elapsedMicroseconds: elapsed),
            quality: []
        )
    }

    static func event(
        seed: UInt8,
        session: WorkoutSessionRecord,
        kind: WorkoutEventKind,
        elapsed: Int64,
        sourceID: SourceID? = nil
    ) -> WorkoutEvent {
        let payload: WorkoutEventPayload = switch kind {
        case .sessionLifecycle:
            .sessionLifecycle(SessionLifecycleEvent(previous: .created, current: .running))
        default:
            .manualStop(ManualStopEvent(reason: "test"))
        }
        return WorkoutEvent(
            recordID: RecordID(rawValue: uuid(seed &+ 120)),
            sessionID: session.sessionID,
            timestamp: EventTimestamp(
                occurredAt: baseDate.addingTimeInterval(Double(elapsed) / 1_000_000),
                recordedAt: baseDate.addingTimeInterval(Double(elapsed + 10_000) / 1_000_000),
                occurredElapsed: ElapsedDuration(microseconds: elapsed),
                recordedElapsed: ElapsedDuration(microseconds: elapsed + 10_000)
            ),
            sourceID: sourceID,
            payload: EventPayloadEnvelope(schemaVersion: 1, payload: payload)
        )
    }

    static func frame(
        seed: UInt8,
        session: WorkoutSessionRecord,
        elapsedSecond: Int64,
        heartRate: HeartRateObservation? = nil
    ) -> CanonicalFrame {
        let evidence = heartRate.map {
            HeartRateFrameEvidence(
                observationID: $0.observationID,
                recordID: $0.recordID,
                sourceID: $0.source.id,
                beatsPerMinute: $0.beatsPerMinute,
                measuredAt: $0.timestamp.measuredAt,
                receivedAt: $0.timestamp.receivedAt,
                evidenceElapsed: $0.timestamp.effectiveElapsed,
                ageAtMaterialization: ElapsedDuration(microseconds: 100_000),
                freshness: .fresh,
                provenance: $0.provenance
            )
        }
        return CanonicalFrame(
            frameID: FrameID(rawValue: uuid(seed &+ 130)),
            recordID: RecordID(rawValue: uuid(seed &+ 140)),
            sessionID: session.sessionID,
            canonicalElapsedSecond: elapsedSecond,
            materializedAt: RecordTimestamp(
                recordedAt: baseDate.addingTimeInterval(Double(elapsedSecond)),
                elapsed: ElapsedDuration(microseconds: elapsedSecond * 1_000_000)
            ),
            heartRateEvidence: evidence,
            treadmillEvidence: nil,
            precedingGap: elapsedSecond > 1
                ? CanonicalGapBoundary(missingSinceElapsedSecond: 1, kind: .recorderOutageOrLoss)
                : nil
        )
    }

    static func analysis(
        seed: UInt8,
        session: WorkoutSessionRecord,
        version: String
    ) -> WorkoutAnalysisResult {
        WorkoutAnalysisResult(
            analysisID: AnalysisID(rawValue: uuid(seed &+ 150)),
            recordID: RecordID(rawValue: uuid(seed &+ 160)),
            sessionID: session.sessionID,
            analyzerVersion: AnalyzerVersion(rawValue: version),
            evidenceHash: ContentHash(
                algorithm: .sha256,
                lowercaseHexDigest: String(repeating: String(format: "%02x", seed &+ 5), count: 32)
            ),
            generatedAt: baseDate.addingTimeInterval(Double(seed)),
            qualityGrade: .high,
            exclusions: [],
            keyMetrics: AnalysisKeyMetrics(
                coveredDuration: ElapsedDuration(microseconds: 500_000_000),
                averageHeartRate: 121.5,
                maximumHeartRate: 140,
                averageFactualSpeedKilometresPerHour: 5.5
            ),
            detailSchemaVersion: 1,
            versionedDetailPayload: Data(#"{"detail":true}"#.utf8)
        )
    }

    private static func uuid(_ byte: UInt8) -> UUID {
        UUID(uuid: (
            byte, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, byte
        ))
    }
}
