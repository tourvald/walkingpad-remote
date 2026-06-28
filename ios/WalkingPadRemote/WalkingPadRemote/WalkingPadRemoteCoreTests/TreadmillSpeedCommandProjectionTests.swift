import XCTest
@testable import WalkingPadCoreLogic

final class TreadmillSpeedCommandProjectionTests: XCTestCase {
    func testMetricProjectionKeepsPhysicalKmhAsNativeCommand() {
        let projection = TreadmillSpeedCommandProjection.project(
            requestedPhysicalSpeedKmh: 5.0,
            nativeUnits: .metric,
            previousRawTenths: 49
        )

        XCTAssertEqual(projection.nativeUnits, .metric)
        XCTAssertEqual(projection.requestedPhysicalSpeedKmh, 5.0, accuracy: 0.0001)
        XCTAssertEqual(projection.cappedPhysicalSpeedKmh, 5.0, accuracy: 0.0001)
        XCTAssertEqual(projection.commandNativeSpeed, 5.0, accuracy: 0.0001)
        XCTAssertEqual(projection.commandRawTenths, 50)
        XCTAssertEqual(projection.commandPhysicalSpeedKmhEstimate, 5.0, accuracy: 0.0001)
        XCTAssertEqual(projection.requestedPhysicalDeltaKmh ?? .nan, 0.1, accuracy: 0.0001)
        XCTAssertEqual(projection.commandPhysicalDeltaKmhEstimate ?? .nan, 0.1, accuracy: 0.0001)
        XCTAssertTrue(projection.shouldSendCommand)
    }

    func testConfirmedImperialProjectionConvertsPhysicalKmhToNativeMphRawTenths() {
        let projection = TreadmillSpeedCommandProjection.project(
            requestedPhysicalSpeedKmh: 5.0,
            nativeUnits: .imperial,
            previousRawTenths: 30
        )

        XCTAssertEqual(projection.nativeUnits, .imperial)
        XCTAssertEqual(projection.requestedPhysicalSpeedKmh, 5.0, accuracy: 0.0001)
        XCTAssertEqual(projection.cappedPhysicalSpeedKmh, 5.0, accuracy: 0.0001)
        XCTAssertEqual(projection.commandRawTenths, 31)
        XCTAssertEqual(projection.commandNativeSpeed, 3.1, accuracy: 0.0001)
        XCTAssertEqual(projection.commandPhysicalSpeedKmhEstimate, 3.1 * 1.609344, accuracy: 0.0001)
        XCTAssertEqual(projection.requestedPhysicalDeltaKmh ?? .nan, 5.0 - (3.0 * 1.609344), accuracy: 0.0001)
        XCTAssertEqual(projection.commandPhysicalDeltaKmhEstimate ?? .nan, (3.1 - 3.0) * 1.609344, accuracy: 0.0001)
        XCTAssertTrue(projection.shouldSendCommand)
    }

    func testConfirmedImperialProjectionSkipsNoOpWhenRawTenthsDoesNotChange() {
        let projection = TreadmillSpeedCommandProjection.project(
            requestedPhysicalSpeedKmh: 5.05,
            nativeUnits: .imperial,
            previousRawTenths: 31
        )

        XCTAssertEqual(projection.commandRawTenths, 31)
        XCTAssertEqual(projection.commandNativeSpeed, 3.1, accuracy: 0.0001)
        XCTAssertEqual(projection.requestedPhysicalDeltaKmh ?? .nan, 5.05 - (3.1 * 1.609344), accuracy: 0.0001)
        XCTAssertEqual(projection.commandPhysicalDeltaKmhEstimate ?? .nan, 0.0, accuracy: 0.0001)
        XCTAssertFalse(projection.shouldSendCommand)
    }

    func testConfirmedImperialProjectionAppliesInitialPhysicalCap() {
        let projection = TreadmillSpeedCommandProjection.project(
            requestedPhysicalSpeedKmh: 10.0,
            nativeUnits: .imperial,
            previousRawTenths: 30
        )

        XCTAssertEqual(projection.requestedPhysicalSpeedKmh, 10.0, accuracy: 0.0001)
        XCTAssertEqual(projection.cappedPhysicalSpeedKmh, 6.0, accuracy: 0.0001)
        XCTAssertEqual(projection.commandRawTenths, 37)
        XCTAssertEqual(projection.commandNativeSpeed, 3.7, accuracy: 0.0001)
        XCTAssertEqual(projection.commandPhysicalSpeedKmhEstimate, 3.7 * 1.609344, accuracy: 0.0001)
        XCTAssertTrue(projection.shouldSendCommand)
    }

    func testConfirmedImperialEffectiveTargetIsCappedBeforeStateStorage() {
        XCTAssertEqual(
            TreadmillSpeedCommandProjection.cappedPhysicalTargetKmh(
                requestedPhysicalSpeedKmh: 6.1,
                nativeUnits: .imperial
            ),
            6.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            TreadmillSpeedCommandProjection.cappedPhysicalTargetKmh(
                requestedPhysicalSpeedKmh: 6.2,
                nativeUnits: .imperial
            ),
            6.0,
            accuracy: 0.0001
        )

        let projection = TreadmillSpeedCommandProjection.project(
            requestedPhysicalSpeedKmh: 6.2,
            nativeUnits: .imperial,
            previousRawTenths: 37
        )
        XCTAssertEqual(projection.cappedPhysicalSpeedKmh, 6.0, accuracy: 0.0001)
        XCTAssertEqual(projection.commandRawTenths, 37)
        XCTAssertFalse(projection.shouldSendCommand)
    }
}
