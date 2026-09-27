//
//  FileDiffEngine.swift
//  osaurus
//
//  Renders a recorded before/after pair as something a person can review:
//  a line diff for text, a structural diff for documents (Word paragraphs,
//  spreadsheet cells, slides, PDF pages), side-by-side images, or a size
//  summary for other binaries. Both sides come from the journal's object
//  store (exported to temp files, which also back "Open"), and documents
//  are parsed outside the journal actor.
//

import Foundation

struct FileDiffContent: Sendable, Equatable {
    enum Body: Sendable, Equatable {
        case text(FileDiff)
        /// Both sides are images; render `beforeURL` / `afterURL`.
        case image
        /// Opaque bytes: compare sizes, offer Open.
        case binary
        case directory
        case symlink(before: String?, after: String?)
        case unavailable(String)
    }

    let path: String
    let body: Body
    /// Plain caption for document comparisons ("Showing changed cells").
    let caption: String?
    let beforeURL: URL?
    let afterURL: URL?
    let beforeSize: Int64?
    let afterSize: Int64?
}

extension FileChangeJournal {
    /// A temp copy of a recorded file state (named like the original so
    /// document adapters and "Open" pick the right app). Nil when the
    /// state is not a stored file.
    func exportedURL(for state: FilePathState?, filename: String, label: String) -> URL? {
        guard let state, state.type == .file, let hash = state.objectHash, canRestore(state) else {
            return nil
        }
        return try? objects.exportTemp(hash: hash, filename: filename, label: label)
    }
}

