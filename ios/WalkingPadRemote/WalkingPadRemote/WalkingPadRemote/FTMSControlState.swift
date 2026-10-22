import Foundation

/// One Control Point procedure per connection. ATT write success is not a grant.
struct FTMSControlState {
    private struct Pending {
        let opcode: UInt8
        let connection: TreadmillControlConnectionIdentity
        let sentAt: ContinuousClock.Instant
    }

    private var pending: Pending?
    private(set) var hasControl = false
    private(set) var isBlocked = false

    var needsRequestControl: Bool { !isBlocked && !hasControl && pending == nil }

    func canSend(opcode: UInt8) -> Bool {
        !isBlocked && pending == nil && (opcode == 0x00 || hasControl)
    }

    mutating func sent(opcode: UInt8, connection: TreadmillControlConnectionIdentity,
                       at now: ContinuousClock.Instant) {
        pending = Pending(opcode: opcode, connection: connection, sentAt: now)
    }

    /// Returns nil for an unsolicited or obsolete indication.
    mutating func receive(opcode: UInt8, resultCode: UInt8,
                          connection: TreadmillControlConnectionIdentity,
                          at now: ContinuousClock.Instant = .now) -> Bool? {
        guard !isBlocked, let pending, pending.opcode == opcode,
              pending.connection == connection else { return nil }
        guard !hasTimedOut(at: now) else {
            invalidate()
            return false
        }
        self.pending = nil
        guard resultCode == 0x01 else {
            // A completed procedure rejection does not revoke an existing grant.
            if opcode == 0x00 || !hasControl || !(0x02...0x04).contains(resultCode) {
                invalidate()
            }
            return false
        }
        if opcode == 0x00 { hasControl = true }
        return true
    }

    func hasTimedOut(at now: ContinuousClock.Instant) -> Bool {
        guard let pending else { return false }
        return pending.sentAt.duration(to: now) >= .seconds(30)
    }

    /// Reconnection is required after lost control or ambiguous completion.
    mutating func invalidate() {
        pending = nil
        hasControl = false
        isBlocked = true
    }
}
