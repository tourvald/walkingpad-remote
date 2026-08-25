import CryptoKit
import Foundation
import SwiftData
import TelemetryDomain

private struct WorkoutAnalysisEventProjection {
    let elapsedMicroseconds: Int64
    let occurredAt: Date
    let kind: String
    let name: String
    let detail: String?
    let phase: WorkoutPhase?
    let targetHeartRate: Int?
    let decisionReference: String?
    let commandReference: String?
    let attemptReference: String?
    let configurationReference: String?
    let decisionAction: String?
    let decisionReason: String?
    let desiredSpeedKilometresPerHour: Double?
    let commandedSpeedNativeValue: Double?
    let commandedSpeedNativeUnit: String?
    let commandAttemptNumber: Int?
    let endReason: String?
}

private final class WorkoutAnalysisCSVStream {
    static let headers = [
        "schema_version", "row_type", "row_order", "elapsed_s", "timestamp",
        "phase", "target_bpm", "hr_bpm", "hr_evidence_ref",
        "hr_evidence_elapsed_s", "hr_age_s", "hr_freshness", "hr_provenance",
        "factual_speed_kmh", "treadmill_evidence_ref",
        "treadmill_evidence_elapsed_s", "treadmill_age_s", "treadmill_freshness",
        "treadmill_availability", "treadmill_state", "treadmill_provenance",
        "gap_missing_since_s", "gap_kind", "event_kind", "event_name",
        "event_detail", "decision_ref", "command_ref", "attempt_ref",
        "configuration_ref", "decision_action", "decision_reason",
        "desired_speed_kmh", "commanded_speed_native_value",
        "commanded_speed_native_unit", "command_attempt_number",
        "metadata_key", "metadata_value", "quality_flags",
    ]

    let fileURL: URL
    private let handle: FileHandle
    private(set) var rowOrder = 0
    private var closed = false

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: fileURL)
        try write(Self.headers)
    }

    deinit { close() }

    func writeTimeline(
        elapsedMicroseconds: Int64,
        timestamp: Date,
        phase: String,
        targetHeartRate: Int?,
        values: [String: String]
    ) throws {
        rowOrder += 1
        var fields = Self.emptyRow
        fields[0] = WorkoutAnalysisExportArtifact.schemaVersion
        fields[1] = values["row_type"] ?? ""
        fields[2] = String(rowOrder)
        fields[3] = Self.seconds(elapsedMicroseconds)
        fields[4] = Self.date(timestamp)
        fields[5] = phase
        fields[6] = targetHeartRate.map(String.init) ?? ""
        for (header, value) in values where header != "row_type" {
            if let index = Self.headerIndexes[header] { fields[index] = value }
        }
        try write(fields)
    }

    func writeMetadata(key: String, value: String) throws {
        rowOrder += 1
        var fields = Self.emptyRow
        fields[0] = WorkoutAnalysisExportArtifact.schemaVersion
        fields[1] = "metadata"
        fields[2] = String(rowOrder)
        fields[36] = key
        fields[37] = value
        try write(fields)
    }

    func close() {
        guard !closed else { return }
        closed = true
        try? handle.close()
    }

    static func number(_ value: Double?) -> String {
        value.map {
            String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), $0)
        } ?? ""
    }

    static func seconds(_ microseconds: Int64?) -> String {
        guard let microseconds else { return "" }
        return number(Double(microseconds) / 1_000_000)
    }

    static func date(_ value: Date?) -> String {
        guard let value else { return "" }
        return dateFormatter.string(from: value)
    }

    private func write(_ fields: [String]) throws {
        let line = fields.map(Self.escape).joined(separator: ",") + "\n"
        try handle.write(contentsOf: Data(line.utf8))
    }

    private static let emptyRow = Array(repeating: "", count: headers.count)
    private static let headerIndexes = Dictionary(
        uniqueKeysWithValues: headers.enumerated().map { ($1, $0) }
    )
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"")
                || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

