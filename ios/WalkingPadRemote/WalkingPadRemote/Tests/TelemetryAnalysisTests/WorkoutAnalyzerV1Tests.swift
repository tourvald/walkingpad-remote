import Foundation
import XCTest
@testable import TelemetryAnalysis
@testable import TelemetryDomain

final class WorkoutAnalyzerV1Tests: XCTestCase {
    func testIrregularCadenceUsesFreshTimestampDurationInsteadOfSampleWeighting() throws {
        let fixture = AnalysisFixture(sessionSeconds: 20)
        let input = fixture.input(
            heartRate: [
                fixture.heartRate(ordinal: 1, seconds: 0, bpm: 80),
                fixture.heartRate(ordinal: 2, seconds: 1, bpm: 120),
                fixture.heartRate(ordinal: 3, seconds: 10, bpm: 100),
            ],
            events: fixture.phaseEvents(mainAt: 0, finishedAt: 20)
        )

        let result = try WorkoutAnalyzerV1.analyze(
            input,
            generatedAt: fixture.baseDate.addingTimeInterval(30)
        )
        let detail = try decodeDetail(result)

        XCTAssertEqual(result.keyMetrics.averageHeartRate!, 108, accuracy: 0.000_001)
        XCTAssertNotEqual(result.keyMetrics.averageHeartRate!, 100, accuracy: 0.000_001)
        XCTAssertEqual(detail.quality.heartRateCoverage.coveredSeconds, 15, accuracy: 0.000_001)
        XCTAssertEqual(detail.quality.heartRateCoverage.uncoveredSeconds, 5, accuracy: 0.000_001)
        XCTAssertEqual(detail.quality.heartRateGapCount, 2)
        XCTAssertEqual(detail.quality.maximumHeartRateGapSeconds!, 3, accuracy: 0.000_001)
        XCTAssertEqual(detail.quality.heartRateCadenceSeconds.value!.mean, 5, accuracy: 0.000_001)
        XCTAssertEqual(
            detail.control.heartRateError.value!.meanAbsoluteErrorBeatsPerMinute,
            10.666_666_666_7,
            accuracy: 0.000_001
        )
    }

    func testTinyStartupFactualSpeedSliceCannotBecomeWorkoutAverage() throws {
        let fixture = AnalysisFixture(sessionSeconds: 1_620)
        let treadmill = stride(from: 0, through: 20, by: 5).enumerated().map {
            fixture.treadmill(
                ordinal: $0.offset + 1,
                seconds: Double($0.element),
                speed: Double(2 + $0.offset),
                factual: true
            )
        }
        let result = try WorkoutAnalyzerV1.analyze(
            fixture.input(
                treadmill: treadmill,
                events: fixture.phaseEvents(mainAt: 0, finishedAt: 1_620)
            ),
            generatedAt: fixture.baseDate.addingTimeInterval(1_700)
        )
        let detail = try decodeDetail(result)

        XCTAssertNil(result.keyMetrics.averageFactualSpeedKilometresPerHour)
        XCTAssertEqual(
            detail.quality.treadmillFactualCoverage.coveredSeconds,
            25,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            detail.quality.treadmillFactualCoverage.coverageRatio!,
            25.0 / 1_620.0,
            accuracy: 0.000_001
        )
        XCTAssertTrue(detail.quality.issues.contains {
            $0.code == "average-factual-speed-insufficient-coverage"
                && $0.detail?.contains("required=0.900000") == true
        })
        XCTAssertTrue(result.exclusions.contains {
            $0.code == "sourceCoverageUnavailable.average-factual-speed-insufficient-coverage"
        })
    }

    func testAdequateFactualCoverageProducesNormalWorkoutAverage() throws {
        let fixture = AnalysisFixture(sessionSeconds: 100)
        let treadmill = stride(from: 0, through: 85, by: 5).enumerated().map {
            fixture.treadmill(
                ordinal: $0.offset + 1,
                seconds: Double($0.element),
                speed: $0.offset.isMultiple(of: 2) ? 4 : 6,
                factual: true
            )
        }
        let result = try WorkoutAnalyzerV1.analyze(
            fixture.input(
                treadmill: treadmill,
                events: fixture.phaseEvents(mainAt: 0, finishedAt: 100)
            ),
            generatedAt: fixture.baseDate.addingTimeInterval(120)
        )
        let detail = try decodeDetail(result)

        XCTAssertEqual(
            detail.quality.treadmillFactualCoverage.coverageRatio!,
            WorkoutAnalyzerV1.minimumAverageFactualSpeedCoverageRatio,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            result.keyMetrics.averageFactualSpeedKilometresPerHour!,
            5,
            accuracy: 0.000_001
        )
        XCTAssertFalse(detail.quality.issues.contains {
            $0.code == "average-factual-speed-insufficient-coverage"
        })
    }

