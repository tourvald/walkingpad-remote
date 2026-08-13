import Foundation
import XCTest
@testable import WalkingPadCoreLogic

final class StopTruthExperimentSafetyCorrectionTests: XCTestCase {
    func testMovingBaselineAcceptsRaw5WithContradictoryAcceptedStateAndMarkersAreImmutable() {
        let harness = SessionHarness()
        harness.advanceToMovingReady(movingState: 0)

        XCTAssertEqual(harness.session.markers.filter { $0.role == .movingBaseline }.count, 1)
        XCTAssertFalse(harness.session.recordMarker(
            .moving,
            timestamp: harness.now(),
            note: "duplicate",
            operatorHadVisibility: true
        ))
        XCTAssertEqual(harness.session.markers.filter { $0.role == .movingBaseline }.count, 1)
    }

    func testStoppedMarkerRequiresActualStopAndFirstPhysicalStopIsImmutable() {
        let harness = SessionHarness()
        XCTAssertFalse(harness.session.recordMarker(
            .stopped,
            timestamp: harness.now(),
            note: "preflight",
            operatorHadVisibility: true
        ))
        harness.advanceToMovingReady()
        XCTAssertTrue(harness.session.beginStopObservation())
        XCTAssertFalse(harness.session.recordMarker(
            .stopped,
            timestamp: harness.now(),
            note: "before actual stop",
            operatorHadVisibility: true
        ))
        XCTAssertTrue(harness.session.recordInitialStopInvocation(timestamp: harness.now()))
        harness.advance(seconds: 0.5)
        XCTAssertTrue(harness.session.recordMarker(
            .stopped,
            timestamp: harness.now(),
            note: "first",
            operatorHadVisibility: true
        ))
        let first = harness.session.markers.first { $0.role == .firstPhysicalStop }
        harness.advance(seconds: 0.5)
        XCTAssertFalse(harness.session.recordMarker(
            .stopped,
            timestamp: harness.now(),
            note: "duplicate",
            operatorHadVisibility: true
        ))
        XCTAssertEqual(harness.session.markers.first { $0.role == .firstPhysicalStop }, first)
    }

    func testInitialStopAndPhysicalStoppedDeadlinesUseApprovedMonotonicBounds() {
        let onTime = SessionHarness()
        onTime.advanceToMovingReady()
        let moving = onTime.session.markers.first { $0.role == .movingBaseline }!.timestamp
        onTime.setUptime(moving.monotonicUptimeNanoseconds + 3_500_000_000)
        XCTAssertTrue(onTime.session.canAttemptInitialStop(nowUptimeNanoseconds: onTime.uptime))
        XCTAssertTrue(onTime.session.beginStopObservation())
        XCTAssertTrue(onTime.session.recordInitialStopInvocation(timestamp: onTime.now()))
        onTime.advance(seconds: 8.5)
        XCTAssertTrue(onTime.session.recordMarker(
            .stopped,
            timestamp: onTime.now(),
            note: "deadline",
            operatorHadVisibility: true
        ))
        XCTAssertEqual(onTime.session.cumulativeMotionDurationSeconds, 13.0, accuracy: 0.000_001)

        let lateStop = SessionHarness()
        lateStop.advanceToMovingReady()
        let lateMoving = lateStop.session.markers.first { $0.role == .movingBaseline }!.timestamp
        lateStop.setUptime(lateMoving.monotonicUptimeNanoseconds + 3_500_000_001)
        XCTAssertFalse(lateStop.session.canAttemptInitialStop(nowUptimeNanoseconds: lateStop.uptime))

        let lateStopped = SessionHarness()
        lateStopped.advanceToMovingReady()
        XCTAssertTrue(lateStopped.session.beginStopObservation())
        XCTAssertTrue(lateStopped.session.recordInitialStopInvocation(timestamp: lateStopped.now()))
        lateStopped.advance(seconds: 8.500_000_001)
        XCTAssertFalse(lateStopped.session.recordMarker(
            .stopped,
            timestamp: lateStopped.now(),
            note: "late",
            operatorHadVisibility: true
        ))
        XCTAssertEqual(lateStopped.session.phase, .failed(reason: "physical_stopped_marker_deadline_exceeded"))
        XCTAssertTrue(lateStopped.session.physicalCutoffRequired)
    }

