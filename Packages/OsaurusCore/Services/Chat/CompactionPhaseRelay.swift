import Foundation

/// UI observation follows real lifecycle transitions. Late cleanup callbacks
/// cannot put an already failed/cancelled compaction back into a running state.
@MainActor
final class CompactionPhaseRelay {
    private let publish: @MainActor (ContextCompactionPhase) -> Void
    private var active = true
    private var latest = -1

    init(publish: @escaping @MainActor (ContextCompactionPhase) -> Void) {
        self.publish = publish
    }

    func receive(_ phase: CompactionDeadline.Phase) {
        guard active, phase.rawValue > latest else { return }
        latest = phase.rawValue
        switch phase {
        case .waiting: publish(.waitingForLocalWork)
        case .preparing: publish(.preparingModel)
        case .generating: publish(.summarizing)
        case .restoring: publish(.restoringModel)
        }
    }

    func invalidate() { active = false }
}
