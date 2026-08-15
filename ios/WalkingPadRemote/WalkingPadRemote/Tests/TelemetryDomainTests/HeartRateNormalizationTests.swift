import Foundation
import TelemetryDomain
import XCTest

final class HeartRateNormalizationTests: XCTestCase {
    private let source = HeartRateProviderIdentity(
        kind: .legacyWatchWorkoutStream,
        stableLocalKey: "legacyWatchWorkoutStream"
    )
    private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

    func testLegacyPayloadWithoutMetadataStillDecodesHeartRate() throws {
        let decoded = try XCTUnwrap(
            WatchHeartRatePayloadDecoder.decode(["hr": 123.4])
        )

        XCTAssertEqual(decoded.beatsPerMinute, 123)
        XCTAssertNil(decoded.sourceCallbackObservedAt)
        XCTAssertNil(decoded.providerSequence)
        XCTAssertTrue(decoded.quality.contains(.missingSourceObservationTime))
        XCTAssertTrue(decoded.quality.contains(.missingProviderSequence))
    }

    func testMalformedOptionalMetadataDoesNotRejectLegacyHeartRate() throws {
        let decoded = try XCTUnwrap(
            WatchHeartRatePayloadDecoder.decode([
                "hr": 121.0,
                HeartRateWatchPayloadKey.sourceCallbackObservedAt: "not-a-date",
                HeartRateWatchPayloadKey.providerSequence: "not-a-sequence",
            ])
        )

        XCTAssertEqual(decoded.beatsPerMinute, 121)
        XCTAssertNil(decoded.sourceCallbackObservedAt)
        XCTAssertNil(decoded.providerSequence)
        XCTAssertTrue(decoded.quality.contains(.malformedSourceObservationTime))
        XCTAssertTrue(decoded.quality.contains(.malformedProviderSequence))
    }

    func testEachOptionalMetadataFailureLeavesLegacyHeartRateValid() throws {
        let validTimestamp = baseDate.timeIntervalSince1970
        let cases: [([String: Any], HeartRateNormalizationQualityFlag)] = [
            ([
                "hr": 121.0,
                HeartRateWatchPayloadKey.providerSequence: Int64(1),
            ], .missingSourceObservationTime),
            ([
                "hr": 121.0,
                HeartRateWatchPayloadKey.sourceCallbackObservedAt: "bad",
                HeartRateWatchPayloadKey.providerSequence: Int64(1),
            ], .malformedSourceObservationTime),
            ([
                "hr": 121.0,
                HeartRateWatchPayloadKey.sourceCallbackObservedAt: validTimestamp,
            ], .missingProviderSequence),
            ([
                "hr": 121.0,
                HeartRateWatchPayloadKey.sourceCallbackObservedAt: validTimestamp,
                HeartRateWatchPayloadKey.providerSequence: "bad",
            ], .malformedProviderSequence),
        ]

        for (payload, expectedFlag) in cases {
            let decoded = try XCTUnwrap(WatchHeartRatePayloadDecoder.decode(payload))
            XCTAssertEqual(decoded.beatsPerMinute, 121)
            XCTAssertTrue(decoded.quality.contains(expectedFlag))
        }
    }

    func testAdditivePayloadKeepsTimestampAndSequenceRolesDistinct() throws {
        let callbackTime = baseDate.timeIntervalSince1970
        let decoded = try XCTUnwrap(
            WatchHeartRatePayloadDecoder.decode([
                "hr": 119.6,
                HeartRateWatchPayloadKey.sourceCallbackObservedAt: callbackTime,
                HeartRateWatchPayloadKey.providerSequence: Int64(44),
                "future_unknown_metadata": "ignored",
            ])
        )

        XCTAssertEqual(decoded.beatsPerMinute, 120)
        XCTAssertEqual(decoded.sourceCallbackObservedAt, baseDate)
        XCTAssertEqual(decoded.providerSequence, 44)
        XCTAssertFalse(decoded.quality.contains(.missingSourceObservationTime))
        XCTAssertFalse(decoded.quality.contains(.missingProviderSequence))
    }