    func testThreeRunsRespectThirtyNineSecondCumulativeMotionBound() {
        let harness = SessionHarness()
        for repetition in 1...3 {
            harness.advanceToMovingReady()
            let moving = harness.session.markers.first {
                $0.role == .movingBaseline && $0.repetition == repetition
            }!.timestamp
            harness.setUptime(moving.monotonicUptimeNanoseconds + 3_500_000_000)
            XCTAssertTrue(harness.session.beginStopObservation())
            XCTAssertTrue(harness.session.recordInitialStopInvocation(timestamp: harness.now()))
            harness.advance(seconds: 8.5)
            XCTAssertTrue(harness.session.recordMarker(
                .stopped,
                timestamp: harness.now(),
                note: "first physical stop",
                operatorHadVisibility: true
            ))
            XCTAssertTrue(harness.session.finishObservationWindow())
            XCTAssertTrue(harness.session.finishPostWindowFreshness(
                timestamp: harness.now(),
                executorQuiescent: true
            ))
            XCTAssertFalse(harness.session.beginNextRepetition(
                clock: harness.clock,
                nowUptimeNanoseconds: harness.uptime,
                executorQuiescent: true
            ), "Recovery pause must reject an immediate next repetition")
            harness.advance(seconds: 30)
            harness.recordPair(speed: 0, state: 0)
            XCTAssertTrue(harness.session.recordMarker(
                .stopped,
                timestamp: harness.now(),
                note: "recovery stationary",
                operatorHadVisibility: true,
                clock: harness.clock
            ))
            XCTAssertTrue(harness.session.beginNextRepetition(
                clock: harness.clock,
                nowUptimeNanoseconds: harness.uptime,
                executorQuiescent: true
            ))
        }
        XCTAssertEqual(harness.session.cumulativeMotionDurationSeconds, 39.0, accuracy: 0.000_001)
        XCTAssertEqual(harness.session.phase, .completed)
    }

    func testRecoveryAtThirtySecondsStillRequiresCurrentStationaryEvidenceAndDistinctMarker() {
        let harness = SessionHarness()
        harness.advanceToMovingReady()
        XCTAssertTrue(harness.session.beginStopObservation())
        XCTAssertTrue(harness.session.recordInitialStopInvocation(timestamp: harness.now()))
        harness.advance(seconds: 0.5)
        XCTAssertTrue(harness.session.recordMarker(
            .stopped,
            timestamp: harness.now(),
            note: "first",
            operatorHadVisibility: true
        ))
        XCTAssertTrue(harness.session.finishObservationWindow())
        XCTAssertTrue(harness.session.finishPostWindowFreshness(
            timestamp: harness.now(),
            executorQuiescent: true
        ))
        harness.advance(seconds: 30)
        XCTAssertFalse(harness.session.beginNextRepetition(
            clock: harness.clock,
            nowUptimeNanoseconds: harness.uptime,
            executorQuiescent: true
        ))
        harness.recordPair(speed: 0, state: 0)
        XCTAssertFalse(harness.session.beginNextRepetition(
            clock: harness.clock,
            nowUptimeNanoseconds: harness.uptime,
            executorQuiescent: true
        ))
        XCTAssertTrue(harness.session.recordMarker(
            .stopped,
            timestamp: harness.now(),
            note: "recovery",
            operatorHadVisibility: true,
            clock: harness.clock
        ))
        XCTAssertEqual(harness.session.markers.filter { $0.role == .firstPhysicalStop }.count, 1)
        XCTAssertEqual(harness.session.markers.filter { $0.role == .recoveryStationaryConfirmation }.count, 1)
        XCTAssertFalse(harness.session.beginNextRepetition(
            clock: harness.clock,
            nowUptimeNanoseconds: harness.uptime,
            executorQuiescent: false
        ))
        XCTAssertTrue(harness.session.beginNextRepetition(
            clock: harness.clock,
            nowUptimeNanoseconds: harness.uptime,
            executorQuiescent: true
        ))
    }

