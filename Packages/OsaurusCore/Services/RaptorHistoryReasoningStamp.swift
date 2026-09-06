//
//  RaptorHistoryReasoningStamp.swift
//  OsaurusCore
//
//  Installed Raptor bundles get `reasoning.history_reasoning: "omit"` stamped
//  into their jang_config.json so `DeclaredReasoningEffort.historyReasoningOmitted`
//  applies to existing installs, not only to bundles downloaded after the key
//  was added upstream. Raptor v0.5 copies its own prior tool-cycle `<think>`
//  verbatim once one identical turn exists (engine ladder 4/5, 5/5, 4/5
//  re-issue with history thinking kept vs 0/5, 1/5, 0/5 without; live pairs
//  median 21 → 9 tool calls). The rewrite is textual (one inserted line,
//  formatting and key order preserved), verified by re-parsing, idempotent,
//  and scoped to bundle ids under `OsaurusAI/Raptor`.
//

import Foundation

enum RaptorHistoryReasoningStamp {

    /// Bundle ids this stamp applies to (case-insensitive prefix match).
    static let bundleIdPrefix = "osaurusai/raptor"

    static func appliesTo(modelId: String) -> Bool {
        modelId.lowercased().hasPrefix(bundleIdPrefix)
    }

    /// The rewritten jang_config text, or nil when nothing should change: the
    /// key is already present, there is no top-level `reasoning` object, or
    /// the result would not parse back with the key in place.
    static func stamped(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let reasoning = root["reasoning"] as? [String: Any],
            reasoning["history_reasoning"] == nil,
            let open = text.range(of: #""reasoning"\s*:\s*\{"#, options: .regularExpression)
        else { return nil }

        let lineStart =
            text[..<open.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let indent = String(text[lineStart..<open.lowerBound].prefix { $0 == " " || $0 == "\t" })
        let rest = text[open.upperBound...]
        let blockIsEmpty = rest.first(where: { !$0.isWhitespace }) == "}"
        let insertion = "\n\(indent)  \"history_reasoning\": \"omit\"" + (blockIsEmpty ? "" : ",")

        var out = text
        out.insert(contentsOf: insertion, at: open.upperBound)

        guard let outData = out.data(using: .utf8),
            let outRoot = try? JSONSerialization.jsonObject(with: outData) as? [String: Any],
            (outRoot["reasoning"] as? [String: Any])?["history_reasoning"] as? String == "omit"
        else { return nil }
        return out
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var checkedThisProcess: Set<String> = []  // guarded by `lock`

    /// Called on the model LOAD path, for this bundle only: one small file
    /// read the first time a Raptor bundle is loaded in this process, nothing
    /// for any other model id. Never throws and never blocks the load: an
    /// unreadable or unwritable file (read-only volume) is logged and the
    /// load proceeds exactly as before. Returns true when the file was
    /// rewritten.
    @discardableResult
    static func stampIfNeeded(modelId: String, directory: URL?) -> Bool {
        guard appliesTo(modelId: modelId), let directory else { return false }
        let key = modelId.lowercased()
        lock.lock()
        let alreadyChecked = checkedThisProcess.contains(key)
        lock.unlock()
        if alreadyChecked { return false }

        // The memo is set only once the file is known to carry the key
        // (already stamped, or stamped now). A missing/unreadable/unwritable
        // file is NOT memoised, so a later load (volume mounted, permissions
        // fixed) gets another cheap try.
        let url = directory.appendingPathComponent("jang_config.json")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        guard let rewritten = stamped(text) else {
            if Self.carriesKey(text) { markChecked(key) }
            return false
        }
        do {
            try rewritten.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("[Osaurus][RaptorStamp] could not stamp \(url.path): \(error.localizedDescription)")
            return false
        }
        markChecked(key)
        print("[Osaurus][RaptorStamp] history_reasoning=omit stamped into \(url.path)")
        DeclaredReasoningEffort.invalidate()
        return true
    }

    private static func markChecked(_ key: String) {
        lock.lock(); checkedThisProcess.insert(key); lock.unlock()
    }

    private static func carriesKey(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (root["reasoning"] as? [String: Any])?["history_reasoning"] != nil
    }

    /// Test hook: forget the per-process memo.
    static func resetForTests() {
        lock.lock(); checkedThisProcess.removeAll(); lock.unlock()
    }
}
