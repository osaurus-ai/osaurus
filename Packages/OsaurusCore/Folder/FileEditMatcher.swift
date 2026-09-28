//
//  FileEditMatcher.swift
//  osaurus
//
//  One matcher for every text `file_edit` route (host folder and sandbox
//  bridge). Locates `old_string` with a tolerance cascade — exact, then
//  whitespace-normalized lines, then ignoring blank lines, then with unicode
//  punctuation folded — and applies `new_string` without rewriting any byte
//  the edit didn't ask to change: lines a relaxed match kept unchanged are
//  copied from the FILE (never from the model), the file's line endings,
//  BOM and trailing-newline state are preserved, and inserted lines inherit
//  the matched block's indentation. A relaxed match is only applied when it
//  is unique (or `replace_all` is set), and the strategy that fired is
//  reported so the model — and eval audits — can see when its `old_string`
//  drifted from the file.
//
//  Why not exact-only: observed live, models copy `file_read` output with
//  collapsed blank lines, tabs turned into spaces, or curly quotes turned
//  straight, then re-issue the identical failing call until the iteration
//  budget runs out. Why not fuzzier: Codex's `apply_patch` fuzzy locator
//  silently overwrote context-line indentation with the model's version
//  (openai/codex#30505); the byte-preservation rule here exists to make
//  that class of corruption impossible.
//

import Foundation

enum FileEditMatcher {
    enum Strategy: String, CaseIterable, Sendable {
        case exact
        case whitespaceNormalized = "whitespace_normalized"
        case blankLinesCollapsed = "blank_lines_collapsed"
        case unicodeNormalized = "unicode_normalized"

        var isRelaxed: Bool { self != .exact }

        /// One-line description for warnings and errors.
        var explanation: String {
            switch self {
            case .exact:
                return "exact text"
            case .whitespaceNormalized:
                return "whole lines compared with leading/trailing whitespace trimmed and inner whitespace runs collapsed"
            case .blankLinesCollapsed:
                return "whole lines compared ignoring whitespace differences and blank lines"
            case .unicodeNormalized:
                return
                    "whole lines compared ignoring whitespace differences, blank lines, and unicode punctuation variants (curly quotes, dashes, non-breaking spaces)"
            }
        }
    }

    struct Applied: Sendable {
        let content: String
        let replacements: Int
        let strategy: Strategy
        /// 1-based inclusive line ranges that were replaced, in file order
        /// (numbered against the file BEFORE the edit).
        let matchedLines: [ClosedRange<Int>]
        /// The file's verbatim text at the first match when a relaxed
        /// strategy fired (nil for exact matches).
        let matchedText: String?
    }

    enum Outcome: Sendable {
        case applied(Applied)
        /// No strategy found the text.
        case notFound
        /// The first strategy that found anything found several and
        /// `replaceAll` was false.
        case ambiguous(count: Int, strategy: Strategy)
        /// `old_string == new_string`: nothing to do.
        case noOp
    }

    // MARK: - Entry point

    /// Locate and replace `oldString` in `content`. Never returns content
    /// that differs from the input outside the matched region(s).
    static func apply(
        oldString: String,
        newString: String,
        to content: String,
        replaceAll: Bool
    ) -> Outcome {
        guard !oldString.isEmpty else { return .notFound }
        guard oldString != newString else { return .noOp }

        // 1. Exact substring — zero overhead when the model is precise.
        let exactRanges = content.literalRanges(of: oldString)
        if !exactRanges.isEmpty {
            if exactRanges.count > 1, !replaceAll {
                return .ambiguous(count: exactRanges.count, strategy: .exact)
            }
            var result = content
            for range in exactRanges.reversed() {
                result.replaceSubrange(range, with: newString)
            }
            let lines = exactRanges.map { lineSpan(of: $0, in: content) }
            return .applied(
                Applied(
                    content: result,
                    replacements: exactRanges.count,
                    strategy: .exact,
                    matchedLines: lines,
                    matchedText: nil
                )
            )
        }

        // 2–4. Line-based relaxed strategies.
        let file = Lines(content)
        let oldLines = splitEditText(oldString)
        let newLines = splitEditText(newString)
        guard oldLines.contains(where: { !normalizeWhitespace($0).isEmpty }) else {
            // An all-whitespace old_string can only ever be an exact match.
            return .notFound
        }

        for strategy in [Strategy.whitespaceNormalized, .blankLinesCollapsed, .unicodeNormalized] {
            let matches = relaxedMatches(strategy: strategy, oldLines: oldLines, file: file)
            guard !matches.isEmpty else { continue }
            if matches.count > 1, !replaceAll {
                return .ambiguous(count: matches.count, strategy: strategy)
            }
            let firstText = file.text(ofLines: matches[0].fileRange)
            var edited = file
            for match in matches.reversed() {
                edited.replace(match: match, oldLines: oldLines, newLines: newLines, strategy: strategy)
            }
            return .applied(
                Applied(
                    content: edited.joined(),
                    replacements: matches.count,
                    strategy: strategy,
                    matchedLines: matches.map { ($0.fileRange.lowerBound + 1)...($0.fileRange.upperBound) },
                    matchedText: firstText
                )
            )
        }
        return .notFound
    }

