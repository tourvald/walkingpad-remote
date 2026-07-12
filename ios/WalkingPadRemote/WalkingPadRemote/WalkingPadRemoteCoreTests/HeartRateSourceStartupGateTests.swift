import Foundation
import XCTest
@testable import WalkingPadCoreLogic

final class HeartRateSourceStartupGateTests: XCTestCase {
    func testWaitTimeoutDoesNotStartBeforeCollectionBegins() {
        var gate = HeartRateSourceStartupGate()
        gate.beginSourceStart()

        XCTAssertTrue(gate.isBeforeFirstSample)
        XCTAssertNil(gate.initialSampleWaitSeconds(at: Date(timeIntervalSince1970: 120)))
        XCTAssertFalse(gate.markFirstSampleAccepted())
        XCTAssertTrue(gate.isBeforeFirstSample)
    }

    func testCollectionStartBeginsWaitAndFirstSampleStartsBeltOnlyOnce() {
        var gate = HeartRateSourceStartupGate()
        let collectionStartedAt = Date(timeIntervalSince1970: 100)
        gate.beginSourceStart()
        gate.collectionDidStart(at: collectionStartedAt)

        XCTAssertEqual(
            gate.initialSampleWaitSeconds(at: collectionStartedAt.addingTimeInterval(12.8)),
            12
        )
        XCTAssertTrue(gate.markFirstSampleAccepted())
        XCTAssertFalse(gate.isBeforeFirstSample)
        XCTAssertFalse(gate.markFirstSampleAccepted())
    }

    func testLateCollectionCallbackAfterResetDoesNotRearmGate() {
        var gate = HeartRateSourceStartupGate()
        gate.beginSourceStart()
        gate.reset()
        gate.collectionDidStart(at: Date(timeIntervalSince1970: 100))

        XCTAssertFalse(gate.isBeforeFirstSample)
        XCTAssertNil(gate.initialSampleWaitSeconds(at: Date(timeIntervalSince1970: 120)))
    }
}
