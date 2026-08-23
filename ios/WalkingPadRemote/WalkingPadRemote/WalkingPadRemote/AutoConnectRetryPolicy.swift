import Foundation

struct AutoConnectRetryPolicy {
    private(set) var failedPeripheralIDs: Set<UUID> = []
    private var retryNotBefore: [UUID: Date] = [:]
    private let cooldownSeconds: TimeInterval

    init(cooldownSeconds: TimeInterval = 3.0) {
        self.cooldownSeconds = max(0, cooldownSeconds)
    }

    mutating func reset() {
        failedPeripheralIDs.removeAll()
        retryNotBefore.removeAll()
    }

    mutating func markFailed(_ peripheralID: UUID, now: Date = Date()) {
        failedPeripheralIDs.insert(peripheralID)
        retryNotBefore[peripheralID] = now.addingTimeInterval(cooldownSeconds)
    }

    mutating func rearmAfterFreshDiscovery(
        peripheralID: UUID,
        knownPeripheralIDs: Set<UUID>,
        now: Date = Date()
    ) -> Bool {
        guard knownPeripheralIDs.contains(peripheralID),
              !knownPeripheralIDs.isEmpty,
              knownPeripheralIDs.isSubset(of: failedPeripheralIDs),
              let threshold = retryNotBefore[peripheralID],
              now >= threshold else {
            return false
        }

        failedPeripheralIDs.remove(peripheralID)
        retryNotBefore.removeValue(forKey: peripheralID)
        return true
    }

    mutating func forget(_ peripheralID: UUID) {
        failedPeripheralIDs.remove(peripheralID)
        retryNotBefore.removeValue(forKey: peripheralID)
    }
}
