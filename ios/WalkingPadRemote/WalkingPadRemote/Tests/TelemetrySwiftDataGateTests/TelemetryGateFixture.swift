import Foundation
import TelemetryDomain
@testable import TelemetryPersistence

struct TelemetryGateProfile: Codable, Equatable, Sendable {
    let name: String
    let sessionCount: Int
    let secondsPerSession: Int
    let frameGapStartSecond: Int
    let frameGapLengthSeconds: Int
    let heartRateIntervalSeconds: Int
    let treadmillIntervalSeconds: Int
    let eventsPerSession: Int
    let batchSize: Int
    let queryRepetitions: Int

    static let fast = TelemetryGateProfile(
        name: "fast-ci",
        sessionCount: 4,
        secondsPerSession: 600,
        frameGapStartSecond: 240,
        frameGapLengthSeconds: 20,
        heartRateIntervalSeconds: 5,
        treadmillIntervalSeconds: 15,
        eventsPerSession: 20,
        batchSize: 128,
        queryRepetitions: 5
    )

    static let full = TelemetryGateProfile(
        name: "full-1000-hours",
        sessionCount: 1_000,
        secondsPerSession: 3_600,
        frameGapStartSecond: 1_200,
        frameGapLengthSeconds: 60,
        heartRateIntervalSeconds: 5,
        treadmillIntervalSeconds: 15,
        eventsPerSession: 20,
        batchSize: 128,
        queryRepetitions: 9
    )

    var representedWorkoutHours: Double {
        Double(sessionCount * secondsPerSession) / 3_600
    }

    var heartRatePerSession: Int {
        (secondsPerSession + heartRateIntervalSeconds - 1) / heartRateIntervalSeconds
    }

    var treadmillPerSession: Int {
        (secondsPerSession + treadmillIntervalSeconds - 1) / treadmillIntervalSeconds
    }

    var framesPerSession: Int {
        secondsPerSession - frameGapLengthSeconds
    }
}

struct TelemetryGateExpectedCounts: Codable, Equatable, Sendable {
    let configurations: Int
    let sessions: Int
    let sources: Int
    let heartRateSamples: Int
    let treadmillSamples: Int
    let events: Int
    let frames: Int
    let analyses: Int
    let expectedNativeRedeliveryRejections: Int
    let identityAbsentDuplicatePairs: Int

    var totalPersistedRecords: Int {
        configurations + sessions + sources + heartRateSamples + treadmillSamples
            + events + frames + analyses
    }

    var storeCounts: TelemetryStoreCounts {
        TelemetryStoreCounts(
            configurations: configurations,
            sessions: sessions,
            sources: sources,
            heartRateSamples: heartRateSamples,
            treadmillSamples: treadmillSamples,
            events: events,
            frames: frames,
            analyses: analyses
        )
    }
}

struct TelemetryGateCausalProbe: Sendable {
    let sessionID: SessionID
    let decisionID: DecisionID
    let commandID: CommandID
    let attemptID: CommandAttemptID
    let profileLocalIdentifier: String
    let workoutMode: WorkoutMode
}

struct TelemetryGateFixtureGenerator: Sendable {
    static let documentedSeed: UInt64 = 0x26_39_40_2026
    static let baseDate = Date(timeIntervalSince1970: 1_820_100_000)

    let profile: TelemetryGateProfile
    let seed: UInt64

    init(profile: TelemetryGateProfile, seed: UInt64 = documentedSeed) {
        self.profile = profile
        self.seed = seed
        precondition(profile.eventsPerSession == 20)
    }

