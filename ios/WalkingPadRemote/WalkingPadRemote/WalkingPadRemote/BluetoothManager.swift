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
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

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
    private var ftmsHasControl: Bool = false
    private var ftmsControlRequestInFlight: Bool = false
    private var ftmsControlRequestConnection: TreadmillControlConnectionIdentity?
    private var ftmsDidReadSupportedSpeedRange: Bool = false
    private var fitShowDidRequestInitialStatus: Bool = false
    private var shouldBeScanning: Bool = false
    private var discoveredMap: [UUID: CBPeripheral] = [:]
    private var autoConnectPendingWorkItem: DispatchWorkItem?
    private var knownDiscoveryGraceWorkItem: DispatchWorkItem?
    private var knownDiscoveryGraceCompleted = false
    private var autoConnectRetryPolicy = AutoConnectRetryPolicy()
    private var connectTimeoutWorkItem: DispatchWorkItem?
#if canImport(WatchConnectivity)
    private var wcSession: WCSession?
    private var pendingWatchCommand: String? = nil
#endif
    private var connectingPeripheralId: UUID? = nil
    private var connectingPeripheral: CBPeripheral? = nil
    private var cancellingConnectionPeripheralId: UUID? = nil
    private var connectingAttemptIsAutomatic = false
    private var controllerUnitsConnectionEpoch: UUID? = nil
    private var controllerUnitsTruthTracker = ControllerUnitsTruthTracker()
    private var lastControllerUnitsQueryAt: Date? = nil
    private var lastControllerUnitsQueryTrigger: String? = nil
    private var stopObservationStreamID: UUID? = nil
    private var stopObservationLifecycle: StopObservationLifecycle? = nil
    private var stopObservationCheckpointWorkItems: [DispatchWorkItem] = []
    private var stopObservationFreshnessWorkItem: DispatchWorkItem?
    private var stopObservationOwnsTrainingLog = false
    private struct UnavailableStopAttempt {
        let id: UUID
        let source: String
        let attemptedAt: Date
        let ownsTrainingLog: Bool
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
    @Published var discoveredPeripherals: [DiscoveredPeripheral] = []
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
    private let workoutHistoryStoreKey = "workout_history_v1"
    private var isLoadingHrSettings: Bool = false
    private var autoConnectSuppressed: Bool = false
    private var lastSuccessfulPeripheralID: UUID? = nil
    private var hrSessionTotalSeconds: Int = 0
    private var hrControlStartedBelt: Bool = false
    private var cooldownRuntimeState: CooldownRuntimeEngine.State? = nil
    @Published var hrCooldownMinSpeed: Double = 3.5 { didSet { saveHrSettingsIfNeeded() } }
    @Published var hrCooldownTargetBpm: Int = HRSettingsDefaults.defaultCooldownTargetBpm { didSet { saveHrSettingsIfNeeded() } }
    @Published var hrCooldownMaxMinutes: Int = 5 { didSet { saveHrSettingsIfNeeded() } }
    private let hrCooldownHoldSeconds: Int = 20
    private var hrCooldownMaxSeconds: Int { hrCooldownMaxMinutes * 60 }
    private let hrMaxSessionMinutes: Int = 120
    private var manualModeSet: Bool = false
    private var hrControlStartedAt: Date? = nil
    private let hrStartGraceSeconds: Int = 15
    private var hrAverageSum: Int = 0
    private var hrAverageCount: Int = 0
    private var hrWorkoutRecorded: Bool = false
    private let workoutMinSaveMinutes: Int = 5
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
    private var pendingHealthkitWorkoutUUID: String? = nil
    private var pendingHealthkitWorkoutProfileID: UUID? = nil
    private var activeTelemetryV2SessionID: SessionID? = nil
    private var pendingHealthkitTelemetryV2SessionID: SessionID? = nil
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
    private let legacyWatchHeartRateSource = HeartRateProviderIdentity(
        kind: .legacyWatchWorkoutStream,
        stableLocalKey: "legacyWatchWorkoutStream"
    )
    private var heartRateObservationNormalizer = HeartRateObservationNormalizer()
    private var heartRateTelemetrySink: (any HeartRateTelemetrySink)?
    private var latestHeartRateDelivery: HeartRateDeliveryEvidence?
    private var treadmillObservationNormalizer = TreadmillObservationNormalizer(
        controllerUnitsFreshnessInterval: ControllerUnitsSafetyPolicy.freshnessInterval
    )
    private var treadmillTelemetrySink: (any TreadmillTelemetrySink)?
    @Published private(set) var telemetryV2StatusText: String = "idle"
    @Published private(set) var telemetryV2WriterHealthSnapshot: TelemetryV2WriterHealthSnapshot = .idle
    @Published private(set) var legacyShadowWriterStatusText: String = "idle"
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
    private struct TreadmillCommandTelemetryRequest {
        let commandID: CommandID
        let decisionID: DecisionID?
        let kind: CommandKind
    }
    private struct TreadmillStopTelemetryChain {
        let decisionID: DecisionID
        let commandID: CommandID?
    }
    private var activeTreadmillStopTelemetryChain: TreadmillStopTelemetryChain?
    private var expectedSpeedKmh: Double? = nil
    private var expectedSpeedSetAt: Date? = nil
    private var expectedSpeedSource: String? = nil
    private var lastLoggedActualSpeedKmh: Double? = nil
    private let trainingLogsDirectoryName = "TrainingLogs"
    private let trainingLogMaxFiles = 40
    private let trainingLogQueue = DispatchQueue(label: "BluetoothManager.trainingLog")
    private let trainingLogTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()

    var activeUserProfileLabel: String {
        activeUserProfile?.label ?? "Пользователь 1"
    }

    private var activeUserProfile: UserProfile? {
        guard let activeUserProfileID else { return userProfiles.first }
        return userProfiles.first(where: { $0.id == activeUserProfileID }) ?? userProfiles.first
    }
    private let trainingLogIsoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    struct TrainingLogsCsvExport {
        let csvURL: URL
        let rowCount: Int
        let scope: TrainingLogCsvExportScope
        fileprivate let sourceFiles: [URL]
    }
    private var trainingLogSessionId: String? = nil
    private var trainingLogFileURL: URL? = nil
    private var trainingLogFileHandle: FileHandle? = nil
    private var trainingLogsInventoryRefreshID = UUID()

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

    private struct WorkoutEntryDTO: Codable {
        let id: UUID
        let date: Date
        let beatsPerMeter: Double?
        let targetBpm: Int
        let durationSeconds: Int
        let avgBpm: Int
        let avgSpeedKmh: Double?
        let healthkitWorkoutUUID: String?
        let zoneSeconds: [Int]?

        enum CodingKeys: String, CodingKey {
            case id, date, beatsPerMeter, targetBpm, durationSeconds, avgBpm, avgSpeedKmh, healthkitWorkoutUUID, zoneSeconds
        }

        init(id: UUID, date: Date, beatsPerMeter: Double?, targetBpm: Int, durationSeconds: Int, avgBpm: Int, avgSpeedKmh: Double?, healthkitWorkoutUUID: String?, zoneSeconds: [Int]?) {
            self.id = id
            self.date = date
            self.beatsPerMeter = beatsPerMeter
            self.targetBpm = targetBpm
            self.durationSeconds = durationSeconds
            self.avgBpm = avgBpm
            self.avgSpeedKmh = avgSpeedKmh
            self.healthkitWorkoutUUID = healthkitWorkoutUUID
            self.zoneSeconds = zoneSeconds
        }

        init(from decoder: Swift.Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
            date = try container.decode(Date.self, forKey: .date)
            beatsPerMeter = try? container.decode(Double.self, forKey: .beatsPerMeter)
            targetBpm = try container.decode(Int.self, forKey: .targetBpm)
            durationSeconds = try container.decode(Int.self, forKey: .durationSeconds)
            avgBpm = (try? container.decode(Int.self, forKey: .avgBpm)) ?? 0
            avgSpeedKmh = try? container.decode(Double.self, forKey: .avgSpeedKmh)
            healthkitWorkoutUUID = try? container.decode(String.self, forKey: .healthkitWorkoutUUID)
            zoneSeconds = try? container.decode([Int].self, forKey: .zoneSeconds)
        }
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

    private var legacyFallbackProfileID: String? {
        sortedProfiles(userProfiles).first?.id.uuidString
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

    private func migrateLegacyProfileStoresIfNeeded(to profileID: UUID) {
        let defaults = UserDefaults.standard

        for baseKey in [hrSettingsStoreKey, zonePlanStoreKey, workoutHistoryStoreKey] {
            let scopedKey = profileScopedStoreKey(baseKey, profileID: profileID)
            guard defaults.object(forKey: scopedKey) == nil,
                  let legacyValue = defaults.object(forKey: baseKey) else {
                continue
            }
            defaults.set(legacyValue, forKey: scopedKey)
        }
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
        migrateLegacyProfileStoresIfNeeded(to: defaultProfile.id)
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

    private func makeHrSettingsDTO() -> HrSettingsDTO {
        HrSettingsDTO(
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
            cooldownMaxMinutes: hrCooldownMaxMinutes
        )
    }

    private func saveHrSettings(profileID: UUID) {
        guard let data = try? JSONEncoder().encode(makeHrSettingsDTO()) else { return }
        UserDefaults.standard.set(data, forKey: profileScopedStoreKey(hrSettingsStoreKey, profileID: profileID))
    }

    private func saveZonePlan(profileID: UUID) {
        let normalized = normalizeZonePlan(zonePlanMinutes)
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        UserDefaults.standard.set(data, forKey: profileScopedStoreKey(zonePlanStoreKey, profileID: profileID))
    }

    private func legacyShadowWorkoutEntry(from dto: WorkoutEntryDTO) -> LegacyShadowWorkoutEntry {
        LegacyShadowWorkoutEntry(
            id: dto.id,
            date: dto.date,
            beatsPerMeter: dto.beatsPerMeter,
            targetBpm: dto.targetBpm,
            durationSeconds: dto.durationSeconds,
            avgBpm: dto.avgBpm,
            avgSpeedKmh: dto.avgSpeedKmh,
            healthkitWorkoutUUID: dto.healthkitWorkoutUUID,
            zoneSeconds: dto.zoneSeconds
        )
    }

    private func workoutEntryDTO(from entry: LegacyShadowWorkoutEntry) -> WorkoutEntryDTO {
        WorkoutEntryDTO(
            id: entry.id,
            date: entry.date,
            beatsPerMeter: entry.beatsPerMeter,
            targetBpm: entry.targetBpm,
            durationSeconds: entry.durationSeconds,
            avgBpm: entry.avgBpm,
            avgSpeedKmh: entry.avgSpeedKmh,
            healthkitWorkoutUUID: entry.healthkitWorkoutUUID,
            zoneSeconds: entry.zoneSeconds
        )
    }

    private func loadLegacyShadowWorkoutHistory(profileID: UUID) -> [LegacyShadowWorkoutEntry] {
        let key = profileScopedStoreKey(workoutHistoryStoreKey, profileID: profileID)
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([WorkoutEntryDTO].self, from: data) else {
            return []
        }

        return list.map { legacyShadowWorkoutEntry(from: $0) }
    }

    private func saveLegacyShadowWorkoutHistory(
        _ entries: [LegacyShadowWorkoutEntry],
        profileID: UUID
    ) {
        // Compatibility-only parity evidence through #37; #36 owns mandatory removal.
        let list = entries.prefix(50).map { workoutEntryDTO(from: $0) }
        guard let data = try? JSONEncoder().encode(list) else {
            legacyShadowWriterStatusText = "failed: encode"
            appendLog("Legacy shadow writer failed: encode")
            return
        }
        let key = profileScopedStoreKey(workoutHistoryStoreKey, profileID: profileID)
        UserDefaults.standard.set(data, forKey: key)
        if UserDefaults.standard.data(forKey: key) == data {
            legacyShadowWriterStatusText = "ok"
        } else {
            legacyShadowWriterStatusText = "failed: persistence"
            appendLog("Legacy shadow writer failed: persistence")
        }
    }

    private func removeStoredData(for profileID: UUID) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: profileScopedStoreKey(hrSettingsStoreKey, profileID: profileID))
        defaults.removeObject(forKey: profileScopedStoreKey(zonePlanStoreKey, profileID: profileID))
        // Preserve legacy workout shadow evidence until the explicit #36 retirement.
    }

    private func loadActiveProfileScopedData() {
        loadHrSettings()
        loadZonePlan()
        loadLegacyShadowWorkoutHistory()
    }

    func selectUserProfile(id: UUID) {
        guard userProfiles.contains(where: { $0.id == id }) else { return }
        guard !shouldPresentActiveWorkout else {
            infoToastMessage = "Во время активной тренировки профиль переключать нельзя."
            return
        }
        guard activeUserProfileID != id else { return }

        saveHrSettingsIfNeeded()
        saveZonePlan()
        saveLegacyShadowWorkoutHistory()

        activeUserProfileID = id
        saveProfilesState()
        loadActiveProfileScopedData()
        refreshWorkoutHistoryFromV2(reset: true)
        refreshTrainingLogsInventory()
        appendLog("Active profile switched: \(activeUserProfileLabel)")
        infoToastMessage = "Активный профиль: \(activeUserProfileLabel)"
    }

    func createUserProfile(named rawLabel: String) {
        guard !shouldPresentActiveWorkout else {
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
        saveLegacyShadowWorkoutHistory()

        saveHrSettings(profileID: profile.id)
        saveZonePlan(profileID: profile.id)
        saveLegacyShadowWorkoutHistory([], profileID: profile.id)

        userProfiles = sortedProfiles(userProfiles + [profile])
        activeUserProfileID = profile.id
        saveProfilesState()
        loadActiveProfileScopedData()
        refreshWorkoutHistoryFromV2(reset: true)
        refreshTrainingLogsInventory()
        appendLog("Profile created: \(profile.label)")
        infoToastMessage = "Создан профиль: \(profile.label)"
    }

    func renameActiveUserProfile(to rawLabel: String) {
        guard !shouldPresentActiveWorkout else {
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
        appendLog("Profile renamed: \(label)")
        infoToastMessage = "Профиль переименован: \(label)"
    }

    func deleteActiveUserProfile() {
        guard !shouldPresentActiveWorkout else {
            infoToastMessage = "Во время активной тренировки профиль менять нельзя."
            return
        }
        guard let activeUserProfileID,
              userProfiles.count > 1 else {
            infoToastMessage = "Нельзя удалить единственный профиль."
            return
        }

        let deletedLabel = activeUserProfileLabel
        removeStoredData(for: activeUserProfileID)

        userProfiles = sortedProfiles(userProfiles.filter { $0.id != activeUserProfileID })
        self.activeUserProfileID = userProfiles.first?.id
        saveProfilesState()
        loadActiveProfileScopedData()
        refreshWorkoutHistoryFromV2(reset: true)
        refreshTrainingLogsInventory()
        appendLog("Profile deleted: \(deletedLabel)")
        infoToastMessage = "Профиль удалён: \(deletedLabel)"
    }

    private func loadLegacyShadowWorkoutHistory() {
        guard let activeUserProfileID else {
            legacyShadowWorkoutHistory = []
            return
        }
        legacyShadowWorkoutHistory = loadLegacyShadowWorkoutHistory(
            profileID: activeUserProfileID
        )
    }

    private func saveLegacyShadowWorkoutHistory() {
        guard let activeUserProfileID else { return }
        saveLegacyShadowWorkoutHistory(
            legacyShadowWorkoutHistory,
            profileID: activeUserProfileID
        )
    }

    private struct HrSettingsDTO: Codable {
        let targetBpm: Int
        let durationMinutes: Int
        let adaptiveStepEnabled: Bool
        let decisionIntervalSeconds: Int
        let speedStepKmh: Double
        let adaptiveDeadbandPercent: Double?
        let adaptiveDownLevel2StartPercent: Double?
        let adaptiveDownLevel3StartPercent: Double?
        let adaptiveDownLevel4StartPercent: Double?
        let adaptiveUpLevel2StartPercent: Double?
        let adaptiveUpLevel3StartPercent: Double?
        let adaptiveUpLevel4StartPercent: Double?
        let trendWindowSeconds: Double?
        let trendEmaAlpha: Double?
        let trendSlopeMaxBpmPerSecond: Double?
        let zone1Max: Int?
        let zone2Max: Int?
        let zone3Max: Int?
        let zone4Max: Int?
        let cooldownTargetBpm: Int?
        let cooldownMinSpeed: Double?
        let cooldownMaxMinutes: Int?
    }

    private func loadHrSettings() {
        isLoadingHrSettings = true
        applyDefaultHrSettings()

        defer {
            normalizeAdaptivePercentThresholdSettings()
            isLoadingHrSettings = false
            normalizeZoneBounds()
            sendHrTargetBpm()
        }

        guard let activeUserProfileID else { return }
        let key = profileScopedStoreKey(hrSettingsStoreKey, profileID: activeUserProfileID)
        guard let data = UserDefaults.standard.data(forKey: key),
              let dto = try? JSONDecoder().decode(HrSettingsDTO.self, from: data) else {
            return
        }

        hrTargetBPM = max(60, min(220, dto.targetBpm))
        hrDurationMinutes = max(1, min(120, dto.durationMinutes))
        hrAdaptiveStepEnabled = dto.adaptiveStepEnabled
        hrDecisionIntervalSeconds = max(1, min(60, dto.decisionIntervalSeconds))
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

    // Watch / HR
    @Published var heartRateBPM: Int = 0
    @Published var lastKnownHeartRateBPM: Int = 0
    @Published var hrStreamingActive: Bool = false
    @Published var watchReachable: Bool = false
    @Published var watchPaired: Bool = false
    @Published var watchAppInstalled: Bool = false
    @Published var hrPermissionGranted: Bool = false
    @Published var hrLastValueAt: Date? = nil
    @Published var hrDataStaleSeconds: Int = 0
    @Published var treadmillStatusText: String = "unknown"
    @Published private(set) var stopTruthStatusText: String = ""
    @Published var lastNotifyAgeSeconds: Int = 0
    @Published var lastCommandAckStatusText: String = ""
    @Published var lastCommandTimeoutsCount: Int = 0
    @Published var deviceReportedSpeedKmh: Double = 0
    @Published var deviceReportedAppSpeedKmh: Double = 0
    @Published var deviceReportedState: Int = 0
    @Published var deviceReportedManualMode: Int = 0
    @Published var deviceReportedTimeSeconds: Int = 0
    @Published var deviceReportedDistance10m: Int = 0
    @Published var deviceReportedSteps: Int = 0
    @Published var deviceReportedButton: Int = 0
    @Published var deviceReportedChecksumOk: Bool = true
    @Published var deviceReportedRawHex: String = ""
    @Published private(set) var controllerUnitsTruth: ControllerUnitsTruth = .disconnected
    @Published private(set) var treadmillTestRunIsActive = false
    @Published private(set) var treadmillTestRunStatusText = "READY"
#if STOP_TRUTH_EXPERIMENT_CAPABILITY
    @Published private(set) var stopTruthExperimentStatus: String = "disabled"
    @Published private(set) var stopTruthExperimentArtifactPath: String = ""
#endif

    // HR control
    @Published var isHrControlRunning: Bool = false
    @Published var isHrControlStartAllowed: Bool = false
    @Published var hrControlStartBlockReasonText: String? = nil
    @Published private(set) var isNativeHeartRatePreflightActive: Bool = false
    @Published private(set) var isNativeHeartRateCurrent: Bool = false
    @Published private(set) var isNativeWorkoutRecoveryActive: Bool = false
    @Published private(set) var nativeWorkoutRecoveryStatusText: String? = nil

    private var nativeHeartRatePreflightEngine = NativeHeartRatePreflightEngine()
    private var nativeHeartRateAppActivity: NativeHeartRatePreflightEngine.AppActivity = .inactive
    private var isTrainingHubVisible = false
    private var nativeHeartRateFlowOwnsController = false
    private var nativeHeartRateProviderLifecycle = NativeHeartRateProviderLifecycle()
    private var nativeHealthKitWorkoutCommitted = false
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
    @Published var hrRemainingSeconds: Int = 0
    @Published var hrCooldownRemainingSeconds: Int = 0
    @Published var hrProgress: Double = 0
    @Published var hrCooldownProgress: Double = 0
    @Published var hrTargetBPM: Int = 130 {
        didSet {
            guard !isRestoringNativeWorkoutRecoveryState else { return }
            sendHrTargetBpm()
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
    struct HrFailureReport: Identifiable { let id = UUID(); let reason: String; let start: Date; let end: Date; let lines: [String] }
    @Published var hrFailureReports: [HrFailureReport] = []
    @Published var loggingEnabled: Bool = false
    @Published var lastCommandLine: String = ""
    @Published var debugLog: String = ""
    @Published var lastTrainingLogPath: String = ""
    @Published private(set) var trainingLogsInventory: TrainingTelemetryWriter.TrainingLogsInventory = .empty

    private func appendLog(_ line: String) {
        guard loggingEnabled else { return }
        let entry = "[\(Date().formatted(date: .omitted, time: .standard))] \(line)"
        DispatchQueue.main.async {
            // Keep a rolling log: cap by lines and by total UTF-8 bytes
            let maxLines = 4000
            let maxBytes = 250_000 // ~250 KB
            var lines = self.debugLog.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            lines.append(entry)
            // Enforce line cap first
            if lines.count > maxLines {
                lines.removeFirst(lines.count - maxLines)
            }
            // Enforce byte cap by keeping the newest suffix that fits
            var kept: [String] = []
            kept.reserveCapacity(min(lines.count, maxLines))
            var totalBytes = 0
            for l in lines.reversed() {
                let bytes = l.lengthOfBytes(using: .utf8) + 1 // + newline
                if totalBytes + bytes > maxBytes { break }
                kept.append(l)
                totalBytes += bytes
                if kept.count >= maxLines { break }
            }
            if kept.isEmpty {
                kept = [lines.last ?? entry]
            }
            self.debugLog = kept.reversed().joined(separator: "\n")
        }
    }

    func logUiAction(_ message: String) {
        appendLog("UI \(message)")
    }

    private func currentTrainingPhase() -> String {
        if isHrControlRunning && hrRemainingSeconds > 0 { return "hr_control" }
        if isHrControlRunning && hrCooldownRemainingSeconds > 0 { return "cooldown" }
        if isHrControlRunning { return "running" }
        return "idle"
    }

    private func currentSessionState() -> String {
        guard isHrControlRunning else { return "idle" }
        if hrCooldownRemainingSeconds > 0 { return "cooldown" }
        if hrRemainingSeconds > 0 {
            if HRDomainService.isWithinInitialHeartRateGrace(
                startedAt: hrControlStartedAt,
                now: Date(),
                graceSeconds: hrStartGraceSeconds
            ) {
                return "warmup"
            }
            return "main"
        }
        return "running"
    }

    private func currentTargetZoneSnapshot() -> (index: Int, lower: Int, upper: Int) {
        let z1 = max(60, min(220, hrZone1Max))
        let z2 = max(z1, min(220, hrZone2Max))
        let z3 = max(z2, min(220, hrZone3Max))
        let z4 = max(z3, min(220, hrZone4Max))
        let hr = max(60, min(220, hrTargetBPM))

        if hr <= z1 { return (index: 1, lower: 60, upper: z1) }
        if hr <= z2 { return (index: 2, lower: z1 + 1, upper: z2) }
        if hr <= z3 { return (index: 3, lower: z2 + 1, upper: z3) }
        if hr <= z4 { return (index: 4, lower: z3 + 1, upper: z4) }
        return (index: 5, lower: z4 + 1, upper: 220)
    }

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
        syncPublishedCooldownRuntimeState()
    }

    private func currentCooldownConfig() -> CooldownRuntimeEngine.Config {
        CooldownRuntimeEngine.Config(
            targetBpm: hrCooldownTargetBpm,
            minSpeedKmh: hrCooldownMinSpeed,
            maxMinutes: hrCooldownMaxMinutes,
            holdSeconds: hrCooldownHoldSeconds,
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
            appReportedSpeedKmh: deviceReportedAppSpeedKmh,
            rawReportedSpeedKmh: deviceReportedSpeedKmh,
            currentActualSpeedKmh: speedKmh
        )
    }

    private func applyCooldownOutput(
        _ output: CooldownRuntimeEngine.Output,
        sessionElapsedSeconds: Int?
    ) {
        cooldownRuntimeState = output.state
        syncPublishedCooldownRuntimeState()

        for effect in output.effects {
            executeCooldownEffect(effect, sessionElapsedSeconds: sessionElapsedSeconds)
        }
    }

    private func executeCooldownEffect(
        _ effect: CooldownRuntimeEngine.Effect,
        sessionElapsedSeconds: Int?
    ) {
        switch effect {
        case .status(let presentation):
            hrStatusLine = presentation.statusLine
            hrDecisionDetails = presentation.decisionDetails
            hrCooldownRemainingSeconds = presentation.remainingSeconds
            hrCooldownProgress = presentation.progress

        case .setSpeed(let speedEffect):
            guard isTreadmillControlReady else {
                appendLog("Cooldown speed skipped: treadmill control not ready")
                return
            }
            let old = deviceTargetSpeedKmh
            desiredSpeedKmh = speedEffect.targetKmh
            deviceTargetSpeedKmh = speedEffect.targetKmh
            recordSpeedChange(from: old, to: speedEffect.targetKmh, reason: "cooldown_set")
            lastCommandLine = String(format: "CMD cooldown adjust -> %.1f", speedEffect.targetKmh)
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
            appendLog(
                "HR cooldown speed: \(String(format: "%.1f", speedEffect.targetKmh)) " +
                "HR=\(speedEffect.hrBpm) step=\(String(format: "%.1f", speedEffect.stepKmh)) " +
                "trigger=\(speedEffect.trigger)"
            )

        case .telemetry(let telemetryEffect):
            logCooldownTelemetry(telemetryEffect)

        case .complete(let completionEffect):
            if completionEffect.shouldRecordWorkout {
                recordHrWorkoutIfNeeded(durationOverride: sessionElapsedSeconds, failed: false)
            }
            if completionEffect.shouldStopSession {
                isHrControlRunning = false
                hrControlStartedAt = nil
            }
            stopTrainingStructuredLog(reason: completionEffect.structuredLogReason)
            if completionEffect.shouldStopWatch {
                stopLegacyWatchHeartRateIfNeeded()
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
        defer {
            let now = Date()
            switch effect {
            case let .start(telemetry):
                _ = telemetryV2Coordinator.observeWorkoutPhase(.cooldown, occurredAt: now)
                _ = telemetryV2Coordinator.observeEvent(
                    .cooldown(
                        CooldownEvent(
                            lifecycle: .started,
                            targetHeartRate: UInt16(exactly: telemetry.targetBpm)
                        )
                    ),
                    occurredAt: now
                )
            case .complete:
                _ = telemetryV2Coordinator.observeEvent(
                    .cooldown(CooldownEvent(lifecycle: .completed)),
                    occurredAt: now
                )
            case .insufficient:
                _ = telemetryV2Coordinator.observeEvent(
                    .cooldown(CooldownEvent(lifecycle: .insufficient)),
                    occurredAt: now
                )
            case .speedSet, .state, .analysis:
                break
            }
        }
        switch effect {
        case .start(let telemetry):
            appendLog(
                "HR cooldown start: from \(String(format: "%.1f", telemetry.fromSpeedKmh)) " +
                "to \(String(format: "%.1f", telemetry.minSpeedKmh)) target=\(telemetry.targetBpm) bpm " +
                "step=\(String(format: "%.1f", telemetry.stepKmh)) interval=\(telemetry.intervalSeconds)s " +
                "max=\(telemetry.maxSeconds)s"
            )
            logTrainingEvent("cooldown_start", fields: [
                "from_speed_kmh": telemetry.fromSpeedKmh,
                "target_bpm": telemetry.targetBpm,
                "min_speed_kmh": telemetry.minSpeedKmh,
                "step_kmh": telemetry.stepKmh,
                "interval_s": telemetry.intervalSeconds,
                "base_max_s": telemetry.baseMaxSeconds,
                "max_s": telemetry.maxSeconds,
                "extra_s": telemetry.extraSeconds,
                "start_hr_bpm": telemetry.startBpm,
                "session_peak_bpm": telemetry.sessionAggregates.sessionPeakBpm,
                "main_avg_bpm": telemetry.sessionAggregates.mainAvgBpm,
                "main_peak_bpm": telemetry.sessionAggregates.mainPeakBpm,
                "zone_seconds": telemetry.sessionAggregates.zoneSeconds,
                "zone4plus_seconds": telemetry.sessionAggregates.zone4PlusSeconds
            ])

        case .speedSet(let telemetry):
            logTrainingEvent("cooldown_speed_set", fields: [
                "hr_bpm": telemetry.hrBpm,
                "target_bpm": telemetry.targetBpm,
                "adaptive_factor": telemetry.adaptiveFactor,
                "step_kmh": telemetry.stepKmh,
                "speed_before_kmh": telemetry.speedBeforeKmh,
                "speed_after_kmh": telemetry.speedAfterKmh,
                "elapsed_s": telemetry.elapsedSeconds,
                "trigger": telemetry.trigger
            ])

        case .state(let telemetry):
            logTrainingEvent("cooldown_state", fields: [
                "hr_bpm": telemetry.hrBpm,
                "target_bpm": telemetry.targetBpm,
                "speed_kmh": telemetry.observedSpeedKmh,
                "cooldown_observed_speed_kmh": telemetry.observedSpeedKmh,
                "cooldown_controller_speed_kmh": telemetry.controllerSpeedKmh,
                "elapsed_s": telemetry.elapsedSeconds,
                "stable_s": telemetry.stableSeconds,
                "stable_required_s": telemetry.stableRequiredSeconds,
                "remaining_s": telemetry.remainingSeconds,
                "target_hit_elapsed_s": telemetry.targetHitElapsedSeconds ?? -1,
                "cooldown_hr_ok": telemetry.hrOk,
                "cooldown_min_speed_ok": telemetry.minSpeedOk,
                "cooldown_stable_ok": telemetry.stableOk,
                "cooldown_stability_blocker": telemetry.blocker,
                "cooldown_first_min_speed_elapsed_s": telemetry.firstMinSpeedElapsedSeconds ?? -1,
                "cooldown_first_stable_elapsed_s": telemetry.firstStableElapsedSeconds ?? -1,
                "cooldown_hr_below_target_s": telemetry.belowTargetSeconds,
                "cooldown_min_speed_s": telemetry.minSpeedSeconds,
                "cooldown_target_and_min_speed_s": telemetry.targetAndMinSpeedSeconds,
                "cooldown_target_and_min_speed_max_streak_s": telemetry.maxStableStreakSeconds,
                "start_hr_bpm": telemetry.startBpm,
                "session_peak_bpm": telemetry.sessionAggregates.sessionPeakBpm,
                "main_avg_bpm": telemetry.sessionAggregates.mainAvgBpm,
                "main_peak_bpm": telemetry.sessionAggregates.mainPeakBpm
            ])

        case .analysis(let telemetry):
            logTrainingEvent("cooldown_analysis", fields: [
                "reason": telemetry.reason,
                "timeout_blocker": telemetry.timeoutBlocker,
                "hr_bpm": telemetry.hrBpm,
                "target_bpm": telemetry.targetBpm,
                "cooldown_observed_speed_kmh": telemetry.observedSpeedKmh,
                "cooldown_controller_speed_kmh": telemetry.controllerSpeedKmh,
                "cooldown_hr_ok": telemetry.hrOk,
                "cooldown_min_speed_ok": telemetry.minSpeedOk,
                "cooldown_stable_ok": telemetry.stableOk,
                "cooldown_stability_blocker": telemetry.blocker,
                "cooldown_first_min_speed_elapsed_s": telemetry.firstMinSpeedElapsedSeconds ?? -1,
                "cooldown_first_stable_elapsed_s": telemetry.firstStableElapsedSeconds ?? -1,
                "cooldown_hr_below_target_s": telemetry.belowTargetSeconds,
                "cooldown_min_speed_s": telemetry.minSpeedSeconds,
                "cooldown_target_and_min_speed_s": telemetry.targetAndMinSpeedSeconds,
                "cooldown_target_and_min_speed_max_streak_s": telemetry.maxStableStreakSeconds,
                "stable_s": telemetry.stableSeconds,
                "stable_required_s": telemetry.stableRequiredSeconds,
                "elapsed_s": telemetry.elapsedSeconds,
                "planned_s": telemetry.plannedSeconds
            ])

        case .complete(let telemetry):
            logTrainingEvent("cooldown_complete", fields: [
                "reason": telemetry.reason,
                "cooldown_finish_reason": telemetry.reason,
                "cooldown_timeout_blocker": telemetry.timeoutBlocker,
                "stable_s": telemetry.stableSeconds,
                "stable_required_s": telemetry.stableRequiredSeconds,
                "remaining_s": telemetry.remainingSeconds,
                "hr_bpm": telemetry.hrBpm,
                "target_bpm": telemetry.targetBpm,
                "cooldown_observed_speed_kmh": telemetry.observedSpeedKmh,
                "cooldown_controller_speed_kmh": telemetry.controllerSpeedKmh,
                "cooldown_hr_ok": telemetry.hrOk,
                "cooldown_min_speed_ok": telemetry.minSpeedOk,
                "cooldown_stable_ok": telemetry.stableOk,
                "cooldown_stability_blocker": telemetry.blocker,
                "elapsed_s": telemetry.elapsedSeconds,
                "planned_s": telemetry.plannedSeconds,
                "target_hit_elapsed_s": telemetry.targetHitElapsedSeconds ?? -1,
                "cooldown_first_min_speed_elapsed_s": telemetry.firstMinSpeedElapsedSeconds ?? -1,
                "cooldown_first_stable_elapsed_s": telemetry.firstStableElapsedSeconds ?? -1,
                "cooldown_hr_below_target_s": telemetry.belowTargetSeconds,
                "cooldown_min_speed_s": telemetry.minSpeedSeconds,
                "cooldown_target_and_min_speed_s": telemetry.targetAndMinSpeedSeconds,
                "cooldown_target_and_min_speed_max_streak_s": telemetry.maxStableStreakSeconds,
                "start_hr_bpm": telemetry.startBpm,
                "end_hr_bpm": telemetry.endBpm,
                "peak_hr_bpm": telemetry.peakBpm,
                "hr_drop_bpm": telemetry.hrDropBpm,
                "hr_recovery_bpm_per_min": telemetry.recoveryBpmPerMinute,
                "session_peak_bpm": telemetry.sessionAggregates.sessionPeakBpm,
                "main_avg_bpm": telemetry.sessionAggregates.mainAvgBpm,
                "main_peak_bpm": telemetry.sessionAggregates.mainPeakBpm,
                "zone_seconds": telemetry.sessionAggregates.zoneSeconds,
                "zone4plus_seconds": telemetry.sessionAggregates.zone4PlusSeconds
            ])

        case .insufficient(let telemetry):
            logTrainingEvent("cooldown_insufficient", fields: [
                "hr_bpm": telemetry.hrBpm,
                "target_bpm": telemetry.targetBpm,
                "excess_bpm": telemetry.excessBpm,
                "cooldown_finish_reason": telemetry.finishReason,
                "cooldown_timeout_blocker": telemetry.timeoutBlocker,
                "cooldown_observed_speed_kmh": telemetry.observedSpeedKmh,
                "cooldown_controller_speed_kmh": telemetry.controllerSpeedKmh,
                "cooldown_first_min_speed_elapsed_s": telemetry.firstMinSpeedElapsedSeconds ?? -1,
                "cooldown_first_stable_elapsed_s": telemetry.firstStableElapsedSeconds ?? -1,
                "cooldown_hr_below_target_s": telemetry.belowTargetSeconds,
                "cooldown_min_speed_s": telemetry.minSpeedSeconds,
                "cooldown_target_and_min_speed_s": telemetry.targetAndMinSpeedSeconds,
                "cooldown_target_and_min_speed_max_streak_s": telemetry.maxStableStreakSeconds,
                "elapsed_s": telemetry.elapsedSeconds,
                "planned_s": telemetry.plannedSeconds,
                "start_hr_bpm": telemetry.startBpm,
                "end_hr_bpm": telemetry.endBpm,
                "hr_drop_bpm": telemetry.hrDropBpm,
                "hr_recovery_bpm_per_min": telemetry.recoveryBpmPerMinute,
                "session_peak_bpm": telemetry.sessionAggregates.sessionPeakBpm,
                "main_avg_bpm": telemetry.sessionAggregates.mainAvgBpm,
                "main_peak_bpm": telemetry.sessionAggregates.mainPeakBpm,
                "zone4plus_seconds": telemetry.sessionAggregates.zone4PlusSeconds
            ])
        }
    }

    private func trainingLogsDirectoryURL() -> URL? {
        TrainingTelemetryWriter.makeDirectoryURL(directoryName: trainingLogsDirectoryName) { [weak self] message in
            self?.appendLog(message)
        }
    }

    private func pruneTrainingLogs(in directory: URL) {
        TrainingTelemetryWriter.pruneJsonlFiles(in: directory, maxFiles: trainingLogMaxFiles)
    }

    private func scheduleTrainingLogsInventoryRefresh() {
        trainingLogQueue.async { [weak self] in
            DispatchQueue.main.async {
                self?.refreshTrainingLogsInventory()
            }
        }
    }

    private func makeTrainingLogPayload(event: String, fields: [String: Any]) -> [String: Any] {
        let zone = currentTargetZoneSnapshot()
        let cooldownState = cooldownRuntimeState
        var payload: [String: Any] = [
            "ts": trainingLogIsoFormatter.string(from: Date()),
            "event": event,
            "installation_id": installationID,
            "profile_id": activeUserProfile?.id.uuidString ?? "",
            "profile_label": activeUserProfileLabel,
            "phase": currentTrainingPhase(),
            "session_state": currentSessionState(),
            "is_hr_running": isHrControlRunning,
            "hr_bpm": heartRateBPM,
            "hr_last_bpm": lastKnownHeartRateBPM,
            "target_bpm": hrTargetBPM,
            "target_zone_index": zone.index,
            "target_zone_lower_bpm": zone.lower,
            "target_zone_upper_bpm": zone.upper,
            "session_peak_bpm": hrSessionPeakBPM,
            "main_avg_bpm": mainPhaseAverageBPMSnapshot(),
            "main_peak_bpm": hrMainPeakBPM,
            "zone_seconds": zoneSecondsSnapshot(),
            "zone4plus_seconds": zone4PlusSecondsSnapshot(),
            "cooldown_start_hr_bpm": cooldownState?.startBpm ?? 0,
            "cooldown_end_hr_bpm": cooldownState?.endBpm ?? 0,
            "cooldown_peak_hr_bpm": cooldownState?.peakBpm ?? 0,
            "cooldown_target_bpm": hrCooldownTargetBpm,
            "cooldown_planned_s": cooldownState?.totalSeconds ?? 0,
            "cooldown_elapsed_s": cooldownState?.elapsedSeconds ?? 0,
            "cooldown_target_hit_elapsed_s": cooldownState?.targetHitElapsedSeconds ?? -1,
            "cooldown_hr_drop_bpm": cooldownState?.hrDropBpm ?? 0,
            "cooldown_hr_recovery_bpm_per_min": cooldownState?.recoveryBpmPerMinute ?? 0,
            "cooldown_finish_reason": cooldownState?.finishReason ?? "",
            "cooldown_timeout_blocker": cooldownState?.timeoutBlocker ?? "",
            "cooldown_first_min_speed_elapsed_s": cooldownState?.firstMinSpeedElapsedSeconds ?? -1,
            "cooldown_first_stable_elapsed_s": cooldownState?.firstStableElapsedSeconds ?? -1,
            "cooldown_hr_below_target_s": cooldownState?.belowTargetSeconds ?? 0,
            "cooldown_min_speed_s": cooldownState?.minSpeedSeconds ?? 0,
            "cooldown_target_and_min_speed_s": cooldownState?.targetAndMinSpeedSeconds ?? 0,
            "cooldown_target_and_min_speed_max_streak_s": cooldownState?.maxStableStreakSeconds ?? 0,
            "speed_actual_kmh": speedKmh,
            "speed_target_kmh": desiredSpeedKmh,
            "speed_device_target_kmh": deviceTargetSpeedKmh,
            "speed_reported_kmh": deviceReportedSpeedKmh,
            "speed_reported_app_kmh": deviceReportedAppSpeedKmh,
            "speed_delta_kmh": lastSpeedDeltaKmh,
            "distance_km": distKm,
            "duration_s": timeSec,
            "steps": stepsCount,
            "treadmill_status": treadmillStatusText
        ]
        if let sessionId = trainingLogSessionId {
            payload["session_id"] = sessionId
        }
        for (key, value) in fields {
            payload[key] = value
        }
        return payload
    }

    private func writeTrainingLogLocked(event: String, fields: [String: Any]) {
        guard let handle = trainingLogFileHandle else { return }
        let payload = makeTrainingLogPayload(event: event, fields: fields)
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return
        }
        handle.seekToEndOfFile()
        handle.write(data)
        handle.write(Data([0x0A]))
    }

    private func logTrainingEvent(_ event: String, fields: [String: Any] = [:]) {
        trainingLogQueue.async { [weak self] in
            self?.writeTrainingLogLocked(event: event, fields: fields)
        }
    }

    @discardableResult
    private func startTrainingStructuredLog(
        trigger: String,
        sessionID: UUID? = nil
    ) -> UUID? {
        stopTrainingStructuredLog(reason: "restart_before_new_session")
        let resolvedSessionID = sessionID
            ?? (trigger == "start_hr"
                ? activeNativeWorkoutRecoveryRecord?.legacySessionID
                : nil)
            ?? UUID()
        guard let dir = trainingLogsDirectoryURL() else {
            return resolvedSessionID
        }
        let sessionId = resolvedSessionID.uuidString
        let fileName = "hr_session_\(trainingLogTimestampFormatter.string(from: Date()))_\(sessionId).jsonl"
        let fileURL = dir.appendingPathComponent(fileName, isDirectory: false)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)

        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            trainingLogQueue.sync {
                trainingLogSessionId = sessionId
                trainingLogFileURL = fileURL
                trainingLogFileHandle = handle
            }
            DispatchQueue.main.async {
                self.lastTrainingLogPath = fileURL.path
                self.refreshTrainingLogsInventory()
            }
            appendLog("Training log started: \(fileName)")
            let adaptiveLevels: [Double] = [0.1, 0.2, 0.3, 0.4]
            logTrainingEvent("session_start", fields: [
                "trigger": trigger,
                "target_bpm": hrTargetBPM,
                "duration_min": hrDurationMinutes,
                "decision_interval_s": hrDecisionIntervalSeconds,
                "adaptive_step_enabled": hrAdaptiveStepEnabled,
                "max_step_kmh": hrSpeedStepKmh,
                "adaptive_levels_kmh": adaptiveLevels,
                "cooldown_target_bpm": hrCooldownTargetBpm,
                "cooldown_min_speed_kmh": hrCooldownMinSpeed,
                "zone_bounds": [hrZone1Max, hrZone2Max, hrZone3Max, hrZone4Max]
            ].merging(controllerUnitsTelemetryFields(action: "session_start")) { current, _ in current })
            scheduleTrainingLogsInventoryRefresh()
            return resolvedSessionID
        } catch {
            appendLog("Training log file open error: \(error.localizedDescription)")
            return resolvedSessionID
        }
    }

    private func stopTrainingStructuredLog(reason: String) {
        trainingLogQueue.sync {
            guard trainingLogFileHandle != nil else { return }
            let cooldownState = self.cooldownRuntimeState
            writeTrainingLogLocked(event: "session_end", fields: [
                "reason": reason,
                "remaining_s": hrRemainingSeconds,
                "cooldown_remaining_s": hrCooldownRemainingSeconds,
                "avg_bpm": hrAverageBPM,
                "session_peak_bpm": hrSessionPeakBPM,
                "main_avg_bpm": mainPhaseAverageBPMSnapshot(),
                "main_peak_bpm": hrMainPeakBPM,
                "zone_seconds": zoneSecondsSnapshot(),
                "zone4plus_seconds": zone4PlusSecondsSnapshot(),
                "cooldown_start_hr_bpm": cooldownState?.startBpm ?? 0,
                "cooldown_end_hr_bpm": cooldownState?.endBpm ?? 0,
                "cooldown_peak_hr_bpm": cooldownState?.peakBpm ?? 0,
                "cooldown_planned_s": cooldownState?.totalSeconds ?? 0,
                "cooldown_elapsed_s": cooldownState?.elapsedSeconds ?? 0,
                "cooldown_target_hit_elapsed_s": cooldownState?.targetHitElapsedSeconds ?? -1,
                "cooldown_hr_drop_bpm": cooldownState?.hrDropBpm ?? 0,
                "cooldown_hr_recovery_bpm_per_min": cooldownState?.recoveryBpmPerMinute ?? 0,
                "distance_km": distKm,
                "duration_s": timeSec
            ])
            trainingLogFileHandle?.synchronizeFile()
            trainingLogFileHandle?.closeFile()
            trainingLogFileHandle = nil
            trainingLogFileURL = nil
            trainingLogSessionId = nil
        }
        appendLog("Training log closed: \(reason)")
        DispatchQueue.main.async {
            self.refreshTrainingLogsInventory()
        }
    }

    func prepareTrainingLogsCsvExport(scope: TrainingLogCsvExportScope = .all) -> TrainingLogsCsvExport? {
        trainingLogQueue.sync {
            trainingLogFileHandle?.synchronizeFile()
        }
        guard let jsonlFiles = availableTrainingJsonlFiles(scope: scope) else {
            return nil
        }

        let headers = TrainingTelemetryWriter.trainingCsvHeaders
        var lines: [String] = [headers.map(TrainingTelemetryWriter.csvEscape).joined(separator: ",")]
        var exportedRows = 0

        for file in jsonlFiles {
            for payload in TrainingTelemetryWriter.loadJsonlPayloads(from: file) {
                let row = TrainingTelemetryWriter.csvRow(
                    sourceFile: file.lastPathComponent,
                    payload: payload
                )

                lines.append(row.map(TrainingTelemetryWriter.csvEscape).joined(separator: ","))
                exportedRows += 1
            }
        }

        guard exportedRows > 0 else { return nil }
        let ts = trainingLogTimestampFormatter.string(from: Date())
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("Training_History\(scope.fileNameSuffix)_\(ts).csv")
        do {
            try lines.joined(separator: "\n").write(to: outURL, atomically: true, encoding: .utf8)
            appendLog("Training CSV exported: \(outURL.lastPathComponent) scope=\(scope.logDescription) rows=\(exportedRows) files=\(jsonlFiles.count)")
            return TrainingLogsCsvExport(
                csvURL: outURL,
                rowCount: exportedRows,
                scope: scope,
                sourceFiles: jsonlFiles
            )
        } catch {
            appendLog("Training CSV export failed: \(error.localizedDescription)")
            return nil
        }
    }

    func prepareTrainingSessionSummaryCsvExport(
        scope: TrainingLogCsvExportScope = .all
    ) -> TrainingLogsCsvExport? {
        trainingLogQueue.sync {
            trainingLogFileHandle?.synchronizeFile()
        }
        guard let allJsonlFiles = allTrainingJsonlFiles(),
              !allJsonlFiles.isEmpty else {
            return nil
        }

        let filteredFiles = TrainingTelemetryWriter.filterJsonlFiles(
            allJsonlFiles,
            matchingProfileID: activeUserProfileID?.uuidString,
            legacyFallbackProfileID: legacyFallbackProfileID
        )
        let jsonlFiles = TrainingTelemetryWriter.selectCompletedJsonlFilesForExport(filteredFiles, scope: scope)
        guard !jsonlFiles.isEmpty else { return nil }

        let headers = TrainingTelemetryWriter.trainingSessionSummaryHeaders
        var lines: [String] = [headers.map(TrainingTelemetryWriter.csvEscape).joined(separator: ",")]
        var exportedRows = 0

        for file in jsonlFiles {
            let payloads = TrainingTelemetryWriter.loadJsonlPayloads(from: file)
            guard let row = TrainingTelemetryWriter.sessionSummaryRow(
                sourceFile: file.lastPathComponent,
                payloads: payloads
            ) else {
                continue
            }

            lines.append(row.map(TrainingTelemetryWriter.csvEscape).joined(separator: ","))
            exportedRows += 1
        }

        guard exportedRows > 0 else { return nil }
        let ts = trainingLogTimestampFormatter.string(from: Date())
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("Training_Session_Summary\(scope.fileNameSuffix)_\(ts).csv")

        do {
            try lines.joined(separator: "\n").write(to: outURL, atomically: true, encoding: .utf8)
            appendLog("Training session summary exported: \(outURL.lastPathComponent) scope=\(scope.logDescription) rows=\(exportedRows) files=\(jsonlFiles.count)")
            return TrainingLogsCsvExport(
                csvURL: outURL,
                rowCount: exportedRows,
                scope: scope,
                sourceFiles: jsonlFiles
            )
        } catch {
            appendLog("Training session summary export failed: \(error.localizedDescription)")
            return nil
        }
    }

    func finalizeTrainingLogsCsvExport(_ export: TrainingLogsCsvExport, completed: Bool) {
        try? FileManager.default.removeItem(at: export.csvURL)
        appendLog(
            "Legacy CSV share \(completed ? "completed" : "cancelled"); source evidence preserved"
        )
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func allTrainingJsonlFiles() -> [URL]? {
        guard let dir = trainingLogsDirectoryURL() else { return nil }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return files
            .filter { $0.pathExtension.lowercased() == "jsonl" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return l < r
            }
    }

    func refreshTrainingLogsInventory() {
        let refreshID = UUID()
        trainingLogsInventoryRefreshID = refreshID
        let profileID = activeUserProfileID?.uuidString
        let fallbackProfileID = legacyFallbackProfileID

        trainingLogQueue.async { [weak self] in
            guard let self else { return }
            self.trainingLogFileHandle?.synchronizeFile()
            let protectedFiles = Set(
                self.trainingLogFileURL.map { [$0.standardizedFileURL] } ?? []
            )
            let snapshot = TrainingTelemetryWriter.trainingLogsInventorySnapshot(
                self.allTrainingJsonlFiles() ?? [],
                matchingProfileID: profileID,
                legacyFallbackProfileID: fallbackProfileID,
                keeping: protectedFiles
            )
            DispatchQueue.main.async {
                guard self.trainingLogsInventoryRefreshID == refreshID else { return }
                self.trainingLogsInventory = snapshot.inventory
                self.lastTrainingLogPath = snapshot.latestMatchingProfileFile?.path ?? ""
            }
        }
    }

    func trainingLogsExportCount(
        for scope: TrainingLogCsvExportScope,
        sessionSummaryOnly: Bool
    ) -> Int {
        switch scope {
        case .all:
            return sessionSummaryOnly
                ? trainingLogsInventory.matchingProfileCompletedWorkoutFiles
                : trainingLogsInventory.matchingProfileSessionFiles
        case .lastCompletedWorkouts(let count):
            let completedCount = trainingLogsInventory.matchingProfileCompletedWorkoutFiles
            return min(max(0, count), completedCount)
        }
    }

    func clearTrainingLogsForActiveProfile() {
        appendLog("Legacy training log clear ignored; source evidence preserved through #37")
        infoToastMessage = "Legacy source evidence is preserved until the explicit retirement gate."
    }

    private func availableTrainingJsonlFiles(scope: TrainingLogCsvExportScope) -> [URL]? {
        guard let allJsonlFiles = allTrainingJsonlFiles(),
              !allJsonlFiles.isEmpty else {
            return nil
        }

        let filteredFiles = TrainingTelemetryWriter.filterJsonlFiles(
            allJsonlFiles,
            matchingProfileID: activeUserProfileID?.uuidString,
            legacyFallbackProfileID: legacyFallbackProfileID
        )
        let selected = TrainingTelemetryWriter.selectJsonlFilesForExport(filteredFiles, scope: scope)
        return selected.isEmpty ? nil : selected
    }

    // UI messaging hooks
    @Published var connectErrorMessage: String? = nil
    @Published var suggestDevicePicker: Bool = false
    @Published var infoToastMessage: String? = nil

    func consumeConnectErrorMessage() {
        connectErrorMessage = nil
    }

    // History
    private struct LegacyShadowWorkoutEntry: Identifiable {
        let id: UUID
        let date: Date
        let beatsPerMeter: Double?
        let targetBpm: Int
        let durationSeconds: Int
        let avgBpm: Int
        let avgSpeedKmh: Double?
        let healthkitWorkoutUUID: String?
        let zoneSeconds: [Int]?
    }
    private var legacyShadowWorkoutHistory: [LegacyShadowWorkoutEntry] = []

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
                    self.appendLog("Telemetry V2 workout read failed: \(error)")
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

    func refreshWorkoutStatisticsFromV2(for interval: DateInterval) {
        guard let filter = activeWorkoutReadFilter(
            startedAtOrAfter: interval.start,
            startedBefore: interval.end
        ), let requestedProfileID = activeUserProfileID else { return }
        let key = workoutStatisticsKey(for: interval)
        let requestedProjectionGeneration = telemetryV2ProjectionGeneration
        telemetryV2StatisticsState[key] = .loading

        Task { [weak self] in
            guard let self else { return }
            do {
                let statistics = try await self.telemetryV2Coordinator.fetchWorkoutStatistics(
                    filter: filter,
                    batchSize: 100
                )
                await MainActor.run {
                    guard self.activeUserProfileID == requestedProfileID,
                          self.telemetryV2ProjectionGeneration
                            == requestedProjectionGeneration else { return }
                    self.telemetryV2Statistics[key] = statistics
                    self.telemetryV2StatisticsState[key] = .loaded
                }
            } catch {
                await MainActor.run {
                    guard self.activeUserProfileID == requestedProfileID,
                          self.telemetryV2ProjectionGeneration
                            == requestedProjectionGeneration else { return }
                    self.telemetryV2StatisticsState[key] = .failed(error.localizedDescription)
                    self.appendLog("Telemetry V2 statistics read failed: \(error)")
                }
            }
        }
    }

    func prepareTelemetryV2Export(
        scope: TrainingLogCsvExportScope
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

    func finalizeTelemetryV2Export(_ artifact: WorkoutExportArtifact, completed: Bool) {
        do {
            try FileManager.default.removeItem(at: artifact.directoryURL)
        } catch {
            appendLog("Telemetry V2 export temporary cleanup failed: \(error.localizedDescription)")
        }
        infoToastMessage = completed
            ? "Telemetry V2 export shared. Source evidence was preserved."
            : "Telemetry V2 export cancelled. Source evidence was preserved."
    }

    // Lifecycle
    private func scheduleLegacyTelemetryMigration() {
        let knownProfiles = sortedProfiles(userProfiles).map {
            $0.id.uuidString.lowercased()
        }
        let deterministicFallbackProfile = knownProfiles.first
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
        activeWorkoutRecoveryRequestPending
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
        guard didStartApplicationRuntime,
              let result = pendingActiveWorkoutRecoveryResult else { return }
        pendingActiveWorkoutRecoveryResult = nil
        guard result.1 == nil, let recoveredSession = result.0 else {
            handleUnavailableActiveWorkoutRecovery(error: result.1)
            return
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
        guard didStartApplicationRuntime,
              activeWorkoutRecoveryAvailability == false,
              !activeWorkoutRecoveryRequestPending,
              !didHandleActiveWorkoutRecoveryCallback,
              !nativeHealthKitWorkoutCommitted,
              !nativeHeartRateFlowOwnsController,
              !nativeHealthKitWorkoutFinishInFlight else { return }
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
            pendingHealthkitWorkoutProfileID = record.profileID
            pendingHealthkitTelemetryV2SessionID = record.telemetrySessionID.map {
                SessionID(rawValue: $0)
            }
            retainDeferredNativeHealthKitLinkage(
                record: record,
                finishRequestedAt: finishRequestedAt,
                healthKitStoppedAt: healthKitStoppedAt
            )
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
              let profileID = record.profileID,
              let telemetrySessionID = record.telemetrySessionID else {
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
        pendingHealthkitWorkoutProfileID = profileID
        pendingHealthkitTelemetryV2SessionID = SessionID(rawValue: telemetrySessionID)
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
        hrTargetBPM = record.targetBPM
        hrDurationMinutes = max(1, (record.effectivePlannedDurationSeconds + 59) / 60)
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
        switch nativeWorkoutRecoveryLoadResult {
        case .missing:
            isNativeWorkoutRecoveryActive = false
            nativeWorkoutRecoveryStatusText = nil
        case .record(let record) where record.phase == .preflight:
            if clearNativeWorkoutRecoveryRecord() {
                isNativeWorkoutRecoveryActive = false
                isNativeHeartRatePreflightActive = false
                nativeWorkoutRecoveryStatusText = nil
            }
        case .invalid, .record:
            isNativeWorkoutRecoveryActive = true
            nativeWorkoutRecoveryStatusText = "Не удалось восстановить тренировку"
            infoToastMessage = "HealthKit не восстановил активную тренировку. Управление дорожкой не возобновлено."
        }
        if error != nil {
            nativeHeartRateLogger.error("active_workout_recovery_failed")
        }
        recomputeHrStartAllowed()
    }

    func start() {
        ensureCentral()
        autoConnectSuppressed = false
        autoConnectRetryPolicy.reset()
        knownDiscoveryGraceWorkItem?.cancel()
        knownDiscoveryGraceWorkItem = nil
        knownDiscoveryGraceCompleted = false
        manualModeSet = false
        loadKnownPeripherals()
        loadLastSuccessfulPeripheral()
        loadProfilesState()
        loadHrSettings()
        loadZonePlan()
        loadLegacyShadowWorkoutHistory()
        loadNativeWorkoutRecoveryState()
        refreshWorkoutHistoryFromV2(reset: true)
        refreshTrainingLogsInventory()
        setHeartRateTelemetrySink(telemetryV2Coordinator)
        setTreadmillTelemetrySink(telemetryV2Coordinator)
        telemetryV2Coordinator.prepareStoreAndRecover()
        scheduleLegacyTelemetryMigration()
        didStartApplicationRuntime = true
        processNoActiveWorkoutRecoveryIfPossible()
        processPendingActiveWorkoutRecoveryIfPossible()
#if canImport(WatchConnectivity)
        startWatchConnectivity()
#endif
        recomputeHrStartAllowed()
        startHrStaleTimer()
        // Optionally kick off scanning so UI has something to connect to
        startDiscoveryScan()
        attemptAutoConnectIfNeeded()
    }

    // Watch
    func pingWatch() {
#if canImport(WatchConnectivity)
        if wcSession == nil { startWatchConnectivity() }
        if let s = wcSession {
            refreshWatchState(s)
            if canSendToWatch(s), s.isReachable {
                s.sendMessage(["cmd": "ping"], replyHandler: nil, errorHandler: nil)
            }
        }
#endif
        recomputeHrStartAllowed()
    }

    // Discovery controls
    func startDiscoveryScan() {
        if let central {
            appendLog("Scan start requested (state=\(central.state.rawValue))")
        } else {
            appendLog("Scan start requested (central=nil)")
        }
        ensureCentral()
        shouldBeScanning = true
        DispatchQueue.main.async {
            if !self.isConnected {
                self.connectionStateText = "Scanning..."
            }
            self.recomputeHrStartAllowed()
        }
        if let central, central.state == .poweredOn {
            appendLog("Scanning started")
            central.scanForPeripherals(withServices: supportedServiceUuids,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }
    func stopDiscoveryScan() {
        appendLog("Scan stop requested")
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
        appendLog("Discovery refresh requested")
        DispatchQueue.main.async {
            self.discoveredPeripherals = []
        }
        discoveredMap.removeAll()
        if shouldBeScanning, let central, central.state == .poweredOn {
            central.stopScan()
            central.scanForPeripherals(withServices: supportedServiceUuids,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }
#if canImport(WatchConnectivity)
    private func refreshWatchState(_ session: WCSession) {
        DispatchQueue.main.async {
            let wasReachable = self.watchReachable
            self.watchReachable = session.isReachable
            self.watchPaired = session.isPaired
            self.watchAppInstalled = session.isWatchAppInstalled
            self.recomputeHrStartAllowed()
            if self.watchReachable != wasReachable {
                self.observeHeartRateSourceLifecycle(
                    self.watchReachable ? .available : .unavailable
                )
            }
        }
    }

    private func startWatchConnectivity() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        wcSession = session
        refreshWatchState(session)
        DispatchQueue.main.async {
            self.appendLog("Watch session: reachable=\(session.isReachable) paired=\(session.isPaired) appInstalled=\(session.isWatchAppInstalled)")
        }
        sendHrTargetBpm()
    }

    private func canSendToWatch(_ session: WCSession) -> Bool {
        guard session.activationState == .activated else { return false }
        guard session.isPaired, session.isWatchAppInstalled else { return false }
        return true
    }
#endif

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
        appendLog("AutoConnect: re-armed known candidate after fresh discovery id=\(peripheralID.uuidString)")
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
            self.appendLog("AutoConnect: known discovery grace completed")
            self.attemptAutoConnectIfNeeded()
        }
        knownDiscoveryGraceWorkItem = work
        appendLog("AutoConnect: waiting 1.0s for known-device discovery")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func attemptAutoConnectIfNeeded() {
        guard let central, central.state == .poweredOn else {
            appendLog("AutoConnect skipped: Bluetooth not poweredOn or central nil")
            return
        }
        appendLog("AutoConnect check: connected=\(isConnected) known=\(knownPeripherals.count) discovered=\(discoveredPeripherals.count) allowUnknown=\(allowAutoConnectUnknown)")
        if isConnected {
            appendLog("AutoConnect skipped: already connected")
            return
        }
        if autoConnectSuppressed {
            appendLog("AutoConnect skipped: suppressed by user action")
            return
        }
        if let cancellingConnectionPeripheralId {
            appendLog("AutoConnect skipped: cancellation pending for \(cancellingConnectionPeripheralId.uuidString)")
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
                appendLog("AutoConnect: connecting preferred known discovered \(candidate.name) id=\(candidate.id.uuidString) rssi=\(candidate.rssi)")
                connectToDiscovered(id: candidate.id, clearsAutoConnectSuppression: false)
                return
            }

            let connectedList = central.retrieveConnectedPeripherals(withServices: supportedServiceUuids)
            if let lastSuccessfulPeripheralID,
               orderedAutoConnectCandidateIDs.contains(lastSuccessfulPeripheralID),
               let p = connectedList.first(where: { $0.identifier == lastSuccessfulPeripheralID }) {
                completeKnownDiscoveryGrace()
                discoveredMap[p.identifier] = p
                appendLog("AutoConnect: connecting to system-connected last-successful id=\(p.identifier.uuidString) name=\(p.name ?? "")")
                connectToDiscovered(id: p.identifier, clearsAutoConnectSuppression: false)
                return
            }

            if lastSuccessfulPeripheralID == nil,
               let p = preferredKnownPeripheral(from: connectedList) {
                completeKnownDiscoveryGrace()
                discoveredMap[p.identifier] = p
                appendLog("AutoConnect: connecting to system-connected known id=\(p.identifier.uuidString) name=\(p.name ?? "")")
                connectToDiscovered(id: p.identifier, clearsAutoConnectSuppression: false)
                return
            }

            guard knownDiscoveryGraceCompleted else {
                scheduleKnownDiscoveryFallbackIfNeeded()
                return
            }

            if let p = preferredKnownPeripheral(from: connectedList) {
                discoveredMap[p.identifier] = p
                appendLog("AutoConnect: connecting to fallback system-connected known id=\(p.identifier.uuidString) name=\(p.name ?? "")")
                connectToDiscovered(id: p.identifier, clearsAutoConnectSuppression: false)
                return
            }

            let ids = orderedAutoConnectCandidateIDs
            if !ids.isEmpty {
                let list = central.retrievePeripherals(withIdentifiers: ids)
                if let p = preferredKnownPeripheral(from: list) {
                    discoveredMap[p.identifier] = p
                    appendLog("AutoConnect: retrieve and connect known id=\(p.identifier.uuidString) name=\(p.name ?? "")")
                    connectToDiscovered(id: p.identifier, clearsAutoConnectSuppression: false)
                    return
                }
            }
            appendLog("AutoConnect: waiting for discovery of known devices")
            return
        }

        // No known devices saved: allow auto-connect to the strongest unknown nearby
        if allowAutoConnectUnknown {
            if let candidate = discoveredPeripherals.max(by: { $0.rssi < $1.rssi }) {
                appendLog("AutoConnect: connecting strongest unknown \(candidate.name) id=\(candidate.id.uuidString) rssi=\(candidate.rssi)")
                connectToDiscovered(id: candidate.id, clearsAutoConnectSuppression: false)
                return
            }
        }
        // Debounce: if nothing discovered yet, schedule a short delayed attempt
        if autoConnectPendingWorkItem == nil {
            appendLog("AutoConnect: scheduling retry in 0.8s (no candidates yet)")
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if !self.isConnected && self.knownPeripherals.isEmpty && self.allowAutoConnectUnknown && !self.autoConnectSuppressed {
                    if let candidate = self.discoveredPeripherals.max(by: { $0.rssi < $1.rssi }) {
                        self.appendLog("AutoConnect (retry): connecting strongest unknown \(candidate.name) id=\(candidate.id.uuidString) rssi=\(candidate.rssi)")
                        self.connectToDiscovered(
                            id: candidate.id,
                            clearsAutoConnectSuppression: false
                        )
                    } else {
                        self.appendLog("AutoConnect (retry): still no candidates")
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
                self.appendLog("Bluetooth poweredOn")
                if self.shouldBeScanning {
                    self.appendLog("Scanning started (state update)")
                    central.scanForPeripherals(withServices: self.supportedServiceUuids,
                                               options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
                    if !self.isConnected {
                        self.connectionStateText = "Scanning..."
                    }
                }
                self.attemptAutoConnectIfNeeded()
            case .poweredOff:
                self.appendLog("Bluetooth poweredOff; stopping scan and clearing discoveries")
                self.cancelTreadmillTestRunForConnectionInvalidation()
                self.resetProtocolState()
                self.recomputeHrStartAllowed()
                self.stopDiscoveryScan()
                self.discoveredPeripherals = []
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
        appendLog("Discovered: name=\(name.isEmpty ? "(no name)" : name) id=\(id.uuidString) rssi=\(rssi) isKnown=\(isKnown)")
        let item = DiscoveredPeripheral(id: id, name: name, rssi: rssi, isKnown: isKnown)
        DispatchQueue.main.async {
            if let idx = self.discoveredPeripherals.firstIndex(where: { $0.id == id }) {
                self.discoveredPeripherals[idx] = item
            } else {
                self.discoveredPeripherals.append(item)
            }
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
                        self.appendLog("AutoConnect (discover): scheduling connect strongest unknown in 0.8s (knownEmpty=\(self.knownPeripherals.isEmpty), allowUnknown=\(self.allowAutoConnectUnknown))")
                        self.autoConnectPendingWorkItem = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
                    }
                }
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        DispatchQueue.main.async {
            let peripheralID = peripheral.identifier
            if self.connectedPeripheralId == peripheralID {
                return
            }
            guard self.connectingPeripheralId == peripheralID else {
                self.appendLog("Ignoring unexpected connection callback for \(peripheralID.uuidString)")
                central.cancelPeripheralConnection(peripheral)
                return
            }
            if self.cancellingConnectionPeripheralId != nil || self.autoConnectSuppressed {
                if self.cancellingConnectionPeripheralId == nil {
                    self.cancellingConnectionPeripheralId = peripheralID
                }
                self.connectTimeoutWorkItem?.cancel()
                self.connectTimeoutWorkItem = nil
                self.appendLog("Rejecting completed connection after cancellation for \(peripheralID.uuidString)")
                central.cancelPeripheralConnection(peripheral)
                return
            }
            self.appendLog("Connected; discovering services…")
            self.logTrainingEvent("ble_connection_event", fields: [
                "status": "connected",
                "peripheral_id": peripheralID.uuidString,
                "name": peripheral.name ?? ""
            ])
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
            self.appendLog("Connected to \(self.deviceName) id=\(peripheral.identifier.uuidString)")
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
                self.appendLog("Ignoring stale connect failure for \(peripheral.identifier.uuidString)")
                return
            }
            let wasAutomatic = self.connectingAttemptIsAutomatic
            self.logTrainingEvent("ble_connection_event", fields: [
                "status": "failed_to_connect",
                "peripheral_id": peripheral.identifier.uuidString,
                "error": error?.localizedDescription ?? "unknown error"
            ])
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
            self.appendLog("Failed to connect to \(peripheral.identifier.uuidString): \(error?.localizedDescription ?? "unknown error")")
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
                self.appendLog("Ignoring stale disconnect for \(peripheralID.uuidString)")
                return
            }
            self.logTrainingEvent("ble_connection_event", fields: [
                "status": "disconnected",
                "peripheral_id": peripheralID.uuidString,
                "error": error?.localizedDescription ?? "none"
            ])
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
                self.appendLog("Connection attempt ended for \(peripheralID.uuidString)")
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
                self.stopTrainingStructuredLog(reason: "ble_disconnected")
            }
            self.resetProtocolState()
            self.connectedPeripheral = nil
            self.appendLog("Disconnected (error: \(error?.localizedDescription ?? "none"))")

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
            self.manualModeSet = false
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
        logTrainingEvent("ble_connection_event", fields: [
            "status": "disconnect_requested",
            "user_initiated": userInitiated
        ])
        if userInitiated {
            autoConnectSuppressed = true
        }
        cancelTreadmillTestRunForConnectionInvalidation()
        finishActiveStopObservationUnconfirmed(reason: "disconnect_requested")
        if let pendingAttemptID = unavailableStopAttempt?.id {
            finalizeUnavailableStopAttempt(attemptID: pendingAttemptID)
        }
        if isHrControlRunning {
            stopTrainingStructuredLog(reason: userInitiated ? "disconnect_user" : "disconnect")
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
        if isConnected { appendLog("Connect known skipped: already connected"); return }
        if let cancellingConnectionPeripheralId {
            appendLog("Connect known skipped: cancellation pending for \(cancellingConnectionPeripheralId.uuidString)")
            return
        }
        if let inProgress = connectingPeripheralId {
            appendLog("Connect known skipped: connection in progress to \(inProgress.uuidString)")
            if inProgress == id { return }
            return
        }
        if let p = discoveredMap[id] {
            DispatchQueue.main.async { self.connectionStateText = "Connecting..." }
            connectingPeripheralId = id
            connectingPeripheral = p
            connectingAttemptIsAutomatic = false
            connectErrorMessage = nil
            appendLog("Connecting to known discovered id=\(id.uuidString) name=\(p.name ?? "")")
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
            appendLog("Connecting to known retrieved id=\(id.uuidString) name=\(p.name ?? "")")
            central.stopScan()
            central.connect(p, options: nil)
            scheduleConnectTimeout(for: id)
        } else {
            // Fallback: start scan to find the peripheral
            shouldBeScanning = true
            central.scanForPeripherals(withServices: supportedServiceUuids,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            DispatchQueue.main.async { self.connectionStateText = "Scanning..." }
            appendLog("Connecting to known id=\(id.uuidString): scanning to discover")
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
        if isConnected { appendLog("Connect discovered skipped: already connected"); return }
        if let cancellingConnectionPeripheralId {
            appendLog("Connect discovered skipped: cancellation pending for \(cancellingConnectionPeripheralId.uuidString)")
            return
        }
        if let inProgress = connectingPeripheralId {
            // Ignore repeated taps while a connection is in progress (including same target)
            appendLog("Connect discovered skipped: connection in progress to \(inProgress.uuidString)")
            if inProgress == id { return }
            return
        }
        if let p = discoveredMap[id] {
            DispatchQueue.main.async { self.connectionStateText = "Connecting..." }
            connectingPeripheralId = id
            connectingPeripheral = p
            connectingAttemptIsAutomatic = !clearsAutoConnectSuppression
            appendLog("Connecting to discovered id=\(id.uuidString) name=\(p.name ?? "")")
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
                appendLog("Connecting to retrieved id=\(id.uuidString) name=\(p.name ?? "")")
                central.stopScan()
                central.connect(p, options: nil)
                scheduleConnectTimeout(for: id)
            } else {
                appendLog("Connect discovered failed: peripheral \(id.uuidString) not found")
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
        appendLog("EXPERIMENT WRITE \(role.rawValue) id=\(writeID.uuidString)")
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
        guard !treadmillTestRunService.isActive,
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
        if !requestProductionStop {
            resetCommandQueue(reason: "Test Run cancelled without safe Stop context")
        }
        executeTreadmillTestRunActions(transition.actions)
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
        logUiAction("GO pressed (target \(String(format: "%.1f", targetSpeed)) km/h, speed=\(String(format: "%.1f", speedKmh)), deviceTarget=\(String(format: "%.1f", deviceTargetSpeedKmh)), status=\(treadmillStatusText))")
        startWithSpeed(targetSpeed)
    }

    func manualStop() {
        logUiAction("STOP pressed (speed=\(String(format: "%.1f", speedKmh)), deviceTarget=\(String(format: "%.1f", deviceTargetSpeedKmh)), status=\(treadmillStatusText))")
        if isHrControlRunning || isNativeWorkoutRecoveryActive {
            appendLog("Manual stop while HR control active → ending training")
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
        lastCommandLine = "CMD start speed=\(String(format: "%.1f", v))"
        let shouldSendStart = speedKmh <= 0.2 && old <= 0.1
        switch treadmillProtocol {
        case .walkingPad:
            // Sequence: manual mode -> start -> set speed
            let modePacket = buildCmdPacket(cmd: 0x02, value: 0x01)
            let startPacket = buildCmdPacket(cmd: 0x04, value: 0x01)
            if !manualModeSet {
                writeCommand(
                    modePacket,
                    label: "MODE MANUAL",
                    requiresControlReadiness: true,
                    telemetryRequest: treadmillCommandRequest(
                        kind: .other("mode_manual"),
                        decision: telemetryDecision
                    )
                )
                manualModeSet = true
            }
            if shouldSendStart {
                scheduleWrite(
                    startPacket,
                    label: "START",
                    after: 0.2,
                    requiresControlReadiness: true,
                    telemetryRequest: treadmillCommandRequest(
                        kind: .other("start"),
                        decision: telemetryDecision
                    )
                )
                scheduleWrite(
                    buildWalkingPadSetSpeedPacket(kmh: v),
                    label: String(format: "SPEED %.1f km/h", v),
                    after: 0.45,
                    requiresControlReadiness: true,
                    telemetryRequest: treadmillCommandRequest(
                        kind: treadmillSetSpeedCommandKind(v),
                        decision: telemetryDecision
                    )
                )
            } else {
                scheduleWrite(
                    buildWalkingPadSetSpeedPacket(kmh: v),
                    label: String(format: "SPEED %.1f km/h", v),
                    after: 0.2,
                    requiresControlReadiness: true,
                    telemetryRequest: treadmillCommandRequest(
                        kind: treadmillSetSpeedCommandKind(v),
                        decision: telemetryDecision
                    )
                )
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
            appendLog("Start skipped: unknown treadmill protocol")
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
        lastCommandLine = "CMD stop"
        resetSessionStats()
        if treadmillProtocol == .ftms {
            enqueueFtmsRequestControlIfNeeded(decision: telemetryDecision)
        }
        guard let packet = buildTreadmillStopPacket() else {
            appendLog("STOP skipped: unknown treadmill protocol")
            return
        }
        let telemetryChain = telemetryDecision.map {
            TreadmillStopTelemetryChain(
                decisionID: $0.decisionID,
                commandID: telemetryRequest.commandID
            )
        }
        writeCommand(
            packet,
            label: "STOP",
            highPriority: true,
            telemetryRequest: telemetryRequest
        )
        scheduleWrite(
            packet,
            label: "STOP retry",
            after: 2.0,
            telemetryRequest: telemetryRequest
        )
        scheduleWrite(
            packet,
            label: "STOP retry",
            after: 4.0,
            telemetryRequest: telemetryRequest
        )
        beginStopObservation(source: "direct", telemetryChain: telemetryChain)
    }

    private func stopBeltOnce(
        telemetryDecision: TreadmillControlDecisionEvidence?,
        telemetryRequest: TreadmillCommandTelemetryRequest
    ) -> Bool {
        guard isConnected else { return false }
        let old = deviceTargetSpeedKmh
        desiredSpeedKmh = 0
        deviceTargetSpeedKmh = 0
        recordSpeedChange(from: old, to: 0, reason: "stop_belt_once")
        lastCommandLine = "CMD stop"
        resetSessionStats()
        if treadmillProtocol == .ftms {
            enqueueFtmsRequestControlIfNeeded(decision: telemetryDecision)
        }
        guard let packet = buildTreadmillStopPacket() else {
            appendLog("STOP skipped: unknown treadmill protocol")
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
        appendLog("STOP sequence (\(reason))")
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
                decisionID: $0.decisionID,
                commandID: stopCommandWasEnqueued ? telemetryRequest.commandID : nil
            )
        }
        guard wasRunning else {
            beginStopObservation(source: reason, telemetryChain: telemetryChain)
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
                )
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                guard let self else { return }
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

        case .ftms, .fitShow, .unknown:
            if let stopPacket = buildTreadmillStopPacket() {
                if treadmillProtocol == .ftms {
                    enqueueFtmsRequestControlIfNeeded(decision: telemetryDecision)
                }
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
        beginStopObservation(source: reason, telemetryChain: telemetryChain)
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
        now: Date = Date()
    ) {
        stopObservationFreshnessWorkItem?.cancel()
        stopObservationFreshnessWorkItem = nil
        finishActiveStopObservationUnconfirmed(reason: "superseded_by_new_attempt", now: now)
        if let pendingAttemptID = unavailableStopAttempt?.id {
            finalizeUnavailableStopAttempt(attemptID: pendingAttemptID)
        }
        activeTreadmillStopTelemetryChain = telemetryChain
        guard let context = currentStopObservationContext() else {
            recordUnavailableStopAttempt(source: source, attemptedAt: now)
            return
        }

        let needsOwnLog = trainingLogQueue.sync { trainingLogFileHandle == nil }
        if needsOwnLog {
            startTrainingStructuredLog(trigger: "stop_observation")
        }
        stopObservationOwnsTrainingLog = needsOwnLog

        let lifecycle = StopObservationLifecycle(
            attemptID: UUID(),
            source: source,
            attemptedAt: now,
            context: context
        )
        stopObservationLifecycle = lifecycle
        stopTruthStatusText = "stop requested • confirming"
        logTrainingEvent(
            "stop_attempt_started",
            fields: stopObservationTelemetryFields(
                lifecycle: lifecycle,
                evaluation: lifecycle.currentEvaluation(at: now),
                now: now
            )
        )
        scheduleStopObservationCheckpoints(attemptID: lifecycle.attemptID)
    }

    private func recordUnavailableStopAttempt(source: String, attemptedAt: Date) {
        let attemptID = UUID()
        let needsOwnLog = trainingLogQueue.sync { trainingLogFileHandle == nil }
        if needsOwnLog {
            startTrainingStructuredLog(trigger: "stop_observation_unavailable")
        }
        unavailableStopAttempt = UnavailableStopAttempt(
            id: attemptID,
            source: source,
            attemptedAt: attemptedAt,
            ownsTrainingLog: needsOwnLog,
            commandSentAt: nil
        )
        let transportCanSend = isConnected && commandCharacteristic != nil && buildTreadmillStopPacket() != nil
        var fields = unavailableStopAttemptFields(
            attemptID: attemptID,
            source: source,
            attemptedAt: attemptedAt,
            commandSentAt: nil
        )
        fields["stop_command_status"] = transportCanSend ? "queued" : "not_sent"
        fields["stop_final_result"] = ""
        fields["stop_unconfirmed_reason"] = transportCanSend
            ? "confirmation_context_unavailable"
            : "stop_command_not_sent_transport_unavailable"
        logTrainingEvent("stop_attempt_started", fields: fields)
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

    private func unavailableStopAttemptFields(
        attemptID: UUID,
        source: String,
        attemptedAt: Date,
        commandSentAt: Date?
    ) -> [String: Any] {
        [
            "stop_attempt_id": attemptID.uuidString,
            "stop_attempt_at": trainingLogIsoFormatter.string(from: attemptedAt),
            "stop_attempt_source": source,
            "stop_command_sent_at": commandSentAt.map { trainingLogIsoFormatter.string(from: $0) } ?? "",
            "stop_confirmed_ever": false,
            "stop_currently_confirmed": false,
            "stop_invalidation_reason": "",
            "stop_observation_sequence": 0,
            "stop_observation_count": 0,
            "stop_observation_age_s": -1,
            "stop_device_speed_raw_tenths": -1,
            "stop_device_state": -1,
            "stop_fe01_checksum_valid": false,
            "stop_fresh": false,
            "stop_confirmation_predicate": "fresh_raw_speed_zero_and_accepted_non_running_state",
            "stop_confirmation_result": StopObservationResult.missingObservation.rawValue,
            "stop_freshness_limit_s": StopObservationPolicy.freshnessInterval,
            "stop_observation_window_s": StopObservationPolicy.observationWindow
        ]
    }

    private func finalizeUnavailableStopAttempt(attemptID: UUID) {
        guard let attempt = unavailableStopAttempt, attempt.id == attemptID else { return }
        var fields = unavailableStopAttemptFields(
            attemptID: attempt.id,
            source: attempt.source,
            attemptedAt: attempt.attemptedAt,
            commandSentAt: attempt.commandSentAt
        )
        fields["stop_command_status"] = attempt.commandSentAt == nil ? "not_sent" : "sent"
        fields["stop_final_result"] = StopObservationFinalResult.unconfirmed.rawValue
        fields["stop_unconfirmed_reason"] = attempt.commandSentAt == nil
            ? "stop_command_not_sent_transport_unavailable"
            : "confirmation_context_unavailable"
        logTrainingEvent("stop_observation_finished", fields: fields)
        unavailableStopAttempt = nil
        if attempt.ownsTrainingLog {
            stopTrainingStructuredLog(
                reason: attempt.commandSentAt == nil
                    ? "stop_command_not_sent_transport_unavailable"
                    : "stop_confirmation_unavailable"
            )
        }
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
                var fields = self.stopObservationTelemetryFields(
                    lifecycle: lifecycle,
                    evaluation: evaluation,
                    now: now
                )
                fields["stop_checkpoint_delay_s"] = delay
                self.logTrainingEvent("stop_observation_checkpoint", fields: fields)

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
        logTrainingEvent(
            "stop_observation",
            fields: stopObservationTelemetryFields(
                lifecycle: lifecycle,
                evaluation: evaluation,
                now: Date()
            )
        )
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
                self.logTrainingEvent(
                    "stop_observation_freshness_expired",
                    fields: self.stopObservationTelemetryFields(
                        lifecycle: lifecycle,
                        evaluation: evaluation,
                        now: now
                    )
                )
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
        if lifecycle.finalResult == .timeoutUnconfirmed {
            stopTruthStatusText = "stop unconfirmed • timeout"
            return
        }
        if lifecycle.finalResult == .unconfirmed {
            stopTruthStatusText = lifecycle.finalReason?.hasPrefix("stop_command_not_sent") == true
                ? "stop command not sent • confirmation unavailable"
                : "stop unconfirmed"
            return
        }

        switch evaluation.result {
        case .confirmed:
            stopTruthStatusText = "stop confirmed by device"
        case .moving:
            stopTruthStatusText = "stop unconfirmed • moving"
        case .contradictory:
            stopTruthStatusText = "stop unconfirmed • contradictory"
        case .stale:
            stopTruthStatusText = "stop unconfirmed • stale"
        case .missingObservation, .commandNotSent, .beforeCommand:
            stopTruthStatusText = "stop requested • confirming"
        case .missingSpeed, .missingState, .invalidChecksum, .wrongContext, .beforeAttempt:
            stopTruthStatusText = "stop unconfirmed • evidence unavailable"
        }
    }

    private func stopObservationTelemetryFields(
        lifecycle: StopObservationLifecycle,
        evaluation: StopObservationEvaluation,
        now: Date
    ) -> [String: Any] {
        let latest = lifecycle.observations.last
        let firstConfirmedElapsed = lifecycle.firstConfirmedAt.map {
            max(0, $0.timeIntervalSince(lifecycle.attemptedAt))
        }
        let confirmedEver = lifecycle.firstConfirmedAt != nil
        return [
            "stop_attempt_id": lifecycle.attemptID.uuidString,
            "stop_attempt_at": trainingLogIsoFormatter.string(from: lifecycle.attemptedAt),
            "stop_attempt_source": lifecycle.source,
            "stop_command_sent_at": lifecycle.commandSentAt.map { trainingLogIsoFormatter.string(from: $0) } ?? "",
            "stop_command_status": lifecycle.commandStatus,
            "stop_confirmed_ever": confirmedEver,
            "stop_currently_confirmed": evaluation.isConfirmed,
            "stop_invalidation_reason": confirmedEver && !evaluation.isConfirmed
                ? evaluation.reason
                : "",
            "stop_peripheral_id": lifecycle.context.peripheralID.uuidString,
            "stop_connection_epoch": lifecycle.context.connectionEpoch.uuidString,
            "stop_notification_stream_id": lifecycle.context.notificationStreamID?.uuidString ?? "",
            "stop_observation_sequence": latest?.sequence ?? 0,
            "stop_observation_count": lifecycle.observations.count,
            "stop_observation_at": latest.map { trainingLogIsoFormatter.string(from: $0.observedAt) } ?? "",
            "stop_observation_age_s": evaluation.ageSeconds ?? -1,
            "stop_device_speed_raw_tenths": latest?.speedRawTenths ?? -1,
            "stop_device_state": latest?.state ?? -1,
            "stop_fe01_checksum_valid": latest?.checksumValid ?? false,
            "stop_fresh": evaluation.isFresh,
            "stop_confirmation_predicate": "fresh_raw_speed_zero_and_accepted_non_running_state",
            "stop_confirmation_result": evaluation.result.rawValue,
            "stop_first_confirmed_at": lifecycle.firstConfirmedAt.map { trainingLogIsoFormatter.string(from: $0) } ?? "",
            "stop_first_confirmed_elapsed_s": firstConfirmedElapsed ?? -1,
            "stop_final_result": lifecycle.finalResult?.rawValue ?? "",
            "stop_unconfirmed_reason": evaluation.isConfirmed
                ? ""
                : (lifecycle.finalReason ?? evaluation.reason),
            "stop_freshness_limit_s": StopObservationPolicy.freshnessInterval,
            "stop_observation_window_s": StopObservationPolicy.observationWindow,
            "stop_accepted_non_running_states": StopObservationPolicy.acceptedNonRunningStates.sorted(),
            "stop_evaluated_at": trainingLogIsoFormatter.string(from: now)
        ]
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
        logTrainingEvent(
            "stop_observation_finished",
            fields: stopObservationTelemetryFields(
                lifecycle: lifecycle,
                evaluation: evaluation,
                now: now
            )
        )

        switch lifecycle.finalResult {
        case .confirmed:
            break
        case .timeoutUnconfirmed:
            stopTruthStatusText = "stop unconfirmed • timeout"
            infoToastMessage = "Остановка дорожки не подтверждена. Если полотно движется, используйте физическое отключение или аварийный способ остановки."
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

        if stopObservationOwnsTrainingLog {
            stopTrainingStructuredLog(reason: lifecycle.finalResult?.rawValue ?? "stop_observation_finished")
            stopObservationOwnsTrainingLog = false
        }
        observeCurrentStopTruth(
            lifecycle: lifecycle,
            evaluation: evaluation,
            evaluatedAt: now
        )
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
        lastCommandLine = "CMD set speed=\(String(format: "%.1f", v))"
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
        lastCommandLine = "CMD adjust delta=\(String(format: "%.1f", delta)) -> \(String(format: "%.1f", v))"
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
        guard isHrControlRunning, hrRemainingSeconds > 0 else { return false }
        return hrSessionTotalSeconds < (hrMaxSessionMinutes * 60)
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
        guard isHrControlRunning, hrRemainingSeconds > 0 else { return }
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
        hrRemainingSeconds += addedSeconds
        hrProgress = hrSessionTotalSeconds > 0 ? (1.0 - (Double(hrRemainingSeconds) / Double(hrSessionTotalSeconds))) : 0
        appendLog("HR extend: +\(addedSeconds / 60)m total=\(hrSessionTotalSeconds / 60)m remaining=\(hrRemainingSeconds / 60)m")
    }

    func startHrControl() {
        guard !isHrControlRunning,
              !hasOutstandingNativeWorkoutRecovery,
              !nativeHeartRatePreflightEngine.hasStartIntent,
              !nativeHeartRateProviderLifecycle.cleanupInFlight else { return }
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
        appendLog("Native HR preflight requested: intent=\(intent.id.uuidString)")
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

    func nativeHeartRateAppBecameActive() {
        nativeHeartRateAppActivity = .active
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
        nativeHeartRateAppActivity = .inactive
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
        nativeHeartRateAppActivity = .background
        applyNativeHeartRatePreflightEffects(
            nativeHeartRatePreflightEngine.safetyChanged(
                nativeHeartRateSafetyFacts(),
                now: Date(),
                freshnessLimit: TimeInterval(hrStaleThresholdSeconds)
            )
        )
        recomputeHrStartAllowed()
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
                persistBlockedControllerUnitsStart(decision: unitsDecision)
                retryControllerUnitsQueryAfterBlockedStart()
            }
            abortNativeHeartRateFlow(reason: .superseded)
            return
        }

        let adaptiveStepDescription = hrAdaptiveStepEnabled
            ? "adaptive_levels=0.1/0.2/0.3/0.4"
            : "step=\(String(format: "%.2f", hrSpeedStepKmh))"
        appendLog("HR start: target=\(hrTargetBPM) duration=\(hrDurationMinutes)m interval=\(hrDecisionIntervalSeconds)s \(adaptiveStepDescription)")
        // Reset all per-session counters before writing session_start telemetry snapshot.
        resetSessionStats()
        let legacySessionID = startTrainingStructuredLog(trigger: "start_hr")
        isHrControlRunning = true
        hrStatusLine = "HR‑контроль запущен"
        hrSessionTotalSeconds = max(60, hrDurationMinutes * 60)
        hrRemainingSeconds = hrSessionTotalSeconds
        hrNextDecisionSeconds = hrDecisionIntervalSeconds
        hrProgress = 0
        hrControlStartedAt = controlledWorkoutStartedAt
        hrDecisionDetails = ""
        hrPredictorStatusLine = ""
        hrWorkoutRecorded = false
        hrTrendSamples.removeAll()
        hrTrendEmaBpm = nil
        hrNoDataSeconds = 0
        hrControlFailed = false
        clearCooldownRuntimeState()
        hrControlStartedBelt = false
        let adaptiveLevels: [Double] = [0.1, 0.2, 0.3, 0.4]
        logTrainingEvent("hr_control_started", fields: [
            "target_bpm": hrTargetBPM,
            "duration_s": hrSessionTotalSeconds,
            "decision_interval_s": hrDecisionIntervalSeconds,
            "adaptive_step_enabled": hrAdaptiveStepEnabled,
            "max_step_kmh": hrSpeedStepKmh,
            "adaptive_levels_kmh": adaptiveLevels,
            "start_speed_kmh": speedKmh,
            "device_target_kmh": deviceTargetSpeedKmh,
            "native_hr_preflight_latency_s": preflightLatencySeconds,
            "native_hr_acquisition_started_at": nativePreflightCommitTimestamps?.acquisitionStartedAt.timeIntervalSince1970 ?? -1,
            "native_hr_first_measured_at": nativePreflightCommitTimestamps?.measuredAt?.timeIntervalSince1970 ?? -1,
            "native_hr_first_received_at": nativePreflightCommitTimestamps?.receivedAt.timeIntervalSince1970 ?? -1
        ].merging(controllerUnitsTelemetryFields(action: "hr_control_start")) { current, _ in current })
        nativePreflightCommitTimestamps = nil
        beginTelemetryV2Session(legacySessionID: legacySessionID)
        persistQualifyingNativeHeartRateBeforeMotion()
        if deviceTargetSpeedKmh <= 0.1 && speedKmh <= 0.2 {
            hrControlStartedBelt = true
            startWithSpeed(3.0)
        } else if deviceTargetSpeedKmh <= 0.1 {
            hrControlStartedBelt = true
            startWithSpeed(desiredSpeedKmh)
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
            treadmillControlReady: isTreadmillControlReady,
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
                appendLog("Native HR session prepared")
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
        let recoveryRecord = NativeWorkoutRecoveryRecord.preflight(
            appWorkoutID: intent.id,
            targetBPM: intent.targetBPM,
            durationMinutes: intent.durationMinutes,
            acquisitionStartedAt: acquisitionStartedAt,
            profileID: activeUserProfileID
        )
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
                appendLog("Native HR collection started: intent=\(intent.id.uuidString)")
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
        let normalization = normalizeHeartRateDelivery(observation, recordedAt: now)
        appendLog("Native HR value: \(observation.beatsPerMinute)")
        logTrainingEvent("hr_sample", fields: [
            "hr_bpm": observation.beatsPerMinute,
            "source": "healthkit_selected"
        ])

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

        hrTargetBPM = intent.targetBPM
        hrDurationMinutes = intent.durationMinutes
        nativeHealthKitWorkoutCommitted = true
        nativePreflightCommitTimestamps = (
            acquisitionStartedAt: acquisitionStartedAt,
            measuredAt: observation.measuredAt,
            receivedAt: observation.receivedAt
        )
        let latency = max(0, now.timeIntervalSince(acquisitionStartedAt))
        nativeHeartRateLogger.info("first_qualifying_hr_received")
        nativeHeartRateLogger.info("preflight_committed")
        appendLog("Native HR preflight committed: latency=\(String(format: "%.3f", latency))s")
        commitExistingHrControl(preflightLatencySeconds: latency)
    }

    private func discardNativeHeartRatePreflight(
        reason: NativeHeartRatePreflightEngine.CancellationReason
    ) {
        appendLog("Native HR preflight cancelled: \(reason.rawValue)")
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
        appendLog("Native HR flow aborted before motion: \(reason.rawValue)")
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
        let elapsed = hrControlStartedAt.map { Int(Date().timeIntervalSince($0)) }
        appendLog("HR stop: elapsed=\(elapsed ?? 0)s")
        logTrainingEvent("hr_control_stop_requested", fields: [
            "reason": "manual_stop",
            "elapsed_s": elapsed ?? 0,
            "speed_kmh": speedKmh,
            "device_speed_kmh": deviceReportedSpeedKmh
        ])
        stopTrainingStructuredLog(reason: "manual_stop")
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
        recordHrWorkoutIfNeeded(durationOverride: elapsed, failed: false)
        hrControlStartedAt = nil
        hrControlStartedBelt = false
        stopBeltWithToggle(reason: "hr")
        stopLegacyWatchHeartRateIfNeeded()
        endTelemetryV2Session(reason: "manual_stop")
    }

    private func stopRecoveredNativeWorkout() {
        guard canStopPresentedWorkout else { return }
        nativeWorkoutRecoveryStopRequested = true
        nativeWorkoutRecoveryStatusText = "Завершаем восстановленную тренировку…"
        appendLog("Recovered native workout stop requested")
        stopBeltWithToggle(reason: "recovered_hr_manual_stop")
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

    private func stopLegacyWatchHeartRateIfNeeded() {
        guard !nativeHeartRateFlowOwnsController else { return }
        sendWatchCommand("stop_hr")
    }

    func clearHrFailureReports() { hrFailureReports.removeAll() }

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
            self.appendLog("Connection timeout for \(id.uuidString)")
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
        let now = Date()
        let safety = nativeHeartRateSafetyFacts(now: now)
        let preflightGatesAllowStart = safety.permitsStartIntent
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
            let wasActive = self.hrStreamingActive
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
                if active != wasActive {
                    self.appendLog("HR stream \(active ? "ACTIVE" : "INACTIVE") (bpm=\(self.heartRateBPM), last=\(hasLast ? "\(secs)s ago" : "none"))")
                    self.logTrainingEvent("hr_stream_state", fields: [
                        "active": active,
                        "hr_bpm": self.heartRateBPM,
                        "last_age_s": hasLast ? secs : -1
                    ])
                }
                self.recomputeHrStartAllowed()
                if active != wasActive && !self.nativeHeartRateFlowOwnsController {
                    self.observeHeartRateSourceLifecycle(
                        active ? .recovered : .stale
                    )
                }
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
            stepsCount += Int.random(in: 1...3)
        }

        // Simple averages
        avgSpeedActive = timeSec > 0
        if avgSpeedActive {
            avgSpeedKmh = ((avgSpeedKmh * Double(max(0, timeSec - 1))) + speedKmh) / Double(max(1, timeSec))
        }

        // Update HR averages only from real data (avoid overwriting watch values)
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

        if isHrControlRunning {
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
                hrRemainingSeconds = max(0, hrRemainingSeconds - 1)
                hrProgress = hrSessionTotalSeconds > 0 ? (1.0 - (Double(hrRemainingSeconds) / Double(hrSessionTotalSeconds))) : 0

                if hrNextDecisionSeconds > 0 {
                    hrNextDecisionSeconds -= 1
                }
                if hrNextDecisionSeconds <= 0 {
                    hrNextDecisionSeconds = hrDecisionIntervalSeconds

                    guard isTreadmillControlReady else {
                        let elapsed = hrControlStartedAt.map { Int(Date().timeIntervalSince($0)) }
                        logTrainingEvent("hr_control_failed", fields: [
                            "reason": "control_not_ready",
                            "elapsed_s": elapsed ?? 0
                        ])
                        stopTrainingStructuredLog(reason: "hr_control_not_ready")
                        hrControlFailed = true
                        infoToastMessage = "HR‑контроль остановлен — дорожка не готова к управлению. Остановка запрошена, но ещё не подтверждена."
                        appendLog("HR control stopped: treadmill control not ready")
                        isHrControlRunning = false
                        hrStatusLine = "HR‑контроль остановлен — дорожка не готова"
                        hrNextDecisionSeconds = 0
                        hrRemainingSeconds = 0
                        hrProgress = 0
                        hrDecisionDetails = ""
                        hrPredictorStatusLine = ""
                        clearCooldownRuntimeState()
                        hrNoDataSeconds = 0
                        recordHrWorkoutIfNeeded(durationOverride: elapsed, failed: true)
                        hrControlStartedAt = nil
                        hrControlStartedBelt = false
                        stopLegacyWatchHeartRateIfNeeded()
                        stopBeltWithToggle(reason: "hr_control_not_ready")
                        endTelemetryV2Session(reason: "hr_control_not_ready")
                        return
                    }
                    guard hrStreamingActive, heartRateBPM > 0 else {
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
                        let elapsed = hrControlStartedAt.map { Int(Date().timeIntervalSince($0)) }
                        logTrainingEvent("hr_control_failed", fields: [
                            "reason": "no_hr_signal",
                            "elapsed_s": elapsed ?? 0,
                            "missing_s": missingSeconds
                        ])
                        stopTrainingStructuredLog(reason: "hr_no_signal")
                        hrControlFailed = true
                        infoToastMessage = "HR‑контроль остановлен — нет данных пульса. Остановка дорожки запрошена, но ещё не подтверждена."
                        appendLog("HR control stopped: no HR for \(missingSeconds)s")
                        isHrControlRunning = false
                        hrStatusLine = "HR‑контроль остановлен — нет данных пульса"
                        hrNextDecisionSeconds = 0
                        hrRemainingSeconds = 0
                        hrProgress = 0
                        hrDecisionDetails = ""
                        hrPredictorStatusLine = ""
                        clearCooldownRuntimeState()
                        hrNoDataSeconds = 0
                        recordHrWorkoutIfNeeded(durationOverride: elapsed, failed: true)
                        hrControlStartedAt = nil
                        hrControlStartedBelt = false
                        stopLegacyWatchHeartRateIfNeeded()
                        stopBeltWithToggle(reason: "hr_no_signal")
                        endTelemetryV2Session(reason: "hr_no_signal")
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
                        appendLog("HR decision: hold target=\(String(format: "%.1f", currentTarget)) HR=\(heartRateBPM) diff=\(diff) diffPct=\(String(format: "%.1f", absDiffPercent))% deadband=\(deadbandBpm)bpm stepTag=\(stepDirectionLabel)-\(holdModeLabel) step=\(String(format: "%.1f", step))")
                        logTrainingEvent("hr_decision", fields: [
                            "decision": "hold",
                            "target_bpm": hrTargetBPM,
                            "hr_bpm": heartRateBPM,
                            "predicted_bpm": predictedBpm ?? -1,
                            "diff_bpm": diff,
                            "diff_percent": absDiffPercent,
                            "deadband_bpm": deadbandBpm,
                            "deadband_percent": adaptiveThresholds.deadband,
                            "step_kmh": step,
                            "step_tag": "\(stepDirectionLabel)-\(holdModeLabel)",
                            "speed_before_kmh": currentTarget,
                            "speed_after_kmh": currentTarget
                        ])
                        observeSemanticHeartRateDecision(
                            action: .noCommand,
                            reason: .withinTarget,
                            heartRateInputs: controlUseEvidence?.inputs ?? [],
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
                            appendLog("HR decision: inertia hold target=\(String(format: "%.1f", currentTarget)) HR=\(heartRateBPM) diff=\(diff) trend=\(String(format: "%.2f", trend)) pred=\(Int(round(predictedValue))) stepTag=\(stepDebugLabel) step=\(String(format: "%.1f", step))")
                            logTrainingEvent("hr_decision", fields: [
                                "decision": "inertia_hold",
                                "target_bpm": hrTargetBPM,
                                "hr_bpm": heartRateBPM,
                                "predicted_bpm": Int(round(predictedValue)),
                                "trend_bpm_per_s": trend,
                                "diff_bpm": diff,
                                "diff_percent": absDiffPercent,
                                "step_kmh": step,
                                "step_tag": stepDebugLabel,
                                "speed_before_kmh": currentTarget,
                                "speed_after_kmh": currentTarget
                            ])
                            observeSemanticHeartRateDecision(
                                action: .noCommand,
                                reason: .heartRateInertiaHold,
                                heartRateInputs: controlUseEvidence?.inputs ?? [],
                                occurredAt: Date()
                            )
                            return
                        }
                    }
                    let nextSpeed = clampRunningSpeedKmh(currentTarget + direction * step)
                    if nextSpeed != currentTarget {
                        let old = deviceTargetSpeedKmh
                        desiredSpeedKmh = nextSpeed
                        deviceTargetSpeedKmh = nextSpeed
                        recordSpeedChange(from: old, to: nextSpeed, reason: "hr_decision_set")
                        lastCommandLine = "CMD HR adjust -> \(String(format: "%.1f", nextSpeed))"
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
                            decision: telemetryDecision
                        )
                        hrStatusLine = diff > 0 ? "HR‑контроль: уменьшаем скорость" : "HR‑контроль: увеличиваем скорость"
                        hrDecisionDetails = "\(decisionPrefix) · шаг \(stepDebugLabel) \(String(format: "%.1f", step)) км/ч · скорость \(String(format: "%.1f", currentTarget)) → \(String(format: "%+.1f", nextSpeed - currentTarget)) км/ч"
                        appendLog("HR decision: set \(String(format: "%.1f", nextSpeed)) from \(String(format: "%.1f", currentTarget)) HR=\(heartRateBPM) diff=\(diff) stepTag=\(stepDebugLabel) step=\(String(format: "%.1f", step))")
                        logTrainingEvent("hr_decision", fields: [
                            "decision": "set",
                            "target_bpm": hrTargetBPM,
                            "hr_bpm": heartRateBPM,
                            "predicted_bpm": predictedBpm ?? -1,
                            "diff_bpm": diff,
                            "diff_percent": absDiffPercent,
                            "step_kmh": step,
                            "step_tag": stepDebugLabel,
                            "speed_before_kmh": currentTarget,
                            "speed_after_kmh": nextSpeed
                        ])
                        observeSemanticHeartRateDecision(
                            action: .enqueueSpeed(
                                DesiredSpeedKilometresPerHour(value: nextSpeed)
                            ),
                            reason: diff < 0 ? .belowTarget : .aboveTarget,
                            heartRateInputs: controlUseEvidence?.inputs ?? [],
                            occurredAt: Date()
                        )
                    } else {
                        hrStatusLine = "HR‑контроль: предел скорости"
                        hrDecisionDetails = "\(decisionPrefix) · шаг \(stepDebugLabel) \(String(format: "%.1f", step)) км/ч · скорость \(String(format: "%.1f", currentTarget)) → предел скорости"
                        appendLog("HR decision: limit target=\(String(format: "%.1f", currentTarget)) HR=\(heartRateBPM) diff=\(diff) stepTag=\(stepDebugLabel) step=\(String(format: "%.1f", step))")
                        logTrainingEvent("hr_decision", fields: [
                            "decision": "limit",
                            "target_bpm": hrTargetBPM,
                            "hr_bpm": heartRateBPM,
                            "predicted_bpm": predictedBpm ?? -1,
                            "diff_bpm": diff,
                            "diff_percent": absDiffPercent,
                            "step_kmh": step,
                            "step_tag": stepDebugLabel,
                            "speed_before_kmh": currentTarget,
                            "speed_after_kmh": currentTarget
                        ])
                        observeSemanticHeartRateDecision(
                            action: .noCommand,
                            reason: .heartRateSpeedLimit,
                            heartRateInputs: controlUseEvidence?.inputs ?? [],
                            occurredAt: Date()
                        )
                    }
                }
            } else if cooldownRuntimeState == nil {
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
                let elapsed = hrControlStartedAt.map { Int(Date().timeIntervalSince($0)) }
                applyCooldownOutput(output, sessionElapsedSeconds: elapsed)
            } else if let cooldownState = cooldownRuntimeState {
                hrNextDecisionSeconds = 0
                let output = telemetryPerformanceObservation.measureControlCycle {
                    CooldownRuntimeEngine.tick(
                        state: cooldownState,
                        config: currentCooldownConfig(),
                        input: CooldownRuntimeEngine.TickInput(
                            hrBpm: heartRateBPM,
                            decisionBpm: heartRateBPM > 0 ? heartRateBPM : hrCooldownTargetBpm,
                            hrAvailable: heartRateBPM > 0,
                            speedSnapshot: currentCooldownSpeedSnapshot(),
                            sessionAggregates: currentCooldownSessionAggregates()
                        )
                    )
                }
                let elapsed = hrControlStartedAt.map { Int(Date().timeIntervalSince($0)) }
                applyCooldownOutput(output, sessionElapsedSeconds: elapsed)
            }
        }
        updateTreadmillStatus()
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

        var observedLegacyCommandTimeout = false
        if lastCommandAwaitingAck, let sentAt = lastCommandSentAt {
            if now.timeIntervalSince(sentAt) > commandAckTimeoutSeconds {
                lastCommandAwaitingAck = false
                lastCommandTimeouts += 1
                lastCommandTimeoutsCount = lastCommandTimeouts
                observedLegacyCommandTimeout = true
                appendLog("CMD ack timeout: \(lastCommandLine)")
                logTrainingEvent("command_ack_timeout", fields: [
                    "last_command": lastCommandLine,
                    "timeouts_count": lastCommandTimeouts
                ])
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
        telemetryRequest: TreadmillCommandTelemetryRequest? = nil
    ) {
#if STOP_TRUTH_EXPERIMENT_CAPABILITY
        guard stopTruthExperimentController?.isActive != true else {
            appendLog("Production command blocked while fixed Stop-truth experiment is active: \(label)")
            return
        }
#endif
        enqueueCommand(
            data,
            label: label,
            highPriority: highPriority,
            requiresControlReadiness: requiresControlReadiness,
            telemetryRequest: telemetryRequest
        )
    }

    private func isSpeedCommandLabel(_ label: String) -> Bool {
        label.lowercased().hasPrefix("speed")
    }

    @discardableResult
    private func resetCommandQueue(
        reason: String,
        observeTelemetryImmediately: Bool = true
    ) -> [TreadmillCommandEnqueuedEvidence] {
        let dropped = CommandQueueService.clear(queue: &commandQueue)
        commandQueueEpoch += 1
        isCommandQueueProcessing = false
        nextCommandAllowedAt = .distantPast
        appendLog("CMD queue reset: \(reason)")
        logTrainingEvent("command_queue_reset", fields: [
            "reason": reason,
            "dropped_count": dropped
        ])
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
        telemetryRequest: TreadmillCommandTelemetryRequest?
    ) {
        let command = CommandQueueService.Command(
            data: data,
            label: label,
            requiresControlReadiness: requiresControlReadiness
        )
        let request = telemetryRequest ?? treadmillCommandRequest(kind: .other(label))
        let telemetryEvidence = treadmillTelemetryConnectionEpoch.map {
            TreadmillCommandEnqueuedEvidence(
                commandID: request.commandID,
                decisionID: request.decisionID,
                kind: request.kind,
                protocolKind: treadmillTelemetryProtocolKind,
                connectionEpoch: $0,
                enqueuedAt: Date()
            )
        }
        if highPriority {
            let cancelled = resetCommandQueue(
                reason: "high priority → \(label)",
                observeTelemetryImmediately: false
            )
            CommandQueueService.replaceWithHighPriority(queue: &commandQueue, command: command)
            var superseded: [TreadmillCommandEnqueuedEvidence] = []
            if let telemetryEvidence {
                superseded = treadmillCommandTelemetrySidecar.replaceWithHighPriority(
                    label: label,
                    evidence: telemetryEvidence
                )
            }
            processCommandQueue()
            observeCancelledTreadmillCommands(
                cancelled,
                reason: .other("legacy_queue_reset")
            )
            observeSupersededTreadmillCommands(superseded)
            if let telemetryEvidence {
                observeTreadmillTelemetry(.commandEnqueued(telemetryEvidence))
            }
            return
        }

        let result = CommandQueueService.enqueueRegular(
            queue: &commandQueue,
            command: command,
            isSpeedLabel: isSpeedCommandLabel
        )
        var superseded: [TreadmillCommandEnqueuedEvidence] = []
        if let telemetryEvidence {
            superseded = treadmillCommandTelemetrySidecar.enqueueRegular(
                label: label,
                evidence: telemetryEvidence,
                isSpeedLabel: isSpeedCommandLabel
            )
        }
        if result.coalescedSpeedCount > 0 {
            logTrainingEvent("command_speed_coalesced", fields: [
                "new_label": label,
                "dropped_count": result.coalescedSpeedCount,
                "queue_size_after": commandQueue.count
            ])
        }
        processCommandQueue()
        observeSupersededTreadmillCommands(superseded)
        if let telemetryEvidence {
            observeTreadmillTelemetry(.commandEnqueued(telemetryEvidence))
        }
    }

    private func observeCancelledTreadmillCommands(
        _ commands: [TreadmillCommandEnqueuedEvidence],
        reason: CommandCancellationReason
    ) {
        for command in commands {
            observeTreadmillTelemetry(
                .commandCancelled(
                    TreadmillCommandCancellationObservation(
                        commandID: command.commandID,
                        decisionID: command.decisionID,
                        connectionEpoch: command.connectionEpoch,
                        occurredAt: Date(),
                        reason: reason
                    )
                )
            )
        }
    }

    private func observeSupersededTreadmillCommands(
        _ commands: [TreadmillCommandEnqueuedEvidence]
    ) {
        for command in commands {
            observeTreadmillTelemetry(
                .commandCancelled(
                    TreadmillCommandCancellationObservation(
                        commandID: command.commandID,
                        decisionID: command.decisionID,
                        connectionEpoch: command.connectionEpoch,
                        occurredAt: Date(),
                        reason: .superseded
                    )
                )
            )
        }
    }

    private func processCommandQueue() {
        guard !isCommandQueueProcessing else { return }
        guard !commandQueue.isEmpty else { return }
        isCommandQueueProcessing = true
        let now = Date()
        let delay = max(0, nextCommandAllowedAt.timeIntervalSince(now))
        if delay > 0 {
            appendLog(String(format: "WRITE QUEUED (%.1fs): %@", delay, commandQueue.first?.label ?? ""))
            logTrainingEvent("command_queued", fields: [
                "delay_s": delay,
                "label": commandQueue.first?.label ?? "",
                "queue_size": commandQueue.count
            ])
        }
        let epoch = commandQueueEpoch
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.commandQueueEpoch == epoch else {
                self.isCommandQueueProcessing = false
                self.nativeWorkoutStopTransportInvocationFailedIfNeeded(
                    reason: "Очередь Stop была сброшена"
                )
                return
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
            var postWriteTelemetry: [TreadmillTelemetryEvidence] = []
            switch self.treadmillCommandTelemetrySidecar.dequeue(
                expectedLabel: next.label,
                currentEpoch: self.treadmillTelemetryConnectionEpoch
            ) {
            case .matched(let evidence):
                telemetryEvidence = evidence
            case .staleEpoch(let evidence):
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
            case .correlationLost(let evidence):
                telemetryEvidence = nil
                postWriteTelemetry.append(
                    contentsOf: evidence.map {
                        .commandCancelled(
                            TreadmillCommandCancellationObservation(
                                commandID: $0.commandID,
                                decisionID: $0.decisionID,
                                connectionEpoch: $0.connectionEpoch,
                                occurredAt: Date(),
                                reason: .other("telemetry_sidecar_order_mismatch")
                            )
                        )
                    }
                )
            case .missing:
                telemetryEvidence = nil
            }
            postWriteTelemetry.append(
                contentsOf: self.performWrite(
                    next.data,
                    label: next.label,
                    requiresControlReadiness: next.requiresControlReadiness,
                    telemetryEvidence: telemetryEvidence
                )
            )
            self.nextCommandAllowedAt = Date().addingTimeInterval(self.commandMinIntervalSecondsForCurrentProtocol())
            self.isCommandQueueProcessing = false
            if !self.commandQueue.isEmpty {
                self.processCommandQueue()
            }
            for evidence in postWriteTelemetry {
                self.observeTreadmillTelemetry(evidence)
            }
        }
    }

    private func performWrite(
        _ data: Data,
        label: String,
        requiresControlReadiness: Bool,
        telemetryEvidence: TreadmillCommandEnqueuedEvidence?
    ) -> [TreadmillTelemetryEvidence] {
        if requiresControlReadiness && !isTreadmillControlReady {
            appendLog("WRITE SKIPPED (control not ready): \(label)")
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
            appendLog("WRITE SKIPPED (not connected): \(label)")
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
            appendLog("WRITE SKIPPED (no characteristic): \(label)")
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
        appendLog("WRITE \(label): \(hex(data)) via \(ch.uuid.uuidString) type=\(type == .withoutResponse ? "withoutResponse" : "withResponse")")
        logTrainingEvent("command_write", fields: [
            "label": label,
            "hex": hex(data),
            "char_uuid": ch.uuid.uuidString,
            "write_type": type == .withoutResponse ? "without_response" : "with_response",
            "ack_expected": type == .withResponse,
            "queue_size": commandQueue.count
        ])
        trackExpectedSpeedIfNeeded(label: label)
        p.writeValue(data, for: ch, type: type)
        if label == "STOP" {
            nativeWorkoutStopTransportInvokedIfNeeded()
        }
        let sentAt = lastCommandSentAt ?? Date()
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
            logTrainingEvent(
                "stop_command_sent",
                fields: stopObservationTelemetryFields(
                    lifecycle: lifecycle,
                    evaluation: lifecycle.currentEvaluation(at: sentAt),
                    now: sentAt
                )
            )
        }
        if var attempt = unavailableStopAttempt, attempt.commandSentAt == nil {
            attempt.commandSentAt = sentAt
            unavailableStopAttempt = attempt
            var fields = unavailableStopAttemptFields(
                attemptID: attempt.id,
                source: attempt.source,
                attemptedAt: attempt.attemptedAt,
                commandSentAt: sentAt
            )
            fields["stop_command_status"] = "sent"
            fields["stop_final_result"] = ""
            fields["stop_unconfirmed_reason"] = "confirmation_context_unavailable"
            logTrainingEvent("stop_command_sent", fields: fields)
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

    private func trackExpectedSpeedIfNeeded(label: String) {
        let lower = label.lowercased()
        if lower.contains("speed") {
            if lower.contains("stop") {
                expectedSpeedKmh = 0
                expectedSpeedSetAt = Date()
                expectedSpeedSource = label
                return
            }
            if let value = extractSpeedFromLabel(label) {
                expectedSpeedKmh = value
                expectedSpeedSetAt = Date()
                expectedSpeedSource = label
            }
        }
    }

    private func extractSpeedFromLabel(_ label: String) -> Double? {
        let parts = label.split(separator: " ")
        for part in parts {
            if let v = Double(part) { return v }
            let cleaned = part.trimmingCharacters(in: CharacterSet(charactersIn: "0123456789.").inverted)
            if let v = Double(cleaned) { return v }
        }
        return nil
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
        ftmsHasControl = false
        ftmsControlRequestInFlight = false
        ftmsControlRequestConnection = nil
        ftmsDidReadSupportedSpeedRange = false
        fitShowDidRequestInitialStatus = false
        commandCharacteristic = nil
        commandCharacteristicConnection = nil
        notifyCharacteristic = nil
        notifyCharacteristicConnection = nil
        rememberedValidatedTreadmillConnection = nil
        characteristicConnections.removeAll()
        extraNotifyCharacteristics.removeAll()
        lastLoggedActualSpeedKmh = nil
        treadmillMinSpeedKmh = 0.5
        treadmillMaxSpeedKmh = 12.0
        treadmillSpeedIncrementKmh = 0.1
        controllerUnitsConnectionEpoch = nil
        stopObservationStreamID = nil
        stopObservationCheckpointWorkItems.forEach { $0.cancel() }
        stopObservationCheckpointWorkItems.removeAll()
        stopObservationFreshnessWorkItem?.cancel()
        stopObservationFreshnessWorkItem = nil
        stopObservationLifecycle = nil
        stopObservationOwnsTrainingLog = false
        unavailableStopAttempt = nil
        stopTruthStatusText = ""
        controllerUnitsTruthTracker.disconnect()
        controllerUnitsTruth = controllerUnitsTruthTracker.state
        lastControllerUnitsQueryAt = nil
        lastControllerUnitsQueryTrigger = nil
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
        let ready = TreadmillControlReadinessPolicy.isReady(
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
        ftmsHasControl = false
        ftmsControlRequestInFlight = false
        ftmsControlRequestConnection = nil
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

    private func controllerUnitsTelemetryFields(
        action: String,
        now: Date = Date(),
        decision: ControllerUnitsGateDecision? = nil
    ) -> [String: Any] {
        let gateDecision = decision ?? controllerUnitsGateDecision(now: now)
        let age = controllerUnitsTruth.age(at: now)
        let queryAge = lastControllerUnitsQueryAt.map { max(0, now.timeIntervalSince($0)) }
        let fresh = controllerUnitsTruth.status == .valid
            && controllerUnitsTruth.connectionEpoch == controllerUnitsConnectionEpoch
            && (age.map { $0 <= ControllerUnitsSafetyPolicy.freshnessInterval } ?? false)
        return [
            "controller_units_action": action,
            "controller_units_motion_path": gateDecision.path.rawValue,
            "controller_units_query_requested": lastControllerUnitsQueryAt != nil,
            "controller_units_query_trigger": lastControllerUnitsQueryTrigger ?? "",
            "controller_units_query_age_s": queryAge ?? -1,
            "controller_units": controllerUnitsTruth.units.rawValue,
            "controller_units_status": controllerUnitsTruth.status.rawValue,
            "controller_units_checksum_ok": controllerUnitsTruth.status == .valid,
            "controller_units_fresh": fresh,
            "controller_units_age_s": age ?? -1,
            "controller_units_freshness_limit_s": ControllerUnitsSafetyPolicy.freshnessInterval,
            "controller_units_gate_allowed": gateDecision.allowed,
            "controller_units_block_reason": gateDecision.blockReason?.rawValue ?? ""
        ]
    }

    private func recordControllerUnitsGate(action: String, decision: ControllerUnitsGateDecision) {
        let fields = controllerUnitsTelemetryFields(action: action, decision: decision)
        let ageValue = fields["controller_units_age_s"] ?? -1
        let blockReason = decision.blockReason?.rawValue ?? "none"
        appendLog(
            "Controller units gate: action=\(action) units=\(controllerUnitsTruth.units.rawValue) " +
            "status=\(controllerUnitsTruth.status.rawValue) age_s=\(ageValue) " +
            "allowed=\(decision.allowed) block=\(blockReason)"
        )
        logTrainingEvent("controller_units_gate", fields: fields)
    }

    private func persistBlockedControllerUnitsStart(decision: ControllerUnitsGateDecision) {
        guard !isHrControlRunning else {
            recordControllerUnitsGate(action: "hr_control_start", decision: decision)
            return
        }
        startTrainingStructuredLog(trigger: "start_hr_units_blocked")
        recordControllerUnitsGate(action: "hr_control_start", decision: decision)
        stopTrainingStructuredLog(reason: decision.blockReason?.rawValue ?? "controller_units_blocked")
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
        appendLog("Controller units query: trigger=\(trigger) command=A6 key=0 read_only=true")
        logTrainingEvent("controller_units_query_requested", fields: [
            "trigger": trigger,
            "command_family": "A6",
            "key": 0,
            "read_only": true
        ])
        writeCommand(BLETransportCodec.buildWalkingPadQueryParamsPacket(), label: "QUERY PARAMS")
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
        appendLog("Subscribing \(label) on \(characteristic.uuid.uuidString)")
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
        guard !ftmsHasControl else { return }
        guard !ftmsControlRequestInFlight else { return }
        guard let ch = commandCharacteristic, ch.uuid == ftmsCharControlPoint else {
            appendLog("FTMS request control skipped: control point not ready")
            return
        }
        guard let connection = currentTreadmillControlConnection,
              commandCharacteristicConnection == connection else {
            appendLog("FTMS request control skipped: stale control point context")
            return
        }
        ftmsControlRequestInFlight = true
        ftmsControlRequestConnection = connection
        writeCommand(
            buildFtmsRequestControlPacket(),
            label: "FTMS REQUEST CONTROL",
            telemetryRequest: treadmillCommandRequest(
                kind: .other("request_control"),
                decision: decision
            )
        )
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
        decision: TreadmillControlDecisionEvidence? = nil
    ) {
        guard !blocksNonStopTreadmillMotion else {
            appendLog("Set speed skipped: native workout recovery is fail-closed")
            return
        }
        guard isTreadmillControlReady else {
            appendLog("Set speed skipped: treadmill control not ready")
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
                )
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
                    )
                )
            }
            writeCommand(
                buildFtmsSetSpeedPacket(kmh: kmh),
                label: label,
                requiresControlReadiness: true,
                telemetryRequest: treadmillCommandRequest(
                    kind: treadmillSetSpeedCommandKind(kmh),
                    decision: decision
                )
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
                    )
                )
            }
            writeCommand(
                buildFitShowSetSpeedPacket(kmh: kmh, incline: 0),
                label: label,
                requiresControlReadiness: true,
                telemetryRequest: treadmillCommandRequest(
                    kind: treadmillSetSpeedCommandKind(kmh),
                    decision: decision
                )
            )
        case .unknown:
            appendLog("Set speed skipped: unknown treadmill protocol (speed=\(String(format: "%.1f", kmh)))")
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
        let cmdHex = String(format: "0x%02X", frame.cmd)
        let subHex = frame.subcmd.map { String(format: "0x%02X", $0) } ?? "-"

        // Update "ack" and keep raw for debugging.
        DispatchQueue.main.async {
            self.deviceReportedRawHex = frame.rawHex
            self.deviceReportedChecksumOk = frame.checksumOk
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
                appendLog("Notify FitShow speed: speed=\(String(format: "%.1f", speedKmh)) km/h incline=\(incline) checksum=\(frame.checksumOk ? "ok" : "bad")")
                logActualSpeedChangeIfNeeded(speedKmh, source: "fitshow_notify")
                logTrainingEvent("notify_fitshow_speed", fields: [
                    "speed_kmh": speedKmh,
                    "incline": incline,
                    "checksum_ok": frame.checksumOk
                ])
                return
            }
        }

        if frame.cmd == 0x51 {
            // Status response.
            guard !frame.payload.isEmpty else {
                appendLog("Notify FitShow status: empty payload checksum=\(frame.checksumOk ? "ok" : "bad")")
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
            appendLog("Notify FitShow status: state=\(state) speed=\(speedKmh.map { String(format: "%.1f", $0) } ?? "-") km/h checksum=\(frame.checksumOk ? "ok" : "bad")")
            logTrainingEvent("notify_fitshow_status", fields: [
                "state": state,
                "speed_kmh": speedKmh ?? -1,
                "checksum_ok": frame.checksumOk
            ])
            return
        }

        appendLog("Notify FitShow frame: cmd=\(cmdHex) sub=\(subHex) len=\(frame.payload.count) checksum=\(frame.checksumOk ? "ok" : "bad")")
        logTrainingEvent("notify_fitshow_frame", fields: [
            "cmd": Int(frame.cmd),
            "subcmd": frame.subcmd.map(Int.init) ?? -1,
            "len": frame.payload.count,
            "checksum_ok": frame.checksumOk
        ])
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
        logTrainingEvent("speed_target_changed", fields: [
            "reason": reason,
            "speed_before_kmh": old,
            "speed_after_kmh": new,
            "speed_delta_kmh": delta
        ])
    }

    private func logActualSpeedChangeIfNeeded(_ newSpeedKmh: Double, source: String) {
        if let previous = lastLoggedActualSpeedKmh, abs(newSpeedKmh - previous) < 0.05 {
            return
        }
        let previous = lastLoggedActualSpeedKmh
        lastLoggedActualSpeedKmh = newSpeedKmh
        logTrainingEvent("speed_actual_changed", fields: [
            "source": source,
            "speed_before_kmh": previous ?? newSpeedKmh,
            "speed_after_kmh": newSpeedKmh,
            "speed_delta_kmh": (previous != nil) ? (newSpeedKmh - (previous ?? newSpeedKmh)) : 0.0
        ])
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
#if canImport(UIKit)
        let deviceModel: String? = UIDevice.current.model
#else
        let deviceModel: String? = nil
#endif
        let descriptor = TelemetryV2SessionDescriptor(
            sessionID: sessionID,
            deterministicLegacySessionID: legacySessionID,
            startedAt: startedAt,
            appContext: AppRuntimeContext(
                appVersion: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String ?? "unknown",
                buildNumber: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleVersion"
                ) as? String ?? "unknown",
                operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                deviceModel: deviceModel
            ),
            configuration: TelemetryV2ConfigurationInput(
                profileLocalIdentifier: activeUserProfile?.id.uuidString ?? "unknown",
                workoutMode: .heartRateControlled,
                targetHeartRate: hrTargetBPM,
                durationMinutes: hrDurationMinutes,
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
            versions: RuntimeVersionContext(
                telemetrySchema: TelemetrySchemaVersion(rawValue: "1.0.0"),
                algorithm: AlgorithmVersion(rawValue: "legacy-hr-control-2026-08"),
                safetyPolicy: SafetyPolicyVersion(rawValue: "walkingpad-runtime-safety-2026-08"),
                workoutProtocol: WorkoutProtocolVersion(rawValue: "hr-workout-v1")
            ),
            heartRateFreshnessLimitSeconds: TimeInterval(hrStaleThresholdSeconds),
            treadmillFreshnessLimitSeconds: ControllerUnitsSafetyPolicy.freshnessInterval
        )
        telemetryV2Coordinator.beginSession(descriptor)
    }

    private func endTelemetryV2Session(reason: String) {
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
                    guard linkNativeHealthKitWorkout(
                        uuid: workout.uuid,
                        record: completedRecord
                    ) else {
                        throw IPhoneHealthKitHeartRateProviderError.operationCancelled
                    }
                    appendLog("Native HealthKit workout linked: \(workout.uuid.uuidString)")
                    nativeHeartRateLogger.info("workout_finished_direct_link")
                    terminalSaveProven = true
                case .savedWorkoutUnavailable:
                    guard let completedRecord = activeNativeWorkoutRecoveryRecord,
                          let terminalRequestedAt = completedRecord.terminalRequestedAt,
                          let healthKitStoppedAt = completedRecord.healthKitStopActivityAt else {
                        throw IPhoneHealthKitHeartRateProviderError.operationCancelled
                    }
                    appendLog("Native HealthKit finish returned no workout; exact saved proof pending")
                    retainDeferredNativeHealthKitLinkage(
                        record: completedRecord,
                        finishRequestedAt: terminalRequestedAt,
                        healthKitStoppedAt: healthKitStoppedAt
                    )
                    resolveDeferredNativeHealthKitLinkageIfPossible()
                    nativeHeartRateLogger.info("workout_finish_proof_deferred")
                    terminalProofPending = true
                }
            } catch {
                appendLog("Native HealthKit workout finish failed: \(error.localizedDescription)")
                nativeHeartRateLogger.error("workout_finish_failed")
            }
        }
    }

    private func retainDeferredNativeHealthKitLinkage(
        record: NativeWorkoutRecoveryRecord,
        finishRequestedAt: Date,
        healthKitStoppedAt: Date
    ) {
        let linkage = DeferredNativeHealthKitLinkage(
            acquisitionStartedAt: record.acquisitionStartedAt,
            finishRequestedAt: finishRequestedAt,
            healthKitStoppedAt: healthKitStoppedAt,
            profileID: record.profileID,
            telemetrySessionID: record.telemetrySessionID,
            linksLegacyWorkout: record.legacyWorkoutID != nil,
            legacyWorkoutID: record.legacyWorkoutID,
            recoveryAppWorkoutID: record.appWorkoutID
        )
        if !deferredNativeHealthKitLinkages.contains(linkage) {
            deferredNativeHealthKitLinkages.append(linkage)
        }
        if let data = try? JSONEncoder().encode(deferredNativeHealthKitLinkages) {
            UserDefaults.standard.set(data, forKey: deferredNativeHealthKitLinkageStoreKey)
        }
    }

    private func clearDeferredNativeHealthKitLinkage(
        _ linkage: DeferredNativeHealthKitLinkage
    ) {
        deferredNativeHealthKitLinkages.removeAll { $0 == linkage }
        if deferredNativeHealthKitLinkages.isEmpty {
            UserDefaults.standard.removeObject(forKey: deferredNativeHealthKitLinkageStoreKey)
        } else if let data = try? JSONEncoder().encode(deferredNativeHealthKitLinkages) {
            UserDefaults.standard.set(data, forKey: deferredNativeHealthKitLinkageStoreKey)
        }
    }

    private func resolveDeferredNativeHealthKitLinkageIfPossible() {
        guard nativeHeartRateAppActivity == .active,
              !nativeHealthKitLinkageQueryInFlight else { return }
        if deferredNativeHealthKitLinkages.isEmpty,
           let data = UserDefaults.standard.data(forKey: deferredNativeHealthKitLinkageStoreKey) {
            deferredNativeHealthKitLinkages = (try? JSONDecoder().decode(
                [DeferredNativeHealthKitLinkage].self,
                from: data
            )) ?? []
        }
        guard let linkage = deferredNativeHealthKitLinkages.first else { return }

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
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                nativeHealthKitLinkageQueryInFlight = false
                guard error == nil else {
                    nativeHeartRateLogger.error("deferred_link_query_failed")
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
                guard let workout else { return }
                guard linkDeferredNativeHealthKitWorkout(
                    uuid: workout.uuid,
                    linkage: linkage
                ) else { return }
                appendLog("Deferred native HealthKit workout linked: \(workout.uuid.uuidString)")
                nativeHeartRateLogger.info("deferred_link_resolved")
                clearDeferredNativeHealthKitLinkage(linkage)
                completeRecoveredFinishIfProven(linkage: linkage)
                resolveDeferredNativeHealthKitLinkageIfPossible()
            }
        }
        healthStore.execute(query)
    }

    @discardableResult
    private func linkDeferredNativeHealthKitWorkout(
        uuid: UUID,
        linkage: DeferredNativeHealthKitLinkage
    ) -> Bool {
        if linkage.linksLegacyWorkout {
            guard let profileID = linkage.profileID,
                  let legacyWorkoutID = linkage.legacyWorkoutID else {
                return false
            }
            var entries = loadLegacyShadowWorkoutHistory(profileID: profileID)
            guard let index = entries.firstIndex(where: { $0.id == legacyWorkoutID }) else {
                return false
            }
            let entry = entries[index]
            guard NativeWorkoutLegacyLinkPolicy.canLink(
                existingWorkoutUUID: entry.healthkitWorkoutUUID,
                expectedWorkoutUUID: uuid
            ) else {
                return false
            }
            if entry.healthkitWorkoutUUID == nil {
                entries[index] = LegacyShadowWorkoutEntry(
                    id: entry.id,
                    date: entry.date,
                    beatsPerMeter: entry.beatsPerMeter,
                    targetBpm: entry.targetBpm,
                    durationSeconds: entry.durationSeconds,
                    avgBpm: entry.avgBpm,
                    avgSpeedKmh: entry.avgSpeedKmh,
                    healthkitWorkoutUUID: uuid.uuidString,
                    zoneSeconds: entry.zoneSeconds
                )
                saveLegacyShadowWorkoutHistory(entries, profileID: profileID)
                if activeUserProfileID == profileID {
                    legacyShadowWorkoutHistory = entries
                }
            }
        }

        if let telemetrySessionID = linkage.telemetrySessionID {
            associateHealthKitWorkoutWithTelemetryV2(
                sessionID: SessionID(rawValue: telemetrySessionID),
                workoutIdentifier: uuid
            )
        }
        return true
    }

    @discardableResult
    private func linkNativeHealthKitWorkout(
        uuid: UUID,
        record: NativeWorkoutRecoveryRecord
    ) -> Bool {
        linkDeferredNativeHealthKitWorkout(
            uuid: uuid,
            linkage: DeferredNativeHealthKitLinkage(
                acquisitionStartedAt: record.acquisitionStartedAt,
                finishRequestedAt: record.terminalRequestedAt ?? Date.distantPast,
                healthKitStoppedAt: record.healthKitStopActivityAt,
                profileID: record.profileID,
                telemetrySessionID: record.telemetrySessionID,
                linksLegacyWorkout: record.legacyWorkoutID != nil,
                legacyWorkoutID: record.legacyWorkoutID,
                recoveryAppWorkoutID: record.appWorkoutID
            )
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
        _ = treadmillTelemetrySink?.observeTreadmillEvidence(evidence)
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
            )
        )
    }

    private func observeHeartRateDelivery(
        _ decoded: DecodedWatchHeartRatePayload,
        receivedAt: Date
    ) -> HeartRateTelemetrySinkDisposition {
        let result = heartRateObservationNormalizer.normalize(
            HeartRateProviderObservation(
                source: legacyWatchHeartRateSource,
                beatsPerMinute: decoded.beatsPerMinute,
                providerSequence: decoded.providerSequence,
                providerNativeIdentity: nil,
                measuredAt: nil,
                sourceCallbackObservedAt: decoded.sourceCallbackObservedAt,
                sourceClockRelationship: .independent,
                receivedAt: receivedAt,
                metadataQuality: decoded.quality
            ),
            canonicalObservationID: HeartRateCanonicalObservationID(),
            deliveryID: HeartRateDeliveryID(),
            recordedAt: Date()
        )
        latestHeartRateDelivery = result.delivery
        attachTelemetryDeliveryToLatestHrTrendSample(result.delivery)
        return heartRateTelemetrySink?.observeHeartRate(result) ?? .unavailable
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

    private func observeHeartRateSourceLifecycle(
        _ transition: HeartRateSourceLifecycleInput,
        occurredAt: Date = Date()
    ) {
        guard let evidence = heartRateObservationNormalizer.observeLifecycle(
            transition,
            source: legacyWatchHeartRateSource,
            occurredAt: occurredAt
        ) else { return }
        _ = heartRateTelemetrySink?.observeSourceLifecycle(evidence)
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
        occurredAt: Date
    ) {
        _ = telemetryV2Coordinator.observeHeartRateControlDecision(
            targetBeatsPerMinute: UInt16(clamping: hrTargetBPM),
            action: action,
            reason: reason,
            heartRateInputs: heartRateInputs,
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

    private func recordHrWorkoutIfNeeded() {
        recordHrWorkoutIfNeeded(durationOverride: nil, failed: nil)
    }

    private func recordHrWorkoutIfNeeded(durationOverride: Int?, failed: Bool?) {
        guard !hrWorkoutRecorded else { return }
        let actualDuration: Int = {
            if let override = durationOverride { return max(0, override) }
            if let start = hrControlStartedAt {
                return max(0, Int(Date().timeIntervalSince(start)))
            }
            let elapsed = max(0, hrSessionTotalSeconds - hrRemainingSeconds)
            return elapsed > 0 ? elapsed : timeSec
        }()
        if failed ?? hrControlFailed {
            appendLog("Workout not saved: failed (duration \(actualDuration)s)")
            logTrainingEvent("workout_not_saved", fields: [
                "reason": "failed",
                "duration_s": actualDuration
            ])
            return
        }
        let minDuration = max(0, workoutMinSaveMinutes * 60)
        guard actualDuration >= minDuration else {
            appendLog("Workout not saved: duration \(actualDuration)s < \(minDuration)s")
            logTrainingEvent("workout_not_saved", fields: [
                "reason": "min_duration",
                "duration_s": actualDuration,
                "min_duration_s": minDuration
            ])
            return
        }
        let averageSpeed = (avgSpeedActive && avgSpeedKmh > 0.05) ? avgSpeedKmh : nil
        let workoutProfileID = activeUserProfileID
        let attachedHealthkitWorkoutUUID = pendingHealthkitWorkoutUUID
        let telemetryV2SessionID = activeTelemetryV2SessionID
        let entry = LegacyShadowWorkoutEntry(
            id: UUID(),
            date: Date(),
            beatsPerMeter: beatsPerMeter,
            targetBpm: hrTargetBPM,
            durationSeconds: actualDuration,
            avgBpm: hrAverageBPM,
            avgSpeedKmh: averageSpeed,
            healthkitWorkoutUUID: attachedHealthkitWorkoutUUID,
            zoneSeconds: hrZoneSeconds
        )
        if nativeHealthKitWorkoutCommitted,
           let recoveryRecord = activeNativeWorkoutRecoveryRecord,
           !persistNativeWorkoutRecoveryRecord(
                recoveryRecord.linkingLegacyWorkout(id: entry.id)
           ) {
            appendLog("Workout not saved: recovery linkage persistence failed")
            return
        }
        legacyShadowWorkoutHistory.insert(entry, at: 0)
        pendingHealthkitWorkoutUUID = nil
        pendingHealthkitWorkoutProfileID = attachedHealthkitWorkoutUUID == nil ? workoutProfileID : nil
        pendingHealthkitTelemetryV2SessionID = attachedHealthkitWorkoutUUID == nil
            ? telemetryV2SessionID
            : nil
        hrWorkoutRecorded = true
        saveLegacyShadowWorkoutHistory()
        if let attachedHealthkitWorkoutUUID,
           let workoutIdentifier = UUID(uuidString: attachedHealthkitWorkoutUUID),
           let telemetryV2SessionID {
            associateHealthKitWorkoutWithTelemetryV2(
                sessionID: telemetryV2SessionID,
                workoutIdentifier: workoutIdentifier
            )
        }
        logTrainingEvent("workout_saved", fields: [
            "workout_id": entry.id.uuidString,
            "duration_s": actualDuration,
            "target_bpm": hrTargetBPM,
            "avg_bpm": hrAverageBPM,
            "avg_speed_kmh": entry.avgSpeedKmh ?? -1,
            "distance_km": distKm,
            "beats_per_meter": beatsPerMeter ?? -1
        ])
        scheduleTrainingLogsInventoryRefresh()
    }

    private func attachHealthkitWorkoutUUID(_ uuid: String, endedAt: Date?) {
        if let workoutIdentifier = UUID(uuidString: uuid),
           let telemetryV2SessionID = pendingHealthkitTelemetryV2SessionID
                ?? activeTelemetryV2SessionID {
            pendingHealthkitTelemetryV2SessionID = nil
            associateHealthKitWorkoutWithTelemetryV2(
                sessionID: telemetryV2SessionID,
                workoutIdentifier: workoutIdentifier
            )
        }
        let matchWindow: TimeInterval = 15 * 60
        let targetProfileID = pendingHealthkitWorkoutProfileID ?? activeUserProfileID
        guard let targetProfileID else {
            pendingHealthkitWorkoutUUID = uuid
            return
        }

        var entries = loadLegacyShadowWorkoutHistory(profileID: targetProfileID)

        let attachUUID: (Int) -> Void = { index in
            let entry = entries[index]
            entries[index] = LegacyShadowWorkoutEntry(
                id: entry.id,
                date: entry.date,
                beatsPerMeter: entry.beatsPerMeter,
                targetBpm: entry.targetBpm,
                durationSeconds: entry.durationSeconds,
                avgBpm: entry.avgBpm,
                avgSpeedKmh: entry.avgSpeedKmh,
                healthkitWorkoutUUID: uuid,
                zoneSeconds: entry.zoneSeconds
            )
            self.saveLegacyShadowWorkoutHistory(entries, profileID: targetProfileID)
            if self.activeUserProfileID == targetProfileID {
                self.legacyShadowWorkoutHistory = entries
            }
            self.pendingHealthkitWorkoutProfileID = nil
        }

        if let endDate = endedAt,
           let idx = entries.firstIndex(where: { $0.healthkitWorkoutUUID == nil && abs($0.date.timeIntervalSince(endDate)) <= matchWindow }) {
            attachUUID(idx)
            return
        }
        if let idx = entries.firstIndex(where: { $0.healthkitWorkoutUUID == nil }) {
            attachUUID(idx)
            return
        }

        pendingHealthkitWorkoutUUID = uuid
        pendingHealthkitWorkoutProfileID = targetProfileID
    }

    private func associateHealthKitWorkoutWithTelemetryV2(
        sessionID: SessionID,
        workoutIdentifier: UUID
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.telemetryV2Coordinator.associateHealthKitWorkout(
                    sessionID: sessionID,
                    workoutIdentifier: workoutIdentifier
                )
            } catch {
                await MainActor.run {
                    self.appendLog("Telemetry V2 HealthKit linkage failed: \(error)")
                    self.telemetryV2WorkoutHistoryState = .failed(
                        "HealthKit linkage failed: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    // KS-F0 protocol: F7 A2 <cmd> <val> <crc> FD, crc = sum(bytes[1..3]) % 256
    private func buildCmdPacket(cmd: UInt8, value: UInt8) -> Data {
        var bytes: [UInt8] = [0xF7, 0xA2, cmd, value, 0xFF, 0xFD]
        let crc = (UInt16(0xA2) + UInt16(cmd) + UInt16(value)) & 0xFF
        bytes[4] = UInt8(crc)
        return Data(bytes)
    }

    private func validateExpectedSpeed(with status: BLETransportCodec.WalkingPadStatus) {
        guard let expected = expectedSpeedKmh, let setAt = expectedSpeedSetAt else { return }
        let age = Date().timeIntervalSince(setAt)
        guard age >= 1.5 else { return }
        let speedDiff = abs(status.speedKmh - expected)
        let appDiff = abs(status.appSpeedKmh - expected)
        let source = expectedSpeedSource ?? "SPEED"
        let matched = speedDiff <= 0.2 || appDiff <= 0.2
        if speedDiff <= 0.2 || appDiff <= 0.2 {
            appendLog("SPEED OK (\(source)): expected \(String(format: "%.1f", expected)) | speed \(String(format: "%.1f", status.speedKmh)) appSpeed \(String(format: "%.1f", status.appSpeedKmh))")
        } else {
            appendLog("SPEED MISMATCH (\(source)): expected \(String(format: "%.1f", expected)) | speed \(String(format: "%.1f", status.speedKmh)) appSpeed \(String(format: "%.1f", status.appSpeedKmh))")
        }
        logTrainingEvent("speed_validation", fields: [
            "source": source,
            "expected_kmh": expected,
            "speed_kmh": status.speedKmh,
            "app_speed_kmh": status.appSpeedKmh,
            "matched": matched,
            "age_s": age
        ])
        expectedSpeedKmh = nil
        expectedSpeedSetAt = nil
        expectedSpeedSource = nil
    }

    private func scheduleWrite(
        _ data: Data,
        label: String,
        after delay: TimeInterval,
        requiresControlReadiness: Bool = false,
        telemetryRequest: TreadmillCommandTelemetryRequest? = nil
    ) {
        let epoch = commandQueueEpoch
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.commandQueueEpoch == epoch else { return }
            self.writeCommand(
                data,
                label: label,
                requiresControlReadiness: requiresControlReadiness,
                telemetryRequest: telemetryRequest
            )
        }
    }

    private func sendHrTargetBpm() {
#if canImport(WatchConnectivity)
        guard let session = wcSession, canSendToWatch(session) else { return }
        let payload: [String: Any] = ["target_bpm": hrTargetBPM]
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        } else {
            try? session.updateApplicationContext(payload)
        }
#endif
    }

    private func sendWatchCommand(_ cmd: String) {
#if canImport(WatchConnectivity)
        guard let session = wcSession else {
            pendingWatchCommand = cmd
            return
        }
        guard canSendToWatch(session) else {
            pendingWatchCommand = cmd
            return
        }
        let payload: [String: Any] = ["cmd": cmd]
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        } else {
            try? session.updateApplicationContext(payload)
        }
#endif
    }

    // MARK: - CBPeripheralDelegate
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === connectedPeripheral,
              peripheral.identifier == connectedPeripheralId else {
            appendLog("Ignoring services from stale peripheral \(peripheral.identifier.uuidString)")
            return
        }
        if let error {
            appendLog("Discover services error: \(error.localizedDescription)")
            invalidateTreadmillControlReadinessEvidence(includingProtocol: true)
            return
        }
        guard let services = peripheral.services, !services.isEmpty else {
            appendLog("No services discovered")
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
            appendLog("Treadmill protocol selected: \(selected.rawValue)")
            logTrainingEvent("treadmill_protocol_selected", fields: [
                "protocol": selected.rawValue,
                "services": services.map { $0.uuid.uuidString }
            ])
            recomputeHrStartAllowed()
        }
        recomputeTreadmillControlReadiness()
        for s in services {
            appendLog("Service discovered: \(s.uuid.uuidString)")
            if supportedServiceUuids.contains(s.uuid) {
                peripheral.discoverCharacteristics(nil, for: s)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === connectedPeripheral,
              peripheral.identifier == connectedPeripheralId,
              service === treadmillProtocolService else {
            appendLog("Ignoring characteristics outside current treadmill transport")
            return
        }
        if let error {
            appendLog("Discover characteristics error: \(error.localizedDescription)")
            invalidateTreadmillControlReadinessEvidence()
            return
        }
        guard let chars = service.characteristics else {
            appendLog("No characteristics for service \(service.uuid.uuidString)")
            invalidateTreadmillControlReadinessEvidence()
            return
        }
        for c in chars {
            appendLog("Char: \(c.uuid.uuidString) props=\(c.properties)")
        }
        commandCharacteristic = nil
        commandCharacteristicConnection = nil
        notifyCharacteristic = nil
        notifyCharacteristicConnection = nil
        characteristicConnections.removeAll()
        extraNotifyCharacteristics.removeAll()
        ftmsHasControl = false
        ftmsControlRequestInFlight = false
        ftmsControlRequestConnection = nil

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
                appendLog("WalkingPad: FE01 notify not found on FE00")
            }
            if let w = write {
                commandCharacteristic = w
                registerCurrentCharacteristic(w)
                commandCharacteristicConnection = currentTreadmillControlConnection
                appendLog("WalkingPad: command characteristic set to \(w.uuid.uuidString)")
                requestInitialControllerUnitsTruthIfReady()
            } else {
                appendLog("WalkingPad: FE02 write not found on FE00")
            }

        case .ftms:
            guard service.uuid == serviceFTMS else { return }
            if let dataChar = chars.first(where: { $0.uuid == ftmsCharTreadmillData && ($0.properties.contains(.notify) || $0.properties.contains(.indicate)) }) {
                notifyCharacteristic = dataChar
                registerCurrentCharacteristic(dataChar)
                subscribe(peripheral, to: dataChar, label: "FTMS treadmill data")
            } else {
                appendLog("FTMS: treadmill data characteristic not found")
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
                appendLog("FTMS: control point set to \(cpChar.uuid.uuidString)")
                subscribe(peripheral, to: cpChar, label: "FTMS control point indications")
            } else {
                appendLog("FTMS: control point characteristic not found")
            }
            if !ftmsDidReadSupportedSpeedRange {
                if let rangeChar = chars.first(where: { $0.uuid == ftmsCharSupportedSpeedRange && $0.properties.contains(.read) }) {
                    ftmsDidReadSupportedSpeedRange = true
                    registerCurrentCharacteristic(rangeChar)
                    appendLog("FTMS: reading supported speed range (2AD4)")
                    peripheral.readValue(for: rangeChar)
                } else if chars.contains(where: { $0.uuid == ftmsCharSupportedSpeedRange }) {
                    ftmsDidReadSupportedSpeedRange = true
                    appendLog("FTMS: supported speed range (2AD4) is not readable")
                }
            }

        case .fitShow:
            guard service.uuid == serviceFitShow else { return }
            if let rx = chars.first(where: { $0.uuid == fitShowCharRx && ($0.properties.contains(.notify) || $0.properties.contains(.indicate)) }) {
                notifyCharacteristic = rx
                registerCurrentCharacteristic(rx)
                subscribe(peripheral, to: rx, label: "FitShow RX")
            } else {
                appendLog("FitShow: RX characteristic (FFF1) not found")
            }
            if let tx = chars.first(where: { $0.uuid == fitShowCharTx && ($0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)) }) {
                commandCharacteristic = tx
                registerCurrentCharacteristic(tx)
                commandCharacteristicConnection = currentTreadmillControlConnection
                appendLog("FitShow: TX characteristic set to \(tx.uuid.uuidString)")
                if !fitShowDidRequestInitialStatus {
                    fitShowDidRequestInitialStatus = true
                    let status = buildFitShowFrame(cmd: 0x51, subcmd: nil, payload: Data())
                    scheduleWrite(status, label: "FitShow STATUS", after: 0.6)
                }
            } else {
                appendLog("FitShow: TX characteristic (FFF2) not found")
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
        if let error {
            appendLog("Notify state error for \(characteristic.uuid.uuidString): \(error.localizedDescription)")
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
            appendLog("WalkingPad: FE01 notifications active")
            requestInitialControllerUnitsTruthIfReady()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === connectedPeripheral,
              peripheral.identifier == connectedPeripheralId,
              isCurrentCharacteristicCallback(characteristic) else {
            appendLog("Ignoring value update from stale peripheral \(peripheral.identifier.uuidString)")
            return
        }
        if let error {
            appendLog("Notify update error from \(characteristic.uuid.uuidString): \(error.localizedDescription)")
            logTrainingEvent("notify_update_error", fields: [
                "char_uuid": characteristic.uuid.uuidString,
                "error": error.localizedDescription
            ])
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
                appendLog("Controller units response ignored: stale peripheral or connection context")
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
                        self.appendLog("Controller units response ignored after connection context changed")
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
                    let decision = self.controllerUnitsGateDecision(now: observedAt)
                    let freshness = self.controllerUnitsTelemetryFields(
                        action: "query_response",
                        now: observedAt,
                        decision: decision
                    )["controller_units_fresh"] ?? false
                    self.appendLog(
                        "Controller units response: units=\(self.controllerUnitsTruth.units.rawValue) " +
                        "status=\(self.controllerUnitsTruth.status.rawValue) fresh=\(freshness)"
                    )
                    self.logTrainingEvent(
                        "controller_units_response",
                        fields: self.controllerUnitsTelemetryFields(action: "query_response", now: observedAt, decision: decision).merging([
                            "max_speed_raw_tenths": params?.maxSpeedRawTenths ?? -1,
                            "start_speed_raw_tenths": params?.startSpeedRawTenths ?? -1
                        ]) { current, _ in current }
                    )
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
                    }
                }
                appendLog("Notify FE01 parsed: state=\(status.beltState) speed=\(String(format: "%.1f", status.speedKmh)) appSpeed=\(String(format: "%.1f", status.appSpeedKmh)) mode=\(status.manualMode) time=\(status.timeSeconds)s dist=\(status.distance10m*10)m steps=\(status.steps) button=\(status.lastButton) checksum=\(status.checksumOk ? "ok" : "bad")")
                logActualSpeedChangeIfNeeded(status.speedKmh, source: "fe01_notify")
                logTrainingEvent("notify_fe01", fields: [
                    "state": status.beltState,
                    "speed_kmh": status.speedKmh,
                    "app_speed_kmh": status.appSpeedKmh,
                    "mode": status.manualMode,
                    "time_s": status.timeSeconds,
                    "distance_m": status.distance10m * 10,
                    "steps": status.steps,
                    "button": status.lastButton,
                    "checksum_ok": status.checksumOk
                ])
                validateExpectedSpeed(with: status)
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
                appendLog("Notify \(characteristic.uuid.uuidString): \(hex(data))")
            }

        case .ftms:
            if characteristic.uuid == ftmsCharSupportedSpeedRange, let range = parseFtmsSupportedSpeedRange(data) {
                DispatchQueue.main.async {
                    self.treadmillMinSpeedKmh = range.minSpeedKmh
                    self.treadmillMaxSpeedKmh = range.maxSpeedKmh
                    self.treadmillSpeedIncrementKmh = range.minIncrementKmh

                    // Clamp any already-chosen targets to avoid "infinite increase" loops.
                    let maxSpeed = self.treadmillSpeedBoundsSnapshot().max
                    if self.desiredSpeedKmh > maxSpeed { self.desiredSpeedKmh = maxSpeed }
                    if self.deviceTargetSpeedKmh > maxSpeed { self.deviceTargetSpeedKmh = maxSpeed }
                }
                appendLog("FTMS supported speed range: min=\(String(format: "%.2f", range.minSpeedKmh)) max=\(String(format: "%.2f", range.maxSpeedKmh)) inc=\(String(format: "%.2f", range.minIncrementKmh)) km/h")
                logTrainingEvent("ftms_supported_speed_range", fields: [
                    "min_kmh": range.minSpeedKmh,
                    "max_kmh": range.maxSpeedKmh,
                    "inc_kmh": range.minIncrementKmh
                ])
            } else if characteristic.uuid == ftmsCharTreadmillData, let parsed = parseFtmsTreadmillData(data) {
                DispatchQueue.main.async {
                    self.deviceReportedSpeedKmh = parsed.instantaneousSpeedKmh
                    self.deviceReportedAppSpeedKmh = parsed.instantaneousSpeedKmh
                    self.deviceReportedState = parsed.isMoving ? 1 : 0
                    self.deviceReportedRawHex = ""
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
                }
                appendLog("Notify FTMS treadmill data: speed=\(String(format: "%.2f", parsed.instantaneousSpeedKmh)) km/h moving=\(parsed.isMoving)")
                logActualSpeedChangeIfNeeded(parsed.instantaneousSpeedKmh, source: "ftms_treadmill_data")
                logTrainingEvent("notify_ftms_treadmill_data", fields: [
                    "speed_kmh": parsed.instantaneousSpeedKmh,
                    "moving": parsed.isMoving
                ])
            } else if characteristic.uuid == ftmsCharControlPoint, let resp = parseFtmsControlPointResponse(data) {
                if resp.requestedOpcode == 0x00 {
                    guard ftmsControlRequestInFlight,
                          ftmsControlRequestConnection == currentTreadmillControlConnection,
                          characteristic === commandCharacteristic else {
                        appendLog("Ignoring FTMS control response without a current pending request")
                        return
                    }
                    ftmsControlRequestInFlight = false
                    ftmsControlRequestConnection = nil
                    if resp.resultCode == 0x01 {
                        ftmsHasControl = true
                    }
                }
                appendLog("Notify FTMS control point: requested=\(String(format: "0x%02X", resp.requestedOpcode)) result=\(String(format: "0x%02X", resp.resultCode))")
                logTrainingEvent("notify_ftms_control_point", fields: [
                    "requested_opcode": resp.requestedOpcode,
                    "result_code": resp.resultCode
                ])
            } else if characteristic.uuid == ftmsCharMachineStatus {
                let statusCode = data.first.map(Int.init) ?? -1
                let raw = hex(data)
                appendLog("Notify FTMS machine status: code=\(statusCode) raw=\(raw)")
                logTrainingEvent("notify_ftms_machine_status", fields: [
                    "status_code": statusCode,
                    "raw_hex": raw
                ])
            } else {
                appendLog("Notify \(characteristic.uuid.uuidString): \(hex(data))")
            }

        case .fitShow:
            if let frame = parseFitShowFrame(data) {
                applyFitShowFrame(
                    frame,
                    peripheral: peripheral,
                    characteristic: characteristic,
                    receivedAt: now
                )
            } else {
                appendLog("Notify \(characteristic.uuid.uuidString): \(hex(data))")
            }

        case .unknown:
            appendLog("Notify \(characteristic.uuid.uuidString): \(hex(data))")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === connectedPeripheral,
              peripheral.identifier == connectedPeripheralId,
              characteristic === commandCharacteristic,
              isCurrentCharacteristicCallback(characteristic) else {
            appendLog("Ignoring write result from stale treadmill transport")
            return
        }
        if let error {
            appendLog("Write to \(characteristic.uuid.uuidString) failed: \(error.localizedDescription)")
            logTrainingEvent("command_write_result", fields: [
                "char_uuid": characteristic.uuid.uuidString,
                "status": "error",
                "error": error.localizedDescription
            ])
        } else {
            appendLog("Write to \(characteristic.uuid.uuidString) OK")
            logTrainingEvent("command_write_result", fields: [
                "char_uuid": characteristic.uuid.uuidString,
                "status": "ok"
            ])
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
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard peripheral === connectedPeripheral,
              peripheral.identifier == connectedPeripheralId,
              let selectedService = treadmillProtocolService,
              invalidatedServices.contains(where: { $0 === selectedService }) else {
            return
        }
        appendLog("Selected treadmill service invalidated")
        treadmillProtocolService = nil
        commandCharacteristic = nil
        notifyCharacteristic = nil
        extraNotifyCharacteristics.removeAll()
        characteristicConnections.removeAll()
        invalidateTreadmillControlReadinessEvidence(includingProtocol: true)
    }
}

#if canImport(WatchConnectivity)
extension BluetoothManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        refreshWatchState(session)
        DispatchQueue.main.async {
            self.appendLog("Watch activation: state=\(activationState.rawValue) error=\(error?.localizedDescription ?? "none") reachable=\(session.isReachable) paired=\(session.isPaired) appInstalled=\(session.isWatchAppInstalled)")
        }
        if activationState == .activated {
            sendHrTargetBpm()
            if let cmd = pendingWatchCommand {
                pendingWatchCommand = nil
                sendWatchCommand(cmd)
            }
        }
    }
    func sessionReachabilityDidChange(_ session: WCSession) {
        refreshWatchState(session)
        DispatchQueue.main.async {
            self.appendLog("Watch reachability changed: reachable=\(session.isReachable) paired=\(session.isPaired) appInstalled=\(session.isWatchAppInstalled)")
        }
    }
    func sessionWatchStateDidChange(_ session: WCSession) {
        refreshWatchState(session)
        DispatchQueue.main.async {
            self.appendLog("Watch state changed: reachable=\(session.isReachable) paired=\(session.isPaired) appInstalled=\(session.isWatchAppInstalled)")
        }
        if session.activationState == .activated {
            sendHrTargetBpm()
            if let cmd = pendingWatchCommand {
                pendingWatchCommand = nil
                sendWatchCommand(cmd)
            }
        }
    }

    // iOS-specific lifecycle hooks
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        handleWatchPayload(message)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        handleWatchPayload(applicationContext)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        handleWatchPayload(userInfo)
    }

    private func handleWatchPayload(_ payload: [String: Any]) {
        let phoneReceivedAt = Date()
        if let decoded = WatchHeartRatePayloadDecoder.decode(payload) {
            DispatchQueue.main.async {
                guard !self.nativeHeartRateFlowOwnsController else {
                    self.appendLog("Ignored legacy Watch HR while native HealthKit owns HR")
                    return
                }
                HeartRateObservationalTee.deliver(
                    decoded.beatsPerMinute,
                    toLegacyController: { bpm in
                        HRDomainService.applyHeartRateDelivery(
                            bpm,
                            now: Date.init,
                            updateCurrent: { self.heartRateBPM = $0 },
                            updateLastKnown: { self.lastKnownHeartRateBPM = $0 },
                            updateLastReceivedAt: { self.hrLastValueAt = $0 },
                            recordPredictorInput: { self.recordHrSample($0) }
                        )
                        // hrStreamingActive will be derived by the staleness timer
                        self.appendLog("HR value: \(bpm)")
                        self.logTrainingEvent("hr_sample", fields: [
                            "hr_bpm": bpm,
                            "source": "watch_payload"
                        ])
                    },
                    observe: {
                        self.observeHeartRateDelivery(
                            decoded,
                            receivedAt: phoneReceivedAt
                        )
                    }
                )
            }
        }
        if let uuid = payload["workout_uuid"] as? String {
            let endDate: Date? = {
                if let ts = payload["workout_end"] as? TimeInterval {
                    return Date(timeIntervalSince1970: ts)
                }
                return nil
            }()
            DispatchQueue.main.async {
                guard !self.nativeHeartRateFlowOwnsController else {
                    self.appendLog("Ignored legacy Watch workout UUID while native HealthKit owns workout")
                    return
                }
                self.attachHealthkitWorkoutUUID(uuid, endedAt: endDate)
                self.appendLog("Workout UUID received: \(uuid)")
                self.logTrainingEvent("workout_uuid_received", fields: [
                    "workout_uuid": uuid,
                    "ended_at": endDate?.timeIntervalSince1970 ?? -1
                ])
            }
        }
        if let status = payload["status"] as? String {
            DispatchQueue.main.async {
                guard !self.nativeHeartRateFlowOwnsController else { return }
                var lifecycleTransition: HeartRateSourceLifecycleInput?
                switch status.lowercased() {
                case "hr_started":
                    self.hrPermissionGranted = true
                    self.appendLog("HR stream started; permission granted")
                    self.logTrainingEvent("watch_status", fields: ["status": "hr_started"])
                    lifecycleTransition = .started
                case "hr_stopped":
                    // Keep permission as last-known; clear last timestamp to mark no data
                    self.hrLastValueAt = nil
                    self.heartRateBPM = 0
                    self.appendLog("HR stream stopped")
                    self.logTrainingEvent("watch_status", fields: ["status": "hr_stopped"])
                    lifecycleTransition = .stopped
                case "watch_ok":
                    self.watchReachable = true
                    self.appendLog("Watch OK")
                    self.logTrainingEvent("watch_status", fields: ["status": "watch_ok"])
                default:
                    break
                }
                self.recomputeHrStartAllowed()
                if let lifecycleTransition {
                    self.observeHeartRateSourceLifecycle(lifecycleTransition)
                }
            }
        }
    }
}
#endif
