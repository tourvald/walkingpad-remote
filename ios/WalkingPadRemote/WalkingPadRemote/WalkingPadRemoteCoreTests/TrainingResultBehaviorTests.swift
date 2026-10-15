#if os(macOS)
import Foundation
import XCTest

/// Executes the production methods verbatim with dependency fixtures, without extracting a production layer.
final class TrainingResultBehaviorTests: XCTestCase {
    func testHealthKitStopRequestedBeforeRunningIsDeliveredOnStateTransition() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("WalkingPadRemote")
        let source = try String(contentsOf: app.appendingPathComponent("IPhoneHealthKitLiveHeartRateProvider.swift"), encoding: .utf8)
        let stop = try declaration("    func stopActivity(at date: Date)", in: source)
        let pending = source.contains("    private func stopPendingActivityIfReady()")
            ? try declaration("    private func stopPendingActivityIfReady()", in: source) : ""
        let callback = try declaration("    func workoutSession(\n        _ workoutSession: HKWorkoutSession,\n        didChangeTo", in: source)
        let program = """
        import Foundation
        enum HKWorkoutSessionState { case prepared, running, paused, stopped, ended }
        enum HealthKitLiveWorkoutDriverError: Error { case operationCancelled }
        final class HKWorkoutSession {
            var state: HKWorkoutSessionState = .prepared
            var sent: [Date] = []
            func stopActivity(with date: Date) { sent.append(date) }
        }
        final class Fixture {
            var session: HKWorkoutSession? = HKWorkoutSession()
            var pendingStopDate: Date?
            var stoppedAt: Date?
            var prepareContinuation: CheckedContinuation<Void, Error>?
            var stoppedTransitionContinuation: CheckedContinuation<Date, Error>?
        \(stop)
        \(pending)
        \(callback)
        }
        @main struct Main {
            static func main() async {
                let owner = Fixture()
                let session = owner.session!
                let requested = Date(timeIntervalSince1970: 100)
                owner.stopActivity(at: requested)
                precondition(session.sent.isEmpty)
                session.state = .running
                owner.workoutSession(session, didChangeTo: .running, from: .prepared, date: requested)
                for _ in 0..<100 { await Task.yield() }
                precondition(session.sent == [requested], "Stop lost while HealthKit was starting")
                owner.workoutSession(session, didChangeTo: .running, from: .prepared, date: requested)
                for _ in 0..<100 { await Task.yield() }
                precondition(session.sent.count == 1)
                let foreign = HKWorkoutSession()
                owner.pendingStopDate = requested
                owner.workoutSession(foreign, didChangeTo: .running, from: .prepared, date: requested)
                for _ in 0..<100 { await Task.yield() }
                precondition(session.sent.count == 1)
                session.state = .paused
                owner.stopActivity(at: requested.addingTimeInterval(1))
                precondition(session.sent.count == 2)
            }
        }
        """
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("HealthKitStop.swift")
        let binary = directory.appendingPathComponent("healthkit-stop")
        try program.write(to: file, atomically: true, encoding: .utf8)
        try execute(URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["swiftc", "-parse-as-library", file.path, "-o", binary.path], directory: directory)
        try execute(binary, arguments: [], directory: directory)
    }

    func testInterruptedRecoveryRequiresExplicitNilHealthKitResultBeforeArchiving() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("WalkingPadRemote")
        let source = try String(contentsOf: app.appendingPathComponent("BluetoothManager.swift"), encoding: .utf8)
        let engine = try String(contentsOf: app.appendingPathComponent("NativeHeartRatePreflightEngine.swift"), encoding: .utf8)
        let pending = try declaration("    private func processPendingActiveWorkoutRecoveryIfPossible()", in: source)
        let nilPath = String(pending[..<pending.range(of: "        guard result.1 == nil, let recoveredSession")!.lowerBound]) + "        failed = true\n}"
        let probe = try declaration("    private func processNoActiveWorkoutRecoveryIfPossible()", in: source)
        let probePath = String(probe[..<probe.range(of: "        let resolution = NativeWorkoutRecoveryPolicy")!.lowerBound]) + "}"
        let program = engine + "\n" + """
        final class HKWorkoutSession {}
        final class Logger { func info(_ value: String) {} }
        final class HealthStore {
            var calls = 0
            var callback: ((HKWorkoutSession?, Error?) -> Void)?
            func recoverActiveWorkoutSession(_ callback: @escaping (HKWorkoutSession?, Error?) -> Void) {
                calls += 1; self.callback = callback
            }
        }
        final class Fixture {
            var didStartApplicationRuntime = true
            var pendingActiveWorkoutRecoveryResult: (HKWorkoutSession?, Error?)?
            var nativeWorkoutRecoveryLoadResult: NativeWorkoutRecoveryLoadResult = .missing
            var activeNativeWorkoutRecoveryRecord: NativeWorkoutRecoveryRecord?
            var nativeWorkoutRecoveryStore: NativeWorkoutRecoveryStore?
            var nativeHeartRateLogger = Logger()
            var infoToastMessage: String?
            var failed = false
            var unlocked = false
            var activeWorkoutRecoveryAvailability: Bool? = false
            var activeWorkoutRecoveryRequestPending = false
            var didHandleActiveWorkoutRecoveryCallback = false
            var nativeHealthKitWorkoutCommitted = false
            var nativeHeartRateFlowOwnsController = false
            var nativeHealthKitWorkoutFinishInFlight = false
            var healthStore = HealthStore()
            func completeNativeWorkoutRecoveryToIdle() { unlocked = true }
            func handleUnavailableActiveWorkoutRecovery(error: Error?) { failed = true }
            func handleActiveWorkoutRecoveryRequest() { activeWorkoutRecoveryRequestPending = true }
            func handleActiveWorkoutRecovery(session: HKWorkoutSession?, error: Error?) {
                activeWorkoutRecoveryRequestPending = false
                didHandleActiveWorkoutRecoveryCallback = true
                pendingActiveWorkoutRecoveryResult = (session, error)
                processPendingActiveWorkoutRecoveryIfPossible()
            }
        \(nilPath.replacingOccurrences(of: "private func", with: "func"))
        \(probePath.replacingOccurrences(of: "private func", with: "func"))
        }
        @main struct Main {
            static func main() async throws {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                let store = NativeWorkoutRecoveryStore(fileURL: directory.appendingPathComponent("recovery.json"))
                let preflight = NativeWorkoutRecoveryRecord.preflight(
                    appWorkoutID: UUID(), targetBPM: 140, durationMinutes: 25,
                    acquisitionStartedAt: Date(timeIntervalSince1970: 100), profileID: UUID())
                let sessionID = UUID()
                let record = preflight.committed(controlledWorkoutStartedAt: Date(timeIntervalSince1970: 101),
                    profileID: UUID(), legacySessionID: sessionID, telemetrySessionID: sessionID)
                    .finishing(requestedAt: Date(timeIntervalSince1970: 110))
                try store.save(record)
                let original = try Data(contentsOf: store.fileURL)
                let f = Fixture()
                f.nativeWorkoutRecoveryStore = store
                f.nativeWorkoutRecoveryLoadResult = .record(record)
                f.activeNativeWorkoutRecoveryRecord = record
                // Scene's false recovery flag must only trigger a probe, never clear the record.
                f.processNoActiveWorkoutRecoveryIfPossible()
                f.processNoActiveWorkoutRecoveryIfPossible()
                precondition(f.healthStore.calls == 1 && !f.unlocked)
                precondition(try! Data(contentsOf: store.fileURL) == original)
                f.healthStore.callback?(nil, NSError(domain: "unavailable", code: 1))
                for _ in 0..<100 { await Task.yield() }
                precondition(!f.unlocked && f.failed)
                precondition(try! Data(contentsOf: store.fileURL) == original)
                f.failed = false
                f.pendingActiveWorkoutRecoveryResult = (HKWorkoutSession(), nil)
                f.processPendingActiveWorkoutRecoveryIfPossible()
                precondition(!f.unlocked && f.failed)
                f.failed = false
                f.pendingActiveWorkoutRecoveryResult = (nil, nil)
                f.processPendingActiveWorkoutRecoveryIfPossible()
                precondition(f.unlocked && !f.failed && store.load() == .missing)
                let archive = directory.appendingPathComponent("interrupted_native_workout_\\(record.appWorkoutID.uuidString).json")
                precondition(try! Data(contentsOf: archive) == original)
            }
        }
        """
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("InterruptedRecovery.swift")
        let binary = directory.appendingPathComponent("interrupted-recovery")
        try program.write(to: file, atomically: true, encoding: .utf8)
        try execute(URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["swiftc", "-parse-as-library", file.path, "-o", binary.path], directory: directory)
        try execute(binary, arguments: [], directory: directory)
    }

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
            "resolveTrainingResultIfPossible()", "resolveTerminalTelemetryFailureIfNeeded(_ status: String)",
            "showUnavailableTrainingResult(", "clearTrainingResultPresentation()"
        ].map { "private func " + $0 }
        let production = try methods.map { signature in
            try declaration(signature, in: source).replacingOccurrences(of: "private func", with: "func")
        }.joined(separator: "\n")
        let profileHook = try declaration(".onChange(of: manager.activeUserProfileID)", in:
            String(source[source.range(of: "private struct ControlSwipeView:")!.lowerBound...]))
        let profileBody = String(profileHook[profileHook.range(of: " in\n")!.upperBound...].dropLast())
        let recoveryHook = try declaration(".onChange(of: manager.isNativeWorkoutRecoveryActive)", in:
            String(source[source.range(of: "private struct ControlSwipeView:")!.lowerBound...]))
        let recoveryBody = String(recoveryHook[recoveryHook.range(of: " in\n")!.upperBound...].dropLast())
        let program = Self.prefix + "\n" + production + "\nfunc profileDidChange() {\n" + profileBody
            + "\n}\nfunc recoveryDidChange(_ isRecovering: Bool) {\n" + recoveryBody + "\n}\n" + Self.driver
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

    func testCompletedStopClosesOnlyAfterCorrelatedEvidenceAndCallbackAdmission() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("WalkingPadRemote")
        let source = try String(contentsOf: app.appendingPathComponent("BluetoothManager.swift"), encoding: .utf8)
        let lifecycle = try String(contentsOf: app.appendingPathComponent("StopObservationService.swift"), encoding: .utf8)
        let methods = try ["private func finalizeCompletedStopIfReady(",
            "private func completeScheduledStopEffect(", "private func finishStopObservation("].map {
            try declaration($0, in: source).replacingOccurrences(of: "private func", with: "func")
        }.joined(separator: "\n")
        let prefix = Self.ownerPrefix.replacingOccurrences(of: "func finalizeCompletedStopIfReady() {}", with: "")
            .replacingOccurrences(of: "func logTrainingEvent(_ event: String, fields: [String: Any]) {}",
                with: "func logTrainingEvent(_ event: String, fields: [String: Any]) { telemetryV2Coordinator.events.append(event) }")
        let driver = #"""
        }
        for scenario in ["confirmed", "queued", "processing", "missing", "wrong-epoch", "wrong-protocol", "wrong-time", "new-context", "old-callback", "response-required"] {
         let owner = Owner()
         let received = Date()
         let context = StopObservationContext(peripheralID: UUID(), connectionEpoch: UUID(), notificationStreamID: UUID())
         var lifecycle = StopObservationLifecycle(attemptID: UUID(), source: "fixture", attemptedAt: received.addingTimeInterval(-4.2), context: context, scheduledStopEffects: 1)
         lifecycle.markCommandSent(at: received.addingTimeInterval(-4.2))
         lifecycle.markMotionWrite(at: received.addingTimeInterval(-2), requiresResponse: scenario == "response-required")
         _ = lifecycle.record(speedRawTenths: 0, state: 0, checksumValid: true, context: context, observedAt: received, evaluatedAt: received)
         owner.stopObservationLifecycle = lifecycle
         owner.latestTreadmillObservationEvidence = .init(protocolKind: scenario == "wrong-protocol" ? .ftms : .walkingPad,
          connectionEpoch: .init(rawValue: scenario == "wrong-epoch" ? UUID() : context.connectionEpoch), receivedAt: scenario == "wrong-time" ? received.addingTimeInterval(-1) : received)
         if scenario == "missing" { owner.latestTreadmillObservationEvidence = nil }
         if scenario == "queued" { owner.commandQueue = [1] }
         if scenario == "processing" { owner.isCommandQueueProcessing = true }
         if scenario == "new-context" { owner.changedContext = .init(peripheralID: UUID(), connectionEpoch: UUID(), notificationStreamID: UUID()) }
         owner.finalizeCompletedStopIfReady()
         precondition(!owner.telemetryV2Coordinator.closed, "Pending callback cannot be ignored")
         owner.completeScheduledStopEffect(attemptID: scenario == "old-callback" ? UUID() : lifecycle.attemptID, cancelled: true)
         if scenario == "confirmed" {
          precondition(owner.stopObservationLifecycle?.finalResult == .confirmed, "Confirmed owner did not finalize")
          precondition(owner.telemetryV2Coordinator.events == ["stop_scheduled_effect_finished", "stop_observation_finished", "owner-final", "close"], "Unexpected order: \(owner.telemetryV2Coordinator.events)")
          owner.finalizeCompletedStopIfReady()
          precondition(owner.telemetryV2Coordinator.finishes == 1)
         } else {
          precondition(!owner.telemetryV2Coordinator.closed, "Unqualified correlation/queue must keep admission open")
          precondition(owner.stopObservationLifecycle?.finalResult == nil, "Unexpected final result in \(scenario): \(String(describing: owner.stopObservationLifecycle?.finalResult))")
         }
        }
        """#
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("CompletedStop.swift")
        let binary = directory.appendingPathComponent("completed-stop")
        try [lifecycle, prefix, methods, driver].joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        try execute(URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["swiftc", file.path, "-o", binary.path], directory: directory)
        try execute(binary, arguments: [], directory: directory)
    }

    func testHistoricalStopSilenceDoesNotPresentFailureAlert() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("WalkingPadRemote")
        let source = try String(contentsOf: app.appendingPathComponent("BluetoothManager.swift"), encoding: .utf8)
        let service = try String(contentsOf: app.appendingPathComponent("StopObservationService.swift"), encoding: .utf8)
        let finish = try declaration("private func finishStopObservation(", in: source)
            .replacingOccurrences(of: "private func", with: "func")
        let driver = #"""
        }
        let owner = Owner()
        let at = Date(timeIntervalSince1970: 100)
        let context = StopObservationContext(peripheralID: UUID(), connectionEpoch: UUID(), notificationStreamID: UUID())
        var lifecycle = StopObservationLifecycle(attemptID: UUID(), source: "fixture", attemptedAt: at,
            context: context, scheduledStopEffects: 1)
        lifecycle.markCommandSent(at: at)
        lifecycle.markMotionWrite(at: at.addingTimeInterval(2))
        let received = at.addingTimeInterval(4.2)
        _ = lifecycle.record(speedRawTenths: 0, state: 0, checksumValid: true, context: context,
            observedAt: received, evaluatedAt: received)
        lifecycle.completeScheduledStopEffect()
        _ = lifecycle.finalizeTimeout(at: lifecycle.deadline)
        owner.stopObservationLifecycle = lifecycle
        owner.latestTreadmillObservationEvidence = .init(protocolKind: .walkingPad,
            connectionEpoch: .init(rawValue: context.connectionEpoch), receivedAt: received)
        owner.finishStopObservation(lifecycle: lifecycle, now: lifecycle.deadline)
        precondition(owner.infoToastMessage.isEmpty, "Freshness expiry must not claim that a proven Stop failed")
        precondition(owner.telemetryV2Coordinator.finishes == 1, "Presentation cannot change finalization")
        precondition(!lifecycle.currentEvaluation(at: lifecycle.deadline).isConfirmed, "Stale truth cannot authorize readiness")
        """#
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("StopNotification.swift")
        let binary = directory.appendingPathComponent("stop-notification")
        try [service, Self.ownerPrefix, finish, driver].joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        try execute(URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["swiftc", file.path, "-o", binary.path], directory: directory)
        try execute(binary, arguments: [], directory: directory)
    }

    func testCancelledReadOnlyEpochCannotFailReplacementStopOrUnlockItsQueue() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("WalkingPadRemote")
        let source = try String(contentsOf: app.appendingPathComponent("BluetoothManager.swift"), encoding: .utf8)
        let queue = try declaration("private func processCommandQueue()", in: source)
        let start = try XCTUnwrap(queue.range(of: "            guard self.commandQueueEpoch == epoch else {")?.lowerBound)
        let end = try XCTUnwrap(queue.range(of: "            let discardedQueries", range: start..<queue.endIndex)?.lowerBound)
        let guardBody = String(queue[start..<end])
        let program = """
        import Foundation
        final class Owner {
         var commandQueueEpoch = 2
         var isCommandQueueProcessing = true
         var failures = 0
         var continued = 0
         func nativeWorkoutStopTransportInvocationFailedIfNeeded(reason: String) { failures += 1 }
         func callback(epoch: Int, queuedReadOnlyQuery: Bool) {
        \(guardBody)
          continued += 1
         }
        }
        let oldQuery = Owner(); oldQuery.callback(epoch: 1, queuedReadOnlyQuery: true)
        precondition(oldQuery.isCommandQueueProcessing && oldQuery.failures == 0 && oldQuery.continued == 0)
        let oldMotion = Owner(); oldMotion.callback(epoch: 1, queuedReadOnlyQuery: false)
        precondition(!oldMotion.isCommandQueueProcessing && oldMotion.failures == 1 && oldMotion.continued == 0)
        let current = Owner(); current.callback(epoch: 2, queuedReadOnlyQuery: true)
        precondition(current.isCommandQueueProcessing && current.failures == 0 && current.continued == 1)
        """
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ReadOnlyEpoch.swift")
        let binary = directory.appendingPathComponent("read-only-epoch")
        try program.write(to: file, atomically: true, encoding: .utf8)
        try execute(URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["swiftc", file.path, "-o", binary.path], directory: directory)
        try execute(binary, arguments: [], directory: directory)
    }

    func testStopRetryProducerPublishesOneOriginalEnqueuePerExplicitRequest() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("WalkingPadRemote")
        let manager = try String(contentsOf: app.appendingPathComponent("BluetoothManager.swift"), encoding: .utf8)
        let sidecar = try String(contentsOf: app.appendingPathComponent("TreadmillCommandTelemetrySidecar.swift"), encoding: .utf8)
        let queue = try String(contentsOf: app.appendingPathComponent("CommandQueueService.swift"), encoding: .utf8)
        let request = manager.contains("private struct TreadmillCommandTelemetryRequest")
            ? try declaration("private struct TreadmillCommandTelemetryRequest", in: manager)
            : "private typealias TreadmillCommandTelemetryRequest = TreadmillCommandTelemetrySidecar.Request"
        let enqueue = try declaration("private func enqueueCommand(", in: manager)
        let prefix = #"""
        import Foundation
        typealias SessionID = Int
        typealias CommandID = Int
        typealias DecisionID = Int
        typealias TreadmillConnectionEpoch = Int
        enum CommandKind: Equatable { case stop; case other(String) }
        enum TreadmillProtocolKind: Equatable { case walkingPad; case ftms }
        struct TreadmillCommandEnqueuedEvidence: Equatable {
          let commandID: Int; let decisionID: Int?; let kind: CommandKind
          let protocolKind: TreadmillProtocolKind; let connectionEpoch: Int; let enqueuedAt: Date
        }
        enum TreadmillTelemetryEvidence { case commandEnqueued(TreadmillCommandEnqueuedEvidence) }
        final class Owner {
          var commandQueue: [CommandQueueService.Command] = []
          var treadmillCommandTelemetrySidecar = TreadmillCommandTelemetrySidecar()
          var treadmillTelemetryConnectionEpoch: Int? = 1
          var treadmillTelemetryProtocolKind = TreadmillProtocolKind.walkingPad
          var emitted: [(Int?, TreadmillCommandEnqueuedEvidence)] = []
          var effects: [String] = []
          func isSpeedCommandLabel(_ label: String) -> Bool { label.hasPrefix("SPEED") }
          private func treadmillCommandRequest(kind: CommandKind) -> TreadmillCommandTelemetryRequest {
            .init(sessionID: 1, commandID: 999, decisionID: nil, kind: kind)
          }
          func resetCommandQueue(reason: String, observeTelemetryImmediately: Bool) -> [TreadmillCommandTelemetrySidecar.Entry] {
            _ = CommandQueueService.clear(queue: &commandQueue)
            return treadmillCommandTelemetrySidecar.clear()
          }
          func processCommandQueue() { effects.append("queue") }
          func observeCancelledTreadmillCommands(_ entries: [TreadmillCommandTelemetrySidecar.Entry], reason: CommandKind) {}
          func observeSupersededTreadmillCommands(_ entries: [TreadmillCommandTelemetrySidecar.Entry]) {}
          func logTrainingEvent(_ name: String, fields: [String: Any]) {}
          func observeTreadmillTelemetry(_ evidence: TreadmillTelemetryEvidence, sessionID: Int?) {
            if case let .commandEnqueued(value) = evidence { emitted.append((sessionID, value)); effects.append("sink") }
          }
        """#
        let driver = #"""
          func run() {
            let stop = TreadmillCommandTelemetryRequest(sessionID: 1, commandID: 100, decisionID: 200, kind: .stop)
            enqueueCommand(Data([1]), label: "STOP", highPriority: true, requiresControlReadiness: false, telemetryRequest: stop)
            enqueueCommand(Data([2]), label: "START/STOP TOGGLE", highPriority: false, requiresControlReadiness: false,
              telemetryRequest: .init(sessionID: 1, commandID: 101, decisionID: 200, kind: .other("legacy_stop_toggle")))
            enqueueCommand(Data([1]), label: "STOP retry", highPriority: false, requiresControlReadiness: false, telemetryRequest: stop)
            precondition(emitted.filter { $0.1.commandID == 100 }.count == 1, "Stop retry duplicated logical enqueue")
            precondition(commandQueue.map(\.data) == [Data([1]), Data([2]), Data([1])])
            precondition(commandQueue.map(\.label) == ["STOP", "START/STOP TOGGLE", "STOP retry"])
            precondition(treadmillCommandTelemetrySidecar.count == 3)
            precondition(treadmillCommandTelemetrySidecar.queued[0].entry.evidence == treadmillCommandTelemetrySidecar.queued[2].entry.evidence)
            precondition(effects.prefix(2).elementsEqual(["queue", "sink"]))
            let cancelled = Owner()
            cancelled.enqueueCommand(Data([1]), label: "STOP", highPriority: true, requiresControlReadiness: false, telemetryRequest: stop)
            cancelled.enqueueCommand(Data([1]), label: "STOP retry", highPriority: true, requiresControlReadiness: false, telemetryRequest: stop)
            precondition(cancelled.emitted.isEmpty, "Explicit request copies must retain prior publication")
            precondition(cancelled.treadmillCommandTelemetrySidecar.count == 1)
            let fresh = TreadmillCommandTelemetryRequest(sessionID: 1, commandID: 102, decisionID: 200, kind: .stop)
            cancelled.enqueueCommand(Data([1]), label: "STOP", highPriority: true, requiresControlReadiness: false, telemetryRequest: fresh)
            cancelled.enqueueCommand(Data([1]), label: "STOP retry", highPriority: true, requiresControlReadiness: false, telemetryRequest: fresh)
            precondition(cancelled.emitted.count == 1, "Cancellation before first send must retain enqueue")
            cancelled.treadmillTelemetryConnectionEpoch = 2
            cancelled.treadmillTelemetryProtocolKind = .ftms
            cancelled.enqueueCommand(Data([1]), label: "STOP retry", highPriority: false, requiresControlReadiness: false, telemetryRequest: fresh)
            precondition(cancelled.emitted.count == 1)
            let original = cancelled.treadmillCommandTelemetrySidecar.queued.last!.entry
            precondition(original.sessionID == 1 && original.evidence.connectionEpoch == 1 && original.evidence.protocolKind == .walkingPad)
            let duplicate = TreadmillCommandTelemetryRequest(sessionID: 1, commandID: 100, decisionID: 200, kind: .stop)
            enqueueCommand(Data([1]), label: "STOP", highPriority: true, requiresControlReadiness: false, telemetryRequest: duplicate)
            precondition(emitted.filter { $0.1.commandID == 100 }.count == 2, "Separate requests must not be globally deduplicated")
          }
        }
        Owner().run()
        """#
        let program = [try declaration("enum CommandQueueService", in: queue),
            try declaration("struct TreadmillCommandTelemetrySidecar", in: sidecar),
            prefix, request, enqueue, driver].joined(separator: "\n")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("StopEnqueue.swift")
        let binary = directory.appendingPathComponent("stop-enqueue")
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
    recovery.recoveryDidChange(true)
    check(recovery.pendingTrainingResult == nil, "Active recovery callback cannot present completion")
    recovery.manager.isNativeWorkoutRecoveryActive = false; recovery.manager.isHrControlRunning = true
    recovery.recoveryDidChange(false)
    check(recovery.pendingTrainingResult == nil, "Recovery callback cannot replace an active workout")
    recovery.manager.isHrControlRunning = false; recovery.recoveryDidChange(false)
    check(recovery.pendingTrainingResult?.sessionID == "A", "Recovery completion enters processing")
    recovery.clearTrainingResultPresentation(); recovery.recoveryDidChange(false)
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
     func finalizeCompletedStopIfReady() {}
     func observeCancelledTreadmillCommands(_ entries: [Int], reason: CancellationReason) {}
     enum CancellationReason { case other(String) }
     var queuedSessionID: String? = "original-session"
         enum ProtocolKind { case walkingPad, ftms }
         struct Epoch { let rawValue: UUID }
         struct Observation { let protocolKind: ProtocolKind; let connectionEpoch: Epoch; let receivedAt: Date }
         var latestTreadmillObservationEvidence: Observation?
         var commandQueue: [Int] = []
         var isCommandQueueProcessing = false
         var changedContext: StopObservationContext?
         func currentStopObservationContext() -> StopObservationContext? { changedContext ?? stopObservationLifecycle?.context }

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
