import Foundation
import XCTest
@testable import WalkingPadCoreLogic

final class StopTruthExperimentEvidenceTests: XCTestCase {
    func testQualifyingFE01SuppliesWallAndMonotonicFirstConfirmation() {
        let context = makeContext()
        let origin = UUID()
        let stop = timestamp(origin: origin, uptime: 1_000_000_000, wall: Date(timeIntervalSince1970: 100))
        let observed = timestamp(origin: origin, uptime: 1_500_000_000, wall: Date(timeIntervalSince1970: 100.5))
        var service = StopTruthExperimentObservationService(context: context, stopInvokedAt: stop)
        let evaluation = service.record(
            .init(context: context, receivedAt: observed, rawHex: "F8 A2 RAW", checksumValid: true, speedRawTenths: 0, state: 0),
            nowUptimeNanoseconds: observed.monotonicUptimeNanoseconds
        )
        XCTAssertTrue(evaluation.isCurrentlyConfirmed)
        XCTAssertEqual(service.firstConfirmedAt, observed.wallDate)
        XCTAssertEqual(service.stopFirstConfirmedMonotonicUptimeNanoseconds, observed.monotonicUptimeNanoseconds)
    }

    func testCurrentAndEverTruthRemainDistinctAndFinalRowsAreDistinct() {
        let context = makeContext()
        let origin = UUID()
        let stop = timestamp(origin: origin, uptime: 1_000_000_000, wall: Date())
        let confirmed = timestamp(origin: origin, uptime: 2_000_000_000, wall: Date())
        var service = StopTruthExperimentObservationService(context: context, stopInvokedAt: stop)
        _ = service.record(
            .init(context: context, receivedAt: confirmed, rawHex: "raw", checksumValid: true, speedRawTenths: 0, state: 0),
            nowUptimeNanoseconds: confirmed.monotonicUptimeNanoseconds
        )
        let stale = service.finalizeWindow(nowUptimeNanoseconds: 4_000_000_001)
        let post = service.recordPostWindowFreshness(nowUptimeNanoseconds: 4_100_000_001)
        XCTAssertEqual(stale.result, .stale)
        XCTAssertNotNil(service.firstConfirmedAt)
        XCTAssertEqual(service.finalWindowEvaluation, stale)
        XCTAssertEqual(service.postWindowFreshnessEvaluation, post)
    }

    func testOriginMismatchAndNegativeAgeFailClosed() {
        let context = makeContext()
        let origin = UUID()
        let stop = timestamp(origin: origin, uptime: 2_000, wall: Date())
        var service = StopTruthExperimentObservationService(context: context, stopInvokedAt: stop)
        let restart = timestamp(origin: UUID(), uptime: 3_000, wall: Date())
        XCTAssertEqual(service.record(
            .init(context: context, receivedAt: restart, rawHex: "raw", checksumValid: true, speedRawTenths: 0, state: 0),
            nowUptimeNanoseconds: 3_000
        ).reason, "monotonic_origin_mismatch")
        let future = timestamp(origin: origin, uptime: 4_000, wall: Date())
        XCTAssertEqual(service.record(
            .init(context: context, receivedAt: future, rawHex: "raw", checksumValid: true, speedRawTenths: 0, state: 0),
            nowUptimeNanoseconds: 3_999
        ).reason, "impossible_negative_monotonic_age")
    }

