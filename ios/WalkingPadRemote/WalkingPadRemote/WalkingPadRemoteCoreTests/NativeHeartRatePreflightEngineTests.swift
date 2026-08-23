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
        engine.collectionStarted(
            intentID: intent.id,
            acquisitionStartedAt: intent.requestedAt
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
        telemetryAvailability: NativeHeartRatePreflightEngine.TelemetryAvailability = .healthy
    ) -> NativeHeartRatePreflightEngine.SafetyFacts {
        .init(
            appActivity: appActivity,
            treadmillControlReady: treadmillControlReady,
            transportValid: true,
            controllerUnitsAllowed: true,
            hasConflictingWorkout: false,
            stopInProgress: false,
            telemetryAvailability: telemetryAvailability
        )
    }
}
