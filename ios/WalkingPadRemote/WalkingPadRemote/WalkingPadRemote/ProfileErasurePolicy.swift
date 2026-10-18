import Foundation

/// Deletion cannot acquire storage ownership while a runtime session owns it.
enum ProfileErasurePolicy {
    struct Selection: Equatable {
        let retainedIDs: [UUID]
        let activeID: UUID
        let replacementID: UUID?
    }

    static func selection(afterDeleting confirmedID: UUID, from ids: [UUID], activeID: UUID?, makeID: () -> UUID = UUID.init) -> Selection? {
        guard ids.contains(confirmedID) else { return nil }
        let retained = ids.filter { $0 != confirmedID }
        if retained.isEmpty {
            let replacement = makeID()
            return Selection(retainedIDs: [replacement], activeID: replacement, replacementID: replacement)
        }
        let selected = activeID.flatMap { retained.contains($0) ? $0 : nil } ?? retained[0]
        return Selection(retainedIDs: retained, activeID: selected, replacementID: nil)
    }

    static func permitsDeletion(
        workoutActive: Bool, recoveryOutstanding: Bool, preflightActive: Bool,
        cleanupInFlight: Bool, testRunActive: Bool, stopPending: Bool,
        erasureInFlight: Bool, linkageInFlight: Bool
    ) -> Bool {
        !workoutActive && !recoveryOutstanding && !preflightActive
            && !cleanupInFlight && !testRunActive && !stopPending
            && !erasureInFlight && !linkageInFlight
    }
}
