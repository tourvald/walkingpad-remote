import Foundation
import HealthKit

@available(iOS 27.0, *)
enum AppleHeartRateZoneProvider {
    enum ReadError: LocalizedError {
        case unavailable
        case missing
        case incompatible

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Apple Health недоступен на этом устройстве."
            case .missing: return "Не удалось прочитать зоны. Проверьте разрешения в приложении «Здоровье» и настройки зон на часах."
            case .incompatible: return "Эти границы Apple Health пока не поддерживаются. Можно задать зоны вручную."
            }
        }
    }

    static func read(from store: HKHealthStore, requestAuthorization: Bool) async throws -> HeartRateZoneSettings.AppleSnapshot {
        guard HKHealthStore.isHealthDataAvailable() else { throw ReadError.unavailable }
        let type = HKQuantityType(.heartRate)
        if requestAuthorization {
            try await store.requestAuthorization(toShare: [], read: [HKObjectType.workoutType(), type])
        }
        guard let configuration = try await store.preferredWorkoutZoneConfiguration(for: type) else {
            throw ReadError.missing
        }
        let zones = configuration.zones.sorted { $0.index < $1.index }
        let unit = HKUnit.count().unitDivided(by: .minute())
        guard configuration.quantityType == type,
              configuration.configurationType == .automatic || configuration.configurationType == .manual,
              zones.count == 5,
              zones.map(\.index) == Array(0..<5),
              zones.first?.minimum == nil, zones.last?.maximum == nil else { throw ReadError.incompatible }
        var thresholds: [Double] = []
        for index in 0..<4 {
            guard let maximum = zones[index].maximum?.doubleValue(for: unit),
                  let minimum = zones[index + 1].minimum?.doubleValue(for: unit),
                  maximum.isFinite, minimum.isFinite, abs(maximum - minimum) < 0.000001 else {
                throw ReadError.incompatible
            }
            thresholds.append(maximum)
        }
        let origin: String
        switch configuration.source {
        case .system: origin = "system"
        case .user: origin = "user"
        case .app: throw ReadError.incompatible
        @unknown default: throw ReadError.incompatible
        }
        let snapshot = HeartRateZoneSettings.AppleSnapshot(
            thresholds: thresholds, origin: origin,
            configuration: configuration.configurationType.rawValue, fetchedAt: Date()
        )
        guard snapshot.upperBounds != nil else { throw ReadError.incompatible }
        return snapshot
    }
}
