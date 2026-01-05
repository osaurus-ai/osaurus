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
    @State private var gradientRotation: Double = 0
    @State private var showCompletionGlow: Bool = false
    @State private var wasInProgress: Bool = false

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
                    isStreaming: isStreaming && isLatest,
                    thinkingLength: turn.thinkingLength
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
        } else if turn.contentIsEmpty && turn.role == .assistant && isStreaming && isLatest {
            // Only show typing indicator if there are no tool calls
            // If tool calls exist, the InlineToolCallView shows its own status
            if turn.toolCalls == nil || turn.toolCalls!.isEmpty {
                TypingIndicator()
                    .padding(.vertical, 4)
            }
        } else if !turn.contentIsEmpty {
            MarkdownMessageView(text: turn.content, baseWidth: contentWidth, turnId: turn.id)
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

    /// Check if any tool call in this turn is still in progress
    private func hasInProgressCall(calls: [ToolCall]) -> Bool {
        calls.contains { turn.toolResults[$0.id] == nil }
    }

    /// Check if any tool call was rejected
    private func hasRejectedCall(calls: [ToolCall]) -> Bool {
        calls.contains { turn.toolResults[$0.id]?.hasPrefix("[REJECTED]") == true }
    }

    /// Border color based on state
    private func completionBorderColor(calls: [ToolCall]) -> Color {
        if hasInProgressCall(calls: calls) {
            return theme.accentColor
        } else if hasRejectedCall(calls: calls) {
            return theme.errorColor
        } else {
            return theme.successColor
        }
    }

    private var animatedGradientBorder: AngularGradient {
        AngularGradient(
            gradient: Gradient(colors: [
                theme.accentColor.opacity(0.6),
                theme.accentColor.opacity(0.2),
                theme.accentColor.opacity(0.4),
                theme.accentColor.opacity(0.2),
                theme.accentColor.opacity(0.6),
            ]),
            center: .center,
            angle: .degrees(gradientRotation)
        )
    }

    private func startGradientAnimation() {
        withAnimation(.linear(duration: 3.0).repeatForever(autoreverses: false)) {
            gradientRotation = 360
        }
    }

    @ViewBuilder
    private func toolCallsView(calls: [ToolCall]) -> some View {
        let inProgress = hasInProgressCall(calls: calls)
        let borderColor = completionBorderColor(calls: calls)

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
        // Border: animated gradient when in progress, colored when complete
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    inProgress
                        ? AnyShapeStyle(animatedGradientBorder)
                        : AnyShapeStyle(borderColor.opacity(showCompletionGlow ? 0.6 : 0.25)),
                    lineWidth: inProgress ? 1.5 : (showCompletionGlow ? 1.5 : 1)
                )
                .animation(.easeOut(duration: 0.8), value: showCompletionGlow)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        // Glow effect
        .shadow(
            color: inProgress
                ? theme.accentColor.opacity(0.15)
                : (showCompletionGlow ? borderColor.opacity(0.2) : .clear),
            radius: 8,
            x: 0,
            y: 2
        )
        .animation(.easeOut(duration: 0.8), value: showCompletionGlow)
        .onAppear {
            wasInProgress = inProgress
            if inProgress {
                startGradientAnimation()
            }
        }
        .onChange(of: inProgress) { _, nowInProgress in
            if nowInProgress {
                wasInProgress = true
                startGradientAnimation()
            } else if wasInProgress {
                // Just completed - show completion glow then fade
                showCompletionGlow = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.easeOut(duration: 0.8)) {
                        showCompletionGlow = false
                    }
                }
            }
        }
    }

    // MARK: - Public Actions

    func startEditing() {
        editingContent = turn.content
        isEditing = true
    }
}
