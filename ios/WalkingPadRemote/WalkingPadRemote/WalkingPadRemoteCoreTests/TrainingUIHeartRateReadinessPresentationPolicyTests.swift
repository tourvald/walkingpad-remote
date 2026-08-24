import XCTest
@testable import WalkingPadCoreLogic

final class TrainingUIHeartRateReadinessPresentationPolicyTests: XCTestCase {
    func testFreshHeartRateIsReadyBeforePreflight() {
        let presentation = TrainingUIHeartRateReadinessPresentationPolicy.presentation(
            isFresh: true,
            currentHeartRateBPM: 77,
            sourceLabel: "HealthKit",
            isPreparing: false
        )

        XCTAssertEqual(presentation.value, "77 bpm")
        XCTAssertEqual(presentation.sourceLabel, "HealthKit")
        XCTAssertTrue(presentation.isReady)
    }

    func testFreshHeartRateWaitsDuringPreflightWithoutSourceClaim() {
        let presentation = TrainingUIHeartRateReadinessPresentationPolicy.presentation(
            isFresh: true,
            currentHeartRateBPM: 77,
            sourceLabel: "HealthKit",
            isPreparing: true
        )

        XCTAssertEqual(presentation.value, "Ожидание")
        XCTAssertNil(presentation.sourceLabel)
        XCTAssertFalse(presentation.isReady)
    }

    func testUnavailableHeartRateUsesSameWaitingPresentationDuringPreflight() {
        let presentation = TrainingUIHeartRateReadinessPresentationPolicy.presentation(
            isFresh: false,
            currentHeartRateBPM: nil,
            sourceLabel: nil,
            isPreparing: true
        )

        XCTAssertEqual(
            presentation,
            TrainingUIHeartRateReadinessPresentation(
                value: "Ожидание",
                sourceLabel: nil,
                isReady: false
            )
        )
    }

    func testUnavailableHeartRateBeforePreflightKeepsExistingPresentation() {
        let presentation = TrainingUIHeartRateReadinessPresentationPolicy.presentation(
            isFresh: false,
            currentHeartRateBPM: nil,
            sourceLabel: nil,
            isPreparing: false
        )

        XCTAssertEqual(presentation.value, "При старте")
        XCTAssertNil(presentation.sourceLabel)
        XCTAssertFalse(presentation.isReady)
    }
}