    func testArrivalOrderIsPreservedWhileDuplicateOutOfOrderAndGapAreOnlyFlagged() {
        var normalizer = HeartRateObservationNormalizer(receiveDelayThreshold: 3)
        let inputs = [
            observation(bpm: 120, sequence: 10, callbackOffset: 0, receiveOffset: 0.1),
            observation(bpm: 120, sequence: 10, callbackOffset: 0, receiveOffset: 0.2),
            observation(bpm: 121, sequence: 9, callbackOffset: -1, receiveOffset: 0.3),
            observation(bpm: 122, sequence: 12, callbackOffset: 1, receiveOffset: 5),
        ]

        let outputs = inputs.enumerated().map { index, input in
            normalizer.normalize(
                input,
                canonicalObservationID: canonicalID(index + 1),
                deliveryID: deliveryID(index + 1),
                recordedAt: baseDate.addingTimeInterval(Double(index) + 10)
            )
        }

        XCTAssertEqual(outputs.map(\.delivery.arrivalOrder), [1, 2, 3, 4])
        XCTAssertEqual(outputs.map(\.delivery.beatsPerMinute), [120, 120, 121, 122])
        XCTAssertEqual(outputs.compactMap(\.canonicalObservation).count, 4)
        XCTAssertTrue(outputs[1].delivery.quality.contains(.duplicateProviderSequence))
        XCTAssertTrue(outputs[1].delivery.quality.contains(.repeatedValue))
        XCTAssertTrue(outputs[2].delivery.quality.contains(.providerSequenceOutOfOrder))
        XCTAssertTrue(outputs[2].delivery.quality.contains(.sourceObservationOutOfArrivalOrder))
        XCTAssertTrue(outputs[3].delivery.quality.contains(.gapBefore))
        XCTAssertTrue(outputs[3].delivery.quality.contains(.receivedLate))
    }

    func testIndependentWatchAndPhoneClocksDoNotClaimLatencyOrRegression() {
        var normalizer = HeartRateObservationNormalizer(receiveDelayThreshold: 3)
        let callbackAfterPhoneReceipt = normalizer.normalize(
            observation(
                bpm: 120,
                sequence: 1,
                callbackOffset: 10,
                receiveOffset: 0,
                sourceClockRelationship: .independent
            ),
            canonicalObservationID: canonicalID(1),
            deliveryID: deliveryID(1),
            recordedAt: baseDate
        )
        let callbackLongBeforePhoneReceipt = normalizer.normalize(
            observation(
                bpm: 121,
                sequence: 2,
                callbackOffset: 0,
                receiveOffset: 60,
                sourceClockRelationship: .independent
            ),
            canonicalObservationID: canonicalID(2),
            deliveryID: deliveryID(2),
            recordedAt: baseDate
        )

        for delivery in [
            callbackAfterPhoneReceipt.delivery,
            callbackLongBeforePhoneReceipt.delivery,
        ] {
            XCTAssertFalse(delivery.quality.contains(.clockRegression))
            XCTAssertFalse(delivery.quality.contains(.receivedLate))
            XCTAssertEqual(delivery.sourceClockRelationship, .independent)
        }
    }

    func testExactNativeRedeliveryUsesDistinctDeliveryIDsAndOneCanonicalObservation() throws {
        let nativeIdentity = try XCTUnwrap(
            HeartRateProviderNativeSampleIdentity(identifier: "native-sample-x")
        )
        var normalizer = HeartRateObservationNormalizer()
        let first = normalizer.normalize(
            observation(bpm: 120, sequence: 1, nativeIdentity: nativeIdentity),
            canonicalObservationID: canonicalID(1),
            deliveryID: deliveryID(1),
            recordedAt: baseDate.addingTimeInterval(1)
        )
        let redelivery = normalizer.normalize(
            observation(bpm: 120, sequence: 2, nativeIdentity: nativeIdentity),
            canonicalObservationID: canonicalID(2),
            deliveryID: deliveryID(2),
            recordedAt: baseDate.addingTimeInterval(2)
        )

        XCTAssertNotEqual(first.delivery.deliveryID, redelivery.delivery.deliveryID)
        XCTAssertEqual(
            first.delivery.canonicalObservationID,
            redelivery.delivery.canonicalObservationID
        )
        XCTAssertNotNil(first.canonicalObservation)
        XCTAssertNil(redelivery.canonicalObservation)
        XCTAssertTrue(redelivery.delivery.quality.contains(.duplicateProviderIdentity))
        XCTAssertEqual(first.delivery.controlUseAtDelivery, .notYetObserved)

        let actualUse = HeartRateControlUseEvidence(
            kind: .speedDecision,
            inputs: [redelivery.delivery.causalReference],
            occurredAt: baseDate.addingTimeInterval(3)
        )
        XCTAssertEqual(actualUse.inputs, [redelivery.delivery.causalReference])
        XCTAssertNotEqual(actualUse.inputs.first?.deliveryID, first.delivery.deliveryID)
        XCTAssertEqual(
            actualUse.inputs.first?.canonicalObservationID,
            first.delivery.canonicalObservationID
        )
    }