public extension TelemetryStore {
    func exportWorkoutAnalysis(
        _ request: WorkoutAnalysisExportRequest
    ) async throws -> WorkoutAnalysisExportArtifact {
        let batchSize = min(256, max(1, request.batchSize))
        let sessionKey = request.sessionID.description
        let profileKey = request.exactProfileLocalIdentifier
        let alternateProfileKey = UUID(uuidString: profileKey)?.uuidString.lowercased()
            ?? profileKey
        var sessionDescriptor = FetchDescriptor<TelemetryWorkoutSessionV1>(
            predicate: #Predicate {
                $0.sessionID == sessionKey
                    && ($0.profileLocalIdentifier == profileKey
                        || $0.profileLocalIdentifier == alternateProfileKey)
            }
        )
        sessionDescriptor.fetchLimit = 1
        guard let session = try modelContext.fetch(sessionDescriptor).first else {
            throw TelemetryWorkoutReadError.unavailable("selected-native-workout-unavailable")
        }

        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WorkoutAnalysisExport_\(UUID().uuidString)",
            isDirectory: true
        )
        let fileURL = directoryURL.appendingPathComponent(
            "Workout_Analysis_\(Self.analysisFileTimestamp(session.startedAt)).csv"
        )
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let stream = try WorkoutAnalysisCSVStream(fileURL: fileURL)
            defer { stream.close() }

            let configuration = try Self.decode(
                PrivacySafeConfigurationExportRecord.self,
                from: session.configuration?.canonicalPayload ?? Data("{}".utf8)
            )
            let analysis = try latestStoredAnalysis(sessionID: sessionKey)
            var fetchCount = 2
            var maximumBufferedRows = 0
            var frameRows = 0
            var eventRows = 0
            var heartRateFrameRows = 0
            var factualSpeedFrameRows = 0
            var gapBoundaryRows = 0
            var phase = WorkoutPhase.unknown
            var targetHeartRate = configuration.targetHeartRate
            var endReason = Self.lifecycleReason(session.incompleteReason)

            var frames: [CanonicalFrame] = []
            var events: [WorkoutAnalysisEventProjection] = []
            var frameIndex = 0
            var eventIndex = 0
            var lastFrameSecond: Int64?
            var lastFrameID = ""
            var lastEventElapsed: Int64?
            var lastEventID = ""
            var framesFinished = false
            var eventsFinished = false

            func loadFramesIfNeeded() throws {
                guard frameIndex == frames.count, !framesFinished else { return }
                let page = try analysisFramePage(
                    sessionID: sessionKey,
                    afterSecond: lastFrameSecond,
                    afterID: lastFrameID,
                    limit: batchSize
                )
                fetchCount += 1
                frames = page
                frameIndex = 0
                if let last = page.last {
                    lastFrameSecond = last.canonicalElapsedSecond
                    lastFrameID = last.frameID.description
                }
                framesFinished = page.count < batchSize
            }

            func loadEventsIfNeeded() throws {
                guard eventIndex == events.count, !eventsFinished else { return }
                let page = try analysisEventPage(
                    sessionID: sessionKey,
                    sessionReference: request.sessionID,
                    afterElapsed: lastEventElapsed,
                    afterID: lastEventID,
                    limit: batchSize
                )
                fetchCount += 1
                events = page.projections
                eventIndex = 0
                lastEventElapsed = page.cursorElapsed
                lastEventID = page.cursorID
                eventsFinished = page.fetchedCount < batchSize
            }

            while true {
                try Task.checkCancellation()
                try loadFramesIfNeeded()
                try loadEventsIfNeeded()
                maximumBufferedRows = max(
                    maximumBufferedRows,
                    (frames.count - frameIndex) + (events.count - eventIndex)
                )
                let frame = frameIndex < frames.count ? frames[frameIndex] : nil
                let event = eventIndex < events.count ? events[eventIndex] : nil
                guard frame != nil || event != nil else { break }

                if let event,
                   frame == nil
                    || event.elapsedMicroseconds <= frame!.materializedAt.elapsed.microseconds {
                    if let eventPhase = event.phase { phase = eventPhase }
                    if let eventTarget = event.targetHeartRate { targetHeartRate = eventTarget }
                    if let eventEndReason = event.endReason { endReason = eventEndReason }
                    try stream.writeAnalysisEvent(
                        event,
                        phase: Self.phaseString(phase),
                        targetHeartRate: targetHeartRate
                    )
                    eventRows += 1
                    eventIndex += 1
                } else if let frame {
                    try stream.writeAnalysisFrame(
                        frame,
                        sessionID: request.sessionID,
                        phase: Self.phaseString(phase),
                        targetHeartRate: targetHeartRate
                    )
                    frameRows += 1
                    if frame.heartRateEvidence != nil { heartRateFrameRows += 1 }
                    if frame.treadmillEvidence?.factualSpeed != nil {
                        factualSpeedFrameRows += 1
                    }
                    if frame.precedingGap != nil { gapBoundaryRows += 1 }
                    frameIndex += 1
                }
            }

            var warnings: [String] = []
            if !session.recorderIsComplete { warnings.append("recorder-incomplete") }
            if session.lostCriticalRecordCount > 0 {
                warnings.append("lost-critical-records:\(session.lostCriticalRecordCount)")
            }
            if session.lostNativeRecordCount > 0 {
                warnings.append("lost-native-records:\(session.lostNativeRecordCount)")
            }
            if frameRows == 0 { warnings.append("canonical-frames-unavailable") }
            if heartRateFrameRows < frameRows {
                warnings.append("heart-rate-frame-coverage-partial")
            }
            if factualSpeedFrameRows < frameRows {
                warnings.append("factual-speed-frame-coverage-partial")
            }
            if gapBoundaryRows > 0 {
                warnings.append("canonical-gaps-present:\(gapBoundaryRows)")
            }
            if analysis == nil { warnings.append("stored-analysis-unavailable") }
            if let analysis,
               let qualityGrade = AnalysisQualityGrade(rawValue: analysis.qualityGradeKey),
               qualityGrade != .high {
                warnings.append("analysis-quality:\(qualityGrade.rawValue)")
            }
            let exclusions = try analysis.map {
                try Self.decode([AnalysisExclusion].self, from: $0.exclusionsPayload)
            } ?? []
            warnings.append(contentsOf: exclusions.map {
                "analysis-exclusion:\(Self.analysisExclusionCode($0.code))"
            })

            let metadata = Self.analysisMetadata(
                session: session,
                configuration: configuration,
                analysis: analysis,
                frameRows: frameRows,
                eventRows: eventRows,
                heartRateFrameRows: heartRateFrameRows,
                factualSpeedFrameRows: factualSpeedFrameRows,
                gapBoundaryRows: gapBoundaryRows,
                endReason: endReason,
                warnings: warnings,
                sessionID: request.sessionID
            )
            for item in metadata {
                try stream.writeMetadata(key: item.key, value: item.value)
            }
            stream.close()
            let byteCount = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return WorkoutAnalysisExportArtifact(
                fileURL: fileURL,
                diagnostics: WorkoutAnalysisExportDiagnostics(
                    frameRowCount: frameRows,
                    eventRowCount: eventRows,
                    metadataRowCount: metadata.count,
                    fileByteCount: Int64(byteCount),
                    storeFetchCount: fetchCount,
                    maximumStoreFetchLimit: batchSize,
                    maximumBufferedTimelineRows: maximumBufferedRows
                ),
                containsHealthData: frameRows > 0
            )
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: directoryURL)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: directoryURL)
            if let readError = error as? TelemetryWorkoutReadError { throw readError }
            throw TelemetryWorkoutReadError.exportFailed(String(describing: error))
        }
    }
}

