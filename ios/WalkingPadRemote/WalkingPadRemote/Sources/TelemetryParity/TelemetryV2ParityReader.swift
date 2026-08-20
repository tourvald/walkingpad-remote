import Foundation
import TelemetryDomain
import TelemetryPersistence
import TelemetryRuntime

public enum TelemetryV2ParityReaderError: Error, Equatable, Sendable {
    case sessionNotFound(SessionID)
    case invalidConfigurationSnapshot
}

public enum TelemetryV2ParityReader {
    public static func read(
        from store: TelemetryStore,
        sessionID: SessionID
    ) async throws -> TelemetryParitySessionEvidence {
        let sessions = try await store.fetchSessions()
        guard let session = sessions.first(where: { $0.sessionID == sessionID }) else {
            throw TelemetryV2ParityReaderError.sessionNotFound(sessionID)
        }
        let heartRate = try await store.fetchHeartRate(sessionID: sessionID)
        let treadmill = try await store.fetchTreadmill(sessionID: sessionID)
        let events = try await store.fetchEvents(sessionID: sessionID)
        let frames = try await store.fetchFrames(sessionID: sessionID)
        return try read(
            session: session,
            heartRate: heartRate,
            treadmill: treadmill,
            events: events,
            frames: frames
        )
    }

    public static func read(
        session: WorkoutSessionRecord,
        heartRate: [HeartRateObservation],
        treadmill: [TreadmillObservation],
        events: [WorkoutEvent],
        frames: [CanonicalFrame]
    ) throws -> TelemetryParitySessionEvidence {
        let decoder = JSONDecoder()
        guard let configuration = try? decoder.decode(
            TelemetryV2ConfigurationInput.self,
            from: session.configuration.canonicalPayload
        ) else {
            throw TelemetryV2ParityReaderError.invalidConfigurationSnapshot
        }

        let orderedEvents = events.sorted {
            if $0.timestamp.occurredElapsed != $1.timestamp.occurredElapsed {
                return $0.timestamp.occurredElapsed < $1.timestamp.occurredElapsed
            }
            return $0.recordID.description < $1.recordID.description
        }
        let lifecycleEvents = orderedEvents.compactMap { event -> SessionLifecycleEvent? in
            guard case let .sessionLifecycle(lifecycle) = event.payload.payload else { return nil }
            return lifecycle
        }
        let endReason = lifecycleEvents.last(where: {
            $0.current == .completed || $0.current == .incomplete || $0.current == .cancelled
        })?.reason ?? lifecycleEvents.last?.incompleteReason ?? session.incompleteReason

        let phases = orderedEvents.compactMap { event -> TelemetryParityPhaseEvidence? in
            guard case let .workoutPhase(transition) = event.payload.payload else { return nil }
            return TelemetryParityPhaseEvidence(
                phase: phaseName(transition.current),
                elapsedMilliseconds: milliseconds(event.timestamp.occurredElapsed)
            )
        }
        let deliveryHeartRate = orderedEvents.compactMap { event -> TelemetryParityHeartRateEvidence? in
            guard case let .heartRateEvidence(.delivery(result)) = event.payload.payload else {
                return nil
            }
            return TelemetryParityHeartRateEvidence(
                elapsedMilliseconds: milliseconds(event.timestamp.occurredElapsed),
                receivedAt: result.delivery.receivedAt,
                beatsPerMinute: result.delivery.beatsPerMinute,
                acceptedForControl: result.delivery.acceptedIntoLegacyControllerState,
                arrivalOrder: result.delivery.arrivalOrder
            )
        }
        let mappedHeartRate = deliveryHeartRate.isEmpty ? heartRate.map {
            TelemetryParityHeartRateEvidence(
                elapsedMilliseconds: milliseconds($0.timestamp.receivedElapsed),
                receivedAt: $0.timestamp.receivedAt,
                beatsPerMinute: Int($0.beatsPerMinute),
                acceptedForControl: $0.controlUse.acceptedForControl,
                arrivalOrder: $0.arrivalOrder
            )
        } : deliveryHeartRate
        let mappedTreadmill = treadmill.map {
            TelemetryParityTreadmillFact(
                elapsedMilliseconds: milliseconds($0.timestamp.receivedElapsed),
                nativeValue: $0.nativeSpeed.value,
                nativeUnit: nativeUnitName($0.nativeSpeed.unit),
                factualSpeedKilometresPerHour: $0.factualSpeed?.value,
                deviceState: $0.deviceState.rawValue
            )
        }
        let decisions = orderedEvents.compactMap(decisionEvidence)
        let commandEvidence = commandEvidence(from: orderedEvents)
        let stops = orderedEvents.compactMap(stopEvidence)
        let integrity = integrityEvidence(
            session: session,
            heartRate: heartRate,
            treadmill: treadmill,
            events: events,
            frames: frames
        )
        let completeness: TelemetryParityCompleteness = session.lifecycleState == .completed
            && session.recorderHealth.isComplete ? .complete : .incomplete

        return TelemetryParitySessionEvidence(
            origin: .telemetryV2,
            sessionIdentifier: session.sessionID.description,
            linkedLegacySessionIdentifier: session.sessionID.description,
            completeness: completeness,
            lifecycle: TelemetryParityLifecycleEvidence(
                startedAt: session.startedAt,
                endedAt: session.endedAt,
                endReason: endReason,
                durationMilliseconds: session.endedElapsed.map(milliseconds)
            ),
            heartRate: mappedHeartRate,
            phases: phases,
            configuration: TelemetryParityConfigurationEvidence(
                targetHeartRate: configuration.targetHeartRate,
                durationSeconds: configuration.durationMinutes * 60,
                decisionIntervalSeconds: configuration.decisionIntervalSeconds,
                adaptiveStepEnabled: configuration.adaptiveStepEnabled,
                maximumStepKilometresPerHour: configuration.maximumStepKilometresPerHour,
                heartRateZoneUpperBounds: configuration.heartRateZones,
                cooldownTargetHeartRate: configuration.cooldownTargetHeartRate,
                cooldownMinimumSpeedKilometresPerHour: configuration.cooldownMinimumSpeedKilometresPerHour,
                cooldownMaximumSeconds: configuration.cooldownMaximumMinutes * 60,
                telemetrySchemaVersion: session.versions.telemetrySchema.rawValue,
                algorithmVersion: session.versions.algorithm.rawValue,
                safetyPolicyVersion: session.versions.safetyPolicy.rawValue,
                workoutProtocolVersion: session.versions.workoutProtocol.rawValue
            ),
            decisions: decisions,
            treadmillFacts: mappedTreadmill,
            commandEvidence: commandEvidence,
            aggregates: nil,
            stopEvidence: stops,
            integrity: integrity,
            limitations: []
        )
    }

