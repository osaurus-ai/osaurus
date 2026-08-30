//
//  KnowledgeGlob.swift
//  osaurus
//
//  Path-glob matching for knowledge collection include/exclude filters.
//  Matches a collection-relative, `/`-separated path (e.g.
//  `docs/ENGINES.md`) against gitignore-style patterns.
//
//  Supported syntax:
//    *   — any run of characters except `/` (stays within one path segment)
//    ?   — any single character except `/`
//    **  — any run of characters including `/` (crosses directories)
//    **/ — zero or more leading directories (so `**/*.md` matches at any depth)
//  A pattern with no `/` (e.g. `*.md`) matches only the basename convention
//  of the top level; use `**/*.md` to match at any depth. A trailing `/**`
//  (e.g. `src/**`) matches the directory's whole subtree.
//

import Foundation

public enum KnowledgeGlob {
    /// Include/exclude decision for one relative path.
    /// - Exclude wins over include.
    /// - Empty `include` means "everything is included" (subject to exclude).
    public static func matches(_ relPath: String, include: [String], exclude: [String]) -> Bool {
        let path = normalize(relPath)
        if exclude.contains(where: { matchesPattern(path, pattern: $0) }) { return false }
        if include.isEmpty { return true }
        return include.contains(where: { matchesPattern(path, pattern: $0) })
    }

    /// True when a single path matches a single glob pattern.
    public static func matchesPattern(_ relPath: String, pattern rawPattern: String) -> Bool {
        let path = normalize(relPath)
        let pattern = normalize(rawPattern)
        guard !pattern.isEmpty else { return false }
        guard let regex = compiledCache.regex(for: pattern) else { return false }
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        return regex.firstMatch(in: path, options: [], range: range) != nil
    }

    // MARK: - Internals

    /// Trim, drop a leading `./`, and collapse a leading `/` — patterns and
    /// paths are both collection-relative.
    private static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        while t.hasPrefix("./") { t.removeFirst(2) }
        while t.hasPrefix("/") { t.removeFirst() }
        return t
    }

    /// Translate a glob to an anchored regex string. `**` is tokenized before
    /// `*` so the single-segment wildcard never consumes it.
    static func regexString(for pattern: String) -> String {
        var out = "^"
        let scalars = Array(pattern)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            switch c {
            case "*":
                if i + 1 < scalars.count, scalars[i + 1] == "*" {
                    // `**` — crosses directories. `**/` also allows matching at
                    // depth zero (so `**/x` matches a top-level `x`).
                    if i + 2 < scalars.count, scalars[i + 2] == "/" {
                        out += "(?:.*/)?"
                        i += 3
                    } else {
                        out += ".*"
                        i += 2
                    }
                } else {
                    out += "[^/]*"
                    i += 1
                }
            case "?":
                out += "[^/]"
                i += 1
            case ".", "(", ")", "+", "|", "^", "$", "{", "}", "[", "]", "\\":
                out += "\\" + String(c)
                i += 1
            default:
                out += String(c)
                i += 1
            }
        }
        out += "$"
        return out
    }

    /// Small compiled-pattern cache — indexing evaluates the same handful of
    /// patterns across thousands of files.
    private static let compiledCache = RegexCache()

    private final class RegexCache: @unchecked Sendable {
        private let lock = NSLock()
        private var cache: [String: NSRegularExpression] = [:]

        func regex(for pattern: String) -> NSRegularExpression? {
            lock.lock()
            defer { lock.unlock() }
            if let cached = cache[pattern] { return cached }
            guard
                let regex = try? NSRegularExpression(
                    pattern: KnowledgeGlob.regexString(for: pattern),
                    options: []
                )
            else { return nil }
            cache[pattern] = regex
            return regex
        }
    }
}
