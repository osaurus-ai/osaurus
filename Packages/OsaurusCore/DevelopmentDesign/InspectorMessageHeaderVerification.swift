#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI
import AppKit

/// Existing native views with local callbacks; no regeneration/deletion/speech.
struct InspectorMessageHeaderVerification: View {
    @Environment(\.theme) private var theme
    @Environment(\.inspectorVerificationWidth) private var width
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            CatalogControlExample("Agent identity · above a reply") {
                NativeHeaderCheckPart(kind: 0, disabled: false, selected: false, callback: {})
                    .frame(width: width, height: NativeCellHeightEstimator.headerInnerHeight(for: theme))
            }
            CatalogControlExample("Message actions · shared Extra small icon buttons") {
                NativeHeaderCheckPart(kind: 2, disabled: false, selected: false, callback: {})
                    .frame(width: width, height: MessageHeaderInspectionStyle.side(theme))
            }
            CatalogControlExample("Reasoning warning · when thinking did not finish") {
                NativeHeaderCheckPart(kind: 3, disabled: false, selected: false, callback: {})
                    .frame(width: width, height: MessageHeaderInspectionStyle.captionHeight(theme))
            }
            Text("Action appearance is edited in Buttons; avatar appearance is edited in Avatars. Run statistics appear in the action More menu; this page owns the name, warning and their layout.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
private struct NativeHeaderCheckPart: NSViewRepresentable {
    @Environment(\.theme) private var theme
    let kind: Int
    let disabled: Bool
    let selected: Bool
    let callback: () -> Void
    private static let turn = UUID(uuidString: "ABC00000-0000-4000-8000-000000000030")!
    func makeNSView(context: Context) -> NSView {
        switch kind {
        case 0,1: NativeHeaderView()
        case 2: NativeAssistantActionsView()
        default: NativeStatsView()
        }
    }
    func updateNSView(_ view: NSView, context: Context) {
        defer { view.updateCatalogInspection(context.environment.nativeCatalogInspection, selection: context.environment.nativeCatalogSelection) }
        if let header = view as? NativeHeaderView {
            header.configure(turnId: Self.turn, role: kind == 0 ? .assistant : .user, name: kind == 0 ? "Research assistant" : "", avatar: nil, customAvatarPath: nil, isEditing: false, isHovered: true, timestamp: Date(timeIntervalSince1970: 0), theme: theme, onCopy: { _ in callback() }, onRegenerate: { _ in callback() }, onEdit: { _ in callback() }, onDelete: { _ in callback() }, onCancelEdit: nil)
        } else if let actions = view as? NativeAssistantActionsView {
            actions.configure(turnId: Self.turn, timestamp: Date(timeIntervalSince1970: 0), theme: theme, hideSecondaryActions: false, onCopy: { _ in callback() }, onRegenerate: { _ in callback() }, onSpeak: { _ in callback() }, onDeleteMessage: { _ in callback() }, responseStatsForTurn: { _ in "Worked for 12s • 420 tokens" })
            actions.speakButton.setInspectionSelected(selected)
        } else if let stats = view as? NativeStatsView {
            stats.configure(ttft: nil, tokensPerSecond: nil, tokenCount: nil, unclosedReasoning: true, theme: theme)
        }
        func enable(_ view: NSView) {
            if let action = view as? HeaderCircleActionControl { action.setInspectionEnabled(!disabled) }
            for child in view.subviews { enable(child) }
        }
        enable(view)
    }
}
#endif
