import Foundation
import XCTest
@testable import WalkingPadCoreLogic

final class StopTruthExperimentPlanTests: XCTestCase {
    private let sha = String(repeating: "a", count: 40)

    func testTypedWhitelistOwnsExactBytesAndDistinctToggleRoles() {
        let expected: [BLETransportCodec.StopTruthExperimentCommandRole: String] = [
            .queryParams: "F7 A6 00 00 00 00 00 A6 FD",
            .modeManual: "F7 A2 02 01 A5 FD",
            .baselineStart: "F7 A2 04 01 A7 FD",
            .speedRaw5: "F7 A2 01 05 A8 FD",
            .initialStop: "F7 A2 01 00 A3 FD",
            .productionStopRecovery: "F7 A2 04 01 A7 FD",
            .conditionalStopRetry: "F7 A2 01 00 A3 FD"
        ]
        XCTAssertEqual(Set(expected.keys), Set(BLETransportCodec.StopTruthExperimentCommandRole.allCases))
        for (role, hex) in expected {
            XCTAssertEqual(BLETransportCodec.buildStopTruthExperimentPacket(role: role).hex, hex)
        }
        let a6Packets = BLETransportCodec.StopTruthExperimentCommandRole.allCases.filter {
            BLETransportCodec.buildStopTruthExperimentPacket(role: $0).dropFirst().first == 0xA6
        }
        XCTAssertEqual(a6Packets, [.queryParams], "No A6 preference/unit write belongs to the experiment set")
        XCTAssertNotEqual(
            BLETransportCodec.StopTruthExperimentCommandRole.baselineStart,
            .productionStopRecovery
        )
    }

    func testFixedSequenceCountsQueryAndModeOnlyOnFirstRepetition() {
        XCTAssertEqual(
            StopTruthExperimentPlanService.fixedRoles(firstRepetition: true, retryRequired: true),
            [.queryParams, .modeManual, .baselineStart, .speedRaw5, .initialStop, .productionStopRecovery, .conditionalStopRetry]
        )
        XCTAssertEqual(
            StopTruthExperimentPlanService.fixedRoles(firstRepetition: false, retryRequired: false),
            [.baselineStart, .speedRaw5, .initialStop, .productionStopRecovery]
        )
        XCTAssertEqual(StopTruthExperimentPlanService.plannedRepetitions, 3)
        XCTAssertEqual(StopTruthExperimentPlanService.allowedReconnectCount, 0)
    }

    func testProductionRetryPredicateAndDelaysAreExact() {
        XCTAssertFalse(StopTruthExperimentPlanService.productionRetryRequired(speedKmh: 0.2, deviceReportedSpeedKmh: 0.2))
        XCTAssertTrue(StopTruthExperimentPlanService.productionRetryRequired(speedKmh: 0.21, deviceReportedSpeedKmh: 0))
        XCTAssertTrue(StopTruthExperimentPlanService.productionRetryRequired(speedKmh: 0, deviceReportedSpeedKmh: 0.21))
        XCTAssertEqual(StopTruthExperimentPlanService.recoveryToggleDelaySeconds, 2.0)
        XCTAssertEqual(StopTruthExperimentPlanService.conditionalRetryDelaySeconds, 4.0)
    }

