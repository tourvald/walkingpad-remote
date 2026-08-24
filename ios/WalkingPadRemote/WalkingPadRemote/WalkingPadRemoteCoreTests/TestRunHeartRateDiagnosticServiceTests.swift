import XCTest
@testable import WalkingPadCoreLogic

final class TestRunHeartRateDiagnosticServiceTests: XCTestCase {
    private let runID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let startedAt = Date(timeIntervalSince1970: 1_000)

    func testUsesProductionQualificationSemanticsAndTracksFreshnessSeparately() {
        var service = TestRunHeartRateDiagnosticService()
        service.start(runID: runID, at: startedAt)
        service.collectionStarted(expectedRunID: runID, at: startedAt)

        service.receive(
            observation(
                bpm: 128,
                measuredAt: startedAt.addingTimeInterval(1),
                receivedAt: startedAt.addingTimeInterval(1.75),
                callbackObservedAt: startedAt.addingTimeInterval(1.5),
                providerNativeIdentity: "provider-sample-1"
            ),
            expectedRunID: runID,
            now: startedAt.addingTimeInterval(2),
            freshnessLimit: 7
        )

        let current = service.snapshot(
            now: startedAt.addingTimeInterval(2),
            freshnessLimit: 7
        )
        XCTAssertEqual(current.receivedSampleCount, 1)
        XCTAssertEqual(current.displayFreshSampleCount, 1)
        XCTAssertEqual(current.qualifyingSampleCount, 1)
        XCTAssertEqual(current.rejectedSampleCount, 0)
        XCTAssertEqual(current.latestSource, "native_healthkit")
        XCTAssertEqual(
            current.latestSourceCallbackObservedAt,
            startedAt.addingTimeInterval(1.5)
        )
        XCTAssertEqual(current.latestProviderNativeIdentity, "provider-sample-1")
        XCTAssertEqual(current.firstQualifyingSampleLatencySeconds, 1.75)
        XCTAssertTrue(current.latestStartQualified)
        XCTAssertTrue(current.latestDisplayFresh)

        let staleDisplay = service.snapshot(
            now: startedAt.addingTimeInterval(20),
            freshnessLimit: 7
        )
        XCTAssertTrue(staleDisplay.latestStartQualified)
        XCTAssertFalse(staleDisplay.latestDisplayFresh)
    }

    func testPreCollectionAndStaleSamplesExposeExactRejectionReasons() {
        var service = TestRunHeartRateDiagnosticService()
        service.start(runID: runID, at: startedAt)
        service.collectionStarted(expectedRunID: runID, at: startedAt)

        service.receive(
            observation(bpm: 120, measuredAt: startedAt.addingTimeInterval(-1)),
            expectedRunID: runID,
            now: startedAt,
            freshnessLimit: 7
        )
        XCTAssertEqual(
            service.snapshot(now: startedAt, freshnessLimit: 7).latestRejectionReason,
            .receivedBeforeCollection
        )

        service.receive(
            observation(
                bpm: 121,
                measuredAt: startedAt.addingTimeInterval(1),
                receivedAt: startedAt.addingTimeInterval(2)
            ),
            expectedRunID: runID,
            now: startedAt.addingTimeInterval(20),
            freshnessLimit: 7
        )
        let snapshot = service.snapshot(now: startedAt.addingTimeInterval(20), freshnessLimit: 7)
        XCTAssertEqual(snapshot.latestRejectionReason, .stale)
        XCTAssertEqual(snapshot.receivedSampleCount, 2)
        XCTAssertEqual(snapshot.rejectedSampleCount, 2)
        XCTAssertEqual(snapshot.rejectionCountsByReason[.receivedBeforeCollection], 1)
        XCTAssertEqual(snapshot.rejectionCountsByReason[.stale], 1)
        XCTAssertFalse(snapshot.latestStartQualified)
    }

    func testFirstQualifyingSampleTimeoutIsTerminalAndStaleRunCannotMutateIt() {
        var service = TestRunHeartRateDiagnosticService()
        service.start(runID: runID, at: startedAt)
        service.collectionStarted(expectedRunID: runID, at: startedAt)

        XCTAssertFalse(service.timeoutIfNeeded(
            expectedRunID: runID,
            now: startedAt.addingTimeInterval(29.9)
        ))
        XCTAssertTrue(service.timeoutIfNeeded(
            expectedRunID: runID,
            now: startedAt.addingTimeInterval(30)
        ))
        service.receive(
            observation(bpm: 130, measuredAt: startedAt.addingTimeInterval(31)),
            expectedRunID: UUID(),
            now: startedAt.addingTimeInterval(31),
            freshnessLimit: 7
        )

        let snapshot = service.snapshot(now: startedAt.addingTimeInterval(31), freshnessLimit: 7)
        XCTAssertEqual(snapshot.phase, .failed)
        XCTAssertEqual(snapshot.terminalReason, .timeout)
        XCTAssertEqual(snapshot.receivedSampleCount, 0)
    }

