import Foundation
import XCTest
@testable import WalkingPadCoreLogic

final class WalkingPadStatusRefreshPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_780_000_000)

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