    func testRaw5RequiresFreshChecksumValidSameContextA6Bounds() {
        var uptime: UInt64 = 1_000_000_000
        let clock = StopTruthExperimentClock(originID: UUID(), uptimeProvider: { uptime }, wallProvider: Date.init)
        let context = makeContext()
        let timestamp = clock.now()!
        let valid = StopTruthExperimentPlanService.A6BoundsEvidence(
            context: context,
            observedAt: timestamp,
            checksumValid: true,
            startSpeedRawTenths: 5,
            maxSpeedRawTenths: 50
        )
        uptime += 2_000_000_000
        XCTAssertTrue(StopTruthExperimentPlanService.raw5IsAllowed(by: valid, currentContext: context, clock: clock, nowUptimeNanoseconds: uptime, maximumAgeSeconds: 2.0))
        uptime += 1
        XCTAssertFalse(StopTruthExperimentPlanService.raw5IsAllowed(by: valid, currentContext: context, clock: clock, nowUptimeNanoseconds: uptime, maximumAgeSeconds: 2.0))

        let badChecksum = StopTruthExperimentPlanService.A6BoundsEvidence(
            context: context,
            observedAt: timestamp,
            checksumValid: false,
            startSpeedRawTenths: 0,
            maxSpeedRawTenths: 50
        )
        XCTAssertFalse(StopTruthExperimentPlanService.raw5IsAllowed(by: badChecksum, currentContext: context, clock: clock, nowUptimeNanoseconds: timestamp.monotonicUptimeNanoseconds, maximumAgeSeconds: 2.0))
        let outOfBounds = StopTruthExperimentPlanService.A6BoundsEvidence(
            context: context,
            observedAt: timestamp,
            checksumValid: true,
            startSpeedRawTenths: 6,
            maxSpeedRawTenths: 50
        )
        XCTAssertFalse(StopTruthExperimentPlanService.raw5IsAllowed(by: outOfBounds, currentContext: context, clock: clock, nowUptimeNanoseconds: timestamp.monotonicUptimeNanoseconds, maximumAgeSeconds: 2.0))
        XCTAssertFalse(StopTruthExperimentPlanService.raw5IsAllowed(by: valid, currentContext: makeContext(), clock: clock, nowUptimeNanoseconds: timestamp.monotonicUptimeNanoseconds, maximumAgeSeconds: 2.0))
    }

    func testStationaryAndMovingBaselinesRequireTwoConsecutiveFreshValidFrames() {
        var uptime: UInt64 = 10_000_000_000
        let clock = StopTruthExperimentClock(uptimeProvider: { uptime }, wallProvider: Date.init)
        let context = makeContext()
        let stationary = makeFE01(context: context, timestamp: clock.now()!, speed: 0, state: 0)
        uptime += 100_000_000
        let secondStationary = makeFE01(context: context, timestamp: clock.now()!, speed: 0, state: 2)
        XCTAssertTrue(StopTruthExperimentPlanService.baselineSatisfied(
            observations: [stationary, secondStationary], kind: .stationary,
            currentContext: context, clock: clock, nowUptimeNanoseconds: uptime
        ))
        let invalid = makeFE01(context: context, timestamp: clock.now()!, speed: 0, state: 0, checksum: false)
        XCTAssertFalse(StopTruthExperimentPlanService.baselineSatisfied(
            observations: [stationary, invalid, secondStationary], kind: .stationary,
            currentContext: context, clock: clock, nowUptimeNanoseconds: uptime
        ))
        let wrongContext = makeFE01(context: makeContext(), timestamp: clock.now()!, speed: 0, state: 0)
        XCTAssertFalse(StopTruthExperimentPlanService.baselineSatisfied(
            observations: [secondStationary, wrongContext], kind: .stationary,
            currentContext: context, clock: clock, nowUptimeNanoseconds: uptime
        ))
        XCTAssertFalse(StopTruthExperimentPlanService.baselineSatisfied(
            observations: [secondStationary], kind: .stationary,
            currentContext: context, clock: clock, nowUptimeNanoseconds: uptime
        ))
        uptime += 2_000_000_001
        XCTAssertFalse(StopTruthExperimentPlanService.baselineSatisfied(
            observations: [stationary, secondStationary], kind: .stationary,
            currentContext: context, clock: clock, nowUptimeNanoseconds: uptime
        ))
        uptime -= 2_000_000_001

        let moving1 = makeFE01(context: context, timestamp: clock.now()!, speed: 5, state: 1)
        let moving2 = makeFE01(context: context, timestamp: clock.now()!, speed: 5, state: 1)
        XCTAssertFalse(StopTruthExperimentPlanService.baselineSatisfied(
            observations: [moving1, moving2], kind: .movingRaw5(movingMarkerRecorded: false),
            currentContext: context, clock: clock, nowUptimeNanoseconds: uptime
        ))
        XCTAssertTrue(StopTruthExperimentPlanService.baselineSatisfied(
            observations: [moving1, moving2], kind: .movingRaw5(movingMarkerRecorded: true),
            currentContext: context, clock: clock, nowUptimeNanoseconds: uptime
        ))
    }

    func testBuildIdentityFailsClosedForDefaultMissingMalformedAndMismatch() {
        XCTAssertFalse(identity(compiled: false, expected: sha, actual: sha).isEnabled)
        XCTAssertFalse(identity(compiled: true, expected: nil, actual: sha).isEnabled)
        XCTAssertFalse(identity(compiled: true, expected: "abc", actual: "abc").isEnabled)
        XCTAssertFalse(identity(compiled: true, expected: sha, actual: String(repeating: "b", count: 40)).isEnabled)
        XCTAssertTrue(identity(compiled: true, expected: sha, actual: sha).isEnabled)
    }

