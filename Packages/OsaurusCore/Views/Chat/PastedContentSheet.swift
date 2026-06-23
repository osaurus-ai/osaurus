//
//  PastedContentSheet.swift
//  osaurus
//
//  Modal preview for a pasted-content attachment. Read-only by default;
//  when `onSave` is provided, the body switches to an editable TextEditor
//  and the header shows Cancel/Save actions.
//

import AppKit
import SwiftUI

struct PastedContentSheet: View {
    let attachment: Attachment
    var onDismiss: () -> Void
    var onSave: ((String) -> Void)? = nil

    @Environment(\.theme) private var theme
    @State private var draft: String = ""
    @State private var didInit: Bool = false
    /// Cached extracted text for spillover (`documentRef`) attachments, whose
    /// content lives in the encrypted blob store. Loaded once off the main
    /// thread so re-reads during layout never touch disk on the main actor.
    @State private var spilledContent: String = ""
    /// Briefly true after a copy so the button swaps to a checkmark.
    @State private var didCopy: Bool = false

    /// Inline documents (and all pasted content) carry their text directly, so
    /// they resolve synchronously with no disk I/O. Spilled documents fall back
    /// to `spilledContent`, which a `.task` fills off the main thread.
    private var originalContent: String {
        if case .document(_, let content, _) = attachment.kind { return content }
        return spilledContent
    }
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
        .task {
            // Hydrate spilled blobs off the main thread before seeding the draft.
            if case .documentRef = attachment.kind, spilledContent.isEmpty {
                let loaded = await Task.detached { attachment.loadDocumentContent() ?? "" }.value
                spilledContent = loaded
            }
            if !didInit {
                draft = originalContent
                didInit = true
            }
        }
    }

    private func copyContent() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(originalContent, forType: .string)
        withAnimation { didCopy = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { didCopy = false }
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

    /// Pasted text keeps its generic "Pasted content" heading; an attached file
    /// (PDF/DOCX/etc.) shows its filename so the preview is self-identifying.
    private var titleText: Text {
        if attachment.isPastedContent {
            return Text(isEditable ? "Edit pasted content" : "Pasted content", bundle: .module)
        }
        if let name = attachment.filename, !name.isEmpty {
            return Text(verbatim: name)
        }
        return Text("Document", bundle: .module)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                titleText
                    .font(theme.font(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(sizeFormatted) · \(lineCount) lines")
                    .font(theme.font(size: 11, weight: .regular))
                    .foregroundColor(theme.secondaryText)
            }
            Spacer(minLength: 8)
            if !isEditable {
                Button(action: copyContent) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(didCopy ? theme.accentColor : theme.secondaryText)
                        .padding(6)
                        .background(
                            Circle().fill(theme.secondaryBackground.opacity(0.6))
                        )
                }
                .buttonStyle(.plain)
                .localizedHelp("Copy")
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