    // MARK: - Line model

    /// A text file as lines plus each line's own terminator, so an edit can
    /// rebuild the file byte-for-byte outside the touched region.
    struct Lines {
        /// U+FEFF when the file starts with a byte-order mark, else empty.
        var bom: String
        var bodies: [String]
        /// One entry per body: `"\n"`, `"\r\n"`, `"\r"`, or `""` for a final
        /// line without a trailing newline.
        var terminators: [String]

        init(_ text: String) {
            var scalars = text.unicodeScalars[...]
            if scalars.first == "\u{FEFF}" {
                bom = "\u{FEFF}"
                scalars = scalars.dropFirst()
            } else {
                bom = ""
            }
            var bodies: [String] = []
            var terminators: [String] = []
            var current = String.UnicodeScalarView()
            var index = scalars.startIndex
            while index < scalars.endIndex {
                let scalar = scalars[index]
                if scalar == "\n" {
                    bodies.append(String(current))
                    terminators.append("\n")
                    current = String.UnicodeScalarView()
                } else if scalar == "\r" {
                    let next = scalars.index(after: index)
                    if next < scalars.endIndex, scalars[next] == "\n" {
                        bodies.append(String(current))
                        terminators.append("\r\n")
                        index = next
                    } else {
                        bodies.append(String(current))
                        terminators.append("\r")
                    }
                    current = String.UnicodeScalarView()
                } else {
                    current.append(scalar)
                }
                index = scalars.index(after: index)
            }
            // The final segment (possibly empty when the file ends with a
            // newline) is a line with no terminator.
            bodies.append(String(current))
            terminators.append("")
            self.bodies = bodies
            self.terminators = terminators
        }

        var count: Int { bodies.count }

        /// The terminator most lines use — what inserted lines get.
        var dominantTerminator: String {
            var counts: [String: Int] = [:]
            for terminator in terminators where !terminator.isEmpty {
                counts[terminator, default: 0] += 1
            }
            return counts.max { lhs, rhs in
                lhs.value < rhs.value || (lhs.value == rhs.value && lhs.key > rhs.key)
            }?.key ?? "\n"
        }

        func joined() -> String {
            var out = bom
            for (body, terminator) in zip(bodies, terminators) {
                out += body
                out += terminator
            }
            return out
        }

        /// Verbatim text for a 0-based line range (terminators between lines
        /// only).
        func text(ofLines range: Range<Int>) -> String {
            var out = ""
            for index in range {
                out += bodies[index]
                if index + 1 < range.upperBound { out += terminators[index] }
            }
            return out
        }

        /// Replace the matched block with `newLines`, copying every line the
        /// edit kept unchanged from the file and re-indenting inserted lines
        /// to the block's indentation.
        mutating func replace(match: RelaxedMatch, oldLines: [String], newLines: [String], strategy: Strategy) {
            let normalize = strategy.normalizer
            let oldNorm = oldLines.map(normalize)
            let newNorm = newLines.map(normalize)

            // Pair unchanged lines between old and new (in order) so they
            // can be sourced from the file rather than the model.
            let difference = newNorm.difference(from: oldNorm)
            var removed = Set<Int>()
            var inserted = Set<Int>()
            for change in difference {
                switch change {
                case .remove(let offset, _, _): removed.insert(offset)
                case .insert(let offset, _, _): inserted.insert(offset)
                }
            }

            // Indentation of the block as the file has it vs as the model
            // wrote it; inserted lines are re-based onto the file's style.
            let mapper = IndentMapper(oldLines: oldLines, match: match, bodies: bodies)
            func reindented(_ line: String) -> String {
                if normalizeWhitespace(line).isEmpty { return "" }
                return mapper.map(line)
            }

            // Merge walk over old/new: kept lines and any file lines the
            // strategy skipped (blank lines) are emitted from the FILE;
            // only inserted lines come from the model.
            let range = match.fileRange
            var replacementBodies: [String] = []
            var fileCursor = range.lowerBound
            func emitFile(through fileIndex: Int) {
                while fileCursor <= fileIndex {
                    replacementBodies.append(bodies[fileCursor])
                    fileCursor += 1
                }
            }
            var oi = 0
            var ni = 0
            while oi < oldNorm.count || ni < newNorm.count {
                if oi < oldNorm.count, removed.contains(oi) {
                    if let fileIndex = match.oldToFile[oi] {
                        emitFile(through: fileIndex - 1)
                        fileCursor = fileIndex + 1
                    }
                    oi += 1
                } else if ni < newNorm.count, inserted.contains(ni) {
                    replacementBodies.append(reindented(newLines[ni]))
                    ni += 1
                } else if oi < oldNorm.count, ni < newNorm.count {
                    // Kept pair. A blank old line the strategy did not map
                    // emits nothing: the file's own blank lines arrive with
                    // the next mapped line.
                    if let fileIndex = match.oldToFile[oi] { emitFile(through: fileIndex) }
                    oi += 1
                    ni += 1
                } else {
                    // Defensive: the difference should pair the remainder.
                    break
                }
            }
            emitFile(through: range.upperBound - 1)

            let lastTerminator = terminators[range.upperBound - 1]
            let innerTerminator = terminators[range.lowerBound].isEmpty ? dominantTerminator : terminators[range.lowerBound]
            var replacementTerminators = Array(repeating: innerTerminator, count: replacementBodies.count)
            if !replacementTerminators.isEmpty {
                replacementTerminators[replacementTerminators.count - 1] = lastTerminator
            }

            bodies.replaceSubrange(range, with: replacementBodies)
            terminators.replaceSubrange(range, with: replacementTerminators)

            // Deleting through the final line of a file that had no trailing
            // newline must not invent one.
            if replacementBodies.isEmpty, lastTerminator.isEmpty, range.lowerBound > 0, range.lowerBound - 1 < terminators.count {
                terminators[range.lowerBound - 1] = ""
            }
            if bodies.isEmpty {
                bodies = [""]
                terminators = [""]
            }
        }
    }