    func testNoNativeIdentityNeverCanonicalizesSimilarSamples() {
        var normalizer = HeartRateObservationNormalizer()
        let timestamp = baseDate.addingTimeInterval(1)
        let first = normalizer.normalize(
            observation(bpm: 120, sequence: 1, callbackAt: timestamp),
            canonicalObservationID: canonicalID(1),
            deliveryID: deliveryID(1),
            recordedAt: timestamp
        )
        let second = normalizer.normalize(
            observation(bpm: 120, sequence: 1, callbackAt: timestamp),
            canonicalObservationID: canonicalID(2),
            deliveryID: deliveryID(2),
            recordedAt: timestamp
        )

        XCTAssertNotEqual(
            first.delivery.canonicalObservationID,
            second.delivery.canonicalObservationID
        )
        XCTAssertNotNil(first.canonicalObservation)
        XCTAssertNotNil(second.canonicalObservation)
    }

    func testSameNativeIdentityDoesNotCollideAcrossStableSources() throws {
        let nativeIdentity = try XCTUnwrap(
            HeartRateProviderNativeSampleIdentity(identifier: "shared-native-id")
        )
        var normalizer = HeartRateObservationNormalizer()
        let first = normalizer.normalize(
            observation(bpm: 120, sequence: 1, nativeIdentity: nativeIdentity),
            canonicalObservationID: canonicalID(1),
            deliveryID: deliveryID(1),
            recordedAt: baseDate
        )
        let secondSource = HeartRateProviderIdentity(
            kind: .bluetooth,
            stableLocalKey: "future-bluetooth-source"
        )
        let second = normalizer.normalize(
            observation(
                bpm: 120,
                sequence: 1,
                nativeIdentity: nativeIdentity,
                source: secondSource
            ),
            canonicalObservationID: canonicalID(2),
            deliveryID: deliveryID(2),
            recordedAt: baseDate
        )

        XCTAssertNotEqual(
            first.delivery.canonicalObservationID,
            second.delivery.canonicalObservationID
        )
        XCTAssertNotNil(second.canonicalObservation)
    }

    func testNativeIdentityDoesNotCanonicalizeWithoutStableSourceIdentity() throws {
        let nativeIdentity = try XCTUnwrap(
            HeartRateProviderNativeSampleIdentity(identifier: "native-id")
        )
        let unstableSource = HeartRateProviderIdentity(
            kind: .unknown,
            stableLocalKey: "  "
        )
        var normalizer = HeartRateObservationNormalizer()
        let first = normalizer.normalize(
            observation(
                bpm: 120,
                sequence: 1,
                nativeIdentity: nativeIdentity,
                source: unstableSource
            ),
            canonicalObservationID: canonicalID(1),
            deliveryID: deliveryID(1),
            recordedAt: baseDate
        )
        let second = normalizer.normalize(
            observation(
                bpm: 120,
                sequence: 2,
                nativeIdentity: nativeIdentity,
                source: unstableSource
            ),
            canonicalObservationID: canonicalID(2),
            deliveryID: deliveryID(2),
            recordedAt: baseDate
        )

        XCTAssertNotEqual(
            first.delivery.canonicalObservationID,
            second.delivery.canonicalObservationID
        )
        XCTAssertNotNil(first.canonicalObservation)
        XCTAssertNotNil(second.canonicalObservation)
        XCTAssertTrue(first.delivery.quality.contains(.missingStableSourceIdentity))
        XCTAssertTrue(second.delivery.quality.contains(.missingStableSourceIdentity))
    }