    func testRecoveryMarkerSurvivesLaterStationaryFramesAndAuthoritiesStayImmutable() {
        let harness = SessionHarness()
        harness.advanceToRecoveryPause()
        harness.advance(seconds: 30)
        harness.recordPair(speed: 0, state: 0)

        let moving = harness.session.markers.first { $0.role == .movingBaseline }
        let firstPhysicalStop = harness.session.markers.first { $0.role == .firstPhysicalStop }
        XCTAssertTrue(harness.recordRecoveryMarker(note: "authoritative recovery"))
        let recovery = harness.session.markers.first { $0.role == .recoveryStationaryConfirmation }

        harness.advance(seconds: 0.1)
        harness.recordPair(speed: 0, state: 0)
        XCTAssertFalse(harness.recordRecoveryMarker(note: "duplicate recovery"))
        XCTAssertEqual(harness.session.markers.first { $0.role == .movingBaseline }, moving)
        XCTAssertEqual(harness.session.markers.first { $0.role == .firstPhysicalStop }, firstPhysicalStop)
        XCTAssertEqual(harness.session.markers.first { $0.role == .recoveryStationaryConfirmation }, recovery)

        XCTAssertTrue(harness.session.beginNextRepetition(
            clock: harness.clock,
            nowUptimeNanoseconds: harness.uptime,
            executorQuiescent: true
        ))
    }

    func testRecoveryMarkerRequiresQualifyingStationaryPairAtMarkerTime() {
        let noPair = SessionHarness()
        noPair.advanceToRecoveryPause()
        noPair.advance(seconds: 30)
        XCTAssertFalse(noPair.recordRecoveryMarker())

        let stale = SessionHarness()
        stale.advanceToRecoveryPause()
        stale.recordPair(speed: 0, state: 0)
        stale.advance(seconds: 2.1)
        XCTAssertFalse(stale.recordRecoveryMarker())

        let invalidChecksum = SessionHarness()
        invalidChecksum.advanceToRecoveryPause()
        invalidChecksum.recordPair(speed: 0, state: 0, checksumValid: false)
        XCTAssertFalse(invalidChecksum.recordRecoveryMarker())

        let wrongContext = SessionHarness()
        wrongContext.advanceToRecoveryPause()
        wrongContext.recordPair(speed: 0, state: 0, context: TestFixtures.context())
        XCTAssertFalse(wrongContext.recordRecoveryMarker())

        let nonzero = SessionHarness()
        nonzero.advanceToRecoveryPause()
        nonzero.recordPair(speed: 1, state: 0)
        XCTAssertFalse(nonzero.recordRecoveryMarker())
    }

    func testUnsafeTelemetryAfterValidRecoveryMarkerStillBlocksNext() {
        let nonzero = SessionHarness.readyForNextRepetition()
        nonzero.recordPair(speed: 1, state: 0)
        XCTAssertFalse(nonzero.beginNextRepetition())

        let invalid = SessionHarness.readyForNextRepetition()
        invalid.recordPair(speed: 0, state: 0, checksumValid: false)
        XCTAssertFalse(invalid.beginNextRepetition())

        let ambiguous = SessionHarness.readyForNextRepetition()
        ambiguous.recordPair(speed: nil, state: nil)
        XCTAssertFalse(ambiguous.beginNextRepetition())

        let wrongContext = SessionHarness.readyForNextRepetition()
        wrongContext.recordPair(speed: 0, state: 0, context: TestFixtures.context())
        XCTAssertFalse(wrongContext.beginNextRepetition())

        let stale = SessionHarness.readyForNextRepetition()
        stale.advance(seconds: 2.1)
        XCTAssertFalse(stale.beginNextRepetition())
    }

    func testEveryTerminalPathAfterMotionRequiresPhysicalCutoff() {
        let reasons = ["deadline", "clock_discontinuity", "executor_failure", "app_lifecycle"]
        for reason in reasons {
            let harness = SessionHarness()
            harness.advanceToMovingStart()
            harness.session.fail(reason)
            XCTAssertTrue(harness.session.physicalCutoffRequired, reason)
            XCTAssertEqual(harness.session.terminalReason, reason)
        }
        let aborted = SessionHarness()
        aborted.advanceToMovingStart()
        aborted.session.abort("operator_abort")
        XCTAssertTrue(aborted.session.physicalCutoffRequired)

        let reconnected = SessionHarness()
        reconnected.advanceToMovingStart()
        reconnected.session.recordReconnect()
        XCTAssertTrue(reconnected.session.physicalCutoffRequired)
    }

