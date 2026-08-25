import Foundation
import XCTest
@testable import WalkingPadCoreLogic

final class TrainingUIHeartRatePresentationHoldPolicyTests: XCTestCase {
    private let acceptedAt = Date(timeIntervalSince1970: 1_000)

    func testFreshSampleIsPresentedImmediatelyWithoutHold() {
        let presentation = resolve(
            snapshot: snapshot(isFresh: true, currentBPM: 131),
            ageSeconds: 0
        )

        XCTAssertEqual(presentation.currentHeartRateBPM, 131)
        XCTAssertEqual(presentation.sourceLabel, "HealthKit")
        XCTAssertTrue(presentation.isReady)
        XCTAssertFalse(presentation.isHeld)
    }

    func testNormalEightSecondGapKeepsAcceptedPresentationStable() {
        let presentation = resolve(
            snapshot: snapshot(isFresh: false, currentBPM: nil),
            ageSeconds: 8
        )

        XCTAssertEqual(presentation.currentHeartRateBPM, 130)
        XCTAssertEqual(presentation.sourceLabel, "HealthKit")
        XCTAssertTrue(presentation.isReady)
        XCTAssertTrue(presentation.isHeld)
    }

    func testNewSampleDuringHoldReplacesPresentedValueImmediately() {
        let stale = resolve(
            snapshot: snapshot(isFresh: false, currentBPM: nil),
            ageSeconds: 8
        )
        let refreshed = resolve(
            snapshot: snapshot(isFresh: true, currentBPM: 134),
            ageSeconds: 8
        )

        XCTAssertEqual(stale.currentHeartRateBPM, 130)
        XCTAssertEqual(refreshed.currentHeartRateBPM, 134)
        XCTAssertFalse(refreshed.isHeld)
    }

    func testNewAcceptedTimestampRestartsHoldWindow() {
        let staleSnapshot = snapshot(isFresh: false, currentBPM: nil)
        let now = acceptedAt.addingTimeInterval(17)
        let expired = TrainingUIHeartRatePresentationHoldPolicy.presentation(
            factualSnapshot: staleSnapshot,
            lastAcceptedPresentation: acceptedPresentation(at: acceptedAt),
            now: now
        )
        let restarted = TrainingUIHeartRatePresentationHoldPolicy.presentation(
            factualSnapshot: staleSnapshot,
            lastAcceptedPresentation: acceptedPresentation(
                bpm: 134,
                at: acceptedAt.addingTimeInterval(8)
            ),
            now: now
        )

        XCTAssertFalse(expired.isReady)
        XCTAssertEqual(restarted.currentHeartRateBPM, 134)
        XCTAssertTrue(restarted.isHeld)
    }

    func testHeldPresentationDoesNotInventUnknownSource() {
        let presentation = TrainingUIHeartRatePresentationHoldPolicy.presentation(
            factualSnapshot: snapshot(isFresh: false, currentBPM: nil),
            lastAcceptedPresentation: acceptedPresentation(
                at: acceptedAt,
                sourceLabel: nil
            ),
            now: acceptedAt.addingTimeInterval(8)
        )

        XCTAssertTrue(presentation.isReady)
        XCTAssertNil(presentation.sourceLabel)
    }

    func testGapJustBelowTenSecondsStillHolds() {
        let presentation = resolve(
            snapshot: snapshot(isFresh: false, currentBPM: nil),
            ageSeconds: 9.999
        )

        XCTAssertTrue(presentation.isReady)
        XCTAssertTrue(presentation.isHeld)
    }

    func testGapAtTenSecondsIsUnavailable() {
        let presentation = resolve(
            snapshot: snapshot(isFresh: false, currentBPM: nil),
            ageSeconds: 10
        )

        XCTAssertNil(presentation.currentHeartRateBPM)
        XCTAssertNil(presentation.sourceLabel)
        XCTAssertFalse(presentation.isReady)
        XCTAssertFalse(presentation.isHeld)
    }

    func testNoPreviouslyAcceptedSampleCannotBecomeReady() {
        let presentation = TrainingUIHeartRatePresentationHoldPolicy.presentation(
            factualSnapshot: TrainingUIHeartRateSnapshot(
                isFresh: false,
                currentHeartRateBPM: nil,
                sourceLabel: nil
            ),
            lastAcceptedPresentation: nil,
            now: acceptedAt.addingTimeInterval(5)
        )

        XCTAssertFalse(presentation.isReady)
        XCTAssertNil(presentation.currentHeartRateBPM)
    }

    func testFutureAcceptedTimestampFailsClosed() {
        let presentation = resolve(
            snapshot: snapshot(isFresh: false, currentBPM: nil),
            ageSeconds: -1
        )

        XCTAssertFalse(presentation.isReady)
        XCTAssertNil(presentation.currentHeartRateBPM)
    }

    private func resolve(
        snapshot: TrainingUIHeartRateSnapshot,
        ageSeconds: TimeInterval
    ) -> TrainingUIHeartRateActivePresentation {
        TrainingUIHeartRatePresentationHoldPolicy.presentation(
            factualSnapshot: snapshot,
            lastAcceptedPresentation: acceptedPresentation(at: acceptedAt),
            now: acceptedAt.addingTimeInterval(ageSeconds)
        )
    }

    private func acceptedPresentation(
        bpm: Int = 130,
        at date: Date,
        sourceLabel: String? = "HealthKit"
    ) -> TrainingUIHeartRateAcceptedPresentation {
        TrainingUIHeartRateAcceptedPresentation(
            heartRateBPM: bpm,
            acceptedAt: date,
            sourceLabel: sourceLabel
        )
    }

    private func snapshot(
        isFresh: Bool,
        currentBPM: Int?
    ) -> TrainingUIHeartRateSnapshot {
        TrainingUIHeartRateSnapshot(
            isFresh: isFresh,
            currentHeartRateBPM: currentBPM,
            sourceLabel: currentBPM == nil ? nil : "HealthKit"
        )
    }
}
