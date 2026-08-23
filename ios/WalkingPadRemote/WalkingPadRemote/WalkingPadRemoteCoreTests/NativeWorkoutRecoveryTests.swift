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

    func testExistingSchemaV1RecordWithoutNewOptionalFieldsStillDecodes() throws {
        let committed = makeCommitted(makePreflight(), latency: 2)
        let encoded = try JSONEncoder().encode(committed)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "plannedDurationSeconds")
        object.removeValue(forKey: "healthKitStopActivityAt")
        object.removeValue(forKey: "legacyWorkoutID")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(
            NativeWorkoutRecoveryRecord.self,
            from: legacyData
        )

        XCTAssertNil(decoded.plannedDurationSeconds)
        XCTAssertNil(decoded.healthKitStopActivityAt)
        XCTAssertNil(decoded.legacyWorkoutID)
        XCTAssertEqual(decoded.effectivePlannedDurationSeconds, 1_800)
        XCTAssertTrue(decoded.isStructurallyValid)
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
        XCTAssertEqual(committed.effectivePlannedDurationSeconds, 1_800)
        XCTAssertEqual(committed.controlledWorkoutStartedAt, controlledStart)
        XCTAssertEqual(committed.profileID, profileID)
        XCTAssertEqual(committed.legacySessionID, legacySessionID)
        XCTAssertEqual(committed.telemetrySessionID, telemetrySessionID)
        XCTAssertTrue(committed.isStructurallyValid)
    }

    func testExtendedDurationIsDurableAtExactSecondPrecision() throws {
        let preflight = makePreflight()
        let committed = makeCommitted(preflight, latency: 2)
        let extended = committed.planningDuration(seconds: 35 * 60)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NativeWorkoutRecoveryStore(
            fileURL: directory.appendingPathComponent("recovery.json")
        )

        try store.save(extended)

        XCTAssertEqual(extended.durationMinutes, 35)
        XCTAssertEqual(extended.effectivePlannedDurationSeconds, 2_100)
        XCTAssertEqual(store.load(), .record(extended))
    }

    func testLegacyWorkoutIdentitySurvivesTerminalRecoveryWithoutGuessing() {
        let committed = makeCommitted(makePreflight(), latency: 2)
        let legacyWorkoutID = UUID()
        let linked = committed.linkingLegacyWorkout(id: legacyWorkoutID)
        let finishing = linked.finishing(
            requestedAt: linked.acquisitionStartedAt.addingTimeInterval(60)
        )

        XCTAssertEqual(finishing.legacyWorkoutID, legacyWorkoutID)
        XCTAssertTrue(finishing.isStructurallyValid)
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

    func testNoActiveRecoveryRequestClearsPreflightAndReconcilesOnlyProvenFinishBoundary() {
        let preflight = makePreflight()
        let committed = makeCommitted(preflight, latency: 2)
        let stopping = committed.stopping(
            requestedAt: preflight.acquisitionStartedAt.addingTimeInterval(60)
        )
        let unfinished = stopping.finishing(
            requestedAt: preflight.acquisitionStartedAt.addingTimeInterval(60)
        )
        let stoppedAt = preflight.acquisitionStartedAt.addingTimeInterval(61)
        let finishing = unfinished.recordingHealthKitStopActivity(at: stoppedAt)

        XCTAssertEqual(
            NativeWorkoutRecoveryPolicy.resolveWithoutActiveRecoveryRequest(
                loadResult: .record(finishing)
            ),
            .reconcileFinished(finishing)
        )
        XCTAssertEqual(
            NativeWorkoutRecoveryPolicy.resolveWithoutActiveRecoveryRequest(
                loadResult: .record(preflight)
            ),
            .discardPreflight(preflight)
        )
        for loadResult in [
            NativeWorkoutRecoveryLoadResult.missing,
            .invalid,
            .record(committed),
            .record(stopping),
            .record(unfinished),
        ] {
            XCTAssertEqual(
                NativeWorkoutRecoveryPolicy.resolveWithoutActiveRecoveryRequest(
                    loadResult: loadResult
                ),
                .retainFailClosed
            )
        }
    }

    func testSavedWorkoutProofRequiresExactAppOwnedStartAndDurableStopTimes() {
        let preflight = makePreflight()
        let stoppedAt = preflight.acquisitionStartedAt.addingTimeInterval(600)
        let finishing = makeCommitted(preflight, latency: 2)
            .finishing(requestedAt: stoppedAt)
            .recordingHealthKitStopActivity(at: stoppedAt)

        XCTAssertTrue(NativeWorkoutSavedProofPolicy.matches(
            record: finishing,
            workoutStartedAt: preflight.acquisitionStartedAt,
            workoutEndedAt: stoppedAt,
            isWalking: true,
            sourceMatchesApp: true
        ))
        XCTAssertFalse(NativeWorkoutSavedProofPolicy.matches(
            record: finishing,
            workoutStartedAt: preflight.acquisitionStartedAt,
            workoutEndedAt: stoppedAt.addingTimeInterval(3_600),
            isWalking: true,
            sourceMatchesApp: true
        ))
        XCTAssertFalse(NativeWorkoutSavedProofPolicy.matches(
            record: finishing,
            workoutStartedAt: preflight.acquisitionStartedAt,
            workoutEndedAt: stoppedAt,
            isWalking: true,
            sourceMatchesApp: false
        ))
    }

    func testSavedWorkoutProofRequiresExactlyOneMatchingCandidate() {
        XCTAssertNil(NativeWorkoutSavedProofPolicy.uniqueMatch(
            in: [1, 2, 3],
            matching: { _ in false }
        ))
        XCTAssertEqual(NativeWorkoutSavedProofPolicy.uniqueMatch(
            in: [1, 2, 3],
            matching: { $0 == 2 }
        ), 2)
        XCTAssertNil(NativeWorkoutSavedProofPolicy.uniqueMatch(
            in: [1, 2, 3],
            matching: { $0 >= 2 }
        ))
    }

    func testLegacyWorkoutLinkRequiresExactMissingOrSameUUIDState() {
        let expected = UUID()

        XCTAssertTrue(NativeWorkoutLegacyLinkPolicy.canLink(
            existingWorkoutUUID: nil,
            expectedWorkoutUUID: expected
        ))
        XCTAssertTrue(NativeWorkoutLegacyLinkPolicy.canLink(
            existingWorkoutUUID: expected.uuidString,
            expectedWorkoutUUID: expected
        ))
        XCTAssertFalse(NativeWorkoutLegacyLinkPolicy.canLink(
            existingWorkoutUUID: UUID().uuidString,
            expectedWorkoutUUID: expected
        ))
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
