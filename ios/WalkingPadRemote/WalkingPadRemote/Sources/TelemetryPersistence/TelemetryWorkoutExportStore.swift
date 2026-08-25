import Foundation
import SwiftData
import TelemetryDomain

private struct WorkoutExportEnvelope<Payload: Encodable>: Encodable {
    let schemaVersion: String
    let recordType: String
    let payload: Payload
}

private struct NativeSessionExportRecord: Encodable {
    let recordID: String
    let sessionID: String
    let lifecycleState: String
    let workoutMode: WorkoutMode
    let startedAt: Date
    let endedAt: Date?
    let endedElapsedMicroseconds: Int64?
    let incompleteReason: String?
    let appVersion: String
    let buildNumber: String
    let operatingSystemVersion: String
    let telemetrySchemaVersion: String
    let algorithmVersion: String
    let safetyPolicyVersion: String
    let workoutProtocolVersion: String
    let healthKitWorkoutIdentifier: String?
    let recorderIsComplete: Bool
    let lostCriticalRecordCount: Int64
    let lostNativeRecordCount: Int64
    let lastPersistedElapsedMicroseconds: Int64?
    let configuration: PrivacySafeConfigurationExportRecord
    let configurationHashAlgorithm: String?
    let configurationHashDigest: String?
}

struct PrivacySafeConfigurationExportRecord: Codable {
    let workoutMode: WorkoutMode?
    let targetHeartRate: Int?
    let durationMinutes: Int?
    let decisionIntervalSeconds: Int?
    let adaptiveStepEnabled: Bool?
    let maximumStepKilometresPerHour: Double?
    let heartRateZones: [Int]?
    let cooldownTargetHeartRate: Int?
    let cooldownMinimumSpeedKilometresPerHour: Double?
    let cooldownMaximumMinutes: Int?
    let heartRateProviderKind: String?
    let treadmill: PrivacySafeTreadmillConfigurationExportRecord?
}

struct PrivacySafeTreadmillConfigurationExportRecord: Codable {
    let protocolName: String?
    let protocolVersion: String?
    let minimumSpeedKilometresPerHour: Double?
    let maximumSpeedKilometresPerHour: Double?
    let speedIncrementKilometresPerHour: Double?
}

private struct HeartRateExportRecord: Encodable {
    let recordID: String
    let observationID: String
    let sessionID: String
    let sourceID: String
    let beatsPerMinute: UInt16
    let arrivalOrder: UInt64
    let providerSequence: Int64?
    let timestamp: ObservationTimestamp
    let provenance: EvidenceProvenance
    let freshness: EvidenceFreshness
    let quality: QualityFlags
    let controlUse: ControlUseState
}

private struct TreadmillExportRecord: Encodable {
    let recordID: String
    let observationID: String
    let sessionID: String
    let sourceID: String
    let nativeSpeed: NativeTreadmillSpeed
    let factualSpeed: FactualSpeedKilometresPerHour?
    let deviceState: TreadmillDeviceState
    let arrivalOrder: UInt64
    let timestamp: ObservationTimestamp
    let provenance: EvidenceProvenance
    let freshness: EvidenceFreshness
    let quality: QualityFlags
}

private struct ImportedWorkoutExportRecord: Encodable {
    let importedWorkoutID: String
    let startedAt: Date?
    let endedAt: Date?
    let identityStatus: String
    let possibleDuplicate: Bool
    let adaptationQualityEligible: Bool
    let candidateIDs: [String]
    let resolvedSummary: LegacyResolvedWorkoutSummary
}

private struct ImportedCandidateExportRecord: Encodable {
    let candidateID: String
    let sourceID: String
    let origin: String
    let workoutIdentifier: String?
    let healthKitWorkoutIdentifier: String?
    let stableLegacySessionIdentifier: String?
    let startedAt: Date?
    let endedAt: Date?
    let identityUncertain: Bool
    let possibleDuplicate: Bool
    let summary: LegacyWorkoutCandidateSummary
}

private struct ImportedEvidenceExportRecord: Encodable {
    let importedRecordID: String
    let sourceID: String
    let candidateID: String
    let sourceRecordIndex: Int64
    let eventKind: String
    let occurredAt: Date?
    let workoutIdentifier: String?
    let healthKitWorkoutIdentifier: String?
    let stableLegacySessionIdentifier: String?
    let provenance: String
    let payload: LegacyImportedRecordPayload
    let identityUncertain: Bool
    let adaptationQualityEligible: Bool
}

private final class WorkoutExportStream {
    let directoryURL: URL
    let rawURL: URL
    let normalizedURL: URL
    let summaryJSONLURL: URL
    let summaryCSVURL: URL
    let manifestURL: URL

    private let rawHandle: FileHandle
    private let normalizedHandle: FileHandle
    private let summaryJSONLHandle: FileHandle
    private let summaryCSVHandle: FileHandle
    private let encoder: JSONEncoder
    private var closed = false

