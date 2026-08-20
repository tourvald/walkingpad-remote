import Foundation
import XCTest
@testable import TelemetryDomain

final class TreadmillTruthTests: XCTestCase {
    private let receivedAt = Date(timeIntervalSince1970: 1_700_000_100)
    private let recordedAt = Date(timeIntervalSince1970: 1_700_000_101)

    func testWalkingPadMetricTruthNormalizesRawTenthsInCurrentEpoch() throws {
        let epoch = connectionEpoch(1)
        var normalizer = TreadmillObservationNormalizer()

        let evidence = normalizer.normalize(
            .walkingPad(
                speedRawTenths: 37,
                rawState: 1,
                deviceState: .moving,
                checksumValid: true,
                connectionEpoch: epoch,
                receivedAt: receivedAt
            ),
            unitsTruth: .valid(
                unit: .kilometresPerHour,
                connectionEpoch: epoch,
                observedAt: receivedAt.addingTimeInterval(-1)
            ),
            observationID: observationID(1),
            recordedAt: recordedAt
        )

        XCTAssertEqual(evidence.nativeSpeed?.rawValue, 37)
        XCTAssertEqual(evidence.nativeSpeed?.resolution, .tenths)
        XCTAssertEqual(evidence.nativeSpeed?.unit, .controllerUnit)
        XCTAssertEqual(try XCTUnwrap(evidence.factualSpeed).value, 3.7, accuracy: 0.000_001)
        XCTAssertEqual(evidence.measuredAt, nil)
        XCTAssertEqual(evidence.connectionEpoch, epoch)
    }

    func testWalkingPadImperialTruthNormalizesThroughExplicitPhysicalUnit() throws {
        let epoch = connectionEpoch(2)
        var normalizer = TreadmillObservationNormalizer()
        let evidence = normalizer.normalize(
            .walkingPad(
                speedRawTenths: 25,
                rawState: 1,
                deviceState: .moving,
                checksumValid: true,
                connectionEpoch: epoch,
                receivedAt: receivedAt
            ),
            unitsTruth: .valid(
                unit: .milesPerHour,
                connectionEpoch: epoch,
                observedAt: receivedAt
            ),
            observationID: observationID(2),
            recordedAt: recordedAt
        )

        XCTAssertEqual(
            try XCTUnwrap(evidence.factualSpeed).value,
            2.5 * 1.609_344,
            accuracy: 0.000_001
        )
        XCTAssertEqual(evidence.quality.values, [.missingMeasurementTime])
    }

    func testWalkingPadUnknownStaleMalformedAndOldEpochTruthNeverNormalizes() {
        let currentEpoch = connectionEpoch(3)
        let oldEpoch = connectionEpoch(4)
        let input = TreadmillProviderObservation.walkingPad(
            speedRawTenths: 42,
            rawState: 1,
            deviceState: .moving,
            checksumValid: true,
            connectionEpoch: currentEpoch,
            receivedAt: receivedAt
        )
        let cases: [(TreadmillUnitsTruth, TreadmillObservationQualityFlag)] = [
            (.unknown(connectionEpoch: currentEpoch), .unitsUnknown),
            (
                .valid(
                    unit: .kilometresPerHour,
                    connectionEpoch: currentEpoch,
                    observedAt: receivedAt.addingTimeInterval(-31)
                ),
                .unitsStale
            ),
            (.malformed(connectionEpoch: currentEpoch), .unitsMalformed),
            (.invalidChecksum(connectionEpoch: currentEpoch), .unitsInvalidChecksum),
            (
                .valid(
                    unit: .kilometresPerHour,
                    connectionEpoch: oldEpoch,
                    observedAt: receivedAt
                ),
                .unitsEpochMismatch
            ),
        ]

        for (index, testCase) in cases.enumerated() {
            var normalizer = TreadmillObservationNormalizer()
            let evidence = normalizer.normalize(
                input,
                unitsTruth: testCase.0,
                observationID: observationID(10 + index),
                recordedAt: recordedAt
            )
            XCTAssertNil(evidence.factualSpeed)
            XCTAssertTrue(evidence.quality.contains(testCase.1))
            XCTAssertEqual(evidence.nativeSpeed?.rawValue, 42)
        }
    }

