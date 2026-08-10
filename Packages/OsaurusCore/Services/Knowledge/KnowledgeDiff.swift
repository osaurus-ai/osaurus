//
//  KnowledgeDiff.swift
//  osaurus
//
//  Minimal line diff for the proposal review sheet: current document vs
//  proposed content. LCS over lines with common prefix/suffix trimming;
//  documents are capped at 2MB by the proposal tool, and pathological
//  inputs degrade to one replace block instead of an expensive diff.
//

import Foundation

public enum KnowledgeDiff {
    public enum LineKind: Sendable, Equatable {
        case context
        case added
        case removed
    }

    public struct Line: Sendable, Equatable, Identifiable {
        public let id: Int
        public let kind: LineKind
        public let text: String
    }

    /// Beyond this many middle (post-trim) lines per side, skip the LCS
    /// and emit a single removed-block + added-block. Keeps worst-case
    /// memory/time bounded for the UI thread that renders the result.
    static let lcsLineCap = 1500

    /// Line-based diff of `old` → `new`. Context lines are shared,
    /// removed lines exist only in `old`, added lines only in `new`.
    public static func lines(old: String, new: String) -> [Line] {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")

        // Trim common prefix.
        var start = 0
        while start < oldLines.count, start < newLines.count, oldLines[start] == newLines[start] {
            start += 1
        }
        // Trim common suffix (not overlapping the prefix).
        var oldEnd = oldLines.count
        var newEnd = newLines.count
        while oldEnd > start, newEnd > start, oldLines[oldEnd - 1] == newLines[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }

        let oldMid = Array(oldLines[start ..< oldEnd])
        let newMid = Array(newLines[start ..< newEnd])

        var result: [Line] = []
        var nextId = 0
        func append(_ kind: LineKind, _ text: String) {
            result.append(Line(id: nextId, kind: kind, text: text))
            nextId += 1
        }

        for line in oldLines[0 ..< start] { append(.context, line) }

        if oldMid.count > Self.lcsLineCap || newMid.count > Self.lcsLineCap {
            for line in oldMid { append(.removed, line) }
            for line in newMid { append(.added, line) }
        } else {
            for entry in lcsDiff(oldMid, newMid) {
                append(entry.kind, entry.text)
            }
        }

        for line in oldLines[oldEnd...] { append(.context, line) }
        return result
    }

    /// Whether the two contents differ at all (cheap pre-check for the UI).
    public static func hasChanges(old: String, new: String) -> Bool {
        old != new
    }

    // MARK: - LCS core

    private static func lcsDiff(_ old: [String], _ new: [String]) -> [(kind: LineKind, text: String)] {
        guard !old.isEmpty || !new.isEmpty else { return [] }
        if old.isEmpty { return new.map { (.added, $0) } }
        if new.isEmpty { return old.map { (.removed, $0) } }

        // Standard LCS length table (bounded by lcsLineCap per side).
        let n = old.count
        let m = new.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if old[i] == new[j] {
                    table[i][j] = table[i + 1][j + 1] + 1
                } else {
                    table[i][j] = max(table[i + 1][j], table[i][j + 1])
                }
            }
        }

        var result: [(kind: LineKind, text: String)] = []
        var i = 0
        var j = 0
        while i < n, j < m {
            if old[i] == new[j] {
                result.append((.context, old[i]))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                result.append((.removed, old[i]))
                i += 1
            } else {
                result.append((.added, new[j]))
                j += 1
            }
        }
        while i < n {
            result.append((.removed, old[i]))
            i += 1
        }
        while j < m {
            result.append((.added, new[j]))
            j += 1
        }
        return result
    }
}