    struct RelaxedMatch {
        /// 0-based half-open range of file lines the block occupies.
        let fileRange: Range<Int>
        /// For each old_string line, the file line it corresponds to (nil
        /// for blank lines the strategy skipped).
        let oldToFile: [Int?]
    }

    /// Re-bases the indentation of lines the model INSERTED onto the file's
    /// indentation style, using the matched block as the Rosetta stone: the
    /// block's first line gives the base indent on each side, and the
    /// shallowest nested line inside the block gives one indent level on
    /// each side (so 4-space nesting in the request becomes one tab in a
    /// tab-indented file). Falls back to a plain base-indent swap when the
    /// block has no nested line to learn from.
    struct IndentMapper {
        let oldBase: String
        let fileBase: String
        /// Characters per nesting level in the model's text, and the string
        /// for one level in the file, when both could be inferred.
        let oldUnit: Int?
        let fileUnit: String?

        init(oldLines: [String], match: RelaxedMatch, bodies: [String]) {
            var pairs: [(old: String, file: String)] = []
            for (index, line) in oldLines.enumerated() {
                guard let fileIndex = match.oldToFile[index], !normalizeWhitespace(line).isEmpty else { continue }
                pairs.append((leadingWhitespace(line), leadingWhitespace(bodies[fileIndex])))
            }
            guard let first = pairs.first else {
                oldBase = ""
                fileBase = ""
                oldUnit = nil
                fileUnit = nil
                return
            }
            oldBase = first.old
            fileBase = first.file
            // Shallowest line nested deeper than the base on BOTH sides.
            let nested =
                pairs.dropFirst()
                .filter { $0.old.count > first.old.count && $0.file.count > first.file.count && $0.old.hasPrefix(first.old) && $0.file.hasPrefix(first.file) }
                .min { $0.old.count < $1.old.count }
            if let nested {
                oldUnit = nested.old.count - first.old.count
                fileUnit = String(nested.file.dropFirst(first.file.count))
            } else {
                oldUnit = nil
                fileUnit = nil
            }
        }

        func map(_ line: String) -> String {
            let indent = leadingWhitespace(line)
            guard indent.hasPrefix(oldBase) else { return line }
            let body = String(line.dropFirst(indent.count))
            let extra = indent.count - oldBase.count
            if extra > 0, let oldUnit, let fileUnit, oldUnit > 0, extra % oldUnit == 0 {
                let levels = extra / oldUnit
                return fileBase + String(repeating: fileUnit, count: levels) + body
            }
            return fileBase + String(indent.dropFirst(oldBase.count)) + body
        }
    }

    // MARK: - Relaxed matching

