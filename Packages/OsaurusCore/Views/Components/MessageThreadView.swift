//
//  MessageThreadView.swift
//  osaurus
//
//  Renders the message thread using an NSTableView-backed
//  NSViewRepresentable for true cell reuse, explicit height
//  management, and stable scroll anchoring during streaming.
//

import SwiftUI

struct MessageThreadView: View {
    let blocks: [ContentBlock]
    /// Optional precomputed group header map; falls back to local computation when nil.
    var groupHeaderMap: [UUID: UUID]? = nil
    let width: CGFloat
    let personaName: String
    let isStreaming: Bool
    let lastAssistantTurnId: UUID?
    var autoScrollEnabled: Bool = true
    var expandedBlocksStore: ExpandedBlocksStore = ExpandedBlocksStore()

    // Scroll
    var scrollToBottomTrigger: Int = 0
    let onScrolledToBottom: () -> Void
    let onScrolledAwayFromBottom: () -> Void

    // Message action callbacks
    let onCopy: (UUID) -> Void
    var onRegenerate: ((UUID) -> Void)? = nil
    var onEdit: ((UUID) -> Void)? = nil
    var onClarificationSubmit: ((String) -> Void)? = nil

    // Inline editing state (optional; unused in AgentView)
    var editingTurnId: UUID? = nil
    var editText: Binding<String>? = nil
    var onConfirmEdit: (() -> Void)? = nil
    var onCancelEdit: (() -> Void)? = nil

    @Environment(\.theme) private var theme

    private var resolvedGroupHeaderMap: [UUID: UUID] {
        if let precomputed = groupHeaderMap { return precomputed }

        var map: [UUID: UUID] = [:]
        var currentGroupHeaderId: UUID? = nil

        for block in blocks {
            if case .groupSpacer = block.kind {
                currentGroupHeaderId = nil
                continue
            }

            if case .header = block.kind {
                currentGroupHeaderId = block.turnId
            }

            if let groupId = currentGroupHeaderId {
                map[block.turnId] = groupId
            } else {
                map[block.turnId] = block.turnId
            }
        }
        return map
    }

    var body: some View {
        MessageTableRepresentable(
            blocks: blocks,
            groupHeaderMap: resolvedGroupHeaderMap,
            width: width,
            personaName: personaName,
            isStreaming: isStreaming,
            lastAssistantTurnId: lastAssistantTurnId,
            autoScrollEnabled: autoScrollEnabled,
            theme: theme,
            expandedBlocksStore: expandedBlocksStore,
            scrollToBottomTrigger: scrollToBottomTrigger,
            onScrolledToBottom: onScrolledToBottom,
            onScrolledAwayFromBottom: onScrolledAwayFromBottom,
            onCopy: onCopy,
            onRegenerate: onRegenerate,
            onEdit: onEdit,
            onClarificationSubmit: onClarificationSubmit,
            editingTurnId: editingTurnId,
            editText: editText,
            onConfirmEdit: onConfirmEdit,
            onCancelEdit: onCancelEdit
        )
    }
}

struct ScrollToBottomButton: View {
    let isPinnedToBottom: Bool
    let hasTurns: Bool
    let onTap: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        if !isPinnedToBottom && hasTurns {
            Button(action: onTap) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(theme.secondaryBackground)
                            .shadow(color: theme.shadowColor.opacity(0.2), radius: 8, x: 0, y: 2)
                    )
            }
            .buttonStyle(.plain)
            .padding(20)
            .transition(.scale.combined(with: .opacity))
        }
    }
}
