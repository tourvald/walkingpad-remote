import XCTest
@testable import WalkingPadCoreLogic

final class NativeSpeedValueTests: XCTestCase {
    func testFormatsMetricRawTenthsAsKmh() {
        let value = NativeSpeedValue(rawTenths: 30, units: .metric)

        XCTAssertEqual(value.nativeSpeed, 3.0)
        XCTAssertEqual(value.displayUnitLabel, "km/h")
        XCTAssertEqual(value.displayText, "3.0 km/h")
    }

    func testFormatsImperialRawTenthsAsControllerImperialWithoutPhysicalClaim() {
        let value = NativeSpeedValue(rawTenths: 30, units: .imperial)

        XCTAssertEqual(value.nativeSpeed, 3.0)
        XCTAssertEqual(value.displayUnitLabel, "mph")
        XCTAssertEqual(value.displayText, "3.0 mph")
        XCTAssertEqual(value.diagnosticText, "native 3.0 / controller imperial")
    }

    func testFormatsUnknownUnitsAsRawOnly() {
        let value = NativeSpeedValue(rawTenths: 30, units: .unknown)

        XCTAssertEqual(value.nativeSpeed, 3.0)
        XCTAssertEqual(value.displayUnitLabel, "native")
        XCTAssertEqual(value.displayText, "native 3.0")
        XCTAssertEqual(value.diagnosticText, "native 3.0 / controller unknown")
    }

    func testConfirmedImperialCurrentDisplayUsesNativeMphAndPhysicalEstimate() {
        let display = TreadmillSpeedDisplay.current(
            reportedRawTenths: 36,
            fallbackMetricKmh: 3.6,
            nativeUnits: .imperial
        )

        XCTAssertEqual(display.value, 3.6)
        XCTAssertEqual(display.unitLabel, "mph")
        XCTAssertEqual(display.semantics, .nativeMph)
        XCTAssertEqual(display.physicalEstimateLabel, "physical km/h estimate")
        XCTAssertEqual(display.physicalKmhEstimate ?? 0, 5.7936384, accuracy: 0.000001)
    }

    func testConfirmedImperialAverageDisplayLabelsLegacyAverageAsMph() {
        let display = TreadmillSpeedDisplay.average(
            legacyAverageSpeed: 3.2,
            nativeUnits: .imperial
        )

        XCTAssertEqual(display.value, 3.2)
        XCTAssertEqual(display.unitLabel, "mph")
        XCTAssertEqual(display.semantics, .nativeMph)
        XCTAssertEqual(display.physicalKmhEstimate ?? 0, 5.1499008, accuracy: 0.000001)
    }

    func testMetricDisplayPreservesKmhSemantics() {
        let current = TreadmillSpeedDisplay.current(
            reportedRawTenths: 36,
            fallbackMetricKmh: 3.5,
            nativeUnits: .metric
        )
        let average = TreadmillSpeedDisplay.average(
            legacyAverageSpeed: 4.1,
            nativeUnits: .metric
        )

        XCTAssertEqual(current.value, 3.5)
        XCTAssertEqual(current.unitLabel, "km/h")
        XCTAssertEqual(current.semantics, .physicalKmh)
        XCTAssertNil(current.physicalKmhEstimate)
        XCTAssertEqual(average.value, 4.1)
        XCTAssertEqual(average.unitLabel, "km/h")
        XCTAssertEqual(average.semantics, .physicalKmh)
        XCTAssertNil(average.physicalKmhEstimate)
    }
}
