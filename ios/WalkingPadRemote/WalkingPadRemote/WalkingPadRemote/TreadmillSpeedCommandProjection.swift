import Foundation

enum TreadmillSpeedCommandProjection {
    static let mphToKmh = 1.609344
    static let initialConfirmedImperialPhysicalCapKmh = 6.0

    struct Projection: Equatable {
        let requestedPhysicalSpeedKmh: Double
        let cappedPhysicalSpeedKmh: Double
        let nativeUnits: TreadmillNativeUnits
        let commandNativeSpeed: Double
        let commandRawTenths: Int
        let previousRawTenths: Int?
        let commandPhysicalSpeedKmhEstimate: Double
        let requestedPhysicalDeltaKmh: Double?
        let commandPhysicalDeltaKmhEstimate: Double?

        var shouldSendCommand: Bool {
            previousRawTenths != commandRawTenths
        }
    }

    static func project(
        requestedPhysicalSpeedKmh: Double,
        nativeUnits: TreadmillNativeUnits,
        previousRawTenths: Int?,
        confirmedImperialPhysicalCapKmh: Double = initialConfirmedImperialPhysicalCapKmh
    ) -> Projection {
        let sanitizedPhysicalSpeed = max(0.0, requestedPhysicalSpeedKmh.isFinite ? requestedPhysicalSpeedKmh : 0.0)
        let cappedPhysicalSpeed = cappedPhysicalSpeedKmh(
            sanitizedPhysicalSpeed,
            nativeUnits: nativeUnits,
            confirmedImperialPhysicalCapKmh: confirmedImperialPhysicalCapKmh
        )
        let rawTenths = commandRawTenths(forPhysicalKmh: cappedPhysicalSpeed, nativeUnits: nativeUnits)
        let nativeSpeed = Double(rawTenths) / 10.0
        let physicalEstimate = physicalSpeedKmhEstimate(forRawTenths: rawTenths, nativeUnits: nativeUnits)
        let previousPhysicalEstimate = previousRawTenths.map {
            physicalSpeedKmhEstimate(forRawTenths: $0, nativeUnits: nativeUnits)
        }

        return Projection(
            requestedPhysicalSpeedKmh: sanitizedPhysicalSpeed,
            cappedPhysicalSpeedKmh: cappedPhysicalSpeed,
            nativeUnits: nativeUnits,
            commandNativeSpeed: nativeSpeed,
            commandRawTenths: rawTenths,
            previousRawTenths: previousRawTenths,
            commandPhysicalSpeedKmhEstimate: physicalEstimate,
            requestedPhysicalDeltaKmh: previousPhysicalEstimate.map { sanitizedPhysicalSpeed - $0 },
            commandPhysicalDeltaKmhEstimate: previousPhysicalEstimate.map { physicalEstimate - $0 }
        )
    }

    static func nativeMph(forPhysicalKmh physicalKmh: Double) -> Double {
        physicalKmh / mphToKmh
    }

    static func physicalKmhEstimate(forNativeMph nativeMph: Double) -> Double {
        nativeMph * mphToKmh
    }

    private static func cappedPhysicalSpeedKmh(
        _ physicalKmh: Double,
        nativeUnits: TreadmillNativeUnits,
        confirmedImperialPhysicalCapKmh: Double
    ) -> Double {
        guard nativeUnits == .imperial else { return physicalKmh }
        let cap = confirmedImperialPhysicalCapKmh.isFinite ? confirmedImperialPhysicalCapKmh : initialConfirmedImperialPhysicalCapKmh
        return min(physicalKmh, max(0.0, cap))
    }

    private static func commandRawTenths(
        forPhysicalKmh physicalKmh: Double,
        nativeUnits: TreadmillNativeUnits
    ) -> Int {
        let nativeSpeed: Double
        switch nativeUnits {
        case .metric, .unknown:
            nativeSpeed = physicalKmh
        case .imperial:
            nativeSpeed = nativeMph(forPhysicalKmh: physicalKmh)
        }
        return Int(max(0.0, min(120.0, (nativeSpeed * 10.0).rounded())))
    }

    private static func physicalSpeedKmhEstimate(
        forRawTenths rawTenths: Int,
        nativeUnits: TreadmillNativeUnits
    ) -> Double {
        let nativeSpeed = Double(max(0, rawTenths)) / 10.0
        switch nativeUnits {
        case .metric, .unknown:
            return nativeSpeed
        case .imperial:
            return physicalKmhEstimate(forNativeMph: nativeSpeed)
        }
    }
}
