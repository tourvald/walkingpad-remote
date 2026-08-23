import Foundation
@testable import WalkingPadCoreLogic
import XCTest

final class AutoConnectRetryPolicyTests: XCTestCase {
    func testExhaustedRoundRearmsFreshPreferredDiscoveryExactlyOnceAfterCooldown() {
        let preferredID = UUID()
        let fallbackID = UUID()
        let knownIDs: Set<UUID> = [preferredID, fallbackID]
        let startedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        var policy = AutoConnectRetryPolicy(cooldownSeconds: 3)

        policy.markFailed(preferredID, now: startedAt)
        policy.markFailed(fallbackID, now: startedAt)

        XCTAssertFalse(policy.rearmAfterFreshDiscovery(
            peripheralID: preferredID,
            knownPeripheralIDs: knownIDs,
            now: startedAt.addingTimeInterval(2.9)
        ))
        XCTAssertTrue(policy.rearmAfterFreshDiscovery(
            peripheralID: preferredID,
            knownPeripheralIDs: knownIDs,
            now: startedAt.addingTimeInterval(3)
        ))
        XCTAssertFalse(policy.rearmAfterFreshDiscovery(
            peripheralID: preferredID,
            knownPeripheralIDs: knownIDs,
            now: startedAt.addingTimeInterval(3)
        ))
        XCTAssertEqual(policy.failedPeripheralIDs, Set([fallbackID]))
    }

    func testFreshDiscoveryCannotInterruptCurrentFallbackRound() {
        let preferredID = UUID()
        let fallbackID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 2_000)
        var policy = AutoConnectRetryPolicy(cooldownSeconds: 0)

        policy.markFailed(preferredID, now: now)

        XCTAssertFalse(policy.rearmAfterFreshDiscovery(
            peripheralID: preferredID,
            knownPeripheralIDs: [preferredID, fallbackID],
            now: now
        ))
        XCTAssertEqual(policy.failedPeripheralIDs, Set([preferredID]))
    }
}
