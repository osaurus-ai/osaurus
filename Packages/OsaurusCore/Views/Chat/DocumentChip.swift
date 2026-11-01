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

    private var isPasted: Bool { attachment.isPastedContent }
    private var businessSummary: BusinessDocumentSummary? { attachment.businessDocumentSummary }

    var body: some View {
        HStack(spacing: 6) {
            chipContent
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    (onRemove != nil ? theme.tertiaryBackground : theme.secondaryBackground)
                        .opacity(isHovered ? 0.9 : 0.7)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.primaryBorder.opacity(0.2), lineWidth: 0.5)
        )
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var chipContent: some View {
        Group {
            if let onTap {
                Button(action: onTap) { labelStack }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
            } else {
                labelStack
            }
        }

        if let onInline {
            // A labeled button, not a bare icon: users did not discover the
            // icon-only version and asked for a way to undo the collapse
            // (#3271).
            Button(action: onInline) {
                // Same fill, stroke, height and text color as the circular
                // edit / remove buttons beside it, and the chip's own 8pt corner
                // radius, so the row reads as one set.
                HStack(spacing: 3) {
                    Image(systemName: "text.insert")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Insert as Text", bundle: .module)
                        .font(theme.font(size: 10, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.primaryBackground.opacity(0.6)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.primaryBorder.opacity(0.25), lineWidth: 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .localizedHelp("Insert into message")
        }

        if let onEdit {
            circularButton(systemName: "pencil", action: onEdit)
                .localizedHelp("Edit pasted content")
        }

        if let onRemove {
            circularButton(systemName: "xmark", action: onRemove)
        }
    }

    private var labelStack: some View {
        HStack(spacing: 5) {
            Image(systemName: isPasted ? "doc.on.clipboard" : businessSummary?.systemImageName ?? attachment.fileIcon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.accentColor)

            if let name = attachment.filename {
                Text(name)
                    .font(theme.font(size: 11, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: onRemove != nil ? 120 : nil)
            }

            if isPasted {
                if let lines = attachment.pastedContentLineCount {
                    Text("\(lines) lines")
                        .font(theme.font(size: 9, weight: .regular))
                        .foregroundColor(onRemove != nil ? theme.secondaryText : theme.tertiaryText)
                }
            } else if let detail = businessSummary?.chipDetailLabel ?? attachment.fileSizeFormatted {
                Text(detail)
                    .font(theme.font(size: 9, weight: .regular))
                    .foregroundColor(onRemove != nil ? theme.secondaryText : theme.tertiaryText)
                    .lineLimit(1)
            }
        }
    }

    private func circularButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.secondaryText)
                .frame(width: 20, height: 20)
                .background(
                    Circle().fill(theme.primaryBackground.opacity(0.6))
                )
                .overlay(
                    Circle().strokeBorder(theme.primaryBorder.opacity(0.25), lineWidth: 0.5)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}
