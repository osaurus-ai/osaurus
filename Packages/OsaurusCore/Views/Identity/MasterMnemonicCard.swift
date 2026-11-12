//
//  MasterMnemonicCard.swift
//  osaurus
//
//  Renders the 24-word BIP39 master-key recovery phrase as a numbered grid
//  with copy / save / print actions. Reached only via Settings → Identity
//  → "View recovery phrase" now that onboarding doesn't gate users on a
//  write-it-down screen.
//

import AppKit
import SwiftUI

struct MasterMnemonicCard: View {
    @Environment(\.theme) private var theme

    let words: [String]

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            SettingsSectionHeader(title: "Your Recovery Code", caption: L("(24 words)"))

            wordGrid

            HStack(spacing: theme.space.s8) {
                SettingsButton(
                    .secondary,
                    copied ? "Copied" : "Copy phrase",
                    icon: copied ? "checkmark" : "doc.on.doc",
                    size: .compact,
                    action: copyPhrase
                )
                SettingsButton(.secondary, "Save as .txt", icon: "square.and.arrow.down", size: .compact, action: saveAsTextFile)
                SettingsButton(.secondary, "Print", icon: "printer", size: .compact, action: printPhrase)
                Spacer(minLength: 0)
            }
        }
        .padding(theme.space.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.inset)
    }

    private var wordGrid: some View {
        // Adaptive columns sized for an 8-letter BIP39 word plus its
        // index gutter. Reflows from 3x8 (narrow rail) through 4x6 to
        // 6x4 (wide container). Words use `.fixedSize(horizontal: true)`
        // and no `lineLimit` — silently truncating a recovery phrase
        // would be data loss.
        let columns = [GridItem(.adaptive(minimum: 110), spacing: theme.space.s10)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: theme.space.s8) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                wordCell(index: index + 1, word: word)
            }
        }
    }

    private func wordCell(index: Int, word: String) -> some View {
        HStack(spacing: theme.space.s6) {
            Text("\(index).")
                .font(SettingsFont.monoSmall)
                .foregroundColor(theme.text.tertiary)
                .frame(width: 22, alignment: .trailing)
                .monospacedDigit()
            Text(word)
                .font(SettingsFont.mono)
                .foregroundColor(theme.text.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, theme.space.s8)
        .padding(.vertical, theme.space.s6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.surface)
    }

    // MARK: - Actions

    private func copyPhrase() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(words.joined(separator: " "), forType: .string)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { copied = false }
        }
    }

    private func saveAsTextFile() {
        let panel = NSSavePanel()
        panel.title = L("Save Recovery Phrase")
        panel.nameFieldStringValue = "osaurus-recovery-phrase.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true

        Task { @MainActor in
            guard await panel.beginModal() == .OK, let url = panel.url else { return }
            let content = renderPlainText()
            try? content.data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }

    private func printPhrase() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 468, height: 600))
        textView.string = renderPlainText()
        textView.font = theme.nsFont(.code)

        let printOp = NSPrintOperation(view: textView)
        printOp.printInfo.isHorizontallyCentered = true
        printOp.printInfo.isVerticallyCentered = false
        printOp.printInfo.topMargin = 72
        printOp.printInfo.leftMargin = 72
        printOp.runModal(for: NSApp.keyWindow ?? NSWindow(), delegate: nil, didRun: nil, contextInfo: nil)
    }

    private func renderPlainText() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var lines: [String] = []
        lines.append("OSAURUS MASTER RECOVERY PHRASE")
        lines.append("BIP39 — 24 words")
        lines.append("Generated: \(formatter.string(from: Date()))")
        lines.append("")
        for (i, word) in words.enumerated() {
            lines.append(String(format: "%2d. %@", i + 1, word))
        }
        lines.append("")
        lines.append("Keep this phrase secret. Anyone with these 24 words can take over")
        lines.append("your Osaurus identity. Osaurus cannot recover this phrase for you.")
        return lines.joined(separator: "\n") + "\n"
    }
}
