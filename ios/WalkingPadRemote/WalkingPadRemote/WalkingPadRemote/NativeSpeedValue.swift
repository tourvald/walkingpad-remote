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

enum TreadmillSpeedDisplaySemantics: String, Equatable {
    case physicalKmh = "physical_kmh"
    case nativeMph = "native_mph"
}

struct TreadmillSpeedDisplayValue: Equatable {
    let value: Double
    let unitLabel: String
    let semantics: TreadmillSpeedDisplaySemantics
    let physicalKmhEstimate: Double?
    let physicalEstimateLabel: String?
}

enum TreadmillSpeedDisplay {
    static func current(
        reportedRawTenths: Int,
        fallbackMetricKmh: Double,
        nativeUnits: TreadmillNativeUnits
    ) -> TreadmillSpeedDisplayValue {
        if nativeUnits == .imperial {
            let native = NativeSpeedValue(rawTenths: max(0, reportedRawTenths), units: .imperial)
            return imperialDisplayValue(nativeSpeedMph: native.nativeSpeed)
        }

        return TreadmillSpeedDisplayValue(
            value: sanitized(fallbackMetricKmh),
            unitLabel: "km/h",
            semantics: .physicalKmh,
            physicalKmhEstimate: nil,
            physicalEstimateLabel: nil
        )
    }

    static func average(
        legacyAverageSpeed: Double,
        nativeUnits: TreadmillNativeUnits
    ) -> TreadmillSpeedDisplayValue {
        if nativeUnits == .imperial {
            return imperialDisplayValue(nativeSpeedMph: sanitized(legacyAverageSpeed))
        }

        return TreadmillSpeedDisplayValue(
            value: sanitized(legacyAverageSpeed),
            unitLabel: "km/h",
            semantics: .physicalKmh,
            physicalKmhEstimate: nil,
            physicalEstimateLabel: nil
        )
    }

    private static func imperialDisplayValue(nativeSpeedMph: Double) -> TreadmillSpeedDisplayValue {
        let speed = sanitized(nativeSpeedMph)
        return TreadmillSpeedDisplayValue(
            value: speed,
            unitLabel: "mph",
            semantics: .nativeMph,
            physicalKmhEstimate: TreadmillSpeedCommandProjection.physicalKmhEstimate(forNativeMph: speed),
            physicalEstimateLabel: "physical km/h estimate"
        )
    }

    private static func sanitized(_ value: Double) -> Double {
        max(0.0, value.isFinite ? value : 0.0)
    }
}
