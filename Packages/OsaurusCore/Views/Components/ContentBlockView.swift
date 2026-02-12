//
//  ContentBlockView.swift
//  osaurus
//
//  Renders a single content block in the flattened chat view.
//  Optimized for LazyVStack recycling with Equatable conformance.
//

import AppKit
import SwiftUI

struct ContentBlockView: View, Equatable {
    let block: ContentBlock
    let width: CGFloat  // Content width (already adjusted by parent)
    let personaName: String
    var isTurnHovered: Bool = false

    // Action callbacks
    var onCopy: ((UUID) -> Void)?
    var onRegenerate: ((UUID) -> Void)?
    var onEdit: ((UUID) -> Void)?
    var onClarificationSubmit: ((String) -> Void)?

    // Inline editing state
    var editingTurnId: UUID? = nil
    var editText: Binding<String>? = nil
    var onConfirmEdit: (() -> Void)? = nil
    var onCancelEdit: (() -> Void)? = nil

    nonisolated static func == (lhs: ContentBlockView, rhs: ContentBlockView) -> Bool {
        lhs.block == rhs.block && lhs.width == rhs.width
            && lhs.personaName == rhs.personaName && lhs.isTurnHovered == rhs.isTurnHovered
            && lhs.editingTurnId == rhs.editingTurnId
    }

    @Environment(\.theme) private var theme

    private var isUserMessage: Bool { block.role == .user }
    private var isLastInTurn: Bool { block.position == .only || block.position == .last }

    // MARK: - Body

    var body: some View {
        if case .groupSpacer = block.kind {
            Color.clear.frame(height: 16)
        } else {
            contentContainer
                .background(isUserMessage ? theme.secondaryBackground.opacity(0.5) : Color.clear)
                .clipShape(UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous))
                .overlay(userMessageBorder)
        }
    }

    // MARK: - Content Container

    private var contentContainer: some View {
        VStack(alignment: .leading, spacing: 0) {
            blockContent
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }

    // MARK: - Block Content

    @ViewBuilder
    private var blockContent: some View {
        switch block.kind {
        case let .header(role, name, _):
            HeaderBlockContent(
                turnId: block.turnId,
                role: role,
                name: name,
                isTurnHovered: isTurnHovered,
                onCopy: onCopy,
                onRegenerate: onRegenerate,
                onEdit: onEdit,
                isEditing: editingTurnId == block.turnId,
                onCancelEdit: onCancelEdit
            )
            .padding(.top, 12)
            .padding(.bottom, isLastInTurn ? 8 : 2)

        case let .paragraph(_, text, isStreaming, _):
            if isUserMessage, editingTurnId == block.turnId, let editText, let onConfirmEdit, let onCancelEdit {
                InlineEditView(
                    text: editText,
                    onConfirm: onConfirmEdit,
                    onCancel: onCancelEdit
                )
                .padding(.top, 4)
                .padding(.bottom, isLastInTurn ? 16 : 4)
            } else {
                MarkdownMessageView(
                    text: text,
                    baseWidth: width,
                    cacheKey: block.id,
                    isStreaming: isStreaming
                )
                .padding(.top, 4)
                .padding(.bottom, isLastInTurn ? 16 : 4)
            }

        case let .toolCallGroup(calls):
            GroupedToolCallsContainerView(calls: calls)
                .padding(.top, 6)
                .padding(.bottom, 16)

        case let .thinking(_, text, isStreaming):
            ThinkingBlockView(
                thinking: text,
                baseWidth: width,
                isStreaming: isStreaming,
                thinkingLength: text.count
            )
            .padding(.top, 6)
            .padding(.bottom, isLastInTurn ? 16 : 6)

        case let .clarification(request):
            ClarificationCardView(
                request: request,
                onSubmit: { response in
                    onClarificationSubmit?(response)
                }
            )
            .padding(.top, 6)
            .padding(.bottom, isLastInTurn ? 12 : 4)

        case let .image(_, imageData):
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
                    .shadow(color: theme.shadowColor.opacity(0.1), radius: 4, x: 0, y: 2)
                    .padding(.top, 6)
                    .padding(.bottom, isLastInTurn ? 16 : 6)
            }

        case .typingIndicator:
            TypingIndicator()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .padding(.bottom, isLastInTurn ? 16 : 8)

        case .groupSpacer:
            EmptyView()
        }
    }

    // MARK: - User Message Styling

    private var cornerRadii: RectangleCornerRadii {
        guard isUserMessage else { return .init() }

        let r: CGFloat = 8
        switch block.position {
        case .only: return .init(topLeading: r, bottomLeading: r, bottomTrailing: r, topTrailing: r)
        case .first: return .init(topLeading: r, bottomLeading: 0, bottomTrailing: 0, topTrailing: r)
        case .middle: return .init()
        case .last: return .init(topLeading: 0, bottomLeading: r, bottomTrailing: r, topTrailing: 0)
        }
    }

    @ViewBuilder
    private var userMessageBorder: some View {
        if isUserMessage {
            UserMessageBorderPath(
                position: block.position,
                radius: 8
            )
            .stroke(theme.primaryBorder.opacity(0.3), lineWidth: 1)
        }
    }
}