    init(root: URL) throws {
        directoryURL = root
        rawURL = root.appendingPathComponent("raw_evidence_v1.jsonl")
        normalizedURL = root.appendingPathComponent("normalized_evidence_v1.csv")
        summaryJSONLURL = root.appendingPathComponent("session_summary_v2.jsonl")
        summaryCSVURL = root.appendingPathComponent("session_summary_v2.csv")
        manifestURL = root.appendingPathComponent("manifest.json")

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        for url in [rawURL, normalizedURL, summaryJSONLURL, summaryCSVURL] {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        rawHandle = try FileHandle(forWritingTo: rawURL)
        normalizedHandle = try FileHandle(forWritingTo: normalizedURL)
        summaryJSONLHandle = try FileHandle(forWritingTo: summaryJSONLURL)
        summaryCSVHandle = try FileHandle(forWritingTo: summaryCSVURL)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        try writeCSV(
            [
                "record_type", "session_id", "record_id", "occurred_at",
                "elapsed_us", "heart_rate_bpm", "native_speed_value",
                "native_speed_unit", "factual_speed_kmh", "event_kind",
                "lifecycle_state", "quality", "provenance",
            ],
            to: normalizedHandle
        )
        try writeCSV(
            [
                "summary_version", "id", "origin", "started_at", "ended_at",
                "duration_s", "target_bpm", "average_hr_bpm", "average_speed_kmh",
                "average_speed_evidence", "factual_speed_covered_s",
                "factual_speed_uncovered_s", "factual_speed_coverage_ratio",
                "factual_speed_required_ratio", "beats_per_metre", "zone_1_s", "zone_2_s",
                "zone_3_s", "zone_4_s", "zone_5_s", "healthkit_workout_uuid",
                "lifecycle_state", "recorder_complete", "analysis_grade",
                "identity_status", "possible_duplicate", "adaptation_eligible",
                "included_in_statistics", "provenance", "unavailable_metrics",
                "warnings",
            ],
            to: summaryCSVHandle
        )
    }

    deinit {
        close()
    }

    var fileURLs: [URL] {
        [rawURL, normalizedURL, summaryJSONLURL, summaryCSVURL, manifestURL]
    }

    func writeRaw<Payload: Encodable>(recordType: String, payload: Payload) throws {
        let envelope = WorkoutExportEnvelope(
            schemaVersion: "telemetry-v2-portable-raw-v1",
            recordType: recordType,
            payload: payload
        )
        try writeJSONLine(envelope, to: rawHandle)
    }

    func writeNormalized(_ fields: [String]) throws {
        try writeCSV(fields, to: normalizedHandle)
    }

    func writeSummary(_ projection: WorkoutHistoryProjection) throws {
        let envelope = WorkoutExportEnvelope(
            schemaVersion: WorkoutExportManifest.sessionSummaryVersion,
            recordType: "workout_summary",
            payload: projection
        )
        try writeJSONLine(envelope, to: summaryJSONLHandle)
        let zones = projection.zoneSeconds ?? []
        try writeCSV(
            [
                WorkoutExportManifest.sessionSummaryVersion,
                projection.id,
                projection.origin.rawValue,
                Self.dateString(projection.startedAt),
                Self.dateString(projection.endedAt),
                Self.numberString(projection.durationSeconds),
                projection.targetHeartRate.map(String.init) ?? "",
                Self.numberString(projection.averageHeartRate),
                Self.numberString(projection.averageSpeed?.kilometresPerHour),
                projection.averageSpeed?.evidenceKind.rawValue ?? "",
                Self.numberString(projection.factualSpeedCoverage?.coveredSeconds),
                Self.numberString(projection.factualSpeedCoverage?.uncoveredSeconds),
                Self.numberString(projection.factualSpeedCoverage?.coverageRatio),
                Self.numberString(projection.factualSpeedCoverage?.requiredRatio),
                Self.numberString(projection.beatsPerMetre),
                Self.numberString(zones[safe: 0] ?? nil),
                Self.numberString(zones[safe: 1] ?? nil),
                Self.numberString(zones[safe: 2] ?? nil),
                Self.numberString(zones[safe: 3] ?? nil),
                Self.numberString(zones[safe: 4] ?? nil),
                projection.healthKitWorkoutIdentifier?.uuidString.lowercased() ?? "",
                projection.quality.lifecycleState,
                projection.quality.recorderComplete.map(String.init) ?? "",
                projection.quality.analysisGrade ?? "",
                projection.quality.identityStatus ?? "",
                String(projection.quality.possibleDuplicate),
                String(projection.quality.adaptationEligible),
                String(projection.quality.includedInStatistics),
                projection.quality.provenance.joined(separator: ";"),
                projection.quality.unavailableMetrics.joined(separator: ";"),
                projection.quality.warnings.joined(separator: ";"),
            ],
            to: summaryCSVHandle
        )
    }

    func writeManifest(_ manifest: WorkoutExportManifest) throws {
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    func close() {
        guard !closed else { return }
        closed = true
        try? rawHandle.close()
        try? normalizedHandle.close()
        try? summaryJSONLHandle.close()
        try? summaryCSVHandle.close()
    }

    private func writeJSONLine<Value: Encodable>(
        _ value: Value,
        to handle: FileHandle
    ) throws {
        var data = try encoder.encode(value)
        data.append(0x0a)
        try handle.write(contentsOf: data)
    }

    private func writeCSV(_ fields: [String], to handle: FileHandle) throws {
        let line = fields.map(Self.csvEscape).joined(separator: ",") + "\n"
        try handle.write(contentsOf: Data(line.utf8))
    }

    private static func csvEscape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"")
                || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func dateString(_ date: Date?) -> String {
        date.map { ISO8601DateFormatter().string(from: $0) } ?? ""
    }

    private static func numberString(_ value: Double?) -> String {
        value.map { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), $0) }
            ?? ""
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private struct WorkoutExportManifestAccumulator {
    var telemetrySchemaVersions: Set<String> = []
    var appVersions: Set<String> = []
    var buildNumbers: Set<String> = []
    var algorithmVersions: Set<String> = []
    var analyzerVersions: Set<String> = []
    var lifecycleCounts: [String: Int] = [:]
    var analysisGradeCounts: [String: Int] = [:]
    var identityStatusCounts: [String: Int] = [:]
    var unavailableMetricWorkoutCount = 0
    var possibleDuplicateCount = 0
    var workoutCount = 0
    var recordCount = 0

    mutating func record(_ projection: WorkoutHistoryProjection) {
        workoutCount += 1
        telemetrySchemaVersions.insertIfPresent(projection.telemetrySchemaVersion)
        appVersions.insertIfPresent(projection.appVersion)
        buildNumbers.insertIfPresent(projection.buildNumber)
        algorithmVersions.insertIfPresent(projection.algorithmVersion)
        analyzerVersions.insertIfPresent(projection.analyzerVersion)
        lifecycleCounts[projection.quality.lifecycleState, default: 0] += 1
        if let grade = projection.quality.analysisGrade {
            analysisGradeCounts[grade, default: 0] += 1
        }
        if let identity = projection.quality.identityStatus {
            identityStatusCounts[identity, default: 0] += 1
        }
        if !projection.quality.unavailableMetrics.isEmpty {
            unavailableMetricWorkoutCount += 1
        }
        if projection.quality.possibleDuplicate {
            possibleDuplicateCount += 1
        }
    }
}

private extension Set where Element == String {
    mutating func insertIfPresent(_ value: String?) {
        if let value, !value.isEmpty { insert(value) }
    }
}

public extension TelemetryStore {
    func exportWorkouts(
        _ request: WorkoutExportRequest
    ) async throws -> WorkoutExportArtifact {
        let batchSize = min(256, max(1, request.batchSize))
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TelemetryV2Export_\(UUID().uuidString)", isDirectory: true)
        let stream: WorkoutExportStream
        do {
            stream = try WorkoutExportStream(root: directoryURL)
        } catch {
            try? FileManager.default.removeItem(at: directoryURL)
            throw TelemetryWorkoutReadError.exportFailed("create-export: \(error)")
        }

        do {
            var manifest = WorkoutExportManifestAccumulator()
            var cursor: WorkoutHistoryCursor?
            var completedSelectionCount = 0
            var shouldContinue = true

            while shouldContinue {
                try Task.checkCancellation()
                let page = try await fetchWorkoutHistoryPage(
                    filter: request.filter,
                    after: cursor,
                    limit: min(100, batchSize)
                )
                cursor = page.nextCursor

                for projection in page.items {
                    try Task.checkCancellation()
                    switch request.selection {
                    case .all:
                        break
                    case let .latestCompleted(limit):
                        guard limit > 0 else {
                            throw TelemetryWorkoutReadError.invalidPageSize
                        }
                        guard projection.quality.lifecycleState == SessionLifecycleState.completed.rawValue
                                || projection.quality.lifecycleState == "imported" else {
                            continue
                        }
                        guard completedSelectionCount < limit else {
                            shouldContinue = false
                            break
                        }
                        completedSelectionCount += 1
                    }

                    try stream.writeSummary(projection)
                    let evidenceCount: Int
                    switch projection.origin {
                    case .nativeV2:
                        evidenceCount = try exportNativeEvidence(
                            projection: projection,
                            batchSize: batchSize,
                            stream: stream
                        )
                    case .importedLegacy:
                        evidenceCount = try exportImportedEvidence(
                            projection: projection,
                            batchSize: batchSize,
                            stream: stream
                        )
                    }
                    manifest.record(projection)
                    manifest.recordCount += evidenceCount

                    if case let .latestCompleted(limit) = request.selection,
                       completedSelectionCount == limit {
                        shouldContinue = false
                        break
                    }
                }

                if cursor == nil { shouldContinue = false }
            }

            let files = stream.fileURLs.map(\.lastPathComponent)
            let containsHealthData = manifest.workoutCount > 0
            let outputManifest = WorkoutExportManifest(
                generatedAt: Date(),
                storageSchemaVersion: "1.1.0",
                telemetrySchemaVersions: Array(manifest.telemetrySchemaVersions),
                appVersions: Array(manifest.appVersions),
                buildNumbers: Array(manifest.buildNumbers),
                algorithmVersions: Array(manifest.algorithmVersions),
                analyzerVersions: Array(manifest.analyzerVersions),
                exportedWorkoutCount: manifest.workoutCount,
                exportedRecordCount: manifest.recordCount,
                batchSize: batchSize,
                containsHealthData: containsHealthData,
                healthDataNotice: "This export contains health and workout data. Share and store it carefully.",
                omittedIdentifierKinds: [
                    "installation-id",
                    "profile-id",
                    "profile-label",
                    "device-model",
                    "treadmill-stable-identifier",
                    "provider-stable-local-key",
                    "provider-native-sample-identifier",
                ],
                files: files,
                quality: WorkoutExportManifestQuality(
                    lifecycleCounts: manifest.lifecycleCounts,
                    analysisGradeCounts: manifest.analysisGradeCounts,
                    identityStatusCounts: manifest.identityStatusCounts,
                    workoutCountWithUnavailableMetrics: manifest.unavailableMetricWorkoutCount,
                    possibleDuplicateCount: manifest.possibleDuplicateCount
                )
            )
            stream.close()
            try stream.writeManifest(outputManifest)
            return WorkoutExportArtifact(
                directoryURL: directoryURL,
                fileURLs: stream.fileURLs,
                exportedWorkoutCount: manifest.workoutCount,
                exportedRecordCount: manifest.recordCount,
                containsHealthData: containsHealthData
            )
        } catch is CancellationError {
            stream.close()
            try? FileManager.default.removeItem(at: directoryURL)
            throw CancellationError()
        } catch {
            stream.close()
            try? FileManager.default.removeItem(at: directoryURL)
            if let readError = error as? TelemetryWorkoutReadError {
                throw readError
            }
            throw TelemetryWorkoutReadError.exportFailed(String(describing: error))
        }
    }

