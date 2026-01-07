//
//  ContentBlockView.swift
//  osaurus
//
//  Renders a single content block in the flattened chat view.
//  Optimized for LazyVStack recycling.
//

import AppKit
import SwiftUI

struct ContentBlockView: View {
    let block: ContentBlock
    let width: CGFloat
    let personaName: String
    var onCopy: ((String) -> Void)?
    var onRegenerate: ((UUID) -> Void)?

    @Environment(\.theme) private var theme

    private var contentWidth: CGFloat {
        // Total deductions: outer padding (32) + accent bar (15) + content padding (28)
        max(100, width - 75)
    }

    private var isSpacer: Bool {
        if case .groupSpacer = block { return true }
        return false
    }

    var body: some View {
        if isSpacer {
            Color.clear.frame(height: 16)
        } else {
            HStack(spacing: 0) {
                accentBar
                contentContainer
            }
            .background(blockBackground)
        }
    }

    // MARK: - Components

    private var accentBar: some View {
        let color = block.role == .user ? theme.accentColor : theme.tertiaryText.opacity(0.4)
        return Rectangle()
            .fill(color)
            .frame(width: 3)
            .frame(maxHeight: .infinity)
            .padding(.leading, 12)
    }

    private var contentContainer: some View {
        VStack(alignment: .leading, spacing: 0) {
            blockContent
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 16)
        .padding(.trailing, 12)
    }

    @ViewBuilder
    private var blockBackground: some View {
        if block.role == .user {
            theme.secondaryBackground.opacity(0.5)
        } else {
            Color.clear
        }
    }

    // MARK: - Block Content

    @ViewBuilder
    private var blockContent: some View {
        switch block {
        case let .header(turnId, role, name, _):
            HeaderBlockContent(
                turnId: turnId,
                role: role,
                name: name,
                onCopy: onCopy,
                onRegenerate: onRegenerate
            )
            .padding(.top, 12)
            .padding(.bottom, 4)

        case let .paragraph(_, _, text, isStreaming, _):
            MarkdownMessageView(
                text: text,
                baseWidth: contentWidth,
                turnId: nil,
                isStreaming: isStreaming
            )
            .padding(.vertical, 4)

        case let .toolCall(_, call, result):
            InlineToolCallView(call: call, result: result)
                .padding(.vertical, 6)

        case let .thinking(_, _, text, isStreaming):
            ThinkingBlockView(
                thinking: text,
                baseWidth: contentWidth,
                isStreaming: isStreaming,
                thinkingLength: text.count
            )
            .padding(.vertical, 6)

        case let .image(_, _, imageData):
            if let nsImage = NSImage(data: imageData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 200, maxHeight: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(theme.primaryBorder.opacity(0.2), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                    .padding(.vertical, 6)
            }

        case .typingIndicator:
            TypingIndicator()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)

        case .groupSpacer:
            EmptyView()
        }
    }
}

// MARK: - Header Block Content

private struct HeaderBlockContent: View {
    let turnId: UUID
    let role: MessageRole
    let name: String
    var onCopy: ((String) -> Void)?
    var onRegenerate: ((UUID) -> Void)?

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .font(theme.font(size: CGFloat(theme.captionSize) + 1, weight: .semibold))
                .foregroundColor(role == .user ? theme.accentColor : theme.secondaryText)

            Spacer()

            actionButtons
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 4) {
            if role == .assistant, let onRegenerate {
                ActionButton(icon: "arrow.clockwise", help: "Regenerate") {
                    onRegenerate(turnId)
                }
            }
            if let onCopy {
                ActionButton(icon: "doc.on.doc", help: "Copy") {
                    onCopy("")
                }
            }
        }
        .opacity(isHovered ? 1 : 0)
        .animation(theme.animationQuick(), value: isHovered)
    }

    private struct ActionButton: View {
        let icon: String
        let help: String
        let action: () -> Void

        @Environment(\.theme) private var theme

        var body: some View {
            Button(action: action) {
                Image(systemName: icon)
                    .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .padding(6)
                    .background(Circle().fill(theme.secondaryBackground.opacity(0.8)))
            }
            .buttonStyle(.plain)
            .help(help)
        }
    }
}
