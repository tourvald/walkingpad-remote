import XCTest
@testable import WalkingPadCoreLogic

final class HRSettingsDefaultsTests: XCTestCase {
    func testMissingSavedCooldownTargetUsesNewDefault() {
        XCTAssertEqual(
            HRSettingsDefaults.resolvedCooldownTargetBpm(savedValue: nil),
            115
        )
    }

    func testSavedCooldownTargetIsPreserved() {
        XCTAssertEqual(
            HRSettingsDefaults.resolvedCooldownTargetBpm(savedValue: 110),
            110
        )
    }
}