    func testChecksumFailureAndMissingSpeedPreserveEvidenceWithoutFactualSpeed() {
        let epoch = connectionEpoch(5)
        let units = TreadmillUnitsTruth.valid(
            unit: .kilometresPerHour,
            connectionEpoch: epoch,
            observedAt: receivedAt
        )
        var normalizer = TreadmillObservationNormalizer()

        let invalidChecksum = normalizer.normalize(
            .walkingPad(
                speedRawTenths: 10,
                rawState: 1,
                deviceState: .moving,
                checksumValid: false,
                connectionEpoch: epoch,
                receivedAt: receivedAt
            ),
            unitsTruth: units,
            observationID: observationID(20),
            recordedAt: recordedAt
        )
        let missingSpeed = normalizer.normalize(
            .walkingPad(
                speedRawTenths: nil,
                rawState: 0,
                deviceState: .stopped,
                checksumValid: true,
                connectionEpoch: epoch,
                receivedAt: receivedAt
            ),
            unitsTruth: units,
            observationID: observationID(21),
            recordedAt: recordedAt
        )

        XCTAssertEqual(invalidChecksum.nativeSpeed?.rawValue, 10)
        XCTAssertNil(invalidChecksum.factualSpeed)
        XCTAssertTrue(invalidChecksum.quality.contains(.invalidChecksum))
        XCTAssertNil(missingSpeed.nativeSpeed)
        XCTAssertNil(missingSpeed.factualSpeed)
        XCTAssertTrue(missingSpeed.quality.contains(.missingSpeed))
    }

    func testFtmsAndFitShowPreserveProtocolNativeSemantics() throws {
        let epoch = connectionEpoch(6)
        var normalizer = TreadmillObservationNormalizer()

        let ftms = normalizer.normalize(
            .ftms(
                speedRawHundredthsKmh: 425,
                rawState: nil,
                deviceState: .moving,
                connectionEpoch: epoch,
                receivedAt: receivedAt
            ),
            unitsTruth: nil,
            observationID: observationID(30),
            recordedAt: recordedAt
        )
        let invalidFitShow = normalizer.normalize(
            .fitShow(
                speedRawTenthsKmh: 32,
                rawState: 1,
                deviceState: .moving,
                checksumValid: false,
                connectionEpoch: epoch,
                receivedAt: receivedAt
            ),
            unitsTruth: nil,
            observationID: observationID(31),
            recordedAt: recordedAt
        )

        XCTAssertEqual(ftms.nativeSpeed?.resolution, .hundredths)
        XCTAssertEqual(ftms.nativeSpeed?.unit, .kilometresPerHour)
        XCTAssertEqual(try XCTUnwrap(ftms.factualSpeed).value, 4.25, accuracy: 0.000_001)
        XCTAssertEqual(invalidFitShow.nativeSpeed?.rawValue, 32)
        XCTAssertNil(invalidFitShow.factualSpeed)
        XCTAssertTrue(invalidFitShow.quality.contains(.invalidChecksum))
    }

    func testUnknownProtocolRemainsUnknownAndDoesNotFabricateSpeed() {
        let epoch = connectionEpoch(7)
        var normalizer = TreadmillObservationNormalizer()
        let evidence = normalizer.normalize(
            .unknown(connectionEpoch: epoch, receivedAt: receivedAt),
            unitsTruth: nil,
            observationID: observationID(40),
            recordedAt: recordedAt
        )

        XCTAssertEqual(evidence.protocolKind, .unknown)
        XCTAssertNil(evidence.nativeSpeed)
        XCTAssertNil(evidence.factualSpeed)
        XCTAssertTrue(evidence.quality.contains(.unsupportedProtocol))
    }

