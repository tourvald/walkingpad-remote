import Foundation
import XCTest
@testable import WalkingPadCoreLogic

final class ProfileErasurePolicyTests: XCTestCase {
    func testConfirmedIdentityPreservesNewActiveProfileAndSoleDeletionIsIdempotent() throws {
        let a = UUID(), b = UUID(), replacement = UUID()
        let inactive = try XCTUnwrap(ProfileErasurePolicy.selection(afterDeleting: a, from: [a, b], activeID: b))
        XCTAssertEqual(inactive.retainedIDs, [b])
        XCTAssertEqual(inactive.activeID, b)
        XCTAssertNil(inactive.replacementID)
        let sole = try XCTUnwrap(ProfileErasurePolicy.selection(afterDeleting: a, from: [a], activeID: a, makeID: { replacement }))
        XCTAssertEqual(sole.retainedIDs, [replacement])
        XCTAssertEqual(sole.activeID, replacement)
        XCTAssertNil(ProfileErasurePolicy.selection(afterDeleting: a, from: sole.retainedIDs, activeID: replacement, makeID: { XCTFail("Duplicate replacement"); return UUID() }))
    }

    func testActualRecoveryArchivesEraseOnlyConfirmedProfileAfterReopenAndRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("native_workout_recovery_v1.json")
        let owner = NativeWorkoutRecoveryStore(fileURL: file)
        let a = UUID(), b = UUID()
        var archives: [URL] = []
        for profile in [a, b] {
            let session = UUID()
            let record = NativeWorkoutRecoveryRecord.preflight(appWorkoutID: UUID(), targetBPM: 140,
                durationMinutes: 25, acquisitionStartedAt: Date(timeIntervalSince1970: 100), profileID: profile)
                .committed(controlledWorkoutStartedAt: Date(timeIntervalSince1970: 101),
                    profileID: profile, legacySessionID: session, telemetrySessionID: session)
                .finishing(requestedAt: Date(timeIntervalSince1970: 110))
            try owner.save(record)
            try owner.archiveInterrupted(record)
            archives.append(root.appendingPathComponent("interrupted_native_workout_\(record.appWorkoutID.uuidString).json"))
        }
        let bBytes = try Data(contentsOf: archives[1])
        let reopened = NativeWorkoutRecoveryStore(fileURL: file)
        try reopened.eraseInterruptedArchives(for: a)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archives[0].path))
        XCTAssertEqual(try Data(contentsOf: archives[1]), bBytes)
        try reopened.eraseInterruptedArchives(for: a)
        let corrupt = root.appendingPathComponent("interrupted_native_workout_unknown.json")
        try Data("corrupt".utf8).write(to: corrupt)
        XCTAssertThrowsError(try reopened.eraseInterruptedArchives(for: b))
        XCTAssertEqual(try Data(contentsOf: archives[1]), bBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.path))
        try FileManager.default.removeItem(at: corrupt)
        try NativeWorkoutRecoveryStore(fileURL: file).eraseInterruptedArchives(for: b)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archives[1].path))
        XCTAssertEqual(reopened.load(), .missing)
        let active = NativeWorkoutRecoveryRecord.preflight(appWorkoutID: UUID(), targetBPM: 140,
            durationMinutes: 10, acquisitionStartedAt: Date(timeIntervalSince1970: 200), profileID: b)
        try reopened.save(active)
        let activeBytes = try Data(contentsOf: file)
        XCTAssertThrowsError(try reopened.eraseInterruptedArchives(for: a))
        XCTAssertEqual(try Data(contentsOf: file), activeBytes)
    }

    func testEveryRuntimeOwnerIndependentlyBlocksErasure() {
        for index in 0..<8 {
            var values = Array(repeating: false, count: 8)
            values[index] = true
            XCTAssertFalse(ProfileErasurePolicy.permitsDeletion(
                workoutActive: values[0], recoveryOutstanding: values[1],
                preflightActive: values[2], cleanupInFlight: values[3],
                testRunActive: values[4], stopPending: values[5],
                erasureInFlight: values[6], linkageInFlight: values[7]
            ))
        }
        XCTAssertTrue(ProfileErasurePolicy.permitsDeletion(
            workoutActive: false, recoveryOutstanding: false, preflightActive: false,
            cleanupInFlight: false, testRunActive: false, stopPending: false,
            erasureInFlight: false, linkageInFlight: false
        ))
    }
}