    func testBlankNativeIdentityIsRejectedBeforeCanonicalization() throws {
        XCTAssertNil(HeartRateProviderNativeSampleIdentity(identifier: " \n\t "))

        let encodedBlank = try XCTUnwrap("\"   \"".data(using: .utf8))
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                HeartRateProviderNativeSampleIdentity.self,
                from: encodedBlank
            )
        )
    }

    func testSourceLifecycleUsesExistingTransitionsAndOnlyClaimsObservableRestart() {
        var normalizer = HeartRateObservationNormalizer()

        XCTAssertEqual(
            normalizer.observeLifecycle(.available, source: source, occurredAt: baseDate)?.kind,
            .available
        )
        XCTAssertNil(
            normalizer.observeLifecycle(.recovered, source: source, occurredAt: baseDate)
        )
        XCTAssertEqual(
            normalizer.observeLifecycle(.started, source: source, occurredAt: baseDate)?.kind,
            .started
        )
        XCTAssertEqual(
            normalizer.observeLifecycle(.stale, source: source, occurredAt: baseDate)?.kind,
            .stale
        )
        XCTAssertNil(
            normalizer.observeLifecycle(.stale, source: source, occurredAt: baseDate)
        )
        XCTAssertEqual(
            normalizer.observeLifecycle(.recovered, source: source, occurredAt: baseDate)?.kind,
            .recovered
        )
        XCTAssertEqual(
            normalizer.observeLifecycle(.stopped, source: source, occurredAt: baseDate)?.kind,
            .stopped
        )
        XCTAssertNil(
            normalizer.observeLifecycle(.stale, source: source, occurredAt: baseDate)
        )
        XCTAssertEqual(
            normalizer.observeLifecycle(.started, source: source, occurredAt: baseDate)?.kind,
            .restarted
        )
    }

    func testFixedLegacyTracePreservesEveryDuplicateAndOutOfOrderDelivery() throws {
        let payloads: [[String: Any]] = [
            ["hr": 120.0, HeartRateWatchPayloadKey.providerSequence: Int64(2)],
            ["hr": 120.0, HeartRateWatchPayloadKey.providerSequence: Int64(2)],
            ["hr": 119.0, HeartRateWatchPayloadKey.providerSequence: Int64(1)],
            ["hr": 121.0, HeartRateWatchPayloadKey.providerSequence: Int64(4)],
        ]
        var current = 0
        var lastKnown = 0
        var lastReceivedAt: Date?
        var controllerDeliveries: [Int] = []
        var predictorInputs: [Int] = []

        for payload in payloads {
            let decoded = try XCTUnwrap(WatchHeartRatePayloadDecoder.decode(payload))
            HeartRateObservationalTee.deliver(
                decoded.beatsPerMinute,
                toLegacyController: { bpm in
                    current = bpm
                    lastKnown = bpm
                    lastReceivedAt = baseDate
                    predictorInputs.append(bpm)
                    controllerDeliveries.append(bpm)
                },
                observe: { .rejected }
            )
        }

        XCTAssertEqual(controllerDeliveries, [120, 120, 119, 121])
        XCTAssertEqual(predictorInputs, controllerDeliveries)
        XCTAssertEqual(current, 121)
        XCTAssertEqual(lastKnown, 121)
        XCTAssertEqual(lastReceivedAt, baseDate)
    }

    func testObservationalTeeDeliversLegacyValueBeforeEveryTelemetryDisposition() {
        for disposition in HeartRateTelemetrySinkDisposition.allCases {
            var trace: [String] = []
            let inputs = [123, 123, 121, 125]
            for input in inputs {
                let result = HeartRateObservationalTee.deliver(
                    input,
                    toLegacyController: { value in trace.append("legacy:\(value)") },
                    observe: {
                        trace.append("telemetry:\(disposition.rawValue)")
                        return disposition
                    }
                )
                XCTAssertEqual(result, disposition)
            }

            XCTAssertEqual(
                trace,
                inputs.flatMap {
                    ["legacy:\($0)", "telemetry:\(disposition.rawValue)"]
                }
            )
        }

        var delivered: [Int] = []
        HeartRateObservationalTee.deliver(
            124,
            toLegacyController: { delivered.append($0) },
            observe: nil
        )
        XCTAssertEqual(delivered, [124])
    }

    private func observation(
        bpm: Int,
        sequence: Int64?,
        callbackOffset: TimeInterval = 0,
        receiveOffset: TimeInterval = 0.1,
        nativeIdentity: HeartRateProviderNativeSampleIdentity? = nil,
        source: HeartRateProviderIdentity? = nil,
        callbackAt: Date? = nil,
        sourceClockRelationship: HeartRateSourceClockRelationship = .receiverComparable
    ) -> HeartRateProviderObservation {
        HeartRateProviderObservation(
            source: source ?? self.source,
            beatsPerMinute: bpm,
            providerSequence: sequence,
            providerNativeIdentity: nativeIdentity,
            measuredAt: nil,
            sourceCallbackObservedAt: callbackAt ?? baseDate.addingTimeInterval(callbackOffset),
            sourceClockRelationship: sourceClockRelationship,
            receivedAt: baseDate.addingTimeInterval(receiveOffset),
            metadataQuality: []
        )
    }

    private func canonicalID(_ value: Int) -> HeartRateCanonicalObservationID {
        HeartRateCanonicalObservationID(rawValue: uuid(value))
    }

    private func deliveryID(_ value: Int) -> HeartRateDeliveryID {
        HeartRateDeliveryID(rawValue: uuid(value + 100))
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