    func testDesiredCommandedAndEstimatedValuesCannotPopulateFactualObservation() {
        let snapshot = TreadmillSpeedSemanticsSnapshot(
            desired: DesiredSpeedKilometresPerHour(value: 4.0),
            commanded: CommandedSpeed(nativeValue: 40, nativeUnit: .controllerNative(code: "tenths")),
            controllerReportedTarget: nil,
            expectedEstimate: EstimatedSpeedKilometresPerHour(
                value: 4.0,
                method: "legacy-label-expected-speed",
                version: "v1"
            ),
            modeledEstimate: EstimatedSpeedKilometresPerHour(
                value: 3.4,
                method: "legacy-one-second-ramp",
                version: "v1"
            )
        )

        XCTAssertEqual(snapshot.desired?.value, 4.0)
        XCTAssertEqual(snapshot.commanded?.nativeValue, 40)
        XCTAssertEqual(snapshot.expectedEstimate?.value, 4.0)
        XCTAssertEqual(snapshot.modeledEstimate?.value, 3.4)
        // There is intentionally no factual-speed field on this non-observation type.
    }

    func testProtocolNativeCommandedSpeedsPreserveWireScaleWithoutUnitInference() {
        let walkingPad = TreadmillCommandedSpeedRepresentation.walkingPad(
            rawControllerTenths: 40
        )
        let ftms = TreadmillCommandedSpeedRepresentation.ftms(rawHundredthsKmh: 400)
        let fitShow = TreadmillCommandedSpeedRepresentation.fitShow(rawTenthsKmh: 40)

        XCTAssertEqual(walkingPad.nativeValue, 40)
        XCTAssertEqual(
            walkingPad.nativeUnit,
            .controllerNative(code: "walkingpad_controller_tenths")
        )
        XCTAssertEqual(ftms.nativeValue, 400)
        XCTAssertEqual(ftms.nativeUnit, .controllerNative(code: "ftms_hundredths_kmh"))
        XCTAssertEqual(fitShow.nativeValue, 40)
        XCTAssertEqual(fitShow.nativeUnit, .controllerNative(code: "fitshow_tenths_kmh"))
    }

    func testWalkingPadCommandRepresentationNeverBorrowsUnitsTruth() {
        let metric = TreadmillCommandedSpeedRepresentation.walkingPad(
            rawControllerTenths: 55
        )
        let imperialOrUnknown = TreadmillCommandedSpeedRepresentation.walkingPad(
            rawControllerTenths: 55
        )

        XCTAssertEqual(metric, imperialOrUnknown)
        XCTAssertEqual(
            metric.nativeUnit,
            .controllerNative(code: "walkingpad_controller_tenths")
        )
        XCTAssertNil(
            FactualSpeedKilometresPerHour.normalized(
                from: NativeTreadmillSpeed(
                    value: metric.nativeValue,
                    unit: metric.nativeUnit
                ),
                provenance: .decodedDeviceReport
            )
        )
    }

    func testArrivalOrderIsMonotonicWithinNormalizerAndRestartsOnlyWithNewInstance() {
        let epoch = connectionEpoch(8)
        var normalizer = TreadmillObservationNormalizer()
        let first = normalizer.normalize(
            .ftms(
                speedRawHundredthsKmh: 100,
                rawState: nil,
                deviceState: .moving,
                connectionEpoch: epoch,
                receivedAt: receivedAt
            ),
            unitsTruth: nil,
            observationID: observationID(50),
            recordedAt: recordedAt
        )
        let second = normalizer.normalize(
            .ftms(
                speedRawHundredthsKmh: 110,
                rawState: nil,
                deviceState: .moving,
                connectionEpoch: epoch,
                receivedAt: receivedAt
            ),
            unitsTruth: nil,
            observationID: observationID(51),
            recordedAt: recordedAt
        )

        XCTAssertEqual(first.arrivalOrder, 1)
        XCTAssertEqual(second.arrivalOrder, 2)
    }

