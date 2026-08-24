import XCTest
@testable import WalkingPadCoreLogic

final class TrainingUITreadmillPublicationPolicyTests: XCTestCase {
    func testUnchangedVisibleSpeedDoesNotPublishNonRenderedTreadmillFacts() {
        XCTAssertFalse(
            TrainingUITreadmillPublicationPolicy.shouldPublish(
                currentVisibleSpeedKmh: 5.0,
                appReportedSpeedKmh: 5.0,
                rawReportedSpeedKmh: 5.0
            )
        )
    }

    func testActualVisibleSpeedChangePublishesImmediately() {
        XCTAssertTrue(
            TrainingUITreadmillPublicationPolicy.shouldPublish(
                currentVisibleSpeedKmh: 5.0,
                appReportedSpeedKmh: 5.1,
                rawReportedSpeedKmh: 5.1
            )
        )
        XCTAssertEqual(
            TrainingUITreadmillPublicationPolicy.visibleSpeedKmh(
                appReportedSpeedKmh: 5.1,
                rawReportedSpeedKmh: 5.1
            ),
            5.1
        )
    }

    func testAppReportedSpeedKeepsExistingFactualPriority() {
        XCTAssertEqual(
            TrainingUITreadmillPublicationPolicy.visibleSpeedKmh(
                appReportedSpeedKmh: 4.8,
                rawReportedSpeedKmh: 5.0
            ),
            4.8
        )
        XCTAssertEqual(
            TrainingUITreadmillPublicationPolicy.visibleSpeedKmh(
                appReportedSpeedKmh: 0,
                rawReportedSpeedKmh: 5.0
            ),
            5.0
        )
        XCTAssertNil(
            TrainingUITreadmillPublicationPolicy.visibleSpeedKmh(
                appReportedSpeedKmh: 0,
                rawReportedSpeedKmh: 0
            )
        )
    }
}