// MARK: - User Message Border Path

/// Custom path that draws position-aware borders for user message blocks
private struct UserMessageBorderPath: Shape {
    let position: BlockPosition
    let radius: CGFloat

    private var showTop: Bool { position == .first || position == .only }
    private var showBottom: Bool { position == .last || position == .only }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let r = radius

        // Left edge
        path.move(to: CGPoint(x: 0, y: showTop ? r : 0))
        path.addLine(to: CGPoint(x: 0, y: showBottom ? h - r : h))

        // Bottom
        if showBottom {
            path.addArc(
                center: CGPoint(x: r, y: h - r),
                radius: r,
                startAngle: .degrees(180),
                endAngle: .degrees(90),
                clockwise: true
            )
            path.addLine(to: CGPoint(x: w - r, y: h))
            path.addArc(
                center: CGPoint(x: w - r, y: h - r),
                radius: r,
                startAngle: .degrees(90),
                endAngle: .degrees(0),
                clockwise: true
            )
        } else {
            path.move(to: CGPoint(x: w, y: h))
        }

        // Right edge
        path.addLine(to: CGPoint(x: w, y: showTop ? r : 0))

        // Top
        if showTop {
            path.addArc(
                center: CGPoint(x: w - r, y: r),
                radius: r,
                startAngle: .degrees(0),
                endAngle: .degrees(-90),
                clockwise: true
            )
            path.addLine(to: CGPoint(x: r, y: 0))
            path.addArc(
                center: CGPoint(x: r, y: r),
                radius: r,
                startAngle: .degrees(-90),
                endAngle: .degrees(180),
                clockwise: true
            )
        }

        return path
    }
}

// MARK: - Header Block Content

private struct HeaderBlockContent: View {
    let turnId: UUID
    let role: MessageRole
    let name: String
    var isTurnHovered: Bool = false
    var onCopy: ((UUID) -> Void)?
    var onRegenerate: ((UUID) -> Void)?
    var onEdit: ((UUID) -> Void)?
    var isEditing: Bool = false
    var onCancelEdit: (() -> Void)?

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .font(theme.font(size: CGFloat(theme.captionSize) + 1, weight: .semibold))
                .foregroundColor(role == .user ? theme.accentColor : theme.secondaryText)

            if isEditing {
                Text("Editing")
                    .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                    .foregroundColor(theme.accentColor.opacity(0.7))
            }

            Spacer()

            actionButtons
                .opacity(isTurnHovered || isEditing ? 1 : 0)
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .animation(theme.animationQuick(), value: isTurnHovered)
        .animation(theme.animationQuick(), value: isEditing)
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 4) {
            if isEditing, let onCancelEdit {
                ActionButton(icon: "xmark", help: "Cancel edit") {
                    onCancelEdit()
                }
            } else if role == .user, let onEdit {
                ActionButton(icon: "pencil", help: "Edit") {
                    onEdit(turnId)
                }
            }
            if role == .assistant, let onRegenerate {
                ActionButton(icon: "arrow.clockwise", help: "Regenerate") {
                    onRegenerate(turnId)
                }
            }
            if !isEditing, let onCopy {
                ActionButton(icon: "doc.on.doc", help: "Copy") {
                    onCopy(turnId)
                }
            }
        }
    }
}

// MARK: - Inline Edit View

/// Inline editor that replaces the message paragraph when editing.
/// Enter submits, Shift+Enter inserts a newline.
private struct InlineEditView: View {
    @Binding var text: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @Environment(\.theme) private var theme
    @State private var isFocused: Bool = true

    private var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            editableArea
            actionButtons
        }
    }

    // MARK: - Subviews

    private var editableArea: some View {
        EditableTextView(
            text: $text,
            fontSize: CGFloat(theme.bodySize),
            textColor: theme.primaryText,
            cursorColor: theme.accentColor,
            isFocused: $isFocused,
            maxHeight: 240,
            onCommit: { if !isEmpty { onConfirm() } }
        )
        .frame(minHeight: 40, maxHeight: 240)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.primaryBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.accentColor.opacity(0.5), lineWidth: 1)
        )
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Spacer()

            Button(action: onCancel) {
                Text("Cancel")
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(theme.secondaryBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(theme.primaryBorder.opacity(0.3), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            Button(action: onConfirm) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .semibold))
                    Text("Save & Regenerate")
                        .font(theme.font(size: CGFloat(theme.captionSize), weight: .semibold))
                }
                .foregroundColor(isEmpty ? theme.secondaryText : .white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isEmpty ? theme.secondaryBackground : theme.accentColor)
                )
            }
            .buttonStyle(.plain)
            .disabled(isEmpty)
        }
    }
}

// MARK: - Action Button

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
