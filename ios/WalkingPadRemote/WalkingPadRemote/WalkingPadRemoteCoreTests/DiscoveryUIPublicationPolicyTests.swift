import XCTest
@testable import WalkingPadCoreLogic

final class DiscoveryUIPublicationPolicyTests: XCTestCase {
    func testSuppressesDuplicateAndSmallRSSIOnlyChanges() {
        XCTAssertFalse(DiscoveryUIPublicationPolicy.shouldPublish(
            currentName: "WalkingPad",
            currentRSSI: -50,
            currentIsKnown: false,
            nextName: "WalkingPad",
            nextRSSI: -50,
            nextIsKnown: false
        ))
        XCTAssertFalse(DiscoveryUIPublicationPolicy.shouldPublish(
            currentName: "WalkingPad",
            currentRSSI: -50,
            currentIsKnown: false,
            nextName: "WalkingPad",
            nextRSSI: -52,
            nextIsKnown: false
        ))
    }

    func testPublishesAccumulatedRSSIAndIdentityFactChanges() {
        XCTAssertTrue(DiscoveryUIPublicationPolicy.shouldPublish(
            currentName: "WalkingPad",
            currentRSSI: -50,
            currentIsKnown: false,
            nextName: "WalkingPad",
            nextRSSI: -53,
            nextIsKnown: false
        ))
        XCTAssertTrue(DiscoveryUIPublicationPolicy.shouldPublish(
            currentName: "",
            currentRSSI: -50,
            currentIsKnown: false,
            nextName: "WalkingPad",
            nextRSSI: -50,
            nextIsKnown: false
        ))
        XCTAssertTrue(DiscoveryUIPublicationPolicy.shouldPublish(
            currentName: "WalkingPad",
            currentRSSI: -50,
            currentIsKnown: false,
            nextName: "WalkingPad",
            nextRSSI: -50,
            nextIsKnown: true
        ))
    }
}
