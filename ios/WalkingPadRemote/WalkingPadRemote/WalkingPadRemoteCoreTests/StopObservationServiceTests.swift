import XCTest
@testable import WalkingPadCoreLogic

final class StopObservationServiceTests: XCTestCase {
    private let attemptAt = Date(timeIntervalSince1970: 1_000)

    private func context() -> StopObservationContext {
        StopObservationContext(
            peripheralID: UUID(),
            connectionEpoch: UUID(),
            notificationStreamID: UUID()
        )
    }

    private func observation(
        speed: Int? = 0,
        state: Int? = 0,
        checksumValid: Bool = true,
        context: StopObservationContext,
        observedAt: Date? = nil
    ) -> StopDeviceObservation {
        StopDeviceObservation(
            sequence: 1,
            observedAt: observedAt ?? attemptAt.addingTimeInterval(0.5),
            speedRawTenths: speed,
            state: state,
            checksumValid: checksumValid,
            context: context
        )
    }

    func testResponseRequiredMotionWriteKeepsOriginalWindowForLateTransportResult() {
        let expected = context()
        var lifecycle = StopObservationLifecycle(attemptID: UUID(), source: "test",
            attemptedAt: attemptAt, context: expected, scheduledStopEffects: 0)
        lifecycle.markCommandSent(at: attemptAt)
        lifecycle.markMotionWrite(at: attemptAt.addingTimeInterval(2), requiresResponse: true)
        let receivedAt = attemptAt.addingTimeInterval(4.2)
        _ = lifecycle.record(speedRawTenths: 0, state: 0, checksumValid: true,
            context: expected, observedAt: receivedAt, evaluatedAt: receivedAt)
        XCTAssertFalse(lifecycle.finalizeCompletedStopIfReady(at: receivedAt, queueIdle: true))
        // A later write without a response cannot erase an earlier unknown completion.
        lifecycle.markMotionWrite(at: receivedAt.addingTimeInterval(0.1))
        let freshAt = receivedAt.addingTimeInterval(0.2)
        _ = lifecycle.record(speedRawTenths: 0, state: 0, checksumValid: true,
            context: expected, observedAt: freshAt, evaluatedAt: freshAt)
        XCTAssertTrue(lifecycle.hasResponseRequiredMotionWrite)
        XCTAssertFalse(lifecycle.finalizeCompletedStopIfReady(at: freshAt, queueIdle: true))
        XCTAssertNil(lifecycle.finalResult)
        XCTAssertEqual(lifecycle.deadline, attemptAt.addingTimeInterval(30))
        let finalAt = lifecycle.deadline.addingTimeInterval(-0.1)
        _ = lifecycle.record(speedRawTenths: 0, state: 0, checksumValid: true,
            context: expected, observedAt: finalAt, evaluatedAt: finalAt)
        _ = lifecycle.finalizeTimeout(at: lifecycle.deadline)
        XCTAssertEqual(lifecycle.finalResult, .confirmed)
    }

