//
//  MessageRow.swift
//  osaurus
//
//  Editorial thread-style message row with accent bar indicator
//

import SwiftUI
import AppKit

struct MessageRow: View {
    @ObservedObject var turn: ChatTurn
    let width: CGFloat
    let isStreaming: Bool
    let isLatest: Bool
    let onCopy: (String) -> Void
    var onEdit: ((UUID, String) -> Void)? = nil
    var onRegenerate: ((UUID) -> Void)? = nil

    @Environment(\.theme) private var theme
    @State private var isHovered: Bool = false
    @State private var isEditing: Bool = false
    @State private var editingContent: String = ""

    private var accentBarColor: Color {
        turn.role == .user ? theme.accentColor : theme.tertiaryText.opacity(0.4)
    }

    private var roleLabel: String {
        turn.role == .user ? "You" : "Assistant"
    }

    /// Calculate the actual content width after accounting for padding and accent bar
    /// - ChatView adds .padding(.horizontal, 16) = 32px
    /// - Accent bar: 3px width + 12px leading padding = 15px
    /// - Content VStack: 16px leading + 12px trailing padding = 28px
    private var contentWidth: CGFloat {
        max(100, width - 32 - 15 - 28)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Accent bar indicator
            accentBar

            // Message content
            VStack(alignment: .leading, spacing: 8) {
                // Header row with role and actions
                headerRow

                // Attached images (if any)
                if turn.hasImages {
                    attachedImagesView
                }

                // Thinking block (if any) - shown above main content for assistant messages
                if turn.role == .assistant && turn.hasThinking {
                    ThinkingBlockView(
                        thinking: turn.thinking,
                        baseWidth: contentWidth,
                        isStreaming: isStreaming && isLatest
                    )
                    .padding(.bottom, 4)
                }

                // Message content or typing indicator
                contentView

                // Tool calls (if any)
                if turn.role == .assistant, let calls = turn.toolCalls, !calls.isEmpty {
                    GroupedToolResponseView(calls: calls, resultsById: turn.toolResults)
                        .padding(.top, 4)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .padding(.vertical, 16)
        }
        .background(messageBackground)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))  // Ensure entire area is hoverable
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering in
            withAnimation(theme.animationQuick()) {
                isHovered = hovering
            }
        }
    }

    // MARK: - Attached Images View

    private var attachedImagesView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(turn.attachedImages.enumerated()), id: \.offset) { _, imageData in
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
                            .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Accent Bar

    private var accentBar: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(accentBarColor)
            .frame(width: 3)
            .padding(.vertical, 12)
            .padding(.leading, 12)
            .opacity(isStreaming && isLatest && turn.role == .assistant ? pulseOpacity : 1.0)
            .animation(
                isStreaming && isLatest && turn.role == .assistant
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .default,
                value: isStreaming
            )
    }

    @State private var pulseOpacity: Double = 1.0

    // MARK: - Header Row

    private var headerRow: some View {
        HStack(spacing: 8) {
            // Role indicator - uses theme font
            Text(roleLabel)
                .font(theme.font(size: CGFloat(theme.captionSize) + 1, weight: .semibold))
                .foregroundColor(turn.role == .user ? theme.accentColor : theme.secondaryText)

            Spacer()

            // Action buttons (visible on hover)
            if !isEditing {
                HStack(spacing: 4) {
                    // Edit button (only for user messages)
                    if turn.role == .user && onEdit != nil {
                        editButton
                    }
                    // Regenerate button (only for assistant messages)
                    if turn.role == .assistant && onRegenerate != nil && !isStreaming {
                        regenerateButton
                    }
                    if !turn.content.isEmpty {
                        copyButton
                    }
                }
            }
        }
        .contentShape(Rectangle())  // Ensure entire header row is hoverable
    }

    private var editButton: some View {
        Button(action: {
            editingContent = turn.content
            isEditing = true
        }) {
            Image(systemName: "pencil")
                .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                .foregroundColor(theme.tertiaryText)
                .padding(6)
                .background(
                    Circle()
                        .fill(theme.secondaryBackground.opacity(isHovered ? 0.8 : 0))
                )
        }
        .buttonStyle(.plain)
        .opacity(isHovered ? 1 : 0)
        .animation(theme.animationQuick(), value: isHovered)
        .allowsHitTesting(isHovered)
        .help("Edit message")
    }

    private var regenerateButton: some View {
        Button(action: {
            onRegenerate?(turn.id)
        }) {
            Image(systemName: "arrow.clockwise")
                .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                .foregroundColor(theme.tertiaryText)
                .padding(6)
                .background(
                    Circle()
                        .fill(theme.secondaryBackground.opacity(isHovered ? 0.8 : 0))
                )
        }
        .buttonStyle(.plain)
        .opacity(isHovered ? 1 : 0)
        .animation(theme.animationQuick(), value: isHovered)
        .allowsHitTesting(isHovered)
        .help("Regenerate response")
    }

    private var copyButton: some View {
        Button(action: { onCopy(turn.content) }) {
            Image(systemName: "doc.on.doc")
                .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                .foregroundColor(theme.tertiaryText)
                .padding(6)
                .background(
                    Circle()
                        .fill(theme.secondaryBackground.opacity(isHovered ? 0.8 : 0))
                )
        }
        .buttonStyle(.plain)
        .opacity(isHovered ? 1 : 0)
        .animation(theme.animationQuick(), value: isHovered)
        .allowsHitTesting(isHovered)  // Only allow clicks when visible
        .help("Copy message")
    }

    // MARK: - Content View

    @ViewBuilder
    private var contentView: some View {
        if isEditing {
            editingView
        } else if turn.content.isEmpty && turn.role == .assistant && isStreaming && isLatest {
            TypingIndicator()
                .padding(.vertical, 4)
        } else {
            MarkdownMessageView(text: turn.content, baseWidth: contentWidth)
                .font(Typography.body(contentWidth, theme: theme))
                .foregroundColor(theme.primaryText)
                .textSelection(.enabled)
        }
    }

    // MARK: - Editing View

    private var editingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: $editingContent)
                .font(Typography.body(contentWidth, theme: theme))
                .foregroundColor(theme.primaryText)
                .scrollContentBackground(.hidden)
                .background(theme.primaryBackground.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.primaryBorder.opacity(0.3), lineWidth: 1)
                )
                .frame(minHeight: 60, maxHeight: 200)

            HStack(spacing: 8) {
                Button("Cancel") {
                    isEditing = false
                    editingContent = ""
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(theme.secondaryBackground.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                Button("Save & Regenerate") {
                    let trimmed = editingContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        onEdit?(turn.id, trimmed)
                    }
                    isEditing = false
                    editingContent = ""
                }
                .buttonStyle(.plain)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(theme.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }

    // MARK: - Background

    private var messageBackground: some View {
        Group {
            if turn.role == .user {
                // Subtle tinted background for user messages
                theme.secondaryBackground.opacity(0.5)
            } else {
                // Transparent for assistant
                Color.clear
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct MessageRow_Previews: PreviewProvider {
        static var previews: some View {
            VStack(spacing: 16) {
                MessageRow(
                    turn: ChatTurn(role: .user, content: "Hello, can you help me with Swift?"),
                    width: 600,
                    isStreaming: false,
                    isLatest: false,
                    onCopy: { _ in }
                )

                MessageRow(
                    turn: ChatTurn(
                        role: .assistant,
                        content: "Of course! I'd be happy to help you with Swift. What would you like to know?"
                    ),
                    width: 600,
                    isStreaming: false,
                    isLatest: false,
                    onCopy: { _ in }
                )

                MessageRow(
                    turn: ChatTurn(role: .assistant, content: ""),
                    width: 600,
                    isStreaming: true,
                    isLatest: true,
                    onCopy: { _ in }
                )
            }
            .padding()
            .frame(width: 700)
            .background(Color(hex: "0f0f10"))
        }
    }
#endif