    func associateHealthKitWorkout(
        sessionID: SessionID,
        workoutIdentifier: UUID
    ) async throws {
        let sessionKey = sessionID.description
        var descriptor = FetchDescriptor<TelemetryWorkoutSessionV1>(
            predicate: #Predicate { $0.sessionID == sessionKey }
        )
        descriptor.fetchLimit = 1
        guard let session = try modelContext.fetch(descriptor).first else {
            throw TelemetryStoreError.missingSession(sessionID)
        }
        let value = workoutIdentifier.uuidString.lowercased()
        var conflictingDescriptor = FetchDescriptor<TelemetryWorkoutSessionV1>(
            predicate: #Predicate {
                $0.healthKitWorkoutIdentifier == value && $0.sessionID != sessionKey
            }
        )
        conflictingDescriptor.fetchLimit = 1
        guard try modelContext.fetch(conflictingDescriptor).isEmpty else {
            throw TelemetryStoreError.conflictingStableIdentity(
                "healthkit-workout:\(value)"
            )
        }
        if let existing = session.healthKitWorkoutIdentifier {
            guard existing == value else {
                throw TelemetryStoreError.conflictingStableIdentity(
                    "healthkit-workout:\(sessionID.description)"
                )
            }
            return
        }
        try explicitTransaction {
            session.healthKitWorkoutIdentifier = value
        }
    }
}