    func testDedicatedWriterUsesPrivateIssue11PathAndPersistsRawFE01() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let experimentID = UUID()
        let writer = try StopTruthExperimentEvidenceWriter(experimentID: experimentID, rootDirectory: root)
        let record = StopTruthExperimentEvidenceRecord(
            event: .fe01Raw, experimentID: experimentID,
            caseID: StopTruthExperimentPlanService.caseID, repetition: 1,
            timestamp: timestamp(origin: UUID(), uptime: 1, wall: Date()),
            fields: ["raw_packet_hex": "F8 A2 00 FD", "checksum_valid": "true"]
        )
        writer.append(record)
        XCTAssertEqual(writer.fileURL.lastPathComponent, "issue11_stop_truth_\(experimentID.uuidString).jsonl")
        let text = try String(contentsOf: writer.fileURL)
        XCTAssertTrue(text.contains("F8 A2 00 FD"))
        XCTAssertTrue(text.contains("fe01_raw"))
    }

    func testSessionBoundsMarkersAndReconnectFailClosedWithoutCommands() {
        let sha = String(repeating: "c", count: 40)
        let identity = StopTruthExperimentBuildIdentity(
            capabilityCompiled: true,
            capabilityBinding: StopTruthExperimentBuildIdentity.requiredCapability,
            expectedGitSHA: sha, actualGitSHA: sha,
            bundleIdentifier: "test", version: "1", build: "1"
        )
        let context = makeContext()
        let origin = UUID()
        var session = StopTruthExperimentSessionService(
            context: context,
            clockOriginID: origin,
            timeoutPolicy: .init(perRepetitionSeconds: 90, globalSeconds: 300),
            buildIdentity: identity
        )
        let marker = timestamp(origin: origin, uptime: 100, wall: Date())
        XCTAssertFalse(session.recordMarker(.moving, timestamp: marker, note: "visible", operatorHadVisibility: true))
        XCTAssertFalse(session.recordMarker(.stopped, timestamp: marker, note: "visible", operatorHadVisibility: true))
        XCTAssertEqual(session.markers.count, 0)
        session.recordReconnect()
        XCTAssertEqual(session.reconnectCount, 1)
        XCTAssertEqual(session.phase, .failed(reason: "reconnect_forbidden"))
        XCTAssertEqual(StopTruthExperimentPlanService.classification, "CORE PHYSICAL QUALIFICATION")
        XCTAssertEqual(StopTruthExperimentPlanService.edgeSubclaim, "EDGE SUBCLAIM: UNKNOWN / NOT OBSERVED")
    }

    func testMovingMarkerIsCurrentRepetitionAndAfterSuccessfulRaw5Invocation() {
        var uptime: UInt64 = 1_000_000_000
        let origin = UUID()
        let clock = StopTruthExperimentClock(
            originID: origin,
            uptimeProvider: { uptime },
            wallProvider: Date.init
        )
        let context = makeContext()
        var session = makeSession(context: context, origin: origin)
        session.recordA6Bounds(.init(
            context: context,
            observedAt: clock.now()!,
            checksumValid: true,
            startSpeedRawTenths: 5,
            maxSpeedRawTenths: 50
        ))

        recordBaseline(
            speed: 0,
            state: 0,
            context: context,
            timestamps: nextPair(origin: origin, uptime: &uptime),
            session: &session
        )
        XCTAssertTrue(session.acceptStationaryBaseline(clock: clock, nowUptimeNanoseconds: uptime))
        XCTAssertTrue(session.beginMovingBaseline())
        XCTAssertFalse(session.recordMarker(.moving, timestamp: clock.now()!, note: "too early", operatorHadVisibility: true))
        session.recordMotionCapableInvocation(role: .baselineStart, timestamp: clock.now()!)
        session.recordRaw5Invocation(timestamp: clock.now()!)
        uptime += 1
        XCTAssertTrue(session.recordMarker(.moving, timestamp: clock.now()!, note: "visible", operatorHadVisibility: true))
        recordBaseline(
            speed: 5,
            state: 1,
            context: context,
            timestamps: nextPair(origin: origin, uptime: &uptime),
            session: &session
        )
        XCTAssertTrue(session.acceptMovingBaseline(clock: clock, nowUptimeNanoseconds: uptime))
        XCTAssertTrue(session.beginStopObservation())
        XCTAssertTrue(session.recordInitialStopInvocation(timestamp: clock.now()!))
        uptime += 100_000_000
        XCTAssertTrue(session.recordMarker(.stopped, timestamp: clock.now()!, note: "visible", operatorHadVisibility: true))
        XCTAssertTrue(session.finishObservationWindow())
        XCTAssertTrue(session.finishPostWindowFreshness(timestamp: clock.now()!, executorQuiescent: true))
        uptime += 30_000_000_000
        recordBaseline(
            speed: 0,
            state: 0,
            context: context,
            timestamps: nextPair(origin: origin, uptime: &uptime),
            session: &session
        )
        XCTAssertTrue(session.recordMarker(
            .stopped,
            timestamp: clock.now()!,
            note: "recovery",
            operatorHadVisibility: true,
            clock: clock
        ))
        XCTAssertTrue(session.beginNextRepetition(
            clock: clock,
            nowUptimeNanoseconds: uptime,
            executorQuiescent: true
        ))

        recordBaseline(
            speed: 0,
            state: 0,
            context: context,
            timestamps: nextPair(origin: origin, uptime: &uptime),
            session: &session
        )
        XCTAssertTrue(session.acceptStationaryBaseline(clock: clock, nowUptimeNanoseconds: uptime))
        XCTAssertTrue(session.beginMovingBaseline())
        session.recordMotionCapableInvocation(role: .baselineStart, timestamp: clock.now()!)
        session.recordRaw5Invocation(timestamp: clock.now()!)
        recordBaseline(
            speed: 5,
            state: 1,
            context: context,
            timestamps: nextPair(origin: origin, uptime: &uptime),
            session: &session
        )
        XCTAssertFalse(session.acceptMovingBaseline(clock: clock, nowUptimeNanoseconds: uptime))
        XCTAssertEqual(session.markers.filter { $0.marker == .moving }.map(\.repetition), [1])
    }

    func testControllerBlocksStaleA6AndUsesReceiveBoundaryTimestamp() {
        var uptime: UInt64 = 1_000_000_000
        let clock = StopTruthExperimentClock(
            uptimeProvider: { uptime },
            wallProvider: { Date(timeIntervalSince1970: Double(uptime) / 1_000_000_000) }
        )
        let context = makeContext()
        let sink = StopTruthExperimentMemoryEvidenceSink()
        var invokedRoles: [BLETransportCodec.StopTruthExperimentCommandRole] = []
        let controller = StopTruthExperimentController(
            buildIdentity: enabledIdentity(),
            context: context,
            timeoutPolicy: .init(perRepetitionSeconds: 90, globalSeconds: 300),
            evidenceSink: sink,
            clock: clock,
            transportInvocation: { _, role, _, _ in
                invokedRoles.append(role)
                return true
            },
            speedSnapshot: { (0, 0) },
            beforeHighPriorityStop: {},
            onStateChange: { _ in }
        )
        XCTAssertTrue(controller.start())
        let a6Received = uptime
        controller.recordA6Bounds(
            params: .init(
                maxSpeedRawTenths: 50,
                startSpeedRawTenths: 5,
                rawControllerUnit: 0,
                checksumOk: true,
                rawHex: "F8 A6"
            ),
            context: context,
            receivedUptimeNanoseconds: a6Received,
            receivedWallDate: Date(timeIntervalSince1970: 1)
        )

        uptime = a6Received + UInt64(StopTruthExperimentPlanService.a6FreshnessIntervalSeconds * 1_000_000_000) + 1
        let firstReceive = uptime
        recordControllerFE01(controller, context: context, uptime: uptime, speed: 0, state: 0)
        uptime += 100_000_000
        recordControllerFE01(controller, context: context, uptime: uptime, speed: 0, state: 0)
        uptime += 100_000_000

        XCTAssertFalse(controller.prepareMotion())
        XCTAssertEqual(invokedRoles, [.queryParams])
        let rawRows = sink.records.filter { $0.event == .fe01Raw }
        XCTAssertEqual(rawRows.first?.timestamp.monotonicUptimeNanoseconds, firstReceive)
        XCTAssertEqual(rawRows.first?.timestamp.wallDate, Date(timeIntervalSince1970: Double(firstReceive) / 1_000_000_000))
    }

    func testSessionTimeoutInputsAndThreeRepetitionMatrixAreBounded() {
        let valid = StopTruthExperimentSessionService.TimeoutPolicy(
            perRepetitionSeconds: 90,
            globalSeconds: 300
        )
        XCTAssertTrue(valid.isValid)
        XCTAssertFalse(StopTruthExperimentSessionService.TimeoutPolicy(
            perRepetitionSeconds: 30,
            globalSeconds: 300
        ).isValid)
        XCTAssertFalse(StopTruthExperimentSessionService.TimeoutPolicy(
            perRepetitionSeconds: 90,
            globalSeconds: 269
        ).isValid)
        XCTAssertEqual(StopTruthExperimentPlanService.observationWindowSeconds, 30)
        XCTAssertEqual(StopTruthExperimentPlanService.postWindowFreshnessDelaySeconds, 2.1)
        XCTAssertEqual(StopTruthExperimentPlanService.plannedRepetitions, 3)
    }

    private func makeContext() -> StopTruthExperimentPlanService.Context {
        .init(peripheralID: UUID(), connectionEpoch: UUID(), notificationStreamID: UUID())
    }

    private func enabledIdentity() -> StopTruthExperimentBuildIdentity {
        let sha = String(repeating: "c", count: 40)
        return .init(
            capabilityCompiled: true,
            capabilityBinding: StopTruthExperimentBuildIdentity.requiredCapability,
            expectedGitSHA: sha,
            actualGitSHA: sha,
            bundleIdentifier: "test",
            version: "1",
            build: "1"
        )
    }

    private func makeSession(
        context: StopTruthExperimentPlanService.Context,
        origin: UUID
    ) -> StopTruthExperimentSessionService {
        .init(
            context: context,
            clockOriginID: origin,
            timeoutPolicy: .init(perRepetitionSeconds: 90, globalSeconds: 300),
            buildIdentity: enabledIdentity()
        )
    }

    private func recordBaseline(
        speed: Int,
        state: Int,
        context: StopTruthExperimentPlanService.Context,
        timestamps: (StopTruthExperimentTimestamp, StopTruthExperimentTimestamp),
        session: inout StopTruthExperimentSessionService
    ) {
        session.recordFE01(.init(
            context: context,
            receivedAt: timestamps.0,
            rawHex: "F8 A2",
            checksumValid: true,
            speedRawTenths: speed,
            state: state
        ))
        session.recordFE01(.init(
            context: context,
            receivedAt: timestamps.1,
            rawHex: "F8 A2",
            checksumValid: true,
            speedRawTenths: speed,
            state: state
        ))
    }

    private func nextPair(
        origin: UUID,
        uptime: inout UInt64
    ) -> (StopTruthExperimentTimestamp, StopTruthExperimentTimestamp) {
        let first = timestamp(origin: origin, uptime: uptime, wall: Date())
        uptime += 100_000_000
        return (first, timestamp(origin: origin, uptime: uptime, wall: Date()))
    }

    private func recordControllerFE01(
        _ controller: StopTruthExperimentController,
        context: StopTruthExperimentPlanService.Context,
        uptime: UInt64,
        speed: UInt8,
        state: Int
    ) {
        controller.recordFE01(
            rawHex: "F8 A2",
            status: .init(
                beltState: state,
                speedRawTenths: speed,
                manualMode: 1,
                timeSeconds: 0,
                distance10m: 0,
                steps: 0,
                appSpeedRawTenths: speed,
                lastButton: 0,
                checksumOk: true
            ),
            context: context,
            receivedUptimeNanoseconds: uptime,
            receivedWallDate: Date(timeIntervalSince1970: Double(uptime) / 1_000_000_000)
        )
    }

    private func timestamp(origin: UUID, uptime: UInt64, wall: Date) -> StopTruthExperimentTimestamp {
        .init(originID: origin, monotonicUptimeNanoseconds: uptime, monotonicElapsedSeconds: 0, wallDate: wall)
    }
}
