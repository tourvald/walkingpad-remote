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

    func testCancelDuringPrepareBlocksRetryUntilProviderCleanupIsIdle() {
        var lifecycle = NativeHeartRateProviderLifecycle()
        let attemptA = UUID()
        lifecycle.bindAttempt(attemptA)
        let prepareGeneration = lifecycle.beginProviderLifecycle()

        let cleanupGeneration = lifecycle.beginCleanup()

        XCTAssertTrue(lifecycle.cleanupInFlight)
        XCTAssertFalse(lifecycle.acceptsProviderCompletion(
            generation: prepareGeneration,
            attemptID: attemptA
        ))
        XCTAssertFalse(lifecycle.completeCleanup(
            generation: cleanupGeneration,
            providerIsIdle: false
        ))
        XCTAssertTrue(lifecycle.cleanupInFlight)
        XCTAssertTrue(lifecycle.completeCleanup(
            generation: cleanupGeneration,
            providerIsIdle: true
        ))
        XCTAssertFalse(lifecycle.cleanupInFlight)
    }

    func testTimeoutDuringCollectionRejectsLateObservationAndCompletion() {
        var lifecycle = NativeHeartRateProviderLifecycle()
        let attemptA = UUID()
        lifecycle.bindAttempt(attemptA)
        let collectionGeneration = lifecycle.beginProviderLifecycle()
        XCTAssertTrue(lifecycle.acceptsObservation(providerIsCollecting: true))

        let cleanupGeneration = lifecycle.beginCleanup()

        XCTAssertFalse(lifecycle.acceptsObservation(providerIsCollecting: true))
        XCTAssertFalse(lifecycle.acceptsProviderCompletion(
            generation: collectionGeneration,
            attemptID: attemptA
        ))
        XCTAssertTrue(lifecycle.completeCleanup(
            generation: cleanupGeneration,
            providerIsIdle: true
        ))
    }

    func testStaleAttemptCompletionCannotAffectNewAttempt() {
        var lifecycle = NativeHeartRateProviderLifecycle()
        let attemptA = UUID()
        lifecycle.bindAttempt(attemptA)
        let generationA = lifecycle.beginProviderLifecycle()
        let cleanupGeneration = lifecycle.beginCleanup()
        XCTAssertTrue(lifecycle.completeCleanup(
            generation: cleanupGeneration,
            providerIsIdle: true
        ))

        let attemptB = UUID()
        lifecycle.bindAttempt(attemptB)
        let generationB = lifecycle.beginProviderLifecycle()

        XCTAssertFalse(lifecycle.acceptsProviderCompletion(
            generation: generationA,
            attemptID: attemptA
        ))
        XCTAssertTrue(lifecycle.acceptsProviderCompletion(
            generation: generationB,
            attemptID: attemptB
        ))
        XCTAssertTrue(lifecycle.acceptsObservation(providerIsCollecting: true))
    }

    func testDelayedRuntimeFailureFromAttemptACannotFailAttemptB() {
        var lifecycle = NativeHeartRateProviderLifecycle()
        let attemptA = UUID()
        lifecycle.bindAttempt(attemptA)
        let contextA = IPhoneHealthKitRuntimeFailureContext(
            providerGeneration: lifecycle.beginProviderLifecycle(),
            attemptID: attemptA
        )
        let cleanupGeneration = lifecycle.beginCleanup()
        XCTAssertTrue(lifecycle.completeCleanup(
            generation: cleanupGeneration,
            providerIsIdle: true
        ))

        let attemptB = UUID()
        lifecycle.bindAttempt(attemptB)
        let contextB = IPhoneHealthKitRuntimeFailureContext(
            providerGeneration: lifecycle.beginProviderLifecycle(),
            attemptID: attemptB
        )

        XCTAssertFalse(lifecycle.acceptsProviderCompletion(
            generation: contextA.providerGeneration,
            attemptID: contextA.attemptID
        ))
        XCTAssertTrue(lifecycle.acceptsProviderCompletion(
            generation: contextB.providerGeneration,
            attemptID: contextB.attemptID
        ))
    }

    func testResolvingDeferredLinkageAPreservesLinkageBIdentity() {
        let profileA = UUID()
        let telemetrySessionA = UUID()
        let linkageA = DeferredNativeHealthKitLinkage(
            acquisitionStartedAt: now,
            finishRequestedAt: now.addingTimeInterval(30),
            healthKitStoppedAt: nil,
            profileID: profileA,
            telemetrySessionID: telemetrySessionA,
            linksLegacyWorkout: true,
            legacyWorkoutID: nil,
            recoveryAppWorkoutID: nil,
            healthKitWorkoutID: nil
        )
        let profileB = UUID()
        let telemetrySessionB = UUID()
        let linkageB = DeferredNativeHealthKitLinkage(
            acquisitionStartedAt: now.addingTimeInterval(60),
            finishRequestedAt: now.addingTimeInterval(90),
            healthKitStoppedAt: nil,
            profileID: profileB,
            telemetrySessionID: telemetrySessionB,
            linksLegacyWorkout: true,
            legacyWorkoutID: nil,
            recoveryAppWorkoutID: nil,
            healthKitWorkoutID: nil
        )
        var pending = [linkageA, linkageB]

        pending.removeAll { $0 == linkageA }

        XCTAssertEqual(pending, [linkageB])
        XCTAssertEqual(pending[0].profileID, profileB)
        XCTAssertEqual(pending[0].telemetrySessionID, telemetrySessionB)
        XCTAssertNotEqual(pending[0].profileID, profileA)
        XCTAssertNotEqual(pending[0].telemetrySessionID, telemetrySessionA)
    }

    func testSavedWorkoutProofFreezesExactUUIDWithoutLosingDeferredIdentity() {
        let recoveryAppWorkoutID = UUID()
        let legacyWorkoutID = UUID()
        let telemetrySessionID = UUID()
        let pending = DeferredNativeHealthKitLinkage(
            acquisitionStartedAt: now,
            finishRequestedAt: now.addingTimeInterval(30),
            healthKitStoppedAt: now.addingTimeInterval(31),
            profileID: UUID(),
            telemetrySessionID: telemetrySessionID,
            linksLegacyWorkout: true,
            legacyWorkoutID: legacyWorkoutID,
            recoveryAppWorkoutID: recoveryAppWorkoutID,
            healthKitWorkoutID: nil
        )
        let healthKitWorkoutID = UUID()

        let proven = pending.provingSavedWorkout(id: healthKitWorkoutID)

        XCTAssertEqual(proven.healthKitWorkoutID, healthKitWorkoutID)
        XCTAssertEqual(proven.recoveryAppWorkoutID, recoveryAppWorkoutID)
        XCTAssertEqual(proven.legacyWorkoutID, legacyWorkoutID)
        XCTAssertEqual(proven.telemetrySessionID, telemetrySessionID)
        XCTAssertEqual(proven.acquisitionStartedAt, pending.acquisitionStartedAt)
        XCTAssertEqual(proven.finishRequestedAt, pending.finishRequestedAt)
        XCTAssertEqual(proven.healthKitStoppedAt, pending.healthKitStoppedAt)
    }

    func testDeferredLinkageWithoutExactWorkoutIDStillDecodesForProofQuery() throws {
        let linkage = DeferredNativeHealthKitLinkage(
            acquisitionStartedAt: now,
            finishRequestedAt: now.addingTimeInterval(30),
            healthKitStoppedAt: now.addingTimeInterval(31),
            profileID: UUID(),
            telemetrySessionID: UUID(),
            linksLegacyWorkout: false,
            legacyWorkoutID: nil,
            recoveryAppWorkoutID: UUID(),
            healthKitWorkoutID: UUID()
        )
        let encoded = try JSONEncoder().encode(linkage)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "healthKitWorkoutID")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(
            DeferredNativeHealthKitLinkage.self,
            from: legacyData
        )

        XCTAssertNil(decoded.healthKitWorkoutID)
        XCTAssertEqual(decoded.recoveryAppWorkoutID, linkage.recoveryAppWorkoutID)
        XCTAssertEqual(decoded.telemetrySessionID, linkage.telemetrySessionID)
    }

    func testBaseShapeDeferredLinkageUpgradesInPlaceWithoutRepeatedQuery() throws {
        let current = DeferredNativeHealthKitLinkage(
            acquisitionStartedAt: now,
            finishRequestedAt: now.addingTimeInterval(30),
            healthKitStoppedAt: now.addingTimeInterval(31),
            profileID: UUID(),
            telemetrySessionID: UUID(),
            linksLegacyWorkout: true,
            legacyWorkoutID: UUID(),
            recoveryAppWorkoutID: UUID(),
            healthKitWorkoutID: nil
        )
        let encoded = try JSONEncoder().encode(current)
        var baseObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        for key in [
            "healthKitStoppedAt", "legacyWorkoutID",
            "recoveryAppWorkoutID", "healthKitWorkoutID",
        ] {
            baseObject.removeValue(forKey: key)
        }
        let baseData = try JSONSerialization.data(withJSONObject: baseObject)
        let baseShape = try JSONDecoder().decode(
            DeferredNativeHealthKitLinkage.self,
            from: baseData
        )
        let workoutID = UUID()

        let updated = try XCTUnwrap(
            DeferredNativeHealthKitLinkageQueue.provingSavedWorkout(
                id: workoutID,
                replacing: baseShape,
                in: [baseShape]
            )
        )

        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated[0].healthKitWorkoutID, workoutID)
        XCTAssertNil(updated[0].recoveryAppWorkoutID)
        XCTAssertEqual(
            DeferredNativeHealthKitLinkageQueue.next(in: updated),
            updated[0]
        )
    }

    func testExactDeferredProofCannotDowngradeOrChangeUUID() throws {
        let recoveryAppWorkoutID = UUID()
        let pending = DeferredNativeHealthKitLinkage(
            acquisitionStartedAt: now,
            finishRequestedAt: now.addingTimeInterval(30),
            healthKitStoppedAt: now.addingTimeInterval(31),
            profileID: UUID(),
            telemetrySessionID: UUID(),
            linksLegacyWorkout: false,
            legacyWorkoutID: nil,
            recoveryAppWorkoutID: recoveryAppWorkoutID,
            healthKitWorkoutID: nil
        )
        let workoutA = UUID()
        let exactA = pending.provingSavedWorkout(id: workoutA)
        let workoutB = UUID()

        XCTAssertEqual(
            DeferredNativeHealthKitLinkageQueue.retaining(
                pending,
                in: [exactA]
            ),
            [exactA]
        )
        XCTAssertNil(DeferredNativeHealthKitLinkageQueue.retaining(
            pending.provingSavedWorkout(id: workoutB),
            in: [exactA]
        ))
        XCTAssertNil(DeferredNativeHealthKitLinkageQueue.provingSavedWorkout(
            id: workoutB,
            replacing: exactA,
            in: [exactA]
        ))
    }

    func testExactDeferredLinkageIsSelectedAheadOfUnresolvedLegacyRow() {
        let legacy = DeferredNativeHealthKitLinkage(
            acquisitionStartedAt: now,
            finishRequestedAt: now.addingTimeInterval(30),
            healthKitStoppedAt: nil,
            profileID: nil,
            telemetrySessionID: nil,
            linksLegacyWorkout: false,
            legacyWorkoutID: nil,
            recoveryAppWorkoutID: nil,
            healthKitWorkoutID: nil
        )
        let exact = DeferredNativeHealthKitLinkage(
            acquisitionStartedAt: now.addingTimeInterval(60),
            finishRequestedAt: now.addingTimeInterval(90),
            healthKitStoppedAt: now.addingTimeInterval(91),
            profileID: UUID(),
            telemetrySessionID: UUID(),
            linksLegacyWorkout: false,
            legacyWorkoutID: nil,
            recoveryAppWorkoutID: UUID(),
            healthKitWorkoutID: UUID()
        )

        XCTAssertEqual(
            DeferredNativeHealthKitLinkageQueue.next(in: [legacy, exact]),
            exact
        )
    }

    func testActionableExactLinkageIsSelectedAheadOfBaseExactLegacyDebt() {
        let baseExact = DeferredNativeHealthKitLinkage(
            acquisitionStartedAt: now,
            finishRequestedAt: now.addingTimeInterval(30),
            healthKitStoppedAt: nil,
            profileID: UUID(),
            telemetrySessionID: UUID(),
            linksLegacyWorkout: true,
            legacyWorkoutID: nil,
            recoveryAppWorkoutID: nil,
            healthKitWorkoutID: UUID()
        )
        let actionableExact = DeferredNativeHealthKitLinkage(
            acquisitionStartedAt: now.addingTimeInterval(60),
            finishRequestedAt: now.addingTimeInterval(90),
            healthKitStoppedAt: now.addingTimeInterval(91),
            profileID: UUID(),
            telemetrySessionID: UUID(),
            linksLegacyWorkout: true,
            legacyWorkoutID: UUID(),
            recoveryAppWorkoutID: UUID(),
            healthKitWorkoutID: UUID()
        )

        XCTAssertEqual(
            DeferredNativeHealthKitLinkageQueue.next(
                in: [baseExact, actionableExact]
            ),
            actionableExact
        )
    }

    func testCurrentPendingProofIsSelectedAheadOfOlderBaseDebt() {
        let oldBase = DeferredNativeHealthKitLinkage(
            acquisitionStartedAt: now,
            finishRequestedAt: now.addingTimeInterval(30),
            healthKitStoppedAt: nil,
            profileID: nil,
            telemetrySessionID: nil,
            linksLegacyWorkout: true,
            legacyWorkoutID: nil,
            recoveryAppWorkoutID: nil,
            healthKitWorkoutID: nil
        )
        let currentWorkoutID = UUID()
        let currentPending = DeferredNativeHealthKitLinkage(
            acquisitionStartedAt: now.addingTimeInterval(60),
            finishRequestedAt: now.addingTimeInterval(90),
            healthKitStoppedAt: now.addingTimeInterval(91),
            profileID: UUID(),
            telemetrySessionID: UUID(),
            linksLegacyWorkout: true,
            legacyWorkoutID: UUID(),
            recoveryAppWorkoutID: currentWorkoutID,
            healthKitWorkoutID: nil
        )

        XCTAssertEqual(
            DeferredNativeHealthKitLinkageQueue.next(
                in: [oldBase, currentPending],
                preferredRecoveryAppWorkoutID: currentWorkoutID
            ),
            currentPending
        )
    }

    func testLateObservationAfterCancelCannotRegainOwnership() {
        var lifecycle = NativeHeartRateProviderLifecycle()
        lifecycle.bindAttempt(UUID())
        _ = lifecycle.beginProviderLifecycle()
        _ = lifecycle.beginCleanup()

        XCTAssertNil(lifecycle.attemptID)
        XCTAssertFalse(lifecycle.acceptsObservation(providerIsCollecting: true))
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