    func testRealisticSparseSessionUsesFreshCanonicalCoverageAcrossCooldown() throws {
        let sessionSeconds = 1_620
        let fixture = AnalysisFixture(sessionSeconds: Double(sessionSeconds))
        let spacing = Double(sessionSeconds) / 49.0
        let treadmill = (0..<49).map { index in
            fixture.treadmill(
                ordinal: index + 1,
                seconds: Double(index) * spacing,
                speed: index < 40 ? 6 : 3,
                factual: true
            )
        }
        let frames = (0..<sessionSeconds).map { second -> CanonicalFrame in
            let observationIndex = min(48, Int(Double(second) / spacing))
            let observation = treadmill[observationIndex]
            let age = Double(second) - Double(observationIndex) * spacing
            return fixture.treadmillFrame(
                observation: observation,
                second: Int64(second),
                freshness: age <= 30 ? .fresh : .stale
            )
        }
        let result = try WorkoutAnalyzerV1.analyze(
            fixture.input(
                treadmill: treadmill,
                events: fixture.cooldownEvents(start: 1_320, end: 1_620, target: 115),
                frames: frames
            ),
            generatedAt: fixture.baseDate.addingTimeInterval(1_700)
        )
        let detail = try decodeDetail(result)

        XCTAssertEqual(treadmill.count, 49)
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(detail.quality.treadmillFactualCoverage.coverageRatio),
            WorkoutAnalyzerV1.minimumAverageFactualSpeedCoverageRatio
        )
        XCTAssertNotNil(result.keyMetrics.averageFactualSpeedKilometresPerHour)
        XCTAssertTrue(detail.quality.phases.allSatisfy {
            ($0.treadmillCoverage.coverageRatio ?? 0)
                >= WorkoutAnalyzerV1.minimumAverageFactualSpeedCoverageRatio
        })
    }

    func testDuplicateAndOutOfOrderNativeSamplesCannotChangeDurationMetrics() throws {
        let fixture = AnalysisFixture(sessionSeconds: 20)
        let heartRate = [
            fixture.heartRate(ordinal: 1, seconds: 0, bpm: 100),
            fixture.heartRate(ordinal: 2, seconds: 10, bpm: 120),
        ]
        let treadmill = [
            fixture.treadmill(ordinal: 1, seconds: 0, speed: 3, factual: true),
            fixture.treadmill(ordinal: 2, seconds: 10, speed: 4, factual: true),
        ]
        let events = fixture.phaseEvents(mainAt: 0, finishedAt: 20)
        let baselineResult = try WorkoutAnalyzerV1.analyze(
            fixture.input(heartRate: heartRate, treadmill: treadmill, events: events),
            generatedAt: fixture.baseDate.addingTimeInterval(30)
        )
        let flaggedResult = try WorkoutAnalyzerV1.analyze(
            fixture.input(
                heartRate: heartRate + [
                    fixture.heartRate(
                        ordinal: 3,
                        seconds: 2,
                        bpm: 200,
                        quality: [.duplicateProviderIdentity]
                    ),
                    fixture.heartRate(
                        ordinal: 4,
                        seconds: 3,
                        bpm: 40,
                        quality: [.measurementOutOfArrivalOrder]
                    ),
                ],
                treadmill: treadmill + [
                    fixture.treadmill(
                        ordinal: 3,
                        seconds: 2,
                        speed: 9,
                        factual: true,
                        quality: [.duplicateProviderSequence]
                    ),
                    fixture.treadmill(
                        ordinal: 4,
                        seconds: 3,
                        speed: 8,
                        factual: true,
                        quality: [.measurementOutOfArrivalOrder]
                    ),
                ],
                events: events
            ),
            generatedAt: fixture.baseDate.addingTimeInterval(30)
        )
        let baseline = try decodeDetail(baselineResult)
        let flagged = try decodeDetail(flaggedResult)

        XCTAssertEqual(flagged.control.heartRateError, baseline.control.heartRateError)
        XCTAssertEqual(
            flaggedResult.keyMetrics.averageHeartRate,
            baselineResult.keyMetrics.averageHeartRate
        )
        XCTAssertEqual(
            flaggedResult.keyMetrics.averageFactualSpeedKilometresPerHour,
            baselineResult.keyMetrics.averageFactualSpeedKilometresPerHour
        )
        XCTAssertEqual(flagged.quality.heartRateCoverage, baseline.quality.heartRateCoverage)
        XCTAssertEqual(
            flagged.quality.treadmillFactualCoverage,
            baseline.quality.treadmillFactualCoverage
        )
        XCTAssertEqual(flagged.quality.duplicateEvidenceCount, 2)
        XCTAssertGreaterThanOrEqual(flagged.quality.outOfOrderEvidenceCount, 2)
        XCTAssertTrue(flagged.quality.issues.contains {
            $0.category == .malformedCorruptEvidence
        })
    }

    func testQualityClassesRemainDistinctForLossAmbiguityCoverageAndMalformedEvidence() throws {
        let fixture = AnalysisFixture(
            sessionSeconds: 30,
            lifecycle: .incomplete,
            recorderComplete: false,
            lostNative: 2,
            incompleteReason: "recorder-tail-loss"
        )
        let sourceB = fixture.source(ordinal: 2, kind: .bluetooth)
        let epoch = TreadmillConnectionEpoch(rawValue: fixture.uuid(90))
        let acknowledgement = LegacyAcknowledgementObservation.unresolved(
            protocolKind: .walkingPad,
            connectionEpoch: epoch,
            receivedAt: fixture.baseDate.addingTimeInterval(4),
            recordedAt: fixture.baseDate.addingTimeInterval(4)
        )
        let input = fixture.input(
            heartRate: [
                fixture.heartRate(
                    ordinal: 1,
                    seconds: 0,
                    bpm: 100,
                    quality: [.duplicateProviderSequence]
                ),
                fixture.heartRate(
                    ordinal: 2,
                    seconds: 5,
                    bpm: 105,
                    source: sourceB,
                    quality: [.measurementOutOfArrivalOrder]
                ),
                fixture.heartRate(
                    ordinal: 3,
                    seconds: 10,
                    bpm: 110,
                    quality: [.invalidNativeValue]
                ),
            ],
            treadmill: [
                fixture.treadmill(
                    ordinal: 1,
                    seconds: 0,
                    speed: 4,
                    factual: false,
                    quality: [.unknownFreshness]
                ),
            ],
            events: fixture.phaseEvents(mainAt: 0, finishedAt: 30) + [
                fixture.event(
                    ordinal: 20,
                    seconds: 4,
                    payload: .treadmillEvidence(.acknowledgement(acknowledgement))
                ),
            ]
        )

        let detail = try decodeDetail(WorkoutAnalyzerV1.analyze(
            input,
            generatedAt: fixture.baseDate.addingTimeInterval(40)
        ))
        let categories = Set(detail.quality.issues.map(\.category))

        XCTAssertTrue(categories.contains(.recorderEvidenceLoss))
        XCTAssertTrue(categories.contains(.protocolRuntimeCausalAmbiguity))
        XCTAssertTrue(categories.contains(.sourceCoverageUnavailable))
        XCTAssertTrue(categories.contains(.malformedCorruptEvidence))
        XCTAssertTrue(detail.quality.incompleteSession)
        XCTAssertTrue(detail.quality.recorderLoss)
        XCTAssertEqual(detail.quality.duplicateEvidenceCount, 1)
        XCTAssertGreaterThanOrEqual(detail.quality.outOfOrderEvidenceCount, 1)
        XCTAssertEqual(detail.quality.sourceSwitchCount, 2)
        XCTAssertEqual(detail.quality.treadmillFactualCoverage.coveredSeconds, 0)
        XCTAssertEqual(detail.quality.commandAcknowledgement.unknownAssociationCount, 1)
        XCTAssertTrue(detail.quality.phases.allSatisfy {
            $0.exclusionCodes.contains("recorder-loss")
                && $0.exclusionCodes.contains("malformed-or-invalid-native-evidence")
        })
    }

    func testUnknownAndUnsupportedClaimsPreserveEquivalentFactualMetrics() throws {
        let fixture = AnalysisFixture(sessionSeconds: 30)
        let heartRate = stride(from: 0, through: 25, by: 5).enumerated().map {
            fixture.heartRate(ordinal: $0.offset + 1, seconds: Double($0.element), bpm: 100)
        }
        let treadmill = stride(from: 0, through: 25, by: 5).enumerated().map {
            fixture.treadmill(
                ordinal: $0.offset + 1,
                seconds: Double($0.element),
                speed: 4,
                factual: true
            )
        }
        let common = fixture.phaseEvents(mainAt: 0, finishedAt: 30)
        let unsupportedDetail = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(
                heartRate: heartRate,
                treadmill: treadmill,
                events: common + fixture.causalEdgeEvents(specificClaim: true)
            ),
            generatedAt: fixture.baseDate.addingTimeInterval(40)
        ))
        let unknownDetail = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(
                heartRate: heartRate,
                treadmill: treadmill,
                events: common + fixture.causalEdgeEvents(specificClaim: false)
            ),
            generatedAt: fixture.baseDate.addingTimeInterval(40)
        ))

        for detail in [unsupportedDetail, unknownDetail] {
            XCTAssertEqual(detail.quality.commandAcknowledgement.provenEdgeCount, 0)
            XCTAssertEqual(detail.quality.commandFactualResponse.provenEdgeCount, 0)
            XCTAssertNil(detail.quality.commandAcknowledgement.latencySeconds.value)
            XCTAssertNil(detail.quality.commandFactualResponse.latencySeconds.value)
            XCTAssertNil(detail.control.eventAlignedHeartRateResponse.value)
            XCTAssertFalse(detail.quality.recorderLoss)
        }
        XCTAssertEqual(unsupportedDetail.quality.commandAcknowledgement.unknownAssociationCount, 0)
        XCTAssertEqual(unsupportedDetail.quality.commandFactualResponse.unknownAssociationCount, 0)
        XCTAssertTrue(unsupportedDetail.quality.issues.contains {
            $0.category == .malformedCorruptEvidence
                && $0.code == "unsupported-persisted-command-ack-causal-claim"
                && $0.count == 1
        })
        XCTAssertTrue(unsupportedDetail.quality.issues.contains {
            $0.category == .malformedCorruptEvidence
                && $0.code == "unsupported-persisted-command-factual-response-causal-claim"
                && $0.count == 1
        })
        XCTAssertFalse(unsupportedDetail.quality.issues.contains {
            $0.category == .protocolRuntimeCausalAmbiguity
                || $0.category == .recorderEvidenceLoss
        })
        XCTAssertEqual(unsupportedDetail.quality.sessionGrade, .low)
        XCTAssertTrue(unsupportedDetail.quality.commandAcknowledgement.latencySeconds
            .unavailableReasons.contains(
                "independently-verifiable-persisted-causal-proof-unavailable"
            ))
        XCTAssertTrue(unsupportedDetail.quality.commandFactualResponse.latencySeconds
            .unavailableReasons.contains(
                "independently-verifiable-persisted-causal-proof-unavailable"
            ))
        XCTAssertTrue(unsupportedDetail.control.eventAlignedHeartRateResponse
            .unavailableReasons.contains(
                "independently-verifiable-persisted-factual-response-proof-unavailable"
            ))
        XCTAssertEqual(unknownDetail.quality.commandAcknowledgement.unknownAssociationCount, 1)
        XCTAssertGreaterThanOrEqual(
            unknownDetail.quality.commandFactualResponse.unknownAssociationCount,
            1
        )
        XCTAssertTrue(unknownDetail.quality.issues.contains {
            $0.category == .protocolRuntimeCausalAmbiguity
        })
        XCTAssertEqual(unknownDetail.quality.sessionGrade, .medium)
        XCTAssertFalse(unknownDetail.quality.issues.contains {
            $0.code.hasPrefix("unsupported-persisted-command-")
        })
        XCTAssertEqual(
            unsupportedDetail.quality.heartRateCoverage,
            unknownDetail.quality.heartRateCoverage
        )
        XCTAssertEqual(
            unsupportedDetail.quality.treadmillFactualCoverage,
            unknownDetail.quality.treadmillFactualCoverage
        )
        XCTAssertEqual(unsupportedDetail.control.commandCount, unknownDetail.control.commandCount)
        XCTAssertEqual(
            unsupportedDetail.control.speedDeltaKilometresPerHour,
            unknownDetail.control.speedDeltaKilometresPerHour
        )
        XCTAssertEqual(
            unsupportedDetail.control.retryAttemptLatencySeconds,
            unknownDetail.control.retryAttemptLatencySeconds
        )
        XCTAssertEqual(
            unsupportedDetail.control.heartRateError,
            unknownDetail.control.heartRateError
        )
        XCTAssertEqual(
            unsupportedDetail.control.zoneDurations,
            unknownDetail.control.zoneDurations
        )
        XCTAssertEqual(
            unsupportedDetail.control.stableSpeedHeartRateDrift,
            unknownDetail.control.stableSpeedHeartRateDrift
        )
    }

    func testStructurallyInvalidSpecificClaimsRemainUnsupported() throws {
        let fixture = AnalysisFixture(sessionSeconds: 30)
        let heartRate = stride(from: 0, through: 25, by: 5).enumerated().map {
            fixture.heartRate(ordinal: $0.offset + 1, seconds: Double($0.element), bpm: 100)
        }
        let treadmill = stride(from: 0, through: 25, by: 5).enumerated().map {
            fixture.treadmill(
                ordinal: $0.offset + 1,
                seconds: Double($0.element),
                speed: 4,
                factual: true
            )
        }
        let common = fixture.phaseEvents(mainAt: 0, finishedAt: 30)
        let missingSend = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(
                heartRate: heartRate,
                treadmill: treadmill,
                events: common + fixture.causalEdgeEvents(specificClaim: true, includeSend: false)
            ),
            generatedAt: fixture.baseDate.addingTimeInterval(40)
        ))
        let responseBeforeSend = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(
                heartRate: heartRate,
                treadmill: treadmill,
                events: common + fixture.causalEdgeEvents(
                    specificClaim: true,
                    responseEventSeconds: 11.5
                )
            ),
            generatedAt: fixture.baseDate.addingTimeInterval(40)
        ))

        XCTAssertEqual(missingSend.quality.commandFactualResponse.provenEdgeCount, 0)
        XCTAssertNil(missingSend.quality.commandFactualResponse.latencySeconds.value)
        XCTAssertNil(missingSend.control.eventAlignedHeartRateResponse.value)
        XCTAssertTrue(missingSend.quality.issues.contains {
            $0.category == .malformedCorruptEvidence && $0.count >= 1
        })

        XCTAssertEqual(responseBeforeSend.quality.commandFactualResponse.provenEdgeCount, 0)
        XCTAssertNil(responseBeforeSend.quality.commandFactualResponse.latencySeconds.value)
        XCTAssertNil(responseBeforeSend.control.eventAlignedHeartRateResponse.value)
        XCTAssertTrue(responseBeforeSend.quality.issues.contains {
            $0.category == .malformedCorruptEvidence && $0.count >= 1
        })
    }

    func testMismatchedProtocolOrEpochCannotProduceCausalMetrics() throws {
        let fixture = AnalysisFixture(sessionSeconds: 30)
        let heartRate = stride(from: 0, through: 25, by: 5).enumerated().map {
            fixture.heartRate(ordinal: $0.offset + 1, seconds: Double($0.element), bpm: 100)
        }
        let treadmill = stride(from: 0, through: 25, by: 5).enumerated().map {
            fixture.treadmill(
                ordinal: $0.offset + 1,
                seconds: Double($0.element),
                speed: 4,
                factual: true
            )
        }
        let common = fixture.phaseEvents(mainAt: 0, finishedAt: 30)
        let protocolMismatch = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(
                heartRate: heartRate,
                treadmill: treadmill,
                events: common + fixture.causalEdgeEvents(
                    specificClaim: true,
                    associatedProtocolKind: .walkingPad
                )
            ),
            generatedAt: fixture.baseDate.addingTimeInterval(40)
        ))
        let epochMismatch = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(
                heartRate: heartRate,
                treadmill: treadmill,
                events: common + fixture.causalEdgeEvents(
                    specificClaim: true,
                    associatedConnectionEpoch: TreadmillConnectionEpoch(
                        rawValue: fixture.uuid(91)
                    )
                )
            ),
            generatedAt: fixture.baseDate.addingTimeInterval(40)
        ))

        for detail in [protocolMismatch, epochMismatch] {
            XCTAssertEqual(detail.quality.commandAcknowledgement.provenEdgeCount, 0)
            XCTAssertEqual(detail.quality.commandFactualResponse.provenEdgeCount, 0)
            XCTAssertNil(detail.quality.commandAcknowledgement.latencySeconds.value)
            XCTAssertNil(detail.quality.commandFactualResponse.latencySeconds.value)
            XCTAssertNil(detail.control.eventAlignedHeartRateResponse.value)
            XCTAssertTrue(detail.quality.issues.contains {
                $0.category == .malformedCorruptEvidence && $0.count >= 2
            })
        }
    }

    func testDecisionDeltasAndEventResponseNeverCrossConnectionEpochs() throws {
        let fixture = AnalysisFixture(sessionSeconds: 30)
        let epochA = TreadmillConnectionEpoch(rawValue: fixture.uuid(92))
        let heartRate = stride(from: 0, through: 25, by: 5).enumerated().map {
            fixture.heartRate(ordinal: $0.offset + 1, seconds: Double($0.element), bpm: 100)
        }
        let detail = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(
                heartRate: heartRate,
                events: fixture.phaseEvents(mainAt: 0, finishedAt: 30)
                    + fixture.causalEdgeEvents(
                        specificClaim: true,
                        firstDecisionConnectionEpoch: epochA
                    )
            ),
            generatedAt: fixture.baseDate.addingTimeInterval(40)
        ))

        XCTAssertNil(detail.control.speedDeltaKilometresPerHour.value)
        XCTAssertNil(detail.control.eventAlignedHeartRateResponse.value)
        XCTAssertEqual(detail.quality.commandFactualResponse.provenEdgeCount, 0)
        XCTAssertTrue(detail.quality.issues.contains {
            $0.code == "unsupported-persisted-command-factual-response-causal-claim"
        })
    }

    func testInvalidDecisionEnqueueAndSendOrderingIsMalformed() throws {
        let fixture = AnalysisFixture(sessionSeconds: 30)
        let heartRate = stride(from: 0, through: 25, by: 5).enumerated().map {
            fixture.heartRate(ordinal: $0.offset + 1, seconds: Double($0.element), bpm: 100)
        }
        let common = fixture.phaseEvents(mainAt: 0, finishedAt: 30)
        let decisionAfterEnqueue = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(
                heartRate: heartRate,
                events: common + fixture.causalEdgeEvents(
                    specificClaim: true,
                    decisionAfterEnqueue: true
                )
            ),
            generatedAt: fixture.baseDate.addingTimeInterval(40)
        ))
        let sendBeforeEnqueue = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(
                heartRate: heartRate,
                events: common + fixture.causalEdgeEvents(
                    specificClaim: true,
                    sendBeforeEnqueue: true
                )
            ),
            generatedAt: fixture.baseDate.addingTimeInterval(40)
        ))

        XCTAssertNil(decisionAfterEnqueue.control.speedDeltaKilometresPerHour.value)
        for detail in [decisionAfterEnqueue, sendBeforeEnqueue] {
            XCTAssertNil(detail.control.eventAlignedHeartRateResponse.value)
            XCTAssertEqual(detail.quality.commandFactualResponse.provenEdgeCount, 0)
            XCTAssertNil(detail.quality.commandFactualResponse.latencySeconds.value)
            XCTAssertTrue(detail.quality.issues.contains {
                $0.category == .malformedCorruptEvidence && $0.count >= 1
            })
        }
    }

    func testEqualOccurredTimeRequiresForwardRecordedCausalOrder() throws {
        let fixture = AnalysisFixture(sessionSeconds: 30)
        let heartRate = stride(from: 0, through: 25, by: 5).enumerated().map {
            fixture.heartRate(ordinal: $0.offset + 1, seconds: Double($0.element), bpm: 100)
        }
        let detail = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(
                heartRate: heartRate,
                events: fixture.phaseEvents(mainAt: 0, finishedAt: 30)
                    + fixture.causalEdgeEvents(
                        specificClaim: true,
                        reversedEqualTimeOrder: true
                    )
            ),
            generatedAt: fixture.baseDate.addingTimeInterval(40)
        ))

        XCTAssertEqual(detail.control.commandCount, 1)
        XCTAssertNil(detail.control.speedDeltaKilometresPerHour.value)
        XCTAssertNil(detail.control.eventAlignedHeartRateResponse.value)
        XCTAssertEqual(detail.quality.commandAcknowledgement.provenEdgeCount, 0)
        XCTAssertEqual(detail.quality.commandFactualResponse.provenEdgeCount, 0)
        XCTAssertTrue(detail.quality.issues.contains {
            $0.category == .malformedCorruptEvidence && $0.count >= 1
        })
    }

    func testDuplicateDecisionIDAndMismatchedSendDecisionAreQuarantined() throws {
        let fixture = AnalysisFixture(sessionSeconds: 30)
        let heartRate = stride(from: 0, through: 25, by: 5).enumerated().map {
            fixture.heartRate(ordinal: $0.offset + 1, seconds: Double($0.element), bpm: 100)
        }
        let common = fixture.phaseEvents(mainAt: 0, finishedAt: 30)
        let duplicateDecision = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(
                heartRate: heartRate,
                events: common + fixture.causalEdgeEvents(
                    specificClaim: true,
                    duplicateDecisionID: true
                )
            ),
            generatedAt: fixture.baseDate.addingTimeInterval(40)
        ))
        let mismatchedSendDecision = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(
                heartRate: heartRate,
                events: common + fixture.causalEdgeEvents(
                    specificClaim: true,
                    mismatchedSendDecision: true
                )
            ),
            generatedAt: fixture.baseDate.addingTimeInterval(40)
        ))

        XCTAssertNil(duplicateDecision.control.speedDeltaKilometresPerHour.value)
        XCTAssertNil(duplicateDecision.control.eventAlignedHeartRateResponse.value)
        XCTAssertTrue(duplicateDecision.quality.issues.contains {
            $0.category == .malformedCorruptEvidence && $0.count >= 1
        })

        XCTAssertEqual(mismatchedSendDecision.quality.commandFactualResponse.provenEdgeCount, 0)
        XCTAssertNil(mismatchedSendDecision.quality.commandFactualResponse.latencySeconds.value)
        XCTAssertNil(mismatchedSendDecision.control.eventAlignedHeartRateResponse.value)
        XCTAssertTrue(mismatchedSendDecision.quality.issues.contains {
            $0.category == .malformedCorruptEvidence && $0.count >= 1
        })
    }

    func testDuplicateTypedEnqueueWithNilDecisionCannotClaimDecisionMetrics() throws {
        let fixture = AnalysisFixture(sessionSeconds: 30)
        let heartRate = stride(from: 0, through: 25, by: 5).enumerated().map {
            fixture.heartRate(ordinal: $0.offset + 1, seconds: Double($0.element), bpm: 100)
        }
        let detail = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(
                heartRate: heartRate,
                events: fixture.phaseEvents(mainAt: 0, finishedAt: 30)
                    + fixture.causalEdgeEvents(
                        specificClaim: true,
                        duplicateCommandEnqueuedWithoutDecision: true
                    )
            ),
            generatedAt: fixture.baseDate.addingTimeInterval(40)
        ))

        XCTAssertNil(detail.control.speedDeltaKilometresPerHour.value)
        XCTAssertNil(detail.control.eventAlignedHeartRateResponse.value)
        XCTAssertEqual(detail.control.commandCount, 1)
        XCTAssertEqual(detail.quality.commandFactualResponse.provenEdgeCount, 0)
        XCTAssertNil(detail.quality.commandFactualResponse.latencySeconds.value)
        XCTAssertTrue(detail.quality.issues.contains {
            $0.category == .malformedCorruptEvidence && $0.count >= 1
        })
    }

    func testNilDecisionTypedChainCannotClaimCommandOrCausalMetrics() throws {
        let fixture = AnalysisFixture(sessionSeconds: 30)
        let heartRate = stride(from: 0, through: 25, by: 5).enumerated().map {
            fixture.heartRate(ordinal: $0.offset + 1, seconds: Double($0.element), bpm: 100)
        }
        let detail = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(
                heartRate: heartRate,
                events: fixture.phaseEvents(mainAt: 0, finishedAt: 30)
                    + fixture.causalEdgeEvents(
                        specificClaim: true,
                        nilDecisionChain: true
                    )
            ),
            generatedAt: fixture.baseDate.addingTimeInterval(40)
        ))

        XCTAssertEqual(detail.control.commandCount, 1)
        XCTAssertEqual(detail.quality.commandAcknowledgement.provenEdgeCount, 0)
        XCTAssertEqual(detail.quality.commandFactualResponse.provenEdgeCount, 0)
        XCTAssertNil(detail.quality.commandAcknowledgement.latencySeconds.value)
        XCTAssertNil(detail.quality.commandFactualResponse.latencySeconds.value)
        XCTAssertNil(detail.control.eventAlignedHeartRateResponse.value)
        XCTAssertTrue(detail.quality.issues.contains {
            $0.category == .malformedCorruptEvidence && $0.count >= 1
        })
    }

    func testConflictingReenteredPhaseEvidenceMakesPhaseMetricsUnavailable() throws {
        let fixture = AnalysisFixture(sessionSeconds: 30)
        let heartRate = stride(from: 0, through: 25, by: 5).enumerated().map {
            fixture.heartRate(ordinal: $0.offset + 1, seconds: Double($0.element), bpm: 100)
        }
        let events = [
            fixture.event(
                ordinal: 1,
                seconds: 0,
                payload: .workoutPhase(WorkoutPhaseTransition(previous: nil, current: .main))
            ),
            fixture.event(
                ordinal: 2,
                seconds: 10,
                payload: .workoutPhase(
                    WorkoutPhaseTransition(previous: .main, current: .cooldown)
                )
            ),
            fixture.event(
                ordinal: 3,
                seconds: 20,
                payload: .workoutPhase(
                    WorkoutPhaseTransition(previous: .cooldown, current: .main)
                )
            ),
            fixture.event(
                ordinal: 4,
                seconds: 30,
                payload: .workoutPhase(
                    WorkoutPhaseTransition(previous: .main, current: .finished)
                )
            ),
        ]
        let detail = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(heartRate: heartRate, events: events),
            generatedAt: fixture.baseDate.addingTimeInterval(40)
        ))

        XCTAssertTrue(detail.control.zoneDurations.isEmpty)
        XCTAssertNil(detail.control.targetRangeDurationSeconds.value)
        XCTAssertNil(detail.control.heartRateError.value)
        XCTAssertNil(detail.control.cooldown.durationSeconds)
        XCTAssertTrue(detail.quality.issues.contains {
            $0.category == .malformedCorruptEvidence
                && $0.code == "invalid-workout-phase-transition-evidence"
        })
        XCTAssertTrue(detail.quality.phases.allSatisfy {
            $0.exclusionCodes.contains("invalid-workout-phase-transition-evidence")
        })
    }

    func testDuplicateCausalAttemptEvidenceIsMalformedAndNeverExceedsCoverage() throws {
        let fixture = AnalysisFixture(sessionSeconds: 30)
        let heartRate = stride(from: 0, through: 25, by: 5).enumerated().map {
            fixture.heartRate(ordinal: $0.offset + 1, seconds: Double($0.element), bpm: 100)
        }
        let common = fixture.phaseEvents(mainAt: 0, finishedAt: 30)
        let duplicateSend = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(
                heartRate: heartRate,
                events: common + fixture.causalEdgeEvents(
                    specificClaim: true,
                    duplicateSend: true
                )
            ),
            generatedAt: fixture.baseDate.addingTimeInterval(40)
        ))
        let duplicateResponse = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(
                heartRate: heartRate,
                events: common + fixture.causalEdgeEvents(
                    specificClaim: true,
                    duplicateResponse: true
                )
            ),
            generatedAt: fixture.baseDate.addingTimeInterval(40)
        ))
        let duplicateAcknowledgement = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(
                heartRate: heartRate,
                events: common + fixture.causalEdgeEvents(
                    specificClaim: true,
                    duplicateAcknowledgement: true
                )
            ),
            generatedAt: fixture.baseDate.addingTimeInterval(40)
        ))

        XCTAssertEqual(duplicateSend.quality.commandAcknowledgement.provenEdgeCount, 0)
        XCTAssertEqual(duplicateSend.quality.commandFactualResponse.provenEdgeCount, 0)
        XCTAssertNil(duplicateSend.quality.commandAcknowledgement.latencySeconds.value)
        XCTAssertNil(duplicateSend.quality.commandFactualResponse.latencySeconds.value)
        XCTAssertNil(duplicateSend.control.eventAlignedHeartRateResponse.value)

        XCTAssertEqual(duplicateResponse.quality.commandFactualResponse.eligibleEdgeCount, 1)
        XCTAssertEqual(duplicateResponse.quality.commandFactualResponse.provenEdgeCount, 0)
        XCTAssertEqual(duplicateResponse.quality.commandFactualResponse.coverageRatio, 0)
        XCTAssertNil(duplicateResponse.quality.commandFactualResponse.latencySeconds.value)
        XCTAssertNil(duplicateResponse.control.eventAlignedHeartRateResponse.value)

        XCTAssertEqual(duplicateAcknowledgement.quality.commandAcknowledgement.eligibleEdgeCount, 1)
        XCTAssertEqual(duplicateAcknowledgement.quality.commandAcknowledgement.provenEdgeCount, 0)
        XCTAssertEqual(duplicateAcknowledgement.quality.commandAcknowledgement.coverageRatio, 0)
        XCTAssertNil(duplicateAcknowledgement.quality.commandAcknowledgement.latencySeconds.value)

        XCTAssertEqual(duplicateSend.control.commandCount, 1)
        XCTAssertNil(duplicateSend.control.speedDeltaKilometresPerHour.value)
        for detail in [duplicateResponse, duplicateAcknowledgement] {
            XCTAssertEqual(detail.control.commandCount, 2)
            XCTAssertEqual(detail.control.speedDeltaKilometresPerHour.value?.count, 1)
        }
        for detail in [duplicateSend, duplicateResponse, duplicateAcknowledgement] {
            for coverage in [
                detail.quality.commandAcknowledgement,
                detail.quality.commandFactualResponse,
            ] {
                if let ratio = coverage.coverageRatio {
                    XCTAssertLessThanOrEqual(ratio, 1)
                }
            }
            XCTAssertTrue(detail.quality.issues.contains {
                $0.category == .malformedCorruptEvidence && $0.count >= 1
            })
        }
    }

    func testGenericLifecycleAttemptAndAckCannotClaimProvenCausalLatency() throws {
        let fixture = AnalysisFixture(sessionSeconds: 20)
        let commandID = CommandID(rawValue: fixture.uuid(5_200))
        let attemptID = CommandAttemptID(rawValue: fixture.uuid(5_201))
        let events = fixture.phaseEvents(mainAt: 0, finishedAt: 20) + [
            fixture.event(
                ordinal: 40,
                seconds: 10,
                payload: .commandLifecycle(CommandLifecycleRecord(
                    commandID: commandID,
                    decisionID: nil,
                    lifecycle: .sendAttempt(attemptID: attemptID, attemptNumber: 1)
                ))
            ),
            fixture.event(
                ordinal: 41,
                seconds: 11,
                payload: .commandLifecycle(CommandLifecycleRecord(
                    commandID: commandID,
                    decisionID: nil,
                    lifecycle: .acknowledged(attemptID: attemptID)
                ))
            ),
        ]
        let detail = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(
                heartRate: [
                    fixture.heartRate(ordinal: 1, seconds: 0, bpm: 100),
                    fixture.heartRate(ordinal: 2, seconds: 5, bpm: 100),
                    fixture.heartRate(ordinal: 3, seconds: 10, bpm: 100),
                    fixture.heartRate(ordinal: 4, seconds: 15, bpm: 100),
                ],
                events: events
            ),
            generatedAt: fixture.baseDate.addingTimeInterval(30)
        ))

        XCTAssertEqual(detail.quality.commandAcknowledgement.eligibleEdgeCount, 0)
        XCTAssertEqual(detail.quality.commandAcknowledgement.provenEdgeCount, 0)
        XCTAssertNil(detail.quality.commandAcknowledgement.latencySeconds.value)
        XCTAssertEqual(detail.control.commandCount, 0)
        XCTAssertTrue(detail.quality.issues.contains {
            $0.category == .malformedCorruptEvidence && $0.count >= 2
        })
    }

    func testGenericEnqueuedCannotLinkInformativeDecisionToTypedResponse() throws {
        let fixture = AnalysisFixture(sessionSeconds: 30)
        let typedWithoutEnqueued = fixture.causalEdgeEvents(specificClaim: true).filter { event in
            guard case .treadmillEvidence(.commandEnqueued) = event.payload.payload else {
                return true
            }
            return false
        }
        let genericEnqueued = fixture.event(
            ordinal: 45,
            seconds: 11,
            payload: .commandLifecycle(CommandLifecycleRecord(
                commandID: CommandID(rawValue: fixture.uuid(5_102)),
                decisionID: DecisionID(rawValue: fixture.uuid(5_101)),
                lifecycle: .enqueued(kind: .other("fixture-generic"))
            ))
        )
        let heartRate = stride(from: 0, through: 25, by: 5).enumerated().map {
            fixture.heartRate(ordinal: $0.offset + 1, seconds: Double($0.element), bpm: 100)
        }
        let detail = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(
                heartRate: heartRate,
                events: fixture.phaseEvents(mainAt: 0, finishedAt: 30)
                    + typedWithoutEnqueued
                    + [genericEnqueued]
            ),
            generatedAt: fixture.baseDate.addingTimeInterval(40)
        ))

        XCTAssertEqual(detail.control.commandCount, 0)
        XCTAssertNil(detail.control.eventAlignedHeartRateResponse.value)
        XCTAssertEqual(detail.quality.commandFactualResponse.provenEdgeCount, 0)
        XCTAssertNil(detail.quality.commandFactualResponse.latencySeconds.value)
        XCTAssertTrue(detail.quality.issues.contains {
            $0.category == .malformedCorruptEvidence && $0.count >= 1
        })
    }

    func testRetryLatencyDoesNotCrossProtocolOrConnectionEpoch() throws {
        let fixture = AnalysisFixture(sessionSeconds: 30)
        let commandID = CommandID(rawValue: fixture.uuid(5_300))
        let epochA = TreadmillConnectionEpoch(rawValue: fixture.uuid(93))
        let epochB = TreadmillConnectionEpoch(rawValue: fixture.uuid(94))
        let attempts = [
            TreadmillCommandSendAttemptEvidence(
                commandID: commandID,
                decisionID: nil,
                attemptID: CommandAttemptID(rawValue: fixture.uuid(5_301)),
                attemptNumber: 1,
                protocolKind: .ftms,
                connectionEpoch: epochA,
                sentAt: fixture.baseDate.addingTimeInterval(10),
                writeType: .withResponse
            ),
            TreadmillCommandSendAttemptEvidence(
                commandID: commandID,
                decisionID: nil,
                attemptID: CommandAttemptID(rawValue: fixture.uuid(5_302)),
                attemptNumber: 2,
                protocolKind: .ftms,
                connectionEpoch: epochB,
                sentAt: fixture.baseDate.addingTimeInterval(15),
                writeType: .withResponse
            ),
            TreadmillCommandSendAttemptEvidence(
                commandID: commandID,
                decisionID: nil,
                attemptID: CommandAttemptID(rawValue: fixture.uuid(5_303)),
                attemptNumber: 3,
                protocolKind: .walkingPad,
                connectionEpoch: epochA,
                sentAt: fixture.baseDate.addingTimeInterval(20),
                writeType: .withResponse
            ),
        ]
        let sendEvents = attempts.enumerated().map { index, attempt in
            fixture.event(
                ordinal: 50 + index,
                seconds: Double(10 + (index * 5)),
                payload: .treadmillEvidence(.sendAttempt(attempt))
            )
        }
        let detail = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(
                events: fixture.phaseEvents(mainAt: 0, finishedAt: 30) + sendEvents
            ),
            generatedAt: fixture.baseDate.addingTimeInterval(40)
        ))

        XCTAssertNil(detail.control.retryAttemptLatencySeconds.value)
    }

    func testValidPersistedAttemptSequenceProducesRetryLatencyWithoutCausalProof() throws {
        let fixture = AnalysisFixture(sessionSeconds: 30)
        let retry = TreadmillCommandSendAttemptEvidence(
            commandID: CommandID(rawValue: fixture.uuid(5_102)),
            decisionID: DecisionID(rawValue: fixture.uuid(5_101)),
            attemptID: CommandAttemptID(rawValue: fixture.uuid(5_303)),
            attemptNumber: 2,
            protocolKind: .ftms,
            connectionEpoch: TreadmillConnectionEpoch(rawValue: fixture.uuid(90)),
            sentAt: fixture.baseDate.addingTimeInterval(14),
            writeType: .withResponse
        )
        let events = fixture.causalEdgeEvents(specificClaim: false) + [
            fixture.event(
                ordinal: 59,
                seconds: 14,
                payload: .treadmillEvidence(.sendAttempt(retry))
            ),
        ]
        let detail = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(events: fixture.phaseEvents(mainAt: 0, finishedAt: 30) + events),
            generatedAt: fixture.baseDate.addingTimeInterval(40)
        ))

        XCTAssertEqual(
            try XCTUnwrap(detail.control.retryAttemptLatencySeconds.value).mean,
            2,
            accuracy: 0.000_001
        )
        XCTAssertNil(detail.quality.commandAcknowledgement.latencySeconds.value)
        XCTAssertNil(detail.quality.commandFactualResponse.latencySeconds.value)
        XCTAssertNil(detail.control.eventAlignedHeartRateResponse.value)
        XCTAssertEqual(detail.quality.commandAcknowledgement.unknownAssociationCount, 1)
        XCTAssertEqual(detail.quality.commandFactualResponse.unknownAssociationCount, 1)
    }

    func testDuplicateAttemptNumberQuarantinesConflictingAttemptsAndEdges() throws {
        let fixture = AnalysisFixture(sessionSeconds: 30)
        let commandID = CommandID(rawValue: fixture.uuid(5_102))
        let decisionID = DecisionID(rawValue: fixture.uuid(5_101))
        let epoch = TreadmillConnectionEpoch(rawValue: fixture.uuid(90))
        let conflictingSend = TreadmillCommandSendAttemptEvidence(
            commandID: commandID,
            decisionID: decisionID,
            attemptID: CommandAttemptID(rawValue: fixture.uuid(5_304)),
            attemptNumber: 1,
            protocolKind: .ftms,
            connectionEpoch: epoch,
            sentAt: fixture.baseDate.addingTimeInterval(14),
            writeType: .withResponse
        )
        let events = fixture.causalEdgeEvents(specificClaim: true) + [
            fixture.event(
                ordinal: 60,
                seconds: 14,
                payload: .treadmillEvidence(.sendAttempt(conflictingSend))
            ),
        ]
        let detail = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(events: fixture.phaseEvents(mainAt: 0, finishedAt: 30) + events),
            generatedAt: fixture.baseDate.addingTimeInterval(40)
        ))

        XCTAssertNil(detail.control.retryAttemptLatencySeconds.value)
        XCTAssertEqual(detail.control.commandCount, 1)
        XCTAssertNil(detail.control.speedDeltaKilometresPerHour.value)
        XCTAssertEqual(detail.quality.commandAcknowledgement.eligibleEdgeCount, 0)
        XCTAssertEqual(detail.quality.commandAcknowledgement.provenEdgeCount, 0)
        XCTAssertEqual(detail.quality.commandFactualResponse.eligibleEdgeCount, 0)
        XCTAssertEqual(detail.quality.commandFactualResponse.provenEdgeCount, 0)
        XCTAssertTrue(detail.quality.issues.contains {
            $0.category == .malformedCorruptEvidence && $0.count >= 1
        })
    }

    func testRetryAttemptRecordedBeforePriorAttemptIsQuarantined() throws {
        let fixture = AnalysisFixture(sessionSeconds: 30)
        let commandID = CommandID(rawValue: fixture.uuid(5_102))
        let decisionID = DecisionID(rawValue: fixture.uuid(5_101))
        let epoch = TreadmillConnectionEpoch(rawValue: fixture.uuid(90))
        let reversedRetry = TreadmillCommandSendAttemptEvidence(
            commandID: commandID,
            decisionID: decisionID,
            attemptID: CommandAttemptID(rawValue: fixture.uuid(5_305)),
            attemptNumber: 2,
            protocolKind: .ftms,
            connectionEpoch: epoch,
            sentAt: fixture.baseDate.addingTimeInterval(12),
            writeType: .withResponse
        )
        let events = fixture.causalEdgeEvents(specificClaim: true) + [
            fixture.event(
                ordinal: 61,
                seconds: 12,
                recordedSeconds: 12.0005,
                payload: .treadmillEvidence(.sendAttempt(reversedRetry))
            ),
        ]
        let detail = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(events: fixture.phaseEvents(mainAt: 0, finishedAt: 30) + events),
            generatedAt: fixture.baseDate.addingTimeInterval(40)
        ))

        XCTAssertNil(detail.control.retryAttemptLatencySeconds.value)
        XCTAssertEqual(detail.control.commandCount, 1)
        XCTAssertNil(detail.control.speedDeltaKilometresPerHour.value)
        XCTAssertEqual(detail.quality.commandAcknowledgement.eligibleEdgeCount, 0)
        XCTAssertEqual(detail.quality.commandAcknowledgement.provenEdgeCount, 0)
        XCTAssertEqual(detail.quality.commandFactualResponse.eligibleEdgeCount, 0)
        XCTAssertEqual(detail.quality.commandFactualResponse.provenEdgeCount, 0)
        XCTAssertTrue(detail.quality.issues.contains {
            $0.category == .malformedCorruptEvidence && $0.count >= 1
        })
    }

    func testInvalidRetryOrderQuarantinesEntireCommandScope() throws {
        let fixture = AnalysisFixture(sessionSeconds: 30)
        let commandID = CommandID(rawValue: fixture.uuid(5_102))
        let decisionID = DecisionID(rawValue: fixture.uuid(5_101))
        let epoch = TreadmillConnectionEpoch(rawValue: fixture.uuid(90))
        let attempt2 = TreadmillCommandSendAttemptEvidence(
            commandID: commandID,
            decisionID: decisionID,
            attemptID: CommandAttemptID(rawValue: fixture.uuid(5_306)),
            attemptNumber: 2,
            protocolKind: .ftms,
            connectionEpoch: epoch,
            sentAt: fixture.baseDate.addingTimeInterval(11.5),
            writeType: .withResponse
        )
        let attempt3ID = CommandAttemptID(rawValue: fixture.uuid(5_307))
        let attempt3 = TreadmillCommandSendAttemptEvidence(
            commandID: commandID,
            decisionID: decisionID,
            attemptID: attempt3ID,
            attemptNumber: 3,
            protocolKind: .ftms,
            connectionEpoch: epoch,
            sentAt: fixture.baseDate.addingTimeInterval(11.75),
            writeType: .withResponse
        )
        let acknowledgement = LegacyAcknowledgementObservation(
            protocolKind: .ftms,
            connectionEpoch: epoch,
            receivedAt: fixture.baseDate.addingTimeInterval(15),
            recordedAt: fixture.baseDate.addingTimeInterval(15),
            association: .deterministicallyCorrelated(
                commandID: commandID,
                attemptID: attempt3ID
            )
        )
        let events = fixture.causalEdgeEvents(specificClaim: false) + [
            fixture.event(
                ordinal: 62,
                seconds: 11.5,
                payload: .treadmillEvidence(.sendAttempt(attempt2))
            ),
            fixture.event(
                ordinal: 63,
                seconds: 11.75,
                payload: .treadmillEvidence(.sendAttempt(attempt3))
            ),
            fixture.event(
                ordinal: 64,
                seconds: 15,
                payload: .treadmillEvidence(.acknowledgement(acknowledgement))
            ),
        ]
        let detail = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(events: fixture.phaseEvents(mainAt: 0, finishedAt: 30) + events),
            generatedAt: fixture.baseDate.addingTimeInterval(40)
        ))

        XCTAssertNil(detail.control.retryAttemptLatencySeconds.value)
        XCTAssertEqual(detail.control.commandCount, 1)
        XCTAssertNil(detail.control.speedDeltaKilometresPerHour.value)
        XCTAssertEqual(detail.quality.commandAcknowledgement.eligibleEdgeCount, 0)
        XCTAssertEqual(detail.quality.commandAcknowledgement.provenEdgeCount, 0)
        XCTAssertTrue(detail.quality.issues.contains {
            $0.category == .malformedCorruptEvidence && $0.count >= 1
        })
    }

    func testDuplicateSetSpeedBindingsForOneDecisionAreQuarantined() throws {
        let fixture = AnalysisFixture(sessionSeconds: 30)
        let decisionID = DecisionID(rawValue: fixture.uuid(5_101))
        let commandID = CommandID(rawValue: fixture.uuid(5_308))
        let epoch = TreadmillConnectionEpoch(rawValue: fixture.uuid(90))
        let duplicateEnqueue = TreadmillCommandEnqueuedEvidence(
            commandID: commandID,
            decisionID: decisionID,
            kind: .setSpeed(CommandedSpeed(
                nativeValue: 400,
                nativeUnit: .controllerNative(code: "ftms_hundredths_kmh")
            )),
            protocolKind: .ftms,
            connectionEpoch: epoch,
            enqueuedAt: fixture.baseDate.addingTimeInterval(11.1)
        )
        let duplicateSend = TreadmillCommandSendAttemptEvidence(
            commandID: commandID,
            decisionID: decisionID,
            attemptID: CommandAttemptID(rawValue: fixture.uuid(5_309)),
            attemptNumber: 1,
            protocolKind: .ftms,
            connectionEpoch: epoch,
            sentAt: fixture.baseDate.addingTimeInterval(12.1),
            writeType: .withResponse
        )
        let events = fixture.causalEdgeEvents(specificClaim: true) + [
            fixture.event(
                ordinal: 65,
                seconds: 11.1,
                payload: .treadmillEvidence(.commandEnqueued(duplicateEnqueue))
            ),
            fixture.event(
                ordinal: 66,
                seconds: 12.1,
                payload: .treadmillEvidence(.sendAttempt(duplicateSend))
            ),
        ]
        let detail = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(events: fixture.phaseEvents(mainAt: 0, finishedAt: 30) + events),
            generatedAt: fixture.baseDate.addingTimeInterval(40)
        ))

        XCTAssertEqual(detail.control.commandCount, 1)
        XCTAssertNil(detail.control.eventAlignedHeartRateResponse.value)
        XCTAssertEqual(detail.quality.commandAcknowledgement.provenEdgeCount, 0)
        XCTAssertEqual(detail.quality.commandFactualResponse.provenEdgeCount, 0)
        XCTAssertTrue(detail.quality.issues.contains {
            $0.category == .malformedCorruptEvidence && $0.count >= 2
        })
    }

    func testDistinctCommandKindsMayShareOneTypedDecision() throws {
        let fixture = AnalysisFixture(sessionSeconds: 30)
        let decisionID = DecisionID(rawValue: fixture.uuid(5_101))
        let epoch = TreadmillConnectionEpoch(rawValue: fixture.uuid(90))
        let startEnqueue = TreadmillCommandEnqueuedEvidence(
            commandID: CommandID(rawValue: fixture.uuid(5_310)),
            decisionID: decisionID,
            kind: .other("start"),
            protocolKind: .ftms,
            connectionEpoch: epoch,
            enqueuedAt: fixture.baseDate.addingTimeInterval(10.5)
        )
        let events = fixture.causalEdgeEvents(specificClaim: true) + [
            fixture.event(
                ordinal: 67,
                seconds: 10.5,
                payload: .treadmillEvidence(.commandEnqueued(startEnqueue))
            ),
        ]
        let detail = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(events: fixture.phaseEvents(mainAt: 0, finishedAt: 30) + events),
            generatedAt: fixture.baseDate.addingTimeInterval(40)
        ))

        XCTAssertEqual(detail.control.commandCount, 3)
        XCTAssertEqual(detail.quality.commandAcknowledgement.provenEdgeCount, 0)
        XCTAssertEqual(detail.quality.commandFactualResponse.provenEdgeCount, 0)
        XCTAssertNil(detail.quality.commandAcknowledgement.latencySeconds.value)
        XCTAssertNil(detail.quality.commandFactualResponse.latencySeconds.value)
    }

    func testStableFactualSpeedDriftAndCommandDomainSpeedDeltasAreVersionedMetrics() throws {
        let fixture = AnalysisFixture(sessionSeconds: 120)
        let heartRate = stride(from: 0, through: 115, by: 5).enumerated().map {
            fixture.heartRate(
                ordinal: $0.offset + 1,
                seconds: Double($0.element),
                bpm: UInt16(80 + (2 * $0.offset))
            )
        }
        let treadmill = stride(from: 0, through: 115, by: 5).enumerated().map {
            fixture.treadmill(
                ordinal: $0.offset + 1,
                seconds: Double($0.element),
                speed: 4,
                factual: true
            )
        }
        let decisions = fixture.speedDecisionEvents(speeds: [3, 4, 3.5], at: [0, 20, 40])
        let detail = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(
                heartRate: heartRate,
                treadmill: treadmill,
                events: fixture.phaseEvents(mainAt: 0, finishedAt: 120) + decisions
            ),
            generatedAt: fixture.baseDate.addingTimeInterval(130)
        ))

        XCTAssertNotNil(detail.control.stableSpeedHeartRateDrift.value)
        XCTAssertGreaterThan(
            detail.control.stableSpeedHeartRateDrift.value!.slopeBeatsPerMinutePerMinute,
            0
        )
        XCTAssertEqual(detail.control.speedDeltaKilometresPerHour.value?.count, 2)
        XCTAssertEqual(detail.control.speedDeltaKilometresPerHour.value?.minimum, -0.5)
        XCTAssertEqual(detail.control.speedDeltaKilometresPerHour.value?.maximum, 1)
        XCTAssertGreaterThan(detail.control.overshoot.value!.durationSeconds, 0)
        XCTAssertGreaterThan(detail.control.undershoot.value!.durationSeconds, 0)
    }

    func testCooldownRecoveryUsesNamedTimestampWindowsAndReportsMissingCoverage() throws {
        let fixture = AnalysisFixture(sessionSeconds: 150)
        let completeHeartRate = stride(from: 0, through: 150, by: 5).enumerated().map { item in
            let seconds = Double(item.element)
            let bpm = seconds < 20 ? 120 : 140 - Int((seconds - 20) / 5)
            return fixture.heartRate(
                ordinal: item.offset + 1,
                seconds: seconds,
                bpm: UInt16(max(90, bpm))
            )
        }
        let treadmill = stride(from: 0, through: 145, by: 5).enumerated().map { item in
            fixture.treadmill(
                ordinal: item.offset + 1,
                seconds: Double(item.element),
                speed: item.element >= 60 ? 2 : 3,
                factual: true
            )
        }
        let events = fixture.cooldownEvents(start: 20, end: 150, target: 120)
        let complete = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(heartRate: completeHeartRate, treadmill: treadmill, events: events),
            generatedAt: fixture.baseDate.addingTimeInterval(160)
        )).control.cooldown

        XCTAssertEqual(complete.hrr10.value!, 2, accuracy: 0.000_001)
        XCTAssertEqual(complete.hrr30.value!, 6, accuracy: 0.000_001)
        XCTAssertEqual(complete.hrr60.value!, 12, accuracy: 0.000_001)
        XCTAssertEqual(complete.hrr120.value!, 24, accuracy: 0.000_001)
        XCTAssertLessThan(complete.recoverySlopeBeatsPerMinutePerMinute.value!, 0)
        XCTAssertGreaterThan(complete.minimumFactualSpeedSeconds.value!, 0)
        XCTAssertEqual(complete.finishReason.value, "completed")
        XCTAssertNil(complete.timeoutBlocker.value)

        let missingWindow = completeHeartRate.filter {
            let time = $0.timestamp.effectiveElapsed.seconds
            return !(75...85).contains(time)
        }
        let missing = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(heartRate: missingWindow, treadmill: treadmill, events: events),
            generatedAt: fixture.baseDate.addingTimeInterval(160)
        )).control.cooldown
        XCTAssertNil(missing.hrr60.value)
        XCTAssertEqual(missing.hrr60.confidence, .unavailable)
        XCTAssertNotNil(missing.hrr10.value)
    }

    func testUncoveredStateMetricsAreUnavailableInsteadOfFabricatedZero() throws {
        let fixture = AnalysisFixture(sessionSeconds: 40)
        let detail = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(
                events: fixture.cooldownEvents(start: 10, end: 40, target: 120)
            ),
            generatedAt: fixture.baseDate.addingTimeInterval(50)
        ))

        XCTAssertTrue(detail.control.zoneDurations.isEmpty)
        XCTAssertNil(detail.control.overshoot.value)
        XCTAssertNil(detail.control.undershoot.value)
        XCTAssertNil(detail.control.cooldown.heartRateBelowTargetSeconds.value)
        XCTAssertNil(detail.control.cooldown.minimumFactualSpeedSeconds.value)
        XCTAssertNil(detail.control.cooldown.targetAndMinimumSpeedSeconds.value)
        XCTAssertNil(detail.control.cooldown.targetAndMinimumSpeedMaximumStreakSeconds.value)
    }

    func testMalformedConfigurationLowersSessionAndPhaseQualityGrades() throws {
        let fixture = AnalysisFixture(
            sessionSeconds: 10,
            configurationPayload: Data(#"{"targetHeartRate":100}"#.utf8)
        )
        let detail = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(
                heartRate: [
                    fixture.heartRate(ordinal: 1, seconds: 0, bpm: 100),
                    fixture.heartRate(ordinal: 2, seconds: 5, bpm: 100),
                ],
                events: fixture.phaseEvents(mainAt: 0, finishedAt: 10)
            ),
            generatedAt: fixture.baseDate.addingTimeInterval(20)
        ))

        XCTAssertEqual(detail.quality.heartRateCoverage.coverageRatio, 1)
        XCTAssertEqual(detail.quality.sessionGrade, .low)
        XCTAssertEqual(detail.quality.phases.map(\.grade), [.low])
        XCTAssertEqual(
            detail.quality.phases.first?.exclusionCodes,
            ["configuration-payload-unavailable", "factual-treadmill-uncovered-time"]
        )
        XCTAssertTrue(detail.quality.issues.contains {
            $0.category == .malformedCorruptEvidence
                && $0.code == "configuration-payload-unavailable"
        })
    }

    func testCoverageExclusionDetailsUseLocaleIndependentDecimalFormatting() throws {
        let fixture = AnalysisFixture(sessionSeconds: 10)
        let detail = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(
                heartRate: [fixture.heartRate(ordinal: 1, seconds: 0, bpm: 100)],
                events: fixture.phaseEvents(mainAt: 0, finishedAt: 10)
            ),
            generatedAt: fixture.baseDate.addingTimeInterval(20)
        ))
        let coverageIssue = try XCTUnwrap(detail.quality.issues.first {
            $0.code == "heart-rate-uncovered-time"
        })
        let frenchFormatting = String(
            format: "%.3f seconds",
            locale: Locale(identifier: "fr_FR"),
            arguments: [3.0]
        )

        XCTAssertEqual(coverageIssue.detail, "3.000 seconds")
        XCTAssertNotEqual(coverageIssue.detail, frenchFormatting)
        XCTAssertEqual(WorkoutAnalyzerV1.secondsDetail(3), "3.000 seconds")
    }

    func testEvidenceHashAndLogicalRecomputeAreDeterministicAcrossInputOrdering() throws {
        let fixture = AnalysisFixture(sessionSeconds: 20)
        let heartRate = [
            fixture.heartRate(ordinal: 1, seconds: 0, bpm: 100),
            fixture.heartRate(ordinal: 2, seconds: 5, bpm: 105),
            fixture.heartRate(ordinal: 3, seconds: 10, bpm: 110),
        ]
        let events = fixture.phaseEvents(mainAt: 0, finishedAt: 20)
        let first = try WorkoutAnalyzerV1.analyze(
            fixture.input(heartRate: heartRate, events: events),
            generatedAt: fixture.baseDate.addingTimeInterval(30)
        )
        let second = try WorkoutAnalyzerV1.analyze(
            fixture.input(heartRate: heartRate.reversed(), events: events.reversed()),
            generatedAt: fixture.baseDate.addingTimeInterval(40)
        )

        XCTAssertEqual(first.evidenceHash, second.evidenceHash)
        XCTAssertEqual(first.analysisID, second.analysisID)
        XCTAssertEqual(first.recordID, second.recordID)
        XCTAssertEqual(first.logicalResult, second.logicalResult)
        XCTAssertNotEqual(first.generatedAt, second.generatedAt)
    }

    func testEqualTimestampCooldownEventsUseDeterministicRecordIDTieBreak() throws {
        let fixture = AnalysisFixture(sessionSeconds: 150)
        let tieTime = 149.999
        let events = fixture.cooldownEvents(start: 20, end: 150, target: 120) + [
            fixture.event(
                ordinal: 20,
                seconds: tieTime,
                payload: .cooldown(CooldownEvent(lifecycle: .cancelled, targetHeartRate: 120))
            ),
            fixture.event(
                ordinal: 21,
                seconds: tieTime,
                payload: .cooldown(CooldownEvent(lifecycle: .insufficient, targetHeartRate: 120))
            ),
        ]
        let first = try WorkoutAnalyzerV1.analyze(
            fixture.input(events: events),
            generatedAt: fixture.baseDate.addingTimeInterval(160)
        )
        let second = try WorkoutAnalyzerV1.analyze(
            fixture.input(events: events.reversed()),
            generatedAt: fixture.baseDate.addingTimeInterval(160)
        )

        XCTAssertEqual(first.evidenceHash, second.evidenceHash)
        XCTAssertEqual(first.logicalResult, second.logicalResult)
        XCTAssertEqual(try decodeDetail(first).control.cooldown.finishReason.value, "insufficient")
        XCTAssertEqual(try decodeDetail(second).control.cooldown.finishReason.value, "insufficient")
    }

    func testCooldownTerminalLifecycleAtPhaseEndpointIsIncluded() throws {
        let fixture = AnalysisFixture(sessionSeconds: 150)
        let events = fixture.cooldownEvents(start: 20, end: 150, target: 120) + [
            fixture.event(
                ordinal: 30,
                seconds: 150,
                payload: .cooldown(CooldownEvent(lifecycle: .cancelled, targetHeartRate: 120))
            ),
        ]
        let detail = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(events: events),
            generatedAt: fixture.baseDate.addingTimeInterval(160)
        ))

        XCTAssertEqual(detail.control.cooldown.finishReason.value, "cancelled")
    }

    func testCanonicalFrameCannotBridgeNativeObservationGap() throws {
        let fixture = AnalysisFixture(sessionSeconds: 20)
        let heartRate = fixture.heartRate(ordinal: 1, seconds: 0, bpm: 100)
        let events = fixture.phaseEvents(mainAt: 0, finishedAt: 20)
        let withoutFrame = try WorkoutAnalyzerV1.analyze(
            fixture.input(heartRate: [heartRate], events: events),
            generatedAt: fixture.baseDate.addingTimeInterval(30)
        )
        let withFrame = try WorkoutAnalyzerV1.analyze(
            fixture.input(
                heartRate: [heartRate],
                events: events,
                frames: [fixture.staleFrame(heartRate: heartRate, seconds: 15)]
            ),
            generatedAt: fixture.baseDate.addingTimeInterval(30)
        )
        let withoutDetail = try decodeDetail(withoutFrame)
        let withDetail = try decodeDetail(withFrame)

        XCTAssertEqual(withoutDetail.quality.heartRateCoverage.coveredSeconds, 7)
        XCTAssertEqual(withDetail.quality.heartRateCoverage.coveredSeconds, 7)
        XCTAssertEqual(withoutFrame.keyMetrics, withFrame.keyMetrics)
        XCTAssertEqual(withoutDetail.control, withDetail.control)
        XCTAssertNotEqual(withoutFrame.evidenceHash, withFrame.evidenceHash)
    }

    func testSourceTransitionEndsPriorHeartRateHold() throws {
        let fixture = AnalysisFixture(sessionSeconds: 20)
        let sourceB = fixture.source(ordinal: 2, kind: .bluetooth)
        let events = fixture.phaseEvents(mainAt: 0, finishedAt: 20) + [
            fixture.event(
                ordinal: 90,
                seconds: 5,
                payload: .sourceTransition(SourceTransition(
                    previousSourceID: fixture.primarySource.id,
                    currentSourceID: sourceB.id,
                    reason: "fixture-switch"
                ))
            ),
        ]
        let detail = try decodeDetail(WorkoutAnalyzerV1.analyze(
            fixture.input(
                heartRate: [
                    fixture.heartRate(ordinal: 1, seconds: 0, bpm: 100),
                    fixture.heartRate(
                        ordinal: 2,
                        seconds: 10,
                        bpm: 110,
                        source: sourceB
                    ),
                ],
                events: events
            ),
            generatedAt: fixture.baseDate.addingTimeInterval(30)
        ))

        XCTAssertEqual(detail.quality.heartRateCoverage.coveredSeconds, 12)
        XCTAssertEqual(detail.quality.heartRateCoverage.uncoveredSeconds, 8)
        XCTAssertEqual(detail.quality.sourceSwitchCount, 1)
    }

    private func decodeDetail(_ result: WorkoutAnalysisResult) throws -> WorkoutAnalysisDetailV1 {
        XCTAssertEqual(result.detailSchemaVersion, WorkoutAnalysisDetailV1.schemaVersion)
        return try JSONDecoder().decode(
            WorkoutAnalysisDetailV1.self,
            from: result.versionedDetailPayload
        )
    }
}

