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
            "$hrCooldownRemainingSeconds",
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

    func testStatisticsWiringRejectsLiveTelemetryAndPreservesEveryDisplayedDependency() throws {
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent("WalkingPadRemote/ContentView.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "    convenience init(statisticsManager manager:"))
        let end = try XCTUnwrap(source.range(of: "    convenience init(manager:", range: start.upperBound..<source.endIndex))
        let wiring = String(source[start.lowerBound..<end.lowerBound])
        let boundary = try String(
            contentsOf: packageRoot.appendingPathComponent("WalkingPadRemote/TrainingUIObservationBoundary.swift"),
            encoding: .utf8
        )
        // Compile the production subscription list against controllable publishers.
        let dependencies = [
            "activeUserProfileID", "telemetryV2WorkoutHistory", "telemetryV2WorkoutHistoryState",
            "telemetryV2WorkoutHistoryHasMore", "telemetryV2Statistics", "telemetryV2StatisticsState",
            "telemetryV2ProjectionGeneration", "zonePlanMinutes", "hrZone1Max", "hrZone2Max",
            "hrZone3Max", "hrZone4Max",
        ]
        let declarations = (dependencies + ["timeSec", "speedKmh", "hrRemainingSeconds"])
            .map { "@Published var \($0) = 0" }.joined(separator: "\n")
        let checks = dependencies.map { name in
            """
            previous = updates
            manager.\(name) += 1
            precondition(updates == previous + 1, "Missing \(name) update")
            """
        }.joined(separator: "\n")
        let program = """
        import Foundation
        \(boundary)
        final class BluetoothManager: ObservableObject { \(declarations) }
        extension TrainingUIObservationBoundary { \(wiring) }
        let manager = BluetoothManager()
        let boundary = TrainingUIObservationBoundary(statisticsManager: manager)
        var updates = 0
        var broadUpdates = 0
        var previous = 0
        let narrow = boundary.objectWillChange.sink { updates += 1 }
        let broad = manager.objectWillChange.sink { broadUpdates += 1 }
        for second in 1...600 {
            manager.timeSec = second
            manager.speedKmh = second
            manager.hrRemainingSeconds = second
        }
        precondition(broadUpdates == 1800 && updates == 0)
        \(checks)
        previous = updates
        manager.zonePlanMinutes = manager.zonePlanMinutes
        manager.hrZone1Max = manager.hrZone1Max
        precondition(updates == previous)
        print("Statistics pressure: 1800 unrelated publications -> 0; all 12 dependencies delivered")
        withExtendedLifetime((narrow, broad)) {}
        """
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = directory.appendingPathComponent("StatisticsObservation.swift")
        try program.write(to: harness, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swift", harness.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, output)
        XCTAssertTrue(output.contains("1800 unrelated publications -> 0"), output)

        let viewStart = try XCTUnwrap(source.range(of: "private struct WorkoutStatsView:"))
        let viewEnd = try XCTUnwrap(source.range(of: "private struct ZoneSummaryRow:", range: viewStart.upperBound..<source.endIndex))
        let view = String(source[viewStart.lowerBound..<viewEnd.lowerBound])
        XCTAssertFalse(view.contains("@EnvironmentObject"))
        XCTAssertTrue(source.contains("WorkoutStatsView(manager: manager)\n                .equatable()"))
        XCTAssertTrue(view.contains("UIApplication.significantTimeChangeNotification"))
        XCTAssertTrue(view.contains(".onAppear { referenceDate = Date() }"))
    }
}
