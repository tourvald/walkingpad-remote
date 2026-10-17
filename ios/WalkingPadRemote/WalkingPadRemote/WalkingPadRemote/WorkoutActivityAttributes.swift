import ActivityKit
import Foundation

struct WorkoutActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable {
            case main, cooldown, finishing
        }
        let phase: Phase
        let deadline: Date?
    }

    let sessionID: UUID
}