private struct AnalysisFixture {
    let baseDate = Date(timeIntervalSince1970: 1_900_000_000)
    let session: WorkoutSessionRecord
    let primarySource: SignalSourceIdentity
    let treadmillSource: SignalSourceIdentity

    init(
        sessionSeconds: Double,
        lifecycle: SessionLifecycleState = .completed,
        recorderComplete: Bool = true,
        lostNative: UInt64 = 0,
        incompleteReason: String? = nil,
        configurationPayload: Data = Data(
            #"{"targetHeartRate":100,"heartRateZones":[90,110,130,150],"cooldownTargetHeartRate":120,"cooldownMinimumSpeedKilometresPerHour":2.0}"#.utf8
        )
    ) {
        let sessionID = SessionID(rawValue: Self.uuid(1))
        primarySource = SignalSourceIdentity(
            id: SourceID(rawValue: Self.uuid(2)),
            providerKind: .watchMediated,
            stableLocalKey: "fixture-watch"
        )
        treadmillSource = SignalSourceIdentity(
            id: SourceID(rawValue: Self.uuid(3)),
            providerKind: .treadmillProtocol,
            stableLocalKey: "fixture-treadmill"
        )
        session = WorkoutSessionRecord(
            recordID: RecordID(rawValue: Self.uuid(4)),
            sessionID: sessionID,
            profileLocalIdentifier: "fixture-profile",
            lifecycleState: lifecycle,
            workoutMode: .heartRateControlled,
            startedAt: baseDate,
            endedAt: baseDate.addingTimeInterval(sessionSeconds),
            endedElapsed: Self.elapsed(sessionSeconds),
            incompleteReason: incompleteReason,
            appContext: AppRuntimeContext(
                appVersion: "1",
                buildNumber: "1",
                operatingSystemVersion: "test"
            ),
            versions: RuntimeVersionContext(
                telemetrySchema: TelemetrySchemaVersion(rawValue: "1.0.0"),
                algorithm: AlgorithmVersion(rawValue: "fixture-algorithm"),
                safetyPolicy: SafetyPolicyVersion(rawValue: "fixture-safety"),
                workoutProtocol: WorkoutProtocolVersion(rawValue: "fixture-workout")
            ),
            configuration: ImmutableConfigurationSnapshot(
                id: ConfigurationSnapshotID(rawValue: Self.uuid(5)),
                formatVersion: 1,
                format: .canonicalJSON,
                canonicalPayload: configurationPayload,
                contentHash: ContentHash(
                    algorithm: .sha256,
                    lowercaseHexDigest: String(repeating: "a", count: 64)
                )
            ),
            healthKitWorkoutIdentifier: nil,
            treadmill: KnownTreadmillMetadata(model: "fixture", protocolName: "ftms"),
            recorderHealth: RecorderHealthSummary(
                isComplete: recorderComplete,
                lostCriticalRecordCount: 0,
                lostNativeRecordCount: lostNative,
                lastPersistedElapsed: Self.elapsed(sessionSeconds)
            )
        )
    }