    func testPositiveRecoveryClearsCutoffRequirementUntilNextActualMotionInvocation() {
        let harness = SessionHarness()
        harness.advanceToMovingReady()
        XCTAssertTrue(harness.session.beginStopObservation())
        XCTAssertTrue(harness.session.recordInitialStopInvocation(timestamp: harness.now()))
        harness.advance(seconds: 0.5)
        XCTAssertTrue(harness.session.recordMarker(
            .stopped,
            timestamp: harness.now(),
            note: "first",
            operatorHadVisibility: true
        ))
        XCTAssertTrue(harness.session.finishObservationWindow())
        XCTAssertTrue(harness.session.finishPostWindowFreshness(
            timestamp: harness.now(),
            executorQuiescent: true
        ))
        harness.advance(seconds: 30)
        harness.recordPair(speed: 0, state: 0)
        XCTAssertTrue(harness.session.recordMarker(
            .stopped,
            timestamp: harness.now(),
            note: "recovery",
            operatorHadVisibility: true,
            clock: harness.clock
        ))
        XCTAssertTrue(harness.session.beginNextRepetition(
            clock: harness.clock,
            nowUptimeNanoseconds: harness.uptime,
            executorQuiescent: true
        ))
        harness.recordPair(speed: 0, state: 0)
        XCTAssertTrue(harness.session.acceptStationaryBaseline(
            clock: harness.clock,
            nowUptimeNanoseconds: harness.uptime
        ))
        XCTAssertTrue(harness.session.beginMovingBaseline())
        harness.session.fail("before_next_actual_motion")
        XCTAssertFalse(harness.session.physicalCutoffRequired)
    }

    func testFinalizedLifecycleIgnoresLaterRawObservationAndPostCheckUsesFrozenLatest() {
        let context = TestFixtures.context()
        let origin = UUID()
        let stop = TestFixtures.timestamp(origin: origin, uptime: 1_000_000_000)
        let retained = TestFixtures.timestamp(origin: origin, uptime: 29_000_000_000)
        var service = StopTruthExperimentObservationService(context: context, stopInvokedAt: stop)
        _ = service.record(
            .init(context: context, receivedAt: retained, rawHex: "retained", checksumValid: true, speedRawTenths: 0, state: 0),
            nowUptimeNanoseconds: retained.monotonicUptimeNanoseconds
        )
        let firstConfirmed = service.firstConfirmedAt
        let final = service.finalizeWindow(nowUptimeNanoseconds: 31_000_000_000)
        let ignored = TestFixtures.timestamp(origin: origin, uptime: 31_100_000_000)
        _ = service.record(
            .init(context: context, receivedAt: ignored, rawHex: "ignored raw", checksumValid: true, speedRawTenths: 7, state: 1),
            nowUptimeNanoseconds: ignored.monotonicUptimeNanoseconds
        )
        let post = service.recordPostWindowFreshness(nowUptimeNanoseconds: 33_100_000_000)

        XCTAssertTrue(service.isFrozen)
        XCTAssertEqual(service.observations.map(\.rawHex), ["retained"])
        XCTAssertEqual(service.firstConfirmedAt, firstConfirmed)
        XCTAssertEqual(service.finalWindowEvaluation, final)
        XCTAssertEqual(post.result, .stale)
        XCTAssertEqual(post.ageSeconds!, 4.1, accuracy: 0.000_001)
    }

    func testRaw5DeadlineTerminatesWithCutoffAndZeroLaterInvocations() {
        let harness = ControllerHarness()
        harness.advanceThroughSuccessfulRaw5()
        let rolesAtRaw5 = harness.roles

        harness.clock.value = 12_000_000_000
        harness.scheduler.fire(delay: 5.0)
        harness.scheduler.fireAll()

        XCTAssertEqual(harness.roles, rolesAtRaw5)
        XCTAssertFalse(harness.controller.isActive)
        XCTAssertTrue(harness.controller.status.contains("physical power cutoff required"))
        XCTAssertTrue(harness.sink.records.contains {
            $0.event == .terminalSafety && $0.fields["physical_cutoff_required"] == "true"
        })
    }

