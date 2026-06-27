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
}
