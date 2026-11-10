//
//  ConfigDiff.swift
//  osaurus
//
//  Differences between two declarative documents, computed once and read two
//  ways: a unified text diff for people (the approval card, History, the
//  `diff` action) and a structured path list for the model. Also builds the
//  approval card's preview: the current document with a plan's desired
//  sections merged on, using the same merge rules the applier follows
//  (merge by default, entities by name, explicit null clears, prune only
//  where asked).
//

import Foundation
import Yams

public struct ConfigDiff: Sendable, Equatable {
    public enum ChangeKind: String, Sendable { case added, removed, changed }

    public struct Change: Sendable, Equatable {
        public let path: String
        public let kind: ChangeKind
        public var row: [String: String] { ["path": path, "change": kind.rawValue] }
    }

    /// Unified text, empty when the documents are equal.
    public let unified: String
    public let changes: [Change]

    public var isEmpty: Bool { changes.isEmpty && unified.isEmpty }
    public var lineCount: Int { unified.isEmpty ? 0 : unified.split(separator: "\n", omittingEmptySubsequences: false).count }

    /// Diff of two canonical YAML documents.
    public static func compute(before: String, after: String, fromLabel: String = "before", toLabel: String = "after")
        -> ConfigDiff
    {
        let beforeTree = (try? Yams.load(yaml: before)) ?? nil
        let afterTree = (try? Yams.load(yaml: after)) ?? nil
        var changes: [Change] = []
        walk(beforeTree, afterTree, path: "", spec: nil, into: &changes)
        let text = unifiedText(before: before, after: after, fromLabel: fromLabel, toLabel: toLabel)
        return ConfigDiff(unified: changes.isEmpty && text.isEmpty ? "" : text, changes: changes)
    }

    // MARK: - Plan preview

    /// The diff an apply of `desired` would make to `currentYAML` (canonical),
    /// or nil when the document names a section this preview cannot model.
    public static func preview(currentYAML: String, desired: OsaurusConfigDocument, prune: Bool) -> String? {
        guard let desiredYAML = try? ConfigYAML.canonical(desired),
            let desiredTree = (try? Yams.load(yaml: desiredYAML)) as? [String: Any]
        else { return nil }
        let currentTree = ((try? Yams.load(yaml: currentYAML)) as? [String: Any]) ?? [:]
        var merged = currentTree
        for (key, value) in desiredTree where key != "version" {
            guard let spec = ConfigManifest.sections.first(where: { $0.id.rawValue == key })?.value else {
                return nil
            }
            let next = merge(current: currentTree[key], desired: value, spec: spec, topLevel: true, prune: prune)
            merged[key] = next
        }
        guard let before = try? Yams.dump(object: currentTree, sortKeys: true),
            let after = try? Yams.dump(object: merged.compactMapValues { $0 }, sortKeys: true)
        else { return nil }
        return compute(before: before, after: after, fromLabel: "current", toLabel: "after apply").unified
    }

    private static func merge(current: Any?, desired: Any, spec: ConfigValueSpec, topLevel: Bool, prune: Bool) -> Any? {
        if desired is NSNull { return nil }
        switch spec {
        case .mapping(let keys), .nullableMapping(let keys):
            guard let wanted = desired as? [String: Any] else { return desired }
            var out = (current as? [String: Any]) ?? [:]
            for (key, value) in wanted {
                let child = keys.first { $0.key == key }?.value
                if let child {
                    out[key] = merge(current: out[key], desired: value, spec: child, topLevel: false, prune: prune)
                } else {
                    out[key] = value is NSNull ? nil : value
                }
            }
            return out
        case .entityList(let keys, let requiredKey):
            guard let wanted = desired as? [Any] else { return desired }
            var out: [Any] = (topLevel && prune) ? [] : ((current as? [Any]) ?? [])
            let existing = (current as? [Any]) ?? []
            func name(_ item: Any) -> String? { ((item as? [String: Any])?[requiredKey] as? String)?.lowercased() }
            for item in wanted {
                guard let key = name(item) else { continue }
                let base = existing.first { name($0) == key }
                let merged = merge(current: base, desired: item, spec: .mapping(keys), topLevel: false, prune: prune)
                if let index = out.firstIndex(where: { name($0) == key }) {
                    out[index] = merged ?? item
                } else if let merged {
                    out.append(merged)
                }
            }
            return out
        case .scalarList, .nullableScalarList:
            guard topLevel, !prune, let wanted = desired as? [Any] else { return desired }
            var out = (current as? [Any]) ?? []
            for item in wanted where !out.contains(where: { "\($0)" == "\(item)" }) { out.append(item) }
            return out
        case .freeformMap:
            guard let wanted = desired as? [String: Any] else { return desired }
            var out = (current as? [String: Any]) ?? [:]
            for (key, value) in wanted { out[key] = value is NSNull ? nil : value }
            return out
        case .scalar, .jsonObject:
            return desired
        }
    }

    // MARK: - Structured changes