    func testExecutorTimingFailureAfterBaselineStartIsTerminalAndCancelsRaw5() {
        let harness = ControllerHarness()
        harness.advanceThroughSuccessfulBaselineStart()
        let throughBaseline = harness.roles

        harness.clock.value = 8_000_000_000
        harness.scheduler.fire(delay: 5.8)
        harness.scheduler.fireAll()

        XCTAssertEqual(harness.roles, throughBaseline)
        XCTAssertFalse(harness.controller.isActive)
        XCTAssertTrue(harness.controller.status.contains("physical power cutoff required"))
        XCTAssertTrue(harness.sink.records.contains {
            $0.event == .timingInvalid && $0.fields["reason"] == "critical_timing_discontinuity"
        })
    }

    func testLateInitialStopIsNotInvoked() {
        let harness = ControllerHarness()
        harness.advanceThroughSuccessfulRaw5()
        harness.recordMovingMarkerAndFreshBaseline(at: 10_400_000_000)
        let before = harness.roles
        harness.clock.value = 10_500_000_001

        XCTAssertFalse(harness.controller.beginStop())
        XCTAssertEqual(harness.roles, before)
        XCTAssertFalse(harness.controller.isActive)
        XCTAssertTrue(harness.controller.status.contains("physical power cutoff required"))
    }

    func testMissingStoppedMarkerAtEightPointFiveSecondsCancelsAllFutureActions() {
        let harness = ControllerHarness()
        harness.advanceThroughSuccessfulRaw5()
        harness.recordMovingMarkerAndFreshBaseline(at: 7_100_000_000)
        harness.clock.value = 9_000_000_000
        XCTAssertTrue(harness.controller.beginStop())
        harness.completeLast()
        let throughInitialStop = harness.roles

        harness.clock.value = 17_500_000_001
        harness.scheduler.fire(delay: 8.500_000_001)
        harness.scheduler.fireAll()

        XCTAssertEqual(harness.roles, throughInitialStop)
        XCTAssertFalse(harness.controller.isActive)
        XCTAssertTrue(harness.controller.status.contains("physical power cutoff required"))
    }

    func testStoppedMarkerAtInclusiveEightPointFiveSecondBoundaryWinsBeforeCutoff() {
        let harness = ControllerHarness()
        harness.advanceThroughSuccessfulRaw5()
        harness.recordMovingMarkerAndFreshBaseline(at: 7_100_000_000)
        harness.clock.value = 9_000_000_000
        XCTAssertTrue(harness.controller.beginStop())
        harness.completeLast()

        harness.clock.value = 17_500_000_000
        harness.controller.recordMarker(.stopped)
        harness.scheduler.fire(delay: 8.500_000_001)

        XCTAssertTrue(harness.controller.isActive)
        XCTAssertFalse(harness.controller.status.contains("physical power cutoff required"))
        XCTAssertEqual(harness.sink.records.filter {
            $0.event == .physicalMarker && $0.fields["marker_role"] == "first_physical_stop"
        }.count, 1)
    }

    func testAbortOverlappingActualBaselineStartRequiresCutoffAndAllowsNoLaterWrite() {
        let harness = ControllerHarness()
        harness.advanceToActualBaselineStartWithoutReceipt()
        let throughBaselineStart = harness.roles

        harness.controller.recordMarker(.abort, note: "overlap")
        harness.completeLast()
        harness.scheduler.fireAll()

        XCTAssertEqual(harness.roles, throughBaselineStart)
        XCTAssertFalse(harness.controller.isActive)
        XCTAssertTrue(harness.controller.status.contains("physical power cutoff required"))
        XCTAssertTrue(harness.sink.records.contains {
            $0.event == .terminalSafety && $0.fields["physical_cutoff_required"] == "true"
        })
        XCTAssertTrue(harness.sink.records.contains {
            $0.event == .transportResult && $0.fields["overlapped_abort_barrier"] == "true"
        })
    }