    func testCompletedStopWaitsForEffectsQueueAndPostWriteObservation() {
        let expected = context()
        var lifecycle = StopObservationLifecycle(attemptID: UUID(), source: "test",
            attemptedAt: attemptAt, context: expected, scheduledStopEffects: 2)
        lifecycle.markCommandSent(at: attemptAt)
        lifecycle.markMotionWrite(at: attemptAt.addingTimeInterval(2))
        lifecycle.completeScheduledStopEffect()
        let receivedAt = attemptAt.addingTimeInterval(4.2)
        _ = lifecycle.record(speedRawTenths: 0, state: 0, checksumValid: true,
            context: expected, observedAt: receivedAt, evaluatedAt: receivedAt)
        XCTAssertFalse(lifecycle.finalizeCompletedStopIfReady(at: receivedAt, queueIdle: true))
        lifecycle.completeScheduledStopEffect()
        XCTAssertFalse(lifecycle.finalizeCompletedStopIfReady(at: receivedAt, queueIdle: false))
        let retryAt = receivedAt.addingTimeInterval(0.1)
        lifecycle.markMotionWrite(at: retryAt)
        XCTAssertFalse(lifecycle.finalizeCompletedStopIfReady(at: retryAt, queueIdle: true))
        _ = lifecycle.record(speedRawTenths: 0, state: 0, checksumValid: true,
            context: expected, observedAt: retryAt, evaluatedAt: retryAt)
        XCTAssertFalse(lifecycle.finalizeCompletedStopIfReady(at: retryAt, queueIdle: true))
        let finalAt = retryAt.addingTimeInterval(0.1)
        _ = lifecycle.record(speedRawTenths: 0, state: 0, checksumValid: true,
            context: expected, observedAt: finalAt, evaluatedAt: finalAt)
        XCTAssertTrue(lifecycle.finalizeCompletedStopIfReady(at: finalAt, queueIdle: true))
        XCTAssertEqual(lifecycle.finalResult, .confirmed)
        XCTAssertEqual(lifecycle.finalizedAt, finalAt)
        XCTAssertEqual(lifecycle.deadline, attemptAt.addingTimeInterval(30))
        XCTAssertFalse(lifecycle.finalizeCompletedStopIfReady(at: finalAt, queueIdle: true))
    }

    func testCancelledCallbackCompletesOnceAndSilenceKeepsOriginalDeadline() {
        let expected = context()
        var lifecycle = StopObservationLifecycle(attemptID: UUID(), source: "test",
            attemptedAt: attemptAt, context: expected, scheduledStopEffects: 2)
        lifecycle.markCommandSent(at: attemptAt)
        let receivedAt = attemptAt.addingTimeInterval(4.2)
        _ = lifecycle.record(speedRawTenths: 0, state: 0, checksumValid: true,
            context: expected, observedAt: receivedAt, evaluatedAt: receivedAt)
        lifecycle.completeScheduledStopEffect()
        lifecycle.completeScheduledStopEffect()
        lifecycle.completeScheduledStopEffect()
        XCTAssertEqual(lifecycle.scheduledStopEffectsRemaining, 0)
        XCTAssertTrue(lifecycle.finalizeCompletedStopIfReady(at: receivedAt, queueIdle: true))
        XCTAssertEqual(lifecycle.lastMotionWriteAt, attemptAt)
        var silent = StopObservationLifecycle(attemptID: UUID(), source: "test",
            attemptedAt: attemptAt, context: expected, scheduledStopEffects: 0)
        silent.markCommandSent(at: attemptAt)
        XCTAssertFalse(silent.finalizeCompletedStopIfReady(at: receivedAt, queueIdle: true))
        _ = silent.finalizeTimeout(at: silent.deadline)
        XCTAssertEqual(silent.finalResult, .timeoutUnconfirmed)
        XCTAssertEqual(silent.deadline, attemptAt.addingTimeInterval(30))
    }

    func testEarlyStopRejectsUnknownEffectsAndNonqualifyingEvidence() {
        for scenario in ["unknown-effects", "stale", "moving", "contradictory", "checksum", "missing-speed", "missing-state", "not-sent", "deadline", "wrong-context", "invalidated"] {
            let expected = context()
            var lifecycle = StopObservationLifecycle(attemptID: UUID(), source: "test",
                attemptedAt: attemptAt, context: expected, scheduledStopEffects: scenario == "unknown-effects" ? nil : 0)
            if scenario != "not-sent" { lifecycle.markCommandSent(at: attemptAt) }
            let receivedAt = attemptAt.addingTimeInterval(4.2)
            _ = lifecycle.record(speedRawTenths: scenario == "missing-speed" ? nil : (scenario == "moving" ? 12 : 0),
                state: scenario == "missing-state" ? nil : (["moving", "contradictory"].contains(scenario) ? 1 : 0),
                checksumValid: scenario != "checksum", context: scenario == "wrong-context" ? context() : expected,
                observedAt: receivedAt, evaluatedAt: receivedAt)
            if scenario == "invalidated" { _ = lifecycle.finalizeUnconfirmed(at: receivedAt, reason: "new_motion_requested") }
            let now = scenario == "deadline" ? lifecycle.deadline : receivedAt.addingTimeInterval(scenario == "stale" ? 2.01 : 0)
            XCTAssertFalse(lifecycle.finalizeCompletedStopIfReady(at: now, queueIdle: true), scenario)
            if scenario == "invalidated" { XCTAssertEqual(lifecycle.finalResult, .unconfirmed) }
            else { XCTAssertNil(lifecycle.finalResult, scenario) }
        }
    }

