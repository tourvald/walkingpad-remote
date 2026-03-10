import Foundation
import SwiftUI
import Combine
import CoreBluetooth
import HealthKit
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
    @Published var discoveredPeripherals: [DiscoveredPeripheral] = []
    @Published var knownPeripherals: [KnownPeripheral] = []

    private struct KnownPeripheralDTO: Codable { let id: UUID; let name: String }
    private let knownStoreKey = "known_peripherals_store_v1"
    private let hrSettingsStoreKey = "hr_settings_v1"
    private let zonePlanStoreKey = "zone_plan_v1"
    private let workoutHistoryStoreKey = "workout_history_v1"
    private var isLoadingHrSettings: Bool = false
    private var autoConnectSuppressed: Bool = false
    private var hrSessionTotalSeconds: Int = 0
    private var hrControlStartedBelt: Bool = false
    private var hrCooldownTotalSeconds: Int = 0
    private var hrCooldownStartSpeed: Double = 0
    private var hrCooldownLastSentSpeed: Double = 0
    private var hrCooldownStepKmh: Double = 0.0
    private var hrCooldownStepIntervalSeconds: Int = 1
    @Published var hrCooldownMinSpeed: Double = 3.5 { didSet { saveHrSettingsIfNeeded() } }
    @Published var hrCooldownTargetBpm: Int = 100 { didSet { saveHrSettingsIfNeeded() } }
    @Published var hrCooldownMaxMinutes: Int = 5 { didSet { saveHrSettingsIfNeeded() } }
    private let hrCooldownHoldSeconds: Int = 20
    private var hrCooldownMaxSeconds: Int { hrCooldownMaxMinutes * 60 }
    private var hrCooldownStableSeconds: Int = 0
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
    private var hrTrendSamples: [(Date, Double)] = []
    private var hrTrendEmaBpm: Double? = nil
    private var hrTrendMinWindowSeconds: TimeInterval {
        max(6, hrTrendWindowSeconds * 0.4)
    }
    private var hrZoneSeconds: [Int] = Array(repeating: 0, count: 5)
    private var hrSessionPeakBPM: Int = 0
    private var hrMainSumBPM: Int = 0
    private var hrMainCountBPM: Int = 0
    private var hrMainPeakBPM: Int = 0
    private var hrCooldownStartBPM: Int = 0
    private var hrCooldownEndBPM: Int = 0
    private var hrCooldownPeakBPM: Int = 0
    private var hrCooldownTargetHitElapsedSeconds: Int? = nil
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
    private var hrControlFailed: Bool = false
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
    private let trainingLogIsoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    struct TrainingLogsCsvExport {
        let csvURL: URL
        let rowCount: Int
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

    private func loadWorkoutHistory() {
        guard let data = UserDefaults.standard.data(forKey: workoutHistoryStoreKey),
              let list = try? JSONDecoder().decode([WorkoutEntryDTO].self, from: data) else {
            return
        }
        self.workoutHistory = list.map {
            WorkoutEntry(
                id: $0.id,
                date: $0.date,
                beatsPerMeter: $0.beatsPerMeter,
                targetBpm: $0.targetBpm,
                durationSeconds: $0.durationSeconds,
                avgBpm: $0.avgBpm,
                avgSpeedKmh: $0.avgSpeedKmh,
                healthkitWorkoutUUID: $0.healthkitWorkoutUUID,
                zoneSeconds: $0.zoneSeconds
            )
        }
    }

    private func saveWorkoutHistory() {
        let list = workoutHistory.prefix(50).map {
            WorkoutEntryDTO(
                id: $0.id,
                date: $0.date,
                beatsPerMeter: $0.beatsPerMeter,
                targetBpm: $0.targetBpm,
                durationSeconds: $0.durationSeconds,
                avgBpm: $0.avgBpm,
                avgSpeedKmh: $0.avgSpeedKmh,
                healthkitWorkoutUUID: $0.healthkitWorkoutUUID,
                zoneSeconds: $0.zoneSeconds
            )
        }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: workoutHistoryStoreKey)
        }
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
        guard let data = UserDefaults.standard.data(forKey: hrSettingsStoreKey),
              let dto = try? JSONDecoder().decode(HrSettingsDTO.self, from: data) else {
            return
        }
        isLoadingHrSettings = true
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
            hrCooldownTargetBpm = max(80, min(140, cooldownTarget))
        }
        if let cooldownMin = dto.cooldownMinSpeed {
            hrCooldownMinSpeed = max(2.0, min(6.0, cooldownMin))
        }
        if let cooldownMaxMinutes = dto.cooldownMaxMinutes {
            hrCooldownMaxMinutes = max(1, min(30, cooldownMaxMinutes))
        }
        normalizeAdaptivePercentThresholdSettings()
        isLoadingHrSettings = false
        normalizeZoneBounds()
        sendHrTargetBpm()
    }

    private func saveHrSettingsIfNeeded() {
        guard !isLoadingHrSettings else { return }
        let dto = HrSettingsDTO(
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
        if let data = try? JSONEncoder().encode(dto) {
            UserDefaults.standard.set(data, forKey: hrSettingsStoreKey)
        }
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
        guard let data = UserDefaults.standard.data(forKey: zonePlanStoreKey),
              let list = try? JSONDecoder().decode([Int].self, from: data) else {
            return
        }
        isUpdatingZonePlan = true
        zonePlanMinutes = normalizeZonePlan(list)
        isUpdatingZonePlan = false
    }

    private func saveZonePlan() {
        let normalized = normalizeZonePlan(zonePlanMinutes)
        if let data = try? JSONEncoder().encode(normalized) {
            UserDefaults.standard.set(data, forKey: zonePlanStoreKey)
        }
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

    // HR control
    @Published var isHrControlRunning: Bool = false
    @Published var isHrControlStartAllowed: Bool = false
    @Published var hrControlStartBlockReasonText: String? = nil
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
        hrCooldownStartBPM = 0
        hrCooldownEndBPM = 0
        hrCooldownPeakBPM = 0
        hrCooldownTargetHitElapsedSeconds = nil
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
            if let started = hrControlStartedAt,
               Date().timeIntervalSince(started) < Double(hrStartGraceSeconds) {
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

    private func cooldownElapsedSecondsSnapshot() -> Int {
        guard hrCooldownTotalSeconds > 0 else { return 0 }
        return max(0, hrCooldownTotalSeconds - hrCooldownRemainingSeconds)
    }

    private func cooldownHrDropBPMSnapshot() -> Int {
        guard hrCooldownStartBPM > 0, hrCooldownEndBPM > 0 else { return 0 }
        return hrCooldownStartBPM - hrCooldownEndBPM
    }

    private func cooldownRecoveryBpmPerMinuteSnapshot() -> Double {
        let elapsed = cooldownElapsedSecondsSnapshot()
        guard elapsed > 0 else { return 0 }
        return (Double(cooldownHrDropBPMSnapshot()) * 60.0) / Double(elapsed)
    }

    private func trainingLogsDirectoryURL() -> URL? {
        TrainingTelemetryWriter.makeDirectoryURL(directoryName: trainingLogsDirectoryName) { [weak self] message in
            self?.appendLog(message)
        }
    }

    private func pruneTrainingLogs(in directory: URL) {
        TrainingTelemetryWriter.pruneJsonlFiles(in: directory, maxFiles: trainingLogMaxFiles)
    }

    private func makeTrainingLogPayload(event: String, fields: [String: Any]) -> [String: Any] {
        let zone = currentTargetZoneSnapshot()
        var payload: [String: Any] = [
            "ts": trainingLogIsoFormatter.string(from: Date()),
            "event": event,
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
            "cooldown_start_hr_bpm": hrCooldownStartBPM,
            "cooldown_end_hr_bpm": hrCooldownEndBPM,
            "cooldown_peak_hr_bpm": hrCooldownPeakBPM,
            "cooldown_planned_s": hrCooldownTotalSeconds,
            "cooldown_elapsed_s": cooldownElapsedSecondsSnapshot(),
            "cooldown_target_hit_elapsed_s": hrCooldownTargetHitElapsedSeconds ?? -1,
            "cooldown_hr_drop_bpm": cooldownHrDropBPMSnapshot(),
            "cooldown_hr_recovery_bpm_per_min": cooldownRecoveryBpmPerMinuteSnapshot(),
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
            ])
        } catch {
            appendLog("Training log file open error: \(error.localizedDescription)")
        }
    }

    private func stopTrainingStructuredLog(reason: String) {
        trainingLogQueue.sync {
            guard trainingLogFileHandle != nil else { return }
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
                "cooldown_start_hr_bpm": hrCooldownStartBPM,
                "cooldown_end_hr_bpm": hrCooldownEndBPM,
                "cooldown_peak_hr_bpm": hrCooldownPeakBPM,
                "cooldown_planned_s": hrCooldownTotalSeconds,
                "cooldown_elapsed_s": cooldownElapsedSecondsSnapshot(),
                "cooldown_target_hit_elapsed_s": hrCooldownTargetHitElapsedSeconds ?? -1,
                "cooldown_hr_drop_bpm": cooldownHrDropBPMSnapshot(),
                "cooldown_hr_recovery_bpm_per_min": cooldownRecoveryBpmPerMinuteSnapshot(),
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
    }

    func prepareTrainingLogsCsvExport() -> TrainingLogsCsvExport? {
        trainingLogQueue.sync {
            trainingLogFileHandle?.synchronizeFile()
        }
        guard let dir = trainingLogsDirectoryURL() else { return nil }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let jsonlFiles = files
            .filter { $0.pathExtension.lowercased() == "jsonl" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return l < r
            }
        guard !jsonlFiles.isEmpty else { return nil }

        let headers: [String] = [
            "source_file",
            "ts",
            "session_id",
            "event",
            "phase",
            "session_state",
            "is_hr_running",
            "hr_bpm",
            "hr_last_bpm",
            "target_bpm",
            "target_zone_index",
            "target_zone_lower_bpm",
            "target_zone_upper_bpm",
            "session_peak_bpm",
            "main_avg_bpm",
            "main_peak_bpm",
            "zone1_s",
            "zone2_s",
            "zone3_s",
            "zone4_s",
            "zone5_s",
            "zone4plus_s",
            "cooldown_start_hr_bpm",
            "cooldown_end_hr_bpm",
            "cooldown_peak_hr_bpm",
            "cooldown_planned_s",
            "cooldown_elapsed_s",
            "cooldown_target_hit_elapsed_s",
            "cooldown_hr_drop_bpm",
            "cooldown_hr_recovery_bpm_per_min",
            "speed_actual_kmh",
            "speed_target_kmh",
            "speed_device_target_kmh",
            "speed_reported_kmh",
            "speed_reported_app_kmh",
            "speed_delta_kmh",
            "decision",
            "reason",
            "diff_bpm",
            "diff_percent",
            "step_tag",
            "step_kmh",
            "label",
            "char_uuid",
            "write_type",
            "queue_size",
            "delay_s",
            "status",
            "error",
            "raw_json"
        ]

        var lines: [String] = [headers.map(csvEscape).joined(separator: ",")]
        var exportedRows = 0

        for file in jsonlFiles {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for rawLine in content.split(whereSeparator: \.isNewline) {
                let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                guard let data = line.data(using: .utf8),
                      let payload = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
                    continue
                }
                let zoneSeconds = zoneSecondsFromPayload(payload)

                let row: [String] = [
                    file.lastPathComponent,
                    csvString(payload["ts"]),
                    csvString(payload["session_id"]),
                    csvString(payload["event"]),
                    csvString(payload["phase"]),
                    csvString(payload["session_state"]),
                    csvString(payload["is_hr_running"]),
                    csvString(payload["hr_bpm"]),
                    csvString(payload["hr_last_bpm"]),
                    csvString(payload["target_bpm"]),
                    csvString(payload["target_zone_index"]),
                    csvString(payload["target_zone_lower_bpm"]),
                    csvString(payload["target_zone_upper_bpm"]),
                    csvString(payload["session_peak_bpm"]),
                    csvString(payload["main_avg_bpm"]),
                    csvString(payload["main_peak_bpm"]),
                    String(zoneSeconds[0]),
                    String(zoneSeconds[1]),
                    String(zoneSeconds[2]),
                    String(zoneSeconds[3]),
                    String(zoneSeconds[4]),
                    csvString(payload["zone4plus_seconds"]),
                    csvString(payload["cooldown_start_hr_bpm"]),
                    csvString(payload["cooldown_end_hr_bpm"]),
                    csvString(payload["cooldown_peak_hr_bpm"]),
                    csvString(payload["cooldown_planned_s"]),
                    csvString(payload["cooldown_elapsed_s"]),
                    csvString(payload["cooldown_target_hit_elapsed_s"]),
                    csvString(payload["cooldown_hr_drop_bpm"]),
                    csvString(payload["cooldown_hr_recovery_bpm_per_min"]),
                    csvString(payload["speed_actual_kmh"]),
                    csvString(payload["speed_target_kmh"]),
                    csvString(payload["speed_device_target_kmh"]),
                    csvString(payload["speed_reported_kmh"]),
                    csvString(payload["speed_reported_app_kmh"]),
                    csvString(payload["speed_delta_kmh"]),
                    csvString(payload["decision"]),
                    csvString(payload["reason"]),
                    csvString(payload["diff_bpm"]),
                    csvString(payload["diff_percent"]),
                    csvString(payload["step_tag"]),
                    csvString(payload["step_kmh"]),
                    csvString(payload["label"]),
                    csvString(payload["char_uuid"]),
                    csvString(payload["write_type"]),
                    csvString(payload["queue_size"]),
                    csvString(payload["delay_s"]),
                    csvString(payload["status"]),
                    csvString(payload["error"]),
                    jsonString(payload)
                ]

                lines.append(row.map(csvEscape).joined(separator: ","))
                exportedRows += 1
            }
        }

        guard exportedRows > 0 else { return nil }
        let ts = trainingLogTimestampFormatter.string(from: Date())
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("Training_History_\(ts).csv")
        do {
            try lines.joined(separator: "\n").write(to: outURL, atomically: true, encoding: .utf8)
            appendLog("Training CSV exported: \(outURL.lastPathComponent) rows=\(exportedRows)")
            return TrainingLogsCsvExport(
                csvURL: outURL,
                rowCount: exportedRows,
                sourceFiles: jsonlFiles
            )
        } catch {
            appendLog("Training CSV export failed: \(error.localizedDescription)")
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

        appendLog("Training raw logs cleanup: removed=\(cleanup.removedCount) skipped=\(cleanup.skippedCount) freed=\(cleanup.reclaimedBytes) rows=\(export.rowCount)")
        DispatchQueue.main.async {
            self.infoToastMessage = message
        }
    }

    private func csvString(_ value: Any?) -> String {
        TrainingTelemetryWriter.csvString(value)
    }

    private func zoneSecondsFromPayload(_ payload: [String: Any]) -> [Int] {
        TrainingTelemetryWriter.zoneSeconds(from: payload)
    }

    private func csvEscape(_ value: String) -> String {
        TrainingTelemetryWriter.csvEscape(value)
    }

    private func jsonString(_ value: Any) -> String {
        TrainingTelemetryWriter.jsonString(value)
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
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
        loadHrSettings()
        loadZonePlan()
        loadWorkoutHistory()
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
            self.watchReachable = session.isReachable
            self.watchPaired = session.isPaired
            self.watchAppInstalled = session.isWatchAppInstalled
            self.recomputeHrStartAllowed()
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

    // Treadmill control
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
        guard wasRunning else { return }
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
        // Start only if allowed: must be connected, watch reachable, and HR stream active (fresh)
        if isConnected && watchReachable && hrStreamingActive {
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
            hrCooldownRemainingSeconds = 0
            hrCooldownProgress = 0
            hrCooldownTotalSeconds = 0
            hrCooldownStartSpeed = 0
            hrCooldownLastSentSpeed = 0
            hrCooldownStableSeconds = 0
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
            ])
            if deviceTargetSpeedKmh <= 0.1 && speedKmh <= 0.2 {
                hrControlStartedBelt = true
                startWithSpeed(3.0)
            } else if deviceTargetSpeedKmh <= 0.1 {
                hrControlStartedBelt = true
                startWithSpeed(desiredSpeedKmh)
            }
        } else {
            isHrControlRunning = false
            if !isConnected {
                hrControlStartBlockReasonText = "Нет подключения к дорожке"
            } else if !watchReachable {
                hrControlStartBlockReasonText = "Часы недоступны — откройте приложение на Apple Watch и дождитесь соединения."
            } else if !hrStreamingActive {
                hrControlStartBlockReasonText = "Пульс недоступен — откройте приложение на Apple Watch и дождитесь передачи пульса."
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
        hrStatusLine = "HR‑контроль остановлен"
        hrNextDecisionSeconds = 0
        hrRemainingSeconds = 0
        hrProgress = 0
        hrDecisionDetails = ""
        hrPredictorStatusLine = ""
        hrCooldownRemainingSeconds = 0
        hrCooldownProgress = 0
        hrCooldownTotalSeconds = 0
        hrCooldownStableSeconds = 0
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
        let allowed = isConnected && watchReachable && hrStreamingActive
        isHrControlStartAllowed = allowed
        if !allowed {
            let withinGrace: Bool = {
                guard let start = hrControlStartedAt else { return false }
                return Date().timeIntervalSince(start) < TimeInterval(hrStartGraceSeconds)
            }()
            if !isConnected {
                hrControlStartBlockReasonText = "Нет подключения к дорожке"
            } else if !watchReachable {
                hrControlStartBlockReasonText = "Часы недоступны — откройте приложение на Apple Watch и дождитесь соединения."
            } else if !hrStreamingActive {
                hrControlStartBlockReasonText = "Пульс недоступен — откройте приложение на Apple Watch и дождитесь передачи пульса."
            } else {
                hrControlStartBlockReasonText = "Недоступно"
            }
            if isHrControlRunning && !withinGrace {
                hrStatusLine = "HR‑контроль: нет сигнала"
            }
        } else {
            hrControlStartBlockReasonText = nil
        }
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
                let active = (self.heartRateBPM > 0) && hasLast && (secs <= self.hrStaleThresholdSeconds)
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
            let withinGrace: Bool = {
                guard let start = hrControlStartedAt else { return false }
                return Date().timeIntervalSince(start) < TimeInterval(hrStartGraceSeconds)
            }()
            if hrStreamingActive && heartRateBPM > 0 {
                hrNoDataSeconds = 0
                hrSessionPeakBPM = max(hrSessionPeakBPM, heartRateBPM)
                if hrRemainingSeconds > 0 {
                    hrMainSumBPM += heartRateBPM
                    hrMainCountBPM += 1
                    hrMainPeakBPM = max(hrMainPeakBPM, heartRateBPM)
                }
                if hrCooldownRemainingSeconds > 0 {
                    if hrCooldownStartBPM <= 0 {
                        hrCooldownStartBPM = heartRateBPM
                    }
                    hrCooldownEndBPM = heartRateBPM
                    hrCooldownPeakBPM = max(hrCooldownPeakBPM, heartRateBPM)
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
                        infoToastMessage = "HR‑контроль остановлен — нет подключения. Дорожка останавливается."
                        appendLog("HR control stopped: no connection")
                        isHrControlRunning = false
                        hrStatusLine = "HR‑контроль остановлен — нет подключения"
                        hrNextDecisionSeconds = 0
                        hrRemainingSeconds = 0
                        hrProgress = 0
                        hrDecisionDetails = ""
                        hrPredictorStatusLine = ""
                        hrCooldownRemainingSeconds = 0
                        hrCooldownProgress = 0
                        hrCooldownTotalSeconds = 0
                        hrCooldownStableSeconds = 0
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
                        let missingSeconds: Int = {
                            if let last = hrLastValueAt {
                                return max(0, Int(Date().timeIntervalSince(last)))
                            }
                            return hrNoDataMaxSeconds
                        }()
                        if missingSeconds < hrNoDataMaxSeconds {
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
                        infoToastMessage = "HR‑контроль остановлен — нет данных пульса. Дорожка останавливается."
                        appendLog("HR control stopped: no HR for \(missingSeconds)s")
                        isHrControlRunning = false
                        hrStatusLine = "HR‑контроль остановлен — нет данных пульса"
                        hrNextDecisionSeconds = 0
                        hrRemainingSeconds = 0
                        hrProgress = 0
                        hrDecisionDetails = ""
                        hrPredictorStatusLine = ""
                        hrCooldownRemainingSeconds = 0
                        hrCooldownProgress = 0
                        hrCooldownTotalSeconds = 0
                        hrCooldownStableSeconds = 0
                        hrNoDataSeconds = 0
                        recordHrWorkoutIfNeeded(durationOverride: elapsed, failed: true)
                        hrControlStartedAt = nil
                        hrControlStartedBelt = false
                        sendWatchCommand("stop_hr")
                        stopBeltWithToggle(reason: "hr_no_signal")
                        return
                    }

                    let trend = currentHrTrendBpmPerSecond()
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
            } else if hrCooldownRemainingSeconds <= 0 {
                let step = max(0.1, min(2.0, hrSpeedStepKmh))
                let interval = max(1, hrDecisionIntervalSeconds)
                hrCooldownStepKmh = step
                hrCooldownStepIntervalSeconds = interval
                hrCooldownStartSpeed = max(hrCooldownMinSpeed, deviceTargetSpeedKmh > 0.1 ? deviceTargetSpeedKmh : speedKmh)
                hrCooldownLastSentSpeed = hrCooldownStartSpeed
                hrCooldownStableSeconds = 0
                let cooldownStartBPM = heartRateBPM > 0 ? heartRateBPM : lastKnownHeartRateBPM
                hrCooldownStartBPM = max(0, cooldownStartBPM)
                hrCooldownEndBPM = hrCooldownStartBPM
                hrCooldownPeakBPM = hrCooldownStartBPM
                hrCooldownTargetHitElapsedSeconds = nil
                hrCooldownTotalSeconds = hrCooldownMaxSeconds
                hrCooldownRemainingSeconds = hrCooldownMaxSeconds
                hrCooldownProgress = 0
                hrNextDecisionSeconds = 0
                hrStatusLine = "Заминка"
                hrDecisionDetails = "Заминка: цель \(hrCooldownTargetBpm) bpm, мин. скорость \(String(format: "%.1f", hrCooldownMinSpeed)) км/ч"
                appendLog("HR cooldown start: from \(String(format: "%.1f", hrCooldownStartSpeed)) to \(String(format: "%.1f", hrCooldownMinSpeed)) target=\(hrCooldownTargetBpm) bpm step=\(String(format: "%.1f", step)) interval=\(interval)s max=\(hrCooldownMaxSeconds)s")
                logTrainingEvent("cooldown_start", fields: [
                    "from_speed_kmh": hrCooldownStartSpeed,
                    "target_bpm": hrCooldownTargetBpm,
                    "min_speed_kmh": hrCooldownMinSpeed,
                    "step_kmh": step,
                    "interval_s": interval,
                    "max_s": hrCooldownMaxSeconds,
                    "start_hr_bpm": hrCooldownStartBPM,
                    "session_peak_bpm": hrSessionPeakBPM,
                    "main_avg_bpm": mainPhaseAverageBPMSnapshot(),
                    "main_peak_bpm": hrMainPeakBPM,
                    "zone_seconds": zoneSecondsSnapshot(),
                    "zone4plus_seconds": zone4PlusSecondsSnapshot()
                ])
            } else {
                hrCooldownRemainingSeconds = max(0, hrCooldownRemainingSeconds - 1)
                hrCooldownProgress = hrCooldownTotalSeconds > 0 ? (1.0 - (Double(hrCooldownRemainingSeconds) / Double(hrCooldownTotalSeconds))) : 0

                let elapsed = hrCooldownTotalSeconds - hrCooldownRemainingSeconds
                let observedSpeed = max(speedKmh, deviceReportedSpeedKmh)
                let hrOk = heartRateBPM > 0 && heartRateBPM <= hrCooldownTargetBpm
                if hrOk && hrCooldownTargetHitElapsedSeconds == nil {
                    hrCooldownTargetHitElapsedSeconds = elapsed
                }
                if observedSpeed <= hrCooldownMinSpeed + 0.05 && hrOk {
                    hrCooldownStableSeconds += 1
                } else {
                    hrCooldownStableSeconds = 0
                }
                logTrainingEvent("cooldown_state", fields: [
                    "hr_bpm": heartRateBPM,
                    "target_bpm": hrCooldownTargetBpm,
                    "speed_kmh": observedSpeed,
                    "elapsed_s": elapsed,
                    "stable_s": hrCooldownStableSeconds,
                    "stable_required_s": hrCooldownHoldSeconds,
                    "remaining_s": hrCooldownRemainingSeconds,
                    "target_hit_elapsed_s": hrCooldownTargetHitElapsedSeconds ?? -1,
                    "start_hr_bpm": hrCooldownStartBPM,
                    "session_peak_bpm": hrSessionPeakBPM,
                    "main_avg_bpm": mainPhaseAverageBPMSnapshot(),
                    "main_peak_bpm": hrMainPeakBPM
                ])

                if hrCooldownTotalSeconds > 0 && hrCooldownStepIntervalSeconds > 0 && elapsed % hrCooldownStepIntervalSeconds == 0 {
                    let diff = heartRateBPM > 0 ? (heartRateBPM - hrCooldownTargetBpm) : 1
                    let adaptiveFactor = diff > 0 ? min(1.0, Double(diff) / 12.0) : 1.0
                    let rawTarget = hrCooldownLastSentSpeed - (hrCooldownStepKmh * adaptiveFactor)
                    let target = max(hrCooldownMinSpeed, rawTarget)
                    if abs(target - hrCooldownLastSentSpeed) >= 0.01 {
                        let old = deviceTargetSpeedKmh
                        desiredSpeedKmh = target
                        deviceTargetSpeedKmh = target
                        recordSpeedChange(from: old, to: target, reason: "cooldown_set")
                        lastCommandLine = String(format: "CMD cooldown adjust -> %.1f", target)
                        sendTreadmillSetSpeed(target, label: String(format: "SPEED %.1f km/h (cooldown)", target))
                        hrCooldownLastSentSpeed = target
                        appendLog("HR cooldown speed: \(String(format: "%.1f", target)) HR=\(heartRateBPM)")
                        logTrainingEvent("cooldown_speed_set", fields: [
                            "hr_bpm": heartRateBPM,
                            "target_bpm": hrCooldownTargetBpm,
                            "adaptive_factor": adaptiveFactor,
                            "speed_before_kmh": old,
                            "speed_after_kmh": target
                        ])
                    }
                }

                hrDecisionDetails = "Заминка: HR \(heartRateBPM) / цель \(hrCooldownTargetBpm) · скорость \(String(format: "%.1f", observedSpeed)) · стаб \(hrCooldownStableSeconds)/\(hrCooldownHoldSeconds)с"

                if hrCooldownStableSeconds >= hrCooldownHoldSeconds || hrCooldownRemainingSeconds == 0 {
                    let finishReason = hrCooldownStableSeconds >= hrCooldownHoldSeconds ? "stable_reached" : "timeout"
                    logTrainingEvent("cooldown_complete", fields: [
                        "reason": finishReason,
                        "stable_s": hrCooldownStableSeconds,
                        "remaining_s": hrCooldownRemainingSeconds,
                        "hr_bpm": heartRateBPM,
                        "target_bpm": hrCooldownTargetBpm,
                        "elapsed_s": cooldownElapsedSecondsSnapshot(),
                        "planned_s": hrCooldownTotalSeconds,
                        "target_hit_elapsed_s": hrCooldownTargetHitElapsedSeconds ?? -1,
                        "start_hr_bpm": hrCooldownStartBPM,
                        "end_hr_bpm": hrCooldownEndBPM,
                        "peak_hr_bpm": hrCooldownPeakBPM,
                        "hr_drop_bpm": cooldownHrDropBPMSnapshot(),
                        "hr_recovery_bpm_per_min": cooldownRecoveryBpmPerMinuteSnapshot(),
                        "session_peak_bpm": hrSessionPeakBPM,
                        "main_avg_bpm": mainPhaseAverageBPMSnapshot(),
                        "main_peak_bpm": hrMainPeakBPM,
                        "zone_seconds": zoneSecondsSnapshot(),
                        "zone4plus_seconds": zone4PlusSecondsSnapshot()
                    ])
                    if finishReason == "timeout", heartRateBPM > hrCooldownTargetBpm {
                        logTrainingEvent("cooldown_insufficient", fields: [
                            "hr_bpm": heartRateBPM,
                            "target_bpm": hrCooldownTargetBpm,
                            "excess_bpm": heartRateBPM - hrCooldownTargetBpm,
                            "elapsed_s": cooldownElapsedSecondsSnapshot(),
                            "planned_s": hrCooldownTotalSeconds,
                            "start_hr_bpm": hrCooldownStartBPM,
                            "end_hr_bpm": hrCooldownEndBPM,
                            "hr_drop_bpm": cooldownHrDropBPMSnapshot(),
                            "hr_recovery_bpm_per_min": cooldownRecoveryBpmPerMinuteSnapshot(),
                            "session_peak_bpm": hrSessionPeakBPM,
                            "main_avg_bpm": mainPhaseAverageBPMSnapshot(),
                            "main_peak_bpm": hrMainPeakBPM,
                            "zone4plus_seconds": zone4PlusSecondsSnapshot()
                        ])
                    }
                    hrStatusLine = "Заминка завершена"
                    let elapsed = hrControlStartedAt.map { Int(Date().timeIntervalSince($0)) }
                    recordHrWorkoutIfNeeded(durationOverride: elapsed, failed: false)
                    isHrControlRunning = false
                    hrControlStartedAt = nil
                    stopTrainingStructuredLog(reason: "cooldown_\(finishReason)")
                    sendWatchCommand("stop_hr")
                    stopBeltWithToggle(reason: "hr_cooldown_done")
                }
            }
        }
        updateTreadmillStatus()
    }

    private func updateTreadmillStatus() {
        let now = Date()
        if let notifyAt = lastNotifyAt {
            lastNotifyAgeSeconds = max(0, Int(now.timeIntervalSince(notifyAt)))
        } else {
            lastNotifyAgeSeconds = 0
        }
        let running = (deviceTargetSpeedKmh > 0.1) || (speedKmh > 0.2)
        let proto = treadmillProtocol.rawValue
        let awakeText: String = {
            guard isConnected else { return "unknown" }
            guard let notifyAt = lastNotifyAt else { return "unknown" }
            return (now.timeIntervalSince(notifyAt) <= 6) ? "awake" : "asleep"
        }()
        if !isConnected {
            treadmillStatusText = "disconnected"
        } else if running {
            treadmillStatusText = "running • \(awakeText) • \(proto)"
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
        guard isConnected else { appendLog("WRITE SKIPPED (not connected): \(label)"); return }
        guard let p = connectedPeripheral, let ch = commandCharacteristic else {
            appendLog("WRITE SKIPPED (no characteristic): \(label)")
            return
        }
        let type: CBCharacteristicWriteType = ch.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        lastCommandSentAt = Date()
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
        hrTrendSamples.append((date, smoothed))
        let cutoff = date.addingTimeInterval(-hrTrendWindowSeconds)
        while hrTrendSamples.count > 2, let first = hrTrendSamples.first, first.0 < cutoff {
            hrTrendSamples.removeFirst()
        }
    }

    private func currentHrTrendBpmPerSecond() -> Double? {
        guard hrTrendSamples.count >= hrTrendMinSamples,
              let first = hrTrendSamples.first,
              let last = hrTrendSamples.last else { return nil }
        let span = last.0.timeIntervalSince(first.0)
        guard span >= hrTrendMinWindowSeconds else { return nil }
        let t0 = first.0
        var sumT = 0.0
        var sumY = 0.0
        var sumTT = 0.0
        var sumTY = 0.0
        for (date, value) in hrTrendSamples {
            let t = date.timeIntervalSince(t0)
            sumT += t
            sumY += value
            sumTT += t * t
            sumTY += t * value
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
        let entry = WorkoutEntry(
            id: UUID(),
            date: Date(),
            beatsPerMeter: beatsPerMeter,
            targetBpm: hrTargetBPM,
            durationSeconds: actualDuration,
            avgBpm: hrAverageBPM,
            avgSpeedKmh: averageSpeed,
            healthkitWorkoutUUID: pendingHealthkitWorkoutUUID,
            zoneSeconds: hrZoneSeconds
        )
        workoutHistory.insert(entry, at: 0)
        pendingHealthkitWorkoutUUID = nil
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
    }

    private func attachHealthkitWorkoutUUID(_ uuid: String, endedAt: Date?) {
        let matchWindow: TimeInterval = 15 * 60
        if let endDate = endedAt,
           let idx = workoutHistory.firstIndex(where: { $0.healthkitWorkoutUUID == nil && abs($0.date.timeIntervalSince(endDate)) <= matchWindow }) {
            let entry = workoutHistory[idx]
            workoutHistory[idx] = WorkoutEntry(
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
            saveWorkoutHistory()
            return
        }
        if let idx = workoutHistory.firstIndex(where: { $0.healthkitWorkoutUUID == nil }) {
            let entry = workoutHistory[idx]
            workoutHistory[idx] = WorkoutEntry(
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
            saveWorkoutHistory()
        } else {
            pendingHealthkitWorkoutUUID = uuid
        }
    }

    // KS-F0 protocol: F7 A2 <cmd> <val> <crc> FD, crc = sum(bytes[1..3]) % 256
    private func buildCmdPacket(cmd: UInt8, value: UInt8) -> Data {
        var bytes: [UInt8] = [0xF7, 0xA2, cmd, value, 0xFF, 0xFD]
        let crc = (UInt16(0xA2) + UInt16(cmd) + UInt16(value)) & 0xFF
        bytes[4] = UInt8(crc)
        return Data(bytes)
    }

    private struct Fe01Status {
        let beltState: Int
        let speedKmh: Double
        let manualMode: Int
        let timeSeconds: Int
        let distance10m: Int
        let steps: Int
        let appSpeedKmh: Double
        let lastButton: Int
        let checksumOk: Bool
    }

    private func parseFe01Status(_ data: Data) -> Fe01Status? {
        guard data.count >= 19, data.first == 0xF8, data[1] == 0xA2 else { return nil }
        guard data.count >= 20 else { return nil }
        let beltState = Int(data[2])
        let speedKmh = Double(Int(data[3])) / 10.0
        let manualMode = Int(data[4])
        let timeSeconds = decode3ByteBE(data, start: 5)
        let distance10m = decode3ByteBE(data, start: 8)
        let steps = decode3ByteBE(data, start: 11)
        let appSpeedKmh = Double(Int(data[14])) / 10.0
        let lastButton = Int(data[16])
        let checksumOk = verifyChecksum(data)
        return Fe01Status(
            beltState: beltState,
            speedKmh: speedKmh,
            manualMode: manualMode,
            timeSeconds: timeSeconds,
            distance10m: distance10m,
            steps: steps,
            appSpeedKmh: appSpeedKmh,
            lastButton: lastButton,
            checksumOk: checksumOk
        )
    }

    private func decode3ByteBE(_ data: Data, start: Int) -> Int {
        guard data.count >= start + 3 else { return 0 }
        let b0 = Int(data[start])
        let b1 = Int(data[start + 1])
        let b2 = Int(data[start + 2])
        return (b0 << 16) + (b1 << 8) + b2
    }

    private func verifyChecksum(_ data: Data) -> Bool {
        guard data.count >= 3 else { return false }
        let checksumIndex = data.count - 2
        let expected = data[checksumIndex]
        var sum: UInt16 = 0
        for b in data[1..<checksumIndex] {
            sum += UInt16(b)
        }
        return UInt8(sum & 0xFF) == expected
    }

    private func validateExpectedSpeed(with status: Fe01Status) {
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
                subscribe(peripheral, to: n, label: "FE01")
            } else {
                appendLog("WalkingPad: FE01 notify not found on FE00")
            }
            if let w = write {
                commandCharacteristic = w
                appendLog("WalkingPad: command characteristic set to \(w.uuid.uuidString)")
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
        let now = Date()
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
            if let status = parseFe01Status(data) {
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
        if let hr = payload["hr"] as? Double {
            let bpm = Int(hr.rounded())
            DispatchQueue.main.async {
                self.heartRateBPM = bpm
                self.lastKnownHeartRateBPM = bpm
                self.hrLastValueAt = Date()
                self.recordHrSample(bpm)
                // hrStreamingActive will be derived by the staleness timer
                self.appendLog("HR value: \(bpm)")
                self.logTrainingEvent("hr_sample", fields: [
                    "hr_bpm": bpm,
                    "source": "watch_payload"
                ])
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
                switch status.lowercased() {
                case "hr_started":
                    self.hrPermissionGranted = true
                    self.appendLog("HR stream started; permission granted")
                    self.logTrainingEvent("watch_status", fields: ["status": "hr_started"])
                case "hr_stopped":
                    // Keep permission as last-known; clear last timestamp to mark no data
                    self.hrLastValueAt = nil
                    self.heartRateBPM = 0
                    self.appendLog("HR stream stopped")
                    self.logTrainingEvent("watch_status", fields: ["status": "hr_stopped"])
                case "watch_ok":
                    self.watchReachable = true
                    self.appendLog("Watch OK")
                    self.logTrainingEvent("watch_status", fields: ["status": "watch_ok"])
                default:
                    break
                }
                self.recomputeHrStartAllowed()
            }
        }
    }
}
#endif