    func testDefaultProjectDoesNotEnableExperimentCapabilityOrBindings() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let project = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("WalkingPadRemote.xcodeproj/project.pbxproj")
        let text = try String(contentsOf: project)
        XCTAssertFalse(text.contains("SWIFT_ACTIVE_COMPILATION_CONDITIONS = \"STOP_TRUTH_EXPERIMENT_CAPABILITY"))
        XCTAssertFalse(text.contains("EXECUTABLE_SUFFIX = \"-issue14-stop-truth"))
    }

    func testExecutableBuildBindingParsesExpectedAndActualExactSHAs() {
        let expected = String(repeating: "a", count: 40)
        let actual = String(repeating: "b", count: 40)
        let executable = "WalkingPadRemote-issue14-stop-truth-v1-e\(expected)-a\(actual)"
        let parsed = StopTruthExperimentBuildIdentity.parseExecutableBinding(executable)
        XCTAssertEqual(parsed?.expected, expected)
        XCTAssertEqual(parsed?.actual, actual)
        XCTAssertNil(StopTruthExperimentBuildIdentity.parseExecutableBinding("WalkingPadRemote"))
        XCTAssertNil(StopTruthExperimentBuildIdentity.parseExecutableBinding("WalkingPadRemote-issue14-stop-truth-v1-eabc-aabc"))
    }

    func testExperimentSourcesExposeNoGenericPacketInputSurface() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceDirectory = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("WalkingPadRemote")
        let names = [
            "StopTruthExperimentController.swift",
            "StopTruthExperimentExecutor.swift",
            "StopTruthExperimentPlanService.swift",
            "DebugStopTruthExperimentCard.swift"
        ]
        let forbidden = ["arbitrary", "rawCommand", "rawPacketInput", "cmdInput", "valueInput", "sequenceInput"]
        for name in names {
            let text = try String(contentsOf: sourceDirectory.appendingPathComponent(name))
            for token in forbidden {
                XCTAssertFalse(text.contains(token), "\(name) exposes forbidden token \(token)")
            }
        }
    }

    func testClockUsesStableOriginAndRejectsNegativeAgeOrRestart() {
        var uptime: UInt64 = 5_000
        let clock = StopTruthExperimentClock(originID: UUID(), uptimeProvider: { uptime }, wallProvider: Date.init)
        let first = clock.now()!
        uptime = 7_000
        let second = clock.now()!
        XCTAssertEqual(first.originID, second.originID)
        XCTAssertEqual(clock.ageSeconds(since: first, nowUptimeNanoseconds: uptime), 0.000002)
        XCTAssertNil(clock.ageSeconds(since: second, nowUptimeNanoseconds: 6_999))
        let restarted = StopTruthExperimentTimestamp(
            originID: UUID(), monotonicUptimeNanoseconds: 7_000,
            monotonicElapsedSeconds: 0, wallDate: Date()
        )
        XCTAssertNil(clock.ageSeconds(since: restarted, nowUptimeNanoseconds: 8_000))
    }

    private func identity(compiled: Bool, expected: String?, actual: String?) -> StopTruthExperimentBuildIdentity {
        StopTruthExperimentBuildIdentity(
            capabilityCompiled: compiled,
            capabilityBinding: StopTruthExperimentBuildIdentity.requiredCapability,
            expectedGitSHA: expected,
            actualGitSHA: actual,
            bundleIdentifier: "test", version: "1", build: "1"
        )
    }

    private func makeContext() -> StopTruthExperimentPlanService.Context {
        .init(peripheralID: UUID(), connectionEpoch: UUID(), notificationStreamID: UUID())
    }

    private func makeFE01(
        context: StopTruthExperimentPlanService.Context,
        timestamp: StopTruthExperimentTimestamp,
        speed: Int?, state: Int?, checksum: Bool = true
    ) -> StopTruthExperimentPlanService.FE01Observation {
        .init(context: context, receivedAt: timestamp, rawHex: "F8 A2", checksumValid: checksum, speedRawTenths: speed, state: state)
    }
}

private extension Data {
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}