    func testControllerPersistsRawAfterFinalizationWithoutMutatingFrozenLifecycle() {
        let harness = ControllerHarness()
        harness.advanceThroughSuccessfulRaw5()
        harness.recordMovingMarkerAndFreshBaseline(at: 7_100_000_000)
        harness.clock.value = 9_000_000_000
        XCTAssertTrue(harness.controller.beginStop())
        harness.completeLast()
        harness.clock.value = 9_100_000_000
        harness.controller.recordMarker(.stopped)

        harness.clock.value = 11_000_000_000
        harness.scheduler.fire(delay: 2.0)
        harness.completeLast()
        harness.clock.value = 13_000_000_000
        harness.scheduler.fire(delay: 4.0)
        harness.recordStatus(at: 38_000_000_000, speed: 0, state: 0, rawHex: "retained")
        harness.clock.value = 39_000_000_000
        harness.scheduler.fire(delay: 30.0)
        let stopRowsBefore = harness.sink.records.filter { $0.event == .stopObservation }.count
        let firstConfirmed = harness.sink.records.last { $0.event == .stopFinalResult }?
            .fields["stop_first_confirmed_monotonic_uptime_ns"]

        harness.recordStatus(at: 39_100_000_000, speed: 7, state: 1, rawHex: "raw after freeze")
        XCTAssertTrue(harness.sink.records.contains {
            $0.event == .fe01Raw && $0.fields["raw_packet_hex"] == "raw after freeze"
        })
        XCTAssertEqual(harness.sink.records.filter { $0.event == .stopObservation }.count, stopRowsBefore)

        harness.clock.value = 41_100_000_000
        harness.scheduler.fire(delay: 32.1)
        let post = harness.sink.records.last { $0.event == .postWindowFreshness }
        XCTAssertEqual(post?.fields["evaluation_result"], StopObservationResult.stale.rawValue)
        XCTAssertEqual(post?.fields["stop_first_confirmed_monotonic_uptime_ns"], firstConfirmed)
    }
}

private final class SessionHarness {
    var uptime: UInt64 = 1_000_000_000
    let context = TestFixtures.context()
    let clock: StopTruthExperimentClock
    var session: StopTruthExperimentSessionService
    private let clockStorage: MutableUptime

    init() {
        let origin = UUID()
        let storage = MutableUptime()
        clockStorage = storage
        clock = StopTruthExperimentClock(
            originID: origin,
            uptimeProvider: { storage.value },
            wallProvider: { Date(timeIntervalSince1970: Double(storage.value) / 1_000_000_000) }
        )
        session = StopTruthExperimentSessionService(
            context: context,
            clockOriginID: origin,
            timeoutPolicy: .init(perRepetitionSeconds: 90, globalSeconds: 300),
            buildIdentity: TestFixtures.identity()
        )
        self.uptime = storage.value
    }

    func now() -> StopTruthExperimentTimestamp {
        TestFixtures.timestamp(origin: session.clockOriginID, uptime: uptime)
    }

    func setUptime(_ value: UInt64) {
        uptime = value
        clockStorage.value = value
    }

    func advance(seconds: TimeInterval) {
        setUptime(uptime + UInt64(seconds * 1_000_000_000))
    }

    func recordPair(
        speed: Int?,
        state: Int?,
        checksumValid: Bool = true,
        context observationContext: StopTruthExperimentPlanService.Context? = nil
    ) {
        let observationContext = observationContext ?? context
        session.recordFE01(.init(
            context: observationContext,
            receivedAt: now(),
            rawHex: "first",
            checksumValid: checksumValid,
            speedRawTenths: speed,
            state: state
        ))
        advance(seconds: 0.1)
        session.recordFE01(.init(
            context: observationContext,
            receivedAt: now(),
            rawHex: "second",
            checksumValid: checksumValid,
            speedRawTenths: speed,
            state: state
        ))
    }

    func advanceToRecoveryPause() {
        advanceToMovingReady()
        XCTAssertTrue(session.beginStopObservation())
        XCTAssertTrue(session.recordInitialStopInvocation(timestamp: now()))
        advance(seconds: 0.5)
        XCTAssertTrue(session.recordMarker(
            .stopped,
            timestamp: now(),
            note: "first physical stop",
            operatorHadVisibility: true
        ))
        XCTAssertTrue(session.finishObservationWindow())
        XCTAssertTrue(session.finishPostWindowFreshness(
            timestamp: now(),
            executorQuiescent: true
        ))
    }

