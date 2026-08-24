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

    func testPhysicalTwentyByteMetricResponseAllowsBothCoveredAutomatedPaths() throws {
        let frame = Data([
            0xF8, 0xA6, 0x00, 0x00, 0x00, 0x00, 0x00, 0x78, 0x08, 0x00,
            0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x28, 0xFD,
        ])
        let params = try XCTUnwrap(BLETransportCodec.parseWalkingPadParams(frame))
        var tracker = ControllerUnitsTruthTracker()
        tracker.beginConnection(epoch: epoch)
        tracker.record(params, for: epoch, at: now)

        for path in ControllerAutomatedMotionPath.allCases {
            let decision = evaluate(path: path, state: tracker.state)
            XCTAssertTrue(decision.allowed, "Expected physical metric evidence to allow \(path.rawValue)")
            XCTAssertNil(decision.blockReason)
        }
    }

    func testTwentyByteUnknownAndInvalidChecksumResponsesFailClosedForBothPaths() throws {
        let unknownBytes = [UInt8](physicalFrame(unit: 2))
        var invalidChecksumBytes = [UInt8](physicalFrame(unit: 0))
        invalidChecksumBytes[18] ^= 0x01

        for (frame, expectedReason) in [
            (Data(unknownBytes), ControllerUnitsBlockReason.unknown),
            (Data(invalidChecksumBytes), ControllerUnitsBlockReason.invalidChecksum),
        ] {
            let params = try XCTUnwrap(BLETransportCodec.parseWalkingPadParams(frame))
            var tracker = ControllerUnitsTruthTracker()
            tracker.beginConnection(epoch: epoch)
            tracker.record(params, for: epoch, at: now)

            for path in ControllerAutomatedMotionPath.allCases {
                let decision = evaluate(path: path, state: tracker.state)
                XCTAssertFalse(decision.allowed)
                XCTAssertEqual(decision.blockReason, expectedReason)
            }
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

    func testHeartRateAffordanceStaysAvailableWhileUnitsGateFailsClosed() {
        XCTAssertTrue(
            HRDomainService.heartRateStartAffordanceAvailable(
                treadmillConnected: true,
                currentHeartRateVisible: true
            )
        )
        let runtimePrerequisitesAllowStart = HRDomainService
            .heartRateRuntimePrerequisitesAllowStart(
                treadmillConnected: true,
                watchReachable: true,
                currentHeartRateVisible: true
            )
        XCTAssertTrue(runtimePrerequisitesAllowStart)

        XCTAssertFalse(
            ControllerUnitsSafetyPolicy.allowsStart(
                path: .hrControl,
                existingGatesAllowStart: runtimePrerequisitesAllowStart,
                state: notReadTruth(),
                currentConnectionEpoch: epoch,
                now: now,
                requiresFreshMetricTruth: true
            )
        )
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

    func testExpiredMetricAutoRefreshRestoresStartEligibilityWithoutReconnect() {
        var tracker = ControllerUnitsTruthTracker()
        tracker.beginConnection(epoch: epoch)
        tracker.record(validParams(unit: 0), for: epoch, at: now)
        XCTAssertTrue(evaluate(state: tracker.state).allowed)

        let afterTTL = now.addingTimeInterval(ControllerUnitsSafetyPolicy.freshnessInterval + 1)
        let staleDecision = ControllerUnitsSafetyPolicy.evaluate(
            path: .hrControl,
            state: tracker.state,
            currentConnectionEpoch: epoch,
            now: afterTTL,
            requiresFreshMetricTruth: true
        )
        XCTAssertFalse(staleDecision.allowed)
        XCTAssertEqual(staleDecision.blockReason, .stale)

        let refreshDecision = ControllerUnitsRefreshPolicy.blockedStartRefresh(
            existingGatesAllowStart: true,
            isHrControlRunning: false,
            transportReady: true,
            unitsDecision: staleDecision,
            lastQueryAt: now.addingTimeInterval(-ControllerUnitsRefreshPolicy.minimumQueryInterval),
            now: afterTTL
        )
        XCTAssertEqual(refreshDecision.trigger, .gateBlockedAuto)

        let refreshedAt = afterTTL.addingTimeInterval(1)
        tracker.record(validParams(unit: 0), for: epoch, at: refreshedAt)
        let refreshedDecision = ControllerUnitsSafetyPolicy.evaluate(
            path: .hrControl,
            state: tracker.state,
            currentConnectionEpoch: epoch,
            now: refreshedAt,
            requiresFreshMetricTruth: true
        )
        XCTAssertTrue(refreshedDecision.allowed)
        XCTAssertEqual(tracker.state.connectionEpoch, epoch)
    }

    func testAutoRefreshRequiresOtherStartGatesAndPreservesQueryThrottle() {
        let staleDecision = evaluate(
            state: truth(
                units: .metric,
                observedAt: now.addingTimeInterval(-ControllerUnitsSafetyPolicy.freshnessInterval - 1)
            )
        )

        XCTAssertFalse(ControllerUnitsRefreshPolicy.blockedStartRefresh(
            existingGatesAllowStart: false,
            isHrControlRunning: false,
            transportReady: true,
            unitsDecision: staleDecision,
            lastQueryAt: nil,
            now: now
        ).shouldRequest)
        XCTAssertFalse(ControllerUnitsRefreshPolicy.blockedStartRefresh(
            existingGatesAllowStart: true,
            isHrControlRunning: false,
            transportReady: true,
            unitsDecision: staleDecision,
            lastQueryAt: now.addingTimeInterval(-ControllerUnitsRefreshPolicy.minimumQueryInterval + 0.001),
            now: now
        ).shouldRequest)
        XCTAssertTrue(ControllerUnitsRefreshPolicy.blockedStartRefresh(
            existingGatesAllowStart: true,
            isHrControlRunning: false,
            transportReady: true,
            unitsDecision: staleDecision,
            lastQueryAt: now.addingTimeInterval(-ControllerUnitsRefreshPolicy.minimumQueryInterval),
            now: now
        ).shouldRequest)
    }

    func testNotReadAutoRefreshesButInvalidAndImperialTruthDoNot() {
        XCTAssertTrue(ControllerUnitsRefreshPolicy.blockedStartRefresh(
            existingGatesAllowStart: true,
            isHrControlRunning: false,
            transportReady: true,
            unitsDecision: evaluate(state: notReadTruth()),
            lastQueryAt: nil,
            now: now
        ).shouldRequest)
        XCTAssertFalse(ControllerUnitsRefreshPolicy.blockedStartRefresh(
            existingGatesAllowStart: true,
            isHrControlRunning: false,
            transportReady: true,
            unitsDecision: evaluate(state: truth(units: .metric, status: .invalidChecksum)),
            lastQueryAt: nil,
            now: now
        ).shouldRequest)
        XCTAssertFalse(ControllerUnitsRefreshPolicy.blockedStartRefresh(
            existingGatesAllowStart: true,
            isHrControlRunning: false,
            transportReady: true,
            unitsDecision: evaluate(state: truth(units: .imperial)),
            lastQueryAt: nil,
            now: now
        ).shouldRequest)
    }

    func testInitialQueryWaitsForNotificationReadyTransport() {
        XCTAssertFalse(ControllerUnitsRefreshPolicy.initialQuery(
            transportReady: false,
            lastQueryAt: nil,
            now: now
        ).shouldRequest)
        XCTAssertEqual(ControllerUnitsRefreshPolicy.initialQuery(
            transportReady: true,
            lastQueryAt: nil,
            now: now
        ).trigger, .connectionReady)
    }

    func testActiveWorkoutRefreshUsesIdleWindowsWithoutChangingMotionGate() {
        XCTAssertEqual(ControllerUnitsSafetyPolicy.freshnessInterval, 30)
        XCTAssertEqual(ControllerUnitsRefreshPolicy.activeWorkoutQueryInterval, 20)
        let gateBefore = evaluate(state: truth(units: .metric))
        var lastQueryAt: Date? = now
        var refreshSeconds: [Int] = []

        for second in 1...1_800 {
            let remainder = second % 10
            let queueIdle = remainder >= 2
            let lead = remainder == 0 ? 0 : 10 - remainder
            let tick = now.addingTimeInterval(TimeInterval(second))
            let decision = ControllerUnitsRefreshPolicy.activeWorkoutRefresh(
                isHrControlRunning: true,
                transportReady: true,
                motionQueueIdle: queueIdle,
                secondsUntilNextScheduledMotion: lead,
                lastQueryAt: lastQueryAt,
                now: tick
            )
            if decision.shouldRequest {
                XCTAssertEqual(decision.trigger, .activeWorkoutIdleWindow)
                refreshSeconds.append(second)
                lastQueryAt = tick
            }
        }
        let gateAfter = evaluate(state: truth(units: .metric))

        XCTAssertEqual(refreshSeconds.first, 22)
        XCTAssertEqual(refreshSeconds.last, 1_782)
        XCTAssertEqual(refreshSeconds.count, 89)
        XCTAssertTrue(zip(refreshSeconds, refreshSeconds.dropFirst()).allSatisfy {
            $1 - $0 == 20
        })
        XCTAssertEqual(gateAfter, gateBefore)
    }

    func testActiveWorkoutRefreshNeverOccupiesMotionSpacingOrImmediateLeadWindow() {
        let dueAt = now.addingTimeInterval(-20)
        for (queueIdle, lead) in [(false, 10), (true, 2), (true, 1), (true, 0)] {
            XCTAssertFalse(ControllerUnitsRefreshPolicy.activeWorkoutRefresh(
                isHrControlRunning: true,
                transportReady: true,
                motionQueueIdle: queueIdle,
                secondsUntilNextScheduledMotion: lead,
                lastQueryAt: dueAt,
                now: now
            ).shouldRequest)
        }
        XCTAssertTrue(ControllerUnitsRefreshPolicy.activeWorkoutRefresh(
            isHrControlRunning: true,
            transportReady: true,
            motionQueueIdle: true,
            secondsUntilNextScheduledMotion: 3,
            lastQueryAt: dueAt,
            now: now
        ).shouldRequest)
    }

    func testResponseContextRejectsPeripheralEpochAndCharacteristicChanges() {
        final class CharacteristicToken {}
        let currentCharacteristic = CharacteristicToken()
        let staleCharacteristic = CharacteristicToken()
        let context = ControllerUnitsResponseContext(
            peripheralID: epoch,
            connectionEpoch: epoch,
            notifyCharacteristicID: ObjectIdentifier(currentCharacteristic)
        )

        XCTAssertTrue(context.matches(
            currentPeripheralID: epoch,
            currentConnectionEpoch: epoch,
            currentNotifyCharacteristicID: ObjectIdentifier(currentCharacteristic)
        ))
        XCTAssertFalse(context.matches(
            currentPeripheralID: UUID(),
            currentConnectionEpoch: epoch,
            currentNotifyCharacteristicID: ObjectIdentifier(currentCharacteristic)
        ))
        XCTAssertFalse(context.matches(
            currentPeripheralID: epoch,
            currentConnectionEpoch: UUID(),
            currentNotifyCharacteristicID: ObjectIdentifier(currentCharacteristic)
        ))
        XCTAssertFalse(context.matches(
            currentPeripheralID: epoch,
            currentConnectionEpoch: epoch,
            currentNotifyCharacteristicID: ObjectIdentifier(staleCharacteristic)
        ))
    }

    func testMalformedDiagnosticKeepsRawEvidenceByteCountAndBlockedGate() {
        let rawHex = "F8 A6 08 00 3C 00 00 00 14 00 00 00 00 00 5E"
        var tracker = ControllerUnitsTruthTracker()
        tracker.beginConnection(epoch: epoch)
        tracker.recordMalformed(rawHex: rawHex, for: epoch, at: now.addingTimeInterval(-2))

        let snapshot = ControllerUnitsDiagnosticSnapshot.capture(
            truth: tracker.state,
            currentConnectionEpoch: epoch,
            now: now,
            requiresFreshMetricTruth: true
        )

        XCTAssertEqual(snapshot.status, .malformed)
        XCTAssertEqual(snapshot.units, .unknown)
        XCTAssertEqual(snapshot.ageSeconds, 2)
        XCTAssertFalse(snapshot.isFresh)
        XCTAssertFalse(snapshot.gateAllowed)
        XCTAssertEqual(snapshot.blockReason, .malformed)
        XCTAssertTrue(snapshot.isCurrentConnection)
        XCTAssertEqual(snapshot.rawHex, rawHex)
        XCTAssertEqual(snapshot.byteCount, 15)
        XCTAssertTrue(snapshot.reportText.contains("byte_count: 15"))
        XCTAssertTrue(snapshot.reportText.contains("raw_hex: \(rawHex)"))
    }

    func testValidDiagnosticKeepsEvidenceWithoutChangingGateBehavior() {
        let rawHex = "F8 A6 08 00 3C 00 00 00 14 00 00 00 00 00 5E FD"
        var tracker = ControllerUnitsTruthTracker()
        tracker.beginConnection(epoch: epoch)
        tracker.record(
            BLETransportCodec.WalkingPadParams(
                maxSpeedRawTenths: 60,
                startSpeedRawTenths: 20,
                rawControllerUnit: 0,
                checksumOk: true,
                rawHex: rawHex
            ),
            for: epoch,
            at: now.addingTimeInterval(-1)
        )

        let snapshot = ControllerUnitsDiagnosticSnapshot.capture(
            truth: tracker.state,
            currentConnectionEpoch: epoch,
            now: now,
            requiresFreshMetricTruth: true
        )
        let existingDecision = evaluate(path: .testRun, state: tracker.state)

        XCTAssertEqual(snapshot.status, .valid)
        XCTAssertEqual(snapshot.units, .metric)
        XCTAssertTrue(snapshot.isFresh)
        XCTAssertEqual(snapshot.gateAllowed, existingDecision.allowed)
        XCTAssertEqual(snapshot.blockReason, existingDecision.blockReason)
        XCTAssertEqual(snapshot.rawHex, rawHex)
        XCTAssertEqual(snapshot.byteCount, 16)
    }

    func testPriorEpochDiagnosticCannotExposeRawEvidenceAsCurrent() {
        let priorRawHex = "F8 A6 08 00 3C 00 00 00 14 00 00 00 00 00 5E FD"
        let priorTruth = ControllerUnitsTruth(
            connectionEpoch: epoch,
            units: .metric,
            status: .valid,
            observedAt: now.addingTimeInterval(-1),
            rawHex: priorRawHex
        )
        let currentEpoch = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        let snapshot = ControllerUnitsDiagnosticSnapshot.capture(
            truth: priorTruth,
            currentConnectionEpoch: currentEpoch,
            now: now,
            requiresFreshMetricTruth: true
        )

        XCTAssertFalse(snapshot.isCurrentConnection)
        XCTAssertEqual(snapshot.status, .notRead)
        XCTAssertEqual(snapshot.units, .unknown)
        XCTAssertNil(snapshot.observedAt)
        XCTAssertNil(snapshot.ageSeconds)
        XCTAssertFalse(snapshot.isFresh)
        XCTAssertFalse(snapshot.gateAllowed)
        XCTAssertEqual(snapshot.blockReason, .notRead)
        XCTAssertNil(snapshot.rawHex)
        XCTAssertNil(snapshot.byteCount)
        XCTAssertTrue(snapshot.reportText.contains("current_connection_context: false"))
        XCTAssertTrue(snapshot.reportText.contains("raw_hex: unavailable"))
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

    private func physicalFrame(unit: UInt8) -> Data {
        var bytes: [UInt8] = [
            0xF8, 0xA6, 0x00, 0x00, 0x00, 0x00, 0x00, 0x78, 0x08, 0x00,
            0x02, 0x00, 0x00, unit, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFD,
        ]
        bytes[18] = UInt8(bytes[1..<18].reduce(UInt16(0)) { ($0 + UInt16($1)) & 0xFF })
        return Data(bytes)
    }
}
