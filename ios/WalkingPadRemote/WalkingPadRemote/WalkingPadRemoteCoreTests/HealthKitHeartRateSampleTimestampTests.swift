import XCTest
@testable import WalkingPadCoreLogic

final class HealthKitHeartRateSampleTimestampTests: XCTestCase {
    func testResolveUsesMostRecentSampleIntervalEnd() {
        let start = Date(timeIntervalSince1970: 1_000)
        let interval = DateInterval(start: start, duration: 2.5)

        XCTAssertEqual(
            HealthKitHeartRateSampleTimestamp.resolve(from: interval),
            interval.end
        )
    }

    func testResolveReturnsNilWithoutSampleInterval() {
        XCTAssertNil(HealthKitHeartRateSampleTimestamp.resolve(from: nil))
    }
}