    func testFactualResponseAssociationRequiresOpaqueProofAndMatchingConnectionEpoch() throws {
        let epoch = connectionEpoch(9)
        var normalizer = TreadmillObservationNormalizer()
        let observation = normalizer.normalize(
            .ftms(
                speedRawHundredthsKmh: 420,
                rawState: nil,
                deviceState: .moving,
                connectionEpoch: epoch,
                receivedAt: receivedAt
            ),
            unitsTruth: nil,
            observationID: observationID(60),
            recordedAt: recordedAt
        )
        let commandID = CommandID(rawValue: uuid(61))
        let attemptID = CommandAttemptID(rawValue: uuid(62))
        let attempt = TreadmillCommandSendAttemptEvidence(
            commandID: commandID,
            decisionID: nil,
            attemptID: attemptID,
            attemptNumber: 1,
            protocolKind: .ftms,
            connectionEpoch: epoch,
            sentAt: receivedAt.addingTimeInterval(-1),
            writeType: .withResponse
        )
        let proof = TreadmillDeterministicResponseProof(evidenceKey: uuid(63))

        XCTAssertEqual(observation.responseAssociation, .unassociated)
        let associated = try XCTUnwrap(
            TreadmillObservationEvidence.deterministicallyAssociated(
                observation,
                sendAttempt: attempt,
                proof: proof
            )
        )
        XCTAssertEqual(associated.commandID, commandID)
        XCTAssertEqual(associated.attemptID, attemptID)

        let wrongEpochAttempt = TreadmillCommandSendAttemptEvidence(
            commandID: commandID,
            decisionID: nil,
            attemptID: attemptID,
            attemptNumber: 1,
            protocolKind: .ftms,
            connectionEpoch: connectionEpoch(10),
            sentAt: receivedAt.addingTimeInterval(-1),
            writeType: .withResponse
        )
        XCTAssertNil(TreadmillObservationEvidence.deterministicallyAssociated(
            observation,
            sendAttempt: wrongEpochAttempt,
            proof: proof
        ))
    }

    private func connectionEpoch(_ value: UInt8) -> TreadmillConnectionEpoch {
        TreadmillConnectionEpoch(rawValue: uuid(value))
    }

    private func observationID(_ value: Int) -> ObservationID {
        ObservationID(rawValue: uuid(UInt8(truncatingIfNeeded: value)))
    }

    private func uuid(_ value: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
    }
}

final class TreadmillCommandDecisionTests: XCTestCase {
    private let epochA = TreadmillConnectionEpoch(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
    )
    private let epochB = TreadmillConnectionEpoch(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000b2")!
    )
    private let receivedAt = Date(timeIntervalSince1970: 1_700_001_000)

    // PM decision test 1: legacy scheduling may send two commands before an ACK.
    func testTwoSendAttemptsRemainIndependentBeforeOneAcknowledgementSignal() {
        var ledger = TreadmillCommandEvidenceLedger()
        let first = attempt(command: 1, attempt: 11, epoch: epochA, number: 1)
        let second = attempt(command: 2, attempt: 22, epoch: epochA, number: 1)
        ledger.recordSendAttempt(first)
        ledger.recordSendAttempt(second)

        XCTAssertEqual(ledger.state(for: first.attemptID), .sent)
        XCTAssertEqual(ledger.state(for: second.attemptID), .sent)
        XCTAssertEqual(ledger.attemptCount, 2)
    }

    // PM decision test 2: ambiguous ACK is factual but has no causal IDs.
    func testAmbiguousAcknowledgementHasNilCausalIDsAndExplicitUnknownAssociation() {
        let ack = LegacyAcknowledgementObservation.unresolved(
            protocolKind: .walkingPad,
            connectionEpoch: epochA,
            receivedAt: receivedAt,
            recordedAt: receivedAt
        )

        XCTAssertEqual(ack.association, .unresolvedByLegacyRuntime)
        XCTAssertNil(ack.commandID)
        XCTAssertNil(ack.attemptID)
    }

