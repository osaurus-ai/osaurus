//
//  PastedContentSheet.swift
//  osaurus
//
//  Modal preview for a pasted-content attachment. Shows a header with
//  byte size, line count, and a formatting disclaimer, then the full
//  pasted text in a read-only monospaced scroll view.
//

import SwiftUI

struct PastedContentSheet: View {
    let attachment: Attachment
    var onDismiss: () -> Void

    @Environment(\.theme) private var theme

    private var content: String { attachment.loadDocumentContent() ?? "" }
    private var lineCount: Int { attachment.pastedContentLineCount ?? 0 }
    private var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(content.utf8.count), countStyle: .file)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                Text(content)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(16)
            }
            .background(theme.primaryBackground.opacity(0.6))
        }
        .frame(minWidth: 520, idealWidth: 640, minHeight: 480, idealHeight: 640)
        .background(theme.primaryBackground)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pasted content", bundle: .module)
                    .font(theme.font(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("\(sizeFormatted) · \(lineCount) lines")
                    .font(theme.font(size: 11, weight: .regular))
                    .foregroundColor(theme.secondaryText)
            }
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.secondaryText)
                    .padding(6)
                    .background(
                        Circle().fill(theme.secondaryBackground.opacity(0.6))
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