    func input<H: Sequence, T: Sequence, E: Sequence, F: Sequence>(
        heartRate: H = [HeartRateObservation](),
        treadmill: T = [TreadmillObservation](),
        events: E,
        frames: F = [CanonicalFrame]()
    ) -> WorkoutAnalysisInput where
        H.Element == HeartRateObservation,
        T.Element == TreadmillObservation,
        E.Element == WorkoutEvent,
        F.Element == CanonicalFrame
    {
        WorkoutAnalysisInput(
            session: session,
            heartRate: Array(heartRate),
            treadmill: Array(treadmill),
            events: Array(events),
            frames: Array(frames)
        )
    }

    func source(ordinal: Int, kind: SignalProviderKind) -> SignalSourceIdentity {
        SignalSourceIdentity(
            id: SourceID(rawValue: uuid(100 + ordinal)),
            providerKind: kind,
            stableLocalKey: "fixture-source-\(ordinal)"
        )
    }

    func heartRate(
        ordinal: Int,
        seconds: Double,
        bpm: UInt16,
        source: SignalSourceIdentity? = nil,
        quality: QualityFlags = [],
        measuredElapsedAvailable: Bool = true
    ) -> HeartRateObservation {
        HeartRateObservation(
            recordID: RecordID(rawValue: uuid(1_000 + ordinal)),
            observationID: ObservationID(rawValue: uuid(2_000 + ordinal)),
            sessionID: session.sessionID,
            source: source ?? primarySource,
            beatsPerMinute: bpm,
            arrivalOrder: UInt64(ordinal),
            providerSequence: Int64(ordinal),
            providerSampleIdentity: nil,
            timestamp: timestamp(seconds: seconds, measuredElapsedAvailable: measuredElapsedAvailable),
            provenance: .reportedByProvider,
            freshness: freshness(seconds: seconds),
            quality: quality,
            controlUse: .acceptedNotUsed
        )
    }