private extension TelemetryStore {
    struct AnalysisEventPage {
        let projections: [WorkoutAnalysisEventProjection]
        let fetchedCount: Int
        let cursorElapsed: Int64?
        let cursorID: String
    }

    func latestStoredAnalysis(sessionID: String) throws -> TelemetryWorkoutAnalysisV1? {
        var descriptor = FetchDescriptor<TelemetryWorkoutAnalysisV1>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [
                SortDescriptor(\.generatedAt, order: .reverse),
                SortDescriptor(\.analysisID, order: .reverse),
            ]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    func analysisFramePage(
        sessionID: String,
        afterSecond: Int64?,
        afterID: String,
        limit: Int
    ) throws -> [CanonicalFrame] {
        var descriptor: FetchDescriptor<TelemetryWorkoutFrameV1>
        if let afterSecond {
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.sessionID == sessionID
                        && ($0.canonicalElapsedSecond > afterSecond
                            || ($0.canonicalElapsedSecond == afterSecond && $0.frameID > afterID))
                },
                sortBy: [SortDescriptor(\.canonicalElapsedSecond), SortDescriptor(\.frameID)]
            )
        } else {
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.sessionID == sessionID },
                sortBy: [SortDescriptor(\.canonicalElapsedSecond), SortDescriptor(\.frameID)]
            )
        }
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map(Self.domainFrame)
    }

    func analysisEventPage(
        sessionID: String,
        sessionReference: SessionID,
        afterElapsed: Int64?,
        afterID: String,
        limit: Int
    ) throws -> AnalysisEventPage {
        let lifecycle = WorkoutEventKind.sessionLifecycle.rawValue
        let phase = WorkoutEventKind.workoutPhase.rawValue
        let source = WorkoutEventKind.sourceTransition.rawValue
        let connection = WorkoutEventKind.connectionTransition.rawValue
        let decision = WorkoutEventKind.controlDecision.rawValue
        let command = WorkoutEventKind.commandLifecycle.rawValue
        let treadmill = WorkoutEventKind.treadmillEvidence.rawValue
        let cooldown = WorkoutEventKind.cooldown.rawValue
        let manualStop = WorkoutEventKind.manualStop.rawValue
        let safety = WorkoutEventKind.safety.rawValue
        let stopEvidence = WorkoutEventKind.stopEvidence.rawValue
        let recorderHealth = WorkoutEventKind.recorderHealth.rawValue
        // V1 indexes the typed envelope kind, not treadmill subtypes. Keep the
        // keyset fetch bounded and allowlist command projections after decode.
        let selectedKinds = [
            lifecycle, phase, source, connection, decision, command, treadmill, cooldown,
            manualStop, safety, stopEvidence, recorderHealth,
        ]
        var descriptor: FetchDescriptor<TelemetryWorkoutEventV1>
        if let afterElapsed {
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.sessionID == sessionID
                        && selectedKinds.contains($0.kindKey)
                        && ($0.occurredElapsedMicroseconds > afterElapsed
                            || ($0.occurredElapsedMicroseconds == afterElapsed
                                && $0.recordID > afterID))
                },
                sortBy: [
                    SortDescriptor(\.occurredElapsedMicroseconds),
                    SortDescriptor(\.recordID),
                ]
            )
        } else {
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.sessionID == sessionID
                        && selectedKinds.contains($0.kindKey)
                },
                sortBy: [
                    SortDescriptor(\.occurredElapsedMicroseconds),
                    SortDescriptor(\.recordID),
                ]
            )
        }
        descriptor.fetchLimit = limit
        let models = try modelContext.fetch(descriptor)
        return AnalysisEventPage(
            projections: try models.compactMap {
                try Self.analysisEventProjection(
                    Self.domainEvent($0),
                    sessionID: sessionReference
                )
            },
            fetchedCount: models.count,
            cursorElapsed: models.last?.occurredElapsedMicroseconds ?? afterElapsed,
            cursorID: models.last?.recordID ?? afterID
        )
    }

    static func analysisEventProjection(
        _ event: WorkoutEvent,
        sessionID: SessionID
    ) throws -> WorkoutAnalysisEventProjection? {
        let decisionRef = event.decisionID.map { reference("decision", $0.description, sessionID) }
        let commandRef = event.commandID.map { reference("command", $0.description, sessionID) }
        let attemptRef = event.attemptID.map { reference("attempt", $0.description, sessionID) }
        let common = (
            event.timestamp.occurredElapsed.microseconds,
            event.timestamp.occurredAt,
            event.kind.rawValue,
            decisionRef,
            commandRef,
            attemptRef
        )
        switch event.payload.payload {
        case let .sessionLifecycle(value):
            let reason = lifecycleReason(value.reason ?? value.incompleteReason)
            return .init(
                elapsedMicroseconds: common.0, occurredAt: common.1, kind: common.2,
                name: "lifecycle_\(value.current.rawValue)", detail: reason,
                phase: nil, targetHeartRate: nil, decisionReference: nil,
                commandReference: nil, attemptReference: nil, configurationReference: nil,
                decisionAction: nil, decisionReason: nil,
                desiredSpeedKilometresPerHour: nil, commandedSpeedNativeValue: nil,
                commandedSpeedNativeUnit: nil, commandAttemptNumber: nil,
                endReason: reason
            )
        case let .workoutPhase(value):
            return .init(
                elapsedMicroseconds: common.0, occurredAt: common.1, kind: common.2,
                name: "phase_transition", detail: phaseString(value.previous),
                phase: value.current, targetHeartRate: nil, decisionReference: nil,
                commandReference: nil, attemptReference: nil, configurationReference: nil,
                decisionAction: nil, decisionReason: nil,
                desiredSpeedKilometresPerHour: nil, commandedSpeedNativeValue: nil,
                commandedSpeedNativeUnit: nil, commandAttemptNumber: nil, endReason: nil
            )
        case let .sourceTransition(value):
            let previous = value.previousSourceID == nil ? "unavailable" : "available"
            let current = value.currentSourceID == nil ? "unavailable" : "available"
            return simpleEvent(
                common,
                name: "source_transition",
                detail: "\(previous)->\(current);reason-present"
            )
        case let .connectionTransition(value):
            return simpleEvent(
                common,
                name: "connection_transition",
                detail: "\(value.previous.rawValue)->\(value.current.rawValue)"
                    + (value.reason == nil ? "" : ";reason-present")
            )
        case let .controlDecision(value):
            let target = targetHeartRate(value.target)
            let action = controlAction(value.action)
            return .init(
                elapsedMicroseconds: common.0, occurredAt: common.1, kind: common.2,
                name: "control_decision", detail: nil, phase: nil,
                targetHeartRate: target, decisionReference: common.3,
                commandReference: nil, attemptReference: nil,
                configurationReference: reference(
                    "configuration", value.configurationSnapshotID.description, sessionID
                ),
                decisionAction: action.name,
                decisionReason: controlReason(value.reason),
                desiredSpeedKilometresPerHour: action.desiredSpeed,
                commandedSpeedNativeValue: nil, commandedSpeedNativeUnit: nil,
                commandAttemptNumber: nil, endReason: nil
            )
        case let .commandLifecycle(value):
            let lifecycle = commandLifecycle(value.lifecycle)
            return .init(
                elapsedMicroseconds: common.0, occurredAt: common.1, kind: common.2,
                name: lifecycle.name, detail: lifecycle.detail, phase: nil,
                targetHeartRate: nil, decisionReference: common.3,
                commandReference: common.4, attemptReference: common.5,
                configurationReference: nil, decisionAction: nil, decisionReason: nil,
                desiredSpeedKilometresPerHour: nil,
                commandedSpeedNativeValue: lifecycle.commandedValue,
                commandedSpeedNativeUnit: lifecycle.commandedUnit,
                commandAttemptNumber: lifecycle.attemptNumber, endReason: nil
            )
        case let .treadmillEvidence(value):
            return treadmillCommandProjection(value, common: common)
        case let .cooldown(value):
            return .init(
                elapsedMicroseconds: common.0, occurredAt: common.1, kind: common.2,
                name: "cooldown_\(value.lifecycle.rawValue)", detail: nil,
                phase: value.lifecycle == .started ? .cooldown : nil,
                targetHeartRate: value.targetHeartRate.map(Int.init),
                decisionReference: nil, commandReference: nil, attemptReference: nil,
                configurationReference: nil, decisionAction: nil, decisionReason: nil,
                desiredSpeedKilometresPerHour: nil, commandedSpeedNativeValue: nil,
                commandedSpeedNativeUnit: nil, commandAttemptNumber: nil, endReason: nil
            )
        case let .manualStop(value):
            return simpleEvent(
                common,
                name: "manual_stop",
                detail: value.reason == nil ? nil : "reason-present"
            )
        case let .safety(value):
            return simpleEvent(
                common,
                name: "safety_\(value.outcome.rawValue)",
                detail: "policy-and-gate-recorded"
            )
        case let .stopEvidence(value):
            return simpleEvent(
                common,
                name: "stop_evidence",
                detail: stopConclusion(value.conclusion)
            )
        case let .recorderHealth(value):
            if let lifecycle = AppLifecycleEvidencePersistence.event(from: value) {
                return simpleEvent(
                    common,
                    name: "app_lifecycle_\(lifecycle.currentState.rawValue)",
                    detail: [
                        lifecycle.workoutStage.rawValue,
                        lifecycle.policyAction.rawValue,
                        lifecycle.policyReason,
                        lifecycle.treadmillConnectionState.rawValue,
                    ].joined(separator: ";")
                )
            }
            return simpleEvent(
                common,
                name: "recorder_\(value.kind.rawValue)",
                detail: [
                    recorderRecordClass(value.affectedRecordClass),
                    recorderDetailCode(value.detailCode),
                ].compactMap { $0 }
                    .joined(separator: ";")
            )
        case .heartRateEvidence:
            throw TelemetryWorkoutReadError.corruptProjection("unselected-analysis-event-kind")
        }
    }

    static func treadmillCommandProjection(
        _ evidence: TreadmillTelemetryEvidence,
        common: (Int64, Date, String, String?, String?, String?)
    ) -> WorkoutAnalysisEventProjection? {
        let projection: (
            name: String,
            detail: String?,
            commandedValue: Double?,
            commandedUnit: String?,
            attemptNumber: Int?
        )
        switch evidence {
        case let .commandEnqueued(value):
            let command = commandKind(value.kind)
            let detail = [
                "protocol=\(treadmillProtocol(value.protocolKind))",
                command.detail.map { "kind=\($0)" },
            ].compactMap { $0 }.joined(separator: ";")
            projection = (
                command.name,
                detail,
                command.commandedValue,
                command.commandedUnit,
                nil
            )
        case let .sendAttempt(value):
            projection = (
                "command_send_attempt",
                "protocol=\(treadmillProtocol(value.protocolKind));write=\(writeType(value.writeType))",
                nil,
                nil,
                Int(value.attemptNumber)
            )
        case let .acknowledgement(value):
            projection = (
                "command_acknowledged",
                "association=\(association(value.association));protocol=\(treadmillProtocol(value.protocolKind))",
                nil,
                nil,
                nil
            )
        case let .commandTimeout(value):
            projection = (
                "command_timed_out",
                "association=\(association(value.association));protocol=\(treadmillProtocol(value.protocolKind))",
                nil,
                nil,
                nil
            )
        case let .commandFailed(value):
            projection = ("command_failed", failureReason(value.reason), nil, nil, nil)
        case let .commandCancelled(value):
            projection = ("command_cancelled", cancellationReason(value.reason), nil, nil, nil)
        case .observation, .unitsTruth, .decision, .commandQueueDelay,
             .unassociatedWrite, .writeResult, .stopEvidence:
            return nil
        }
        return .init(
            elapsedMicroseconds: common.0,
            occurredAt: common.1,
            kind: common.2,
            name: projection.name,
            detail: projection.detail,
            phase: nil,
            targetHeartRate: nil,
            decisionReference: common.3,
            commandReference: common.4,
            attemptReference: common.5,
            configurationReference: nil,
            decisionAction: nil,
            decisionReason: nil,
            desiredSpeedKilometresPerHour: nil,
            commandedSpeedNativeValue: projection.commandedValue,
            commandedSpeedNativeUnit: projection.commandedUnit,
            commandAttemptNumber: projection.attemptNumber,
            endReason: nil
        )
    }

    static func simpleEvent(
        _ common: (Int64, Date, String, String?, String?, String?),
        name: String,
        detail: String?
    ) -> WorkoutAnalysisEventProjection {
        .init(
            elapsedMicroseconds: common.0, occurredAt: common.1, kind: common.2,
            name: name, detail: detail, phase: nil, targetHeartRate: nil,
            decisionReference: common.3, commandReference: common.4,
            attemptReference: common.5, configurationReference: nil,
            decisionAction: nil, decisionReason: nil,
            desiredSpeedKilometresPerHour: nil, commandedSpeedNativeValue: nil,
            commandedSpeedNativeUnit: nil, commandAttemptNumber: nil, endReason: nil
        )
    }

    static func analysisMetadata(
        session: TelemetryWorkoutSessionV1,
        configuration: PrivacySafeConfigurationExportRecord,
        analysis: TelemetryWorkoutAnalysisV1?,
        frameRows: Int,
        eventRows: Int,
        heartRateFrameRows: Int,
        factualSpeedFrameRows: Int,
        gapBoundaryRows: Int,
        endReason: String?,
        warnings: [String],
        sessionID: SessionID
    ) -> [(key: String, value: String)] {
        let treadmill = configuration.treadmill
        return [
            ("schema_version", WorkoutAnalysisExportArtifact.schemaVersion),
            ("workout_ref", reference("workout", sessionID.description, sessionID)),
            ("lifecycle_state", session.lifecycleStateKey),
            ("started_at", WorkoutAnalysisCSVStream.date(session.startedAt)),
            ("ended_at", WorkoutAnalysisCSVStream.date(session.endedAt)),
            ("ended_elapsed_s", WorkoutAnalysisCSVStream.seconds(session.endedElapsedMicroseconds)),
            ("end_reason", endReason ?? ""),
            ("app_version", session.appVersion),
            ("build_number", session.buildNumber),
            ("operating_system_version", session.operatingSystemVersion),
            ("telemetry_schema_version", session.telemetrySchemaVersion),
            ("analyzer_version", analysis?.analyzerVersion ?? ""),
            ("algorithm_version", session.algorithmVersion),
            ("safety_policy_version", session.safetyPolicyVersion),
            ("workout_protocol_version", session.workoutProtocolVersion),
            ("configuration_hash", session.configuration?.contentHashDigest ?? ""),
            ("workout_mode", workoutModeString(configuration.workoutMode)),
            ("target_bpm", configuration.targetHeartRate.map(String.init) ?? ""),
            ("duration_minutes", configuration.durationMinutes.map(String.init) ?? ""),
            ("decision_interval_s", configuration.decisionIntervalSeconds.map(String.init) ?? ""),
            ("adaptive_step_enabled", configuration.adaptiveStepEnabled.map(String.init) ?? ""),
            ("maximum_step_kmh", WorkoutAnalysisCSVStream.number(configuration.maximumStepKilometresPerHour)),
            ("heart_rate_zones_bpm", configuration.heartRateZones?.map(String.init).joined(separator: ";") ?? ""),
            ("cooldown_target_bpm", configuration.cooldownTargetHeartRate.map(String.init) ?? ""),
            ("cooldown_minimum_speed_kmh", WorkoutAnalysisCSVStream.number(configuration.cooldownMinimumSpeedKilometresPerHour)),
            ("cooldown_maximum_minutes", configuration.cooldownMaximumMinutes.map(String.init) ?? ""),
            ("treadmill_protocol", treadmill?.protocolName ?? ""),
            ("treadmill_protocol_version", treadmill?.protocolVersion ?? ""),
            ("treadmill_minimum_speed_kmh", WorkoutAnalysisCSVStream.number(treadmill?.minimumSpeedKilometresPerHour)),
            ("treadmill_maximum_speed_kmh", WorkoutAnalysisCSVStream.number(treadmill?.maximumSpeedKilometresPerHour)),
            ("treadmill_speed_increment_kmh", WorkoutAnalysisCSVStream.number(treadmill?.speedIncrementKilometresPerHour)),
            ("recorder_complete", String(session.recorderIsComplete)),
            ("lost_critical_record_count", String(session.lostCriticalRecordCount)),
            ("lost_native_record_count", String(session.lostNativeRecordCount)),
            ("analysis_quality_grade", analysis.flatMap {
                AnalysisQualityGrade(rawValue: $0.qualityGradeKey)?.rawValue
            } ?? ""),
            ("frame_row_count", String(frameRows)),
            ("event_row_count", String(eventRows)),
            ("heart_rate_frame_row_count", String(heartRateFrameRows)),
            ("heart_rate_frame_coverage_ratio", coverage(heartRateFrameRows, frameRows)),
            ("factual_speed_frame_row_count", String(factualSpeedFrameRows)),
            ("factual_speed_frame_coverage_ratio", coverage(factualSpeedFrameRows, frameRows)),
            ("gap_boundary_row_count", String(gapBoundaryRows)),
            ("quality_warnings", warnings.sorted().joined(separator: ";")),
            ("omitted_identifier_kinds", "profile;device;source;healthkit;raw-record;raw-command"),
        ]
    }

    static func analysisFileTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    static func coverage(_ available: Int, _ total: Int) -> String {
        guard total > 0 else { return "" }
        return WorkoutAnalysisCSVStream.number(Double(available) / Double(total))
    }

    static func reference(_ kind: String, _ raw: String, _ sessionID: SessionID) -> String {
        let digest = SHA256.hash(data: Data("\(sessionID.description)|\(kind)|\(raw)".utf8))
        return "\(kind)-\(digest.prefix(8).map { String(format: "%02x", $0) }.joined())"
    }

    static func phaseString(_ phase: WorkoutPhase?) -> String {
        guard let phase else { return "" }
        return switch phase {
        case .warmup: "warmup"
        case .main: "main"
        case .cooldown: "cooldown"
        case .finished: "finished"
        case .unknown: "unknown"
        case .other: "other"
        }
    }

    static func workoutModeString(_ mode: WorkoutMode?) -> String {
        guard let mode else { return "" }
        return switch mode {
        case .heartRateControlled: "heart-rate-controlled"
        case .manual: "manual"
        case .other: "other"
        }
    }

    static func targetHeartRate(_ target: ControlTarget) -> Int? {
        if case let .heartRate(beatsPerMinute) = target { return Int(beatsPerMinute) }
        return nil
    }

    static func controlAction(_ action: ControlAction) -> (name: String, desiredSpeed: Double?) {
        switch action {
        case .noCommand: ("hold", nil)
        case let .enqueueSpeed(speed): ("enqueue-speed", speed.value)
        case .enqueueStop: ("enqueue-stop", nil)
        }
    }

    static func controlReason(_ reason: ControlDecisionReason) -> String {
        switch reason {
        case .withinTarget: "within-target"
        case .belowTarget: "below-target"
        case .aboveTarget: "above-target"
        case .safetyGate: "safety-gate"
        case .manual: "manual"
        case let .other(value) where value == "inertiaHold": "inertia-hold"
        case let .other(value) where value == "speedLimit": "speed-limit"
        case .other: "other"
        }
    }

    static func commandLifecycle(
        _ lifecycle: CommandLifecycle
    ) -> (name: String, detail: String?, commandedValue: Double?, commandedUnit: String?, attemptNumber: Int?) {
        switch lifecycle {
        case let .enqueued(kind):
            let command = commandKind(kind)
            return (
                command.name,
                command.detail,
                command.commandedValue,
                command.commandedUnit,
                nil
            )
        case let .sendAttempt(_, attemptNumber):
            return ("command_send_attempt", nil, nil, nil, Int(attemptNumber))
        case .acknowledged:
            return ("command_acknowledged", nil, nil, nil, nil)
        case .timedOut:
            return ("command_timed_out", nil, nil, nil, nil)
        case let .retryScheduled(_, _, nextAttemptNumber):
            return ("command_retry_scheduled", nil, nil, nil, Int(nextAttemptNumber))
        case let .cancelled(reason):
            return ("command_cancelled", cancellationReason(reason), nil, nil, nil)
        case let .failed(_, reason):
            return ("command_failed", failureReason(reason), nil, nil, nil)
        }
    }

    static func commandKind(
        _ kind: CommandKind
    ) -> (name: String, detail: String?, commandedValue: Double?, commandedUnit: String?) {
        switch kind {
        case let .setSpeed(speed):
            (
                "command_enqueued_set_speed",
                nil,
                speed.nativeValue,
                nativeUnit(speed.nativeUnit)
            )
        case .stop:
            ("command_enqueued_stop", nil, nil, nil)
        case .other:
            ("command_enqueued_other", "opaque-command-kind", nil, nil)
        }
    }

    static func treadmillProtocol(_ value: TreadmillProtocolKind) -> String {
        switch value {
        case .walkingPad: "walkingpad"
        case .ftms: "ftms"
        case .fitShow: "fitshow"
        case .unknown: "unknown"
        }
    }

    static func writeType(_ value: TreadmillCommandWriteType) -> String {
        switch value {
        case .withResponse: "with-response"
        case .withoutResponse: "without-response"
        }
    }

    static func association(_ value: LegacyAcknowledgementAssociation) -> String {
        switch value {
        case .unresolvedByLegacyRuntime: "unresolved"
        case .deterministicallyCorrelated: "deterministic"
        }
    }

    static func nativeUnit(_ unit: TreadmillNativeSpeedUnit) -> String {
        switch unit {
        case .kilometresPerHour: "km/h"
        case .milesPerHour: "mph"
        case let .controllerNative(code):
            switch code {
            case "walkingpad_controller_tenths", "walkingPad-tenths", "tenths":
                "controller-native:walkingpad-tenths"
            case "ftms_hundredths_kmh":
                "controller-native:ftms-hundredths-kmh"
            case "fitshow_tenths_kmh":
                "controller-native:fitshow-tenths-kmh"
            default:
                "controller-native"
            }
        case .unknown: "unknown"
        }
    }

    static func cancellationReason(_ reason: CommandCancellationReason) -> String {
        switch reason {
        case .superseded: "superseded"
        case .sessionEnded: "session-ended"
        case .safetyGate: "safety-gate"
        case .other: "other"
        }
    }

    static func failureReason(_ reason: CommandFailureReason) -> String {
        switch reason {
        case .transportUnavailable: "transport-unavailable"
        case .encodingFailed: "encoding-failed"
        case .rejected: "rejected"
        case .other: "other"
        }
    }

    static func stopConclusion(_ conclusion: StopEvidenceConclusion) -> String {
        switch conclusion {
        case .confirmedByFreshFactualObservation: "confirmed-fresh-factual"
        case .unconfirmed: "unconfirmed"
        case .contradictory: "contradictory"
        }
    }

    static func lifecycleReason(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let allowed = [
            "authorized-start", "manual_stop", "ble_disconnected",
            "hr_control_not_ready", "hr_no_signal", "cooldown_stable_reached",
            "cooldown_timeout", "pre-recorder-staging-overflow",
            "recorder-cancelled", "recorder-terminated", "forced-process-interruption",
        ]
        return allowed.contains(rawValue) ? rawValue : "opaque-reason"
    }

    static func recorderRecordClass(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        return ["critical", "native", "bulkFrame", "all"].contains(rawValue)
            ? rawValue
            : "opaque-record-class"
    }

    static func recorderDetailCode(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        return rawValue == "pre-recorder-staging-overflow"
            ? rawValue
            : "opaque-detail-code"
    }

    static func analysisExclusionCode(_ rawValue: String) -> String {
        let allowed = [
            "recorderEvidenceLoss.recorder-loss",
            "protocolRuntimeCausalAmbiguity.unknown-command-ack-association",
            "protocolRuntimeCausalAmbiguity.unknown-command-factual-response-association",
            "malformedCorruptEvidence.unsupported-persisted-command-ack-causal-claim",
            "malformedCorruptEvidence.unsupported-persisted-command-factual-response-causal-claim",
            "sourceCoverageUnavailable.heart-rate-uncovered-time",
            "sourceCoverageUnavailable.factual-treadmill-uncovered-time",
            "sourceCoverageUnavailable.average-factual-speed-insufficient-coverage",
            "malformedCorruptEvidence.configuration-payload-unavailable",
            "malformedCorruptEvidence.malformed-or-invalid-native-evidence",
            "malformedCorruptEvidence.invalid-workout-phase-transition-evidence",
            "sourceCoverageUnavailable.incomplete-session",
        ]
        return allowed.contains(rawValue) ? rawValue : "opaque-analysis-exclusion"
    }
}

