import Foundation

public struct ElapsedDuration: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: Int64

    public init(rawValue microseconds: Int64) {
        self.rawValue = microseconds
    }

    public init(microseconds: Int64) {
        self.init(rawValue: microseconds)
    }

    public init?(milliseconds: Int64) {
        let conversion = milliseconds.multipliedReportingOverflow(by: 1_000)
        guard !conversion.overflow else {
            return nil
        }

        self.init(rawValue: conversion.partialValue)
    }

    public static let zero = ElapsedDuration(microseconds: 0)

    public var microseconds: Int64 {
        rawValue
    }

    public var seconds: Double {
        Double(rawValue) / 1_000_000
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct RecordTimestamp: Codable, Hashable, Sendable {
    public let recordedAt: Date
    public let elapsed: ElapsedDuration

    public init(recordedAt: Date, elapsed: ElapsedDuration) {
        self.recordedAt = recordedAt
        self.elapsed = elapsed
    }
}

public struct ObservationTimestamp: Codable, Hashable, Sendable {
    public let measuredAt: Date?
    public let receivedAt: Date
    public let recordedAt: Date
    public let measuredElapsed: ElapsedDuration?
    public let receivedElapsed: ElapsedDuration
    public let recordedElapsed: ElapsedDuration

    public init(
        measuredAt: Date?,
        receivedAt: Date,
        recordedAt: Date,
        measuredElapsed: ElapsedDuration?,
        receivedElapsed: ElapsedDuration,
        recordedElapsed: ElapsedDuration
    ) {
        self.measuredAt = measuredAt
        self.receivedAt = receivedAt
        self.recordedAt = recordedAt
        self.measuredElapsed = measuredElapsed
        self.receivedElapsed = receivedElapsed
        self.recordedElapsed = recordedElapsed
    }

    public var effectiveElapsed: ElapsedDuration {
        measuredElapsed ?? receivedElapsed
    }
}

public struct EventTimestamp: Codable, Hashable, Sendable {
    public let occurredAt: Date
    public let recordedAt: Date
    public let occurredElapsed: ElapsedDuration
    public let recordedElapsed: ElapsedDuration

    public init(
        occurredAt: Date,
        recordedAt: Date,
        occurredElapsed: ElapsedDuration,
        recordedElapsed: ElapsedDuration
    ) {
        self.occurredAt = occurredAt
        self.recordedAt = recordedAt
        self.occurredElapsed = occurredElapsed
        self.recordedElapsed = recordedElapsed
    }
}