    func treadmill(
        ordinal: Int,
        seconds: Double,
        speed: Double,
        factual: Bool,
        quality: QualityFlags = []
    ) -> TreadmillObservation {
        TreadmillObservation(
            recordID: RecordID(rawValue: uuid(3_000 + ordinal)),
            observationID: ObservationID(rawValue: uuid(4_000 + ordinal)),
            sessionID: session.sessionID,
            source: treadmillSource,
            nativeSpeed: NativeTreadmillSpeed(
                value: speed,
                unit: factual ? .kilometresPerHour : .unknown
            ),
            deviceState: .moving,
            arrivalOrder: UInt64(ordinal),
            timestamp: timestamp(seconds: seconds),
            provenance: .decodedDeviceReport,
            freshness: freshness(seconds: seconds),
            quality: quality
        )
    }

    func phaseEvents(mainAt: Double, finishedAt: Double) -> [WorkoutEvent] {
        [
            event(
                ordinal: 1,
                seconds: mainAt,
                payload: .workoutPhase(WorkoutPhaseTransition(previous: nil, current: .main))
            ),
            event(
                ordinal: 2,
                seconds: finishedAt,
                payload: .workoutPhase(WorkoutPhaseTransition(previous: .main, current: .finished))
            ),
        ]
    }

    func cooldownEvents(start: Double, end: Double, target: UInt16) -> [WorkoutEvent] {
        [
            event(
                ordinal: 1,
                seconds: 0,
                payload: .workoutPhase(WorkoutPhaseTransition(previous: nil, current: .main))
            ),
            event(
                ordinal: 2,
                seconds: start,
                payload: .workoutPhase(WorkoutPhaseTransition(previous: .main, current: .cooldown))
            ),
            event(
                ordinal: 3,
                seconds: start,
                payload: .cooldown(CooldownEvent(lifecycle: .started, targetHeartRate: target))
            ),
            event(
                ordinal: 4,
                seconds: end - 0.001,
                payload: .cooldown(CooldownEvent(lifecycle: .completed, targetHeartRate: target))
            ),
            event(
                ordinal: 5,
                seconds: end,
                payload: .workoutPhase(WorkoutPhaseTransition(previous: .cooldown, current: .finished))
            ),
        ]
    }