    static func relaxedMatches(strategy: Strategy, oldLines: [String], file: Lines) -> [RelaxedMatch] {
        let normalize = strategy.normalizer
        let oldNorm = oldLines.map(normalize)
        let fileNorm = file.bodies.map(normalize)

        switch strategy {
        case .exact:
            return []
        case .whitespaceNormalized:
            // Every old line (blank ones included) must line up.
            let k = oldNorm.count
            guard k > 0, k <= fileNorm.count else { return [] }
            var matches: [RelaxedMatch] = []
            var start = 0
            while start + k <= fileNorm.count {
                if fileNorm[start..<start + k].elementsEqual(oldNorm) {
                    matches.append(
                        RelaxedMatch(fileRange: start..<start + k, oldToFile: (0..<k).map { start + $0 })
                    )
                    start += k
                } else {
                    start += 1
                }
            }
            return matches
        case .blankLinesCollapsed, .unicodeNormalized:
            // Only non-blank lines participate; the match spans from the
            // first to the last matched file line (blank file lines inside
            // the block are kept as they are).
            let oldNonBlank = oldNorm.indices.filter { !oldNorm[$0].isEmpty }
            let fileNonBlank = fileNorm.indices.filter { !fileNorm[$0].isEmpty }
            let k = oldNonBlank.count
            guard k > 0, k <= fileNonBlank.count else { return [] }
            var matches: [RelaxedMatch] = []
            var start = 0
            while start + k <= fileNonBlank.count {
                var all = true
                for offset in 0..<k where fileNorm[fileNonBlank[start + offset]] != oldNorm[oldNonBlank[offset]] {
                    all = false
                    break
                }
                if all {
                    var oldToFile = [Int?](repeating: nil, count: oldNorm.count)
                    for offset in 0..<k { oldToFile[oldNonBlank[offset]] = fileNonBlank[start + offset] }
                    let first = fileNonBlank[start]
                    let last = fileNonBlank[start + k - 1]
                    matches.append(RelaxedMatch(fileRange: first..<(last + 1), oldToFile: oldToFile))
                    start += k
                } else {
                    start += 1
                }
            }
            return matches
        }
    }

    // MARK: - Normalization

    /// Trim, and collapse inner runs of spaces/tabs to one space.
    static func normalizeWhitespace(_ line: String) -> String {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" || $0 == "\u{3000}" })
            .joined(separator: " ")
    }

    /// `normalizeWhitespace` after folding unicode punctuation look-alikes
    /// to ASCII and canonically composing (NFC).
    static func normalizeUnicode(_ line: String) -> String {
        var folded = String.UnicodeScalarView()
        for scalar in line.precomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar {
            case "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}", "\u{2032}", "\u{00B4}", "\u{02BC}":
                folded.append("'")
            case "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{2033}", "\u{00AB}", "\u{00BB}":
                folded.append("\"")
            case "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}", "\u{2212}":
                folded.append("-")
            case "\u{2026}":
                folded.append(contentsOf: "...".unicodeScalars)
            case "\u{00A0}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}", "\u{2006}", "\u{2007}", "\u{2008}",
                "\u{2009}", "\u{200A}", "\u{202F}", "\u{205F}", "\u{3000}":
                folded.append(" ")
            case "\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{00AD}":
                continue
            default:
                folded.append(scalar)
            }
        }
        return normalizeWhitespace(String(folded))
    }

    static func leadingWhitespace(_ line: String) -> String {
        String(line.prefix(while: { $0 == " " || $0 == "\t" }))
    }

    /// Split `old_string` / `new_string` into lines the same way the file is
    /// split; a trailing newline does not produce an extra empty line (the
    /// model meant "through the end of that line", not "plus a blank one").
    static func splitEditText(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = Lines(text)
        if lines.bodies.count > 1, lines.bodies.last == "" {
            lines.bodies.removeLast()
            lines.terminators.removeLast()
        }
        return lines.bodies
    }

    /// 1-based inclusive line span of a character range in `content`.
    static func lineSpan(of range: Range<String.Index>, in content: String) -> ClosedRange<Int> {
        var start = 1
        var scalarCount = 0
        for scalar in content[..<range.lowerBound].unicodeScalars where scalar == "\n" { scalarCount += 1 }
        start += scalarCount
        var inner = 0
        for scalar in content[range].unicodeScalars where scalar == "\n" { inner += 1 }
        // A match that ends exactly on a newline doesn't reach the next line.
        if inner > 0, content[range].unicodeScalars.last == "\n" { inner -= 1 }
        return start...(start + inner)
    }
}

extension FileEditMatcher.Strategy {
    var normalizer: (String) -> String {
        switch self {
        case .exact:
            return { $0 }
        case .whitespaceNormalized, .blankLinesCollapsed:
            return FileEditMatcher.normalizeWhitespace
        case .unicodeNormalized:
            return FileEditMatcher.normalizeUnicode
        }
    }
}

extension String {
    /// Non-overlapping literal (byte-wise, no canonical equivalence) ranges
    /// of `needle`, left to right.
    func literalRanges(of needle: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var start = startIndex
        while start < endIndex,
            let range = self.range(of: needle, options: [.literal], range: start..<endIndex)
        {
            ranges.append(range)
            start = range.upperBound
        }
        return ranges
    }
}
