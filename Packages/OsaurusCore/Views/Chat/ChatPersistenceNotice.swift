import SwiftUI

struct ChatPersistenceNotice: View {
    @ObservedObject private var status = ChatPersistenceStatus.shared
    let sessionId: UUID?

    var body: some View {
        if let sessionId, status.unsaved.contains(sessionId) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                Text("History isn't saved yet. Retrying automatically; keep Osaurus open.", bundle: .module)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: { ChatSessionStore.retryUnsaved() }) { Text("Retry", bundle: .module) }
            }
            .padding(10)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
        }
    }
}
