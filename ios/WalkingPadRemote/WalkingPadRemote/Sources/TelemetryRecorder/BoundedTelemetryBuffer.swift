import Foundation

struct BufferedTelemetryRecord: Sendable {
    let sequenced: SequencedTelemetryRecord
    let enqueuedAt: Duration
}

struct TelemetryDiscardCounts: Equatable, Sendable {
    var critical = 0
    var native = 0
    var bulkFrame = 0

    var total: Int {
        critical + native + bulkFrame
    }
}

struct BufferEnqueueResult: Sendable {
    let disposition: TelemetryYieldDisposition
    let evictedBulkFrame: Bool
}

struct BoundedTelemetryBuffer: Sendable {
    private struct Slot: Sendable {
        var value: BufferedTelemetryRecord?
        var previous: Int?
        var next: Int?
        var previousBulk: Int?
        var nextBulk: Int?
        var nextFree: Int?
    }

    let policy: TelemetryBufferPolicy

    private var slots: [Slot]
    private var freeHead: Int?
    private var head: Int?
    private var tail: Int?
    private var bulkHead: Int?
    private var bulkTail: Int?
    private var frameSlots: [CanonicalFrameIdentity: Int] = [:]
    private(set) var count = 0
    private(set) var criticalCount = 0
    private(set) var nativeCount = 0
    private(set) var bulkFrameCount = 0

    init(policy: TelemetryBufferPolicy) {
        self.policy = policy
        slots = (0..<policy.capacity).map { index in
            Slot(
                value: nil,
                previous: nil,
                next: nil,
                previousBulk: nil,
                nextBulk: nil,
                nextFree: index + 1 < policy.capacity ? index + 1 : nil
            )
        }
        freeHead = slots.isEmpty ? nil : 0
        frameSlots.reserveCapacity(policy.bulkFrameCapacity)
    }

    var isEmpty: Bool {
        count == 0
    }

    var oldestEnqueueTime: Duration? {
        guard let head else {
            return nil
        }
        return slots[head].value?.enqueuedAt
    }

    mutating func enqueue(
        _ record: SequencedTelemetryRecord,
        at enqueueTime: Duration
    ) -> BufferEnqueueResult {
        switch record.record.recordClass {
        case .bulkFrame:
            return enqueueFrame(record, at: enqueueTime)
        case .native:
            return enqueueNative(record, at: enqueueTime)
        case .critical:
            return enqueueCritical(record, at: enqueueTime)
        }
    }

    mutating func drain(maximumCount: Int) -> [SequencedTelemetryRecord] {
        guard maximumCount > 0 else {
            return []
        }
        var drained: [SequencedTelemetryRecord] = []
        drained.reserveCapacity(Swift.min(maximumCount, count))
        while drained.count < maximumCount, let head {
            guard let value = remove(at: head) else {
                preconditionFailure("A linked telemetry slot must contain a value.")
            }
            drained.append(value.sequenced)
        }
        return drained
    }

    mutating func discardAll() -> TelemetryDiscardCounts {
        var discarded = TelemetryDiscardCounts()
        while let head, let removed = remove(at: head) {
            switch removed.sequenced.record.recordClass {
            case .critical:
                discarded.critical += 1
            case .native:
                discarded.native += 1
            case .bulkFrame:
                discarded.bulkFrame += 1
            }
        }
        return discarded
    }

    private mutating func enqueueFrame(
        _ record: SequencedTelemetryRecord,
        at enqueueTime: Duration
    ) -> BufferEnqueueResult {
        guard case let .frame(frame) = record.record else {
            preconditionFailure("Bulk telemetry must be a canonical frame.")
        }
        let identity = CanonicalFrameIdentity(frame)
        if let existing = frameSlots[identity] {
            _ = remove(at: existing)
            append(record, at: enqueueTime, frameIdentity: identity)
            return BufferEnqueueResult(
                disposition: .coalescedFrame,
                evictedBulkFrame: false
            )
        }

        guard bulkFrameCount < policy.bulkFrameCapacity,
              nativeCount + bulkFrameCount < policy.nonCriticalCapacity,
              count < policy.capacity
        else {
            return BufferEnqueueResult(disposition: .droppedFrame, evictedBulkFrame: false)
        }

        append(record, at: enqueueTime, frameIdentity: identity)
        return BufferEnqueueResult(disposition: .enqueued, evictedBulkFrame: false)
    }

