//
//  CodeBlockMasker.swift
//  osaurus / PrivacyFilter
//
//  Masks fenced code blocks (``` ... ```) and inline code (`code`)
//  before handing text to the classifier so we don't flag variable
//  names, keywords, or identifiers as people-names. After detection,
//  the matching `restoreRange` translates classifier hits back to
//  the original input so we can highlight the right characters.
//
//  Implementation note: the masker replaces a code span with the same
//  number of UTF-16 spaces. Equal-length replacement keeps every
//  `String.Index` valid across `original ↔ masked`, which is the only
//  reason `restoreRange` can return the same indices unchanged when
//  the span lies outside any masked region.
//

import Foundation

public enum CodeBlockMasker {
    /// The result of a masking pass.
    public struct MaskOutput {
        public let masked: String

        /// Translate a detected range (in `masked`) back into the
        /// original input. Returns `nil` when the range lies entirely
        /// inside a masked region — those detections should be
        /// discarded because they came from text the user did not
        /// write (or wrote as code).
        public let restoreRange: (Range<String.Index>) -> Range<String.Index>?
    }

    /// Mask fenced and inline code spans in `text` and return a
    /// `MaskOutput`. Calling `restoreRange` on a range whose start or
    /// end falls inside a masked span returns `nil`; otherwise the
    /// range is passed through (we keep the masked length equal to
    /// the original length so indices stay aligned).
    public static func mask(_ text: String) -> MaskOutput {
        let spans = findCodeSpans(in: text)
        if spans.isEmpty {
            return MaskOutput(masked: text) { range in range }
        }

        // Build the masked string by replacing each code span with
        // an equal-length run of spaces. Equal-length keeps every
        // string index valid in both strings.
        var masked = text
        for span in spans.reversed() {
            let count = text.distance(from: span.lowerBound, to: span.upperBound)
            let filler = String(repeating: " ", count: count)
            masked.replaceSubrange(span, with: filler)
        }

        // Capture the spans as UTF-16 offsets so the closure doesn't
        // hold a reference to the original `String.Index` values
        // (which are valid in `text` and `masked` but become awkward
        // to compare across instances when callers pass a range from
        // a copy).
        let utf16Spans: [Range<Int>] = spans.map { span in
            let start = text.utf16.distance(
                from: text.utf16.startIndex,
                to: span.lowerBound.samePosition(in: text.utf16)!
            )
            let end = text.utf16.distance(
                from: text.utf16.startIndex,
                to: span.upperBound.samePosition(in: text.utf16)!
            )
            return start ..< end
        }
        let originalCopy = text

        let restore: (Range<String.Index>) -> Range<String.Index>? = { range in
            // Treat indices as UTF-16 positions in the original
            // string. Discard hits that overlap any masked span.
            let utf16 = originalCopy.utf16
            guard let startU16 = range.lowerBound.samePosition(in: utf16),
                let endU16 = range.upperBound.samePosition(in: utf16)
            else {
                return nil
            }
            let start = utf16.distance(from: utf16.startIndex, to: startU16)
            let end = utf16.distance(from: utf16.startIndex, to: endU16)
            for span in utf16Spans {
                let overlaps = !(end <= span.lowerBound || start >= span.upperBound)
                if overlaps { return nil }
            }
            return range
        }

        return MaskOutput(masked: masked, restoreRange: restore)
    }

    // MARK: - Span scanner

    /// Returns ranges of all fenced and inline code spans in scan order.
    /// Fenced spans match `` ``` `` openers (optionally followed by a
    /// language identifier) and close on the next `` ``` `` at the
    /// start of a line. Inline spans match a single `` ` `` opener and
    /// close at the next `` ` `` on the same line. Unbalanced fences
    /// or inline backticks consume the rest of the input / line.
    private static func findCodeSpans(in text: String) -> [Range<String.Index>] {
        var spans: [Range<String.Index>] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            // Fenced (```): match a triple backtick anywhere — Markdown
            // typically requires line-start but loosely matching here
            // is safe because we discard hits inside the masked span.
            if matchesTripleBacktick(text, at: idx) {
                let openerStart = idx
                var cursor = text.index(idx, offsetBy: 3)
                // Skip optional language identifier line.
                if let newline = text.range(of: "\n", range: cursor ..< text.endIndex) {
                    cursor = newline.upperBound
                } else {
                    spans.append(openerStart ..< text.endIndex)
                    break
                }
                // Find the closing ```.
                if let close = findCloseTripleBacktick(text, from: cursor) {
                    spans.append(openerStart ..< close)
                    idx = close
                } else {
                    spans.append(openerStart ..< text.endIndex)
                    break
                }
                continue
            }
            // Inline (`...`).
            if text[idx] == "`" {
                let openerStart = idx
                let afterOpener = text.index(after: idx)
                // Find the close on the same line (until newline or end).
                var scan = afterOpener
                var closed = false
                while scan < text.endIndex {
                    let ch = text[scan]
                    if ch == "\n" { break }
                    if ch == "`" {
                        let closeEnd = text.index(after: scan)
                        spans.append(openerStart ..< closeEnd)
                        idx = closeEnd
                        closed = true
                        break
                    }
                    scan = text.index(after: scan)
                }
                if !closed {
                    // Unbalanced ` — consume to next newline so we don't
                    // accidentally swallow the entire rest of the text.
                    spans.append(openerStart ..< scan)
                    idx = scan
                }
                continue
            }
            idx = text.index(after: idx)
        }
        return spans
    }

    private static func matchesTripleBacktick(_ text: String, at idx: String.Index) -> Bool {
        guard text.distance(from: idx, to: text.endIndex) >= 3 else { return false }
        let end = text.index(idx, offsetBy: 3)
        return text[idx ..< end] == "```"
    }

    /// Find the next `` ``` `` token after `cursor`, accepting it
    /// either at the start of a line or after whitespace so we tolerate
    /// chat clients that don't strictly follow CommonMark line rules.
    private static func findCloseTripleBacktick(_ text: String, from cursor: String.Index) -> String.Index? {
        var idx = cursor
        while idx < text.endIndex {
            if matchesTripleBacktick(text, at: idx) {
                return text.index(idx, offsetBy: 3)
            }
            idx = text.index(after: idx)
        }
        return nil
    }
}
