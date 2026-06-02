import XCTest
@testable import WalkingPadCoreLogic

final class TreadmillTestRunPlanServiceTests: XCTestCase {
    private let bounds = TreadmillSpeedBoundsService.Bounds(
        min: 0.5,
        max: 12.0,
        increment: 0.1
    )

    func testDefaultPlanRampsUpThenDownAndFinishesAtStopTarget() {
        let start = TreadmillTestRunPlanService.snapshot(elapsedSeconds: 0, bounds: bounds)
        let rampUp = TreadmillTestRunPlanService.snapshot(elapsedSeconds: 45, bounds: bounds)
        let peak = TreadmillTestRunPlanService.snapshot(elapsedSeconds: 90, bounds: bounds)
        let rampDown = TreadmillTestRunPlanService.snapshot(elapsedSeconds: 135, bounds: bounds)
        let settle = TreadmillTestRunPlanService.snapshot(elapsedSeconds: 170, bounds: bounds)
        let finished = TreadmillTestRunPlanService.snapshot(elapsedSeconds: 180, bounds: bounds)

        XCTAssertEqual(start.phase, .warmup)
        XCTAssertEqual(start.targetSpeedKmh, 3.0)
        XCTAssertEqual(rampUp.phase, .rampUp)
        XCTAssertEqual(rampUp.targetSpeedKmh, 5.0)
        XCTAssertEqual(peak.phase, .rampDown)
        XCTAssertEqual(peak.targetSpeedKmh, 8.0)
        XCTAssertEqual(rampDown.phase, .rampDown)
        XCTAssertEqual(rampDown.targetSpeedKmh, 5.0)
        XCTAssertEqual(settle.phase, .settle)
        XCTAssertEqual(settle.targetSpeedKmh, 3.0)
        XCTAssertEqual(finished.phase, .finished)
        XCTAssertEqual(finished.targetSpeedKmh, 0.0)
    }

    func testPlanHonorsDeviceSpeedBounds() {
        let lowMaxBounds = TreadmillSpeedBoundsService.Bounds(
            min: 2.0,
            max: 6.0,
            increment: 0.5
        )

        let peak = TreadmillTestRunPlanService.snapshot(elapsedSeconds: 90, bounds: lowMaxBounds)
        let base = TreadmillTestRunPlanService.snapshot(elapsedSeconds: 170, bounds: lowMaxBounds)

        XCTAssertEqual(peak.targetSpeedKmh, 6.0)
        XCTAssertEqual(base.targetSpeedKmh, 3.0)
    }

    func testCommandCadenceUsesConfiguredInterval() {
        let commandTick = TreadmillTestRunPlanService.snapshot(elapsedSeconds: 40, bounds: bounds)
        let nonCommandTick = TreadmillTestRunPlanService.snapshot(elapsedSeconds: 41, bounds: bounds)

        XCTAssertTrue(commandTick.shouldSendSpeedCommand)
        XCTAssertFalse(nonCommandTick.shouldSendSpeedCommand)
    }
}