private extension WorkoutAnalysisCSVStream {
    func writeAnalysisFrame(
        _ frame: CanonicalFrame,
        sessionID: SessionID,
        phase: String,
        targetHeartRate: Int?
    ) throws {
        let heartRate = frame.heartRateEvidence
        let treadmill = frame.treadmillEvidence
        let treadmillAvailability: String
        if treadmill?.factualSpeed != nil {
            treadmillAvailability = "factual"
        } else if treadmill != nil {
            treadmillAvailability = "non-factual-evidence-only"
        } else {
            treadmillAvailability = "unavailable"
        }
        var quality: [String] = []
        if heartRate == nil { quality.append("heart-rate-unavailable") }
        if treadmill?.factualSpeed == nil { quality.append("factual-speed-unavailable") }
        if let gap = frame.precedingGap { quality.append("preceding-gap:\(gap.kind.rawValue)") }
        try writeTimeline(
            elapsedMicroseconds: frame.materializedAt.elapsed.microseconds,
            timestamp: frame.materializedAt.recordedAt,
            phase: phase,
            targetHeartRate: targetHeartRate,
            values: [
                "row_type": "frame",
                "hr_bpm": heartRate.map { String($0.beatsPerMinute) } ?? "",
                "hr_evidence_ref": heartRate.map {
                    TelemetryStore.reference("hr-evidence", $0.observationID.description, sessionID)
                } ?? "",
                "hr_evidence_elapsed_s": Self.seconds(heartRate?.evidenceElapsed.microseconds),
                "hr_age_s": Self.seconds(heartRate?.ageAtMaterialization.microseconds),
                "hr_freshness": heartRate?.freshness.rawValue ?? "",
                "hr_provenance": heartRate?.provenance.rawValue ?? "",
                "factual_speed_kmh": Self.number(treadmill?.factualSpeed?.value),
                "treadmill_evidence_ref": treadmill.map {
                    TelemetryStore.reference(
                        "treadmill-evidence", $0.observationID.description, sessionID
                    )
                } ?? "",
                "treadmill_evidence_elapsed_s": Self.seconds(treadmill?.evidenceElapsed.microseconds),
                "treadmill_age_s": Self.seconds(treadmill?.ageAtMaterialization.microseconds),
                "treadmill_freshness": treadmill?.freshness.rawValue ?? "",
                "treadmill_availability": treadmillAvailability,
                "treadmill_state": treadmill?.deviceState.rawValue ?? "",
                "treadmill_provenance": treadmill?.provenance.rawValue ?? "",
                "gap_missing_since_s": frame.precedingGap.map {
                    String($0.missingSinceElapsedSecond)
                } ?? "",
                "gap_kind": frame.precedingGap?.kind.rawValue ?? "",
                "quality_flags": quality.joined(separator: ";"),
            ]
        )
    }

    func writeAnalysisEvent(
        _ event: WorkoutAnalysisEventProjection,
        phase: String,
        targetHeartRate: Int?
    ) throws {
        try writeTimeline(
            elapsedMicroseconds: event.elapsedMicroseconds,
            timestamp: event.occurredAt,
            phase: phase,
            targetHeartRate: targetHeartRate,
            values: [
                "row_type": "event",
                "event_kind": event.kind,
                "event_name": event.name,
                "event_detail": event.detail ?? "",
                "decision_ref": event.decisionReference ?? "",
                "command_ref": event.commandReference ?? "",
                "attempt_ref": event.attemptReference ?? "",
                "configuration_ref": event.configurationReference ?? "",
                "decision_action": event.decisionAction ?? "",
                "decision_reason": event.decisionReason ?? "",
                "desired_speed_kmh": Self.number(event.desiredSpeedKilometresPerHour),
                "commanded_speed_native_value": Self.number(event.commandedSpeedNativeValue),
                "commanded_speed_native_unit": event.commandedSpeedNativeUnit ?? "",
                "command_attempt_number": event.commandAttemptNumber.map(String.init) ?? "",
            ]
        )
    }
}
