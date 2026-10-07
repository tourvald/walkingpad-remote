#if os(macOS)
import Foundation
import XCTest

/// Executes the production methods verbatim with dependency fixtures, without extracting a production layer.
final class TrainingResultBehaviorTests: XCTestCase {
    func testSelectedNotificationLossClosesTailWithoutChangingCallbackGuards() throws {
        let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("WalkingPadRemote/BluetoothManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let handler = try declaration("func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor", in: source)
        let program = Self.notificationPrefix + "\n" + handler + "\n" + Self.notificationDriver
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("NotificationBoundary.swift")
        let binary = directory.appendingPathComponent("notification-boundary")
        try program.write(to: file, atomically: true, encoding: .utf8)
        try execute(URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["swiftc", file.path, "-o", binary.path], directory: directory)
        try execute(binary, arguments: [], directory: directory)
    }

    func testProductionResultAcceptanceMatrix() throws {
        let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("WalkingPadRemote/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let methods = [
            "beginTrainingPresentationSession()", "finishTrainingPresentationSession()",
            "finishTrainingPresentationAfterRecovery(_ isRecovering: Bool)",
            "resolveTrainingResultIfPossible()", "resolveTerminalTelemetryFailureIfNeeded(_ status: String)",
            "showUnavailableTrainingResult(", "clearTrainingResultPresentation()"
        ].map { "private func " + $0 }
        let production = try methods.map { signature in
            try declaration(signature, in: source).replacingOccurrences(of: "private func", with: "func")
        }.joined(separator: "\n")
        let profileHook = try declaration(".onChange(of: manager.activeUserProfileID)", in:
            String(source[source.range(of: "private struct ControlSwipeView:")!.lowerBound...]))
        let profileBody = String(profileHook[profileHook.range(of: " in\n")!.upperBound...].dropLast())
        let program = Self.prefix + "\n" + production + "\nfunc profileDidChange() {\n" + profileBody
            + "\n}\n" + Self.driver
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ResultFlow.swift")
        let binary = directory.appendingPathComponent("result-flow")
        try program.write(to: file, atomically: true, encoding: .utf8)
        try execute(URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["swiftc", file.path, "-o", binary.path], directory: directory)
        try execute(binary, arguments: [], directory: directory)
    }

    func testFailedFirstStopWriteIsRecordedBeforeTailClose() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("WalkingPadRemote")
        let source = try String(contentsOf: app.appendingPathComponent("BluetoothManager.swift"), encoding: .utf8)
        let lifecycle = try String(contentsOf: app.appendingPathComponent("StopObservationService.swift"), encoding: .utf8)
        let write = try declaration("private func performWrite(", in: source)
        let blockedWrite = String(write[..<write.range(of: "        let type: CBCharacteristicWriteType")!.lowerBound]) + "        return []\n}"
        let finish = try declaration("private func finishStopObservation(", in: source)
        let notSent = try declaration("private func markInitialStopCommandNotSent(", in: source)
        let queue = try declaration("private func processCommandQueue()", in: source)
        let routingStart = queue.range(of: "            for evidence in postWriteTelemetry {")!.lowerBound
        var routingEnd = routingStart
        var depth = 0
        while routingEnd < queue.endIndex {
            let character = queue[routingEnd]
            if character == "}" && depth == 0 { break }
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            routingEnd = queue.index(after: routingEnd)
        }
        let routing = String(queue[routingStart..<routingEnd])
        let program = lifecycle + "\n" + Self.ownerPrefix + "\n" + [blockedWrite, finish, notSent].map { $0.replacingOccurrences(of: "private func", with: "func") }.joined(separator: "\n")
            + "\nfunc route(_ postWriteTelemetry: [TreadmillTelemetryEvidence]) { let lostEntries: [Int] = [];\n"
            + routing + "\n}\n" + Self.ownerDriver
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("StopDelivery.swift")
        let binary = directory.appendingPathComponent("stop-delivery")
        try program.write(to: file, atomically: true, encoding: .utf8)
        try execute(URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["swiftc", file.path, "-o", binary.path], directory: directory)
        try execute(binary, arguments: [], directory: directory)
    }

