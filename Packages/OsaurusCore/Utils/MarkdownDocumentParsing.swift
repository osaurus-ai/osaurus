import Foundation

/// Model cards commonly wrap source paragraphs to a fixed column. Those
/// soft breaks should flow with the window width, rather than becoming
/// hard lines with paragraph spacing in the native text view. Chat keeps
/// its existing newline policy; fenced code, tables and math stay intact.
func parseDocumentBlocks(_ input: String) -> [MessageBlock] {
    parseBlocks(input, preserveBlockquoteHardBreaks: true).map { block in
        let kind: MessageBlock.Kind
        switch block.kind {
        case .paragraph(let text): kind = .paragraph(reflowDocumentParagraph(text))
        case .blockquote(let text): kind = .blockquote(reflowDocumentParagraph(text))
        default: kind = block.kind
        }
        return MessageBlock(index: block.index, kind: kind)
    }
}

private func reflowDocumentParagraph(_ text: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard let first = lines.first else { return text }
    var result = String(first)
    for index in lines.indices.dropFirst() {
        let previous = lines[index - 1]
        let next = lines[index]
        let backslashes = previous.reversed().prefix { $0 == "\\" }.count
        // Two trailing spaces or an unescaped backslash are deliberate
        // Markdown hard breaks. Empty quote lines separate paragraphs.
        let hardBreak = previous.hasSuffix("  ") || backslashes % 2 == 1
        if hardBreak || previous.trimmingCharacters(in: .whitespaces).isEmpty
            || next.trimmingCharacters(in: .whitespaces).isEmpty
        {
            result += "\n" + next
        } else {
            while result.last == " " || result.last == "\t" { result.removeLast() }
            result += " " + next.drop { $0 == " " || $0 == "\t" }
        }
    }
    return result
}