    // PM decision test 3: neither latest nor oldest command is selected heuristically.
    func testUnresolvedAcknowledgementDoesNotChooseLatestOrOldestCommand() {
        var ledger = TreadmillCommandEvidenceLedger()
        let first = attempt(command: 3, attempt: 31, epoch: epochA, number: 1)
        let second = attempt(command: 4, attempt: 41, epoch: epochA, number: 1)
        ledger.recordSendAttempt(first)
        ledger.recordSendAttempt(second)
        let ack = LegacyAcknowledgementObservation.unresolved(
            protocolKind: .ftms,
            connectionEpoch: epochA,
            receivedAt: receivedAt,
            recordedAt: receivedAt
        )

        ledger.observeAcknowledgement(ack)

        XCTAssertEqual(ledger.state(for: first.attemptID), .sent)
        XCTAssertEqual(ledger.state(for: second.attemptID), .sent)
    }

    // PM decision test 4: unknown ACK never completes an attempt.
    func testUnassociatedAcknowledgementDoesNotMutateAttemptEvidenceState() {
        var ledger = TreadmillCommandEvidenceLedger()
        let send = attempt(command: 5, attempt: 51, epoch: epochA, number: 1)
        ledger.recordSendAttempt(send)
        ledger.observeAcknowledgement(
            .unresolved(
                protocolKind: .fitShow,
                connectionEpoch: epochA,
                receivedAt: receivedAt,
                recordedAt: receivedAt
            )
        )

        XCTAssertEqual(ledger.state(for: send.attemptID), .sent)
    }

    // PM decision test 5: every sink disposition leaves the legacy trace identical.
    func testTelemetryDispositionCannotChangeLegacyBytesOrderTimingTimeoutOrRetryTrace() {
        let dispositions: [TreadmillTelemetrySinkDisposition?] = [
            .accepted,
            .degraded,
            .rejected,
            nil,
        ]

        let traces = dispositions.map { disposition -> LegacyTrace in
            var trace = LegacyTrace()
            TreadmillObservationalTee.afterLegacyAction(
                {
                    trace.bytes = [[0x02], [0x02, 0x90, 0x01]]
                    trace.sendOffsets = [0.0, 0.25]
                    trace.timeoutOffsets = [3.0]
                    trace.retryOffsets = [3.25]
                    trace.target = 4.0
                    trace.stopConfirmed = false
                },
                observe: disposition.map { value in { value } }
            )
            return trace
        }

        XCTAssertTrue(traces.dropFirst().allSatisfy { $0 == traces[0] })
    }

    // PM decision test 6: an ACK cannot attach across a reconnect epoch.
    func testConnectionEpochChangePreventsDeterministicAssociation() {
        let send = attempt(command: 6, attempt: 61, epoch: epochA, number: 1)

        XCTAssertNil(
            LegacyAcknowledgementObservation.deterministicallyAssociated(
                protocolKind: .walkingPad,
                connectionEpoch: epochB,
                receivedAt: receivedAt,
                recordedAt: receivedAt,
                sendAttempt: send,
                proof: TreadmillDeterministicAcknowledgementProof(evidenceKey: uuid(60))
            )
        )
    }

    // PM decision test 7: a proven same-epoch edge remains typed and precise.
    func testIndependentSameEpochProofCanCreateKnownAssociation() throws {
        let send = attempt(command: 7, attempt: 71, epoch: epochA, number: 1)
        let ack = try XCTUnwrap(
            LegacyAcknowledgementObservation.deterministicallyAssociated(
                protocolKind: .ftms,
                connectionEpoch: epochA,
                receivedAt: receivedAt,
                recordedAt: receivedAt,
                sendAttempt: send,
                proof: TreadmillDeterministicAcknowledgementProof(evidenceKey: uuid(70))
            )
        )

        XCTAssertEqual(ack.commandID, send.commandID)
        XCTAssertEqual(ack.attemptID, send.attemptID)
        XCTAssertEqual(
            ack.association,
            .deterministicallyCorrelated(commandID: send.commandID, attemptID: send.attemptID)
        )
    }

