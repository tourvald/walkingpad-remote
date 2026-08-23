import Foundation

enum CommandQueueService {
    struct Command: Equatable {
        let data: Data
        let label: String
        let requiresControlReadiness: Bool

        init(data: Data, label: String, requiresControlReadiness: Bool = false) {
            self.data = data
            self.label = label
            self.requiresControlReadiness = requiresControlReadiness
        }
    }

    struct EnqueueResult {
        let coalescedSpeedCount: Int
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
        var coalesced = 0
        if isSpeedLabel(command.label) {
            let before = queue.count
            queue.removeAll(where: { isSpeedLabel($0.label) })
            coalesced = max(0, before - queue.count)
        }

        queue.append(command)
        return EnqueueResult(coalescedSpeedCount: coalesced)
    }
}
