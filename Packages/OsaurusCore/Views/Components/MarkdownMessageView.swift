//
//  MarkdownMessageView.swift
//  osaurus
//
//  Renders markdown text with proper typography and code blocks
//

import SwiftUI

struct MarkdownMessageView: View {
    let text: String
    let baseWidth: CGFloat

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(parseBlocks(text), id: \.id) { block in
                switch block.kind {
                case .paragraph(let md):
                    paragraphView(md)
                case .code(let code, let lang):
                    CodeBlockView(code: code, language: lang, baseWidth: baseWidth)
                }
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func paragraphView(_ md: String) -> some View {
        if let attributed = try? AttributedString(
            markdown: md,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
                .font(Typography.body(baseWidth))
                .lineSpacing(4)
                .foregroundColor(theme.primaryText)
        } else {
            Text(md)
                .font(Typography.body(baseWidth))
                .lineSpacing(4)
                .foregroundColor(theme.primaryText)
        }
    }
}

// MARK: - Message Block

private struct MessageBlock: Identifiable {
    enum Kind {
        case paragraph(String)
        case code(String, String?)
    }
    let id = UUID()
    let kind: Kind
}

// MARK: - Parser

private func parseBlocks(_ input: String) -> [MessageBlock] {
    var blocks: [MessageBlock] = []
    var currentParagraphLines: [String] = []
    let lines = input.replacingOccurrences(of: "\r\n", with: "\n").split(
        separator: "\n",
        omittingEmptySubsequences: false
    )

    var i = 0
    while i < lines.count {
        let line = String(lines[i])
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            // fenced code block
            let fenceLine = line.trimmingCharacters(in: .whitespaces)
            let lang = String(fenceLine.dropFirst(3)).trimmingCharacters(in: .whitespaces).nilIfEmpty
            i += 1
            var codeLines: [String] = []
            while i < lines.count {
                let l = String(lines[i])
                if l.trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
                codeLines.append(l)
                i += 1
            }
            // flush paragraph before code
            if !currentParagraphLines.isEmpty {
                blocks.append(MessageBlock(kind: .paragraph(currentParagraphLines.joined(separator: "\n"))))
                currentParagraphLines.removeAll()
            }
            blocks.append(MessageBlock(kind: .code(codeLines.joined(separator: "\n"), lang)))
            // skip closing fence if present
            if i < lines.count { i += 1 }
            continue
        }

        // blank line separates paragraphs
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            if !currentParagraphLines.isEmpty {
                blocks.append(MessageBlock(kind: .paragraph(currentParagraphLines.joined(separator: "\n"))))
                currentParagraphLines.removeAll()
            }
            i += 1
            continue
        }

        currentParagraphLines.append(line)
        i += 1
    }

    if !currentParagraphLines.isEmpty {
        blocks.append(MessageBlock(kind: .paragraph(currentParagraphLines.joined(separator: "\n"))))
    }

    return blocks
}

// MARK: - String Extension

extension String {
    fileprivate var nilIfEmpty: String? { self.isEmpty ? nil : self }
}

// MARK: - Preview

#if DEBUG
    struct MarkdownMessageView_Previews: PreviewProvider {
        static let sampleMarkdown = """
            Here's a **bold** statement and some *italic* text.

            This is a code example:

            ```swift
            func greet(name: String) -> String {
                return "Hello, \\(name)!"
            }
            ```

            And here's a list:
            - First item
            - Second item
            - Third item
            """

        static var previews: some View {
            MarkdownMessageView(text: sampleMarkdown, baseWidth: 600)
                .padding()
                .frame(width: 600)
                .background(Color(hex: "0f0f10"))
        }
    }
#endif