enum FileDiffEngine {
    /// Largest side diffed as text / document; bigger files get a summary.
    static let maxDiffBytes: Int64 = 8 * 1024 * 1024
    static let contextLines = 3
    /// Changed lines shown before the diff is cut (context is folded first,
    /// so this budget is spent only on real changes).
    static let maxChangedLines = 600
    /// Myers edit-distance budget; past it the middle is shown as a plain
    /// remove/add block, which is still correct, just less minimal.
    static let maxEditDistance = 1000

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp",
    ]
    /// Document formats compared structurally, with the caption shown above
    /// the diff (as a catalog key; localized at use).
    static let documentExtensions: [String: String] = [
        "docx": "Showing changed paragraphs",
        "rtf": "Showing changed paragraphs",
        "odt": "Showing changed paragraphs",
        "xlsx": "Showing changed cells",
        "xlsm": "Showing changed cells",
        "pptx": "Showing changed slides",
        "pdf": "Showing changed pages",
    ]

    static func diff(
        key: FilePathKey,
        before: FilePathState?,
        after: FilePathState?,
        journal: FileChangeJournal = .shared
    ) async -> FileDiffContent {
        let path = key.displayPath
        let filename = key.filename
        let ext = (filename as NSString).pathExtension.lowercased()
        let beforeURL = await journal.exportedURL(for: before, filename: filename, label: "before")
        let afterURL = await journal.exportedURL(for: after, filename: filename, label: "after")

        func content(_ body: FileDiffContent.Body, caption: String? = nil) -> FileDiffContent {
            FileDiffContent(
                path: path, body: body, caption: caption, beforeURL: beforeURL,
                afterURL: afterURL, beforeSize: before?.type == .file ? before?.size : nil,
                afterSize: after?.type == .file ? after?.size : nil)
        }

        if before?.type == .directory || after?.type == .directory {
            if before?.type == .file || after?.type == .file {
                return content(.unavailable(L("Replaced a folder with a file (or the reverse).")))
            }
            return content(.directory)
        }
        if before?.type == .symlink || after?.type == .symlink {
            func target(_ s: FilePathState?) -> String? {
                guard let s, s.type == .symlink else { return nil }
                return String(s.signature.dropFirst("link:".count))
            }
            return content(.symlink(before: target(before), after: target(after)))
        }
        if [before, after].contains(where: { $0?.type == .file && $0?.isRestorable == false }) {
            return content(.unavailable(L("Too large to keep in history; only its size is known.")))
        }
        if (before != nil && beforeURL == nil) || (after != nil && afterURL == nil) {
            return content(.unavailable(L("This version is no longer in history.")))
        }
        if imageExtensions.contains(ext) { return content(.image) }
        let tooBig = [before?.size, after?.size].contains { ($0 ?? 0) > maxDiffBytes }
        if tooBig { return content(.binary) }

        if let caption = documentExtensions[ext] {
            let old = await documentLines(beforeURL)
            let new = await documentLines(afterURL)
            if let old, let new {
                return content(
                    .text(textDiff(old: old, new: new, path: path, existed: before != nil)),
                    caption: L(String.LocalizationValue(caption)))
            }
            return content(.binary)
        }

        let old = beforeURL.flatMap(textContent)
        let new = afterURL.flatMap(textContent)
        if (beforeURL == nil || old != nil) && (afterURL == nil || new != nil) {
            return content(.text(textDiff(old: old ?? "", new: new ?? "", path: path, existed: before != nil)))
        }
        return content(.binary)
    }

    // MARK: - Text

    /// UTF-8 text without NULs, or nil for binary content.
    static func textContent(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.prefix(8192).contains(0) { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The panel's own diff (the tool-result helper caps on total lines,
    /// which hid edits deep in long files). Lines are hashed, common
    /// prefix/suffix trimmed, the middle run through Myers with a budget,
    /// unchanged runs folded to "N unchanged lines" and only then is the
    /// change budget applied.
    static func textDiff(old: String, new: String, path: String, existed: Bool) -> FileDiff {
        let oldLines = splitLines(old)
        let newLines = splitLines(new)
        let ops = lineDiff(oldLines, newLines)
        let (lines, truncated) = collapse(ops, old: oldLines, new: newLines)
        var added = 0
        var removed = 0
        for op in ops {
            switch op {
            case .insert: added += 1
            case .delete: removed += 1
            case .equal: break
            }
        }
        var raw = ["--- \(path) (\(existed ? "before" : "before (new file)"))", "+++ \(path) (after)"]
        raw.reserveCapacity(lines.count + 2)
        for line in lines {
            switch line.kind {
            case .added: raw.append("+" + line.text)
            case .removed: raw.append("-" + line.text)
            case .context: raw.append(" " + line.text)
            case .meta: raw.append("@@ " + line.text + " @@")
            }
        }
        return FileDiff(
            path: path, language: FileDiff.language(forPath: path), lines: lines,
            addedCount: added, removedCount: removed, isPreview: false, truncated: truncated,
            rawDiff: raw.joined(separator: "\n"))
    }

    static func splitLines(_ text: String) -> [String] {
        text.isEmpty ? [] : text.components(separatedBy: "\n")
    }

    enum DiffOp: Equatable {
        case equal(oldIndex: Int, newIndex: Int)
        case delete(oldIndex: Int)
        case insert(newIndex: Int)
    }

    /// Line-level edit script. Hashes lines so comparisons are integer
    /// compares, trims the shared prefix/suffix, then runs Myers' greedy
    /// O((N+M)D) forward pass on the middle with `maxEditDistance` as the
    /// budget; a middle too different to reach falls back to delete-all /
    /// insert-all, which is still a correct (non-minimal) script.
    static func lineDiff(_ old: [String], _ new: [String]) -> [DiffOp] {
        let a = old.map(\.hashValue)
        let b = new.map(\.hashValue)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix], old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
            a[a.count - 1 - suffix] == b[b.count - 1 - suffix],
            old[a.count - 1 - suffix] == new[b.count - 1 - suffix]
        {
            suffix += 1
        }
        var ops: [DiffOp] = []
        ops.reserveCapacity(a.count + b.count)
        for i in 0..<prefix { ops.append(.equal(oldIndex: i, newIndex: i)) }

        let midA = Array(a[prefix..<(a.count - suffix)])
        let midB = Array(b[prefix..<(b.count - suffix)])
        let midOld = Array(old[prefix..<(a.count - suffix)])
        let midNew = Array(new[prefix..<(b.count - suffix)])
        if let middle = myers(midA, midB, old: midOld, new: midNew) {
            for op in middle {
                switch op {
                case .equal(let i, let j): ops.append(.equal(oldIndex: i + prefix, newIndex: j + prefix))
                case .delete(let i): ops.append(.delete(oldIndex: i + prefix))
                case .insert(let j): ops.append(.insert(newIndex: j + prefix))
                }
            }
        } else {
            for i in 0..<midA.count { ops.append(.delete(oldIndex: i + prefix)) }
            for j in 0..<midB.count { ops.append(.insert(newIndex: j + prefix)) }
        }
        for k in 0..<suffix {
            ops.append(.equal(oldIndex: a.count - suffix + k, newIndex: b.count - suffix + k))
        }
        return ops
    }

    /// Myers forward pass with trace-back. Nil when D exceeds the budget.
    private static func myers(_ a: [Int], _ b: [Int], old: [String], new: [String]) -> [DiffOp]? {
        let n = a.count
        let m = b.count
        if n == 0 { return (0..<m).map { .insert(newIndex: $0) } }
        if m == 0 { return (0..<n).map { .delete(oldIndex: $0) } }
        // Bound both time ((N+M)·D) and the trace memory (D·(2D+3) ints).
        let maxD = max(1, min(n + m, maxEditDistance, 40_000_000 / (n + m)))
        let offset = maxD + 1
        var v = [Int](repeating: 0, count: 2 * maxD + 3)
        var trace: [[Int]] = []
        func same(_ x: Int, _ y: Int) -> Bool { a[x] == b[y] && old[x] == new[y] }

        for d in 0...maxD {
            trace.append(v)
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset]) {
                    x = v[k + 1 + offset]
                } else {
                    x = v[k - 1 + offset] + 1
                }
                var y = x - k
                while x < n, y < m, same(x, y) {
                    x += 1
                    y += 1
                }
                v[k + offset] = x
                if x >= n, y >= m {
                    return backtrack(trace: trace, d: d, n: n, m: m, offset: offset)
                }
                k += 2
            }
        }
        return nil
    }

    private static func backtrack(trace: [[Int]], d: Int, n: Int, m: Int, offset: Int) -> [DiffOp] {
        var ops: [DiffOp] = []
        var x = n
        var y = m
        var depth = d
        while depth >= 0 {
            let v = trace[depth]
            let k = x - y
            let prevK: Int
            if k == -depth || (k != depth && v[k - 1 + offset] < v[k + 1 + offset]) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }
            let prevX = v[prevK + offset]
            let prevY = prevX - prevK
            while x > prevX, y > prevY {
                x -= 1
                y -= 1
                ops.append(.equal(oldIndex: x, newIndex: y))
            }
            if depth > 0 {
                if x == prevX {
                    y -= 1
                    ops.append(.insert(newIndex: y))
                } else {
                    x -= 1
                    ops.append(.delete(oldIndex: x))
                }
            }
            depth -= 1
        }
        ops.reverse()
        return ops
    }

    /// Fold unchanged runs beyond `contextLines` into meta rows, then cap
    /// the number of changed rows. Removed lines of a hunk come before its
    /// added lines so word highlights can pair them.
    static func collapse(_ ops: [DiffOp], old: [String], new: [String]) -> (lines: [FileDiff.Line], truncated: Bool) {
        var lines: [FileDiff.Line] = []
        var changedShown = 0
        var truncated = false
        var i = 0
        var pendingEqual: [String] = []
        var firstHunk = true

        func flushEqual(isLast: Bool) {
            guard !pendingEqual.isEmpty else { return }
            let lead = firstHunk ? 0 : contextLines
            let trail = isLast ? 0 : contextLines
            if pendingEqual.count > lead + trail {
                for line in pendingEqual.prefix(lead) { lines.append(.init(kind: .context, text: line)) }
                let folded = pendingEqual.count - lead - trail
                lines.append(.init(kind: .meta, text: L("\(folded) unchanged lines")))
                for line in pendingEqual.suffix(trail) { lines.append(.init(kind: .context, text: line)) }
            } else {
                for line in pendingEqual { lines.append(.init(kind: .context, text: line)) }
            }
            pendingEqual.removeAll()
        }

        while i < ops.count {
            switch ops[i] {
            case .equal(let oi, _):
                pendingEqual.append(old[oi])
                i += 1
            case .delete, .insert:
                flushEqual(isLast: false)
                firstHunk = false
                var removed: [String] = []
                var added: [String] = []
                while i < ops.count {
                    if case .delete(let oi) = ops[i] {
                        removed.append(old[oi])
                    } else if case .insert(let ni) = ops[i] {
                        added.append(new[ni])
                    } else {
                        break
                    }
                    i += 1
                }
                let budget = maxChangedLines - changedShown
                if removed.count + added.count > budget {
                    truncated = true
                    let keepRemoved = min(removed.count, budget)
                    let keepAdded = min(added.count, budget - keepRemoved)
                    removed = Array(removed.prefix(keepRemoved))
                    added = Array(added.prefix(keepAdded))
                }
                for line in removed { lines.append(.init(kind: .removed, text: line)) }
                for line in added { lines.append(.init(kind: .added, text: line)) }
                changedShown += removed.count + added.count
                if truncated { return (lines, true) }
            }
        }
        flushEqual(isLast: true)
        if lines.isEmpty, !old.isEmpty || !new.isEmpty {
            lines.append(.init(kind: .meta, text: L("no text changes")))
        }
        return (lines, truncated)
    }

    // MARK: - Word highlights

    /// Ranges of changed words inside replaced line pairs (a removed run
    /// followed by an added run of the same length), keyed by row index.
    /// Lines that are mostly different get no highlight (a solid tint reads
    /// better than confetti).
    static func wordHighlights(for lines: [FileDiff.Line]) -> [Int: [Range<String.Index>]] {
        var result: [Int: [Range<String.Index>]] = [:]
        var i = 0
        while i < lines.count {
            guard lines[i].kind == .removed else {
                i += 1
                continue
            }
            var j = i
            while j < lines.count, lines[j].kind == .removed { j += 1 }
            var k = j
            while k < lines.count, lines[k].kind == .added { k += 1 }
            let removedCount = j - i
            let addedCount = k - j
            if removedCount == addedCount {
                for offset in 0..<removedCount {
                    let (r, a) = wordRanges(lines[i + offset].text, lines[j + offset].text)
                    if !r.isEmpty { result[i + offset] = r }
                    if !a.isEmpty { result[j + offset] = a }
                }
            }
            i = k
        }
        return result
    }

    private static let maxHighlightLineLength = 600

    /// Token-level LCS between two lines; returns the ranges of tokens that
    /// differ on each side. Empty when the lines share less than a third.
    static func wordRanges(_ before: String, _ after: String) -> ([Range<String.Index>], [Range<String.Index>]) {
        guard before.count <= maxHighlightLineLength, after.count <= maxHighlightLineLength else { return ([], []) }
        let a = tokens(before)
        let b = tokens(after)
        guard !a.isEmpty, !b.isEmpty, a.count * b.count <= 40_000 else { return ([], []) }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] =
                    before[a[i]] == after[b[j]] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        let shared = table[0][0]
        let meaningful = max(a.count, b.count)
        guard shared * 3 >= meaningful else { return ([], []) }
        var removed: [Range<String.Index>] = []
        var added: [Range<String.Index>] = []
        var i = 0
        var j = 0
        while i < a.count, j < b.count {
            if before[a[i]] == after[b[j]] {
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                removed.append(a[i])
                i += 1
            } else {
                added.append(b[j])
                j += 1
            }
        }
        while i < a.count {
            removed.append(a[i])
            i += 1
        }
        while j < b.count {
            added.append(b[j])
            j += 1
        }
        return (merge(removed), merge(added))
    }

    /// Words and single punctuation/whitespace characters as ranges.
    private static func tokens(_ s: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            var j = s.index(after: i)
            if c.isLetter || c.isNumber || c == "_" {
                while j < s.endIndex, s[j].isLetter || s[j].isNumber || s[j] == "_" { j = s.index(after: j) }
            }
            out.append(i..<j)
            i = j
        }
        return out
    }

    private static func merge(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        for r in ranges {
            if let last = out.last, last.upperBound == r.lowerBound {
                out[out.count - 1] = last.lowerBound..<r.upperBound
            } else {
                out.append(r)
            }
        }
        return out
    }

    // MARK: - Documents

    /// A document flattened to reviewable lines, or nil when no adapter
    /// can parse it. A missing side is an empty document.
    static func documentLines(_ url: URL?) async -> String? {
        guard let url else { return "" }
        guard let adapter = DocumentFormatRegistry.shared.adapter(for: url) else { return nil }
        let limit = DocumentLimits.limit(forFormatId: adapter.formatId)
        guard let document = try? await adapter.parse(url: url, sizeLimit: limit) else { return nil }
        return canonicalLines(document).joined(separator: "\n")
    }

    static func canonicalLines(_ document: StructuredDocument) -> [String] {
        if let workbook = document.representation.underlying as? Workbook {
            var lines: [String] = []
            for sheet in workbook.sheets {
                lines.append("## Sheet: \(sheet.name)")
                for row in sheet.rows {
                    for cell in row.cells {
                        let value = cell.value.fallbackText
                        guard !value.isEmpty || cell.formula != nil else { continue }
                        var line = "\(cell.reference): \(value)"
                        if let formula = cell.formula { line += "  (=\(formula))" }
                        lines.append(line)
                    }
                }
            }
            return lines
        }
        var lines: [String] = []
        var counters: [DocumentElement.Kind: Int] = [:]
        func textLines(_ text: String?, prefix: String = "") {
            guard let text else { return }
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { lines.append(prefix + trimmed) }
            }
        }
        func walk(_ element: DocumentElement) {
            switch element.kind {
            case .page, .slide, .sheet:
                counters[element.kind, default: 0] += 1
                let label = element.kind == .page ? "Page" : element.kind == .slide ? "Slide" : "Sheet"
                lines.append("## \(label) \(counters[element.kind] ?? 0)")
                if element.children.isEmpty { textLines(element.text) } else { element.children.forEach(walk) }
            case .tableRow:
                let cells = element.children.map { ($0.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
                if cells.contains(where: { !$0.isEmpty }) { lines.append("| " + cells.joined(separator: " | ") + " |") }
            case .heading:
                textLines(element.text, prefix: String(repeating: "#", count: max(1, element.attributes.level ?? 1)) + " ")
            case .listItem:
                textLines(element.text, prefix: "- ")
            case .speakerNotes:
                textLines(element.text, prefix: "Notes: ")
            case .image:
                lines.append("[image]")
            case .chart:
                lines.append("[chart]")
            default:
                if element.children.isEmpty { textLines(element.text) } else { element.children.forEach(walk) }
            }
        }
        walk(document.structure.root)
        if lines.isEmpty { textLines(document.textFallback) }
        return lines
    }
}
