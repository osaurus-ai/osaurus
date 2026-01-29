//
//  MessageThreadView.swift
//  osaurus
//
//  Isolated message thread view to prevent cascading re-renders.
//  Observes only the session data it needs, not all ChatView state.
//

import SwiftUI

// MARK: - Message Thread View

/// An isolated view for rendering the message thread.
/// This prevents ChatView state changes (like isPinnedToBottom) from causing
/// all ContentBlockViews to re-render.
struct MessageThreadView: View {
    let blocks: [ContentBlock]
    let width: CGFloat
    let personaName: String
    let isStreaming: Bool
    let turnsCount: Int
    let lastAssistantTurnId: UUID?

    // Callbacks - excluded from Equatable comparison in child views
    let onCopy: (UUID) -> Void
    let onRegenerate: (UUID) -> Void
    let onScrolledToBottom: () -> Void
    let onScrolledAwayFromBottom: () -> Void
    var onClarificationSubmit: ((String) -> Void)? = nil

    @Environment(\.theme) private var theme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                EquatableView(
                    content: MessageBlocksList(
                        blocks: blocks,
                        width: width,
                        personaName: personaName,
                        onCopy: onCopy,
                        onRegenerate: onRegenerate,
                        onClarificationSubmit: onClarificationSubmit
                    )
                )

                Color.clear.frame(height: 16)

                Color.clear
                    .frame(height: 1)
                    .id("BOTTOM")
                    .onAppear { onScrolledToBottom() }
                    .onDisappear { if !isStreaming { onScrolledAwayFromBottom() } }
            }
            .scrollContentBackground(.hidden)
            .scrollIndicators(.visible)
            .onChange(of: turnsCount) { _, _ in
                scrollToResponseStart(proxy: proxy)
            }
        }
    }

    /// Scroll to the start of the assistant's response header
    private func scrollToResponseStart(proxy: ScrollViewProxy) {
        guard let turnId = lastAssistantTurnId else { return }
        let headerId = "header-\(turnId.uuidString)"

        DispatchQueue.main.async {
            withAnimation(theme.animationQuick()) {
                proxy.scrollTo(headerId, anchor: .top)
            }
        }
    }
}

// MARK: - Message Blocks List

/// Isolated list view that only re-renders when blocks change.
/// Uses Equatable conformance to prevent unnecessary updates.
private struct MessageBlocksList: View, Equatable {
    let blocks: [ContentBlock]
    let width: CGFloat
    let personaName: String
    let onCopy: (UUID) -> Void
    let onRegenerate: (UUID) -> Void
    var onClarificationSubmit: ((String) -> Void)?

    nonisolated static func == (lhs: MessageBlocksList, rhs: MessageBlocksList) -> Bool {
        lhs.blocks == rhs.blocks && lhs.width == rhs.width && lhs.personaName == rhs.personaName
    }

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(blocks) { block in
                EquatableView(
                    content: ContentBlockRow(
                        block: block,
                        width: width,
                        personaName: personaName,
                        onCopy: onCopy,
                        onRegenerate: onRegenerate,
                        onClarificationSubmit: onClarificationSubmit
                    )
                )
                .id(block.id)
            }
        }
        .padding(.top, 8)
    }
}

// MARK: - Content Block Row

/// Individual block row with Equatable conformance to prevent re-renders
/// when the block hasn't changed.
private struct ContentBlockRow: View, Equatable {
    let block: ContentBlock
    let width: CGFloat
    let personaName: String
    let onCopy: (UUID) -> Void
    let onRegenerate: (UUID) -> Void
    var onClarificationSubmit: ((String) -> Void)?

    nonisolated static func == (lhs: ContentBlockRow, rhs: ContentBlockRow) -> Bool {
        lhs.block == rhs.block && lhs.width == rhs.width && lhs.personaName == rhs.personaName
    }

    var body: some View {
        ContentBlockView(
            block: block,
            width: width,
            personaName: personaName,
            onCopy: onCopy,
            onRegenerate: onRegenerate,
            onClarificationSubmit: onClarificationSubmit
        )
        .padding(.horizontal, 8)
    }
}

// MARK: - Scroll to Bottom Button

/// Isolated scroll button that doesn't trigger re-renders of content blocks
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
