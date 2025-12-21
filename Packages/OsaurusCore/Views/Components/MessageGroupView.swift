//
//  MessageGroupView.swift
//  osaurus
//
//  Displays a group of consecutive messages from the same role with a shared accent bar
//

import SwiftUI
import AppKit

struct MessageGroup: Identifiable, Equatable {
    let id: UUID
    let role: MessageRole
    var turns: [ChatTurn]

    static func == (lhs: MessageGroup, rhs: MessageGroup) -> Bool {
        return lhs.id == rhs.id && lhs.role == rhs.role && lhs.turns.map(\.id) == rhs.turns.map(\.id)
    }
}

struct MessageGroupView: View {
    let group: MessageGroup
    let width: CGFloat
    let isStreaming: Bool  // Global streaming state

    // Actions
    let onCopy: (String) -> Void
    var onEdit: ((UUID, String) -> Void)? = nil
    var onRegenerate: ((UUID) -> Void)? = nil

    @Environment(\.theme) private var theme
    @State private var isHovered: Bool = false
    @State private var pulseOpacity: Double = 1.0

    // MARK: - Computed Properties

    private var accentBarColor: Color {
        group.role == .user ? theme.accentColor : theme.tertiaryText.opacity(0.4)
    }

    private var roleLabel: String {
        group.role == .user ? "You" : "Assistant"
    }

    /// Calculate the actual content width
    /// - ChatView adds .padding(.horizontal, 16) = 32px
    /// - Accent bar: 3px width + 12px leading padding = 15px
    /// - Content VStack: 16px leading + 12px trailing padding = 28px
    private var contentWidth: CGFloat {
        max(100, width - 32 - 15 - 28)
    }

    private var isStreamingGroup: Bool {
        // If global streaming is on, and this is an assistant group, check if the last turn is streaming
        isStreaming && group.role == .assistant
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Continuous accent bar
            accentBar

            // Message content stack
            VStack(alignment: .leading, spacing: 0) {
                // Header row (only once per group)
                headerRow
                    .padding(.bottom, 8)

                // Message turns
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(group.turns.enumerated()), id: \.element.id) { index, turn in
                        let isLatestInGroup = index == group.turns.count - 1

                        MessageContent(
                            turn: turn,
                            availableWidth: contentWidth,
                            isStreaming: isStreaming,
                            isLatest: isLatestInGroup && isStreamingGroup,
                            onCopy: onCopy,
                            onEdit: onEdit
                        )
                        .padding(.top, spacingForTurn(at: index))
                        // Allow edit via direct tap on user messages?
                        // MessageContent handles its own editing state
                    }
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .padding(.vertical, 16)
        }
        .background(groupBackground)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering in
            withAnimation(theme.animationQuick()) {
                isHovered = hovering
            }
        }
    }

    // MARK: - Helpers

    private func spacingForTurn(at index: Int) -> CGFloat {
        if index == 0 { return 0 }

        let currentTurn = group.turns[index]
        let previousTurn = group.turns[index - 1]

        // If both are tool-only turns (empty content, has tool calls), reduce spacing
        let currentIsToolOnly = currentTurn.content.isEmpty && (currentTurn.toolCalls?.isEmpty == false)
        let previousIsToolOnly = previousTurn.content.isEmpty && (previousTurn.toolCalls?.isEmpty == false)

        if currentIsToolOnly && previousIsToolOnly {
            return 4  // Reduced spacing (visually closer)
        }

        return 16  // Standard spacing
    }

    // MARK: - Accent Bar

    private var accentBar: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(accentBarColor)
            .frame(width: 3)
            .padding(.vertical, 12)
            .padding(.leading, 12)
            // Pulse if this group is currently streaming
            .opacity(isStreamingGroup ? pulseOpacity : 1.0)
            .animation(
                isStreamingGroup
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .default,
                value: isStreamingGroup
            )
            .onAppear {
                if isStreamingGroup {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        pulseOpacity = 0.4
                    }
                }
            }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 8) {
            // Role indicator
            Text(roleLabel)
                .font(theme.font(size: CGFloat(theme.captionSize) + 1, weight: .semibold))
                .foregroundColor(group.role == .user ? theme.accentColor : theme.secondaryText)
                .frame(height: 28)

            Spacer()

            // Group Actions (apply to specific turns if needed, or last turn)
            HStack(spacing: 4) {
                // For user messages, we usually want to edit the specific turn,
                // but since they are grouped, maybe we just show edit button on the individual message?
                // Or for now, keep it simple: simple actions on the header usually apply to the whole "turn"
                // but here a "group" might be multiple turns (e.g. tool calls).

                // Actually, actions like "Regenerate" usually apply to the last assistant response.
                // "Edit" applies to the user message.

                // If it's a user group, show edit button for the *last* message in group?
                // Or let MessageContent handle its own hover actions?
                // The design in MessageRow had actions in the header.

                // Let's implement actions here that target the relevant turn(s).

                if group.role == .assistant && !isStreaming && onRegenerate != nil {
                    // Regenerate the entire group (start from first turn)
                    if let firstTurn = group.turns.first {
                        Button(action: { onRegenerate?(firstTurn.id) }) {
                            Image(systemName: "arrow.clockwise")
                                .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                                .foregroundColor(theme.tertiaryText)
                                .padding(6)
                                .background(
                                    Circle()
                                        .fill(theme.secondaryBackground.opacity(0.8))
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Regenerate response")
                    }
                }

                // Copy button - maybe copy all content in group?
                // For now, let's just copy the full text of the group joined by newlines
                Button(action: {
                    let text = group.turns.map { $0.content }.joined(separator: "\n\n")
                    onCopy(text)
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                        .padding(6)
                        .background(
                            Circle()
                                .fill(theme.secondaryBackground.opacity(0.8))
                        )
                }
                .buttonStyle(.plain)
                .help("Copy all")
            }
            .opacity(isHovered ? 1 : 0)
            .animation(theme.animationQuick(), value: isHovered)
            .allowsHitTesting(isHovered)
        }
        .frame(height: 28)
    }

    // MARK: - Background

    private var groupBackground: some View {
        Group {
            if group.role == .user {
                theme.secondaryBackground.opacity(0.5)
            } else {
                Color.clear
            }
        }
    }
}