    func recordRecoveryMarker(note: String = "recovery") -> Bool {
        session.recordMarker(
            .stopped,
            timestamp: now(),
            note: note,
            operatorHadVisibility: true,
            clock: clock
        )
    }

    func beginNextRepetition() -> Bool {
        session.beginNextRepetition(
            clock: clock,
            nowUptimeNanoseconds: uptime,
            executorQuiescent: true
        )
    }

    static func readyForNextRepetition() -> SessionHarness {
        let harness = SessionHarness()
        harness.advanceToRecoveryPause()
        harness.advance(seconds: 30)
        harness.recordPair(speed: 0, state: 0)
        XCTAssertTrue(harness.recordRecoveryMarker())
        return harness
    }

    func advanceToMovingStart() {
        session.recordA6Bounds(.init(
            context: context,
            observedAt: now(),
            checksumValid: true,
            startSpeedRawTenths: 5,
            maxSpeedRawTenths: 50
        ))
        recordPair(speed: 0, state: 0)
        XCTAssertTrue(session.acceptStationaryBaseline(clock: clock, nowUptimeNanoseconds: uptime))
        XCTAssertTrue(session.beginMovingBaseline())
        session.recordMotionCapableInvocation(role: .baselineStart, timestamp: now())
    }

    func advanceToMovingReady(movingState: Int = 1) {
        advanceToMovingStart()
        session.recordMotionCapableInvocation(role: .speedRaw5, timestamp: now())
        session.recordRaw5Invocation(timestamp: now())
        XCTAssertTrue(session.recordMarker(.moving, timestamp: now(), note: "moving", operatorHadVisibility: true))
        recordPair(speed: 5, state: movingState)
        XCTAssertTrue(session.acceptMovingBaseline(clock: clock, nowUptimeNanoseconds: uptime))
    }
}

private final class ControllerHarness {
    let clock = MutableUptime(value: 1_000_000_000)
    let scheduler = SafetyScheduler()
    let sink = StopTruthExperimentMemoryEvidenceSink()
    let context = TestFixtures.context()
    private(set) var invocations: [SafetyInvocation] = []
    let controller: StopTruthExperimentController

    init() {
        let monotonicClock = StopTruthExperimentClock(
            originID: UUID(),
            uptimeProvider: { [clock] in clock.value },
            wallProvider: { [clock] in Date(timeIntervalSince1970: Double(clock.value) / 1_000_000_000) }
        )
        var captured: [SafetyInvocation] = []
        controller = StopTruthExperimentController(
            buildIdentity: TestFixtures.identity(),
            context: context,
            timeoutPolicy: .init(perRepetitionSeconds: 90, globalSeconds: 300),
            evidenceSink: sink,
            clock: monotonicClock,
            transportInvocation: { packet, role, writeID, completion in
                captured.append(.init(packet: packet, role: role, writeID: writeID, completion: completion))
                return true
            },
            speedSnapshot: { (0, 0) },
            beforeHighPriorityStop: {},
            scheduleHandler: { [scheduler] delay, item in scheduler.schedule(delay: delay, item: item) },
            onStateChange: { _ in }
        )
        invocationSource = { captured }
        XCTAssertTrue(controller.start())
    }

    private var invocationSource: () -> [SafetyInvocation] = { [] }
    var roles: [BLETransportCodec.StopTruthExperimentCommandRole] { invocationSource().map(\.role) }

    func completeLast() {
        guard let invocation = invocationSource().last else { return XCTFail("Missing invocation") }
        invocation.completion(.success(.init(characteristicUUID: "FE02", writeType: "without_response")))
    }

    func advanceThroughSuccessfulRaw5() {
        advanceThroughSuccessfulBaselineStart()
        clock.value = 7_000_000_000
        scheduler.fire(delay: 5.8)
        completeLast()
        XCTAssertEqual(roles, [.queryParams, .modeManual, .baselineStart, .speedRaw5])
    }

    func advanceThroughSuccessfulBaselineStart() {
        advanceToActualBaselineStartWithoutReceipt()
        completeLast()
        XCTAssertEqual(roles, [.queryParams, .modeManual, .baselineStart])
    }

