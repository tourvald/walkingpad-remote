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

    func testImperialDiagnosticPlanIsFixedNoLoadProfile() {
        let configuration = TreadmillTestRunPlanService.imperialNoLoadDiagnosticConfiguration
        let start = TreadmillTestRunPlanService.snapshot(
            elapsedSeconds: 0,
            bounds: bounds,
            configuration: configuration
        )
        let mid = TreadmillTestRunPlanService.snapshot(
            elapsedSeconds: 30,
            bounds: bounds,
            configuration: configuration
        )
        let finished = TreadmillTestRunPlanService.snapshot(
            elapsedSeconds: 60,
            bounds: bounds,
            configuration: configuration
        )

        XCTAssertEqual(configuration.durationSeconds, 60)
        XCTAssertEqual(configuration.profileID, "imperial_units_discriminator_60s")
        XCTAssertTrue(configuration.requiresNoLoadConfirmation)
        XCTAssertEqual(configuration.nativeUnits, .imperial)
        XCTAssertEqual(start.targetSpeedRawTenths, 30)
        XCTAssertEqual(mid.targetSpeedRawTenths, 30)
        XCTAssertEqual(finished.targetSpeedRawTenths, 0)
        XCTAssertEqual(start.targetNativeSpeed.displayText, "3.0 mph")
        XCTAssertEqual(start.targetNativeSpeed.diagnosticText, "native 3.0 / controller imperial")
    }

    func testDefaultMetricPlanKeepsLegacyKmhProfile() {
        let configuration = TreadmillTestRunPlanService.defaultConfiguration
        let start = TreadmillTestRunPlanService.snapshot(
            elapsedSeconds: 0,
            bounds: bounds,
            configuration: configuration
        )

        XCTAssertEqual(configuration.profileID, "metric_ramp_3m")
        XCTAssertFalse(configuration.requiresNoLoadConfirmation)
        XCTAssertEqual(configuration.nativeUnits, .metric)
        XCTAssertEqual(start.targetSpeedRawTenths, 30)
        XCTAssertEqual(start.targetNativeSpeed.displayText, "3.0 km/h")
    }

    func testDiagnosticStartSendsStartWhenFreshReportIsMissingDespiteStalePreviousTarget() {
        let decision = TreadmillTestRunPlanService.shouldSendWalkingPadDiagnosticStart(
            hasFreshReport: false,
            reportedState: 1,
            reportedSpeedRawTenths: 30
        )

        XCTAssertTrue(decision)
    }

    func testDiagnosticStartSkipsStartWhenFreshReportShowsMovingBelt() {
        let decision = TreadmillTestRunPlanService.shouldSendWalkingPadDiagnosticStart(
            hasFreshReport: true,
            reportedState: 1,
            reportedSpeedRawTenths: 8
        )

        XCTAssertFalse(decision)
    }
}