    // PM decision test 8: replay cannot backfill an unknown edge during Codable round-trip.
    func testUnknownAssociationRoundTripStaysUnknownWithoutCausalIDs() throws {
        let ack = LegacyAcknowledgementObservation.unresolved(
            protocolKind: .walkingPad,
            connectionEpoch: epochA,
            receivedAt: receivedAt,
            recordedAt: receivedAt
        )
        let decoded = try JSONDecoder().decode(
            LegacyAcknowledgementObservation.self,
            from: JSONEncoder().encode(ack)
        )

        XCTAssertEqual(decoded, ack)
        XCTAssertEqual(decoded.association, .unresolvedByLegacyRuntime)
        XCTAssertNil(decoded.commandID)
        XCTAssertNil(decoded.attemptID)
    }

    func testLegacyRetryUsesOneCommandWithDistinctAttempts() {
        let first = attempt(command: 8, attempt: 81, epoch: epochA, number: 1)
        let retry = attempt(command: 8, attempt: 82, epoch: epochA, number: 2)

        XCTAssertEqual(first.commandID, retry.commandID)
        XCTAssertNotEqual(first.attemptID, retry.attemptID)
        XCTAssertEqual(first.attemptNumber, 1)
        XCTAssertEqual(retry.attemptNumber, 2)
    }

    func testLegacyTimeoutRemainsUnresolvedWithoutAttemptMutation() {
        let timeout = LegacyCommandTimeoutObservation(
            protocolKind: .walkingPad,
            connectionEpoch: epochA,
            occurredAt: receivedAt
        )

        XCTAssertEqual(timeout.association, .unresolvedByLegacyRuntime)
        XCTAssertNil(timeout.commandID)
        XCTAssertNil(timeout.attemptID)
    }

    func testLegacyWriteResultRemainsUnresolvedWithoutCausalIDs() {
        for status in [TreadmillWriteResultStatus.succeeded, .failed] {
            let result = LegacyWriteResultObservation(
                protocolKind: .fitShow,
                connectionEpoch: epochA,
                occurredAt: receivedAt,
                status: status
            )

            XCTAssertEqual(result.association, .unresolvedByLegacyRuntime)
            XCTAssertNil(result.commandID)
            XCTAssertNil(result.attemptID)
        }
    }

