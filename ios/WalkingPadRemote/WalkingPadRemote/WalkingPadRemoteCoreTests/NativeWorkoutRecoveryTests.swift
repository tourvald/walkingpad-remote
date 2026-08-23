import Foundation
import XCTest
@testable import WalkingPadCoreLogic

final class NativeWorkoutRecoveryTests: XCTestCase {
    func testRecoveryRequestGateAcceptsFlagExactlyOncePerSceneSession() {
        var gate = ActiveWorkoutRecoveryRequestGate()

        XCTAssertFalse(gate.shouldRequestRecovery(
            sceneSessionID: "scene-a",
            recoveryRequested: false
        ))
        XCTAssertTrue(gate.shouldRequestRecovery(
            sceneSessionID: "scene-a",
            recoveryRequested: true
        ))
        XCTAssertFalse(gate.shouldRequestRecovery(
            sceneSessionID: "scene-a",
            recoveryRequested: true
        ))
        XCTAssertTrue(gate.shouldRequestRecovery(
            sceneSessionID: "scene-b",
            recoveryRequested: true
        ))
    }

    func testRecoveryStoreAtomicallyTransitionsPreflightToCommittedAndClears() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NativeWorkoutRecoveryStore(
            fileURL: directory.appendingPathComponent("recovery.json")
        )
        let preflight = makePreflight()

        try store.save(preflight)
        XCTAssertEqual(store.load(), .record(preflight))

        let committed = makeCommitted(preflight, latency: 4)
        try store.save(committed)
        XCTAssertEqual(store.load(), .record(committed))

        let stopping = committed.stopping(
            requestedAt: preflight.acquisitionStartedAt.addingTimeInterval(60)
        )
        try store.save(stopping)
        XCTAssertEqual(store.load(), .record(stopping))

        let finishing = stopping.finishing(
            requestedAt: preflight.acquisitionStartedAt.addingTimeInterval(60)
        )
        try store.save(finishing)
        XCTAssertEqual(store.load(), .record(finishing))

