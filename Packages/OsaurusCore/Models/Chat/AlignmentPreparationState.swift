import Combine
import Foundation
import MLXLMCommon

/// Active load identities prevent delayed callbacks from reviving a finished banner.
@MainActor
final class AlignmentPreparationState: ObservableObject {
    static let shared = AlignmentPreparationState()
    struct Entry {
        let modelID: String
        let sessionID: String?
        var progress: AlignmentRepairProgress?
    }
    @Published private(set) var entries: [UUID: Entry] = [:]

    func begin(id: UUID, modelID: String, sessionID: String?) {
        entries[id] = Entry(modelID: modelID, sessionID: sessionID)
    }

    func update(id: UUID, progress: AlignmentRepairProgress) {
        guard var entry = entries[id] else { return }
        switch progress.stage {
        case .copying, .verifying: entry.progress = progress
        case .installed, .fallback: entry.progress = nil
        }
        entries[id] = entry
    }

    func finish(id: UUID) { entries.removeValue(forKey: id) }

    func progress(modelID: String?, sessionID: UUID?) -> AlignmentRepairProgress? {
        guard let modelID, let sessionID else { return nil }
        return entries.values.first {
            $0.modelID == modelID && $0.sessionID == sessionID.uuidString
        }?.progress
    }
}