    func testHistoricalStopPresentationSurvivesSilenceWithoutCurrentConfirmation() {
        let expected = context()
        var lifecycle = StopObservationLifecycle(attemptID: UUID(), source: "test",
            attemptedAt: attemptAt, context: expected)
        lifecycle.markCommandSent(at: attemptAt)
        let receivedAt = attemptAt.addingTimeInterval(4.2)
        _ = lifecycle.record(speedRawTenths: 0, state: 0, checksumValid: true,
            context: expected, observedAt: receivedAt, evaluatedAt: receivedAt)
        let now = receivedAt.addingTimeInterval(2.01)
        let stale = lifecycle.currentEvaluation(at: now)
        XCTAssertFalse(stale.isConfirmed)
        XCTAssertEqual(lifecycle.statusText(for: stale, currentObservationMatches: true),
            "stop previously confirmed • current evidence stale")
        XCTAssertEqual(lifecycle.statusText(for: stale, currentObservationMatches: false),
            "stop unconfirmed • stale")
        _ = lifecycle.finalizeTimeout(at: lifecycle.deadline)
        XCTAssertEqual(lifecycle.finalResult, .timeoutUnconfirmed)
        XCTAssertEqual(lifecycle.statusText(for: lifecycle.currentEvaluation(at: lifecycle.deadline),
            currentObservationMatches: true), "stop previously confirmed • current evidence stale")
    }

    func testLaterConflictingEvidenceCannotBecomeHistoricalConfirmationWhenStale() {
        for (speed, state, checksum) in [(35 as Int?, 1 as Int?, true),
            (0, 1, true), (35, 0, true), (0, 0, false), (nil, 0, true), (0, nil, true)] {
            let expected = context()
            var lifecycle = StopObservationLifecycle(attemptID: UUID(), source: "test",
                attemptedAt: attemptAt, context: expected)
            lifecycle.markCommandSent(at: attemptAt)
            let confirmedAt = attemptAt.addingTimeInterval(0.5)
            _ = lifecycle.record(speedRawTenths: 0, state: 0, checksumValid: true,
                context: expected, observedAt: confirmedAt, evaluatedAt: confirmedAt)
            let laterAt = attemptAt.addingTimeInterval(1)
            _ = lifecycle.record(speedRawTenths: speed, state: state, checksumValid: checksum,
                context: expected, observedAt: laterAt, evaluatedAt: laterAt)
            let stale = lifecycle.currentEvaluation(at: laterAt.addingTimeInterval(2.01))
            XCTAssertEqual(stale.result, .stale)
            XCTAssertNotNil(lifecycle.firstConfirmedAt)
            XCTAssertEqual(lifecycle.statusText(for: stale, currentObservationMatches: true),
                "stop unconfirmed • stale")
            _ = lifecycle.finalizeTimeout(at: lifecycle.deadline)
            XCTAssertEqual(lifecycle.statusText(for: lifecycle.currentEvaluation(at: lifecycle.deadline),
                currentObservationMatches: true), "stop unconfirmed • timeout")
        }
    }

