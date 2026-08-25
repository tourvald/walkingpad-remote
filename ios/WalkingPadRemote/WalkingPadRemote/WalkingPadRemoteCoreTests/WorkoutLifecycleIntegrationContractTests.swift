import Foundation
import XCTest

final class WorkoutLifecycleIntegrationContractTests: XCTestCase {
    func testSceneTransitionsRouteThroughTypedLifecycleEvidence() throws {
        let contentView = try source("WalkingPadRemote/ContentView.swift")
        let manager = try source("WalkingPadRemote/BluetoothManager.swift")

        for token in [
            "manager.nativeHeartRateAppBecameActive()",
            "manager.nativeHeartRateAppBecameInactive()",
            "manager.nativeHeartRateAppEnteredBackground()",
        ] {
            XCTAssertTrue(contentView.contains(token), token)
        }
        for token in [
            "recordWorkoutLifecycleTransition(",
            "logTrainingEvent(\"app_lifecycle\"",
            ".appLifecycle(AppLifecycleEvent(",
            "\"hr_last_factual_at\"",
            "\"hr_last_received_at\"",
            "\"treadmill_control_ready\"",
            "\"background_policy_action\"",
        ] {
            XCTAssertTrue(manager.contains(token), token)
        }
    }

    func testLifecycleEvidenceCannotSendMotionOrStopCommands() throws {
        let manager = try source("WalkingPadRemote/BluetoothManager.swift")
        let body = try functionBody(
            "private func recordWorkoutLifecycleTransition(",
            in: manager
        )

        for forbidden in [
            "startWithSpeed", "setTargetSpeed", "sendTreadmill", "writeCommand",
            "enqueue", "stopBelt", "stopHrControl",
        ] {
            XCTAssertFalse(body.contains(forbidden), forbidden)
        }
    }

    func testBackgroundCapabilityIsBluetoothCentralOnlyAndIdleTimerRemainsSystemOwned() throws {
        let project = try source("WalkingPadRemote.xcodeproj/project.pbxproj")
        let infoPlist = try source("WalkingPadRemote/Info.plist")
        let appSources = try FileManager.default.contentsOfDirectory(
            at: sourceRoot.appendingPathComponent("WalkingPadRemote", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" }
        .map { try String(contentsOf: $0, encoding: .utf8) }
        .joined(separator: "\n")

        XCTAssertEqual(
            project.components(
                separatedBy: "INFOPLIST_FILE = WalkingPadRemote/Info.plist;"
            ).count - 1,
            2
        )
        XCTAssertTrue(project.contains("com.apple.BackgroundModes"))
        XCTAssertTrue(infoPlist.contains("<key>UIBackgroundModes</key>"))
        XCTAssertEqual(
            infoPlist.components(separatedBy: "<string>bluetooth-central</string>").count - 1,
            1
        )
        XCTAssertFalse(infoPlist.contains("<string>audio</string>"))
        XCTAssertFalse(project.contains("bluetooth-peripheral"))
        XCTAssertFalse(appSources.contains("isIdleTimerDisabled"))
    }

    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: sourceRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func functionBody(_ signature: String, in source: String) throws -> String {
        guard let start = source.range(of: signature)?.lowerBound else {
            throw ContractError.missingSignature(signature)
        }
        let suffix = source[start...]
        guard let openingBrace = suffix.firstIndex(of: "{") else {
            throw ContractError.missingBody(signature)
        }
        var depth = 0
        for index in suffix.indices[openingBrace...] {
            switch suffix[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(suffix[openingBrace...index])
                }
            default: break
            }
        }
        throw ContractError.missingBody(signature)
    }

    private enum ContractError: Error {
        case missingSignature(String)
        case missingBody(String)
    }
}
