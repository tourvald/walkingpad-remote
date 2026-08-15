import Foundation
import XCTest

final class HeartRateLegacyBehaviorContractTests: XCTestCase {
    private lazy var managerSource = source(
        relativePath: "WalkingPadRemote/BluetoothManager.swift"
    )
    private lazy var contentViewSource = source(
        relativePath: "WalkingPadRemote/ContentView.swift"
    )
    private lazy var watchSource = source(
        relativePath: "WalkingPadRemoteWatch Watch App/WatchHeartRateManager.swift"
    )
    private lazy var normalizationSource = source(
        relativePath: "Sources/TelemetryDomain/HeartRateNormalization.swift"
    )

    func testLegacyWatchPayloadCarriesHeartRateValue() throws {
        let body = try functionBody(
            "private func sendHeartRate(_ value: Double, callbackObservedAt: Date)",
            in: watchSource
        )

        XCTAssertTrue(body.contains("\"hr\": value"))
        XCTAssertTrue(body.contains("\"hr_callback_observed_at\""))
        XCTAssertTrue(body.contains("\"hr_sequence\""))
        XCTAssertTrue(body.contains("session.sendMessage(payload"))
        XCTAssertTrue(body.contains("session.updateApplicationContext(payload)"))
    }

    func testEveryValidLegacyPayloadUpdatesControllerStateAndPredictorInOrder() throws {
        let body = try functionBody(
            "private func handleWatchPayload(_ payload: [String: Any])",
            in: managerSource
        )
        let delivery = try functionBody(
            "public static func applyDelivery(",
            in: normalizationSource
        )

        assertOrdered(
            [
                "HeartRateLegacyControlSemantics.applyDelivery(",
                "self.observeHeartRateDelivery(",
            ],
            in: body
        )
        assertOrdered(
            [
                "updateCurrent(beatsPerMinute)",
                "updateLastKnown(beatsPerMinute)",
                "updateLastReceivedAt(now())",
                "recordPredictorInput(beatsPerMinute)",
            ],
            in: delivery
        )
        XCTAssertFalse(body.contains("dedup"))
        XCTAssertFalse(body.contains("sorted"))
        XCTAssertFalse(body.contains("debounce"))
        XCTAssertTrue(body.contains("let phoneReceivedAt = Date()"))
        XCTAssertFalse(body.contains("Task"))
        XCTAssertFalse(body.contains("await"))
        XCTAssertFalse(body.contains("TelemetryRecorder"))
        XCTAssertFalse(body.contains("TelemetryPersistence"))
        XCTAssertFalse(body.contains("SwiftData"))
    }

    func testActualControlUseIsObservedAtTheExistingSpeedDecisionBranch() throws {
        let tick = try functionBody("private func tickTelemetry()", in: managerSource)

        assertOrdered(
            [
                "guard hrStreamingActive, heartRateBPM > 0",
                "let trend = currentHrTrendBpmPerSecond()",
                "let controlUseEvidence = makeHeartRateControlUseEvidence(",
                "defer { observeHeartRateControlUse(controlUseEvidence) }",
                "let effectiveBpm = max(heartRateBPM",
            ],
            in: tick
        )
        XCTAssertFalse(
            try functionBody(
                "private func observeHeartRateDelivery(",
                in: managerSource
            ).contains("usedForControl")
        )
    }

    func testStartEligibilityPreservesConnectionWatchFreshHeartRateAndUnitsGates() throws {
        let recompute = try functionBody(
            "private func recomputeHrStartAllowed()",
            in: managerSource
        )
        let start = try functionBody("func startHrControl()", in: managerSource)

        for body in [recompute, start] {
            XCTAssertTrue(
                body.contains("HeartRateControlStartEligibility")
            )
            XCTAssertTrue(body.contains("controllerUnits"))
            XCTAssertFalse(body.contains("TelemetryRecorder"))
            XCTAssertFalse(body.contains("TelemetryPersistence"))
            XCTAssertFalse(body.contains("telemetry health"))
        }

        XCTAssertTrue(
            contentViewSource.contains(
                "manager.isHrControlStartAllowed && manager.watchReachable && manager.hrStreamingActive"
            )
        )
    }

    func testStaleGraceAndMissingSignalBehaviorConstantsRemainExact() throws {
        XCTAssertTrue(managerSource.contains("private let hrStartGraceSeconds: Int = 15"))
        XCTAssertTrue(managerSource.contains("private let hrNoDataMaxSeconds: Int = 60"))
        XCTAssertTrue(managerSource.contains("private let hrStaleThresholdSeconds: Int = 7"))

        let staleTimer = try functionBody(
            "private func startHrStaleTimer()",
            in: managerSource
        )
        XCTAssertTrue(
            staleTimer.contains("HeartRateLegacyControlSemantics.streamIsActive(")
        )

        let tick = try functionBody("private func tickTelemetry()", in: managerSource)
        XCTAssertTrue(tick.contains("HeartRateLegacyControlSemantics.shouldStopForMissingSignal("))
        XCTAssertTrue(tick.contains("HeartRateLegacyControlSemantics.isWithinInitialGrace("))
        XCTAssertTrue(tick.contains("HeartRateLegacyControlSemantics"))
        XCTAssertTrue(tick.contains(".missingSignalSeconds("))
    }

    func testWatchStartStopLifecycleRemainsOwnedByExistingCommands() throws {
        let start = try functionBody("func start()", in: watchSource)
        let stop = try functionBody("func stop()", in: watchSource)
        let command = try functionBody("private func handleCommand(_ cmd: String)", in: watchSource)

        XCTAssertTrue(start.contains("startWorkout()"))
        XCTAssertTrue(stop.contains("workoutController.endAndFinish()"))
        XCTAssertTrue(stop.contains("sendStatus(\"hr_stopped\")"))
        XCTAssertTrue(command.contains("start_hr"))
        XCTAssertTrue(command.contains("stop_hr"))
    }

    private func source(relativePath: String) -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let root = testsDirectory.deletingLastPathComponent()
        return (try? String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )) ?? ""
    }

    private func functionBody(_ signature: String, in source: String) throws -> String {
        guard let signatureRange = source.range(of: signature),
              let openingBrace = source[signatureRange.upperBound...].firstIndex(of: "{")
        else {
            throw NSError(domain: "HeartRateLegacyBehaviorContractTests", code: 1)
        }
        var depth = 0
        var index = openingBrace
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[openingBrace...index])
                }
            default: break
            }
            index = source.index(after: index)
        }
        throw NSError(domain: "HeartRateLegacyBehaviorContractTests", code: 2)
    }

    private func assertOrdered(
        _ fragments: [String],
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var lowerBound = source.startIndex
        for fragment in fragments {
            guard let range = source.range(
                of: fragment,
                range: lowerBound..<source.endIndex
            ) else {
                XCTFail("Missing or out-of-order fragment: \(fragment)", file: file, line: line)
                return
            }
            lowerBound = range.upperBound
        }
    }
}