    func testNewAttemptAndInvalidatedContextNeverReuseHistoricalStopPresentation() {
        let expected = context()
        var old = StopObservationLifecycle(attemptID: UUID(), source: "test",
            attemptedAt: attemptAt, context: expected)
        old.markCommandSent(at: attemptAt)
        let at = attemptAt.addingTimeInterval(0.5)
        _ = old.record(speedRawTenths: 0, state: 0, checksumValid: true,
            context: expected, observedAt: at, evaluatedAt: at)
        _ = old.finalizeUnconfirmed(at: at.addingTimeInterval(3), reason: "connection_context_changed")
        XCTAssertEqual(old.statusText(for: old.currentEvaluation(at: at.addingTimeInterval(3)),
            currentObservationMatches: true), "stop unconfirmed")
        let next = StopObservationLifecycle(attemptID: UUID(), source: "test",
            attemptedAt: at.addingTimeInterval(3), context: context())
        XCTAssertEqual(next.statusText(for: next.currentEvaluation(at: at.addingTimeInterval(3)),
            currentObservationMatches: true), "stop requested • confirming")
    }

    func testFreshZeroAndAcceptedNonRunningStateConfirmsStop() {
        let expectedContext = context()
        let result = StopObservationLifecycle.evaluate(
            observation(context: expectedContext),
            attemptAt: attemptAt,
            commandSentAt: attemptAt,
            expectedContext: expectedContext,
            now: attemptAt.addingTimeInterval(1)
        )

        XCTAssertEqual(result.result, .confirmed)
        XCTAssertTrue(result.isConfirmed)
        XCTAssertEqual(StopObservationPolicy.acceptedNonRunningStates, [0, 2, 5, 7, 9])
        XCTAssertEqual(StopObservationPolicy.freshnessInterval, 2.0)
    }

    func testZeroWithRunningStateIsUnconfirmed() {
        let expectedContext = context()
        let result = StopObservationLifecycle.evaluate(
            observation(state: 1, context: expectedContext),
            attemptAt: attemptAt,
            commandSentAt: attemptAt,
            expectedContext: expectedContext,
            now: attemptAt.addingTimeInterval(1)
        )

        XCTAssertEqual(result.result, .contradictory)
        XCTAssertFalse(result.isConfirmed)
    }

    func testFreshNonZeroSpeedIsUnconfirmed() {
        let expectedContext = context()
        let result = StopObservationLifecycle.evaluate(
            observation(speed: 4, state: 1, context: expectedContext),
            attemptAt: attemptAt,
            commandSentAt: attemptAt,
            expectedContext: expectedContext,
            now: attemptAt.addingTimeInterval(1)
        )

        XCTAssertEqual(result.result, .moving)
        XCTAssertFalse(result.isConfirmed)
    }

    func testStaleZeroIsUnconfirmed() {
        let expectedContext = context()
        let result = StopObservationLifecycle.evaluate(
            observation(context: expectedContext),
            attemptAt: attemptAt,
            commandSentAt: attemptAt,
            expectedContext: expectedContext,
            now: attemptAt.addingTimeInterval(3)
        )

        XCTAssertEqual(result.result, .stale)
        XCTAssertFalse(result.isConfirmed)
    }

    func testMissingSpeedAndStateAreUnconfirmed() {
        let expectedContext = context()
        let missingSpeed = StopObservationLifecycle.evaluate(
            observation(speed: nil, context: expectedContext),
            attemptAt: attemptAt,
            commandSentAt: attemptAt,
            expectedContext: expectedContext,
            now: attemptAt.addingTimeInterval(1)
        )
        let missingState = StopObservationLifecycle.evaluate(
            observation(state: nil, context: expectedContext),
            attemptAt: attemptAt,
            commandSentAt: attemptAt,
            expectedContext: expectedContext,
            now: attemptAt.addingTimeInterval(1)
        )

        XCTAssertEqual(missingSpeed.result, .missingSpeed)
        XCTAssertEqual(missingState.result, .missingState)
    }

    func testContradictoryObservationsDoNotCreateFalseConfirmation() {
        let expectedContext = context()
        var lifecycle = StopObservationLifecycle(
            attemptID: UUID(),
            source: "test",
            attemptedAt: attemptAt,
            context: expectedContext
        )
        lifecycle.markCommandSent(at: attemptAt)

        _ = lifecycle.record(
            speedRawTenths: 3,
            state: 0,
            checksumValid: true,
            context: expectedContext,
            observedAt: attemptAt.addingTimeInterval(0.5),
            evaluatedAt: attemptAt.addingTimeInterval(0.5)
        )
        _ = lifecycle.record(
            speedRawTenths: 0,
            state: 1,
            checksumValid: true,
            context: expectedContext,
            observedAt: attemptAt.addingTimeInterval(1),
            evaluatedAt: attemptAt.addingTimeInterval(1)
        )

        XCTAssertNil(lifecycle.firstConfirmedAt)
        XCTAssertNil(lifecycle.finalResult)
        XCTAssertEqual(lifecycle.currentEvaluation(at: attemptAt.addingTimeInterval(1)).result, .contradictory)
    }

