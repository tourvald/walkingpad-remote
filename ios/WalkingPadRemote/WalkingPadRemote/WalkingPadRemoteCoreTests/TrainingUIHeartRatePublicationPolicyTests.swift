import XCTest
@testable import WalkingPadCoreLogic

final class TrainingUIHeartRatePublicationPolicyTests: XCTestCase {
    func testUnchangedVisibleHeartRateKeepsSameTrainingSnapshot() {
        let current = TrainingUIHeartRatePublicationPolicy.snapshot(
            isNativeHeartRateCurrent: true,
            isHeartRateStreamActive: true,
            heartRateBPM: 130
        )

        XCTAssertEqual(
            current,
            TrainingUIHeartRatePublicationPolicy.snapshot(
                isNativeHeartRateCurrent: true,
                isHeartRateStreamActive: true,
                heartRateBPM: 130
            )
        )
    }

    func testVisibleHeartRateChangeIsAvailableImmediately() {
        let updated = TrainingUIHeartRatePublicationPolicy.snapshot(
            isNativeHeartRateCurrent: true,
            isHeartRateStreamActive: true,
            heartRateBPM: 131
        )

        XCTAssertEqual(updated.currentHeartRateBPM, 131)
        XCTAssertTrue(updated.isFresh)
        XCTAssertEqual(updated.sourceLabel, "HealthKit")
    }

    func testFreshnessLossAndRestorationAreImmediateAndFailSafe() {
        let stale = TrainingUIHeartRatePublicationPolicy.snapshot(
            isNativeHeartRateCurrent: false,
            isHeartRateStreamActive: false,
            heartRateBPM: 130
        )
        XCTAssertFalse(stale.isFresh)
        XCTAssertNil(stale.currentHeartRateBPM)
        XCTAssertNil(stale.sourceLabel)

        let restored = TrainingUIHeartRatePublicationPolicy.snapshot(
            isNativeHeartRateCurrent: true,
            isHeartRateStreamActive: true,
            heartRateBPM: 130
        )
        XCTAssertTrue(restored.isFresh)
        XCTAssertEqual(restored.currentHeartRateBPM, 130)
        XCTAssertEqual(restored.sourceLabel, "HealthKit")
    }

    func testInvalidHeartRateNeverBecomesCurrentTrainingState() {
        let snapshot = TrainingUIHeartRatePublicationPolicy.snapshot(
            isNativeHeartRateCurrent: true,
            isHeartRateStreamActive: true,
            heartRateBPM: 0
        )

        XCTAssertTrue(snapshot.isFresh)
        XCTAssertNil(snapshot.currentHeartRateBPM)
        XCTAssertNil(snapshot.sourceLabel)
    }
}