    private static func decisionEvidence(
        _ event: WorkoutEvent
    ) -> TelemetryParityDecisionEvidence? {
        switch event.payload.payload {
        case let .treadmillEvidence(.decision(decision)):
            let mapped = mappedDecisionIntent(decision.intent)
            return TelemetryParityDecisionEvidence(
                domain: decision.source == .heartRateControl
                    ? .heartRateControl
                    : .outsideHeartRateControl,
                source: decision.source.rawValue,
                action: mapped.action,
                desiredSpeedKilometresPerHour: mapped.speed,
                elapsedMilliseconds: milliseconds(event.timestamp.occurredElapsed)
            )
        case let .controlDecision(decision):
            let mapped = mappedControlAction(decision.action)
            return TelemetryParityDecisionEvidence(
                domain: .unclassified,
                source: "controlDecision",
                action: mapped.action,
                desiredSpeedKilometresPerHour: mapped.speed,
                elapsedMilliseconds: milliseconds(event.timestamp.occurredElapsed)
            )
        default:
            return nil
        }
    }

    private static func commandEvidence(
        from events: [WorkoutEvent]
    ) -> [TelemetryParityCommandEvidence] {
        var semanticCommands: [String: String] = [:]
        for event in events {
            switch event.payload.payload {
            case let .treadmillEvidence(.commandEnqueued(enqueued)):
                semanticCommands[enqueued.commandID.description] = semanticCommand(enqueued.kind)
            case let .commandLifecycle(record):
                if case let .enqueued(kind) = record.lifecycle {
                    semanticCommands[record.commandID.description] = semanticCommand(kind)
                }
            default:
                break
            }
        }

        var result: [TelemetryParityCommandEvidence] = []

        for event in events {
            let elapsedMilliseconds = milliseconds(event.timestamp.occurredElapsed)
            switch event.payload.payload {
            case let .treadmillEvidence(.commandEnqueued(enqueued)):
                semanticCommands[enqueued.commandID.description] = semanticCommand(enqueued.kind)
            case let .treadmillEvidence(.sendAttempt(attempt)):
                result.append(
                    TelemetryParityCommandEvidence(
                        outcomeKind: .sent,
                        semanticCommand: semanticCommands[attempt.commandID.description],
                        elapsedMilliseconds: elapsedMilliseconds,
                        association: .deterministicallyCorrelated,
                        commandIdentifier: attempt.commandID.description,
                        attemptIdentifier: attempt.attemptID.description
                    )
                )
            case let .treadmillEvidence(.acknowledgement(acknowledgement)):
                result.append(
                    causalOutcome(
                        kind: .acknowledgement,
                        association: acknowledgement.association,
                        elapsedMilliseconds: elapsedMilliseconds
                    )
                )
            case let .treadmillEvidence(.commandTimeout(timeout)):
                result.append(
                    causalOutcome(
                        kind: .timeout,
                        association: timeout.association,
                        elapsedMilliseconds: elapsedMilliseconds
                    )
                )
            case let .treadmillEvidence(.writeResult(writeResult)):
                result.append(
                    causalOutcome(
                        kind: .writeResult,
                        association: writeResult.association,
                        elapsedMilliseconds: elapsedMilliseconds
                    )
                )
            case let .treadmillEvidence(.observation(observation)):
                switch observation.responseAssociation {
                case .unassociated:
                    result.append(
                        TelemetryParityCommandEvidence(
                            outcomeKind: .observedResponse,
                            semanticCommand: nil,
                            elapsedMilliseconds: elapsedMilliseconds,
                            association: .unknown,
                            commandIdentifier: nil,
                            attemptIdentifier: nil
                        )
                    )
                case let .deterministicallyCorrelated(commandID, attemptID):
                    result.append(
                        TelemetryParityCommandEvidence(
                            outcomeKind: .observedResponse,
                            semanticCommand: semanticCommands[commandID.description],
                            elapsedMilliseconds: elapsedMilliseconds,
                            association: .deterministicallyCorrelated,
                            commandIdentifier: commandID.description,
                            attemptIdentifier: attemptID.description
                        )
                    )
                }
            case let .commandLifecycle(record):
                result.append(
                    contentsOf: genericCommandEvidence(
                        record,
                        semanticCommand: semanticCommands[record.commandID.description],
                        elapsedMilliseconds: elapsedMilliseconds
                    )
                )
            default:
                break
            }
        }
        return result
    }