    func testLaterFreshQualifyingEvidenceCanConfirmAfterContradiction() {
        let expectedContext = context()
        var lifecycle = StopObservationLifecycle(
            attemptID: UUID(),
            source: "test",
            attemptedAt: attemptAt,
            context: expectedContext
        )
        lifecycle.markCommandSent(at: attemptAt)
        _ = lifecycle.record(
            speedRawTenths: 0,
            state: 1,
            checksumValid: true,
            context: expectedContext,
            observedAt: attemptAt.addingTimeInterval(0.5),
            evaluatedAt: attemptAt.addingTimeInterval(0.5)
        )
        let confirmedAt = attemptAt.addingTimeInterval(1)

        _ = lifecycle.record(
            speedRawTenths: 0,
            state: 5,
            checksumValid: true,
            context: expectedContext,
            observedAt: confirmedAt,
            evaluatedAt: confirmedAt
        )

        XCTAssertEqual(lifecycle.firstConfirmedAt, confirmedAt)
        XCTAssertNil(lifecycle.finalResult)
    }

    func testMovingObservationsFinalizeAsTimeoutUnconfirmed() {
        let expectedContext = context()
        var lifecycle = StopObservationLifecycle(
            attemptID: UUID(),
            source: "test",
            attemptedAt: attemptAt,
            context: expectedContext
        )
        lifecycle.markCommandSent(at: attemptAt)
        _ = lifecycle.record(
            speedRawTenths: 3,
            state: 1,
            checksumValid: true,
            context: expectedContext,
            observedAt: attemptAt.addingTimeInterval(29.5),
            evaluatedAt: attemptAt.addingTimeInterval(29.5)
        )

        _ = lifecycle.finalizeTimeout(at: attemptAt.addingTimeInterval(30))

        XCTAssertEqual(lifecycle.finalResult, .timeoutUnconfirmed)
        XCTAssertEqual(lifecycle.finalReason, "moving_at_timeout")
    }

    func testFirstConfirmedAtUsesFirstQualifyingObservation() {
        let expectedContext = context()
        var lifecycle = StopObservationLifecycle(
            attemptID: UUID(),
            source: "test",
            attemptedAt: attemptAt,
            context: expectedContext
        )
        lifecycle.markCommandSent(at: attemptAt)
        _ = lifecycle.record(
            speedRawTenths: 2,
            state: 1,
            checksumValid: true,
            context: expectedContext,
            observedAt: attemptAt.addingTimeInterval(0.5),
            evaluatedAt: attemptAt.addingTimeInterval(0.5)
        )
        let confirmedAt = attemptAt.addingTimeInterval(1.25)
        _ = lifecycle.record(
            speedRawTenths: 0,
            state: 2,
            checksumValid: true,
            context: expectedContext,
            observedAt: confirmedAt,
            evaluatedAt: confirmedAt
        )

        XCTAssertEqual(lifecycle.firstConfirmedAt, confirmedAt)
        XCTAssertNil(lifecycle.finalResult)
    }