extension TelemetryStore: TelemetryWorkoutReadCapability {}
extension TelemetryStore: TelemetryHealthKitWorkoutLinkageCapability {}

private extension TelemetryStore {
    func exportNativeEvidence(
        projection: WorkoutHistoryProjection,
        batchSize: Int,
        stream: WorkoutExportStream
    ) throws -> Int {
        let sessionID = String(projection.id.dropFirst("native:".count))
        var sessionDescriptor = FetchDescriptor<TelemetryWorkoutSessionV1>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        sessionDescriptor.fetchLimit = 1
        guard let sessionModel = try modelContext.fetch(sessionDescriptor).first else {
            throw TelemetryWorkoutReadError.corruptProjection("missing native session \(sessionID)")
        }
        let session = try Self.domainSession(sessionModel)
        let privacySafeConfiguration = try Self.decode(
            PrivacySafeConfigurationExportRecord.self,
            from: session.configuration.canonicalPayload
        )
        try stream.writeRaw(
            recordType: "workout_session",
            payload: NativeSessionExportRecord(
                recordID: session.recordID.description,
                sessionID: session.sessionID.description,
                lifecycleState: session.lifecycleState.rawValue,
                workoutMode: session.workoutMode,
                startedAt: session.startedAt,
                endedAt: session.endedAt,
                endedElapsedMicroseconds: session.endedElapsed?.microseconds,
                incompleteReason: session.incompleteReason,
                appVersion: session.appContext.appVersion,
                buildNumber: session.appContext.buildNumber,
                operatingSystemVersion: session.appContext.operatingSystemVersion,
                telemetrySchemaVersion: session.versions.telemetrySchema.rawValue,
                algorithmVersion: session.versions.algorithm.rawValue,
                safetyPolicyVersion: session.versions.safetyPolicy.rawValue,
                workoutProtocolVersion: session.versions.workoutProtocol.rawValue,
                healthKitWorkoutIdentifier: session.healthKitWorkoutIdentifier?.uuidString.lowercased(),
                recorderIsComplete: session.recorderHealth.isComplete,
                lostCriticalRecordCount: sessionModel.lostCriticalRecordCount,
                lostNativeRecordCount: sessionModel.lostNativeRecordCount,
                lastPersistedElapsedMicroseconds: session.recorderHealth.lastPersistedElapsed?.microseconds,
                configuration: privacySafeConfiguration,
                configurationHashAlgorithm: session.configuration.contentHash.algorithm.rawValue,
                configurationHashDigest: session.configuration.contentHash.lowercaseHexDigest
            )
        )
        try stream.writeNormalized([
            "workout_session", sessionID, session.recordID.description,
            WorkoutExportStreamDate.string(session.startedAt), "", "", "", "", "", "",
            session.lifecycleState.rawValue,
            session.recorderHealth.isComplete ? "complete" : "incomplete",
            "telemetry-v2-native",
        ])
        var count = 1
        count += try exportHeartRate(sessionID: sessionID, batchSize: batchSize, stream: stream)
        count += try exportTreadmill(sessionID: sessionID, batchSize: batchSize, stream: stream)
        count += try exportEvents(sessionID: sessionID, batchSize: batchSize, stream: stream)
        count += try exportFrames(sessionID: sessionID, batchSize: batchSize, stream: stream)
        count += try exportAnalyses(sessionID: sessionID, batchSize: batchSize, stream: stream)
        return count
    }

