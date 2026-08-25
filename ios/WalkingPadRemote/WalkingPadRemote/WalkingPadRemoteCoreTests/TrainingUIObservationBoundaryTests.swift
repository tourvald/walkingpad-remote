import Combine
import Foundation
import XCTest
@testable import WalkingPadCoreLogic

final class TrainingUIObservationBoundaryTests: XCTestCase {
    func testBoundaryForwardsConfiguredTrainingSignalsSynchronously() {
        let readiness = PassthroughSubject<Void, Never>()
        let heartRate = PassthroughSubject<Void, Never>()
        let treadmill = PassthroughSubject<Void, Never>()
        let timing = PassthroughSubject<Void, Never>()
        let phaseAndStop = PassthroughSubject<Void, Never>()
        let result = PassthroughSubject<Void, Never>()
        let feedback = PassthroughSubject<Void, Never>()
        let boundary = TrainingUIObservationBoundary(
            signals: [
                readiness.eraseToAnyPublisher(),
                heartRate.eraseToAnyPublisher(),
                treadmill.eraseToAnyPublisher(),
                timing.eraseToAnyPublisher(),
                phaseAndStop.eraseToAnyPublisher(),
                result.eraseToAnyPublisher(),
                feedback.eraseToAnyPublisher(),
            ]
        )
        var publications = 0
        let cancellable = boundary.objectWillChange.sink { publications += 1 }

        for signal in [
            readiness,
            heartRate,
            treadmill,
            timing,
            phaseAndStop,
            result,
            feedback,
        ] {
            signal.send()
        }

        XCTAssertEqual(publications, 7)
        withExtendedLifetime(cancellable) {}
    }

    func testUnconfiguredDiscoverySignalCannotInvalidateBoundary() {
        let training = PassthroughSubject<Void, Never>()
        let discovery = PassthroughSubject<Void, Never>()
        let boundary = TrainingUIObservationBoundary(
            signals: [training.eraseToAnyPublisher()]
        )
        var publications = 0
        let cancellable = boundary.objectWillChange.sink { publications += 1 }

        discovery.send()
        XCTAssertEqual(publications, 0)

        training.send()
        XCTAssertEqual(publications, 1)
        withExtendedLifetime(cancellable) {}
    }

    func testRepeatedAcceptedSameBPMTimestampsDoNotAddBoundaryInvalidations() {
        let heartRateSnapshot = PassthroughSubject<Void, Never>()
        let oneHertzTiming = PassthroughSubject<Void, Never>()
        let acceptedSameBPMTimestamp = PassthroughSubject<Void, Never>()
        let boundary = TrainingUIObservationBoundary(
            signals: [
                heartRateSnapshot.eraseToAnyPublisher(),
                oneHertzTiming.eraseToAnyPublisher(),
            ]
        )
        var publications = 0
        let cancellable = boundary.objectWillChange.sink { publications += 1 }

        for _ in 0..<8 {
            acceptedSameBPMTimestamp.send()
        }
        XCTAssertEqual(publications, 0)

        heartRateSnapshot.send()
        XCTAssertEqual(publications, 1)

        for _ in 0..<8 {
            acceptedSameBPMTimestamp.send()
        }
        XCTAssertEqual(publications, 1)

        oneHertzTiming.send()
        XCTAssertEqual(publications, 2)
        withExtendedLifetime(cancellable) {}
    }

    func testProductionWiringIncludesTrainingStateAndExcludesBroadManagerObservation() throws {
        let source = try String(
            contentsOf: packageRoot
                .appendingPathComponent("WalkingPadRemote/ContentView.swift"),
            encoding: .utf8
        )
        let boundaryStart = try XCTUnwrap(
            source.range(of: "private extension TrainingUIObservationBoundary")
        )
        let harnessStart = try XCTUnwrap(
            source.range(of: "#if DEBUG", range: boundaryStart.upperBound..<source.endIndex)
        )
        let wiring = String(source[boundaryStart.lowerBound..<harnessStart.lowerBound])

        for requiredPublisher in [
            "$isConnected",
            "$isTreadmillControlReady",
            "$trainingUIHeartRateSnapshot",
            "$trainingUITreadmillSpeedKmh",
            "$hrTargetBPM",
            "$hrZone1Max",
            "$hrZone2Max",
            "$hrZone3Max",
            "$hrZone4Max",
            "$hrDurationMinutes",
            "$isHrControlStartAllowed",
            "$hrControlStartBlockReasonText",
            "$isNativeHeartRatePreflightActive",
            "$isHrControlRunning",
            "$hrRemainingSeconds",
            "$hrCooldownTargetBpm",
            "$timeSec",
            "$isNativeWorkoutRecoveryActive",
            "$nativeWorkoutRecoveryStatusText",
            "$stopTruthStatusText",
            "$telemetryV2ProjectionGeneration",
            "$telemetryV2WorkoutHistoryState",
            "$telemetryV2WorkoutHistory",
            "$telemetryV2StatusText",
            "$connectErrorMessage",
            "$suggestDevicePicker",
            "$infoToastMessage",
        ] {
            XCTAssertTrue(wiring.contains(requiredPublisher), requiredPublisher)
        }
        XCTAssertFalse(wiring.contains("$discoveryUIPeripherals"))
        XCTAssertFalse(wiring.contains("heartRateFactualState.$lastValueAt"))
        XCTAssertFalse(wiring.contains("manager.objectWillChange"))
        XCTAssertTrue(source.contains("ControlSwipeView(manager: manager)"))
        XCTAssertTrue(source.contains(".equatable()"))
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
