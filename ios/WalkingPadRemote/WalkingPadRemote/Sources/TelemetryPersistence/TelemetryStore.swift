import Foundation
import SwiftData
import TelemetryDomain

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
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
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
            try requireAbsent(TelemetryWorkoutSessionV1.self, key: sessionKey) { model, value in
                model.sessionID == value || model.recordID == recordKey
            }

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
            try requireAbsent(TelemetrySignalSourceV1.self, key: sourceKey) { model, value in
                model.sourceID == value || model.stableIdentityKey == stableIdentityKey
            }
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

        try explicitTransaction {
            try requireAbsent(TelemetryHeartRateSampleV1.self, key: observationKey) { model, value in
                model.observationID == value || model.recordID == recordKey
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
                    providerSampleIdentifier: observation.providerSampleIdentifier,
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
            try requireAbsent(TelemetryTreadmillSampleV1.self, key: observationKey) { model, value in
                model.observationID == value || model.recordID == recordKey
            }
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
            try requireAbsent(TelemetryWorkoutEventV1.self, key: recordKey) { model, value in
                model.recordID == value
            }
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
            try requireAbsent(TelemetryWorkoutFrameV1.self, key: identityKey) { model, value in
                model.canonicalIdentityKey == value || model.frameID == frameKey || model.recordID == recordKey
            }
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
            try requireAbsent(TelemetryWorkoutAnalysisV1.self, key: identityKey) { model, value in
                model.analysisIdentityKey == value || model.analysisID == analysisKey || model.recordID == recordKey
            }
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

    private func explicitTransaction(_ operation: () throws -> Void) throws {
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

    private func requireAbsent<Model: PersistentModel>(
        _ type: Model.Type,
        key: String,
        matches: (Model, String) -> Bool
    ) throws {
        let models = try modelContext.fetch(FetchDescriptor<Model>())
        guard !models.contains(where: { matches($0, key) }) else {
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
        return HeartRateObservation(
            recordID: try uuid(model.recordID, as: RecordIDTag.self),
            observationID: try uuid(model.observationID, as: ObservationIDTag.self),
            sessionID: try uuid(model.sessionID, as: SessionIDTag.self),
            source: try domainSource(source).identity,
            beatsPerMinute: bpm,
            arrivalOrder: arrivalOrder,
            providerSequence: model.providerSequence,
            providerSampleIdentifier: model.providerSampleIdentifier,
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
        let observation = TreadmillObservation(
            recordID: try uuid(model.recordID, as: RecordIDTag.self),
            observationID: try uuid(model.observationID, as: ObservationIDTag.self),
            sessionID: try uuid(model.sessionID, as: SessionIDTag.self),
            source: try domainSource(source).identity,
            nativeSpeed: NativeTreadmillSpeed(
                value: model.nativeValue,
                unit: try decode(TreadmillNativeSpeedUnit.self, from: model.nativeUnitPayload)
            ),
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
            quality: try decode(QualityFlags.self, from: model.qualityPayload),
            normalizationRule: normalizationRule ?? .nativeToKilometresPerHourV1
        )
        guard observation.factualSpeed?.value == model.factualKilometresPerHour,
              observation.factualSpeed?.normalizationRule == normalizationRule
        else {
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
        return WorkoutEvent(
            recordID: try uuid(model.recordID, as: RecordIDTag.self),
            sessionID: try uuid(model.sessionID, as: SessionIDTag.self),
            timestamp: EventTimestamp(
                occurredAt: model.occurredAt,
                recordedAt: model.recordedAt,
                occurredElapsed: ElapsedDuration(microseconds: model.occurredElapsedMicroseconds),
                recordedElapsed: ElapsedDuration(microseconds: model.recordedElapsedMicroseconds)
            ),
            sourceID: try model.sourceID.map { try uuid($0, as: SourceIDTag.self) },
            decisionID: try model.decisionID.map { try uuid($0, as: DecisionIDTag.self) },
            commandID: try model.commandID.map { try uuid($0, as: CommandIDTag.self) },
            attemptID: try model.attemptID.map { try uuid($0, as: CommandAttemptIDTag.self) },
            payload: EventPayloadEnvelope(
                schemaVersion: payloadVersion,
                payload: payload
            )
        )
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