    private func declaration(_ signature: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: signature)?.lowerBound)
        var cursor = try XCTUnwrap(source[start...].firstIndex(of: "{"))
        var depth = 0
        repeat {
            if source[cursor] == "{" { depth += 1 }
            if source[cursor] == "}" { depth -= 1 }
            cursor = source.index(after: cursor)
        } while depth > 0 && cursor < source.endIndex
        XCTAssertEqual(depth, 0)
        return String(source[start..<cursor])
    }

    private func execute(_ binary: URL, arguments: [String], directory: URL) throws {
        let log = directory.appendingPathComponent(UUID().uuidString + ".log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertEqual(process.terminationStatus, 0, text)
    }

    private static let notificationPrefix = #"""
    import Foundation
    final class CBPeripheral { let identifier = UUID() }
    final class CBCharacteristic { var isNotifying = true; let uuid: String; init(_ uuid: String) { self.uuid = uuid } }
    enum ProtocolKind { case walkingPad, ftms, fitShow }
    final class Capture {
     var closures = 0
     func invalidateStopTail() { closures += 1 }
    }
    final class Owner {
     let connectedPeripheral: CBPeripheral? = CBPeripheral()
     var connectedPeripheralId: UUID? { connectedPeripheral?.identifier }
     let notifyCharacteristic: CBCharacteristic? = CBCharacteristic("FE01")
     let commandCharacteristic: CBCharacteristic? = CBCharacteristic("2AD9")
     var treadmillProtocol = ProtocolKind.walkingPad
     let ftmsCharControlPoint = "2AD9"
     let charFE01 = "FE01"
     var notifyCharacteristicConnection: UUID? = UUID()
     var commandCharacteristicConnection: UUID? = UUID()
     let currentTreadmillControlConnection: UUID? = UUID()
     let telemetryV2Coordinator = Capture()
     var callbackIsCurrent = true
     var readinessUpdates = 0
     var unitsRequests = 0
     func isCurrentCharacteristicCallback(_ characteristic: CBCharacteristic) -> Bool { callbackIsCurrent }
     func recomputeTreadmillControlReadiness() { readinessUpdates += 1 }
     func requestInitialControllerUnitsTruthIfReady() { unitsRequests += 1 }
    """#

    private static let notificationDriver = #"""
    }
    for kind in [ProtocolKind.walkingPad, .ftms, .fitShow] {
     for controlPoint in [false, true] where !controlPoint || kind == .ftms {
      for (notifying, failed) in [(false, false), (false, true), (true, true)] {
       let owner = Owner(); owner.treadmillProtocol = kind
       let characteristic = controlPoint ? owner.commandCharacteristic! : owner.notifyCharacteristic!
       characteristic.isNotifying = notifying
       owner.peripheral(owner.connectedPeripheral!, didUpdateNotificationStateFor: characteristic,
        error: failed ? NSError(domain: "fixture", code: 1) : nil)
       precondition(owner.telemetryV2Coordinator.closures == 1)
       precondition(owner.readinessUpdates == 1 && owner.unitsRequests == 0)
       precondition(controlPoint ? owner.commandCharacteristicConnection == nil : owner.notifyCharacteristicConnection == nil)
       characteristic.isNotifying = true
       owner.peripheral(owner.connectedPeripheral!, didUpdateNotificationStateFor: characteristic, error: nil)
       precondition(owner.telemetryV2Coordinator.closures == 1, "Resubscription must not reopen or close a new tail")
       precondition(controlPoint ? owner.commandCharacteristicConnection != nil : owner.notifyCharacteristicConnection != nil)
      }
     }
    }
    for rejection in 0..<4 {
     let owner = Owner()
     let peripheral = rejection == 0 ? CBPeripheral() : owner.connectedPeripheral!
     let characteristic = rejection == 1 ? CBCharacteristic("FE01") : owner.notifyCharacteristic!
     if rejection == 2 { owner.callbackIsCurrent = false }
     characteristic.isNotifying = rejection == 3
     owner.peripheral(peripheral, didUpdateNotificationStateFor: characteristic,
      error: rejection == 3 ? nil : NSError(domain: "fixture", code: 1))
     precondition(owner.telemetryV2Coordinator.closures == 0, "Foreign, old and successful callbacks cannot close the tail")
     precondition(owner.notifyCharacteristicConnection != nil)
     precondition(owner.readinessUpdates == (rejection == 3 ? 1 : 0))
     precondition(owner.unitsRequests == (rejection == 3 ? 1 : 0))
    }
    print("PASS: selected notification loss/error/resume and callback boundaries")
    """#

    private static let prefix = #"""
    import Foundation
    typealias SessionID = String
    struct TrainingDistanceReading {}
    struct TrainingSessionPresentationAnchor { let sessionID: SessionID?; let profileID: UUID?; let distanceStart: TrainingDistanceReading? }
    struct PendingTrainingResult { let sessionID: SessionID; let profileID: UUID; let distanceKilometres: Double? }
    enum Origin { case nativeV2, legacy }
    struct WorkoutHistoryProjection { var id: String; var origin: Origin = .nativeV2 }
    struct ResolvedTrainingResult { let projection: WorkoutHistoryProjection; let distanceKilometres: Double? }
    enum HistoryState { case loaded, loading, failed }
    enum SummaryState { case ready, processing, failed }
    final class Manager {
     var activeTelemetryV2SessionID: SessionID? = "A"
     var activeTelemetryV2ProfileID: UUID? = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
     var activeUserProfileID: UUID? = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
     var isHrControlRunning = false
     var isNativeWorkoutRecoveryActive = false
     var shouldPresentActiveWorkout = false
     var telemetryV2StatusText = "idle"
     var telemetryV2WorkoutHistoryState = HistoryState.loaded
     var telemetryV2WorkoutHistory: [WorkoutHistoryProjection] = []
     var outcomes: [SessionID: SummaryState] = [:]
     func terminalAnalysisFailed(sessionID: SessionID) -> Bool { outcomes[sessionID] == .failed }
     func summaryAnalysisState(for projection: WorkoutHistoryProjection) -> SummaryState { outcomes[String(projection.id.dropFirst("native:".count))] ?? .processing }
    }
    final class Harness {
     let manager = Manager()
     var sessionPresentationAnchor: TrainingSessionPresentationAnchor?
     var pendingTrainingResult: PendingTrainingResult?
     var resolvedTrainingResult: ResolvedTrainingResult?
     var trainingResultError: String?
     func currentFactualDistanceReading() -> TrainingDistanceReading? { nil }
     func factualSessionDistanceKilometres(from: TrainingDistanceReading?, to: TrainingDistanceReading?) -> Double? { nil }
    """#

    private static let driver = #"""
    }
    func check(_ condition: @autoclosure () -> Bool, _ name: String) { precondition(condition(), name); print("PASS: \(name)") }
    let h = Harness()
    h.beginTrainingPresentationSession(); h.finishTrainingPresentationSession()
    check(h.pendingTrainingResult?.sessionID == "A", "Original exact session")
    h.manager.telemetryV2WorkoutHistory = [.init(id:"native:B"), .init(id:"native:C")]
    h.manager.outcomes = ["B":.ready,"C":.ready]
    h.resolveTrainingResultIfPossible()
    check(h.resolvedTrainingResult == nil && h.trainingResultError == nil, "Multiple unrelated projections and missing current page wait")
    h.manager.telemetryV2WorkoutHistory.append(.init(id:"native:A")); h.manager.outcomes["A"] = .ready
    h.resolveTrainingResultIfPossible()
    check(h.resolvedTrainingResult?.projection.id == "native:A", "Exact final success while visible")
    h.manager.outcomes["A"] = .failed; h.resolveTrainingResultIfPossible()
    check(h.resolvedTrainingResult == nil && h.trainingResultError != nil, "Actual exact failure while visible")
    h.clearTrainingResultPresentation(); h.manager.outcomes["A"] = .ready; h.resolveTrainingResultIfPossible()
    check(h.resolvedTrainingResult == nil && h.trainingResultError == nil, "Dismissal before late success")
    h.manager.outcomes["A"] = .failed; h.resolveTrainingResultIfPossible(); h.resolveTerminalTelemetryFailureIfNeeded("unavailable")
    check(h.resolvedTrainingResult == nil && h.trainingResultError == nil, "Dismissal before late failure")
    h.manager.activeTelemetryV2SessionID = "B"; h.manager.shouldPresentActiveWorkout = true; h.beginTrainingPresentationSession()
    h.manager.outcomes["A"] = .ready; h.resolveTrainingResultIfPossible(); h.manager.outcomes["A"] = .failed; h.resolveTrainingResultIfPossible()
    check(h.sessionPresentationAnchor?.sessionID == "B" && h.resolvedTrainingResult == nil && h.trainingResultError == nil, "Old completion cannot replace a new active workout")
    h.manager.shouldPresentActiveWorkout = false; h.finishTrainingPresentationSession(); h.resolveTrainingResultIfPossible()
    check(h.resolvedTrainingResult?.projection.id == "native:B", "New workout uses its own result")
    h.manager.activeUserProfileID = UUID(); h.profileDidChange(); h.resolveTrainingResultIfPossible()
    check(h.pendingTrainingResult == nil && h.resolvedTrainingResult == nil && h.trainingResultError == nil, "Profile switch clears presentation")
    let missing = Harness(); missing.manager.activeTelemetryV2SessionID = nil; missing.beginTrainingPresentationSession(); missing.finishTrainingPresentationSession()
    check(missing.pendingTrainingResult == nil && missing.trainingResultError != nil, "Missing native identity fails closed")
    let recovery = Harness(); recovery.beginTrainingPresentationSession(); recovery.manager.isNativeWorkoutRecoveryActive = true; recovery.finishTrainingPresentationSession()
    check(recovery.sessionPresentationAnchor != nil && recovery.pendingTrainingResult == nil, "Actual recovery retains product boundary")
    recovery.finishTrainingPresentationAfterRecovery(true)
    check(recovery.pendingTrainingResult == nil, "Active recovery callback cannot present completion")
    recovery.manager.isNativeWorkoutRecoveryActive = false; recovery.manager.isHrControlRunning = true
    recovery.finishTrainingPresentationAfterRecovery(false)
    check(recovery.pendingTrainingResult == nil, "Recovery callback cannot replace an active workout")
    recovery.manager.isHrControlRunning = false; recovery.finishTrainingPresentationAfterRecovery(false)
    check(recovery.pendingTrainingResult?.sessionID == "A", "Recovery completion enters processing")
    recovery.clearTrainingResultPresentation(); recovery.finishTrainingPresentationAfterRecovery(false)
    check(recovery.pendingTrainingResult == nil && recovery.trainingResultError == nil, "Repeated recovery completion cannot reopen a dismissed result")
    let early = Harness(); early.manager.telemetryV2WorkoutHistory=[.init(id:"native:A")]; early.manager.outcomes["A"] = .ready; early.beginTrainingPresentationSession(); early.finishTrainingPresentationSession()
    check(early.resolvedTrainingResult?.projection.id == "native:A", "Analysis can precede terminal UI transition")
    let wrong = Harness(); wrong.beginTrainingPresentationSession(); wrong.manager.activeUserProfileID = UUID(); wrong.finishTrainingPresentationSession()
    check(wrong.pendingTrainingResult == nil && wrong.trainingResultError == nil, "Original profile mismatch never substitutes result")
    """#

    private static let ownerPrefix = #"""
    struct TreadmillCommandEnqueuedEvidence { let commandID: String; let decisionID: String?; let connectionEpoch: UUID? }
    enum CommandFailureReason { case transportUnavailable }
    struct TreadmillCommandFailureObservation {
     let commandID: String?; let decisionID: String?; let attemptID: String?; let connectionEpoch: UUID?; let occurredAt: Date; let reason: CommandFailureReason
    }
    enum TreadmillTelemetryEvidence { case commandFailed(TreadmillCommandFailureObservation) }
    final class Capture {
     var closed = false
     var finishes = 0
     var events: [String] = []
     func stopAttemptFinalized(attemptID: UUID) { closed = true; finishes += 1; events.append("close") }
    }
    struct Unavailable { let id: UUID }
    final class Owner {
     let telemetryV2Coordinator = Capture()
     var stopObservationLifecycle: StopObservationLifecycle? = .init(attemptID: UUID(), source: "fixture",
      attemptedAt: Date(), context: .init(peripheralID: UUID(), connectionEpoch: UUID(), notificationStreamID: UUID()))
     var unavailableStopAttempt: Unavailable?
     var isTreadmillControlReady = true
     var isConnected = false
     var connectedPeripheral: Int? = 1
     var commandCharacteristic: Int? = 1
     var stopObservationCheckpointWorkItems: [DispatchWorkItem] = []
     var stopObservationFreshnessWorkItem: DispatchWorkItem?
     var stopObservationOwnsTrainingLog = false
     var stopTruthStatusText = ""
     var infoToastMessage = ""
     func nativeWorkoutStopTransportInvocationFailedIfNeeded(reason: String) {}
     func finalizeUnavailableStopAttempt(attemptID: UUID) {}
     func refreshStopTruthStatus(lifecycle: StopObservationLifecycle, evaluation: StopObservationEvaluation) {}
     func stopObservationTelemetryFields(lifecycle: StopObservationLifecycle, evaluation: StopObservationEvaluation, now: Date) -> [String: Any] { [:] }
     func logTrainingEvent(_ event: String, fields: [String: Any]) {}
     func stopTrainingStructuredLog(reason: String) {}
     func observeCurrentStopTruth(lifecycle: StopObservationLifecycle, evaluation: StopObservationEvaluation, evaluatedAt: Date) { telemetryV2Coordinator.events.append("owner-final") }
     func observeTreadmillTelemetry(_ evidence: TreadmillTelemetryEvidence, sessionID: String?) {
      precondition(!telemetryV2Coordinator.closed, "Failure must precede closure")
      if case let .commandFailed(failure) = evidence { precondition(failure.commandID == "original-stop"); telemetryV2Coordinator.events.append("failure") }
     }
     func observeCancelledTreadmillCommands(_ entries: [Int], reason: CancellationReason) {}
     enum CancellationReason { case other(String) }
     var queuedSessionID: String? = "original-session"
    """#

    private static let ownerDriver = #"""
    }
    for disconnected in [true, false] {
     let owner = Owner()
     owner.isConnected = !disconnected
     owner.commandCharacteristic = nil
     let command = TreadmillCommandEnqueuedEvidence(commandID: "original-stop", decisionID: "original-decision", connectionEpoch: UUID())
     let evidence = owner.performWrite(Data(), label: "STOP", requiresControlReadiness: true, telemetryEvidence: command)
     precondition(evidence.count == 1)
     precondition(!owner.telemetryV2Coordinator.closed, "Owner finalization must retain the known returning failure")
     owner.route(evidence)
     precondition(owner.telemetryV2Coordinator.events == ["owner-final", "failure", "close"])
     precondition(owner.telemetryV2Coordinator.finishes == 1)
     precondition(owner.stopObservationLifecycle?.finalReason == (disconnected ? "stop_command_not_sent_not_connected" : "stop_command_not_sent_characteristic_unavailable"))
    }
    """#

}
#endif
