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

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    private var isPasted: Bool { attachment.isPastedContent }

    var body: some View {
        HStack(spacing: 5) {
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
            } else {
                labelStack
            }
        }

        if let onRemove {
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(theme.secondaryText)
            }
            .buttonStyle(.plain)
        }
    }

    private var labelStack: some View {
        HStack(spacing: 5) {
            Image(systemName: isPasted ? "doc.on.clipboard" : attachment.fileIcon)
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
                pastedBadge
                if let lines = attachment.pastedContentLineCount {
                    Text("\(lines) lines")
                        .font(theme.font(size: 9, weight: .regular))
                        .foregroundColor(onRemove != nil ? theme.secondaryText : theme.tertiaryText)
                }
            } else if let size = attachment.fileSizeFormatted {
                Text(size)
                    .font(theme.font(size: 9, weight: .regular))
                    .foregroundColor(onRemove != nil ? theme.secondaryText : theme.tertiaryText)
            }
        }
    }

    private var pastedBadge: some View {
        Text("PASTED")
            .font(theme.font(size: 8, weight: .bold))
            .foregroundColor(theme.secondaryText)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(theme.primaryBorder.opacity(0.45), lineWidth: 0.5)
            )
    }
}
