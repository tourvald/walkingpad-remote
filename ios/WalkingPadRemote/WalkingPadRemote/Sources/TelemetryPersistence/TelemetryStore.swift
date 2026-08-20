import Foundation
import SwiftData
import TelemetryDomain
import TelemetryRecorder

public enum TelemetryStoreConfiguration: Sendable, Equatable {
    case inMemory
    case onDisk(URL)
}

public enum TelemetryStoreError: Error, Equatable, Sendable {
    case missingSession(SessionID)
    case missingSource(SourceID)
    case duplicateStableIdentity(String)
    case conflictingStableIdentity(String)
    case invalidNumericValue(String)
    case corruptStoredRecord(String)
    case nonMonotonicRecorderSequence
    case conflictingAnalysis(String)
}

public struct StoredSignalSource: Codable, Hashable, Sendable {
    public let identity: SignalSourceIdentity
    public let firstSeen: Date
    public let lastSeen: Date

    public init(identity: SignalSourceIdentity, firstSeen: Date, lastSeen: Date) {
        self.identity = identity
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

public struct TelemetryStoreCounts: Codable, Hashable, Sendable {
    public let configurations: Int
    public let sessions: Int
    public let sources: Int
    public let heartRateSamples: Int
    public let treadmillSamples: Int
    public let events: Int
    public let frames: Int
    public let analyses: Int

    public init(
        configurations: Int,
        sessions: Int,
        sources: Int,
        heartRateSamples: Int,
        treadmillSamples: Int,
        events: Int,
        frames: Int,
        analyses: Int
    ) {
        self.configurations = configurations
        self.sessions = sessions
        self.sources = sources
        self.heartRateSamples = heartRateSamples
        self.treadmillSamples = treadmillSamples
        self.events = events
        self.frames = frames
        self.analyses = analyses
    }
}

enum TelemetryGateRecord: Sendable {
    case session(WorkoutSessionRecord)
    case source(StoredSignalSource)
    case heartRate(HeartRateObservation)
    case treadmill(TreadmillObservation)
    case event(WorkoutEvent)
    case frame(CanonicalFrame)
    case analysis(WorkoutAnalysisResult)
}

struct TelemetryGateTraversalCounts: Codable, Hashable, Sendable {
    let sessions: Int
    let heartRateSamples: Int
    let treadmillSamples: Int
    let events: Int
    let frames: Int
    let analyses: Int

    var total: Int {
        sessions + heartRateSamples + treadmillSamples + events + frames + analyses
    }
}

public enum TelemetryStoreFactory {
    public static func make(_ configuration: TelemetryStoreConfiguration) throws -> TelemetryStore {
        let schema = Schema(versionedSchema: TelemetrySchemaV1.self)
        let modelConfiguration: ModelConfiguration
        let onDiskStoreURL: URL?

        switch configuration {
        case .inMemory:
            onDiskStoreURL = nil
            modelConfiguration = ModelConfiguration(
                "TelemetryV2InMemory",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        case let .onDisk(url):
            onDiskStoreURL = url
            _ = try TelemetryStoreFilePolicy.prepareStoreDirectory(
                primaryStoreURL: url
            )
            modelConfiguration = ModelConfiguration(
                "TelemetryV2",
                schema: schema,
                url: url,
                cloudKitDatabase: .none
            )
        }

        let container = try ModelContainer(
            for: schema,
            migrationPlan: TelemetryMigrationPlan.self,
            configurations: [modelConfiguration]
        )
        if let onDiskStoreURL {
            _ = try TelemetryStoreFilePolicy.applyRequiredAttributes(
                primaryStoreURL: onDiskStoreURL
            )
        }
        return TelemetryStore(
            modelContainer: container,
            onDiskStoreURL: onDiskStoreURL
        )
    }
}

@ModelActor
public actor TelemetryStore {
    private var onDiskStoreURL: URL?
    private var explicitTransactionDepth = 0

    init(modelContainer: ModelContainer, onDiskStoreURL: URL?) {
        let modelContext = ModelContext(modelContainer)
        modelExecutor = DefaultSerialModelExecutor(modelContext: modelContext)
        self.modelContainer = modelContainer
        self.onDiskStoreURL = onDiskStoreURL
    }

    public func insertSession(_ record: WorkoutSessionRecord) throws {
        let sessionKey = record.sessionID.description
        let recordKey = record.recordID.description
        let configurationKey = record.configuration.id.description
        let modePayload = try Self.encode(record.workoutMode)
        let treadmillPayload = try record.treadmill.map(Self.encode)
        let lostCritical = try Self.int64(record.recorderHealth.lostCriticalRecordCount, field: "lostCriticalRecordCount")
        let lostNative = try Self.int64(record.recorderHealth.lostNativeRecordCount, field: "lostNativeRecordCount")

        try explicitTransaction {
            try rejectDuplicate(
                TelemetryWorkoutSessionV1.self,
                key: sessionKey,
                predicate: #Predicate { $0.sessionID == sessionKey }
            )
            try rejectDuplicate(
                TelemetryWorkoutSessionV1.self,
                key: recordKey,
                predicate: #Predicate { $0.recordID == recordKey }
            )

            let configuration = try configurationModel(
                snapshot: record.configuration,
                configurationKey: configurationKey
            )
            let model = TelemetryWorkoutSessionV1(
                sessionID: sessionKey,
                recordID: recordKey,
                profileLocalIdentifier: record.profileLocalIdentifier,
                lifecycleStateKey: record.lifecycleState.rawValue,
                workoutModePayload: modePayload,
                startedAt: record.startedAt,
                endedAt: record.endedAt,
                endedElapsedMicroseconds: record.endedElapsed?.microseconds,
                incompleteReason: record.incompleteReason,
                appVersion: record.appContext.appVersion,
                buildNumber: record.appContext.buildNumber,
                operatingSystemVersion: record.appContext.operatingSystemVersion,
                deviceModel: record.appContext.deviceModel,
                telemetrySchemaVersion: record.versions.telemetrySchema.rawValue,
                algorithmVersion: record.versions.algorithm.rawValue,
                safetyPolicyVersion: record.versions.safetyPolicy.rawValue,
                workoutProtocolVersion: record.versions.workoutProtocol.rawValue,
                healthKitWorkoutIdentifier: record.healthKitWorkoutIdentifier?.uuidString.lowercased(),
                treadmillMetadataPayload: treadmillPayload,
                recorderIsComplete: record.recorderHealth.isComplete,
                lostCriticalRecordCount: lostCritical,
                lostNativeRecordCount: lostNative,
                lastPersistedElapsedMicroseconds: record.recorderHealth.lastPersistedElapsed?.microseconds,
                configuration: configuration
            )
            modelContext.insert(model)
        }
    }

    public func insertSource(
        _ source: SignalSourceIdentity,
        firstSeen: Date,
        lastSeen: Date
    ) throws {
        let sourceKey = source.id.description
        let stableIdentityKey = try Self.sourceStableIdentityKey(source)
        let providerKindPayload = try Self.encode(source.providerKind)
        let savingSourcePayload = try source.savingSource.map(Self.encode)
        let knownDevicePayload = try source.knownDevice.map(Self.encode)

        try explicitTransaction {
            try rejectDuplicate(
                TelemetrySignalSourceV1.self,
                key: sourceKey,
                predicate: #Predicate { $0.sourceID == sourceKey }
            )
            try rejectDuplicate(
                TelemetrySignalSourceV1.self,
                key: stableIdentityKey,
                predicate: #Predicate { $0.stableIdentityKey == stableIdentityKey }
            )
            modelContext.insert(
                TelemetrySignalSourceV1(
                    sourceID: sourceKey,
                    stableIdentityKey: stableIdentityKey,
                    providerKindKey: Self.providerKindKey(source.providerKind),
                    providerKindPayload: providerKindPayload,
                    stableLocalKey: source.stableLocalKey,
                    savingSourcePayload: savingSourcePayload,
                    knownDevicePayload: knownDevicePayload,
                    firstSeen: firstSeen,
                    lastSeen: lastSeen
                )
            )
        }
    }

    public func insertHeartRate(_ observation: HeartRateObservation) throws {
        let observationKey = observation.observationID.description
        let recordKey = observation.recordID.description
        let session = try sessionModel(observation.sessionID)
        let source = try sourceModel(observation.source.id)
        let freshnessPayload = try Self.encode(observation.freshness)
        let qualityPayload = try Self.encode(observation.quality)
        let arrivalOrder = try Self.int64(observation.arrivalOrder, field: "arrivalOrder")
        let nativeSampleIdentityKey = try observation.providerSampleIdentity.map {
            try Self.heartRateNativeSampleIdentityKey(
                sourceStableIdentityKey: source.stableIdentityKey,
                providerSampleIdentity: $0
            )
        }

        try explicitTransaction {
            try rejectDuplicate(
                TelemetryHeartRateSampleV1.self,
                key: observationKey,
                predicate: #Predicate { $0.observationID == observationKey }
            )
            try rejectDuplicate(
                TelemetryHeartRateSampleV1.self,
                key: recordKey,
                predicate: #Predicate { $0.recordID == recordKey }
            )
            if let nativeSampleIdentityKey {
                try rejectDuplicate(
                    TelemetryHeartRateSampleV1.self,
                    key: nativeSampleIdentityKey,
                    predicate: #Predicate {
                        $0.nativeSampleIdentityKey == nativeSampleIdentityKey
                    }
                )
            }
            modelContext.insert(
                TelemetryHeartRateSampleV1(
                    observationID: observationKey,
                    recordID: recordKey,
                    sessionID: observation.sessionID.description,
                    sourceID: observation.source.id.description,
                    beatsPerMinute: Int(observation.beatsPerMinute),
                    arrivalOrder: arrivalOrder,
                    providerSequence: observation.providerSequence,
                    providerSampleIdentifier: observation.providerSampleIdentity?.identifier,
                    nativeSampleIdentityKey: nativeSampleIdentityKey,
                    measuredAt: observation.timestamp.measuredAt,
                    receivedAt: observation.timestamp.receivedAt,
                    recordedAt: observation.timestamp.recordedAt,
                    measuredElapsedMicroseconds: observation.timestamp.measuredElapsed?.microseconds,
                    receivedElapsedMicroseconds: observation.timestamp.receivedElapsed.microseconds,
                    recordedElapsedMicroseconds: observation.timestamp.recordedElapsed.microseconds,
                    provenanceKey: observation.provenance.rawValue,
                    freshnessPayload: freshnessPayload,
                    qualityPayload: qualityPayload,
                    controlUseKey: observation.controlUse.rawValue,
                    session: session,
                    source: source
                )
            )
        }
    }

    public func insertTreadmill(_ observation: TreadmillObservation) throws {
        let observationKey = observation.observationID.description
        let recordKey = observation.recordID.description
        let session = try sessionModel(observation.sessionID)
        let source = try sourceModel(observation.source.id)
        let nativeUnitPayload = try Self.encode(observation.nativeSpeed.unit)
        let freshnessPayload = try Self.encode(observation.freshness)
        let qualityPayload = try Self.encode(observation.quality)
        let arrivalOrder = try Self.int64(observation.arrivalOrder, field: "arrivalOrder")

        try explicitTransaction {
            try rejectDuplicate(
                TelemetryTreadmillSampleV1.self,
                key: observationKey,
                predicate: #Predicate { $0.observationID == observationKey }
            )
            try rejectDuplicate(
                TelemetryTreadmillSampleV1.self,
                key: recordKey,
                predicate: #Predicate { $0.recordID == recordKey }
            )
            modelContext.insert(
                TelemetryTreadmillSampleV1(
                    observationID: observationKey,
                    recordID: recordKey,
                    sessionID: observation.sessionID.description,
                    sourceID: observation.source.id.description,
                    nativeValue: observation.nativeSpeed.value,
                    nativeUnitKey: Self.nativeUnitKey(observation.nativeSpeed.unit),
                    nativeUnitPayload: nativeUnitPayload,
                    factualKilometresPerHour: observation.factualSpeed?.value,
                    factualSpeedNormalizationRuleKey: observation.factualSpeed?
                        .normalizationRule.rawValue,
                    deviceStateKey: observation.deviceState.rawValue,
                    arrivalOrder: arrivalOrder,
                    measuredAt: observation.timestamp.measuredAt,
                    receivedAt: observation.timestamp.receivedAt,
                    recordedAt: observation.timestamp.recordedAt,
                    measuredElapsedMicroseconds: observation.timestamp.measuredElapsed?.microseconds,
                    receivedElapsedMicroseconds: observation.timestamp.receivedElapsed.microseconds,
                    recordedElapsedMicroseconds: observation.timestamp.recordedElapsed.microseconds,
                    provenanceKey: observation.provenance.rawValue,
                    freshnessPayload: freshnessPayload,
                    qualityPayload: qualityPayload,
                    session: session,
                    source: source
                )
            )
        }
    }

    public func insertEvent(_ event: WorkoutEvent) throws {
        let recordKey = event.recordID.description
        let session = try sessionModel(event.sessionID)
        let source = try event.sourceID.map(sourceModel)
        let payload = try Self.encode(event.payload.payload)

        try explicitTransaction {
            try rejectDuplicate(
                TelemetryWorkoutEventV1.self,
                key: recordKey,
                predicate: #Predicate { $0.recordID == recordKey }
            )
            modelContext.insert(
                TelemetryWorkoutEventV1(
                    recordID: recordKey,
                    sessionID: event.sessionID.description,
                    kindKey: event.kind.rawValue,
                    occurredAt: event.timestamp.occurredAt,
                    recordedAt: event.timestamp.recordedAt,
                    occurredElapsedMicroseconds: event.timestamp.occurredElapsed.microseconds,
                    recordedElapsedMicroseconds: event.timestamp.recordedElapsed.microseconds,
                    sourceID: event.sourceID?.description,
                    decisionID: event.decisionID?.description,
                    commandID: event.commandID?.description,
                    attemptID: event.attemptID?.description,
                    payloadSchemaVersion: Int(event.payload.schemaVersion),
                    payload: payload,
                    session: session,
                    source: source
                )
            )
        }
    }

    public func insertFrame(_ frame: CanonicalFrame) throws {
        guard frame.canonicalElapsedSecond >= 0 else {
            throw TelemetryStoreError.invalidNumericValue("canonicalElapsedSecond")
        }
        let frameKey = frame.frameID.description
        let recordKey = frame.recordID.description
        let identityKey = Self.frameIdentityKey(
            sessionID: frame.sessionID,
            elapsedSecond: frame.canonicalElapsedSecond
        )
        let session = try sessionModel(frame.sessionID)
        let heartRatePayload = try frame.heartRateEvidence.map(Self.encode)
        let treadmillPayload = try frame.treadmillEvidence.map(Self.encode)
        let gapPayload = try frame.precedingGap.map(Self.encode)

        try explicitTransaction {
            try rejectDuplicate(
                TelemetryWorkoutFrameV1.self,
                key: identityKey,
                predicate: #Predicate { $0.canonicalIdentityKey == identityKey }
            )
            try rejectDuplicate(
                TelemetryWorkoutFrameV1.self,
                key: frameKey,
                predicate: #Predicate { $0.frameID == frameKey }
            )
            try rejectDuplicate(
                TelemetryWorkoutFrameV1.self,
                key: recordKey,
                predicate: #Predicate { $0.recordID == recordKey }
            )
            modelContext.insert(
                TelemetryWorkoutFrameV1(
                    frameID: frameKey,
                    recordID: recordKey,
                    canonicalIdentityKey: identityKey,
                    sessionID: frame.sessionID.description,
                    canonicalElapsedSecond: frame.canonicalElapsedSecond,
                    materializedAt: frame.materializedAt.recordedAt,
                    materializedElapsedMicroseconds: frame.materializedAt.elapsed.microseconds,
                    heartRateEvidencePayload: heartRatePayload,
                    treadmillEvidencePayload: treadmillPayload,
                    precedingGapPayload: gapPayload,
                    session: session
                )
            )
        }
    }

    public func insertAnalysis(_ analysis: WorkoutAnalysisResult) throws {
        let analysisKey = analysis.analysisID.description
        let recordKey = analysis.recordID.description
        let identityKey = try Self.analysisIdentityKey(analysis)
        let session = try sessionModel(analysis.sessionID)
        let exclusionsPayload = try Self.encode(analysis.exclusions)

        try explicitTransaction {
            try rejectDuplicate(
                TelemetryWorkoutAnalysisV1.self,
                key: identityKey,
                predicate: #Predicate { $0.analysisIdentityKey == identityKey }
            )
            try rejectDuplicate(
                TelemetryWorkoutAnalysisV1.self,
                key: analysisKey,
                predicate: #Predicate { $0.analysisID == analysisKey }
            )
            try rejectDuplicate(
                TelemetryWorkoutAnalysisV1.self,
                key: recordKey,
                predicate: #Predicate { $0.recordID == recordKey }
            )
            modelContext.insert(
                TelemetryWorkoutAnalysisV1(
                    analysisID: analysisKey,
                    recordID: recordKey,
                    analysisIdentityKey: identityKey,
                    sessionID: analysis.sessionID.description,
                    analyzerVersion: analysis.analyzerVersion.rawValue,
                    evidenceHashAlgorithm: analysis.evidenceHash.algorithm.rawValue,
                    evidenceHashDigest: analysis.evidenceHash.lowercaseHexDigest,
                    generatedAt: analysis.generatedAt,
                    qualityGradeKey: analysis.qualityGrade.rawValue,
                    exclusionsPayload: exclusionsPayload,
                    coveredDurationMicroseconds: analysis.keyMetrics.coveredDuration.microseconds,
                    averageHeartRate: analysis.keyMetrics.averageHeartRate,
                    maximumHeartRate: analysis.keyMetrics.maximumHeartRate.map(Int.init),
                    averageFactualSpeedKilometresPerHour: analysis.keyMetrics.averageFactualSpeedKilometresPerHour,
                    detailSchemaVersion: Int(analysis.detailSchemaVersion),
                    detailPayload: analysis.versionedDetailPayload,
                    session: session
                )
            )
        }
    }

    public func fetchSessions(profileLocalIdentifier: String? = nil) throws -> [WorkoutSessionRecord] {
        var descriptor = FetchDescriptor<TelemetryWorkoutSessionV1>(
            sortBy: [SortDescriptor(\TelemetryWorkoutSessionV1.startedAt)]
        )
        if let profileLocalIdentifier {
            descriptor.predicate = #Predicate { $0.profileLocalIdentifier == profileLocalIdentifier }
        }
        return try modelContext.fetch(descriptor).map(Self.domainSession)
    }

    public func fetchSources(providerKindKey: String? = nil) throws -> [StoredSignalSource] {
        var descriptor = FetchDescriptor<TelemetrySignalSourceV1>(
            sortBy: [SortDescriptor(\TelemetrySignalSourceV1.lastSeen)]
        )
        if let providerKindKey {
            descriptor.predicate = #Predicate { $0.providerKindKey == providerKindKey }
        }
        return try modelContext.fetch(descriptor).map(Self.domainSource)
    }

    public func fetchHeartRate(sessionID: SessionID) throws -> [HeartRateObservation] {
        let key = sessionID.description
        let descriptor = FetchDescriptor<TelemetryHeartRateSampleV1>(
            predicate: #Predicate { $0.sessionID == key },
            sortBy: [SortDescriptor(\TelemetryHeartRateSampleV1.arrivalOrder)]
        )
        return try modelContext.fetch(descriptor).map(Self.domainHeartRate)
    }

    public func fetchTreadmill(sessionID: SessionID) throws -> [TreadmillObservation] {
        let key = sessionID.description
        let descriptor = FetchDescriptor<TelemetryTreadmillSampleV1>(
            predicate: #Predicate { $0.sessionID == key },
            sortBy: [SortDescriptor(\TelemetryTreadmillSampleV1.arrivalOrder)]
        )
        return try modelContext.fetch(descriptor).map(Self.domainTreadmill)
    }

    public func fetchEvents(
        sessionID: SessionID,
        kind: WorkoutEventKind? = nil
    ) throws -> [WorkoutEvent] {
        let sessionKey = sessionID.description
        let descriptor: FetchDescriptor<TelemetryWorkoutEventV1>
        if let kind {
            let kindKey = kind.rawValue
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.sessionID == sessionKey && $0.kindKey == kindKey },
                sortBy: [SortDescriptor(\TelemetryWorkoutEventV1.occurredElapsedMicroseconds)]
            )
        } else {
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.sessionID == sessionKey },
                sortBy: [SortDescriptor(\TelemetryWorkoutEventV1.occurredElapsedMicroseconds)]
            )
        }
        return try modelContext.fetch(descriptor).map(Self.domainEvent)
    }

    public func fetchFrames(sessionID: SessionID) throws -> [CanonicalFrame] {
        let key = sessionID.description
        let descriptor = FetchDescriptor<TelemetryWorkoutFrameV1>(
            predicate: #Predicate { $0.sessionID == key },
            sortBy: [SortDescriptor(\TelemetryWorkoutFrameV1.canonicalElapsedSecond)]
        )
        return try modelContext.fetch(descriptor).map(Self.domainFrame)
    }

    public func fetchAnalyses(
        sessionID: SessionID,
        analyzerVersion: AnalyzerVersion? = nil
    ) throws -> [WorkoutAnalysisResult] {
        let sessionKey = sessionID.description
        let descriptor: FetchDescriptor<TelemetryWorkoutAnalysisV1>
        if let analyzerVersion {
            let versionKey = analyzerVersion.rawValue
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.sessionID == sessionKey && $0.analyzerVersion == versionKey },
                sortBy: [SortDescriptor(\TelemetryWorkoutAnalysisV1.generatedAt)]
            )
        } else {
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.sessionID == sessionKey },
                sortBy: [SortDescriptor(\TelemetryWorkoutAnalysisV1.generatedAt)]
            )
        }
        return try modelContext.fetch(descriptor).map(Self.domainAnalysis)
    }

    public func deleteSession(_ sessionID: SessionID) throws {
        let session = try sessionModel(sessionID)
        try explicitTransaction {
            modelContext.delete(session)
        }
    }

    public func counts() throws -> TelemetryStoreCounts {
        TelemetryStoreCounts(
            configurations: try modelContext.fetchCount(FetchDescriptor<TelemetryConfigurationSnapshotV1>()),
            sessions: try modelContext.fetchCount(FetchDescriptor<TelemetryWorkoutSessionV1>()),
            sources: try modelContext.fetchCount(FetchDescriptor<TelemetrySignalSourceV1>()),
            heartRateSamples: try modelContext.fetchCount(FetchDescriptor<TelemetryHeartRateSampleV1>()),
            treadmillSamples: try modelContext.fetchCount(FetchDescriptor<TelemetryTreadmillSampleV1>()),
            events: try modelContext.fetchCount(FetchDescriptor<TelemetryWorkoutEventV1>()),
            frames: try modelContext.fetchCount(FetchDescriptor<TelemetryWorkoutFrameV1>()),
            analyses: try modelContext.fetchCount(FetchDescriptor<TelemetryWorkoutAnalysisV1>())
        )
    }

    public func isAutosaveEnabled() -> Bool {
        modelContext.autosaveEnabled
    }

    public func insertRecorderBatch(_ records: [SequencedTelemetryRecord]) throws {
        guard !records.isEmpty else {
            return
        }
        var previousSequence: UInt64?
        for record in records {
            if let previousSequence,
               record.recorderSequence <= previousSequence
            {
                throw TelemetryStoreError.nonMonotonicRecorderSequence
            }
            previousSequence = record.recorderSequence
        }

        try explicitTransaction {
            for sequenced in records {
                switch sequenced.record {
                case let .source(source):
                    try reuseOrInsertRecorderSource(
                        source.identity,
                        firstSeen: source.firstSeen,
                        lastSeen: source.lastSeen
                    )
                case let .heartRate(observation):
                    try insertHeartRate(observation)
                case let .treadmill(observation):
                    try insertTreadmill(observation)
                case let .event(event):
                    try insertEvent(event)
                case let .frame(frame):
                    try insertFrame(frame)
                }
            }
        }
    }

    public func finalizeRecorderSession(_ finalization: TelemetrySessionFinalization) throws {
        let session = try sessionModel(finalization.sessionID)
        let lostCritical = try Self.int64(
            finalization.recorderHealth.lostCriticalRecordCount,
            field: "lostCriticalRecordCount"
        )
        let lostNative = try Self.int64(
            finalization.recorderHealth.lostNativeRecordCount,
            field: "lostNativeRecordCount"
        )
        try explicitTransaction {
            session.lifecycleStateKey = finalization.lifecycleState.rawValue
            session.endedAt = finalization.endedAt
            session.endedElapsedMicroseconds = finalization.endedElapsed?.microseconds
            session.incompleteReason = finalization.incompleteReason
            session.recorderIsComplete = finalization.recorderHealth.isComplete
            session.lostCriticalRecordCount = lostCritical
            session.lostNativeRecordCount = lostNative
            session.lastPersistedElapsedMicroseconds = finalization.recorderHealth
                .lastPersistedElapsed?.microseconds
        }
    }

    public func fetchUnfinishedRecorderSessions() throws -> [WorkoutSessionRecord] {
        let completed = SessionLifecycleState.completed.rawValue
        let cancelled = SessionLifecycleState.cancelled.rawValue
        let incomplete = SessionLifecycleState.incomplete.rawValue
        let descriptor = FetchDescriptor<TelemetryWorkoutSessionV1>(
            predicate: #Predicate {
                $0.lifecycleStateKey != completed
                    && $0.lifecycleStateKey != cancelled
                    && $0.lifecycleStateKey != incomplete
            },
            sortBy: [SortDescriptor(\TelemetryWorkoutSessionV1.startedAt)]
        )
        return try modelContext.fetch(descriptor).map(Self.domainSession)
    }

    /// Issue #26 testability seam. It exercises the existing insert validation and model
    /// mapping in one explicit transaction without defining a production recorder policy.
    func insertGateBatch(_ records: [TelemetryGateRecord]) throws {
        guard !records.isEmpty else {
            return
        }

        try explicitTransaction {
            for record in records {
                switch record {
                case let .session(session):
                    try insertSession(session)
                case let .source(source):
                    try insertSource(
                        source.identity,
                        firstSeen: source.firstSeen,
                        lastSeen: source.lastSeen
                    )
                case let .heartRate(observation):
                    try insertHeartRate(observation)
                case let .treadmill(observation):
                    try insertTreadmill(observation)
                case let .event(event):
                    try insertEvent(event)
                case let .frame(frame):
                    try insertFrame(frame)
                case let .analysis(analysis):
                    try insertAnalysis(analysis)
                }
            }
        }
    }

    /// Issue #26 crash-worker seam. The package-only worker stages a real model-context
    /// tail while autosave is disabled, then the supervisor interrupts the process.
    package func gateStageUncommittedHeartRate(_ observation: HeartRateObservation) throws {
        explicitTransactionDepth += 1
        defer { explicitTransactionDepth -= 1 }
        try insertHeartRate(observation)
    }

    func gateFetchRecentSessions(
        profileLocalIdentifier: String,
        limit: Int
    ) throws -> [WorkoutSessionRecord] {
        guard limit > 0 else {
            return []
        }
        var descriptor = FetchDescriptor<TelemetryWorkoutSessionV1>(
            predicate: #Predicate { $0.profileLocalIdentifier == profileLocalIdentifier },
            sortBy: [SortDescriptor(\TelemetryWorkoutSessionV1.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map(Self.domainSession)
    }

    func gateFetchComparableSessions(
        profileLocalIdentifier: String,
        workoutMode: WorkoutMode,
        limit: Int
    ) throws -> [WorkoutSessionRecord] {
        guard limit > 0 else {
            return []
        }
        let descriptor = FetchDescriptor<TelemetryWorkoutSessionV1>(
            predicate: #Predicate { $0.profileLocalIdentifier == profileLocalIdentifier },
            sortBy: [SortDescriptor(\TelemetryWorkoutSessionV1.startedAt, order: .reverse)]
        )
        var comparable: [WorkoutSessionRecord] = []
        for model in try modelContext.fetch(descriptor) {
            let session = try Self.domainSession(model)
            if session.workoutMode == workoutMode {
                comparable.append(session)
                if comparable.count == limit {
                    break
                }
            }
        }
        return comparable
    }

    func gateFetchEvents(decisionID: DecisionID) throws -> [WorkoutEvent] {
        let key = decisionID.description
        let descriptor = FetchDescriptor<TelemetryWorkoutEventV1>(
            predicate: #Predicate { $0.decisionID == key },
            sortBy: [SortDescriptor(\TelemetryWorkoutEventV1.occurredElapsedMicroseconds)]
        )
        return try modelContext.fetch(descriptor).map(Self.domainEvent)
    }

    func gateFetchEvents(commandID: CommandID) throws -> [WorkoutEvent] {
        let key = commandID.description
        let descriptor = FetchDescriptor<TelemetryWorkoutEventV1>(
            predicate: #Predicate { $0.commandID == key },
            sortBy: [SortDescriptor(\TelemetryWorkoutEventV1.occurredElapsedMicroseconds)]
        )
        return try modelContext.fetch(descriptor).map(Self.domainEvent)
    }

    func gateFetchEvents(attemptID: CommandAttemptID) throws -> [WorkoutEvent] {
        let key = attemptID.description
        let descriptor = FetchDescriptor<TelemetryWorkoutEventV1>(
            predicate: #Predicate { $0.attemptID == key },
            sortBy: [SortDescriptor(\TelemetryWorkoutEventV1.occurredElapsedMicroseconds)]
        )
        return try modelContext.fetch(descriptor).map(Self.domainEvent)
    }

    func gateTraverseSession(_ sessionID: SessionID) throws -> TelemetryGateTraversalCounts {
        let sessionKey = sessionID.description
        let sessionDescriptor = FetchDescriptor<TelemetryWorkoutSessionV1>(
            predicate: #Predicate { $0.sessionID == sessionKey }
        )
        let sessions = try modelContext.fetchCount(sessionDescriptor)
        let heartRateSamples = try fetchHeartRate(sessionID: sessionID).count
        let treadmillSamples = try fetchTreadmill(sessionID: sessionID).count
        let events = try fetchEvents(sessionID: sessionID).count
        let frames = try fetchFrames(sessionID: sessionID).count
        let analyses = try fetchAnalyses(sessionID: sessionID).count
        return TelemetryGateTraversalCounts(
            sessions: sessions,
            heartRateSamples: heartRateSamples,
            treadmillSamples: treadmillSamples,
            events: events,
            frames: frames,
            analyses: analyses
        )
    }

    func gateMarkInterruptedSessionIncomplete(
        _ sessionID: SessionID,
        reason: String
    ) throws {
        let session = try sessionModel(sessionID)
        try explicitTransaction {
            session.lifecycleStateKey = SessionLifecycleState.incomplete.rawValue
            session.incompleteReason = reason
            session.recorderIsComplete = false
            session.endedAt = nil
            session.endedElapsedMicroseconds = nil
        }
    }

    func gateRunsOnMainThread() -> Bool {
        Thread.isMainThread
    }

    private func explicitTransaction(_ operation: () throws -> Void) throws {
        if explicitTransactionDepth > 0 {
            try operation()
            return
        }

        explicitTransactionDepth += 1
        defer { explicitTransactionDepth -= 1 }
        modelContext.autosaveEnabled = false
        try modelContext.transaction(block: operation)
        if let onDiskStoreURL {
            _ = try TelemetryStoreFilePolicy.applyRequiredAttributes(
                primaryStoreURL: onDiskStoreURL
            )
        }
    }

    private func sessionModel(_ sessionID: SessionID) throws -> TelemetryWorkoutSessionV1 {
        let key = sessionID.description
        var descriptor = FetchDescriptor<TelemetryWorkoutSessionV1>(
            predicate: #Predicate { $0.sessionID == key }
        )
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else {
            throw TelemetryStoreError.missingSession(sessionID)
        }
        return model
    }

    private func sourceModel(_ sourceID: SourceID) throws -> TelemetrySignalSourceV1 {
        let key = sourceID.description
        var descriptor = FetchDescriptor<TelemetrySignalSourceV1>(
            predicate: #Predicate { $0.sourceID == key }
        )
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else {
            throw TelemetryStoreError.missingSource(sourceID)
        }
        return model
    }

    private func reuseOrInsertRecorderSource(
        _ source: SignalSourceIdentity,
        firstSeen: Date,
        lastSeen: Date
    ) throws {
        let sourceKey = source.id.description
        let stableIdentityKey = try Self.sourceStableIdentityKey(source)
        let providerKindPayload = try Self.encode(source.providerKind)
        let savingSourcePayload = try source.savingSource.map(Self.encode)
        let knownDevicePayload = try source.knownDevice.map(Self.encode)
        var idDescriptor = FetchDescriptor<TelemetrySignalSourceV1>(
            predicate: #Predicate { $0.sourceID == sourceKey }
        )
        idDescriptor.fetchLimit = 1
        var stableDescriptor = FetchDescriptor<TelemetrySignalSourceV1>(
            predicate: #Predicate { $0.stableIdentityKey == stableIdentityKey }
        )
        stableDescriptor.fetchLimit = 1
        let byID = try modelContext.fetch(idDescriptor).first
        let byStableIdentity = try modelContext.fetch(stableDescriptor).first

        guard byID != nil || byStableIdentity != nil else {
            try insertSource(source, firstSeen: firstSeen, lastSeen: lastSeen)
            return
        }
        guard let existing = byID,
              let stableExisting = byStableIdentity,
              existing.sourceID == stableExisting.sourceID,
              existing.providerKindKey == Self.providerKindKey(source.providerKind),
              existing.providerKindPayload == providerKindPayload,
              existing.stableLocalKey == source.stableLocalKey,
              existing.savingSourcePayload == savingSourcePayload,
              existing.knownDevicePayload == knownDevicePayload
        else {
            throw TelemetryStoreError.conflictingStableIdentity(stableIdentityKey)
        }
        existing.firstSeen = min(existing.firstSeen, firstSeen)
        existing.lastSeen = max(existing.lastSeen, lastSeen)
    }

    private func configurationModel(
        snapshot: ImmutableConfigurationSnapshot,
        configurationKey: String
    ) throws -> TelemetryConfigurationSnapshotV1 {
        var descriptor = FetchDescriptor<TelemetryConfigurationSnapshotV1>(
            predicate: #Predicate { $0.snapshotID == configurationKey }
        )
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            guard existing.formatVersion == Int(snapshot.formatVersion),
                  existing.formatKey == snapshot.format.rawValue,
                  existing.canonicalPayload == snapshot.canonicalPayload,
                  existing.hashAlgorithmKey == snapshot.contentHash.algorithm.rawValue,
                  existing.contentHashDigest == snapshot.contentHash.lowercaseHexDigest
            else {
                throw TelemetryStoreError.conflictingStableIdentity(configurationKey)
            }
            return existing
        }

        let created = TelemetryConfigurationSnapshotV1(
            snapshotID: configurationKey,
            formatVersion: Int(snapshot.formatVersion),
            formatKey: snapshot.format.rawValue,
            canonicalPayload: snapshot.canonicalPayload,
            hashAlgorithmKey: snapshot.contentHash.algorithm.rawValue,
            contentHashDigest: snapshot.contentHash.lowercaseHexDigest
        )
        modelContext.insert(created)
        return created
    }

    private func rejectDuplicate<Model: PersistentModel>(
        _: Model.Type,
        key: String,
        predicate: Predicate<Model>
    ) throws {
        var descriptor = FetchDescriptor<Model>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard try modelContext.fetch(descriptor).isEmpty else {
            throw TelemetryStoreError.duplicateStableIdentity(key)
        }
    }
}

private extension TelemetryStore {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder = JSONDecoder()

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }

    static func int64(_ value: UInt64, field: String) throws -> Int64 {
        guard let converted = Int64(exactly: value) else {
            throw TelemetryStoreError.invalidNumericValue(field)
        }
        return converted
    }

    static func providerKindKey(_ kind: SignalProviderKind) -> String {
        switch kind {
        case .unknown: "unknown"
        case .healthKitSelected: "healthKitSelected"
        case .watchMediated: "watchMediated"
        case .phoneLocal: "phoneLocal"
        case .bluetooth: "bluetooth"
        case .treadmillProtocol: "treadmillProtocol"
        case .other: "other"
        }
    }

    static func nativeUnitKey(_ unit: TreadmillNativeSpeedUnit) -> String {
        switch unit {
        case .kilometresPerHour: "kilometresPerHour"
        case .milesPerHour: "milesPerHour"
        case .controllerNative: "controllerNative"
        case .unknown: "unknown"
        }
    }

    static func sourceStableIdentityKey(_ source: SignalSourceIdentity) throws -> String {
        let providerIdentity = try encode(source.providerKind).base64EncodedString()
        return "\(providerIdentity)|\(source.stableLocalKey)"
    }

    static func heartRateNativeSampleIdentityKey(
        sourceStableIdentityKey: String,
        providerSampleIdentity: ProviderNativeSampleIdentity
    ) throws -> String {
        try encode([
            sourceStableIdentityKey,
            providerSampleIdentity.identifier,
        ]).base64EncodedString()
    }

    static func frameIdentityKey(sessionID: SessionID, elapsedSecond: Int64) -> String {
        "\(sessionID.description)|\(elapsedSecond)"
    }

    static func analysisIdentityKey(_ analysis: WorkoutAnalysisResult) throws -> String {
        try encode([
            analysis.sessionID.description,
            analysis.analyzerVersion.rawValue,
            analysis.evidenceHash.algorithm.rawValue,
            analysis.evidenceHash.lowercaseHexDigest,
        ]).base64EncodedString()
    }

    static func uuid<Tag>(_ string: String, as type: Tag.Type) throws -> TelemetryIdentifier<Tag> {
        guard let value = UUID(uuidString: string) else {
            throw TelemetryStoreError.corruptStoredRecord("invalid UUID: \(string)")
        }
        return TelemetryIdentifier<Tag>(rawValue: value)
    }

    static func domainSession(_ model: TelemetryWorkoutSessionV1) throws -> WorkoutSessionRecord {
        guard let configuration = model.configuration,
              let lifecycle = SessionLifecycleState(rawValue: model.lifecycleStateKey),
              let lostCritical = UInt64(exactly: model.lostCriticalRecordCount),
              let lostNative = UInt64(exactly: model.lostNativeRecordCount),
              let configurationFormatVersion = UInt16(exactly: configuration.formatVersion),
              let configurationFormat = ConfigurationPayloadFormat(rawValue: configuration.formatKey),
              let configurationHashAlgorithm = ContentHashAlgorithm(
                  rawValue: configuration.hashAlgorithmKey
              )
        else {
            throw TelemetryStoreError.corruptStoredRecord(model.sessionID)
        }
        let healthKitWorkoutIdentifier: UUID?
        if let storedIdentifier = model.healthKitWorkoutIdentifier {
            guard let identifier = UUID(uuidString: storedIdentifier) else {
                throw TelemetryStoreError.corruptStoredRecord(model.sessionID)
            }
            healthKitWorkoutIdentifier = identifier
        } else {
            healthKitWorkoutIdentifier = nil
        }
        let mode = try decode(WorkoutMode.self, from: model.workoutModePayload)
        let treadmill = try model.treadmillMetadataPayload.map { try decode(KnownTreadmillMetadata.self, from: $0) }
        let configurationSnapshot = ImmutableConfigurationSnapshot(
            id: try uuid(configuration.snapshotID, as: ConfigurationSnapshotIDTag.self),
            formatVersion: configurationFormatVersion,
            format: configurationFormat,
            canonicalPayload: configuration.canonicalPayload,
            contentHash: ContentHash(
                algorithm: configurationHashAlgorithm,
                lowercaseHexDigest: configuration.contentHashDigest
            )
        )
        return WorkoutSessionRecord(
            recordID: try uuid(model.recordID, as: RecordIDTag.self),
            sessionID: try uuid(model.sessionID, as: SessionIDTag.self),
            profileLocalIdentifier: model.profileLocalIdentifier,
            lifecycleState: lifecycle,
            workoutMode: mode,
            startedAt: model.startedAt,
            endedAt: model.endedAt,
            endedElapsed: model.endedElapsedMicroseconds.map(ElapsedDuration.init(microseconds:)),
            incompleteReason: model.incompleteReason,
            appContext: AppRuntimeContext(
                appVersion: model.appVersion,
                buildNumber: model.buildNumber,
                operatingSystemVersion: model.operatingSystemVersion,
                deviceModel: model.deviceModel
            ),
            versions: RuntimeVersionContext(
                telemetrySchema: TelemetrySchemaVersion(rawValue: model.telemetrySchemaVersion),
                algorithm: AlgorithmVersion(rawValue: model.algorithmVersion),
                safetyPolicy: SafetyPolicyVersion(rawValue: model.safetyPolicyVersion),
                workoutProtocol: WorkoutProtocolVersion(rawValue: model.workoutProtocolVersion)
            ),
            configuration: configurationSnapshot,
            healthKitWorkoutIdentifier: healthKitWorkoutIdentifier,
            treadmill: treadmill,
            recorderHealth: RecorderHealthSummary(
                isComplete: model.recorderIsComplete,
                lostCriticalRecordCount: lostCritical,
                lostNativeRecordCount: lostNative,
                lastPersistedElapsed: model.lastPersistedElapsedMicroseconds.map(ElapsedDuration.init(microseconds:))
            )
        )
    }

    static func domainSource(_ model: TelemetrySignalSourceV1) throws -> StoredSignalSource {
        let identity = SignalSourceIdentity(
            id: try uuid(model.sourceID, as: SourceIDTag.self),
            providerKind: try decode(SignalProviderKind.self, from: model.providerKindPayload),
            stableLocalKey: model.stableLocalKey,
            savingSource: try model.savingSourcePayload.map { try decode(ProviderSavingSource.self, from: $0) },
            knownDevice: try model.knownDevicePayload.map { try decode(KnownDeviceMetadata.self, from: $0) }
        )
        return StoredSignalSource(identity: identity, firstSeen: model.firstSeen, lastSeen: model.lastSeen)
    }

    static func domainHeartRate(_ model: TelemetryHeartRateSampleV1) throws -> HeartRateObservation {
        guard let bpm = UInt16(exactly: model.beatsPerMinute),
              let arrivalOrder = UInt64(exactly: model.arrivalOrder),
              let provenance = EvidenceProvenance(rawValue: model.provenanceKey),
              let controlUse = ControlUseState(rawValue: model.controlUseKey),
              let session = model.session,
              session.sessionID == model.sessionID,
              let source = model.source,
              source.sourceID == model.sourceID
        else {
            throw TelemetryStoreError.corruptStoredRecord(model.observationID)
        }
        let providerSampleIdentity: ProviderNativeSampleIdentity?
        if let identifier = model.providerSampleIdentifier {
            guard let identity = ProviderNativeSampleIdentity(identifier: identifier),
                  model.nativeSampleIdentityKey == (try heartRateNativeSampleIdentityKey(
                      sourceStableIdentityKey: source.stableIdentityKey,
                      providerSampleIdentity: identity
                  ))
            else {
                throw TelemetryStoreError.corruptStoredRecord(model.observationID)
            }
            providerSampleIdentity = identity
        } else {
            guard model.nativeSampleIdentityKey == nil else {
                throw TelemetryStoreError.corruptStoredRecord(model.observationID)
            }
            providerSampleIdentity = nil
        }
        return HeartRateObservation(
            recordID: try uuid(model.recordID, as: RecordIDTag.self),
            observationID: try uuid(model.observationID, as: ObservationIDTag.self),
            sessionID: try uuid(model.sessionID, as: SessionIDTag.self),
            source: try domainSource(source).identity,
            beatsPerMinute: bpm,
            arrivalOrder: arrivalOrder,
            providerSequence: model.providerSequence,
            providerSampleIdentity: providerSampleIdentity,
            timestamp: observationTimestamp(
                measuredAt: model.measuredAt,
                receivedAt: model.receivedAt,
                recordedAt: model.recordedAt,
                measuredElapsed: model.measuredElapsedMicroseconds,
                receivedElapsed: model.receivedElapsedMicroseconds,
                recordedElapsed: model.recordedElapsedMicroseconds
            ),
            provenance: provenance,
            freshness: try decode(EvidenceFreshness.self, from: model.freshnessPayload),
            quality: try decode(QualityFlags.self, from: model.qualityPayload),
            controlUse: controlUse
        )
    }

    static func domainTreadmill(_ model: TelemetryTreadmillSampleV1) throws -> TreadmillObservation {
        guard let arrivalOrder = UInt64(exactly: model.arrivalOrder),
              let provenance = EvidenceProvenance(rawValue: model.provenanceKey),
              let deviceState = TreadmillDeviceState(rawValue: model.deviceStateKey),
              let session = model.session,
              session.sessionID == model.sessionID,
              let source = model.source,
              source.sourceID == model.sourceID
        else {
            throw TelemetryStoreError.corruptStoredRecord(model.observationID)
        }
        let normalizationRule: FactualSpeedNormalizationRule?
        switch (model.factualKilometresPerHour, model.factualSpeedNormalizationRuleKey) {
        case (nil, nil):
            normalizationRule = nil
        case (.some, let ruleKey?):
            guard let rule = FactualSpeedNormalizationRule(rawValue: ruleKey) else {
                throw TelemetryStoreError.corruptStoredRecord(model.observationID)
            }
            normalizationRule = rule
        default:
            throw TelemetryStoreError.corruptStoredRecord(model.observationID)
        }
        guard let observation = TreadmillObservation(
            restoringRecordID: try uuid(model.recordID, as: RecordIDTag.self),
            observationID: try uuid(model.observationID, as: ObservationIDTag.self),
            sessionID: try uuid(model.sessionID, as: SessionIDTag.self),
            source: try domainSource(source).identity,
            nativeSpeed: NativeTreadmillSpeed(
                value: model.nativeValue,
                unit: try decode(TreadmillNativeSpeedUnit.self, from: model.nativeUnitPayload)
            ),
            factualKilometresPerHour: model.factualKilometresPerHour,
            factualNormalizationRule: normalizationRule,
            deviceState: deviceState,
            arrivalOrder: arrivalOrder,
            timestamp: observationTimestamp(
                measuredAt: model.measuredAt,
                receivedAt: model.receivedAt,
                recordedAt: model.recordedAt,
                measuredElapsed: model.measuredElapsedMicroseconds,
                receivedElapsed: model.receivedElapsedMicroseconds,
                recordedElapsed: model.recordedElapsedMicroseconds
            ),
            provenance: provenance,
            freshness: try decode(EvidenceFreshness.self, from: model.freshnessPayload),
            quality: try decode(QualityFlags.self, from: model.qualityPayload)
        ) else {
            throw TelemetryStoreError.corruptStoredRecord(model.observationID)
        }
        return observation
    }

    static func domainEvent(_ model: TelemetryWorkoutEventV1) throws -> WorkoutEvent {
        guard let kind = WorkoutEventKind(rawValue: model.kindKey),
              let payloadVersion = UInt16(exactly: model.payloadSchemaVersion),
              let session = model.session,
              session.sessionID == model.sessionID
        else {
            throw TelemetryStoreError.corruptStoredRecord(model.recordID)
        }
        if let sourceID = model.sourceID {
            guard let source = model.source, source.sourceID == sourceID else {
                throw TelemetryStoreError.corruptStoredRecord(model.recordID)
            }
        } else if model.source != nil {
            throw TelemetryStoreError.corruptStoredRecord(model.recordID)
        }
        let payload = try decode(WorkoutEventPayload.self, from: model.payload)
        guard payload.kind == kind else {
            throw TelemetryStoreError.corruptStoredRecord(model.recordID)
        }
        let event = WorkoutEvent(
            recordID: try uuid(model.recordID, as: RecordIDTag.self),
            sessionID: try uuid(model.sessionID, as: SessionIDTag.self),
            timestamp: EventTimestamp(
                occurredAt: model.occurredAt,
                recordedAt: model.recordedAt,
                occurredElapsed: ElapsedDuration(microseconds: model.occurredElapsedMicroseconds),
                recordedElapsed: ElapsedDuration(microseconds: model.recordedElapsedMicroseconds)
            ),
            sourceID: try model.sourceID.map { try uuid($0, as: SourceIDTag.self) },
            payload: EventPayloadEnvelope(
                schemaVersion: payloadVersion,
                payload: payload
            )
        )
        guard model.decisionID == event.decisionID?.description,
              model.commandID == event.commandID?.description,
              model.attemptID == event.attemptID?.description
        else {
            throw TelemetryStoreError.corruptStoredRecord(model.recordID)
        }
        return event
    }

    static func domainFrame(_ model: TelemetryWorkoutFrameV1) throws -> CanonicalFrame {
        guard let session = model.session, session.sessionID == model.sessionID else {
            throw TelemetryStoreError.corruptStoredRecord(model.recordID)
        }
        return CanonicalFrame(
            frameID: try uuid(model.frameID, as: FrameIDTag.self),
            recordID: try uuid(model.recordID, as: RecordIDTag.self),
            sessionID: try uuid(model.sessionID, as: SessionIDTag.self),
            canonicalElapsedSecond: model.canonicalElapsedSecond,
            materializedAt: RecordTimestamp(
                recordedAt: model.materializedAt,
                elapsed: ElapsedDuration(microseconds: model.materializedElapsedMicroseconds)
            ),
            heartRateEvidence: try model.heartRateEvidencePayload.map { try decode(HeartRateFrameEvidence.self, from: $0) },
            treadmillEvidence: try model.treadmillEvidencePayload.map { try decode(TreadmillFrameEvidence.self, from: $0) },
            precedingGap: try model.precedingGapPayload.map { try decode(CanonicalGapBoundary.self, from: $0) }
        )
    }

    static func domainAnalysis(_ model: TelemetryWorkoutAnalysisV1) throws -> WorkoutAnalysisResult {
        guard let hashAlgorithm = ContentHashAlgorithm(rawValue: model.evidenceHashAlgorithm),
              let qualityGrade = AnalysisQualityGrade(rawValue: model.qualityGradeKey),
              let detailSchemaVersion = UInt16(exactly: model.detailSchemaVersion),
              let session = model.session,
              session.sessionID == model.sessionID
        else {
            throw TelemetryStoreError.corruptStoredRecord(model.analysisID)
        }
        let maximumHeartRate: UInt16?
        if let storedMaximum = model.maximumHeartRate {
            guard let convertedMaximum = UInt16(exactly: storedMaximum) else {
                throw TelemetryStoreError.corruptStoredRecord(model.analysisID)
            }
            maximumHeartRate = convertedMaximum
        } else {
            maximumHeartRate = nil
        }
        return WorkoutAnalysisResult(
            analysisID: try uuid(model.analysisID, as: AnalysisIDTag.self),
            recordID: try uuid(model.recordID, as: RecordIDTag.self),
            sessionID: try uuid(model.sessionID, as: SessionIDTag.self),
            analyzerVersion: AnalyzerVersion(rawValue: model.analyzerVersion),
            evidenceHash: ContentHash(
                algorithm: hashAlgorithm,
                lowercaseHexDigest: model.evidenceHashDigest
            ),
            generatedAt: model.generatedAt,
            qualityGrade: qualityGrade,
            exclusions: try decode([AnalysisExclusion].self, from: model.exclusionsPayload),
            keyMetrics: AnalysisKeyMetrics(
                coveredDuration: ElapsedDuration(microseconds: model.coveredDurationMicroseconds),
                averageHeartRate: model.averageHeartRate,
                maximumHeartRate: maximumHeartRate,
                averageFactualSpeedKilometresPerHour: model.averageFactualSpeedKilometresPerHour
            ),
            detailSchemaVersion: detailSchemaVersion,
            versionedDetailPayload: model.detailPayload
        )
    }

    static func observationTimestamp(
        measuredAt: Date?,
        receivedAt: Date,
        recordedAt: Date,
        measuredElapsed: Int64?,
        receivedElapsed: Int64,
        recordedElapsed: Int64
    ) -> ObservationTimestamp {
        ObservationTimestamp(
            measuredAt: measuredAt,
            receivedAt: receivedAt,
            recordedAt: recordedAt,
            measuredElapsed: measuredElapsed.map(ElapsedDuration.init(microseconds:)),
            receivedElapsed: ElapsedDuration(microseconds: receivedElapsed),
            recordedElapsed: ElapsedDuration(microseconds: recordedElapsed)
        )
    }
}