    func testConfirmedThenFreshZeroWithRunningStateIsCurrentlyContradictory() {
        let expectedContext = context()
        var lifecycle = StopObservationLifecycle(
            attemptID: UUID(),
            source: "test",
            attemptedAt: attemptAt,
            context: expectedContext
        )
        lifecycle.markCommandSent(at: attemptAt)
        let confirmedAt = attemptAt.addingTimeInterval(0.5)
        _ = lifecycle.record(
            speedRawTenths: 0,
            state: 2,
            checksumValid: true,
            context: expectedContext,
            observedAt: confirmedAt,
            evaluatedAt: confirmedAt
        )

        let contradictoryAt = attemptAt.addingTimeInterval(1)
        let contradictory = lifecycle.record(
            speedRawTenths: 0,
            state: 1,
            checksumValid: true,
            context: expectedContext,
            observedAt: contradictoryAt,
            evaluatedAt: contradictoryAt
        )

        XCTAssertEqual(contradictory.result, .contradictory)
        XCTAssertFalse(contradictory.isConfirmed)
        XCTAssertEqual(lifecycle.currentEvaluation(at: contradictoryAt).result, .contradictory)
        XCTAssertEqual(lifecycle.firstConfirmedAt, confirmedAt)
        XCTAssertNil(lifecycle.finalResult)
    }

    func testConfirmedBecomesStaleButKeepsHistoricalFirstConfirmation() {
        let expectedContext = context()
        var lifecycle = StopObservationLifecycle(
            attemptID: UUID(),
            source: "test",
            attemptedAt: attemptAt,
            context: expectedContext
        )
        lifecycle.markCommandSent(at: attemptAt)
        let confirmedAt = attemptAt.addingTimeInterval(0.5)
        _ = lifecycle.record(
            speedRawTenths: 0,
            state: 5,
            checksumValid: true,
            context: expectedContext,
            observedAt: confirmedAt,
            evaluatedAt: confirmedAt
        )

        let stale = lifecycle.currentEvaluation(
            at: confirmedAt.addingTimeInterval(StopObservationPolicy.freshnessInterval + 0.01)
        )

        XCTAssertEqual(stale.result, .stale)
        XCTAssertFalse(stale.isConfirmed)
        XCTAssertEqual(lifecycle.firstConfirmedAt, confirmedAt)
        XCTAssertNil(lifecycle.finalResult)
    }

    func testContinuousFreshZeroAcceptedStateKeepsCurrentConfirmation() {
        let expectedContext = context()
        var lifecycle = StopObservationLifecycle(
            attemptID: UUID(),
            source: "test",
            attemptedAt: attemptAt,
            context: expectedContext
        )
        lifecycle.markCommandSent(at: attemptAt)
        let firstConfirmedAt = attemptAt.addingTimeInterval(0.5)
        _ = lifecycle.record(
            speedRawTenths: 0,
            state: 2,
            checksumValid: true,
            context: expectedContext,
            observedAt: firstConfirmedAt,
            evaluatedAt: firstConfirmedAt
        )
        let latestAt = attemptAt.addingTimeInterval(2.0)
        let latest = lifecycle.record(
            speedRawTenths: 0,
            state: 7,
            checksumValid: true,
            context: expectedContext,
            observedAt: latestAt,
            evaluatedAt: latestAt
        )

        XCTAssertTrue(latest.isConfirmed)
        XCTAssertTrue(lifecycle.currentEvaluation(at: latestAt.addingTimeInterval(1.9)).isConfirmed)
        XCTAssertEqual(lifecycle.firstConfirmedAt, firstConfirmedAt)
        XCTAssertEqual(lifecycle.observations.count, 2)
    }

    func testWindowEndUsesCurrentTruthAndPreservesHistoricalConfirmation() {
        let expectedContext = context()
        var lifecycle = StopObservationLifecycle(
            attemptID: UUID(),
            source: "test",
            attemptedAt: attemptAt,
            context: expectedContext
        )
        lifecycle.markCommandSent(at: attemptAt)
        let firstConfirmedAt = attemptAt.addingTimeInterval(0.5)
        _ = lifecycle.record(
            speedRawTenths: 0,
            state: 2,
            checksumValid: true,
            context: expectedContext,
            observedAt: firstConfirmedAt,
            evaluatedAt: firstConfirmedAt
        )

        _ = lifecycle.finalizeTimeout(at: attemptAt.addingTimeInterval(StopObservationPolicy.observationWindow))

        XCTAssertEqual(lifecycle.finalResult, .timeoutUnconfirmed)
        XCTAssertEqual(lifecycle.finalReason, "stale_at_timeout")
        XCTAssertEqual(lifecycle.firstConfirmedAt, firstConfirmedAt)
        XCTAssertEqual(lifecycle.deadline, attemptAt.addingTimeInterval(30))
    }

