import XCTest
@testable import TelemetryInstrumentation

final class TelemetryPerformanceInstrumentationTests: XCTestCase {
    func testEnabledAndDisabledControlObservationPreserveOutput() {
        let fixture = Array(0..<1_000)
        let enabled = TelemetryPerformanceInstrumentation(enabled: true)
        let disabled = TelemetryPerformanceInstrumentation(enabled: false)

        let enabledOutput = enabled.measureControlCycle {
            fixture.reduce(into: UInt64(0)) { checksum, value in
                checksum = (checksum &* 1_099_511_628_211) ^ UInt64(value)
            }
        }
        let disabledOutput = disabled.measureControlCycle {
            fixture.reduce(into: UInt64(0)) { checksum, value in
                checksum = (checksum &* 1_099_511_628_211) ^ UInt64(value)
            }
        }

        XCTAssertEqual(enabledOutput, disabledOutput)
    }

    func testInstrumentationSourceHasNoPrivateWorkoutMetadataSurface() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TelemetryInstrumentation/TelemetryPerformanceInstrumentation.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        for forbidden in [
            "beatsPerMinute", "BPM", "heartRate", "speedTrajectory",
            "profileIdentifier", "deviceIdentifier", "sessionIdentifier",
            "rawBLE", "healthPayload", "workoutExport",
        ] {
            XCTAssertFalse(source.contains(forbidden), "Instrumentation exposes \(forbidden)")
        }
    }
}