extension TelemetryStore: TelemetryRecorderPersistence {
    public func beginSession(_ header: WorkoutSessionRecord) async throws {
        do {
            try insertSession(header)
        } catch {
            throw TelemetryPersistenceOperationError.commitOutcomeUnknown(
                code: "swiftdata-begin-session"
            )
        }
    }

    public func persistBatch(_ records: [SequencedTelemetryRecord]) async throws {
        do {
            try insertRecorderBatch(records)
        } catch {
            throw TelemetryPersistenceOperationError.commitOutcomeUnknown(
                code: "swiftdata-batch"
            )
        }
    }

    public func finalizeSession(_ finalization: TelemetrySessionFinalization) async throws {
        do {
            try finalizeRecorderSession(finalization)
        } catch {
            if recorderFinalizationMatchesStoredState(finalization) {
                return
            }
            throw TelemetryPersistenceOperationError.commitOutcomeUnknown(
                code: "swiftdata-finalize-session"
            )
        }
    }

    public func unfinishedSessions() async throws -> [WorkoutSessionRecord] {
        do {
            return try fetchUnfinishedRecorderSessions()
        } catch {
            throw TelemetryPersistenceOperationError.terminal(
                code: "swiftdata-unfinished-session-query"
            )
        }
    }

    private func recorderFinalizationMatchesStoredState(
        _ finalization: TelemetrySessionFinalization
    ) -> Bool {
        guard let stored = try? Self.domainSession(sessionModel(finalization.sessionID)) else {
            return false
        }
        return stored.lifecycleState == finalization.lifecycleState
            && stored.endedAt == finalization.endedAt
            && stored.endedElapsed == finalization.endedElapsed
            && stored.incompleteReason == finalization.incompleteReason
            && stored.recorderHealth == finalization.recorderHealth
    }
}
