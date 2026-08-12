import Foundation
import XCTest
@testable import WalkingPadCoreLogic

final class ControllerUnitsReadOnlyContractTests: XCTestCase {
    func testProductionUnitsImplementationContainsNoPreferenceWritePath() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("WalkingPadRemote")
        let productionFiles = [
            "BLETransportCodec.swift",
            "BluetoothManager.swift",
            "ControllerUnitsSafetyPolicy.swift"
        ]
        let forbiddenTokens = [
            "buildWalkingPadUnitPreferencePacket",
            "setUnit(",
            "setMetric",
            "setImperial",
            "F7 A6 08"
        ]

        for fileName in productionFiles {
            let source = try String(contentsOf: sourceDirectory.appendingPathComponent(fileName), encoding: .utf8)
            for token in forbiddenTokens {
                XCTAssertFalse(source.contains(token), "Unexpected controller unit write token \(token) in \(fileName)")
            }
        }
    }
}