    func testCompletionAndCancellationKeepCountersForReport() {
        var service = TestRunHeartRateDiagnosticService()
        service.start(runID: runID, at: startedAt)
        service.collectionStarted(expectedRunID: runID, at: startedAt)
        service.receive(
            observation(bpm: 126, measuredAt: startedAt.addingTimeInterval(1)),
            expectedRunID: runID,
            now: startedAt.addingTimeInterval(1),
            freshnessLimit: 7
        )
        service.finish(expectedRunID: runID, reason: .testRunCompleted)
        service.providerDiscarded(expectedRunID: runID)

        let completed = service.snapshot(now: startedAt.addingTimeInterval(85), freshnessLimit: 7)
        XCTAssertEqual(completed.phase, .completed)
        XCTAssertEqual(completed.providerState, "idle_discarded")
        XCTAssertEqual(completed.qualifyingSampleCount, 1)

        let secondRunID = UUID()
        service.start(runID: secondRunID, at: startedAt.addingTimeInterval(100))
        service.finish(expectedRunID: secondRunID, reason: .appInactive)
        XCTAssertEqual(
            service.snapshot(now: startedAt.addingTimeInterval(101), freshnessLimit: 7).phase,
            .cancelled
        )
    }

    func testDelayedObservationFromOldAttemptCannotMutateNewAttempt() {
        let providerA = FakeDiagnosticProvider()
        let providerB = FakeDiagnosticProvider()
        let attemptA = TestRunHeartRateDiagnosticProviderAttempt(
            runID: runID,
            generation: 1,
            providerIdentity: ObjectIdentifier(providerA)
        )
        let runB = UUID()
        let attemptB = TestRunHeartRateDiagnosticProviderAttempt(
            runID: runB,
            generation: 2,
            providerIdentity: ObjectIdentifier(providerB)
        )
        var ownership = TestRunHeartRateDiagnosticProviderOwnership()
        ownership.bind(attemptA)
        XCTAssertTrue(ownership.release(attemptA))
        ownership.bind(attemptB)

        var service = TestRunHeartRateDiagnosticService()
        service.start(runID: runB, at: startedAt)
        service.collectionStarted(expectedRunID: runB, at: startedAt)
        service.receive(
            observation(bpm: 140, measuredAt: startedAt.addingTimeInterval(1)),
            expectedRunID: attemptA.runID,
            now: startedAt.addingTimeInterval(1),
            freshnessLimit: 7
        )

        XCTAssertFalse(ownership.accepts(attemptA, provider: providerA))
        XCTAssertEqual(ownership.currentAttempt, attemptB)
        XCTAssertTrue(ownership.accepts(attemptB, provider: providerB))
        XCTAssertEqual(
            service.snapshot(now: startedAt.addingTimeInterval(1), freshnessLimit: 7)
                .receivedSampleCount,
            0
        )
    }

    func testDelayedFailureFromOldAttemptCannotReleaseNewAttempt() {
        let providerA = FakeDiagnosticProvider()
        let providerB = FakeDiagnosticProvider()
        let attemptA = TestRunHeartRateDiagnosticProviderAttempt(
            runID: runID,
            generation: 1,
            providerIdentity: ObjectIdentifier(providerA)
        )
        let attemptB = TestRunHeartRateDiagnosticProviderAttempt(
            runID: UUID(),
            generation: 2,
            providerIdentity: ObjectIdentifier(providerB)
        )
        var ownership = TestRunHeartRateDiagnosticProviderOwnership()
        ownership.bind(attemptB)

        XCTAssertFalse(ownership.release(attemptA))
        XCTAssertEqual(ownership.currentAttempt, attemptB)
        XCTAssertTrue(ownership.accepts(attemptB, provider: providerB))
    }

    private func observation(
        bpm: Int,
        measuredAt: Date,
        receivedAt: Date? = nil,
        callbackObservedAt: Date? = nil,
        providerNativeIdentity: String? = nil
    ) -> TestRunHeartRateDiagnosticService.Sample {
        TestRunHeartRateDiagnosticService.Sample(
            qualificationObservation: NativeHeartRatePreflightEngine.Observation(
                source: .nativeHealthKit,
                beatsPerMinute: bpm,
                measuredAt: measuredAt,
                receivedAt: receivedAt ?? measuredAt
            ),
            sourceCallbackObservedAt: callbackObservedAt,
            providerNativeIdentity: providerNativeIdentity
        )
    }
}

private final class FakeDiagnosticProvider {}
