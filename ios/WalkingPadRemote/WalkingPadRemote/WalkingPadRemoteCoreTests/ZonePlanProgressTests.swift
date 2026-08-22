import Foundation
import XCTest
@testable import WalkingPadCoreLogic

final class ZonePlanProgressTests: XCTestCase {
    func testFiftyNineSecondsContributeWithoutTruncation() {
        let progress = ZonePlanProgress.rawProgress(
            actualSeconds: 59,
            planSeconds: 60
        )

        XCTAssertEqual(progress ?? -1, 59.0 / 60.0, accuracy: 0.000_001)
        XCTAssertEqual(ZonePlanProgress.durationText(seconds: 59), "0:59")
    }

    func testNinetySecondsContributeWithoutTruncation() {
        let progress = ZonePlanProgress.rawProgress(
            actualSeconds: 90,
            planSeconds: 120
        )

        XCTAssertEqual(progress ?? -1, 0.75, accuracy: 0.000_001)
        XCTAssertEqual(ZonePlanProgress.durationText(seconds: 90), "1:30")
    }

    func testCompletionUsesExactSecondBoundary() {
        let planSeconds = ZonePlanProgress.planSeconds(
            monthlyPlanMinutes: 90,
            isWeekly: false
        )

        XCTAssertFalse(
            ZonePlanProgress.isAchieved(
                actualSeconds: 89 * 60 + 59,
                planSeconds: planSeconds
            )
        )
        XCTAssertTrue(
            ZonePlanProgress.isAchieved(
                actualSeconds: 90 * 60,
                planSeconds: planSeconds
            )
        )
    }

    func testNinetyMinuteMonthProducesExactWeeklyTarget() {
        let sixtyMinutePlanSeconds = ZonePlanProgress.planSeconds(
            monthlyPlanMinutes: 60,
            isWeekly: true
        )
        let planSeconds = ZonePlanProgress.planSeconds(
            monthlyPlanMinutes: 90,
            isWeekly: true
        )

        XCTAssertEqual(sixtyMinutePlanSeconds, 15 * 60)
        XCTAssertEqual(
            ZonePlanProgress.durationText(seconds: sixtyMinutePlanSeconds),
            "15:00"
        )
        XCTAssertEqual(planSeconds, 22 * 60 + 30)
        XCTAssertEqual(ZonePlanProgress.durationText(seconds: planSeconds), "22:30")
    }

    func testHundredOneMinuteMonthProducesExactWeeklyTarget() {
        let planSeconds = ZonePlanProgress.planSeconds(
            monthlyPlanMinutes: 101,
            isWeekly: true
        )

        XCTAssertEqual(planSeconds, 25 * 60 + 15)
        XCTAssertEqual(ZonePlanProgress.durationText(seconds: planSeconds), "25:15")
    }

    func testUnavailableExposureRemainsUnavailable() {
        let progress = ZonePlanProgress.rawProgress(
            actualSeconds: nil,
            planSeconds: 60
        )

        XCTAssertNil(progress)
        XCTAssertNil(ZonePlanProgress.displayedProgress(progress))
        XCTAssertFalse(ZonePlanProgress.isAchieved(actualSeconds: nil, planSeconds: 60))
        XCTAssertEqual(ZonePlanProgress.durationText(seconds: nil), "—")
    }

    func testDisplayedProgressCapsWithoutChangingFactualSeconds() {
        let actualSeconds = 121.0
        let progress = ZonePlanProgress.rawProgress(
            actualSeconds: actualSeconds,
            planSeconds: 60
        )

        XCTAssertEqual(progress ?? -1, 121.0 / 60.0, accuracy: 0.000_001)
        XCTAssertEqual(ZonePlanProgress.displayedProgress(progress), 1.0)
        XCTAssertEqual(actualSeconds, 121)
        XCTAssertTrue(
            ZonePlanProgress.isAchieved(
                actualSeconds: actualSeconds,
                planSeconds: 60
            )
        )
    }

    func testDurationFormattingBelowAndAboveOneHour() {
        XCTAssertEqual(ZonePlanProgress.durationText(seconds: 42 * 60 + 17), "42:17")
        XCTAssertEqual(
            ZonePlanProgress.durationText(seconds: 60 * 60 + 2 * 60 + 14),
            "1:02:14"
        )
        XCTAssertEqual(ZonePlanProgress.durationText(seconds: 90 * 60), "1:30:00")
    }

    func testStatisticsViewUsesFactualZoneSecondsWithoutMinuteRounding() throws {
        let packageDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let contentViewURL = packageDirectory
            .appendingPathComponent("WalkingPadRemote/ContentView.swift")
        let source = try String(contentsOf: contentViewURL, encoding: .utf8)

        XCTAssertTrue(source.contains("zoneSeconds: stats?.zoneSeconds"))
        XCTAssertTrue(source.contains("actualSeconds: seconds"))
        XCTAssertTrue(source.contains("ZonePlanProgress.planSeconds("))
        XCTAssertTrue(source.contains("monthlyPlanMinutes: monthPlan"))
        XCTAssertTrue(source.contains("isWeekly: scope == .week"))
        XCTAssertTrue(source.contains("ZonePlanProgress.rawProgress("))
        XCTAssertTrue(source.contains("ZonePlanProgress.isAchieved("))
        XCTAssertTrue(source.contains("ZonePlanProgress.displayedProgress(progress)"))
        XCTAssertTrue(source.contains("ZonePlanProgress.durationText(seconds: actualSeconds)"))
        XCTAssertFalse(source.contains("Int($0 / 60.0)"))
        XCTAssertFalse(source.contains("Int(round(Double(monthPlan) / 4.0))"))
    }
}
