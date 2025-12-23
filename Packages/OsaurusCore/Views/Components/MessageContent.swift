//
//  MessageContent.swift
//  osaurus
//
//  Renders the actual content of a message (text, images, tools)
//

import SwiftUI
import AppKit

struct MessageContent: View {
    @ObservedObject var turn: ChatTurn
    let availableWidth: CGFloat
    let isStreaming: Bool
    let isLatest: Bool
    let onCopy: (String) -> Void
    var onEdit: ((UUID, String) -> Void)? = nil

    @Environment(\.theme) private var theme
    @State private var isEditing: Bool = false
    @State private var editingContent: String = ""

    // Derived from MessageRow logic
    private var contentWidth: CGFloat {
        // MessageGroupView will handle outer padding/accent bar
        // We just need to fit within the available width passed down
        availableWidth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Attached images
            if turn.hasImages {
                attachedImagesView
            }

            // Thinking block
            if turn.role == .assistant && turn.hasThinking {
                ThinkingBlockView(
                    thinking: turn.thinking,
                    baseWidth: contentWidth,
                    isStreaming: isStreaming && isLatest
                )
                .padding(.bottom, 4)
            }

            // Main content
            contentView

            // Tool calls
            if turn.role == .assistant, let calls = turn.toolCalls, !calls.isEmpty {
                toolCallsView(calls: calls)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Attached Images

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

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        if isEditing {
            editingView
        } else if turn.content.isEmpty && turn.role == .assistant && isStreaming && isLatest {
            // Only show typing indicator if there are no tool calls
            // If tool calls exist, the InlineToolCallView shows its own status
            if turn.toolCalls == nil || turn.toolCalls!.isEmpty {
                TypingIndicator()
                    .padding(.vertical, 4)
            }
        } else if !turn.content.isEmpty {
            MarkdownMessageView(text: turn.content, baseWidth: contentWidth)
                .font(Typography.body(contentWidth, theme: theme))
                .foregroundColor(theme.primaryText)
                .textSelection(.enabled)
        }
    }

    // MARK: - Editing

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

    // MARK: - Tools

    @ViewBuilder
    private func toolCallsView(calls: [ToolCall]) -> some View {
        // Grouped container for all tool calls
        VStack(spacing: 0) {
            ForEach(Array(calls.enumerated()), id: \.element.id) { index, call in
                InlineToolCallView(
                    call: call,
                    result: turn.toolResults[call.id]
                )

                // Divider between tool calls (not after last)
                if index < calls.count - 1 {
                    Divider()
                        .background(theme.primaryBorder.opacity(0.15))
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.secondaryBackground.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.primaryBorder.opacity(0.2), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Public Actions

    func startEditing() {
        editingContent = turn.content
        isEditing = true
    }
}
