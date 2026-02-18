//
//  ContentBlockView.swift
//  osaurus
//
//  Renders a single content block in the NSTableView-backed chat view.
//  Equatable conformance enables efficient cell reuse.
//

import AppKit
import SwiftUI

struct ContentBlockView: View, Equatable {
    let block: ContentBlock
    let width: CGFloat  // Content width (already adjusted by parent)
    let agentName: String
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
            && lhs.agentName == rhs.agentName && lhs.isTurnHovered == rhs.isTurnHovered
            && lhs.editingTurnId == rhs.editingTurnId
    }

    @Environment(\.theme) private var theme

    private var isUserMessage: Bool { block.role == .user }
    private var isLastInTurn: Bool { block.position == .only || block.position == .last }

    // MARK: - Body

    private var userBubbleBackgroundColor: Color {
        if let color = theme.userBubbleColor { return color }
        return theme.accentColor
    }

    private var bubbleCornerRadius: CGFloat { CGFloat(theme.bubbleCornerRadius) }

    @ViewBuilder
    private var messageBubbleBackground: some View {
        if isUserMessage {
            ZStack {
                if theme.glassEnabled {
                    RoundedRectangle(cornerRadius: bubbleCornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                }
                RoundedRectangle(cornerRadius: bubbleCornerRadius, style: .continuous)
                    .fill(userBubbleBackgroundColor.opacity(theme.userBubbleOpacity))
            }
        } else {
            Color.clear
        }
    }

    var body: some View {
        if case .groupSpacer = block.kind {
            Color.clear.frame(height: 16)
        } else {
            contentContainer
                .background(messageBubbleBackground)
                .clipShape(RoundedRectangle(cornerRadius: isUserMessage ? bubbleCornerRadius : 0, style: .continuous))
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
            MarkdownMessageView(
                text: text,
                baseWidth: width,
                cacheKey: block.id,
                isStreaming: isStreaming
            )
            .padding(.top, 4)
            .padding(.bottom, isLastInTurn ? 16 : 4)

        case let .toolCallGroup(calls):
            GroupedToolCallsContainerView(calls: calls)
                .padding(.top, 6)
                .padding(.bottom, 16)

        case let .thinking(_, text, isStreaming):
            ThinkingBlockView(
                thinking: text,
                baseWidth: width,
                isStreaming: isStreaming,
                thinkingLength: text.count,
                blockId: block.id
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

        case let .userMessage(text, images):
            HeaderBlockContent(
                turnId: block.turnId,
                role: .user,
                name: "You",
                isTurnHovered: isTurnHovered,
                onCopy: onCopy,
                onRegenerate: onRegenerate,
                onEdit: onEdit,
                isEditing: editingTurnId == block.turnId,
                onCancelEdit: onCancelEdit
            )
            .padding(.top, 12)
            .padding(.bottom, 2)

            ForEach(Array(images.enumerated()), id: \.offset) { _, imageData in
                ImageThumbnail(imageData: imageData, baseWidth: width)
                    .padding(.top, 6)
                    .padding(.bottom, text.isEmpty ? 16 : 6)
            }

            if editingTurnId == block.turnId, let editText, let onConfirmEdit, let onCancelEdit {
                InlineEditView(
                    text: editText,
                    onConfirm: onConfirmEdit,
                    onCancel: onCancelEdit
                )
                .padding(.top, 4)
                .padding(.bottom, 16)
            } else if !text.isEmpty {
                MarkdownMessageView(
                    text: text,
                    baseWidth: width,
                    cacheKey: block.id,
                    isStreaming: false
                )
                .padding(.top, 4)
                .padding(.bottom, 16)
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

    @ViewBuilder
    private var userMessageBorder: some View {
        if isUserMessage {
            if theme.showEdgeLight {
                RoundedRectangle(cornerRadius: bubbleCornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [theme.glassEdgeLight, theme.glassEdgeLight.opacity(0.4)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: CGFloat(theme.messageBorderWidth)
                    )
            } else {
                RoundedRectangle(cornerRadius: bubbleCornerRadius, style: .continuous)
                    .strokeBorder(
                        theme.primaryBorder.opacity(theme.borderOpacity),
                        lineWidth: CGFloat(theme.messageBorderWidth)
                    )
            }
        }
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
            RoundedRectangle(cornerRadius: CGFloat(theme.inputCornerRadius), style: .continuous)
                .fill(theme.primaryBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CGFloat(theme.inputCornerRadius), style: .continuous)
                .strokeBorder(
                    theme.accentColor.opacity(theme.borderOpacity + 0.2),
                    lineWidth: CGFloat(theme.defaultBorderWidth)
                )
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
                            .strokeBorder(
                                theme.primaryBorder.opacity(theme.borderOpacity),
                                lineWidth: CGFloat(theme.defaultBorderWidth)
                            )
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

// MARK: - Image Thumbnail

private struct ImageThumbnail: View {
    let imageData: Data
    let baseWidth: CGFloat

    @Environment(\.theme) private var theme
    @State private var isHovered = false
    @State private var showFullScreen = false

    private var maxImageWidth: CGFloat {
        min(baseWidth - 32, 560)
    }

    private func displaySize(for image: NSImage) -> CGSize {
        let size = image.size
        guard size.width > 0, size.height > 0 else {
            return CGSize(width: maxImageWidth, height: maxImageWidth * 0.75)
        }
        let width = min(size.width, maxImageWidth)
        return CGSize(width: width, height: width * size.height / size.width)
    }

    var body: some View {
        if let nsImage = NSImage(data: imageData) {
            let size = displaySize(for: nsImage)
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
                .clipShape(imageClipShape)
                .overlay(imageClipShape.strokeBorder(theme.primaryBorder.opacity(0.3), lineWidth: 0.5))
                .overlay(alignment: .topTrailing) {
                    if isHovered {
                        imageHoverToolbar(for: nsImage)
                            .transition(.opacity)
                    }
                }
                .contextMenu { imageContextMenu(for: nsImage) }
                .shadow(
                    color: theme.shadowColor.opacity(isHovered ? 0.15 : 0.08),
                    radius: isHovered ? 12 : 6,
                    x: 0,
                    y: isHovered ? 6 : 3
                )
                .scaleEffect(isHovered ? 1.01 : 1.0)
                .animation(.easeInOut(duration: 0.2), value: isHovered)
                .onHover { isHovered = $0 }
                .onTapGesture { showFullScreen = true }
                .sheet(isPresented: $showFullScreen) {
                    ImageFullScreenView(image: nsImage, altText: "")
                }
        }
    }

    @ViewBuilder
    private func imageContextMenu(for image: NSImage) -> some View {
        Button {
            ImageActions.saveImageToFile(image)
        } label: {
            Label("Save Image\u{2026}", systemImage: "arrow.down.to.line")
        }
        Button {
            ImageActions.copyImageToClipboard(image)
        } label: {
            Label("Copy Image", systemImage: "doc.on.doc")
        }
        Divider()
        Button {
            showFullScreen = true
        } label: {
            Label("Open Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
        }
    }

    private func imageHoverToolbar(for image: NSImage) -> some View {
        HStack(spacing: 2) {
            toolbarButton("arrow.down.to.line", help: "Save Image") {
                ImageActions.saveImageToFile(image)
            }
            toolbarButton("doc.on.doc", help: "Copy Image") {
                ImageActions.copyImageToClipboard(image)
            }
        }
        .foregroundColor(.white)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .padding(8)
    }

    private func toolbarButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(help)
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
