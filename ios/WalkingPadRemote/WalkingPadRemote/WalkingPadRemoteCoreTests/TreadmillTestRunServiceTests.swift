import XCTest
@testable import WalkingPadCoreLogic

final class TreadmillTestRunServiceTests: XCTestCase {
    private let runID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    func testFixedScenarioUsesExactSemanticOrderAndCompletesAtEightyFiveSeconds() throws {
        var service = TreadmillTestRunService()
        var actions: [TreadmillTestRunService.Action] = []

        actions += try XCTUnwrap(service.start(at: 100, runID: runID)).actions
        for now in [115.0, 130.0, 145.0, 160.0, 175.0, 185.0] {
            actions += try XCTUnwrap(service.advance(at: now, expectedRunID: runID)).actions
        }

        XCTAssertEqual(actions, [
            .start(speedKmh: 1.0),
            .setSpeed(speedKmh: 2.0),
            .setSpeed(speedKmh: 3.0),
            .setSpeed(speedKmh: 2.0),
            .stop,
            .start(speedKmh: 1.5),
            .stop
        ])
        XCTAssertEqual(service.state, .completed)
        XCTAssertEqual(service.statusText, "TEST COMPLETE · STOP отправлен")
        XCTAssertFalse(service.isActive)
        XCTAssertNil(service.advance(at: 1_000, expectedRunID: runID))
    }

    func testSecondRunCannotStartWhileOneIsActive() throws {
        var service = TreadmillTestRunService()

        _ = try XCTUnwrap(service.start(at: 0, runID: runID))
        let secondStart = service.start(at: 1, runID: UUID())

        XCTAssertNil(secondStart)
        XCTAssertEqual(service.activeRunID, runID)
    }

    func testUserCancellationBecomesTerminalBeforeRequestingProductionStop() throws {
        var service = TreadmillTestRunService()
        _ = try XCTUnwrap(service.start(at: 0, runID: runID))

        let transition = try XCTUnwrap(service.cancel(
            reason: .userRequested,
            requestProductionStop: true
        ))

        XCTAssertEqual(
            transition.state,
            .cancelled(reason: .userRequested, stopRequested: true)
        )
        XCTAssertEqual(service.state, transition.state)
        XCTAssertFalse(service.isActive)
        XCTAssertEqual(transition.actions, [.stop])
        XCTAssertNil(service.advance(at: 1_000, expectedRunID: runID))
    }

    func testConnectionInvalidationCancelsWithoutLateActionOrAutomaticResume() throws {
        var service = TreadmillTestRunService()
        _ = try XCTUnwrap(service.start(at: 0, runID: runID))

        let transition = try XCTUnwrap(service.cancel(
            reason: .connectionInvalidated,
            requestProductionStop: false
        ))

        XCTAssertEqual(transition.actions, [])
        XCTAssertEqual(
            service.state,
            .cancelled(reason: .connectionInvalidated, stopRequested: false)
        )
        XCTAssertNil(service.advance(at: 15, expectedRunID: runID))
        XCTAssertNil(service.advance(at: 30, expectedRunID: UUID()))
        XCTAssertFalse(service.isActive)
    }

    func testAppInactiveCancellationPreventsFutureMotionAndRequestsStop() throws {
        var service = TreadmillTestRunService()
        _ = try XCTUnwrap(service.start(at: 0, runID: runID))
        _ = try XCTUnwrap(service.advance(at: 15, expectedRunID: runID))

        let transition = try XCTUnwrap(service.cancel(
            reason: .appInactive,
            requestProductionStop: true
        ))

        XCTAssertEqual(transition.actions, [.stop])
        XCTAssertFalse(service.isActive)
        XCTAssertNil(service.advance(at: 30, expectedRunID: runID))
        XCTAssertNil(service.advance(at: 1_000, expectedRunID: runID))
    }

    func testDelayedTickAdvancesOnlyOneStageInsteadOfCatchingUpMotionActions() throws {
        var service = TreadmillTestRunService()
        _ = try XCTUnwrap(service.start(at: 0, runID: runID))

        let delayedTransition = try XCTUnwrap(
            service.advance(at: 100, expectedRunID: runID)
        )

        XCTAssertEqual(delayedTransition.actions, [.setSpeed(speedKmh: 2.0)])
        XCTAssertNil(service.advance(at: 114.9, expectedRunID: runID))
        XCTAssertEqual(
            service.advance(at: 115, expectedRunID: runID)?.actions,
            [.setSpeed(speedKmh: 3.0)]
        )
    }

    func testStaleTimerRunIdentifierCannotAdvanceCurrentRun() throws {
        var service = TreadmillTestRunService()
        _ = try XCTUnwrap(service.start(at: 0, runID: runID))

        XCTAssertNil(service.advance(at: 15, expectedRunID: UUID()))
        XCTAssertEqual(
            service.state,
            .running(runID: runID, stage: .startAtOne)
        )
    }

    func testOrchestrationSourceHasNoBleOrRawPacketSurface() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let sourceFile = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("WalkingPadRemote/TreadmillTestRunService.swift")
        let source = try String(contentsOf: sourceFile, encoding: .utf8)

        for forbidden in ["CoreBluetooth", "CBUUID", "FE02", "writeCommand", "buildCmdPacket", "Data("] {
            XCTAssertFalse(source.contains(forbidden), "Unexpected command surface: \(forbidden)")
        }
    }
}
