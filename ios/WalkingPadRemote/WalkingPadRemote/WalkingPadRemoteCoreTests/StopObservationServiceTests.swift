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
