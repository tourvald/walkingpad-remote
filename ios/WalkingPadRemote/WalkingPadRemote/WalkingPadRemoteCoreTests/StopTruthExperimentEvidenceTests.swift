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
            timeoutPolicy: .init(perRepetitionSeconds: 60, globalSeconds: 180),
            buildIdentity: identity
        )
        let marker = timestamp(origin: origin, uptime: 100, wall: Date())
        XCTAssertTrue(session.recordMarker(.moving, timestamp: marker, note: "visible", operatorHadVisibility: true))
        XCTAssertEqual(session.markers.count, 1)
        session.recordReconnect()
        XCTAssertEqual(session.reconnectCount, 1)
        XCTAssertEqual(session.phase, .failed(reason: "reconnect_forbidden"))
        XCTAssertEqual(StopTruthExperimentPlanService.classification, "CORE PHYSICAL QUALIFICATION")
        XCTAssertEqual(StopTruthExperimentPlanService.edgeSubclaim, "EDGE SUBCLAIM: UNKNOWN / NOT OBSERVED")
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

    private func timestamp(origin: UUID, uptime: UInt64, wall: Date) -> StopTruthExperimentTimestamp {
        .init(originID: origin, monotonicUptimeNanoseconds: uptime, monotonicElapsedSeconds: 0, wallDate: wall)
    }
}
