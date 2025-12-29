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
    let personaName: String  // Name to display for assistant messages

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
        group.role == .user ? "You" : personaName
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

    private struct TurnContentGroup: Identifiable {
        let id: String
        let kind: TurnContentKind
        var turns: [ChatTurn]
    }

    /// Groups consecutive tool-only turns together for unified rendering
    private var groupedTurnContent: [TurnContentGroup] {
        var result: [TurnContentGroup] = []

        for turn in group.turns {
            let isToolOnly = turn.content.isEmpty && (turn.toolCalls?.isEmpty == false)
            let kind: TurnContentKind = isToolOnly ? .toolCalls : .content

            // If same kind as previous, append to existing group
            if let last = result.last, last.kind == kind {
                result[result.count - 1].turns.append(turn)
            } else {
                // Use first turn's ID as stable identifier for the group
                let stableId = "\(kind)-\(turn.id.uuidString)"
                result.append(TurnContentGroup(id: stableId, kind: kind, turns: [turn]))
            }
        }

        return result
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

                // Message turns - grouped by content type
                VStack(alignment: .leading, spacing: 0) {
                    let groups = groupedTurnContent
                    ForEach(Array(groups.enumerated()), id: \.element.id) { groupIndex, turnGroup in
                        if turnGroup.kind == .toolCalls {
                            // Render all tool calls from consecutive tool-only turns in one container
                            GroupedToolCallsView(
                                turns: turnGroup.turns,
                                isStreaming: isStreaming
                            )
                            .padding(.top, groupIndex > 0 ? 8 : 0)
                        } else {
                            // Regular content turns
                            ForEach(Array(turnGroup.turns.enumerated()), id: \.element.id) { turnIndex, turn in
                                let isLatestInGroup =
                                    groupIndex == groups.count - 1 && turnIndex == turnGroup.turns.count - 1

                                MessageContent(
                                    turn: turn,
                                    availableWidth: contentWidth,
                                    isStreaming: isStreaming,
                                    isLatest: isLatestInGroup && isStreamingGroup,
                                    onCopy: onCopy,
                                    onEdit: onEdit
                                )
                                .padding(.top, (groupIndex > 0 || turnIndex > 0) ? 16 : 0)
                            }
                        }
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
            // Use explicit animation only for hover state, not for child layouts
            isHovered = hovering
        }
    }

    private enum TurnContentKind {
        case content
        case toolCalls
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

// MARK: - Grouped Tool Calls View

/// Renders tool calls from multiple turns in a single grouped container
struct GroupedToolCallsView: View {
    let turns: [ChatTurn]
    let isStreaming: Bool

    @Environment(\.theme) private var theme
    @State private var gradientRotation: Double = 0
    @State private var showCompletionGlow: Bool = false

    /// Collect all tool calls from all turns with their results
    private var allToolCalls: [(call: ToolCall, result: String?, turnId: UUID)] {
        var result: [(call: ToolCall, result: String?, turnId: UUID)] = []
        for turn in turns {
            if let calls = turn.toolCalls {
                for call in calls {
                    result.append((call: call, result: turn.toolResults[call.id], turnId: turn.id))
                }
            }
        }
        return result
    }

    /// Check if any tool call is still in progress
    private var hasInProgressCall: Bool {
        allToolCalls.contains { $0.result == nil }
    }

    /// Check if any tool call was rejected
    private var hasRejectedCall: Bool {
        allToolCalls.contains { $0.result?.hasPrefix("[REJECTED]") == true }
    }

    /// Border color based on state
    private var completionBorderColor: Color {
        if hasInProgressCall {
            return theme.accentColor
        } else if hasRejectedCall {
            return theme.errorColor
        } else {
            return theme.successColor
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(allToolCalls.enumerated()), id: \.element.call.id) { index, item in
                InlineToolCallView(
                    call: item.call,
                    result: item.result
                )

                // Divider between tool calls (not after last)
                if index < allToolCalls.count - 1 {
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
                    hasInProgressCall
                        ? AnyShapeStyle(animatedGradientBorder)
                        : AnyShapeStyle(completionBorderColor.opacity(showCompletionGlow ? 0.6 : 0.25)),
                    lineWidth: hasInProgressCall ? 1.5 : (showCompletionGlow ? 1.5 : 1)
                )
                .animation(.easeOut(duration: 0.8), value: showCompletionGlow)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        // Glow effect
        .shadow(
            color: hasInProgressCall
                ? theme.accentColor.opacity(0.15)
                : (showCompletionGlow ? completionBorderColor.opacity(0.2) : .clear),
            radius: 8,
            x: 0,
            y: 2
        )
        .animation(.easeOut(duration: 0.8), value: showCompletionGlow)
        .onAppear {
            if hasInProgressCall {
                startGradientAnimation()
            }
        }
        .onChange(of: hasInProgressCall) { oldValue, inProgress in
            if inProgress {
                startGradientAnimation()
            } else if oldValue {
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

    private func startGradientAnimation() {
        withAnimation(.linear(duration: 3.0).repeatForever(autoreverses: false)) {
            gradientRotation = 360
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
}
