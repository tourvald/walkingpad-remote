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
            observation(bpm: 128, measuredAt: startedAt.addingTimeInterval(1)),
            expectedRunID: runID,
            now: startedAt.addingTimeInterval(2),
            freshnessLimit: 7
        )

        let current = service.snapshot(
            now: startedAt.addingTimeInterval(2),
            freshnessLimit: 7
        )
        XCTAssertEqual(current.receivedSampleCount, 1)
        XCTAssertEqual(current.qualifyingSampleCount, 1)
        XCTAssertEqual(current.rejectedSampleCount, 0)
        XCTAssertEqual(current.latestSource, "native_healthkit")
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

    private func observation(
        bpm: Int,
        measuredAt: Date,
        receivedAt: Date? = nil
    ) -> NativeHeartRatePreflightEngine.Observation {
        NativeHeartRatePreflightEngine.Observation(
            source: .nativeHealthKit,
            beatsPerMinute: bpm,
            measuredAt: measuredAt,
            receivedAt: receivedAt ?? measuredAt
        )
    }
}
