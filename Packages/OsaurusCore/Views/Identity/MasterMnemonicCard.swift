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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("YOUR RECOVERY CODE", bundle: .module)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
                    .tracking(1)

                Text(localized: "(24 words)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)

                Spacer(minLength: 0)
            }

            wordGrid

            HStack(spacing: 8) {
                Button(action: copyPhrase) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                        Text(copied ? "Copied" : "Copy phrase")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(copied ? theme.successColor : theme.primaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(theme.tertiaryBackground)
                    )
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: saveAsTextFile) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 11, weight: .medium))
                        Text("Save as .txt", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(theme.primaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(theme.tertiaryBackground)
                    )
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: printPhrase) {
                    HStack(spacing: 4) {
                        Image(systemName: "printer")
                            .font(.system(size: 11, weight: .medium))
                        Text("Print", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(theme.primaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(theme.tertiaryBackground)
                    )
                }
                .buttonStyle(PlainButtonStyle())

                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.tertiaryBackground.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private var wordGrid: some View {
        // Adaptive columns sized for an 8-letter BIP39 word plus its
        // index gutter. Reflows from 3x8 (narrow rail) through 4x6 to
        // 6x4 (wide container). Words use `.fixedSize(horizontal: true)`
        // and no `lineLimit` — silently truncating a recovery phrase
        // would be data loss.
        let columns = [GridItem(.adaptive(minimum: 110), spacing: 10)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                wordCell(index: index + 1, word: word)
            }
        }
    }

    private func wordCell(index: Int, word: String) -> some View {
        HStack(spacing: 6) {
            Text("\(index).")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 22, alignment: .trailing)
                .monospacedDigit()
            Text(word)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.cardBackground.opacity(0.6))
        )
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
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

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
