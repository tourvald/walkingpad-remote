import Foundation

struct NativeSpeedValue: Equatable {
    let rawTenths: Int
    let units: TreadmillNativeUnits

    var nativeSpeed: Double {
        Double(rawTenths) / 10.0
    }

    var displayUnitLabel: String {
        switch units {
        case .metric:
            return "km/h"
        case .imperial:
            return "mph"
        case .unknown:
            return "native"
        }
    }

    var displayText: String {
        switch units {
        case .metric, .imperial:
            return String(format: "%.1f %@", nativeSpeed, displayUnitLabel)
        case .unknown:
            return String(format: "native %.1f", nativeSpeed)
        }
    }

    var diagnosticText: String {
        switch units {
        case .metric:
            return String(format: "native %.1f / controller metric", nativeSpeed)
        case .imperial:
            return String(format: "native %.1f / controller imperial", nativeSpeed)
        case .unknown:
            return String(format: "native %.1f / controller unknown", nativeSpeed)
        }
    }
}
