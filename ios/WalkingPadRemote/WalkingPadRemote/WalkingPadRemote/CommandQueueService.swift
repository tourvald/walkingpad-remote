import Foundation

enum CommandQueueService {
    struct Command: Equatable {
        let data: Data
        let label: String
        let requiresControlReadiness: Bool
        let heartRateSpeed: HRDomainService.SpeedCommand?

        init(data: Data, label: String, requiresControlReadiness: Bool = false,
             heartRateSpeed: HRDomainService.SpeedCommand? = nil) {
            self.data = data
            self.label = label
            self.requiresControlReadiness = requiresControlReadiness
            self.heartRateSpeed = heartRateSpeed
        }
    }

    struct EnqueueResult {
        let coalescedSpeedCommands: [Command]
        var coalescedSpeedCount: Int { coalescedSpeedCommands.count }
    }

    static func isReadOnlyQueryLabel(_ label: String) -> Bool {
        label == "QUERY STATUS" || label == "QUERY PARAMS"
    }

    static func discardReadOnlyQueries(
        queue: inout [Command],
        motionWindowIsProtected: Bool
    ) -> [Command] {
        guard motionWindowIsProtected || queue.contains(where: { !isReadOnlyQueryLabel($0.label) }) else {
            return []
        }
        let discarded = queue.filter { isReadOnlyQueryLabel($0.label) }
        queue.removeAll { isReadOnlyQueryLabel($0.label) }
        return discarded
    }

    static func clear(queue: inout [Command]) -> Int {
        let dropped = queue.count
        queue.removeAll()
        return dropped
    }

    static func replaceWithHighPriority(queue: inout [Command], command: Command) {
        queue.removeAll()
        queue.append(command)
    }

    static func enqueueRegular(
        queue: inout [Command],
        command: Command,
        isSpeedLabel: (String) -> Bool
    ) -> EnqueueResult {
        var coalesced: [Command] = []
        if isSpeedLabel(command.label) {
            coalesced = queue.filter { isSpeedLabel($0.label) }
            queue.removeAll(where: { isSpeedLabel($0.label) })
        }

        queue.append(command)
        return EnqueueResult(coalescedSpeedCommands: coalesced)
    }
}
