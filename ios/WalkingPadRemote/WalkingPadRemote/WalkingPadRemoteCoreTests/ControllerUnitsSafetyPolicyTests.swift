import Foundation
import XCTest
@testable import WalkingPadCoreLogic

final class ControllerUnitsSafetyPolicyTests: XCTestCase {
    private let epoch = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let now = Date(timeIntervalSince1970: 1_000)

    func testFreshVerifiedMetricAllowsBothCoveredAutomatedPaths() {
        for path in ControllerAutomatedMotionPath.allCases {
            let decision = evaluate(path: path, state: truth(units: .metric))
            XCTAssertTrue(decision.allowed, "Expected fresh metric to allow \(path.rawValue)")
            XCTAssertNil(decision.blockReason)
        }
    }

    func testFreshImperialBlocksBothCoveredAutomatedPaths() {
        for path in ControllerAutomatedMotionPath.allCases {
            let decision = evaluate(path: path, state: truth(units: .imperial))
            XCTAssertFalse(decision.allowed)
            XCTAssertEqual(decision.blockReason, .imperial)
        }
    }

    func testInvalidChecksumMalformedUnknownAndNotReadFailClosed() {
        XCTAssertEqual(evaluate(state: truth(units: .metric, status: .invalidChecksum)).blockReason, .invalidChecksum)
        XCTAssertEqual(evaluate(state: truth(units: .unknown, status: .malformed)).blockReason, .malformed)
        XCTAssertEqual(evaluate(state: truth(units: .unknown)).blockReason, .unknown)
        XCTAssertEqual(evaluate(state: notReadTruth()).blockReason, .notRead)
    }

    func testExpiredMetricTruthIsStale() {
        let observedAt = now.addingTimeInterval(-ControllerUnitsSafetyPolicy.freshnessInterval - 0.001)
        let decision = evaluate(state: truth(units: .metric, observedAt: observedAt))

        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.blockReason, .stale)
    }

    func testReconnectClearsPriorMetricTruthAndRejectsPreviousEpoch() {
        var tracker = ControllerUnitsTruthTracker()
        tracker.beginConnection(epoch: epoch)
        tracker.record(validParams(unit: 0), for: epoch, at: now)
        XCTAssertTrue(evaluate(state: tracker.state).allowed)

        let reconnectedEpoch = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        tracker.beginConnection(epoch: reconnectedEpoch)
        tracker.record(validParams(unit: 0), for: epoch, at: now)

        XCTAssertEqual(tracker.state.status, .notRead)
        let decision = ControllerUnitsSafetyPolicy.evaluate(
            path: .hrControl,
            state: tracker.state,
            currentConnectionEpoch: reconnectedEpoch,
            now: now,
            requiresFreshMetricTruth: true
        )
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.blockReason, .notRead)
    }

    func testExistingSafetyGatesStillBlockWithFreshMetricTruth() {
        let state = truth(units: .metric)

        XCTAssertFalse(ControllerUnitsSafetyPolicy.allowsStart(
            path: .hrControl,
            existingGatesAllowStart: false,
            state: state,
            currentConnectionEpoch: epoch,
            now: now,
            requiresFreshMetricTruth: true
        ))
        XCTAssertTrue(ControllerUnitsSafetyPolicy.allowsStart(
            path: .hrControl,
            existingGatesAllowStart: true,
            state: state,
            currentConnectionEpoch: epoch,
            now: now,
            requiresFreshMetricTruth: true
        ))
    }

    func testNonLegacyProtocolsRemainSubjectOnlyToExistingGates() {
        XCTAssertTrue(ControllerUnitsSafetyPolicy.allowsStart(
            path: .hrControl,
            existingGatesAllowStart: true,
            state: .disconnected,
            currentConnectionEpoch: nil,
            now: now,
            requiresFreshMetricTruth: false
        ))
        XCTAssertFalse(ControllerUnitsSafetyPolicy.allowsStart(
            path: .hrControl,
            existingGatesAllowStart: false,
            state: .disconnected,
            currentConnectionEpoch: nil,
            now: now,
            requiresFreshMetricTruth: false
        ))
    }

    private func evaluate(
        path: ControllerAutomatedMotionPath = .hrControl,
        state: ControllerUnitsTruth
    ) -> ControllerUnitsGateDecision {
        ControllerUnitsSafetyPolicy.evaluate(
            path: path,
            state: state,
            currentConnectionEpoch: epoch,
            now: now,
            requiresFreshMetricTruth: true
        )
    }

    private func truth(
        units: ControllerUnits,
        status: ControllerUnitsTruthStatus = .valid,
        observedAt: Date? = nil
    ) -> ControllerUnitsTruth {
        ControllerUnitsTruth(
            connectionEpoch: epoch,
            units: units,
            status: status,
            observedAt: observedAt ?? now.addingTimeInterval(-1),
            rawHex: "F8 A6 ... FD"
        )
    }

    private func notReadTruth() -> ControllerUnitsTruth {
        ControllerUnitsTruth(
            connectionEpoch: epoch,
            units: .unknown,
            status: .notRead,
            observedAt: nil,
            rawHex: nil
        )
    }

    private func validParams(unit: UInt8) -> BLETransportCodec.WalkingPadParams {
        BLETransportCodec.WalkingPadParams(
            maxSpeedRawTenths: 60,
            startSpeedRawTenths: 20,
            rawControllerUnit: unit,
            checksumOk: true,
            rawHex: "F8 A6 ... FD"
        )
    }
}
