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

    func testDebugDiagnosticIsShareableAndDoesNotBecomeControlAuthority() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent(
            "WalkingPadRemote"
        )
        let manager = try String(
            contentsOf: sourceDirectory.appendingPathComponent("BluetoothManager.swift"),
            encoding: .utf8
        )
        let content = try String(
            contentsOf: sourceDirectory.appendingPathComponent("ContentView.swift"),
            encoding: .utf8
        )
        let card = try String(
            contentsOf: sourceDirectory.appendingPathComponent("DebugTrainingLogsCard.swift"),
            encoding: .utf8
        )

        XCTAssertEqual(
            manager.components(separatedBy: "ControllerUnitsDiagnosticSnapshot").count - 1,
            2
        )
        XCTAssertTrue(content.contains("manager.controllerUnitsDiagnosticSnapshot()"))
        XCTAssertTrue(card.contains("ShareLink(item: presentation.controllerUnitsDiagnosticReport)"))
        XCTAssertTrue(card.contains("presentation.controllerUnitsDiagnosticDetailLines"))

        for controlSignature in [
            "func startTreadmillTestRun()",
            "private func controllerUnitsGateDecision(",
            "private func commitNativeHeartRatePreflight(",
        ] {
            let body = try functionBody(controlSignature, in: manager)
            XCTAssertFalse(body.contains("ControllerUnitsDiagnostic"))
        }
    }

    func testControllerParamsParserContractAcceptsOnlyProvenShapes() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let codec = try String(
            contentsOf: testsDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("WalkingPadRemote/BLETransportCodec.swift"),
            encoding: .utf8
        )
        let parser = try functionBody(
            "static func parseWalkingPadParams(_ data: Data)",
            in: codec
        )

        XCTAssertTrue(parser.contains("case 16, 20:"))
        XCTAssertTrue(parser.contains("default:\n            return nil"))
        XCTAssertTrue(parser.contains("data[0] == 0xF8"))
        XCTAssertTrue(parser.contains("data[1] == 0xA6"))
        XCTAssertTrue(parser.contains("data[data.count - 1] == 0xFD"))
        XCTAssertTrue(parser.contains("rawControllerUnit: data[13]"))
    }

    func testActiveUnitsRefreshUsesOnlyProvenMotionIdleWindow() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let manager = try String(
            contentsOf: testsDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("WalkingPadRemote/BluetoothManager.swift"),
            encoding: .utf8
        )
        let tick = try functionBody("private func tickTelemetry()", in: manager)
        let maintenance = try functionBody(
            "private func maintainWalkingPadReadOnlyEvidenceDuringActiveWorkout(",
            in: manager
        )
        let request = try functionBody("private func requestControllerUnitsTruth(", in: manager)

        XCTAssertTrue(tick.contains("maintainWalkingPadReadOnlyEvidenceDuringActiveWorkout"))
        XCTAssertTrue(maintenance.contains("motionQueueIdle: commandQueue.isEmpty"))
        XCTAssertTrue(maintenance.contains("!isCommandQueueProcessing"))
        XCTAssertTrue(maintenance.contains("nextCommandAllowedAt <= now"))
        XCTAssertTrue(maintenance.contains("controllerUnitsNextScheduledMotionLeadSeconds"))
        XCTAssertTrue(maintenance.contains("WalkingPadStatusRefreshPolicy.activeWorkoutRefresh"))
        XCTAssertTrue(request.contains("BLETransportCodec.buildWalkingPadQueryParamsPacket()"))
        XCTAssertFalse(maintenance.contains("sendTreadmill"))
        XCTAssertFalse(maintenance.contains("isHrControlStartAllowed ="))
    }

    private func functionBody(_ signature: String, in source: String) throws -> String {
        guard let signatureRange = source.range(of: signature),
              let openingBrace = source[signatureRange.upperBound...].firstIndex(of: "{") else {
            throw NSError(domain: "ControllerUnitsReadOnlyContractTests", code: 1)
        }
        var depth = 0
        var index = openingBrace
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(source[openingBrace...index]) }
            default: break
            }
            index = source.index(after: index)
        }
        throw NSError(domain: "ControllerUnitsReadOnlyContractTests", code: 2)
    }
}