    func testLegacyTimeoutAndWriteResultRejectBackfilledAssociationDuringReplay() throws {
        let association = LegacyAcknowledgementAssociation.deterministicallyCorrelated(
            commandID: commandID(91),
            attemptID: attemptID(92)
        )
        let timeout = FabricatedLegacyTimeout(
            protocolKind: .walkingPad,
            connectionEpoch: epochA,
            occurredAt: receivedAt,
            association: association
        )
        let writeResult = FabricatedLegacyWriteResult(
            protocolKind: .walkingPad,
            connectionEpoch: epochA,
            occurredAt: receivedAt,
            status: .succeeded,
            association: association
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                LegacyCommandTimeoutObservation.self,
                from: JSONEncoder().encode(timeout)
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                LegacyWriteResultObservation.self,
                from: JSONEncoder().encode(writeResult)
            )
        )
    }

    func testObservedResponseIsFactualAndUnassociatedUntilIndependentProofExists() {
        var normalizer = TreadmillObservationNormalizer()
        let observation = normalizer.normalize(
            .ftms(
                speedRawHundredthsKmh: 350,
                rawState: 1,
                deviceState: .moving,
                connectionEpoch: epochA,
                receivedAt: receivedAt
            ),
            unitsTruth: nil,
            observationID: ObservationID(),
            recordedAt: receivedAt
        )

        XCTAssertEqual(observation.nativeSpeed?.rawValue, 350)
        XCTAssertEqual(observation.responseAssociation, .unassociated)
        XCTAssertNil(observation.commandID)
        XCTAssertNil(observation.attemptID)
    }

    func testStopEvidenceRetainsDecisionCommandAndFactualObservationChain() {
        let decision = decisionID(12)
        let command = commandID(13)
        let observation = ObservationID(rawValue: uuid(14))
        let evidence = TreadmillStopTruthEvidence(
            stopAttemptID: uuid(15),
            decisionID: decision,
            commandID: command,
            observationID: observation,
            connectionEpoch: epochA,
            protocolKind: .walkingPad,
            conclusion: .confirmedByFreshFactualObservation(observation),
            rawSpeedTenths: 0,
            rawDeviceState: 0,
            checksumValid: true,
            observationReceivedAt: receivedAt,
            evaluatedAt: receivedAt
        )

        XCTAssertEqual(evidence.decisionID, decision)
        XCTAssertEqual(evidence.commandID, command)
        XCTAssertEqual(evidence.observationID, observation)
        XCTAssertEqual(evidence.rawSpeedTenths, 0)
    }

    func testHeartRateDecisionKeepsExactAcceptedControlUseReferences() {
        let reference = HeartRateCausalReference(
            deliveryID: HeartRateDeliveryID(
                rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
            ),
            canonicalObservationID: HeartRateCanonicalObservationID(
                rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
            )
        )
        let decision = TreadmillControlDecisionEvidence(
            decisionID: decisionID(8),
            source: .heartRateControl,
            intent: .setDesiredSpeed(DesiredSpeedKilometresPerHour(value: 4.2)),
            heartRateInputs: [reference],
            occurredAt: receivedAt,
            connectionEpoch: epochA
        )

        XCTAssertEqual(decision.heartRateInputs, [reference])
        XCTAssertEqual(decision.source, .heartRateControl)
    }

    func testManualCooldownAndStopDecisionsDoNotBorrowHeartRateInputs() {
        for source in [
            TreadmillControlDecisionSource.manual,
            .cooldown,
            .stop,
        ] {
            let decision = TreadmillControlDecisionEvidence(
                decisionID: decisionID(UInt8(source == .manual ? 9 : source == .cooldown ? 10 : 11)),
                source: source,
                intent: source == .stop
                    ? .stop
                    : .setDesiredSpeed(DesiredSpeedKilometresPerHour(value: 3.5)),
                heartRateInputs: [],
                occurredAt: receivedAt,
                connectionEpoch: epochA
            )
            XCTAssertTrue(decision.heartRateInputs.isEmpty)
        }
    }

    private func attempt(
        command: UInt8,
        attempt: UInt8,
        epoch: TreadmillConnectionEpoch,
        number: UInt16
    ) -> TreadmillCommandSendAttemptEvidence {
        TreadmillCommandSendAttemptEvidence(
            commandID: commandID(command),
            decisionID: nil,
            attemptID: attemptID(attempt),
            attemptNumber: number,
            protocolKind: .walkingPad,
            connectionEpoch: epoch,
            sentAt: receivedAt,
            writeType: .withResponse
        )
    }

    private func commandID(_ value: UInt8) -> CommandID {
        CommandID(rawValue: uuid(value))
    }

    private func attemptID(_ value: UInt8) -> CommandAttemptID {
        CommandAttemptID(rawValue: uuid(value))
    }

    private func decisionID(_ value: UInt8) -> DecisionID {
        DecisionID(rawValue: uuid(value))
    }

    private func uuid(_ value: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
    }
}

private struct LegacyTrace: Equatable {
    var bytes: [[UInt8]] = []
    var sendOffsets: [TimeInterval] = []
    var timeoutOffsets: [TimeInterval] = []
    var retryOffsets: [TimeInterval] = []
    var target: Double = 0
    var stopConfirmed = false
}

private struct FabricatedLegacyTimeout: Encodable {
    let protocolKind: TreadmillProtocolKind
    let connectionEpoch: TreadmillConnectionEpoch
    let occurredAt: Date
    let association: LegacyAcknowledgementAssociation
}

private struct FabricatedLegacyWriteResult: Encodable {
    let protocolKind: TreadmillProtocolKind
    let connectionEpoch: TreadmillConnectionEpoch
    let occurredAt: Date
    let status: TreadmillWriteResultStatus
    let association: LegacyAcknowledgementAssociation
}