    func advanceToActualBaselineStartWithoutReceipt() {
        completeLast()
        controller.recordA6Bounds(
            params: .init(
                maxSpeedRawTenths: 50,
                startSpeedRawTenths: 5,
                rawControllerUnit: 0,
                checksumOk: true,
                rawHex: "F8 A6"
            ),
            context: context,
            receivedUptimeNanoseconds: clock.value,
            receivedWallDate: Date(timeIntervalSince1970: 1)
        )
        recordFE01(at: 1_100_000_000, speed: 0, state: 0)
        recordFE01(at: 1_200_000_000, speed: 0, state: 0)
        clock.value = 1_200_000_000
        XCTAssertTrue(controller.prepareMotion())
        clock.value = 3_000_000_000
        scheduler.fire(delay: 1.8)
        completeLast()
        clock.value = 5_000_000_000
        scheduler.fire(delay: 3.8)
        XCTAssertEqual(roles, [.queryParams, .modeManual, .baselineStart])
    }

    func recordMovingMarkerAndFreshBaseline(at firstUptime: UInt64) {
        clock.value = 7_000_000_000
        controller.recordMarker(.moving)
        recordFE01(at: firstUptime, speed: 5, state: 0)
        recordFE01(at: firstUptime + 100_000_000, speed: 5, state: 0)
        clock.value = firstUptime + 100_000_000
    }

    func recordStatus(at uptime: UInt64, speed: UInt8, state: Int, rawHex: String = "F8 A2") {
        clock.value = uptime
        controller.recordFE01(
            rawHex: rawHex,
            status: .init(
                beltState: state,
                speedRawTenths: speed,
                manualMode: 1,
                timeSeconds: 0,
                distance10m: 0,
                steps: 0,
                appSpeedRawTenths: speed,
                lastButton: 0,
                checksumOk: true
            ),
            context: context,
            receivedUptimeNanoseconds: uptime,
            receivedWallDate: Date(timeIntervalSince1970: Double(uptime) / 1_000_000_000)
        )
    }

    private func recordFE01(at uptime: UInt64, speed: UInt8, state: Int) {
        recordStatus(at: uptime, speed: speed, state: state)
    }
}

private final class MutableUptime {
    var value: UInt64
    init(value: UInt64 = 1_000_000_000) { self.value = value }
}

private struct SafetyInvocation {
    let packet: Data
    let role: BLETransportCodec.StopTruthExperimentCommandRole
    let writeID: UUID
    let completion: (Result<StopTruthExperimentTransportReceipt, Error>) -> Void
}

private final class SafetyScheduler {
    private var entries: [(delay: TimeInterval, item: DispatchWorkItem)] = []

    func schedule(delay: TimeInterval, item: DispatchWorkItem) {
        entries.append((delay, item))
    }

    func fire(delay: TimeInterval, accuracy: TimeInterval = 0.000_001) {
        guard let index = entries.firstIndex(where: { abs($0.delay - delay) <= accuracy }) else {
            return XCTFail("No scheduled item for delay \(delay); found \(entries.map(\.delay))")
        }
        let entry = entries.remove(at: index)
        entry.item.perform()
    }

    func fireAll() {
        let pending = entries
        entries.removeAll()
        pending.forEach { $0.item.perform() }
    }
}

private enum TestFixtures {
    static func context() -> StopTruthExperimentPlanService.Context {
        .init(peripheralID: UUID(), connectionEpoch: UUID(), notificationStreamID: UUID())
    }

    static func identity() -> StopTruthExperimentBuildIdentity {
        let sha = String(repeating: "d", count: 40)
        return .init(
            capabilityCompiled: true,
            capabilityBinding: StopTruthExperimentBuildIdentity.requiredCapability,
            expectedGitSHA: sha,
            actualGitSHA: sha,
            bundleIdentifier: "test",
            version: "1",
            build: "1"
        )
    }

    static func timestamp(origin: UUID, uptime: UInt64) -> StopTruthExperimentTimestamp {
        .init(
            originID: origin,
            monotonicUptimeNanoseconds: uptime,
            monotonicElapsedSeconds: Double(uptime) / 1_000_000_000,
            wallDate: Date(timeIntervalSince1970: Double(uptime) / 1_000_000_000)
        )
    }
}
