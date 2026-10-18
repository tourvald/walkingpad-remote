import Foundation
import XCTest
@testable import WalkingPadCoreLogic

final class WalkingPadStatusRefreshPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_780_000_000)

    func testDueHeartRateCannotConsumePhaseBoundaryMotionWindow() {
        for (decision, phase, expected) in [(0, 40, 40), (0, 1, 1), (0, 0, 0), (9, 1, 1), (9, 40, 9)] {
            let lead = WalkingPadStatusRefreshPolicy.motionLeadSeconds(
                decisionRemainingSeconds: decision, phaseRemainingSeconds: phase)
            XCTAssertEqual(lead, expected)
            if phase <= 1 {
                for delay in [0.0, 1.0] {
                    XCTAssertFalse(WalkingPadStatusRefreshPolicy.activeWorkoutRefresh(
                        isWorkoutOrCooldownActive: true, transportReady: true, motionQueueIdle: true,
                        secondsUntilNextScheduledMotion: lead, lastStatusQueryAt: nil,
                        lastControllerUnitsQueryAt: nil, earliestWriteDelaySeconds: delay, now: start).shouldRequest)
                }
            }
        }
    }

    func testWaitingForHeartRateAllowsStatusAndUnitsButNotBusyOrInvalidTransport() {
        for (statusAge, expected) in [(5.0, WalkingPadReadOnlyRefreshKind.status), (2.0, .controllerUnits)] {
            XCTAssertEqual(refresh(active: true, transport: true, idle: true, lead: 40,
                status: start.addingTimeInterval(-statusAge), units: start.addingTimeInterval(-20)).kind, expected)
        }
        for (active, transport, idle) in [(false, true, true), (true, false, true), (true, true, false)] {
            XCTAssertFalse(refresh(active: active, transport: transport, idle: idle, lead: 40,
                status: nil, units: nil).shouldRequest)
        }
        for lead in [-1, 0, 1, 2] {
            XCTAssertFalse(refresh(active: true, transport: true, idle: true, lead: lead,
                status: nil, units: nil).shouldRequest)
        }
        for delay in [-1.0, .infinity, .nan] {
            XCTAssertFalse(WalkingPadStatusRefreshPolicy.activeWorkoutRefresh(
                isWorkoutOrCooldownActive: true, transportReady: true, motionQueueIdle: true,
                secondsUntilNextScheduledMotion: 40, lastStatusQueryAt: nil, lastControllerUnitsQueryAt: nil,
                earliestWriteDelaySeconds: delay, now: start).shouldRequest)
        }
    }

    func testProlongedHeartRateSilenceKeepsPollingAndResumedDecisionsRespectCadence() {
        var lastStatus = start
        var lastUnits = start
        var nextWriteSecond = 0
        var lastDecisionSecond = 0
        var statusSeconds = [0]
        var unitsSeconds = [0]
        var decisionSeconds: [Int] = []

        for second in 1...120 {
            let now = start.addingTimeInterval(Double(second))
            // Five-second deliveries resume after a forty-second gap.
            let sampleArrived = second == 5 || (second >= 45 && second % 5 == 0)
            let elapsed: Duration = .seconds(second - lastDecisionSecond)
            if sampleArrived && HRDomainService.heartRateDecisionIsDue(
                sampleAgeSeconds: 0, elapsedSinceLastDecision: elapsed, intervalSeconds: 9
            ) {
                lastDecisionSecond = second
                decisionSeconds.append(second)
                nextWriteSecond = second + 2
            }
            let remaining = HRDomainService.heartRateDecisionRemainingSeconds(
                elapsedSinceLastDecision: .seconds(second - lastDecisionSecond), intervalSeconds: 9)
            let decision = WalkingPadStatusRefreshPolicy.activeWorkoutRefresh(
                isWorkoutOrCooldownActive: true, transportReady: true,
                motionQueueIdle: second >= nextWriteSecond,
                secondsUntilNextScheduledMotion: WalkingPadStatusRefreshPolicy.motionLeadSeconds(
                    decisionRemainingSeconds: remaining, phaseRemainingSeconds: 121 - second),
                lastStatusQueryAt: lastStatus, lastControllerUnitsQueryAt: lastUnits, now: now)
            switch decision.kind {
            case .status:
                lastStatus = now
                statusSeconds.append(second)
                nextWriteSecond = second + 2
            case .controllerUnits:
                lastUnits = now
                unitsSeconds.append(second)
                nextWriteSecond = second + 2
            case nil: break
            }
        }

        XCTAssertEqual(decisionSeconds, [45, 55, 65, 75, 85, 95, 105, 115])
        XCTAssertGreaterThan(statusSeconds.filter { (9..<45).contains($0) }.count, 5)
        XCTAssertTrue(unitsSeconds.contains { (9..<45).contains($0) })
        let silenceStatusSeconds = statusSeconds.filter { (9..<45).contains($0) }
        XCTAssertLessThanOrEqual(zip(silenceStatusSeconds, silenceStatusSeconds.dropFirst()).map { $1 - $0 }.max() ?? 0, 5)
        XCTAssertGreaterThan(statusSeconds.filter { (45...120).contains($0) }.count, 10)
        XCTAssertLessThanOrEqual(zip(unitsSeconds, unitsSeconds.dropFirst()).map { $1 - $0 }.max() ?? 0, 30)
        XCTAssertTrue(Set(statusSeconds + unitsSeconds).isDisjoint(with: decisionSeconds))
    }

    func testStatusQueryPacketIsTheProvenReadOnlyCurrentStatusRequest() {
        XCTAssertEqual(
            BLETransportCodec.buildWalkingPadQueryStatusPacket(),
            Data([0xF7, 0xA2, 0x00, 0x00, 0xA2, 0xFD])
        )
    }

    func testRefreshRequiresActiveCurrentIdleTransportAndMotionLead() {
        let due = start.addingTimeInterval(-10)

        for decision in [
            refresh(active: false, transport: true, idle: true, lead: 10, status: due, units: due),
            refresh(active: true, transport: false, idle: true, lead: 10, status: due, units: due),
            refresh(active: true, transport: true, idle: false, lead: 10, status: due, units: due),
            refresh(active: true, transport: true, idle: true, lead: 2, status: due, units: due),
        ] {
            XCTAssertFalse(decision.shouldRequest)
        }
    }

    func testStatusRefreshHasPriorityAtFreshnessBoundaryAndUnitsStillRefresh() {
        XCTAssertEqual(
            refresh(
                active: true,
                transport: true,
                idle: true,
                lead: 8,
                status: start.addingTimeInterval(-5),
                units: start.addingTimeInterval(-20)
            ).kind,
            .status
        )
        XCTAssertEqual(
            refresh(
                active: true,
                transport: true,
                idle: true,
                lead: 8,
                status: start.addingTimeInterval(-2),
                units: start.addingTimeInterval(-20)
            ).kind,
            .controllerUnits
        )
    }

    func testThirtyOneMinuteStableWorkoutKeepsFactualCoverageAboveGate() {
        let sessionSeconds = 31 * 60
        var lastStatusQueryAt: Date?
        var lastUnitsQueryAt = start
        var nextWriteAllowedAt = start
        var observationSeconds: [Int] = []
        var unitsQuerySeconds: [Int] = []

        for second in 1...sessionSeconds {
            let now = start.addingTimeInterval(TimeInterval(second))
            let remainder = second % 10
            let motionLead = remainder == 0 ? 10 : 10 - remainder
            let scheduledMotion = remainder == 0
            if scheduledMotion {
                nextWriteAllowedAt = now.addingTimeInterval(2)
            }
            let decision = WalkingPadStatusRefreshPolicy.activeWorkoutRefresh(
                isWorkoutOrCooldownActive: true,
                transportReady: true,
                motionQueueIdle: !scheduledMotion && nextWriteAllowedAt <= now,
                secondsUntilNextScheduledMotion: motionLead,
                lastStatusQueryAt: lastStatusQueryAt,
                lastControllerUnitsQueryAt: lastUnitsQueryAt,
                now: now
            )
            switch decision.kind {
            case .status:
                lastStatusQueryAt = now
                observationSeconds.append(second) // A real F8 A2 response is received.
                nextWriteAllowedAt = now.addingTimeInterval(2)
            case .controllerUnits:
                lastUnitsQueryAt = now
                unitsQuerySeconds.append(second)
                nextWriteAllowedAt = now.addingTimeInterval(2)
            case nil:
                break
            }
        }

        let coveredSeconds = (0..<sessionSeconds).filter { second in
            observationSeconds.last(where: { $0 <= second }).map {
                second - $0 < 5
            } ?? false
        }.count
        let coverage = Double(coveredSeconds) / Double(sessionSeconds)
        let observationGaps = zip(observationSeconds, observationSeconds.dropFirst()).map {
            $1 - $0
        }

        XCTAssertGreaterThanOrEqual(coverage, 0.90)
        XCTAssertLessThanOrEqual(observationGaps.max() ?? 0, 5)
        XCTAssertGreaterThan(unitsQuerySeconds.count, 80)
        XCTAssertLessThanOrEqual(observationSeconds.count, sessionSeconds / 2)
    }

    func testDeferredAdmissionPreservesLeadAndRejectsUnknownWriteTiming() {
        for delay in [-1.0, .infinity, .nan, 1.0] {
            let decision = WalkingPadStatusRefreshPolicy.activeWorkoutRefresh(isWorkoutOrCooldownActive: true,
                transportReady: true, motionQueueIdle: true, secondsUntilNextScheduledMotion: 3,
                lastStatusQueryAt: nil, lastControllerUnitsQueryAt: start,
                earliestWriteDelaySeconds: delay, now: start)
            XCTAssertFalse(decision.shouldRequest)
        }
        let safe = WalkingPadStatusRefreshPolicy.activeWorkoutRefresh(isWorkoutOrCooldownActive: true,
            transportReady: true, motionQueueIdle: true, secondsUntilNextScheduledMotion: 3,
            lastStatusQueryAt: nil, lastControllerUnitsQueryAt: start, earliestWriteDelaySeconds: 0.024, now: start)
        XCTAssertEqual(safe.kind, .status)
    }

    func testUnitsQueryLeavesPacedStatusSlotAndCannotTakeAgingStatusWindow() {
        for (age, lead, delay, expected) in [(4.0, 8, 0.0, WalkingPadReadOnlyRefreshKind.status as WalkingPadReadOnlyRefreshKind?),
                                          (2.0, 5, 0.0, .controllerUnits), (2.0, 5, 1.0, nil)] {
            let decision = WalkingPadStatusRefreshPolicy.activeWorkoutRefresh(isWorkoutOrCooldownActive: true,
                transportReady: true, motionQueueIdle: true, secondsUntilNextScheduledMotion: lead,
                lastStatusQueryAt: start.addingTimeInterval(-age), lastControllerUnitsQueryAt: start.addingTimeInterval(-20),
                earliestWriteDelaySeconds: delay, now: start)
            XCTAssertEqual(decision.kind, expected)
        }
    }

    private func refresh(
        active: Bool,
        transport: Bool,
        idle: Bool,
        lead: Int,
        status: Date?,
        units: Date?
    ) -> WalkingPadReadOnlyRefreshDecision {
        WalkingPadStatusRefreshPolicy.activeWorkoutRefresh(
            isWorkoutOrCooldownActive: active,
            transportReady: transport,
            motionQueueIdle: idle,
            secondsUntilNextScheduledMotion: lead,
            lastStatusQueryAt: status,
            lastControllerUnitsQueryAt: units,
            now: start
        )
    }
}