    func speedDecisionEvents(speeds: [Double], at times: [Double]) -> [WorkoutEvent] {
        let epoch = TreadmillConnectionEpoch(rawValue: uuid(90))
        return zip(speeds, times).enumerated().flatMap { index, row in
            let decisionID = DecisionID(rawValue: uuid(5_000 + index))
            return [
                event(
                    ordinal: 100 + (index * 2),
                    seconds: row.1,
                    payload: .treadmillEvidence(.decision(
                        TreadmillControlDecisionEvidence(
                            decisionID: decisionID,
                            source: .heartRateControl,
                            intent: .setDesiredSpeed(
                                DesiredSpeedKilometresPerHour(value: row.0)
                            ),
                            heartRateInputs: [],
                            occurredAt: baseDate.addingTimeInterval(row.1),
                            connectionEpoch: epoch
                        )
                    ))
                ),
                event(
                    ordinal: 101 + (index * 2),
                    seconds: row.1 + 0.001,
                    payload: .treadmillEvidence(.commandEnqueued(
                        TreadmillCommandEnqueuedEvidence(
                            commandID: CommandID(rawValue: uuid(5_050 + index)),
                            decisionID: decisionID,
                            kind: .setSpeed(CommandedSpeed(
                                nativeValue: (row.0 * 100).rounded(),
                                nativeUnit: .controllerNative(code: "ftms_hundredths_kmh")
                            )),
                            protocolKind: .ftms,
                            connectionEpoch: epoch,
                            enqueuedAt: baseDate.addingTimeInterval(row.1 + 0.001)
                        )
                    ))
                ),
            ]
        }
    }

