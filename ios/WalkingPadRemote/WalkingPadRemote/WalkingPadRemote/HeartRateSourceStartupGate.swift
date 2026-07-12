import Foundation

struct HeartRateSourceStartupGate: Equatable {
    enum Phase: Equatable {
        case idle
        case startingSource
        case waitingForFirstSample(startedAt: Date)
        case beltStarted
    }

    private(set) var phase: Phase = .idle

    var isBeforeFirstSample: Bool {
        switch phase {
        case .startingSource, .waitingForFirstSample:
            return true
        case .idle, .beltStarted:
            return false
        }
    }

    mutating func beginSourceStart() {
        phase = .startingSource
    }

    mutating func collectionDidStart(at date: Date) {
        guard phase == .startingSource else { return }
        phase = .waitingForFirstSample(startedAt: date)
    }

    func initialSampleWaitSeconds(at date: Date) -> Int? {
        guard case .waitingForFirstSample(let startedAt) = phase else { return nil }
        return max(0, Int(date.timeIntervalSince(startedAt)))
    }

    mutating func markFirstSampleAccepted() -> Bool {
        guard case .waitingForFirstSample = phase else { return false }
        phase = .beltStarted
        return true
    }

    mutating func reset() {
        phase = .idle
    }
}