    func exportHeartRate(
        sessionID: String,
        batchSize: Int,
        stream: WorkoutExportStream
    ) throws -> Int {
        var lastReceivedElapsed: Int64?
        var lastID = ""
        var count = 0
        while true {
            try Task.checkCancellation()
            var descriptor: FetchDescriptor<TelemetryHeartRateSampleV1>
            if let lastReceivedElapsed {
                descriptor = FetchDescriptor(
                    predicate: #Predicate {
                        $0.sessionID == sessionID
                            && ($0.receivedElapsedMicroseconds > lastReceivedElapsed
                                || ($0.receivedElapsedMicroseconds == lastReceivedElapsed
                                    && $0.observationID > lastID))
                    },
                    sortBy: [
                        SortDescriptor(\.receivedElapsedMicroseconds),
                        SortDescriptor(\.observationID),
                    ]
                )
            } else {
                descriptor = FetchDescriptor(
                    predicate: #Predicate { $0.sessionID == sessionID },
                    sortBy: [
                        SortDescriptor(\.receivedElapsedMicroseconds),
                        SortDescriptor(\.observationID),
                    ]
                )
            }
            descriptor.fetchLimit = batchSize
            let models = try modelContext.fetch(descriptor)
            guard !models.isEmpty else { break }
            for model in models {
                let observation = try Self.domainHeartRate(model)
                try stream.writeRaw(
                    recordType: "heart_rate_observation",
                    payload: HeartRateExportRecord(
                        recordID: observation.recordID.description,
                        observationID: observation.observationID.description,
                        sessionID: observation.sessionID.description,
                        sourceID: observation.source.id.description,
                        beatsPerMinute: observation.beatsPerMinute,
                        arrivalOrder: observation.arrivalOrder,
                        providerSequence: observation.providerSequence,
                        timestamp: observation.timestamp,
                        provenance: observation.provenance,
                        freshness: observation.freshness,
                        quality: observation.quality,
                        controlUse: observation.controlUse
                    )
                )
                try stream.writeNormalized([
                    "heart_rate_observation", sessionID, observation.recordID.description,
                    WorkoutExportStreamDate.string(observation.timestamp.recordedAt),
                    String(observation.timestamp.recordedElapsed.microseconds),
                    String(observation.beatsPerMinute), "", "", "", "", "",
                    observation.quality.values.map(\.rawValue).sorted().joined(separator: ";"),
                    observation.provenance.rawValue,
                ])
                count += 1
                lastReceivedElapsed = model.receivedElapsedMicroseconds
                lastID = model.observationID
            }
            if models.count < batchSize { break }
        }
        return count
    }

    func exportTreadmill(
        sessionID: String,
        batchSize: Int,
        stream: WorkoutExportStream
    ) throws -> Int {
        var lastReceivedElapsed: Int64?
        var lastID = ""
        var count = 0
        while true {
            try Task.checkCancellation()
            var descriptor: FetchDescriptor<TelemetryTreadmillSampleV1>
            if let lastReceivedElapsed {
                descriptor = FetchDescriptor(
                    predicate: #Predicate {
                        $0.sessionID == sessionID
                            && ($0.receivedElapsedMicroseconds > lastReceivedElapsed
                                || ($0.receivedElapsedMicroseconds == lastReceivedElapsed
                                    && $0.observationID > lastID))
                    },
                    sortBy: [
                        SortDescriptor(\.receivedElapsedMicroseconds),
                        SortDescriptor(\.observationID),
                    ]
                )
            } else {
                descriptor = FetchDescriptor(
                    predicate: #Predicate { $0.sessionID == sessionID },
                    sortBy: [
                        SortDescriptor(\.receivedElapsedMicroseconds),
                        SortDescriptor(\.observationID),
                    ]
                )
            }
            descriptor.fetchLimit = batchSize
            let models = try modelContext.fetch(descriptor)
            guard !models.isEmpty else { break }
            for model in models {
                let observation = try Self.domainTreadmill(model)
                try stream.writeRaw(
                    recordType: "treadmill_observation",
                    payload: TreadmillExportRecord(
                        recordID: observation.recordID.description,
                        observationID: observation.observationID.description,
                        sessionID: observation.sessionID.description,
                        sourceID: observation.source.id.description,
                        nativeSpeed: observation.nativeSpeed,
                        factualSpeed: observation.factualSpeed,
                        deviceState: observation.deviceState,
                        arrivalOrder: observation.arrivalOrder,
                        timestamp: observation.timestamp,
                        provenance: observation.provenance,
                        freshness: observation.freshness,
                        quality: observation.quality
                    )
                )
                try stream.writeNormalized([
                    "treadmill_observation", sessionID, observation.recordID.description,
                    WorkoutExportStreamDate.string(observation.timestamp.recordedAt),
                    String(observation.timestamp.recordedElapsed.microseconds), "",
                    String(observation.nativeSpeed.value),
                    treadmillUnitString(observation.nativeSpeed.unit),
                    observation.factualSpeed.map { String($0.value) } ?? "", "", "",
                    observation.quality.values.map(\.rawValue).sorted().joined(separator: ";"),
                    observation.provenance.rawValue,
                ])
                count += 1
                lastReceivedElapsed = model.receivedElapsedMicroseconds
                lastID = model.observationID
            }
            if models.count < batchSize { break }
        }
        return count
    }

    func exportEvents(
        sessionID: String,
        batchSize: Int,
        stream: WorkoutExportStream
    ) throws -> Int {
        var lastElapsed: Int64?
        var lastID = ""
        var count = 0
        while true {
            try Task.checkCancellation()
            var descriptor: FetchDescriptor<TelemetryWorkoutEventV1>
            if let lastElapsed {
                descriptor = FetchDescriptor(
                    predicate: #Predicate {
                        $0.sessionID == sessionID
                            && ($0.occurredElapsedMicroseconds > lastElapsed
                                || ($0.occurredElapsedMicroseconds == lastElapsed
                                    && $0.recordID > lastID))
                    },
                    sortBy: [
                        SortDescriptor(\.occurredElapsedMicroseconds),
                        SortDescriptor(\.recordID),
                    ]
                )
            } else {
                descriptor = FetchDescriptor(
                    predicate: #Predicate { $0.sessionID == sessionID },
                    sortBy: [
                        SortDescriptor(\.occurredElapsedMicroseconds),
                        SortDescriptor(\.recordID),
                    ]
                )
            }
            descriptor.fetchLimit = batchSize
            let models = try modelContext.fetch(descriptor)
            guard !models.isEmpty else { break }
            for model in models {
                let event = try Self.domainEvent(model)
                try stream.writeRaw(recordType: "workout_event", payload: event)
                try stream.writeNormalized([
                    "workout_event", sessionID, event.recordID.description,
                    WorkoutExportStreamDate.string(event.timestamp.occurredAt),
                    String(event.timestamp.occurredElapsed.microseconds), "", "", "", "",
                    event.kind.rawValue, "", "", "typed-v2-event",
                ])
                count += 1
                lastElapsed = model.occurredElapsedMicroseconds
                lastID = model.recordID
            }
            if models.count < batchSize { break }
        }
        return count
    }

    func exportFrames(
        sessionID: String,
        batchSize: Int,
        stream: WorkoutExportStream
    ) throws -> Int {
        var lastSecond: Int64?
        var lastID = ""
        var count = 0
        while true {
            try Task.checkCancellation()
            var descriptor: FetchDescriptor<TelemetryWorkoutFrameV1>
            if let lastSecond {
                descriptor = FetchDescriptor(
                    predicate: #Predicate {
                        $0.sessionID == sessionID
                            && ($0.canonicalElapsedSecond > lastSecond
                                || ($0.canonicalElapsedSecond == lastSecond && $0.frameID > lastID))
                    },
                    sortBy: [
                        SortDescriptor(\.canonicalElapsedSecond),
                        SortDescriptor(\.frameID),
                    ]
                )
            } else {
                descriptor = FetchDescriptor(
                    predicate: #Predicate { $0.sessionID == sessionID },
                    sortBy: [
                        SortDescriptor(\.canonicalElapsedSecond),
                        SortDescriptor(\.frameID),
                    ]
                )
            }
            descriptor.fetchLimit = batchSize
            let models = try modelContext.fetch(descriptor)
            guard !models.isEmpty else { break }
            for model in models {
                let frame = try Self.domainFrame(model)
                try stream.writeRaw(recordType: "canonical_frame", payload: frame)
                try stream.writeNormalized([
                    "canonical_frame", sessionID, frame.recordID.description,
                    WorkoutExportStreamDate.string(frame.materializedAt.recordedAt),
                    String(frame.materializedAt.elapsed.microseconds),
                    frame.heartRateEvidence.map { String($0.beatsPerMinute) } ?? "",
                    frame.treadmillEvidence.map { String($0.nativeSpeed.value) } ?? "",
                    frame.treadmillEvidence.map {
                        treadmillUnitString($0.nativeSpeed.unit)
                    } ?? "",
                    frame.treadmillEvidence?.factualSpeed.map { String($0.value) } ?? "",
                    "", "", "", "canonical-frame-projection",
                ])
                count += 1
                lastSecond = model.canonicalElapsedSecond
                lastID = model.frameID
            }
            if models.count < batchSize { break }
        }
        return count
    }

    func exportAnalyses(
        sessionID: String,
        batchSize: Int,
        stream: WorkoutExportStream
    ) throws -> Int {
        var lastGeneratedAt: Date?
        var lastID = ""
        var count = 0
        while true {
            try Task.checkCancellation()
            var descriptor: FetchDescriptor<TelemetryWorkoutAnalysisV1>
            if let lastGeneratedAt {
                descriptor = FetchDescriptor(
                    predicate: #Predicate {
                        $0.sessionID == sessionID
                            && ($0.generatedAt > lastGeneratedAt
                                || ($0.generatedAt == lastGeneratedAt && $0.analysisID > lastID))
                    },
                    sortBy: [SortDescriptor(\.generatedAt), SortDescriptor(\.analysisID)]
                )
            } else {
                descriptor = FetchDescriptor(
                    predicate: #Predicate { $0.sessionID == sessionID },
                    sortBy: [SortDescriptor(\.generatedAt), SortDescriptor(\.analysisID)]
                )
            }
            descriptor.fetchLimit = batchSize
            let models = try modelContext.fetch(descriptor)
            guard !models.isEmpty else { break }
            for model in models {
                let analysis = try Self.domainAnalysis(model)
                try stream.writeRaw(recordType: "workout_analysis", payload: analysis)
                try stream.writeNormalized([
                    "workout_analysis", sessionID, analysis.recordID.description,
                    WorkoutExportStreamDate.string(analysis.generatedAt), "", "", "", "",
                    analysis.keyMetrics.averageFactualSpeedKilometresPerHour.map { String($0) } ?? "",
                    "", "", analysis.qualityGrade.rawValue, "derived-analysis",
                ])
                count += 1
                lastGeneratedAt = model.generatedAt
                lastID = model.analysisID
            }
            if models.count < batchSize { break }
        }
        return count
    }

    func exportImportedEvidence(
        projection: WorkoutHistoryProjection,
        batchSize: Int,
        stream: WorkoutExportStream
    ) throws -> Int {
        let workoutID = String(projection.id.dropFirst("imported:".count))
        var descriptor = FetchDescriptor<TelemetryLegacyImportedWorkoutV2>(
            predicate: #Predicate { $0.importedWorkoutID == workoutID }
        )
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else {
            throw TelemetryWorkoutReadError.corruptProjection("missing imported workout \(workoutID)")
        }
        let candidates = try exportImportedCandidateModels(model)
        let resolvedSummary = try Self.decode(
            LegacyResolvedWorkoutSummary.self,
            from: model.resolvedSummaryPayload
        )
        try stream.writeRaw(
            recordType: "imported_workout",
            payload: ImportedWorkoutExportRecord(
                importedWorkoutID: model.importedWorkoutID,
                startedAt: model.startedAt,
                endedAt: model.endedAt,
                identityStatus: model.identityStatusKey,
                possibleDuplicate: model.possibleDuplicate,
                adaptationQualityEligible: model.adaptationQualityEligible,
                candidateIDs: try exportModelCandidateIDs(model),
                resolvedSummary: resolvedSummary
            )
        )
        try stream.writeNormalized([
            "imported_workout", workoutID, workoutID,
            WorkoutExportStreamDate.string(model.startedAt), "", "", "", "", "", "",
            projection.quality.lifecycleState, model.identityStatusKey,
            "telemetry-v2-imported-legacy",
        ])
        var count = 1
        for candidate in candidates {
            try Task.checkCancellation()
            let summary = try Self.decode(
                LegacyWorkoutCandidateSummary.self,
                from: candidate.summaryPayload
            )
            try stream.writeRaw(
                recordType: "imported_workout_candidate",
                payload: ImportedCandidateExportRecord(
                    candidateID: candidate.candidateID,
                    sourceID: candidate.sourceID,
                    origin: candidate.originKindKey,
                    workoutIdentifier: candidate.workoutIdentifier,
                    healthKitWorkoutIdentifier: candidate.healthKitWorkoutIdentifier,
                    stableLegacySessionIdentifier: candidate.stableLegacySessionIdentifier,
                    startedAt: candidate.startedAt,
                    endedAt: candidate.endedAt,
                    identityUncertain: candidate.identityUncertain,
                    possibleDuplicate: candidate.possibleDuplicate,
                    summary: summary
                )
            )
            count += 1
            count += try exportImportedRecords(
                candidateID: candidate.candidateID,
                batchSize: batchSize,
                stream: stream
            )
        }
        return count
    }

    func exportImportedRecords(
        candidateID: String,
        batchSize: Int,
        stream: WorkoutExportStream
    ) throws -> Int {
        var lastIndex: Int64?
        var lastID = ""
        var count = 0
        while true {
            try Task.checkCancellation()
            var descriptor: FetchDescriptor<TelemetryLegacyImportedRecordV2>
            if let lastIndex {
                descriptor = FetchDescriptor(
                    predicate: #Predicate {
                        $0.candidateID == candidateID
                            && ($0.sourceRecordIndex > lastIndex
                                || ($0.sourceRecordIndex == lastIndex
                                    && $0.importedRecordID > lastID))
                    },
                    sortBy: [SortDescriptor(\.sourceRecordIndex), SortDescriptor(\.importedRecordID)]
                )
            } else {
                descriptor = FetchDescriptor(
                    predicate: #Predicate { $0.candidateID == candidateID },
                    sortBy: [SortDescriptor(\.sourceRecordIndex), SortDescriptor(\.importedRecordID)]
                )
            }
            descriptor.fetchLimit = batchSize
            let models = try modelContext.fetch(descriptor)
            guard !models.isEmpty else { break }
            for model in models {
                let payload = try Self.decode(
                    LegacyImportedRecordPayload.self,
                    from: model.normalizedPayload
                )
                try stream.writeRaw(
                    recordType: "imported_evidence_record",
                    payload: ImportedEvidenceExportRecord(
                        importedRecordID: model.importedRecordID,
                        sourceID: model.sourceID,
                        candidateID: model.candidateID,
                        sourceRecordIndex: model.sourceRecordIndex,
                        eventKind: model.eventKind,
                        occurredAt: model.occurredAt,
                        workoutIdentifier: model.workoutIdentifier,
                        healthKitWorkoutIdentifier: model.healthKitWorkoutIdentifier,
                        stableLegacySessionIdentifier: model.stableLegacySessionIdentifier,
                        provenance: model.provenanceKey,
                        payload: payload,
                        identityUncertain: model.identityUncertain,
                        adaptationQualityEligible: model.adaptationQualityEligible
                    )
                )
                try stream.writeNormalized([
                    "imported_evidence_record", candidateID, model.importedRecordID,
                    WorkoutExportStreamDate.string(model.occurredAt), "",
                    payload.heartRateBeatsPerMinute.map(String.init) ?? "",
                    "", "", "", model.eventKind, "",
                    model.identityUncertain ? "identity-uncertain" : "",
                    model.provenanceKey,
                ])
                count += 1
                lastIndex = model.sourceRecordIndex
                lastID = model.importedRecordID
            }
            if models.count < batchSize { break }
        }
        return count
    }

    func exportImportedCandidateModels(
        _ model: TelemetryLegacyImportedWorkoutV2
    ) throws -> [TelemetryLegacyWorkoutCandidateV2] {
        var candidates: [TelemetryLegacyWorkoutCandidateV2] = []
        for candidateID in try exportModelCandidateIDs(model) {
            var descriptor = FetchDescriptor<TelemetryLegacyWorkoutCandidateV2>(
                predicate: #Predicate { $0.candidateID == candidateID }
            )
            descriptor.fetchLimit = 1
            guard let candidate = try modelContext.fetch(descriptor).first else {
                throw TelemetryWorkoutReadError.corruptProjection(
                    "missing imported candidate \(candidateID)"
                )
            }
            candidates.append(candidate)
        }
        return candidates.sorted { $0.candidateID < $1.candidateID }
    }

    func exportModelCandidateIDs(
        _ model: TelemetryLegacyImportedWorkoutV2
    ) throws -> [String] {
        do {
            return try Self.decode([String].self, from: model.candidateIDsPayload)
        } catch {
            throw TelemetryWorkoutReadError.corruptProjection(
                "invalid imported candidate linkage for \(model.importedWorkoutID)"
            )
        }
    }

    func treadmillUnitString(_ unit: TreadmillNativeSpeedUnit) -> String {
        switch unit {
        case .kilometresPerHour: return "kilometresPerHour"
        case .milesPerHour: return "milesPerHour"
        case let .controllerNative(code):
            return code.map { "controllerNative:\($0)" } ?? "controllerNative"
        case .unknown: return "unknown"
        }
    }
}

private enum WorkoutExportStreamDate {
    static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func string(_ date: Date?) -> String {
        date.map(formatter.string) ?? ""
    }
}