    private mutating func enqueueNative(
        _ record: SequencedTelemetryRecord,
        at enqueueTime: Duration
    ) -> BufferEnqueueResult {
        let nonCriticalCount = nativeCount + bulkFrameCount
        var evictedBulkFrame = false
        if nonCriticalCount >= policy.nonCriticalCapacity || count >= policy.capacity {
            guard evictOldestBulkFrame() else {
                return BufferEnqueueResult(disposition: .lostNative, evictedBulkFrame: false)
            }
            evictedBulkFrame = true
        }
        append(record, at: enqueueTime, frameIdentity: nil)
        return BufferEnqueueResult(
            disposition: .enqueued,
            evictedBulkFrame: evictedBulkFrame
        )
    }

    private mutating func enqueueCritical(
        _ record: SequencedTelemetryRecord,
        at enqueueTime: Duration
    ) -> BufferEnqueueResult {
        var evictedBulkFrame = false
        if count >= policy.capacity {
            guard evictOldestBulkFrame() else {
                return BufferEnqueueResult(disposition: .lostCritical, evictedBulkFrame: false)
            }
            evictedBulkFrame = true
        }
        append(record, at: enqueueTime, frameIdentity: nil)
        return BufferEnqueueResult(
            disposition: .enqueued,
            evictedBulkFrame: evictedBulkFrame
        )
    }

    private mutating func append(
        _ record: SequencedTelemetryRecord,
        at enqueueTime: Duration,
        frameIdentity: CanonicalFrameIdentity?
    ) {
        guard let index = allocateSlot() else {
            preconditionFailure("Telemetry admission must reserve a free slot.")
        }
        slots[index].value = BufferedTelemetryRecord(
            sequenced: record,
            enqueuedAt: enqueueTime
        )
        slots[index].previous = tail
        slots[index].next = nil
        if let tail {
            slots[tail].next = index
        } else {
            head = index
        }
        tail = index

        switch record.record.recordClass {
        case .critical:
            criticalCount += 1
        case .native:
            nativeCount += 1
        case .bulkFrame:
            bulkFrameCount += 1
            slots[index].previousBulk = bulkTail
            slots[index].nextBulk = nil
            if let bulkTail {
                slots[bulkTail].nextBulk = index
            } else {
                bulkHead = index
            }
            bulkTail = index
            if let frameIdentity {
                frameSlots[frameIdentity] = index
            }
        }
        count += 1
    }

    private mutating func evictOldestBulkFrame() -> Bool {
        guard let bulkHead else {
            return false
        }
        _ = remove(at: bulkHead)
        return true
    }

    @discardableResult
    private mutating func remove(at index: Int) -> BufferedTelemetryRecord? {
        guard let removed = slots[index].value else {
            return nil
        }

        let previous = slots[index].previous
        let next = slots[index].next
        if let previous {
            slots[previous].next = next
        } else {
            head = next
        }
        if let next {
            slots[next].previous = previous
        } else {
            tail = previous
        }

        switch removed.sequenced.record.recordClass {
        case .critical:
            criticalCount -= 1
        case .native:
            nativeCount -= 1
        case .bulkFrame:
            bulkFrameCount -= 1
            let previousBulk = slots[index].previousBulk
            let nextBulk = slots[index].nextBulk
            if let previousBulk {
                slots[previousBulk].nextBulk = nextBulk
            } else {
                bulkHead = nextBulk
            }
            if let nextBulk {
                slots[nextBulk].previousBulk = previousBulk
            } else {
                bulkTail = previousBulk
            }
            if case let .frame(frame) = removed.sequenced.record {
                let identity = CanonicalFrameIdentity(frame)
                if frameSlots[identity] == index {
                    frameSlots.removeValue(forKey: identity)
                }
            }
        }
        count -= 1
        releaseSlot(index)
        return removed
    }

    private mutating func allocateSlot() -> Int? {
        guard let index = freeHead else {
            return nil
        }
        freeHead = slots[index].nextFree
        slots[index].nextFree = nil
        return index
    }

    private mutating func releaseSlot(_ index: Int) {
        slots[index].value = nil
        slots[index].previous = nil
        slots[index].next = nil
        slots[index].previousBulk = nil
        slots[index].nextBulk = nil
        slots[index].nextFree = freeHead
        freeHead = index
    }
}
