import Foundation
import SwiftUI
import Combine
import CoreBluetooth
import HealthKit
import OSLog
import TelemetryDomain
import TelemetryPersistence
import TelemetryRuntime
#if canImport(UIKit)
import UIKit
#endif

final class TreadmillFactualObservationPublisher: ObservableObject {
    func publish() {
        objectWillChange.send()
    }
}

final class HeartRateFactualState: ObservableObject {
    @Published fileprivate(set) var heartRateBPM = 0
    @Published fileprivate(set) var lastKnownHeartRateBPM = 0
    @Published fileprivate(set) var isStreamActive = false
    @Published fileprivate(set) var lastValueAt: Date?
    @Published fileprivate(set) var staleSeconds = 0
    @Published fileprivate(set) var isNativeCurrent = false
}

// Minimal stub to satisfy references in the UI. Replace with real implementation.
final class BluetoothManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let telemetryPerformanceObservation = TelemetryV2PerformanceObservation()
    private let nativeHeartRateLogger = Logger(
        subsystem: "sw.WalkingPadRemote",
        category: "NativeHeartRatePreflight"
    )

    // CoreBluetooth
    private var central: CBCentralManager?
    private let healthStore = HKHealthStore()
    private lazy var iPhoneHealthKitHeartRateProvider: IPhoneHealthKitLiveHeartRateProvider = {
        let provider = IPhoneHealthKitLiveHeartRateProvider(healthStore: healthStore)
        provider.onObservation = { [weak self] observation in
            self?.handleNativeHeartRateObservation(observation)
        }
        provider.onFailure = { [weak self] context in
            guard let self else { return }
            self.nativeHeartRateProviderFailed(
                generation: context.providerGeneration,
                attemptID: context.attemptID
            )
        }
        return provider
    }()
    private let serviceFE00 = CBUUID(string: "FE00")
    private let serviceFTMS = CBUUID(string: "1826") // Fitness Machine Service
    private let serviceFitShow = CBUUID(string: "FFF0") // Common FitShow/FitMonster service

    private let charFE01 = CBUUID(string: "FE01")
    private let charFE02 = CBUUID(string: "FE02")

    private let ftmsCharTreadmillData = CBUUID(string: "2ACD")
    private let ftmsCharControlPoint = CBUUID(string: "2AD9")
    private let ftmsCharMachineStatus = CBUUID(string: "2ADA")
    private let ftmsCharSupportedSpeedRange = CBUUID(string: "2AD4")

    private let fitShowCharRx = CBUUID(string: "FFF1") // notify/indicate (from treadmill)
    private let fitShowCharTx = CBUUID(string: "FFF2") // write/withoutResponse (to treadmill)

    private enum TreadmillProtocol: String {
        case walkingPad = "WalkingPad"
        case ftms = "FTMS"
        case fitShow = "FitShow"
        case unknown = "Unknown"
    }

    private var treadmillProtocol: TreadmillProtocol = .unknown
    private var treadmillProtocolService: CBService?
    private var treadmillProtocolConnection: TreadmillControlConnectionIdentity?
    private var ftmsControlState = FTMSControlState()
    private var ftmsDidReadSupportedSpeedRange: Bool = false
    private var fitShowDidRequestInitialStatus: Bool = false
    private var shouldBeScanning: Bool = false
    private var discoveredMap: [UUID: CBPeripheral] = [:]
    private var autoConnectPendingWorkItem: DispatchWorkItem?
    private var knownDiscoveryGraceWorkItem: DispatchWorkItem?
    private var knownDiscoveryGraceCompleted = false
    private var autoConnectRetryPolicy = AutoConnectRetryPolicy()
    private var connectTimeoutWorkItem: DispatchWorkItem?
    private var connectingPeripheralId: UUID? = nil
    private var connectingPeripheral: CBPeripheral? = nil
    private var cancellingConnectionPeripheralId: UUID? = nil
    private var connectingAttemptIsAutomatic = false
    private var controllerUnitsConnectionEpoch: UUID? = nil
    private var controllerUnitsTruthTracker = ControllerUnitsTruthTracker()
    private var lastControllerUnitsQueryAt: Date? = nil
    private var lastControllerUnitsQueryTrigger: String? = nil
    private var lastWalkingPadStatusQueryAt: Date? = nil
    private var stopObservationStreamID: UUID? = nil
    private var stopObservationLifecycle: StopObservationLifecycle? = nil
    private var stopObservationCheckpointWorkItems: [DispatchWorkItem] = []
    private var stopObservationFreshnessWorkItem: DispatchWorkItem?
    private struct UnavailableStopAttempt {
        let id: UUID
        let source: String
        let attemptedAt: Date
        var commandSentAt: Date?
    }
    private var unavailableStopAttempt: UnavailableStopAttempt? = nil
#if STOP_TRUTH_EXPERIMENT_CAPABILITY
    private var stopTruthExperimentController: StopTruthExperimentController?
    private var stopTruthExperimentTerminalLatch = false
#endif
    private struct TreadmillTestRunConnectionContext: Equatable {
        let peripheralID: UUID
        let connectionEpoch: UUID
    }
    private var treadmillTestRunService = TreadmillTestRunService()
    private var treadmillTestRunTimer: Timer?
    private var treadmillTestRunContext: TreadmillTestRunConnectionContext?
    private var treadmillTestRunHeartRateDiagnosticService =
        TestRunHeartRateDiagnosticService()
    private var treadmillTestRunHeartRateProvider: IPhoneHealthKitLiveHeartRateProvider?
    private var treadmillTestRunHeartRateProviderOwnership =
        TestRunHeartRateDiagnosticProviderOwnership()
    private var treadmillTestRunHeartRateCleanupInFlight = false
    private var treadmillTestRunHeartRateProviderGeneration: UInt64 = 0

    // Peripheral/characteristics
    private var connectedPeripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var commandCharacteristicConnection: TreadmillControlConnectionIdentity?
    private var notifyCharacteristic: CBCharacteristic?
    private var notifyCharacteristicConnection: TreadmillControlConnectionIdentity?
    private var rememberedValidatedTreadmillConnection: TreadmillControlConnectionIdentity?
    private var characteristicConnections: [ObjectIdentifier: TreadmillControlConnectionIdentity] = [:]
    private var extraNotifyCharacteristics: [CBCharacteristic] = []
    private var supportedServiceUuids: [CBUUID] { [serviceFE00, serviceFTMS, serviceFitShow] }

    // Connection / device info
    @Published var connectionStateText: String = "Disconnected"
    @Published var displayDeviceName: String? = nil
    @Published var deviceName: String = ""
    @Published var isConnected: Bool = false
    @Published private(set) var isTreadmillControlReady: Bool = false
    @Published var connectedPeripheralId: UUID? = nil
    // Best-effort capabilities (defaults are safe fallbacks; FTMS can override them).
    @Published var treadmillMinSpeedKmh: Double = 0.5
    @Published var treadmillMaxSpeedKmh: Double = 12.0
    @Published var treadmillSpeedIncrementKmh: Double = 0.1

    // Discovery
    struct DiscoveredPeripheral: Identifiable { let id: UUID; let name: String; let rssi: Int; let isKnown: Bool }
    struct KnownPeripheral: Identifiable { let id: UUID; var name: String }
    struct UserProfile: Identifiable, Equatable {
        let id: UUID
        var label: String
        let createdAt: Date
    }
    private(set) var discoveredPeripherals: [DiscoveredPeripheral] = []
    @Published private(set) var discoveryUIPeripherals: [DiscoveredPeripheral] = []
    @Published var knownPeripherals: [KnownPeripheral] = []
    @Published private(set) var userProfiles: [UserProfile] = []
    @Published private(set) var activeUserProfileID: UUID? = nil
    @Published private(set) var installationID: String = ""

    private struct KnownPeripheralDTO: Codable { let id: UUID; let name: String }
    private struct UserProfileDTO: Codable {
        let id: UUID
        let label: String
        let createdAt: Date
    }
    private struct UserProfilesStateDTO: Codable {
        let profiles: [UserProfileDTO]
        let activeProfileID: UUID?
    }
    private let knownStoreKey = "known_peripherals_store_v1"
    private let lastSuccessfulPeripheralStoreKey = "last_successful_known_peripheral_id_v1"
    private let userProfilesStoreKey = "user_profiles_state_v1"
    private let installationIDStoreKey = "installation_id_v1"
    private let hrSettingsStoreKey = "hr_settings_v1"
    private let zonePlanStoreKey = "zone_plan_v1"
    private var isLoadingHrSettings: Bool = false
    private var autoConnectSuppressed: Bool = false
    private var lastSuccessfulPeripheralID: UUID? = nil
    private var hrSessionTotalSeconds: Int = 0
    private var hrControlStartedBelt: Bool = false
    private var cooldownRuntimeState: CooldownRuntimeEngine.State? = nil
    private var cooldownStartedInstant: ContinuousClock.Instant?
    @Published var hrCooldownMinSpeed: Double = 3.5 { didSet { saveHrSettingsIfNeeded() } }
    @Published var hrCooldownTargetBpm: Int = HRSettingsDefaults.defaultCooldownTargetBpm { didSet { saveHrSettingsIfNeeded() } }
    @Published var hrCooldownMaxMinutes: Int = 5 { didSet { saveHrSettingsIfNeeded() } }
    private var hrCooldownMaxSeconds: Int { hrCooldownMaxMinutes * 60 }
    private let hrMaxSessionMinutes: Int = 120
    private var hrControlStartedAt: Date? = nil
    private let hrStartGraceSeconds: Int = 15
    private var hrAverageSum: Int = 0
    private var hrAverageCount: Int = 0
    private let hrTrendMinSamples: Int = 4
    private let hrPredictSeconds: Double = 15
    private let hrPredictMarginBpm: Int = 2
    private struct HRTrendSample {
        let date: Date
        let smoothedBPM: Double
        var telemetryDelivery: HeartRateDeliveryEvidence?
    }
    private var hrTrendSamples: [HRTrendSample] = []
    private var hrTrendEmaBpm: Double? = nil
    private var hrTrendMinWindowSeconds: TimeInterval {
        max(6, hrTrendWindowSeconds * 0.4)
    }
    private var hrZoneSeconds: [Int] = Array(repeating: 0, count: 5)
    private var hrSessionPeakBPM: Int = 0
    private var hrMainSumBPM: Int = 0
    private var hrMainCountBPM: Int = 0
    private var hrMainPeakBPM: Int = 0
    private var isAdjustingZoneBounds: Bool = false
    private var isUpdatingZonePlan: Bool = false
    private var hrNoDataSeconds: Int = 0
    private let hrNoDataMaxSeconds: Int = 60
    private let commandAckTimeoutSeconds: TimeInterval = 3
    private let commandMinIntervalWalkingPadSeconds: TimeInterval = 2.0
    private let commandMinIntervalFtmsSeconds: TimeInterval = 0.25
    private let commandMinIntervalFitShowSeconds: TimeInterval = 0.25
    private let commandMinIntervalUnknownSeconds: TimeInterval = 0.8
    private var lastNotifyAt: Date? = nil
    private var lastCommandSentAt: Date? = nil
    private var lastCommandAckedAt: Date? = nil
    private var lastCommandAwaitingAck: Bool = false
    private var lastCommandTimeouts: Int = 0
    private var commandQueue: [CommandQueueService.Command] = []
    private var isCommandQueueProcessing: Bool = false
    private var commandQueueEpoch: Int = 0
    private var nextCommandAllowedAt: Date = .distantPast
    private(set) var activeTelemetryV2SessionID: SessionID? = nil
    private(set) var activeTelemetryV2ProfileID: UUID?
    private let deferredNativeHealthKitLinkageStoreKey = "deferred_native_healthkit_linkage_v1"
    private var deferredNativeHealthKitLinkages: [DeferredNativeHealthKitLinkage] = []
    private var nativeHealthKitAcquisitionStartedAt: Date?
    private var nativeHealthKitLinkageQueryInFlight = false
    private lazy var nativeWorkoutRecoveryStore: NativeWorkoutRecoveryStore? = try? .applicationSupport(
        bundleIdentifier: Bundle.main.bundleIdentifier ?? "sw.WalkingPadRemote"
    )
    private var nativeWorkoutRecoveryLoadResult: NativeWorkoutRecoveryLoadResult = .missing
    private var activeNativeWorkoutRecoveryRecord: NativeWorkoutRecoveryRecord?
    private var pendingActiveWorkoutRecoveryResult: (HKWorkoutSession?, Error?)?
    private var didStartApplicationRuntime = false
    private var activeWorkoutRecoveryAvailability: Bool?
    private var activeWorkoutRecoveryRequestPending = false
    private var didHandleActiveWorkoutRecoveryCallback = false
    private var nativeWorkoutRecoverySessionRecovered = false
    private var nativeWorkoutRecoveryStopRequested = false
    private var pendingNativeWorkoutStopTerminalRequest: (
        record: NativeWorkoutRecoveryRecord,
        requestedAt: Date
    )?
    private var isRestoringNativeWorkoutRecoveryState = false
    private var hrControlFailed: Bool = false
    private var heartRateObservationNormalizer = HeartRateObservationNormalizer()
    private var heartRateTelemetrySink: (any HeartRateTelemetrySink)?
    private var latestHeartRateDelivery: HeartRateDeliveryEvidence?
    private var treadmillObservationNormalizer = TreadmillObservationNormalizer(
        controllerUnitsFreshnessInterval: ControllerUnitsSafetyPolicy.freshnessInterval
    )
    private var treadmillTelemetrySink: (any TreadmillTelemetrySink)?
    @Published private(set) var telemetryV2StatusText: String = "idle"
    @Published private(set) var telemetryV2WriterHealthSnapshot: TelemetryV2WriterHealthSnapshot = .idle
    private lazy var telemetryV2Coordinator = TelemetryV2RuntimeCoordinator(
        persistenceFactory: {
            let appIdentifier = Bundle.main.bundleIdentifier ?? "sw.WalkingPadRemote"
            let storeURL = try TelemetryStoreLocation.applicationSupportStoreURL(
                appIdentifier: appIdentifier
            )
            return try TelemetryStoreFactory.make(.onDisk(storeURL))
        },
        statusHandler: { [weak self] status in
            Task { @MainActor [weak self] in
                self?.telemetryV2StatusText = String(describing: status)
            }
        },
        writerHealthHandler: { [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.telemetryV2WriterHealthSnapshot = snapshot
            }
        },
        projectionChangeHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.telemetryV2ProjectionDidChange()
            }
        }
    )
    private var latestTreadmillObservationEvidence: TreadmillObservationEvidence?
    private var treadmillCommandTelemetrySidecar = TreadmillCommandTelemetrySidecar()
    private var treadmillCommandAttemptNumbers: [CommandID: UInt16] = [:]
    private typealias TreadmillCommandTelemetryRequest = TreadmillCommandTelemetrySidecar.Request
    private struct TreadmillStopTelemetryChain {
        let sessionID: SessionID?
        let decisionID: DecisionID
        let commandID: CommandID?
    }
    private var activeTreadmillStopTelemetryChain: TreadmillStopTelemetryChain?
    var activeUserProfileLabel: String {
        activeUserProfile?.label ?? "Пользователь 1"
    }

    private var activeUserProfile: UserProfile? {
        guard let activeUserProfileID else { return userProfiles.first }
        return userProfiles.first(where: { $0.id == activeUserProfileID }) ?? userProfiles.first
    }
    private func loadKnownPeripherals() {
        guard let data = UserDefaults.standard.data(forKey: knownStoreKey) else { return }
        if let list = try? JSONDecoder().decode([KnownPeripheralDTO].self, from: data) {
            self.knownPeripherals = list.map { KnownPeripheral(id: $0.id, name: $0.name) }
        }
    }

    private func saveKnownPeripherals() {
        let list = knownPeripherals.map { KnownPeripheralDTO(id: $0.id, name: $0.name) }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: knownStoreKey)
        }
    }

    private func loadLastSuccessfulPeripheral() {
        guard let rawValue = UserDefaults.standard.string(forKey: lastSuccessfulPeripheralStoreKey),
              let peripheralID = UUID(uuidString: rawValue),
              knownPeripherals.contains(where: { $0.id == peripheralID }) else {
            lastSuccessfulPeripheralID = nil
            UserDefaults.standard.removeObject(forKey: lastSuccessfulPeripheralStoreKey)
            return
        }
        lastSuccessfulPeripheralID = peripheralID
    }

    private func saveLastSuccessfulPeripheral(_ peripheralID: UUID) {
        lastSuccessfulPeripheralID = peripheralID
        UserDefaults.standard.set(peripheralID.uuidString, forKey: lastSuccessfulPeripheralStoreKey)
    }

    private func userProfileDTO(from profile: UserProfile) -> UserProfileDTO {
        UserProfileDTO(id: profile.id, label: profile.label, createdAt: profile.createdAt)
    }

    private func userProfile(from dto: UserProfileDTO) -> UserProfile {
        UserProfile(id: dto.id, label: dto.label, createdAt: dto.createdAt)
    }

    private func sortedProfiles(_ profiles: [UserProfile]) -> [UserProfile] {
        profiles.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
    }

    private func profileScopedStoreKey(_ baseKey: String, profileID: UUID) -> String {
        "\(baseKey)_profile_\(profileID.uuidString.lowercased())"
    }

    private func makeDefaultProfileLabel() -> String {
        "Пользователь \(max(1, userProfiles.count + 1))"
    }

    private func normalizedProfileLabel(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? makeDefaultProfileLabel() : trimmed
    }

    private func makeUniqueProfileLabel(_ rawValue: String, excluding profileID: UUID? = nil) -> String {
        let base = normalizedProfileLabel(rawValue)
        let existing = Set(
            userProfiles
                .filter { $0.id != profileID }
                .map { $0.label.lowercased() }
        )

        guard existing.contains(base.lowercased()) else {
            return base
        }

        var suffix = 2
        while existing.contains("\(base) \(suffix)".lowercased()) {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }

    private func loadInstallationID() {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: installationIDStoreKey),
           !existing.isEmpty {
            installationID = existing
            return
        }

        let generated = UUID().uuidString
        defaults.set(generated, forKey: installationIDStoreKey)
        installationID = generated
    }

    private func saveProfilesState() {
        let dto = UserProfilesStateDTO(
            profiles: sortedProfiles(userProfiles).map { userProfileDTO(from: $0) },
            activeProfileID: activeUserProfileID
        )
        guard let data = try? JSONEncoder().encode(dto) else { return }
        UserDefaults.standard.set(data, forKey: userProfilesStoreKey)
    }

    private func loadProfilesState() {
        loadInstallationID()

        if let data = UserDefaults.standard.data(forKey: userProfilesStoreKey),
           let dto = try? JSONDecoder().decode(UserProfilesStateDTO.self, from: data),
           !dto.profiles.isEmpty {
            let profiles = sortedProfiles(dto.profiles.map(userProfile(from:)))
            userProfiles = profiles
            activeUserProfileID = dto.activeProfileID.flatMap { candidate in
                profiles.contains(where: { $0.id == candidate }) ? candidate : profiles.first?.id
            } ?? profiles.first?.id
            if dto.activeProfileID != activeUserProfileID {
                saveProfilesState()
            }
            return
        }

        let defaultProfile = UserProfile(
            id: UUID(),
            label: "Пользователь 1",
            createdAt: Date()
        )
        userProfiles = [defaultProfile]
        activeUserProfileID = defaultProfile.id
        saveProfilesState()
    }

    private func applyDefaultHrSettings() {
        hrTargetBPM = 130
        hrDurationMinutes = 10
        hrAdaptiveStepEnabled = true
        hrDecisionIntervalSeconds = 10
        hrSpeedStepKmh = 0.5
        hrAdaptiveDeadbandPercent = 3.0
        hrAdaptiveDownLevel2StartPercent = 8.0
        hrAdaptiveDownLevel3StartPercent = 15.0
        hrAdaptiveDownLevel4StartPercent = 23.0
        hrAdaptiveUpLevel2StartPercent = 23.0
        hrAdaptiveUpLevel3StartPercent = 31.0
        hrAdaptiveUpLevel4StartPercent = 46.0
        hrTrendWindowSeconds = 20
        hrTrendEmaAlpha = 0.25
        hrTrendSlopeMaxBpmPerSecond = 0.6
        hrZone1Max = 134
        hrZone2Max = 146
        hrZone3Max = 158
        hrZone4Max = 170
        hrCooldownTargetBpm = HRSettingsDefaults.defaultCooldownTargetBpm
        hrCooldownMinSpeed = 3.5
        hrCooldownMaxMinutes = 5
    }

    private func makeHRSettingsDTO() -> HRSettingsDTO {
        HRSettingsDTO(
            targetBpm: hrTargetBPM,
            durationMinutes: hrDurationMinutes,
            adaptiveStepEnabled: hrAdaptiveStepEnabled,
            decisionIntervalSeconds: hrDecisionIntervalSeconds,
            speedStepKmh: hrSpeedStepKmh,
            adaptiveDeadbandPercent: hrAdaptiveDeadbandPercent,
            adaptiveDownLevel2StartPercent: hrAdaptiveDownLevel2StartPercent,
            adaptiveDownLevel3StartPercent: hrAdaptiveDownLevel3StartPercent,
            adaptiveDownLevel4StartPercent: hrAdaptiveDownLevel4StartPercent,
            adaptiveUpLevel2StartPercent: hrAdaptiveUpLevel2StartPercent,
            adaptiveUpLevel3StartPercent: hrAdaptiveUpLevel3StartPercent,
            adaptiveUpLevel4StartPercent: hrAdaptiveUpLevel4StartPercent,
            trendWindowSeconds: hrTrendWindowSeconds,
            trendEmaAlpha: hrTrendEmaAlpha,
            trendSlopeMaxBpmPerSecond: hrTrendSlopeMaxBpmPerSecond,
            zone1Max: hrZone1Max,
            zone2Max: hrZone2Max,
            zone3Max: hrZone3Max,
            zone4Max: hrZone4Max,
            cooldownTargetBpm: hrCooldownTargetBpm,
            cooldownMinSpeed: hrCooldownMinSpeed,
            cooldownMaxMinutes: hrCooldownMaxMinutes,
            heartRateZones: heartRateZoneSettings
        )
    }

    private func saveHrSettings(profileID: UUID) {
        guard !erasedProfiles.contains(profileID.uuidString.lowercased()) else { return }
        var dto = makeHRSettingsDTO()
        if profileID != activeUserProfileID {
            dto = dto.copiedForNewProfile()
        }
        guard let data = try? JSONEncoder().encode(dto) else { return }
        UserDefaults.standard.set(data, forKey: profileScopedStoreKey(hrSettingsStoreKey, profileID: profileID))
    }

    private func saveZonePlan(profileID: UUID) {
        guard !erasedProfiles.contains(profileID.uuidString.lowercased()) else { return }
        let normalized = normalizeZonePlan(zonePlanMinutes)
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        UserDefaults.standard.set(data, forKey: profileScopedStoreKey(zonePlanStoreKey, profileID: profileID))
    }

    @Published private(set) var profileErasureInFlight = false
    private var profileExportOperations = 0
    private var erasedProfiles: Set<String> = []
    private var profileErasureStateLoaded = false
    private let legacyFallbackProfileStoreKey = "legacy_fallback_profile_v1"

    var canDeleteUserProfile: Bool {
        profileErasureStateLoaded && ProfileErasurePolicy.permitsDeletion(
            workoutActive: isHrControlRunning || nativeHealthKitWorkoutCommitted || nativeHealthKitWorkoutFinishInFlight,
            recoveryOutstanding: hasOutstandingNativeWorkoutRecovery,
            preflightActive: nativeHeartRatePreflightEngine.hasStartIntent,
            cleanupInFlight: nativeHeartRateProviderLifecycle.cleanupInFlight,
            testRunActive: treadmillTestRunIsActive,
            stopPending: stopObservationLifecycle.map { $0.finalResult == nil } == true
                || unavailableStopAttempt != nil || blocksNonStopTreadmillMotion
                || telemetryV2Coordinator.hasSessionStorageOwnership,
            erasureInFlight: profileErasureInFlight || profileExportOperations > 0,
            linkageInFlight: nativeHealthKitLinkageQueryInFlight
        )
    }

    private var profileDataAvailable: Bool {
        profileErasureStateLoaded && !profileErasureInFlight
            && activeUserProfileID.map { !erasedProfiles.contains($0.uuidString.lowercased()) } == true
    }

    private func loadProfileErasureState() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                erasedProfiles = try await telemetryV2Coordinator.erasedProfileIdentifiers()
                if let profileID = activeUserProfileID {
                    ProfileErasureSettings.loadAfterLegacyMigration(
                        userDefaults: .standard, profileID: profileID.uuidString,
                        legacyFallback: UserDefaults.standard.string(forKey: legacyFallbackProfileStoreKey),
                        erasedProfiles: erasedProfiles,
                        load: { self.loadActiveProfileScopedData() }
                    )
                }
                profileErasureStateLoaded = true
                processNoActiveWorkoutRecoveryIfPossible()
                processPendingActiveWorkoutRecoveryIfPossible()
                resolveDeferredNativeHealthKitLinkageIfPossible()
                if !profileDataAvailable {
                    infoToastMessage = "Удаление профиля не завершено. Повторите удаление в параметрах."
                }
            } catch {
                infoToastMessage = "Не удалось проверить состояние локальных данных. Запуск тренировки недоступен."
            }
            recomputeHrStartAllowed()
        }
    }

    private func loadActiveProfileScopedData() {
        loadHrSettings()
        loadZonePlan()
    }

    func selectUserProfile(id: UUID) {
        guard userProfiles.contains(where: { $0.id == id }) else { return }
        guard profileErasureStateLoaded, !profileErasureInFlight, !shouldPresentActiveWorkout else {
            infoToastMessage = "Во время активной тренировки профиль переключать нельзя."
            return
        }
        guard activeUserProfileID != id else { return }

        saveHrSettingsIfNeeded()
        saveZonePlan()

        activeUserProfileID = id
        saveProfilesState()
        loadActiveProfileScopedData()
        refreshWorkoutHistoryFromV2(reset: true)
        infoToastMessage = "Активный профиль: \(activeUserProfileLabel)"
    }

    func createUserProfile(named rawLabel: String) {
        guard profileErasureStateLoaded, !profileErasureInFlight, !shouldPresentActiveWorkout else {
            infoToastMessage = "Во время активной тренировки профиль менять нельзя."
            return
        }

        let profile = UserProfile(
            id: UUID(),
            label: makeUniqueProfileLabel(rawLabel),
            createdAt: Date()
        )

        saveHrSettingsIfNeeded()
        saveZonePlan()

        saveHrSettings(profileID: profile.id)
        saveZonePlan(profileID: profile.id)

        userProfiles = sortedProfiles(userProfiles + [profile])
        activeUserProfileID = profile.id
        saveProfilesState()
        loadActiveProfileScopedData()
        refreshWorkoutHistoryFromV2(reset: true)
        infoToastMessage = "Создан профиль: \(profile.label)"
    }

    func renameActiveUserProfile(to rawLabel: String) {
        guard profileErasureStateLoaded, !profileErasureInFlight, !shouldPresentActiveWorkout else {
            infoToastMessage = "Во время активной тренировки профиль менять нельзя."
            return
        }
        guard let activeUserProfileID,
              let index = userProfiles.firstIndex(where: { $0.id == activeUserProfileID }) else {
            return
        }

        let label = makeUniqueProfileLabel(rawLabel, excluding: activeUserProfileID)
        guard userProfiles[index].label != label else { return }

        userProfiles[index].label = label
        userProfiles = sortedProfiles(userProfiles)
        saveProfilesState()
        infoToastMessage = "Профиль переименован: \(label)"
    }

    func deleteUserProfile(id: UUID) {
        guard canDeleteUserProfile, let profile = userProfiles.first(where: { $0.id == id }) else {
            infoToastMessage = "Удаление недоступно: дождитесь завершения тренировки, восстановления и экспорта."
            return
        }
        cancelAppleHeartRateZoneRead()
        profileErasureInFlight = true
        recomputeHrStartAllowed()
        let fallback = UserDefaults.standard.string(forKey: legacyFallbackProfileStoreKey)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                profileErasureInFlight = false
                recomputeHrStartAllowed()
            }
            do {
                let linkages = try UserDefaults.standard.data(forKey: deferredNativeHealthKitLinkageStoreKey)
                    .map { try JSONDecoder().decode([DeferredNativeHealthKitLinkage].self, from: $0) } ?? []
                guard linkages.allSatisfy({ $0.profileID != nil }) else { throw CocoaError(.fileReadCorruptFile) }
                try await telemetryV2Coordinator.eraseProfile(
                    id.uuidString, legacyFallback: fallback,
                    logsDirectory: LegacyTelemetryMigrationSourceDiscovery.defaultTrainingLogsDirectory(),
                    temporaryDirectory: FileManager.default.temporaryDirectory
                )
                erasedProfiles.insert(id.uuidString.lowercased())
                guard let nativeWorkoutRecoveryStore else { throw NativeWorkoutRecoveryStoreError.invalidRecord }
                try nativeWorkoutRecoveryStore.eraseInterruptedArchives(for: id)
                deferredNativeHealthKitLinkages = linkages.filter { $0.profileID != id }
                guard persistDeferredNativeHealthKitLinkages() else {
                    throw CocoaError(.fileWriteUnknown)
                }
                ProfileErasureSettings.removeProfileSettings(userDefaults: .standard, profileID: id.uuidString, legacyFallback: fallback)
                guard let selection = ProfileErasurePolicy.selection(
                    afterDeleting: id, from: userProfiles.map(\.id), activeID: activeUserProfileID
                ) else { return }
                userProfiles = userProfiles.filter { selection.retainedIDs.contains($0.id) }
                if let replacement = selection.replacementID {
                    userProfiles.append(UserProfile(id: replacement, label: "Пользователь 1", createdAt: Date()))
                }
                userProfiles = sortedProfiles(userProfiles)
                activeUserProfileID = selection.activeID
                saveProfilesState()
                loadActiveProfileScopedData()
                refreshWorkoutHistoryFromV2(reset: true)
                infoToastMessage = "Локальные данные профиля «\(profile.label)» удалены. Apple Health и ранее переданные копии сохранены."
            } catch {
                erasedProfiles = (try? await telemetryV2Coordinator.erasedProfileIdentifiers()) ?? erasedProfiles
                infoToastMessage = "Удаление не завершено. Часть данных могла быть удалена. Повторите попытку; файлы с неясной принадлежностью сохранены."
                refreshWorkoutHistoryFromV2(reset: true)
            }
        }
    }

    private func loadHrSettings() {
        cancelAppleHeartRateZoneRead()
        var loadedHeartRateZones: HeartRateZoneSettings?
        heartRateZoneSettings = HeartRateZoneSettings()
        isLoadingHrSettings = true
        applyDefaultHrSettings()

        defer {
            normalizeAdaptivePercentThresholdSettings()
            normalizeZoneBounds()
            heartRateZoneSettings = .restored(loadedHeartRateZones, legacyBounds: currentHeartRateZoneBounds)
            if #unavailable(iOS 27.0) { heartRateZoneSettings.source = .manual }
            applyHeartRateZoneBounds(heartRateZoneSettings.effectiveUpperBounds)
            isLoadingHrSettings = false
            saveHrSettingsIfNeeded()
        }

        guard let activeUserProfileID else { return }
        let key = profileScopedStoreKey(hrSettingsStoreKey, profileID: activeUserProfileID)
        guard let data = UserDefaults.standard.data(forKey: key),
              let dto = try? JSONDecoder().decode(HRSettingsDTO.self, from: data) else {
            return
        }

        loadedHeartRateZones = dto.heartRateZones
        hrTargetBPM = max(60, min(220, dto.targetBpm))
        hrDurationMinutes = max(1, min(120, dto.durationMinutes))
        hrAdaptiveStepEnabled = dto.adaptiveStepEnabled
        hrDecisionIntervalSeconds = max(HRDomainService.minimumDecisionIntervalSeconds, min(60, dto.decisionIntervalSeconds))
        let step = max(0.1, min(2.0, dto.speedStepKmh))
        hrSpeedStepKmh = (step * 10).rounded() / 10.0
        if let value = dto.adaptiveDeadbandPercent {
            hrAdaptiveDeadbandPercent = quantizeAdaptivePercent(max(1.0, min(15.0, value)))
        }
        if let value = dto.adaptiveDownLevel2StartPercent {
            hrAdaptiveDownLevel2StartPercent = quantizeAdaptivePercent(max(2.0, min(30.0, value)))
        }
        if let value = dto.adaptiveDownLevel3StartPercent {
            hrAdaptiveDownLevel3StartPercent = quantizeAdaptivePercent(max(2.0, min(40.0, value)))
        }
        if let value = dto.adaptiveDownLevel4StartPercent {
            hrAdaptiveDownLevel4StartPercent = quantizeAdaptivePercent(max(3.0, min(60.0, value)))
        }
        if let value = dto.adaptiveUpLevel2StartPercent {
            hrAdaptiveUpLevel2StartPercent = quantizeAdaptivePercent(max(2.0, min(40.0, value)))
        }
        if let value = dto.adaptiveUpLevel3StartPercent {
            hrAdaptiveUpLevel3StartPercent = quantizeAdaptivePercent(max(3.0, min(60.0, value)))
        }
        if let value = dto.adaptiveUpLevel4StartPercent {
            hrAdaptiveUpLevel4StartPercent = quantizeAdaptivePercent(max(4.0, min(80.0, value)))
        }
        if let window = dto.trendWindowSeconds {
            hrTrendWindowSeconds = max(15, min(30, window))
        }
        if let alpha = dto.trendEmaAlpha {
            hrTrendEmaAlpha = max(0.2, min(0.4, alpha))
        }
        if let slope = dto.trendSlopeMaxBpmPerSecond {
            hrTrendSlopeMaxBpmPerSecond = max(0.3, min(1.0, slope))
        }
        if let z1 = dto.zone1Max { hrZone1Max = max(80, min(200, z1)) }
        if let z2 = dto.zone2Max { hrZone2Max = max(81, min(210, z2)) }
        if let z3 = dto.zone3Max { hrZone3Max = max(82, min(220, z3)) }
        if let z4 = dto.zone4Max { hrZone4Max = max(83, min(230, z4)) }
        if let cooldownTarget = dto.cooldownTargetBpm {
            hrCooldownTargetBpm = HRSettingsDefaults.resolvedCooldownTargetBpm(savedValue: cooldownTarget)
        }
        if let cooldownMin = dto.cooldownMinSpeed {
            hrCooldownMinSpeed = max(2.0, min(6.0, cooldownMin))
        }
        if let cooldownMaxMinutes = dto.cooldownMaxMinutes {
            hrCooldownMaxMinutes = max(1, min(30, cooldownMaxMinutes))
        }
    }

    @Published private(set) var heartRateZoneSettings = HeartRateZoneSettings()
    @Published private(set) var heartRateZoneReadInFlight = false
    @Published private(set) var heartRateZoneReadError: String?
    private var heartRateZoneReadRequest: HeartRateZoneSettings.AppleReadRequest?

    // Reuse the existing idle-profile safety gate, including Stop/recovery/storage ownership.
    var canEditHeartRateZoneSettings: Bool { profileDataAvailable && canDeleteUserProfile }

    private var currentHeartRateZoneBounds: [Int] {
        [hrZone1Max, hrZone2Max, hrZone3Max, hrZone4Max]
    }

    func cancelAppleHeartRateZoneRead() {
        heartRateZoneReadRequest = nil
        heartRateZoneReadInFlight = false
        heartRateZoneReadError = nil
    }

    private func applyHeartRateZoneBounds(_ bounds: [Int]) {
        guard HeartRateZoneSettings.validBounds(bounds) else { return }
        isAdjustingZoneBounds = true
        hrZone1Max = bounds[0]
        hrZone2Max = bounds[1]
        hrZone3Max = bounds[2]
        hrZone4Max = bounds[3]
        isAdjustingZoneBounds = false
        saveHrSettingsIfNeeded()
    }

    func useManualHeartRateZones() {
        guard canEditHeartRateZoneSettings else { return }
        cancelAppleHeartRateZoneRead()
        heartRateZoneSettings.source = .manual
        applyHeartRateZoneBounds(heartRateZoneSettings.manualUpperBounds)
    }

    func updateManualHeartRateZone(index: Int, upperBound: Int) {
        guard canEditHeartRateZoneSettings, !heartRateZoneReadInFlight,
              heartRateZoneSettings.source == .manual, (0..<4).contains(index) else { return }
        var bounds = heartRateZoneSettings.manualUpperBounds
        bounds[index] = upperBound
        guard HeartRateZoneSettings.validBounds(bounds) else { return }
        heartRateZoneSettings.manualUpperBounds = bounds
        applyHeartRateZoneBounds(bounds)
    }

    @discardableResult
    func updateMaximumHeartRate(_ value: Int?) -> Bool {
        guard canEditHeartRateZoneSettings, HeartRateZoneSettings.validMaximum(value) else { return false }
        heartRateZoneSettings.maximumHeartRate = value
        saveHrSettingsIfNeeded()
        return true
    }

    func readAppleHeartRateZones(requestAuthorization: Bool) async {
        guard #available(iOS 27.0, *), canEditHeartRateZoneSettings,
              !heartRateZoneReadInFlight, let profileID = activeUserProfileID,
              requestAuthorization || heartRateZoneSettings.source == .appleHealth else { return }
        let request = HeartRateZoneSettings.AppleReadRequest(profileID: profileID)
        heartRateZoneReadRequest = request
        heartRateZoneReadInFlight = true
        heartRateZoneReadError = nil
        defer {
            if heartRateZoneReadRequest == request {
                heartRateZoneReadRequest = nil
                heartRateZoneReadInFlight = false
            }
        }
        do {
            let snapshot = try await AppleHeartRateZoneProvider.read(
                from: healthStore, requestAuthorization: requestAuthorization
            )
            guard request.canApply(current: heartRateZoneReadRequest, activeProfileID: activeUserProfileID,
                                   settingsEditable: canEditHeartRateZoneSettings, taskCancelled: Task.isCancelled),
                  let bounds = snapshot.upperBounds else { return }
            heartRateZoneSettings.appleSnapshot = snapshot
            heartRateZoneSettings.source = .appleHealth
            applyHeartRateZoneBounds(bounds)
        } catch {
            guard request.canApply(current: heartRateZoneReadRequest, activeProfileID: activeUserProfileID,
                                   settingsEditable: canEditHeartRateZoneSettings, taskCancelled: Task.isCancelled) else { return }
            heartRateZoneReadError = (error as? AppleHeartRateZoneProvider.ReadError)?.errorDescription
                ?? "Не удалось обновить зоны Apple Health. Проверьте доступ и повторите попытку. Сохранённые границы не изменены."
        }
    }

    private func saveHrSettingsIfNeeded() {
        guard !isLoadingHrSettings,
              let activeUserProfileID else { return }
        saveHrSettings(profileID: activeUserProfileID)
    }

    private func quantizeAdaptivePercent(_ value: Double) -> Double {
        (value * 2.0).rounded() / 2.0
    }

    private func normalizeAdaptivePercentThresholdSettings() {
        let deadband = quantizeAdaptivePercent(max(1.0, min(15.0, hrAdaptiveDeadbandPercent)))
        let downL2 = quantizeAdaptivePercent(max(deadband + 0.5, min(30.0, hrAdaptiveDownLevel2StartPercent)))
        let downL3 = quantizeAdaptivePercent(max(downL2 + 0.5, min(40.0, hrAdaptiveDownLevel3StartPercent)))
        let downL4 = quantizeAdaptivePercent(max(downL3 + 0.5, min(60.0, hrAdaptiveDownLevel4StartPercent)))
        let upL2 = quantizeAdaptivePercent(max(deadband + 0.5, min(40.0, hrAdaptiveUpLevel2StartPercent)))
        let upL3 = quantizeAdaptivePercent(max(upL2 + 0.5, min(60.0, hrAdaptiveUpLevel3StartPercent)))
        let upL4 = quantizeAdaptivePercent(max(upL3 + 0.5, min(80.0, hrAdaptiveUpLevel4StartPercent)))
        hrAdaptiveDeadbandPercent = deadband
        hrAdaptiveDownLevel2StartPercent = downL2
        hrAdaptiveDownLevel3StartPercent = downL3
        hrAdaptiveDownLevel4StartPercent = downL4
        hrAdaptiveUpLevel2StartPercent = upL2
        hrAdaptiveUpLevel3StartPercent = upL3
        hrAdaptiveUpLevel4StartPercent = upL4
    }

    private func normalizeZonePlan(_ plan: [Int]) -> [Int] {
        var values = plan
        if values.count < 5 {
            values.append(contentsOf: Array(repeating: 0, count: 5 - values.count))
        } else if values.count > 5 {
            values = Array(values.prefix(5))
        }
        return values.map { max(0, min(2000, $0)) }
    }

    private func loadZonePlan() {
        isUpdatingZonePlan = true
        defer { isUpdatingZonePlan = false }
        zonePlanMinutes = Array(repeating: 0, count: 5)

        guard let activeUserProfileID else { return }
        let key = profileScopedStoreKey(zonePlanStoreKey, profileID: activeUserProfileID)
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([Int].self, from: data) else {
            return
        }
        zonePlanMinutes = normalizeZonePlan(list)
    }

    private func saveZonePlan() {
        guard let activeUserProfileID else { return }
        saveZonePlan(profileID: activeUserProfileID)
    }

    private func normalizeZoneBounds() {
        guard !isAdjustingZoneBounds else { return }
        isAdjustingZoneBounds = true
        defer {
            isAdjustingZoneBounds = false
            saveHrSettingsIfNeeded()
        }
        let z1 = max(80, min(200, hrZone1Max))
        let z2 = max(z1 + 1, min(210, hrZone2Max))
        let z3 = max(z2 + 1, min(220, hrZone3Max))
        let z4 = max(z3 + 1, min(230, hrZone4Max))
        if hrZone1Max != z1 { hrZone1Max = z1 }
        if hrZone2Max != z2 { hrZone2Max = z2 }
        if hrZone3Max != z3 { hrZone3Max = z3 }
        if hrZone4Max != z4 { hrZone4Max = z4 }
    }

    private func zoneIndex(for bpm: Int) -> Int {
        if bpm <= hrZone1Max { return 0 }
        if bpm <= hrZone2Max { return 1 }
        if bpm <= hrZone3Max { return 2 }
        if bpm <= hrZone4Max { return 3 }
        return 4
    }

    @Published var allowAutoConnectUnknown: Bool = false

    // Heart rate
    let heartRateFactualState = HeartRateFactualState()
    var heartRateBPM: Int {
        get { heartRateFactualState.heartRateBPM }
        set {
            heartRateFactualState.heartRateBPM = newValue
            publishTrainingUIHeartRateIfNeeded()
        }
    }
    var lastKnownHeartRateBPM: Int {
        get { heartRateFactualState.lastKnownHeartRateBPM }
        set {
            heartRateFactualState.lastKnownHeartRateBPM = newValue
            publishTrainingUIHeartRateIfNeeded()
        }
    }
    var hrStreamingActive: Bool {
        get { heartRateFactualState.isStreamActive }
        set {
            heartRateFactualState.isStreamActive = newValue
            publishTrainingUIHeartRateIfNeeded()
        }
    }
    var hrLastValueAt: Date? {
        get { heartRateFactualState.lastValueAt }
        set {
            heartRateFactualState.lastValueAt = newValue
            publishTrainingUIHeartRateIfNeeded()
        }
    }
    var hrDataStaleSeconds: Int {
        get { heartRateFactualState.staleSeconds }
        set {
            heartRateFactualState.staleSeconds = newValue
            publishTrainingUIHeartRateIfNeeded()
        }
    }
    @Published var treadmillStatusText: String = "unknown"
    @Published private(set) var stopTruthStatusText: String = ""
    @Published var lastNotifyAgeSeconds: Int = 0
    @Published var lastCommandAckStatusText: String = ""
    @Published var lastCommandTimeoutsCount: Int = 0
    let treadmillFactualObservationPublisher = TreadmillFactualObservationPublisher()
    var deviceReportedSpeedKmh: Double = 0
    var deviceReportedAppSpeedKmh: Double = 0
    var deviceReportedState: Int = 0
    var deviceReportedManualMode: Int = 0
    var deviceReportedTimeSeconds: Int = 0
    var deviceReportedDistance10m: Int = 0
    var deviceReportedSteps: Int = 0
    var deviceReportedButton: Int = 0
    var deviceReportedChecksumOk: Bool = true
    var deviceReportedRawHex: String = ""
    @Published private(set) var trainingUITreadmillSpeedKmh: Double? = nil
    @Published private(set) var trainingUIHeartRateSnapshot =
        TrainingUIHeartRatePublicationPolicy.snapshot(
            isNativeHeartRateCurrent: false,
            isHeartRateStreamActive: false,
            heartRateBPM: 0
        )
    @Published private(set) var controllerUnitsTruth: ControllerUnitsTruth = .disconnected
    @Published private(set) var treadmillTestRunIsActive = false
    @Published private(set) var treadmillTestRunStatusText = "READY"
    @Published private(set) var treadmillTestRunHeartRateDiagnosticSnapshot =
        TestRunHeartRateDiagnosticService.Snapshot.idle
#if STOP_TRUTH_EXPERIMENT_CAPABILITY
    @Published private(set) var stopTruthExperimentStatus: String = "disabled"
    @Published private(set) var stopTruthExperimentArtifactPath: String = ""
#endif

    // HR control
    @Published var isHrControlRunning: Bool = false {
        didSet { synchronizeWorkoutIdleTimerOwnership() }
    }
    @Published var isHrControlStartAllowed: Bool = false
    @Published var hrControlStartBlockReasonText: String? = nil
    @Published private(set) var isNativeHeartRatePreflightActive: Bool = false
    private(set) var isNativeHeartRateCurrent: Bool {
        get { heartRateFactualState.isNativeCurrent }
        set {
            heartRateFactualState.isNativeCurrent = newValue
            publishTrainingUIHeartRateIfNeeded()
        }
    }
    @Published private(set) var isNativeWorkoutRecoveryActive: Bool = false
    @Published private(set) var nativeWorkoutRecoveryStatusText: String? = nil

    private var nativeHeartRatePreflightEngine = NativeHeartRatePreflightEngine()
    private var nativeHeartRateAppActivity: NativeHeartRatePreflightEngine.AppActivity = .inactive {
        didSet { synchronizeWorkoutIdleTimerOwnership() }
    }
    private var isTrainingHubVisible = false
    private var nativeHeartRateFlowOwnsController = false
    private var nativeHeartRateProviderLifecycle = NativeHeartRateProviderLifecycle()
    private var nativeHealthKitWorkoutCommitted = false {
        didSet { synchronizeWorkoutIdleTimerOwnership() }
    }
    private var workoutIdleTimerOwnership = WorkoutIdleTimerOwnership()
    private var nativeHealthKitWorkoutFinishInFlight = false
    private var nativePreflightCommitTimestamps: (
        acquisitionStartedAt: Date,
        measuredAt: Date?,
        receivedAt: Date
    )?
    private var pendingNativePreflightHeartRate: HeartRateNormalizationResult?

    var isHrControlStartAffordanceAvailable: Bool {
        isHrControlStartAllowed && !isNativeHeartRatePreflightActive
    }

    @Published var hrNextDecisionSeconds: Int = 0
    private var hrLastDecisionAt: ContinuousClock.Instant?
    @Published var hrRemainingSeconds: Int = 0
    @Published var hrCooldownRemainingSeconds: Int = 0
    @Published private(set) var intervalWorkoutSelected = false
    @Published private(set) var intervalCycleCount = 1
    @Published private(set) var intervalWorkoutState: IntervalWorkoutRuntime.State?
    private var pendingIntervalPlan: IntervalWorkoutRuntime.Plan?
    private var hrControlStartedInstant: ContinuousClock.Instant?

    var intervalStartBlockReason: String? {
        intervalWorkoutSelected && IntervalWorkoutRuntime.Plan(
            maximumHeartRate: heartRateZoneSettings.maximumHeartRate, cycles: intervalCycleCount
        ) == nil ? "Укажите максимальный пульс в параметрах пульсовых зон" : nil
    }

    func selectIntervalWorkout(_ selected: Bool) {
        guard !shouldPresentActiveWorkout, !isNativeHeartRatePreflightActive else { return }
        intervalWorkoutSelected = selected
    }

    func selectIntervalCycles(_ cycles: Int) {
        guard !shouldPresentActiveWorkout, !isNativeHeartRatePreflightActive,
              (1...4).contains(cycles) else { return }
        intervalCycleCount = cycles
    }

    var activeHRControlTargetBPM: Int {
        guard isHrControlRunning, let state = intervalWorkoutState else { return hrTargetBPM }
        return state.phase == .cooldown ? hrCooldownTargetBpm : state.targetBPM
    }

    var intervalOutcomeMessage: String? {
        guard let state = intervalWorkoutState else { return nil }
        switch state.finishReason {
        case "cycles_completed": return nil
        case "above_95_percent": return "Интервалы завершены досрочно: пульс выше 95% максимального."
        case "recovery_target_not_reached": return "Интервалы завершены досрочно: пульс не снизился до цели восстановления."
        case "heart_rate_unavailable_at_transition": return "Интервалы завершены досрочно: нет свежего пульса для следующего этапа."
        default: return "Интервалы прерваны."
        }
    }

    var intervalPhaseTitle: String? {
        guard isHrControlRunning, let state = intervalWorkoutState else { return nil }
        switch state.phase {
        case .warmup: return "РАЗМИНКА"
        case .work: return "НАГРУЗКА \(state.cycle)/\(state.plan.cycles)"
        case .recovery: return "ВОССТАНОВЛЕНИЕ \(state.cycle)/\(state.plan.cycles)"
        case .cooldown: return "ЗАМИНКА"
        }
    }

    @Published var hrProgress: Double = 0
    @Published var hrCooldownProgress: Double = 0
    @Published var hrTargetBPM: Int = 130 {
        didSet {
            guard !isRestoringNativeWorkoutRecoveryState else { return }
            saveHrSettingsIfNeeded()
        }
    }
    @Published var hrDurationMinutes: Int = 10 {
        didSet {
            guard !isRestoringNativeWorkoutRecoveryState else { return }
            saveHrSettingsIfNeeded()
        }
    }
    @Published var hrAdaptiveStepEnabled: Bool = true { didSet { saveHrSettingsIfNeeded() } }
    @Published var hrDecisionIntervalSeconds: Int = 10 { didSet { saveHrSettingsIfNeeded() } }
    @Published var hrSpeedStepKmh: Double = 0.5 { didSet { saveHrSettingsIfNeeded() } }
    @Published var hrAdaptiveDeadbandPercent: Double = 3.0 { didSet { saveHrSettingsIfNeeded() } }
    @Published var hrAdaptiveDownLevel2StartPercent: Double = 8.0 { didSet { saveHrSettingsIfNeeded() } }
    @Published var hrAdaptiveDownLevel3StartPercent: Double = 15.0 { didSet { saveHrSettingsIfNeeded() } }
    @Published var hrAdaptiveDownLevel4StartPercent: Double = 23.0 { didSet { saveHrSettingsIfNeeded() } }
    @Published var hrAdaptiveUpLevel2StartPercent: Double = 23.0 { didSet { saveHrSettingsIfNeeded() } }
    @Published var hrAdaptiveUpLevel3StartPercent: Double = 31.0 { didSet { saveHrSettingsIfNeeded() } }
    @Published var hrAdaptiveUpLevel4StartPercent: Double = 46.0 { didSet { saveHrSettingsIfNeeded() } }
    @Published var hrTrendWindowSeconds: Double = 20 { didSet { saveHrSettingsIfNeeded() } }
    @Published var hrTrendEmaAlpha: Double = 0.25 { didSet { saveHrSettingsIfNeeded() } }
    @Published var hrTrendSlopeMaxBpmPerSecond: Double = 0.6 { didSet { saveHrSettingsIfNeeded() } }
    @Published var hrZone1Max: Int = 134 { didSet { normalizeZoneBounds() } }
    @Published var hrZone2Max: Int = 146 { didSet { normalizeZoneBounds() } }
    @Published var hrZone3Max: Int = 158 { didSet { normalizeZoneBounds() } }
    @Published var hrZone4Max: Int = 170 { didSet { normalizeZoneBounds() } }
    @Published var zonePlanMinutes: [Int] = Array(repeating: 0, count: 5) {
        didSet {
            guard !isUpdatingZonePlan else { return }
            let normalized = normalizeZonePlan(zonePlanMinutes)
            if normalized != zonePlanMinutes {
                isUpdatingZonePlan = true
                zonePlanMinutes = normalized
                isUpdatingZonePlan = false
                return
            }
            saveZonePlan()
        }
    }
    @Published var hrStatusLine: String = ""
    @Published var lastSpeedDeltaKmh: Double = 0
    @Published var hrDecisionDetails: String = ""
    @Published var hrPredictorStatusLine: String = ""

    // Metrics
    @Published var speedKmh: Double = 0
    @Published var desiredSpeedKmh: Double = 0
    @Published var deviceTargetSpeedKmh: Double = 0
    @Published var hrAverageBPM: Int = 0
    @Published var avgSpeedKmh: Double = 0
    @Published var avgSpeedActive: Bool = false
    @Published var beatsPerMeter: Double? = nil

    // Session stats
    @Published var timeSec: Int = 0
    @Published var distKm: Double = 0
    @Published var stepsCount: Int = 0

    private func resetSessionStats() {
        timeSec = 0
        distKm = 0
        stepsCount = 0
        avgSpeedKmh = 0
        avgSpeedActive = false
        hrAverageBPM = 0
        beatsPerMeter = nil
        lastSpeedDeltaKmh = 0
        hrAverageSum = 0
        hrAverageCount = 0
        hrSessionPeakBPM = 0
        hrMainSumBPM = 0
        hrMainCountBPM = 0
        hrMainPeakBPM = 0
        clearCooldownRuntimeState()
        hrZoneSeconds = Array(repeating: 0, count: 5)
    }

    // Simulation / scheduling
    private var telemetryTimer: Timer?
    private var hrStaleTimer: Timer?
    private let hrStaleThresholdSeconds: Int = 7
    private let mainQueue = DispatchQueue.main

    // Logs / failures

    private func zoneSecondsSnapshot() -> [Int] {
        var out = Array(hrZoneSeconds.prefix(5))
        while out.count < 5 { out.append(0) }
        return out
    }

    private func zone4PlusSecondsSnapshot() -> Int {
        let zones = zoneSecondsSnapshot()
        return zones[3] + zones[4]
    }

    private func mainPhaseAverageBPMSnapshot() -> Int {
        guard hrMainCountBPM > 0 else { return hrAverageBPM }
        return Int(round(Double(hrMainSumBPM) / Double(hrMainCountBPM)))
    }

    private func syncPublishedCooldownRuntimeState() {
        hrCooldownRemainingSeconds = cooldownRuntimeState?.remainingSeconds ?? 0
        hrCooldownProgress = cooldownRuntimeState?.progress ?? 0
    }

    private func clearCooldownRuntimeState() {
        cooldownRuntimeState = nil
        cooldownStartedInstant = nil
        syncPublishedCooldownRuntimeState()
    }

    private func currentCooldownConfig() -> CooldownRuntimeEngine.Config {
        CooldownRuntimeEngine.Config(
            targetBpm: hrCooldownTargetBpm,
            minSpeedKmh: hrCooldownMinSpeed,
            maxMinutes: hrCooldownMaxMinutes,
            baseStepKmh: max(0.1, min(2.0, hrSpeedStepKmh)),
            stepIntervalSeconds: max(1, hrDecisionIntervalSeconds)
        )
    }

    private func currentCooldownSessionAggregates() -> CooldownRuntimeEngine.SessionAggregates {
        CooldownRuntimeEngine.SessionAggregates(
            sessionPeakBpm: hrSessionPeakBPM,
            mainAvgBpm: mainPhaseAverageBPMSnapshot(),
            mainPeakBpm: hrMainPeakBPM,
            zoneSeconds: zoneSecondsSnapshot(),
            zone4PlusSeconds: zone4PlusSecondsSnapshot()
        )
    }

    private func currentCooldownSpeedSnapshot() -> HRDomainService.CooldownSpeedSnapshot {
        HRDomainService.cooldownSpeedSnapshot(
            desiredSpeedKmh: desiredSpeedKmh,
            deviceTargetSpeedKmh: deviceTargetSpeedKmh,
            observation: latestTreadmillObservationEvidence,
            connectionEpoch: treadmillTelemetryConnectionEpoch,
            sessionStartedAt: hrControlStartedAt,
            now: Date(),
            freshnessLimit: StopObservationPolicy.freshnessInterval
        )
    }

    private func publishTrainingUITreadmillSpeedIfNeeded() {
        treadmillFactualObservationPublisher.publish()
        guard TrainingUITreadmillPublicationPolicy.shouldPublish(
            currentVisibleSpeedKmh: trainingUITreadmillSpeedKmh,
            appReportedSpeedKmh: deviceReportedAppSpeedKmh,
            rawReportedSpeedKmh: deviceReportedSpeedKmh
        ) else { return }
        trainingUITreadmillSpeedKmh = TrainingUITreadmillPublicationPolicy.visibleSpeedKmh(
            appReportedSpeedKmh: deviceReportedAppSpeedKmh,
            rawReportedSpeedKmh: deviceReportedSpeedKmh
        )
    }

    private func publishTrainingUIHeartRateIfNeeded() {
        let nextSnapshot = TrainingUIHeartRatePublicationPolicy.snapshot(
            isNativeHeartRateCurrent: isNativeHeartRateCurrent,
            isHeartRateStreamActive: hrStreamingActive,
            heartRateBPM: heartRateBPM
        )
        guard nextSnapshot != trainingUIHeartRateSnapshot else { return }
        trainingUIHeartRateSnapshot = nextSnapshot
    }

    private func applyCooldownOutput(
        _ output: CooldownRuntimeEngine.Output
    ) {
        cooldownRuntimeState = output.state
        syncPublishedCooldownRuntimeState()

        for effect in output.effects {
            executeCooldownEffect(effect)
        }
    }

    private func executeCooldownEffect(
        _ effect: CooldownRuntimeEngine.Effect
    ) {
        switch effect {
        case .status(let presentation):
            hrStatusLine = presentation.statusLine
            hrDecisionDetails = presentation.decisionDetails
            hrCooldownRemainingSeconds = presentation.remainingSeconds
            hrCooldownProgress = presentation.progress

        case .setSpeed(let speedEffect):
            guard isTreadmillControlReady else {
                return
            }
            let old = deviceTargetSpeedKmh
            desiredSpeedKmh = speedEffect.targetKmh
            deviceTargetSpeedKmh = speedEffect.targetKmh
            recordSpeedChange(from: old, to: speedEffect.targetKmh, reason: "cooldown_set")
            let telemetryDecision = makeTreadmillDecision(
                source: .cooldown,
                intent: .setDesiredSpeed(
                    DesiredSpeedKilometresPerHour(value: speedEffect.targetKmh)
                )
            )
            defer { observeTreadmillDecision(telemetryDecision) }
            sendTreadmillSetSpeed(
                speedEffect.targetKmh,
                label: String(format: "SPEED %.1f km/h (cooldown)", speedEffect.targetKmh),
                decision: telemetryDecision
            )

        case .telemetry(let telemetryEffect):
            logCooldownTelemetry(telemetryEffect)

        case .complete(let completionEffect):
            if completionEffect.shouldStopSession {
                isHrControlRunning = false
                hrControlStartedAt = nil
            }

            if completionEffect.shouldStopBelt {
                stopBeltWithToggle(reason: "hr_cooldown_done")
            }
            if completionEffect.shouldStopSession {
                endTelemetryV2Session(reason: completionEffect.structuredLogReason)
            }
        }
    }

    private func logCooldownTelemetry(_ effect: CooldownRuntimeEngine.TelemetryEffect) {
        let now = Date()
        switch effect {
        case let .start(telemetry):
            _ = telemetryV2Coordinator.observeWorkoutPhase(.cooldown, occurredAt: now)
            _ = telemetryV2Coordinator.observeEvent(
                .cooldown(CooldownEvent(lifecycle: .started,
                    targetHeartRate: UInt16(exactly: telemetry.targetBpm))), occurredAt: now
            )
        case .complete:
            _ = telemetryV2Coordinator.observeEvent(
                .cooldown(CooldownEvent(lifecycle: .completed)), occurredAt: now
            )
        case .insufficient:
            _ = telemetryV2Coordinator.observeEvent(
                .cooldown(CooldownEvent(lifecycle: .insufficient)), occurredAt: now
            )
        case .speedSet, .state, .analysis:
            break
        }
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    // UI messaging hooks
    @Published var connectErrorMessage: String? = nil
    @Published var suggestDevicePicker: Bool = false
    @Published var infoToastMessage: String? = nil

    func consumeConnectErrorMessage() {
        connectErrorMessage = nil
    }

    // History

    enum WorkoutReadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var telemetryV2WorkoutHistory: [WorkoutHistoryProjection] = []
    @Published private(set) var telemetryV2WorkoutHistoryState: WorkoutReadState = .idle
    @Published private(set) var telemetryV2WorkoutHistoryHasMore: Bool = false
    @Published private(set) var telemetryV2Statistics: [String: WorkoutStatisticsProjection] = [:]
    @Published private(set) var telemetryV2StatisticsState: [String: WorkoutReadState] = [:]
    @Published private(set) var telemetryV2ProjectionGeneration: UInt = 0
    private var telemetryV2WorkoutHistoryCursor: WorkoutHistoryCursor? = nil
    private var telemetryV2WorkoutReadRequestID: UUID? = nil
    private let telemetryV2WorkoutPageSize = 50

    func terminalAnalysisFailed(sessionID: SessionID) -> Bool {
        let result = telemetryV2Coordinator.terminalAnalysisResult(for: sessionID)
        return result == .failed || result == .ineligible
    }

    func summaryAnalysisState(for projection: WorkoutHistoryProjection) -> WorkoutSummaryAnalysisState {
        guard projection.origin == .nativeV2,
              projection.id.hasPrefix("native:"),
              let sessionID = UUID(uuidString: String(projection.id.dropFirst("native:".count))) else {
            return .failed
        }
        let result = telemetryV2Coordinator.terminalAnalysisResult(for: SessionID(rawValue: sessionID))
        return projection.summaryAnalysisState(terminalResult: result)
    }

    private func telemetryV2ProjectionDidChange() {
        telemetryV2ProjectionGeneration &+= 1
        telemetryV2Statistics.removeAll()
        telemetryV2StatisticsState.removeAll()
        refreshWorkoutHistoryFromV2(reset: true)
    }

    private func activeWorkoutReadFilter(
        startedAtOrAfter: Date? = nil,
        startedBefore: Date? = nil
    ) -> WorkoutReadFilter? {
        guard let profileID = activeUserProfileID else { return nil }
        return WorkoutReadFilter(
            profileScope: .exact(profileID.uuidString),
            startedAtOrAfter: startedAtOrAfter,
            startedBefore: startedBefore
        )
    }

    func refreshWorkoutHistoryFromV2(reset: Bool = true) {
        guard let filter = activeWorkoutReadFilter(),
              let requestedProfileID = activeUserProfileID else {
            telemetryV2WorkoutHistory = []
            telemetryV2WorkoutHistoryState = .failed("active-profile-unavailable")
            telemetryV2WorkoutHistoryHasMore = false
            telemetryV2WorkoutHistoryCursor = nil
            return
        }

        if reset {
            telemetryV2WorkoutHistory = []
            telemetryV2WorkoutHistoryCursor = nil
        }
        telemetryV2WorkoutHistoryState = .loading
        let cursor = telemetryV2WorkoutHistoryCursor
        let requestID = UUID()
        telemetryV2WorkoutReadRequestID = requestID

        Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await self.telemetryV2Coordinator.fetchWorkoutHistoryPage(
                    filter: filter,
                    after: cursor,
                    limit: self.telemetryV2WorkoutPageSize
                )
                await MainActor.run {
                    guard self.activeUserProfileID == requestedProfileID,
                          self.telemetryV2WorkoutReadRequestID == requestID else { return }
                    if reset {
                        self.telemetryV2WorkoutHistory = page.items
                    } else {
                        let existingIDs = Set(self.telemetryV2WorkoutHistory.map(\.id))
                        self.telemetryV2WorkoutHistory.append(
                            contentsOf: page.items.filter { !existingIDs.contains($0.id) }
                        )
                    }
                    self.telemetryV2WorkoutHistoryCursor = page.nextCursor
                    self.telemetryV2WorkoutHistoryHasMore = page.nextCursor != nil
                    self.telemetryV2WorkoutHistoryState = .loaded
                }
            } catch {
                await MainActor.run {
                    guard self.activeUserProfileID == requestedProfileID,
                          self.telemetryV2WorkoutReadRequestID == requestID else { return }
                    self.telemetryV2WorkoutHistoryState = .failed(error.localizedDescription)
                }
            }
        }
    }

    func loadNextWorkoutHistoryPageFromV2() {
        guard telemetryV2WorkoutHistoryHasMore,
              telemetryV2WorkoutHistoryState != .loading else { return }
        refreshWorkoutHistoryFromV2(reset: false)
    }

    func workoutStatisticsKey(for interval: DateInterval) -> String {
        let profile = activeUserProfileID?.uuidString ?? "unassigned"
        return "\(profile)|\(interval.start.timeIntervalSince1970)|\(interval.end.timeIntervalSince1970)"
    }

    @MainActor
    func refreshWorkoutStatisticsFromV2(
        for interval: DateInterval,
        retaining periods: [DateInterval]
    ) async {
        guard !Task.isCancelled,
              let filter = activeWorkoutReadFilter(
                startedAtOrAfter: interval.start,
                startedBefore: interval.end
              ), let requestedProfileID = activeUserProfileID else { return }
        let key = workoutStatisticsKey(for: interval)
        let retainedKeys = Set(periods.prefix(2).map { workoutStatisticsKey(for: $0) })
        guard retainedKeys.contains(key) else { return }
        telemetryV2Statistics = telemetryV2Statistics.filter { retainedKeys.contains($0.key) }
        telemetryV2StatisticsState = telemetryV2StatisticsState.filter { retainedKeys.contains($0.key) }
        let requestedProjectionGeneration = telemetryV2ProjectionGeneration
        telemetryV2StatisticsState[key] = .loading

        do {
            try Task.checkCancellation()
            let statistics = try await telemetryV2Coordinator.fetchWorkoutStatistics(
                filter: filter,
                batchSize: 100
            )
            try Task.checkCancellation()
            guard activeUserProfileID == requestedProfileID,
                  telemetryV2ProjectionGeneration == requestedProjectionGeneration,
                  telemetryV2StatisticsState[key] != nil else { return }
            telemetryV2Statistics[key] = statistics
            telemetryV2StatisticsState[key] = .loaded
        } catch is CancellationError {
            // SwiftUI owns the read lifetime; cancellation is not a read failure.
        } catch {
            guard !Task.isCancelled,
                  activeUserProfileID == requestedProfileID,
                  telemetryV2ProjectionGeneration == requestedProjectionGeneration,
                  telemetryV2StatisticsState[key] != nil else { return }
            telemetryV2StatisticsState[key] = .failed(error.localizedDescription)
        }
    }

    func prepareTelemetryV2Export(
        scope: WorkoutDiagnosticExportScope
    ) async throws -> WorkoutExportArtifact {
        guard let filter = activeWorkoutReadFilter() else {
            throw TelemetryWorkoutReadError.unavailable("active-profile-unavailable")
        }
        let selection: WorkoutExportSelection
        switch scope {
        case .all:
            selection = .all
        case .lastCompletedWorkouts(let count):
            selection = .latestCompleted(count)
        }
        return try await telemetryV2Coordinator.exportWorkouts(
            WorkoutExportRequest(filter: filter, selection: selection)
        )
    }

    func prepareWorkoutAnalysisExport(
        for entry: WorkoutHistoryProjection
    ) async throws -> WorkoutAnalysisExportArtifact {
        guard entry.origin == .nativeV2,
              entry.id.hasPrefix("native:"),
              let profileID = activeUserProfileID,
              let sessionUUID = UUID(uuidString: String(entry.id.dropFirst("native:".count))) else {
            throw TelemetryWorkoutReadError.unavailable("selected-native-workout-unavailable")
        }
        return try await telemetryV2Coordinator.exportWorkoutAnalysis(
            WorkoutAnalysisExportRequest(
                sessionID: SessionID(rawValue: sessionUUID),
                exactProfileLocalIdentifier: profileID.uuidString
            )
        )
    }

    func finalizeWorkoutAnalysisExport(_ artifact: WorkoutAnalysisExportArtifact) {
        try? FileManager.default.removeItem(
            at: artifact.fileURL.deletingLastPathComponent()
        )
    }

    func prepareDiagnosticBundle(
        scope: WorkoutDiagnosticExportScope,
        archiveName: String
    ) async throws -> DiagnosticBundleArtifact {
        guard !profileErasureInFlight, let profileID = activeUserProfileID else {
            throw TelemetryWorkoutReadError.unavailable("profile-export-unavailable")
        }
        cancelAppleHeartRateZoneRead()
        profileExportOperations += 1
        defer { profileExportOperations -= 1 }
        let supportSnapshot = diagnosticSupportSnapshot()
        let workoutArtifact: WorkoutExportArtifact
        do {
            workoutArtifact = try await prepareTelemetryV2Export(scope: scope)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try markDiagnosticOwnership(try await DiagnosticBundlePackager.createSupportOnly(
                supportSnapshot: supportSnapshot,
                archiveName: archiveName,
                workoutEvidenceFailureCategory: diagnosticWorkoutExportFailureCategory(error)
            ), profileID: profileID)
        }
        if workoutArtifact.exportedWorkoutCount == 0 {
            try? FileManager.default.removeItem(at: workoutArtifact.directoryURL)
            return try markDiagnosticOwnership(try await DiagnosticBundlePackager.createSupportOnly(
                supportSnapshot: supportSnapshot,
                archiveName: archiveName,
                workoutEvidenceStatus: "not_present",
                workoutEvidenceFailureCategory: "no_completed_workout"
            ), profileID: profileID)
        }
        do {
            return try await DiagnosticBundlePackager.create(
                workoutArtifact: workoutArtifact,
                supportSnapshot: supportSnapshot,
                archiveName: archiveName
            )
        } catch {
            try? FileManager.default.removeItem(at: workoutArtifact.directoryURL)
            throw error
        }
    }

    private func markDiagnosticOwnership(_ artifact: DiagnosticBundleArtifact, profileID: UUID) throws -> DiagnosticBundleArtifact {
        do {
            try ProfileErasureFiles.mark(artifact.directoryURL, profiles: [profileID.uuidString])
            return artifact
        } catch {
            try? FileManager.default.removeItem(at: artifact.directoryURL)
            throw error
        }
    }

    private func diagnosticWorkoutExportFailureCategory(_ error: Error) -> String {
        guard let error = error as? TelemetryWorkoutReadError else {
            return "unexpected_error"
        }
        return switch error {
        case .unavailable(_): "unavailable"
        case .invalidPageSize: "invalid_page_size"
        case .corruptProjection(_): "corrupt_projection"
        case .exportFailed(_): "export_failed"
        }
    }

    private func diagnosticSupportSnapshot(
        now: Date = Date()
    ) -> DiagnosticSupportSnapshot {
        let preflight = nativeHeartRatePreflightEngine.diagnosticSnapshot
        let controllerUnits = controllerUnitsDiagnosticSnapshot(now: now)
        let currentConnection = currentTreadmillControlConnection
        let writer = telemetryV2WriterHealthSnapshot
        let app = currentTelemetryV2AppContext
        let versions = currentTelemetryV2RuntimeVersions
        return DiagnosticSupportSnapshot(
            capturedAt: now,
            runtime: .init(
                appVersion: app.appVersion,
                buildNumber: app.buildNumber,
                operatingSystemVersion: app.operatingSystemVersion,
                telemetrySchemaVersion: versions.telemetrySchema.rawValue,
                algorithmVersion: versions.algorithm.rawValue,
                safetyPolicyVersion: versions.safetyPolicy.rawValue,
                workoutProtocolVersion: versions.workoutProtocol.rawValue
            ),
            nativeHeartRatePreflight: .init(
                phase: preflight.phase,
                requestedAt: preflight.requestedAt,
                providerPreparedAt: preflight.providerPreparedAt,
                collectionStartedAt: preflight.collectionStartedAt,
                firstNativeCallbackMeasuredAt: preflight.firstNativeCallbackMeasuredAt,
                firstNativeCallbackReceivedAt: preflight.firstNativeCallbackReceivedAt,
                firstQualifyingLatencySeconds: preflight.firstQualifyingLatencySeconds,
                terminalAt: preflight.terminalAt,
                terminalReason: preflight.terminalReason,
                gateBlockReason: preflight.gateBlockReason,
                providerState: iPhoneHealthKitHeartRateProvider.state.rawValue,
                providerCleanupInFlight: nativeHeartRateProviderLifecycle.cleanupInFlight,
                providerGeneration: nativeHeartRateProviderLifecycle.generation,
                providerHasBoundAttempt: nativeHeartRateProviderLifecycle.attemptID != nil,
                nativeWorkoutCommitted: nativeHealthKitWorkoutCommitted
            ),
            controllerUnits: .init(
                status: controllerUnits.status.rawValue,
                physicalUnits: controllerUnits.units.rawValue,
                observedAt: controllerUnits.observedAt,
                ageSeconds: controllerUnits.ageSeconds,
                isFresh: controllerUnits.isFresh,
                gateAllowed: controllerUnits.gateAllowed,
                blockReason: controllerUnits.blockReason?.rawValue,
                evidenceConnectionEpoch: controllerUnits.evidenceConnectionEpoch?.uuidString,
                currentConnectionEpoch: controllerUnits.currentConnectionEpoch?.uuidString,
                isCurrentConnection: controllerUnits.isCurrentConnection,
                byteCount: controllerUnits.byteCount,
                rawA6Hex: controllerUnits.rawHex
            ),
            treadmill: .init(
                protocolName: treadmillProtocol.rawValue,
                isConnected: isConnected,
                isControlReady: isTreadmillControlReady,
                hasCurrentConnectionContext: currentConnection != nil,
                protocolMatchesCurrentConnection: currentConnection != nil
                    && treadmillProtocolConnection == currentConnection,
                connectionEpoch: currentConnection?.epoch.uuidString
            ),
            writerHealth: .init(
                workoutReadState: telemetryV2WorkoutReadStateDiagnosticValue,
                runtimeLifecycle: writer.runtimeLifecycle.rawValue,
                recorderLifecycle: writer.recorderLifecycle?.rawValue,
                completeness: writer.completeness?.rawValue,
                queueDepth: writer.queueDepth,
                peakQueueDepth: writer.peakQueueDepth,
                coalescedFrameCount: writer.coalescedFrameCount,
                droppedFrameCount: writer.droppedFrameCount,
                lostNativeCount: writer.lostNativeCount,
                lostCriticalCount: writer.lostCriticalCount,
                writerFailureCount: writer.writerFailureCount,
                retryCount: writer.retryCount,
                successfulFlushCount: writer.successfulFlushCount,
                lastCommittedRecorderSequence: writer.lastCommittedRecorderSequence
            )
        )
    }

    private var telemetryV2WorkoutReadStateDiagnosticValue: String {
        switch telemetryV2WorkoutHistoryState {
        case .idle: "idle"
        case .loading: "loading"
        case .loaded: "loaded"
        case .failed(_): "failed"
        }
    }

    func finalizeDiagnosticBundle(_ artifact: DiagnosticBundleArtifact, completed: Bool) {
        do {
            try FileManager.default.removeItem(at: artifact.directoryURL)
        } catch {
        }
        infoToastMessage = completed
            ? "Diagnostic bundle shared. Source evidence was preserved."
            : "Diagnostic bundle cancelled. Source evidence was preserved."
    }

    // Lifecycle
    private func scheduleLegacyTelemetryMigration() {
        let knownProfiles = sortedProfiles(userProfiles).map {
            $0.id.uuidString.lowercased()
        }
        let deterministicFallbackProfile = UserDefaults.standard.string(forKey: legacyFallbackProfileStoreKey)
        telemetryV2Coordinator.scheduleLegacyMigrationInBackground {
            guard let logsDirectory = LegacyTelemetryMigrationSourceDiscovery
                .defaultTrainingLogsDirectory() else {
                return LegacyTelemetryMigrationRequest(
                    jsonlSources: [],
                    workoutHistorySources: [],
                    knownProfileLocalIdentifiers: Set(knownProfiles)
                )
            }
            return LegacyTelemetryMigrationSourceDiscovery.makeRequest(
                userDefaults: .standard,
                trainingLogsDirectory: logsDirectory,
                knownProfileLocalIdentifiers: knownProfiles,
                deterministicLegacyFallbackProfileLocalIdentifier:
                    deterministicFallbackProfile
            )
        }
    }

    func handleActiveWorkoutRecoveryRequest() {
        guard !didHandleActiveWorkoutRecoveryCallback else { return }
        activeWorkoutRecoveryRequestPending = true
        isNativeWorkoutRecoveryActive = true
        nativeWorkoutRecoveryStatusText = "Восстанавливаем тренировку…"
        recomputeHrStartAllowed()
    }

    func handleActiveWorkoutRecoveryAvailability(recoveryRequested: Bool) {
        if recoveryRequested {
            activeWorkoutRecoveryAvailability = true
            return
        }
        guard activeWorkoutRecoveryAvailability != true else { return }
        activeWorkoutRecoveryAvailability = false
        processNoActiveWorkoutRecoveryIfPossible()
    }

    func handleActiveWorkoutRecovery(
        session: HKWorkoutSession?,
        error: Error?
    ) {
        guard !didHandleActiveWorkoutRecoveryCallback else { return }
        didHandleActiveWorkoutRecoveryCallback = true
        activeWorkoutRecoveryRequestPending = false
        pendingActiveWorkoutRecoveryResult = (session, error)
        processPendingActiveWorkoutRecoveryIfPossible()
    }

    private var hasOutstandingNativeWorkoutRecovery: Bool {
        if activeWorkoutRecoveryRequestPending || isNativeWorkoutRecoveryActive {
            return true
        }
        switch nativeWorkoutRecoveryLoadResult {
        case .missing:
            return false
        case .invalid, .record:
            return true
        }
    }

    private var blocksNonStopTreadmillMotion: Bool {
        profileErasureInFlight || activeWorkoutRecoveryRequestPending
            || isNativeWorkoutRecoveryActive
            || pendingNativeWorkoutStopTerminalRequest != nil
            || activeNativeWorkoutRecoveryRecord?.phase == .stopping
            || activeNativeWorkoutRecoveryRecord?.phase == .finishing
    }

    private func loadNativeWorkoutRecoveryState() {
        guard let nativeWorkoutRecoveryStore else {
            nativeWorkoutRecoveryLoadResult = .invalid
            isNativeWorkoutRecoveryActive = true
            nativeWorkoutRecoveryStatusText = "Не удалось прочитать состояние восстановления"
            return
        }
        nativeWorkoutRecoveryLoadResult = nativeWorkoutRecoveryStore.load()
        guard case .record(let record) = nativeWorkoutRecoveryLoadResult else {
            if case .invalid = nativeWorkoutRecoveryLoadResult {
                isNativeWorkoutRecoveryActive = true
                nativeWorkoutRecoveryStatusText = "Восстанавливаем тренировку…"
            }
            return
        }
        activeNativeWorkoutRecoveryRecord = record
        switch record.phase {
        case .preflight:
            isNativeWorkoutRecoveryActive = true
            nativeWorkoutRecoveryStatusText = "Восстанавливаем тренировку…"
            isNativeHeartRatePreflightActive = true
        case .committed, .stopping, .finishing:
            restoreNativeWorkoutRecoveryPresentation(record)
            isNativeWorkoutRecoveryActive = true
            nativeWorkoutRecoveryStopRequested = record.phase == .finishing
            nativeWorkoutRecoveryStatusText = record.phase == .finishing
                ? "Завершаем восстановленную тренировку…"
                : "Восстанавливаем тренировку…"
        }
    }

    @discardableResult
    private func persistNativeWorkoutRecoveryRecord(
        _ record: NativeWorkoutRecoveryRecord
    ) -> Bool {
        guard let nativeWorkoutRecoveryStore else { return false }
        do {
            try nativeWorkoutRecoveryStore.save(record)
            nativeWorkoutRecoveryLoadResult = .record(record)
            activeNativeWorkoutRecoveryRecord = record
            return true
        } catch {
            nativeHeartRateLogger.error("recovery_marker_write_failed")
            return false
        }
    }

    @discardableResult
    private func clearNativeWorkoutRecoveryRecord() -> Bool {
        guard let nativeWorkoutRecoveryStore else { return false }
        do {
            try nativeWorkoutRecoveryStore.clear()
            nativeWorkoutRecoveryLoadResult = .missing
            activeNativeWorkoutRecoveryRecord = nil
            return true
        } catch {
            nativeHeartRateLogger.error("recovery_marker_clear_failed")
            return false
        }
    }

    private func processPendingActiveWorkoutRecoveryIfPossible() {
        guard didStartApplicationRuntime, profileErasureStateLoaded,
              let result = pendingActiveWorkoutRecoveryResult else { return }
        pendingActiveWorkoutRecoveryResult = nil
        if result.1 == nil, result.0 == nil,
           case .record(let record) = nativeWorkoutRecoveryLoadResult,
           record.isStructurallyValid, record.phase == .finishing,
           record.healthKitStopActivityAt == nil,
           let nativeWorkoutRecoveryStore {
            do {
                try nativeWorkoutRecoveryStore.archiveInterrupted(record)
                nativeWorkoutRecoveryLoadResult = .missing
                activeNativeWorkoutRecoveryRecord = nil
                completeNativeWorkoutRecoveryToIdle()
                infoToastMessage = "Незавершённая попытка сохранена для диагностики. Можно начать новую тренировку."
                nativeHeartRateLogger.info("interrupted_finishing_attempt_archived")
            } catch {
                handleUnavailableActiveWorkoutRecovery(error: error)
            }
            return
        }
        guard result.1 == nil, let recoveredSession = result.0 else {
            handleUnavailableActiveWorkoutRecovery(error: result.1)
            return
        }

        // A newly probed session must match the stranded attempt before taking ownership.
        if case .record(let record) = nativeWorkoutRecoveryLoadResult,
           record.phase == .finishing, record.healthKitStopActivityAt == nil {
            let configuration = recoveredSession.workoutConfiguration
            guard let startedAt = recoveredSession.startDate,
                  abs(startedAt.timeIntervalSince(record.acquisitionStartedAt))
                    <= NativeWorkoutRecoveryPolicy.sessionStartTolerance,
                  configuration.activityType == .walking,
                  configuration.locationType == .indoor else {
                handleUnavailableActiveWorkoutRecovery(error: nil)
                return
            }
        }
        isNativeWorkoutRecoveryActive = true
        isNativeHeartRatePreflightActive = false
        nativeWorkoutRecoveryStatusText = "Восстанавливаем тренировку…"
        let recoveryAttemptID: UUID = {
            guard case .record(let record) = nativeWorkoutRecoveryLoadResult else {
                return UUID()
            }
            return record.appWorkoutID
        }()
        nativeHeartRateProviderLifecycle.bindAttempt(recoveryAttemptID)
        let providerGeneration = nativeHeartRateProviderLifecycle.beginProviderLifecycle()
        do {
            let lifecycle = try iPhoneHealthKitHeartRateProvider.recover(
                recoveredSession,
                failureContext: IPhoneHealthKitRuntimeFailureContext(
                    providerGeneration: providerGeneration,
                    attemptID: recoveryAttemptID
                )
            )
            let configuration = recoveredSession.workoutConfiguration
            let resolution = NativeWorkoutRecoveryPolicy.resolve(
                loadResult: nativeWorkoutRecoveryLoadResult,
                recoveredSessionStartedAt: lifecycle.startedAt,
                recoveredCollectionStarted: lifecycle.collectionStarted,
                configurationIsIndoorWalking: configuration.activityType == .walking
                    && configuration.locationType == .indoor
            )
            switch resolution {
            case .discard:
                discardRecoveredUncommittedWorkout()
            case .restore(let record):
                restoreCommittedNativeWorkout(record)
            case .finish(let record):
                resumeFinishingNativeWorkout(record)
            }
        } catch {
            nativeHeartRateLogger.error("active_workout_recovery_attach_failed")
            let cleanupGeneration = nativeHeartRateProviderLifecycle.beginCleanup()
            _ = nativeHeartRateProviderLifecycle.completeCleanup(
                generation: cleanupGeneration,
                providerIsIdle: iPhoneHealthKitHeartRateProvider.state == .idle
            )
            handleUnavailableActiveWorkoutRecovery(error: error)
        }
    }

    private func processNoActiveWorkoutRecoveryIfPossible() {
        guard didStartApplicationRuntime, profileErasureStateLoaded,
              activeWorkoutRecoveryAvailability == false,
              !activeWorkoutRecoveryRequestPending,
              !didHandleActiveWorkoutRecoveryCallback,
              !nativeHealthKitWorkoutCommitted,
              !nativeHeartRateFlowOwnsController,
              !nativeHealthKitWorkoutFinishInFlight else { return }
        if case .record(let record) = nativeWorkoutRecoveryLoadResult,
           record.isStructurallyValid, record.phase == .finishing,
           record.healthKitStopActivityAt == nil {
            // A scene flag is not proof of absence: ask HealthKit exactly once.
            handleActiveWorkoutRecoveryRequest()
            healthStore.recoverActiveWorkoutSession { [weak self] session, error in
                DispatchQueue.main.async {
                    self?.handleActiveWorkoutRecovery(session: session, error: error)
                }
            }
            return
        }
        let resolution = NativeWorkoutRecoveryPolicy
            .resolveWithoutActiveRecoveryRequest(
                loadResult: nativeWorkoutRecoveryLoadResult
            )
        switch resolution {
        case .retainFailClosed:
            return
        case .discardPreflight:
            guard clearNativeWorkoutRecoveryRecord() else {
                isNativeWorkoutRecoveryActive = true
                nativeWorkoutRecoveryStatusText = "Не удалось очистить незапущенную тренировку"
                recomputeHrStartAllowed()
                return
            }
            completeNativeWorkoutRecoveryToIdle()
            warmNativeHeartRateProviderIfPossible()
            nativeHeartRateLogger.info("stale_preflight_cleared_without_recovery_request")
        case .reconcileFinished(let record):
            guard let finishRequestedAt = record.terminalRequestedAt,
                  let healthKitStoppedAt = record.healthKitStopActivityAt else {
                return
            }
            nativeHealthKitAcquisitionStartedAt = record.acquisitionStartedAt
            guard retainDeferredNativeHealthKitLinkage(
                record: record,
                finishRequestedAt: finishRequestedAt,
                healthKitStoppedAt: healthKitStoppedAt
            ) != nil else {
                isNativeWorkoutRecoveryActive = true
                nativeWorkoutRecoveryStatusText = "Не удалось сохранить проверку тренировки"
                recomputeHrStartAllowed()
                return
            }
            isNativeWorkoutRecoveryActive = true
            nativeWorkoutRecoveryStatusText = "Проверяем сохранение восстановленной тренировки…"
            recomputeHrStartAllowed()
            resolveDeferredNativeHealthKitLinkageIfPossible()
        }
    }

    private func completeNativeWorkoutRecoveryToIdle() {
        nativeHealthKitWorkoutCommitted = false
        nativeHeartRateFlowOwnsController = false
        isNativeHeartRatePreflightActive = false
        isNativeHeartRateCurrent = false
        hrStreamingActive = false
        hrLastValueAt = nil
        heartRateBPM = 0
        nativeHealthKitAcquisitionStartedAt = nil
        nativeWorkoutRecoverySessionRecovered = false
        nativeWorkoutRecoveryStopRequested = false
        isNativeWorkoutRecoveryActive = false
        nativeWorkoutRecoveryStatusText = nil
        hrControlStartedAt = nil
        hrRemainingSeconds = 0
        hrProgress = 0
        recomputeHrStartAllowed()
    }

    private func discardRecoveredUncommittedWorkout() {
        nativeHeartRateFlowOwnsController = false
        nativeHealthKitWorkoutCommitted = false
        isNativeHeartRateCurrent = false
        hrStreamingActive = false
        hrLastValueAt = nil
        heartRateBPM = 0
        let cleanupGeneration = nativeHeartRateProviderLifecycle.beginCleanup()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await iPhoneHealthKitHeartRateProvider.discard(at: Date())
            guard nativeHeartRateProviderLifecycle.completeCleanup(
                generation: cleanupGeneration,
                providerIsIdle: iPhoneHealthKitHeartRateProvider.state == .idle
            ) else { return }
            guard clearNativeWorkoutRecoveryRecord() else {
                handleUnavailableActiveWorkoutRecovery(error: nil)
                return
            }
            isNativeWorkoutRecoveryActive = false
            isNativeHeartRatePreflightActive = false
            nativeWorkoutRecoveryStatusText = nil
            nativeWorkoutRecoverySessionRecovered = false
            nativeWorkoutRecoveryStopRequested = false
            recomputeHrStartAllowed()
            warmNativeHeartRateProviderIfPossible()
        }
    }

    private func restoreCommittedNativeWorkout(
        _ record: NativeWorkoutRecoveryRecord
    ) {
        guard let controlledWorkoutStartedAt = record.controlledWorkoutStartedAt,
              record.profileID != nil,
              record.telemetrySessionID != nil else {
            discardRecoveredUncommittedWorkout()
            return
        }
        activeNativeWorkoutRecoveryRecord = record
        nativeWorkoutRecoveryLoadResult = .record(record)
        nativeHealthKitWorkoutCommitted = true
        nativeHeartRateFlowOwnsController = true
        nativeWorkoutRecoverySessionRecovered = true
        nativeWorkoutRecoveryStopRequested = false
        nativeHealthKitAcquisitionStartedAt = record.acquisitionStartedAt
        hrControlStartedAt = controlledWorkoutStartedAt
        restoreNativeWorkoutRecoveryPresentation(record)
        isNativeWorkoutRecoveryActive = true
        nativeWorkoutRecoveryStatusText = "Тренировка восстановлена"
        syncRecoveredWorkoutTiming()
        recomputeHrStartAllowed()
        nativeHeartRateLogger.info("active_workout_recovered_fail_closed")
    }

    private func resumeFinishingNativeWorkout(
        _ record: NativeWorkoutRecoveryRecord
    ) {
        restoreCommittedNativeWorkout(record)
        nativeWorkoutRecoveryStopRequested = true
        nativeWorkoutRecoveryStatusText = "Завершаем восстановленную тренировку…"
        finishNativeHealthKitWorkoutIfNeeded()
    }

    private func restoreNativeWorkoutRecoveryPresentation(
        _ record: NativeWorkoutRecoveryRecord
    ) {
        isRestoringNativeWorkoutRecoveryState = true
        if record.isIntervalWorkout != true {
            hrTargetBPM = record.targetBPM
            hrDurationMinutes = max(1, (record.effectivePlannedDurationSeconds + 59) / 60)
        }
        isRestoringNativeWorkoutRecoveryState = false
        hrSessionTotalSeconds = record.effectivePlannedDurationSeconds
        hrControlStartedAt = record.controlledWorkoutStartedAt
        syncRecoveredWorkoutTiming()
    }

    private func syncRecoveredWorkoutTiming(now: Date = Date()) {
        guard let controlledWorkoutStartedAt = activeNativeWorkoutRecoveryRecord?
                .controlledWorkoutStartedAt else { return }
        let elapsed = max(0, Int(now.timeIntervalSince(controlledWorkoutStartedAt)))
        hrRemainingSeconds = max(0, hrSessionTotalSeconds - elapsed)
        hrProgress = hrSessionTotalSeconds > 0
            ? min(1, Double(elapsed) / Double(hrSessionTotalSeconds))
            : 0
        hrNextDecisionSeconds = 0
    }

    private func handleUnavailableActiveWorkoutRecovery(error: Error?) {
        nativeHeartRateFlowOwnsController = false
        nativeWorkoutRecoverySessionRecovered = false
        nativeWorkoutRecoveryStopRequested = false
        isNativeHeartRateCurrent = false
        hrStreamingActive = false
        hrLastValueAt = nil
        heartRateBPM = 0
        isNativeWorkoutRecoveryActive = true
        nativeWorkoutRecoveryStatusText = "Не удалось восстановить тренировку"
        infoToastMessage = "HealthKit не восстановил активную тренировку. Управление дорожкой не возобновлено."
        if error != nil {
            nativeHeartRateLogger.error("active_workout_recovery_failed")
        }
        recomputeHrStartAllowed()
    }

    func start() {
        guard !didStartApplicationRuntime else { return }
        ensureCentral()
        autoConnectSuppressed = false
        autoConnectRetryPolicy.reset()
        knownDiscoveryGraceWorkItem?.cancel()
        knownDiscoveryGraceWorkItem = nil
        knownDiscoveryGraceCompleted = false
        loadKnownPeripherals()
        loadLastSuccessfulPeripheral()
        loadProfilesState()
        if UserDefaults.standard.string(forKey: legacyFallbackProfileStoreKey) == nil,
           let original = sortedProfiles(userProfiles).first?.id {
            UserDefaults.standard.set(original.uuidString.lowercased(), forKey: legacyFallbackProfileStoreKey)
        }
        loadNativeWorkoutRecoveryState()
        refreshWorkoutHistoryFromV2(reset: true)
        setHeartRateTelemetrySink(telemetryV2Coordinator)
        setTreadmillTelemetrySink(telemetryV2Coordinator)
        telemetryV2Coordinator.prepareStoreAndRecover()
        loadProfileErasureState()
        scheduleLegacyTelemetryMigration()
        didStartApplicationRuntime = true
        processNoActiveWorkoutRecoveryIfPossible()
        processPendingActiveWorkoutRecoveryIfPossible()
        recomputeHrStartAllowed()
        startHrStaleTimer()
        // Optionally kick off scanning so UI has something to connect to
        startDiscoveryScan()
        attemptAutoConnectIfNeeded()
    }

    // Discovery controls
    func startDiscoveryScan() {
        ensureCentral()
        shouldBeScanning = true
        DispatchQueue.main.async {
            if !self.isConnected {
                self.connectionStateText = "Scanning..."
            }
            self.recomputeHrStartAllowed()
        }
        if let central, central.state == .poweredOn {
            central.scanForPeripherals(withServices: supportedServiceUuids,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }
    func stopDiscoveryScan() {
        shouldBeScanning = false
        central?.stopScan()
        DispatchQueue.main.async {
            if !self.isConnected {
                self.connectionStateText = "Disconnected"
            }
            self.recomputeHrStartAllowed()
        }
    }
    func refreshDiscovery() {
        DispatchQueue.main.async {
            self.discoveredPeripherals = []
            self.discoveryUIPeripherals = []
        }
        discoveredMap.removeAll()
        if shouldBeScanning, let central, central.state == .poweredOn {
            central.stopScan()
            central.scanForPeripherals(withServices: supportedServiceUuids,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    // Auto-connect policy helper
    private var orderedAutoConnectCandidateIDs: [UUID] {
        var ordered = knownPeripherals.map(\.id).filter {
            !autoConnectRetryPolicy.failedPeripheralIDs.contains($0)
        }
        if let lastSuccessfulPeripheralID,
           let index = ordered.firstIndex(of: lastSuccessfulPeripheralID) {
            ordered.remove(at: index)
            ordered.insert(lastSuccessfulPeripheralID, at: 0)
        }
        return ordered
    }

    private func markAutoConnectCandidateFailed(_ peripheralID: UUID) {
        autoConnectRetryPolicy.markFailed(peripheralID)
    }

    private func rearmAutoConnectCandidateAfterFreshDiscovery(
        peripheralID: UUID,
        now: Date = Date()
    ) -> Bool {
        let didRearm = autoConnectRetryPolicy.rearmAfterFreshDiscovery(
            peripheralID: peripheralID,
            knownPeripheralIDs: Set(knownPeripherals.map(\.id)),
            now: now
        )
        guard didRearm else { return false }
        return true
    }

    private func preferredKnownPeripheral(from peripherals: [CBPeripheral]) -> CBPeripheral? {
        orderedAutoConnectCandidateIDs.lazy.compactMap { candidateID in
            peripherals.first(where: { $0.identifier == candidateID })
        }.first
    }

    private func preferredKnownDiscoveredPeripheral() -> DiscoveredPeripheral? {
        let candidateIDs = orderedAutoConnectCandidateIDs
        let eligible = discoveredPeripherals.filter { candidateIDs.contains($0.id) }
        if let lastSuccessfulPeripheralID,
           let preferred = eligible.first(where: { $0.id == lastSuccessfulPeripheralID }) {
            return preferred
        }
        return eligible.max { lhs, rhs in
            if lhs.rssi != rhs.rssi {
                return lhs.rssi < rhs.rssi
            }
            let lhsIndex = candidateIDs.firstIndex(of: lhs.id) ?? .max
            let rhsIndex = candidateIDs.firstIndex(of: rhs.id) ?? .max
            return lhsIndex > rhsIndex
        }
    }

    private func completeKnownDiscoveryGrace() {
        knownDiscoveryGraceWorkItem?.cancel()
        knownDiscoveryGraceWorkItem = nil
        knownDiscoveryGraceCompleted = true
    }

    private func scheduleKnownDiscoveryFallbackIfNeeded() {
        guard !knownDiscoveryGraceCompleted,
              knownDiscoveryGraceWorkItem == nil else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.knownDiscoveryGraceWorkItem = nil
            self.knownDiscoveryGraceCompleted = true
            self.attemptAutoConnectIfNeeded()
        }
        knownDiscoveryGraceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func attemptAutoConnectIfNeeded() {
        guard let central, central.state == .poweredOn else {
            return
        }
        if isConnected {
            return
        }
        if autoConnectSuppressed {
            return
        }
        if cancellingConnectionPeripheralId != nil {
            return
        }

        // If we have known peripherals saved, prefer connecting to them
        if !knownPeripherals.isEmpty {
            if let candidate = preferredKnownDiscoveredPeripheral() {
                if !knownDiscoveryGraceCompleted,
                   let lastSuccessfulPeripheralID,
                   orderedAutoConnectCandidateIDs.contains(lastSuccessfulPeripheralID),
                   candidate.id != lastSuccessfulPeripheralID {
                    scheduleKnownDiscoveryFallbackIfNeeded()
                    return
                }
                completeKnownDiscoveryGrace()
                connectToDiscovered(id: candidate.id, clearsAutoConnectSuppression: false)
                return
            }

            let connectedList = central.retrieveConnectedPeripherals(withServices: supportedServiceUuids)
            if let lastSuccessfulPeripheralID,
               orderedAutoConnectCandidateIDs.contains(lastSuccessfulPeripheralID),
               let p = connectedList.first(where: { $0.identifier == lastSuccessfulPeripheralID }) {
                completeKnownDiscoveryGrace()
                discoveredMap[p.identifier] = p
                connectToDiscovered(id: p.identifier, clearsAutoConnectSuppression: false)
                return
            }

            if lastSuccessfulPeripheralID == nil,
               let p = preferredKnownPeripheral(from: connectedList) {
                completeKnownDiscoveryGrace()
                discoveredMap[p.identifier] = p
                connectToDiscovered(id: p.identifier, clearsAutoConnectSuppression: false)
                return
            }

            guard knownDiscoveryGraceCompleted else {
                scheduleKnownDiscoveryFallbackIfNeeded()
                return
            }

            if let p = preferredKnownPeripheral(from: connectedList) {
                discoveredMap[p.identifier] = p
                connectToDiscovered(id: p.identifier, clearsAutoConnectSuppression: false)
                return
            }

            let ids = orderedAutoConnectCandidateIDs
            if !ids.isEmpty {
                let list = central.retrievePeripherals(withIdentifiers: ids)
                if let p = preferredKnownPeripheral(from: list) {
                    discoveredMap[p.identifier] = p
                    connectToDiscovered(id: p.identifier, clearsAutoConnectSuppression: false)
                    return
                }
            }
            return
        }

        // No known devices saved: allow auto-connect to the strongest unknown nearby
        if allowAutoConnectUnknown {
            if let candidate = discoveredPeripherals.max(by: { $0.rssi < $1.rssi }) {
                connectToDiscovered(id: candidate.id, clearsAutoConnectSuppression: false)
                return
            }
        }
        // Debounce: if nothing discovered yet, schedule a short delayed attempt
        if autoConnectPendingWorkItem == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if !self.isConnected && self.knownPeripherals.isEmpty && self.allowAutoConnectUnknown && !self.autoConnectSuppressed {
                    if let candidate = self.discoveredPeripherals.max(by: { $0.rssi < $1.rssi }) {
                        self.connectToDiscovered(
                            id: candidate.id,
                            clearsAutoConnectSuppression: false
                        )
                    } else {
                    }
                }
                self.autoConnectPendingWorkItem = nil
            }
            autoConnectPendingWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        }
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        DispatchQueue.main.async {
            switch central.state {
            case .poweredOn:
                if self.shouldBeScanning {
                    central.scanForPeripherals(withServices: self.supportedServiceUuids,
                                               options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
                    if !self.isConnected {
                        self.connectionStateText = "Scanning..."
                    }
                }
                self.attemptAutoConnectIfNeeded()
            case .poweredOff:
                self.cancelTreadmillTestRunForConnectionInvalidation()
                self.resetProtocolState()
                self.recomputeHrStartAllowed()
                self.stopDiscoveryScan()
                self.discoveredPeripherals = []
                self.discoveryUIPeripherals = []
                self.discoveredMap.removeAll()
            default:
                break
            }
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        discoveredMap[id] = peripheral
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let rssi = RSSI.intValue
        let isKnown = self.knownPeripherals.contains(where: { $0.id == id })
        let item = DiscoveredPeripheral(id: id, name: name, rssi: rssi, isKnown: isKnown)
        DispatchQueue.main.async {
            self.recordDiscoveredPeripheral(item)
            // Auto-connect policy:
            // - Prefer the last successful known device during the bounded discovery grace
            // - After grace, fall back through the remaining known devices serially
            // - Else if allowAutoConnectUnknown -> debounce and connect strongest unknown
            if !self.isConnected {
                if self.autoConnectSuppressed {
                    return
                }
                let rearmedKnownCandidate = self.rearmAutoConnectCandidateAfterFreshDiscovery(
                    peripheralID: id
                )
                if rearmedKnownCandidate || self.preferredKnownDiscoveredPeripheral() != nil {
                    self.autoConnectPendingWorkItem?.cancel()
                    self.autoConnectPendingWorkItem = nil
                    self.attemptAutoConnectIfNeeded()
                } else if self.allowAutoConnectUnknown {
                    if self.autoConnectPendingWorkItem == nil {
                        let work = DispatchWorkItem { [weak self] in
                            guard let self else { return }
                            if !self.isConnected && self.allowAutoConnectUnknown && !self.autoConnectSuppressed {
                                let candidate = self.discoveredPeripherals.max(by: { $0.rssi < $1.rssi })
                                if let candidate {
                                    self.connectToDiscovered(
                                        id: candidate.id,
                                        clearsAutoConnectSuppression: false
                                    )
                                }
                            }
                            self.autoConnectPendingWorkItem = nil
                        }
                        self.autoConnectPendingWorkItem = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
                    }
                }
            }
        }
    }

    private func recordDiscoveredPeripheral(_ item: DiscoveredPeripheral) {
        if let idx = self.discoveredPeripherals.firstIndex(where: { $0.id == item.id }) {
            self.discoveredPeripherals[idx] = item
        } else {
            self.discoveredPeripherals.append(item)
        }
        self.publishDiscoveredPeripheralToUI(item)
    }

    private func publishDiscoveredPeripheralToUI(_ item: DiscoveredPeripheral) {
        guard let idx = self.discoveryUIPeripherals.firstIndex(where: { $0.id == item.id }) else {
            self.discoveryUIPeripherals.append(item)
            return
        }
        let current = self.discoveryUIPeripherals[idx]
        guard DiscoveryUIPublicationPolicy.shouldPublish(
            currentName: current.name,
            currentRSSI: current.rssi,
            currentIsKnown: current.isKnown,
            nextName: item.name,
            nextRSSI: item.rssi,
            nextIsKnown: item.isKnown
        ) else { return }
        self.discoveryUIPeripherals[idx] = item
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        DispatchQueue.main.async {
            let peripheralID = peripheral.identifier
            if self.connectedPeripheralId == peripheralID {
                return
            }
            guard self.connectingPeripheralId == peripheralID else {
                central.cancelPeripheralConnection(peripheral)
                return
            }
            if self.cancellingConnectionPeripheralId != nil || self.autoConnectSuppressed {
                if self.cancellingConnectionPeripheralId == nil {
                    self.cancellingConnectionPeripheralId = peripheralID
                }
                self.connectTimeoutWorkItem?.cancel()
                self.connectTimeoutWorkItem = nil
                central.cancelPeripheralConnection(peripheral)
                return
            }

            self.autoConnectPendingWorkItem?.cancel()
            self.autoConnectPendingWorkItem = nil
            self.completeKnownDiscoveryGrace()
            self.connectTimeoutWorkItem?.cancel()
            self.connectTimeoutWorkItem = nil
            self.connectingPeripheralId = nil
            self.connectingPeripheral = nil
            self.cancellingConnectionPeripheralId = nil
            self.connectingAttemptIsAutomatic = false
            self.autoConnectRetryPolicy.reset()
            self.connectErrorMessage = nil
            self.isConnected = true
            central.stopScan()
            self.connectedPeripheralId = peripheral.identifier
            let defaultName = peripheral.name
            if let kp = self.knownPeripherals.first(where: { $0.id == peripheral.identifier }) {
                self.displayDeviceName = kp.name
                self.deviceName = kp.name
            } else {
                self.displayDeviceName = defaultName
                self.deviceName = defaultName ?? "Device"
            }
            self.connectedPeripheral = peripheral
            peripheral.delegate = self
            self.resetProtocolState()
            self.beginControllerUnitsConnection()
            peripheral.discoverServices(self.supportedServiceUuids)
            self.connectionStateText = "Connected"
            self.startTelemetry()
            self.recomputeHrStartAllowed()
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        DispatchQueue.main.async {
            guard self.connectingPeripheralId == peripheral.identifier else {
                return
            }
            let wasAutomatic = self.connectingAttemptIsAutomatic

            self.isConnected = false
            self.connectionStateText = "Disconnected"
            if wasAutomatic {
                self.markAutoConnectCandidateFailed(peripheral.identifier)
            } else {
                self.connectErrorMessage = error?.localizedDescription ?? "Failed to connect"
            }
            self.connectingPeripheralId = nil
            self.connectingPeripheral = nil
            self.connectingAttemptIsAutomatic = false
            if self.cancellingConnectionPeripheralId == peripheral.identifier {
                self.cancellingConnectionPeripheralId = nil
            }
            self.connectTimeoutWorkItem?.cancel()
            self.connectTimeoutWorkItem = nil
            self.resumeDiscoveryScanIfNeeded()
            if wasAutomatic && !self.autoConnectSuppressed {
                self.attemptAutoConnectIfNeeded()
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        DispatchQueue.main.async {
            let peripheralID = peripheral.identifier
            let endedConnectionAttempt = self.connectingPeripheralId == peripheralID
                && self.connectedPeripheralId != peripheralID
            let endedEstablishedConnection = self.connectedPeripheralId == peripheralID
                || (self.cancellingConnectionPeripheralId == peripheralID
                    && self.connectingPeripheralId != peripheralID)
            guard endedConnectionAttempt || endedEstablishedConnection else {
                return
            }

            if endedConnectionAttempt {
                let shouldContinueAutoConnect = self.connectingAttemptIsAutomatic
                    && !self.autoConnectSuppressed
                if shouldContinueAutoConnect {
                    self.markAutoConnectCandidateFailed(peripheralID)
                }
                self.connectingPeripheralId = nil
                self.connectingPeripheral = nil
                self.connectingAttemptIsAutomatic = false
                if self.cancellingConnectionPeripheralId == peripheralID {
                    self.cancellingConnectionPeripheralId = nil
                }
                self.connectTimeoutWorkItem?.cancel()
                self.connectTimeoutWorkItem = nil
                self.connectionStateText = "Disconnected"
                self.resumeDiscoveryScanIfNeeded()
                if shouldContinueAutoConnect {
                    self.attemptAutoConnectIfNeeded()
                }
                return
            }
            self.cancelTreadmillTestRunForConnectionInvalidation()
#if STOP_TRUTH_EXPERIMENT_CAPABILITY
            self.stopTruthExperimentController?.connectionContextInvalidated()
#endif
            self.finishActiveStopObservationUnconfirmed(reason: "connection_changed")
            if let pendingAttemptID = self.unavailableStopAttempt?.id {
                self.finalizeUnavailableStopAttempt(attemptID: pendingAttemptID)
            }
            if self.isHrControlRunning {

            }
            self.resetProtocolState()
            self.connectedPeripheral = nil

            self.isConnected = false
            self.connectedPeripheralId = nil
            self.connectionStateText = "Disconnected"
            self.stopTelemetry()
            self.isHrControlRunning = false
            self.recomputeHrStartAllowed()
            self.resetSessionStats()
            self.connectingPeripheralId = nil
            self.connectingPeripheral = nil
            self.connectingAttemptIsAutomatic = false
            if self.cancellingConnectionPeripheralId == peripheralID {
                self.cancellingConnectionPeripheralId = nil
            }
            self.connectTimeoutWorkItem?.cancel()
            self.connectTimeoutWorkItem = nil
            _ = self.telemetryV2Coordinator.observeEvent(
                .connectionTransition(
                    ConnectionTransition(
                        previous: .connected,
                        current: .disconnected,
                        reason: "ble_disconnected"
                    )
                ),
                occurredAt: Date()
            )
            self.endTelemetryV2Session(reason: "ble_disconnected")
            self.resumeDiscoveryScanIfNeeded()
        }
    }

    // Connection actions
    func toggleConnection() {
        if isConnected {
            disconnect(userInitiated: true)
        } else {
            // Attempt to connect to the strongest known discovered peripheral
            if let candidate = discoveredPeripherals.max(by: { $0.rssi < $1.rssi }) {
                autoConnectSuppressed = false
                connectToDiscovered(id: candidate.id)
            }
        }
    }
    func disconnectFromCurrent() {
        disconnect(userInitiated: true)
    }
    private func disconnect(userInitiated: Bool = false) {
        central?.stopScan()

        if userInitiated {
            autoConnectSuppressed = true
        }
        cancelTreadmillTestRunForConnectionInvalidation()
        finishActiveStopObservationUnconfirmed(reason: "disconnect_requested")
        if let pendingAttemptID = unavailableStopAttempt?.id {
            finalizeUnavailableStopAttempt(attemptID: pendingAttemptID)
        }
        if isHrControlRunning {

        }
        if let central {
            if let id = connectedPeripheralId, let p = discoveredMap[id] {
                cancellingConnectionPeripheralId = id
                central.cancelPeripheralConnection(p)
            } else if let id = connectingPeripheralId,
                      let p = connectingPeripheral,
                      p.identifier == id {
                cancellingConnectionPeripheralId = id
                central.cancelPeripheralConnection(p)
            }
        }
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
        DispatchQueue.main.async {
            self.isConnected = false
            self.resetProtocolState()
            self.connectedPeripheralId = nil
            self.connectionStateText = "Disconnected"
            self.displayDeviceName = nil
            self.deviceTargetSpeedKmh = 0
            self.desiredSpeedKmh = 0
            self.resetSessionStats()
            self.stopTelemetry()
            self.isHrControlRunning = false
            self.recomputeHrStartAllowed()
            _ = self.telemetryV2Coordinator.observeEvent(
                .connectionTransition(
                    ConnectionTransition(
                        previous: .connected,
                        current: .disconnected,
                        reason: userInitiated ? "disconnect_user" : "disconnect"
                    )
                ),
                occurredAt: Date()
            )
            self.endTelemetryV2Session(
                reason: userInitiated ? "disconnect_user" : "disconnect"
            )
        }
    }
    func connectToKnownPeripheral(id: UUID) {
        ensureCentral()
        guard let central else { return }
        autoConnectSuppressed = false
        // Prevent duplicate connection attempts
        if isConnected { return }
        if cancellingConnectionPeripheralId != nil {
            return
        }
        if let inProgress = connectingPeripheralId {
            if inProgress == id { return }
            return
        }
        if let p = discoveredMap[id] {
            DispatchQueue.main.async { self.connectionStateText = "Connecting..." }
            connectingPeripheralId = id
            connectingPeripheral = p
            connectingAttemptIsAutomatic = false
            connectErrorMessage = nil
            central.stopScan()
            central.connect(p, options: nil)
            scheduleConnectTimeout(for: id)
            return
        }
        let list = central.retrievePeripherals(withIdentifiers: [id])
        if let p = list.first {
            discoveredMap[id] = p
            DispatchQueue.main.async { self.connectionStateText = "Connecting..." }
            connectingPeripheralId = id
            connectingPeripheral = p
            connectingAttemptIsAutomatic = false
            connectErrorMessage = nil
            central.stopScan()
            central.connect(p, options: nil)
            scheduleConnectTimeout(for: id)
        } else {
            // Fallback: start scan to find the peripheral
            shouldBeScanning = true
            central.scanForPeripherals(withServices: supportedServiceUuids,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            DispatchQueue.main.async { self.connectionStateText = "Scanning..." }
        }
    }
    func connectToDiscovered(
        id: UUID,
        clearsAutoConnectSuppression: Bool = true
    ) {
        ensureCentral()
        guard let central else { return }
        if clearsAutoConnectSuppression {
            autoConnectSuppressed = false
            connectErrorMessage = nil
        }
        // Prevent duplicate connection attempts
        if isConnected { return }
        if cancellingConnectionPeripheralId != nil {
            return
        }
        if let inProgress = connectingPeripheralId {
            // Ignore repeated taps while a connection is in progress (including same target)
            if inProgress == id { return }
            return
        }
        if let p = discoveredMap[id] {
            DispatchQueue.main.async { self.connectionStateText = "Connecting..." }
            connectingPeripheralId = id
            connectingPeripheral = p
            connectingAttemptIsAutomatic = !clearsAutoConnectSuppression
            central.stopScan()
            central.connect(p, options: nil)
            scheduleConnectTimeout(for: id)
        } else {
            let list = central.retrievePeripherals(withIdentifiers: [id])
            if let p = list.first {
                discoveredMap[id] = p
                DispatchQueue.main.async { self.connectionStateText = "Connecting..." }
                connectingPeripheralId = id
                connectingPeripheral = p
                connectingAttemptIsAutomatic = !clearsAutoConnectSuppression
                central.stopScan()
                central.connect(p, options: nil)
                scheduleConnectTimeout(for: id)
            } else {
            }
        }
    }
    func forgetKnownPeripheral(id: UUID) {
        DispatchQueue.main.async {
            self.autoConnectSuppressed = true
            self.knownPeripherals.removeAll { $0.id == id }
            if self.lastSuccessfulPeripheralID == id {
                self.lastSuccessfulPeripheralID = nil
                UserDefaults.standard.removeObject(forKey: self.lastSuccessfulPeripheralStoreKey)
            }
            self.autoConnectRetryPolicy.forget(id)
            self.discoveredPeripherals = self.discoveredPeripherals.map { item in
                guard item.id == id else { return item }
                return DiscoveredPeripheral(
                    id: item.id,
                    name: item.name,
                    rssi: item.rssi,
                    isKnown: false
                )
            }
            self.discoveryUIPeripherals = self.discoveredPeripherals
            if self.connectedPeripheralId == id {
                self.disconnect(userInitiated: true)
            } else if self.connectingPeripheralId == id,
                      let central = self.central,
                      let peripheral = self.connectingPeripheral,
                      peripheral.identifier == id {
                self.cancellingConnectionPeripheralId = id
                self.connectTimeoutWorkItem?.cancel()
                self.connectTimeoutWorkItem = nil
                central.cancelPeripheralConnection(peripheral)
            }
            self.saveKnownPeripherals()
        }
    }

    func renameKnownPeripheral(id: UUID, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        DispatchQueue.main.async {
            if let idx = self.knownPeripherals.firstIndex(where: { $0.id == id }) {
                self.knownPeripherals[idx].name = trimmed
                if self.connectedPeripheralId == id {
                    self.displayDeviceName = trimmed
                    self.deviceName = trimmed
                }
                self.saveKnownPeripherals()
            }
        }
    }

#if STOP_TRUTH_EXPERIMENT_CAPABILITY
    var stopTruthExperimentCapabilityAvailable: Bool {
        StopTruthExperimentBuildIdentity.current().isEnabled && !stopTruthExperimentTerminalLatch
    }

    var stopTruthExperimentIsActive: Bool {
        stopTruthExperimentController?.isActive == true
    }

    func startStopTruthExperiment() {
        guard stopTruthExperimentController == nil,
              !stopTruthExperimentTerminalLatch,
              !blocksNonStopTreadmillMotion,
              !isHrControlRunning,
              treadmillProtocol == .walkingPad,
              controllerUnitsQueryTransportReady,
              let context = currentStopTruthExperimentContext() else {
            stopTruthExperimentStatus = "blocked: transport/context/HR gate"
            return
        }
        let buildIdentity = StopTruthExperimentBuildIdentity.current()
        guard buildIdentity.isEnabled else {
            stopTruthExperimentStatus = "disabled: exact build identity mismatch"
            return
        }
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            stopTruthExperimentStatus = "blocked: application support unavailable"
            return
        }
        do {
            let experimentID = UUID()
            let writer = try StopTruthExperimentEvidenceWriter(
                experimentID: experimentID,
                rootDirectory: applicationSupport
            )
            resetCommandQueue(reason: "fixed Stop-truth experiment exclusive start")
            let controller = StopTruthExperimentController(
                experimentID: experimentID,
                buildIdentity: buildIdentity,
                context: context,
                timeoutPolicy: .init(perRepetitionSeconds: 90, globalSeconds: 300),
                evidenceSink: writer,
                transportInvocation: { [weak self] packet, role, writeID, completion in
                    guard let self else { return false }
                    return self.invokeStopTruthExperimentTransport(
                        packet: packet,
                        role: role,
                        writeID: writeID,
                        completion: completion
                    )
                },
                speedSnapshot: { [weak self] in
                    (self?.speedKmh ?? 0, self?.deviceReportedSpeedKmh ?? 0)
                },
                beforeHighPriorityStop: { [weak self] in
                    self?.resetCommandQueue(reason: "experiment initial Stop high priority")
                },
                deviceMetadata: { [weak self] in
                    var fields = [
                        "treadmill_name": self?.deviceName ?? "",
                        "installation_id": self?.installationID ?? "",
                        "profile_id": self?.activeUserProfileID?.uuidString ?? ""
                    ]
#if canImport(UIKit)
                    fields["ios_device_model"] = UIDevice.current.model
                    fields["ios_system_name"] = UIDevice.current.systemName
                    fields["ios_system_version"] = UIDevice.current.systemVersion
#endif
                    return fields
                },
                onStateChange: { [weak self] status in
                    DispatchQueue.main.async {
                        self?.stopTruthExperimentStatus = status
                        if status.hasPrefix("aborted")
                            || status.hasPrefix("failed")
                            || status == "completed" {
                            self?.stopTruthExperimentTerminalLatch = true
                        }
                    }
                }
            )
            stopTruthExperimentController = controller
            stopTruthExperimentArtifactPath = writer.fileURL.path
            guard controller.start() else {
                stopTruthExperimentStatus = "blocked: experiment start rejected"
                return
            }
            stopTruthExperimentStatus = controller.status
        } catch {
            stopTruthExperimentStatus = "blocked: evidence writer unavailable"
        }
    }

    func prepareStopTruthExperimentMotion() {
        guard stopTruthExperimentController?.prepareMotion() == true else {
            if let controller = stopTruthExperimentController, !controller.isActive {
                stopTruthExperimentStatus = controller.status
            } else {
                stopTruthExperimentStatus = "blocked: stationary/A6/sequence gate"
            }
            return
        }
        stopTruthExperimentStatus = stopTruthExperimentController?.status ?? "blocked"
    }

    func beginStopTruthExperimentStop() {
        guard stopTruthExperimentController?.beginStop() == true else {
            if let controller = stopTruthExperimentController, !controller.isActive {
                stopTruthExperimentStatus = controller.status
            } else {
                stopTruthExperimentStatus = "blocked: moving baseline/marker gate"
            }
            return
        }
        stopTruthExperimentStatus = stopTruthExperimentController?.status ?? "blocked"
    }

    func markStopTruthExperimentMoving() {
        stopTruthExperimentController?.recordMarker(.moving)
    }

    func markStopTruthExperimentStopped() {
        stopTruthExperimentController?.recordMarker(.stopped)
    }

    func abortStopTruthExperiment() {
        stopTruthExperimentTerminalLatch = true
        stopTruthExperimentController?.recordMarker(.abort)
        stopTruthExperimentStatus = stopTruthExperimentController?.status
            ?? "aborted • use physical power cutoff after any motion-capable write"
    }

    func stopTruthExperimentAppBecameInactive() {
        guard stopTruthExperimentController?.isActive == true else { return }
        stopTruthExperimentTerminalLatch = true
        stopTruthExperimentController?.recordMarker(
            .abort,
            note: "app_lifecycle_inactive",
            operatorHadVisibility: false
        )
        stopTruthExperimentStatus = stopTruthExperimentController?.status
            ?? "aborted: app lifecycle inactive / suspension risk"
    }

    func beginNextStopTruthExperimentRepetition() {
        guard stopTruthExperimentController?.beginNextRepetition() == true else {
            stopTruthExperimentStatus = "blocked: recovery/post-window gate"
            return
        }
        stopTruthExperimentStatus = stopTruthExperimentController?.status ?? "completed"
    }

    private func currentStopTruthExperimentContext() -> StopTruthExperimentPlanService.Context? {
        guard let peripheralID = connectedPeripheralId,
              let connectionEpoch = controllerUnitsConnectionEpoch,
              let notificationStreamID = stopObservationStreamID else {
            return nil
        }
        return .init(
            peripheralID: peripheralID,
            connectionEpoch: connectionEpoch,
            notificationStreamID: notificationStreamID
        )
    }

    private func stopTruthExperimentObservationContext(
        peripheral: CBPeripheral,
        characteristic: CBCharacteristic
    ) -> StopTruthExperimentPlanService.Context? {
        guard let connectionEpoch = controllerUnitsConnectionEpoch,
              let currentStreamID = stopObservationStreamID else {
            return nil
        }
        let streamID = characteristic === notifyCharacteristic
            ? currentStreamID
            : UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        return .init(
            peripheralID: peripheral.identifier,
            connectionEpoch: connectionEpoch,
            notificationStreamID: streamID
        )
    }

    private func invokeStopTruthExperimentTransport(
        packet: Data,
        role: BLETransportCodec.StopTruthExperimentCommandRole,
        writeID: UUID,
        completion: @escaping (Result<StopTruthExperimentTransportReceipt, Error>) -> Void
    ) -> Bool {
        guard Thread.isMainThread,
              !blocksNonStopTreadmillMotion,
              stopTruthExperimentController?.isActive == true,
              BLETransportCodec.validateStopTruthExperimentPacket(packet, role: role),
              treadmillProtocol == .walkingPad,
              currentStopTruthExperimentContext() != nil,
              let peripheral = connectedPeripheral,
              let characteristic = commandCharacteristic,
              characteristic.uuid == charFE02 else {
            return false
        }
        let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.writeWithoutResponse)
            ? .withoutResponse
            : .withResponse
        peripheral.writeValue(packet, for: characteristic, type: writeType)
        nextCommandAllowedAt = Date().addingTimeInterval(commandMinIntervalWalkingPadSeconds)
        let receipt = StopTruthExperimentTransportReceipt(
            characteristicUUID: characteristic.uuid.uuidString,
            writeType: writeType == .withoutResponse ? "without_response" : "with_response"
        )
        DispatchQueue.main.async { completion(.success(receipt)) }
        return true
    }

#endif

    // Treadmill control
    var canStartTreadmillTestRun: Bool {
        let unitsDecision = ControllerUnitsSafetyPolicy.evaluate(
            path: .testRun,
            state: controllerUnitsTruth,
            currentConnectionEpoch: controllerUnitsConnectionEpoch,
            now: Date(),
            requiresFreshMetricTruth: controllerUnitsTruthRequired
        )
        guard profileDataAvailable,
              !treadmillTestRunService.isActive,
              !blocksNonStopTreadmillMotion,
              !isHrControlRunning,
              isTreadmillControlReady,
              connectedPeripheralId != nil,
              controllerUnitsConnectionEpoch != nil,
              unitsDecision.allowed,
              treadmillMinSpeedKmh <= 1.0,
              treadmillMaxSpeedKmh >= 3.0 else {
            return false
        }
#if STOP_TRUTH_EXPERIMENT_CAPABILITY
        guard stopTruthExperimentController?.isActive != true else { return false }
#endif
        return true
    }

    var treadmillTestRunDisplayText: String {
        guard case .idle = treadmillTestRunService.state else {
            return treadmillTestRunStatusText
        }
        if !isConnected {
            return "Подключите дорожку"
        }
        if isHrControlRunning {
            return "Недоступно во время HR-контроля"
        }
        if !isTreadmillControlReady {
            return "Дождитесь готовности управления"
        }
        let unitsDecision = ControllerUnitsSafetyPolicy.evaluate(
            path: .testRun,
            state: controllerUnitsTruth,
            currentConnectionEpoch: controllerUnitsConnectionEpoch,
            now: Date(),
            requiresFreshMetricTruth: controllerUnitsTruthRequired
        )
        if let unitsBlockReason = unitsDecision.blockReason {
            return unitsBlockReason.userMessage
        }
        if treadmillMinSpeedKmh > 1.0 || treadmillMaxSpeedKmh < 3.0 {
            return "Диапазон дорожки не поддерживает сценарий 1.0–3.0 km/h"
        }
#if STOP_TRUTH_EXPERIMENT_CAPABILITY
        if stopTruthExperimentController?.isActive == true {
            return "Недоступно во время Stop-truth experiment"
        }
#endif
        return treadmillTestRunStatusText
    }

    func startTreadmillTestRun() {
        cancelAppleHeartRateZoneRead()
        guard canStartTreadmillTestRun,
              let context = currentTreadmillTestRunContext() else {
            treadmillTestRunStatusText = treadmillTestRunDisplayText
            return
        }
        let runID = UUID()
        guard let transition = treadmillTestRunService.start(
            at: ProcessInfo.processInfo.systemUptime,
            runID: runID
        ) else {
            return
        }

        treadmillTestRunContext = context
        syncTreadmillTestRunPresentation()
        startTreadmillTestRunTimer(runID: runID)
        executeTreadmillTestRunActions(transition.actions)
        startTreadmillTestRunHeartRateDiagnostic(runID: runID)
    }

    func stopTreadmillTestRun() {
        let contextIsCurrent = treadmillTestRunContext == currentTreadmillTestRunContext()
        cancelTreadmillTestRun(
            reason: .userRequested,
            requestProductionStop: isConnected && contextIsCurrent
        )
    }

    func treadmillTestRunAppBecameInactive() {
        guard treadmillTestRunService.isActive else { return }
        let contextIsCurrent = treadmillTestRunContext == currentTreadmillTestRunContext()
        cancelTreadmillTestRun(
            reason: .appInactive,
            requestProductionStop: isConnected && contextIsCurrent
        )
    }

    private func currentTreadmillTestRunContext() -> TreadmillTestRunConnectionContext? {
        guard isTreadmillControlReady,
              let peripheralID = connectedPeripheralId,
              let connectionEpoch = controllerUnitsConnectionEpoch else {
            return nil
        }
        return TreadmillTestRunConnectionContext(
            peripheralID: peripheralID,
            connectionEpoch: connectionEpoch
        )
    }

    private func startTreadmillTestRunTimer(runID: UUID) {
        treadmillTestRunTimer?.invalidate()
        treadmillTestRunTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.advanceTreadmillTestRun(expectedRunID: runID)
        }
    }

    private func advanceTreadmillTestRun(expectedRunID: UUID) {
        guard treadmillTestRunService.activeRunID == expectedRunID else { return }
        tickTreadmillTestRunHeartRateDiagnostic(expectedRunID: expectedRunID)
        guard treadmillTestRunContext == currentTreadmillTestRunContext() else {
            cancelTreadmillTestRunForConnectionInvalidation()
            return
        }
        guard let transition = treadmillTestRunService.advance(
            at: ProcessInfo.processInfo.systemUptime,
            expectedRunID: expectedRunID
        ) else {
            return
        }

        syncTreadmillTestRunPresentation()
        if !treadmillTestRunService.isActive {
            invalidateTreadmillTestRunScheduling()
        }
        executeTreadmillTestRunActions(transition.actions)
        if !treadmillTestRunService.isActive {
            finishCurrentTreadmillTestRunHeartRateDiagnostic(
                expectedRunID: expectedRunID,
                reason: .testRunCompleted
            )
        }
    }

    private func cancelTreadmillTestRun(
        reason: TreadmillTestRunService.CancellationReason,
        requestProductionStop: Bool
    ) {
        guard let transition = treadmillTestRunService.cancel(
            reason: reason,
            requestProductionStop: requestProductionStop
        ) else {
            return
        }

        invalidateTreadmillTestRunScheduling()
        syncTreadmillTestRunPresentation()
        // Procedure rejection owns queue filtering and preserves an existing Stop.
        if !requestProductionStop && reason != .commandRejected {
            resetCommandQueue(reason: "Test Run cancelled without safe Stop context")
        }
        executeTreadmillTestRunActions(transition.actions)
        if let runID = treadmillTestRunHeartRateDiagnosticSnapshot.runID {
            finishCurrentTreadmillTestRunHeartRateDiagnostic(
                expectedRunID: runID,
                reason: treadmillTestRunHeartRateTerminalReason(for: reason)
            )
        }
    }

    private func cancelTreadmillTestRunForConnectionInvalidation() {
        cancelTreadmillTestRun(
            reason: .connectionInvalidated,
            requestProductionStop: false
        )
    }

    private func invalidateTreadmillTestRunScheduling() {
        treadmillTestRunTimer?.invalidate()
        treadmillTestRunTimer = nil
        treadmillTestRunContext = nil
    }

    private func syncTreadmillTestRunPresentation() {
        treadmillTestRunIsActive = treadmillTestRunService.isActive
        treadmillTestRunStatusText = treadmillTestRunService.statusText
    }

    private func startTreadmillTestRunHeartRateDiagnostic(runID: UUID) {
        let now = Date()
        guard IPhoneHealthKitLiveHeartRateProvider.isSupported else {
            treadmillTestRunHeartRateDiagnosticService.markUnavailable(
                runID: runID,
                at: now,
                detail: "Native HealthKit heart-rate provider is unsupported"
            )
            syncTreadmillTestRunHeartRateDiagnosticPresentation(now: now)
            return
        }
        guard treadmillTestRunHeartRateProvider == nil,
              !treadmillTestRunHeartRateCleanupInFlight,
              iPhoneHealthKitHeartRateProvider.state == .idle,
              !nativeHeartRatePreflightEngine.ownsUncommittedWorkout,
              !hasOutstandingNativeWorkoutRecovery,
              !nativeHealthKitWorkoutCommitted,
              !nativeHealthKitWorkoutFinishInFlight,
              !isHrControlRunning else {
            treadmillTestRunHeartRateDiagnosticService.markUnavailable(
                runID: runID,
                at: now,
                detail: "Production HealthKit provider or workout recovery owns the session"
            )
            syncTreadmillTestRunHeartRateDiagnosticPresentation(now: now)
            return
        }

        treadmillTestRunHeartRateProviderGeneration &+= 1
        let providerGeneration = treadmillTestRunHeartRateProviderGeneration
        treadmillTestRunHeartRateDiagnosticService.start(runID: runID, at: now)
        let provider = IPhoneHealthKitLiveHeartRateProvider(healthStore: healthStore)
        let attempt = TestRunHeartRateDiagnosticProviderAttempt(
            runID: runID,
            generation: providerGeneration,
            providerIdentity: ObjectIdentifier(provider)
        )
        treadmillTestRunHeartRateProviderOwnership.bind(attempt)
        provider.onObservation = { [weak self, weak provider] observation in
            guard let provider else { return }
            self?.handleTreadmillTestRunHeartRateObservation(
                observation,
                expectedAttempt: attempt,
                provider: provider
            )
        }
        provider.onFailure = { [weak self, weak provider] context in
            guard let provider else { return }
            guard context.providerGeneration == providerGeneration,
                  context.attemptID == runID else { return }
            self?.treadmillTestRunHeartRateProviderFailed(
                expectedAttempt: attempt,
                provider: provider,
                detail: "HealthKit runtime failure"
            )
        }
        treadmillTestRunHeartRateProvider = provider
        syncTreadmillTestRunHeartRateDiagnosticPresentation(now: now)

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .walking
        configuration.locationType = .indoor
        Task { @MainActor [weak self, weak provider] in
            guard let self, let provider else { return }
            do {
                try await provider.prepare(
                    configuration: configuration,
                    failureContext: IPhoneHealthKitRuntimeFailureContext(
                        providerGeneration: providerGeneration,
                        attemptID: runID
                    )
                )
                guard ownsTreadmillTestRunHeartRateProvider(
                    attempt,
                    provider: provider
                ),
                      treadmillTestRunService.activeRunID == runID else {
                    await provider.discard(at: Date())
                    return
                }
                treadmillTestRunHeartRateDiagnosticService.updateProviderState(
                    provider.state.rawValue,
                    expectedRunID: runID
                )
                syncTreadmillTestRunHeartRateDiagnosticPresentation()
                let collectionStartedAt = Date()
                treadmillTestRunHeartRateDiagnosticService.updateProviderState(
                    IPhoneHealthKitHeartRateProviderState.starting.rawValue,
                    expectedRunID: runID
                )
                syncTreadmillTestRunHeartRateDiagnosticPresentation()
                try await provider.start(at: collectionStartedAt)
                guard ownsTreadmillTestRunHeartRateProvider(
                    attempt,
                    provider: provider
                ),
                      treadmillTestRunService.activeRunID == runID else {
                    await provider.discard(at: Date())
                    return
                }
                treadmillTestRunHeartRateDiagnosticService.collectionStarted(
                    expectedRunID: runID,
                    at: collectionStartedAt
                )
                syncTreadmillTestRunHeartRateDiagnosticPresentation()
            } catch {
                treadmillTestRunHeartRateProviderFailed(
                    expectedAttempt: attempt,
                    provider: provider,
                    detail: String(describing: error)
                )
            }
        }
    }

    private func handleTreadmillTestRunHeartRateObservation(
        _ observation: HeartRateProviderObservation,
        expectedAttempt: TestRunHeartRateDiagnosticProviderAttempt,
        provider: IPhoneHealthKitLiveHeartRateProvider
    ) {
        guard ownsTreadmillTestRunHeartRateProvider(
            expectedAttempt,
            provider: provider
        ), provider.state == .collecting else { return }
        let now = Date()
        treadmillTestRunHeartRateDiagnosticService.receive(
            TestRunHeartRateDiagnosticService.Sample(
                qualificationObservation: NativeHeartRatePreflightEngine.Observation(
                    source: .nativeHealthKit,
                    beatsPerMinute: observation.beatsPerMinute,
                    measuredAt: observation.measuredAt,
                    receivedAt: observation.receivedAt
                ),
                sourceCallbackObservedAt: observation.sourceCallbackObservedAt,
                providerNativeIdentity: observation.providerNativeIdentity?.identifier
            ),
            expectedRunID: expectedAttempt.runID,
            now: now,
            freshnessLimit: TimeInterval(hrStaleThresholdSeconds)
        )
        syncTreadmillTestRunHeartRateDiagnosticPresentation(now: now)
    }

    private func tickTreadmillTestRunHeartRateDiagnostic(expectedRunID: UUID) {
        let now = Date()
        if treadmillTestRunHeartRateDiagnosticService.timeoutIfNeeded(
            expectedRunID: expectedRunID,
            now: now
        ) {
            syncTreadmillTestRunHeartRateDiagnosticPresentation(now: now)
            guard let attempt = treadmillTestRunHeartRateProviderOwnership.currentAttempt,
                  attempt.runID == expectedRunID,
                  let provider = treadmillTestRunHeartRateProvider else { return }
            discardTreadmillTestRunHeartRateProvider(
                expectedAttempt: attempt,
                provider: provider
            )
        } else {
            syncTreadmillTestRunHeartRateDiagnosticPresentation(now: now)
        }
    }

    private func treadmillTestRunHeartRateProviderFailed(
        expectedAttempt: TestRunHeartRateDiagnosticProviderAttempt,
        provider: IPhoneHealthKitLiveHeartRateProvider,
        detail: String
    ) {
        finishTreadmillTestRunHeartRateDiagnostic(
            expectedAttempt: expectedAttempt,
            provider: provider,
            reason: .providerFailure,
            detail: detail
        )
    }

    private func finishCurrentTreadmillTestRunHeartRateDiagnostic(
        expectedRunID: UUID,
        reason: TestRunHeartRateDiagnosticService.TerminalReason
    ) {
        guard let attempt = treadmillTestRunHeartRateProviderOwnership.currentAttempt,
              attempt.runID == expectedRunID,
              let provider = treadmillTestRunHeartRateProvider else { return }
        finishTreadmillTestRunHeartRateDiagnostic(
            expectedAttempt: attempt,
            provider: provider,
            reason: reason
        )
    }

    private func finishTreadmillTestRunHeartRateDiagnostic(
        expectedAttempt: TestRunHeartRateDiagnosticProviderAttempt,
        provider: IPhoneHealthKitLiveHeartRateProvider,
        reason: TestRunHeartRateDiagnosticService.TerminalReason,
        detail: String? = nil
    ) {
        guard ownsTreadmillTestRunHeartRateProvider(
            expectedAttempt,
            provider: provider
        ),
              treadmillTestRunHeartRateDiagnosticSnapshot.runID == expectedAttempt.runID,
              treadmillTestRunHeartRateDiagnosticService.isActive else { return }
        treadmillTestRunHeartRateDiagnosticService.finish(
            expectedRunID: expectedAttempt.runID,
            reason: reason,
            detail: detail
        )
        syncTreadmillTestRunHeartRateDiagnosticPresentation()
        discardTreadmillTestRunHeartRateProvider(
            expectedAttempt: expectedAttempt,
            provider: provider
        )
    }

    private func discardTreadmillTestRunHeartRateProvider(
        expectedAttempt: TestRunHeartRateDiagnosticProviderAttempt,
        provider: IPhoneHealthKitLiveHeartRateProvider
    ) {
        guard ownsTreadmillTestRunHeartRateProvider(
            expectedAttempt,
            provider: provider
        ),
              !treadmillTestRunHeartRateCleanupInFlight else { return }
        treadmillTestRunHeartRateCleanupInFlight = true
        Task { @MainActor [weak self, weak provider] in
            guard let self, let provider else { return }
            await provider.discard(at: Date())
            guard ownsTreadmillTestRunHeartRateProvider(
                expectedAttempt,
                provider: provider
            ), treadmillTestRunHeartRateProviderOwnership.release(expectedAttempt) else {
                return
            }
            treadmillTestRunHeartRateProvider = nil
            treadmillTestRunHeartRateCleanupInFlight = false
            treadmillTestRunHeartRateDiagnosticService.providerDiscarded(
                expectedRunID: expectedAttempt.runID
            )
            syncTreadmillTestRunHeartRateDiagnosticPresentation()
            warmNativeHeartRateProviderIfPossible()
        }
    }

    private func ownsTreadmillTestRunHeartRateProvider(
        _ attempt: TestRunHeartRateDiagnosticProviderAttempt,
        provider: IPhoneHealthKitLiveHeartRateProvider
    ) -> Bool {
        treadmillTestRunHeartRateProvider === provider
            && treadmillTestRunHeartRateProviderOwnership.accepts(
                attempt,
                provider: provider
            )
    }

    private func syncTreadmillTestRunHeartRateDiagnosticPresentation(
        now: Date = Date()
    ) {
        treadmillTestRunHeartRateDiagnosticSnapshot =
            treadmillTestRunHeartRateDiagnosticService.snapshot(
                now: now,
                freshnessLimit: TimeInterval(hrStaleThresholdSeconds)
            )
    }

    private func treadmillTestRunHeartRateTerminalReason(
        for reason: TreadmillTestRunService.CancellationReason
    ) -> TestRunHeartRateDiagnosticService.TerminalReason {
        switch reason {
        case .userRequested: return .userRequested
        case .appInactive: return .appInactive
        case .connectionInvalidated: return .connectionInvalidated
        case .commandRejected: return .commandRejected
        }
    }

    private func executeTreadmillTestRunActions(_ actions: [TreadmillTestRunService.Action]) {
        for action in actions {
            switch action {
            case .start(let speedKmh):
                manualGo(targetSpeed: speedKmh)
            case .setSpeed(let speedKmh):
                setTargetSpeedFromSlider(speedKmh)
            case .stop:
                manualStop()
            }
        }
    }

    func manualGo(targetSpeed: Double) {
        startWithSpeed(targetSpeed)
    }

    func manualStop() {
        if isHrControlRunning || isNativeWorkoutRecoveryActive {
            stopHrControl()
            return
        }
        stopBeltWithToggle(reason: "manual")
    }

    func startWithSpeed(_ kmh: Double) {
        guard !blocksNonStopTreadmillMotion else {
            infoToastMessage = "Сначала завершите восстановленную тренировку"
            return
        }
        guard isTreadmillControlReady else {
            infoToastMessage = isConnected
                ? "Дождитесь готовности управления дорожкой"
                : "Не подключено к дорожке"
            return
        }
        endStopObservationForNewMotion()
        // Cancel any pending delayed writes (e.g. stop retries) before starting a new run.
        resetCommandQueue(reason: "startWithSpeed")
        let v = clampRunningSpeedKmh(kmh)
        let telemetryDecision = makeTreadmillDecision(
            source: .start,
            intent: .startAtDesiredSpeed(DesiredSpeedKilometresPerHour(value: v))
        )
        defer { observeTreadmillDecision(telemetryDecision) }
        let old = deviceTargetSpeedKmh
        desiredSpeedKmh = v
        deviceTargetSpeedKmh = v
        recordSpeedChange(from: old, to: v, reason: "manual_go")
        let shouldSendStart = speedKmh <= 0.2 && old <= 0.1
        switch treadmillProtocol {
        case .walkingPad:
            for scheduled in WalkingPadStartTransaction.commands(
                shouldSendStart: shouldSendStart,
                targetSpeedKmh: v
            ) {
                switch scheduled.command {
                case .modeManual:
                    writeCommand(
                        buildCmdPacket(cmd: 0x02, value: 0x01),
                        label: scheduled.command.label,
                        requiresControlReadiness: true,
                        telemetryRequest: treadmillCommandRequest(
                            kind: .other("mode_manual"),
                            decision: telemetryDecision
                        )
                    )
                case .start:
                    scheduleWrite(
                        buildCmdPacket(cmd: 0x04, value: 0x01),
                        label: scheduled.command.label,
                        after: scheduled.delay,
                        requiresControlReadiness: true,
                        telemetryRequest: treadmillCommandRequest(
                            kind: .other("start"),
                            decision: telemetryDecision
                        )
                    )
                case .speed(let targetSpeedKmh):
                    scheduleWrite(
                        buildWalkingPadSetSpeedPacket(kmh: targetSpeedKmh),
                        label: scheduled.command.label,
                        after: scheduled.delay,
                        requiresControlReadiness: true,
                        telemetryRequest: treadmillCommandRequest(
                            kind: treadmillSetSpeedCommandKind(targetSpeedKmh),
                            decision: telemetryDecision
                        )
                    )
                }
            }

        case .ftms:
            enqueueFtmsRequestControlIfNeeded(decision: telemetryDecision)
            if shouldSendStart {
                scheduleWrite(
                    buildFtmsStartOrResumePacket(),
                    label: "FTMS START/RESUME",
                    after: 0.2,
                    requiresControlReadiness: true,
                    telemetryRequest: treadmillCommandRequest(
                        kind: .other("start"),
                        decision: telemetryDecision
                    )
                )
                scheduleWrite(
                    buildFtmsSetSpeedPacket(kmh: v),
                    label: String(format: "SPEED %.1f km/h (FTMS)", v),
                    after: 0.45,
                    requiresControlReadiness: true,
                    telemetryRequest: treadmillCommandRequest(
                        kind: treadmillSetSpeedCommandKind(v),
                        decision: telemetryDecision
                    )
                )
            } else {
                scheduleWrite(
                    buildFtmsSetSpeedPacket(kmh: v),
                    label: String(format: "SPEED %.1f km/h (FTMS)", v),
                    after: 0.2,
                    requiresControlReadiness: true,
                    telemetryRequest: treadmillCommandRequest(
                        kind: treadmillSetSpeedCommandKind(v),
                        decision: telemetryDecision
                    )
                )
            }

        case .fitShow:
            if shouldSendStart {
                writeCommand(
                    buildFitShowStartOrResumePacket(),
                    label: "FitShow START/RESUME",
                    requiresControlReadiness: true,
                    telemetryRequest: treadmillCommandRequest(
                        kind: .other("start"),
                        decision: telemetryDecision
                    )
                )
                scheduleWrite(
                    buildFitShowSetSpeedPacket(kmh: v, incline: 0),
                    label: String(format: "SPEED %.1f km/h (FitShow)", v),
                    after: 0.35,
                    requiresControlReadiness: true,
                    telemetryRequest: treadmillCommandRequest(
                        kind: treadmillSetSpeedCommandKind(v),
                        decision: telemetryDecision
                    )
                )
            } else {
                scheduleWrite(
                    buildFitShowSetSpeedPacket(kmh: v, incline: 0),
                    label: String(format: "SPEED %.1f km/h (FitShow)", v),
                    after: 0.2,
                    requiresControlReadiness: true,
                    telemetryRequest: treadmillCommandRequest(
                        kind: treadmillSetSpeedCommandKind(v),
                        decision: telemetryDecision
                    )
                )
            }

        case .unknown:
            infoToastMessage = "Неподдерживаемая дорожка (протокол не определён)"
        }
    }
    func stopBelt() {
        guard isConnected else { return }
        let telemetryDecision = makeTreadmillDecision(
            source: .stop,
            intent: .stop
        )
        defer { observeTreadmillDecision(telemetryDecision) }
        let telemetryRequest = treadmillCommandRequest(
            kind: .stop,
            decision: telemetryDecision
        )
        let old = deviceTargetSpeedKmh
        desiredSpeedKmh = 0
        deviceTargetSpeedKmh = 0
        recordSpeedChange(from: old, to: 0, reason: "stop_belt")
        resetSessionStats()
        if treadmillProtocol == .ftms {
            enqueueFtmsRequestControlIfNeeded(decision: telemetryDecision)
        }
        guard let packet = buildTreadmillStopPacket() else {
            return
        }
        let telemetryChain = telemetryDecision.map {
            TreadmillStopTelemetryChain(
                sessionID: telemetryRequest.sessionID,
                decisionID: $0.decisionID,
                commandID: telemetryRequest.commandID
            )
        }
        let stopAttemptID = UUID()
        writeCommand(
            packet,
            label: "STOP",
            highPriority: true,
            telemetryRequest: telemetryRequest
        )
        if treadmillProtocol != .ftms {
            scheduleWrite(
                packet,
                label: "STOP retry",
                after: 2.0,
                telemetryRequest: telemetryRequest,
                stopAttemptID: stopAttemptID
            )
            scheduleWrite(
                packet,
                label: "STOP retry",
                after: 4.0,
                telemetryRequest: telemetryRequest,
                stopAttemptID: stopAttemptID
            )
        }
        beginStopObservation(source: "direct", telemetryChain: telemetryChain,
            scheduledStopEffects: treadmillProtocol == .ftms ? 0 : 2, attemptID: stopAttemptID)
    }

    private func stopBeltOnce(
        telemetryDecision: TreadmillControlDecisionEvidence?,
        telemetryRequest: TreadmillCommandTelemetryRequest
    ) -> Bool {
        guard isConnected else { return false }
        guard treadmillProtocol != .ftms || !ftmsControlState.isBlocked else { return false }
        let old = deviceTargetSpeedKmh
        desiredSpeedKmh = 0
        deviceTargetSpeedKmh = 0
        recordSpeedChange(from: old, to: 0, reason: "stop_belt_once")
        resetSessionStats()
        if treadmillProtocol == .ftms {
            enqueueFtmsRequestControlIfNeeded(decision: telemetryDecision)
        }
        guard let packet = buildTreadmillStopPacket() else {
            return false
        }
        writeCommand(
            packet,
            label: "STOP",
            highPriority: true,
            telemetryRequest: telemetryRequest
        )
        return true
    }

    @discardableResult
    private func stopBeltWithToggle(reason: String) -> Bool {
        beginNativeWorkoutStopTerminalRequestIfNeeded()
        let wasRunning = (deviceTargetSpeedKmh > 0.3) || (speedKmh > 0.3)
        let telemetryDecision = makeTreadmillDecision(
            source: .stop,
            intent: .stop
        )
        defer { observeTreadmillDecision(telemetryDecision) }
        let telemetryRequest = treadmillCommandRequest(
            kind: .stop,
            decision: telemetryDecision
        )
        let stopCommandWasEnqueued = stopBeltOnce(
            telemetryDecision: telemetryDecision,
            telemetryRequest: telemetryRequest
        )
        if !stopCommandWasEnqueued {
            nativeWorkoutStopTransportInvocationFailedIfNeeded(
                reason: "Stop не поставлен в очередь"
            )
        }
        let telemetryChain = telemetryDecision.map {
            TreadmillStopTelemetryChain(
                sessionID: telemetryRequest.sessionID,
                decisionID: $0.decisionID,
                commandID: stopCommandWasEnqueued ? telemetryRequest.commandID : nil
            )
        }
        let stopAttemptID = UUID()
        guard wasRunning else {
            beginStopObservation(source: reason, telemetryChain: telemetryChain,
                scheduledStopEffects: 0, attemptID: stopAttemptID)
            return stopCommandWasEnqueued
        }
        switch treadmillProtocol {
        case .walkingPad:
            let toggle = buildCmdPacket(cmd: 0x04, value: 0x01)
            scheduleWrite(
                toggle,
                label: "START/STOP TOGGLE",
                after: 2.0,
                telemetryRequest: treadmillCommandRequest(
                    kind: .other("legacy_stop_toggle"),
                    decision: telemetryDecision
                ),
                stopAttemptID: stopAttemptID
            )
            let epoch = commandQueueEpoch
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                guard let self else { return }
                let cancelled = self.commandQueueEpoch != epoch
                defer { self.completeScheduledStopEffect(attemptID: stopAttemptID, cancelled: cancelled) }
                guard !cancelled else { return }
                let reported = self.deviceReportedSpeedKmh
                let observed = max(self.speedKmh, reported)
                if observed > 0.2 {
                    if let stopPacket = self.buildTreadmillStopPacket() {
                        self.writeCommand(
                            stopPacket,
                            label: "STOP retry",
                            telemetryRequest: telemetryRequest
                        )
                    }
                }
            }

        case .ftms:
            break // Control Point completion/timeout owns this single Stop attempt.
        case .fitShow, .unknown:
            if let stopPacket = buildTreadmillStopPacket() {
                scheduleWrite(
                    stopPacket,
                    label: "STOP retry",
                    after: 2.0,
                    telemetryRequest: telemetryRequest
                )
                scheduleWrite(
                    stopPacket,
                    label: "STOP retry",
                    after: 4.0,
                    telemetryRequest: telemetryRequest
                )
            }
        }
        beginStopObservation(source: reason, telemetryChain: telemetryChain,
            scheduledStopEffects: treadmillProtocol == .walkingPad ? 2 : 0, attemptID: stopAttemptID)
        return stopCommandWasEnqueued
    }

    private func currentStopObservationContext() -> StopObservationContext? {
        guard treadmillProtocol == .walkingPad,
              isConnected,
              let peripheralID = connectedPeripheralId,
              let connectionEpoch = controllerUnitsConnectionEpoch else {
            return nil
        }
        return StopObservationContext(
            peripheralID: peripheralID,
            connectionEpoch: connectionEpoch,
            notificationStreamID: stopObservationStreamID
        )
    }

    private func beginStopObservation(
        source: String,
        telemetryChain: TreadmillStopTelemetryChain? = nil,
        scheduledStopEffects: Int? = nil,
        attemptID: UUID = UUID(),
        now: Date = Date()
    ) {
        cancelAppleHeartRateZoneRead()
        let attemptedMonotonic = telemetryV2Coordinator.stopAttemptMonotonicTime
        stopObservationFreshnessWorkItem?.cancel()
        stopObservationFreshnessWorkItem = nil
        finishActiveStopObservationUnconfirmed(reason: "superseded_by_new_attempt", now: now)
        if let pendingAttemptID = unavailableStopAttempt?.id {
            finalizeUnavailableStopAttempt(attemptID: pendingAttemptID)
        }
        telemetryV2Coordinator.invalidateStopTail()
        activeTreadmillStopTelemetryChain = telemetryChain
        guard let context = currentStopObservationContext() else {
            recordUnavailableStopAttempt(source: source, attemptedAt: now, attemptedMonotonic: attemptedMonotonic)
            return
        }

        let lifecycle = StopObservationLifecycle(
            attemptID: attemptID,
            source: source,
            attemptedAt: now,
            context: context,
            scheduledStopEffects: scheduledStopEffects
        )
        stopObservationLifecycle = lifecycle
        captureStopTelemetryAttempt(lifecycle.attemptID, attemptedMonotonic: attemptedMonotonic)
        stopTruthStatusText = "stop requested • confirming"

        scheduleStopObservationCheckpoints(attemptID: lifecycle.attemptID)
    }

    private func recordUnavailableStopAttempt(source: String, attemptedAt: Date, attemptedMonotonic: Duration) {
        let attemptID = UUID()
        captureStopTelemetryAttempt(attemptID, attemptedMonotonic: attemptedMonotonic)
        unavailableStopAttempt = UnavailableStopAttempt(
            id: attemptID,
            source: source,
            attemptedAt: attemptedAt,
            commandSentAt: nil
        )
        let transportCanSend = isConnected && commandCharacteristic != nil
            && !(treadmillProtocol == .ftms && ftmsControlState.isBlocked)
            && buildTreadmillStopPacket() != nil

        let telemetryEvidence = treadmillTelemetryConnectionEpoch.map {
            TreadmillStopTruthEvidence(
                stopAttemptID: attemptID,
                decisionID: activeTreadmillStopTelemetryChain?.decisionID,
                commandID: activeTreadmillStopTelemetryChain?.commandID,
                observationID: nil,
                connectionEpoch: $0,
                protocolKind: treadmillTelemetryProtocolKind,
                conclusion: .unconfirmed(
                    reason: transportCanSend
                        ? "legacy_stop_confirmation_unavailable_for_protocol"
                        : "stop_command_not_sent_transport_unavailable"
                ),
                rawSpeedTenths: nil,
                rawDeviceState: nil,
                checksumValid: nil,
                observationReceivedAt: nil,
                evaluatedAt: attemptedAt
            )
        }

        if transportCanSend {
            stopTruthStatusText = "stop requested • confirmation unavailable"
            infoToastMessage = "Остановка дорожки запрошена, но устройство не может подтвердить её. Если полотно движется, используйте физическое отключение или аварийный способ остановки."
        } else {
            stopTruthStatusText = "stop command not sent • confirmation unavailable"
            infoToastMessage = "Команда остановки не отправлена: соединение с дорожкой недоступно. Если полотно движется, используйте физическое отключение или аварийный способ остановки."
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.finalizeUnavailableStopAttempt(attemptID: attemptID)
        }
        if let telemetryEvidence {
            observeTreadmillTelemetry(.stopEvidence(telemetryEvidence))
        }
    }

    private func finalizeUnavailableStopAttempt(attemptID: UUID) {
        guard unavailableStopAttempt?.id == attemptID else { return }

        unavailableStopAttempt = nil
    }

    private func scheduleStopObservationCheckpoints(attemptID: UUID) {
        stopObservationCheckpointWorkItems.forEach { $0.cancel() }
        stopObservationCheckpointWorkItems.removeAll()

        for delay in StopObservationPolicy.checkpointDelays {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self,
                      var lifecycle = self.stopObservationLifecycle,
                      lifecycle.attemptID == attemptID,
                      lifecycle.finalResult == nil else {
                    return
                }
                let now = Date()
                let evaluation = lifecycle.currentEvaluation(at: now)
                self.refreshStopTruthStatus(lifecycle: lifecycle, evaluation: evaluation)

                if delay == StopObservationPolicy.observationWindow {
                    _ = lifecycle.finalizeTimeout(at: now)
                    self.stopObservationLifecycle = lifecycle
                    self.finishStopObservation(lifecycle: lifecycle, now: now)
                }
            }
            stopObservationCheckpointWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func recordStopObservation(
        status: BLETransportCodec.WalkingPadStatus,
        peripheral: CBPeripheral,
        characteristic: CBCharacteristic,
        observedAt: Date
    ) {
        guard var lifecycle = stopObservationLifecycle,
              characteristic === notifyCharacteristic,
              peripheral.identifier == connectedPeripheralId,
              let context = currentStopObservationContext() else {
            return
        }

        guard lifecycle.finalResult == nil else { return }

        let evaluation = lifecycle.record(
            speedRawTenths: Int(status.speedRawTenths),
            state: status.beltState,
            checksumValid: status.checksumOk,
            context: context,
            observedAt: observedAt,
            evaluatedAt: Date()
        )
        stopObservationLifecycle = lifecycle
        refreshStopTruthStatus(lifecycle: lifecycle, evaluation: evaluation)

        scheduleStopObservationFreshnessRefresh(
            attemptID: lifecycle.attemptID,
            observationSequence: lifecycle.observations.last?.sequence
        )
    }

    private func scheduleStopObservationFreshnessRefresh(
        attemptID: UUID,
        observationSequence: Int?
    ) {
        stopObservationFreshnessWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  let lifecycle = self.stopObservationLifecycle,
                  lifecycle.attemptID == attemptID,
                  lifecycle.observations.last?.sequence == observationSequence else {
                return
            }
            let now = Date()
            let evaluation = lifecycle.currentEvaluation(at: now)
            self.refreshStopTruthStatus(lifecycle: lifecycle, evaluation: evaluation)
            if evaluation.result == .stale, lifecycle.finalResult == nil {

            }
            self.updateTreadmillStatus()
        }
        stopObservationFreshnessWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + StopObservationPolicy.freshnessInterval + 0.01,
            execute: workItem
        )
    }

    private func refreshStopTruthStatus(
        lifecycle: StopObservationLifecycle,
        evaluation: StopObservationEvaluation
    ) {
        stopTruthStatusText = lifecycle.statusText(for: evaluation,
            currentObservationMatches: currentStopObservationContext() == lifecycle.context
                && latestTreadmillObservationEvidence?.receivedAt == lifecycle.observations.last?.observedAt)
    }

    private func completeScheduledStopEffect(attemptID: UUID?, cancelled: Bool) {
        guard let attemptID, var lifecycle = stopObservationLifecycle,
              lifecycle.attemptID == attemptID, lifecycle.finalResult == nil else { return }
        lifecycle.completeScheduledStopEffect()
        stopObservationLifecycle = lifecycle

        finalizeCompletedStopIfReady()
    }

    private func finalizeCompletedStopIfReady(now: Date = Date()) {
        guard var lifecycle = stopObservationLifecycle,
              currentStopObservationContext() == lifecycle.context,
              let observation = latestTreadmillObservationEvidence,
              observation.protocolKind == .walkingPad,
              observation.connectionEpoch.rawValue == lifecycle.context.connectionEpoch,
              observation.receivedAt == lifecycle.observations.last?.observedAt,
              lifecycle.finalizeCompletedStopIfReady(at: now,
                queueIdle: commandQueue.isEmpty && !isCommandQueueProcessing) else { return }
        stopObservationLifecycle = lifecycle
        finishStopObservation(lifecycle: lifecycle, now: now)
    }

    private func finishStopObservation(lifecycle: StopObservationLifecycle, now: Date) {
        stopObservationCheckpointWorkItems.forEach { $0.cancel() }
        stopObservationCheckpointWorkItems.removeAll()

        let evaluation = lifecycle.currentEvaluation(at: now)
        if !evaluation.isConfirmed {
            stopObservationFreshnessWorkItem?.cancel()
            stopObservationFreshnessWorkItem = nil
        }
        refreshStopTruthStatus(lifecycle: lifecycle, evaluation: evaluation)

        switch lifecycle.finalResult {
        case .confirmed:
            break
        case .timeoutUnconfirmed:
            if lifecycle.shouldPresentTimeoutWarning(at: now,
                currentObservationMatches: currentStopObservationContext() == lifecycle.context
                    && latestTreadmillObservationEvidence?.receivedAt == lifecycle.observations.last?.observedAt,
                queueIdle: commandQueue.isEmpty && !isCommandQueueProcessing) {
                infoToastMessage = "Остановка дорожки не подтверждена. Если полотно движется, используйте физическое отключение или аварийный способ остановки."
            }
        case .unconfirmed:
            if lifecycle.finalReason?.hasPrefix("stop_command_not_sent") == true {
                stopTruthStatusText = "stop command not sent • confirmation unavailable"
                infoToastMessage = "Команда остановки не отправлена. Если полотно движется, используйте физическое отключение или аварийный способ остановки."
            } else {
                stopTruthStatusText = "stop unconfirmed"
            }
            if lifecycle.finalReason?.hasPrefix("stop_command_not_sent") != true,
               lifecycle.finalReason != "new_motion_requested",
               lifecycle.finalReason != "superseded_by_new_attempt" {
                infoToastMessage = "Остановка дорожки не подтверждена. Если полотно движется, используйте физическое отключение или аварийный способ остановки."
            }
        case .none:
            return
        }

        observeCurrentStopTruth(
            lifecycle: lifecycle,
            evaluation: evaluation,
            evaluatedAt: now
        )
        if lifecycle.finalReason?.hasPrefix("stop_command_not_sent") != true {
            telemetryV2Coordinator.stopAttemptFinalized(attemptID: lifecycle.attemptID)
        }
    }

    private func finishActiveStopObservationUnconfirmed(reason: String, now: Date = Date()) {
        guard var lifecycle = stopObservationLifecycle,
              lifecycle.finalResult == nil else {
            return
        }
        let finalReason = lifecycle.commandSentAt == nil
            ? "stop_command_not_sent_\(reason)"
            : reason
        _ = lifecycle.finalizeUnconfirmed(at: now, reason: finalReason)
        stopObservationLifecycle = lifecycle
        finishStopObservation(lifecycle: lifecycle, now: now)
    }

    private func endStopObservationForNewMotion() {
        stopObservationFreshnessWorkItem?.cancel()
        stopObservationFreshnessWorkItem = nil
        finishActiveStopObservationUnconfirmed(reason: "new_motion_requested")
        if let pendingAttemptID = unavailableStopAttempt?.id {
            finalizeUnavailableStopAttempt(attemptID: pendingAttemptID)
        }
        stopObservationLifecycle = nil
        stopTruthStatusText = ""
        activeTreadmillStopTelemetryChain = nil
        telemetryV2Coordinator.invalidateStopTail()
    }
    func setTargetSpeedFromSlider(_ kmh: Double) {
        guard !blocksNonStopTreadmillMotion else { return }
        let v = clampRunningSpeedKmh(kmh)
        desiredSpeedKmh = v
        guard isTreadmillControlReady else { return }
        let isRunning = deviceTargetSpeedKmh > 0.1 || speedKmh > 0.2
        guard isRunning else { return }
        let old = deviceTargetSpeedKmh
        guard abs(v - old) >= 0.01 else { return }
        deviceTargetSpeedKmh = v
        recordSpeedChange(from: old, to: v, reason: "manual_slider")
        let telemetryDecision = makeTreadmillDecision(
            source: .manual,
            intent: .setDesiredSpeed(DesiredSpeedKilometresPerHour(value: v))
        )
        defer { observeTreadmillDecision(telemetryDecision) }
        sendTreadmillSetSpeed(
            v,
            label: String(format: "SPEED %.1f km/h", v),
            decision: telemetryDecision
        )
    }
    func adjustSpeed(delta: Double) {
        guard isTreadmillControlReady else { return }
        guard !blocksNonStopTreadmillMotion else { return }
        let base = (deviceTargetSpeedKmh > 0.1) ? deviceTargetSpeedKmh : (speedKmh > 0.1 ? speedKmh : desiredSpeedKmh)
        let v = clampAnySpeedKmh(base + delta)
        guard abs(v - base) >= 0.01 else { return }
        let old = deviceTargetSpeedKmh
        desiredSpeedKmh = v
        deviceTargetSpeedKmh = v
        recordSpeedChange(from: old, to: v, reason: "manual_adjust")
        let telemetryDecision = makeTreadmillDecision(
            source: .manual,
            intent: .setDesiredSpeed(DesiredSpeedKilometresPerHour(value: v))
        )
        defer { observeTreadmillDecision(telemetryDecision) }
        sendTreadmillSetSpeed(
            v,
            label: String(format: "SPEED %.1f km/h", v),
            decision: telemetryDecision
        )
    }

    // HR control actions
    var canExtendHrSession: Bool {
        guard isHrControlRunning, intervalWorkoutState == nil,
              let startedAt = hrControlStartedInstant else { return false }
        return hrSessionTotalSeconds < (hrMaxSessionMinutes * 60)
            && HRDomainService.remainingSessionSeconds(
                totalSeconds: hrSessionTotalSeconds, elapsed: startedAt.duration(to: .now)
            ) > 0
    }

    var shouldPresentActiveWorkout: Bool {
        if isHrControlRunning { return true }
        guard isNativeWorkoutRecoveryActive,
              case .record(let record) = nativeWorkoutRecoveryLoadResult else {
            return false
        }
        return record.phase == .committed
            || record.phase == .stopping
            || record.phase == .finishing
    }

    var canStopPresentedWorkout: Bool {
        guard isNativeWorkoutRecoveryActive else { return true }
        guard case .record(let record) = nativeWorkoutRecoveryLoadResult,
              record.phase == .committed || record.phase == .stopping else {
            return false
        }
        return !nativeWorkoutRecoveryStopRequested
            && isTreadmillControlReady
    }

    var presentedWorkoutElapsedSeconds: Int {
        guard let hrControlStartedAt else { return timeSec }
        return max(0, Int(Date().timeIntervalSince(hrControlStartedAt)))
    }

    var presentedWorkoutPhaseTitle: String? {
        guard isNativeWorkoutRecoveryActive else { return nil }
        if nativeWorkoutRecoveryStopRequested { return "ЗАВЕРШАЕМ" }
        return nativeWorkoutRecoverySessionRecovered
            ? "ВОССТАНОВЛЕНА"
            : "ВОССТАНОВЛЕНИЕ"
    }

    var hrSessionMaxMinutes: Int { hrMaxSessionMinutes }

    func extendHrSession(minutes: Int = 5) {
        guard canExtendHrSession else { return }
        let addSeconds = max(0, minutes * 60)
        guard addSeconds > 0 else { return }
        let maxTotalSeconds = hrMaxSessionMinutes * 60
        let newTotalSeconds = min(hrSessionTotalSeconds + addSeconds, maxTotalSeconds)
        let addedSeconds = max(0, newTotalSeconds - hrSessionTotalSeconds)
        guard addedSeconds > 0 else { return }
        if nativeHealthKitWorkoutCommitted,
           let recoveryRecord = activeNativeWorkoutRecoveryRecord,
           !persistNativeWorkoutRecoveryRecord(
                recoveryRecord.planningDuration(seconds: newTotalSeconds)
           ) {
            infoToastMessage = "Не удалось сохранить новое время тренировки."
            return
        }
        hrSessionTotalSeconds = newTotalSeconds
        syncHrSessionTiming()
    }

    func startHrControl() {
        cancelAppleHeartRateZoneRead()
        guard profileDataAvailable,
              !isHrControlRunning,
              !hasOutstandingNativeWorkoutRecovery,
              !nativeHeartRatePreflightEngine.hasStartIntent,
              !nativeHeartRateProviderLifecycle.cleanupInFlight else { return }
        if let blocker = intervalStartBlockReason {
            infoToastMessage = blocker
            return
        }
        pendingIntervalPlan = intervalWorkoutSelected ? IntervalWorkoutRuntime.Plan(
            maximumHeartRate: heartRateZoneSettings.maximumHeartRate, cycles: intervalCycleCount
        ) : nil
        intervalWorkoutState = nil
        hrControlStartedInstant = nil
        let now = Date()
        let intent = NativeHeartRatePreflightEngine.Intent(
            id: UUID(),
            targetBPM: hrTargetBPM,
            durationMinutes: hrDurationMinutes,
            requestedAt: now
        )
        let effects = nativeHeartRatePreflightEngine.requestStart(
            intent: intent,
            safety: nativeHeartRateSafetyFacts(now: now)
        )
        guard nativeHeartRatePreflightEngine.hasStartIntent else {
            recomputeHrStartAllowed()
            return
        }
        nativeHeartRateFlowOwnsController = true
        nativeHeartRateProviderLifecycle.bindAttempt(intent.id)
        isNativeHeartRateCurrent = false
        hrStreamingActive = false
        hrLastValueAt = nil
        heartRateBPM = 0
        nativeHeartRateLogger.info("preflight_requested")
        applyNativeHeartRatePreflightEffects(effects)
    }

    func cancelNativeHeartRatePreflight() {
        applyNativeHeartRatePreflightEffects(
            nativeHeartRatePreflightEngine.cancel(reason: .user)
        )
    }

    func trainingHubDidAppear() {
        isTrainingHubVisible = true
        warmNativeHeartRateProviderIfPossible()
    }

    func trainingHubDidDisappear() {
        isTrainingHubVisible = false
        guard !shouldPresentActiveWorkout else { return }
        applyNativeHeartRatePreflightEffects(
            nativeHeartRatePreflightEngine.cancel(reason: .hubLeft)
        )
    }

#if DEBUG
    func prepareTrainingUIIdlePressureBaseline() {
        isConnected = false
        isTreadmillControlReady = false
        isHrControlRunning = false
        isNativeHeartRatePreflightActive = false
        isNativeHeartRateCurrent = false
        hrStreamingActive = false
        heartRateBPM = 0
        let initialPeripherals = (0..<4).map { index in
            DiscoveredPeripheral(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index)")!,
                name: "Mock WalkingPad \(index + 1)",
                rssi: -50 - index,
                isKnown: false
            )
        }
        discoveredPeripherals = initialPeripherals
        discoveryUIPeripherals = initialPeripherals
    }

    func applyTrainingUIDiscoveryPressureEvent(_ eventIndex: Int) {
        let deviceIndex = eventIndex % discoveredPeripherals.count
        let existing = discoveredPeripherals[deviceIndex]
        let updated = DiscoveredPeripheral(
            id: existing.id,
            name: existing.name,
            rssi: -50 - ((eventIndex / discoveredPeripherals.count) % 4),
            isKnown: existing.isKnown
        )
        recordDiscoveredPeripheral(updated)
    }

    func prepareTrainingUIActivePressureBaseline() {
        isConnected = true
        isTreadmillControlReady = true
        isHrControlRunning = true
        isNativeHeartRatePreflightActive = false
        isNativeHeartRateCurrent = true
        hrStreamingActive = true
        heartRateBPM = 130
        lastKnownHeartRateBPM = 130
        hrLastValueAt = Date(timeIntervalSince1970: 1_800_000_000)
        hrDataStaleSeconds = 0
        deviceReportedSpeedKmh = 5.0
        deviceReportedAppSpeedKmh = 5.0
        deviceReportedState = 1
        deviceReportedManualMode = 1
        deviceReportedTimeSeconds = 0
        deviceReportedDistance10m = 0
        deviceReportedSteps = 0
        deviceReportedButton = 0
        deviceReportedChecksumOk = true
        deviceReportedRawHex = "F8A2"
        publishTrainingUITreadmillSpeedIfNeeded()
        speedKmh = 5.0
        timeSec = 0
        distKm = 0
        stepsCount = 0
        avgSpeedActive = true
        avgSpeedKmh = 5.0
        hrAverageBPM = 130
        beatsPerMeter = 1.56
        hrTargetBPM = 130
        hrSessionTotalSeconds = 600
        hrRemainingSeconds = 600
        hrNextDecisionSeconds = 10
        hrProgress = 0
        hrCooldownRemainingSeconds = 0
        hrControlStartedAt = nil
    }

    func applyTrainingUIHeartRatePressureEvent(second: Int) {
        let bpm = 128 + ((second / 5) % 5)
        heartRateBPM = bpm
        lastKnownHeartRateBPM = bpm
        hrLastValueAt = Date(timeIntervalSince1970: 1_800_000_000 + Double(second))
        hrDataStaleSeconds = 0
        hrStreamingActive = true
        isNativeHeartRateCurrent = true
    }

    func applyTrainingUITreadmillPressureEvent(second: Int) {
        deviceReportedSpeedKmh = 5.0
        deviceReportedAppSpeedKmh = 5.0
        deviceReportedState = 1
        deviceReportedManualMode = 1
        deviceReportedTimeSeconds = second
        deviceReportedDistance10m = second / 2
        deviceReportedSteps = second * 2
        deviceReportedButton = 0
        deviceReportedChecksumOk = true
        deviceReportedRawHex = String(format: "F8A2%04X", second)
        publishTrainingUITreadmillSpeedIfNeeded()
    }

    func applyTrainingUITimerPressureEvent(second: Int) {
        speedKmh = 5.0
        distKm = Double(second) * 5.0 / 3_600.0
        timeSec = second
        stepsCount = second * 2
        avgSpeedActive = true
        avgSpeedKmh = 5.0
        hrAverageBPM = 130
        beatsPerMeter = 1.56
        hrPredictorStatusLine = "HR \(heartRateBPM) / цель \(hrTargetBPM) · тренд —"
        hrRemainingSeconds = 600 - second
        hrProgress = Double(second) / 600.0
        hrNextDecisionSeconds = 10 - (second % 10)
        if second.isMultiple(of: 10) {
            hrStatusLine = "HR‑контроль: цель удерживается"
            hrDecisionDetails = "Deterministic HOLD sample \(second / 10)"
        }
    }
#endif

    func nativeHeartRateAppBecameActive() {
        let previousState = currentWorkoutLifecycleAppState
        nativeHeartRateAppActivity = .active
        recordWorkoutLifecycleTransition(
            from: previousState,
            to: .active,
            occurredAt: Date()
        )
        applyNativeHeartRatePreflightEffects(
            nativeHeartRatePreflightEngine.safetyChanged(
                nativeHeartRateSafetyFacts(),
                now: Date(),
                freshnessLimit: TimeInterval(hrStaleThresholdSeconds)
            )
        )
        warmNativeHeartRateProviderIfPossible()
        resolveDeferredNativeHealthKitLinkageIfPossible()
        recomputeHrStartAllowed()
    }

    func nativeHeartRateAppBecameInactive() {
        let previousState = currentWorkoutLifecycleAppState
        nativeHeartRateAppActivity = .inactive
        recordWorkoutLifecycleTransition(
            from: previousState,
            to: .inactive,
            occurredAt: Date()
        )
        applyNativeHeartRatePreflightEffects(
            nativeHeartRatePreflightEngine.safetyChanged(
                nativeHeartRateSafetyFacts(),
                now: Date(),
                freshnessLimit: TimeInterval(hrStaleThresholdSeconds)
            )
        )
        recomputeHrStartAllowed()
    }

    func nativeHeartRateAppEnteredBackground() {
        let previousState = currentWorkoutLifecycleAppState
        nativeHeartRateAppActivity = .background
        recordWorkoutLifecycleTransition(
            from: previousState,
            to: .background,
            occurredAt: Date()
        )
        applyNativeHeartRatePreflightEffects(
            nativeHeartRatePreflightEngine.safetyChanged(
                nativeHeartRateSafetyFacts(),
                now: Date(),
                freshnessLimit: TimeInterval(hrStaleThresholdSeconds)
            )
        )
        recomputeHrStartAllowed()
    }

    private var currentWorkoutLifecycleAppState: WorkoutLifecycleAppState {
        switch nativeHeartRateAppActivity {
        case .active: .active
        case .inactive: .inactive
        case .background: .background
        }
    }

    private var currentWorkoutLifecycleStage: WorkoutLifecycleStage {
        if nativeHealthKitWorkoutFinishInFlight
            || pendingNativeWorkoutStopTerminalRequest != nil {
            return .stopping
        }
        if isNativeWorkoutRecoveryActive && !isHrControlRunning {
            return .recovery
        }
        if isHrControlRunning && (cooldownRuntimeState != nil || hrCooldownRemainingSeconds > 0) {
            return .cooldown
        }
        if isHrControlRunning && nativeHealthKitWorkoutCommitted {
            return .main
        }
        if isNativeHeartRatePreflightActive
            || (nativeHeartRateFlowOwnsController && !nativeHealthKitWorkoutCommitted) {
            return .preflight
        }
        return .idle
    }

    private func synchronizeWorkoutIdleTimerOwnership() {
        let hasCommittedWorkout = nativeHealthKitWorkoutCommitted && isHrControlRunning
        guard let shouldDisable = workoutIdleTimerOwnership.update(
            WorkoutLifecyclePolicyInput(
                appState: currentWorkoutLifecycleAppState,
                stage: currentWorkoutLifecycleStage,
                hasCommittedWorkout: hasCommittedWorkout
            )
        ) else {
            return
        }
#if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = shouldDisable
#endif
    }

    private func recordWorkoutLifecycleTransition(
        from previousState: WorkoutLifecycleAppState,
        to currentState: WorkoutLifecycleAppState,
        occurredAt: Date
    ) {
        let stage = currentWorkoutLifecycleStage
        let hasCommittedWorkout = nativeHealthKitWorkoutCommitted && isHrControlRunning
        let decision = WorkoutLifecyclePolicy.evaluate(WorkoutLifecyclePolicyInput(
            appState: currentState,
            stage: stage,
            hasCommittedWorkout: hasCommittedWorkout
        ))
        let lastFactualAt = hrLastValueAt
        let lastReceivedAt = latestHeartRateDelivery?.receivedAt
        let lastAgeSeconds = lastFactualAt.map {
            max(0, occurredAt.timeIntervalSince($0))
        }
        let connectionState: ConnectionState = {
            guard isConnected else { return .disconnected }
            return isTreadmillControlReady ? .connected : .degraded
        }()

        guard activeTelemetryV2SessionID != nil,
              let telemetryState = AppLifecycleState(rawValue: currentState.rawValue),
              let telemetryPreviousState = AppLifecycleState(rawValue: previousState.rawValue),
              let telemetryStage = AppWorkoutLifecycleStage(rawValue: stage.rawValue),
              let telemetryAction = AppBackgroundPolicyAction(
                rawValue: decision.action.rawValue
              ) else {
            return
        }
        let lifecycleEvent = AppLifecycleEvent(
            previousState: telemetryPreviousState,
            currentState: telemetryState,
            workoutStage: telemetryStage,
            hasCommittedWorkout: hasCommittedWorkout,
            policyAction: telemetryAction,
            policyReason: decision.reason,
            controlLoopPermitted: decision.permitsControlLoop,
            heartRateProviderState: iPhoneHealthKitHeartRateProvider.state.rawValue,
            lastHeartRateFactualAt: lastFactualAt,
            lastHeartRateReceivedAt: lastReceivedAt,
            lastHeartRateAgeSeconds: lastAgeSeconds,
            treadmillConnectionState: connectionState,
            treadmillControlReady: isTreadmillControlReady,
            treadmillProtocol: treadmillProtocol.rawValue
        )
        do {
            _ = telemetryV2Coordinator.observeEvent(
                try AppLifecycleEvidencePersistence.payload(for: lifecycleEvent),
                occurredAt: occurredAt
            )
        } catch {
        }
    }

    private func commitExistingHrControl(preflightLatencySeconds: TimeInterval) {
        let unitsDecision = controllerUnitsGateDecision()
        guard nativeHeartRateSafetyFacts().permitsCommit,
              unitsDecision.allowed,
              nativeHealthKitWorkoutCommitted,
              let controlledWorkoutStartedAt = activeNativeWorkoutRecoveryRecord?
                .controlledWorkoutStartedAt,
              activeNativeWorkoutRecoveryRecord?.legacySessionID != nil else {
            if !unitsDecision.allowed {
                retryControllerUnitsQueryAfterBlockedStart()
            }
            abortNativeHeartRateFlow(reason: .superseded)
            return
        }

        // Reset per-session counters before starting the V2 session.
        resetSessionStats()
        let legacySessionID = activeNativeWorkoutRecoveryRecord?.legacySessionID
        isHrControlRunning = true
        hrStatusLine = "HR‑контроль запущен"
        intervalWorkoutState = pendingIntervalPlan.map { IntervalWorkoutRuntime.State(plan: $0) }
        if let measuredAt = hrLastValueAt {
            observeIntervalHeartRate(heartRateBPM, measuredAt: measuredAt, now: Date())
        }
        hrControlStartedInstant = ContinuousClock.now
        hrSessionTotalSeconds = pendingIntervalPlan?.totalSeconds ?? max(60, hrDurationMinutes * 60)
        hrRemainingSeconds = hrSessionTotalSeconds
        hrLastDecisionAt = ContinuousClock.now
        hrNextDecisionSeconds = max(HRDomainService.minimumDecisionIntervalSeconds, hrDecisionIntervalSeconds)
        hrProgress = 0
        hrControlStartedAt = controlledWorkoutStartedAt
        hrDecisionDetails = ""
        hrPredictorStatusLine = ""
        hrTrendSamples.removeAll()
        hrTrendEmaBpm = nil
        hrNoDataSeconds = 0
        hrControlFailed = false
        clearCooldownRuntimeState()
        hrControlStartedBelt = false

        nativePreflightCommitTimestamps = nil
        beginTelemetryV2Session(legacySessionID: legacySessionID)
        if let state = intervalWorkoutState {
            _ = telemetryV2Coordinator.observeWorkoutPhase(
                state.telemetryPhase, occurredAt: Date(), intervalContext: state.evidence()
            )
        }
        if treadmillProtocol == .walkingPad,
           let connectionEpoch = treadmillTelemetryConnectionEpoch {
            treadmillObservationNormalizer.commitWorkout(
                unitsTruth: treadmillUnitsTruthEvidence(),
                connectionEpoch: connectionEpoch,
                at: controlledWorkoutStartedAt
            )
        }
        persistQualifyingNativeHeartRateBeforeMotion()
        if let motionTargetSpeedKmh = HRDomainService.initialMotionTargetSpeedKmh(
            deviceTargetSpeedKmh: deviceTargetSpeedKmh,
            speedKmh: speedKmh,
            desiredSpeedKmh: desiredSpeedKmh
        ) {
            hrControlStartedBelt = true
            startWithSpeed(motionTargetSpeedKmh)
        }
    }

    private var nativeHeartRateTransportIsValid: Bool {
        guard let currentConnection = currentTreadmillControlConnection else { return false }
        return treadmillProtocol != .unknown
            && treadmillProtocolConnection == currentConnection
            && isTreadmillControlReady
    }

    private func nativeHeartRateSafetyFacts(
        now: Date = Date()
    ) -> NativeHeartRatePreflightEngine.SafetyFacts {
        let effectiveAppActivity: NativeHeartRatePreflightEngine.AppActivity = {
#if canImport(UIKit)
            let systemActivity: NativeHeartRatePreflightEngine.AppActivity
            switch UIApplication.shared.applicationState {
            case .active: systemActivity = .active
            case .inactive: systemActivity = .inactive
            case .background: systemActivity = .background
            @unknown default: systemActivity = .background
            }
            if nativeHeartRateAppActivity == .background || systemActivity == .background {
                return .background
            }
            if nativeHeartRateAppActivity == .inactive || systemActivity == .inactive {
                return .inactive
            }
#endif
            return nativeHeartRateAppActivity
        }()
        let stopInProgress = NativeHeartRatePreflightEngine.RuntimePolicy.stopInProgress(
            hasObservationLifecycle: stopObservationLifecycle != nil,
            observationHasFinalResult: stopObservationLifecycle?.finalResult != nil,
            hasUnavailableAttempt: unavailableStopAttempt != nil
        )
        return NativeHeartRatePreflightEngine.SafetyFacts(
            appActivity: effectiveAppActivity,
            treadmillControlReady: isTreadmillControlReady && profileDataAvailable,
            transportValid: nativeHeartRateTransportIsValid,
            controllerUnitsAllowed: controllerUnitsGateDecision(now: now).allowed,
            hasConflictingWorkout: NativeHeartRatePreflightEngine.RuntimePolicy
                .hasConflictingWorkout(
                    isHrControlRunning: isHrControlRunning,
                    treadmillTestRunIsActive: treadmillTestRunIsActive,
                    nativeWorkoutCommitted: nativeHealthKitWorkoutCommitted,
                    nativeFlowOwnsController: nativeHeartRateFlowOwnsController,
                    nativeWorkoutFinishInFlight: nativeHealthKitWorkoutFinishInFlight
                ),
            stopInProgress: stopInProgress,
            telemetryAvailability: .healthy
        )
    }

    private func warmNativeHeartRateProviderIfPossible() {
        guard !nativeHeartRateProviderLifecycle.cleanupInFlight,
              treadmillTestRunHeartRateProvider == nil,
              !treadmillTestRunHeartRateCleanupInFlight,
              !treadmillTestRunIsActive,
              !hasOutstandingNativeWorkoutRecovery,
              NativeHeartRatePreflightEngine.RuntimePolicy.canWarmPrepare(
            isTrainingHubVisible: isTrainingHubVisible,
            appActivity: nativeHeartRateAppActivity,
            isHrControlRunning: isHrControlRunning,
            nativeWorkoutCommitted: nativeHealthKitWorkoutCommitted,
            nativeWorkoutFinishInFlight: nativeHealthKitWorkoutFinishInFlight,
            providerIsIdle: iPhoneHealthKitHeartRateProvider.state == .idle,
            providerIsSupported: IPhoneHealthKitLiveHeartRateProvider.isSupported
        ) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let canPrepare = await iPhoneHealthKitHeartRateProvider
                .canPrepareWithoutAuthorizationPrompt()
            guard canPrepare,
                  !nativeHeartRateProviderLifecycle.cleanupInFlight,
                  treadmillTestRunHeartRateProvider == nil,
                  !treadmillTestRunHeartRateCleanupInFlight,
                  !treadmillTestRunIsActive,
                  !hasOutstandingNativeWorkoutRecovery,
                  NativeHeartRatePreflightEngine.RuntimePolicy.canWarmPrepare(
                    isTrainingHubVisible: isTrainingHubVisible,
                    appActivity: nativeHeartRateAppActivity,
                    isHrControlRunning: isHrControlRunning,
                    nativeWorkoutCommitted: nativeHealthKitWorkoutCommitted,
                    nativeWorkoutFinishInFlight: nativeHealthKitWorkoutFinishInFlight,
                    providerIsIdle: iPhoneHealthKitHeartRateProvider.state == .idle,
                    providerIsSupported: IPhoneHealthKitLiveHeartRateProvider.isSupported
                  ) else { return }
            applyNativeHeartRatePreflightEffects(
                nativeHeartRatePreflightEngine.requestWarmPreparation()
            )
        }
    }

    private func applyNativeHeartRatePreflightEffects(
        _ effects: [NativeHeartRatePreflightEngine.Effect]
    ) {
        syncNativeHeartRatePreflightPresentation()
        for effect in effects {
            switch effect {
            case .prepare:
                prepareNativeHeartRateProvider()
            case .startCollection(let intent, let acquisitionStartedAt):
                startNativeHeartRateCollection(
                    intent: intent,
                    acquisitionStartedAt: acquisitionStartedAt
                )
            case .commit(let intent, let observation, let acquisitionStartedAt):
                commitNativeHeartRatePreflight(
                    intent: intent,
                    observation: observation,
                    acquisitionStartedAt: acquisitionStartedAt
                )
            case .discard(let reason):
                discardNativeHeartRatePreflight(reason: reason)
            }
        }
        syncNativeHeartRatePreflightPresentation()
        recomputeHrStartAllowed()
    }

    private func syncNativeHeartRatePreflightPresentation() {
        isNativeHeartRatePreflightActive = nativeHeartRatePreflightEngine.hasStartIntent
    }

    private func prepareNativeHeartRateProvider() {
        let providerGeneration = nativeHeartRateProviderLifecycle.beginProviderLifecycle()
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .walking
        configuration.locationType = .indoor
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await iPhoneHealthKitHeartRateProvider.prepare(
                    configuration: configuration,
                    failureContext: IPhoneHealthKitRuntimeFailureContext(
                        providerGeneration: providerGeneration,
                        attemptID: nativeHeartRateProviderLifecycle.attemptID
                    )
                )
                guard nativeHeartRateProviderLifecycle.acceptsProviderCompletion(
                    generation: providerGeneration
                ) else { return }
                nativeHeartRateLogger.info("session_prepared")
                applyNativeHeartRatePreflightEffects(
                    nativeHeartRatePreflightEngine.providerPrepared(at: Date())
                )
            } catch {
                nativeHeartRateProviderFailed(generation: providerGeneration)
            }
        }
    }

    private func startNativeHeartRateCollection(
        intent: NativeHeartRatePreflightEngine.Intent,
        acquisitionStartedAt: Date
    ) {
        var recoveryRecord = NativeWorkoutRecoveryRecord.preflight(
            appWorkoutID: intent.id,
            targetBPM: intent.targetBPM,
            durationMinutes: intent.durationMinutes,
            acquisitionStartedAt: acquisitionStartedAt,
            profileID: activeUserProfileID,
            isIntervalWorkout: pendingIntervalPlan == nil ? nil : true
        )
        if let plan = pendingIntervalPlan {
            recoveryRecord = recoveryRecord.planningDuration(seconds: plan.totalSeconds)
        }
        guard persistNativeWorkoutRecoveryRecord(recoveryRecord) else {
            applyNativeHeartRatePreflightEffects(
                nativeHeartRatePreflightEngine.cancel(reason: .providerFailure)
            )
            return
        }
        let providerGeneration = nativeHeartRateProviderLifecycle.generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                iPhoneHealthKitHeartRateProvider.bindRuntimeFailureContext(
                    IPhoneHealthKitRuntimeFailureContext(
                        providerGeneration: providerGeneration,
                        attemptID: intent.id
                    )
                )
                try await iPhoneHealthKitHeartRateProvider.start(at: acquisitionStartedAt)
                guard nativeHeartRateProviderLifecycle.acceptsProviderCompletion(
                    generation: providerGeneration,
                    attemptID: intent.id
                ) else { return }
                let effects = nativeHeartRatePreflightEngine.collectionStarted(
                    intentID: intent.id,
                    acquisitionStartedAt: acquisitionStartedAt,
                    now: Date()
                )
                applyNativeHeartRatePreflightEffects(effects)
                guard nativeHeartRatePreflightEngine.hasStartIntent else { return }
                nativeHealthKitAcquisitionStartedAt = acquisitionStartedAt
                nativeHeartRateLogger.info("collection_started")
                syncNativeHeartRatePreflightPresentation()
            } catch {
                nativeHeartRateProviderFailed(
                    generation: providerGeneration,
                    attemptID: intent.id
                )
            }
        }
    }

    private func handleNativeHeartRateObservation(
        _ observation: HeartRateProviderObservation
    ) {
        guard nativeHeartRateFlowOwnsController,
              nativeHeartRateProviderLifecycle.acceptsObservation(
                providerIsCollecting: iPhoneHealthKitHeartRateProvider.state == .collecting
              ) else {
            nativeHeartRateLogger.info("stale_observation_ignored")
            return
        }
        let now = Date()
        let factualDate = observation.measuredAt ?? observation.receivedAt
        let ageSeconds = max(0, Int(now.timeIntervalSince(factualDate)))
        HRDomainService.applyHeartRateDelivery(
            observation.beatsPerMinute,
            now: { factualDate },
            updateCurrent: { heartRateBPM = $0 },
            updateLastKnown: { lastKnownHeartRateBPM = $0 },
            updateLastReceivedAt: { hrLastValueAt = $0 },
            recordPredictorInput: { recordHrSample($0, at: factualDate) }
        )
        hrDataStaleSeconds = ageSeconds
        hrStreamingActive = HRDomainService.heartRateStreamIsActive(
            beatsPerMinute: observation.beatsPerMinute,
            hasLastReceivedAt: true,
            ageSeconds: ageSeconds,
            staleThresholdSeconds: hrStaleThresholdSeconds
        )
        isNativeHeartRateCurrent = hrStreamingActive
        observeIntervalHeartRate(observation.beatsPerMinute, measuredAt: factualDate, now: now)
        let normalization = normalizeHeartRateDelivery(observation, recordedAt: now)

        let preflightObservation = NativeHeartRatePreflightEngine.Observation(
            source: .nativeHealthKit,
            beatsPerMinute: observation.beatsPerMinute,
            measuredAt: observation.measuredAt,
            receivedAt: observation.receivedAt
        )
        let effects = nativeHeartRatePreflightEngine.receive(
            preflightObservation,
            safety: nativeHeartRateSafetyFacts(now: now),
            now: now,
            freshnessLimit: TimeInterval(hrStaleThresholdSeconds)
        )
        if nativeHeartRatePreflightEngine.pendingObservation == preflightObservation
            || effects.contains(where: { effect in
                guard case .commit(_, let observation, _) = effect else { return false }
                return observation == preflightObservation
            })
        {
            pendingNativePreflightHeartRate = normalization
        } else if !nativeHeartRatePreflightEngine.hasStartIntent {
            publishHeartRateNormalization(normalization)
        }
        applyNativeHeartRatePreflightEffects(effects)
        evaluateHeartRateControlDecision()
    }

    private func commitNativeHeartRatePreflight(
        intent: NativeHeartRatePreflightEngine.Intent,
        observation: NativeHeartRatePreflightEngine.Observation,
        acquisitionStartedAt: Date
    ) {
        let now = Date()
        let observationIsQualifying = observation.isQualifying(
            collectionStartedAt: acquisitionStartedAt,
            now: now,
            freshnessLimit: TimeInterval(hrStaleThresholdSeconds)
        )
        guard NativeHeartRatePreflightEngine.RuntimePolicy.permitsProductionCommit(
            intent: intent,
            now: now,
            flowOwnsController: nativeHeartRateFlowOwnsController,
            nativeWorkoutAlreadyCommitted: nativeHealthKitWorkoutCommitted,
            providerIsCollecting: iPhoneHealthKitHeartRateProvider.state == .collecting,
            observationIsQualifying: observationIsQualifying,
            safety: nativeHeartRateSafetyFacts(now: now)
        ) else {
            abortNativeHeartRateFlow(reason: .superseded)
            return
        }

        guard case .record(let preflightRecord) = nativeWorkoutRecoveryLoadResult,
              preflightRecord.phase == .preflight,
              preflightRecord.appWorkoutID == intent.id,
              preflightRecord.acquisitionStartedAt == acquisitionStartedAt,
              let profileID = activeUserProfileID else {
            abortNativeHeartRateFlow(reason: .superseded)
            return
        }
        let controlledWorkoutStartedAt = now
        let legacySessionID = UUID()
        let telemetrySessionID = TelemetryV2SessionDescriptor.sessionID(
            deterministicallyLinkedTo: legacySessionID
        ).rawValue
        let committedRecoveryRecord = preflightRecord.committed(
            controlledWorkoutStartedAt: controlledWorkoutStartedAt,
            profileID: profileID,
            legacySessionID: legacySessionID,
            telemetrySessionID: telemetrySessionID
        )
        guard persistNativeWorkoutRecoveryRecord(committedRecoveryRecord) else {
            abortNativeHeartRateFlow(reason: .providerFailure)
            return
        }

        if pendingIntervalPlan == nil {
            hrTargetBPM = intent.targetBPM
            hrDurationMinutes = intent.durationMinutes
        }
        nativeHealthKitWorkoutCommitted = true
        nativePreflightCommitTimestamps = (
            acquisitionStartedAt: acquisitionStartedAt,
            measuredAt: observation.measuredAt,
            receivedAt: observation.receivedAt
        )
        let latency = max(0, now.timeIntervalSince(acquisitionStartedAt))
        nativeHeartRateLogger.info("first_qualifying_hr_received")
        nativeHeartRateLogger.info("preflight_committed")
        commitExistingHrControl(preflightLatencySeconds: latency)
    }

    private func discardNativeHeartRatePreflight(
        reason: NativeHeartRatePreflightEngine.CancellationReason
    ) {
        nativeHeartRateLogger.info("preflight_cancelled reason=\(reason.rawValue, privacy: .public)")
        nativeHeartRateFlowOwnsController = false
        isNativeHeartRateCurrent = false
        hrStreamingActive = false
        hrLastValueAt = nil
        heartRateBPM = 0
        pendingNativePreflightHeartRate = nil
        let cleanupGeneration = nativeHeartRateProviderLifecycle.beginCleanup()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await iPhoneHealthKitHeartRateProvider.discard(at: Date())
            guard nativeHeartRateProviderLifecycle.completeCleanup(
                generation: cleanupGeneration,
                providerIsIdle: iPhoneHealthKitHeartRateProvider.state == .idle
            ) else { return }
            guard clearNativeWorkoutRecoveryRecord() else {
                handleUnavailableActiveWorkoutRecovery(error: nil)
                return
            }
            recomputeHrStartAllowed()
            warmNativeHeartRateProviderIfPossible()
        }
        if reason == .timeout || reason == .providerFailure {
            infoToastMessage = "Пульс не получен. Проверьте подключение и посадку датчика, а также доступ к данным «Здоровье»."
        }
    }

    private func abortNativeHeartRateFlow(
        reason: NativeHeartRatePreflightEngine.CancellationReason
    ) {
        nativeHealthKitWorkoutCommitted = false
        nativeHeartRateFlowOwnsController = false
        isNativeHeartRateCurrent = false
        hrStreamingActive = false
        hrLastValueAt = nil
        heartRateBPM = 0
        nativePreflightCommitTimestamps = nil
        pendingNativePreflightHeartRate = nil
        nativeHeartRateLogger.info("preflight_aborted reason=\(reason.rawValue, privacy: .public)")
        let cleanupGeneration = nativeHeartRateProviderLifecycle.beginCleanup()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await iPhoneHealthKitHeartRateProvider.discard(at: Date())
            guard nativeHeartRateProviderLifecycle.completeCleanup(
                generation: cleanupGeneration,
                providerIsIdle: iPhoneHealthKitHeartRateProvider.state == .idle
            ) else { return }
            guard clearNativeWorkoutRecoveryRecord() else {
                handleUnavailableActiveWorkoutRecovery(error: nil)
                return
            }
            recomputeHrStartAllowed()
            warmNativeHeartRateProviderIfPossible()
        }
        syncNativeHeartRatePreflightPresentation()
        recomputeHrStartAllowed()
    }

    private func nativeHeartRateProviderFailed(
        generation: UInt64,
        attemptID: UUID? = nil
    ) {
        guard nativeHeartRateProviderLifecycle.acceptsProviderCompletion(
            generation: generation,
            attemptID: attemptID
        ) else { return }
        hrStreamingActive = false
        isNativeHeartRateCurrent = false
        hrLastValueAt = nil
        heartRateBPM = 0
        if nativeHeartRatePreflightEngine.ownsUncommittedWorkout {
            applyNativeHeartRatePreflightEffects(
                nativeHeartRatePreflightEngine.cancel(reason: .providerFailure)
            )
        } else if !nativeHealthKitWorkoutCommitted {
            nativeHeartRateFlowOwnsController = false
            recomputeHrStartAllowed()
        }
    }
    func stopHrControl() {
        if isNativeWorkoutRecoveryActive {
            stopRecoveredNativeWorkout()
            return
        }

        isHrControlRunning = false
        hrStatusLine = "HR‑контроль завершён • остановка дорожки запрошена"
        hrNextDecisionSeconds = 0
        hrRemainingSeconds = 0
        hrProgress = 0
        hrDecisionDetails = ""
        hrPredictorStatusLine = ""
        clearCooldownRuntimeState()
        hrNoDataSeconds = 0
        hrControlStartBlockReasonText = nil
        hrControlStartedAt = nil
        hrControlStartedBelt = false
        stopBeltWithToggle(reason: "hr")
        endTelemetryV2Session(reason: "manual_stop")
    }

    private func stopRecoveredNativeWorkout() {
        guard canStopPresentedWorkout else { return }
        nativeWorkoutRecoveryStopRequested = true
        nativeWorkoutRecoveryStatusText = "Завершаем восстановленную тренировку…"
        stopBeltWithToggle(reason: "recovered_hr_manual_stop")
    }

    private func stopHrControlAfterCommandFailure(
        reason: String = "hr_auto_start_speed_cancelled",
        requestStop: Bool = true
    ) {
        hrControlFailed = true
        isHrControlRunning = false
        hrStatusLine = "HR‑контроль остановлен — команда дорожки не выполнена"
        infoToastMessage = "Команда дорожки не выполнена. Остановка ещё не подтверждена."
        hrNextDecisionSeconds = 0
        hrRemainingSeconds = 0
        hrProgress = 0
        hrDecisionDetails = ""
        hrPredictorStatusLine = ""
        clearCooldownRuntimeState()
        hrNoDataSeconds = 0
        hrControlStartedAt = nil
        hrControlStartedBelt = false
        if requestStop { stopBeltWithToggle(reason: reason) }
        endTelemetryV2Session(reason: reason)
    }

    private func beginNativeWorkoutStopTerminalRequestIfNeeded() {
        guard pendingNativeWorkoutStopTerminalRequest == nil,
              let record = activeNativeWorkoutRecoveryRecord,
              record.phase == .committed || record.phase == .stopping else {
            return
        }
        let requestedAt = record.terminalRequestedAt ?? Date()
        if record.phase == .committed,
           !persistNativeWorkoutRecoveryRecord(
                record.stopping(requestedAt: requestedAt)
           ) {
            nativeHeartRateLogger.error("stopping_marker_write_failed")
        }
        pendingNativeWorkoutStopTerminalRequest = (
            record: record,
            requestedAt: requestedAt
        )
    }

    private func nativeWorkoutStopTransportInvokedIfNeeded() {
        guard let pending = pendingNativeWorkoutStopTerminalRequest else { return }
        pendingNativeWorkoutStopTerminalRequest = nil
        guard nativeHealthKitWorkoutCommitted else {
            nativeWorkoutRecoveryStopRequested = false
            nativeWorkoutRecoveryStatusText = "Stop отправлен • HealthKit не восстановлен"
            recomputeHrStartAllowed()
            return
        }
        guard persistNativeWorkoutRecoveryRecord(
            pending.record.finishing(requestedAt: pending.requestedAt)
        ) else {
            isNativeWorkoutRecoveryActive = true
            nativeWorkoutRecoveryStopRequested = false
            nativeWorkoutRecoveryStatusText = "Не удалось сохранить завершение тренировки"
            infoToastMessage = "Stop отправлен, но завершение не сохранено. Проверьте дорожку и повторите Stop."
            recomputeHrStartAllowed()
            return
        }
        finishNativeHealthKitWorkoutIfNeeded()
    }

    private func nativeWorkoutStopTransportInvocationFailedIfNeeded(reason: String) {
        guard pendingNativeWorkoutStopTerminalRequest != nil else { return }
        pendingNativeWorkoutStopTerminalRequest = nil
        isNativeWorkoutRecoveryActive = true
        nativeWorkoutRecoveryStopRequested = false
        nativeWorkoutRecoveryStatusText = "Stop не отправлен"
        infoToastMessage = "\(reason). Проверьте подключение и повторите Stop."
        recomputeHrStartAllowed()
    }

    private func ensureCentral() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: true])
        }
    }

    private func resumeDiscoveryScanIfNeeded() {
        guard shouldBeScanning,
              let central,
              central.state == .poweredOn else { return }
        central.scanForPeripherals(
            withServices: supportedServiceUuids,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        if !isConnected {
            connectionStateText = "Scanning..."
        }
    }

    private func scheduleConnectTimeout(for id: UUID, seconds: TimeInterval = 12) {
        connectTimeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.connectingPeripheralId == id else { return }
            if let central,
               let p = self.connectingPeripheral,
               p.identifier == id {
                self.cancellingConnectionPeripheralId = id
                central.cancelPeripheralConnection(p)
            }
            self.isConnected = false
            self.connectionStateText = "Disconnecting..."
            if !self.connectingAttemptIsAutomatic {
                self.connectErrorMessage = "Connection timeout"
            }
            self.connectTimeoutWorkItem = nil
        }
        connectTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func recomputeHrStartAllowed() {
        guard profileDataAvailable else {
            isHrControlStartAllowed = false
            hrControlStartBlockReasonText = "Локальные данные недоступны или удаление профиля не завершено"
            return
        }
        let now = Date()
        let safety = nativeHeartRateSafetyFacts(now: now)
        let preflightGatesAllowStart = profileDataAvailable && safety.permitsStartIntent
            && IPhoneHealthKitLiveHeartRateProvider.isSupported
            && !hasOutstandingNativeWorkoutRecovery
            && !nativeHeartRatePreflightEngine.hasStartIntent
            && !nativeHeartRateProviderLifecycle.cleanupInFlight
        let unitsDecision = controllerUnitsGateDecision(now: now)
        isHrControlStartAllowed = preflightGatesAllowStart
        if !preflightGatesAllowStart {
            let withinGrace = HRDomainService.isWithinInitialHeartRateGrace(
                startedAt: hrControlStartedAt,
                now: Date(),
                graceSeconds: hrStartGraceSeconds
            )
            if !isConnected {
                hrControlStartBlockReasonText = "Нет подключения к дорожке"
            } else if !isTreadmillControlReady {
                hrControlStartBlockReasonText = "Дождитесь готовности управления дорожкой"
            } else if !IPhoneHealthKitLiveHeartRateProvider.isSupported {
                hrControlStartBlockReasonText = "HealthKit недоступен на этом устройстве"
            } else if nativeHeartRateAppActivity != .active {
                hrControlStartBlockReasonText = "Вернитесь в приложение для старта"
            } else if nativeHeartRatePreflightEngine.hasStartIntent {
                hrControlStartBlockReasonText = nil
            } else {
                hrControlStartBlockReasonText = "Недоступно"
            }
            if isHrControlRunning && !withinGrace && !hrStreamingActive {
                hrStatusLine = "HR‑контроль: нет сигнала"
            }
        } else {
            hrControlStartBlockReasonText = nil
        }
        refreshControllerUnitsTruthIfNeeded(
            existingGatesAllowStart: preflightGatesAllowStart,
            unitsDecision: unitsDecision,
            now: now
        )
    }
    private func startTelemetry() {
        stopTelemetry()
        telemetryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tickTelemetry()
        }
        RunLoop.main.add(telemetryTimer!, forMode: .common)
    }

    private func stopTelemetry() {
        telemetryTimer?.invalidate()
        telemetryTimer = nil
    }

    private func startHrStaleTimer() {
        stopHrStaleTimer()
        hrStaleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let hasLast = (self.hrLastValueAt != nil)
            let secs: Int
            if let last = self.hrLastValueAt {
                secs = max(0, Int(Date().timeIntervalSince(last)))
            } else {
                secs = self.hrStaleThresholdSeconds + 1
            }
            DispatchQueue.main.async {
                self.hrDataStaleSeconds = hasLast ? secs : 0
                let active = HRDomainService.heartRateStreamIsActive(
                    beatsPerMinute: self.heartRateBPM,
                    hasLastReceivedAt: hasLast,
                    ageSeconds: secs,
                    staleThresholdSeconds: self.hrStaleThresholdSeconds
                )
                self.hrStreamingActive = active
                if self.nativeHeartRateFlowOwnsController {
                    self.isNativeHeartRateCurrent = active
                }
                self.recomputeHrStartAllowed()
            }
        }
        if let t = hrStaleTimer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    private func stopHrStaleTimer() {
        hrStaleTimer?.invalidate()
        hrStaleTimer = nil
    }

    private func observeIntervalHeartRate(_ bpm: Int, measuredAt: Date, now: Date) {
        guard isHrControlRunning, var state = intervalWorkoutState,
              state.observeHeartRate(bpm, sampleAgeSeconds: now.timeIntervalSince(measuredAt)) else { return }
        intervalWorkoutState = state
    }

    private func syncHrSessionTiming(now: ContinuousClock.Instant = .now) {
        guard intervalWorkoutState == nil, let startedAt = hrControlStartedInstant else { return }
        hrRemainingSeconds = HRDomainService.remainingSessionSeconds(
            totalSeconds: hrSessionTotalSeconds, elapsed: startedAt.duration(to: now)
        )
        hrProgress = hrSessionTotalSeconds > 0
            ? 1.0 - Double(hrRemainingSeconds) / Double(hrSessionTotalSeconds) : 0
    }

    private func advanceIntervalWorkout() {
        guard var state = intervalWorkoutState,
              let startedAt = hrControlStartedInstant, state.phase != .cooldown else { return }
        let previousPhase = state.phase
        let duration = startedAt.duration(to: ContinuousClock.now).components
        let elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        let age = hrLastValueAt.map { Date().timeIntervalSince($0) }
        let fresh = hrStreamingActive && heartRateBPM > 0 && (age.map { $0 >= 0 && $0 <= 7 } ?? false)
        state.tick(elapsed: elapsed, heartRate: fresh ? heartRateBPM : nil,
                   validForSeconds: fresh ? max(0, 7 - (age ?? 7)) : 0)
        intervalWorkoutState = state
        hrRemainingSeconds = state.mainRemainingSeconds
        hrProgress = state.progress
        guard previousPhase != state.phase else { return }
        _ = telemetryV2Coordinator.observeWorkoutPhase(
            state.telemetryPhase, occurredAt: Date(), intervalContext: state.evidence()
        )
        if state.phase != .cooldown {
            observeSemanticHeartRateDecision(action: .noCommand,
                reason: .other("interval_phase_target"), heartRateInputs: [], occurredAt: Date())
        }
        if state.phase == .cooldown, state.finishReason != "cycles_completed" {
            infoToastMessage = state.finishReason == "above_95_percent"
                ? "Пульс выше 95% максимального — переходим к заминке"
                : "Интервалы завершены досрочно — переходим к заминке"
        }
    }

    private func reduceIntervalRecoverySpeed() {
        // Recovery reuses the existing readiness/signal checks and decision cadence.
        // Lowering the recovery target never authorizes acceleration.
        guard controllerUnitsGateDecision().allowed, !blocksNonStopTreadmillMotion else { return }
        let controlUseEvidence = makeHeartRateControlUseEvidence(trendUsed: false, occurredAt: Date())
        defer { observeHeartRateControlUse(controlUseEvidence) }
        let current = deviceTargetSpeedKmh
        let proposed = IntervalWorkoutRuntime.recoverySpeed(
            current: current, minimum: hrCooldownMinSpeed, step: hrSpeedStepKmh
        )
        let next = min(current, clampRunningSpeedKmh(proposed))
        guard next < current else {
            hrDecisionDetails = "Восстановление: удерживаем минимальную скорость"
            observeSemanticHeartRateDecision(action: .noCommand, reason: .other("interval_recovery"),
                heartRateInputs: controlUseEvidence?.inputs ?? [], occurredAt: Date())
            return
        }
        desiredSpeedKmh = next
        deviceTargetSpeedKmh = next
        recordSpeedChange(from: current, to: next, reason: "interval_recovery")
        let decision = makeTreadmillDecision(
            source: .heartRateControl,
            intent: .setDesiredSpeed(DesiredSpeedKilometresPerHour(value: next)),
            heartRateInputs: controlUseEvidence?.inputs ?? []
        )
        defer { observeTreadmillDecision(decision) }
        sendTreadmillSetSpeed(next, label: "SPEED interval recovery", decision: decision)
        observeSemanticHeartRateDecision(
            action: .enqueueSpeed(DesiredSpeedKilometresPerHour(value: next)),
            reason: .other("interval_recovery"), heartRateInputs: controlUseEvidence?.inputs ?? [],
            occurredAt: Date())
        hrDecisionDetails = "Восстановление: снижаем скорость до \(String(format: "%.1f", next)) км/ч"
    }

    private func maintainHeartRateControlSafety() {
        guard isHrControlRunning, cooldownRuntimeState == nil else { return }
        let withinGrace = HRDomainService.isWithinInitialHeartRateGrace(
            startedAt: hrControlStartedAt, now: Date(), graceSeconds: hrStartGraceSeconds
        )
        guard isTreadmillControlReady else {

            hrControlFailed = true
            infoToastMessage = "HR‑контроль остановлен — дорожка не готова к управлению. Остановка запрошена, но ещё не подтверждена."
            isHrControlRunning = false
            hrStatusLine = "HR‑контроль остановлен — дорожка не готова"
            hrNextDecisionSeconds = 0
            hrRemainingSeconds = 0
            hrProgress = 0
            hrDecisionDetails = ""
            hrPredictorStatusLine = ""
            clearCooldownRuntimeState()
            hrNoDataSeconds = 0
            hrControlStartedAt = nil
            hrControlStartedBelt = false
            stopBeltWithToggle(reason: "hr_control_not_ready")
            endTelemetryV2Session(reason: "hr_control_not_ready")
            return
        }
        let intervalHeartRateIsFresh = intervalWorkoutState == nil || hrLastValueAt.map {
            let age = Date().timeIntervalSince($0)
            return age >= 0 && age <= 7
        } == true
        guard hrStreamingActive, heartRateBPM > 0, intervalHeartRateIsFresh else {
            if withinGrace {
                hrStatusLine = "HR‑контроль: ожидание пульса"
                hrDecisionDetails = "Ожидание данных пульса…"
                return
            }
            let missingSeconds = HRDomainService
                .missingHeartRateSignalSeconds(
                    lastReceivedAt: hrLastValueAt,
                    now: Date(),
                    noDataMaximumSeconds: hrNoDataMaxSeconds
                )
            if !HRDomainService.shouldStopForMissingHeartRateSignal(
                missingSeconds: missingSeconds,
                noDataMaximumSeconds: hrNoDataMaxSeconds
            ) {
                hrStatusLine = "HR‑контроль: нет сигнала (\(missingSeconds)с)"
                hrDecisionDetails = "Данные пульса пропали, удерживаем скорость"
                return
            }

            hrControlFailed = true
            infoToastMessage = "HR‑контроль остановлен — нет данных пульса. Остановка дорожки запрошена, но ещё не подтверждена."
            isHrControlRunning = false
            hrStatusLine = "HR‑контроль остановлен — нет данных пульса"
            hrNextDecisionSeconds = 0
            hrRemainingSeconds = 0
            hrProgress = 0
            hrDecisionDetails = ""
            hrPredictorStatusLine = ""
            clearCooldownRuntimeState()
            hrNoDataSeconds = 0
            hrControlStartedAt = nil
            hrControlStartedBelt = false
            stopBeltWithToggle(reason: "hr_no_signal")
            endTelemetryV2Session(reason: "hr_no_signal")
            return
        }

    }

    private func evaluateHeartRateControlDecision() {
        guard isHrControlRunning, hrRemainingSeconds > 0,
              isTreadmillControlReady, !blocksNonStopTreadmillMotion,
              heartRateBPM > 0,
              let measuredAt = hrLastValueAt, let lastDecisionAt = hrLastDecisionAt else { return }
        let now = Date()
        let instant = ContinuousClock.now
        guard HRDomainService.heartRateDecisionIsDue(
            sampleAgeSeconds: now.timeIntervalSince(measuredAt),
            elapsedSinceLastDecision: lastDecisionAt.duration(to: instant),
            intervalSeconds: hrDecisionIntervalSeconds
        ) else { return }
        if let state = intervalWorkoutState {
            guard let startedAt = hrControlStartedInstant,
                  state.permitsHeartRateDecision(at: startedAt.duration(to: instant)) else { return }
        }
        let unitsDecision = controllerUnitsGateDecision()
        guard unitsDecision.allowed else {
            hrStatusLine = "HR‑контроль: ожидание подтверждения единиц скорости"
            hrDecisionDetails = unitsDecision.blockReason?.userMessage ?? "Единицы скорости не подтверждены"
            return
        }
        hrLastDecisionAt = instant
        hrNextDecisionSeconds = max(HRDomainService.minimumDecisionIntervalSeconds, hrDecisionIntervalSeconds)
        let hrTargetBPM = activeHRControlTargetBPM
        if intervalWorkoutState?.phase == .recovery {
            reduceIntervalRecoverySpeed()
            return
        }
        let trend = currentHrTrendBpmPerSecond()
        let controlUseEvidence = makeHeartRateControlUseEvidence(
            trendUsed: trend != nil,
            occurredAt: Date()
        )
        defer { observeHeartRateControlUse(controlUseEvidence) }
        let performanceInterval = telemetryPerformanceObservation
            .beginControlCycle()
        defer {
            telemetryPerformanceObservation.endControlCycle(
                performanceInterval
            )
        }
        let predictedValue = trend.map { Double(heartRateBPM) + $0 * hrPredictSeconds }
        let predictedBpm = predictedValue.map { Int(round($0)) }
        let effectiveBpm = max(heartRateBPM, predictedBpm ?? heartRateBPM)
        let diff = effectiveBpm - hrTargetBPM
        let predictionEvaluatedAt = Date()
        let prediction = HeartRatePredictionSnapshot(
            evaluatedAt: predictionEvaluatedAt,
            currentBeatsPerMinute: heartRateBPM,
            controllerInputAt: hrLastValueAt,
            controllerInputAgeSeconds: hrLastValueAt.map {
                predictionEvaluatedAt.timeIntervalSince($0)
            },
            trendBeatsPerMinutePerSecond: trend,
            trendWindowSeconds: hrTrendWindowSeconds,
            smoothingAlpha: hrTrendEmaAlpha,
            trendLimitBeatsPerMinutePerSecond: hrTrendSlopeMaxBpmPerSecond,
            horizonSeconds: hrPredictSeconds,
            predictedBeatsPerMinute: predictedBpm,
            effectiveBeatsPerMinute: effectiveBpm,
            phase: intervalWorkoutState?.telemetryPhase ?? .main,
            intervalContext: intervalWorkoutState?.evidence()
        )
        let decisionPrefix: String = {
            if let predictedBpm, predictedBpm > heartRateBPM {
                return "HR \(heartRateBPM) / прогноз \(predictedBpm) / цель \(hrTargetBPM) (Δ \(diff))"
            }
            return "HR \(heartRateBPM) / цель \(hrTargetBPM) (Δ \(diff))"
        }()
        let fixedStep = max(0.1, min(2.0, hrSpeedStepKmh))
        let absDiff = abs(diff)
        let adaptiveThresholds = adaptiveThresholdPercentsSnapshot()
        let absDiffPercent = adaptiveDiffPercent(absDiff, targetBpm: hrTargetBPM)
        let deadbandBpm = adaptiveDeadbandBpm(targetBpm: hrTargetBPM, thresholds: adaptiveThresholds)
        let direction: Double = diff > 0 ? -1.0 : 1.0
        let stepDirectionLabel = diff > 0 ? "DOWN" : (diff < 0 ? "UP" : "HOLD")
        let isIncreasingSpeed = direction > 0
        let stepSelection: AdaptiveStepSelection = {
            if hrAdaptiveStepEnabled {
                return adaptiveStepFromDiff(
                    diffPercent: absDiffPercent,
                    isIncreasingSpeed: isIncreasingSpeed,
                    thresholds: adaptiveThresholds
                )
            }
            return AdaptiveStepSelection(level: 4, stepKmh: quantizeSpeedStep(fixedStep))
        }()
        // KS-F0 accepts 0.1 km/h increments, so quantize before applying.
        let step = quantizeSpeedStep(stepSelection.stepKmh)
        let stepModeLabel = hrAdaptiveStepEnabled ? "L\(stepSelection.level)" : "FIXED"
        let stepDebugLabel = "\(stepDirectionLabel)-\(stepModeLabel)"

        let currentTarget = (deviceTargetSpeedKmh > 0.1) ? deviceTargetSpeedKmh : clampRunningSpeedKmh(desiredSpeedKmh)
        if absDiff <= deadbandBpm {
            let holdModeLabel = hrAdaptiveStepEnabled ? "L0" : "FIXED"
            recordSpeedChange(from: currentTarget, to: currentTarget, reason: "hr_hold")
            hrStatusLine = "HR‑контроль: цель удерживается"
            hrDecisionDetails = "\(decisionPrefix) · шаг \(stepDirectionLabel)-\(holdModeLabel) \(String(format: "%.1f", step)) км/ч · deadband ±\(deadbandBpm)bpm (\(String(format: "%.1f", adaptiveThresholds.deadband))%) · скорость \(String(format: "%.1f", currentTarget)) → без изменений"

            observeSemanticHeartRateDecision(
                action: .noCommand,
                reason: .withinTarget,
                heartRateInputs: controlUseEvidence?.inputs ?? [],
                prediction: prediction,
                occurredAt: Date()
            )
            return
        }
        if direction > 0, let trend, trend > 0, let predictedValue {
            let threshold = Double(hrTargetBPM - hrPredictMarginBpm)
            if predictedValue >= threshold {
                recordSpeedChange(from: currentTarget, to: currentTarget, reason: "hr_inertia_hold")
                hrStatusLine = "HR‑контроль: инерция"
                let trendPerMin = trend * 60.0
                hrDecisionDetails = "\(decisionPrefix) · шаг \(stepDebugLabel) \(String(format: "%.1f", step)) км/ч · тренд \(String(format: "%+.1f", trendPerMin)) bpm/мин · прогноз \(Int(round(predictedValue))) → без повышения"

                observeSemanticHeartRateDecision(
                    action: .noCommand,
                    reason: .heartRateInertiaHold,
                    heartRateInputs: controlUseEvidence?.inputs ?? [],
                    prediction: prediction,
                    occurredAt: Date()
                )
                return
            }
        }
        let nextSpeed = clampRunningSpeedKmh(currentTarget + direction * step)
        if nextSpeed != currentTarget {
            let telemetryDecision = makeTreadmillDecision(
                source: .heartRateControl,
                intent: .setDesiredSpeed(
                    DesiredSpeedKilometresPerHour(value: nextSpeed)
                ),
                heartRateInputs: controlUseEvidence?.inputs ?? []
            )
            defer { observeTreadmillDecision(telemetryDecision) }
            sendTreadmillSetSpeed(
                nextSpeed,
                label: String(format: "SPEED %.1f km/h (HR)", nextSpeed),
                decision: telemetryDecision,
                heartRateSpeed: HRDomainService.SpeedCommand(
                    targetKmh: nextSpeed, increaseSampleAt: nextSpeed > currentTarget ? measuredAt : nil
                )
            )
            hrStatusLine = diff > 0 ? "HR‑контроль: уменьшаем скорость" : "HR‑контроль: увеличиваем скорость"
            hrDecisionDetails = "\(decisionPrefix) · шаг \(stepDebugLabel) \(String(format: "%.1f", step)) км/ч · скорость \(String(format: "%.1f", currentTarget)) → \(String(format: "%+.1f", nextSpeed - currentTarget)) км/ч"

            observeSemanticHeartRateDecision(
                action: .enqueueSpeed(
                    DesiredSpeedKilometresPerHour(value: nextSpeed)
                ),
                reason: diff < 0 ? .belowTarget : .aboveTarget,
                heartRateInputs: controlUseEvidence?.inputs ?? [],
                prediction: prediction,
                occurredAt: Date()
            )
        } else {
            hrStatusLine = "HR‑контроль: предел скорости"
            hrDecisionDetails = "\(decisionPrefix) · шаг \(stepDebugLabel) \(String(format: "%.1f", step)) км/ч · скорость \(String(format: "%.1f", currentTarget)) → предел скорости"

            observeSemanticHeartRateDecision(
                action: .noCommand,
                reason: .heartRateSpeedLimit,
                heartRateInputs: controlUseEvidence?.inputs ?? [],
                prediction: prediction,
                occurredAt: Date()
            )
        }
    }

    private func tickTelemetry() {
        applyNativeHeartRatePreflightEffects(
            nativeHeartRatePreflightEngine.tick(now: Date())
        )
        if isNativeWorkoutRecoveryActive {
            syncRecoveredWorkoutTiming()
        }
        defer {
            if isHrControlRunning {
                _ = telemetryV2Coordinator.observeCurrentElapsedSecond()
            }
        }
        // Move actual speed towards desired speed
        let target = deviceTargetSpeedKmh
        let diff = target - speedKmh
        let step = max(-0.6, min(0.6, diff))
        speedKmh = clampAnySpeedKmh(speedKmh + step)

        // Accumulate stats only when belt is moving
        let metersPerSec = speedKmh / 3.6
        if metersPerSec > 0.2 {
            distKm += metersPerSec / 1000.0
            timeSec += 1
        }

        // Simple averages
        avgSpeedActive = timeSec > 0
        if avgSpeedActive {
            avgSpeedKmh = ((avgSpeedKmh * Double(max(0, timeSec - 1))) + speedKmh) / Double(max(1, timeSec))
        }

        // Update HR averages only from measured data.
        if hrStreamingActive && heartRateBPM > 0 {
            let bpm = heartRateBPM
            hrAverageSum += bpm
            hrAverageCount += 1
            if hrAverageCount > 0 {
                hrAverageBPM = Int(round(Double(hrAverageSum) / Double(hrAverageCount)))
            }
        }

        if avgSpeedKmh > 0.1 && hrAverageBPM > 0 {
            beatsPerMeter = (Double(hrAverageBPM) * 60.0) / (avgSpeedKmh * 1000.0)
        } else {
            beatsPerMeter = nil
        }

        maintainHeartRateControlSafety()

        if isHrControlRunning {
            advanceIntervalWorkout()
            syncHrSessionTiming()
            let hrTargetBPM = activeHRControlTargetBPM
            let withinGrace = HRDomainService.isWithinInitialHeartRateGrace(
                startedAt: hrControlStartedAt,
                now: Date(),
                graceSeconds: hrStartGraceSeconds
            )
            if hrStreamingActive && heartRateBPM > 0 {
                hrNoDataSeconds = 0
                hrSessionPeakBPM = max(hrSessionPeakBPM, heartRateBPM)
                if hrRemainingSeconds > 0 {
                    hrMainSumBPM += heartRateBPM
                    hrMainCountBPM += 1
                    hrMainPeakBPM = max(hrMainPeakBPM, heartRateBPM)
                }
                if let trend = currentHrTrendBpmPerSecond() {
                    let predicted = Double(heartRateBPM) + trend * hrPredictSeconds
                    let trendPerMin = trend * 60.0
                    hrPredictorStatusLine = "HR \(heartRateBPM) / цель \(hrTargetBPM) · тренд \(String(format: "%+.1f", trendPerMin)) bpm/мин · прогноз \(Int(round(predicted)))"
                } else {
                    hrPredictorStatusLine = "HR \(heartRateBPM) / цель \(hrTargetBPM) · тренд —"
                }
                let idx = zoneIndex(for: heartRateBPM)
                if idx >= 0 && idx < hrZoneSeconds.count {
                    hrZoneSeconds[idx] += 1
                }
            } else if withinGrace {
                hrPredictorStatusLine = "Ожидание пульса…"
            } else {
                hrPredictorStatusLine = "Нет данных пульса"
            }
            if hrRemainingSeconds > 0 {
                if let lastDecisionAt = hrLastDecisionAt {
                    hrNextDecisionSeconds = HRDomainService.heartRateDecisionRemainingSeconds(
                        elapsedSinceLastDecision: lastDecisionAt.duration(to: ContinuousClock.now),
                        intervalSeconds: hrDecisionIntervalSeconds
                    )
                }
            } else if cooldownRuntimeState == nil {
                cooldownStartedInstant = .now
                hrNextDecisionSeconds = 0
                let output = telemetryPerformanceObservation.measureControlCycle {
                    CooldownRuntimeEngine.start(
                        config: currentCooldownConfig(),
                        input: CooldownRuntimeEngine.StartInput(
                            currentBpm: heartRateBPM > 0 ? heartRateBPM : lastKnownHeartRateBPM,
                            deviceTargetSpeedKmh: deviceTargetSpeedKmh,
                            actualSpeedKmh: speedKmh,
                            sessionAggregates: currentCooldownSessionAggregates()
                        )
                    )
                }
                applyCooldownOutput(output)
            } else if let cooldownState = cooldownRuntimeState,
                      let cooldownStartedInstant {
                hrNextDecisionSeconds = 0
                let output = telemetryPerformanceObservation.measureControlCycle {
                    CooldownRuntimeEngine.tick(
                        state: cooldownState,
                        config: currentCooldownConfig(),
                        input: CooldownRuntimeEngine.TickInput(
                            elapsedSeconds: Int(clamping: max(0, cooldownStartedInstant.duration(to: .now).components.seconds)),
                            hrBpm: heartRateBPM,
                            decisionBpm: heartRateBPM > 0 ? heartRateBPM : hrCooldownTargetBpm,
                            hrAvailable: heartRateBPM > 0 && HRDomainService.cooldownEvidenceIsCurrent(
                                observedAt: hrLastValueAt,
                                sessionStartedAt: hrControlStartedAt,
                                now: Date(),
                                freshnessLimit: TimeInterval(hrStaleThresholdSeconds)
                            ),
                            speedSnapshot: currentCooldownSpeedSnapshot(),
                            sessionAggregates: currentCooldownSessionAggregates()
                        )
                    )
                }
                applyCooldownOutput(output)
            }
        }
        updateTreadmillStatus()
        maintainWalkingPadReadOnlyEvidenceDuringActiveWorkout(now: Date())
    }

    private func updateTreadmillStatus() {
        let now = Date()
        if let lifecycle = stopObservationLifecycle {
            refreshStopTruthStatus(
                lifecycle: lifecycle,
                evaluation: lifecycle.currentEvaluation(at: now)
            )
        }
        if let notifyAt = lastNotifyAt {
            lastNotifyAgeSeconds = max(0, Int(now.timeIntervalSince(notifyAt)))
        } else {
            lastNotifyAgeSeconds = 0
        }
        let running = (deviceTargetSpeedKmh > 0.1) || (speedKmh > 0.2) || (deviceReportedSpeedKmh > 0.2)
        let proto = treadmillProtocol.rawValue
        let awakeText: String = {
            guard isConnected else { return "unknown" }
            guard let notifyAt = lastNotifyAt else { return "unknown" }
            return (now.timeIntervalSince(notifyAt) <= 6) ? "awake" : "asleep"
        }()
        if !isConnected {
            treadmillStatusText = "disconnected"
        } else if treadmillProtocol == .walkingPad, !stopTruthStatusText.isEmpty {
            treadmillStatusText = "\(stopTruthStatusText) • \(awakeText) • \(proto)"
        } else if running {
            treadmillStatusText = "running • \(awakeText) • \(proto)"
        } else if treadmillProtocol == .walkingPad {
            treadmillStatusText = "idle target • stop not verified • \(awakeText) • \(proto)"
        } else {
            treadmillStatusText = "stopped • \(awakeText) • \(proto)"
        }

        if treadmillProtocol == .ftms, ftmsControlState.hasTimedOut(at: .now) {
            failFTMSControl()
        }
        var observedLegacyCommandTimeout = false
        if lastCommandAwaitingAck, let sentAt = lastCommandSentAt {
            if now.timeIntervalSince(sentAt) > commandAckTimeoutSeconds {
                lastCommandAwaitingAck = false
                lastCommandTimeouts += 1
                lastCommandTimeoutsCount = lastCommandTimeouts
                observedLegacyCommandTimeout = true

            }
        }
        if let sentAt = lastCommandSentAt {
            if lastCommandAwaitingAck {
                lastCommandAckStatusText = "ack pending \(max(0, Int(now.timeIntervalSince(sentAt))))s"
            } else if let ackAt = lastCommandAckedAt {
                lastCommandAckStatusText = "ack \(max(0, Int(ackAt.timeIntervalSince(sentAt))))s"
            } else {
                lastCommandAckStatusText = "sent \(max(0, Int(now.timeIntervalSince(sentAt))))s"
            }
        } else {
            lastCommandAckStatusText = ""
        }
        if observedLegacyCommandTimeout,
           let connectionEpoch = treadmillTelemetryConnectionEpoch {
            observeTreadmillTelemetry(
                .commandTimeout(
                    LegacyCommandTimeoutObservation(
                        protocolKind: treadmillTelemetryProtocolKind,
                        connectionEpoch: connectionEpoch,
                        occurredAt: now
                    )
                )
            )
        }
    }

    // MARK: - BLE write helpers
    private func writeCommand(
        _ data: Data,
        label: String,
        highPriority: Bool = false,
        requiresControlReadiness: Bool = false,
        telemetryRequest: TreadmillCommandTelemetryRequest? = nil,
        heartRateSpeed: HRDomainService.SpeedCommand? = nil
    ) {
#if STOP_TRUTH_EXPERIMENT_CAPABILITY
        guard stopTruthExperimentController?.isActive != true else {
            return
        }
#endif
        enqueueCommand(
            data,
            label: label,
            highPriority: highPriority,
            requiresControlReadiness: requiresControlReadiness,
            telemetryRequest: telemetryRequest,
            heartRateSpeed: heartRateSpeed
        )
    }

    private func isSpeedCommandLabel(_ label: String) -> Bool {
        label.lowercased().hasPrefix("speed")
    }

    @discardableResult
    private func resetCommandQueue(
        reason: String,
        observeTelemetryImmediately: Bool = true
    ) -> [TreadmillCommandTelemetrySidecar.Entry] {
        _ = CommandQueueService.clear(queue: &commandQueue)
        commandQueueEpoch += 1
        isCommandQueueProcessing = false
        nextCommandAllowedAt = .distantPast

        let cancelledTelemetry = treadmillCommandTelemetrySidecar.clear()
        if observeTelemetryImmediately {
            observeCancelledTreadmillCommands(
                cancelledTelemetry,
                reason: .other("legacy_queue_reset")
            )
        }
        return cancelledTelemetry
    }

    private func enqueueCommand(
        _ data: Data,
        label: String,
        highPriority: Bool,
        requiresControlReadiness: Bool,
        telemetryRequest: TreadmillCommandTelemetryRequest?,
        heartRateSpeed: HRDomainService.SpeedCommand? = nil
    ) {
        let command = CommandQueueService.Command(
            data: data,
            label: label,
            requiresControlReadiness: requiresControlReadiness,
            heartRateSpeed: heartRateSpeed
        )
        let request = telemetryRequest ?? treadmillCommandRequest(kind: .other(label))
        let enqueue = request.prepareEnqueue(
            protocolKind: treadmillTelemetryProtocolKind,
            connectionEpoch: treadmillTelemetryConnectionEpoch,
            enqueuedAt: Date()
        )
        let telemetryEvidence = enqueue.queued
        if highPriority {
            let cancelled = resetCommandQueue(
                reason: "high priority → \(label)",
                observeTelemetryImmediately: false
            )
            enqueueFtmsRequestControlIfNeeded()
            commandQueue.append(command)
            var superseded: [TreadmillCommandTelemetrySidecar.Entry] = []
            if let telemetryEvidence {
                superseded = treadmillCommandTelemetrySidecar.enqueueRegular(
                    label: label,
                    evidence: telemetryEvidence,
                    sessionID: request.sessionID,
                    isSpeedLabel: isSpeedCommandLabel
                )
            }
            processCommandQueue()
            observeCancelledTreadmillCommands(
                cancelled,
                reason: .other("legacy_queue_reset")
            )
            observeSupersededTreadmillCommands(superseded)
            if let publication = enqueue.publication {
                observeTreadmillTelemetry(.commandEnqueued(publication), sessionID: request.sessionID)
            }
            return
        }

        let result = CommandQueueService.enqueueRegular(
            queue: &commandQueue,
            command: command,
            isSpeedLabel: isSpeedCommandLabel
        )
        var superseded: [TreadmillCommandTelemetrySidecar.Entry] = []
        if let telemetryEvidence {
            superseded = treadmillCommandTelemetrySidecar.enqueueRegular(
                label: label,
                evidence: telemetryEvidence,
                sessionID: request.sessionID,
                isSpeedLabel: isSpeedCommandLabel
            )
        }
        observeSupersededTreadmillCommands(superseded)
        if let publication = enqueue.publication {
            observeTreadmillTelemetry(.commandEnqueued(publication), sessionID: request.sessionID)
        }
        if result.coalescedSpeedCommands.contains(where: {
            $0.heartRateSpeed?.consumeAutoStartCompensation() == true
        }) {
            stopHrControlAfterCommandFailure()
            return
        }
        processCommandQueue()
    }

    private func observeCancelledTreadmillCommands(
        _ commands: [TreadmillCommandTelemetrySidecar.Entry],
        reason: CommandCancellationReason
    ) {
        for entry in commands {
            let command = entry.evidence
            observeTreadmillTelemetry(
                .commandCancelled(
                    TreadmillCommandCancellationObservation(
                        commandID: command.commandID,
                        decisionID: command.decisionID,
                        connectionEpoch: command.connectionEpoch,
                        occurredAt: Date(),
                        reason: reason
                    )
                ), sessionID: entry.sessionID
            )
        }
    }

    private func observeSupersededTreadmillCommands(
        _ commands: [TreadmillCommandTelemetrySidecar.Entry]
    ) {
        for entry in commands {
            let command = entry.evidence
            observeTreadmillTelemetry(
                .commandCancelled(
                    TreadmillCommandCancellationObservation(
                        commandID: command.commandID,
                        decisionID: command.decisionID,
                        connectionEpoch: command.connectionEpoch,
                        occurredAt: Date(),
                        reason: .superseded
                    )
                ), sessionID: entry.sessionID
            )
        }
    }

    private func processCommandQueue() {
        guard !isCommandQueueProcessing else { return }
        guard let next = commandQueue.first else { return }
        if treadmillProtocol == .ftms {
            if ftmsControlState.isBlocked {
                failFTMSControl()
                return
            }
            guard let opcode = next.data.first, ftmsControlState.canSend(opcode: opcode) else { return }
        }
        isCommandQueueProcessing = true
        let now = Date()
        let delay = max(0, nextCommandAllowedAt.timeIntervalSince(now))
        if delay > 0 {

        }
        let epoch = commandQueueEpoch
        // An invalidated callback never owns the replacement queue or its Stop.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.commandQueueEpoch == epoch else {
                return
            }
            let discardedQueries = CommandQueueService.discardReadOnlyQueries(
                queue: &self.commandQueue,
                motionWindowIsProtected: self.isHrControlRunning
                    && self.controllerUnitsNextScheduledMotionLeadSeconds <= ControllerUnitsRefreshPolicy.requiredMotionLeadSeconds
            )
            if !discardedQueries.isEmpty {
                if discardedQueries.contains(where: { $0.label == "QUERY PARAMS" }) {
                    self.lastControllerUnitsQueryAt = nil
                }
                self.observeCancelledTreadmillCommands(
                    self.treadmillCommandTelemetrySidecar.removeQueued(where: CommandQueueService.isReadOnlyQueryLabel),
                    reason: .other("read_only_query_yielded_to_motion")
                )
                if self.commandQueue.isEmpty {
                    self.isCommandQueueProcessing = false
                    return
                }
            }
            guard !self.commandQueue.isEmpty else {
                self.isCommandQueueProcessing = false
                self.nativeWorkoutStopTransportInvocationFailedIfNeeded(
                    reason: "Команда Stop отсутствует в очереди"
                )
                return
            }
            let next = self.commandQueue.removeFirst()
            let telemetryEvidence: TreadmillCommandEnqueuedEvidence?
            var queuedSessionID = self.treadmillCommandTelemetrySidecar.queued.first?.entry.sessionID
            var postWriteTelemetry: [TreadmillTelemetryEvidence] = []
            var lostEntries: [TreadmillCommandTelemetrySidecar.Entry] = []
            switch self.treadmillCommandTelemetrySidecar.dequeue(
                expectedLabel: next.label,
                currentEpoch: self.treadmillTelemetryConnectionEpoch
            ) {
            case .matched(let entry):
                telemetryEvidence = entry.evidence
            case .staleEpoch(let entry):
                let evidence = entry.evidence
                telemetryEvidence = nil
                postWriteTelemetry.append(
                    .commandCancelled(
                        TreadmillCommandCancellationObservation(
                            commandID: evidence.commandID,
                            decisionID: evidence.decisionID,
                            connectionEpoch: evidence.connectionEpoch,
                            occurredAt: Date(),
                            reason: .other("connection_epoch_changed_before_write")
                        )
                    )
                )
            case .correlationLost(let entries):
                telemetryEvidence = nil
                queuedSessionID = self.activeTelemetryV2SessionID
                lostEntries = entries
            case .missing:
                telemetryEvidence = nil
                queuedSessionID = self.activeTelemetryV2SessionID
            }
            let hrBlockReason = next.heartRateSpeed.flatMap {
                HRDomainService.speedCommandBlockReason(
                    $0, isRunning: self.isHrControlRunning && self.hrRemainingSeconds > 0,
                    unitsAllowed: self.controllerUnitsGateDecision().allowed, now: Date()
                )
            }
            if let hrBlockReason {
                if let telemetryEvidence {
                    postWriteTelemetry.append(.commandCancelled(
                        TreadmillCommandCancellationObservation(
                            commandID: telemetryEvidence.commandID,
                            decisionID: telemetryEvidence.decisionID,
                            connectionEpoch: telemetryEvidence.connectionEpoch,
                            occurredAt: Date(), reason: .other(hrBlockReason)
                        )
                    ))
                }
                if self.isHrControlRunning && self.hrRemainingSeconds > 0 {
                    self.hrStatusLine = "HR‑контроль: изменение скорости отменено"
                    self.hrDecisionDetails = hrBlockReason == "hr_units_blocked_before_write"
                        ? "Дождитесь подтверждения единиц скорости"
                        : "Дождитесь свежего измерения пульса"
                }
            } else {
                postWriteTelemetry.append(
                    contentsOf: self.performWrite(
                        next.data,
                        label: next.label,
                        requiresControlReadiness: next.requiresControlReadiness,
                        telemetryEvidence: telemetryEvidence,
                        heartRateSpeed: next.heartRateSpeed
                    )
                )
                self.nextCommandAllowedAt = Date().addingTimeInterval(self.commandMinIntervalSecondsForCurrentProtocol())
            }
            let needsCompensatingStop = self.isSpeedCommandLabel(next.label)
                && next.heartRateSpeed?.consumeAutoStartCompensation() == true
            self.isCommandQueueProcessing = false
            for evidence in postWriteTelemetry {
                self.observeTreadmillTelemetry(evidence, sessionID: queuedSessionID)
            }
            self.observeCancelledTreadmillCommands(
                lostEntries, reason: .other("telemetry_sidecar_order_mismatch")
            )
            if needsCompensatingStop {
                self.stopHrControlAfterCommandFailure()
                return
            }
            if !self.commandQueue.isEmpty {
                self.processCommandQueue()
            }
            self.finalizeCompletedStopIfReady()
            if let lifecycle = self.stopObservationLifecycle, lifecycle.finalReason?.hasPrefix("stop_command_not_sent") == true {
                self.telemetryV2Coordinator.stopAttemptFinalized(attemptID: lifecycle.attemptID)
            }
        }
    }

    private func performWrite(
        _ data: Data,
        label: String,
        requiresControlReadiness: Bool,
        telemetryEvidence: TreadmillCommandEnqueuedEvidence?,
        heartRateSpeed: HRDomainService.SpeedCommand? = nil
    ) -> [TreadmillTelemetryEvidence] {
        if requiresControlReadiness && !isTreadmillControlReady {
            if label == "STOP" {
                nativeWorkoutStopTransportInvocationFailedIfNeeded(
                    reason: "Управление дорожкой потеряло готовность"
                )
            }
            return [
                .commandFailed(
                    TreadmillCommandFailureObservation(
                        commandID: telemetryEvidence?.commandID,
                        decisionID: telemetryEvidence?.decisionID,
                        attemptID: nil,
                        connectionEpoch: telemetryEvidence?.connectionEpoch,
                        occurredAt: Date(),
                        reason: .transportUnavailable
                    )
                )
            ]
        }
        guard isConnected else {
            if label == "STOP" {
                markInitialStopCommandNotSent(reason: "not_connected")
                nativeWorkoutStopTransportInvocationFailedIfNeeded(
                    reason: "Дорожка отключилась до отправки Stop"
                )
            }
            return [
                .commandFailed(
                    TreadmillCommandFailureObservation(
                        commandID: telemetryEvidence?.commandID,
                        decisionID: telemetryEvidence?.decisionID,
                        attemptID: nil,
                        connectionEpoch: telemetryEvidence?.connectionEpoch,
                        occurredAt: Date(),
                        reason: .transportUnavailable
                    )
                )
            ]
        }
        guard let p = connectedPeripheral, let ch = commandCharacteristic else {
            if label == "STOP" {
                markInitialStopCommandNotSent(reason: "characteristic_unavailable")
                nativeWorkoutStopTransportInvocationFailedIfNeeded(
                    reason: "Канал управления недоступен для Stop"
                )
            }
            return [
                .commandFailed(
                    TreadmillCommandFailureObservation(
                        commandID: telemetryEvidence?.commandID,
                        decisionID: telemetryEvidence?.decisionID,
                        attemptID: nil,
                        connectionEpoch: telemetryEvidence?.connectionEpoch,
                        occurredAt: Date(),
                        reason: .transportUnavailable
                    )
                )
            ]
        }
        let type: CBCharacteristicWriteType = ch.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        lastCommandSentAt = Date()
        if label == "STOP" {
            markInitialStopCommandSent(at: lastCommandSentAt ?? Date())
        }
        lastCommandAwaitingAck = (type == .withResponse)
        lastCommandAckedAt = (type == .withResponse) ? nil : lastCommandSentAt

        if treadmillProtocol == .ftms, let opcode = data.first,
           let connection = currentTreadmillControlConnection {
            ftmsControlState.sent(opcode: opcode, connection: connection, at: .now)
        }
        p.writeValue(data, for: ch, type: type)
        if let heartRateSpeed {
            if isSpeedCommandLabel(label) {
                heartRateSpeed.recordSpeedWrite()
                let old = deviceTargetSpeedKmh
                desiredSpeedKmh = heartRateSpeed.targetKmh
                deviceTargetSpeedKmh = heartRateSpeed.targetKmh
                recordSpeedChange(from: old, to: heartRateSpeed.targetKmh, reason: "hr_decision_set")
            } else {
                // Only the paired FTMS/FitShow auto-starts carry this context here.
                heartRateSpeed.recordAutoStartWrite()
            }
        }
        if label != "QUERY STATUS", label != "QUERY PARAMS",
           var lifecycle = stopObservationLifecycle, lifecycle.finalResult == nil {
            lifecycle.markMotionWrite(at: lastCommandSentAt ?? Date(), requiresResponse: type == .withResponse)
            stopObservationLifecycle = lifecycle
        }
        if label == "STOP" {
            nativeWorkoutStopTransportInvokedIfNeeded()
        }
        let sentAt = lastCommandSentAt ?? Date()
        if label == "QUERY STATUS" { lastWalkingPadStatusQueryAt = sentAt }
        let telemetryWriteType: TreadmillCommandWriteType = type == .withoutResponse
            ? .withoutResponse
            : .withResponse
        if let telemetryEvidence {
            let previousAttemptNumber = treadmillCommandAttemptNumbers[
                telemetryEvidence.commandID
            ] ?? 0
            let attemptNumber = previousAttemptNumber == UInt16.max
                ? UInt16.max
                : previousAttemptNumber + 1
            treadmillCommandAttemptNumbers[telemetryEvidence.commandID] = attemptNumber
            return [
                .commandQueueDelay(
                    TreadmillCommandQueueDelayEvidence(
                        commandID: telemetryEvidence.commandID,
                        decisionID: telemetryEvidence.decisionID,
                        connectionEpoch: telemetryEvidence.connectionEpoch,
                        enqueuedAt: telemetryEvidence.enqueuedAt,
                        sentAt: sentAt
                    )
                ),
                .sendAttempt(
                    TreadmillCommandSendAttemptEvidence(
                        commandID: telemetryEvidence.commandID,
                        decisionID: telemetryEvidence.decisionID,
                        attemptID: CommandAttemptID(),
                        attemptNumber: attemptNumber,
                        protocolKind: telemetryEvidence.protocolKind,
                        connectionEpoch: telemetryEvidence.connectionEpoch,
                        sentAt: sentAt,
                        writeType: telemetryWriteType
                    )
                ),
            ]
        } else if let connectionEpoch = treadmillTelemetryConnectionEpoch {
            return [
                .unassociatedWrite(
                    UnassociatedLegacyWriteObservation(
                        protocolKind: treadmillTelemetryProtocolKind,
                        connectionEpoch: connectionEpoch,
                        sentAt: sentAt,
                        writeType: telemetryWriteType
                    )
                )
            ]
        }
        return []
    }

    private func markInitialStopCommandSent(at sentAt: Date) {
        if var lifecycle = stopObservationLifecycle,
           lifecycle.finalResult == nil,
           lifecycle.commandSentAt == nil {
            lifecycle.markCommandSent(at: sentAt)
            stopObservationLifecycle = lifecycle

        }
        if var attempt = unavailableStopAttempt, attempt.commandSentAt == nil {
            attempt.commandSentAt = sentAt
            unavailableStopAttempt = attempt

        }
    }

    private func markInitialStopCommandNotSent(reason: String, at now: Date = Date()) {
        if var lifecycle = stopObservationLifecycle,
           lifecycle.finalResult == nil,
           lifecycle.commandSentAt == nil {
            _ = lifecycle.finalizeUnconfirmed(
                at: now,
                reason: "stop_command_not_sent_\(reason)"
            )
            stopObservationLifecycle = lifecycle
            finishStopObservation(lifecycle: lifecycle, now: now)
        }
        if let pendingAttemptID = unavailableStopAttempt?.id {
            finalizeUnavailableStopAttempt(attemptID: pendingAttemptID)
        }
    }

    private func clampSpeedTenths(_ kmh: Double) -> Int {
        TreadmillSpeedBoundsService.clampSpeedTenths(kmh)
    }

    // MARK: - Multi-protocol treadmill support

    private func treadmillSpeedBoundsSnapshot() -> TreadmillSpeedBoundsService.Bounds {
        TreadmillSpeedBoundsService.normalized(
            min: treadmillMinSpeedKmh,
            max: treadmillMaxSpeedKmh,
            increment: treadmillSpeedIncrementKmh
        )
    }

    private func clampRunningSpeedKmh(_ value: Double) -> Double {
        TreadmillSpeedBoundsService.clampRunningSpeed(value, bounds: treadmillSpeedBoundsSnapshot())
    }

    private func clampAnySpeedKmh(_ value: Double) -> Double {
        TreadmillSpeedBoundsService.clampAnySpeed(value, bounds: treadmillSpeedBoundsSnapshot())
    }

    private func resetProtocolState() {
        treadmillObservationNormalizer.endWorkout()
        let cancelledTelemetry = resetCommandQueue(
            reason: "connection epoch reset",
            observeTelemetryImmediately: false
        )
        treadmillCommandAttemptNumbers.removeAll()
        latestTreadmillObservationEvidence = nil
        activeTreadmillStopTelemetryChain = nil
        treadmillProtocol = .unknown
        treadmillProtocolService = nil
        treadmillProtocolConnection = nil
        ftmsControlState = FTMSControlState()
        ftmsDidReadSupportedSpeedRange = false
        fitShowDidRequestInitialStatus = false
        commandCharacteristic = nil
        commandCharacteristicConnection = nil
        notifyCharacteristic = nil
        notifyCharacteristicConnection = nil
        rememberedValidatedTreadmillConnection = nil
        characteristicConnections.removeAll()
        extraNotifyCharacteristics.removeAll()
        treadmillMinSpeedKmh = 0.5
        treadmillMaxSpeedKmh = 12.0
        treadmillSpeedIncrementKmh = 0.1
        telemetryV2Coordinator.invalidateStopTail()
        controllerUnitsConnectionEpoch = nil
        stopObservationStreamID = nil
        stopObservationCheckpointWorkItems.forEach { $0.cancel() }
        stopObservationCheckpointWorkItems.removeAll()
        stopObservationFreshnessWorkItem?.cancel()
        stopObservationFreshnessWorkItem = nil
        stopObservationLifecycle = nil
        unavailableStopAttempt = nil
        stopTruthStatusText = ""
        controllerUnitsTruthTracker.disconnect()
        controllerUnitsTruth = controllerUnitsTruthTracker.state
        lastControllerUnitsQueryAt = nil
        lastControllerUnitsQueryTrigger = nil
        lastWalkingPadStatusQueryAt = nil
        isTreadmillControlReady = false
        applyNativeHeartRatePreflightEffects(
            nativeHeartRatePreflightEngine.safetyChanged(
                nativeHeartRateSafetyFacts(),
                now: Date(),
                freshnessLimit: TimeInterval(hrStaleThresholdSeconds)
            )
        )
        observeCancelledTreadmillCommands(
            cancelledTelemetry,
            reason: .other("connection_epoch_reset")
        )
    }

    private var currentTreadmillControlConnection: TreadmillControlConnectionIdentity? {
        guard isConnected,
              let peripheralID = connectedPeripheralId,
              connectedPeripheral?.identifier == peripheralID,
              let epoch = controllerUnitsConnectionEpoch else {
            return nil
        }
        return TreadmillControlConnectionIdentity(
            peripheralID: peripheralID,
            epoch: epoch
        )
    }

    private var treadmillControlProtocolKind: TreadmillControlProtocolKind {
        switch treadmillProtocol {
        case .walkingPad: return .walkingPad
        case .ftms: return .ftms
        case .fitShow: return .fitShow
        case .unknown: return .unknown
        }
    }

    private var treadmillControlTelemetryRole: TreadmillControlTransportRole? {
        switch treadmillProtocol {
        case .walkingPad where notifyCharacteristic?.uuid == charFE01:
            return .walkingPadTelemetry
        case .ftms where notifyCharacteristic?.uuid == ftmsCharTreadmillData:
            return .ftmsTelemetry
        case .fitShow where notifyCharacteristic?.uuid == fitShowCharRx:
            return .fitShowTelemetry
        case .walkingPad, .ftms, .fitShow, .unknown:
            return nil
        }
    }

    private var treadmillControlCommandRole: TreadmillControlTransportRole? {
        switch treadmillProtocol {
        case .walkingPad where commandCharacteristic?.uuid == charFE02:
            return .walkingPadCommand
        case .ftms where commandCharacteristic?.uuid == ftmsCharControlPoint:
            return .ftmsCommand
        case .fitShow where commandCharacteristic?.uuid == fitShowCharTx:
            return .fitShowCommand
        case .walkingPad, .ftms, .fitShow, .unknown:
            return nil
        }
    }

    private func recomputeTreadmillControlReadiness() {
        let telemetryEvidence = treadmillControlTelemetryRole.flatMap { role in
            notifyCharacteristicConnection.map {
                TreadmillControlTransportEvidence(
                    role: role,
                    connection: $0,
                    isUsable: notifyCharacteristic?.isNotifying == true
                )
            }
        }
        let commandEvidence = treadmillControlCommandRole.flatMap { role in
            commandCharacteristicConnection.map {
                TreadmillControlTransportEvidence(
                    role: role,
                    connection: $0,
                    isUsable: commandCharacteristic.map {
                        $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)
                    } ?? false
                )
            }
        }
        let ready = !ftmsControlState.isBlocked && TreadmillControlReadinessPolicy.isReady(
            TreadmillControlReadinessSnapshot(
                currentConnection: currentTreadmillControlConnection,
                protocolKind: treadmillControlProtocolKind,
                protocolConnection: treadmillProtocolConnection,
                telemetry: telemetryEvidence,
                command: commandEvidence
            )
        )
        let becameReady = ready && !isTreadmillControlReady
        isTreadmillControlReady = ready
        applyNativeHeartRatePreflightEffects(
            nativeHeartRatePreflightEngine.safetyChanged(
                nativeHeartRateSafetyFacts(),
                now: Date(),
                freshnessLimit: TimeInterval(hrStaleThresholdSeconds)
            )
        )
        recomputeHrStartAllowed()
        if becameReady {
            rememberCurrentValidatedTreadmill()
        }
    }

    private func invalidateTreadmillControlReadinessEvidence(
        includingProtocol: Bool = false
    ) {
        if includingProtocol {
            treadmillProtocolService = nil
            treadmillProtocolConnection = nil
        }
        commandCharacteristicConnection = nil
        notifyCharacteristicConnection = nil
        if treadmillProtocol == .ftms { failFTMSControl() }
        recomputeTreadmillControlReadiness()
    }

    private func registerCurrentCharacteristic(_ characteristic: CBCharacteristic) {
        guard let connection = currentTreadmillControlConnection else { return }
        characteristicConnections[ObjectIdentifier(characteristic)] = connection
    }

    private func isCurrentCharacteristicCallback(_ characteristic: CBCharacteristic) -> Bool {
        TreadmillControlReadinessPolicy.isCurrentCallback(
            characteristicConnections[ObjectIdentifier(characteristic)],
            currentConnection: currentTreadmillControlConnection
        )
    }

    private func rememberCurrentValidatedTreadmill() {
        guard isTreadmillControlReady,
              let connection = currentTreadmillControlConnection,
              rememberedValidatedTreadmillConnection != connection,
              let peripheral = connectedPeripheral,
              peripheral.identifier == connectedPeripheralId else {
            return
        }
        rememberedValidatedTreadmillConnection = connection
        if !knownPeripherals.contains(where: { $0.id == peripheral.identifier }) {
            let display = peripheral.name ?? "Device"
            knownPeripherals.append(KnownPeripheral(id: peripheral.identifier, name: display))
            saveKnownPeripherals()
        }
        saveLastSuccessfulPeripheral(peripheral.identifier)
    }

    private var controllerUnitsTruthRequired: Bool {
        treadmillProtocol == .walkingPad || treadmillProtocol == .unknown
    }

    private func beginControllerUnitsConnection() {
        treadmillObservationNormalizer.endWorkout()
        let epoch = UUID()
        controllerUnitsConnectionEpoch = epoch
        controllerUnitsTruthTracker.beginConnection(epoch: epoch)
        controllerUnitsTruth = controllerUnitsTruthTracker.state
        lastControllerUnitsQueryAt = nil
        lastControllerUnitsQueryTrigger = nil
    }

    private func controllerUnitsGateDecision(now: Date = Date()) -> ControllerUnitsGateDecision {
        ControllerUnitsSafetyPolicy.evaluate(
            path: .hrControl,
            state: controllerUnitsTruth,
            currentConnectionEpoch: controllerUnitsConnectionEpoch,
            now: now,
            requiresFreshMetricTruth: controllerUnitsTruthRequired
        )
    }

    func controllerUnitsDiagnosticSnapshot(
        now: Date = Date()
    ) -> ControllerUnitsDiagnosticSnapshot {
        ControllerUnitsDiagnosticSnapshot.capture(
            truth: controllerUnitsTruth,
            currentConnectionEpoch: controllerUnitsConnectionEpoch,
            now: now,
            requiresFreshMetricTruth: controllerUnitsTruthRequired
        )
    }

    private func requestControllerUnitsTruth(trigger: String, now: Date = Date()) {
        guard controllerUnitsQueryTransportReady,
              ControllerUnitsRefreshPolicy.throttleAllowsQuery(
                lastQueryAt: lastControllerUnitsQueryAt,
                now: now
              ) else {
            return
        }
        lastControllerUnitsQueryAt = now
        lastControllerUnitsQueryTrigger = trigger

        writeCommand(
            BLETransportCodec.buildWalkingPadQueryParamsPacket(), label: "QUERY PARAMS",
            telemetryRequest: treadmillCommandRequest(kind: .walkingPadControllerUnitsQuery)
        )
    }

    private func retryControllerUnitsQueryAfterBlockedStart(now: Date = Date()) {
        guard isConnected, treadmillProtocol == .walkingPad else { return }
        guard ControllerUnitsRefreshPolicy.throttleAllowsQuery(
            lastQueryAt: lastControllerUnitsQueryAt,
            now: now
        ) else {
            return
        }
        requestControllerUnitsTruth(trigger: "gate_blocked", now: now)
    }

    private var controllerUnitsQueryTransportReady: Bool {
        guard isConnected,
              treadmillProtocol == .walkingPad,
              controllerUnitsConnectionEpoch != nil,
              commandCharacteristic?.uuid == charFE02,
              notifyCharacteristic?.uuid == charFE01,
              notifyCharacteristic?.isNotifying == true,
              let connectedPeripheralID = connectedPeripheralId else {
            return false
        }
        return connectedPeripheral?.identifier == connectedPeripheralID
    }

    private func requestInitialControllerUnitsTruthIfReady(now: Date = Date()) {
        let decision = ControllerUnitsRefreshPolicy.initialQuery(
            transportReady: controllerUnitsQueryTransportReady,
            lastQueryAt: lastControllerUnitsQueryAt,
            now: now
        )
        guard let trigger = decision.trigger else { return }
        requestControllerUnitsTruth(trigger: trigger.rawValue, now: now)
    }

    private func refreshControllerUnitsTruthIfNeeded(
        existingGatesAllowStart: Bool,
        unitsDecision: ControllerUnitsGateDecision,
        now: Date
    ) {
        let refreshDecision = ControllerUnitsRefreshPolicy.blockedStartRefresh(
            existingGatesAllowStart: existingGatesAllowStart,
            isHrControlRunning: isHrControlRunning,
            transportReady: controllerUnitsQueryTransportReady,
            unitsDecision: unitsDecision,
            lastQueryAt: lastControllerUnitsQueryAt,
            now: now
        )
        guard let trigger = refreshDecision.trigger else { return }
        requestControllerUnitsTruth(trigger: trigger.rawValue, now: now)
    }

    private func maintainWalkingPadReadOnlyEvidenceDuringActiveWorkout(now: Date) {
        let refreshDecision = WalkingPadStatusRefreshPolicy.activeWorkoutRefresh(
            isWorkoutOrCooldownActive: isHrControlRunning,
            transportReady: controllerUnitsQueryTransportReady,
            motionQueueIdle: commandQueue.isEmpty && !isCommandQueueProcessing,
            secondsUntilNextScheduledMotion: controllerUnitsNextScheduledMotionLeadSeconds,
            lastStatusQueryAt: lastWalkingPadStatusQueryAt,
            lastControllerUnitsQueryAt: lastControllerUnitsQueryAt,
            earliestWriteDelaySeconds: max(0, nextCommandAllowedAt.timeIntervalSince(now)),
            writeSpacingSeconds: commandMinIntervalSecondsForCurrentProtocol(),
            now: now
        )
        switch refreshDecision.kind {
        case .status:
            requestWalkingPadStatusRefresh()
        case .controllerUnits:
            requestControllerUnitsTruth(
                trigger: ControllerUnitsRefreshTrigger.activeWorkoutIdleWindow.rawValue,
                now: now
            )
        case nil:
            break
        }
    }

    private func requestWalkingPadStatusRefresh() {
        guard controllerUnitsQueryTransportReady else { return }

        writeCommand(
            BLETransportCodec.buildWalkingPadQueryStatusPacket(),
            label: "QUERY STATUS",
            telemetryRequest: treadmillCommandRequest(kind: .walkingPadStatusQuery)
        )
    }

    private var controllerUnitsNextScheduledMotionLeadSeconds: Int {
        if let cooldownState = cooldownRuntimeState {
            return cooldownState.nextSpeedDecisionRemainingSeconds
        }
        return WalkingPadStatusRefreshPolicy.motionLeadSeconds(
            decisionRemainingSeconds: hrNextDecisionSeconds,
            phaseRemainingSeconds: intervalWorkoutState?.remainingSeconds ?? hrRemainingSeconds
        )
    }

    private func controllerUnitsResponseContext(
        peripheral: CBPeripheral,
        characteristic: CBCharacteristic
    ) -> ControllerUnitsResponseContext? {
        guard characteristic.uuid == charFE01,
              let currentPeripheralID = connectedPeripheralId,
              peripheral.identifier == currentPeripheralID,
              connectedPeripheral?.identifier == currentPeripheralID,
              let currentNotifyCharacteristic = notifyCharacteristic,
              characteristic === currentNotifyCharacteristic,
              let connectionEpoch = controllerUnitsConnectionEpoch else {
            return nil
        }
        return ControllerUnitsResponseContext(
            peripheralID: currentPeripheralID,
            connectionEpoch: connectionEpoch,
            notifyCharacteristicID: ObjectIdentifier(currentNotifyCharacteristic)
        )
    }

    private func selectTreadmillProtocol(from discoveredUuids: Set<CBUUID>) -> TreadmillProtocol {
        // WalkingPad's FE00 is the most specific signal; prefer it over generic services.
        if discoveredUuids.contains(serviceFE00) { return .walkingPad }
        if discoveredUuids.contains(serviceFTMS) { return .ftms }
        if discoveredUuids.contains(serviceFitShow) { return .fitShow }
        return .unknown
    }

    private func subscribe(_ peripheral: CBPeripheral, to characteristic: CBCharacteristic, label: String) {
        if !extraNotifyCharacteristics.contains(where: { $0.uuid == characteristic.uuid }) {
            extraNotifyCharacteristics.append(characteristic)
        }
        peripheral.setNotifyValue(true, for: characteristic)
    }

    private func shouldTreatAsCommandAck(characteristic: CBCharacteristic, data: Data) -> Bool {
        switch treadmillProtocol {
        case .walkingPad:
            guard characteristic.uuid == charFE01 else { return false }
            return data.count >= 2 && data[0] == 0xF8
        case .ftms:
            return characteristic.uuid == ftmsCharControlPoint
        case .fitShow:
            return characteristic.uuid == fitShowCharRx
        case .unknown:
            return false
        }
    }

    private func enqueueFtmsRequestControlIfNeeded(
        decision: TreadmillControlDecisionEvidence? = nil
    ) {
        guard treadmillProtocol == .ftms else { return }
        guard ftmsControlState.needsRequestControl,
              !commandQueue.contains(where: { $0.label == "FTMS REQUEST CONTROL" }) else { return }
        guard let ch = commandCharacteristic, ch.uuid == ftmsCharControlPoint else {
            return
        }
        guard let connection = currentTreadmillControlConnection,
              commandCharacteristicConnection == connection else {
            return
        }
        writeCommand(
            buildFtmsRequestControlPacket(),
            label: "FTMS REQUEST CONTROL",
            telemetryRequest: treadmillCommandRequest(
                kind: .other("request_control"),
                decision: decision
            )
        )
    }

    private func failFTMSControl() {
        ftmsControlState.invalidate()
        resetCommandQueue(reason: "FTMS control unavailable")
        markInitialStopCommandNotSent(reason: "ftms_control_unavailable")
        nativeWorkoutStopTransportInvocationFailedIfNeeded(reason: "FTMS не подтвердил управление")
        isTreadmillControlReady = false
        cancelTreadmillTestRunForConnectionInvalidation()
        if isHrControlRunning {
            stopHrControlAfterCommandFailure(reason: "ftms_control_unavailable", requestStop: false)
        }
        infoToastMessage = "Управление FTMS недоступно. Проверьте остановку дорожки и переподключитесь."
        recomputeHrStartAllowed()
    }

    private func handleFTMSProcedureRejection(opcode: UInt8) {
        cancelTreadmillTestRun(reason: .commandRejected, requestProductionStop: false)
        // A rejected Stop must also discard queued Stops, avoiding an implicit retry.
        let rejectedStop = opcode == 0x08
        commandQueueEpoch += 1
        isCommandQueueProcessing = false
        nextCommandAllowedAt = .distantPast
        commandQueue.removeAll { rejectedStop || $0.label != "STOP" }
        observeCancelledTreadmillCommands(
            treadmillCommandTelemetrySidecar.removeQueued { rejectedStop || $0 != "STOP" },
            reason: .other("ftms_procedure_rejected")
        )
        let hasQueuedStop = !commandQueue.isEmpty
        let requestStop = !rejectedStop && !hasQueuedStop
        if isHrControlRunning {
            stopHrControlAfterCommandFailure(reason: "ftms_procedure_rejected", requestStop: requestStop)
        } else if requestStop {
            stopBeltWithToggle(reason: "ftms_procedure_rejected")
        }
        if opcode == 0x08 {
            nativeWorkoutStopTransportInvocationFailedIfNeeded(reason: "Дорожка отклонила Stop")
            infoToastMessage = "Дорожка отклонила остановку. Проверьте полотно и повторите Stop."
        } else {
            infoToastMessage = "Дорожка отклонила команду. Остановка запрошена, но ещё не подтверждена."
        }
        if hasQueuedStop { processCommandQueue() }
    }

    private func commandMinIntervalSecondsForCurrentProtocol() -> TimeInterval {
        switch treadmillProtocol {
        case .walkingPad:
            return commandMinIntervalWalkingPadSeconds
        case .ftms:
            return commandMinIntervalFtmsSeconds
        case .fitShow:
            return commandMinIntervalFitShowSeconds
        case .unknown:
            return commandMinIntervalUnknownSeconds
        }
    }

    private func shouldAutoStartForSpeedChange(kmh: Double) -> Bool {
        // For FTMS/FitShow devices, a speed write may be ignored unless the machine is in started state.
        // We keep it conservative: only auto-start when requested speed is clearly > 0.
        guard kmh >= 0.3 else { return false }
        let observed = max(deviceReportedSpeedKmh, speedKmh)
        return observed < 0.2
    }

    private func sendTreadmillSetSpeed(
        _ kmh: Double,
        label: String,
        decision: TreadmillControlDecisionEvidence? = nil,
        heartRateSpeed: HRDomainService.SpeedCommand? = nil
    ) {
        guard !blocksNonStopTreadmillMotion else {
            return
        }
        guard isTreadmillControlReady else {
            return
        }
        if kmh > 0.1 {
            endStopObservationForNewMotion()
        }
        switch treadmillProtocol {
        case .walkingPad:
            writeCommand(
                buildWalkingPadSetSpeedPacket(kmh: kmh),
                label: label,
                requiresControlReadiness: true,
                telemetryRequest: treadmillCommandRequest(
                    kind: treadmillSetSpeedCommandKind(kmh),
                    decision: decision
                ),
                heartRateSpeed: heartRateSpeed
            )
        case .ftms:
            enqueueFtmsRequestControlIfNeeded(decision: decision)
            if shouldAutoStartForSpeedChange(kmh: kmh) {
                writeCommand(
                    buildFtmsStartOrResumePacket(),
                    label: "FTMS START/RESUME (auto)",
                    requiresControlReadiness: true,
                    telemetryRequest: treadmillCommandRequest(
                        kind: .other("auto_start"),
                        decision: decision
                    ),
                    heartRateSpeed: heartRateSpeed
                )
            }
            writeCommand(
                buildFtmsSetSpeedPacket(kmh: kmh),
                label: label,
                requiresControlReadiness: true,
                telemetryRequest: treadmillCommandRequest(
                    kind: treadmillSetSpeedCommandKind(kmh),
                    decision: decision
                ),
                heartRateSpeed: heartRateSpeed
            )
        case .fitShow:
            if shouldAutoStartForSpeedChange(kmh: kmh) {
                writeCommand(
                    buildFitShowStartOrResumePacket(),
                    label: "FitShow START/RESUME (auto)",
                    requiresControlReadiness: true,
                    telemetryRequest: treadmillCommandRequest(
                        kind: .other("auto_start"),
                        decision: decision
                    ),
                    heartRateSpeed: heartRateSpeed
                )
            }
            writeCommand(
                buildFitShowSetSpeedPacket(kmh: kmh, incline: 0),
                label: label,
                requiresControlReadiness: true,
                telemetryRequest: treadmillCommandRequest(
                    kind: treadmillSetSpeedCommandKind(kmh),
                    decision: decision
                ),
                heartRateSpeed: heartRateSpeed
            )
        case .unknown:
            break
        }
    }

    private func buildTreadmillStopPacket() -> Data? {
        switch treadmillProtocol {
        case .walkingPad:
            return buildCmdPacket(cmd: 0x01, value: 0x00)
        case .ftms:
            return buildFtmsStopPacket()
        case .fitShow:
            return buildFitShowStopPacket()
        case .unknown:
            return nil
        }
    }

    private func buildWalkingPadSetSpeedPacket(kmh: Double) -> Data {
        buildCmdPacket(cmd: 0x01, value: UInt8(clampSpeedTenths(kmh)))
    }

    private func buildFtmsRequestControlPacket() -> Data {
        BLETransportCodec.buildFtmsRequestControlPacket()
    }

    private func buildFtmsStartOrResumePacket() -> Data {
        BLETransportCodec.buildFtmsStartOrResumePacket()
    }

    private func buildFtmsStopPacket() -> Data {
        BLETransportCodec.buildFtmsStopPacket()
    }

    private func buildFtmsSetSpeedPacket(kmh: Double) -> Data {
        BLETransportCodec.buildFtmsSetSpeedPacket(kmh: kmh)
    }

    private func buildFitShowStartOrResumePacket() -> Data {
        BLETransportCodec.buildFitShowStartOrResumePacket()
    }

    private func buildFitShowStopPacket() -> Data {
        BLETransportCodec.buildFitShowStopPacket()
    }

    private func buildFitShowSetSpeedPacket(kmh: Double, incline: UInt8) -> Data {
        BLETransportCodec.buildFitShowSetSpeedPacket(kmh: kmh, incline: incline)
    }

    private func buildFitShowFrame(cmd: UInt8, subcmd: UInt8?, payload: Data) -> Data {
        BLETransportCodec.buildFitShowFrame(cmd: cmd, subcmd: subcmd, payload: payload)
    }

    private typealias FtmsTreadmillData = BLETransportCodec.FtmsTreadmillData

    private func parseFtmsTreadmillData(_ data: Data) -> FtmsTreadmillData? {
        BLETransportCodec.parseFtmsTreadmillData(data)
    }

    private typealias FtmsSupportedSpeedRange = BLETransportCodec.FtmsSupportedSpeedRange

    private func parseFtmsSupportedSpeedRange(_ data: Data) -> FtmsSupportedSpeedRange? {
        BLETransportCodec.parseFtmsSupportedSpeedRange(data)
    }

    private typealias FtmsControlPointResponse = BLETransportCodec.FtmsControlPointResponse

    private func parseFtmsControlPointResponse(_ data: Data) -> FtmsControlPointResponse? {
        BLETransportCodec.parseFtmsControlPointResponse(data)
    }

    private typealias FitShowFrame = BLETransportCodec.FitShowFrame

    private func parseFitShowFrame(_ data: Data) -> FitShowFrame? {
        BLETransportCodec.parseFitShowFrame(data)
    }

    private func applyFitShowFrame(
        _ frame: FitShowFrame,
        peripheral: CBPeripheral,
        characteristic: CBCharacteristic,
        receivedAt: Date
    ) {

        // Update "ack" and keep raw for debugging.
        DispatchQueue.main.async {
            self.deviceReportedRawHex = frame.rawHex
            self.deviceReportedChecksumOk = frame.checksumOk
            self.treadmillFactualObservationPublisher.publish()
        }

        if frame.cmd == 0x53, frame.subcmd == 0x02 {
            // Set speed response: current speed + incline (B,B) for <= 25 km/h.
            if frame.payload.count >= 2 {
                let speedTenths = Int(frame.payload[0])
                let incline = Int(frame.payload[1])
                let speedKmh = Double(speedTenths) / 10.0
                DispatchQueue.main.async {
                    self.deviceReportedSpeedKmh = speedKmh
                    self.deviceReportedAppSpeedKmh = speedKmh
                    self.deviceReportedManualMode = incline
                    self.publishTrainingUITreadmillSpeedIfNeeded()
                    if peripheral.identifier == self.connectedPeripheralId,
                       characteristic.uuid == self.fitShowCharRx,
                       let connectionEpoch = self.treadmillTelemetryConnectionEpoch {
                        _ = self.observeTreadmillProviderObservation(
                            .fitShow(
                                speedRawTenthsKmh: speedTenths,
                                rawState: nil,
                                deviceState: .unknown,
                                checksumValid: frame.checksumOk,
                                connectionEpoch: connectionEpoch,
                                receivedAt: receivedAt
                            )
                        )
                    }
                }

                return
            }
        }

        if frame.cmd == 0x51 {
            // Status response.
            guard !frame.payload.isEmpty else {
                DispatchQueue.main.async {
                    guard peripheral.identifier == self.connectedPeripheralId,
                          characteristic.uuid == self.fitShowCharRx,
                          let connectionEpoch = self.treadmillTelemetryConnectionEpoch else {
                        return
                    }
                    _ = self.observeTreadmillProviderObservation(
                        .fitShow(
                            speedRawTenthsKmh: nil,
                            rawState: nil,
                            deviceState: .unknown,
                            checksumValid: frame.checksumOk,
                            connectionEpoch: connectionEpoch,
                            receivedAt: receivedAt
                        )
                    )
                }
                return
            }
            let state = Int(frame.payload[0])
            var speedKmh: Double? = nil
            var speedRawTenths: Int? = nil
            if frame.payload.count >= 3 {
                let speedTenths = Int(frame.payload[1])
                speedRawTenths = speedTenths
                speedKmh = Double(speedTenths) / 10.0
            }
            DispatchQueue.main.async {
                self.deviceReportedState = state
                if let speedKmh {
                    self.deviceReportedSpeedKmh = speedKmh
                    self.deviceReportedAppSpeedKmh = speedKmh
                }
                self.publishTrainingUITreadmillSpeedIfNeeded()
                if peripheral.identifier == self.connectedPeripheralId,
                   characteristic.uuid == self.fitShowCharRx,
                   let connectionEpoch = self.treadmillTelemetryConnectionEpoch {
                    _ = self.observeTreadmillProviderObservation(
                        .fitShow(
                            speedRawTenthsKmh: speedRawTenths,
                            rawState: state,
                            deviceState: .unknown,
                            checksumValid: frame.checksumOk,
                            connectionEpoch: connectionEpoch,
                            receivedAt: receivedAt
                        )
                    )
                }
            }

            return
        }

    }

    private typealias AdaptiveStepSelection = HRDomainService.AdaptiveStepSelection
    private typealias AdaptiveThresholdPercents = HRDomainService.AdaptiveThresholdPercents

    private func quantizeSpeedStep(_ value: Double) -> Double {
        HRDomainService.quantizeSpeedStep(value)
    }

    private func adaptiveThresholdPercentsSnapshot() -> AdaptiveThresholdPercents {
        let deadband = quantizeAdaptivePercent(max(1.0, min(15.0, hrAdaptiveDeadbandPercent)))
        let downL2 = quantizeAdaptivePercent(max(deadband + 0.5, min(30.0, hrAdaptiveDownLevel2StartPercent)))
        let downL3 = quantizeAdaptivePercent(max(downL2 + 0.5, min(40.0, hrAdaptiveDownLevel3StartPercent)))
        let downL4 = quantizeAdaptivePercent(max(downL3 + 0.5, min(60.0, hrAdaptiveDownLevel4StartPercent)))
        let upL2 = quantizeAdaptivePercent(max(deadband + 0.5, min(40.0, hrAdaptiveUpLevel2StartPercent)))
        let upL3 = quantizeAdaptivePercent(max(upL2 + 0.5, min(60.0, hrAdaptiveUpLevel3StartPercent)))
        let upL4 = quantizeAdaptivePercent(max(upL3 + 0.5, min(80.0, hrAdaptiveUpLevel4StartPercent)))
        return AdaptiveThresholdPercents(
            deadband: deadband,
            downLevel2Start: downL2,
            downLevel3Start: downL3,
            downLevel4Start: downL4,
            upLevel2Start: upL2,
            upLevel3Start: upL3,
            upLevel4Start: upL4
        )
    }

    private func adaptiveDiffPercent(_ absDiff: Int, targetBpm: Int) -> Double {
        HRDomainService.diffPercent(absDiff: absDiff, targetBpm: targetBpm)
    }

    private func adaptiveDiffBpm(forPercent percent: Double, targetBpm: Int) -> Int {
        HRDomainService.diffBpm(forPercent: percent, targetBpm: targetBpm)
    }

    private func adaptiveDeadbandBpm(targetBpm: Int, thresholds: AdaptiveThresholdPercents) -> Int {
        HRDomainService.deadbandBpm(targetBpm: targetBpm, thresholds: thresholds)
    }

    private func adaptiveStepFromDiff(
        diffPercent: Double,
        isIncreasingSpeed: Bool,
        thresholds: AdaptiveThresholdPercents
    ) -> AdaptiveStepSelection {
        HRDomainService.stepFromDiff(
            diffPercent: diffPercent,
            isIncreasingSpeed: isIncreasingSpeed,
            thresholds: thresholds
        )
    }

    private func adaptiveStepForLevel(_ level: Int) -> Double {
        HRDomainService.stepForLevel(level)
    }

    private func recordSpeedChange(from old: Double, to new: Double, reason: String = "unspecified") {
        let delta = new - old
        lastSpeedDeltaKmh = abs(delta) < 0.01 ? 0 : delta
        guard abs(delta) >= 0.01 else { return }

    }

    private func recordHrSample(_ bpm: Int, at date: Date = Date()) {
        let raw = Double(bpm)
        let smoothed: Double
        if let ema = hrTrendEmaBpm {
            smoothed = ema + hrTrendEmaAlpha * (raw - ema)
        } else {
            smoothed = raw
        }
        hrTrendEmaBpm = smoothed
        hrTrendSamples.append(
            HRTrendSample(
                date: date,
                smoothedBPM: smoothed,
                telemetryDelivery: nil
            )
        )
        let cutoff = date.addingTimeInterval(-hrTrendWindowSeconds)
        while hrTrendSamples.count > 2,
              let first = hrTrendSamples.first,
              first.date < cutoff
        {
            hrTrendSamples.removeFirst()
        }
    }

    private func attachTelemetryDeliveryToLatestHrTrendSample(
        _ delivery: HeartRateDeliveryEvidence
    ) {
        guard !hrTrendSamples.isEmpty else { return }
        hrTrendSamples[hrTrendSamples.count - 1].telemetryDelivery = delivery
    }

    func setHeartRateTelemetrySink(_ sink: (any HeartRateTelemetrySink)?) {
        heartRateTelemetrySink = sink
    }

    func setTreadmillTelemetrySink(_ sink: (any TreadmillTelemetrySink)?) {
        treadmillTelemetrySink = sink
    }

    private func beginTelemetryV2Session(legacySessionID: UUID?) {
        guard isHrControlRunning, let startedAt = hrControlStartedAt else { return }
        let sessionID = TelemetryV2SessionDescriptor.sessionID(
            deterministicallyLinkedTo: legacySessionID
        )
        activeTelemetryV2SessionID = sessionID
        activeTelemetryV2ProfileID = activeUserProfileID
#if canImport(UIKit)
        let deviceModel: String? = UIDevice.current.model
#else
        let deviceModel: String? = nil
#endif
        let descriptor = TelemetryV2SessionDescriptor(
            sessionID: sessionID,
            deterministicLegacySessionID: legacySessionID,
            startedAt: startedAt,
            appContext: currentTelemetryV2AppContext(deviceModel: deviceModel),
            configuration: TelemetryV2ConfigurationInput(
                profileLocalIdentifier: activeUserProfile?.id.uuidString ?? "unknown",
                workoutMode: intervalWorkoutState == nil ? .heartRateControlled : .other("intervals-v1"),
                targetHeartRate: activeHRControlTargetBPM,
                durationMinutes: intervalWorkoutState == nil ? hrDurationMinutes : (hrSessionTotalSeconds + 59) / 60,
                decisionIntervalSeconds: hrDecisionIntervalSeconds,
                adaptiveStepEnabled: hrAdaptiveStepEnabled,
                maximumStepKilometresPerHour: hrSpeedStepKmh,
                heartRateZones: [hrZone1Max, hrZone2Max, hrZone3Max, hrZone4Max],
                cooldownTargetHeartRate: hrCooldownTargetBpm,
                cooldownMinimumSpeedKilometresPerHour: hrCooldownMinSpeed,
                cooldownMaximumMinutes: hrCooldownMaxMinutes,
                heartRateProviderKind: "healthKitSelected",
                heartRateProviderStableLocalKey: "iphone-healthkit-selected",
                treadmill: TelemetryV2TreadmillContext(
                    stableLocalIdentifier: connectedPeripheralId?.uuidString,
                    model: displayDeviceName ?? (deviceName.isEmpty ? nil : deviceName),
                    protocolName: treadmillProtocol.rawValue,
                    protocolVersion: nil,
                    minimumSpeedKilometresPerHour: treadmillMinSpeedKmh,
                    maximumSpeedKilometresPerHour: treadmillMaxSpeedKmh,
                    speedIncrementKilometresPerHour: treadmillSpeedIncrementKmh
                )
            ),
            versions: currentTelemetryV2RuntimeVersions,
            heartRateFreshnessLimitSeconds: 7,
            treadmillFreshnessLimitSeconds: 5
        )
        telemetryV2Coordinator.beginSession(descriptor)
    }

    private var currentTelemetryV2AppContext: AppRuntimeContext {
        currentTelemetryV2AppContext(deviceModel: nil)
    }

    private func currentTelemetryV2AppContext(deviceModel: String?) -> AppRuntimeContext {
        AppRuntimeContext(
            appVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown",
            buildNumber: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "unknown",
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceModel: deviceModel
        )
    }

    private var currentTelemetryV2RuntimeVersions: RuntimeVersionContext {
        RuntimeVersionContext(
            telemetrySchema: TelemetrySchemaVersion(rawValue: "1.0.0"),
            algorithm: AlgorithmVersion(rawValue: intervalWorkoutState == nil
                ? "legacy-hr-control-2026-08" : "interval-hr-control-v1-test"),
            safetyPolicy: SafetyPolicyVersion(rawValue: "walkingpad-runtime-safety-2026-08"),
            workoutProtocol: WorkoutProtocolVersion(rawValue: "hr-workout-v1")
        )
    }

    private func endTelemetryV2Session(reason: String) {
        hrLastDecisionAt = nil
        if let state = intervalWorkoutState {
            _ = telemetryV2Coordinator.observeWorkoutPhase(
                .finished, occurredAt: Date(), intervalContext: state.evidence(reason: state.finishReason ?? reason)
            )
        }
        pendingIntervalPlan = nil
        hrControlStartedInstant = nil
        treadmillObservationNormalizer.endWorkout()
        finishNativeHealthKitWorkoutIfNeeded()
        telemetryV2Coordinator.endSession(reason: reason)
    }

    private func finishNativeHealthKitWorkoutIfNeeded() {
        guard nativeHealthKitWorkoutCommitted,
              !nativeHealthKitWorkoutFinishInFlight else { return }
        guard pendingNativeWorkoutStopTerminalRequest == nil else { return }
        let finishRequestedAt = Date()
        guard let record = activeNativeWorkoutRecoveryRecord else {
            isNativeWorkoutRecoveryActive = true
            nativeWorkoutRecoveryStatusText = "Не удалось сохранить завершение тренировки"
            recomputeHrStartAllowed()
            return
        }
        if record.phase == .stopping {
            return
        }
        if record.phase == .committed {
            guard !isConnected else {
                isNativeWorkoutRecoveryActive = true
                nativeWorkoutRecoveryStatusText = "Stop не отправлен"
                recomputeHrStartAllowed()
                return
            }
            guard persistNativeWorkoutRecoveryRecord(
                record.finishing(requestedAt: finishRequestedAt)
            ) else {
                isNativeWorkoutRecoveryActive = true
                nativeWorkoutRecoveryStatusText = "Не удалось сохранить завершение тренировки"
                recomputeHrStartAllowed()
                return
            }
        } else if record.phase != .finishing {
            isNativeWorkoutRecoveryActive = true
            nativeWorkoutRecoveryStatusText = "Некорректное состояние завершения"
            recomputeHrStartAllowed()
            return
        }
        guard let finishingRecord = activeNativeWorkoutRecoveryRecord,
              finishingRecord.phase == .finishing else { return }
        nativeHealthKitWorkoutFinishInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            var terminalSaveProven = false
            var terminalProofPending = false
            defer {
                nativeHealthKitWorkoutFinishInFlight = false
                nativeHeartRateFlowOwnsController = false
                isNativeHeartRateCurrent = false
                nativeHealthKitAcquisitionStartedAt = nil
                nativeHeartRateProviderLifecycle.releaseCommittedProvider()
                nativeWorkoutRecoverySessionRecovered = false
                nativeWorkoutRecoveryStopRequested = false
                if terminalSaveProven,
                   clearNativeWorkoutRecoveryRecord() {
                    completeNativeWorkoutRecoveryToIdle()
                } else {
                    nativeHealthKitWorkoutCommitted = true
                    isNativeWorkoutRecoveryActive = true
                    nativeWorkoutRecoveryStatusText = terminalProofPending
                        ? "Проверяем сохранение восстановленной тренировки…"
                        : "Не удалось завершить восстановленную тренировку"
                }
                recomputeHrStartAllowed()
                if !hasOutstandingNativeWorkoutRecovery {
                    warmNativeHeartRateProviderIfPossible()
                }
            }
            do {
                switch try await iPhoneHealthKitHeartRateProvider.finish(
                    at: finishRequestedAt,
                    recoveredStoppedAt: finishingRecord.healthKitStopActivityAt,
                    persistStoppedAt: { [weak self] stoppedAt in
                        guard let self,
                              let currentRecord = activeNativeWorkoutRecoveryRecord,
                              currentRecord.appWorkoutID == finishingRecord.appWorkoutID,
                              currentRecord.phase == .finishing else {
                            return false
                        }
                        return persistNativeWorkoutRecoveryRecord(
                            currentRecord.recordingHealthKitStopActivity(at: stoppedAt)
                        )
                    }
                ) {
                case .saved(let workout):
                    guard let completedRecord = activeNativeWorkoutRecoveryRecord,
                          completedRecord.appWorkoutID == finishingRecord.appWorkoutID,
                          NativeWorkoutSavedProofPolicy.matches(
                            record: completedRecord,
                            workoutStartedAt: workout.startDate,
                            workoutEndedAt: workout.endDate,
                            isWalking: workout.workoutActivityType == .walking,
                            sourceMatchesApp: workout.sourceRevision.source.bundleIdentifier
                                == Bundle.main.bundleIdentifier
                          ) else {
                        throw IPhoneHealthKitHeartRateProviderError.operationCancelled
                    }
                    nativeHealthKitAcquisitionStartedAt = nil
                    guard retainDeferredNativeHealthKitLinkage(
                        record: completedRecord,
                        finishRequestedAt: completedRecord.terminalRequestedAt
                            ?? finishRequestedAt,
                        healthKitStoppedAt: completedRecord.healthKitStopActivityAt,
                        healthKitWorkoutID: workout.uuid
                    ) != nil else {
                        throw IPhoneHealthKitHeartRateProviderError.operationCancelled
                    }
                    terminalSaveProven = true
                    resolveDeferredNativeHealthKitLinkageIfPossible()
                    nativeHeartRateLogger.info("workout_finished_direct_proof")
                case .savedWorkoutUnavailable:
                    guard let completedRecord = activeNativeWorkoutRecoveryRecord,
                          let terminalRequestedAt = completedRecord.terminalRequestedAt,
                          let healthKitStoppedAt = completedRecord.healthKitStopActivityAt else {
                        throw IPhoneHealthKitHeartRateProviderError.operationCancelled
                    }
                    guard retainDeferredNativeHealthKitLinkage(
                        record: completedRecord,
                        finishRequestedAt: terminalRequestedAt,
                        healthKitStoppedAt: healthKitStoppedAt,
                        healthKitWorkoutID: nil
                    ) != nil else {
                        throw IPhoneHealthKitHeartRateProviderError.operationCancelled
                    }
                    resolveDeferredNativeHealthKitLinkageIfPossible()
                    nativeHeartRateLogger.info("workout_finish_proof_deferred")
                    terminalProofPending = true
                }
            } catch {
                nativeHeartRateLogger.error("workout_finish_failed")
            }
        }
    }

    private func retainDeferredNativeHealthKitLinkage(
        record: NativeWorkoutRecoveryRecord,
        finishRequestedAt: Date,
        healthKitStoppedAt: Date?,
        healthKitWorkoutID: UUID? = nil
    ) -> DeferredNativeHealthKitLinkage? {
        let linkage = DeferredNativeHealthKitLinkage(
            acquisitionStartedAt: record.acquisitionStartedAt,
            finishRequestedAt: finishRequestedAt,
            healthKitStoppedAt: healthKitStoppedAt,
            profileID: record.profileID,
            telemetrySessionID: record.telemetrySessionID,
            linksLegacyWorkout: false,
            legacyWorkoutID: nil,
            recoveryAppWorkoutID: record.appWorkoutID,
            healthKitWorkoutID: healthKitWorkoutID
        )
        guard retainDeferredNativeHealthKitLinkage(linkage) else { return nil }
        return linkage
    }

    @discardableResult
    private func retainDeferredNativeHealthKitLinkage(
        _ linkage: DeferredNativeHealthKitLinkage
    ) -> Bool {
        loadDeferredNativeHealthKitLinkagesIfNeeded()
        guard let updated = DeferredNativeHealthKitLinkageQueue.retaining(
            linkage,
            in: deferredNativeHealthKitLinkages
        ) else { return false }
        let previous = deferredNativeHealthKitLinkages
        deferredNativeHealthKitLinkages = updated
        guard persistDeferredNativeHealthKitLinkages() else {
            deferredNativeHealthKitLinkages = previous
            return false
        }
        return true
    }

    private func retainSavedWorkoutProof(
        id: UUID,
        replacing source: DeferredNativeHealthKitLinkage
    ) -> DeferredNativeHealthKitLinkage? {
        guard let updated = DeferredNativeHealthKitLinkageQueue.provingSavedWorkout(
            id: id,
            replacing: source,
            in: deferredNativeHealthKitLinkages
        ) else { return nil }
        let previous = deferredNativeHealthKitLinkages
        deferredNativeHealthKitLinkages = updated
        guard persistDeferredNativeHealthKitLinkages() else {
            deferredNativeHealthKitLinkages = previous
            return nil
        }
        return source.provingSavedWorkout(id: id)
    }

    private func clearDeferredNativeHealthKitLinkage(
        _ linkage: DeferredNativeHealthKitLinkage
    ) {
        deferredNativeHealthKitLinkages.removeAll { $0 == linkage }
        if deferredNativeHealthKitLinkages.isEmpty {
            UserDefaults.standard.removeObject(forKey: deferredNativeHealthKitLinkageStoreKey)
        } else {
            _ = persistDeferredNativeHealthKitLinkages()
        }
    }

    private func loadDeferredNativeHealthKitLinkagesIfNeeded() {
        guard deferredNativeHealthKitLinkages.isEmpty,
              let data = UserDefaults.standard.data(
                forKey: deferredNativeHealthKitLinkageStoreKey
              ) else { return }
        deferredNativeHealthKitLinkages = (try? JSONDecoder().decode(
            [DeferredNativeHealthKitLinkage].self,
            from: data
        )) ?? []
    }

    private func persistDeferredNativeHealthKitLinkages() -> Bool {
        guard let data = try? JSONEncoder().encode(deferredNativeHealthKitLinkages) else {
            return false
        }
        UserDefaults.standard.set(data, forKey: deferredNativeHealthKitLinkageStoreKey)
        guard let storedData = UserDefaults.standard.data(
            forKey: deferredNativeHealthKitLinkageStoreKey
        ), let stored = try? JSONDecoder().decode(
            [DeferredNativeHealthKitLinkage].self,
            from: storedData
        ) else {
            return false
        }
        return stored == deferredNativeHealthKitLinkages
    }

    private func resolveDeferredNativeHealthKitLinkageIfPossible(
        excluding attempted: [DeferredNativeHealthKitLinkage] = []
    ) {
        guard profileErasureStateLoaded, !profileErasureInFlight,
              nativeHeartRateAppActivity == .active,
              !nativeHealthKitLinkageQueryInFlight else { return }
        loadDeferredNativeHealthKitLinkagesIfNeeded()
        let candidates = deferredNativeHealthKitLinkages.filter {
            !attempted.contains($0) && $0.profileID.map { !erasedProfiles.contains($0.uuidString.lowercased()) } != false
        }
        guard let linkage = DeferredNativeHealthKitLinkageQueue.next(
            in: candidates,
            preferredRecoveryAppWorkoutID: activeNativeWorkoutRecoveryRecord?
                .appWorkoutID
        ) else { return }
        let attemptedIncludingCurrent = attempted + [linkage]

        if let workoutID = linkage.healthKitWorkoutID {
            nativeHealthKitLinkageQueryInFlight = true
            completeRecoveredFinishIfProven(linkage: linkage)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let linkagePersisted = await linkDeferredNativeHealthKitWorkout(
                    uuid: workoutID,
                    linkage: linkage
                )
                nativeHealthKitLinkageQueryInFlight = false
                guard linkagePersisted else {
                    nativeHeartRateLogger.error("deferred_exact_link_failed")
                    resolveDeferredNativeHealthKitLinkageIfPossible(
                        excluding: attemptedIncludingCurrent
                    )
                    return
                }
                nativeHeartRateLogger.info("deferred_exact_link_resolved")
                clearDeferredNativeHealthKitLinkage(linkage)
                resolveDeferredNativeHealthKitLinkageIfPossible(
                    excluding: attempted
                )
            }
            return
        }

        nativeHealthKitLinkageQueryInFlight = true
        let expectedEndAt = linkage.healthKitStoppedAt ?? linkage.finishRequestedAt
        let predicate = HKQuery.predicateForSamples(
            withStart: linkage.acquisitionStartedAt.addingTimeInterval(-2),
            end: expectedEndAt.addingTimeInterval(2),
            options: []
        )
        let query = HKSampleQuery(
            sampleType: HKObjectType.workoutType(),
            predicate: predicate,
            limit: 10,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
        ) { [weak self] _, samples, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard error == nil else {
                    nativeHealthKitLinkageQueryInFlight = false
                    nativeHeartRateLogger.error("deferred_link_query_failed")
                    resolveDeferredNativeHealthKitLinkageIfPossible(
                        excluding: attemptedIncludingCurrent
                    )
                    return
                }
                let appBundleIdentifier = Bundle.main.bundleIdentifier
                let recoveryRecord: NativeWorkoutRecoveryRecord? = {
                    guard let recoveryAppWorkoutID = linkage.recoveryAppWorkoutID,
                          case .record(let record) = self.nativeWorkoutRecoveryLoadResult,
                          record.appWorkoutID == recoveryAppWorkoutID else {
                        return nil
                    }
                    return record
                }()
                let workout = NativeWorkoutSavedProofPolicy.uniqueMatch(
                    in: samples as? [HKWorkout] ?? []
                ) { workout in
                    if let recoveryRecord {
                        return NativeWorkoutSavedProofPolicy.matches(
                            record: recoveryRecord,
                            workoutStartedAt: workout.startDate,
                            workoutEndedAt: workout.endDate,
                            isWalking: workout.workoutActivityType == .walking,
                            sourceMatchesApp: workout.sourceRevision.source.bundleIdentifier
                                == appBundleIdentifier
                        )
                    }
                    return workout.workoutActivityType == .walking
                        && workout.sourceRevision.source.bundleIdentifier == appBundleIdentifier
                        && abs(workout.startDate.timeIntervalSince(
                            linkage.acquisitionStartedAt
                        )) <= 5
                        && abs(workout.endDate.timeIntervalSince(expectedEndAt)) <= 15
                }
                guard let workout else {
                    nativeHealthKitLinkageQueryInFlight = false
                    nativeHeartRateLogger.error("deferred_link_match_unproven")
                    resolveDeferredNativeHealthKitLinkageIfPossible(
                        excluding: attemptedIncludingCurrent
                    )
                    return
                }
                let provenLinkage = retainSavedWorkoutProof(
                    id: workout.uuid,
                    replacing: linkage
                )
                nativeHealthKitLinkageQueryInFlight = false
                guard let provenLinkage else {
                    nativeHeartRateLogger.error("deferred_saved_proof_write_failed")
                    resolveDeferredNativeHealthKitLinkageIfPossible(
                        excluding: attemptedIncludingCurrent
                    )
                    return
                }
                completeRecoveredFinishIfProven(linkage: provenLinkage)
                resolveDeferredNativeHealthKitLinkageIfPossible(
                    excluding: attempted
                )
            }
        }
        healthStore.execute(query)
    }

    @discardableResult
    private func linkDeferredNativeHealthKitWorkout(
        uuid: UUID,
        linkage: DeferredNativeHealthKitLinkage
    ) async -> Bool {
        // Old recovery records retain their legacy fields for decoding. Only a
        // proven V2 session can satisfy linkage; never rewrite legacy sources.
        return await NativeWorkoutRequiredLinkagePolicy.complete(
            telemetrySessionID: linkage.telemetrySessionID,
            persistTelemetry: { [self] sessionUUID in
                await persistHealthKitWorkoutAssociationWithTelemetryV2(
                    sessionID: SessionID(rawValue: sessionUUID), workoutIdentifier: uuid
                )
            }
        )
    }

    private func completeRecoveredFinishIfProven(
        linkage: DeferredNativeHealthKitLinkage
    ) {
        guard let recoveryAppWorkoutID = linkage.recoveryAppWorkoutID,
              case .record(let record) = nativeWorkoutRecoveryLoadResult,
              record.phase == .finishing,
              record.appWorkoutID == recoveryAppWorkoutID,
              clearNativeWorkoutRecoveryRecord() else { return }
        completeNativeWorkoutRecoveryToIdle()
        warmNativeHeartRateProviderIfPossible()
        nativeHeartRateLogger.info("finished_workout_reconciled_after_saved_proof")
    }

    private var treadmillTelemetryConnectionEpoch: TreadmillConnectionEpoch? {
        controllerUnitsConnectionEpoch.map(TreadmillConnectionEpoch.init(rawValue:))
    }

    private var treadmillTelemetryProtocolKind: TreadmillProtocolKind {
        switch treadmillProtocol {
        case .walkingPad: return .walkingPad
        case .ftms: return .ftms
        case .fitShow: return .fitShow
        case .unknown: return .unknown
        }
    }

    private func observeTreadmillTelemetry(_ evidence: TreadmillTelemetryEvidence) {
        observeTreadmillTelemetry(evidence, sessionID: activeTelemetryV2SessionID)
    }

    private func observeTreadmillTelemetry(_ evidence: TreadmillTelemetryEvidence, sessionID: SessionID?) {
        guard let sessionID else { return }
        _ = treadmillTelemetrySink?.observeTreadmillEvidence(
            evidence, currentConnectionEpoch: treadmillTelemetryConnectionEpoch, sessionID: sessionID
        )
    }

    private func captureStopTelemetryAttempt(_ attemptID: UUID, attemptedMonotonic: Duration) {
        guard let chain = activeTreadmillStopTelemetryChain, chain.commandID != nil, let sessionID = chain.sessionID,
              let epoch = treadmillTelemetryConnectionEpoch else { return }
        telemetryV2Coordinator.captureStopAttempt(
            sessionID: sessionID, attemptID: attemptID, decisionID: chain.decisionID,
            connectionEpoch: epoch, observationWindow: .seconds(StopObservationPolicy.observationWindow),
            attemptedMonotonic: attemptedMonotonic
        )
    }

    private func makeTreadmillDecision(
        source: TreadmillControlDecisionSource,
        intent: TreadmillControlDecisionIntent,
        heartRateInputs: [HeartRateCausalReference] = [],
        occurredAt: Date = Date()
    ) -> TreadmillControlDecisionEvidence? {
        guard let connectionEpoch = treadmillTelemetryConnectionEpoch else { return nil }
        return TreadmillControlDecisionEvidence(
            decisionID: DecisionID(),
            source: source,
            intent: intent,
            heartRateInputs: heartRateInputs,
            occurredAt: occurredAt,
            connectionEpoch: connectionEpoch
        )
    }

    private func observeTreadmillDecision(
        _ decision: TreadmillControlDecisionEvidence?
    ) {
        guard let decision else { return }
        observeTreadmillTelemetry(.decision(decision))
    }

    private func treadmillCommandRequest(
        kind: CommandKind,
        decision: TreadmillControlDecisionEvidence? = nil,
        commandID: CommandID = CommandID()
    ) -> TreadmillCommandTelemetryRequest {
        TreadmillCommandTelemetryRequest(
            sessionID: activeTelemetryV2SessionID,
            commandID: commandID,
            decisionID: decision?.decisionID,
            kind: kind
        )
    }

    private func treadmillSetSpeedCommandKind(_ kmh: Double) -> CommandKind {
        let commandedSpeed: CommandedSpeed
        switch treadmillProtocol {
        case .walkingPad:
            commandedSpeed = TreadmillCommandedSpeedRepresentation.walkingPad(
                rawControllerTenths: clampSpeedTenths(kmh)
            )
        case .ftms:
            let raw = UInt16(max(0, min(65_535, (kmh * 100.0).rounded())))
            commandedSpeed = TreadmillCommandedSpeedRepresentation.ftms(
                rawHundredthsKmh: raw
            )
        case .fitShow:
            let raw = UInt8(max(0, min(250, Int((kmh * 10.0).rounded()))))
            commandedSpeed = TreadmillCommandedSpeedRepresentation.fitShow(
                rawTenthsKmh: raw
            )
        case .unknown:
            commandedSpeed = .init(nativeValue: kmh, nativeUnit: .unknown)
        }
        return .setSpeed(commandedSpeed)
    }

    private func treadmillUnitsTruthEvidence() -> TreadmillUnitsTruth? {
        guard let currentEpoch = treadmillTelemetryConnectionEpoch else { return nil }
        guard controllerUnitsTruth.connectionEpoch == currentEpoch.rawValue else {
            return .notRead(connectionEpoch: currentEpoch)
        }
        switch controllerUnitsTruth.status {
        case .notRead:
            return .notRead(connectionEpoch: currentEpoch)
        case .invalidChecksum:
            return .invalidChecksum(connectionEpoch: currentEpoch)
        case .malformed:
            return .malformed(connectionEpoch: currentEpoch)
        case .valid:
            guard let observedAt = controllerUnitsTruth.observedAt else {
                return .malformed(connectionEpoch: currentEpoch)
            }
            switch controllerUnitsTruth.units {
            case .metric:
                return .valid(
                    unit: .kilometresPerHour,
                    connectionEpoch: currentEpoch,
                    observedAt: observedAt
                )
            case .imperial:
                return .valid(
                    unit: .milesPerHour,
                    connectionEpoch: currentEpoch,
                    observedAt: observedAt
                )
            case .unknown:
                return .unknown(connectionEpoch: currentEpoch)
            }
        }
    }

    private func observeTreadmillProviderObservation(
        _ observation: TreadmillProviderObservation,
        unitsTruth: TreadmillUnitsTruth? = nil,
        recordedAt: Date = Date()
    ) -> TreadmillObservationEvidence {
        let evidence = treadmillObservationNormalizer.normalize(
            observation,
            unitsTruth: unitsTruth,
            observationID: ObservationID(),
            recordedAt: recordedAt
        )
        latestTreadmillObservationEvidence = evidence
        observeTreadmillTelemetry(.observation(evidence))
        return evidence
    }

    private func walkingPadTelemetryDeviceState(
        status: BLETransportCodec.WalkingPadStatus
    ) -> TreadmillDeviceState {
        if status.speedRawTenths > 0 { return .moving }
        if StopObservationPolicy.acceptedNonRunningStates.contains(status.beltState) {
            return .stopped
        }
        return .unknown
    }

    private func observeCurrentStopTruth(
        lifecycle: StopObservationLifecycle,
        evaluation: StopObservationEvaluation,
        evaluatedAt: Date
    ) {
        guard let connectionEpoch = treadmillTelemetryConnectionEpoch,
              lifecycle.context.connectionEpoch == connectionEpoch.rawValue else {
            return
        }
        let latest = lifecycle.observations.last
        let factualObservation = latestTreadmillObservationEvidence.flatMap { observation in
            observation.protocolKind == .walkingPad
                && observation.connectionEpoch == connectionEpoch
                && observation.receivedAt == latest?.observedAt
                ? observation
                : nil
        }
        let conclusion: StopEvidenceConclusion = evaluation.isConfirmed
            ? factualObservation.map {
                .confirmedByFreshFactualObservation($0.observationID)
            } ?? .unconfirmed(reason: "confirmed_predicate_without_correlated_observation_id")
            : .unconfirmed(reason: lifecycle.finalReason ?? evaluation.reason)
        observeTreadmillTelemetry(
            .stopEvidence(
                TreadmillStopTruthEvidence(
                    stopAttemptID: lifecycle.attemptID,
                    decisionID: activeTreadmillStopTelemetryChain?.decisionID,
                    commandID: activeTreadmillStopTelemetryChain?.commandID,
                    observationID: factualObservation?.observationID,
                    connectionEpoch: connectionEpoch,
                    protocolKind: .walkingPad,
                    conclusion: conclusion,
                    rawSpeedTenths: latest?.speedRawTenths,
                    rawDeviceState: latest?.state,
                    checksumValid: latest?.checksumValid,
                    observationReceivedAt: latest?.observedAt,
                    evaluatedAt: evaluatedAt
                )
            ), sessionID: activeTreadmillStopTelemetryChain?.sessionID
        )
    }

    private func observeHeartRateDelivery(
        _ observation: HeartRateProviderObservation,
        recordedAt: Date
    ) {
        publishHeartRateNormalization(
            normalizeHeartRateDelivery(observation, recordedAt: recordedAt)
        )
    }

    private func normalizeHeartRateDelivery(
        _ observation: HeartRateProviderObservation,
        recordedAt: Date
    ) -> HeartRateNormalizationResult {
        heartRateObservationNormalizer.normalize(
            observation,
            canonicalObservationID: HeartRateCanonicalObservationID(),
            deliveryID: HeartRateDeliveryID(),
            recordedAt: recordedAt
        )
    }

    private func publishHeartRateNormalization(
        _ result: HeartRateNormalizationResult
    ) {
        latestHeartRateDelivery = result.delivery
        attachTelemetryDeliveryToLatestHrTrendSample(result.delivery)
        _ = heartRateTelemetrySink?.observeHeartRate(result)
    }

    private func persistQualifyingNativeHeartRateBeforeMotion() {
        guard let result = pendingNativePreflightHeartRate else { return }
        pendingNativePreflightHeartRate = nil
        let disposition = heartRateTelemetrySink?.observeHeartRate(result) ?? .unavailable
        guard disposition == .accepted else {
            latestHeartRateDelivery = nil
            return
        }

        latestHeartRateDelivery = result.delivery
        let sampleDate = result.canonicalObservation?.measuredAt
            ?? result.delivery.receivedAt
        recordHrSample(result.delivery.beatsPerMinute, at: sampleDate)
        attachTelemetryDeliveryToLatestHrTrendSample(result.delivery)
        observeHeartRateControlUse(HeartRateControlUseEvidence(
            kind: .speedDecision,
            inputs: [result.delivery.causalReference],
            occurredAt: Date()
        ))
    }

    private func makeHeartRateControlUseEvidence(
        trendUsed: Bool,
        occurredAt: Date
    ) -> HeartRateControlUseEvidence? {
        var inputs: [HeartRateCausalReference]
        if trendUsed {
            inputs = hrTrendSamples.compactMap { $0.telemetryDelivery?.causalReference }
        } else {
            inputs = latestHeartRateDelivery.map { [$0.causalReference] } ?? []
        }
        if let latest = latestHeartRateDelivery?.causalReference,
           !inputs.contains(latest)
        {
            inputs.append(latest)
        }
        guard !inputs.isEmpty else { return nil }
        return HeartRateControlUseEvidence(
            kind: .speedDecision,
            inputs: inputs,
            occurredAt: occurredAt
        )
    }

    private func observeHeartRateControlUse(_ evidence: HeartRateControlUseEvidence?) {
        guard let evidence else { return }
        _ = heartRateTelemetrySink?.observeControlUse(evidence)
    }

    private func observeSemanticHeartRateDecision(
        action: ControlAction,
        reason: ControlDecisionReason,
        heartRateInputs: [HeartRateCausalReference],
        prediction: HeartRatePredictionSnapshot? = nil,
        occurredAt: Date
    ) {
        _ = telemetryV2Coordinator.observeHeartRateControlDecision(
            targetBeatsPerMinute: UInt16(clamping: activeHRControlTargetBPM),
            action: action,
            reason: reason,
            heartRateInputs: heartRateInputs,
            prediction: prediction,
            occurredAt: occurredAt
        )
    }

    private func currentHrTrendBpmPerSecond() -> Double? {
        guard hrTrendSamples.count >= hrTrendMinSamples,
              let first = hrTrendSamples.first,
              let last = hrTrendSamples.last else { return nil }
        let span = last.date.timeIntervalSince(first.date)
        guard span >= hrTrendMinWindowSeconds else { return nil }
        let t0 = first.date
        var sumT = 0.0
        var sumY = 0.0
        var sumTT = 0.0
        var sumTY = 0.0
        for sample in hrTrendSamples {
            let t = sample.date.timeIntervalSince(t0)
            sumT += t
            sumY += sample.smoothedBPM
            sumTT += t * t
            sumTY += t * sample.smoothedBPM
        }
        let n = Double(hrTrendSamples.count)
        let denom = (n * sumTT) - (sumT * sumT)
        guard denom > 0.0001 else { return nil }
        let slope = (n * sumTY - sumT * sumY) / denom
        return max(-hrTrendSlopeMaxBpmPerSecond, min(hrTrendSlopeMaxBpmPerSecond, slope))
    }

    private func persistHealthKitWorkoutAssociationWithTelemetryV2(
        sessionID: SessionID,
        workoutIdentifier: UUID
    ) async -> Bool {
        do {
            try await telemetryV2Coordinator.associateHealthKitWorkout(
                sessionID: sessionID,
                workoutIdentifier: workoutIdentifier
            )
            return true
        } catch {
            telemetryV2WorkoutHistoryState = .failed(
                "HealthKit linkage failed: \(error.localizedDescription)"
            )
            return false
        }
    }

    // KS-F0 protocol: F7 A2 <cmd> <val> <crc> FD, crc = sum(bytes[1..3]) % 256
    private func buildCmdPacket(cmd: UInt8, value: UInt8) -> Data {
        var bytes: [UInt8] = [0xF7, 0xA2, cmd, value, 0xFF, 0xFD]
        let crc = (UInt16(0xA2) + UInt16(cmd) + UInt16(value)) & 0xFF
        bytes[4] = UInt8(crc)
        return Data(bytes)
    }

    private func scheduleWrite(
        _ data: Data,
        label: String,
        after delay: TimeInterval,
        requiresControlReadiness: Bool = false,
        telemetryRequest: TreadmillCommandTelemetryRequest? = nil,
        stopAttemptID: UUID? = nil
    ) {
        let epoch = commandQueueEpoch
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let cancelled = self.commandQueueEpoch != epoch
            defer { self.completeScheduledStopEffect(attemptID: stopAttemptID, cancelled: cancelled) }
            guard self.commandQueueEpoch == epoch else { return }
            self.writeCommand(
                data,
                label: label,
                requiresControlReadiness: requiresControlReadiness,
                telemetryRequest: telemetryRequest
            )
        }
    }


    // MARK: - CBPeripheralDelegate
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === connectedPeripheral,
              peripheral.identifier == connectedPeripheralId else {
            return
        }
        if error != nil {
            invalidateTreadmillControlReadinessEvidence(includingProtocol: true)
            return
        }
        guard let services = peripheral.services, !services.isEmpty else {
            invalidateTreadmillControlReadinessEvidence(includingProtocol: true)
            return
        }
        let discoveredUuids = Set(services.map { $0.uuid })
        let selected = selectTreadmillProtocol(from: discoveredUuids)
        treadmillProtocolService = services.first { service in
            switch selected {
            case .walkingPad: return service.uuid == serviceFE00
            case .ftms: return service.uuid == serviceFTMS
            case .fitShow: return service.uuid == serviceFitShow
            case .unknown: return false
            }
        }
        treadmillProtocolConnection = currentTreadmillControlConnection
        if treadmillProtocol != selected {
            treadmillProtocol = selected

            recomputeHrStartAllowed()
        }
        recomputeTreadmillControlReadiness()
        for s in services {
            if supportedServiceUuids.contains(s.uuid) {
                peripheral.discoverCharacteristics(nil, for: s)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === connectedPeripheral,
              peripheral.identifier == connectedPeripheralId,
              service === treadmillProtocolService else {
            return
        }
        telemetryV2Coordinator.invalidateStopTail()
        if error != nil {
            invalidateTreadmillControlReadinessEvidence()
            return
        }
        guard let chars = service.characteristics else {
            invalidateTreadmillControlReadinessEvidence()
            return
        }
        commandCharacteristic = nil
        commandCharacteristicConnection = nil
        notifyCharacteristic = nil
        notifyCharacteristicConnection = nil
        characteristicConnections.removeAll()
        extraNotifyCharacteristics.removeAll()

        switch treadmillProtocol {
        case .walkingPad:
            guard service.uuid == serviceFE00 else { return }
            let notify = chars.first(where: { $0.uuid == charFE01 && ($0.properties.contains(.notify) || $0.properties.contains(.indicate)) })
            let write = chars.first(where: { $0.uuid == charFE02 && ($0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)) })

            if let n = notify {
                notifyCharacteristic = n
                registerCurrentCharacteristic(n)
                stopObservationStreamID = UUID()
                subscribe(peripheral, to: n, label: "FE01")
            } else {
            }
            if let w = write {
                commandCharacteristic = w
                registerCurrentCharacteristic(w)
                commandCharacteristicConnection = currentTreadmillControlConnection
                requestInitialControllerUnitsTruthIfReady()
            } else {
            }

        case .ftms:
            guard service.uuid == serviceFTMS else { return }
            if let dataChar = chars.first(where: { $0.uuid == ftmsCharTreadmillData && ($0.properties.contains(.notify) || $0.properties.contains(.indicate)) }) {
                notifyCharacteristic = dataChar
                registerCurrentCharacteristic(dataChar)
                subscribe(peripheral, to: dataChar, label: "FTMS treadmill data")
            } else {
            }
            if let statusChar = chars.first(where: { $0.uuid == ftmsCharMachineStatus && ($0.properties.contains(.notify) || $0.properties.contains(.indicate)) }) {
                registerCurrentCharacteristic(statusChar)
                subscribe(peripheral, to: statusChar, label: "FTMS machine status")
            }
            if let cpChar = chars.first(where: {
                $0.uuid == ftmsCharControlPoint
                    && $0.properties.contains(.write)
                    && ($0.properties.contains(.notify) || $0.properties.contains(.indicate))
            }) {
                commandCharacteristic = cpChar
                registerCurrentCharacteristic(cpChar)
                subscribe(peripheral, to: cpChar, label: "FTMS control point indications")
            } else {
            }
            if !ftmsDidReadSupportedSpeedRange {
                if let rangeChar = chars.first(where: { $0.uuid == ftmsCharSupportedSpeedRange && $0.properties.contains(.read) }) {
                    ftmsDidReadSupportedSpeedRange = true
                    registerCurrentCharacteristic(rangeChar)
                    peripheral.readValue(for: rangeChar)
                } else if chars.contains(where: { $0.uuid == ftmsCharSupportedSpeedRange }) {
                    ftmsDidReadSupportedSpeedRange = true
                }
            }

        case .fitShow:
            guard service.uuid == serviceFitShow else { return }
            if let rx = chars.first(where: { $0.uuid == fitShowCharRx && ($0.properties.contains(.notify) || $0.properties.contains(.indicate)) }) {
                notifyCharacteristic = rx
                registerCurrentCharacteristic(rx)
                subscribe(peripheral, to: rx, label: "FitShow RX")
            } else {
            }
            if let tx = chars.first(where: { $0.uuid == fitShowCharTx && ($0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)) }) {
                commandCharacteristic = tx
                registerCurrentCharacteristic(tx)
                commandCharacteristicConnection = currentTreadmillControlConnection
                if !fitShowDidRequestInitialStatus {
                    fitShowDidRequestInitialStatus = true
                    let status = buildFitShowFrame(cmd: 0x51, subcmd: nil, payload: Data())
                    scheduleWrite(status, label: "FitShow STATUS", after: 0.6)
                }
            }

        case .unknown:
            // No-op. We only support known treadmill protocols.
            return
        }
        recomputeTreadmillControlReadiness()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === connectedPeripheral,
              peripheral.identifier == connectedPeripheralId else {
            return
        }
        let isRequiredTelemetry = characteristic === notifyCharacteristic
        let isFtmsControlPoint = treadmillProtocol == .ftms
            && characteristic === commandCharacteristic
            && characteristic.uuid == ftmsCharControlPoint
        guard (isRequiredTelemetry || isFtmsControlPoint),
              isCurrentCharacteristicCallback(characteristic) else {
            return
        }
        if error != nil || !characteristic.isNotifying {
            if treadmillProtocol == .ftms { failFTMSControl() }
            telemetryV2Coordinator.invalidateStopTail()
        }
        if error != nil {
            if isRequiredTelemetry { notifyCharacteristicConnection = nil }
            if isFtmsControlPoint { commandCharacteristicConnection = nil }
            recomputeTreadmillControlReadiness()
            return
        }
        if isRequiredTelemetry {
            notifyCharacteristicConnection = characteristic.isNotifying
                ? currentTreadmillControlConnection
                : nil
        }
        if isFtmsControlPoint {
            commandCharacteristicConnection = characteristic.isNotifying
                ? currentTreadmillControlConnection
                : nil
        }
        recomputeTreadmillControlReadiness()
        if treadmillProtocol == .walkingPad,
           characteristic.uuid == charFE01,
           characteristic.isNotifying {
            requestInitialControllerUnitsTruthIfReady()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === connectedPeripheral,
              peripheral.identifier == connectedPeripheralId,
              isCurrentCharacteristicCallback(characteristic) else {
            return
        }
        if error != nil {
            if treadmillProtocol == .ftms { failFTMSControl() }
            return
        }
        guard let data = characteristic.value else { return }
        let isControllerUnitsResponse = treadmillProtocol == .walkingPad
            && data.count >= 2
            && data[0] == 0xF8
            && data[1] == 0xA6
        let unitsResponseContext: ControllerUnitsResponseContext?
        if isControllerUnitsResponse {
            guard let context = controllerUnitsResponseContext(
                peripheral: peripheral,
                characteristic: characteristic
            ) else {
                return
            }
            unitsResponseContext = context
        } else {
            unitsResponseContext = nil
        }
        let now = Date()
#if STOP_TRUTH_EXPERIMENT_CAPABILITY
        let experimentReceiveUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
#endif
        lastNotifyAt = now
        let isLegacyAcknowledgementSignal = shouldTreatAsCommandAck(
            characteristic: characteristic,
            data: data
        )
        let legacyAcknowledgementDecision = LegacyAcknowledgementObservationSeam.evaluate(
            isAwaitingAcknowledgement: lastCommandAwaitingAck,
            sentAt: lastCommandSentAt,
            receivedAt: now,
            timeout: commandAckTimeoutSeconds,
            isQualifyingSignal: isLegacyAcknowledgementSignal,
            protocolKind: treadmillTelemetryProtocolKind,
            connectionEpoch: treadmillTelemetryConnectionEpoch,
            recordedAt: Date()
        )
        defer {
            if let observation = legacyAcknowledgementDecision.observation {
                observeTreadmillTelemetry(
                    .acknowledgement(observation)
                )
            }
        }
        if legacyAcknowledgementDecision.isAcceptedByLegacyRuntime {
            lastCommandAwaitingAck = false
            lastCommandAckedAt = now
        }

        switch treadmillProtocol {
        case .walkingPad:
            if isControllerUnitsResponse {
                let observedAt = now
                let params = BLETransportCodec.parseWalkingPadParams(data)
                guard let responseContext = unitsResponseContext else { return }
                DispatchQueue.main.async {
                    guard responseContext.matches(
                        currentPeripheralID: self.connectedPeripheralId,
                        currentConnectionEpoch: self.controllerUnitsConnectionEpoch,
                        currentNotifyCharacteristicID: self.notifyCharacteristic.map(ObjectIdentifier.init)
                    ) else {
                        return
                    }
                    if let params {
                        self.controllerUnitsTruthTracker.record(
                            params,
                            for: responseContext.connectionEpoch,
                            at: observedAt
                        )
#if STOP_TRUTH_EXPERIMENT_CAPABILITY
                        if let experimentContext = self.currentStopTruthExperimentContext() {
                            self.stopTruthExperimentController?.recordA6Bounds(
                                params: params,
                                context: experimentContext,
                                receivedUptimeNanoseconds: experimentReceiveUptimeNanoseconds,
                                receivedWallDate: observedAt
                            )
                        }
#endif
                    } else {
                        self.controllerUnitsTruthTracker.recordMalformed(
                            rawHex: self.hex(data),
                            for: responseContext.connectionEpoch,
                            at: observedAt
                        )
#if STOP_TRUTH_EXPERIMENT_CAPABILITY
                        if let experimentContext = self.currentStopTruthExperimentContext() {
                            self.stopTruthExperimentController?.recordMalformedA6(
                                rawHex: self.hex(data),
                                context: experimentContext,
                                receivedUptimeNanoseconds: experimentReceiveUptimeNanoseconds,
                                receivedWallDate: observedAt
                            )
                        }
#endif
                    }
                    self.controllerUnitsTruth = self.controllerUnitsTruthTracker.state
                    self.recomputeHrStartAllowed()
                    if let truth = self.treadmillUnitsTruthEvidence() {
                        self.observeTreadmillTelemetry(
                            .unitsTruth(
                                TreadmillUnitsTruthEvidence(
                                    truth: truth,
                                    observedAt: observedAt
                                )
                            )
                        )
                    }
                }
            } else if let status = BLETransportCodec.parseWalkingPadStatus(data) {
                let hexStr = hex(data)
                DispatchQueue.main.async {
                    self.deviceReportedSpeedKmh = status.speedKmh
                    self.deviceReportedAppSpeedKmh = status.appSpeedKmh
                    self.deviceReportedState = status.beltState
                    self.deviceReportedManualMode = status.manualMode
                    self.deviceReportedTimeSeconds = status.timeSeconds
                    self.deviceReportedDistance10m = status.distance10m
                    self.deviceReportedSteps = status.steps
                    self.deviceReportedButton = status.lastButton
                    self.deviceReportedChecksumOk = status.checksumOk
                    self.deviceReportedRawHex = hexStr
                    self.publishTrainingUITreadmillSpeedIfNeeded()
#if STOP_TRUTH_EXPERIMENT_CAPABILITY
                    if let experimentContext = self.stopTruthExperimentObservationContext(
                        peripheral: peripheral,
                        characteristic: characteristic
                    ) {
                        self.stopTruthExperimentController?.recordFE01(
                            rawHex: hexStr,
                            status: status,
                            context: experimentContext,
                            receivedUptimeNanoseconds: experimentReceiveUptimeNanoseconds,
                            receivedWallDate: now
                        )
                    }
#endif
                    self.recordStopObservation(
                        status: status,
                        peripheral: peripheral,
                        characteristic: characteristic,
                        observedAt: now
                    )
                    if peripheral.identifier == self.connectedPeripheralId,
                       characteristic === self.notifyCharacteristic,
                       let connectionEpoch = self.treadmillTelemetryConnectionEpoch {
                        _ = self.observeTreadmillProviderObservation(
                            .walkingPad(
                                speedRawTenths: Int(status.speedRawTenths),
                                rawState: status.beltState,
                                deviceState: self.walkingPadTelemetryDeviceState(status: status),
                                checksumValid: status.checksumOk,
                                connectionEpoch: connectionEpoch,
                                receivedAt: now
                            ),
                            unitsTruth: self.treadmillUnitsTruthEvidence()
                        )
                        if let lifecycle = self.stopObservationLifecycle {
                            self.observeCurrentStopTruth(
                                lifecycle: lifecycle,
                                evaluation: lifecycle.currentEvaluation(at: Date()),
                                evaluatedAt: Date()
                            )
                        }
                        self.finalizeCompletedStopIfReady()
                    }
                }

            } else {
#if STOP_TRUTH_EXPERIMENT_CAPABILITY
                if data.count >= 2,
                   data[0] == 0xF8,
                   data[1] == 0xA2,
                   let experimentContext = stopTruthExperimentObservationContext(
                    peripheral: peripheral,
                    characteristic: characteristic
                   ) {
                    stopTruthExperimentController?.recordInvalidFE01(
                        rawHex: hex(data),
                        context: experimentContext,
                        reason: "malformed_fe01",
                        receivedUptimeNanoseconds: experimentReceiveUptimeNanoseconds,
                        receivedWallDate: now
                    )
                }
#endif
            }

        case .ftms:
            if characteristic.uuid == ftmsCharSupportedSpeedRange, let range = parseFtmsSupportedSpeedRange(data) {
                self.treadmillMinSpeedKmh = range.minSpeedKmh
                self.treadmillMaxSpeedKmh = range.maxSpeedKmh
                self.treadmillSpeedIncrementKmh = range.minIncrementKmh

                // Clamp any already-chosen targets to avoid "infinite increase" loops.
                let maxSpeed = self.treadmillSpeedBoundsSnapshot().max
                if self.desiredSpeedKmh > maxSpeed { self.desiredSpeedKmh = maxSpeed }
                if self.deviceTargetSpeedKmh > maxSpeed { self.deviceTargetSpeedKmh = maxSpeed }

            } else if characteristic.uuid == ftmsCharTreadmillData, let parsed = parseFtmsTreadmillData(data) {
                self.deviceReportedSpeedKmh = parsed.instantaneousSpeedKmh
                self.deviceReportedAppSpeedKmh = parsed.instantaneousSpeedKmh
                self.deviceReportedState = parsed.isMoving ? 1 : 0
                self.deviceReportedRawHex = ""
                self.publishTrainingUITreadmillSpeedIfNeeded()
                if peripheral.identifier == self.connectedPeripheralId,
                   characteristic.uuid == self.ftmsCharTreadmillData,
                   let connectionEpoch = self.treadmillTelemetryConnectionEpoch {
                    _ = self.observeTreadmillProviderObservation(
                        .ftms(
                            speedRawHundredthsKmh: Int(
                                parsed.instantaneousSpeedRawHundredthsKmh
                            ),
                            rawState: parsed.isMoving ? 1 : 0,
                            deviceState: parsed.isMoving ? .moving : .stopped,
                            connectionEpoch: connectionEpoch,
                            receivedAt: now
                        )
                    )
                }

            } else if characteristic.uuid == ftmsCharControlPoint, let resp = parseFtmsControlPointResponse(data) {
                guard characteristic === commandCharacteristic,
                      let connection = currentTreadmillControlConnection,
                      let succeeded = ftmsControlState.receive(
                        opcode: resp.requestedOpcode, resultCode: resp.resultCode,
                        connection: connection
                      ) else { return }
                if succeeded {
                    processCommandQueue()
                } else {
                    observeTreadmillTelemetry(.commandFailed(TreadmillCommandFailureObservation(
                        commandID: nil, decisionID: nil, attemptID: nil,
                        connectionEpoch: treadmillTelemetryConnectionEpoch, occurredAt: now,
                        reason: .other("ftms_response_\(resp.requestedOpcode)_\(resp.resultCode)")
                    )))
                    if ftmsControlState.isBlocked { failFTMSControl() }
                    else { handleFTMSProcedureRejection(opcode: resp.requestedOpcode) }
                }
            } else if characteristic.uuid == ftmsCharMachineStatus,
                      BLETransportCodec.ftmsControlPermissionWasLost(data) {
                failFTMSControl()

            }

        case .fitShow:
            if let frame = parseFitShowFrame(data) {
                applyFitShowFrame(
                    frame,
                    peripheral: peripheral,
                    characteristic: characteristic,
                    receivedAt: now
                )
            }

        case .unknown:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === connectedPeripheral,
              peripheral.identifier == connectedPeripheralId,
              characteristic === commandCharacteristic,
              isCurrentCharacteristicCallback(characteristic) else {
            return
        }
        if peripheral.identifier == connectedPeripheralId,
           let connectionEpoch = treadmillTelemetryConnectionEpoch {
            observeTreadmillTelemetry(
                .writeResult(
                    LegacyWriteResultObservation(
                        protocolKind: treadmillTelemetryProtocolKind,
                        connectionEpoch: connectionEpoch,
                        occurredAt: Date(),
                        status: error == nil ? .succeeded : .failed
                    )
                )
            )
        }
        if treadmillProtocol == .ftms, error != nil { failFTMSControl() }
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard peripheral === connectedPeripheral,
              peripheral.identifier == connectedPeripheralId,
              let selectedService = treadmillProtocolService,
              invalidatedServices.contains(where: { $0 === selectedService }) else {
            return
        }
        telemetryV2Coordinator.invalidateStopTail()
        treadmillProtocolService = nil
        commandCharacteristic = nil
        notifyCharacteristic = nil
        extraNotifyCharacteristics.removeAll()
        characteristicConnections.removeAll()
        invalidateTreadmillControlReadinessEvidence(includingProtocol: true)
    }
}
