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

    @Environment(\.theme) private var environmentTheme
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(24) }
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
        VStack(spacing: theme.space.s0) {
            header
            Divider()
            contentBody
                .background(theme.surface.canvas)
            if isEditable {
                Divider()
                footer
            }
        }
        .frame(minWidth: 520, idealWidth: 640, minHeight: 480, idealHeight: 640)
        .background(theme.surface.canvas)
        .environment(\.theme, theme)
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
        HStack(spacing: theme.catalogLayoutMetric("component.library.24.elements.layout.pastedContentSheet.footer.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(24, "gap", theme.space.s8, theme))) {
            Spacer()
            Button(localized: "Cancel", action: onDismiss)
                .keyboardShortcut(.cancelAction)
                .assignedSettingsButtonStyle(.secondary)
            Button(localized: "Save") {
                onSave?(draft)
            }
            .keyboardShortcut(.defaultAction)
            .assignedSettingsButtonStyle(.primary)
        }.catalogLayoutTarget("component.library.24.elements.layout.pastedContentSheet.footer.horizontalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.24.elements.layout.pastedContentSheet.footer.paddingX", inheriting: NativeComponentInspectionStyle.metric(24, "padding", theme.space.s16, theme))).catalogLayoutTarget("component.library.24.elements.layout.pastedContentSheet.footer.paddingX")
        .padding(.vertical, theme.catalogLayoutMetric("component.library.24.elements.layout.pastedContentSheet.footer.paddingY", inheriting: NativeComponentInspectionStyle.metric(24, "padding", theme.space.s12, theme))).catalogLayoutTarget("component.library.24.elements.layout.pastedContentSheet.footer.paddingY")
    }

    /// Body style, the same one the chat composer uses, so pasted text reads
    /// the way it would if it had been typed. The code style it replaced was
    /// the "much smaller font" reported in #3271.
    @ViewBuilder
    private var contentBody: some View {
        if isEditable {
            TextEditor(text: $draft)
                .textStyle(.body)
                .foregroundColor(theme.text.primary)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, theme.catalogLayoutMetric("component.library.24.elements.layout.pastedContentSheet.contentBody.padding.horizontal", inheriting: NativeComponentInspectionStyle.metric(24, "padding", theme.space.s12, theme))).padding(.vertical, theme.catalogLayoutMetric("component.library.24.elements.layout.pastedContentSheet.contentBody.padding.vertical", inheriting: NativeComponentInspectionStyle.metric(24, "padding", theme.space.s12, theme))).catalogLayoutTarget("component.library.24.elements.layout.pastedContentSheet.contentBody.padding.horizontal").catalogLayoutTarget("component.library.24.elements.layout.pastedContentSheet.contentBody.padding.vertical")
        } else {
            ScrollView {
                Text(originalContent)
                    .textStyle(.body)
                    .foregroundColor(theme.text.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, theme.catalogLayoutMetric("component.library.24.elements.layout.pastedContentSheet.contentBody.padding2.horizontal", inheriting: NativeComponentInspectionStyle.metric(24, "padding", theme.space.s16, theme))).padding(.vertical, theme.catalogLayoutMetric("component.library.24.elements.layout.pastedContentSheet.contentBody.padding2.vertical", inheriting: NativeComponentInspectionStyle.metric(24, "padding", theme.space.s16, theme))).catalogLayoutTarget("component.library.24.elements.layout.pastedContentSheet.contentBody.padding2.horizontal").catalogLayoutTarget("component.library.24.elements.layout.pastedContentSheet.contentBody.padding2.vertical")
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
        HStack(alignment: .top, spacing: theme.catalogLayoutMetric("component.library.24.elements.layout.pastedContentSheet.header.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(24, "gap", theme.space.s12, theme))) {
            VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.24.elements.layout.pastedContentSheet.header.verticalGap", inheriting: NativeComponentInspectionStyle.metric(24, "gap", theme.space.s4, theme))) {
                titleText
                    .componentInspectionText(24, role: .heading, fallback: .body, weight: 600, theme: theme)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(
                    lineCount == 1
                        ? L("\(sizeFormatted) · 1 line")
                        : L("\(sizeFormatted) · \(lineCount) lines")
                )
                .componentInspectionText(24, role: .caption, fallback: .footnote, theme: theme)
                .foregroundColor(theme.text.secondary)
            }.catalogLayoutTarget("component.library.24.elements.layout.pastedContentSheet.header.verticalGap")
            Spacer(minLength: 8)
            if !isEditable {
                SettingsIconButton(didCopy ? "checkmark" : "doc.on.doc", help: "Copy", size: .compact, action: copyContent)
                .localizedHelp("Copy")
                SettingsIconButton("xmark", help: "Close", size: .compact, action: onDismiss)
                .keyboardShortcut(.cancelAction)
            }
        }.catalogLayoutTarget("component.library.24.elements.layout.pastedContentSheet.header.horizontalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.24.elements.layout.pastedContentSheet.header.paddingX", inheriting: NativeComponentInspectionStyle.metric(24, "padding", theme.space.s16, theme))).catalogLayoutTarget("component.library.24.elements.layout.pastedContentSheet.header.paddingX")
        .padding(.vertical, theme.catalogLayoutMetric("component.library.24.elements.layout.pastedContentSheet.header.paddingY", inheriting: NativeComponentInspectionStyle.metric(24, "padding", theme.space.s12, theme))).catalogLayoutTarget("component.library.24.elements.layout.pastedContentSheet.header.paddingY")
    }
}
