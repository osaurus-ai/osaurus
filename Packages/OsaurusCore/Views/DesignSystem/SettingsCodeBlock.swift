//
//  SettingsCodeBlock.swift
//  osaurus
//
//  Multi-line snippets and one-time secrets: monospaced text in a code well
//  with a copy button. Single values use `SettingsValueRow(monospaced:)`.
//

import AppKit
import SwiftUI

struct SettingsCodeBlock: View {
    @Environment(\.theme) private var theme

    /// Rendered verbatim.
    let code: String
    var copyable: Bool = true
    /// Wraps long lines instead of truncating; snippets wrap, keys don't.
    var wraps: Bool = true
    var anchorId: String? = nil

    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: theme.settingsControlGap) {
            Text(verbatim: code)
                .font(SettingsFont.monoSmall)
                .foregroundColor(theme.text.primary)
                .textSelection(.enabled)
                .lineLimit(wraps ? nil : 1)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: wraps)
                .frame(maxWidth: .infinity, alignment: .leading)
            if copyable {
                SettingsIconButton(copied ? "checkmark" : "doc.on.doc", help: "Copy", size: .compact, action: copy)
            }
        }
        .padding(theme.settingsInlineGap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.code)
        .settingsLandingAnchor(anchorId)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}
