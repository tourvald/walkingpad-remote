import XCTest
@testable import WalkingPadCoreLogic

final class HRTrendMathTests: XCTestCase {
    func testEmaSmoothFirstSampleReturnsRaw() {
        XCTAssertEqual(HRDomainService.emaSmooth(previousEma: nil, raw: 120, alpha: 0.25), 120, accuracy: 0.0001)
    }

    func testEmaSmoothBlendsTowardRaw() {
        // 100 + 0.25 * (140 - 100) = 110
        XCTAssertEqual(HRDomainService.emaSmooth(previousEma: 100, raw: 140, alpha: 0.25), 110, accuracy: 0.0001)
    }

    private let rising: [(time: TimeInterval, value: Double)] = [
        (0, 100), (1, 101), (2, 102), (3, 103), (4, 104)
    ]

    func testTrendSlopePerfectRisingLine() {
        let slope = HRDomainService.trendSlopeBpmPerSecond(
            samples: rising, minSamples: 3, minWindowSeconds: 2, clampMaxBpmPerSecond: 2.0
        )
        XCTAssertEqual(slope ?? .nan, 1.0, accuracy: 0.0001)
    }

    func testTrendSlopeClampsToMax() {
        let slope = HRDomainService.trendSlopeBpmPerSecond(
            samples: rising, minSamples: 3, minWindowSeconds: 2, clampMaxBpmPerSecond: 0.6
        )
        XCTAssertEqual(slope ?? .nan, 0.6, accuracy: 0.0001)
    }

    func testTrendSlopeNegativeForFallingHr() {
        let falling: [(time: TimeInterval, value: Double)] = [(0, 150), (1, 149), (2, 148), (3, 147)]
        let slope = HRDomainService.trendSlopeBpmPerSecond(
            samples: falling, minSamples: 3, minWindowSeconds: 2, clampMaxBpmPerSecond: 2.0
        )
        XCTAssertEqual(slope ?? .nan, -1.0, accuracy: 0.0001)
    }

    func testTrendSlopeFlatIsZero() {
        let flat: [(time: TimeInterval, value: Double)] = [(0, 130), (1, 130), (2, 130), (3, 130)]
        let slope = HRDomainService.trendSlopeBpmPerSecond(
            samples: flat, minSamples: 3, minWindowSeconds: 2, clampMaxBpmPerSecond: 2.0
        )
        XCTAssertEqual(slope ?? .nan, 0.0, accuracy: 0.0001)
    }

    func testTrendSlopeNilWhenTooFewSamples() {
        XCTAssertNil(HRDomainService.trendSlopeBpmPerSecond(
            samples: rising, minSamples: 10, minWindowSeconds: 2, clampMaxBpmPerSecond: 2.0
        ))
    }

    func testTrendSlopeNilWhenWindowTooShort() {
        XCTAssertNil(HRDomainService.trendSlopeBpmPerSecond(
            samples: rising, minSamples: 3, minWindowSeconds: 10, clampMaxBpmPerSecond: 2.0
        ))
    }
}
