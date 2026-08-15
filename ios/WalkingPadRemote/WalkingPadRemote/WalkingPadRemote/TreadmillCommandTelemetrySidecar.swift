import Foundation
#if SWIFT_PACKAGE
import TelemetryDomain
#endif

/// Observational metadata that mirrors the legacy queue without participating in
/// command equality, admission, ordering, coalescing, or transport decisions.
struct TreadmillCommandTelemetrySidecar {
    enum DequeueResult: Equatable {
        case matched(TreadmillCommandEnqueuedEvidence)
        case staleEpoch(TreadmillCommandEnqueuedEvidence)
        case correlationLost([TreadmillCommandEnqueuedEvidence])
        case missing
    }

    private(set) var queued: [(label: String, evidence: TreadmillCommandEnqueuedEvidence)] = []

    var count: Int { queued.count }

    mutating func enqueueRegular(
        label: String,
        evidence: TreadmillCommandEnqueuedEvidence,
        isSpeedLabel: (String) -> Bool
    ) -> [TreadmillCommandEnqueuedEvidence] {
        var superseded: [TreadmillCommandEnqueuedEvidence] = []
        if isSpeedLabel(label) {
            superseded = queued.compactMap { entry in
                isSpeedLabel(entry.label) ? entry.evidence : nil
            }
            queued.removeAll { isSpeedLabel($0.label) }
        }
        queued.append((label, evidence))
        return superseded
    }

    mutating func replaceWithHighPriority(
        label: String,
        evidence: TreadmillCommandEnqueuedEvidence
    ) -> [TreadmillCommandEnqueuedEvidence] {
        let superseded = queued.map(\.evidence)
        queued = [(label, evidence)]
        return superseded
    }

    mutating func clear() -> [TreadmillCommandEnqueuedEvidence] {
        let cancelled = queued.map(\.evidence)
        queued.removeAll()
        return cancelled
    }

    mutating func dequeue(
        expectedLabel: String,
        currentEpoch: TreadmillConnectionEpoch?
    ) -> DequeueResult {
        guard let first = queued.first else { return .missing }
        guard first.label == expectedLabel else {
            let lost = clear()
            return .correlationLost(lost)
        }
        queued.removeFirst()
        guard first.evidence.connectionEpoch == currentEpoch else {
            return .staleEpoch(first.evidence)
        }
        return .matched(first.evidence)
    }
}

/// Mirrors the existing global legacy ACK acceptance predicate without adding
/// command/attempt correlation or participating in transport behavior.
struct LegacyAcknowledgementObservationSeam {
    let isAcceptedByLegacyRuntime: Bool
    let observation: LegacyAcknowledgementObservation?

    static func evaluate(
        isAwaitingAcknowledgement: Bool,
        sentAt: Date?,
        receivedAt: Date,
        timeout: TimeInterval,
        isQualifyingSignal: Bool,
        protocolKind: TreadmillProtocolKind,
        connectionEpoch: TreadmillConnectionEpoch?,
        recordedAt: Date
    ) -> Self {
        let isAcceptedByLegacyRuntime = isAwaitingAcknowledgement
            && sentAt.map { receivedAt.timeIntervalSince($0) <= timeout } == true
            && isQualifyingSignal
        let observation = connectionEpoch.flatMap {
            isAcceptedByLegacyRuntime
                ? LegacyAcknowledgementObservation.unresolved(
                    protocolKind: protocolKind,
                    connectionEpoch: $0,
                    receivedAt: receivedAt,
                    recordedAt: recordedAt
                )
                : nil
        }
        return Self(
            isAcceptedByLegacyRuntime: isAcceptedByLegacyRuntime,
            observation: observation
        )
    }
}
