import XCTest
@testable import WalkingPadCoreLogic

final class ProfileErasurePolicyTests: XCTestCase {
    func testConfirmedIdentityPreservesNewActiveProfileAndSoleDeletionIsIdempotent() throws {
        let a = UUID(), b = UUID(), replacement = UUID()
        let inactive = try XCTUnwrap(ProfileErasurePolicy.selection(afterDeleting: a, from: [a, b], activeID: b))
        XCTAssertEqual(inactive.retainedIDs, [b])
        XCTAssertEqual(inactive.activeID, b)
        XCTAssertNil(inactive.replacementID)
        let sole = try XCTUnwrap(ProfileErasurePolicy.selection(afterDeleting: a, from: [a], activeID: a, makeID: { replacement }))
        XCTAssertEqual(sole.retainedIDs, [replacement])
        XCTAssertEqual(sole.activeID, replacement)
        XCTAssertNil(ProfileErasurePolicy.selection(afterDeleting: a, from: sole.retainedIDs, activeID: replacement, makeID: { XCTFail("Duplicate replacement"); return UUID() }))
    }

    func testEveryRuntimeOwnerIndependentlyBlocksErasure() {
        for index in 0..<8 {
            var values = Array(repeating: false, count: 8)
            values[index] = true
            XCTAssertFalse(ProfileErasurePolicy.permitsDeletion(
                workoutActive: values[0], recoveryOutstanding: values[1],
                preflightActive: values[2], cleanupInFlight: values[3],
                testRunActive: values[4], stopPending: values[5],
                erasureInFlight: values[6], linkageInFlight: values[7]
            ))
        }
        XCTAssertTrue(ProfileErasurePolicy.permitsDeletion(
            workoutActive: false, recoveryOutstanding: false, preflightActive: false,
            cleanupInFlight: false, testRunActive: false, stopPending: false,
            erasureInFlight: false, linkageInFlight: false
        ))
    }
}
