//
//  MarkdownMessageView.swift
//  osaurus
//

import SwiftUI

struct MarkdownMessageView: View {
  let text: String
  let baseWidth: CGFloat

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(parseBlocks(text), id: \.id) { block in
        switch block.kind {
        case .paragraph(let md):
          if let attributed = try? AttributedString(markdown: md) {
            Text(attributed)
              .font(Typography.body(baseWidth))
          } else {
            Text(md)
              .font(Typography.body(baseWidth))
          }
        case .code(let code, let lang):
          CodeBlockView(code: code, language: lang, baseWidth: baseWidth)
        }
      }
    }
    .textSelection(.enabled)
  }
}

private struct MessageBlock {
  enum Kind {
    case paragraph(String)
    case code(String, String?)
  }
  let id = UUID()
  let kind: Kind
}

private func parseBlocks(_ input: String) -> [MessageBlock] {
  var blocks: [MessageBlock] = []
  var currentParagraphLines: [String] = []
  let lines = input.replacingOccurrences(of: "\r\n", with: "\n").split(
    separator: "\n", omittingEmptySubsequences: false)

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

extension String {
  fileprivate var nilIfEmpty: String? { self.isEmpty ? nil : self }
}
