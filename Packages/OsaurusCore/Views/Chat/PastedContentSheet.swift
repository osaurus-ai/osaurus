//
//  PastedContentSheet.swift
//  osaurus
//
//  Modal preview for a pasted-content attachment. Read-only by default;
//  when `onSave` is provided, the body switches to an editable TextEditor
//  and the header shows Cancel/Save actions.
//

import SwiftUI

struct PastedContentSheet: View {
    let attachment: Attachment
    var onDismiss: () -> Void
    var onSave: ((String) -> Void)? = nil

    @Environment(\.theme) private var theme
    @State private var draft: String = ""
    @State private var didInit: Bool = false

    private var originalContent: String { attachment.loadDocumentContent() ?? "" }
    private var displayedContent: String { isEditable ? draft : originalContent }
    private var isEditable: Bool { onSave != nil }
    private var lineCount: Int {
        let text = displayedContent
        if text.isEmpty { return 0 }
        var count = 1
        for ch in text where ch == "\n" { count += 1 }
        return count
    }
    private var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(displayedContent.utf8.count), countStyle: .file)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            contentBody
                .background(theme.primaryBackground.opacity(0.6))
            if isEditable {
                Divider()
                footer
            }
        }
        .frame(minWidth: 520, idealWidth: 640, minHeight: 480, idealHeight: 640)
        .background(theme.primaryBackground)
        .onAppear {
            if !didInit {
                draft = originalContent
                didInit = true
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button(localized: "Cancel", action: onDismiss)
                .keyboardShortcut(.cancelAction)
            Button(localized: "Save") {
                onSave?(draft)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var contentBody: some View {
        if isEditable {
            TextEditor(text: $draft)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .scrollContentBackground(.hidden)
                .padding(12)
        } else {
            ScrollView {
                Text(originalContent)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(16)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(isEditable ? "Edit pasted content" : "Pasted content", bundle: .module)
                    .font(theme.font(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("\(sizeFormatted) · \(lineCount) lines")
                    .font(theme.font(size: 11, weight: .regular))
                    .foregroundColor(theme.secondaryText)
            }
            Spacer(minLength: 8)
            if !isEditable {
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
