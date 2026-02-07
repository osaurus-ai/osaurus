//
//  MessageThreadView.swift
//  osaurus
//
//  Renders the message thread with optimized block recycling.
//

import SwiftUI

struct MessageThreadView: View {
    let blocks: [ContentBlock]
    let width: CGFloat
    let personaName: String
    let isStreaming: Bool
    let scrollTrigger: Int
    let lastAssistantTurnId: UUID?
    var autoScrollEnabled: Bool = true

    let onCopy: (UUID) -> Void
    let onRegenerate: (UUID) -> Void
    let onScrolledToBottom: () -> Void
    let onScrolledAwayFromBottom: () -> Void
    var onClarificationSubmit: ((String) -> Void)? = nil

    @Environment(\.theme) private var theme

    private var contentWidth: CGFloat { max(100, width - 64) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(blocks) { block in
                        ContentBlockView(
                            block: block,
                            width: contentWidth,
                            personaName: personaName,
                            onCopy: onCopy,
                            onRegenerate: onRegenerate,
                            onClarificationSubmit: onClarificationSubmit
                        )
                        .equatable()
                        .id(block.id)
                        .padding(.horizontal, 12)
                    }
                }
                .padding(.top, 8)

                Color.clear.frame(height: 24)

                Color.clear
                    .frame(height: 1)
                    .id("BOTTOM")
                    .onAppear { onScrolledToBottom() }
                    .onDisappear { if !isStreaming { onScrolledAwayFromBottom() } }
            }
            .scrollContentBackground(.hidden)
            .scrollIndicators(.visible)
            .onChange(of: scrollTrigger) { _, _ in
                if autoScrollEnabled {
                    scrollToResponseStart(proxy: proxy)
                }
            }
        }
    }

    private func scrollToResponseStart(proxy: ScrollViewProxy) {
        guard let turnId = lastAssistantTurnId else { return }
        DispatchQueue.main.async {
            withAnimation(theme.animationQuick()) {
                proxy.scrollTo("header-\(turnId.uuidString)", anchor: .top)
            }
        }
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
