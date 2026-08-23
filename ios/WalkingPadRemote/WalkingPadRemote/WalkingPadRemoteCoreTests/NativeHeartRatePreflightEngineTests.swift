import XCTest
@testable import WalkingPadCoreLogic

final class NativeHeartRatePreflightEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testHubHoldsOnePreparedSessionWithoutPollingOrStartingCollection() {
        var engine = NativeHeartRatePreflightEngine()

        XCTAssertEqual(engine.requestWarmPreparation(), [.prepare])
        XCTAssertEqual(engine.requestWarmPreparation(), [])
        XCTAssertEqual(engine.providerPrepared(at: now), [])
        XCTAssertTrue(engine.isWarmPrepared)
        XCTAssertEqual(engine.requestWarmPreparation(), [])
    }

    func testStartWithoutHeartRateOnlyStartsNativeCollection() {
        var engine = preparedEngine()
        let intent = makeIntent()

        let effects = engine.requestStart(intent: intent, safety: safeFacts())

        XCTAssertEqual(effects, [
            .startCollection(intent: intent, acquisitionStartedAt: intent.requestedAt),
        ])
        XCTAssertTrue(engine.hasStartIntent)
    }

    func testQualifyingNativeHeartRateCommitsExactlyOnce() {
        var engine = waitingEngine()
        let observation = nativeObservation()

        let first = engine.receive(
            observation,
            safety: safeFacts(),
            now: now.addingTimeInterval(2),
            freshnessLimit: 7
        )
        let repeated = engine.receive(
            observation,
            safety: safeFacts(),
            now: now.addingTimeInterval(3),
            freshnessLimit: 7
        )

        XCTAssertEqual(first.count, 1)
        guard case .commit = first.first else {
            return XCTFail("Expected one commit")
        }
        XCTAssertEqual(repeated, [])
    }

    func testCachedPreSessionAndLegacyWatchHeartRateCannotCommit() {
        var cachedEngine = waitingEngine()
        var watchEngine = waitingEngine()

        XCTAssertEqual(cachedEngine.receive(
            nativeObservation(measuredAt: now.addingTimeInterval(-1)),
            safety: safeFacts(),
            now: now.addingTimeInterval(2),
            freshnessLimit: 7
        ), [])
        XCTAssertEqual(watchEngine.receive(
            nativeObservation(source: .legacyWatch),
            safety: safeFacts(),
            now: now.addingTimeInterval(2),
            freshnessLimit: 7
        ), [])
    }

    func testFirstNativeHeartRateCommitsImmediatelyWithoutTimerTick() {
        var engine = waitingEngine()

        let effects = engine.receive(
            nativeObservation(),
            safety: safeFacts(),
            now: now.addingTimeInterval(2),
            freshnessLimit: 7
        )

        XCTAssertEqual(effects.count, 1)
        guard case .commit = effects[0] else {
            return XCTFail("Expected immediate commit")
        }
    }

    func testRawLinkWithoutControlReadinessBlocksStart() {
        var engine = preparedEngine()
        XCTAssertEqual(engine.requestStart(
            intent: makeIntent(),
            safety: safeFacts(treadmillControlReady: false)
        ), [])
        XCTAssertTrue(engine.isWarmPrepared)
    }

    func testControlReadinessLossBeforeHeartRateDiscards() {
        var engine = waitingEngine()

        XCTAssertEqual(engine.safetyChanged(
            safeFacts(treadmillControlReady: false),
            now: now.addingTimeInterval(2),
            freshnessLimit: 7
        ), [.discard(reason: .treadmillControlLost)])
        XCTAssertFalse(engine.ownsUncommittedWorkout)
    }

    func testTransientInactiveKeepsPreflightAndDefersCommitUntilActive() {
        var engine = waitingEngine()
        let inactiveFacts = safeFacts(appActivity: .inactive)

        XCTAssertEqual(engine.receive(
            nativeObservation(),
            safety: inactiveFacts,
            now: now.addingTimeInterval(2),
            freshnessLimit: 7
        ), [])
        XCTAssertTrue(engine.hasStartIntent)

        let effects = engine.safetyChanged(
            safeFacts(),
            now: now.addingTimeInterval(3),
            freshnessLimit: 7
        )
        XCTAssertEqual(effects.count, 1)
        guard case .commit = effects[0] else {
            return XCTFail("Expected deferred commit")
        }
    }

    func testBackgroundBeforeCommitDiscards() {
        var engine = waitingEngine()
        XCTAssertEqual(engine.safetyChanged(
            safeFacts(appActivity: .background),
            now: now.addingTimeInterval(2),
            freshnessLimit: 7
        ), [.discard(reason: .appBackgrounded)])
    }

    func testUserCancelDiscards() {
        var engine = waitingEngine()
        XCTAssertEqual(engine.cancel(reason: .user), [.discard(reason: .user)])
        XCTAssertEqual(engine.cancel(reason: .user), [])
    }

    func testThirtySecondTimeoutDiscards() {
        var engine = waitingEngine()
        XCTAssertEqual(engine.tick(now: now.addingTimeInterval(29.9)), [])
        XCTAssertEqual(engine.tick(now: now.addingTimeInterval(30)), [
            .discard(reason: .timeout),
        ])
    }

    func testHeartRateAtDeadlineCannotCommitWithoutTimerTick() {
        var engine = waitingEngine()

        XCTAssertEqual(engine.receive(
            nativeObservation(
                measuredAt: now.addingTimeInterval(30),
                receivedAt: now.addingTimeInterval(30)
            ),
            safety: safeFacts(),
            now: now.addingTimeInterval(30),
            freshnessLimit: 7
        ), [.discard(reason: .timeout)])
    }

    func testHeartRateAfterDeadlineCannotCommitWithoutTimerTick() {
        var engine = waitingEngine()

        XCTAssertEqual(engine.receive(
            nativeObservation(
                measuredAt: now.addingTimeInterval(31),
                receivedAt: now.addingTimeInterval(31)
            ),
            safety: safeFacts(),
            now: now.addingTimeInterval(31),
            freshnessLimit: 7
        ), [.discard(reason: .timeout)])
    }

    func testDeferredInactiveToActiveAtDeadlineTimesOutInsteadOfCommitting() {
        var engine = waitingEngine()
        XCTAssertEqual(engine.receive(
            nativeObservation(),
            safety: safeFacts(appActivity: .inactive),
            now: now.addingTimeInterval(2),
            freshnessLimit: 40
        ), [])

        XCTAssertEqual(engine.safetyChanged(
            safeFacts(),
            now: now.addingTimeInterval(30),
            freshnessLimit: 40
        ), [.discard(reason: .timeout)])
    }

    func testPreparationCompletingAtDeadlineTimesOutBeforeCollection() {
        var engine = NativeHeartRatePreflightEngine()
        let intent = makeIntent()
        XCTAssertEqual(engine.requestStart(intent: intent, safety: safeFacts()), [.prepare])

        XCTAssertEqual(engine.providerPrepared(
            at: now.addingTimeInterval(30)
        ), [.discard(reason: .timeout)])
    }

    func testCollectionCompletingAtDeadlineTimesOutBeforeWaitingForHeartRate() {
        var engine = preparedEngine()
        let intent = makeIntent()
        _ = engine.requestStart(intent: intent, safety: safeFacts())

        XCTAssertEqual(engine.collectionStarted(
            intentID: intent.id,
            acquisitionStartedAt: intent.requestedAt,
            now: now.addingTimeInterval(30)
        ), [.discard(reason: .timeout)])
    }

    func testRuntimeStopPolicyAllowsCleanIdleAndBlocksUnresolvedStop() {
        XCTAssertFalse(NativeHeartRatePreflightEngine.RuntimePolicy.stopInProgress(
            hasObservationLifecycle: false,
            observationHasFinalResult: false,
            hasUnavailableAttempt: false
        ))
        XCTAssertTrue(NativeHeartRatePreflightEngine.RuntimePolicy.stopInProgress(
            hasObservationLifecycle: true,
            observationHasFinalResult: false,
            hasUnavailableAttempt: false
        ))

        var engine = preparedEngine()
        XCTAssertEqual(engine.requestStart(
            intent: makeIntent(),
            safety: safeFacts(stopInProgress: false)
        ).count, 1)
        var blockedEngine = preparedEngine()
        XCTAssertEqual(blockedEngine.requestStart(
            intent: makeIntent(),
            safety: safeFacts(stopInProgress: true)
        ), [])
    }

    func testFreshNativeHeartRateCrossesProductionCommitSeamExactlyOnce() {
        var engine = waitingEngine()
        let observation = nativeObservation()
        let effects = engine.receive(
            observation,
            safety: safeFacts(),
            now: now.addingTimeInterval(2),
            freshnessLimit: 7
        )
        guard case .commit(let intent, let committedObservation, let startedAt) = effects.first else {
            return XCTFail("Expected engine commit")
        }

        var nativeWorkoutCommitted = false
        var productionStartCount = 0
        for _ in 0..<2 {
            let safety = safeFacts(hasConflictingWorkout:
                NativeHeartRatePreflightEngine.RuntimePolicy.hasConflictingWorkout(
                    isHrControlRunning: false,
                    treadmillTestRunIsActive: false,
                    nativeWorkoutCommitted: nativeWorkoutCommitted,
                    nativeFlowOwnsController: true,
                    nativeWorkoutFinishInFlight: false
                )
            )
            let permitted = NativeHeartRatePreflightEngine.RuntimePolicy
                .permitsProductionCommit(
                    intent: intent,
                    now: now.addingTimeInterval(2),
                    flowOwnsController: true,
                    nativeWorkoutAlreadyCommitted: nativeWorkoutCommitted,
                    providerIsCollecting: true,
                    observationIsQualifying: committedObservation.isQualifying(
                        collectionStartedAt: startedAt,
                        now: now.addingTimeInterval(2),
                        freshnessLimit: 7
                    ),
                    safety: safety
                )
            if permitted {
                nativeWorkoutCommitted = true
                let postClaimSafety = safeFacts(hasConflictingWorkout:
                    NativeHeartRatePreflightEngine.RuntimePolicy.hasConflictingWorkout(
                        isHrControlRunning: false,
                        treadmillTestRunIsActive: false,
                        nativeWorkoutCommitted: nativeWorkoutCommitted,
                        nativeFlowOwnsController: true,
                        nativeWorkoutFinishInFlight: false
                    )
                )
                if postClaimSafety.permitsCommit {
                    productionStartCount += 1
                }
            }
        }

        XCTAssertEqual(productionStartCount, 1)
    }

    func testProductionCommitSeamRechecksDeadlineAfterEngineCommitEffect() {
        var engine = waitingEngine()
        let beforeDeadline = now.addingTimeInterval(29.9)
        let effects = engine.receive(
            nativeObservation(
                measuredAt: beforeDeadline,
                receivedAt: beforeDeadline
            ),
            safety: safeFacts(),
            now: beforeDeadline,
            freshnessLimit: 7
        )
        guard case .commit(let intent, let observation, let startedAt) = effects.first else {
            return XCTFail("Expected engine commit before deadline")
        }

        XCTAssertFalse(NativeHeartRatePreflightEngine.RuntimePolicy.permitsProductionCommit(
            intent: intent,
            now: now.addingTimeInterval(30),
            flowOwnsController: true,
            nativeWorkoutAlreadyCommitted: false,
            providerIsCollecting: true,
            observationIsQualifying: observation.isQualifying(
                collectionStartedAt: startedAt,
                now: beforeDeadline,
                freshnessLimit: 7
            ),
            safety: safeFacts()
        ))
    }

    func testRapidStopToHubWarmCannotInterfereWithCommittedFinish() {
        XCTAssertFalse(NativeHeartRatePreflightEngine.RuntimePolicy.canWarmPrepare(
            isTrainingHubVisible: true,
            appActivity: .active,
            isHrControlRunning: false,
            nativeWorkoutCommitted: true,
            nativeWorkoutFinishInFlight: true,
            providerIsIdle: false,
            providerIsSupported: true
        ))
        XCTAssertFalse(NativeHeartRatePreflightEngine.RuntimePolicy.canWarmPrepare(
            isTrainingHubVisible: true,
            appActivity: .active,
            isHrControlRunning: false,
            nativeWorkoutCommitted: false,
            nativeWorkoutFinishInFlight: false,
            providerIsIdle: false,
            providerIsSupported: true
        ))
        XCTAssertTrue(NativeHeartRatePreflightEngine.RuntimePolicy.canWarmPrepare(
            isTrainingHubVisible: true,
            appActivity: .active,
            isHrControlRunning: false,
            nativeWorkoutCommitted: false,
            nativeWorkoutFinishInFlight: false,
            providerIsIdle: true,
            providerIsSupported: true
        ))
    }

    func testFrozenIntentIsReturnedAtCommit() {
        var engine = waitingEngine(targetBPM: 151, durationMinutes: 45)

        let effects = engine.receive(
            nativeObservation(),
            safety: safeFacts(),
            now: now.addingTimeInterval(2),
            freshnessLimit: 7
        )

        guard case .commit(let intent, _, let acquisitionStartedAt) = effects.first else {
            return XCTFail("Expected commit")
        }
        XCTAssertEqual(intent.targetBPM, 151)
        XCTAssertEqual(intent.durationMinutes, 45)
        XCTAssertEqual(acquisitionStartedAt, now)
    }

    func testAcquisitionStartPrecedesCommitAndIsPreserved() {
        var engine = waitingEngine()
        let commitAt = now.addingTimeInterval(5)

        let effects = engine.receive(
            nativeObservation(receivedAt: commitAt),
            safety: safeFacts(),
            now: commitAt,
            freshnessLimit: 7
        )

        guard case .commit(_, _, let acquisitionStartedAt) = effects.first else {
            return XCTFail("Expected commit")
        }
        XCTAssertEqual(acquisitionStartedAt, now)
        XCTAssertLessThan(acquisitionStartedAt, commitAt)
    }

    func testTelemetryAvailabilityDoesNotChangeCommitSafety() {
        for availability in [
            NativeHeartRatePreflightEngine.TelemetryAvailability.healthy,
            .degraded,
            .unavailable,
        ] {
            var engine = waitingEngine()
            let effects = engine.receive(
                nativeObservation(),
                safety: safeFacts(telemetryAvailability: availability),
                now: now.addingTimeInterval(2),
                freshnessLimit: 7
            )
            XCTAssertEqual(effects.count, 1, "\(availability)")
            guard case .commit = effects[0] else {
                return XCTFail("Expected commit for \(availability)")
            }
        }
    }

    private func preparedEngine() -> NativeHeartRatePreflightEngine {
        var engine = NativeHeartRatePreflightEngine()
        _ = engine.requestWarmPreparation()
        _ = engine.providerPrepared(at: now)
        return engine
    }

    private func waitingEngine(
        targetBPM: Int = 145,
        durationMinutes: Int = 30
    ) -> NativeHeartRatePreflightEngine {
        var engine = preparedEngine()
        let intent = makeIntent(targetBPM: targetBPM, durationMinutes: durationMinutes)
        _ = engine.requestStart(intent: intent, safety: safeFacts())
        _ = engine.collectionStarted(
            intentID: intent.id,
            acquisitionStartedAt: intent.requestedAt,
            now: intent.requestedAt
        )
        return engine
    }

    private func makeIntent(
        targetBPM: Int = 145,
        durationMinutes: Int = 30
    ) -> NativeHeartRatePreflightEngine.Intent {
        .init(
            id: UUID(uuidString: "A7B3EAB7-C59A-453D-BC4E-9C030BAC8659")!,
            targetBPM: targetBPM,
            durationMinutes: durationMinutes,
            requestedAt: now
        )
    }

    private func nativeObservation(
        source: NativeHeartRatePreflightEngine.ObservationSource = .nativeHealthKit,
        measuredAt: Date? = nil,
        receivedAt: Date? = nil
    ) -> NativeHeartRatePreflightEngine.Observation {
        .init(
            source: source,
            beatsPerMinute: 142,
            measuredAt: measuredAt ?? now.addingTimeInterval(1),
            receivedAt: receivedAt ?? now.addingTimeInterval(1)
        )
    }

    private func safeFacts(
        appActivity: NativeHeartRatePreflightEngine.AppActivity = .active,
        treadmillControlReady: Bool = true,
        hasConflictingWorkout: Bool = false,
        stopInProgress: Bool = false,
        telemetryAvailability: NativeHeartRatePreflightEngine.TelemetryAvailability = .healthy
    ) -> NativeHeartRatePreflightEngine.SafetyFacts {
        .init(
            appActivity: appActivity,
            treadmillControlReady: treadmillControlReady,
            transportValid: true,
            controllerUnitsAllowed: true,
            hasConflictingWorkout: hasConflictingWorkout,
            stopInProgress: stopInProgress,
            telemetryAvailability: telemetryAvailability
        )
    }
}