    private static func causalOutcome(
        kind: TelemetryParityCommandOutcomeKind,
        association: LegacyAcknowledgementAssociation,
        elapsedMilliseconds: Int64
    ) -> TelemetryParityCommandEvidence {
        switch association {
        case .unresolvedByLegacyRuntime:
            return TelemetryParityCommandEvidence(
                outcomeKind: kind,
                semanticCommand: nil,
                elapsedMilliseconds: elapsedMilliseconds,
                association: .unknown,
                commandIdentifier: nil,
                attemptIdentifier: nil
            )
        case let .deterministicallyCorrelated(commandID, attemptID):
            return TelemetryParityCommandEvidence(
                outcomeKind: kind,
                semanticCommand: nil,
                elapsedMilliseconds: elapsedMilliseconds,
                association: .deterministicallyCorrelated,
                commandIdentifier: commandID.description,
                attemptIdentifier: attemptID.description
            )
        }
    }

    private static func genericCommandEvidence(
        _ record: CommandLifecycleRecord,
        semanticCommand: String?,
        elapsedMilliseconds: Int64
    ) -> [TelemetryParityCommandEvidence] {
        switch record.lifecycle {
        case .enqueued:
            return []
        case let .sendAttempt(attemptID, _):
            return [
                TelemetryParityCommandEvidence(
                    outcomeKind: .sent,
                    semanticCommand: semanticCommand,
                    elapsedMilliseconds: elapsedMilliseconds,
                    association: .deterministicallyCorrelated,
                    commandIdentifier: record.commandID.description,
                    attemptIdentifier: attemptID.description
                )
            ]
        case let .acknowledged(attemptID):
            return [unsupportedGenericOutcome(.acknowledgement, record, attemptID, elapsedMilliseconds)]
        case let .timedOut(attemptID):
            return [unsupportedGenericOutcome(.timeout, record, attemptID, elapsedMilliseconds)]
        default:
            return []
        }
    }

    private static func unsupportedGenericOutcome(
        _ kind: TelemetryParityCommandOutcomeKind,
        _ record: CommandLifecycleRecord,
        _ attemptID: CommandAttemptID,
        _ elapsedMilliseconds: Int64
    ) -> TelemetryParityCommandEvidence {
        TelemetryParityCommandEvidence(
            outcomeKind: kind,
            semanticCommand: nil,
            elapsedMilliseconds: elapsedMilliseconds,
            association: .deterministicallyCorrelated,
            commandIdentifier: record.commandID.description,
            attemptIdentifier: attemptID.description
        )
    }

