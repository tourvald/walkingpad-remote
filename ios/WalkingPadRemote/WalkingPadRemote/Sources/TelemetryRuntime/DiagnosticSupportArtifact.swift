import Foundation
import TelemetryDomain

public struct DiagnosticSupportSnapshot: Codable, Equatable, Sendable {
    public struct Runtime: Codable, Equatable, Sendable {
        public let appVersion: String
        public let buildNumber: String
        public let operatingSystemVersion: String
        public let telemetrySchemaVersion: String
        public let algorithmVersion: String
        public let safetyPolicyVersion: String
        public let workoutProtocolVersion: String

        public init(
            appVersion: String,
            buildNumber: String,
            operatingSystemVersion: String,
            telemetrySchemaVersion: String,
            algorithmVersion: String,
            safetyPolicyVersion: String,
            workoutProtocolVersion: String
        ) {
            self.appVersion = appVersion
            self.buildNumber = buildNumber
            self.operatingSystemVersion = operatingSystemVersion
            self.telemetrySchemaVersion = telemetrySchemaVersion
            self.algorithmVersion = algorithmVersion
            self.safetyPolicyVersion = safetyPolicyVersion
            self.workoutProtocolVersion = workoutProtocolVersion
        }
    }

    public struct NativeHeartRatePreflight: Codable, Equatable, Sendable {
        public let phase: String
        public let requestedAt: Date?
        public let providerPreparedAt: Date?
        public let collectionStartedAt: Date?
        public let firstNativeCallbackMeasuredAt: Date?
        public let firstNativeCallbackReceivedAt: Date?
        public let firstQualifyingLatencySeconds: TimeInterval?
        public let terminalAt: Date?
        public let terminalReason: String?
        public let gateBlockReason: String?
        public let providerState: String
        public let providerCleanupInFlight: Bool
        public let providerGeneration: UInt64
        public let providerHasBoundAttempt: Bool
        public let nativeWorkoutCommitted: Bool

        public init(
            phase: String,
            requestedAt: Date?,
            providerPreparedAt: Date?,
            collectionStartedAt: Date?,
            firstNativeCallbackMeasuredAt: Date?,
            firstNativeCallbackReceivedAt: Date?,
            firstQualifyingLatencySeconds: TimeInterval?,
            terminalAt: Date?,
            terminalReason: String?,
            gateBlockReason: String?,
            providerState: String,
            providerCleanupInFlight: Bool,
            providerGeneration: UInt64,
            providerHasBoundAttempt: Bool,
            nativeWorkoutCommitted: Bool
        ) {
            self.phase = phase
            self.requestedAt = requestedAt
            self.providerPreparedAt = providerPreparedAt
            self.collectionStartedAt = collectionStartedAt
            self.firstNativeCallbackMeasuredAt = firstNativeCallbackMeasuredAt
            self.firstNativeCallbackReceivedAt = firstNativeCallbackReceivedAt
            self.firstQualifyingLatencySeconds = firstQualifyingLatencySeconds
            self.terminalAt = terminalAt
            self.terminalReason = terminalReason
            self.gateBlockReason = gateBlockReason
            self.providerState = providerState
            self.providerCleanupInFlight = providerCleanupInFlight
            self.providerGeneration = providerGeneration
            self.providerHasBoundAttempt = providerHasBoundAttempt
            self.nativeWorkoutCommitted = nativeWorkoutCommitted
        }
    }

    public struct ControllerUnits: Codable, Equatable, Sendable {
        public let status: String
        public let physicalUnits: String
        public let observedAt: Date?
        public let ageSeconds: TimeInterval?
        public let isFresh: Bool
        public let gateAllowed: Bool
        public let blockReason: String?
        public let evidenceConnectionEpoch: String?
        public let currentConnectionEpoch: String?
        public let isCurrentConnection: Bool
        public let byteCount: Int?
        public let rawA6Hex: String?