        try store.clear()
        XCTAssertEqual(store.load(), .missing)
        try store.clear()
        XCTAssertEqual(store.load(), .missing)
    }

    func testCorruptRecoveryMarkerRemainsInvalidRatherThanInventingIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let store = NativeWorkoutRecoveryStore(
            fileURL: directory.appendingPathComponent("recovery.json")
        )
        try Data("not-json".utf8).write(to: store.fileURL, options: .atomic)

        XCTAssertEqual(store.load(), .invalid)
    }

    func testOnlyExactlyLinkedCommittedIndoorWalkingSessionRestores() {
        let preflight = makePreflight()
        let committed = makeCommitted(preflight, latency: 3)

        XCTAssertEqual(
            NativeWorkoutRecoveryPolicy.resolve(
                loadResult: .record(committed),
                recoveredSessionStartedAt: preflight.acquisitionStartedAt,
                recoveredCollectionStarted: true,
                configurationIsIndoorWalking: true
            ),
            .restore(committed)
        )
        let finishing = committed.finishing(
            requestedAt: preflight.acquisitionStartedAt.addingTimeInterval(60)
        )
        XCTAssertEqual(
            NativeWorkoutRecoveryPolicy.resolve(
                loadResult: .record(finishing),
                recoveredSessionStartedAt: preflight.acquisitionStartedAt,
                recoveredCollectionStarted: true,
                configurationIsIndoorWalking: true
            ),
            .finish(finishing)
        )
        let stopping = committed.stopping(
            requestedAt: preflight.acquisitionStartedAt.addingTimeInterval(60)
        )
        XCTAssertEqual(
            NativeWorkoutRecoveryPolicy.resolve(
                loadResult: .record(stopping),
                recoveredSessionStartedAt: preflight.acquisitionStartedAt,
                recoveredCollectionStarted: true,
                configurationIsIndoorWalking: true
            ),
            .restore(stopping)
        )
        for loadResult in [
            NativeWorkoutRecoveryLoadResult.missing,
            .invalid,
            .record(preflight),
        ] {
            XCTAssertEqual(
                NativeWorkoutRecoveryPolicy.resolve(
                    loadResult: loadResult,
                    recoveredSessionStartedAt: preflight.acquisitionStartedAt,
                    recoveredCollectionStarted: true,
                    configurationIsIndoorWalking: true
                ),
                .discard
            )
        }
        XCTAssertEqual(
            NativeWorkoutRecoveryPolicy.resolve(
                loadResult: .record(committed),
                recoveredSessionStartedAt: preflight.acquisitionStartedAt
                    .addingTimeInterval(10),
                recoveredCollectionStarted: true,
                configurationIsIndoorWalking: true
            ),
            .discard
        )
        XCTAssertEqual(
            NativeWorkoutRecoveryPolicy.resolve(
                loadResult: .record(committed),
                recoveredSessionStartedAt: preflight.acquisitionStartedAt,
                recoveredCollectionStarted: true,
                configurationIsIndoorWalking: false
            ),
            .discard
        )
        XCTAssertEqual(
            NativeWorkoutRecoveryPolicy.resolve(
                loadResult: .record(committed),
                recoveredSessionStartedAt: preflight.acquisitionStartedAt,
                recoveredCollectionStarted: false,
                configurationIsIndoorWalking: true
            ),
            .discard
        )
    }

    func testCommittedRecordPreservesFrozenTimingAndSessionIdentities() {
        let preflight = makePreflight()
        let controlledStart = preflight.acquisitionStartedAt.addingTimeInterval(2)
        let profileID = UUID()
        let legacySessionID = UUID()
        let telemetrySessionID = legacySessionID

        let committed = preflight.committed(
            controlledWorkoutStartedAt: controlledStart,
            profileID: profileID,
            legacySessionID: legacySessionID,
            telemetrySessionID: telemetrySessionID
        )

        XCTAssertEqual(committed.targetBPM, 145)
        XCTAssertEqual(committed.durationMinutes, 30)
        XCTAssertEqual(committed.controlledWorkoutStartedAt, controlledStart)
        XCTAssertEqual(committed.profileID, profileID)
        XCTAssertEqual(committed.legacySessionID, legacySessionID)
        XCTAssertEqual(committed.telemetrySessionID, telemetrySessionID)
        XCTAssertTrue(committed.isStructurallyValid)
    }

    func testCommittedRecordRejectsContradictoryPreflightTiming() {
        let preflight = makePreflight()
        let legacySessionID = UUID()
        let invalid = preflight.committed(
            controlledWorkoutStartedAt: preflight.acquisitionStartedAt.addingTimeInterval(
                NativeHeartRatePreflightEngine.timeoutSeconds + 1
            ),
            profileID: UUID(),
            legacySessionID: legacySessionID,
            telemetrySessionID: legacySessionID
        )

        XCTAssertFalse(invalid.isStructurallyValid)
        XCTAssertEqual(
            NativeWorkoutRecoveryPolicy.resolve(
                loadResult: .record(invalid),
                recoveredSessionStartedAt: preflight.acquisitionStartedAt,
                recoveredCollectionStarted: true,
                configurationIsIndoorWalking: true
            ),
            .discard
        )
    }

    func testCommittedRecordRejectsInventedTelemetryLinkage() {
        let preflight = makePreflight()
        let invalid = preflight.committed(
            controlledWorkoutStartedAt: preflight.acquisitionStartedAt.addingTimeInterval(2),
            profileID: UUID(),
            legacySessionID: UUID(),
            telemetrySessionID: UUID()
        )

        XCTAssertFalse(invalid.isStructurallyValid)
    }

    func testNoActiveRecoveryRequestReconcilesOnlyDurableFinishingPhase() {
        let preflight = makePreflight()
        let committed = makeCommitted(preflight, latency: 2)
        let stopping = committed.stopping(
            requestedAt: preflight.acquisitionStartedAt.addingTimeInterval(60)
        )
        let finishing = stopping.finishing(
            requestedAt: preflight.acquisitionStartedAt.addingTimeInterval(60)
        )

        XCTAssertEqual(
            NativeWorkoutRecoveryPolicy.resolveWithoutActiveRecoveryRequest(
                loadResult: .record(finishing)
            ),
            .reconcileFinished(finishing)
        )
        for loadResult in [
            NativeWorkoutRecoveryLoadResult.missing,
            .invalid,
            .record(preflight),
            .record(committed),
            .record(stopping),
        ] {
            XCTAssertEqual(
                NativeWorkoutRecoveryPolicy.resolveWithoutActiveRecoveryRequest(
                    loadResult: loadResult
                ),
                .retainFailClosed
            )
        }
    }

    private func makePreflight() -> NativeWorkoutRecoveryRecord {
        NativeWorkoutRecoveryRecord.preflight(
            appWorkoutID: UUID(),
            targetBPM: 145,
            durationMinutes: 30,
            acquisitionStartedAt: Date(timeIntervalSince1970: 10_000),
            profileID: UUID()
        )
    }

    private func makeCommitted(
        _ preflight: NativeWorkoutRecoveryRecord,
        latency: TimeInterval
    ) -> NativeWorkoutRecoveryRecord {
        let legacySessionID = UUID()
        return preflight.committed(
            controlledWorkoutStartedAt: preflight.acquisitionStartedAt.addingTimeInterval(
                latency
            ),
            profileID: UUID(),
            legacySessionID: legacySessionID,
            telemetrySessionID: legacySessionID
        )
    }
}
