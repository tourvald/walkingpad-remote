import Foundation
import TelemetryDomain

/// Observational metadata that mirrors the legacy queue without participating in
/// command equality, admission, ordering, coalescing, or transport decisions.
struct TreadmillCommandTelemetrySidecar {
    struct Entry: Equatable {
        let evidence: TreadmillCommandEnqueuedEvidence
        let sessionID: SessionID?
    }

    enum DequeueResult: Equatable {
        case matched(Entry)
        case staleEpoch(Entry)
        case correlationLost([Entry])
        case missing
    }

    private(set) var queued: [(label: String, entry: Entry)] = []

    var count: Int { queued.count }

    mutating func enqueueRegular(
        label: String,
        evidence: TreadmillCommandEnqueuedEvidence,
        sessionID: SessionID? = nil,
        isSpeedLabel: (String) -> Bool
    ) -> [Entry] {
        var superseded: [Entry] = []
        if isSpeedLabel(label) {
            superseded = queued.compactMap { entry in
                isSpeedLabel(entry.label) ? entry.entry : nil
            }
            queued.removeAll { isSpeedLabel($0.label) }
        }
        queued.append((label, Entry(evidence: evidence, sessionID: sessionID)))
        return superseded
    }

    mutating func replaceWithHighPriority(
        label: String,
        evidence: TreadmillCommandEnqueuedEvidence,
        sessionID: SessionID? = nil
    ) -> [Entry] {
        let superseded = queued.map(\.entry)
        queued = [(label, Entry(evidence: evidence, sessionID: sessionID))]
        return superseded
    }

    mutating func clear() -> [Entry] {
        let cancelled = queued.map(\.entry)
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
        guard first.entry.evidence.connectionEpoch == currentEpoch else {
            return .staleEpoch(first.entry)
        }
        return .matched(first.entry)
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
