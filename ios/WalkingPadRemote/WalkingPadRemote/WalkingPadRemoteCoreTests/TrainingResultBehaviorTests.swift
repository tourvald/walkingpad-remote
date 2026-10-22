#if os(macOS)
import Foundation
import XCTest

/// Executes the production methods verbatim with dependency fixtures, without extracting a production layer.
final class TrainingResultBehaviorTests: XCTestCase {
    func testPlankNotificationOwnershipAcrossPermissionAddResetAndCompletion() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("WalkingPadRemote")
        let source = try String(contentsOf: app.appendingPathComponent("PlankTimerView.swift"), encoding: .utf8)
        let methods = try ["private func prepareCountdown(", "private func startIfNeeded()",
                           "private func finish()", "private func resetTimer()"].map {
            try declaration($0, in: source)
        }.joined(separator: "\n")
        let program = #"""
        import Foundation
        enum Authorization { case notDetermined, authorized, denied, provisional }
        enum SoundSetting { case enabled, disabled }
        struct Settings { var authorizationStatus: Authorization = .authorized; var soundSetting: SoundSetting = .enabled }
        enum Option { case alert, sound }
        enum Sound { case `default` }
        final class UNMutableNotificationContent { var title = "", body = ""; var sound: Sound? }
        struct UNTimeIntervalNotificationTrigger { let timeInterval: Double; let repeats: Bool }
        struct UNNotificationRequest { let identifier: String; let content: UNMutableNotificationContent; let trigger: UNTimeIntervalNotificationTrigger }
        enum Failure: Error { case unavailable }
        @MainActor final class UNUserNotificationCenter {
            static var instance = UNUserNotificationCenter()
            static func current() -> UNUserNotificationCenter { instance }
            var settings = Settings(), authorizationCalls = 0
            var requests: [String] = ["unrelated"], additions = 0, failAdd = false
            var onAuthorization: (() -> Void)?, onAdd: (() -> Void)?
            func notificationSettings() async -> Settings { settings }
            func requestAuthorization(options: [Option]) async throws -> Bool {
                authorizationCalls += 1; onAuthorization?()
                settings.authorizationStatus = .authorized
                return true
            }
            func add(_ request: UNNotificationRequest) async throws {
                additions += 1; onAdd?()
                if failAdd { throw Failure.unavailable }
                precondition(request.trigger.timeInterval == 60 && !request.trigger.repeats)
                precondition(request.content.sound != nil)
                requests.append(request.identifier)
            }
            func removePendingNotificationRequests(withIdentifiers ids: [String]) {
                requests.removeAll { ids.contains($0) }
            }
        }
        @MainActor final class Owner {
            var completionNotificationID: String? = "old"
            var timerStartedAt: ContinuousClock.Instant?
            var usesCompletionNotification = false, isRunning = false, isMeasuring = false
            var notificationNotice: String?, lastMeasuredBaselineSeconds: Int?
            var activeSetTotalSeconds = 60, nextSetTotalSeconds = 60, remainingSeconds = 60
            var completedSetsCount = 0, sounds = 0, banners = 0
            var isStarting: Bool { completionNotificationID != nil && !isRunning }
            func resetHoldProgress() {}
            func playCompletionSignal() { sounds += 1 }
            func showCompletionBannerTemporarily() { banners += 1 }
        """# + "\n" + methods + "\n" + #"""
            func prepare() async { await prepareCountdown(identifier: "old", seconds: 60) }
            func cancel() { resetTimer() }
            func complete() { finish() }
            func start() { startIfNeeded() }
        }
        @main struct Main {
            @MainActor static func main() async {
                for scenario in ["authorized", "denied", "silent", "provisional", "add_error",
                                 "cancel_permission", "replace_permission", "cancel_add", "replace_add", "cancel_add_error"] {
                    let center = UNUserNotificationCenter()
                    UNUserNotificationCenter.instance = center
                    let owner = Owner()
                    if scenario == "denied" { center.settings.authorizationStatus = .denied }
                    if scenario == "silent" { center.settings.soundSetting = .disabled }
                    if scenario == "provisional" { center.settings.authorizationStatus = .provisional }
                    if scenario.contains("error") { center.failAdd = true }
                    if scenario.contains("permission") {
                        center.settings.authorizationStatus = .notDetermined
                        center.onAuthorization = {
                            owner.cancel()
                            if scenario == "replace_permission" { owner.completionNotificationID = "new" }
                        }
                    }
                    if scenario.hasPrefix("cancel_add") || scenario == "replace_add" {
                        center.onAdd = {
                            owner.cancel()
                            if scenario == "replace_add" { owner.completionNotificationID = "new" }
                        }
                    }
                    await owner.prepare()
                    if scenario.hasPrefix("cancel") || scenario.hasPrefix("replace") {
                        precondition(!owner.isRunning && owner.timerStartedAt == nil, scenario)
                        precondition(center.requests == ["unrelated"], scenario)
                        precondition(owner.completionNotificationID == (scenario.hasPrefix("replace") ? "new" : nil), scenario)
                    } else {
                        precondition(owner.isRunning && owner.timerStartedAt != nil, scenario)
                        let notified = scenario == "authorized"
                        precondition(owner.usesCompletionNotification == notified, scenario)
                        owner.complete(); owner.complete()
                        precondition(owner.completedSetsCount == 1 && owner.banners == 1, scenario)
                        precondition(owner.sounds == (notified ? 0 : 1), scenario)
                        precondition(center.requests == (notified ? ["unrelated", "old"] : ["unrelated"]), scenario)
                    }
                }
                let center = UNUserNotificationCenter()
                UNUserNotificationCenter.instance = center
                let owner = Owner(); owner.completionNotificationID = nil
                owner.start(); let identifier = owner.completionNotificationID; owner.start()
                precondition(identifier != nil && owner.completionNotificationID == identifier)
                for _ in 0..<100 { if owner.isRunning { break }; await Task.yield() }
                precondition(owner.isRunning && center.additions == 1)
                owner.cancel()
                precondition(!owner.isRunning && center.requests == ["unrelated"])
            }
        }
        """#
        try executeFixture(program, name: "PlankNotificationOwnership")
    }

    func testFTMSRejectionPreservesStopIdentityAndTerminatesAutomaticMotion() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("WalkingPadRemote")
        let source = try String(contentsOf: app.appendingPathComponent("BluetoothManager.swift"), encoding: .utf8)
        let rejection = try declaration("private func handleFTMSProcedureRejection(", in: source)
        let termination = try declaration("private func stopHrControlAfterCommandFailure(", in: source)
        let cancelTestRun = try declaration("private func cancelTreadmillTestRun(", in: source)
        let testRun = try String(contentsOf: app.appendingPathComponent("TreadmillTestRunService.swift"), encoding: .utf8)
        let program = testRun + "\n" + #"""
        import Foundation
        struct Command { let label: String; let id: Int }
        enum Reason { case other(String) }
        struct Sidecar {
            var queued: [Command] = []
            mutating func removeQueued(where predicate: (String) -> Bool) -> [Command] {
                let removed = queued.filter { predicate($0.label) }
                queued.removeAll { predicate($0.label) }
                return removed
            }
        }
        final class Owner {
            var commandQueueEpoch = 3, isCommandQueueProcessing = true
            var nextCommandAllowedAt = Date()
            var commandQueue: [Command] = []
            var treadmillCommandTelemetrySidecar = Sidecar()
            var isHrControlRunning = false, hrControlFailed = false, hrControlStartedBelt = true
            var hrControlStartedAt: Date? = Date()
            var hrNextDecisionSeconds = 5, hrRemainingSeconds = 60, hrNoDataSeconds = 0
            var hrProgress = 1.0
            var hrStatusLine = "", infoToastMessage = "", hrDecisionDetails = "", hrPredictorStatusLine = ""
            var stoppedSessions = 0, newStops = 0, failedStops = 0
            var cancelled: [Int] = [], written: [Int] = []
            var cooldown = true
            var treadmillTestRunService = TreadmillTestRunService()
            var treadmillTestRunHeartRateDiagnosticSnapshot = (runID: UUID?.none, unused: false)
            var testRunTimerActive = false, diagnosticFinishes = 0
            var cancelledTestRunActions: [TreadmillTestRunService.Action] = []
            func invalidateTreadmillTestRunScheduling() { testRunTimerActive = false }
            func syncTreadmillTestRunPresentation() {}
            func resetCommandQueue(reason: String) { preconditionFailure("Must preserve Stop ownership") }
            func executeTreadmillTestRunActions(_ actions: [TreadmillTestRunService.Action]) {
                cancelledTestRunActions += actions
            }
            func treadmillTestRunHeartRateTerminalReason(for reason: TreadmillTestRunService.CancellationReason) -> String {
                reason.rawValue
            }
            func finishCurrentTreadmillTestRunHeartRateDiagnostic(expectedRunID: UUID, reason: String) {
                precondition(expectedRunID == treadmillTestRunHeartRateDiagnosticSnapshot.runID)
                precondition(reason == "command_rejected")
                diagnosticFinishes += 1
            }
            func clearCooldownRuntimeState() { cooldown = false }
            func endTelemetryV2Session(reason: String) {
                precondition(reason == "ftms_procedure_rejected"); stoppedSessions += 1
            }
            func stopBeltWithToggle(reason: String) {
                precondition(reason == "ftms_procedure_rejected")
                newStops += 1; written.append(99)
            }
            func observeCancelledTreadmillCommands(_ commands: [Command], reason: Reason) {
                cancelled += commands.map(\.id)
            }
            func nativeWorkoutStopTransportInvocationFailedIfNeeded(reason: String) { failedStops += 1 }
            func processCommandQueue() { written += commandQueue.map(\.id) }
        """# + "\n" + rejection + "\n" + termination + "\n" + cancelTestRun + "\n" + #"""
            func run(_ opcode: UInt8) { handleFTMSProcedureRejection(opcode: opcode) }
        }
        @main struct Main { static func main() {
            for active in [false, true] {
              for testRunActive in [false, true] {
                for queuedStop in [false, true] {
                    for opcode: UInt8 in [0x02, 0x07, 0x08] {
                        let owner = Owner()
                        owner.isHrControlRunning = active
                        let runID = UUID()
                        if testRunActive {
                            _ = owner.treadmillTestRunService.start(at: 0, runID: runID)
                            owner.treadmillTestRunHeartRateDiagnosticSnapshot.runID = runID
                            owner.testRunTimerActive = true
                        }
                        owner.commandQueue = [.init(label: "SPEED old", id: 1), .init(label: "START", id: 2)]
                        if queuedStop { owner.commandQueue.append(.init(label: "STOP", id: 42)) }
                        owner.treadmillCommandTelemetrySidecar.queued = owner.commandQueue
                        owner.run(opcode)
                        precondition(owner.commandQueueEpoch == 4 && !owner.isCommandQueueProcessing)
                        precondition(owner.nextCommandAllowedAt == .distantPast)
                        let preservesStop = queuedStop && opcode != 0x08
                        precondition(owner.cancelled == [1, 2] + (queuedStop && opcode == 0x08 ? [42] : []))
                        precondition(owner.commandQueue.map(\.id) == (preservesStop ? [42] : []))
                        precondition(owner.treadmillCommandTelemetrySidecar.queued.map(\.id) == (preservesStop ? [42] : []))
                        let expectedWrites = opcode == 0x08 ? [] : (queuedStop ? [42] : [99])
                        precondition(owner.written == expectedWrites)
                        precondition(owner.failedStops == (opcode == 0x08 ? 1 : 0))
                        precondition(owner.stoppedSessions == (active ? 1 : 0))
                        precondition(!owner.treadmillTestRunService.isActive && !owner.testRunTimerActive)
                        precondition(owner.treadmillTestRunService.advance(at: 100, expectedRunID: runID) == nil)
                        precondition(owner.cancelledTestRunActions.isEmpty)
                        precondition(owner.diagnosticFinishes == (testRunActive ? 1 : 0))
                        if active { precondition(owner.hrControlFailed && !owner.isHrControlRunning && !owner.cooldown) }
                    }
                }
              }
            }
        }}
        """#
        try executeFixture(program, name: "FTMSRejection")
    }

    func testFTMSControlLossTerminatesAutomaticOwnersWithoutRequestingStop() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("WalkingPadRemote")
        let source = try String(contentsOf: app.appendingPathComponent("BluetoothManager.swift"), encoding: .utf8)
        let failure = try declaration("private func failFTMSControl()", in: source)
        let program = #"""
        import Foundation
        struct ControlState {
            var blocked = false
            mutating func invalidate() { blocked = true }
        }
        final class Owner {
            var ftmsControlState = ControlState()
            var isTreadmillControlReady = true, isHrControlRunning = false
            var testRunActive = false, cooldownActive = false
            var infoToastMessage = ""
            var queue = ["START", "SPEED", "STOP"], epoch = 0
            var stopRequests = 0, terminations = 0, testRunCancellations = 0
            func resetCommandQueue(reason: String) { queue.removeAll(); epoch += 1 }
            func markInitialStopCommandNotSent(reason: String) {}
            func nativeWorkoutStopTransportInvocationFailedIfNeeded(reason: String) {}
            func recomputeHrStartAllowed() {}
            func cancelTreadmillTestRunForConnectionInvalidation() {
                precondition(ftmsControlState.blocked && !isTreadmillControlReady)
                if testRunActive { testRunActive = false; testRunCancellations += 1 }
            }
            func stopHrControlAfterCommandFailure(reason: String, requestStop: Bool) {
                precondition(ftmsControlState.blocked && !isTreadmillControlReady)
                precondition(reason == "ftms_control_unavailable")
                if requestStop { stopRequests += 1 }
                terminations += 1; isHrControlRunning = false; cooldownActive = false
            }
        """# + "\n" + failure + "\n" + #"""
            func fail() { failFTMSControl() }
        }
        @main struct Main { static func main() {
            for hrActive in [false, true] {
                for cooldown in [false, true] where !cooldown || hrActive {
                    for testRun in [false, true] {
                        let owner = Owner()
                        owner.isHrControlRunning = hrActive
                        owner.cooldownActive = cooldown; owner.testRunActive = testRun
                        owner.fail(); owner.fail()
                        precondition(owner.ftmsControlState.blocked && !owner.isTreadmillControlReady)
                        precondition(!owner.isHrControlRunning && !owner.cooldownActive && !owner.testRunActive)
                        precondition(owner.queue.isEmpty && owner.epoch == 2)
                        precondition(owner.stopRequests == 0 && owner.terminations == (hrActive ? 1 : 0))
                        precondition(owner.testRunCancellations == (testRun ? 1 : 0))
                    }
                }
            }
        }}
        """#
        try executeFixture(program, name: "FTMSControlLoss")
    }

    func testFTMSValueErrorsInvalidateOnlyTheCurrentConnection() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("WalkingPadRemote")
        let source = try String(contentsOf: app.appendingPathComponent("BluetoothManager.swift"), encoding: .utf8)
        let handler = try declaration("func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor", in: source)
        let boundary = try XCTUnwrap(handler.range(of: "guard let data = characteristic.value"))
        let entry = String(handler[..<boundary.lowerBound]) + "acceptedValues += 1\n}"
        let program = #"""
        import Foundation
        final class CBPeripheral { let identifier = UUID() }
        final class CBCharacteristic {}
        enum ProtocolKind { case walkingPad, ftms, fitShow }
        final class Owner {
            let connectedPeripheral = CBPeripheral()
            var connectedPeripheralId: UUID { connectedPeripheral.identifier }
            var treadmillProtocol = ProtocolKind.ftms
            var callbackCurrent = true, failures = 0, acceptedValues = 0
            func isCurrentCharacteristicCallback(_ characteristic: CBCharacteristic) -> Bool { callbackCurrent }
            func failFTMSControl() { failures += 1 }
        """# + "\n" + entry + "\n" + #"""
        }
        @main struct Main { static func main() {
            for kind in [ProtocolKind.walkingPad, .ftms, .fitShow] {
                for foreign in [false, true] {
                    for current in [false, true] {
                        for failed in [false, true] {
                            let owner = Owner(); owner.treadmillProtocol = kind; owner.callbackCurrent = current
                            owner.peripheral(foreign ? CBPeripheral() : owner.connectedPeripheral,
                                didUpdateValueFor: CBCharacteristic(),
                                error: failed ? NSError(domain: "fixture", code: 1) : nil)
                            precondition(owner.failures == (!foreign && current && failed && kind == .ftms ? 1 : 0))
                            precondition(owner.acceptedValues == (!foreign && current && !failed ? 1 : 0))
                        }
                    }
                }
            }
        }}
        """#
        try executeFixture(program, name: "FTMSValueError")
        let ftms = try XCTUnwrap(handler.range(of: "case .ftms:"))
        let fitShow = try XCTUnwrap(handler.range(of: "case .fitShow:", range: ftms.upperBound..<handler.endIndex))
        // CoreBluetooth already delivers callbacks on main; no old value may be deferred across reconnect.
        XCTAssertFalse(handler[ftms.lowerBound..<fitShow.lowerBound].contains("DispatchQueue"))
        let central = try declaration("private func ensureCentral()", in: source)
        XCTAssertTrue(central.contains("CBCentralManager(delegate: self, queue: nil"))
    }

    func testMainCountdownAndExtensionUseTheOriginalMonotonicAnchor() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("WalkingPadRemote")
        let source = try String(contentsOf: app.appendingPathComponent("BluetoothManager.swift"), encoding: .utf8)
        let domain = try String(contentsOf: app.appendingPathComponent("HRDomainService.swift"), encoding: .utf8)
        let remaining = try declaration("static func remainingSessionSeconds(", in: domain)
        let methods = try ["var canExtendHrSession: Bool", "private func syncHrSessionTiming(", "func extendHrSession("].map {
            try declaration($0, in: source)
        }.joined(separator: "\n")
        let program = """
        import Foundation
        enum HRDomainService { \(remaining) }
        struct RecoveryRecord { func planningDuration(seconds: Int) -> Self { self } }
        final class Owner {
            var isHrControlRunning = true, nativeHealthKitWorkoutCommitted = true
            var intervalWorkoutState: Int?
            var hrControlStartedInstant: ContinuousClock.Instant?
            var hrSessionTotalSeconds = 60, hrRemainingSeconds = 60, hrMaxSessionMinutes = 120
            var hrProgress = 0.0
            var activeNativeWorkoutRecoveryRecord: RecoveryRecord? = RecoveryRecord()
            var infoToastMessage: String?
            var canPersist = true
            var persistCalls = 0
            func persistNativeWorkoutRecoveryRecord(_ record: RecoveryRecord) -> Bool {
                persistCalls += 1
                return canPersist
            }
            \(methods)
            func sync(at now: ContinuousClock.Instant) { syncHrSessionTiming(now: now) }
        }
        @main struct Main { static func main() {
            let owner = Owner()
            let start = ContinuousClock.now
            owner.hrControlStartedInstant = start
            owner.sync(at: start.advanced(by: .seconds(1)))
            precondition(owner.hrRemainingSeconds == 59)
            owner.sync(at: start.advanced(by: .seconds(20)))
            precondition(owner.hrRemainingSeconds == 40)
            owner.sync(at: start.advanced(by: .seconds(90)))
            precondition(owner.hrRemainingSeconds == 0 && owner.hrProgress == 1)
            owner.hrSessionTotalSeconds = 600
            owner.hrRemainingSeconds = 600
            let original = ContinuousClock.now.advanced(by: .seconds(-20))
            owner.hrControlStartedInstant = original
            owner.extendHrSession()
            precondition(owner.hrSessionTotalSeconds == 900 && (879...880).contains(owner.hrRemainingSeconds))
            precondition(owner.hrControlStartedInstant == original)
            let before = owner.hrRemainingSeconds
            owner.canPersist = false
            owner.extendHrSession()
            precondition(owner.hrSessionTotalSeconds == 900 && owner.hrRemainingSeconds == before)
            owner.intervalWorkoutState = 1
            owner.sync(at: original.advanced(by: .seconds(1000)))
            precondition(owner.hrRemainingSeconds == before)
            owner.intervalWorkoutState = nil
            owner.hrSessionTotalSeconds = 60
            owner.hrRemainingSeconds = 1
            owner.hrControlStartedInstant = .now.advanced(by: .seconds(-90))
            let persistCalls = owner.persistCalls
            precondition(!owner.canExtendHrSession)
            owner.extendHrSession()
            precondition(owner.hrSessionTotalSeconds == 60 && owner.hrRemainingSeconds == 1)
            precondition(owner.persistCalls == persistCalls, "Expired main phase must not be extended")
            precondition(HRDomainService.remainingSessionSeconds(totalSeconds: 60, elapsed: .seconds(-1)) == 60)
            precondition(HRDomainService.remainingSessionSeconds(totalSeconds: 60, elapsed: .milliseconds(1999)) == 59)
        }}
        """
        try executeFixture(program, name: "MonotonicCountdown")
        let tick = try declaration("private func tickTelemetry()", in: source)
        let sync = try XCTUnwrap(tick.range(of: "syncHrSessionTiming()"))
        let phaseBranch = try XCTUnwrap(tick.range(of: "if hrRemainingSeconds > 0"))
        XCTAssertLessThan(sync.lowerBound, phaseBranch.lowerBound)
        XCTAssertTrue(tick.contains("cooldownStartedInstant = .now"))
        XCTAssertTrue(tick.contains("cooldownStartedInstant.duration(to: .now)"))
        XCTAssertTrue(try declaration("private func clearCooldownRuntimeState()", in: source)
            .contains("cooldownStartedInstant = nil"))
        XCTAssertTrue(try declaration("private func endTelemetryV2Session(", in: source)
            .contains("hrControlStartedInstant = nil"))
    }

    func testDelayedMainDeadlineCannotSkipSafetyBeforeCooldown() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("WalkingPadRemote")
        let source = try String(contentsOf: app.appendingPathComponent("BluetoothManager.swift"), encoding: .utf8)
        let domain = try String(contentsOf: app.appendingPathComponent("HRDomainService.swift"), encoding: .utf8)
        let rules = try ["static func isWithinInitialHeartRateGrace(", "static func missingHeartRateSignalSeconds(",
                         "static func shouldStopForMissingHeartRateSignal("].map {
            try declaration($0, in: domain)
        }.joined(separator: "\n")
        let safety = try declaration("private func maintainHeartRateControlSafety()", in: source)
        let program = """
        import Foundation
        enum HRDomainService { \(rules) }
        final class Owner {
            var isHrControlRunning = true, isTreadmillControlReady = true, hrStreamingActive = false
            var hrControlFailed = false, hrControlStartedBelt = true
            var hrRemainingSeconds = 0, heartRateBPM = 0, hrStartGraceSeconds = 20, hrNoDataMaxSeconds = 60
            var hrNextDecisionSeconds = 0, hrNoDataSeconds = 0
            var hrProgress = 1.0
            var intervalWorkoutState: Int?, cooldownRuntimeState: Int?
            var hrControlStartedAt: Date? = Date().addingTimeInterval(-140)
            var hrLastValueAt: Date? = Date().addingTimeInterval(-75)
            var infoToastMessage = "", hrStatusLine = "", hrDecisionDetails = "", hrPredictorStatusLine = ""
            var stops: [String] = []
            func clearCooldownRuntimeState() { cooldownRuntimeState = nil }
            func stopBeltWithToggle(reason: String) { stops.append(reason) }
            func endTelemetryV2Session(reason: String) {}
            \(safety)
            func run() { maintainHeartRateControlSafety() }
        }
        @main struct Main { static func main() {
            for scenario in ["missing", "not_ready", "healthy", "cooldown", "stopped"] {
                let owner = Owner()
                if scenario == "not_ready" { owner.isTreadmillControlReady = false }
                if scenario == "healthy" { owner.hrStreamingActive = true; owner.heartRateBPM = 120 }
                if scenario == "cooldown" { owner.cooldownRuntimeState = 1 }
                if scenario == "stopped" { owner.isHrControlRunning = false }
                owner.run()
                let mustStop = scenario == "missing" || scenario == "not_ready"
                precondition(owner.stops.count == (mustStop ? 1 : 0), "Main deadline must retain safety: " + scenario)
                precondition(owner.hrControlFailed == mustStop)
                if mustStop { precondition(!owner.isHrControlRunning && owner.cooldownRuntimeState == nil) }
                if scenario == "missing" { precondition(owner.stops == ["hr_no_signal"]) }
                if scenario == "not_ready" { precondition(owner.stops == ["hr_control_not_ready"]) }
            }
        }}
        """
        try executeFixture(program, name: "DelayedMainSafety")
        let tick = try declaration("private func tickTelemetry()", in: source)
        XCTAssertTrue(tick.contains("maintainHeartRateControlSafety()\n\n        if isHrControlRunning {"))
        let safetyCall = try XCTUnwrap(tick.range(of: "maintainHeartRateControlSafety()"))
        let phaseAdvance = try XCTUnwrap(tick.range(of: "advanceIntervalWorkout()"))
        XCTAssertLessThan(safetyCall.lowerBound, phaseAdvance.lowerBound)
    }

    func testHealthKitBuilderCallbacksCannotCompleteReplacementOperations() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("WalkingPadRemote")
        let source = try String(contentsOf: app.appendingPathComponent("IPhoneHealthKitLiveHeartRateProvider.swift"), encoding: .utf8)
        let driver = try declaration("private final class HealthKitLiveWorkoutDriver:", in: source)
        let methods = try ["func beginCollection(at", "func endCollection(at", "func finishWorkout()",
                           "func reset()", "private func completeVoidOperation("].map {
            try declaration($0, in: driver)
        }.joined(separator: "\n")
        let program = #"""
        import Foundation
        enum HealthKitLiveWorkoutDriverError: Error { case missingWorkout, operationCancelled, operationFailed }
        final class HKWorkout {}
        final class Builder {
            var completion: ((Bool, Error?) -> Void)?
            var finishCompletion: ((HKWorkout?, Error?) -> Void)?
            func beginCollection(withStart: Date, completion: @escaping (Bool, Error?) -> Void) { self.completion = completion }
            func endCollection(withEnd: Date, completion: @escaping (Bool, Error?) -> Void) {
                precondition(self.completion == nil, "Duplicate pending collection")
                self.completion = completion
            }
            func finishWorkout(completion: @escaping (HKWorkout?, Error?) -> Void) { finishCompletion = completion }
            func fire(success: Bool, workout: HKWorkout) {
                let error: Error? = success ? nil : HealthKitLiveWorkoutDriverError.operationFailed
                completion?(success, error)
                finishCompletion?(success ? workout : nil, error)
            }
        }
        @MainActor final class HealthKitLiveWorkoutDriver {
            var builder: Builder? = Builder()
            var session: NSObject?
            var pendingStopDate: Date?, stoppedAt: Date?
            var prepareContinuation: CheckedContinuation<Void, Error>?
            var beginCollectionContinuation: CheckedContinuation<Void, Error>?
            var endCollectionContinuation: CheckedContinuation<Void, Error>?
            var finishContinuation: CheckedContinuation<HKWorkout?, Error>?
            var stoppedTransitionContinuation: CheckedContinuation<Date, Error>?
        """# + "\n" + methods + "\n" + #"""
        }
        @main struct Main {
            @MainActor static func call(_ owner: HealthKitLiveWorkoutDriver, _ operation: Int) async throws -> HKWorkout? {
                switch operation {
                case 0: try await owner.beginCollection(at: Date()); return nil
                case 1: try await owner.endCollection(at: Date()); return nil
                default: return try await owner.finishWorkout()
                }
            }
            @MainActor static func pending(_ owner: HealthKitLiveWorkoutDriver, _ operation: Int) -> Bool {
                switch operation {
                case 0: return owner.beginCollectionContinuation != nil
                case 1: return owner.endCollectionContinuation != nil
                default: return owner.finishContinuation != nil
                }
            }
            static func barrier() async {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    DispatchQueue.main.async { c.resume() }
                }
            }
            @MainActor static func main() async throws {
                for operation in 0..<3 {
                    for oldSuccess in [false, true] {
                        let owner = HealthKitLiveWorkoutDriver()
                        let old = owner.builder!
                        let first = Task { try await call(owner, operation) }
                        while !pending(owner, operation) { await Task.yield() }
                        owner.reset()
                        do { _ = try await first.value; preconditionFailure("Reset must cancel") } catch {}
                        let current = Builder()
                        owner.builder = current
                        let second = Task { try await call(owner, operation) }
                        while !pending(owner, operation) { await Task.yield() }
                        old.fire(success: oldSuccess, workout: HKWorkout())
                        await barrier()
                        precondition(pending(owner, operation), "Old callback stole a new continuation")
                        let expected = HKWorkout()
                        current.fire(success: !oldSuccess, workout: expected)
                        do {
                            let actual = try await second.value
                            precondition(!oldSuccess)
                            precondition(operation != 2 || actual === expected)
                        } catch HealthKitLiveWorkoutDriverError.operationFailed {
                            precondition(oldSuccess)
                        }
                        precondition(!pending(owner, operation))
                    }
                }
                // Cleanup may request endCollection while finish is already waiting for it.
                let owner = HealthKitLiveWorkoutDriver()
                let first = Task { try await owner.endCollection(at: Date()) }
                while owner.endCollectionContinuation == nil { await Task.yield() }
                do {
                    try await owner.endCollection(at: Date())
                    preconditionFailure("Overlapping endCollection must be rejected")
                } catch {}
                owner.builder!.fire(success: true, workout: HKWorkout())
                try await first.value
            }
        }
        """#
        try executeFixture(program, name: "BuilderCallbackOwnership")
    }

    func testRuntimeStartIsIdempotentAcrossWindows() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("WalkingPadRemote")
        let source = try String(contentsOf: app.appendingPathComponent("BluetoothManager.swift"), encoding: .utf8)
        let method = try declaration("    func start()", in: source)
        let program = #"""
        import Foundation
        final class Dependency { func reset() {}; func cancel() {}; func prepareStoreAndRecover() {} }
        struct Profile { let id = UUID() }
        final class UserDefaults {
            static let standard = UserDefaults()
            func string(forKey: String) -> String? { "existing" }
            func set(_ value: String, forKey: String) {}
        }
        final class Owner {
            var didStartApplicationRuntime = false, autoConnectSuppressed = true, knownDiscoveryGraceCompleted = true
            var autoConnectRetryPolicy = Dependency(), telemetryV2Coordinator = Dependency()
            var knownDiscoveryGraceWorkItem: Dependency?
            var legacyFallbackProfileStoreKey = "fallback", userProfiles: [Profile] = []
            var calls: [String] = []
            func ensureCentral() { calls.append("central") }
            func loadKnownPeripherals() { calls.append("known") }
            func loadLastSuccessfulPeripheral() { calls.append("last") }
            func loadProfilesState() { calls.append("profiles") }
            func sortedProfiles(_ profiles: [Profile]) -> [Profile] { profiles }
            func loadNativeWorkoutRecoveryState() { calls.append("recovery") }
            func refreshWorkoutHistoryFromV2(reset: Bool) { calls.append("history") }
            func setHeartRateTelemetrySink(_ sink: Dependency) {}
            func setTreadmillTelemetrySink(_ sink: Dependency) {}
            func loadProfileErasureState() { calls.append("erasure") }
            func scheduleLegacyTelemetryMigration() { calls.append("migration") }
            func processNoActiveWorkoutRecoveryIfPossible() { precondition(didStartApplicationRuntime) }
            func processPendingActiveWorkoutRecoveryIfPossible() { precondition(didStartApplicationRuntime) }
            func recomputeHrStartAllowed() {}
            func startHrStaleTimer() { calls.append("timer") }
            func startDiscoveryScan() { calls.append("scan") }
            func attemptAutoConnectIfNeeded() { calls.append("connect") }
        """# + "\n" + method + "\n" + #"""
        }
        @main struct Main { static func main() {
            let owner = Owner()
            owner.start()
            let initial = owner.calls
            precondition(initial.contains("recovery") && initial.contains("timer"))
            owner.autoConnectSuppressed = true
            owner.start()
            precondition(owner.calls == initial, "A second window restarted the live runtime")
            precondition(owner.autoConnectSuppressed)
        }}
        """#
        try executeFixture(program, name: "StartupIdempotence")
    }

    func testFTMSStopHasNoBlindTimerRetriesAndRecoveryRetainsReconnect() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("WalkingPadRemote")
        let source = try String(contentsOf: app.appendingPathComponent("BluetoothManager.swift"), encoding: .utf8)
        let direct = try declaration("func stopBelt()", in: source)
        let retryGuard = try declaration("if treadmillProtocol != .ftms", in: direct)
        XCTAssertEqual(retryGuard.components(separatedBy: "scheduleWrite(").count - 1, 2)
        XCTAssertEqual(direct.components(separatedBy: "scheduleWrite(").count - 1, 2)
        XCTAssertTrue(direct.contains("scheduledStopEffects: treadmillProtocol == .ftms ? 0 : 2"))
        let stop = try declaration("private func stopBeltWithToggle(", in: source)
        let ftms = try XCTUnwrap(stop.range(of: "case .ftms:"))
        let next = try XCTUnwrap(stop.range(of: "case .fitShow, .unknown:", range: ftms.upperBound..<stop.endIndex))
        XCTAssertFalse(stop[ftms.upperBound..<next.lowerBound].contains("scheduleWrite"))
        let content = try String(contentsOf: app.appendingPathComponent("ContentView.swift"), encoding: .utf8)
        let shell = try declaration("private struct ActiveWorkoutShell:", in: content)
        XCTAssertTrue(shell.contains("treadmillInteractive: onReconnect != nil && !presentation.isPreview"))
        XCTAssertTrue(shell.contains("onTreadmillTap: { onReconnect?() }"))
        XCTAssertTrue(content.contains("onReconnect: manager.isTreadmillControlReady ? nil : { showDevicePicker = true }"))
    }

    func testDelayedConditionalStopCannotCrossQueueOrAttemptEpoch() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("WalkingPadRemote")
        let source = try String(contentsOf: app.appendingPathComponent("BluetoothManager.swift"), encoding: .utf8)
        let stop = try declaration("private func stopBeltWithToggle(", in: source)
        let callback = try declaration("DispatchQueue.main.asyncAfter(deadline: .now() + 4.0)", in: stop)
        let prefix = #"""
        import Foundation
        extension Double { static func now() -> Double { 0 } }
        final class DispatchQueue {
          static let main = DispatchQueue()
          var pending: [() -> Void] = []
          func asyncAfter(deadline: Double, execute: @escaping () -> Void) { pending.append(execute) }
        }
        final class Owner {
          var commandQueueEpoch = 1
          var deviceReportedSpeedKmh = 2.0
          var speedKmh = 2.0
          var writes = 0
          var attempt = UUID()
          var completed: [Bool] = []
          func completeScheduledStopEffect(attemptID: UUID?, cancelled: Bool) {
            if attemptID == attempt { completed.append(cancelled) }
          }
          func buildTreadmillStopPacket() -> Data? { Data([0]) }
          func writeCommand(_ data: Data, label: String, telemetryRequest: Int) { writes += 1 }
          func schedule() {
            let epoch = commandQueueEpoch
            let stopAttemptID = attempt
            let telemetryRequest = 1
        """#
        let driver = #"""
          }
        }
        @main struct Main { static func main() {
        for scenario in ["moving", "zero", "new_start", "new_stop", "reconnected"] {
          let owner = Owner()
          owner.schedule()
          if scenario == "zero" { owner.speedKmh = 0; owner.deviceReportedSpeedKmh = 0 }
          if ["new_start", "new_stop", "reconnected"].contains(scenario) { owner.commandQueueEpoch += 1 }
          if scenario == "new_stop" { owner.attempt = UUID() }
          DispatchQueue.main.pending.removeFirst()()
          precondition(owner.writes == (scenario == "moving" ? 1 : 0), scenario)
          precondition(owner.completed == (scenario == "new_stop" ? [] : [scenario == "new_start" || scenario == "reconnected"]), scenario)
        }
        """#
        try executeFixture(prefix + "\n" + callback + "\n" + driver + "\n}}", name: "DelayedStop")
    }

    func testAutoStartCompensationExecutesFailedUnconfirmedStopTermination() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("WalkingPadRemote")
        let source = try String(contentsOf: app.appendingPathComponent("BluetoothManager.swift"), encoding: .utf8)
        let method = try declaration("private func stopHrControlAfterCommandFailure(", in: source)
        let program = """
        import Foundation
        final class Owner {
            var hrControlStartedAt: Date? = Date()
            var hrControlFailed = false, isHrControlRunning = true, hrControlStartedBelt = true
            var hrStatusLine = "", infoToastMessage = "", hrDecisionDetails = "", hrPredictorStatusLine = ""
            var hrNextDecisionSeconds = 9, hrRemainingSeconds = 60, hrNoDataSeconds = 0
            var hrProgress = 0.5
            var events: [String] = []
            func clearCooldownRuntimeState() { events.append("clear") }
            func stopBeltWithToggle(reason: String) {
                precondition(reason == "hr_auto_start_speed_cancelled"); events.append("stop_requested")
            }
            func endTelemetryV2Session(reason: String) { events.append("end") }
            \(method)
            func run() { stopHrControlAfterCommandFailure() }
        }
        let owner = Owner(); owner.run()
        precondition(owner.hrControlFailed && !owner.isHrControlRunning)
        precondition(owner.hrControlStartedAt == nil && !owner.hrControlStartedBelt)
        precondition(owner.hrRemainingSeconds == 0 && owner.hrNextDecisionSeconds == 0)
        precondition(owner.infoToastMessage.contains("ещё не подтверждена"))
        precondition(owner.events == ["clear", "stop_requested", "end"])
        """
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("AutoStartStop.swift")
        let binary = directory.appendingPathComponent("auto-start-stop")
        try program.write(to: file, atomically: true, encoding: .utf8)
        try execute(URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["swiftc", file.path, "-o", binary.path], directory: directory)
        try execute(binary, arguments: [], directory: directory)
    }

    func testWorkoutCountdownUsesPhaseFactsWithoutOwningAClock() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("WalkingPadRemote")
        let source = try String(contentsOf: app.appendingPathComponent("ContentView.swift"), encoding: .utf8)
        let model = try declaration("private struct TrainingWorkoutCountdown", in: source)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("Countdown.swift")
        try (model + #"""

        private func snapshot(_ main: Int, _ cooldown: Int = 134, _ progress: Double = 0.6,
                      _ cooldownProgress: Double = 0.4, running: Bool = true,
                      recovering: Bool = false) -> TrainingWorkoutCountdown? {
            TrainingWorkoutCountdown(isRunning: running, isRecovering: recovering,
                mainRemainingSeconds: main, cooldownRemainingSeconds: cooldown,
                mainProgress: progress, cooldownProgress: cooldownProgress)
        }
        private let main = snapshot(678)!
        precondition(main.remainingSeconds == 678 && main.progress == 0.6 && main.title == "До заминки")
        private let extended = snapshot(978, 134, 1 - 978.0 / 2100)!
        precondition(extended.remainingSeconds == 978 && extended.progress < main.progress)
        private let cooldown = snapshot(0)!
        precondition(cooldown.remainingSeconds == 134 && cooldown.progress == 0.4)
        precondition(cooldown.title == "До лимита заминки")
        precondition(snapshot(0, 0, 1, 1)!.remainingSeconds == 0)
        precondition(snapshot(-1, -8, 1, 2)!.remainingSeconds == 0)
        precondition(snapshot(-1, -8, 1, 2)!.progress == 1)
        precondition(snapshot(7200, 134, 0)!.remainingSeconds == 7200)
        precondition(snapshot(1, 134, -0.2)!.progress == 0)
        precondition(snapshot(1, 134, .nan)!.progress == 0)
        precondition(snapshot(0, 134, 0, .infinity)!.progress == 0)
        precondition(snapshot(678, running: false) == nil)
        precondition(snapshot(678, recovering: true) == nil)
        precondition(snapshot(0, recovering: true) == nil)
        // Repeated reads never advance the countdown or infer physical Stop.
        for _ in 0..<3600 { precondition(snapshot(678)!.remainingSeconds == 678) }
        """#).write(to: script, atomically: true, encoding: .utf8)
        try execute(URL(fileURLWithPath: "/usr/bin/swift"), arguments: [script.path], directory: directory)
        let adapter = try declaration("private func makeProductionActiveWorkoutPresentation(", in: source)
        for fact in ["manager.isHrControlRunning", "manager.isNativeWorkoutRecoveryActive",
                     "manager.hrRemainingSeconds", "manager.hrCooldownRemainingSeconds",
                     "manager.hrProgress", "manager.hrCooldownProgress"] {
            XCTAssertTrue(adapter.contains(fact), fact)
        }
        let shell = try declaration("private struct ActiveWorkoutShell: View", in: source)
        for forbidden in ["Timer", "TimelineView", "Task", "Date()", ".repeatForever(", "sendTreadmill"] {
            XCTAssertFalse(shell.contains(forbidden), forbidden)
        }
        XCTAssertTrue(shell.contains("countdownBar(countdown)"))
        XCTAssertTrue(shell.contains(".accessibilityValue("))
    }

    func testHealthKitStopRequestedBeforeRunningIsDeliveredOnStateTransition() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("WalkingPadRemote")
        let source = try String(contentsOf: app.appendingPathComponent("IPhoneHealthKitLiveHeartRateProvider.swift"), encoding: .utf8)
        let methods = try [
            "    func stopActivity(at date: Date)",
            "    private func stopPendingActivityIfReady()",
            "    func waitForStoppedTransition()",
            "    func reset()",
            "    func workoutSession(\n        _ workoutSession: HKWorkoutSession,\n        didChangeTo",
            "    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError",
        ].map { try declaration($0, in: source) }.joined(separator: "\n")
        let program = """
        import Foundation
        enum HKWorkoutSessionState { case prepared, running, paused, stopped, ended }
        enum HealthKitLiveWorkoutDriverError: Error { case operationCancelled, missingWorkout }
        final class HKWorkout {}
        final class HKWorkoutSession {
            var state: HKWorkoutSessionState = .prepared
            var sent: [Date] = []
            func stopActivity(with date: Date) { sent.append(date) }
        }
        final class Fixture {
            var session: HKWorkoutSession? = HKWorkoutSession()
            var builder: NSObject?
            var pendingStopDate: Date?
            var stoppedAt: Date?
            var prepareContinuation: CheckedContinuation<Void, Error>?
            var beginCollectionContinuation: CheckedContinuation<Void, Error>?
            var endCollectionContinuation: CheckedContinuation<Void, Error>?
            var finishContinuation: CheckedContinuation<HKWorkout?, Error>?
            var registered: CheckedContinuation<Void, Never>?
            var stoppedTransitionContinuation: CheckedContinuation<Date, Error>? {
                didSet { if stoppedTransitionContinuation != nil { registered?.resume(); registered = nil } }
            }
            var runtimeFailureContexts: [ObjectIdentifier: String] = [:]
            var runtimeFailureContextOrder: [ObjectIdentifier] = []
            var onRuntimeFailure: ((String) -> Void)?
        \(methods)
        }
        @main struct Main {
            static func barrier() async {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    DispatchQueue.main.async { c.resume() }
                }
            }
            static func wait(_ owner: Fixture) async -> Task<Date, Error> {
                let task = Task { try await owner.waitForStoppedTransition() }
                await withCheckedContinuation { c in
                    if owner.stoppedTransitionContinuation != nil { c.resume() } else { owner.registered = c }
                }
                return task
            }
            static func rejected(_ task: Task<Date, Error>) async {
                do { _ = try await task.value; preconditionFailure("Unexpected stopped proof") } catch {}
            }
            static func main() async throws {
                let owner = Fixture()
                let session = owner.session!
                let requested = Date(timeIntervalSince1970: 100)
                owner.stopActivity(at: requested)
                precondition(session.sent.isEmpty)
                session.state = .running
                owner.workoutSession(session, didChangeTo: .running, from: .prepared, date: requested)
                await barrier()
                precondition(session.sent == [requested], "Stop lost while HealthKit was starting")
                owner.workoutSession(session, didChangeTo: .running, from: .prepared, date: requested)
                await barrier()
                precondition(session.sent.count == 1)
                let foreign = HKWorkoutSession()
                owner.pendingStopDate = requested
                owner.workoutSession(foreign, didChangeTo: .running, from: .prepared, date: requested)
                await barrier()
                precondition(session.sent.count == 1)
                session.state = .paused
                owner.stopActivity(at: requested.addingTimeInterval(1))
                precondition(session.sent.count == 2)

                let stopped = requested.addingTimeInterval(2)
                session.state = .stopped
                owner.workoutSession(session, didChangeTo: .stopped, from: .running, date: stopped)
                await barrier()
                let buffered = try await owner.waitForStoppedTransition()
                precondition(buffered == stopped && owner.pendingStopDate == nil)
                session.state = .running
                let waiting = await wait(owner)
                session.state = .stopped
                owner.workoutSession(session, didChangeTo: .stopped, from: .running, date: stopped)
                let observed = try await waiting.value
                precondition(observed == stopped)

                session.state = .ended
                do { _ = try await owner.waitForStoppedTransition(); preconditionFailure("Ended session waited") } catch {}
                session.state = .running
                let ended = await wait(owner)
                session.state = .ended
                owner.workoutSession(session, didChangeTo: .ended, from: .running, date: stopped)
                await rejected(ended)

                session.state = .running
                let reset = await wait(owner)
                owner.pendingStopDate = requested
                owner.reset()
                await rejected(reset)
                precondition(owner.session == nil && owner.pendingStopDate == nil)
                let replacement = HKWorkoutSession()
                replacement.state = .running
                owner.session = replacement
                owner.workoutSession(session, didChangeTo: .running, from: .prepared, date: stopped)
                owner.workoutSession(replacement, didChangeTo: .running, from: .prepared, date: stopped)
                await barrier()
                precondition(replacement.sent.isEmpty)

                let failure = await wait(owner)
                owner.runtimeFailureContexts[ObjectIdentifier(session)] = "old"
                owner.runtimeFailureContexts[ObjectIdentifier(replacement)] = "current"
                var failures: [String] = []
                owner.onRuntimeFailure = { failures.append($0) }
                owner.workoutSession(session, didFailWithError: HealthKitLiveWorkoutDriverError.operationCancelled)
                await barrier()
                precondition(owner.stoppedTransitionContinuation != nil && failures == ["old"])
                owner.workoutSession(replacement, didFailWithError: HealthKitLiveWorkoutDriverError.operationCancelled)
                await rejected(failure)
                precondition(failures == ["old", "current"])
                owner.reset()
                do { _ = try await owner.waitForStoppedTransition(); preconditionFailure("Missing session waited") } catch {}
            }
        }
        """
        try executeFixture(program, name: "HealthKitStop")
    }

    func testInterruptedRecoveryRequiresExplicitNilHealthKitResultBeforeArchiving() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("WalkingPadRemote")
        let source = try String(contentsOf: app.appendingPathComponent("BluetoothManager.swift"), encoding: .utf8)
        let engine = try String(contentsOf: app.appendingPathComponent("NativeHeartRatePreflightEngine.swift"), encoding: .utf8)
        let pending = try declaration("    private func processPendingActiveWorkoutRecoveryIfPossible()", in: source)
        let probe = try declaration("    private func processNoActiveWorkoutRecoveryIfPossible()", in: source)
        let probePath = String(probe[..<probe.range(of: "        let resolution = NativeWorkoutRecoveryPolicy")!.lowerBound]) + "}"
        let handlers = try ["    func handleActiveWorkoutRecoveryRequest()", "    func handleActiveWorkoutRecovery(\n"]
            .map { try declaration($0, in: source) }.joined(separator: "\n")
        let program = engine + "\n" + """
        enum Activity { case walking, other }
        enum Location { case indoor, outdoor }
        struct Configuration { var activityType: Activity = .walking; var locationType: Location = .indoor }
        final class HKWorkoutSession {
            var workoutConfiguration = Configuration()
            var startDate: Date? = Date(timeIntervalSince1970: 100)
        }
        struct Lifecycle { let startedAt: Date?; let collectionStarted = true }
        enum ProviderState { case idle }
        final class Provider {
            var state: ProviderState = .idle
            var recovered = 0
            func recover(_ session: HKWorkoutSession, failureContext: IPhoneHealthKitRuntimeFailureContext) throws -> Lifecycle {
                recovered += 1; return Lifecycle(startedAt: session.startDate)
            }
        }
        final class Logger { func info(_ value: String) {}; func error(_ value: String) {} }
        final class HealthStore {
            var calls = 0
            var callback: ((HKWorkoutSession?, Error?) -> Void)?
            func recoverActiveWorkoutSession(_ callback: @escaping (HKWorkoutSession?, Error?) -> Void) {
                calls += 1; self.callback = callback
            }
        }
        final class Fixture {
            var didStartApplicationRuntime = true
            var profileErasureStateLoaded = true
            var pendingActiveWorkoutRecoveryResult: (HKWorkoutSession?, Error?)?
            var nativeWorkoutRecoveryLoadResult: NativeWorkoutRecoveryLoadResult = .missing
            var activeNativeWorkoutRecoveryRecord: NativeWorkoutRecoveryRecord?
            var nativeWorkoutRecoveryStore: NativeWorkoutRecoveryStore?
            var nativeHeartRateLogger = Logger()
            var infoToastMessage: String?
            var isNativeWorkoutRecoveryActive = true
            var isNativeHeartRatePreflightActive = false
            var nativeWorkoutRecoveryStatusText: String?
            var failed = false
            var unlocked = false
            var finished = 0
            var discarded = 0
            var restored = 0
            var activeWorkoutRecoveryAvailability: Bool? = false
            var activeWorkoutRecoveryRequestPending = false
            var didHandleActiveWorkoutRecoveryCallback = false
            var nativeHealthKitWorkoutCommitted = false
            var nativeHeartRateFlowOwnsController = false
            var nativeHealthKitWorkoutFinishInFlight = false
            var healthStore = HealthStore()
            var nativeHeartRateProviderLifecycle = NativeHeartRateProviderLifecycle()
            var iPhoneHealthKitHeartRateProvider = Provider()
            func recomputeHrStartAllowed() {}
            func completeNativeWorkoutRecoveryToIdle() { unlocked = true; isNativeWorkoutRecoveryActive = false }
            func handleUnavailableActiveWorkoutRecovery(error: Error?) { failed = true }
            func discardRecoveredUncommittedWorkout() { discarded += 1 }
            func restoreCommittedNativeWorkout(_ record: NativeWorkoutRecoveryRecord) { restored += 1 }
            func resumeFinishingNativeWorkout(_ record: NativeWorkoutRecoveryRecord) { finished += 1 }
        \(pending.replacingOccurrences(of: "private func", with: "func"))
        \(probePath.replacingOccurrences(of: "private func", with: "func"))
        \(handlers)
        }
        @main struct Main {
            static func barrier() async {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    DispatchQueue.main.async { c.resume() }
                }
            }
            static func main() async throws {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                let store = NativeWorkoutRecoveryStore(fileURL: directory.appendingPathComponent("recovery.json"))
                let preflight = NativeWorkoutRecoveryRecord.preflight(appWorkoutID: UUID(), targetBPM: 140, durationMinutes: 25,
                    acquisitionStartedAt: Date(timeIntervalSince1970: 100), profileID: UUID())
                let sessionID = UUID()
                let record = preflight.committed(controlledWorkoutStartedAt: Date(timeIntervalSince1970: 101),
                    profileID: UUID(), legacySessionID: sessionID, telemetrySessionID: sessionID)
                    .finishing(requestedAt: Date(timeIntervalSince1970: 110))
                try store.save(record)
                let original = try Data(contentsOf: store.fileURL)
                func fixture() -> Fixture {
                    let f = Fixture(); f.nativeWorkoutRecoveryStore = store
                    f.nativeWorkoutRecoveryLoadResult = .record(record); f.activeNativeWorkoutRecoveryRecord = record
                    return f
                }
                let f = fixture()
                f.processNoActiveWorkoutRecoveryIfPossible()
                f.processNoActiveWorkoutRecoveryIfPossible()
                precondition(f.healthStore.calls == 1 && !f.unlocked)
                f.healthStore.callback?(nil, NSError(domain: "unavailable", code: 1))
                await barrier()
                precondition(!f.unlocked && f.failed && f.didHandleActiveWorkoutRecoveryCallback)
                precondition(try! Data(contentsOf: store.fileURL) == original)
                f.handleActiveWorkoutRecovery(session: nil, error: nil)
                precondition(!f.unlocked, "Duplicate callback must not unlock")

                for variant in 0..<4 {
                    let foreign = HKWorkoutSession()
                    switch variant {
                    case 0: foreign.startDate = nil
                    case 1: foreign.startDate = Date(timeIntervalSince1970: 200)
                    case 2: foreign.workoutConfiguration.activityType = .other
                    default: foreign.workoutConfiguration.locationType = .outdoor
                    }
                    let other = fixture()
                    other.handleActiveWorkoutRecovery(session: foreign, error: nil)
                    precondition(other.failed && !other.unlocked && other.iPhoneHealthKitHeartRateProvider.recovered == 0)
                    precondition(other.discarded == 0 && other.finished == 0)
                    precondition(try! Data(contentsOf: store.fileURL) == original)
                }
                let matching = fixture()
                matching.handleActiveWorkoutRecovery(session: HKWorkoutSession(), error: nil)
                precondition(matching.finished == 1 && matching.discarded == 0 && !matching.unlocked)
                precondition(try! Data(contentsOf: store.fileURL) == original)

                let archive = directory.appendingPathComponent("interrupted_native_workout_\\(record.appWorkoutID.uuidString).json")
                try Data("conflict".utf8).write(to: archive)
                let conflict = fixture()
                conflict.handleActiveWorkoutRecovery(session: nil, error: nil)
                precondition(conflict.failed && !conflict.unlocked)
                precondition(try! Data(contentsOf: store.fileURL) == original)
                try FileManager.default.removeItem(at: archive)

                for load in [NativeWorkoutRecoveryLoadResult.invalid, .record(preflight),
                             .record(record.stopping(requestedAt: Date(timeIntervalSince1970: 110)))] {
                    let blocked = fixture(); blocked.nativeWorkoutRecoveryLoadResult = load
                    blocked.handleActiveWorkoutRecovery(session: nil, error: nil)
                    precondition(blocked.failed && !blocked.unlocked)
                    precondition(try! Data(contentsOf: store.fileURL) == original)
                }
                let buffered = fixture()
                buffered.didStartApplicationRuntime = false
                buffered.handleActiveWorkoutRecovery(session: nil, error: nil)
                precondition(!buffered.unlocked && buffered.pendingActiveWorkoutRecoveryResult != nil)
                buffered.didStartApplicationRuntime = true
                buffered.processPendingActiveWorkoutRecoveryIfPossible()
                precondition(buffered.unlocked && !buffered.failed && store.load() == .missing)
                precondition(try! Data(contentsOf: archive) == original)
                buffered.handleActiveWorkoutRecovery(session: HKWorkoutSession(), error: nil)
                precondition(buffered.finished == 0)
                try FileManager.default.removeItem(at: archive)
                try store.save(record)
                let resaved = try Data(contentsOf: store.fileURL)
                let awaitingPreferences = fixture()
                awaitingPreferences.profileErasureStateLoaded = false
                awaitingPreferences.handleActiveWorkoutRecovery(session: nil, error: nil)
                precondition(!awaitingPreferences.unlocked && awaitingPreferences.pendingActiveWorkoutRecoveryResult != nil, "Recovery must wait for profile preferences")
                awaitingPreferences.processNoActiveWorkoutRecoveryIfPossible()
                precondition(!awaitingPreferences.unlocked && awaitingPreferences.healthStore.calls == 0, "No early recovery probe")
                awaitingPreferences.profileErasureStateLoaded = true
                awaitingPreferences.processPendingActiveWorkoutRecoveryIfPossible()
                precondition(awaitingPreferences.unlocked && !awaitingPreferences.failed && store.load() == .missing, "Buffered recovery must resume after preferences")
                precondition(try! Data(contentsOf: archive) == resaved)
            }
        }
        """
        try executeFixture(program, name: "InterruptedRecovery")
    }

    private func executeFixture(_ program: String, name: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(name + ".swift")
        let binary = directory.appendingPathComponent(name)
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
        let hr = try String(contentsOf: app.appendingPathComponent("HRDomainService.swift"), encoding: .utf8)
        let speedCommand = "enum HRDomainService { " + (try declaration("final class SpeedCommand", in: hr)) + " }"
        let program = lifecycle + "\n" + speedCommand + "\n" + Self.ownerPrefix + "\n" + [blockedWrite, finish, notSent].map { $0.replacingOccurrences(of: "private func", with: "func") }.joined(separator: "\n")
            + "\nfunc route(_ postWriteTelemetry: [TreadmillTelemetryEvidence]) { let lostEntries: [Int] = []; let needsCompensatingStop = false;\n"
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
          precondition(owner.telemetryV2Coordinator.events == ["owner-final", "close"], "Unexpected order: \(owner.telemetryV2Coordinator.events)")
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

    func testCancelledCallbackEpochCannotFailReplacementStopOrUnlockItsQueue() throws {
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
        precondition(oldMotion.isCommandQueueProcessing && oldMotion.failures == 0 && oldMotion.continued == 0)
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
        let requestControl = try declaration("private func enqueueFtmsRequestControlIfNeeded(", in: manager)
        let controlState = try String(contentsOf: app.appendingPathComponent("FTMSControlState.swift"), encoding: .utf8)
        let readiness = try String(contentsOf: app.appendingPathComponent("TreadmillControlReadinessPolicy.swift"), encoding: .utf8)
        let connectionIdentity = try declaration("struct TreadmillControlConnectionIdentity", in: readiness)
        let prefix = #"""
        import Foundation
        typealias TreadmillControlDecisionEvidence = Int
        struct Characteristic { let uuid = "2AD9" }
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
          var treadmillProtocol: TreadmillProtocolKind { treadmillTelemetryProtocolKind }
          var ftmsControlState = FTMSControlState()
          let ftmsCharControlPoint = "2AD9"
          let commandCharacteristic: Characteristic? = Characteristic()
          let currentTreadmillControlConnection: TreadmillControlConnectionIdentity? = .init(peripheralID: UUID(), epoch: UUID())
          var commandCharacteristicConnection: TreadmillControlConnectionIdentity? { currentTreadmillControlConnection }
          func buildFtmsRequestControlPacket() -> Data { Data([0x00]) }
          private func writeCommand(_ data: Data, label: String, telemetryRequest: TreadmillCommandTelemetryRequest) {
            enqueueCommand(data, label: label, highPriority: false, requiresControlReadiness: false, telemetryRequest: telemetryRequest)
          }
          var treadmillCommandTelemetrySidecar = TreadmillCommandTelemetrySidecar()
          var treadmillTelemetryConnectionEpoch: Int? = 1
          var treadmillTelemetryProtocolKind = TreadmillProtocolKind.walkingPad
          var emitted: [(Int?, TreadmillCommandEnqueuedEvidence)] = []
          var effects: [String] = []
          func isSpeedCommandLabel(_ label: String) -> Bool { label.hasPrefix("SPEED") }
          private func treadmillCommandRequest(kind: CommandKind, decision: TreadmillControlDecisionEvidence? = nil) -> TreadmillCommandTelemetryRequest {
            .init(sessionID: 1, commandID: 999, decisionID: nil, kind: kind)
          }
          func resetCommandQueue(reason: String, observeTelemetryImmediately: Bool) -> [TreadmillCommandTelemetrySidecar.Entry] {
            _ = CommandQueueService.clear(queue: &commandQueue)
            return treadmillCommandTelemetrySidecar.clear()
          }
          func processCommandQueue() { effects.append("queue") }
          func stopHrControlAfterCommandFailure() { preconditionFailure("Unexpected HR compensation") }
          func observeCancelledTreadmillCommands(_ entries: [TreadmillCommandTelemetrySidecar.Entry], reason: CommandKind) {}
          func observeSupersededTreadmillCommands(_ entries: [TreadmillCommandTelemetrySidecar.Entry]) {}
          func logTrainingEvent(_ name: String, fields: [String: Any]) {}
          func observeTreadmillTelemetry(_ evidence: TreadmillTelemetryEvidence, sessionID: Int?) {
            if case let .commandEnqueued(value) = evidence { emitted.append((sessionID, value)); effects.append("sink") }
          }
        """#
        let driver = #"""
          func run() {
            let ftms = Owner()
            ftms.treadmillTelemetryProtocolKind = .ftms
            ftms.enqueueFtmsRequestControlIfNeeded()
            ftms.enqueueCommand(Data([0x02]), label: "SPEED old", highPriority: false, requiresControlReadiness: false, telemetryRequest: nil)
            ftms.enqueueCommand(Data([0x08]), label: "STOP", highPriority: true, requiresControlReadiness: false, telemetryRequest: nil)
            precondition(ftms.commandQueue.map(\.label) == ["FTMS REQUEST CONTROL", "STOP"], "Queued request must survive priority Stop")
            ftms.ftmsControlState.sent(opcode: 0x00, connection: ftms.currentTreadmillControlConnection!, at: .now)
            ftms.enqueueCommand(Data([0x08]), label: "STOP", highPriority: true, requiresControlReadiness: false, telemetryRequest: nil)
            precondition(ftms.commandQueue.map(\.label) == ["STOP"], "Sent request must not be duplicated")
            precondition(!ftms.ftmsControlState.canSend(opcode: 0x08))
            _ = ftms.ftmsControlState.receive(opcode: 0x00, resultCode: 0x01, connection: ftms.currentTreadmillControlConnection!)
            precondition(ftms.ftmsControlState.canSend(opcode: 0x08))
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
        let hr = try String(contentsOf: app.appendingPathComponent("HRDomainService.swift"), encoding: .utf8)
        let speedCommand = "enum HRDomainService { " + (try declaration("final class SpeedCommand", in: hr)) + " }"
        let program = [controlState, connectionIdentity, speedCommand, try declaration("enum CommandQueueService", in: queue),
            try declaration("struct TreadmillCommandTelemetrySidecar", in: sidecar),
            prefix, request, enqueue, requestControl, driver].joined(separator: "\n")
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
        guard process.terminationStatus == 0 else {
            XCTFail(text)
            throw NSError(domain: "FixtureExecutionFailed", code: Int(process.terminationStatus))
        }
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
     func failFTMSControl() {}
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
     func processCommandQueue() { preconditionFailure("Unexpected queue continuation") }
     func stopHrControlAfterCommandFailure() { preconditionFailure("Unexpected HR compensation") }
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
