import Foundation

enum TreadmillTestRunPlanService {
    enum Phase: String {
        case warmup
        case rampUp = "ramp_up"
        case rampDown = "ramp_down"
        case settle
        case finished
    }

    struct Configuration: Equatable {
        let profileID: String
        let durationSeconds: Int
        let warmupSeconds: Int
        let rampUpSeconds: Int
        let rampDownSeconds: Int
        let settleSeconds: Int
        let baseSpeedKmh: Double
        let peakSpeedKmh: Double
        let commandIntervalSeconds: Int
        let nativeUnits: TreadmillNativeUnits
        let requiresNoLoadConfirmation: Bool
    }

    struct Snapshot: Equatable {
        let elapsedSeconds: Int
        let remainingSeconds: Int
        let progress: Double
        let phase: Phase
        let targetSpeedKmh: Double
        let targetSpeedRawTenths: Int
        let targetNativeSpeed: NativeSpeedValue
        let shouldSendSpeedCommand: Bool
    }

    static let defaultConfiguration = Configuration(
        profileID: "metric_ramp_3m",
        durationSeconds: 180,
        warmupSeconds: 15,
        rampUpSeconds: 75,
        rampDownSeconds: 75,
        settleSeconds: 15,
        baseSpeedKmh: 3.0,
        peakSpeedKmh: 8.0,
        commandIntervalSeconds: 10,
        nativeUnits: .metric,
        requiresNoLoadConfirmation: false
    )

    static let imperialNoLoadDiagnosticConfiguration = Configuration(
        profileID: "imperial_units_discriminator_60s",
        durationSeconds: 60,
        warmupSeconds: 60,
        rampUpSeconds: 0,
        rampDownSeconds: 0,
        settleSeconds: 0,
        baseSpeedKmh: 3.0,
        peakSpeedKmh: 3.0,
        commandIntervalSeconds: 10,
        nativeUnits: .imperial,
        requiresNoLoadConfirmation: true
    )

    static func snapshot(
        elapsedSeconds rawElapsedSeconds: Int,
        bounds: TreadmillSpeedBoundsService.Bounds,
        configuration: Configuration = defaultConfiguration
    ) -> Snapshot {
        let elapsedSeconds = min(max(0, rawElapsedSeconds), configuration.durationSeconds)
        let remainingSeconds = max(0, configuration.durationSeconds - elapsedSeconds)
        let progress = configuration.durationSeconds > 0
            ? min(1.0, max(0.0, Double(elapsedSeconds) / Double(configuration.durationSeconds)))
            : 1.0
        let phase = phase(elapsedSeconds: elapsedSeconds, configuration: configuration)
        let targetSpeedKmh = targetSpeedKmh(
            elapsedSeconds: elapsedSeconds,
            phase: phase,
            bounds: bounds,
            configuration: configuration
        )
        let targetSpeedRawTenths = Int((targetSpeedKmh * 10.0).rounded())
        let targetNativeSpeed = NativeSpeedValue(
            rawTenths: targetSpeedRawTenths,
            units: configuration.nativeUnits
        )
        let shouldSendSpeedCommand = elapsedSeconds == 0
            || elapsedSeconds >= configuration.durationSeconds
            || elapsedSeconds % max(1, configuration.commandIntervalSeconds) == 0

        return Snapshot(
            elapsedSeconds: elapsedSeconds,
            remainingSeconds: remainingSeconds,
            progress: progress,
            phase: phase,
            targetSpeedKmh: targetSpeedKmh,
            targetSpeedRawTenths: targetSpeedRawTenths,
            targetNativeSpeed: targetNativeSpeed,
            shouldSendSpeedCommand: shouldSendSpeedCommand
        )
    }

    private static func phase(
        elapsedSeconds: Int,
        configuration: Configuration
    ) -> Phase {
        if elapsedSeconds >= configuration.durationSeconds {
            return .finished
        }

        let rampUpStart = configuration.warmupSeconds
        let rampDownStart = rampUpStart + configuration.rampUpSeconds
        let settleStart = rampDownStart + configuration.rampDownSeconds

        if elapsedSeconds < rampUpStart {
            return .warmup
        }
        if elapsedSeconds < rampDownStart {
            return .rampUp
        }
        if elapsedSeconds < settleStart {
            return .rampDown
        }
        return .settle
    }

    private static func targetSpeedKmh(
        elapsedSeconds: Int,
        phase: Phase,
        bounds: TreadmillSpeedBoundsService.Bounds,
        configuration: Configuration
    ) -> Double {
        let baseSpeed = TreadmillSpeedBoundsService.clampRunningSpeed(
            configuration.baseSpeedKmh,
            bounds: bounds
        )
        let peakSpeed = TreadmillSpeedBoundsService.clampRunningSpeed(
            max(configuration.peakSpeedKmh, baseSpeed),
            bounds: bounds
        )

        let rawSpeed: Double
        switch phase {
        case .warmup, .settle:
            rawSpeed = baseSpeed
        case .rampUp:
            let progress = segmentProgress(
                elapsedSeconds: elapsedSeconds - configuration.warmupSeconds,
                durationSeconds: configuration.rampUpSeconds
            )
            rawSpeed = interpolate(from: baseSpeed, to: peakSpeed, progress: progress)
        case .rampDown:
            let rampDownStart = configuration.warmupSeconds + configuration.rampUpSeconds
            let progress = segmentProgress(
                elapsedSeconds: elapsedSeconds - rampDownStart,
                durationSeconds: configuration.rampDownSeconds
            )
            rawSpeed = interpolate(from: peakSpeed, to: baseSpeed, progress: progress)
        case .finished:
            return 0.0
        }

        return quantizedSpeed(rawSpeed, bounds: bounds)
    }

    private static func segmentProgress(elapsedSeconds: Int, durationSeconds: Int) -> Double {
        guard durationSeconds > 0 else { return 1.0 }
        return min(1.0, max(0.0, Double(elapsedSeconds) / Double(durationSeconds)))
    }

    private static func interpolate(from start: Double, to end: Double, progress: Double) -> Double {
        start + ((end - start) * progress)
    }

    private static func quantizedSpeed(
        _ speedKmh: Double,
        bounds: TreadmillSpeedBoundsService.Bounds
    ) -> Double {
        let increment = max(0.01, bounds.increment)
        let quantized = (speedKmh / increment).rounded() * increment
        let clamped = TreadmillSpeedBoundsService.clampRunningSpeed(quantized, bounds: bounds)
        return (clamped * 100).rounded() / 100
    }
}
