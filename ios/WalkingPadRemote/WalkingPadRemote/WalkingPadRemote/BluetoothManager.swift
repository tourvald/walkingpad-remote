import Foundation
import SwiftUI
import Combine
import CoreBluetooth
import HealthKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

// Minimal stub to satisfy references in the UI. Replace with real implementation.
final class BluetoothManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    // CoreBluetooth
    private var central: CBCentralManager?
    private let healthStore = HKHealthStore()
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
    private var ftmsHasControl: Bool = false
    private var ftmsControlRequestInFlight: Bool = false
    private var ftmsDidReadSupportedSpeedRange: Bool = false
    private var fitShowDidRequestInitialStatus: Bool = false
    private var shouldBeScanning: Bool = false
    private var discoveredMap: [UUID: CBPeripheral] = [:]
    private var autoConnectPendingWorkItem: DispatchWorkItem?
    private var connectTimeoutWorkItem: DispatchWorkItem?
#if canImport(WatchConnectivity)
    private var wcSession: WCSession?
    private var pendingWatchCommand: String? = nil
#endif
    private var connectingPeripheralId: UUID? = nil
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
    private var notifyCharacteristic: CBCharacteristic?
    private var extraNotifyCharacteristics: [CBCharacteristic] = []
    private var supportedServiceUuids: [CBUUID] { [serviceFE00, serviceFTMS, serviceFitShow] }

    // Connection / device info
    @Published var connectionStateText: String = "Disconnected"
    @Published var displayDeviceName: String? = nil
    @Published var deviceName: String = ""
    @Published var isConnected: Bool = false
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
    private let userProfilesStoreKey = "user_profiles_state_v1"
    private let installationIDStoreKey = "installation_id_v1"
    private let hrSettingsStoreKey = "hr_settings_v1"
    private let zonePlanStoreKey = "zone_plan_v1"
    private let workoutHistoryStoreKey = "workout_history_v1"
    private var isLoadingHrSettings: Bool = false
    private var autoConnectSuppressed: Bool = false
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
    private var hrControlFailed: Bool = false
    private let legacyWatchHeartRateSource = HeartRateProviderIdentity(
        kind: .legacyWatchWorkoutStream,
        stableLocalKey: "legacyWatchWorkoutStream"
    )
    private var heartRateObservationNormalizer = HeartRateObservationNormalizer()
    private var heartRateTelemetrySink: (any HeartRateTelemetrySink)?
    private var latestHeartRateDelivery: HeartRateDeliveryEvidence?
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

    private func workoutEntry(from dto: WorkoutEntryDTO) -> WorkoutEntry {
        WorkoutEntry(
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

    private func workoutEntryDTO(from entry: WorkoutEntry) -> WorkoutEntryDTO {
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

    private func loadWorkoutHistory(profileID: UUID) -> [WorkoutEntry] {
        let key = profileScopedStoreKey(workoutHistoryStoreKey, profileID: profileID)
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([WorkoutEntryDTO].self, from: data) else {
            return []
        }

        return list.map { workoutEntry(from: $0) }
    }

    private func saveWorkoutHistory(_ entries: [WorkoutEntry], profileID: UUID) {
        let list = entries.prefix(50).map { workoutEntryDTO(from: $0) }
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: profileScopedStoreKey(workoutHistoryStoreKey, profileID: profileID))
    }

    private func removeStoredData(for profileID: UUID) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: profileScopedStoreKey(hrSettingsStoreKey, profileID: profileID))
        defaults.removeObject(forKey: profileScopedStoreKey(zonePlanStoreKey, profileID: profileID))
        defaults.removeObject(forKey: profileScopedStoreKey(workoutHistoryStoreKey, profileID: profileID))
    }

    private func loadActiveProfileScopedData() {
        loadHrSettings()
        loadZonePlan()
        loadWorkoutHistory()
    }

    func selectUserProfile(id: UUID) {
        guard userProfiles.contains(where: { $0.id == id }) else { return }
        guard !isHrControlRunning else {
            infoToastMessage = "Во время активной тренировки профиль переключать нельзя."
            return
        }
        guard activeUserProfileID != id else { return }

        saveHrSettingsIfNeeded()
        saveZonePlan()
        saveWorkoutHistory()

        activeUserProfileID = id
        saveProfilesState()
        loadActiveProfileScopedData()
        refreshTrainingLogsInventory()
        appendLog("Active profile switched: \(activeUserProfileLabel)")
        infoToastMessage = "Активный профиль: \(activeUserProfileLabel)"
    }

    func createUserProfile(named rawLabel: String) {
        guard !isHrControlRunning else {
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
        saveWorkoutHistory()

        saveHrSettings(profileID: profile.id)
        saveZonePlan(profileID: profile.id)
        saveWorkoutHistory([], profileID: profile.id)

        userProfiles = sortedProfiles(userProfiles + [profile])
        activeUserProfileID = profile.id
        saveProfilesState()
        loadActiveProfileScopedData()
        refreshTrainingLogsInventory()
        appendLog("Profile created: \(profile.label)")
        infoToastMessage = "Создан профиль: \(profile.label)"
    }

    func renameActiveUserProfile(to rawLabel: String) {
        guard !isHrControlRunning else {
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
        guard !isHrControlRunning else {
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
        refreshTrainingLogsInventory()
        appendLog("Profile deleted: \(deletedLabel)")
        infoToastMessage = "Профиль удалён: \(deletedLabel)"
    }

    private func loadWorkoutHistory() {
        guard let activeUserProfileID else {
            workoutHistory = []
            return
        }
        workoutHistory = loadWorkoutHistory(profileID: activeUserProfileID)
    }

    private func saveWorkoutHistory() {
        guard let activeUserProfileID else { return }
        saveWorkoutHistory(workoutHistory, profileID: activeUserProfileID)
    }

    func deleteWorkoutEntry(id: UUID) {
        guard let idx = workoutHistory.firstIndex(where: { $0.id == id }) else { return }
        let entry = workoutHistory.remove(at: idx)
        saveWorkoutHistory()
        guard let uuidString = entry.healthkitWorkoutUUID, let uuid = UUID(uuidString: uuidString) else { return }
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let workoutType = HKObjectType.workoutType()
        healthStore.requestAuthorization(toShare: [workoutType], read: [workoutType]) { [weak self] success, error in
            guard success, error == nil else {
                self?.appendLog("HealthKit delete auth failed")
                return
            }
            let predicate = HKQuery.predicateForObject(with: uuid)
            let query = HKSampleQuery(sampleType: workoutType, predicate: predicate, limit: 1, sortDescriptors: nil) { _, samples, _ in
                guard let workout = samples?.first as? HKWorkout else {
                    self?.appendLog("HealthKit workout not found for UUID \(uuidString)")
                    return
                }
                self?.healthStore.delete(workout) { ok, _ in
                    if ok {
                        self?.appendLog("HealthKit workout deleted \(uuidString)")
                    } else {
                        self?.appendLog("HealthKit delete failed \(uuidString)")
                    }
                }
            }
            self?.healthStore.execute(query)
        }
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

    var isHrControlStartAffordanceAvailable: Bool {
        HRDomainService.heartRateStartAffordanceAvailable(
            treadmillConnected: isConnected,
            currentHeartRateVisible: hrStreamingActive
        )
    }

    @Published var hrNextDecisionSeconds: Int = 0
    @Published var hrRemainingSeconds: Int = 0
    @Published var hrCooldownRemainingSeconds: Int = 0
    @Published var hrProgress: Double = 0
    @Published var hrCooldownProgress: Double = 0
    @Published var hrTargetBPM: Int = 130 {
        didSet {
            sendHrTargetBpm()
            saveHrSettingsIfNeeded()
        }
    }
    @Published var hrDurationMinutes: Int = 10 { didSet { saveHrSettingsIfNeeded() } }
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
            let old = deviceTargetSpeedKmh
            desiredSpeedKmh = speedEffect.targetKmh
            deviceTargetSpeedKmh = speedEffect.targetKmh
            recordSpeedChange(from: old, to: speedEffect.targetKmh, reason: "cooldown_set")
            lastCommandLine = String(format: "CMD cooldown adjust -> %.1f", speedEffect.targetKmh)
            sendTreadmillSetSpeed(speedEffect.targetKmh, label: String(format: "SPEED %.1f km/h (cooldown)", speedEffect.targetKmh))
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
                sendWatchCommand("stop_hr")
            }
            if completionEffect.shouldStopBelt {
                stopBeltWithToggle(reason: "hr_cooldown_done")
            }
        }
    }

    private func logCooldownTelemetry(_ effect: CooldownRuntimeEngine.TelemetryEffect) {
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

    private func synchronizeTrainingLogFileIfNeeded() {
        trainingLogQueue.sync {
            trainingLogFileHandle?.synchronizeFile()
        }
    }

    private func currentProtectedTrainingLogFiles() -> Set<URL> {
        let activeLogFile: URL? = trainingLogQueue.sync {
            trainingLogFileURL?.standardizedFileURL
        }
        return Set(activeLogFile.map { [$0] } ?? [])
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

    private func startTrainingStructuredLog(trigger: String) {
        stopTrainingStructuredLog(reason: "restart_before_new_session")
        guard let dir = trainingLogsDirectoryURL() else { return }
        pruneTrainingLogs(in: dir)

        let sessionId = UUID().uuidString
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
        } catch {
            appendLog("Training log file open error: \(error.localizedDescription)")
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
        defer {
            try? FileManager.default.removeItem(at: export.csvURL)
        }

        guard completed else {
            appendLog("Training CSV share cancelled: \(export.csvURL.lastPathComponent)")
            return
        }

        let activeLogFile: URL? = trainingLogQueue.sync { trainingLogFileURL?.standardizedFileURL }
        let protectedFiles = Set(activeLogFile.map { [$0] } ?? [])
        let cleanup = TrainingTelemetryWriter.cleanupExportedJsonlFiles(
            export.sourceFiles,
            keeping: protectedFiles
        )

        if let dir = trainingLogsDirectoryURL() {
            pruneTrainingLogs(in: dir)
        }

        refreshTrainingLogsInventory()

        let reclaimedText = ByteCountFormatter.string(
            fromByteCount: cleanup.reclaimedBytes,
            countStyle: .file
        )

        let message: String
        if cleanup.removedCount > 0 {
            if cleanup.skippedCount > 0 {
                message = "CSV выгружен. Очищено \(cleanup.removedCount) raw логов, освобождено \(reclaimedText), пропущено \(cleanup.skippedCount)."
            } else {
                message = "CSV выгружен. Очищено \(cleanup.removedCount) raw логов, освобождено \(reclaimedText)."
            }
        } else if cleanup.skippedCount > 0 {
            message = "CSV выгружен. Raw логи не удалены: активная сессия ещё открыта или файлы уже были очищены."
        } else {
            message = "CSV выгружен. Дополнительная очистка raw логов не потребовалась."
        }

        appendLog("Training raw logs cleanup: scope=\(export.scope.logDescription) removed=\(cleanup.removedCount) skipped=\(cleanup.skippedCount) freed=\(cleanup.reclaimedBytes) rows=\(export.rowCount)")
        DispatchQueue.main.async {
            self.infoToastMessage = message
        }
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
        synchronizeTrainingLogFileIfNeeded()
        let protectedFiles = currentProtectedTrainingLogFiles()
        guard let allJsonlFiles = allTrainingJsonlFiles(),
              !allJsonlFiles.isEmpty else {
            trainingLogsInventory = .empty
            lastTrainingLogPath = ""
            return
        }

        let filteredFiles = TrainingTelemetryWriter.filterJsonlFiles(
            allJsonlFiles,
            matchingProfileID: activeUserProfileID?.uuidString,
            legacyFallbackProfileID: legacyFallbackProfileID
        )
        trainingLogsInventory = TrainingTelemetryWriter.trainingLogsInventory(
            allJsonlFiles,
            matchingProfileID: activeUserProfileID?.uuidString,
            legacyFallbackProfileID: legacyFallbackProfileID,
            keeping: protectedFiles
        )
        lastTrainingLogPath = filteredFiles.last?.path ?? ""
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
        synchronizeTrainingLogFileIfNeeded()
        guard let allJsonlFiles = allTrainingJsonlFiles(),
              !allJsonlFiles.isEmpty else {
            trainingLogsInventory = .empty
            infoToastMessage = "Raw training logs не найдены."
            return
        }

        let protectedFiles = currentProtectedTrainingLogFiles()
        let selectedFiles = TrainingTelemetryWriter.selectJsonlFilesForClear(
            allJsonlFiles,
            matchingProfileID: activeUserProfileID?.uuidString,
            legacyFallbackProfileID: legacyFallbackProfileID,
            keeping: protectedFiles
        )

        guard !selectedFiles.isEmpty else {
            refreshTrainingLogsInventory()
            infoToastMessage = "Для активного профиля нечего очищать. Активная сессия не удаляется."
            return
        }

        let cleanup = TrainingTelemetryWriter.cleanupExportedJsonlFiles(
            selectedFiles,
            keeping: protectedFiles
        )

        if let dir = trainingLogsDirectoryURL() {
            pruneTrainingLogs(in: dir)
        }

        refreshTrainingLogsInventory()

        let reclaimedText = ByteCountFormatter.string(
            fromByteCount: cleanup.reclaimedBytes,
            countStyle: .file
        )

        let message: String
        if cleanup.removedCount > 0 {
            if cleanup.skippedCount > 0 {
                message = "Raw training logs очищены: удалено \(cleanup.removedCount) файлов, освобождено \(reclaimedText), пропущено \(cleanup.skippedCount). История тренировок в статистике сохранена."
            } else {
                message = "Raw training logs очищены: удалено \(cleanup.removedCount) файлов, освобождено \(reclaimedText). История тренировок в статистике сохранена."
            }
        } else {
            message = "Raw training logs не очищены: активная сессия ещё открыта или файлы уже отсутствуют."
        }

        appendLog("Training raw logs cleared manually: removed=\(cleanup.removedCount) skipped=\(cleanup.skippedCount) freed=\(cleanup.reclaimedBytes)")
        infoToastMessage = message
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

    // History
    struct WorkoutEntry: Identifiable {
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
    @Published var workoutHistory: [WorkoutEntry] = []

    // Lifecycle
    func start() {
        ensureCentral()
        autoConnectSuppressed = false
        manualModeSet = false
        loadKnownPeripherals()
        loadProfilesState()
        loadHrSettings()
        loadZonePlan()
        loadWorkoutHistory()
        refreshTrainingLogsInventory()
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

        // If we have known peripherals saved, prefer connecting to them
        if !knownPeripherals.isEmpty {
            // Prefer a discovered known with strongest RSSI
            if let candidate = discoveredPeripherals.filter({ $0.isKnown }).max(by: { $0.rssi < $1.rssi }) {
                appendLog("AutoConnect: connecting strongest known discovered \(candidate.name) id=\(candidate.id.uuidString) rssi=\(candidate.rssi)")
                connectToDiscovered(id: candidate.id)
                return
            }
            // Try already connected peripherals that match our service and are known
            let connectedList = central.retrieveConnectedPeripherals(withServices: supportedServiceUuids)
            if let p = connectedList.first(where: { kp in self.knownPeripherals.contains(where: { $0.id == kp.identifier }) }) {
                discoveredMap[p.identifier] = p
                DispatchQueue.main.async { self.connectionStateText = "Connecting..." }
                appendLog("AutoConnect: connecting to system-connected known id=\(p.identifier.uuidString) name=\(p.name ?? "")")
                central.stopScan()
                central.connect(p, options: nil)
                return
            }
            // Try retrieve by identifiers for known devices
            let ids = knownPeripherals.map { $0.id }
            if !ids.isEmpty {
                let list = central.retrievePeripherals(withIdentifiers: ids)
                if let p = list.first {
                    discoveredMap[p.identifier] = p
                    DispatchQueue.main.async { self.connectionStateText = "Connecting..." }
                    appendLog("AutoConnect: retrieve and connect known id=\(p.identifier.uuidString) name=\(p.name ?? "")")
                    central.stopScan()
                    central.connect(p, options: nil)
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
                connectToDiscovered(id: candidate.id)
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
                        self.connectToDiscovered(id: candidate.id)
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
            // - If any known discovered -> connect immediately to the strongest known
            // - Else if allowAutoConnectUnknown -> debounce and connect strongest unknown
            if !self.isConnected {
                if self.autoConnectSuppressed {
                    return
                }
                if self.discoveredPeripherals.contains(where: { $0.isKnown }) {
                    let candidate = self.discoveredPeripherals.filter { $0.isKnown }.max(by: { $0.rssi < $1.rssi })
                    if let candidate {
                        self.autoConnectPendingWorkItem?.cancel()
                        self.autoConnectPendingWorkItem = nil
                        self.appendLog("AutoConnect (discover): connecting strongest known \(candidate.name) id=\(candidate.id.uuidString) rssi=\(candidate.rssi)")
                        self.connectToDiscovered(id: candidate.id)
                    }
                } else if self.allowAutoConnectUnknown {
                    if self.autoConnectPendingWorkItem == nil {
                        let work = DispatchWorkItem { [weak self] in
                            guard let self else { return }
                            if !self.isConnected && self.allowAutoConnectUnknown && !self.autoConnectSuppressed {
                                let candidate = self.discoveredPeripherals.max(by: { $0.rssi < $1.rssi })
                                if let candidate {
                                    self.connectToDiscovered(id: candidate.id)
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
        appendLog("Connected; discovering services…")
        logTrainingEvent("ble_connection_event", fields: [
            "status": "connected",
            "peripheral_id": peripheral.identifier.uuidString,
            "name": peripheral.name ?? ""
        ])
        DispatchQueue.main.async {
            self.autoConnectPendingWorkItem?.cancel()
            self.autoConnectPendingWorkItem = nil
            self.connectTimeoutWorkItem?.cancel()
            self.connectTimeoutWorkItem = nil
            self.connectingPeripheralId = nil
            self.isConnected = true
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
            if !self.knownPeripherals.contains(where: { $0.id == peripheral.identifier }) {
                let display = peripheral.name ?? "Device"
                self.knownPeripherals.append(KnownPeripheral(id: peripheral.identifier, name: display))
                self.saveKnownPeripherals()
            }
        }
        central.stopScan()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logTrainingEvent("ble_connection_event", fields: [
            "status": "failed_to_connect",
            "peripheral_id": peripheral.identifier.uuidString,
            "error": error?.localizedDescription ?? "unknown error"
        ])
        DispatchQueue.main.async {
            self.isConnected = false
            self.connectionStateText = "Disconnected"
            self.connectErrorMessage = error?.localizedDescription ?? "Failed to connect"
            self.connectingPeripheralId = nil
            self.connectTimeoutWorkItem?.cancel()
            self.connectTimeoutWorkItem = nil
            self.appendLog("Failed to connect to \(peripheral.identifier.uuidString): \(error?.localizedDescription ?? "unknown error")")
        }
        if shouldBeScanning {
            central.scanForPeripherals(withServices: supportedServiceUuids,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logTrainingEvent("ble_connection_event", fields: [
            "status": "disconnected",
            "peripheral_id": peripheral.identifier.uuidString,
            "error": error?.localizedDescription ?? "none"
        ])
        DispatchQueue.main.async {
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
            self.connectTimeoutWorkItem?.cancel()
            self.connectTimeoutWorkItem = nil
            self.manualModeSet = false
        }
        if shouldBeScanning, central.state == .poweredOn {
            central.scanForPeripherals(withServices: supportedServiceUuids,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
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
        if let central, let id = connectedPeripheralId, let p = discoveredMap[id] {
            central.cancelPeripheralConnection(p)
        }
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
        DispatchQueue.main.async {
            self.isConnected = false
            self.connectedPeripheralId = nil
            self.connectionStateText = "Disconnected"
            self.displayDeviceName = nil
            self.deviceTargetSpeedKmh = 0
            self.desiredSpeedKmh = 0
            self.resetSessionStats()
            self.stopTelemetry()
            self.isHrControlRunning = false
        }
    }
    func connectToKnownPeripheral(id: UUID) {
        ensureCentral()
        guard let central else { return }
        autoConnectSuppressed = false
        // Prevent duplicate connection attempts
        if isConnected { appendLog("Connect known skipped: already connected"); return }
        if let inProgress = connectingPeripheralId {
            appendLog("Connect known skipped: connection in progress to \(inProgress.uuidString)")
            if inProgress == id { return }
            return
        }
        if let p = discoveredMap[id] {
            DispatchQueue.main.async { self.connectionStateText = "Connecting..." }
            connectingPeripheralId = id
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
    func connectToDiscovered(id: UUID) {
        ensureCentral()
        guard let central else { return }
        autoConnectSuppressed = false
        // Prevent duplicate connection attempts
        if isConnected { appendLog("Connect discovered skipped: already connected"); return }
        if let inProgress = connectingPeripheralId {
            // Ignore repeated taps while a connection is in progress (including same target)
            appendLog("Connect discovered skipped: connection in progress to \(inProgress.uuidString)")
            if inProgress == id { return }
            return
        }
        if let p = discoveredMap[id] {
            DispatchQueue.main.async { self.connectionStateText = "Connecting..." }
            connectingPeripheralId = id
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
            if self.connectedPeripheralId == id {
                self.disconnect(userInitiated: true)
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
              !isHrControlRunning,
              isConnected,
              connectedPeripheralId != nil,
              controllerUnitsConnectionEpoch != nil,
              commandCharacteristic != nil,
              treadmillProtocol != .unknown,
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
        if commandCharacteristic == nil || treadmillProtocol == .unknown {
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
        guard isConnected,
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
        if isHrControlRunning {
            appendLog("Manual stop while HR control active → ending training")
            stopHrControl()
            return
        }
        stopBeltWithToggle(reason: "manual")
    }

    func startWithSpeed(_ kmh: Double) {
        guard isConnected else {
            infoToastMessage = "Не подключено к дорожке"
            return
        }
        endStopObservationForNewMotion()
        // Cancel any pending delayed writes (e.g. stop retries) before starting a new run.
        resetCommandQueue(reason: "startWithSpeed")
        let v = clampRunningSpeedKmh(kmh)
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
                writeCommand(modePacket, label: "MODE MANUAL")
                manualModeSet = true
            }
            if shouldSendStart {
                scheduleWrite(startPacket, label: "START", after: 0.2)
                scheduleWrite(buildWalkingPadSetSpeedPacket(kmh: v), label: String(format: "SPEED %.1f km/h", v), after: 0.45)
            } else {
                scheduleWrite(buildWalkingPadSetSpeedPacket(kmh: v), label: String(format: "SPEED %.1f km/h", v), after: 0.2)
            }

        case .ftms:
            enqueueFtmsRequestControlIfNeeded()
            if shouldSendStart {
                scheduleWrite(buildFtmsStartOrResumePacket(), label: "FTMS START/RESUME", after: 0.2)
                scheduleWrite(buildFtmsSetSpeedPacket(kmh: v), label: String(format: "SPEED %.1f km/h (FTMS)", v), after: 0.45)
            } else {
                scheduleWrite(buildFtmsSetSpeedPacket(kmh: v), label: String(format: "SPEED %.1f km/h (FTMS)", v), after: 0.2)
            }

        case .fitShow:
            if shouldSendStart {
                writeCommand(buildFitShowStartOrResumePacket(), label: "FitShow START/RESUME")
                scheduleWrite(buildFitShowSetSpeedPacket(kmh: v, incline: 0), label: String(format: "SPEED %.1f km/h (FitShow)", v), after: 0.35)
            } else {
                scheduleWrite(buildFitShowSetSpeedPacket(kmh: v, incline: 0), label: String(format: "SPEED %.1f km/h (FitShow)", v), after: 0.2)
            }

        case .unknown:
            infoToastMessage = "Неподдерживаемая дорожка (протокол не определён)"
            appendLog("Start skipped: unknown treadmill protocol")
        }
    }
    func stopBelt() {
        guard isConnected else { return }
        let old = deviceTargetSpeedKmh
        desiredSpeedKmh = 0
        deviceTargetSpeedKmh = 0
        recordSpeedChange(from: old, to: 0, reason: "stop_belt")
        lastCommandLine = "CMD stop"
        resetSessionStats()
        if treadmillProtocol == .ftms {
            enqueueFtmsRequestControlIfNeeded()
        }
        guard let packet = buildTreadmillStopPacket() else {
            appendLog("STOP skipped: unknown treadmill protocol")
            return
        }
        writeCommand(packet, label: "STOP", highPriority: true)
        scheduleWrite(packet, label: "STOP retry", after: 2.0)
        scheduleWrite(packet, label: "STOP retry", after: 4.0)
        beginStopObservation(source: "direct")
    }

    private func stopBeltOnce() {
        guard isConnected else { return }
        let old = deviceTargetSpeedKmh
        desiredSpeedKmh = 0
        deviceTargetSpeedKmh = 0
        recordSpeedChange(from: old, to: 0, reason: "stop_belt_once")
        lastCommandLine = "CMD stop"
        resetSessionStats()
        if treadmillProtocol == .ftms {
            enqueueFtmsRequestControlIfNeeded()
        }
        guard let packet = buildTreadmillStopPacket() else {
            appendLog("STOP skipped: unknown treadmill protocol")
            return
        }
        writeCommand(packet, label: "STOP", highPriority: true)
    }

    private func stopBeltWithToggle(reason: String) {
        let wasRunning = (deviceTargetSpeedKmh > 0.3) || (speedKmh > 0.3)
        appendLog("STOP sequence (\(reason))")
        stopBeltOnce()
        guard wasRunning else {
            beginStopObservation(source: reason)
            return
        }
        switch treadmillProtocol {
        case .walkingPad:
            let toggle = buildCmdPacket(cmd: 0x04, value: 0x01)
            scheduleWrite(toggle, label: "START/STOP TOGGLE", after: 2.0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                guard let self else { return }
                let reported = self.deviceReportedSpeedKmh
                let observed = max(self.speedKmh, reported)
                if observed > 0.2 {
                    if let stopPacket = self.buildTreadmillStopPacket() {
                        self.writeCommand(stopPacket, label: "STOP retry")
                    }
                }
            }

        case .ftms, .fitShow, .unknown:
            if let stopPacket = buildTreadmillStopPacket() {
                if treadmillProtocol == .ftms {
                    enqueueFtmsRequestControlIfNeeded()
                }
                scheduleWrite(stopPacket, label: "STOP retry", after: 2.0)
                scheduleWrite(stopPacket, label: "STOP retry", after: 4.0)
            }
        }
        beginStopObservation(source: reason)
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

    private func beginStopObservation(source: String, now: Date = Date()) {
        stopObservationFreshnessWorkItem?.cancel()
        stopObservationFreshnessWorkItem = nil
        finishActiveStopObservationUnconfirmed(reason: "superseded_by_new_attempt", now: now)
        if let pendingAttemptID = unavailableStopAttempt?.id {
            finalizeUnavailableStopAttempt(attemptID: pendingAttemptID)
        }
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
    }
    func setTargetSpeedFromSlider(_ kmh: Double) {
        let v = clampRunningSpeedKmh(kmh)
        desiredSpeedKmh = v
        guard isConnected else { return }
        let isRunning = deviceTargetSpeedKmh > 0.1 || speedKmh > 0.2
        guard isRunning else { return }
        let old = deviceTargetSpeedKmh
        guard abs(v - old) >= 0.01 else { return }
        deviceTargetSpeedKmh = v
        recordSpeedChange(from: old, to: v, reason: "manual_slider")
        lastCommandLine = "CMD set speed=\(String(format: "%.1f", v))"
        sendTreadmillSetSpeed(v, label: String(format: "SPEED %.1f km/h", v))
    }
    func adjustSpeed(delta: Double) {
        guard isConnected else { return }
        let base = (deviceTargetSpeedKmh > 0.1) ? deviceTargetSpeedKmh : (speedKmh > 0.1 ? speedKmh : desiredSpeedKmh)
        let v = clampAnySpeedKmh(base + delta)
        guard abs(v - base) >= 0.01 else { return }
        let old = deviceTargetSpeedKmh
        desiredSpeedKmh = v
        deviceTargetSpeedKmh = v
        recordSpeedChange(from: old, to: v, reason: "manual_adjust")
        lastCommandLine = "CMD adjust delta=\(String(format: "%.1f", delta)) -> \(String(format: "%.1f", v))"
        sendTreadmillSetSpeed(v, label: String(format: "SPEED %.1f km/h", v))
    }

    // HR control actions
    var canExtendHrSession: Bool {
        guard isHrControlRunning, hrRemainingSeconds > 0 else { return false }
        return hrSessionTotalSeconds < (hrMaxSessionMinutes * 60)
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
        hrSessionTotalSeconds = newTotalSeconds
        hrRemainingSeconds += addedSeconds
        hrProgress = hrSessionTotalSeconds > 0 ? (1.0 - (Double(hrRemainingSeconds) / Double(hrSessionTotalSeconds))) : 0
        appendLog("HR extend: +\(addedSeconds / 60)m total=\(hrSessionTotalSeconds / 60)m remaining=\(hrRemainingSeconds / 60)m")
    }

    func startHrControl() {
        guard !isHrControlRunning else { return }
        // Preserve the existing connection/watch/fresh-HR gates, then compose the
        // legacy WalkingPad units gate before any automated motion can start.
        let existingGatesAllowStart = HRDomainService
            .heartRateRuntimePrerequisitesAllowStart(
                treadmillConnected: isConnected,
                watchReachable: watchReachable,
                currentHeartRateVisible: hrStreamingActive
            )
        guard existingGatesAllowStart else {
            isHrControlRunning = false
            if !isConnected {
                hrControlStartBlockReasonText = "Нет подключения к дорожке"
            } else if !watchReachable {
                hrControlStartBlockReasonText = "Часы недоступны — откройте приложение на Apple Watch и дождитесь соединения."
            } else if !hrStreamingActive {
                hrControlStartBlockReasonText = "Пульс недоступен — откройте приложение на Apple Watch и дождитесь передачи пульса."
            }
            return
        }

        let unitsDecision = controllerUnitsGateDecision()
        guard unitsDecision.allowed else {
            isHrControlRunning = false
            hrControlStartBlockReasonText = unitsDecision.blockReason?.userMessage ?? "Единицы контроллера не подтверждены"
            persistBlockedControllerUnitsStart(decision: unitsDecision)
            retryControllerUnitsQueryAfterBlockedStart()
            return
        }

        if existingGatesAllowStart {
            let adaptiveStepDescription = hrAdaptiveStepEnabled
                ? "adaptive_levels=0.1/0.2/0.3/0.4"
                : "step=\(String(format: "%.2f", hrSpeedStepKmh))"
            appendLog("HR start: target=\(hrTargetBPM) duration=\(hrDurationMinutes)m interval=\(hrDecisionIntervalSeconds)s \(adaptiveStepDescription)")
            // Reset all per-session counters before writing session_start telemetry snapshot.
            resetSessionStats()
            startTrainingStructuredLog(trigger: "start_hr")
            isHrControlRunning = true
            hrStatusLine = "HR‑контроль запущен"
            hrSessionTotalSeconds = max(60, hrDurationMinutes * 60)
            hrRemainingSeconds = hrSessionTotalSeconds
            hrNextDecisionSeconds = hrDecisionIntervalSeconds
            hrProgress = 0
            hrControlStartedAt = Date()
            hrDecisionDetails = ""
            hrPredictorStatusLine = ""
            hrWorkoutRecorded = false
            hrTrendSamples.removeAll()
            hrTrendEmaBpm = nil
            hrNoDataSeconds = 0
            hrControlFailed = false
            clearCooldownRuntimeState()
            // Ensure treadmill is running when HR control starts
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
                "device_target_kmh": deviceTargetSpeedKmh
            ].merging(controllerUnitsTelemetryFields(action: "hr_control_start")) { current, _ in current })
            if deviceTargetSpeedKmh <= 0.1 && speedKmh <= 0.2 {
                hrControlStartedBelt = true
                startWithSpeed(3.0)
            } else if deviceTargetSpeedKmh <= 0.1 {
                hrControlStartedBelt = true
                startWithSpeed(desiredSpeedKmh)
            }
        }
    }
    func stopHrControl() {
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
        sendWatchCommand("stop_hr")
    }

    func clearHrFailureReports() { hrFailureReports.removeAll() }

    private func ensureCentral() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: true])
        }
    }

    private func scheduleConnectTimeout(for id: UUID, seconds: TimeInterval = 12) {
        connectTimeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.connectingPeripheralId == id else { return }
            self.appendLog("Connection timeout for \(id.uuidString)")
            if let central, let p = self.discoveredMap[id] {
                central.cancelPeripheralConnection(p)
            }
            DispatchQueue.main.async {
                self.isConnected = false
                self.connectionStateText = "Disconnected"
                self.connectErrorMessage = "Connection timeout"
                self.connectingPeripheralId = nil
            }
        }
        connectTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func recomputeHrStartAllowed() {
        let now = Date()
        let existingGatesAllowStart = HRDomainService
            .heartRateRuntimePrerequisitesAllowStart(
                treadmillConnected: isConnected,
                watchReachable: watchReachable,
                currentHeartRateVisible: hrStreamingActive
            )
        let unitsDecision = controllerUnitsGateDecision(now: now)
        let allowed = ControllerUnitsSafetyPolicy.allowsStart(
            path: .hrControl,
            existingGatesAllowStart: existingGatesAllowStart,
            state: controllerUnitsTruth,
            currentConnectionEpoch: controllerUnitsConnectionEpoch,
            now: now,
            requiresFreshMetricTruth: controllerUnitsTruthRequired
        )
        isHrControlStartAllowed = allowed
        if !allowed {
            let withinGrace = HRDomainService.isWithinInitialHeartRateGrace(
                startedAt: hrControlStartedAt,
                now: Date(),
                graceSeconds: hrStartGraceSeconds
            )
            if !isConnected {
                hrControlStartBlockReasonText = "Нет подключения к дорожке"
            } else if !watchReachable {
                hrControlStartBlockReasonText = "Часы недоступны — откройте приложение на Apple Watch и дождитесь соединения."
            } else if !hrStreamingActive {
                hrControlStartBlockReasonText = "Пульс недоступен — откройте приложение на Apple Watch и дождитесь передачи пульса."
            } else if let unitsBlockReason = unitsDecision.blockReason {
                hrControlStartBlockReasonText = unitsBlockReason.userMessage
            } else {
                hrControlStartBlockReasonText = "Недоступно"
            }
            if isHrControlRunning && !withinGrace && !existingGatesAllowStart {
                hrStatusLine = "HR‑контроль: нет сигнала"
            }
        } else {
            hrControlStartBlockReasonText = nil
        }
        refreshControllerUnitsTruthIfNeeded(
            existingGatesAllowStart: existingGatesAllowStart,
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
                if active != wasActive {
                    self.appendLog("HR stream \(active ? "ACTIVE" : "INACTIVE") (bpm=\(self.heartRateBPM), last=\(hasLast ? "\(secs)s ago" : "none"))")
                    self.logTrainingEvent("hr_stream_state", fields: [
                        "active": active,
                        "hr_bpm": self.heartRateBPM,
                        "last_age_s": hasLast ? secs : -1
                    ])
                }
                self.recomputeHrStartAllowed()
                if active != wasActive {
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

                    guard isConnected else {
                        let elapsed = hrControlStartedAt.map { Int(Date().timeIntervalSince($0)) }
                        logTrainingEvent("hr_control_failed", fields: [
                            "reason": "no_connection",
                            "elapsed_s": elapsed ?? 0
                        ])
                        stopTrainingStructuredLog(reason: "hr_no_connection")
                        hrControlFailed = true
                        infoToastMessage = "HR‑контроль остановлен — нет подключения. Остановка дорожки запрошена, но ещё не подтверждена."
                        appendLog("HR control stopped: no connection")
                        isHrControlRunning = false
                        hrStatusLine = "HR‑контроль остановлен — нет подключения"
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
                        sendWatchCommand("stop_hr")
                        stopBeltWithToggle(reason: "hr_no_connection")
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
                        sendWatchCommand("stop_hr")
                        stopBeltWithToggle(reason: "hr_no_signal")
                        return
                    }

                    let trend = currentHrTrendBpmPerSecond()
                    let controlUseEvidence = makeHeartRateControlUseEvidence(
                        trendUsed: trend != nil,
                        occurredAt: Date()
                    )
                    defer { observeHeartRateControlUse(controlUseEvidence) }
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
                        sendTreadmillSetSpeed(nextSpeed, label: String(format: "SPEED %.1f km/h (HR)", nextSpeed))
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
                    }
                }
            } else if cooldownRuntimeState == nil {
                hrNextDecisionSeconds = 0
                let output = CooldownRuntimeEngine.start(
                    config: currentCooldownConfig(),
                    input: CooldownRuntimeEngine.StartInput(
                        currentBpm: heartRateBPM > 0 ? heartRateBPM : lastKnownHeartRateBPM,
                        deviceTargetSpeedKmh: deviceTargetSpeedKmh,
                        actualSpeedKmh: speedKmh,
                        sessionAggregates: currentCooldownSessionAggregates()
                    )
                )
                let elapsed = hrControlStartedAt.map { Int(Date().timeIntervalSince($0)) }
                applyCooldownOutput(output, sessionElapsedSeconds: elapsed)
            } else if let cooldownState = cooldownRuntimeState {
                hrNextDecisionSeconds = 0
                let output = CooldownRuntimeEngine.tick(
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

        if lastCommandAwaitingAck, let sentAt = lastCommandSentAt {
            if now.timeIntervalSince(sentAt) > commandAckTimeoutSeconds {
                lastCommandAwaitingAck = false
                lastCommandTimeouts += 1
                lastCommandTimeoutsCount = lastCommandTimeouts
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
    }

    // MARK: - BLE write helpers
    private func writeCommand(_ data: Data, label: String, highPriority: Bool = false) {
#if STOP_TRUTH_EXPERIMENT_CAPABILITY
        guard stopTruthExperimentController?.isActive != true else {
            appendLog("Production command blocked while fixed Stop-truth experiment is active: \(label)")
            return
        }
#endif
        enqueueCommand(data, label: label, highPriority: highPriority)
    }

    private func isSpeedCommandLabel(_ label: String) -> Bool {
        label.lowercased().hasPrefix("speed")
    }

    private func resetCommandQueue(reason: String) {
        let dropped = CommandQueueService.clear(queue: &commandQueue)
        commandQueueEpoch += 1
        isCommandQueueProcessing = false
        nextCommandAllowedAt = .distantPast
        appendLog("CMD queue reset: \(reason)")
        logTrainingEvent("command_queue_reset", fields: [
            "reason": reason,
            "dropped_count": dropped
        ])
    }

    private func enqueueCommand(_ data: Data, label: String, highPriority: Bool) {
        let command = CommandQueueService.Command(data: data, label: label)
        if highPriority {
            resetCommandQueue(reason: "high priority → \(label)")
            CommandQueueService.replaceWithHighPriority(queue: &commandQueue, command: command)
            processCommandQueue()
            return
        }

        let result = CommandQueueService.enqueueRegular(
            queue: &commandQueue,
            command: command,
            isSpeedLabel: isSpeedCommandLabel
        )
        if result.coalescedSpeedCount > 0 {
            logTrainingEvent("command_speed_coalesced", fields: [
                "new_label": label,
                "dropped_count": result.coalescedSpeedCount,
                "queue_size_after": commandQueue.count
            ])
        }
        processCommandQueue()
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
                return
            }
            guard !self.commandQueue.isEmpty else {
                self.isCommandQueueProcessing = false
                return
            }
            let next = self.commandQueue.removeFirst()
            self.performWrite(next.data, label: next.label)
            self.nextCommandAllowedAt = Date().addingTimeInterval(self.commandMinIntervalSecondsForCurrentProtocol())
            self.isCommandQueueProcessing = false
            if !self.commandQueue.isEmpty {
                self.processCommandQueue()
            }
        }
    }

    private func performWrite(_ data: Data, label: String) {
        guard isConnected else {
            appendLog("WRITE SKIPPED (not connected): \(label)")
            if label == "STOP" {
                markInitialStopCommandNotSent(reason: "not_connected")
            }
            return
        }
        guard let p = connectedPeripheral, let ch = commandCharacteristic else {
            appendLog("WRITE SKIPPED (no characteristic): \(label)")
            if label == "STOP" {
                markInitialStopCommandNotSent(reason: "characteristic_unavailable")
            }
            return
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
        treadmillProtocol = .unknown
        ftmsHasControl = false
        ftmsControlRequestInFlight = false
        ftmsDidReadSupportedSpeedRange = false
        fitShowDidRequestInitialStatus = false
        commandCharacteristic = nil
        notifyCharacteristic = nil
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

    private func enqueueFtmsRequestControlIfNeeded() {
        guard treadmillProtocol == .ftms else { return }
        guard !ftmsHasControl else { return }
        guard !ftmsControlRequestInFlight else { return }
        guard let ch = commandCharacteristic, ch.uuid == ftmsCharControlPoint else {
            appendLog("FTMS request control skipped: control point not ready")
            return
        }
        ftmsControlRequestInFlight = true
        writeCommand(buildFtmsRequestControlPacket(), label: "FTMS REQUEST CONTROL")
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

    private func sendTreadmillSetSpeed(_ kmh: Double, label: String) {
        if kmh > 0.1 {
            endStopObservationForNewMotion()
        }
        switch treadmillProtocol {
        case .walkingPad:
            writeCommand(buildWalkingPadSetSpeedPacket(kmh: kmh), label: label)
        case .ftms:
            enqueueFtmsRequestControlIfNeeded()
            if shouldAutoStartForSpeedChange(kmh: kmh) {
                writeCommand(buildFtmsStartOrResumePacket(), label: "FTMS START/RESUME (auto)")
            }
            writeCommand(buildFtmsSetSpeedPacket(kmh: kmh), label: label)
        case .fitShow:
            if shouldAutoStartForSpeedChange(kmh: kmh) {
                writeCommand(buildFitShowStartOrResumePacket(), label: "FitShow START/RESUME (auto)")
            }
            writeCommand(buildFitShowSetSpeedPacket(kmh: kmh, incline: 0), label: label)
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

    private func applyFitShowFrame(_ frame: FitShowFrame) {
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
                return
            }
            let state = Int(frame.payload[0])
            var speedKmh: Double? = nil
            if frame.payload.count >= 3 {
                let speedTenths = Int(frame.payload[1])
                speedKmh = Double(speedTenths) / 10.0
            }
            DispatchQueue.main.async {
                self.deviceReportedState = state
                if let speedKmh {
                    self.deviceReportedSpeedKmh = speedKmh
                    self.deviceReportedAppSpeedKmh = speedKmh
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
        let entry = WorkoutEntry(
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
        workoutHistory.insert(entry, at: 0)
        pendingHealthkitWorkoutUUID = nil
        pendingHealthkitWorkoutProfileID = attachedHealthkitWorkoutUUID == nil ? workoutProfileID : nil
        hrWorkoutRecorded = true
        saveWorkoutHistory()
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
        let matchWindow: TimeInterval = 15 * 60
        let targetProfileID = pendingHealthkitWorkoutProfileID ?? activeUserProfileID
        guard let targetProfileID else {
            pendingHealthkitWorkoutUUID = uuid
            return
        }

        var entries = loadWorkoutHistory(profileID: targetProfileID)

        let attachUUID: (Int) -> Void = { index in
            let entry = entries[index]
            entries[index] = WorkoutEntry(
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
            self.saveWorkoutHistory(entries, profileID: targetProfileID)
            if self.activeUserProfileID == targetProfileID {
                self.workoutHistory = entries
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

    private func scheduleWrite(_ data: Data, label: String, after delay: TimeInterval) {
        let epoch = commandQueueEpoch
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.commandQueueEpoch == epoch else { return }
            self.writeCommand(data, label: label)
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
        if let error { appendLog("Discover services error: \(error.localizedDescription)") }
        guard let services = peripheral.services, !services.isEmpty else {
            appendLog("No services discovered")
            return
        }
        let discoveredUuids = Set(services.map { $0.uuid })
        let selected = selectTreadmillProtocol(from: discoveredUuids)
        if treadmillProtocol != selected {
            treadmillProtocol = selected
            appendLog("Treadmill protocol selected: \(selected.rawValue)")
            logTrainingEvent("treadmill_protocol_selected", fields: [
                "protocol": selected.rawValue,
                "services": services.map { $0.uuid.uuidString }
            ])
            recomputeHrStartAllowed()
        }
        for s in services {
            appendLog("Service discovered: \(s.uuid.uuidString)")
            if supportedServiceUuids.contains(s.uuid) {
                peripheral.discoverCharacteristics(nil, for: s)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { appendLog("Discover characteristics error: \(error.localizedDescription)") }
        guard let chars = service.characteristics else {
            appendLog("No characteristics for service \(service.uuid.uuidString)")
            return
        }
        for c in chars {
            appendLog("Char: \(c.uuid.uuidString) props=\(c.properties)")
        }

        switch treadmillProtocol {
        case .walkingPad:
            guard service.uuid == serviceFE00 else { return }
            let notify = chars.first(where: { $0.uuid == charFE01 && ($0.properties.contains(.notify) || $0.properties.contains(.indicate)) })
            let write = chars.first(where: { $0.uuid == charFE02 && ($0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)) })

            if let n = notify {
                notifyCharacteristic = n
                stopObservationStreamID = UUID()
                subscribe(peripheral, to: n, label: "FE01")
            } else {
                appendLog("WalkingPad: FE01 notify not found on FE00")
            }
            if let w = write {
                commandCharacteristic = w
                appendLog("WalkingPad: command characteristic set to \(w.uuid.uuidString)")
                requestInitialControllerUnitsTruthIfReady()
            } else {
                appendLog("WalkingPad: FE02 write not found on FE00")
            }

        case .ftms:
            guard service.uuid == serviceFTMS else { return }
            if let dataChar = chars.first(where: { $0.uuid == ftmsCharTreadmillData && ($0.properties.contains(.notify) || $0.properties.contains(.indicate)) }) {
                subscribe(peripheral, to: dataChar, label: "FTMS treadmill data")
            } else {
                appendLog("FTMS: treadmill data characteristic not found")
            }
            if let statusChar = chars.first(where: { $0.uuid == ftmsCharMachineStatus && ($0.properties.contains(.notify) || $0.properties.contains(.indicate)) }) {
                subscribe(peripheral, to: statusChar, label: "FTMS machine status")
            }
            if let cpChar = chars.first(where: { $0.uuid == ftmsCharControlPoint && ($0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)) }) {
                commandCharacteristic = cpChar
                appendLog("FTMS: control point set to \(cpChar.uuid.uuidString)")
                if cpChar.properties.contains(.notify) || cpChar.properties.contains(.indicate) {
                    subscribe(peripheral, to: cpChar, label: "FTMS control point indications")
                }
            } else {
                appendLog("FTMS: control point characteristic not found")
            }
            if !ftmsDidReadSupportedSpeedRange {
                if let rangeChar = chars.first(where: { $0.uuid == ftmsCharSupportedSpeedRange && $0.properties.contains(.read) }) {
                    ftmsDidReadSupportedSpeedRange = true
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
                subscribe(peripheral, to: rx, label: "FitShow RX")
            } else {
                appendLog("FitShow: RX characteristic (FFF1) not found")
            }
            if let tx = chars.first(where: { $0.uuid == fitShowCharTx && ($0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)) }) {
                commandCharacteristic = tx
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
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            appendLog("Notify state error for \(characteristic.uuid.uuidString): \(error.localizedDescription)")
            return
        }
        guard treadmillProtocol == .walkingPad,
              characteristic.uuid == charFE01,
              characteristic.isNotifying,
              peripheral.identifier == connectedPeripheralId,
              characteristic === notifyCharacteristic else {
            return
        }
        appendLog("WalkingPad: FE01 notifications active")
        requestInitialControllerUnitsTruthIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
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
        if lastCommandAwaitingAck,
           let sentAt = lastCommandSentAt,
           now.timeIntervalSince(sentAt) <= commandAckTimeoutSeconds,
           shouldTreatAsCommandAck(characteristic: characteristic, data: data) {
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
                }
                appendLog("Notify FTMS treadmill data: speed=\(String(format: "%.2f", parsed.instantaneousSpeedKmh)) km/h moving=\(parsed.isMoving)")
                logActualSpeedChangeIfNeeded(parsed.instantaneousSpeedKmh, source: "ftms_treadmill_data")
                logTrainingEvent("notify_ftms_treadmill_data", fields: [
                    "speed_kmh": parsed.instantaneousSpeedKmh,
                    "moving": parsed.isMoving
                ])
            } else if characteristic.uuid == ftmsCharControlPoint, let resp = parseFtmsControlPointResponse(data) {
                if resp.requestedOpcode == 0x00 {
                    ftmsControlRequestInFlight = false
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
                applyFitShowFrame(frame)
            } else {
                appendLog("Notify \(characteristic.uuid.uuidString): \(hex(data))")
            }

        case .unknown:
            appendLog("Notify \(characteristic.uuid.uuidString): \(hex(data))")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
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