    func causalEdgeEvents(
        specificClaim: Bool,
        includeSend: Bool = true,
        responseEventSeconds: Double = 15,
        associatedProtocolKind: TreadmillProtocolKind? = nil,
        associatedConnectionEpoch: TreadmillConnectionEpoch? = nil,
        duplicateSend: Bool = false,
        duplicateResponse: Bool = false,
        duplicateAcknowledgement: Bool = false,
        firstDecisionConnectionEpoch: TreadmillConnectionEpoch? = nil,
        duplicateDecisionID: Bool = false,
        mismatchedSendDecision: Bool = false,
        duplicateCommandEnqueuedWithoutDecision: Bool = false,
        decisionAfterEnqueue: Bool = false,
        sendBeforeEnqueue: Bool = false,
        nilDecisionChain: Bool = false,
        reversedEqualTimeOrder: Bool = false
    ) -> [WorkoutEvent] {
        let epoch = TreadmillConnectionEpoch(rawValue: uuid(90))
        let firstEpoch = firstDecisionConnectionEpoch ?? epoch
        let secondDecisionSeconds = reversedEqualTimeOrder
            ? 12.0
            : (decisionAfterEnqueue ? 11.5 : 10.0)
        let enqueueSeconds = reversedEqualTimeOrder ? 12.0 : 11.0
        let sendSeconds = reversedEqualTimeOrder
            ? 12.0
            : (sendBeforeEnqueue ? 10.5 : 12.0)
        let acknowledgementSeconds = reversedEqualTimeOrder ? 12.0 : 13.0
        let factualResponseSeconds = reversedEqualTimeOrder
            ? 12.0
            : responseEventSeconds
        let firstDecisionID = DecisionID(rawValue: uuid(5_100))
        let decisionID = duplicateDecisionID
            ? firstDecisionID
            : DecisionID(rawValue: uuid(5_101))
        let firstCommandID = CommandID(rawValue: uuid(5_105))
        let commandID = CommandID(rawValue: uuid(5_102))
        let attemptID = CommandAttemptID(rawValue: uuid(5_103))
        let send = TreadmillCommandSendAttemptEvidence(
            commandID: commandID,
            decisionID: mismatchedSendDecision
                ? DecisionID(rawValue: uuid(5_106))
                : (nilDecisionChain ? nil : decisionID),
            attemptID: attemptID,
            attemptNumber: 1,
            protocolKind: .ftms,
            connectionEpoch: epoch,
            sentAt: baseDate.addingTimeInterval(sendSeconds),
            writeType: .withResponse
        )
        var normalizer = TreadmillObservationNormalizer()
        let unassociatedResponse = normalizer.normalize(
            .ftms(
                speedRawHundredthsKmh: 400,
                rawState: 1,
                deviceState: .moving,
                connectionEpoch: epoch,
                receivedAt: baseDate.addingTimeInterval(15)
            ),
            unitsTruth: nil,
            observationID: ObservationID(rawValue: uuid(5_104)),
            recordedAt: baseDate.addingTimeInterval(15)
        )
        let acknowledgement: LegacyAcknowledgementObservation
        let response: TreadmillObservationEvidence
        if specificClaim {
            let edgeProtocol = associatedProtocolKind ?? .ftms
            let edgeEpoch = associatedConnectionEpoch ?? epoch
            acknowledgement = LegacyAcknowledgementObservation(
                protocolKind: edgeProtocol,
                connectionEpoch: edgeEpoch,
                receivedAt: baseDate.addingTimeInterval(13),
                recordedAt: baseDate.addingTimeInterval(13),
                association: .deterministicallyCorrelated(
                    commandID: commandID,
                    attemptID: attemptID
                )
            )
            response = TreadmillObservationEvidence(
                observationID: unassociatedResponse.observationID,
                protocolKind: edgeProtocol,
                connectionEpoch: edgeEpoch,
                nativeSpeed: unassociatedResponse.nativeSpeed,
                factualSpeed: unassociatedResponse.factualSpeed,
                rawDeviceState: unassociatedResponse.rawDeviceState,
                deviceState: unassociatedResponse.deviceState,
                measuredAt: unassociatedResponse.measuredAt,
                receivedAt: unassociatedResponse.receivedAt,
                recordedAt: unassociatedResponse.recordedAt,
                arrivalOrder: unassociatedResponse.arrivalOrder,
                freshness: unassociatedResponse.freshness,
                quality: unassociatedResponse.quality,
                provenance: unassociatedResponse.provenance,
                responseAssociation: .deterministicallyCorrelated(
                    commandID: commandID,
                    attemptID: attemptID
                )
            )
        } else {
            acknowledgement = .unresolved(
                protocolKind: .ftms,
                connectionEpoch: epoch,
                receivedAt: baseDate.addingTimeInterval(13),
                recordedAt: baseDate.addingTimeInterval(13)
            )
            response = unassociatedResponse
        }
        var events = [
            event(
                ordinal: 30,
                seconds: 0,
                payload: .treadmillEvidence(.decision(
                    TreadmillControlDecisionEvidence(
                        decisionID: firstDecisionID,
                        source: .heartRateControl,
                        intent: .setDesiredSpeed(DesiredSpeedKilometresPerHour(value: 3)),
                        heartRateInputs: [],
                        occurredAt: baseDate,
                        connectionEpoch: firstEpoch
                    )
                ))
            ),
            event(
                ordinal: 31,
                seconds: 0.001,
                payload: .treadmillEvidence(.commandEnqueued(
                    TreadmillCommandEnqueuedEvidence(
                        commandID: firstCommandID,
                        decisionID: firstDecisionID,
                        kind: .setSpeed(CommandedSpeed(
                            nativeValue: 300,
                            nativeUnit: .controllerNative(code: "ftms_hundredths_kmh")
                        )),
                        protocolKind: .ftms,
                        connectionEpoch: firstEpoch,
                        enqueuedAt: baseDate.addingTimeInterval(0.001)
                    )
                ))
            ),
            event(
                ordinal: 32,
                seconds: secondDecisionSeconds,
                recordedSeconds: reversedEqualTimeOrder ? 12.005 : nil,
                payload: .treadmillEvidence(.decision(
                    TreadmillControlDecisionEvidence(
                        decisionID: decisionID,
                        source: .heartRateControl,
                        intent: .setDesiredSpeed(DesiredSpeedKilometresPerHour(value: 4)),
                        heartRateInputs: [],
                        occurredAt: baseDate.addingTimeInterval(secondDecisionSeconds),
                        connectionEpoch: epoch
                    )
                ))
            ),
            event(
                ordinal: 33,
                seconds: enqueueSeconds,
                recordedSeconds: reversedEqualTimeOrder ? 12.004 : nil,
                payload: .treadmillEvidence(.commandEnqueued(
                    TreadmillCommandEnqueuedEvidence(
                        commandID: commandID,
                        decisionID: nilDecisionChain ? nil : decisionID,
                        kind: .setSpeed(CommandedSpeed(
                            nativeValue: 400,
                            nativeUnit: .controllerNative(code: "ftms_hundredths_kmh")
                        )),
                        protocolKind: .ftms,
                        connectionEpoch: epoch,
                        enqueuedAt: baseDate.addingTimeInterval(enqueueSeconds)
                    )
                ))
            ),
            event(
                ordinal: 35,
                seconds: acknowledgementSeconds,
                recordedSeconds: reversedEqualTimeOrder ? 12.002 : nil,
                payload: .treadmillEvidence(.acknowledgement(acknowledgement))
            ),
            event(
                ordinal: 36,
                seconds: factualResponseSeconds,
                recordedSeconds: reversedEqualTimeOrder ? 12.001 : nil,
                payload: .treadmillEvidence(.observation(response))
            ),
        ]
        if includeSend {
            events.append(
                event(
                    ordinal: 34,
                    seconds: sendSeconds,
                    recordedSeconds: reversedEqualTimeOrder ? 12.003 : nil,
                    payload: .treadmillEvidence(.sendAttempt(send))
                )
            )
            if duplicateSend {
                events.append(
                    event(
                        ordinal: 37,
                        seconds: sendSeconds,
                        payload: .treadmillEvidence(.sendAttempt(send))
                    )
                )
            }
        }
        if duplicateResponse {
            events.append(
                event(
                    ordinal: 38,
                    seconds: responseEventSeconds,
                    payload: .treadmillEvidence(.observation(response))
                )
            )
        }
        if duplicateAcknowledgement {
            events.append(
                event(
                    ordinal: 39,
                    seconds: 13,
                    payload: .treadmillEvidence(.acknowledgement(acknowledgement))
                )
            )
        }
        if duplicateCommandEnqueuedWithoutDecision {
            events.append(
                event(
                    ordinal: 40,
                    seconds: 11.001,
                    payload: .treadmillEvidence(.commandEnqueued(
                        TreadmillCommandEnqueuedEvidence(
                            commandID: commandID,
                            decisionID: nil,
                            kind: .setSpeed(CommandedSpeed(
                                nativeValue: 400,
                                nativeUnit: .controllerNative(
                                    code: "ftms_hundredths_kmh"
                                )
                            )),
                            protocolKind: .ftms,
                            connectionEpoch: epoch,
                            enqueuedAt: baseDate.addingTimeInterval(11.001)
                        )
                    ))
                )
            )
        }
        return events
    }