    private static func walk(_ before: Any?, _ after: Any?, path: String, spec: ConfigValueSpec?, into changes: inout [Change]) {
        let before = before is NSNull ? nil : before
        let after = after is NSNull ? nil : after
        switch (before, after) {
        case (nil, nil):
            return
        case (nil, _):
            changes.append(Change(path: path, kind: .added))
            return
        case (_, nil):
            changes.append(Change(path: path, kind: .removed))
            return
        default: break
        }
        if let old = before as? [String: Any], let new = after as? [String: Any] {
            for key in Set(old.keys).union(new.keys).sorted() {
                let child = path.isEmpty ? key : "\(path).\(key)"
                walk(old[key], new[key], path: child, spec: childSpec(spec, key: key, root: path.isEmpty), into: &changes)
            }
            return
        }
        if let old = before as? [Any], let new = after as? [Any] {
            if case .entityList(let keys, let requiredKey)? = spec {
                func keyed(_ list: [Any]) -> [String: Any] {
                    var out: [String: Any] = [:]
                    for item in list {
                        if let name = (item as? [String: Any])?[requiredKey] as? String { out[name] = item }
                    }
                    return out
                }
                let oldItems = keyed(old)
                let newItems = keyed(new)
                for name in Set(oldItems.keys).union(newItems.keys).sorted() {
                    walk(oldItems[name], newItems[name], path: "\(path)[\(name)]", spec: .mapping(keys), into: &changes)
                }
                return
            }
            if render(old) != render(new) { changes.append(Change(path: path, kind: .changed)) }
            return
        }
        if render(before) != render(after) { changes.append(Change(path: path, kind: .changed)) }
    }

    private static func childSpec(_ spec: ConfigValueSpec?, key: String, root: Bool) -> ConfigValueSpec? {
        if root { return ConfigManifest.sections.first { $0.id.rawValue == key }?.value }
        switch spec {
        case .mapping(let keys)?, .nullableMapping(let keys)?: return keys.first { $0.key == key }?.value
        default: return nil
        }
    }

    private static func render(_ value: Any?) -> String {
        guard let value else { return "" }
        return (try? Yams.dump(object: value, sortKeys: true)) ?? String(describing: value)
    }

    // MARK: - Unified text

    /// Above this many cells the middle section is shown as a block replace
    /// rather than aligned line by line.
    private static let maxAlignedCells = 4_000_000

    static func unifiedText(before: String, after: String, fromLabel: String, toLabel: String, context: Int = 3)
        -> String
    {
        if before == after { return "" }
        let a = before.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let b = after.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let ops = editScript(a, b)
        guard ops.contains(where: { $0.kind != .same }) else { return "" }

        var lines = ["--- \(fromLabel)", "+++ \(toLabel)"]
        var index = 0
        while index < ops.count {
            guard let start = ops[index...].firstIndex(where: { $0.kind != .same }) else { break }
            var end = start
            var cursor = start
            while cursor < ops.count {
                if ops[cursor].kind != .same {
                    end = cursor
                    cursor += 1
                    continue
                }
                let run = ops[cursor...].prefix { $0.kind == .same }.count
                if cursor + run >= ops.count || run > context * 2 { break }
                cursor += run
            }
            let hunkStart = max(0, start - context)
            let hunkEnd = min(ops.count - 1, end + context)
            let hunk = ops[hunkStart ... hunkEnd]
            let aStart = (hunk.first?.aIndex ?? 0) + 1
            let bStart = (hunk.first?.bIndex ?? 0) + 1
            let aCount = hunk.filter { $0.kind != .insert }.count
            let bCount = hunk.filter { $0.kind != .delete }.count
            lines.append("@@ -\(aStart),\(aCount) +\(bStart),\(bCount) @@")
            for op in hunk {
                switch op.kind {
                case .same: lines.append(" " + a[op.aIndex])
                case .delete: lines.append("-" + a[op.aIndex])
                case .insert: lines.append("+" + b[op.bIndex])
                }
            }
            index = hunkEnd + 1
        }
        return lines.joined(separator: "\n")
    }

    private struct Op {
        enum Kind { case same, delete, insert }
        let kind: Kind
        /// Position in `a` (for `.insert`, the position the line lands before).
        let aIndex: Int
        let bIndex: Int
    }

    private static func editScript(_ a: [String], _ b: [String]) -> [Op] {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
            a[a.count - 1 - suffix] == b[b.count - 1 - suffix]
        {
            suffix += 1
        }
        var ops: [Op] = (0 ..< prefix).map { Op(kind: .same, aIndex: $0, bIndex: $0) }
        let midA = Array(a[prefix ..< (a.count - suffix)])
        let midB = Array(b[prefix ..< (b.count - suffix)])
        let n = midA.count
        let m = midB.count
        if n * m > maxAlignedCells || n == 0 || m == 0 {
            ops += (0 ..< n).map { Op(kind: .delete, aIndex: prefix + $0, bIndex: prefix) }
            ops += (0 ..< m).map { Op(kind: .insert, aIndex: prefix + n, bIndex: prefix + $0) }
        } else {
            // LCS table over the differing middle.
            var table = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i][j] =
                        midA[i] == midB[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
            var i = 0
            var j = 0
            while i < n || j < m {
                if i < n, j < m, midA[i] == midB[j] {
                    ops.append(Op(kind: .same, aIndex: prefix + i, bIndex: prefix + j))
                    i += 1
                    j += 1
                } else if j < m, i == n || table[i][j + 1] >= table[i + 1][j] {
                    ops.append(Op(kind: .insert, aIndex: prefix + i, bIndex: prefix + j))
                    j += 1
                } else {
                    ops.append(Op(kind: .delete, aIndex: prefix + i, bIndex: prefix + j))
                    i += 1
                }
            }
        }
        ops += (0 ..< suffix).map { Op(kind: .same, aIndex: a.count - suffix + $0, bIndex: b.count - suffix + $0) }
        return ops
    }
}