    var configuration: ImmutableConfigurationSnapshot {
        ImmutableConfigurationSnapshot(
            id: ConfigurationSnapshotID(rawValue: uuid(kind: 1, counter: 1)),
            formatVersion: 1,
            format: .canonicalJSON,
            canonicalPayload: Data(#"{"fixture":"swiftdata-gate","version":1}"#.utf8),
            contentHash: ContentHash(
                algorithm: .sha256,
                lowercaseHexDigest: String(format: "%064llx", seed)
            )
        )
    }

    var versions: RuntimeVersionContext {
        RuntimeVersionContext(
            telemetrySchema: TelemetrySchemaVersion(rawValue: "v1"),
            algorithm: AlgorithmVersion(rawValue: "gate-algorithm-v1"),
            safetyPolicy: SafetyPolicyVersion(rawValue: "gate-safety-v1"),
            workoutProtocol: WorkoutProtocolVersion(rawValue: "gate-workout-v1")
        )
    }

    var heartRateSource: SignalSourceIdentity {
        SignalSourceIdentity(
            id: SourceID(rawValue: uuid(kind: 2, counter: 1)),
            providerKind: .healthKitSelected,
            stableLocalKey: "gate-health-provider",
            savingSource: ProviderSavingSource(
                bundleIdentifier: "gate.synthetic.health-provider",
                productType: "hosted-fixture",
                softwareVersion: "1"
            ),
            knownDevice: nil
        )
    }

    var treadmillSource: SignalSourceIdentity {
        SignalSourceIdentity(
            id: SourceID(rawValue: uuid(kind: 2, counter: 2)),
            providerKind: .treadmillProtocol,
            stableLocalKey: "gate-treadmill-protocol",
            savingSource: nil,
            knownDevice: nil
        )
    }

    var sources: [StoredSignalSource] {
        let lastSeen = Self.baseDate.addingTimeInterval(
            Double(profile.sessionCount * (profile.secondsPerSession + 60))
        )
        return [heartRateSource, treadmillSource].map {
            StoredSignalSource(identity: $0, firstSeen: Self.baseDate, lastSeen: lastSeen)
        }
    }

    var expectedCounts: TelemetryGateExpectedCounts {
        let redeliveriesPerSession = (profile.heartRatePerSession + 199) / 200
        let duplicatePairsPerSession = profile.heartRatePerSession > 22
            ? ((profile.heartRatePerSession - 23) / 40) + 1
            : 0
        return TelemetryGateExpectedCounts(
            configurations: 1,
            sessions: profile.sessionCount,
            sources: sources.count,
            heartRateSamples: profile.sessionCount * profile.heartRatePerSession,
            treadmillSamples: profile.sessionCount * profile.treadmillPerSession,
            events: profile.sessionCount * profile.eventsPerSession,
            frames: profile.sessionCount * profile.framesPerSession,
            analyses: profile.sessionCount,
            expectedNativeRedeliveryRejections: profile.sessionCount * redeliveriesPerSession,
            identityAbsentDuplicatePairs: profile.sessionCount * duplicatePairsPerSession
        )
    }

    func session(index: Int) -> WorkoutSessionRecord {
        let start = sessionStart(index: index)
        let isIncomplete = index % 20 == 19
        let elapsed = ElapsedDuration(microseconds: Int64(profile.secondsPerSession) * 1_000_000)
        return WorkoutSessionRecord(
            recordID: RecordID(rawValue: uuid(kind: 3, counter: UInt64(index))),
            sessionID: sessionID(index: index),
            profileLocalIdentifier: profileIdentifier(sessionIndex: index),
            lifecycleState: isIncomplete ? .incomplete : .completed,
            workoutMode: workoutMode(sessionIndex: index),
            startedAt: start,
            endedAt: isIncomplete ? nil : start.addingTimeInterval(Double(profile.secondsPerSession)),
            endedElapsed: isIncomplete ? nil : elapsed,
            incompleteReason: isIncomplete ? "synthetic-hosted-interruption" : nil,
            appContext: AppRuntimeContext(
                appVersion: "gate",
                buildNumber: "26",
                operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                deviceModel: "hosted-mac"
            ),
            versions: versions,
            configuration: configuration,
            healthKitWorkoutIdentifier: nil,
            treadmill: KnownTreadmillMetadata(
                stableLocalIdentifier: nil,
                model: nil,
                protocolName: "synthetic-v1",
                protocolVersion: "1"
            ),
            recorderHealth: RecorderHealthSummary(
                isComplete: !isIncomplete,
                lostCriticalRecordCount: 0,
                lostNativeRecordCount: 0,
                lastPersistedElapsed: elapsed
            )
        )
    }

    func heartRate(sessionIndex: Int, sampleIndex: Int, redelivery: Bool = false)
        -> HeartRateObservation
    {
        let sampleSecond = sampleIndex * profile.heartRateIntervalSeconds
        let elapsed = Int64(sampleSecond) * 1_000_000
        let measured = sessionStart(index: sessionIndex).addingTimeInterval(Double(sampleSecond))
        let stableIdentity = sampleIndex % 4 == 0
            ? ProviderNativeSampleIdentity(identifier: "hr-\(sessionIndex)-\(sampleIndex)")
            : nil
        let providerSequence = sampleIndex % 40 == 22
            ? Int64(sampleIndex - 1)
            : Int64(sampleIndex)
        let bpmIndex = sampleIndex % 40 == 22 ? sampleIndex - 1 : sampleIndex
        return HeartRateObservation(
            recordID: RecordID(
                rawValue: uuid(
                    kind: redelivery ? 31 : 4,
                    counter: recordCounter(sessionIndex: sessionIndex, localIndex: sampleIndex)
                )
            ),
            observationID: ObservationID(
                rawValue: uuid(
                    kind: redelivery ? 32 : 5,
                    counter: recordCounter(sessionIndex: sessionIndex, localIndex: sampleIndex)
                )
            ),
            sessionID: sessionID(index: sessionIndex),
            source: heartRateSource,
            beatsPerMinute: UInt16(105 + (bpmIndex / 2) % 55),
            arrivalOrder: UInt64(sampleIndex),
            providerSequence: providerSequence,
            providerSampleIdentity: stableIdentity,
            timestamp: observationTimestamp(measured: measured, elapsedMicroseconds: elapsed),
            provenance: .reportedByProvider,
            freshness: freshness(at: measured, elapsedMicroseconds: elapsed),
            quality: sampleIndex % 40 == 22 ? [.duplicateProviderSequence] : [],
            controlUse: sampleIndex % 12 == 0 ? .acceptedAndUsed : .acceptedNotUsed
        )
    }

    func treadmill(sessionIndex: Int, sampleIndex: Int) -> TreadmillObservation {
        let sampleSecond = sampleIndex * profile.treadmillIntervalSeconds
        let elapsed = Int64(sampleSecond) * 1_000_000
        let measured = sessionStart(index: sessionIndex).addingTimeInterval(Double(sampleSecond))
        return TreadmillObservation(
            recordID: RecordID(
                rawValue: uuid(
                    kind: 6,
                    counter: recordCounter(sessionIndex: sessionIndex, localIndex: sampleIndex)
                )
            ),
            observationID: ObservationID(
                rawValue: uuid(
                    kind: 7,
                    counter: recordCounter(sessionIndex: sessionIndex, localIndex: sampleIndex)
                )
            ),
            sessionID: sessionID(index: sessionIndex),
            source: treadmillSource,
            nativeSpeed: NativeTreadmillSpeed(
                value: 4.5 + Double(sampleIndex % 10) / 10,
                unit: .kilometresPerHour
            ),
            deviceState: .moving,
            arrivalOrder: UInt64(sampleIndex),
            timestamp: observationTimestamp(measured: measured, elapsedMicroseconds: elapsed),
            provenance: .decodedDeviceReport,
            freshness: freshness(at: measured, elapsedMicroseconds: elapsed),
            quality: []
        )
    }

    func frame(sessionIndex: Int, elapsedSecond: Int) -> CanonicalFrame? {
        let gapEnd = profile.frameGapStartSecond + profile.frameGapLengthSeconds
        guard elapsedSecond < profile.frameGapStartSecond || elapsedSecond >= gapEnd else {
            return nil
        }

        let heartRateIndex = elapsedSecond / profile.heartRateIntervalSeconds
        let treadmillIndex = elapsedSecond / profile.treadmillIntervalSeconds
        let heartRate = self.heartRate(sessionIndex: sessionIndex, sampleIndex: heartRateIndex)
        let treadmill = self.treadmill(sessionIndex: sessionIndex, sampleIndex: treadmillIndex)
        let materialized = sessionStart(index: sessionIndex).addingTimeInterval(Double(elapsedSecond))
        let elapsed = Int64(elapsedSecond) * 1_000_000
        let heartRateAge = Int64(elapsedSecond % profile.heartRateIntervalSeconds) * 1_000_000
        let treadmillAge = Int64(elapsedSecond % profile.treadmillIntervalSeconds) * 1_000_000
        return CanonicalFrame(
            frameID: FrameID(
                rawValue: uuid(
                    kind: 8,
                    counter: recordCounter(sessionIndex: sessionIndex, localIndex: elapsedSecond)
                )
            ),
            recordID: RecordID(
                rawValue: uuid(
                    kind: 9,
                    counter: recordCounter(sessionIndex: sessionIndex, localIndex: elapsedSecond)
                )
            ),
            sessionID: sessionID(index: sessionIndex),
            canonicalElapsedSecond: Int64(elapsedSecond),
            materializedAt: RecordTimestamp(
                recordedAt: materialized,
                elapsed: ElapsedDuration(microseconds: elapsed)
            ),
            heartRateEvidence: HeartRateFrameEvidence(
                observationID: heartRate.observationID,
                recordID: heartRate.recordID,
                sourceID: heartRate.source.id,
                beatsPerMinute: heartRate.beatsPerMinute,
                measuredAt: heartRate.timestamp.measuredAt,
                receivedAt: heartRate.timestamp.receivedAt,
                evidenceElapsed: heartRate.timestamp.effectiveElapsed,
                ageAtMaterialization: ElapsedDuration(microseconds: heartRateAge),
                freshness: .fresh,
                provenance: heartRate.provenance
            ),
            treadmillEvidence: TreadmillFrameEvidence(
                observationID: treadmill.observationID,
                recordID: treadmill.recordID,
                sourceID: treadmill.source.id,
                nativeSpeed: treadmill.nativeSpeed,
                factualSpeed: treadmill.factualSpeed,
                deviceState: treadmill.deviceState,
                measuredAt: treadmill.timestamp.measuredAt,
                receivedAt: treadmill.timestamp.receivedAt,
                evidenceElapsed: treadmill.timestamp.effectiveElapsed,
                ageAtMaterialization: ElapsedDuration(microseconds: treadmillAge),
                freshness: .fresh,
                provenance: treadmill.provenance
            ),
            precedingGap: elapsedSecond == gapEnd
                ? CanonicalGapBoundary(
                    missingSinceElapsedSecond: Int64(profile.frameGapStartSecond),
                    kind: .runtimeSuspensionOrStall
                )
                : nil
        )
    }

    func events(sessionIndex: Int) -> [WorkoutEvent] {
        let session = session(index: sessionIndex)
        let decision1 = decisionID(sessionIndex: sessionIndex, localIndex: 1)
        let decision2 = decisionID(sessionIndex: sessionIndex, localIndex: 2)
        let command1 = commandID(sessionIndex: sessionIndex, localIndex: 1)
        let command2 = commandID(sessionIndex: sessionIndex, localIndex: 2)
        let attempt1 = attemptID(sessionIndex: sessionIndex, localIndex: 1)
        let attempt2 = attemptID(sessionIndex: sessionIndex, localIndex: 2)
        let attempt3 = attemptID(sessionIndex: sessionIndex, localIndex: 3)
        let referenceHR = heartRate(sessionIndex: sessionIndex, sampleIndex: 0)
        let referenceTreadmill = treadmill(sessionIndex: sessionIndex, sampleIndex: 0)
        let control1 = ControlDecision(
            decisionID: decision1,
            observationsUsed: [
                .heartRate(referenceHR.observationID),
                .treadmill(referenceTreadmill.observationID),
            ],
            target: .heartRate(beatsPerMinute: 125),
            action: .enqueueSpeed(DesiredSpeedKilometresPerHour(value: 5.0)),
            reason: .belowTarget,
            versions: versions,
            configurationSnapshotID: configuration.id
        )
        let control2 = ControlDecision(
            decisionID: decision2,
            observationsUsed: [.heartRate(referenceHR.observationID)],
            target: .stop,
            action: .enqueueStop,
            reason: .safetyGate("synthetic-timeout"),
            versions: versions,
            configurationSnapshotID: configuration.id
        )
        let payloads: [WorkoutEventPayload] = [
            .sessionLifecycle(SessionLifecycleEvent(previous: .created, current: .running)),
            .workoutPhase(WorkoutPhaseTransition(previous: nil, current: .warmup)),
            .workoutPhase(WorkoutPhaseTransition(previous: .warmup, current: .main)),
            .sourceTransition(
                SourceTransition(
                    previousSourceID: nil,
                    currentSourceID: heartRateSource.id,
                    reason: "synthetic-provider-selected"
                )
            ),
            .connectionTransition(
                ConnectionTransition(previous: .connecting, current: .connected)
            ),
            .controlDecision(control1),
            .commandLifecycle(
                CommandLifecycleRecord(
                    commandID: command1,
                    decisionID: decision1,
                    lifecycle: .enqueued(
                        kind: .setSpeed(
                            CommandedSpeed(
                                nativeValue: 5.0,
                                nativeUnit: .kilometresPerHour
                            )
                        )
                    )
                )
            ),
            .commandLifecycle(
                CommandLifecycleRecord(
                    commandID: command1,
                    decisionID: decision1,
                    lifecycle: .sendAttempt(attemptID: attempt1, attemptNumber: 1)
                )
            ),
            .commandLifecycle(
                CommandLifecycleRecord(
                    commandID: command1,
                    decisionID: decision1,
                    lifecycle: .acknowledged(attemptID: attempt1)
                )
            ),
            .controlDecision(control2),
            .commandLifecycle(
                CommandLifecycleRecord(
                    commandID: command2,
                    decisionID: decision2,
                    lifecycle: .enqueued(kind: .stop)
                )
            ),
            .commandLifecycle(
                CommandLifecycleRecord(
                    commandID: command2,
                    decisionID: decision2,
                    lifecycle: .sendAttempt(attemptID: attempt2, attemptNumber: 1)
                )
            ),
            .commandLifecycle(
                CommandLifecycleRecord(
                    commandID: command2,
                    decisionID: decision2,
                    lifecycle: .timedOut(attemptID: attempt2)
                )
            ),
            .commandLifecycle(
                CommandLifecycleRecord(
                    commandID: command2,
                    decisionID: decision2,
                    lifecycle: .retryScheduled(
                        previousAttemptID: attempt2,
                        nextAttemptID: attempt3,
                        nextAttemptNumber: 2
                    )
                )
            ),
            .commandLifecycle(
                CommandLifecycleRecord(
                    commandID: command2,
                    decisionID: decision2,
                    lifecycle: .failed(
                        attemptID: attempt3,
                        reason: .transportUnavailable
                    )
                )
            ),
            .safety(
                SafetyEvent(
                    policy: versions.safetyPolicy,
                    gate: "synthetic-stale-hr",
                    outcome: .failedClosed,
                    evidence: [.heartRate(referenceHR.observationID)]
                )
            ),
            .cooldown(CooldownEvent(lifecycle: .started, targetHeartRate: 110)),
            .stopEvidence(
                StopEvidenceEvent(
                    conclusion: .unconfirmed(reason: "no-fresh-factual-stop-evidence"),
                    freshness: nil,
                    deviceState: nil,
                    factualSpeed: nil
                )
            ),
            .manualStop(ManualStopEvent(reason: "synthetic-user-request")),
            .recorderHealth(
                RecorderHealthEvent(kind: .drain, affectedRecordClass: "all", count: 0)
            ),
        ]
        precondition(payloads.count == profile.eventsPerSession)
        return payloads.enumerated().map { eventIndex, payload in
            let elapsedSecond = min(eventIndex * 30, profile.secondsPerSession - 1)
            let occurred = session.startedAt.addingTimeInterval(Double(elapsedSecond))
            return WorkoutEvent(
                recordID: RecordID(
                    rawValue: uuid(
                        kind: 10,
                        counter: recordCounter(
                            sessionIndex: sessionIndex,
                            localIndex: eventIndex
                        )
                    )
                ),
                sessionID: session.sessionID,
                timestamp: EventTimestamp(
                    occurredAt: occurred,
                    recordedAt: occurred.addingTimeInterval(0.01),
                    occurredElapsed: ElapsedDuration(
                        microseconds: Int64(elapsedSecond) * 1_000_000
                    ),
                    recordedElapsed: ElapsedDuration(
                        microseconds: Int64(elapsedSecond) * 1_000_000 + 10_000
                    )
                ),
                sourceID: payload.kind == .sourceTransition ? heartRateSource.id : nil,
                payload: EventPayloadEnvelope(schemaVersion: 1, payload: payload)
            )
        }
    }

    func analysis(sessionIndex: Int) -> WorkoutAnalysisResult {
        WorkoutAnalysisResult(
            analysisID: AnalysisID(rawValue: uuid(kind: 11, counter: UInt64(sessionIndex))),
            recordID: RecordID(rawValue: uuid(kind: 12, counter: UInt64(sessionIndex))),
            sessionID: sessionID(index: sessionIndex),
            analyzerVersion: AnalyzerVersion(rawValue: "gate-analyzer-v1"),
            evidenceHash: ContentHash(
                algorithm: .sha256,
                lowercaseHexDigest: String(format: "%064llx", UInt64(sessionIndex) ^ seed)
            ),
            generatedAt: sessionStart(index: sessionIndex).addingTimeInterval(
                Double(profile.secondsPerSession + 1)
            ),
            qualityGrade: sessionIndex % 20 == 19 ? .low : .high,
            exclusions: sessionIndex % 20 == 19
                ? [AnalysisExclusion(code: "incomplete-session")]
                : [],
            keyMetrics: AnalysisKeyMetrics(
                coveredDuration: ElapsedDuration(
                    microseconds: Int64(profile.secondsPerSession - profile.frameGapLengthSeconds)
                        * 1_000_000
                ),
                averageHeartRate: 126,
                maximumHeartRate: 159,
                averageFactualSpeedKilometresPerHour: 4.95
            ),
            detailSchemaVersion: 1,
            versionedDetailPayload: Data(#"{"method":"timestamp-aware-synthetic"}"#.utf8)
        )
    }

    func causalProbe(sessionIndex: Int) -> TelemetryGateCausalProbe {
        TelemetryGateCausalProbe(
            sessionID: sessionID(index: sessionIndex),
            decisionID: decisionID(sessionIndex: sessionIndex, localIndex: 1),
            commandID: commandID(sessionIndex: sessionIndex, localIndex: 1),
            attemptID: attemptID(sessionIndex: sessionIndex, localIndex: 1),
            profileLocalIdentifier: profileIdentifier(sessionIndex: sessionIndex),
            workoutMode: workoutMode(sessionIndex: sessionIndex)
        )
    }

    func isFrameGapSecond(_ second: Int) -> Bool {
        second >= profile.frameGapStartSecond
            && second < profile.frameGapStartSecond + profile.frameGapLengthSeconds
    }

    func redeliverySampleIndices() -> StrideTo<Int> {
        stride(from: 0, to: profile.heartRatePerSession, by: 200)
    }

    private func sessionID(index: Int) -> SessionID {
        SessionID(rawValue: uuid(kind: 13, counter: UInt64(index)))
    }

    private func decisionID(sessionIndex: Int, localIndex: Int) -> DecisionID {
        DecisionID(
            rawValue: uuid(
                kind: 14,
                counter: recordCounter(sessionIndex: sessionIndex, localIndex: localIndex)
            )
        )
    }

    private func commandID(sessionIndex: Int, localIndex: Int) -> CommandID {
        CommandID(
            rawValue: uuid(
                kind: 15,
                counter: recordCounter(sessionIndex: sessionIndex, localIndex: localIndex)
            )
        )
    }

    private func attemptID(sessionIndex: Int, localIndex: Int) -> CommandAttemptID {
        CommandAttemptID(
            rawValue: uuid(
                kind: 16,
                counter: recordCounter(sessionIndex: sessionIndex, localIndex: localIndex)
            )
        )
    }

    private func sessionStart(index: Int) -> Date {
        Self.baseDate.addingTimeInterval(
            Double(index * (profile.secondsPerSession + 60))
        )
    }

    private func profileIdentifier(sessionIndex: Int) -> String {
        "profile-\(sessionIndex % 4)"
    }

    private func workoutMode(sessionIndex: Int) -> WorkoutMode {
        sessionIndex % 3 == 0 ? .manual : .heartRateControlled
    }

    private func observationTimestamp(
        measured: Date,
        elapsedMicroseconds: Int64
    ) -> ObservationTimestamp {
        ObservationTimestamp(
            measuredAt: measured,
            receivedAt: measured.addingTimeInterval(0.02),
            recordedAt: measured.addingTimeInterval(0.03),
            measuredElapsed: ElapsedDuration(microseconds: elapsedMicroseconds),
            receivedElapsed: ElapsedDuration(microseconds: elapsedMicroseconds + 20_000),
            recordedElapsed: ElapsedDuration(microseconds: elapsedMicroseconds + 30_000)
        )
    }

    private func freshness(at measured: Date, elapsedMicroseconds: Int64) -> EvidenceFreshness {
        EvidenceFreshness(
            state: .fresh,
            evaluatedAt: RecordTimestamp(
                recordedAt: measured.addingTimeInterval(0.03),
                elapsed: ElapsedDuration(microseconds: elapsedMicroseconds + 30_000)
            ),
            age: ElapsedDuration(microseconds: 30_000),
            policyVersion: versions.safetyPolicy
        )
    }

    private func recordCounter(sessionIndex: Int, localIndex: Int) -> UInt64 {
        UInt64(sessionIndex) * 10_000_000 + UInt64(localIndex)
    }

    private func uuid(kind: UInt64, counter: UInt64) -> UUID {
        var high = seed ^ (kind &* 0x9e37_79b9_7f4a_7c15) ^ counter
        var low = high &+ 0x9e37_79b9_7f4a_7c15
        high = Self.mix(high)
        low = Self.mix(low)
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

struct TelemetryGateIdentityHasher {
    private(set) var value: UInt64 = 14_695_981_039_346_656_037

    mutating func update(_ text: String) {
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
    }

    var lowercaseHexDigest: String {
        String(format: "%016llx", value)
    }
}