    func event(
        ordinal: Int,
        seconds: Double,
        recordedSeconds: Double? = nil,
        payload: WorkoutEventPayload
    ) -> WorkoutEvent {
        let persistedSeconds = recordedSeconds ?? (seconds + 0.001)
        return WorkoutEvent(
            recordID: RecordID(rawValue: uuid(6_000 + ordinal)),
            sessionID: session.sessionID,
            timestamp: EventTimestamp(
                occurredAt: baseDate.addingTimeInterval(seconds),
                recordedAt: baseDate.addingTimeInterval(persistedSeconds),
                occurredElapsed: elapsed(seconds),
                recordedElapsed: elapsed(persistedSeconds)
            ),
            payload: EventPayloadEnvelope(schemaVersion: 1, payload: payload)
        )
    }

    func staleFrame(
        heartRate: HeartRateObservation,
        seconds: Int64
    ) -> CanonicalFrame {
        CanonicalFrame(
            frameID: FrameID(rawValue: uuid(7_000 + Int(seconds))),
            recordID: RecordID(rawValue: uuid(8_000 + Int(seconds))),
            sessionID: session.sessionID,
            canonicalElapsedSecond: seconds,
            materializedAt: RecordTimestamp(
                recordedAt: baseDate.addingTimeInterval(Double(seconds)),
                elapsed: elapsed(Double(seconds))
            ),
            heartRateEvidence: HeartRateFrameEvidence(
                observationID: heartRate.observationID,
                recordID: heartRate.recordID,
                sourceID: heartRate.source.id,
                beatsPerMinute: heartRate.beatsPerMinute,
                measuredAt: heartRate.timestamp.measuredAt,
                receivedAt: heartRate.timestamp.receivedAt,
                evidenceElapsed: heartRate.timestamp.effectiveElapsed,
                ageAtMaterialization: elapsed(Double(seconds)),
                freshness: .stale,
                provenance: heartRate.provenance
            ),
            treadmillEvidence: nil,
            precedingGap: CanonicalGapBoundary(
                missingSinceElapsedSecond: 7,
                kind: .noObservation
            )
        )
    }

    func treadmillFrame(
        observation: TreadmillObservation,
        second: Int64,
        freshness: FreshnessState
    ) -> CanonicalFrame {
        CanonicalFrame(
            frameID: FrameID(rawValue: uuid(9_000 + Int(second))),
            recordID: RecordID(rawValue: uuid(11_000 + Int(second))),
            sessionID: session.sessionID,
            canonicalElapsedSecond: second,
            materializedAt: RecordTimestamp(
                recordedAt: baseDate.addingTimeInterval(Double(second)),
                elapsed: elapsed(Double(second))
            ),
            heartRateEvidence: nil,
            treadmillEvidence: TreadmillFrameEvidence(
                observationID: observation.observationID,
                recordID: observation.recordID,
                sourceID: observation.source.id,
                nativeSpeed: observation.nativeSpeed,
                factualSpeed: observation.factualSpeed,
                deviceState: observation.deviceState,
                measuredAt: observation.timestamp.measuredAt,
                receivedAt: observation.timestamp.receivedAt,
                evidenceElapsed: observation.timestamp.effectiveElapsed,
                ageAtMaterialization: elapsed(
                    max(0, Double(second) - observation.timestamp.effectiveElapsed.seconds)
                ),
                freshness: freshness,
                provenance: observation.provenance
            )
        )
    }

    func timestamp(
        seconds: Double,
        measuredElapsedAvailable: Bool = true
    ) -> ObservationTimestamp {
        ObservationTimestamp(
            measuredAt: measuredElapsedAvailable ? baseDate.addingTimeInterval(seconds) : nil,
            receivedAt: baseDate.addingTimeInterval(seconds + 0.05),
            recordedAt: baseDate.addingTimeInterval(seconds + 0.06),
            measuredElapsed: measuredElapsedAvailable ? elapsed(seconds) : nil,
            receivedElapsed: elapsed(seconds + 0.05),
            recordedElapsed: elapsed(seconds + 0.06)
        )
    }

    func freshness(seconds: Double) -> EvidenceFreshness {
        EvidenceFreshness(
            state: .fresh,
            evaluatedAt: RecordTimestamp(
                recordedAt: baseDate.addingTimeInterval(seconds + 0.06),
                elapsed: elapsed(seconds + 0.06)
            ),
            age: elapsed(0.06),
            policyVersion: session.versions.safetyPolicy
        )
    }

    func uuid(_ ordinal: Int) -> UUID { Self.uuid(ordinal) }

    private static func uuid(_ ordinal: Int) -> UUID {
        UUID(uuidString: String(format: "90000000-0000-0000-0000-%012d", ordinal))!
    }

    private func elapsed(_ seconds: Double) -> ElapsedDuration {
        Self.elapsed(seconds)
    }

    private static func elapsed(_ seconds: Double) -> ElapsedDuration {
        ElapsedDuration(microseconds: Int64((seconds * 1_000_000).rounded()))
    }
}
