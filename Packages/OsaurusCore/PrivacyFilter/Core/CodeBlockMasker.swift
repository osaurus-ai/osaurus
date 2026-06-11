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
//  Implementation note: the masker replaces a code span with a run
//  of spaces matching the span's UTF-16 length, so every UTF-16
//  offset means the same thing in `original` and `masked`.
//  `restoreRange` relies on that to translate a detection's offsets
//  in the masked string back into indices in the original. Indices
//  themselves are NOT interchangeable between the two strings once a
//  masked span contains non-ASCII characters (their UTF-8 layouts
//  diverge), which is why the translation goes through offsets.
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
    /// `MaskOutput`. Calling `restoreRange` on a range that overlaps
    /// a masked span returns `nil`; otherwise the range is translated
    /// into the equivalent indices in the original string (UTF-16
    /// offsets are preserved by the masking pass, so the translation
    /// is a straight offset lookup).
    public static func mask(_ text: String) -> MaskOutput {
        // Hot-path bail: no backticks AND no indented-block hint =>
        // no spans to mask. `findCodeSpans` would still walk every
        // character looking for fences, so skipping it shaves a
        // measurable chunk off the per-segment cost on the common
        // case (plain prose). We can't fast-return for the
        // "backticks-only" case because indented blocks could
        // still apply, but the indented-block scanner has its own
        // cheap precheck and is no-op there.
        if !text.contains("`")
            && !text.contains("\n    ")
            && !text.contains("\n\t")
            && !hasIndentedFirstLine(text)
        {
            return MaskOutput(masked: text) { range in range }
        }
        let spans = findCodeSpans(in: text)
        if spans.isEmpty {
            return MaskOutput(masked: text) { range in range }
        }

        // The fenced/inline pass and the indented pass can emit spans
        // that partially overlap (an inline span inside an indented
        // line, for example). Merge them before masking so each
        // region is rewritten exactly once — replacing overlapping
        // ranges independently invalidates the later range's indices.
        var merged: [Range<String.Index>] = []
        merged.reserveCapacity(spans.count)
        for span in spans {
            if let last = merged.last, span.lowerBound < last.upperBound {
                if span.upperBound > last.upperBound {
                    merged[merged.count - 1] = last.lowerBound ..< span.upperBound
                }
            } else {
                merged.append(span)
            }
        }

        // Build the masked string in one forward pass, replacing each
        // code span with a run of spaces matching the span's UTF-16
        // length so UTF-16 offsets stay identical in both strings.
        var masked = ""
        masked.reserveCapacity(text.count)
        var cursor = text.startIndex
        for span in merged {
            masked += text[cursor ..< span.lowerBound]
            let count = text.utf16.distance(from: span.lowerBound, to: span.upperBound)
            masked += String(repeating: " ", count: count)
            cursor = span.upperBound
        }
        masked += text[cursor...]

        // Capture the spans as UTF-16 offsets so the closure doesn't
        // hold `String.Index` values that are only meaningful in one
        // of the two strings.
        let utf16Spans: [Range<Int>] = merged.map { span in
            let start = text.utf16.distance(from: text.utf16.startIndex, to: span.lowerBound)
            let end = text.utf16.distance(from: text.utf16.startIndex, to: span.upperBound)
            return start ..< end
        }
        let originalCopy = text
        let maskedCopy = masked

        let restore: (Range<String.Index>) -> Range<String.Index>? = { range in
            // The range was produced against the masked string.
            // Convert it to UTF-16 offsets there, discard hits that
            // overlap any masked span, then rebuild the equivalent
            // indices in the original string.
            let maskedUtf16 = maskedCopy.utf16
            guard let startU16 = range.lowerBound.samePosition(in: maskedUtf16),
                let endU16 = range.upperBound.samePosition(in: maskedUtf16)
            else {
                return nil
            }
            let start = maskedUtf16.distance(from: maskedUtf16.startIndex, to: startU16)
            let end = maskedUtf16.distance(from: maskedUtf16.startIndex, to: endU16)
            for span in utf16Spans {
                let overlaps = !(end <= span.lowerBound || start >= span.upperBound)
                if overlaps { return nil }
            }
            let utf16 = originalCopy.utf16
            guard start <= end, end <= utf16.count,
                let lower = utf16.index(
                    utf16.startIndex,
                    offsetBy: start,
                    limitedBy: utf16.endIndex
                )?.samePosition(in: originalCopy),
                let upper = utf16.index(
                    utf16.startIndex,
                    offsetBy: end,
                    limitedBy: utf16.endIndex
                )?.samePosition(in: originalCopy)
            else {
                return nil
            }
            return lower ..< upper
        }

        return MaskOutput(masked: masked, restoreRange: restore)
    }

    // MARK: - Span scanner

    /// Returns ranges of all fenced, inline, and indented (4-space /
    /// tab) code spans in scan order. Spans from the indented-block
    /// pass run AFTER the fenced/inline pass and skip ranges that
    /// already overlap an earlier span — fenced blocks naturally
    /// contain whitespace-indented lines, but the fenced span already
    /// covers them.
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

        appendIndentedCodeSpans(in: text, into: &spans)
        // Re-sort because the indented pass appends spans at the end
        // of the run, not in document order with the fenced/inline
        // pass.
        spans.sort { $0.lowerBound < $1.lowerBound }
        return spans
    }

    /// Indented code blocks per CommonMark §4.4: a paragraph-level
    /// block whose lines begin with 4 spaces or one tab and are
    /// preceded by a blank line (or start of document). We use a
    /// looser heuristic suited to PII masking: any run of one or
    /// more consecutive lines starting with 4+ leading spaces (or
    /// a tab) gets masked, as long as the first such line wasn't
    /// already covered by an earlier (fenced/inline) span. Over-
    /// masking is fine — we'd rather miss PII inside what might be
    /// formatted code than misclassify an identifier as a name.
    private static func appendIndentedCodeSpans(
        in text: String,
        into spans: inout [Range<String.Index>]
    ) {
        // Cheap precheck: if the text has no leading whitespace
        // followed by content on any line, no work to do.
        guard text.contains("\n    ") || text.contains("\n\t") || hasIndentedFirstLine(text) else {
            return
        }
        let fencedRanges = spans
        var idx = text.startIndex
        var atLineStart = true
        var prevLineBlank = true
        while idx < text.endIndex {
            if atLineStart {
                let isIndented = lineStartsIndented(text, at: idx)
                if isIndented, prevLineBlank, !inAnyRange(idx, ranges: fencedRanges) {
                    // Collect the contiguous indented run.
                    var lineStart = idx
                    let runStart = idx
                    var lastLineEnd = idx
                    while lineStart < text.endIndex {
                        if !lineStartsIndented(text, at: lineStart) { break }
                        guard let newline = text.range(of: "\n", range: lineStart ..< text.endIndex) else {
                            lastLineEnd = text.endIndex
                            lineStart = text.endIndex
                            break
                        }
                        lastLineEnd = newline.upperBound
                        lineStart = newline.upperBound
                        if lineStart == text.endIndex { break }
                    }
                    spans.append(runStart ..< lastLineEnd)
                    idx = lastLineEnd
                    atLineStart = true
                    prevLineBlank = false
                    continue
                }
            }
            let ch = text[idx]
            if ch == "\n" {
                // Determine if THIS line (before the newline we're
                // about to step over) was blank. We track that by
                // checking the prior character.
                prevLineBlank = (idx == text.startIndex) || text[text.index(before: idx)] == "\n"
                atLineStart = true
            } else {
                atLineStart = false
            }
            idx = text.index(after: idx)
        }
    }

    private static func hasIndentedFirstLine(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return first == "\t" || (text.hasPrefix("    ") && !text.hasPrefix("     "))  // 4 leading spaces, not 5+
            || text.hasPrefix("    ")
    }

    private static func lineStartsIndented(_ text: String, at idx: String.Index) -> Bool {
        guard idx < text.endIndex else { return false }
        if text[idx] == "\t" { return true }
        // Require at least 4 leading spaces and at least one
        // non-whitespace char on the line.
        let remaining = text.distance(from: idx, to: text.endIndex)
        guard remaining >= 4 else { return false }
        let fourEnd = text.index(idx, offsetBy: 4)
        for ch in text[idx ..< fourEnd] where ch != " " { return false }
        // Skip the rest of the leading spaces, then ensure the
        // remainder of the line is non-empty (otherwise it's a
        // blank line with trailing whitespace, not code).
        var scan = fourEnd
        while scan < text.endIndex, text[scan] == " " {
            scan = text.index(after: scan)
        }
        if scan >= text.endIndex { return false }
        return text[scan] != "\n"
    }

    private static func inAnyRange(_ idx: String.Index, ranges: [Range<String.Index>]) -> Bool {
        for r in ranges where r.contains(idx) { return true }
        return false
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