    private static func stopEvidence(_ event: WorkoutEvent) -> TelemetryParityStopEvidence? {
        let conclusion: StopEvidenceConclusion
        switch event.payload.payload {
        case let .treadmillEvidence(.stopEvidence(stop)):
            conclusion = stop.conclusion
        case let .stopEvidence(stop):
            conclusion = stop.conclusion
        default:
            return nil
        }
        switch conclusion {
        case let .confirmedByFreshFactualObservation(observationID):
            return TelemetryParityStopEvidence(
                conclusion: "confirmed",
                factualObservationIdentifier: observationID.description,
                elapsedMilliseconds: milliseconds(event.timestamp.occurredElapsed)
            )
        case .unconfirmed:
            return TelemetryParityStopEvidence(
                conclusion: "unconfirmed",
                factualObservationIdentifier: nil,
                elapsedMilliseconds: milliseconds(event.timestamp.occurredElapsed)
            )
        case .contradictory:
            return TelemetryParityStopEvidence(
                conclusion: "contradictory",
                factualObservationIdentifier: nil,
                elapsedMilliseconds: milliseconds(event.timestamp.occurredElapsed)
            )
        }
    }

    private static func integrityEvidence(
        session: WorkoutSessionRecord,
        heartRate: [HeartRateObservation],
        treadmill: [TreadmillObservation],
        events: [WorkoutEvent],
        frames: [CanonicalFrame]
    ) -> TelemetryParityIntegrityEvidence {
        let identifiers = [session.recordID.description]
            + heartRate.map { $0.recordID.description }
            + treadmill.map { $0.recordID.description }
            + events.map { $0.recordID.description }
            + frames.map { $0.recordID.description }
        let duplicateIdentifiers = identifiers.count - Set(identifiers).count
        let outOfOrder = outOfOrderCount(heartRate.map(\.arrivalOrder))
            + outOfOrderCount(treadmill.map(\.arrivalOrder))
            + zip(events, events.dropFirst()).filter {
                $0.timestamp.occurredElapsed > $1.timestamp.occurredElapsed
            }.count
        let frameSeconds = frames.map(\.canonicalElapsedSecond)
        let duplicateSeconds = frameSeconds.count - Set(frameSeconds).count
        let sortedFrames = frames.sorted { $0.canonicalElapsedSecond < $1.canonicalElapsedSecond }
        var unexplainedGaps = 0
        for (index, frame) in sortedFrames.enumerated() {
            let expected = index == 0 ? 0 : sortedFrames[index - 1].canonicalElapsedSecond + 1
            if frame.canonicalElapsedSecond > expected && frame.precedingGap == nil {
                unexplainedGaps += 1
            }
        }
        return TelemetryParityIntegrityEvidence(
            duplicateRecordIdentifierCount: duplicateIdentifiers,
            outOfOrderRecordCount: outOfOrder,
            duplicateCanonicalSecondCount: duplicateSeconds,
            unexplainedFrameGapCount: unexplainedGaps,
            lostCriticalRecordCount: session.recorderHealth.lostCriticalRecordCount,
            lostNativeRecordCount: session.recorderHealth.lostNativeRecordCount
        )
    }

    private static func mappedDecisionIntent(
        _ intent: TreadmillControlDecisionIntent
    ) -> (action: String, speed: Double?) {
        switch intent {
        case let .startAtDesiredSpeed(speed): ("start", speed.value)
        case let .setDesiredSpeed(speed): ("setSpeed", speed.value)
        case .stop: ("stop", nil)
        case .hold: ("hold", nil)
        case .requestControl: ("requestControl", nil)
        case .queryControllerUnits: ("queryControllerUnits", nil)
        case let .other(value): (value, nil)
        }
    }

    private static func mappedControlAction(_ action: ControlAction) -> (action: String, speed: Double?) {
        switch action {
        case .noCommand: ("hold", nil)
        case let .enqueueSpeed(speed): ("setSpeed", speed.value)
        case .enqueueStop: ("stop", nil)
        }
    }

    private static func semanticCommand(_ kind: CommandKind) -> String {
        switch kind {
        case .setSpeed: "setSpeed"
        case .stop: "stop"
        case let .other(value): value
        }
    }

    private static func phaseName(_ phase: WorkoutPhase) -> String {
        switch phase {
        case .warmup: "warmup"
        case .main: "main"
        case .cooldown: "cooldown"
        case .finished: "finished"
        case .unknown: "unknown"
        case let .other(value): value
        }
    }

    private static func nativeUnitName(_ unit: TreadmillNativeSpeedUnit) -> String {
        switch unit {
        case .kilometresPerHour: "kilometres_per_hour"
        case .milesPerHour: "miles_per_hour"
        case let .controllerNative(code):
            code == "walkingPad-tenths"
                ? "walkingpad_controller_tenths"
                : code.map { "controller_native:\($0)" } ?? "controller_native"
        case .unknown: "unknown"
        }
    }

    private static func outOfOrderCount<T: Comparable>(_ values: [T]) -> Int {
        zip(values, values.dropFirst()).filter { pair in pair.0 >= pair.1 }.count
    }

    private static func milliseconds(_ elapsed: ElapsedDuration) -> Int64 {
        elapsed.microseconds / 1_000
    }
}
