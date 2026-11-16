//
//  DocumentChip.swift
//  osaurus
//
//  Compact chip showing a document attachment's name, icon, and file size.
//  When `onRemove` is provided, a dismiss button is shown (for pending attachments).
//  When the attachment is a pasted-content sentinel, the chip swaps the
//  file-size label for a "PASTED" badge + line count and exposes an
//  optional tap action for opening the preview sheet.
//

import SwiftUI

struct DocumentChip: View {
    let attachment: Attachment
    var onRemove: (() -> Void)? = nil
    var onTap: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    var onInline: (() -> Void)? = nil

    @Environment(\.theme) private var theme
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isOnComposerInputSurface) private var isOnComposerInputSurface

    private var isPasted: Bool { attachment.isPastedContent }
    private var businessSummary: BusinessDocumentSummary? { attachment.businessDocumentSummary }

    var body: some View {
        let border = AttachmentInspectionStyle.color("border", theme.border.subtle, theme)
        let borderWidth = AttachmentInspectionStyle.metric("borderWidth", theme.hairline, theme)
        let needsComposerBoundary = isOnComposerInputSurface && !theme.isDark && isEnabled
        HStack(spacing: theme.catalogLayoutMetric("component.library.24.elements.layout.documentChip.body.horizontalGap", inheriting: AttachmentInspectionStyle.metric("gap", theme.space.s6, theme))) {
            chipContent
        }.catalogLayoutTarget("component.library.24.elements.layout.documentChip.body.horizontalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.24.elements.layout.documentChip.body.paddingX", inheriting: AttachmentInspectionStyle.metric("padding", theme.space.s8, theme))).catalogLayoutTarget("component.library.24.elements.layout.documentChip.body.paddingX")
        .padding(.vertical, theme.catalogLayoutMetric("component.library.24.elements.layout.documentChip.body.paddingY", inheriting: AttachmentInspectionStyle.metric("padding", theme.space.s4, theme))).catalogLayoutTarget("component.library.24.elements.layout.documentChip.body.paddingY")
        .modifier(AttachmentMinimumHeight())
        .background(
            RoundedRectangle(cornerRadius: AttachmentInspectionStyle.metric("radius", theme.radius.medium, theme), style: .continuous)
                .fill(chipBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AttachmentInspectionStyle.metric("radius", theme.radius.medium, theme), style: .continuous)
                .strokeBorder(
                    needsComposerBoundary ? theme.assignedColor("color.border.control", fallback: theme.border.strong) : border,
                    lineWidth: needsComposerBoundary ? max(theme.stroke.default, borderWidth) : borderWidth
                )
        )
        .overlay(alignment: .topTrailing) {
            if let onRemove {
                SettingsIconButton("xmark", help: "Remove attachment", size: .extraExtraSmall, role: .secondary, action: onRemove)
                    .accessibilityLabel("Remove \(attachment.filename ?? "attachment")")
                    .offset(x: theme.space.s4, y: -theme.space.s4)
                    .pointingHandCursor()
            }
        }
        .onHover { isHovered = $0 }
    }

    private var chipBackground: Color {
        AttachmentInspectionStyle.color(!isEnabled ? "disabledBackground" : isHovered ? "hover" : "background", theme.surface.subtle, theme)
    }

    @ViewBuilder
    private var chipContent: some View {
        Group {
            if let onTap {
                Button(action: onTap) { labelStack }
                    .assignedBasePlainButtonStyle()
                    .assignedBaseKeyboardButton(24, action: onTap)
                    .pointingHandCursor()
            } else {
                labelStack
            }
        }

        if let onInline {
            // A labeled button, not a bare icon: users did not discover the
            // icon-only version and asked for a way to undo the collapse
            // (#3271).
            let shape = RoundedRectangle(
                cornerRadius: AttachmentInspectionStyle.metric("radius", theme.radius.medium, theme),
                style: .continuous
            )
            Button(action: onInline) {
                // Same fill, stroke, height and ink as the circular edit /
                // remove buttons beside it, and the chip's own corner radius,
                // so the row reads as one set.
                HStack(spacing: theme.space.s2) {
                    Image(systemName: "text.insert")
                        .glyphSize(.micro, weight: .semibold)
                    Text("Insert as Text", bundle: .module)
                        .attachmentTextStyle(.micro, property: "caption", weight: 600)
                        .lineLimit(1)
                }
                .attachmentInk("accent", fallback: theme.text.secondary)
                .padding(.horizontal, theme.space.s6)
                .frame(height: 20)
                .background(
                    shape.fill(AttachmentInspectionStyle.color(isEnabled ? "background" : "disabledBackground", theme.surface.canvas, theme))
                )
                .overlay(
                    shape.strokeBorder(AttachmentInspectionStyle.color("border", theme.border.subtle, theme), lineWidth: AttachmentInspectionStyle.metric("borderWidth", theme.hairline, theme))
                )
                .contentShape(shape)
            }
            .assignedBasePlainButtonStyle()
            .assignedBaseKeyboardButton(24, action: onInline)
            .pointingHandCursor()
            .localizedHelp("Insert into message")
        }

        if let onEdit {
            circularButton(systemName: "pencil", action: onEdit)
                .localizedHelp("Edit pasted content")
        }

    }

    private var labelStack: some View {
        HStack(spacing: theme.catalogLayoutMetric("component.library.24.elements.layout.documentChip.labelStack.horizontalGap", inheriting: AttachmentInspectionStyle.metric("gap", theme.space.s4, theme))) {
            Image(systemName: isPasted ? "doc.on.clipboard" : businessSummary?.systemImageName ?? attachment.fileIcon)
                .glyphSize(.footnote, weight: .medium)
                .attachmentInk("accent", fallback: theme.text.secondary)

            if let name = attachment.filename {
                Text(name)
                    .attachmentTextStyle(.footnote, property: "text", weight: 500)
                    .attachmentInk("foreground", fallback: theme.text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: onRemove != nil ? 120 : nil)
            }

            if isPasted {
                if let lines = attachment.pastedContentLineCount {
                    Text("\(lines) lines")
                        .attachmentTextStyle(.micro, property: "caption")
                        .attachmentInk("secondary", fallback: onRemove != nil ? theme.text.secondary : theme.text.tertiary)
                }
            } else if let detail = businessSummary?.chipDetailLabel ?? attachment.fileSizeFormatted {
                Text(detail)
                    .attachmentTextStyle(.micro, property: "caption")
                    .attachmentInk("secondary", fallback: onRemove != nil ? theme.text.secondary : theme.text.tertiary)
                    .lineLimit(1)
            }
        }.catalogLayoutTarget("component.library.24.elements.layout.documentChip.labelStack.horizontalGap")
    }

    private func circularButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .glyphSize(.micro, weight: .semibold)
                .attachmentInk("accent", fallback: theme.text.secondary)
                .frame(width: 20, height: 20)
                .background(
                    Circle().fill(AttachmentInspectionStyle.color(isEnabled ? "background" : "disabledBackground", theme.surface.canvas, theme))
                )
                .overlay(
                    Circle().strokeBorder(AttachmentInspectionStyle.color("border", theme.border.subtle, theme), lineWidth: AttachmentInspectionStyle.metric("borderWidth", theme.hairline, theme))
                )
                .contentShape(Circle())
        }
        .assignedBasePlainButtonStyle()
        .assignedBaseKeyboardButton(24, action: action)
        .pointingHandCursor()
        .accessibilityLabel(systemName == "pencil" ? "Edit pasted content" : "Insert into message")
    }
}

private struct AttachmentMinimumHeight: ViewModifier {
    @Environment(\.theme) private var theme
    @ViewBuilder func body(content: Content) -> some View {
        content.frame(minHeight: AttachmentInspectionStyle.documentHeight(theme))
    }
}