        public init(
            status: String,
            physicalUnits: String,
            observedAt: Date?,
            ageSeconds: TimeInterval?,
            isFresh: Bool,
            gateAllowed: Bool,
            blockReason: String?,
            evidenceConnectionEpoch: String?,
            currentConnectionEpoch: String?,
            isCurrentConnection: Bool,
            byteCount: Int?,
            rawA6Hex: String?
        ) {
            self.status = status
            self.physicalUnits = physicalUnits
            self.observedAt = observedAt
            self.ageSeconds = ageSeconds
            self.isFresh = isFresh
            self.gateAllowed = gateAllowed
            self.blockReason = blockReason
            self.evidenceConnectionEpoch = evidenceConnectionEpoch
            self.currentConnectionEpoch = currentConnectionEpoch
            self.isCurrentConnection = isCurrentConnection
            self.byteCount = byteCount
            self.rawA6Hex = rawA6Hex
        }
    }

    public struct Treadmill: Codable, Equatable, Sendable {
        public let protocolName: String
        public let isConnected: Bool
        public let isControlReady: Bool
        public let hasCurrentConnectionContext: Bool
        public let protocolMatchesCurrentConnection: Bool
        public let connectionEpoch: String?

        public init(
            protocolName: String,
            isConnected: Bool,
            isControlReady: Bool,
            hasCurrentConnectionContext: Bool,
            protocolMatchesCurrentConnection: Bool,
            connectionEpoch: String?
        ) {
            self.protocolName = protocolName
            self.isConnected = isConnected
            self.isControlReady = isControlReady
            self.hasCurrentConnectionContext = hasCurrentConnectionContext
            self.protocolMatchesCurrentConnection = protocolMatchesCurrentConnection
            self.connectionEpoch = connectionEpoch
        }
    }

    public struct WriterHealth: Codable, Equatable, Sendable {
        public let workoutReadState: String
        public let runtimeLifecycle: String
        public let recorderLifecycle: String?
        public let completeness: String?
        public let queueDepth: Int
        public let peakQueueDepth: Int
        public let coalescedFrameCount: UInt64
        public let droppedFrameCount: UInt64
        public let lostNativeCount: UInt64
        public let lostCriticalCount: UInt64
        public let writerFailureCount: UInt64
        public let retryCount: UInt64
        public let successfulFlushCount: UInt64
        public let lastCommittedRecorderSequence: UInt64?

        public init(
            workoutReadState: String,
            runtimeLifecycle: String,
            recorderLifecycle: String?,
            completeness: String?,
            queueDepth: Int,
            peakQueueDepth: Int,
            coalescedFrameCount: UInt64,
            droppedFrameCount: UInt64,
            lostNativeCount: UInt64,
            lostCriticalCount: UInt64,
            writerFailureCount: UInt64,
            retryCount: UInt64,
            successfulFlushCount: UInt64,
            lastCommittedRecorderSequence: UInt64?
        ) {
            self.workoutReadState = workoutReadState
            self.runtimeLifecycle = runtimeLifecycle
            self.recorderLifecycle = recorderLifecycle
            self.completeness = completeness
            self.queueDepth = queueDepth
            self.peakQueueDepth = peakQueueDepth
            self.coalescedFrameCount = coalescedFrameCount
            self.droppedFrameCount = droppedFrameCount
            self.lostNativeCount = lostNativeCount
            self.lostCriticalCount = lostCriticalCount
            self.writerFailureCount = writerFailureCount
            self.retryCount = retryCount
            self.successfulFlushCount = successfulFlushCount
            self.lastCommittedRecorderSequence = lastCommittedRecorderSequence
        }
    }

    public let capturedAt: Date
    public let runtime: Runtime
    public let nativeHeartRatePreflight: NativeHeartRatePreflight
    public let controllerUnits: ControllerUnits
    public let treadmill: Treadmill
    public let writerHealth: WriterHealth

    public init(
        capturedAt: Date,
        runtime: Runtime,
        nativeHeartRatePreflight: NativeHeartRatePreflight,
        controllerUnits: ControllerUnits,
        treadmill: Treadmill,
        writerHealth: WriterHealth
    ) {
        self.capturedAt = capturedAt
        self.runtime = runtime
        self.nativeHeartRatePreflight = nativeHeartRatePreflight
        self.controllerUnits = controllerUnits
        self.treadmill = treadmill
        self.writerHealth = writerHealth
    }
}