    func testNewAttemptRejectsPreviousConnectionAndPreAttemptEvidence() {
        let currentContext = context()
        let oldContext = context()
        let wrongContext = StopObservationLifecycle.evaluate(
            observation(context: oldContext),
            attemptAt: attemptAt,
            commandSentAt: attemptAt,
            expectedContext: currentContext,
            now: attemptAt.addingTimeInterval(1)
        )
        let beforeAttempt = StopObservationLifecycle.evaluate(
            observation(context: currentContext, observedAt: attemptAt.addingTimeInterval(-0.1)),
            attemptAt: attemptAt,
            commandSentAt: attemptAt,
            expectedContext: currentContext,
            now: attemptAt
        )

        XCTAssertEqual(wrongContext.result, .wrongContext)
        XCTAssertEqual(beforeAttempt.result, .beforeAttempt)
    }

    func testEvidenceBeforeActualStopWriteCannotConfirm() {
        let expectedContext = context()
        var lifecycle = StopObservationLifecycle(
            attemptID: UUID(),
            source: "test",
            attemptedAt: attemptAt,
            context: expectedContext
        )
        let observedAt = attemptAt.addingTimeInterval(0.1)
        let beforeSend = lifecycle.record(
            speedRawTenths: 0,
            state: 0,
            checksumValid: true,
            context: expectedContext,
            observedAt: observedAt,
            evaluatedAt: observedAt
        )
        lifecycle.markCommandSent(at: attemptAt.addingTimeInterval(0.2))
        let predatesWrite = lifecycle.record(
            speedRawTenths: 0,
            state: 0,
            checksumValid: true,
            context: expectedContext,
            observedAt: observedAt,
            evaluatedAt: attemptAt.addingTimeInterval(0.2)
        )

        XCTAssertEqual(beforeSend.result, .commandNotSent)
        XCTAssertEqual(predatesWrite.result, .beforeCommand)
        XCTAssertNil(lifecycle.firstConfirmedAt)
        XCTAssertTrue(lifecycle.observations.isEmpty)
    }

    func testCommandStatusDistinguishesQueuedSentAndFinalNotSent() {
        let expectedContext = context()
        var queued = StopObservationLifecycle(
            attemptID: UUID(),
            source: "test",
            attemptedAt: attemptAt,
            context: expectedContext
        )
        XCTAssertEqual(queued.commandStatus, "queued")

        queued.markCommandSent(at: attemptAt)
        XCTAssertEqual(queued.commandStatus, "sent")

        var notSent = StopObservationLifecycle(
            attemptID: UUID(),
            source: "test",
            attemptedAt: attemptAt,
            context: expectedContext
        )
        _ = notSent.finalizeUnconfirmed(at: attemptAt, reason: "stop_command_not_sent_not_connected")
        XCTAssertEqual(notSent.commandStatus, "not_sent")
    }

    func testObservationStorageIsBounded() {
        let expectedContext = context()
        var lifecycle = StopObservationLifecycle(
            attemptID: UUID(),
            source: "test",
            attemptedAt: attemptAt,
            context: expectedContext
        )
        lifecycle.markCommandSent(at: attemptAt)

        for index in 0..<(StopObservationPolicy.maxStoredObservations + 20) {
            let observedAt = attemptAt.addingTimeInterval(Double(index) / 100)
            _ = lifecycle.record(
                speedRawTenths: 1,
                state: 1,
                checksumValid: true,
                context: expectedContext,
                observedAt: observedAt,
                evaluatedAt: observedAt
            )
        }

        XCTAssertEqual(lifecycle.observations.count, StopObservationPolicy.maxStoredObservations)
        XCTAssertEqual(lifecycle.observations.last?.sequence, StopObservationPolicy.maxStoredObservations + 20)
    }
}
