import XCTest
@testable import WalkingPadCoreLogic

final class TrainingUIHeartRateReadinessPresentationPolicyTests: XCTestCase {
    func testFreshHeartRateWithKnownSourceIsOneLineReadyBeforePreflight() {
        let presentation = TrainingUIHeartRateReadinessPresentationPolicy.presentation(
            isFresh: true,
            sourceLabel: "HealthKit",
            isPreparing: false
        )

        XCTAssertEqual(presentation.value, "HealthKit")
        XCTAssertNil(presentation.sourceLabel)
        XCTAssertTrue(presentation.isReady)
    }

    func testFreshHeartRateWithoutKnownSourceUsesTruthfulGenericReadyValue() {
        let presentation = TrainingUIHeartRateReadinessPresentationPolicy.presentation(
            isFresh: true,
            sourceLabel: nil,
            isPreparing: false
        )

        XCTAssertEqual(presentation.value, "Готов")
        XCTAssertNil(presentation.sourceLabel)
        XCTAssertTrue(presentation.isReady)
    }

    func testFreshHeartRateWaitsDuringPreflightWithoutSourceClaim() {
        let presentation = TrainingUIHeartRateReadinessPresentationPolicy.presentation(
            isFresh: true,
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
            sourceLabel: nil,
            isPreparing: false
        )

        XCTAssertEqual(presentation.value, "При старте")
        XCTAssertNil(presentation.sourceLabel)
        XCTAssertFalse(presentation.isReady)
    }
}