public struct DiagnosticBundleArtifact: Equatable, Sendable {
    public let directoryURL: URL
    public let archiveURL: URL
    public let containsHealthData: Bool
    public let exportedWorkoutCount: Int
    public let exportedRecordCount: Int
    public let packagingDurationSeconds: TimeInterval
    public let archiveBytes: UInt64
    public let maximumChunkBytes: Int
}

public enum DiagnosticBundlePackager {
    public static func create(
        workoutArtifact: WorkoutExportArtifact,
        supportSnapshot: DiagnosticSupportSnapshot,
        archiveName: String
    ) async throws -> DiagnosticBundleArtifact {
        try await package(
            workoutArtifact: workoutArtifact,
            supportSnapshot: supportSnapshot,
            archiveName: archiveName,
            workoutEvidenceStatus: "available",
            workoutEvidenceFailureCategory: nil
        )
    }

    public static func createSupportOnly(
        supportSnapshot: DiagnosticSupportSnapshot,
        archiveName: String,
        workoutEvidenceStatus: String = "unavailable",
        workoutEvidenceFailureCategory: String
    ) async throws -> DiagnosticBundleArtifact {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WalkingPadSupportExport_\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            return try await package(
                workoutArtifact: WorkoutExportArtifact(
                    directoryURL: directoryURL,
                    fileURLs: [],
                    exportedWorkoutCount: 0,
                    exportedRecordCount: 0,
                    containsHealthData: false
                ),
                supportSnapshot: supportSnapshot,
                archiveName: archiveName,
                workoutEvidenceStatus: workoutEvidenceStatus,
                workoutEvidenceFailureCategory: workoutEvidenceFailureCategory
            )
        } catch {
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
    }

    private static func package(
        workoutArtifact: WorkoutExportArtifact,
        supportSnapshot: DiagnosticSupportSnapshot,
        archiveName: String,
        workoutEvidenceStatus: String,
        workoutEvidenceFailureCategory: String?
    ) async throws -> DiagnosticBundleArtifact {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let supportURL = workoutArtifact.directoryURL.appendingPathComponent(
                "support_diagnostics_v1.json"
            )
            let envelope = DiagnosticSupportArtifactEnvelope(
                schemaVersion: "walkingpad-support-diagnostics-v1",
                generatedAt: Date(),
                exportedWorkoutCount: workoutArtifact.exportedWorkoutCount,
                exportedRecordCount: workoutArtifact.exportedRecordCount,
                containsHealthData: workoutArtifact.containsHealthData,
                workoutEvidenceStatus: workoutEvidenceStatus,
                workoutEvidenceFailureCategory: workoutEvidenceFailureCategory,
                support: supportSnapshot
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(envelope).write(to: supportURL, options: .atomic)
            try Task.checkCancellation()

            let started = ContinuousClock.now
            let archive = try DiagnosticZipArchive.createWithMetrics(
                directoryURL: workoutArtifact.directoryURL,
                fileURLs: workoutArtifact.fileURLs + [supportURL],
                archiveName: archiveName
            )
            return DiagnosticBundleArtifact(
                directoryURL: workoutArtifact.directoryURL,
                archiveURL: archive.url,
                containsHealthData: workoutArtifact.containsHealthData,
                exportedWorkoutCount: workoutArtifact.exportedWorkoutCount,
                exportedRecordCount: workoutArtifact.exportedRecordCount,
                packagingDurationSeconds: started.duration(to: .now).seconds,
                archiveBytes: archive.outputBytes,
                maximumChunkBytes: archive.maximumChunkBytes
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

private struct DiagnosticSupportArtifactEnvelope: Codable {
    let schemaVersion: String
    let generatedAt: Date
    let exportedWorkoutCount: Int
    let exportedRecordCount: Int
    let containsHealthData: Bool
    let workoutEvidenceStatus: String
    let workoutEvidenceFailureCategory: String?
    let support: DiagnosticSupportSnapshot
}

private extension Duration {
    var seconds: TimeInterval {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
