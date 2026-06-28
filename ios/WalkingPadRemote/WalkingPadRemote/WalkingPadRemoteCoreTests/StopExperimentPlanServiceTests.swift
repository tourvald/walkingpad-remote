import XCTest
@testable import WalkingPadCoreLogic

final class StopExperimentPlanServiceTests: XCTestCase {
    func testVariantsExposeOnlyWhitelistedPackets() {
        XCTAssertEqual(
            StopExperimentPlanService.plan(for: .speedZeroOnly).packetHex,
            "F7 A2 01 00 A3 FD"
        )
        XCTAssertEqual(
            StopExperimentPlanService.plan(for: .toggleOnly).packetHex,
            "F7 A2 04 01 A7 FD"
        )
    }

    func testMovingLowFreshBaselineIsAllowed() {
        let error = StopExperimentPlanService.baselineError(
            sample: .init(parseOK: true, checksumOK: true, state: 1, speedRawTenths: 3, ageSeconds: 0.5)
        )

        XCTAssertNil(error)
    }

    func testStoppedBaselineIsRejected() {
        let error = StopExperimentPlanService.baselineError(
            sample: .init(parseOK: true, checksumOK: true, state: 1, speedRawTenths: 0, ageSeconds: 0.5)
        )

        XCTAssertEqual(error, .stoppedBaseline)
    }

    func testStaleBaselineIsRejected() {
        let error = StopExperimentPlanService.baselineError(
            sample: .init(parseOK: true, checksumOK: true, state: 1, speedRawTenths: 3, ageSeconds: 3.0)
        )

        XCTAssertEqual(error, .staleBaseline)
    }

    func testHighSpeedBaselineIsRejected() {
        let error = StopExperimentPlanService.baselineError(
            sample: .init(parseOK: true, checksumOK: true, state: 1, speedRawTenths: 41, ageSeconds: 0.5)
        )

        XCTAssertEqual(error, .highSpeedBaseline)
    }

    func testOutcomeConfirmsFreshStoppedState() {
        let outcome = StopExperimentPlanService.classifyOutcome(
            baselineSpeedRawTenths: 3,
            latest: .init(parseOK: true, checksumOK: true, state: 0, speedRawTenths: 0, ageSeconds: 0.5),
            maxAfterCommandSpeedRawTenths: 3
        )

        XCTAssertEqual(outcome, .stopConfirmed)
    }

    func testOutcomeDetectsDeceleratedButNotZero() {
        let outcome = StopExperimentPlanService.classifyOutcome(
            baselineSpeedRawTenths: 8,
            latest: .init(parseOK: true, checksumOK: true, state: 1, speedRawTenths: 3, ageSeconds: 0.5),
            maxAfterCommandSpeedRawTenths: 8
        )

        XCTAssertEqual(outcome, .deceleratedButNotZero)
    }

    func testOutcomeDetectsAcceleration() {
        let outcome = StopExperimentPlanService.classifyOutcome(
            baselineSpeedRawTenths: 3,
            latest: .init(parseOK: true, checksumOK: true, state: 1, speedRawTenths: 6, ageSeconds: 0.5),
            maxAfterCommandSpeedRawTenths: 6
        )

        XCTAssertEqual(outcome, .commandCausedAcceleration)
    }

    func testOutcomeRequiresFreshFe01() {
        let outcome = StopExperimentPlanService.classifyOutcome(
            baselineSpeedRawTenths: 3,
            latest: .init(parseOK: true, checksumOK: true, state: 0, speedRawTenths: 0, ageSeconds: 3.0),
            maxAfterCommandSpeedRawTenths: 3
        )

        XCTAssertEqual(outcome, .noFreshFE01)
    }
}
