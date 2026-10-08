//
//  StreamingMarkdownBalancer.swift
//  osaurus
//
//  Hides raw markdown delimiters from `parseBlocks` while a chunk is mid-flight

import Foundation

enum StreamingMarkdownBalancer {

    /// Returns text with the trailing in-progress paragraph rebalanced for streaming.
    /// Fenced code regions are left untouched. Earlier paragraphs are also untouched,
    /// only the last paragraph after the final fence is rebalanced, because finished
    /// paragraphs already have their final form.
    static func balance(_ text: String) -> String {
        guard let tailStart = trailingProseStart(in: text) else { return text }
        let prefix = String(text[..<tailStart])
        return prefix + balanceTrailingParagraph(String(text[tailStart...]))
    }

    /// Start of the prose after the last closed fence, or nil when the text ends
    /// inside an open fence (its content is code in progress, leave it alone).
    /// Uses the same fence rules as `parseBlocks`, so a longer fence holding
    /// shorter fence lines stays one code region.
    private static func trailingProseStart(in text: String) -> String.Index? {
        var openFence: CodeFence?
        var tailStart = text.startIndex
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[lineStart ..< lineEnd]
            let next = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
            if let fence = openFence {
                if fence.isClosedBy(line) {
                    openFence = nil
                    tailStart = next
                }
            } else if let fence = parseCodeFenceOpener(line) {
                openFence = fence
            }
            lineStart = next
        }
        return openFence == nil ? tailStart : nil
    }

    /// Rebalance only the last paragraph (after the final blank line). Earlier paragraphs
    /// are committed and shouldn't be touched.
    private static func balanceTrailingParagraph(_ segment: String) -> String {
        guard let paragraphRange = lastParagraphRange(in: segment) else { return segment }
        let prefix = String(segment[..<paragraphRange.lowerBound])
        let lastPara = String(segment[paragraphRange])
        return prefix + balanceParagraph(lastPara)
    }

    /// Find the range of the last paragraph in `s` (everything after the last `\n\n`).
    private static func lastParagraphRange(in s: String) -> Range<String.Index>? {
        if s.isEmpty { return nil }
        if let r = s.range(of: "\n\n", options: .backwards) {
            return r.upperBound ..< s.endIndex
        }
        return s.startIndex ..< s.endIndex
    }

    private static func balanceParagraph(_ paragraph: String) -> String {
        // drop any trailing line that is just a half-streamed list marker ("-", "*",
        // "+", "1.", "2)", possibly followed by whitespace but no content). parseBlocks
        // requires `<marker><space><content>` to recognize a list item, so without this
        // a bare "-" renders as literal text until the next chunk arrives.
        var body = stripIncompleteTrailingListMarkerLine(paragraph)

        // Preserve trailing whitespace so virtual closers land before it.
        let trailingWS = body.suffix(while: { $0 == " " || $0 == "\t" || $0 == "\n" })
        body = String(body.dropLast(trailingWS.count))

        // 1. strip a freshly-opened trailing emphasis marker that would otherwise be
        //    balanced into something visibly wrong:
        //    - "Foo **" → drop "**" (next chunk will provide content + closer)
        //    - "Foo *" → drop "*" (could be start of "**", or italic with no content)
        //    - "Foo `" → drop "`" (could be start of fence ``` or inline code with no content)
        body = stripFreshlyOpenedTrailingMarker(body)

        // re-run the list-marker strip: removing a freshly-opened "**"/"*"/"`" can leave
        // a now-bare list marker line (e.g. "- **" → "- ") which parseBlocks would render
        // as a literal "-" paragraph until the next chunk delivers actual content
        body = stripIncompleteTrailingListMarkerLine(body)

        // 2. close unbalanced inline code spans first so bold inside a code span
        //    isn't mistakenly balanced
        if hasOddSingleBacktickCount(body) {
            body += "`"
        }

        // 3. close unbalanced bold (`**`). We count `**` occurrences naively. the
        //    rare case of literal `**` inside an inline code span produces at worst
        //    one extra virtual closer — invisible in normal LLM output
        if hasOddDoubleAsteriskCount(body) {
            body += "**"
        }

        return body + String(trailingWS)
    }

    /// If the last non-blank line is just a list marker with no content yet, strip it
    /// (along with the preceding newline). Returns input unchanged otherwise.
    private static func stripIncompleteTrailingListMarkerLine(_ s: String) -> String {
        // Walk back over trailing whitespace to find the end of the last non-blank line.
        var endIdx = s.endIndex
        while endIdx > s.startIndex {
            let prev = s.index(before: endIdx)
            let ch = s[prev]
            if ch == " " || ch == "\t" || ch == "\n" {
                endIdx = prev
            } else {
                break
            }
        }
        if endIdx == s.startIndex { return s }

        let lineStart: String.Index
        if let nl = s.range(of: "\n", options: .backwards, range: s.startIndex ..< endIdx) {
            lineStart = nl.upperBound
        } else {
            lineStart = s.startIndex
        }
        let lastLine = String(s[lineStart ..< endIdx]).trimmingCharacters(in: .whitespaces)
        guard isIncompleteListMarker(lastLine) else { return s }

        let dropFrom = lineStart > s.startIndex ? s.index(before: lineStart) : s.startIndex
        return String(s[..<dropFrom])
    }

    private static func isIncompleteListMarker(_ trimmed: String) -> Bool {
        if trimmed == "-" || trimmed == "*" || trimmed == "+" { return true }
        // Ordered: digits followed by `.` or `)`, e.g. `1.`, `12)`.
        if trimmed.count >= 2,
            let last = trimmed.last,
            (last == "." || last == ")"),
            trimmed.dropLast().allSatisfy({ $0.isNumber })
        {
            return true
        }
        return false
    }

    private static func stripFreshlyOpenedTrailingMarker(_ s: String) -> String {
        guard let last = s.last else { return s }
        // Only strip if the marker is preceded by whitespace, start-of-string, or
        // another opener — i.e. "no content yet" — so we don't eat into real content.
        if last == "*" || last == "`" {
            // Walk back over a run of `*` or `` ` ``
            var idx = s.endIndex
            var runStart = s.endIndex
            while idx > s.startIndex {
                let prev = s.index(before: idx)
                if s[prev] == last {
                    runStart = prev
                    idx = prev
                } else {
                    break
                }
            }
            // Run length: 1 or 2 strip; 3+ is probably a fence and we don't touch it.
            let runLength = s.distance(from: runStart, to: s.endIndex)
            guard runLength == 1 || runLength == 2 else { return s }

            // What precedes the run? If it's whitespace or start-of-string, this is
            // a "freshly opened" marker with no content — strip it.
            if runStart == s.startIndex {
                return String(s[..<runStart])
            }
            let beforeRun = s[s.index(before: runStart)]
            if beforeRun.isWhitespace || beforeRun == "\n" {
                return String(s[..<runStart])
            }
        }
        return s
    }

    /// Counts `**` occurrences (non-overlapping). Odd → unbalanced bold.
    private static func hasOddDoubleAsteriskCount(_ s: String) -> Bool {
        var count = 0
        var search = s.startIndex
        while let r = s.range(of: "**", range: search ..< s.endIndex) {
            count += 1
            search = r.upperBound
        }
        return count % 2 == 1
    }

    /// Counts single backticks (after stripping all `**`-like content is unnecessary
    /// since `*` and `` ` `` don't interact). Odd → unbalanced inline code.
    private static func hasOddSingleBacktickCount(_ s: String) -> Bool {
        var count = 0
        for ch in s where ch == "`" {
            count += 1
        }
        return count % 2 == 1
    }
}

private extension String {
    func suffix(while predicate: (Character) -> Bool) -> Substring {
        var idx = endIndex
        while idx > startIndex {
            let prev = index(before: idx)
            if !predicate(self[prev]) { break }
            idx = prev
        }
        return self[idx ..< endIndex]
    }
}
