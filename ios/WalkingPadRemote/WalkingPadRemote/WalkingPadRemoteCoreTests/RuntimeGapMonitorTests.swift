import XCTest
@testable import WalkingPadCoreLogic

final class RuntimeGapMonitorTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    func testNilWhenNoPreviousTick() {
        XCTAssertNil(RuntimeGapMonitor.evaluate(
            lastTickAt: nil, now: base, expectedIntervalSeconds: 1, minReportableSeconds: 3
        ))
    }

    func testNilWithinNormalCadence() {
        let now = base.addingTimeInterval(1.2)
        XCTAssertNil(RuntimeGapMonitor.evaluate(
            lastTickAt: base, now: now, expectedIntervalSeconds: 1, minReportableSeconds: 3
        ))
    }

    func testReportsGapBeyondThreshold() {
        let now = base.addingTimeInterval(20)
        let gap = RuntimeGapMonitor.evaluate(
            lastTickAt: base, now: now, expectedIntervalSeconds: 1, minReportableSeconds: 3
        )
        XCTAssertEqual(gap, RuntimeGapMonitor.Gap(seconds: 20, expectedIntervalSeconds: 1))
    }

    func testThresholdIsInclusive() {
        let now = base.addingTimeInterval(3)
        XCTAssertNotNil(RuntimeGapMonitor.evaluate(
            lastTickAt: base, now: now, expectedIntervalSeconds: 1, minReportableSeconds: 3
        ))
    }

    func testNilWhenClockMovesBackward() {
        let now = base.addingTimeInterval(-5)
        XCTAssertNil(RuntimeGapMonitor.evaluate(
            lastTickAt: base, now: now, expectedIntervalSeconds: 1, minReportableSeconds: 3
        ))
    }
}
