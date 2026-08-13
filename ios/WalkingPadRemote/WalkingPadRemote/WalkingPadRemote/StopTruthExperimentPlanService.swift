import Foundation

enum StopTruthExperimentPlanService {
    static let caseID = "issue11_core_stop_truth"
    static let plannedRepetitions = 3
    static let allowedReconnectCount = 0
    static let observationWindowSeconds: TimeInterval = 30
    static let postWindowFreshnessDelaySeconds: TimeInterval = 2.1
    static let recoveryToggleDelaySeconds: TimeInterval = 2.0
    static let conditionalRetryDelaySeconds: TimeInterval = 4.0
    static let maximumObservationAgeSeconds: TimeInterval = 2.0
    static let classification = "CORE PHYSICAL QUALIFICATION"
    static let edgeSubclaim = "EDGE SUBCLAIM: UNKNOWN / NOT OBSERVED"

    struct Context: Equatable, Codable {
        let peripheralID: UUID
        let connectionEpoch: UUID
        let notificationStreamID: UUID
    }

    struct A6BoundsEvidence: Equatable {
        let context: Context
        let observedAt: StopTruthExperimentTimestamp
        let checksumValid: Bool
        let startSpeedRawTenths: UInt8
        let maxSpeedRawTenths: UInt8
    }

    struct FE01Observation: Equatable {
        let context: Context
        let receivedAt: StopTruthExperimentTimestamp
        let rawHex: String
        let checksumValid: Bool
        let speedRawTenths: Int?
        let state: Int?
    }

    enum BaselineKind: Equatable {
        case stationary
        case movingRaw5(movingMarkerRecorded: Bool)
    }

    static func raw5IsAllowed(
        by evidence: A6BoundsEvidence?,
        currentContext: Context,
        clock: StopTruthExperimentClock,
        nowUptimeNanoseconds: UInt64,
        maximumAgeSeconds: TimeInterval
    ) -> Bool {
        guard let evidence,
              evidence.context == currentContext,
              evidence.checksumValid,
              let age = clock.ageSeconds(
                since: evidence.observedAt,
                nowUptimeNanoseconds: nowUptimeNanoseconds
              ),
              (0...maximumAgeSeconds).contains(age) else {
            return false
        }
        return evidence.startSpeedRawTenths <= 5 && 5 <= evidence.maxSpeedRawTenths
    }

    static func baselineSatisfied(
        observations: [FE01Observation],
        kind: BaselineKind,
        currentContext: Context,
        clock: StopTruthExperimentClock,
        nowUptimeNanoseconds: UInt64
    ) -> Bool {
        guard observations.count >= 2 else { return false }
        let pair = observations.suffix(2)
        guard pair.allSatisfy({ observation in
            guard observation.context == currentContext,
                  observation.checksumValid,
                  let age = clock.ageSeconds(
                    since: observation.receivedAt,
                    nowUptimeNanoseconds: nowUptimeNanoseconds
                  ),
                  (0...maximumObservationAgeSeconds).contains(age),
                  let speed = observation.speedRawTenths,
                  let state = observation.state else {
                return false
            }
            switch kind {
            case .stationary:
                return speed == 0 && StopObservationPolicy.acceptedNonRunningStates.contains(state)
            case .movingRaw5(let markerRecorded):
                return markerRecorded && speed == 5 && !StopObservationPolicy.acceptedNonRunningStates.contains(state)
            }
        }) else {
            return false
        }
        return true
    }

    static func fixedRoles(firstRepetition: Bool, retryRequired: Bool) -> [BLETransportCodec.StopTruthExperimentCommandRole] {
        var roles: [BLETransportCodec.StopTruthExperimentCommandRole] = []
        if firstRepetition { roles += [.queryParams, .modeManual] }
        roles += [.baselineStart, .speedRaw5, .initialStop, .productionStopRecovery]
        if retryRequired { roles.append(.conditionalStopRetry) }
        return roles
    }

    static func productionRetryRequired(speedKmh: Double, deviceReportedSpeedKmh: Double) -> Bool {
        max(speedKmh, deviceReportedSpeedKmh) > 0.2
    }
}
