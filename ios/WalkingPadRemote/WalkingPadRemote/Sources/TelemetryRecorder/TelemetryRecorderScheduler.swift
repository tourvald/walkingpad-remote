import Foundation

public final class ContinuousTelemetryRecorderScheduler: TelemetryRecorderScheduler,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant
    private var generation: UInt64 = 0
    private var scheduledTask: Task<Void, Never>?

    public init() {
        origin = clock.now
    }

    deinit {
        cancelScheduledOperation()
    }

    public func now() -> Duration {
        origin.duration(to: clock.now)
    }

    public func schedule(
        after delay: Duration,
        operation: @escaping @Sendable () -> Void
    ) {
        let boundedDelay = max(delay, .zero)
        let previous: Task<Void, Never>?
        let currentGeneration: UInt64
        lock.lock()
        generation &+= 1
        currentGeneration = generation
        previous = scheduledTask
        scheduledTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await clock.sleep(until: clock.now.advanced(by: boundedDelay))
            } catch {
                return
            }
            guard takeScheduledOperation(generation: currentGeneration) else {
                return
            }
            operation()
        }
        lock.unlock()
        previous?.cancel()
    }

    public func cancelScheduledOperation() {
        let previous: Task<Void, Never>? = lock.withLock {
            generation &+= 1
            defer { scheduledTask = nil }
            return scheduledTask
        }
        previous?.cancel()
    }

    private func takeScheduledOperation(generation expected: UInt64) -> Bool {
        lock.withLock {
            guard generation == expected else {
                return false
            }
            scheduledTask = nil
            return true
        }
    }
}

extension NSLock {
    @inlinable
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
